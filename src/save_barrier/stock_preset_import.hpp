#pragma once
#include "engine_clone.hpp"
#include "summary_cache.hpp"
#include "win_support.hpp"
#include "stock_profiles.hpp"

namespace pbz_dropin {
using ParseObject = bool (__fastcall*)(pbz_barrier::JsonWrapper*, const pbz_barrier::BorrowedString*);
using CollectKeys = bool (*)(void*, std::set<std::wstring>&, std::string&);

inline bool collect_object_keys(void* object, std::set<std::wstring>& keys, std::string& reason) {
    auto header = static_cast<unsigned char*>(object);
    void* data = nullptr; std::uint32_t* heap = nullptr;
    std::int32_t number = 0, capacity = 0, free_number = 0, number_bits = 0;
    if (!pbz_barrier::read_bytes(header, &data, 8) || !pbz_barrier::read_bytes(header + 8, &number, 4)
        || !pbz_barrier::read_bytes(header + 12, &capacity, 4) || !pbz_barrier::read_bytes(header + 0x20, &heap, 8)
        || !pbz_barrier::read_bytes(header + 0x28, &number_bits, 4) || !pbz_barrier::read_bytes(header + 0x34, &free_number, 4)
        || number < 0 || number > 4096 || capacity < number || capacity > 4096 || free_number < 0 || free_number > number
        || number_bits < number || number_bits > 4096 || (!heap && number_bits > 128) || (number && !data)) {
        reason = "Native JSON object map has an invalid bounded layout"; return false;
    }
    std::vector<std::uint32_t> bits((static_cast<std::size_t>(number_bits) + 31) / 32);
    if (!pbz_barrier::read_bytes(heap ? static_cast<void*>(heap) : header + 0x10, bits.data(), bits.size() * 4)) {
        reason = "Native JSON object allocation bits are unreadable"; return false;
    }
    std::vector<unsigned char> entries(static_cast<std::size_t>(number) * 0x28);
    if (!pbz_barrier::read_bytes(data, entries.data(), entries.size())) {
        reason = "Native JSON object entries are unreadable"; return false;
    }
    std::set<std::wstring> result;
    for (std::int32_t i = 0; i < number; ++i) {
        if (!(bits[static_cast<std::size_t>(i) >> 5] & (1u << (i & 31)))) continue;
        pbz_barrier::BorrowedString key{}; std::memcpy(&key, entries.data() + static_cast<std::size_t>(i) * 0x28, sizeof(key));
        if (!key.data || key.number < 1 || key.number > 1024 || key.maximum < key.number || key.maximum > 65536) {
            reason = "Native JSON object key has an invalid layout"; return false;
        }
        std::vector<wchar_t> value(static_cast<std::size_t>(key.number));
        if (!pbz_barrier::read_bytes(key.data, value.data(), value.size() * 2) || value.back() != L'\0'
            || std::find(value.begin(), value.end() - 1, L'\0') != value.end() - 1
            || !result.emplace(value.data(), value.size() - 1).second) {
            reason = "Native JSON object keys are unreadable or duplicate"; return false;
        }
    }
    if (result.size() != static_cast<std::size_t>(number - free_number)) {
        reason = "Native JSON object allocation count is inconsistent"; return false;
    }
    keys = std::move(result); return true;
}

inline bool invalidate_private_summaries(void* cache, pbz_barrier::RemoveSummary remove, std::string& reason) {
    if (!remove) { reason = "Native summary invalidation is unavailable"; return false; }
    std::vector<std::wstring> keys;
    if (!pbz_barrier::collect_summary_keys(cache, keys, reason)) return false;
    for (const auto& key : keys) {
        if (!is_checkpoint_slot(key)) continue;
        const pbz_barrier::BorrowedString borrowed{key.c_str(), static_cast<std::int32_t>(key.size() + 1),
            static_cast<std::int32_t>(key.size() + 1)};
        if (remove(cache, &borrowed) != 1) { reason = "Native private summary invalidation failed"; return false; }
    }
    std::vector<std::wstring> remaining;
    if (!pbz_barrier::collect_summary_keys(cache, remaining, reason)) return false;
    for (const auto& key : remaining) if (is_checkpoint_slot(key)) {
        reason = "A stale private summary remains after import"; return false;
    }
    return true;
}

inline bool import_into_clone(void* manager, pbz_barrier::SharedJson& destination,
    const SelectedPreset& presets, const pbz_barrier::EngineClone& engine, ParseObject parse,
    std::string& reason, CollectKeys collect = collect_object_keys) {
    pbz_barrier::JsonWrapper wrapper{};
    struct Cleanup {
        const pbz_barrier::EngineClone& engine; pbz_barrier::JsonWrapper& wrapper;
        ~Cleanup() { engine.drop(wrapper.shared); }
    } cleanup{engine, wrapper};
    try {
        const bool reference = parse && engine.construct && !engine.initialize_json;
        const bool legacy = !parse && !engine.construct && engine.initialize_json;
        if (!manager || !destination.object || !destination.controller || presets.text.empty()
            || !(reference || legacy) || !engine.deep_copy || !engine.release || !collect) {
            reason = "Drop-in native import dependencies are incomplete"; return false;
        }
        std::set<std::wstring> before;
        if (!collect(destination.object, before, reason)) return false;
        const std::set<std::wstring> approved{presets.slot};
        for (const auto& name : before) {
            auto lower = name;
            for (auto& c : lower) if (c >= L'A' && c <= L'Z') c = static_cast<wchar_t>(c - L'A' + L'a');
            if (lower.rfind(L"pbzarenastock", 0) == 0) {
                reason = "A trial-only slot name already exists in the account"; return false;
            }
        }
        const auto length = static_cast<std::int32_t>(presets.text.size() + 1);
        bool parsed_ok = false;
        if (legacy) {
            // The admitted 301524 parser initializes an empty wrapper and borrows the text.
            pbz_barrier::BorrowedJsonText borrowed{presets.text.c_str(), length, length};
            parsed_ok = engine.initialize_json(&wrapper, &borrowed);
            LONG strong = 0;
            SIZE_T read = 0;
            if (!wrapper.shared.controller || !ReadProcessMemory(GetCurrentProcess(),
                static_cast<unsigned char*>(wrapper.shared.controller) + 8, &strong, sizeof(strong), &read)
                || read != sizeof(strong) || strong < 1 || strong > 65536) {
                wrapper.shared = {}; // Cleanup can release only a validated owner.
            }
            const unsigned char empty_string[sizeof(wrapper.string)]{};
            parsed_ok = parsed_ok && borrowed.data == presets.text.c_str() && borrowed.number == length
                && borrowed.capacity == length && std::memcmp(wrapper.string, empty_string, sizeof(empty_string)) == 0;
        } else {
            engine.construct(&wrapper);
            const pbz_barrier::BorrowedString borrowed{presets.text.c_str(), length, length};
            parsed_ok = wrapper.shared.object && wrapper.shared.controller && parse(&wrapper, &borrowed);
        }
        if (!parsed_ok || !wrapper.shared.object || !wrapper.shared.controller) {
            reason = "The pinned engine could not parse the approved private presets"; return false;
        }
        std::set<std::wstring> parsed;
        if (!collect(wrapper.shared.object, parsed, reason) || parsed != approved) {
            reason = "The parsed native preset root does not match the selected map slot"; return false;
        }
        auto temporary = destination;
        InterlockedIncrement(reinterpret_cast<volatile LONG*>(static_cast<unsigned char*>(temporary.controller) + 8));
        engine.deep_copy(manager, &temporary, &wrapper.shared); // Verified consuming-destination merge ABI.
        before.insert(approved.begin(), approved.end());
        std::set<std::wstring> after;
        if (!collect(destination.object, after, reason) || after != before) {
            reason = "The private native clone did not retain the exact expected root keys"; return false;
        }
        return true;
    } catch (const std::exception&) {
        reason = "Drop-in native preset import failed before master publication"; return false;
    }
}
} // namespace pbz_dropin
