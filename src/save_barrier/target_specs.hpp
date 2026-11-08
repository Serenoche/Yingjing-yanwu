#pragma once
#include <cstdint>

namespace pbz_barrier {
constexpr std::uint32_t pinned_timestamp = 0x6AE7AE3F;
constexpr std::uint32_t pinned_image_size = 0x1E0BB000;
constexpr unsigned char return_false[8] = {0x31, 0xC0, 0xC3, 0x90, 0x90, 0x90, 0x90, 0x90};
constexpr unsigned char return_void[8] = {0xC3, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90};
struct TargetSpec {
    const char* name;
    std::uint32_t rva;
    unsigned char original[8];
    const unsigned char (&replacement)[8];
};

// JsonSave uses a generated rel32 jump to a C++ failure handler: its by-value
// SaveGameParam owns an FString that must be destroyed even on failure.
constexpr unsigned char json_original[8] = {0x40,0x55,0x53,0x56,0x57,0x41,0x54,0x41};
constexpr std::uint32_t json_rva = 0x06B6F150;
// Verified native entrypoints in CL-302256_JKS-17280. The advanced getters
// remain intact; block their central sync helper instead. This is a disposable
// prototype, not proof of full master/cache isolation.
constexpr TargetSpec targets[] = {
    {"SyncAdvancedToMaster", 0x06B710B0, {0x40,0x57,0x48,0x83,0xEC,0x40,0x48,0x83}, return_void},
    {"WriteMasterToDisk", 0x06B730B0, {0x48,0x89,0x5C,0x24,0x18,0x57,0x48,0x83}, return_false},
};
} // namespace pbz_barrier
