#pragma once
#define NOMINMAX
#include <windows.h>
#include <intrin.h>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace pbz_barrier {
struct Patch {
    const char* name;
    void* address;
    std::uint64_t expected;
    std::uint64_t replacement;
};

inline std::uint64_t word(const unsigned char (&bytes)[8]) {
    std::uint64_t value;
    std::memcpy(&value, bytes, sizeof(value));
    return value;
}

inline bool read_word(void* address, std::uint64_t& value) {
    SIZE_T amount = 0;
    return ReadProcessMemory(GetCurrentProcess(), address, &value, sizeof(value), &amount)
        && amount == sizeof(value);
}

inline bool readable_executable(void* address) {
    MEMORY_BASIC_INFORMATION region{};
    if (reinterpret_cast<std::uintptr_t>(address) % 8 != 0
        || VirtualQuery(address, &region, sizeof(region)) != sizeof(region)
        || region.State != MEM_COMMIT || (region.Protect & (PAGE_GUARD | PAGE_NOACCESS))) return false;
    const DWORD protection = region.Protect & 0xFF;
    return protection == PAGE_EXECUTE || protection == PAGE_EXECUTE_READ
        || protection == PAGE_EXECUTE_READWRITE || protection == PAGE_EXECUTE_WRITECOPY;
}

inline bool preflight(const std::vector<Patch>& patches, std::string& reason) {
    for (std::size_t i = 0; i < patches.size(); ++i) {
        const auto& patch = patches[i];
        std::uint64_t current = 0;
        if (!readable_executable(patch.address) || !read_word(patch.address, current)
            || current != patch.expected) {
            reason = std::string("preflight mismatch: ") + patch.name;
            return false;
        }
        for (std::size_t j = 0; j < i; ++j) {
            if (patch.address == patches[j].address) {
                reason = "duplicate target address";
                return false;
            }
        }
    }
    return true;
}

inline bool exchange(const Patch& patch, bool reverse, std::string& reason, bool& changed) {
    changed = false;
    const auto expected = reverse ? patch.replacement : patch.expected;
    const auto replacement = reverse ? patch.expected : patch.replacement;
    DWORD previous = 0;
    if (!VirtualProtect(patch.address, 8, PAGE_EXECUTE_READWRITE, &previous)) {
        reason = std::string("VirtualProtect failed: ") + patch.name;
        return false;
    }
    const auto found = static_cast<std::uint64_t>(InterlockedCompareExchange64(
        static_cast<volatile LONG64*>(patch.address), static_cast<LONG64>(replacement), static_cast<LONG64>(expected)));
    changed = found == expected;
    const bool flushed = !changed || FlushInstructionCache(GetCurrentProcess(), patch.address, 8) != FALSE;
    DWORD ignored = 0;
    const bool protected_again = VirtualProtect(patch.address, 8, previous, &ignored) != FALSE;
    if (!changed || !flushed || !protected_again) {
        reason = std::string(!changed ? "atomic compare mismatch: "
            : !flushed ? "instruction flush failed: " : "protection restore failed: ") + patch.name;
        return false;
    }
    return true;
}

// A test-only injector may refuse one forward operation. Rollback never calls it.
using RejectOperation = bool (*)(std::size_t index);
inline bool transact(const std::vector<Patch>& patches, std::string& reason, RejectOperation reject = nullptr) {
    if (!preflight(patches, reason)) return false;
    std::size_t applied = 0;
    for (; applied < patches.size(); ++applied) {
        bool changed = false;
        const bool refused = reject && reject(applied);
        if (!refused && exchange(patches[applied], false, reason, changed)) continue;
        if (refused) reason = "injected operation failure";
        if (changed) ++applied;
        bool rolled_back = true;
        while (applied > 0) {
            bool restored = false;
            std::string rollback_reason;
            if (!exchange(patches[--applied], true, rollback_reason, restored)) {
                rolled_back = false;
                reason += "; rollback failed: " + rollback_reason;
            }
        }
        if (rolled_back) reason += "; rolled back";
        return false;
    }
    return true;
}

inline std::vector<Patch> reversed(const std::vector<Patch>& patches) {
    std::vector<Patch> result = patches;
    for (auto& patch : result) std::swap(patch.expected, patch.replacement);
    return result;
}
} // namespace pbz_barrier
