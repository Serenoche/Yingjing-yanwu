#pragma once
#include "win_support.hpp"
#include "vendor/json.hpp"
#include <filesystem>
#include <iterator>
#include <set>
#include <vector>

namespace pbz_dropin {
using Json = nlohmann::ordered_json;
constexpr unsigned slot_capacity = 60;
constexpr wchar_t slot_prefix[] = L"PBZArenaStockMap";

inline bool is_checkpoint_slot(const std::wstring& name) {
    constexpr std::size_t prefix_size = std::size(slot_prefix) - 1;
    if (name.size() != prefix_size + 2 || name.compare(0, prefix_size, slot_prefix) != 0) return false;
    const auto tens = name[prefix_size], ones = name[prefix_size + 1];
    if (tens < L'0' || tens > L'9' || ones < L'0' || ones > L'9') return false;
    const auto index = static_cast<unsigned>((tens - L'0') * 10 + ones - L'0');
    return index > 0 && index <= slot_capacity;
}

inline bool is_player_cycle(int cycle) {
    return cycle >= -1 && cycle <= 6;
}

struct PreparedPresets {
    Json shared, maps, players;
};

struct SelectedPreset {
    std::wstring slot, text;
};

// Fragments are disjoint except for the nested game system record.
inline void merge_fragment(Json& record, const Json& fragment) {
    for (auto field = fragment.begin(); field != fragment.end(); ++field) {
        if (field.key() == "PBZGameSystem") {
            pbz_save::require(field->is_object(), "Invalid player/map game system record");
            if (!record.contains(field.key())) record[field.key()] = Json::object();
            auto& target = record[field.key()];
            for (auto item = field->begin(); item != field->end(); ++item) {
                pbz_save::require(!target.contains(item.key()), "Overlapping game system fields");
                target[item.key()] = *item;
            }
        } else {
            pbz_save::require(!record.contains(field.key()), "Overlapping player/map fragments");
            record[field.key()] = *field;
        }
    }
}

inline Json compose(const PreparedPresets& presets, const std::wstring& slot, int cycle) {
    pbz_save::require(is_checkpoint_slot(slot) && is_player_cycle(cycle), "Invalid checkpoint or player cycle");
    auto record = presets.shared;
    merge_fragment(record, presets.maps.at(pbz_save::utf8(slot)));
    merge_fragment(record, presets.players.at(std::to_string(cycle)));
    pbz_save::require(record.at("PBZGameSystem").at("CycleCount") == (cycle < 0 ? 0 : cycle),
        "Composed checkpoint cycle does not match the player profile");
    return record;
}

inline bool prepare_bytes(const unsigned char* bytes, std::size_t size, const std::string& expected_sha,
    PreparedPresets& output, std::string& reason) {
    try {
        pbz_save::require(size > 0 && size <= 128ULL * 1024 * 1024, "Checkpoint bundle size is invalid");
        pbz_save::require(expected_sha.size() == 64 && pbz_save::sha256(bytes, size) == expected_sha,
            "Checkpoint bundle fingerprint differs");
        std::vector<std::set<std::string>> keys;
        const auto callback = [&](int depth, Json::parse_event_t event, Json& item) {
            pbz_save::require(depth <= 128, "Checkpoint bundle nesting is too deep");
            if (event == Json::parse_event_t::object_start) keys.emplace_back();
            else if (event == Json::parse_event_t::object_end) keys.pop_back();
            else if (event == Json::parse_event_t::key) {
                pbz_save::require(keys.back().insert(item.get<std::string>()).second,
                    "Checkpoint bundle contains duplicate keys");
            }
            return true;
        };
        auto root = Json::parse(bytes, bytes + size, callback);
        pbz_save::require(root.is_object() && root.size() == 5 && root.at("schemaVersion") == 2
            && root.at("slotCapacity") == slot_capacity, "Checkpoint bundle layout differs");
        PreparedPresets presets{
            std::move(root.at("shared")), std::move(root.at("maps")), std::move(root.at("players"))};
        pbz_save::require(presets.shared.is_object() && presets.maps.is_object() && !presets.maps.empty()
            && presets.maps.size() <= slot_capacity && presets.players.is_object() && presets.players.size() == 8,
            "Checkpoint or player profile count is invalid");
        for (auto map = presets.maps.begin(); map != presets.maps.end(); ++map) {
            const std::wstring name(map.key().begin(), map.key().end());
            pbz_save::require(is_checkpoint_slot(name) && map->is_object()
                && map->at("PBZGameSystem").at("CurrentLevelName").is_string(),
                "Invalid map checkpoint");
        }
        for (int cycle = -1; cycle <= 6; ++cycle) {
            const auto& profile = presets.players.at(std::to_string(cycle));
            pbz_save::require(profile.is_object() && profile.at("Inventory").is_object()
                && profile.at("AbilityNode_RenewalHun").is_object()
                && profile.at("PBZGameSystem").at("CycleCount") == (cycle < 0 ? 0 : cycle),
                "Invalid player profile");
        }
        output = std::move(presets);
        return true;
    } catch (const std::exception& failure) {
        output = {};
        reason = std::string("Checkpoint bundle rejected: ") + failure.what();
        return false;
    }
}

inline bool prepare_file(const std::wstring& module_path, const std::string& expected_sha,
    PreparedPresets& output, std::string& reason) {
    try {
        const auto module_directory = pbz_save::parent_path(pbz_save::full_path(module_path));
        // Resolve game-directory links here. The preset itself still has to be an ordinary file.
        std::error_code error;
        const auto directory = std::filesystem::canonical(module_directory, error);
        if (error) {
            throw std::runtime_error("Resolve checkpoint preset directory (Win32=" + std::to_string(error.value()) + ")");
        }
        const auto preset_path = directory / L"StockArenaPresets.json";
        const pbz_save::ReadOnlyFile input(preset_path.native(), 128ULL * 1024 * 1024);
        return prepare_bytes(input.data(), input.size(), expected_sha, output, reason);
    } catch (const std::exception& failure) {
        output = {};
        reason = std::string("Could not read the adjacent StockArenaPresets.json: ") + failure.what();
        return false;
    }
}

inline bool select_preset(const PreparedPresets& presets, const std::wstring& slot, int cycle,
    SelectedPreset& output, std::string& reason) {
    try {
        auto data = Json::object();
        data[pbz_save::utf8(slot)] = compose(presets, slot, cycle);
        const auto bytes = data.dump();
        const auto size = static_cast<int>(bytes.size());
        const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, bytes.data(), size, nullptr, 0);
        pbz_save::require(length > 0, "Composed checkpoint is not valid UTF-8");
        std::wstring text(static_cast<std::size_t>(length), L'\0');
        pbz_save::require(MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
            bytes.data(), size, text.data(), length) == length, "Composed checkpoint UTF-16 conversion failed");
        output = {slot, std::move(text)};
        return true;
    } catch (const std::exception& failure) {
        output = {};
        reason = std::string("Checkpoint composition failed: ") + failure.what();
        return false;
    }
}
} // namespace pbz_dropin
