#pragma once

#include <algorithm>
#include <array>
#include <charconv>
#include <string_view>
#include "custom_player_catalog.hpp"

namespace pbz_dropin {

inline bool custom_prefix(std::string_view wire) {
    return wire.substr(0, 8) == "custom1,";
}

inline bool same_item(std::string_view left, std::string_view right) {
    if (left.size() != right.size()) return false;
    const auto lower = [](char c) { return c >= 'A' && c <= 'Z' ? static_cast<char>(c - 'A' + 'a') : c; };
    return std::equal(left.begin(), left.end(), right.begin(), [&](char a, char b) { return lower(a) == lower(b); });
}

inline void project_custom_player(nlohmann::ordered_json& record, std::string_view& wire) {
    if (!custom_prefix(wire)) return;
    const auto end = wire.find('\t');
    auto values = wire.substr(8, end == std::string_view::npos ? end : end - 8);
    wire = end == std::string_view::npos ? std::string_view{} : wire.substr(end + 1);
    std::array<int, 4> settings{};
    constexpr std::array<int, 4> limits{60, 6, 6, 7};
    for (std::size_t i = 0; i < settings.size(); ++i) {
        const auto sep = values.find(',');
        const auto field = values.substr(0, sep);
        const auto result = std::from_chars(field.data(), field.data() + field.size(), settings[i]);
        pbz_save::require(!field.empty() && result.ec == std::errc{} && result.ptr == field.data() + field.size() &&
            (sep == std::string_view::npos) == (i + 1 == settings.size()) &&
            settings[i] >= (i == 3 ? 0 : -1) && settings[i] <= limits[i], "Invalid custom player checkpoint settings");
        if (sep != std::string_view::npos) values.remove_prefix(sep + 1);
    }

    auto& inventory = record.at("Inventory");
    if (settings[0] >= 0) {
        const int level = std::max(1, settings[0]);
        const int required_rank = std::max(0, (level - 30 + 4) / 5);
        const auto project_weapons = [&](const char* items, const char* field) {
            for (auto& weapon : inventory.at(items)) {
                weapon.at(field) = level;
                weapon.at("ReincarnationCount") = std::max(required_rank, weapon.at("ReincarnationCount").get<int>());
            }
        };
        project_weapons("MainWeaponInfos", "WeaponLevel");
        project_weapons("ShaChiWeaponInfo", "ShaChiWeaponLevel");
    }
    if (settings[1] >= 0) {
        for (auto& medicine : inventory.at("MedicineInfos").items()) {
            const auto limits_for_item = std::find_if(custom_medicines.begin(), custom_medicines.end(),
                [&](const auto& item) { return same_item(medicine.key(), item.id); });
            pbz_save::require(limits_for_item != custom_medicines.end(), "Unknown custom medicine");
            const auto uses = limits_for_item->uses[static_cast<std::size_t>(settings[1])];
            auto& item = medicine.value();
            item.at("CurrentLevel") = settings[1];
            item.at("MaxTime") = uses;
            item.at("CurrentTime") = std::min(uses, item.at("CurrentTime").get<int>());
            if (item.contains("DisplayTime")) item.at("DisplayTime") = std::min(uses, item.at("DisplayTime").get<int>());
        }
    }
    if (settings[2] >= 0) {
        for (auto& accessory : inventory.at("AccessoryInfos").items()) {
            const auto limits_for_item = std::find_if(custom_accessories.begin(), custom_accessories.end(),
                [&](const auto& item) { return same_item(accessory.key(), item.id); });
            pbz_save::require(limits_for_item != custom_accessories.end(), "Unknown custom accessory");
            const auto rank = std::min(settings[2], limits_for_item->extra);
            accessory.value().at("CurrentLevel") = limits_for_item->base + rank;
            accessory.value().at("ReincarnationCount") = rank;
        }
    }

    // These contributions are replaced by the selected percentages in Lua.
    // Leave every unrelated item and the original master alone.
    const auto removed = settings[3];
    if (removed) {
        auto& items = inventory.at("InventoryInfos");
        if (removed & 1) { items.erase("Item_001"); items.erase("Item_Piece_001"); }
        if (removed & 2) { items.erase("Item_002"); items.erase("Item_Piece_002"); }
        if (removed & 4) {
            for (auto it = items.begin(); it != items.end();) {
                const std::string_view id(it.key());
                if (id.substr(0, 2) == "F_" || id.substr(0, 3) == "FA_" || id.substr(0, 3) == "FS_") it = items.erase(it);
                else ++it;
            }
        }
    }
}

} // namespace pbz_dropin
