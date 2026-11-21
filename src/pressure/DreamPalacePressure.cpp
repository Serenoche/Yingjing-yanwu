#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#include <intrin.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace {
// Steam CL-302256_JKS-17280. The overlay also verifies the game file hash.
constexpr DWORD GameTimestamp = 0x6ae7ae3f;
constexpr DWORD GameImageSize = 0x1e0bb000;
constexpr std::size_t EvaluatorVtable = 0x0bf82148;
constexpr std::size_t EvaluatorReadoutSlot = 0x2b8;
constexpr std::size_t EvaluatorTickSlot = 0x2c0;
constexpr std::size_t EvaluatorRaw = 0x70;
constexpr std::size_t EvaluatorConfidence = 0xc8;
constexpr std::size_t ObjectOuter = 0x20;
constexpr std::size_t ProfileEvaluator = 0x38;
constexpr std::size_t ProfileShadows = 0x40;
constexpr std::size_t WorldSessions = 0xc0;
constexpr std::size_t SessionStride = 0x160;
constexpr std::size_t SessionProfile = 0x10;
constexpr std::size_t SessionRaw = 0x18;
constexpr std::size_t SessionActive = 0x151;

struct WeakObject {
    std::int32_t index;
    std::int32_t serial;
    bool operator==(const WeakObject&) const = default;
};

struct EvaluationContext {
    void* playerState;
    float* bossPressure;
    void* profile;
    WeakObject boss;
};
static_assert(offsetof(EvaluationContext, boss) == 0x18);

struct Readout {
    float raw;
    std::uint8_t tier;
    float confidence;
};
static_assert(offsetof(Readout, confidence) == 8);

enum class PressureMode { Floor, Fixed, Minimum };

struct PressureRule {
    PressureMode mode;
    int value;
};

struct Binding {
    std::int64_t token;
    void* subsystem;
    WeakObject worldKey;
    WeakObject bossKey;
    PressureRule rule;
    bool observe;
    float nativeRaw;
    std::int64_t updates;
    std::int64_t readouts;
    std::int64_t aiQueries;
};

struct lua_State;
std::int64_t (*luaToInteger)(lua_State*, int, int*);
void (*luaPushInteger)(lua_State*, std::int64_t);
void (*luaPushNumber)(lua_State*, double);
constexpr int LuaBridgeProbe = 6;

using TickFunction = void (*)(void*, float, const EvaluationContext*);
using ReadoutFunction = Readout* (*)(void*, Readout*);
struct EvaluatorArray {
    void** data;
    std::int32_t size;
};
TickFunction originalTick;
ReadoutFunction originalReadout;
void (*makeWeak)(WeakObject*, void* const*);
void* (*resolveWeak)(const WeakObject*);
int (*findSession)(void*, std::uint32_t, const WeakObject*);
void* nativeReadoutReturn;
void* aiQueryReturn;
std::array<Binding, 16> bindings{};
std::size_t bindingCount;
DWORD gameThread;
std::int64_t nextToken = 1;

template <class T>
T& field(void* object, std::size_t offset) {
    return *reinterpret_cast<T*>(static_cast<std::byte*>(object) + offset);
}

template <typename Function, std::size_t Size>
Function checked(void* image, std::size_t offset, const unsigned char (&bytes)[Size]) {
    auto* target = static_cast<std::byte*>(image) + offset;
    return std::memcmp(target, bytes, Size) == 0 ? reinterpret_cast<Function>(target) : nullptr;
}

bool matchesImage(void* image, DWORD timestamp, DWORD size) {
    if (!image) return false;
    const auto& dos = field<IMAGE_DOS_HEADER>(image, 0);
    if (dos.e_magic != IMAGE_DOS_SIGNATURE || dos.e_lfanew <= 0) return false;
    const auto& nt = field<IMAGE_NT_HEADERS64>(image, dos.e_lfanew);
    return nt.Signature == IMAGE_NT_SIGNATURE && nt.FileHeader.Machine == IMAGE_FILE_MACHINE_AMD64
        && nt.FileHeader.TimeDateStamp == timestamp && nt.OptionalHeader.SizeOfImage == size;
}

struct CodeSection {
    std::uintptr_t start;
    std::size_t size;
};

CodeSection loaderCode(HMODULE loader) {
    if (!loader) return {};
    const auto& dos = field<IMAGE_DOS_HEADER>(loader, 0);
    if (dos.e_magic != IMAGE_DOS_SIGNATURE || dos.e_lfanew <= 0) return {};
    const auto& nt = field<IMAGE_NT_HEADERS64>(loader, dos.e_lfanew);
    if (nt.Signature != IMAGE_NT_SIGNATURE || nt.FileHeader.Machine != IMAGE_FILE_MACHINE_AMD64
        || nt.OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC) return {};
    constexpr DWORD ReadExecute = IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE;
    const auto* sections = IMAGE_FIRST_SECTION(&nt);
    for (unsigned i = 0; i < nt.FileHeader.NumberOfSections; ++i) {
        const auto& section = sections[i];
        if (std::memcmp(section.Name, ".text", sizeof(".text")) != 0) continue;
        if ((section.Characteristics & ReadExecute) != ReadExecute
            || section.VirtualAddress >= nt.OptionalHeader.SizeOfImage
            || section.Misc.VirtualSize > nt.OptionalHeader.SizeOfImage - section.VirtualAddress) return {};
        return {reinterpret_cast<std::uintptr_t>(loader) + section.VirtualAddress, section.Misc.VirtualSize};
    }
    return {};
}

template <typename Function, std::size_t WrapperSize, std::size_t EntrySize>
Function resolveLuaApi(HMODULE loader, CodeSection code, const char* exportName,
                       const unsigned char (&wrapper)[WrapperSize], const unsigned char (&entry)[EntrySize]) {
    // Match an exported wrapper through its direct call/jump opcode. The
    // displacement follows the matched bytes and must stay within .text.
    constexpr std::size_t InstructionEnd = WrapperSize + sizeof(std::int32_t);
    const auto address = reinterpret_cast<std::uintptr_t>(GetProcAddress(loader, exportName));
    if (address < code.start || InstructionEnd > code.size || address - code.start > code.size - InstructionEnd) {
        return nullptr;
    }
    const auto* bytes = reinterpret_cast<const unsigned char*>(address);
    if (std::memcmp(bytes, wrapper, WrapperSize) != 0) return nullptr;
    std::int32_t displacement;
    std::memcpy(&displacement, bytes + WrapperSize, sizeof(displacement));
    const auto offset = static_cast<std::int64_t>(address - code.start + InstructionEnd) + displacement;
    if (offset < 0 || EntrySize > code.size || static_cast<std::size_t>(offset) > code.size - EntrySize) {
        return nullptr;
    }
    const auto* target = reinterpret_cast<const unsigned char*>(code.start + offset);
    return std::memcmp(target, entry, EntrySize) == 0 ? reinterpret_cast<Function>(target) : nullptr;
}

bool bindLua() {
    // UE4SS links Lua internally. These LuaMadeSimple exports identify its
    // Lua 5.4 functions even when a rebuild shifts their addresses.
    const auto loader = GetModuleHandleW(L"UE4SS.dll");
    const auto code = loaderCode(loader);
    if (!code.size) return false;
    constexpr unsigned char SetValue[] = {0x48, 0x8b, 0x09, 0xe9};
    luaToInteger = resolveLuaApi<decltype(luaToInteger)>(loader, code,
        "?get_integer@Lua@LuaMadeSimple@RC@@QEBA_JH@Z",
        {0x48, 0x89, 0x5c, 0x24, 0x08, 0x48, 0x89, 0x74, 0x24, 0x10, 0x57, 0x48, 0x83, 0xec,
         0x20, 0x48, 0x8b, 0xf1, 0x45, 0x33, 0xc0, 0x48, 0x8b, 0x09, 0x8b, 0xfa, 0xe8},
        {0x40, 0x53, 0x48, 0x83, 0xec, 0x20, 0x49, 0x8b, 0xd8, 0x48, 0xc7, 0x44, 0x24, 0x40,
         0x00, 0x00, 0x00, 0x00, 0xe8});
    luaPushInteger = resolveLuaApi<decltype(luaPushInteger)>(loader, code,
        "?set_integer@Lua@LuaMadeSimple@RC@@QEBAX_J@Z", SetValue,
        {0x48, 0x89, 0x5c, 0x24, 0x08, 0x57, 0x48, 0x83, 0xec, 0x20, 0x48, 0x8b, 0xda, 0x48,
         0x8b, 0xf9, 0xe8});
    luaPushNumber = resolveLuaApi<decltype(luaPushNumber)>(loader, code,
        "?set_number@Lua@LuaMadeSimple@RC@@QEBAXN@Z", SetValue,
        {0x40, 0x53, 0x48, 0x83, 0xec, 0x30, 0x0f, 0x29, 0x74, 0x24, 0x20, 0x48, 0x8b, 0xd9,
         0x0f, 0x28, 0xf1, 0xe8});
    return luaToInteger && luaPushInteger && luaPushNumber;
}

float applyPressure(float native, PressureRule rule) {
    if (rule.mode == PressureMode::Floor) {
        if (rule.value < 41 || rule.value > 101) return native;
        if (rule.value >= 100) return 100;
    }
    const float value = static_cast<float>(rule.value);
    if (rule.mode == PressureMode::Fixed) return value;
    if (native > 100) return 100;
    return native >= value ? native : value;
}

std::uint8_t tierFor(float raw) {
    // The native evaluator uses inclusive upper limits for each lower tier.
    return raw <= -40 ? 0 : raw <= -10 ? 1 : raw <= 10 ? 2 : raw <= 40 ? 3 : raw <= 75 ? 4 : 5;
}

void* sessionFor(void* subsystem, const WeakObject& boss) {
    void* map = static_cast<std::byte*>(subsystem) + WorldSessions;
    const auto hash = static_cast<std::uint32_t>(boss.index) ^ static_cast<std::uint32_t>(boss.serial);
    const int index = findSession(map, hash, &boss);
    if (index < 0) return nullptr;
    auto* entry = field<std::byte*>(map, 0) + static_cast<std::size_t>(index) * SessionStride;
    return field<bool>(entry, SessionActive) ? entry : nullptr;
}

void* evaluatorFor(void* session) {
    auto* profile = field<void*>(session, SessionProfile);
    return profile ? field<void*>(profile, ProfileEvaluator) : nullptr;
}

bool ownsEvaluator(void* subsystem, void* profile, void* evaluator) {
    return profile && evaluator && field<void*>(profile, ObjectOuter) == subsystem
        && field<void*>(evaluator, ObjectOuter) == profile;
}

Binding* boundActor(const WeakObject& boss) {
    for (auto& binding : bindings) {
        if (binding.token && binding.bossKey == boss && resolveWeak(&binding.worldKey) == binding.subsystem) {
            return &binding;
        }
    }
    return nullptr;
}

bool isGameThread() {
    return GetCurrentThreadId() == gameThread;
}

void applyToSession(Binding& binding, void* evaluator, float& sessionRaw, bool updated) {
    auto& evaluatorRaw = field<float>(evaluator, EvaluatorRaw);
    binding.nativeRaw = evaluatorRaw;
    if (updated) ++binding.updates;
    sessionRaw = applyPressure(evaluatorRaw, binding.rule);
    // Keep the evaluator's original progression for the menu-driven modes.
    // The floor mode retains the already tested Dream Palace behavior.
    if (binding.rule.mode == PressureMode::Floor) evaluatorRaw = sessionRaw;
}

void tickPressure(void* evaluator, float delta, const EvaluationContext* context) {
    originalTick(evaluator, delta, context);
    if (!isGameThread() || !bindingCount || !context || !context->bossPressure) return;
    auto* binding = boundActor(context->boss);
    if (!binding || !ownsEvaluator(binding->subsystem, context->profile, evaluator)) return;
    auto* primary = field<void*>(context->profile, ProfileEvaluator);
    if (evaluator == primary) {
        applyToSession(*binding, evaluator, *context->bossPressure, true);
    } else {
        // The world subsystem ticks the shadows after the primary. A shadow
        // can write to the same BossState, which also drives the tier event.
        *context->bossPressure = applyPressure(field<float>(primary, EvaluatorRaw), binding->rule);
    }
}

Readout* readPressure(void* evaluator, Readout* output) {
    auto* result = originalReadout(evaluator, output);
    // GetReadout is also called directly by the native behavior-tree decorator.
    // The other virtual read calls are for the evaluator's own calculations.
    if (!isGameThread() || !bindingCount || _ReturnAddress() != nativeReadoutReturn) return result;
    for (auto& binding : bindings) {
        if (!binding.token || !resolveWeak(&binding.bossKey) || !resolveWeak(&binding.worldKey)) continue;
        auto* session = sessionFor(binding.subsystem, binding.bossKey);
        if (!session || evaluatorFor(session) != evaluator
            || !ownsEvaluator(binding.subsystem, field<void*>(session, SessionProfile), evaluator)) continue;
        result->raw = applyPressure(result->raw, binding.rule);
        result->tier = tierFor(result->raw);
        if (binding.observe) {
            ++binding.readouts;
            // The audited subsystem reader saves two registers and reserves
            // 0xc8 bytes. Its caller is 0xe0 bytes above this return address.
            auto* stack = static_cast<std::byte*>(_AddressOfReturnAddress());
            if (field<void*>(stack, 0xe0) == aiQueryReturn) ++binding.aiQueries;
        }
        break;
    }
    return result;
}

bool installPressure() {
    void* image = GetModuleHandleW(nullptr);
    if (!matchesImage(image, GameTimestamp, GameImageSize)) return false;
    if (gameThread) return isGameThread();
    originalTick = checked<TickFunction>(image, 0x064eecf0,
        {0x48,0x8b,0xc4,0x55,0x41,0x55,0x41,0x56,0x48,0x8d,0x68,0xa1});
    originalReadout = checked<ReadoutFunction>(image, 0x064e5480,
        {0x48,0x89,0x5c,0x24,0x10,0x48,0x89,0x6c,0x24,0x18,0x56,0x57});
    makeWeak = checked<decltype(makeWeak)>(image, 0x0166e900,
        {0x40,0x53,0x48,0x83,0xec,0x20,0x48,0x8b,0x12,0x48,0x8b,0xd9});
    resolveWeak = checked<decltype(resolveWeak)>(image, 0x01672710,
        {0x44,0x8b,0x49,0x04,0x45,0x85,0xc9,0x74,0x48,0x8b,0x01,0x85});
    findSession = checked<decltype(findSession)>(image, 0x064de640,
        {0x48,0x89,0x5c,0x24,0x10,0x56,0x57,0x41,0x56,0x48,0x83,0xec});
    auto* readoutEntry = checked<void*>(image, 0x064e5660,
        {0x4c,0x8b,0xdc,0x53,0x55,0x48,0x81,0xec,0xc8,0x00,0x00,0x00});
    auto* queryCall = checked<std::byte*>(image, 0x064e26fa,
        {0xe8,0x61,0x2f,0x00,0x00,0xf3,0x0f,0x10,0x44,0x24,0x28});
    nativeReadoutReturn = static_cast<std::byte*>(image) + 0x064e57ad;
    auto& readoutSlot = field<void*>(image, EvaluatorVtable + EvaluatorReadoutSlot);
    auto& tickSlot = field<void*>(image, EvaluatorVtable + EvaluatorTickSlot);
    if (!originalTick || !originalReadout || !makeWeak || !resolveWeak || !findSession || !readoutEntry || !queryCall
        || readoutSlot != reinterpret_cast<void*>(originalReadout) || tickSlot != reinterpret_cast<void*>(originalTick)) {
        return false;
    }
    // UE4SS can reload Lua, so retain the module while the two native slots
    // may call it. An empty registry makes both callbacks pass through.
    HMODULE pinned;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                           reinterpret_cast<LPCWSTR>(&tickPressure), &pinned)) return false;
    DWORD oldProtection;
    if (!VirtualProtect(&readoutSlot, 2 * sizeof(void*), PAGE_READWRITE, &oldProtection)) return false;
    aiQueryReturn = queryCall + 5;
    gameThread = GetCurrentThreadId();
    InterlockedExchangePointer(&readoutSlot, reinterpret_cast<void*>(readPressure));
    InterlockedExchangePointer(&tickSlot, reinterpret_cast<void*>(tickPressure));
    DWORD discarded;
    VirtualProtect(&readoutSlot, 2 * sizeof(void*), oldProtection, &discarded);
    return true;
}

std::int64_t bindActor(void* subsystem, void* boss, PressureRule rule, bool observe) {
    if (!subsystem || !boss || !installPressure()) return -1;
    WeakObject world{}, key{};
    makeWeak(&world, &subsystem);
    makeWeak(&key, &boss);
    if (resolveWeak(&world) != subsystem || resolveWeak(&key) != boss) return -2;
    auto* session = sessionFor(subsystem, key);
    if (!session) return 0;
    auto* evaluator = evaluatorFor(session);
    if (!evaluator) return -3;
    void* image = GetModuleHandleW(nullptr);
    auto* vtable = static_cast<std::byte*>(image) + EvaluatorVtable;
    if (field<void*>(evaluator, 0) != vtable) return -3;
    auto* profile = field<void*>(session, SessionProfile);
    if (!ownsEvaluator(subsystem, profile, evaluator)) return -5;
    const auto& shadows = field<EvaluatorArray>(profile, ProfileShadows);
    for (int index = 0; index < shadows.size; ++index) {
        auto* shadow = shadows.data[index];
        if (shadow && (field<void*>(shadow, 0) != vtable || !ownsEvaluator(subsystem, profile, shadow))) return -5;
    }

    Binding* available = nullptr;
    for (auto& binding : bindings) {
        if (binding.token && binding.bossKey == key && binding.worldKey == world) {
            available = &binding;
            break;
        }
        if (!available && (!binding.token || !resolveWeak(&binding.bossKey) || !resolveWeak(&binding.worldKey))) {
            available = &binding;
        }
    }
    if (!available) return -4;
    if (!available->token) ++bindingCount;
    *available = {nextToken++, subsystem, world, key, rule, observe, 0, 0, 0, 0};
    applyToSession(*available, evaluator, field<float>(session, SessionRaw), false);
    return available->token;
}

int dispatch(lua_State* lua) {
    const auto command = luaToInteger(lua, 1, nullptr);
    if (command == LuaBridgeProbe) {
        int isInteger = 0;
        const auto cookie = luaToInteger(lua, 2, &isInteger);
        if (!isInteger) return 0;
        luaPushInteger(lua, cookie);
        luaPushNumber(lua, -13.25);
        return 2;
    }
    if (command == 4) {
        luaPushInteger(lua, installPressure() ? 1 : 0);
        return 1;
    }
    if (command == 1 || command == 5) {
        auto* subsystem = reinterpret_cast<void*>(luaToInteger(lua, 2, nullptr));
        auto* actor = reinterpret_cast<void*>(luaToInteger(lua, 3, nullptr));
        int isInteger = 0;
        const auto value = luaToInteger(lua, 4, &isInteger);
        const auto mode = command == 5 ? luaToInteger(lua, 6, nullptr) : 0;
        const bool valid = isInteger && (command == 1 ? value >= 41 && value <= 101
            : value >= -100 && value <= 100 && (mode == 1 || mode == 2));
        const auto rule = mode == 0 ? PressureMode::Floor : mode == 1 ? PressureMode::Fixed : PressureMode::Minimum;
        luaPushInteger(lua, valid ? bindActor(subsystem, actor, {rule, static_cast<int>(value)},
            luaToInteger(lua, 5, nullptr) == 1) : -1);
        return 1;
    }
    if (!isGameThread()) return 0;
    auto token = luaToInteger(lua, 2, nullptr);
    if (!token) return 0;
    for (auto& binding : bindings) {
        if (binding.token != token) continue;
        if (command == 2) {
            binding = {};
            --bindingCount;
            return 0;
        }
        if (command != 3 || !resolveWeak(&binding.bossKey) || !resolveWeak(&binding.worldKey)) return 0;
        auto* session = sessionFor(binding.subsystem, binding.bossKey);
        auto* evaluator = session ? evaluatorFor(session) : nullptr;
        if (!evaluator || !ownsEvaluator(binding.subsystem, field<void*>(session, SessionProfile), evaluator)) return 0;
        const float effective = applyPressure(field<float>(evaluator, EvaluatorRaw), binding.rule);
        luaPushNumber(lua, binding.nativeRaw);
        luaPushNumber(lua, effective);
        luaPushInteger(lua, tierFor(effective));
        luaPushNumber(lua, field<float>(evaluator, EvaluatorConfidence));
        luaPushInteger(lua, binding.updates);
        luaPushInteger(lua, binding.readouts);
        luaPushInteger(lua, binding.aiQueries);
        return 7;
    }
    return 0;
}
} // namespace

extern "C" __declspec(dllexport) int PBZPressureDispatch(lua_State* lua) {
    static const bool available = bindLua();
    return available ? dispatch(lua) : 0;
}
