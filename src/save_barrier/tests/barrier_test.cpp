// Includes the actual implementation so ABI cleanup and request/state checks
// can be exercised without a PBZ process or engine addresses.
#include "patch_transaction.hpp"
// Replace only pinned-host discovery/engine dependencies. The real operation
// state machine, manager guards, scalar snapshots, executable transactions and
// restore/error paths below are compiled unchanged from the production file.
namespace { bool host_targets(std::vector<pbz_barrier::Patch>&, std::string&); }
#define PBZ_BARRIER_OFFLINE_TEST
#include "barrier.cpp"
#include <algorithm>
#include <cstdio>
#include <map>

namespace {
int checks = 0;
void check(bool condition, const char* label) {
    if (!condition) { std::fprintf(stderr, "FAIL %s\n", label); std::exit(1); }
    ++checks; std::printf("PASS %s\n", label);
}
bool reject_second(std::size_t index) { return index == 1; }
int fake_free_calls = 0;
void __fastcall fake_free(void* memory) { ++fake_free_calls; HeapFree(GetProcessHeap(), 0, memory); }
void* observed_arguments[4]{};
void* __fastcall observed_json_failure(void* manager, unsigned char* result, void* parameter, void* delegate) {
    observed_arguments[0] = manager; observed_arguments[1] = result;
    observed_arguments[2] = parameter; observed_arguments[3] = delegate;
    return json_failure(manager, result, parameter, delegate);
}
struct MockAddressSpace {
    std::vector<pbz_barrier::AddressRegion> regions;
    unsigned int failures = 0;
    bool query(std::uintptr_t address, pbz_barrier::AddressRegion& output, DWORD& error) const {
        for (const auto& region : regions) {
            if (address >= region.base && address - region.base < region.size) { output = region; return true; }
        }
        error = ERROR_INVALID_PARAMETER; return false;
    }
    bool reserve(std::uintptr_t address, std::uintptr_t size, DWORD& error) {
        if (failures) { --failures; error = ERROR_INVALID_ADDRESS; return false; }
        for (const auto& region : regions) {
            if (region.free && address >= region.base && size <= region.size
                && address - region.base <= region.size - size) return true;
        }
        error = ERROR_INVALID_ADDRESS; return false;
    }
};
std::uintptr_t search_mock(MockAddressSpace& space, std::uintptr_t source, pbz_barrier::RelayDiagnostics& diagnostics) {
    return pbz_barrier::reserve_relay_address(source, 0x10000, 0x00007FFFFFFF0000ULL, 4096, 65536,
        [&](std::uintptr_t address, pbz_barrier::AddressRegion& region, DWORD& error) { return space.query(address,region,error); },
        [&](std::uintptr_t address, std::uintptr_t size, DWORD& error) { return space.reserve(address,size,error); }, diagnostics);
}
struct FakeJson { std::map<std::string, std::vector<int>> fields; };
struct FakeControl { void* vtable; volatile LONG strong; LONG weak; FakeJson* object; };
int live_json = 0, releases = 0;
std::vector<pbz_barrier::Patch> offline_host_patches;
bool offline_constructor_fails = false, offline_remove_fails = false;
int offline_advanced_loads = 0;
std::vector<std::wstring> removed_keys;
struct FakeSavable { unsigned char prefix[0x10]{}; void* object_class = nullptr; bool permitted = false; };
int fake_interface_class = 0, fake_eligible_class = 0, fake_other_class = 0, eligibility_calls = 0;
bool __fastcall fake_can_save(void*) { return false; }
void* __fastcall fake_interface() { return &fake_interface_class; }
bool __fastcall fake_implements(void* klass, void* interface_class) {
    return klass == &fake_eligible_class && interface_class == &fake_interface_class;
}
bool __fastcall fake_execute(void* object) { ++eligibility_calls; return static_cast<FakeSavable*>(object)->permitted; }
std::int32_t __fastcall fake_remove_summary(void* map, const pbz_barrier::BorrowedString* key) {
    auto header = static_cast<unsigned char*>(map);
    unsigned char* data = nullptr; std::int32_t count = 0, free_count = 0;
    std::uint32_t* heap_bits = nullptr;
    std::memcpy(&data, header, 8); std::memcpy(&count, header + 8, 4);
    std::memcpy(&free_count, header + 0x34, 4); std::memcpy(&heap_bits, header + 0x20, 8);
    auto bits = heap_bits ? heap_bits : reinterpret_cast<std::uint32_t*>(header + 0x10);
    for (std::int32_t i = 0; i < count; ++i) {
        if (!(bits[i >> 5] & (1u << (i & 31)))) continue;
        pbz_barrier::BorrowedString stored{}; std::memcpy(&stored, data + i * 0xC0, sizeof(stored));
        if (stored.number == key->number && std::wmemcmp(stored.data, key->data, static_cast<std::size_t>(key->number)) == 0) {
            removed_keys.emplace_back(key->data, static_cast<std::size_t>(key->number) - 1);
            bits[i >> 5] &= ~(1u << (i & 31)); ++free_count;
            std::memcpy(header + 0x34, &free_count, 4);
            std::memset(data + i * 0xC0, 0, 0xC0); // Destroy the removed entry in place.
            return 1;
        }
    }
    return 0;
}
pbz_barrier::SharedJson make_fake() {
    auto object = new FakeJson;
    auto control = new FakeControl{nullptr,1,1,object};
    ++live_json;
    return {object,control};
}
void __fastcall fake_release(void* pointer) {
    auto control = static_cast<FakeControl*>(pointer);
    ++releases;
    if (InterlockedDecrement(&control->strong) == 0) {
        delete control->object; delete control; --live_json;
    }
}
void* __fastcall fake_construct(pbz_barrier::JsonWrapper* wrapper) {
    *wrapper = {};
    if (!offline_constructor_fails) wrapper->shared = make_fake();
    return wrapper;
}
void __fastcall fake_copy(void*, pbz_barrier::SharedJson* destination, const pbz_barrier::SharedJson* source) {
    *static_cast<FakeJson*>(destination->object) = *static_cast<FakeJson*>(source->object);
    fake_release(destination->controller); // Match the verified native consuming ABI.
}
void __fastcall offline_load_advanced(void* manager) {
    auto master = reinterpret_cast<pbz_barrier::SharedJson*>(static_cast<unsigned char*>(manager) + 0xD8);
    check(master->object && static_cast<FakeJson*>(master->object)->fields.count("formal") == 1,
        "actual Prepare loads Advanced only after restoring the original master");
    ++offline_advanced_loads;
}
std::int32_t __fastcall offline_remove_summary(void* map, const pbz_barrier::BorrowedString* key) {
    if (offline_remove_fails) return 0;
    return fake_remove_summary(map, key);
}
bool host_targets(std::vector<pbz_barrier::Patch>& patches, std::string&) {
    patches = offline_host_patches;
    native_free = fake_free;
    load_advanced = offline_load_advanced;
    clone_engine = {fake_construct, fake_copy, fake_release};
    remove_summary = offline_remove_summary;
    return true;
}
std::string run_operation(Operation action, void* manager) {
    static int nonce_number = 0;
    const auto path = module_path();
    const auto nonce = "offline_" + std::to_string(++nonce_number);
    char address[32]{};
    std::snprintf(address, sizeof(address), "%llX", static_cast<unsigned long long>(reinterpret_cast<std::uintptr_t>(manager)));
    check(write_status(path + L".request", nonce + "\t" + address), "write isolated operation request");
    operation(action);
    HANDLE file = CreateFileW((path + L".status").c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    check(file != INVALID_HANDLE_VALUE, "read actual operation status handshake");
    char result[1024]{}; DWORD amount = 0;
    const bool read = ReadFile(file, result, sizeof(result), &amount, nullptr) != FALSE;
    CloseHandle(file);
    check(read && amount > nonce.size() + 1, "actual operation status contains this request nonce");
    std::string status(result, amount);
    check(status.rfind(nonce + "\t", 0) == 0, "actual operation never reuses a stale acknowledgment");
    return status.substr(nonce.size() + 1);
}
} // namespace

int main() {
    using namespace pbz_barrier;
    auto memory = static_cast<unsigned char*>(VirtualAlloc(nullptr, 4096, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE));
    check(memory != nullptr, "allocate isolated executable test buffers");
    constexpr unsigned char original[8] = {0xB8,0x2A,0,0,0,0xC3,0x90,0x90};
    for (int i = 0; i < 3; ++i) std::memcpy(memory + i * 16, original, 8);
    DWORD previous = 0;
    check(VirtualProtect(memory, 4096, PAGE_EXECUTE_READ, &previous) != FALSE, "protect fixture bytes as execute-read");
    std::vector<Patch> patches = {
        {"one",memory,word(original),word(return_false)},
        {"two",memory+16,word(original),word(return_void)},
        {"three",memory+32,word(original),word(return_false)},
    };
    std::string reason;
    using ValueFunction = int (__fastcall*)();
    check(reinterpret_cast<ValueFunction>(memory)() == 42, "synthetic original entry executes normally");
    check(transact(patches, reason), "all verified aligned entries patch as one transaction");
    check(reinterpret_cast<ValueFunction>(memory)() == 0, "patched return-false entry executes without original body");
    check(transact(reversed(patches), reason), "disarm restores original bytes");
    check(reinterpret_cast<ValueFunction>(memory)() == 42, "restored function executes its original body");
    reason.clear();
    check(!transact(patches, reason, reject_second), "injected second operation fails the transaction");
    check(reason.find("rolled back") != std::string::npos && preflight(patches, reason),
        "partial transaction failure restores every prior entry");
    auto mismatched = patches; mismatched[2].expected ^= 1;
    check(!transact(mismatched, reason) && preflight(patches, reason),
        "all-target preflight rejects one bad fingerprint without changing any entry");
    auto misaligned = patches; misaligned[0].address = memory + 1;
    check(!transact(misaligned, reason) && preflight(patches, reason), "unaligned patch is refused before mutation");
    MEMORY_BASIC_INFORMATION protection{}; VirtualQuery(memory, &protection, sizeof(protection));
    check(protection.Protect == PAGE_EXECUTE_READ, "every patch and rollback restores page protection");

    constexpr std::uintptr_t mock_source = 0x50000F150ULL;
    constexpr std::uintptr_t old_missed_boundary = 0x580000000ULL;
    MockAddressSpace boundary{{{0x10000,old_missed_boundary-0x10000,false},
        {old_missed_boundary,0x10000,true}, {old_missed_boundary+0x10000,0x800000000000ULL-old_missed_boundary-0x10000,false}}};
    bool old_found = false;
    const auto old_origin = mock_source & ~static_cast<std::uintptr_t>(65535);
    for (std::uintptr_t offset = 65536; offset < 0x7FFF0000; offset += 65536) {
        if (old_origin + offset == old_missed_boundary || old_origin - offset == old_missed_boundary) old_found = true;
    }
    RelayDiagnostics boundary_diagnostics;
    check(!old_found && search_mock(boundary, mock_source, boundary_diagnostics) == old_missed_boundary,
        "full rel32 region walk finds the valid final granule missed by the old offset bound");
    std::uint64_t encoded = 0;
    check(relative_jump(reinterpret_cast<void*>(mock_source), reinterpret_cast<void*>(mock_source+5+0x7FFFFFFF), encoded)
        && relative_jump(reinterpret_cast<void*>(mock_source), reinterpret_cast<void*>(mock_source+5-0x80000000ULL), encoded)
        && !relative_jump(reinterpret_cast<void*>(mock_source), reinterpret_cast<void*>(mock_source+5+0x80000000ULL), encoded),
        "rel32 bounds are inclusive and measured from source plus five");
    constexpr std::uintptr_t low_hole = 0x20000000;
    MockAddressSpace near_reserved{{{0x10000,low_hole-0x10000,false}, {low_hole,0x30000,true},
        {low_hole+0x30000,0x800000000000ULL-low_hole-0x30000,false}}};
    RelayDiagnostics fallback_diagnostics;
    check(search_mock(near_reserved, mock_source, fallback_diagnostics) == low_hole
        && fallback_diagnostics.used_low_address && fallback_diagnostics.near_search.attempts == 0,
        "entire near span reserved still finds an available low-4GiB relay");
    check(relay_jump(reinterpret_cast<void*>(mock_source), reinterpret_cast<void*>(low_hole), encoded)
        && (encoded & 0xFF) == 0xB8 && !absolute_low_jump(reinterpret_cast<void*>(0x100000000ULL), encoded),
        "low-address jump encodes mov EAX and rejects truncated 64-bit addresses");
    MockAddressSpace fragmented{{{0x10000,0x12345000-0x10000,false}, {0x12345000,0x40000,true},
        {0x12385000,0x800000000000ULL-0x12385000,false}},1};
    RelayDiagnostics fragmented_diagnostics;
    check(search_mock(fragmented, mock_source, fragmented_diagnostics) == 0x12360000
        && fragmented_diagnostics.low_search.attempts == 2
        && fragmented_diagnostics.low_search.allocation_error == ERROR_INVALID_ADDRESS,
        "fragmented free-region search aligns correctly and retries an allocation race");

    void* relay = allocate_near_relay(memory, reinterpret_cast<void*>(&fake_construct));
    std::uint64_t jump = 0;
    check(relay && relative_jump(memory, relay, jump), "allocate a reachable near relay for an absolute native destination");
    const Patch relay_patch{"relay",memory,word(original),jump};
    check(transact({relay_patch}, reason), "atomic entry patch reaches the near relay");
    using ConstructorFunction = void* (__fastcall*)(JsonWrapper*);
    JsonWrapper wrapper{};
    check(reinterpret_cast<ConstructorFunction>(memory)(&wrapper) == &wrapper && live_json == 1,
        "entry-to-relay-to-C++ round trip preserves native argument and return ABI");
    fake_release(wrapper.shared.controller);
    check(transact(reversed({relay_patch}), reason) && live_json == 0, "relay entry restoration retains exact bytes and releases fixture owner");

    std::vector<EntryState> entry_states;
    check(capture_entry_states(patches, entry_states, reason) && confirm_entries_unchanged(entry_states),
        "safe refusal verifies original bytes and page protections explicitly");
    check(transact(patches, reason) && !confirm_entries_unchanged(entry_states),
        "modified entries cannot be classified as unchanged refusal");
    check(transact(reversed(patches), reason) && confirm_entries_unchanged(entry_states),
        "successful rollback restores provably unchanged refusal state");

    alignas(8) unsigned char fake_manager[0x660]{};
    void* fake_vtable[] = {reinterpret_cast<void*>(&fake_free)};
    void* vtable_pointer = fake_vtable;
    std::memcpy(fake_manager, &vtable_pointer, sizeof(vtable_pointer));
    fake_manager[0x3A0] = 1;
    bool busy = false;
    check(manager_ready(fake_manager, reason, busy, true) && !busy,
        "quiescent clean synthetic manager satisfies native guard preflight");
    fake_manager[0x279] = 1;
    check(!manager_ready(fake_manager, reason, busy, true) && busy,
        "working native save refuses Arm without mutating manager");
    fake_manager[0x279] = 0; fake_manager[0x208] = 1;
    check(!manager_ready(fake_manager, reason, busy, true) && busy,
        "legitimate dirty advanced state refuses Arm instead of losing pending data");
    check(manager_ready(fake_manager, reason, busy, false), "dirty private state may drain during protected restore");
    fake_manager[0x208] = 0; fake_manager[0x3A0] = 0;
    check(!manager_ready(fake_manager, reason, busy, false) && busy, "unfinished async summary cache refuses restore");
    fake_manager[0x3A0] = 1;
    const std::int32_t one = 1;
    std::memcpy(fake_manager + 0x518, &one, 4); std::memcpy(fake_manager + 0x51C, &one, 4);
    check(!manager_ready(fake_manager, reason, busy, false) && busy, "queued delegate callbacks refuse restore");
    const std::int32_t none = 0; std::memcpy(fake_manager + 0x518, &none, 4);

    // Reproduce the live failure using the actual companion operation state
    // machine. Only pinned-host/engine dependencies are synthetic; executable
    // pages, requests, guards, clone ownership and restore paths are real.
    offline_host_patches = patches;
    auto formal_owner = make_fake();
    static_cast<FakeJson*>(formal_owner.object)->fields["formal"] = {7,8,9};
    std::memcpy(fake_manager + 0xD8, &formal_owner, sizeof(formal_owner));
    std::vector<EntryState> cycle_entries;
    check(capture_entry_states(patches, cycle_entries, reason), "capture exact executable pages before actual Arm cycles");
    struct BusyCase { std::size_t offset; std::size_t width; std::uint64_t value; };
    const BusyCase busy_cases[] = {
        {0x220,1,1}, {0x238,1,1}, {0x278,1,1}, {0x279,1,1},
        {0x450,1,1}, {0x558,1,1}, {0x592,1,1}, {0x1B0,1,1}, {0x208,1,1},
        {0x518,4,1}, {0x568,4,1}, {0x650,8,0x41700AA0A27BE47DULL}, {0x658,4,1},
    };
    std::memcpy(fake_manager + 0x56C, &one, 4);
    for (const auto& test : busy_cases) {
        std::memcpy(fake_manager + test.offset, &test.value, test.width);
        unsigned char before[sizeof(fake_manager)]; std::memcpy(before, fake_manager, sizeof(before));
        check(run_operation(Operation::arm, fake_manager) == "busy\n" && !armed,
            "actual Arm still refuses initial dirty, queue, inflight or retry state");
        check(std::memcmp(before, fake_manager, sizeof(before)) == 0 && confirm_entries_unchanged(cycle_entries),
            "busy Arm changes no manager bytes, native entry bytes or page protection");
        std::memset(fake_manager + test.offset, 0, test.width);
    }
    fake_manager[0x3A0] = 0;
    check(run_operation(Operation::arm, fake_manager) == "busy\n" && confirm_entries_unchanged(cycle_entries),
        "actual Arm still refuses incomplete summary cache without touching native entries");
    fake_manager[0x3A0] = 1;
    offline_constructor_fails = true;
    check(run_operation(Operation::arm, fake_manager).rfind("refused\t",0) == 0 && !armed
        && confirm_entries_unchanged(cycle_entries) && live_json == 1,
        "actual failed clone rolls back every entry and retains original master ownership");
    offline_constructor_fails = false;
    const std::uint64_t live_deadline = 0x41700AA0A27BE47DULL;
    for (int round = 0; round < 6; ++round) {
        check(run_operation(Operation::arm, fake_manager) == "armed\n" && armed && !prepared,
            "actual companion Arm succeeds repeatedly from the same restored manager");
        const auto current_master = reinterpret_cast<SharedJson*>(fake_manager + 0xD8);
        check(current_master->object != formal_owner.object && live_json == 2,
            "actual Arm installs a distinct private master with balanced ownership");
        const auto deadline_snapshot = std::find_if(saved_scalars.begin(), saved_scalars.end(),
            [](const Scalar& value) { return value.offset == 0x650 && value.length == 8; });
        const auto count_snapshot = std::find_if(saved_scalars.begin(), saved_scalars.end(),
            [](const Scalar& value) { return value.offset == 0x658 && value.length == 4; });
        check(deadline_snapshot != saved_scalars.end() && count_snapshot != saved_scalars.end(),
            "actual Arm snapshots retry deadline and counter at their native widths");
        // Native failed-save completion leaves this deadline/count even after
        // pending requests and callbacks are consumed (live run193142).
        unsigned char failed_result = 255;
        json_failure(fake_manager, &failed_result, nullptr, nullptr);
        std::memcpy(fake_manager + 0x650, &live_deadline, 8);
        std::memcpy(fake_manager + 0x658, &one, 4);
        fake_manager[0x1B0] = 1; fake_manager[0x591] = 1;
        fake_manager[0x450] = 1;
        check(run_operation(Operation::prepare, fake_manager) == "busy\n" && !prepared,
            "actual Prepare waits for genuine pending requests with the barrier armed");
        std::uint64_t read_deadline = 0; std::int32_t read_count = 0;
        std::memcpy(&read_deadline, fake_manager + 0x650, 8);
        std::memcpy(&read_count, fake_manager + 0x658, 4);
        check(read_deadline == live_deadline && read_count == 1 && !preflight(patches, reason),
            "busy Prepare never clears retry state or restores protected entries early");
        fake_manager[0x450] = 0;
        const auto unprepared = run_operation(Operation::disarm, fake_manager);
        std::memcpy(&read_deadline, fake_manager + 0x650, 8);
        check(unprepared.rfind("error\tPrepareRestore is required",0) == 0
            && armed && read_deadline == live_deadline,
            "actual Disarm refuses to skip Prepare without changing owned retry state");
        const int loads_before = offline_advanced_loads;
        check(run_operation(Operation::prepare, fake_manager) == "prepared\n" && prepared && master_restored,
            "actual Prepare restores master and cache while native write barrier remains armed");
        std::memcpy(&read_deadline, fake_manager + 0x650, 8);
        std::memcpy(&read_count, fake_manager + 0x658, 4);
        check(read_deadline == live_deadline && read_count == 1 && offline_advanced_loads == loads_before + 1
            && current_master->object == formal_owner.object && live_json == 1,
            "successful Prepare leaves private retry state untouched and restores original owner exactly once");
        fake_manager[0x238] = 1;
        check(run_operation(Operation::disarm, fake_manager) == "busy\n" && armed && prepared,
            "actual Disarm still refuses an in-flight native Advanced write");
        fake_manager[0x238] = 0;
        check(run_operation(Operation::disarm, fake_manager) == "idle\n" && !armed && !prepared,
            "actual quiescent Disarm restores the transaction and acknowledges idle");
        std::memcpy(&read_deadline, fake_manager + 0x650, 8);
        std::memcpy(&read_count, fake_manager + 0x658, 4);
        check(read_deadline == 0 && read_count == 0 && saved_scalars.empty()
            && fake_manager[0x1B0] == 0 && fake_manager[0x591] == 0,
            "actual Disarm returns retry deadline/count and all transaction scalars to their entry values");
        check(confirm_entries_unchanged(cycle_entries) && current_master->object == formal_owner.object,
            "every actual restore cycle retains exact original bytes, protection and formal master identity");
    }
    clone_engine.drop(formal_owner);
    std::memset(fake_manager + 0xD8, 0, sizeof(SharedJson));
    check(live_json == 0, "six actual Arm/Prepare/Disarm cycles leak no private or original JSON owner");
    DeleteFileW((module_path() + L".request").c_str());
    DeleteFileW((module_path() + L".status").c_str());

    unsigned char parameter[0xA0]{};
    void* allocation = HeapAlloc(GetProcessHeap(), 0, 64);
    std::memcpy(parameter + 0x78, &allocation, sizeof(allocation));
    const std::int32_t size = 16; std::memcpy(parameter + 0x80, &size, 4); std::memcpy(parameter + 0x84, &size, 4);
    unsigned char result = 255; fake_manager[0x558] = 1; native_free = fake_free;
    check(json_failure(fake_manager, &result, parameter, nullptr) == &result && result == 1,
        "JSON failure handler returns the caller-owned failed result");
    unsigned char zero[16]{};
    check(fake_free_calls == 1 && std::memcmp(parameter + 0x78, zero, 16) == 0 && fake_manager[0x558] == 0,
        "JSON failure consumes its FString exactly once and clears native dispatch flag");
    json_failure(fake_manager, &result, parameter, nullptr);
    check(fake_free_calls == 1, "already-empty owned FString is not double-freed");

    RelayDiagnostics real_low_diagnostics;
    std::string low_failure;
    void* low_relay = allocate_near_relay(reinterpret_cast<void*>(0xFFFFFFFF00000000ULL),
        reinterpret_cast<void*>(&observed_json_failure), &real_low_diagnostics, &low_failure);
    check(low_relay && reinterpret_cast<std::uintptr_t>(low_relay) <= 0xFFFFFFFFULL
        && real_low_diagnostics.used_low_address, "real Windows fallback reserves executable relay below 4GiB");
    std::uint64_t low_jump = 0;
    check(absolute_low_jump(low_relay, low_jump), "actual allocated low address fits the complete eight-byte entry stub");
    const Patch low_patch{"low32",memory,word(original),low_jump};
    check(transact({low_patch}, reason), "low-4GiB handler preserves the existing aligned atomic-eight transaction");
    allocation = HeapAlloc(GetProcessHeap(),0,64);
    std::memcpy(parameter+0x78,&allocation,sizeof(allocation)); fake_manager[0x558] = 1; result = 255;
    using JsonFunction = void* (__fastcall*)(void*,unsigned char*,void*,void*);
    void* delegate = reinterpret_cast<void*>(0x12345678);
    check(reinterpret_cast<JsonFunction>(memory)(fake_manager,&result,parameter,delegate) == &result
        && result == 1 && fake_free_calls == 2 && fake_manager[0x558] == 0
        && observed_arguments[0] == fake_manager && observed_arguments[1] == &result
        && observed_arguments[2] == parameter && observed_arguments[3] == delegate
        && std::memcmp(parameter+0x78,zero,16) == 0,
        "mov-EAX relay preserves all four JSON arguments, failed output, owned FString cleanup and dispatch flag");
    check(transact(reversed({low_patch}),reason) && VirtualFree(low_relay,0,MEM_RELEASE),
        "idle fixture restores its original entry and releases the actual low-address reservation");
    MEMORY_BASIC_INFORMATION freed_low{}; VirtualQuery(low_relay,&freed_low,sizeof(freed_low));
    check(freed_low.State == MEM_FREE, "released low-address fixture reservation is free again");

    EngineClone engine{fake_construct,fake_copy,fake_release};
    auto original_owner = make_fake();
    static_cast<FakeJson*>(original_owner.object)->fields["slot"] = {1,2,3};
    SharedJson cloned_owner;
    check(engine.clone(nullptr, original_owner, cloned_owner, reason), "engine wrapper and consuming-copy ABI produce an owned clone");
    auto clone_control = static_cast<FakeControl*>(cloned_owner.controller);
    check(live_json == 2 && clone_control->strong == 1, "temporary destination reference is consumed while clone owner stays alive");
    static_cast<FakeJson*>(cloned_owner.object)->fields["slot"][0] = 99;
    check(static_cast<FakeJson*>(original_owner.object)->fields["slot"][0] == 1,
        "nested clone changes do not change the protected original fixture");
    engine.drop(cloned_owner); engine.drop(original_owner);
    check(live_json == 0 && !cloned_owner.controller && !original_owner.controller,
        "moving and releasing cloned/original owners destroys each object once");

    alignas(8) unsigned char cache[0x50]{};
    std::vector<unsigned char> cache_data(3 * 0xC0);
    void* cache_pointer = cache_data.data(); const std::int32_t cache_count = 3;
    std::memcpy(cache, &cache_pointer, 8); std::memcpy(cache + 8, &cache_count, 4);
    std::memcpy(cache + 12, &cache_count, 4); std::memcpy(cache + 0x28, &cache_count, 4);
    std::memcpy(cache + 0x34, &one, 4); const std::uint32_t allocation_flags = 5;
    std::memcpy(cache + 0x10, &allocation_flags, 4);
    const BorrowedString first{L"AutoSave0",10,10}, last{L"PBZArenaTitleProbe",19,19};
    std::memcpy(cache_data.data(), &first, sizeof(first));
    std::memcpy(cache_data.data() + 2 * 0xC0, &last, sizeof(last));
    std::vector<std::wstring> keys;
    check(collect_summary_keys(cache, keys, reason) && keys.size() == 2
        && keys[0] == L"AutoSave0" && keys[1] == L"PBZArenaTitleProbe",
        "summary key collector respects sparse holes and inline allocation bits");
    check(remove_summary_keys(cache, keys, fake_remove_summary, reason) && removed_keys == keys,
        "copied summary keys survive native in-place entry destruction and clear all cache entries");
    std::vector<std::wstring> empty;
    check(collect_summary_keys(cache, empty, reason) && empty.empty(), "cleared sparse summary cache validates empty");
    std::memcpy(cache + 0x34, &none, 4);
    check(!collect_summary_keys(cache, empty, reason), "inconsistent summary allocation population is refused before removals");

    std::memset(cache, 0, sizeof(cache));
    cache_data.assign(129 * 0xC0, 0); cache_pointer = cache_data.data();
    const std::int32_t heap_count = 129, heap_free = 127;
    std::uint32_t heap_flags[5] = {1,0,0,0,1}; std::uint32_t* heap_pointer = heap_flags;
    std::memcpy(cache, &cache_pointer, 8); std::memcpy(cache + 8, &heap_count, 4);
    std::memcpy(cache + 12, &heap_count, 4); std::memcpy(cache + 0x28, &heap_count, 4);
    std::memcpy(cache + 0x20, &heap_pointer, 8); std::memcpy(cache + 0x34, &heap_free, 4);
    std::memcpy(cache_data.data(), &first, sizeof(first));
    std::memcpy(cache_data.data() + 128 * 0xC0, &last, sizeof(last));
    check(collect_summary_keys(cache, keys, reason) && keys.size() == 2,
        "summary key collector uses heap allocation bits beyond inline capacity");
    auto invalid_key = first; invalid_key.data = reinterpret_cast<const wchar_t*>(1);
    std::memcpy(cache_data.data(), &invalid_key, sizeof(invalid_key));
    check(!collect_summary_keys(cache, keys, reason), "unreadable native key rejects the complete collection before mutation");
    std::memcpy(cache_data.data(), &last, sizeof(last));
    check(!collect_summary_keys(cache, keys, reason), "duplicate native summary keys are refused before partial removals");
    const wchar_t embedded[] = L"Auto\0Save0";
    const BorrowedString embedded_key{embedded,11,11};
    std::memcpy(cache_data.data(), &embedded_key, sizeof(embedded_key));
    check(!collect_summary_keys(cache, keys, reason), "embedded native string terminators are refused before mutation");

    // Read-only diagnostics inspect synthetic pinned-layout data and code pages.
    auto fake_image = static_cast<unsigned char*>(VirtualAlloc(nullptr,0x06B74000,MEM_RESERVE,PAGE_NOACCESS));
    check(fake_image != nullptr, "reserve sparse synthetic image for read-only native diagnostics");
    for (const auto& spec : targets) {
        void* page = VirtualAlloc(fake_image+(spec.rva & ~0xFFFu),4096,MEM_COMMIT,PAGE_READWRITE);
        check(page != nullptr, "commit synthetic diagnostic entry page");
        std::memcpy(fake_image+spec.rva,spec.original,8);
        VirtualProtect(page,4096,PAGE_EXECUTE_READ,&previous);
    }
    void* json_page = VirtualAlloc(fake_image+(json_rva & ~0xFFFu),4096,MEM_COMMIT,PAGE_READWRITE);
    check(json_page != nullptr, "commit synthetic JSON diagnostic entry page");
    std::memcpy(fake_image+json_rva,json_original,8); VirtualProtect(json_page,4096,PAGE_EXECUTE_READ,&previous);
    alignas(8) unsigned char diagnostic_manager[0x660]{};
    std::vector<unsigned char> veto_data(2*0x28);
    void* veto_pointer = veto_data.data(); const std::int32_t veto_count = 2;
    auto veto_map = diagnostic_manager+0x3E8;
    std::memcpy(veto_map,&veto_pointer,8); std::memcpy(veto_map+8,&veto_count,4);
    std::memcpy(veto_map+12,&veto_count,4); std::memcpy(veto_map+0x28,&veto_count,4);
    const std::uint32_t veto_bits = 3; std::memcpy(veto_map+0x10,&veto_bits,4);
    const std::uint64_t first_key = 123, second_key = 456;
    std::memcpy(veto_data.data(),&first_key,8); std::memcpy(veto_data.data()+0x18,&veto_count,4);
    std::memcpy(veto_data.data()+0x28,&second_key,8); veto_data[0x28+8] = 2;
    std::memcpy(veto_data.data()+0x28+0x18,&one,4);
    diagnostic_manager[0x27A] = 1; std::memcpy(diagnostic_manager+0x3D4,&veto_count,4);
    unsigned char diagnostic_before[0x660]; std::memcpy(diagnostic_before,diagnostic_manager,sizeof(diagnostic_before));
    const auto veto_before = veto_data;
    const auto diagnostic = inspect_manager(diagnostic_manager,fake_image);
    check(diagnostic.find("entriesOriginal=1") != std::string::npos
        && diagnostic.find("vetoReason0=2") != std::string::npos && diagnostic.find("vetoReason2=1") != std::string::npos
        && diagnostic.find("callbackNesting=2") != std::string::npos && diagnostic.find("rawU8_27A=1") != std::string::npos,
        "diagnostics distinguish original code, gameplay veto refs, mode veto refs and callback nesting");
    check(std::memcmp(diagnostic_before,diagnostic_manager,sizeof(diagnostic_before)) == 0 && veto_before == veto_data,
        "native inspection changes no manager or veto map bytes");
    check(diagnostic.size() < 4096, "native diagnostic payload fits the Lua bounded handshake reader");
    std::vector<unsigned char> registry_data(3*0x18);
    FakeSavable blocked_object{}, allowed_object{}, other_object{};
    blocked_object.object_class = allowed_object.object_class = &fake_eligible_class;
    allowed_object.permitted = true; other_object.object_class = &fake_other_class;
    void* registry_pointer = registry_data.data(); auto registry_map = diagnostic_manager+0x2B0;
    std::memcpy(registry_map,&registry_pointer,8); std::memcpy(registry_map+8,&cache_count,4);
    std::memcpy(registry_map+12,&cache_count,4); std::memcpy(registry_map+0x28,&cache_count,4);
    const std::uint32_t registry_bits = 7; std::memcpy(registry_map+0x10,&registry_bits,4);
    void* registry_objects[] = {&blocked_object,&allowed_object,&other_object};
    for (std::size_t i=0;i<3;++i) {
        const std::uint64_t key=i+1; std::memcpy(registry_data.data()+i*0x18,&key,8);
        std::memcpy(registry_data.data()+i*0x18+8,&registry_objects[i],8);
    }
    const auto registry_before=registry_data;
    const EligibilityApi mock_eligibility{fake_can_save,fake_interface,fake_implements,fake_execute};
    std::string eligibility_report;
    check(inspect_registry(diagnostic_manager,eligibility_report,&mock_eligibility)
        && eligibility_report.find("savableChecked=2") != std::string::npos
        && eligibility_report.find("savableBlocked=1") != std::string::npos
        && eligibility_report.find(hex_word(reinterpret_cast<std::uintptr_t>(&blocked_object))) != std::string::npos,
        "eligibility diagnostics identify the exact registered object returning false");
    check(eligibility_calls==2 && registry_before==registry_data && !blocked_object.permitted && allowed_object.permitted,
        "eligibility query skips non-interface objects and changes no saved actor or registry data");
    VirtualFree(fake_image,0,MEM_RELEASE);
    VirtualFree(memory, 0, MEM_RELEASE);
    // Relay is deliberately retained by the production allocation policy.
    std::printf("PASS %d offline native barrier checks\n", checks);
    return 0;
}
