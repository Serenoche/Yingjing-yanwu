#include "patch_transaction.hpp"
#include "target_specs.hpp"
#include "near_relay.hpp"
#include "engine_clone.hpp"
#include "summary_cache.hpp"
#include "provider_identity.hpp"
#include "native_binding_profiles.hpp"
#include <mutex>

#if !defined(_WIN64)
#error The disposable PBZ save barrier requires Windows x64.
#endif

namespace {
HMODULE module_handle = nullptr;
std::mutex operation_mutex;
bool armed = false;
bool prepared = false;
bool master_restored = false;
std::vector<pbz_barrier::Patch> installed;
void* protected_manager = nullptr;
void* json_relay = nullptr;
using NativeFree = void (__fastcall*)(void*);
using NativeLoadAdvanced = void (__fastcall*)(void*);
NativeFree native_free = nullptr;
NativeLoadAdvanced load_advanced = nullptr;
pbz_barrier::EngineClone clone_engine;
pbz_barrier::RemoveSummary remove_summary = nullptr;
pbz_barrier::SharedJson original_master;
struct Scalar { std::size_t offset; std::size_t length; unsigned char bytes[8]; };
std::vector<Scalar> saved_scalars;
pbz_compat::VerifiedIdentity verified_native_identity;
const pbz_bindings::Profile* active_profile=nullptr;

bool read_native_image(std::uintptr_t address,void* output,std::size_t length) {
    return pbz_barrier::read_bytes(reinterpret_cast<const void*>(address),output,length);
}
bool query_native_image(std::uintptr_t address,pbz_compat::Region& output) {
    MEMORY_BASIC_INFORMATION region{};
    if(VirtualQuery(reinterpret_cast<const void*>(address),&region,sizeof(region))!=sizeof(region))return false;
    output={reinterpret_cast<std::uintptr_t>(region.BaseAddress),region.RegionSize,
        reinterpret_cast<std::uintptr_t>(region.AllocationBase),region.State,region.Type,region.Protect};
    return true;
}

void* __fastcall json_failure(void* manager, unsigned char* result, void* save_parameter, void*) {
    if (result) *result = 1; // ESaveLoadResultType::Failed.
    if (manager) *(static_cast<unsigned char*>(manager) + 0x558) = 0;
    if (save_parameter) {
        auto string = static_cast<unsigned char*>(save_parameter) + 0x78;
        void* allocation = nullptr;
        std::memcpy(&allocation, string, sizeof(allocation));
        if (allocation) native_free(allocation);
        std::memset(string, 0, 16); // Destroy the owned FString exactly once.
    }
    return result;
}

std::wstring module_path() {
    std::vector<wchar_t> buffer(32768);
    const DWORD length = GetModuleFileNameW(module_handle, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (!length || length >= buffer.size()) return {};
    return std::wstring(buffer.data(), length);
}

bool read_request(const std::wstring& path, std::string& nonce, void*& manager) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER size{};
    BY_HANDLE_FILE_INFORMATION information{};
    bool ok = GetFileSizeEx(file, &size) && size.QuadPart > 0 && size.QuadPart <= 113
        && GetFileInformationByHandle(file, &information)
        && !(information.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT);
    char bytes[113]{};
    DWORD amount = 0;
    if (ok) ok = ReadFile(file, bytes, static_cast<DWORD>(size.QuadPart), &amount, nullptr)
        && amount == size.QuadPart;
    CloseHandle(file);
    if (!ok) return false;
    const std::string request(bytes, amount);
    const auto separator = request.find('\t');
    if (separator == std::string::npos || separator == 0 || separator > 96) return false;
    nonce = request.substr(0, separator);
    for (const unsigned char value : nonce) {
        if (!((value >= 'A' && value <= 'Z') || (value >= 'a' && value <= 'z')
            || (value >= '0' && value <= '9') || value == '_' || value == '-')) return false;
    }
    const auto address_text = request.substr(separator + 1);
    if (address_text.empty() || address_text.size() > 16) return false;
    std::uintptr_t address = 0;
    for (const unsigned char value : address_text) {
        unsigned int digit = 0;
        if (value >= '0' && value <= '9') digit = value - '0';
        else if (value >= 'a' && value <= 'f') digit = value - 'a' + 10;
        else if (value >= 'A' && value <= 'F') digit = value - 'A' + 10;
        else return false;
        address = address * 16 + digit;
    }
    if (address < 0x10000 || address > 0x00007FFFFFFFFFFF || address % 8 != 0) return false;
    manager = reinterpret_cast<void*>(address);
    return true;
}

bool write_status(const std::wstring& path, const std::string& bytes) {
    const std::wstring temporary = path + L".tmp-" + std::to_wstring(GetCurrentProcessId())
        + L"-" + std::to_wstring(GetCurrentThreadId());
    HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
        FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    DWORD amount = 0;
    const bool wrote = WriteFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &amount, nullptr)
        && amount == bytes.size() && FlushFileBuffers(file);
    CloseHandle(file);
    const bool moved = wrote && MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
    if (!moved) DeleteFileW(temporary.c_str());
    return moved;
}

template <typename Type> bool read_memory(const void* pointer, Type& output) {
    SIZE_T amount = 0;
    return ReadProcessMemory(GetCurrentProcess(), pointer, &output, sizeof(output), &amount)
        && amount == sizeof(output);
}

bool manager_memory_valid(void* manager, std::string& reason) {
    MEMORY_BASIC_INFORMATION region{};
    const auto start = reinterpret_cast<std::uintptr_t>(manager);
    if (VirtualQuery(manager, &region, sizeof(region)) != sizeof(region) || region.State != MEM_COMMIT
        || (region.Protect & (PAGE_GUARD | PAGE_NOACCESS))
        || start + 0x660 > reinterpret_cast<std::uintptr_t>(region.BaseAddress) + region.RegionSize) {
        reason = "manager memory is not readable"; return false;
    }
    const DWORD protection = region.Protect & 0xFF;
    if (protection != PAGE_READWRITE && protection != PAGE_WRITECOPY
        && protection != PAGE_EXECUTE_READWRITE && protection != PAGE_EXECUTE_WRITECOPY) {
        reason = "manager memory is not writable"; return false;
    }
    void** vtable = nullptr;
    void* first_function = nullptr;
    if (!read_memory(manager, vtable) || !read_memory(vtable, first_function)
        || !pbz_barrier::readable_executable(first_function)) {
        reason = "manager vtable is invalid"; return false;
    }
    return true;
}

bool manager_ready(void* manager, std::string& reason, bool& busy, bool for_arm) {
    busy = false;
    if (!manager_memory_valid(manager, reason)) return false;
    const std::size_t flags[] = {0x220, 0x238, 0x278, 0x279, 0x450, 0x558, 0x592};
    for (const auto offset : flags) {
        unsigned char value = 0;
        if (!read_memory(static_cast<unsigned char*>(manager) + offset, value)) {
            reason = "manager flag is unreadable"; return false;
        }
        if (value != 0) busy = true;
    }
    if (for_arm) {
        const std::size_t dirty_flags[] = {0x1B0, 0x208};
        for (const auto offset : dirty_flags) {
            unsigned char dirty = 0;
            if (!read_memory(static_cast<unsigned char*>(manager) + offset, dirty)) {
                reason = "native dirty flags are unreadable"; return false;
            }
            if (dirty != 0) busy = true;
        }
        std::uint64_t suspension = 0;
        std::uint32_t suspension_kind = 0;
        if (!read_memory(static_cast<unsigned char*>(manager) + 0x650, suspension)
            || !read_memory(static_cast<unsigned char*>(manager) + 0x658, suspension_kind)) {
            reason = "native suspension state is unreadable"; return false;
        }
        if (suspension || suspension_kind) busy = true;
    }
    unsigned char summary_ready = 0;
    if (!read_memory(static_cast<unsigned char*>(manager) + 0x3A0, summary_ready)) {
        reason = "summary cache state is unreadable"; return false;
    }
    if (summary_ready != 1) busy = true;
    const std::size_t arrays[] = {0x510, 0x560};
    for (const auto offset : arrays) {
        std::int32_t number = 0, capacity = 0;
        if (!read_memory(static_cast<unsigned char*>(manager) + offset + 8, number)
            || !read_memory(static_cast<unsigned char*>(manager) + offset + 12, capacity)
            || number < 0 || capacity < number || capacity > 65536) {
            reason = "manager callback array is invalid"; return false;
        }
        if (number != 0) busy = true;
    }
    if (busy) { reason = "native save queue is busy"; return false; }
    return true;
}

bool capture_scalars(void* manager, std::string& reason) {
    std::vector<Scalar> snapshot = {{0x1A8,8,{}}, {0x1B0,1,{}}, {0x208,1,{}}, {0x210,8,{}}, {0x218,8,{}},
        {0x220,1,{}}, {0x228,8,{}}, {0x230,8,{}}, {0x238,1,{}}, {0x2A4,8,{}},
        {0x3A1,1,{}}, {0x3A2,1,{}}, {0x438,1,{}}, {0x558,1,{}}, {0x591,1,{}},
        // The native failed-write path retains a double retry deadline and
        // retry count after its queue drains. They belong to this transaction,
        // just like its generation/force state; restore the entry snapshot only
        // at the existing quiescent Disarm boundary, never clear live queues.
        {0x650,8,{}}, {0x658,4,{}}};
    for (auto& scalar : snapshot) {
        SIZE_T amount = 0;
        if (!ReadProcessMemory(GetCurrentProcess(), static_cast<unsigned char*>(manager) + scalar.offset,
            scalar.bytes, scalar.length, &amount) || amount != scalar.length) {
            reason = "cannot snapshot native save counters"; return false;
        }
    }
    saved_scalars = std::move(snapshot);
    return true;
}

bool host_identity(unsigned char*& base, std::string& reason) {
    base = reinterpret_cast<unsigned char*>(GetModuleHandleW(nullptr));
    wchar_t executable[32768]{};
    const DWORD length = GetModuleFileNameW(nullptr, executable, 32768);
    if (!base || !length || length >= 32768) { reason = "executable identity unavailable"; return false; }
    const std::wstring path(executable, length);
    const auto split = path.find_last_of(L"\\/");
    if (_wcsicmp(path.c_str() + (split == std::wstring::npos ? 0 : split + 1), L"PBZ.exe") != 0) {
        reason = "pinned PBZ executable name mismatch"; return false;
    }
    pbz_compat::Image image;
    if(!pbz_compat::image_headers(reinterpret_cast<std::uintptr_t>(base),read_native_image,image)) {
        reason="native-runtime-incompatible:PEImage";return false;
    }
    // Inspect also reads provider state and can acquire its initialized cache
    // lock. Verify the real interface set before either Inspect or Arm does so.
    // Only our already-armed transaction may reuse this proof: its own three
    // entry patches would otherwise fail the original-byte digest comparison.
    return pbz_bindings::select(image,active_profile,verified_native_identity,armed,
        [&](){return pbz_barrier::preflight(pbz_barrier::reversed(installed),reason);},
        read_native_image,query_native_image,reason);
}

#if !defined(PBZ_BARRIER_OFFLINE_TEST)
bool host_targets(std::vector<pbz_barrier::Patch>& patches, std::string& reason) {
    unsigned char* base = nullptr;
    if (!host_identity(base, reason)) return false;
    const auto& profile=*active_profile;
    std::size_t target_index=0;
    for (const auto& spec : pbz_barrier::targets) {
        const auto rva=target_index++==0 ? profile.sync_rva : profile.write_rva;
        void* address = base + rva;
        MEMORY_BASIC_INFORMATION region{};
        if (verified_native_identity.size < 8 || rva > verified_native_identity.size - 8
            || VirtualQuery(address, &region, sizeof(region)) != sizeof(region)
            || region.Type != MEM_IMAGE || region.AllocationBase != base) {
            reason = std::string("target is outside the PBZ image: ") + spec.name; return false;
        }
        patches.push_back({spec.name, address, pbz_barrier::word(spec.original), pbz_barrier::word(spec.replacement)});
    }
    constexpr unsigned char free_prolog[8] = {0x48,0x85,0xC9,0x74,0x2E,0x53,0x48,0x83};
    constexpr unsigned char advanced_prolog[8] = {0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x6C};
    std::uint64_t current = 0;
    if (!pbz_barrier::read_word(base + profile.free_rva, current) || current != pbz_barrier::word(free_prolog)
        || !pbz_barrier::read_word(base + profile.advanced_rva, current) || current != pbz_barrier::word(advanced_prolog)) {
        reason = "native resource cleanup prolog mismatch"; return false;
    }
    native_free = reinterpret_cast<NativeFree>(base + profile.free_rva);
    load_advanced = reinterpret_cast<NativeLoadAdvanced>(base + profile.advanced_rva);
    constexpr unsigned char constructor_prolog[32] = {0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x6C,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x48,
        0x89,0x7C,0x24,0x20,0x41,0x56,0x48,0x83,0xEC,0x30,0x33,0xED,0x48,0x8D,0x79,0x10};
    constexpr unsigned char copy_prolog[32] = {0x48,0x8B,0xC4,0x48,0x89,0x48,0x08,0x55,0x56,0x41,0x54,0x41,0x57,0x48,0x8D,0x68,
        0xA1,0x48,0x81,0xEC,0xF8,0x00,0x00,0x00,0x4D,0x8B,0x20,0x4C,0x8B,0xFA,0x48,0x8B};
    constexpr unsigned char release_prolog[32] = {0x48,0x85,0xC9,0x74,0x42,0x53,0x48,0x83,0xEC,0x20,0x48,0x89,0x7C,0x24,0x30,0x48,
        0x8B,0xD9,0xBF,0xFF,0xFF,0xFF,0xFF,0x8B,0xC7,0xF0,0x0F,0xC1,0x41,0x08,0x83,0xF8};
    constexpr unsigned char remove_prolog[32] = {0x41,0x56,0x41,0x57,0x48,0x83,0xEC,0x28,0x8B,0x41,0x08,0x4C,0x8B,0xFA,0x4C,0x8B,
        0xF1,0x3B,0x41,0x34,0x0F,0x84,0x38,0x01,0x00,0x00,0x8B,0x42,0x08,0x48,0x89,0x5C};
    struct Fingerprint { std::uint32_t rva; const unsigned char* bytes; };
    const Fingerprint fingerprints[] = {{profile.constructor_rva,constructor_prolog}, {profile.copy_rva,copy_prolog},
        {profile.release_rva,release_prolog}, {profile.remove_rva,remove_prolog}};
    for (const auto& fingerprint : fingerprints) {
        if(!fingerprint.rva)continue; // Legacy initializes an empty wrapper via its admitted JSON parser.
        unsigned char bytes[32]{};
        SIZE_T amount = 0;
        if (!ReadProcessMemory(GetCurrentProcess(), base + fingerprint.rva, bytes, sizeof(bytes), &amount)
            || amount != sizeof(bytes) || std::memcmp(bytes, fingerprint.bytes, sizeof(bytes)) != 0) {
            reason = "native master clone prolog mismatch"; return false;
        }
    }
    clone_engine.construct = profile.constructor_rva
        ? reinterpret_cast<pbz_barrier::WrapperConstructor>(base + profile.constructor_rva) : nullptr;
    clone_engine.initialize_json = profile.parser_rva
        ? reinterpret_cast<pbz_barrier::JsonParser>(base + profile.parser_rva) : nullptr;
    clone_engine.deep_copy = reinterpret_cast<pbz_barrier::CopyJson>(base + profile.copy_rva);
    clone_engine.release = reinterpret_cast<pbz_barrier::ReleaseShared>(base + profile.release_rva);
    remove_summary = reinterpret_cast<pbz_barrier::RemoveSummary>(base + profile.remove_rva);
    std::string allocation_failure;
    if (!json_relay) json_relay = pbz_barrier::allocate_near_relay(base + profile.json_rva,
        reinterpret_cast<void*>(&json_failure), nullptr, &allocation_failure);
    std::uint64_t jump = 0;
    if (!json_relay || !pbz_barrier::relay_jump(base + profile.json_rva, json_relay, jump)) {
        reason = "cannot prepare native JSON failure relay: " + allocation_failure; return false;
    }
    patches.push_back({"JsonSaveToDisk", base + profile.json_rva, pbz_barrier::word(pbz_barrier::json_original), jump});
    return true;
}
#endif

struct EntryState { pbz_barrier::Patch patch; DWORD protection; };
std::vector<EntryState> last_entry_states;
bool capture_entry_states(const std::vector<pbz_barrier::Patch>& patches, std::vector<EntryState>& states,
    std::string& reason) {
    if (!pbz_barrier::preflight(patches, reason)) return false;
    std::vector<EntryState> captured;
    for (const auto& patch : patches) {
        MEMORY_BASIC_INFORMATION memory{};
        if (VirtualQuery(patch.address, &memory, sizeof(memory)) != sizeof(memory)) {
            reason = "cannot capture native entry protection"; return false;
        }
        captured.push_back({patch,memory.Protect});
    }
    states = std::move(captured);
    return true;
}

bool confirm_entries_unchanged(const std::vector<EntryState>& states) {
    for (const auto& state : states) {
        std::uint64_t bytes = 0;
        MEMORY_BASIC_INFORMATION memory{};
        if (!pbz_barrier::read_word(state.patch.address, bytes) || bytes != state.patch.expected
            || VirtualQuery(state.patch.address, &memory, sizeof(memory)) != sizeof(memory)
            || memory.Protect != state.protection
            || !FlushInstructionCache(GetCurrentProcess(), state.patch.address, 8)) return false;
    }
    return true;
}

enum class Operation { arm, prepare, disarm };
int operation(Operation action) {
    std::lock_guard<std::mutex> lock(operation_mutex);
    const auto path = module_path();
    if (path.empty()) return 0;
    std::string nonce;
    void* manager = nullptr;
    if (!read_request(path + L".request", nonce, manager)) {
        write_status(path + L".status", "invalid\terror\tinvalid request nonce or manager address\n");
        return 0;
    }
    std::string reason;
    bool ok = false;
    bool busy = false;
    bool refused = action == Operation::arm && !armed;
    if (action == Operation::arm) {
        if (armed) {
            ok = manager == protected_manager && pbz_barrier::preflight(pbz_barrier::reversed(installed), reason);
            if (!ok && reason.empty()) reason = "protected manager identity mismatch";
        } else {
            std::vector<pbz_barrier::Patch> candidates;
            std::vector<EntryState> initial_entries;
            ok = host_targets(candidates, reason) && manager_ready(manager, reason, busy, true)
                && capture_scalars(manager, reason) && capture_entry_states(candidates, initial_entries, reason);
            if (ok) last_entry_states = initial_entries;
            HMODULE pinned_module = nullptr;
            if (ok && !GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                reinterpret_cast<LPCWSTR>(&json_failure), &pinned_module)) {
                ok = false; reason = "cannot pin native barrier lifetime";
            }
            if (ok) {
                refused = false; // Mutation is possible from this point onward.
                ok = pbz_barrier::transact(candidates, reason);
                if (!ok) refused = confirm_entries_unchanged(initial_entries);
            }
            if (ok) {
                const auto master = reinterpret_cast<pbz_barrier::SharedJson*>(static_cast<unsigned char*>(manager) + 0xD8);
                pbz_barrier::SharedJson private_master;
                ok = clone_engine.clone(manager, *master, private_master, reason);
                if (ok) {
                    original_master = *master; // Move the original owner out of the subsystem.
                    *master = private_master; // Move the clone owner into the subsystem.
                    installed = std::move(candidates); protected_manager = manager;
                    armed = true; prepared = false; master_restored = false;
                } else {
                    std::string rollback_reason;
                    const bool restored = pbz_barrier::transact(pbz_barrier::reversed(candidates), rollback_reason);
                    refused = restored && confirm_entries_unchanged(initial_entries);
                    if (!restored)
                        reason += "; native patch rollback failed: " + rollback_reason;
                }
            }
        }
    } else if (!armed && action == Operation::disarm) {
        ok = true;
    } else {
        ok = armed && manager == protected_manager && manager_ready(manager, reason, busy, false);
        if (!ok && reason.empty()) reason = "protected manager identity mismatch";
        if (ok && action == Operation::prepare && !prepared) {
            auto cache = static_cast<unsigned char*>(manager) + 0x350;
            std::vector<std::wstring> keys;
            ok = pbz_barrier::collect_summary_keys(cache, keys, reason);
            if (ok) {
                if (!master_restored) {
                    const auto master = reinterpret_cast<pbz_barrier::SharedJson*>(static_cast<unsigned char*>(manager) + 0xD8);
                    auto private_master = *master;
                    *master = original_master; original_master = {};
                    master_restored = true; // Retrying cannot overwrite the restored owner with an empty one.
                    clone_engine.drop(private_master);
                    load_advanced(manager);
                }
                ok = pbz_barrier::remove_summary_keys(cache, keys, remove_summary, reason);
                if (ok) prepared = true;
            }
        } else if (ok && action == Operation::disarm) {
            if (!prepared) { reason = "PrepareRestore is required before Disarm"; ok = false; }
            else {
                for (const auto& scalar : saved_scalars)
                    std::memcpy(static_cast<unsigned char*>(manager) + scalar.offset, scalar.bytes, scalar.length);
                ok = pbz_barrier::transact(pbz_barrier::reversed(installed), reason);
                if (ok && !confirm_entries_unchanged(last_entry_states)) {
                    ok = false; reason = "native entries or protections differ after Disarm";
                }
                if (ok) { armed = false; prepared = false; master_restored = false;
                    installed.clear(); protected_manager = nullptr; saved_scalars.clear(); }
            }
        }
    }
    if (ok) write_status(path + L".status", nonce + (prepared ? "\tprepared\n" : armed ? "\tarmed\n" : "\tidle\n"));
    else if (busy) write_status(path + L".status", nonce + "\tbusy\n");
    else if (refused) write_status(path + L".status", nonce + "\trefused\t" + reason + "\n");
    else write_status(path + L".status", nonce + "\terror\t" + reason + "\n");
    return 0;
}

std::string hex_word(std::uint64_t value) {
    constexpr char digits[] = "0123456789ABCDEF";
    std::string text(16,'0');
    for (std::size_t index = 0; index < 16; ++index) {
        text[15-index] = digits[value & 15]; value >>= 4;
    }
    return text;
}

template <typename Type> void inspect_field(void* manager, std::size_t offset, const char* label, std::string& output) {
    Type value{};
    output += std::string(";") + label + "=";
    if (!read_memory(static_cast<unsigned char*>(manager)+offset,value)) output += "unreadable";
    else output += std::to_string(value);
}

bool inspect_vetoes(void* manager, std::string& output) {
    auto map = static_cast<unsigned char*>(manager)+0x3E8;
    void* data = nullptr; std::uint32_t* heap_bits = nullptr;
    std::int32_t number = 0, capacity = 0, free_number = 0, number_bits = 0;
    if (!read_memory(map,data) || !read_memory(map+8,number) || !read_memory(map+12,capacity)
        || !read_memory(map+0x20,heap_bits) || !read_memory(map+0x28,number_bits) || !read_memory(map+0x34,free_number)
        || number < 0 || number > 4096 || capacity < number || capacity > 4096
        || free_number < 0 || free_number > number || number_bits < number || number_bits > 4096
        || (!heap_bits && number_bits > 128) || (number && !data)) return false;
    std::vector<std::uint32_t> bits((static_cast<std::size_t>(number_bits)+31)/32);
    if (!pbz_barrier::read_bytes(heap_bits ? static_cast<void*>(heap_bits) : map+0x10,
        bits.data(),bits.size()*sizeof(bits[0]))) return false;
    std::uint64_t counts[4]{};
    std::int32_t occupied = 0;
    std::string entries;
    for (std::int32_t index = 0; index < number; ++index) {
        if (!(bits[static_cast<std::size_t>(index)>>5] & (1u << (index & 31)))) continue;
        auto entry = static_cast<unsigned char*>(data)+static_cast<std::size_t>(index)*0x28;
        std::uint64_t key = 0; unsigned char reason = 0; std::int32_t references = 0;
        if (!read_memory(entry,key) || !read_memory(entry+8,reason) || !read_memory(entry+0x18,references)
            || references < 0 || references > 1048576) return false;
        counts[reason < 3 ? reason : 3] += static_cast<std::uint64_t>(references);
        if (occupied < 16) entries += (entries.empty() ? "" : ",") + hex_word(key)
            + ":" + std::to_string(reason) + ":" + std::to_string(references);
        ++occupied;
    }
    if (occupied != number-free_number) return false;
    output += ";vetoEntries=" + std::to_string(occupied) + ";vetoReason0=" + std::to_string(counts[0])
        + ";vetoReason1=" + std::to_string(counts[1]) + ";vetoReason2=" + std::to_string(counts[2])
        + ";vetoOther=" + std::to_string(counts[3]) + ";vetoKeys=" + entries;
    return true;
}

struct EligibilityApi {
    bool (__fastcall* can_save)(void*) = nullptr;
    void* (__fastcall* interface_class)() = nullptr;
    bool (__fastcall* implements)(void*,void*) = nullptr;
    bool (__fastcall* execute)(void*) = nullptr;
};

EligibilityApi eligibility_api(unsigned char* base) {
    if(!active_profile || !active_profile->reference_eligibility)return {};
    pbz_compat::Image image;std::string compatibility_reason;
    if(!pbz_compat::image_headers(reinterpret_cast<std::uintptr_t>(base),read_native_image,image)
        || !pbz_compat::verify(image,pbz_compat_profile::eligibility,std::size(pbz_compat_profile::eligibility),
            nullptr,0,read_native_image,query_native_image,compatibility_reason))return {};
    constexpr unsigned char gate[32] = {0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x48,0x89,0x7C,0x24,0x18,0x4C,
        0x89,0x64,0x24,0x20,0x55,0x41,0x56,0x41,0x57,0x48,0x8D,0x6C,0x24,0xB9,0x48,0x81};
    constexpr unsigned char execute[32] = {0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x15,0x73,0x1C,0xAC,0x07,0x48,0x8B,0xD9,
        0xC6,0x44,0x24,0x38,0x00,0xE8,0x26,0x57,0x06,0xFB,0x48,0x85,0xC0,0x74,0x23,0x48};
    constexpr unsigned char getter[32] = {0x4C,0x8B,0xDC,0x48,0x83,0xEC,0x78,0x48,0x8B,0x05,0xFA,0x30,0xAC,0x07,0x48,0x85,
        0xC0,0x0F,0x85,0x92,0x00,0x00,0x00,0x48,0x8D,0x05,0xB2,0x1A,0xC9,0xFA,0x49,0x89};
    constexpr unsigned char implements[32] = {0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0xFA,0x48,0x8B,0xD9,
        0x48,0x85,0xD2,0x74,0x63,0xF7,0x82,0x24,0x01,0x00,0x00,0x00,0x40,0x00,0x00,0x74};
    struct Check { std::uint32_t rva; const unsigned char* bytes; };
    const Check checks[] = {{0x06B5D750,gate},{0x065C9E60,execute},{0x065C8910,getter},{0x0153C140,implements}};
    for (const auto& check : checks) {
        unsigned char current[32]{};
        if (!pbz_barrier::read_bytes(base+check.rva,current,sizeof(current))
            || std::memcmp(current,check.bytes,sizeof(current)) != 0) return {};
    }
    return {reinterpret_cast<bool (__fastcall*)(void*)>(base+0x06B5D750),
        reinterpret_cast<void* (__fastcall*)()>(base+0x065C8910),
        reinterpret_cast<bool (__fastcall*)(void*,void*)>(base+0x0153C140),
        reinterpret_cast<bool (__fastcall*)(void*)>(base+0x065C9E60)};
}

bool inspect_registry(void* manager, std::string& output, const EligibilityApi* eligibility = nullptr) {
    auto map = static_cast<unsigned char*>(manager)+0x2B0;
    void* data = nullptr; std::uint32_t* heap_bits = nullptr;
    std::int32_t number = 0, capacity = 0, free_number = 0, number_bits = 0;
    if (!read_memory(map,data) || !read_memory(map+8,number) || !read_memory(map+12,capacity)
        || !read_memory(map+0x20,heap_bits) || !read_memory(map+0x28,number_bits) || !read_memory(map+0x34,free_number)
        || number < 0 || number > 65536 || capacity < number || capacity > 65536
        || free_number < 0 || free_number > number || number_bits < number || number_bits > 65536
        || (!heap_bits && number_bits > 128) || (number && !data)) return false;
    std::vector<std::uint32_t> bits((static_cast<std::size_t>(number_bits)+31)/32);
    if (!pbz_barrier::read_bytes(heap_bits ? static_cast<void*>(heap_bits) : map+0x10,
        bits.data(),bits.size()*sizeof(bits[0]))) return false;
    std::int32_t occupied = 0;
    std::int32_t checked = 0, blocked = 0, invalid = 0;
    std::string entries;
    std::string blocked_entries;
    void* interface_class = eligibility ? eligibility->interface_class() : nullptr;
    for (std::int32_t index = 0; index < number; ++index) {
        if (!(bits[static_cast<std::size_t>(index)>>5] & (1u << (index & 31)))) continue;
        auto entry = static_cast<unsigned char*>(data)+static_cast<std::size_t>(index)*0x18;
        std::uint64_t key = 0, object = 0;
        if (!read_memory(entry,key) || !read_memory(entry+8,object)) return false;
        if (occupied < 16) entries += (entries.empty() ? "" : ",") + hex_word(key) + ":" + hex_word(object);
        if (eligibility && interface_class && object) {
            void* object_class = nullptr;
            if (!read_memory(reinterpret_cast<unsigned char*>(object)+0x10,object_class) || !object_class) ++invalid;
            else if (eligibility->implements(object_class,interface_class)) {
                ++checked;
                if (!eligibility->execute(reinterpret_cast<void*>(object))) {
                    if (blocked < 16) blocked_entries += (blocked_entries.empty() ? "" : ",")
                        + hex_word(key) + ":" + hex_word(object);
                    ++blocked;
                }
            }
        }
        ++occupied;
    }
    if (occupied != number-free_number) return false;
    output += ";savableEntries=" + std::to_string(occupied) + ";savableKeys=" + entries;
    if (eligibility) output += ";savableChecked=" + std::to_string(checked) + ";savableBlocked=" + std::to_string(blocked)
        + ";savableInvalid=" + std::to_string(invalid) + ";savableBlockedKeys=" + blocked_entries;
    return true;
}

std::string inspect_manager(void* manager, unsigned char* base, bool include_eligibility = false) {
    std::string output = std::string("armed=") + (armed ? "1" : "0")
        + ";prepared=" + (prepared ? "1" : "0") + ";masterRestored=" + (master_restored ? "1" : "0");
    const auto& profile=active_profile ? *active_profile : pbz_bindings::reference;
    output += std::string(";nativeProfile=")+profile.id;
    bool original = true;
    std::size_t target_index=0;
    for (const auto& spec : pbz_barrier::targets) {
        const auto rva=target_index++==0 ? profile.sync_rva : profile.write_rva;
        std::uint64_t bytes = 0;
        const bool readable = pbz_barrier::read_word(base+rva,bytes);
        original = original && readable && bytes == pbz_barrier::word(spec.original);
        output += std::string(";") + spec.name + "=" + (readable ? hex_word(bytes) : "unreadable");
    }
    std::uint64_t json_bytes = 0;
    const bool json_readable = pbz_barrier::read_word(base+profile.json_rva,json_bytes);
    original = original && json_readable && json_bytes == pbz_barrier::word(pbz_barrier::json_original);
    output += ";JsonSave=" + (json_readable ? hex_word(json_bytes) : "unreadable")
        + ";entriesOriginal=" + (original ? "1" : "0");
    int protection_match = last_entry_states.empty() ? -1 : 1;
    for (const auto& state : last_entry_states) {
        MEMORY_BASIC_INFORMATION memory{};
        if (VirtualQuery(state.patch.address,&memory,sizeof(memory)) != sizeof(memory)
            || memory.Protect != state.protection) protection_match = 0;
    }
    output += ";protectionsOriginal=" + std::to_string(protection_match);
    inspect_field<std::uint64_t>(manager,0x1A8,"masterGeneration",output);
    inspect_field<unsigned char>(manager,0x1B0,"currentDirty",output);
    inspect_field<unsigned char>(manager,0x208,"advancedDirty",output);
    inspect_field<std::uint64_t>(manager,0x210,"currentGeneration",output);
    inspect_field<std::uint64_t>(manager,0x218,"currentInFlightGeneration",output);
    inspect_field<unsigned char>(manager,0x220,"currentWriteActive",output);
    inspect_field<std::uint64_t>(manager,0x228,"advancedGeneration",output);
    inspect_field<std::uint64_t>(manager,0x230,"advancedInFlightGeneration",output);
    inspect_field<unsigned char>(manager,0x238,"advancedWriteActive",output);
    inspect_field<unsigned char>(manager,0x278,"masterWriteRequested",output);
    inspect_field<unsigned char>(manager,0x279,"masterWriteWorking",output);
    inspect_field<unsigned char>(manager,0x27A,"rawU8_27A",output);
    inspect_field<std::uint64_t>(manager,0x2A4,"nextBellFName",output);
    inspect_field<unsigned char>(manager,0x3A0,"summaryReady",output);
    inspect_field<unsigned char>(manager,0x3A1,"nightmareCycleFlag",output);
    inspect_field<unsigned char>(manager,0x3A2,"endingReturnFlag",output);
    inspect_field<std::uint32_t>(manager,0x3D0,"rawU32_3D0",output);
    inspect_field<std::uint32_t>(manager,0x3D4,"callbackNesting",output);
    inspect_field<unsigned char>(manager,0x438,"retryFlag",output);
    inspect_field<unsigned char>(manager,0x450,"pendingSave",output);
    inspect_field<std::int32_t>(manager,0x518,"pendingCallbacks",output);
    inspect_field<unsigned char>(manager,0x558,"dispatchFlag",output);
    inspect_field<std::int32_t>(manager,0x568,"inFlightCallbacks",output);
    inspect_field<unsigned char>(manager,0x591,"forceFlag",output);
    inspect_field<unsigned char>(manager,0x592,"inFlightSemantic",output);
    inspect_field<std::uint64_t>(manager,0x650,"suspensionRaw",output);
    inspect_field<std::uint32_t>(manager,0x658,"suspensionKindRaw",output);
    std::string veto_output;
    output += inspect_vetoes(manager,veto_output) ? ";vetoRead=1" + veto_output : ";vetoRead=0";
    std::string registry_output;
    const auto eligibility = include_eligibility ? eligibility_api(base) : EligibilityApi{};
    output += std::string(";eligibilityRequested=") + (include_eligibility ? "1" : "0")
        + ";eligibilityProbe=" + (eligibility.can_save ? "1" : "0");
    if (eligibility.can_save) output += std::string(";nativeCanSave=") + (eligibility.can_save(manager) ? "1" : "0");
    unsigned char shutdown = 1;
    read_memory(static_cast<unsigned char*>(manager)+0x27A,shutdown);
    output += inspect_registry(manager,registry_output,eligibility.can_save && !shutdown ? &eligibility : nullptr)
        ? ";savableRead=1" + registry_output : ";savableRead=0";
    const auto provider=active_profile ? pbz_bindings::admitted_provider(profile,verified_native_identity.size)
        : pbz_provider::default_layout;
    output += pbz_provider::inspect(manager,base,provider);
    return output;
}

int inspect_operation(bool include_eligibility) {
    std::lock_guard<std::mutex> lock(operation_mutex);
    const auto path = module_path();
    if (path.empty()) return 0;
    std::string nonce; void* manager = nullptr;
    if (!read_request(path+L".request",nonce,manager)) {
        write_status(path+L".status","invalid\terror\tinvalid request nonce or manager address\n"); return 0;
    }
    unsigned char* base = nullptr; std::string reason;
    if (!host_identity(base,reason) || !manager_memory_valid(manager,reason)) {
        write_status(path+L".status",nonce+"\trefused\t"+reason+"\n"); return 0;
    }
    write_status(path+L".status",nonce+"\tinspect\t"+inspect_manager(manager,base,include_eligibility)+"\n");
    return 0;
}
} // namespace

// Lua C function ABI. No Lua APIs or UE4SS C++ ABI are imported; both exports
// take an opaque lua_State*, ignore it, and return zero Lua results.
extern "C" __declspec(dllexport) int __cdecl PBZBarrierArm(void*) { return operation(Operation::arm); }
extern "C" __declspec(dllexport) int __cdecl PBZBarrierPrepareRestore(void*) { return operation(Operation::prepare); }
extern "C" __declspec(dllexport) int __cdecl PBZBarrierDisarm(void*) { return operation(Operation::disarm); }
extern "C" __declspec(dllexport) int __cdecl PBZBarrierInspect(void*) { return inspect_operation(false); }
extern "C" __declspec(dllexport) int __cdecl PBZBarrierInspectEligibility(void*) { return inspect_operation(true); }

BOOL WINAPI DllMain(HINSTANCE handle, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) module_handle = handle;
    return TRUE;
}
