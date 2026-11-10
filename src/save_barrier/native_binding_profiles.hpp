#pragma once
#include "native_compat_profile.hpp"
#include "native_legacy_301524.hpp"
#include "provider_identity.hpp"

namespace pbz_bindings {
struct Profile {
    const char* id;
    const pbz_compat::Window* windows;std::size_t window_count;
    const pbz_compat::Span* spans;std::size_t span_count;
    std::uint32_t json_rva,sync_rva,write_rva;
    std::uint32_t free_rva,advanced_rva,constructor_rva,copy_rva,release_rva,remove_rva,parser_rva;
    pbz_provider::Layout provider;
    bool reference_eligibility;
};
inline const Profile reference={
    "reference-302256",pbz_compat_profile::mandatory,std::size(pbz_compat_profile::mandatory),
    pbz_compat_profile::provider_spans,std::size(pbz_compat_profile::provider_spans),
    0x06B6F150,0x06B710B0,0x06B730B0,0x012E0AF0,0x06B66760,0x024D2AA0,
    0x06B5E620,0x0126EC80,0x06B6CAC0,0,pbz_provider::default_layout,true
};
inline const Profile legacy=[](){
    pbz_provider::Layout provider;
    provider.cache_rva=0x0DF9E370;provider.platform_global_rva=0x0DF46340;
    provider.platform_vtable_rva=0;provider.windows_vtable_rva=0;
    provider.windows_getter_rva=0x04794490;provider.windows_provider_rva=0x0DF759B0;
    provider.windows_loaded_rva=0x0DF759B8;
    provider.save_object_rva=0;provider.save_vtable_rva=0;provider.direct_getter_rva=0;
    provider.static_object_thunk_rva=0;provider.cache_getter_rva=0x04826820;
    provider.path_getter_rva=0x04820DA0;provider.effective_directory_rva=0;
    provider.discover_tables_from_getters=true;provider.read_only_cache_snapshots=true;
    provider.allow_heap_cached_provider=true;
    return Profile{"legacy-301524",pbz_legacy_301524::mandatory,std::size(pbz_legacy_301524::mandatory),
        pbz_legacy_301524::provider_spans,std::size(pbz_legacy_301524::provider_spans),
        0x06B28570,0x06B2A4D0,0x06B2C4D0,0x012E1930,0x06B1FB80,0,
        0x06B17A20,0x0126FC00,0x06B25EE0,0x024D8550,provider,false};
}();

// Selection is based on the actual interfaces, never a version/whole-file hash.
// Once armed, retain the exact admitted profile and prove our own entry patches.
template<typename Read,typename Query,typename OwnPatchProof>
bool select(const pbz_compat::Image& image,const Profile*& active,pbz_compat::VerifiedIdentity& verified,
    bool armed,OwnPatchProof owned_patches,Read read,Query query,std::string& reason) {
    if(armed) {
        if(!active || !verified.matches(image)){reason="native-runtime-incompatible:ArmedImageIdentity";return false;}
        return pbz_compat::admit(image,active->windows,active->window_count,active->spans,active->span_count,
            verified,true,owned_patches,read,query,reason);
    }
    active=nullptr;
    const Profile* profiles[]={&reference,&legacy};
    for(const auto* profile:profiles) {
        if(pbz_compat::admit(image,profile->windows,profile->window_count,profile->spans,profile->span_count,
            verified,false,owned_patches,read,query,reason)) {
            active=profile;reason.clear();return true;
        }
    }
    return false;
}
inline pbz_provider::Layout admitted_provider(const Profile& profile,std::uint32_t image_size) {
    auto layout=profile.provider;layout.image_size=image_size;layout.caller_verified_code=true;return layout;
}
} // namespace pbz_bindings
