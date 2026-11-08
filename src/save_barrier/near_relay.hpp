#pragma once
#include "patch_transaction.hpp"
#include <limits>

namespace pbz_barrier {
struct AddressRange { std::uintptr_t first; std::uintptr_t last; };
struct AddressRegion { std::uintptr_t base; std::uintptr_t size; bool free; };
struct SearchDiagnostics {
    std::uint32_t regions = 0, free_regions = 0, attempts = 0;
    DWORD query_error = 0, allocation_error = 0;
};
struct RelayDiagnostics {
    SearchDiagnostics near_search, low_search;
    DWORD protect_error = 0, flush_error = 0;
    bool used_low_address = false;
};

inline bool relative_jump(void* source, void* destination, std::uint64_t& bytes) {
    const auto address = reinterpret_cast<std::uintptr_t>(source);
    const auto target = reinterpret_cast<std::uintptr_t>(destination);
    if (address > (std::numeric_limits<std::uintptr_t>::max)() - 5) return false;
    const auto next = address + 5;
    std::int32_t displacement = 0;
    if (target >= next) {
        if (target - next > 0x7FFFFFFF) return false;
        displacement = static_cast<std::int32_t>(target - next);
    } else {
        if (next - target > 0x80000000ULL) return false;
        displacement = static_cast<std::int32_t>(-static_cast<std::int64_t>(next - target));
    }
    unsigned char buffer[8] = {0xE9,0,0,0,0,0x90,0x90,0x90};
    std::memcpy(buffer + 1, &displacement, 4);
    bytes = word(buffer);
    return true;
}

inline bool absolute_low_jump(void* destination, std::uint64_t& bytes) {
    const auto address = reinterpret_cast<std::uintptr_t>(destination);
    if (!address || address > 0xFFFFFFFFULL) return false;
    // Win64 JsonSaveToDisk has no incoming RAX argument. EAX zero-extends.
    unsigned char buffer[8] = {0xB8,0,0,0,0,0xFF,0xE0,0x90};
    const auto immediate = static_cast<std::uint32_t>(address);
    std::memcpy(buffer + 1, &immediate, 4);
    bytes = word(buffer);
    return true;
}

inline bool relay_jump(void* source, void* destination, std::uint64_t& bytes) {
    return relative_jump(source, destination, bytes) || absolute_low_jump(destination, bytes);
}

inline AddressRange relative_range(std::uintptr_t source, std::uintptr_t minimum, std::uintptr_t maximum) {
    const auto limit = (std::numeric_limits<std::uintptr_t>::max)();
    if (source > limit - 5) return {1,0};
    const auto next = source + 5;
    const auto first = next >= 0x80000000ULL ? next - 0x80000000ULL : 0;
    const auto last = next <= limit - 0x7FFFFFFF ? next + 0x7FFFFFFF : limit;
    return {(std::max)(first, minimum), (std::min)(last, maximum)};
}

inline bool align_up(std::uintptr_t value, std::uintptr_t alignment, std::uintptr_t& output) {
    if (!alignment) return false;
    const auto remainder = value % alignment;
    const auto addition = remainder ? alignment - remainder : 0;
    if (value > (std::numeric_limits<std::uintptr_t>::max)() - addition) return false;
    output = value + addition;
    return true;
}

// Native allocation and deterministic address-space mocks use this complete
// bounded region walker. Query and reserve report Win32 errors.
template <typename Query, typename Reserve>
inline std::uintptr_t reserve_free_region(AddressRange range, std::uintptr_t allocation_size,
    std::uintptr_t granularity, std::uintptr_t page_size, Query query, Reserve reserve, SearchDiagnostics& diagnostics) {
    if (range.first > range.last || !allocation_size || !granularity || !page_size) return 0;
    std::uintptr_t cursor = range.first;
    const auto max_queries = static_cast<std::uint64_t>((range.last - range.first) / page_size) + 2;
    while (cursor <= range.last && diagnostics.regions < max_queries) {
        AddressRegion region{};
        DWORD error = 0;
        if (!query(cursor, region, error)) { diagnostics.query_error = error; return 0; }
        ++diagnostics.regions;
        if (!region.size || region.base > cursor || region.base > (std::numeric_limits<std::uintptr_t>::max)() - region.size
            || region.base + region.size <= cursor) {
            diagnostics.query_error = ERROR_INVALID_DATA; return 0;
        }
        const auto end = region.base + region.size;
        if (region.free) {
            ++diagnostics.free_regions;
            std::uintptr_t candidate = 0;
            if (end >= allocation_size && align_up((std::max)(cursor, range.first), granularity, candidate)) {
                const auto last = (std::min)(range.last, end - allocation_size);
                while (candidate <= last) {
                    ++diagnostics.attempts;
                    DWORD allocation_error = 0;
                    if (reserve(candidate, allocation_size, allocation_error)) return candidate;
                    diagnostics.allocation_error = allocation_error;
                    if (candidate > (std::numeric_limits<std::uintptr_t>::max)() - granularity) break;
                    candidate += granularity;
                }
            }
        }
        cursor = end;
    }
    return 0;
}

inline std::string relay_diagnostic_text(const RelayDiagnostics& diagnostics) {
    const auto describe = [](const char* label, const SearchDiagnostics& search) {
        return std::string(label) + "{regions=" + std::to_string(search.regions)
            + ",free=" + std::to_string(search.free_regions) + ",attempts=" + std::to_string(search.attempts)
            + ",queryWin32=" + std::to_string(search.query_error)
            + ",allocWin32=" + std::to_string(search.allocation_error) + "}";
    };
    return describe("near", diagnostics.near_search) + ";" + describe("low4G", diagnostics.low_search)
        + ";protectWin32=" + std::to_string(diagnostics.protect_error)
        + ";flushWin32=" + std::to_string(diagnostics.flush_error);
}

template <typename Query, typename Reserve>
inline std::uintptr_t reserve_relay_address(std::uintptr_t source, std::uintptr_t minimum,
    std::uintptr_t maximum, std::uintptr_t page, std::uintptr_t granularity,
    Query query, Reserve reserve, RelayDiagnostics& diagnostics) {
    auto address = reserve_free_region(relative_range(source, minimum, maximum),
        page, granularity, page, query, reserve, diagnostics.near_search);
    if (!address) {
        address = reserve_free_region({minimum, (std::min)(maximum, static_cast<std::uintptr_t>(0xFFFFFFFFULL))},
            page, granularity, page, query, reserve, diagnostics.low_search);
        diagnostics.used_low_address = address != 0;
    }
    return address;
}

// Relays remain allocated until exit. The low-4GiB fallback removes dependence
// on an available rel32 reservation around the large game image.
inline void* allocate_near_relay(void* source, void* destination,
    RelayDiagnostics* report = nullptr, std::string* failure = nullptr) {
    RelayDiagnostics diagnostics;
    SYSTEM_INFO system{};
    GetSystemInfo(&system);
    const auto minimum = reinterpret_cast<std::uintptr_t>(system.lpMinimumApplicationAddress);
    const auto system_maximum = reinterpret_cast<std::uintptr_t>(system.lpMaximumApplicationAddress);
    const auto page = static_cast<std::uintptr_t>(system.dwPageSize);
    const auto maximum = system_maximum - (page - 1);
    const auto query = [](std::uintptr_t address, AddressRegion& region, DWORD& error) {
        MEMORY_BASIC_INFORMATION memory{};
        if (VirtualQuery(reinterpret_cast<void*>(address), &memory, sizeof(memory)) != sizeof(memory)) {
            error = GetLastError(); return false;
        }
        region = {reinterpret_cast<std::uintptr_t>(memory.BaseAddress), memory.RegionSize, memory.State == MEM_FREE};
        return true;
    };
    const auto reserve = [](std::uintptr_t candidate, std::uintptr_t size, DWORD& error) {
        void* allocation = VirtualAlloc(reinterpret_cast<void*>(candidate), size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
        if (!allocation) { error = GetLastError(); return false; }
        if (reinterpret_cast<std::uintptr_t>(allocation) != candidate) {
            VirtualFree(allocation, 0, MEM_RELEASE); error = ERROR_INVALID_ADDRESS; return false;
        }
        return true;
    };
    const auto address = reserve_relay_address(reinterpret_cast<std::uintptr_t>(source), minimum,
        maximum, page, system.dwAllocationGranularity, query, reserve, diagnostics);
    void* relay = reinterpret_cast<void*>(address);
    if (relay) {
        unsigned char code[14] = {0xFF,0x25,0,0,0,0};
        std::memcpy(code + 6, &destination, sizeof(destination));
        std::memcpy(relay, code, sizeof(code));
        DWORD previous = 0;
        if (!VirtualProtect(relay, page, PAGE_EXECUTE_READ, &previous)) diagnostics.protect_error = GetLastError();
        else if (!FlushInstructionCache(GetCurrentProcess(), relay, sizeof(code))) diagnostics.flush_error = GetLastError();
        else {
            if (report) *report = diagnostics;
            return relay;
        }
        VirtualFree(relay, 0, MEM_RELEASE);
    }
    if (report) *report = diagnostics;
    if (failure) *failure = std::string(address ? "relay executable preparation failed; " : "relay address space exhausted; ")
        + relay_diagnostic_text(diagnostics);
    return nullptr;
}
} // namespace pbz_barrier
