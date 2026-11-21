#pragma once

#include <array>
#include <string>
#include <string_view>
#include "vendor/json.hpp"

namespace pbz_dropin {

// This input only selects slots from the already-owned inventory of the
// destination preset. All amounts, levels, stats and world data stay in it.
inline bool project_equipment(nlohmann::ordered_json& record, std::string_view wire) {
    std::array<std::string, 12> ids;
    for (std::size_t index = 0; index < ids.size(); ++index) {
        const auto end = wire.find('\t');
        if ((end == std::string_view::npos) != (index + 1 == ids.size())) return false;
        const auto field = wire.substr(0, end);
        if (field.empty() || field.size() > 160 ||
            field.find_first_not_of("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-") != std::string_view::npos) return false;
        ids[index].assign(field);
        if (end != std::string_view::npos) wire.remove_prefix(end + 1);
    }

    constexpr std::string_view empty = "None";
    if (ids[0] == empty && ids[1] == empty) return false;
    const auto& source = record.at("Inventory");
    const auto verify = [&](const char* owned, std::size_t start, std::size_t count) {
        const auto& inventory = source.at(owned);
        if (!inventory.is_object()) return false;
        for (std::size_t at = start; at < start + count; ++at) {
            const auto& item = ids[at];
            if (item == empty) continue;
            if (!inventory.contains(item)) return false;
            for (std::size_t earlier = start; earlier < at; ++earlier) {
                if (ids[earlier] == item) return false;
            }
        }
        return true;
    };
    // These two shadow weapons are deliberately unavailable in this runtime.
    for (std::size_t index = 2; index < 4; ++index) {
        if (ids[index] == "BaWangLianQiu" || ids[index] == "MoShou") return false;
    }
    if (!verify("MainWeaponInfos", 0, 2) || !verify("ShaChiWeaponInfo", 2, 2) ||
        !verify("AccessoryInfos", 4, 6) || !verify("MedicineInfos", 10, 2)) return false;

    const auto active = [&](const char* field, std::size_t start) {
        const auto preferred = source.at(field).get<int>();
        if (preferred >= 0 && preferred < 2 && ids[start + static_cast<std::size_t>(preferred)] != empty) return preferred;
        return ids[start] == empty && ids[start + 1] != empty ? 1 : 0;
    };
    const auto main_index = active("CurrentWeaponIndex", 0);
    const auto shadow_index = active("CurrentShaqiWeaponIndex", 2);
    auto& inventory = record.at("Inventory");
    inventory["MainWeapons"] = {ids[0], ids[1]};
    inventory["ShaqiWeapons"] = {ids[2], ids[3]};
    inventory["AccessoryIDs"] = {ids[4], ids[5], ids[6], ids[7], ids[8], ids[9]};
    inventory["TopMedicine"] = ids[10];
    inventory["BottomMedicine"] = ids[11];
    inventory["CurrentWeaponIndex"] = main_index;
    inventory["CurrentMainWeaponID"] = ids[static_cast<std::size_t>(main_index)];
    inventory["CurrentShaqiWeaponIndex"] = shadow_index;
    return true;
}

} // namespace pbz_dropin
