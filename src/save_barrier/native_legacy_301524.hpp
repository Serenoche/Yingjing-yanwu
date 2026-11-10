#pragma once
#include "native_compat.hpp"
// Internal old-interface descriptor from bounded client instruction evidence.
// Hash/RVA metadata only; no game code bytes or save-key material.
namespace pbz_legacy_301524 {
inline constexpr pbz_compat::Window mandatory[]={
    {"JsonSaveToDisk",0x06B28570,193,pbz_compat::Kind::code,"7223037680f20f1534a278bb79081ce64e871d458f039b545a6aa56f9112b18a",nullptr,0},
    {"SyncAdvancedToMaster",0x06B2A4D0,197,pbz_compat::Kind::code,"d16a05cc3c7934acf5919a710bbd90a2dd6f4f11e03d5d2bac20947a74fd9be2",nullptr,0},
    {"WriteMasterToDisk",0x06B2C4D0,193,pbz_compat::Kind::code,"b25b562066ad808b661f6f2a8d4142e5ca240ebd06ca9796887bf40bdcd35d8b",nullptr,0},
    {"LoadAdvanced",0x06B1FB80,195,pbz_compat::Kind::code,"ea5c71e9af03e26d40c402764dd4712d847a535fdfaf1e4e76a0fd12340a20b4",nullptr,0},
    {"CopyJson",0x06B17A20,199,pbz_compat::Kind::code,"e53c53eb3fc09cb01a4e2f35d40e4deacb5b3f3a6878d82282c3e36e793050a1",nullptr,0},
    {"ReleaseShared",0x0126FC00,72,pbz_compat::Kind::code,"7defe80d157d1f0179fbe7d61fc1a4ac76d32fd94f4aaaf704eebb855fc4f41b",nullptr,0},
    {"RemoveSummary",0x06B25EE0,194,pbz_compat::Kind::code,"f587222801b568a63f136243e3dd96771a56644e6c6a1000dab75ac24916ae8f",nullptr,0},
    {"JsonObjectFromString",0x024D8550,195,pbz_compat::Kind::code,"74d3e71e1c3731a79456a430268d49e383a4c7c630b7e056833116af19bb5dbc",nullptr,0},
    {"ProviderGetPath",0x04820DA0,196,pbz_compat::Kind::code,"38e35aad53558861a4b039ff1dec13fe8aa00c03963dfe9fb99b1aa868cb335f",nullptr,0},
    {"WindowsProviderGetter",0x04794490,194,pbz_compat::Kind::code,"4f2380c5dcbd1a0775a92b26eda24eee1298d23bf7ae4ad9755db89aaa6fc3c1",nullptr,0},
    {"NativeFree",0x012E1930,52,pbz_compat::Kind::code,"cc4ab265c4b9ea07eb1bbe25ecc0b81d2c0d62a0a0c2d842ed34ecfa55965168",nullptr,0},
    {"ProviderCacheGetter",0x04826820,128,pbz_compat::Kind::code,"f9bd4ed876bde137f9be44459a1ccfca35d8b5afa117f2605750b132e243614f",nullptr,0},
    {"PlatformFeaturesSingletonGetter",0x03F6D3A0,128,pbz_compat::Kind::code,"c5e6c37a6d75ef3070a95ada7e26da97e6106d59b2d31114a726fa390d3b2667",nullptr,0},
    {"ParserReaderFactory",0x014966E0,128,pbz_compat::Kind::code,"71d2be525578f6cf079e45cb689c51fe96346bb67c37a7f63bb42973bd96cf90",nullptr,0},
    {"ParserDeserializer",0x01469E60,128,pbz_compat::Kind::code,"6b9f4bd577a75b573591aa86dbfa41a319759033ef653b8d4b19b62ec20dafd0",nullptr,0},
    {"ParserSharedAssignment",0x0147AB20,65,pbz_compat::Kind::code,"2b23628b05b2d99144e7f46d1eb931c1a679f51d300db38ba2aa26ad3c22220b",nullptr,0},
};
inline constexpr pbz_compat::Span provider_spans[]={
    {"ProviderCacheRange",0x0DF9E370,192,pbz_compat::Kind::mutable_data},
    {"ProviderPlatformPointer",0x0DF46340,8,pbz_compat::Kind::mutable_data},
    {"ProviderWindowsCache",0x0DF759B0,16,pbz_compat::Kind::mutable_data},
};
} // namespace pbz_legacy_301524
