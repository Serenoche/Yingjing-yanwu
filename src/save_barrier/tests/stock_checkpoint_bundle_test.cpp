#include "stock_profiles.hpp"
#include <cstdio>

int wmain(int argc, wchar_t** argv) {
    if (argc != 3) return 2;
    try {
        const auto path = pbz_save::full_path(argv[1]);
        const auto adjacent_module = pbz_save::parent_path(path) + L"\\PBZSaveBarrier.dll";
        pbz_dropin::PreparedPresets presets;
        std::string reason;
        if (!pbz_dropin::prepare_file(adjacent_module, pbz_save::utf8(argv[2]), presets, reason)) {
            throw std::runtime_error(reason);
        }
        pbz_save::require(presets.maps.size() == 52, "Expected the 52-map checkpoint bundle");
        unsigned tested = 0;
        for (const auto& entry : presets.maps.items()) {
            const std::wstring slot(entry.key().begin(), entry.key().end());
            for (int cycle = -1; cycle <= 6; ++cycle) {
                pbz_dropin::SelectedPreset plain, customized;
                if (!pbz_dropin::select_preset(presets, slot, cycle, plain, reason)
                    || !pbz_dropin::select_preset(presets, slot, cycle, customized, reason, "custom1,45,2,4,5")) {
                    throw std::runtime_error(reason);
                }
                const auto original = pbz_dropin::Json::parse(pbz_save::utf8(plain.text));
                auto projected = pbz_dropin::Json::parse(pbz_save::utf8(customized.text));
                auto& inventory = projected.at(entry.key()).at("Inventory");
                for (const auto& weapon : inventory.at("MainWeaponInfos")) {
                    pbz_save::require(weapon.at("WeaponLevel") == 45, "Custom weapon level mismatch");
                }
                inventory = original.at(entry.key()).at("Inventory");
                pbz_save::require(projected == original, "Custom settings changed non-inventory checkpoint data");
                ++tested;
            }
        }
        std::printf("PASS %u pinned checkpoint and custom player combinations\n", tested);
        return 0;
    } catch (const std::exception& failure) {
        std::fprintf(stderr, "%s\n", failure.what());
        return 1;
    }
}
