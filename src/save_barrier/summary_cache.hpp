#pragma once
#include "patch_transaction.hpp"
#include <algorithm>

namespace pbz_barrier {
struct BorrowedString { const wchar_t* data; std::int32_t number; std::int32_t maximum; };
static_assert(sizeof(BorrowedString) == 16, "pinned FString layout");
using RemoveSummary = std::int32_t (__fastcall*)(void*, const BorrowedString*);

inline bool read_bytes(const void* source, void* destination, std::size_t length) {
    if (!length) return true;
    SIZE_T amount = 0;
    return ReadProcessMemory(GetCurrentProcess(), source, destination, length, &amount) && amount == length;
}

inline bool collect_summary_keys(void* map, std::vector<std::wstring>& keys, std::string& reason) {
    auto header = static_cast<unsigned char*>(map);
    void* data = nullptr;
    std::uint32_t* heap_bits = nullptr;
    std::int32_t indices = 0, capacity = 0, free_indices = 0, number_bits = 0;
    if (!read_bytes(header, &data, 8) || !read_bytes(header + 8, &indices, 4)
        || !read_bytes(header + 12, &capacity, 4) || !read_bytes(header + 0x34, &free_indices, 4)
        || !read_bytes(header + 0x20, &heap_bits, 8) || !read_bytes(header + 0x28, &number_bits, 4)
        || indices < 0 || indices > 4096 || capacity < indices || capacity > 4096
        || free_indices < 0 || free_indices > indices || number_bits < indices || number_bits > 4096
        || (!heap_bits && number_bits > 128) || (indices && !data)) {
        reason = "native summary cache layout is invalid"; return false;
    }
    std::vector<std::uint32_t> bits((static_cast<std::size_t>(number_bits) + 31) / 32);
    const void* allocation_bits = heap_bits ? static_cast<void*>(heap_bits) : header + 0x10;
    if (!read_bytes(allocation_bits, bits.data(), bits.size() * sizeof(bits[0]))) {
        reason = "native summary allocation bits are unreadable"; return false;
    }
    std::vector<unsigned char> entries(static_cast<std::size_t>(indices) * 0xC0);
    if (!read_bytes(data, entries.data(), entries.size())) {
        reason = "native summary entries are unreadable"; return false;
    }
    std::vector<std::wstring> result;
    for (std::int32_t index = 0; index < indices; ++index) {
        if (!(bits[static_cast<std::size_t>(index) >> 5] & (1u << (index & 31)))) continue;
        BorrowedString key{};
        std::memcpy(&key, entries.data() + static_cast<std::size_t>(index) * 0xC0, sizeof(key));
        if (!key.data || key.number < 1 || key.number > 1024 || key.maximum < key.number || key.maximum > 65536) {
            reason = "native summary cache key is invalid"; return false;
        }
        std::vector<wchar_t> text(static_cast<std::size_t>(key.number));
        if (!read_bytes(key.data, text.data(), text.size() * sizeof(wchar_t)) || text.back() != L'\0') {
            reason = "native summary cache key is unreadable"; return false;
        }
        if (std::find(text.begin(), text.end() - 1, L'\0') != text.end() - 1) {
            reason = "native summary key has an embedded terminator"; return false;
        }
        std::wstring copied(text.data(), text.size() - 1);
        if (std::find(result.begin(), result.end(), copied) != result.end()) {
            reason = "native summary cache has duplicate keys"; return false;
        }
        result.push_back(std::move(copied));
    }
    if (result.size() != static_cast<std::size_t>(indices - free_indices)) {
        reason = "native summary allocation count is inconsistent"; return false;
    }
    keys = std::move(result); // All key memory was validated before any removal.
    return true;
}

inline bool remove_summary_keys(void* map, const std::vector<std::wstring>& keys,
    RemoveSummary remove, std::string& reason) {
    for (const auto& key : keys) {
        const auto length = static_cast<std::int32_t>(key.size() + 1);
        const BorrowedString borrowed{key.c_str(),length,length};
        if (remove(map, &borrowed) != 1) {
            reason = "native summary cache removal failed"; return false;
        }
    }
    std::vector<std::wstring> remaining;
    if (!collect_summary_keys(map, remaining, reason)) return false;
    if (!remaining.empty()) { reason = "native summary cache did not become empty"; return false; }
    return true;
}
} // namespace pbz_barrier
