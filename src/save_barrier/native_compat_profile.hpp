#pragma once
#include "native_compat.hpp"

// Generated metadata only. No game code bytes or save-key material.
// Regenerate using work/pbz_test_scene/multiversion_compat_internal/generate_try_compat_profile.py.
namespace pbz_compat_profile {
inline constexpr const char* reference_sha256="4415933ce33476f14c837abb61a1b60af8b78cd81783896501913a7aac69e423";
inline constexpr pbz_compat::Window mandatory[]={
    {"JsonSaveToDisk",0x06B6F150,512,pbz_compat::Kind::code,"b5d91851eea83d559dc3c67c7c9291be1e7c6f021becab89ccc8a3def36639f5",nullptr,0},
    {"SyncAdvancedToMaster",0x06B710B0,512,pbz_compat::Kind::code,"915ed78587a33fb1085e7b5dd9787761d13f3aea8f739845c99d3652aac8d2d6",nullptr,0},
    {"WriteMasterToDisk",0x06B730B0,512,pbz_compat::Kind::code,"3c8baabf49f2c04a41c1701fdee1bc4918e71dbbe309cdfec2bfa0b271ea711c",nullptr,0},
    {"NativeFree",0x012E0AF0,256,pbz_compat::Kind::code,"68a70c13d43daecccc9e9e9ff2e115e6e4b1e4e6718f75a13e3213e2b33be2d6",nullptr,0},
    {"LoadAdvanced",0x06B66760,512,pbz_compat::Kind::code,"fe8266ab324d544d1e0a1b0539ddfd63af18f1f08a0a9bd8989dd979c79ed831",nullptr,0},
    {"WrapperConstructor",0x024D2AA0,256,pbz_compat::Kind::code,"7ee6bbf164dc1673d7df16e7eac3552505a933539458ff5cae119c3b9b10b379",nullptr,0},
    {"CopyJson",0x06B5E620,512,pbz_compat::Kind::code,"fc6a6813a89ebfdd84be893fe5c8890de9ed78aa6100afdebc13702d1e6fe564",nullptr,0},
    {"ReleaseShared",0x0126EC80,256,pbz_compat::Kind::code,"84b2939371a49e1cf458e257a45e5a43b2c179b25af2e49608b76409d4b6a1a5",nullptr,0},
    {"RemoveSummary",0x06B6CAC0,512,pbz_compat::Kind::code,"3f68d343609e90b7ccfa39b87e277c94b23ec47291673c5ff6ea3ae83cccc986",nullptr,0},
    {"ProviderGetterThunk",0x048511D0,8,pbz_compat::Kind::code,"013eddd068ed9f714df2a0529b26e4da995f05627b1e1cad05195b34cc3eb769",nullptr,0},
    {"ProviderStaticObjectThunk",0x0484A730,8,pbz_compat::Kind::code,"8c6ba686d196624519770f3d1507970be99ae129d5b7fd7040b049f4262312cb",nullptr,0},
    {"ProviderCacheGetter",0x04850B20,512,pbz_compat::Kind::code,"3b434e2b427d93dc83df347db950e56c7db77cc55534eeaca35bc60d08950e74",nullptr,0},
    {"ProviderGetPath",0x0484B070,512,pbz_compat::Kind::code,"1a78b54fea1933aadabefdf673e6324660a5b80beb36e0a21397451230825ab2",nullptr,0},
    {"ProviderEffectiveDirectory",0x0484F960,512,pbz_compat::Kind::code,"066f5a561c9adb4a986275e7797a1a90540b500b7ac69949dfe445d793f1655c",nullptr,0},
    {"WindowsProviderGetter",0x047B7490,256,pbz_compat::Kind::code,"2f54f4f994ea1208861dbf6a9533c0b6f199f52993c72d66be56d4a248491517",nullptr,0},
    {"ProviderDirectGetterSlot",0x0B5520C0,8,pbz_compat::Kind::constant_data,"099e3ed63aa16946210414f543999f84c0ca722f3f12643293ab16fa2a4fb816",nullptr,0},
    {"ProviderWindowsGetterSlot",0x0B4EFFE0,8,pbz_compat::Kind::constant_data,"9ae75f0f162d56a541a187c9ee23359501c57782da4286f95c3c196ff7824b68",nullptr,0},
    {"ProviderSavePathSlot",0x0B54FBF8,8,pbz_compat::Kind::constant_data,"f2bb9e0f1d87cbd46262ef36a067ff0d826efc3956750e7f68f85738cee9a4bd",nullptr,0},
};
inline constexpr pbz_compat::Window eligibility[]={
    {"EligibilityCanSave",0x06B5D750,512,pbz_compat::Kind::code,"7b2f37799676df053109027a0771a1848909a009c95e9f1f65ad0c668b96cecf",nullptr,0},
    {"EligibilityExecute",0x065C9E60,512,pbz_compat::Kind::code,"c68e66c9c0e2fe24e80f65cb46df1a489f2367f8f210bf71e3d711302c483d6f",nullptr,0},
    {"EligibilityGetter",0x065C8910,512,pbz_compat::Kind::code,"8ac8e8d04bcd2c38cd57f5ec702c17d64f7a247d15c19bba7d41332474a304d4",nullptr,0},
    {"EligibilityImplements",0x0153C140,256,pbz_compat::Kind::code,"836e7430f32339e7ef9db9a16e5a1c1e174062e4a16a48cc15e6140fbcd59ed2",nullptr,0},
};
inline constexpr pbz_compat::Span provider_spans[]={
    {"ProviderCacheRange",0x0E013440,192,pbz_compat::Kind::mutable_data},
    {"ProviderPlatformPointer",0x0DFBB3B0,8,pbz_compat::Kind::mutable_data},
    {"ProviderWindowsCache",0x0DFEAA60,16,pbz_compat::Kind::mutable_data},
    {"ProviderSaveObject",0x0DB242F0,8,pbz_compat::Kind::mutable_data},
};
} // namespace pbz_compat_profile
