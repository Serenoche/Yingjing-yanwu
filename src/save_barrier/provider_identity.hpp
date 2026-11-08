#pragma once
#include "summary_cache.hpp"
#include <array>

// Pinned PBZSaveGameSystem cache. This reader never calls the lazy cache getter,
// root initializer, account migration, path constructor, or any game UObject.
namespace pbz_provider {
constexpr std::uint32_t cache_rva = 0x0E013440;
constexpr std::uint32_t platform_global_rva = 0x0DFBB3B0;
constexpr std::uint32_t platform_vtable_rva = 0x0B552080;
constexpr std::uint32_t windows_vtable_rva = 0x0B4EFFA0;
constexpr std::uint32_t windows_getter_rva = 0x047B7490;
constexpr std::uint32_t windows_provider_rva = 0x0DFEAA60;
constexpr std::uint32_t windows_loaded_rva = 0x0DFEAA68;
constexpr std::uint32_t save_object_rva = 0x0DB242F0;
constexpr std::uint32_t save_vtable_rva = 0x0B54FB80;
struct FString { std::uintptr_t data; std::int32_t number, capacity; };
struct Array { std::uintptr_t data; std::int32_t number, capacity; };
static_assert(sizeof(FString)==16 && sizeof(Array)==16,"pinned native string/array layout");
using Header = std::array<unsigned char,0x98>; // cache + 0x28 .. 0xBF; excludes CRITICAL_SECTION.
inline bool span(std::uintptr_t start,std::size_t size) {
    return start>=0x10000 && start<=0x00007FFFFFFFFFFF && size<=0x00007FFFFFFFFFFF-start;
}
struct Snapshot {
    Header header{};
    std::wstring root, public_root, scope, override_directory;
    std::vector<std::wstring> public_slots;
};
template<typename T> T field(const Header& header, std::size_t offset) {
    T value{}; std::memcpy(&value,header.data()+offset-0x28,sizeof(value)); return value;
}
template<typename Read> bool string_copy(const void* address, std::wstring& output, Read read, std::string& reason) {
    FString value{};
    if (!read(address,&value,sizeof(value)) || value.number<0 || value.number>4097
        || value.capacity<value.number || value.capacity>32768
        || (value.capacity && (!span(value.data,static_cast<std::size_t>(value.number)*2) || value.data%2))) {
        reason="invalid native provider string"; return false;
    }
    output.clear();
    if (!value.number) return true;
    std::vector<wchar_t> data(static_cast<std::size_t>(value.number));
    if (!read(reinterpret_cast<const void*>(value.data),data.data(),data.size()*sizeof(wchar_t))
        || data.back()!=0 || std::find(data.begin(),data.end()-1,L'\0')!=data.end()-1) {
        reason="unreadable or unterminated provider string"; return false;
    }
    output.assign(data.data(),data.size()-1); return true;
}
template<typename Read> bool snapshot_once(const void* cache, Snapshot& out, Read read, std::string& reason) {
    auto bytes=static_cast<const unsigned char*>(cache);
    if (!read(bytes+0x28,out.header.data(),out.header.size()) || out.header[2]!=1 || out.header[3]!=1) {
        reason="native provider cache is not initialized"; return false;
    }
    if (!string_copy(bytes+0x30,out.root,read,reason)
        || !string_copy(bytes+0x40,out.public_root,read,reason)
        || !string_copy(bytes+0x70,out.scope,read,reason)
        || !string_copy(bytes+0x80,out.override_directory,read,reason)) return false;
    const auto slots=field<Array>(out.header,0x50);
    if (slots.number<0 || slots.number>256 || slots.capacity<slots.number || slots.capacity>1024
        || (slots.capacity && (!span(slots.data,static_cast<std::size_t>(slots.number)*16) || slots.data%8))) {
        reason="invalid native public-slot registry"; return false;
    }
    out.public_slots.clear();
    for (std::int32_t i=0;i<slots.number;++i) {
        std::wstring slot;
        if (!string_copy(reinterpret_cast<const void*>(slots.data+static_cast<std::size_t>(i)*16),slot,read,reason)) return false;
        out.public_slots.push_back(std::move(slot));
    }
    Header after{};
    if (!read(bytes+0x28,after.data(),after.size()) || after!=out.header) {
        reason="native provider changed during header copy"; return false;
    }
    return true;
}
inline bool same(const Snapshot& a,const Snapshot& b) {
    return a.header==b.header && a.root==b.root && a.public_root==b.public_root && a.scope==b.scope
        && a.override_directory==b.override_directory && a.public_slots==b.public_slots;
}
inline bool normalize(std::wstring value,bool absolute,std::wstring& output,std::string& reason) {
    std::replace(value.begin(),value.end(),L'\\',L'/');
    const bool drive=value.size()>=3 && ((value[0]>=L'A'&&value[0]<=L'Z')||(value[0]>=L'a'&&value[0]<=L'z'))
        && value[1]==L':' && value[2]==L'/';
    if ((absolute && !drive) || (!absolute && (drive || (!value.empty()&&value[0]==L'/')))) {
        reason="provider path is not an unambiguous local drive path"; return false;
    }
    output=absolute?value.substr(0,3):L"";
    std::size_t offset=absolute?3:0;
    while (offset<value.size()) {
        const auto end=value.find(L'/',offset);
        const auto part=value.substr(offset,end==std::wstring::npos?value.size()-offset:end-offset);
        if (part==L"." || part==L"..") { reason="relative provider path component"; return false; }
        for (const wchar_t c:part) if (c<32 || c==L':' || c==L'<' || c==L'>' || c==L'"'
            || c==L'|' || c==L'?' || c==L'*') { reason="invalid provider path character"; return false; }
        if (!part.empty()) { if (!output.empty()&&output.back()!=L'/') output+=L'/'; output+=part; }
        if (end==std::wstring::npos) break;
        offset=end+1;
    }
    if (absolute&&output.size()<3) { reason="empty provider root"; return false; }
    return true;
}
inline bool path_from(const Snapshot& value,std::string& output,std::string& reason) {
    bool public_master=false;
    for (const auto& slot:value.public_slots) {
        if (CompareStringOrdinal(slot.c_str(),static_cast<int>(slot.size()),L"PBZSaveGame",11,TRUE)==CSTR_EQUAL) public_master=true;
    }
    std::wstring directory,scope;
    if (public_master) {
        if (!normalize(value.public_root,true,directory,reason)) return false;
    } else if (!value.override_directory.empty()) {
        if (!normalize(value.override_directory,true,directory,reason)) return false;
    } else {
        if (!normalize(value.root,true,directory,reason) || !normalize(value.scope,false,scope,reason)) return false;
        if (!scope.empty()) { if (directory.back()!=L'/') directory+=L'/'; directory+=scope; }
    }
    if (directory.back()!=L'/') directory+=L'/';
    directory+=L"PBZSaveGame.sav";
    const auto length=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,directory.data(),static_cast<int>(directory.size()),nullptr,0,nullptr,nullptr);
    if (length<=0 || length>4096) { reason="provider path has invalid or oversized UTF-8"; return false; }
    output.resize(static_cast<std::size_t>(length));
    return WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,directory.data(),static_cast<int>(directory.size()),output.data(),length,nullptr,nullptr)==length;
}
template<typename Read> bool copy_path(const void* cache,Read read,std::string& path,std::string& reason) {
    Snapshot first,second;
    if (!snapshot_once(cache,first,read,reason) || !snapshot_once(cache,second,read,reason)) return false;
    if (!same(first,second)) { reason="native provider changed during string copy"; return false; }
    return path_from(first,path,reason);
}
inline std::string hex(const std::string& value) {
    constexpr char digits[]="0123456789abcdef";
    std::string out;out.reserve(value.size()*2);
    for (const unsigned char c:value) { out+=digits[c>>4];out+=digits[c&15]; } return out;
}
struct Fingerprint {std::uint32_t rva;std::size_t length;unsigned char bytes[32];};
// Actual module getter -> static SaveGameSystem -> cached GetSaveGamePath.
inline constexpr Fingerprint signatures[]={
    {0x048511D0,8,{0xE9,0x5B,0x95,0xFF,0xFF,0xCC,0xCC,0xCC}},
    {0x0484A730,8,{0x48,0x8D,0x05,0xB9,0x9B,0x2D,0x09,0xC3}},
    {0x04850B20,32,{0x40,0x53,0x48,0x83,0xEC,0x20,0x8B,0x0D,0xC4,0x0D,0x9A,0x09,0x65,0x48,0x8B,0x04,
        0x25,0x58,0x00,0x00,0x00,0xBA,0xEC,0x1B,0x00,0x00,0x48,0x8B,0x04,0xC8,0x8B,0x04}},
    {0x0484B070,32,{0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x74,0x24,0x18,0x55,0x57,0x41,0x54,0x41,0x56,
        0x41,0x57,0x48,0x8D,0x6C,0x24,0xC9,0x48,0x81,0xEC,0xA0,0x00,0x00,0x00,0x4C,0x8B}},
    {0x0484F960,32,{0x40,0x57,0x48,0x83,0xEC,0x70,0x48,0x8B,0xF9,0x33,0xC9,0x83,0xBA,0x88,0x00,0x00,
        0x00,0x01,0x7E,0x15,0x48,0x83,0xEA,0x80,0x48,0x8B,0xCF,0xE8,0xC0,0xC5,0xA2,0xFC}}
};
inline std::string number_hex(std::uintptr_t value) {
    constexpr char digits[]="0123456789ABCDEF";std::string out(16,'0');
    for(std::size_t i=0;i<16;++i){out[15-i]=digits[value&15];value>>=4;}return out;
}
inline std::string pointer_diagnostic(const char* name,void* value,unsigned char* base) {
    const auto address=reinterpret_cast<std::uintptr_t>(value),image=reinterpret_cast<std::uintptr_t>(base);
    return std::string(";")+name+"="+number_hex(address)+";"+name+"Rva="
        +(address>=image&&address-image<0x1E0BB000?number_hex(address-image):"external-or-null");
}
template<typename Read> bool signature_matches(unsigned char* base,const Fingerprint& check,Read read,std::string* diagnostic) {
    unsigned char current[32]{};const bool readable=read(base+check.rva,current,check.length);
    if(readable&&!std::memcmp(current,check.bytes,check.length))return true;
    if(diagnostic)*diagnostic+=";providerStage=signature;providerSigRva="+number_hex(check.rva)
        +";providerSigReadable="+(readable?"1":"0")+";providerSigExpected="
        +hex(std::string(reinterpret_cast<const char*>(check.bytes),check.length))+";providerSigActual="
        +(readable?hex(std::string(reinterpret_cast<const char*>(current),check.length)):"unreadable");
    return false;
}
inline bool fingerprints(unsigned char* base,std::string* diagnostic=nullptr) {
    const auto read=[](const void* a,void* b,std::size_t n){return pbz_barrier::read_bytes(a,b,n);};
    for(const auto& check:signatures) {
        if(!signature_matches(base,check,read,diagnostic))return false;
    }
    return true;
}
inline constexpr Fingerprint windows_signature={windows_getter_rva,32,{
    0x40,0x57,0x48,0x83,0xEC,0x40,0x48,0x8B,0x05,0xC3,0x35,0x83,0x09,0x48,0x8B,0xF9,
    0x48,0x85,0xC0,0x74,0x0D,0x80,0x3D,0xBC,0x35,0x83,0x09,0x00,0x0F,0x85,0xCC,0x00}};
struct Chain {
    void* platform=nullptr;void* table=nullptr;void* get_save=nullptr;
    void* actual=nullptr;void* save_table=nullptr;void* get_path=nullptr;
    unsigned char loaded=0;bool windows=false;
};
inline bool same(const Chain& a,const Chain& b) {
    return a.platform==b.platform&&a.table==b.table&&a.get_save==b.get_save&&a.actual==b.actual
        &&a.save_table==b.save_table&&a.get_path==b.get_path&&a.loaded==b.loaded&&a.windows==b.windows;
}
inline std::string chain_diagnostic(const Chain& value,unsigned char* base,const char* stage) {
    return std::string(";providerStage=")+stage+";providerRoute="+(value.windows?"windows-cached":"direct-or-unrecognized")
        +pointer_diagnostic("providerModule",value.platform,base)+pointer_diagnostic("providerModuleVtable",value.table,base)
        +pointer_diagnostic("providerGetter",value.get_save,base)+pointer_diagnostic("providerActual",value.actual,base)
        +pointer_diagnostic("providerActualVtable",value.save_table,base)+pointer_diagnostic("providerPathMethod",value.get_path,base)
        +";providerCachedLoaded="+std::to_string(value.loaded);
}
template<typename Read> bool read_chain(unsigned char* base,Read read,Chain& value,std::string* diagnostic=nullptr) {
    auto fail=[&](const char* stage){if(diagnostic)*diagnostic+=chain_diagnostic(value,base,stage);return false;};
    if(!read(base+platform_global_rva,&value.platform,8)||!value.platform)return fail("platform-pointer");
    if(!read(value.platform,&value.table,8)||!value.table)return fail("platform-vtable-unreadable");
    // Safe reads only, even for diagnostics. Never invoke an unrecognized getter.
    if(!read(static_cast<unsigned char*>(value.table)+0x40,&value.get_save,8))return fail("platform-getter-unreadable");
    if(value.table==base+platform_vtable_rva) {
        if(value.get_save!=base+0x048511D0)return fail("direct-getter");
        value.actual=base+save_object_rva;
    } else if(value.table==base+windows_vtable_rva) {
        value.windows=true;
        if(value.get_save!=base+windows_getter_rva)return fail("windows-getter");
        if(!signature_matches(base,windows_signature,read,diagnostic))return false;
        if(!read(base+windows_provider_rva,&value.actual,8)||!read(base+windows_loaded_rva,&value.loaded,1))return fail("windows-cache-unreadable");
        if(value.loaded!=1||!value.actual)return fail("windows-cache-not-ready");
        if(value.actual!=base+save_object_rva)return fail("windows-provider-pointer");
    } else return fail("platform-vtable");
    if(!read(value.actual,&value.save_table,8)||value.save_table!=base+save_vtable_rva)return fail("save-vtable");
    if(!read(static_cast<unsigned char*>(value.save_table)+0x78,&value.get_path,8)
        ||value.get_path!=base+0x0484B070)return fail("save-path-method");
    if(value.windows) {
        void* after=nullptr;unsigned char loaded=0;
        if(!read(base+windows_provider_rva,&after,8)||!read(base+windows_loaded_rva,&loaded,1)
            ||after!=value.actual||loaded!=value.loaded)return fail("windows-cache-changed");
    }
    return true;
}
inline bool provider_chain(unsigned char* base,Chain& value,std::string* diagnostic=nullptr) {
    const auto read=[](const void* a,void* b,std::size_t n){return pbz_barrier::read_bytes(a,b,n);};
    return read_chain(base,read,value,diagnostic);
}
inline std::string inspect(void*,unsigned char* base) {
    const auto read=[](const void* a,void* b,std::size_t n){return pbz_barrier::read_bytes(a,b,n);};
    std::string reason,path,diagnostic;
    auto fail=[&](const char* fallback){return std::string(";providerReady=0;providerReason=")+(reason.empty()?fallback:reason)+diagnostic;};
    unsigned char initialized[4]{};Chain before;
    if(!fingerprints(base,&diagnostic)||!provider_chain(base,before,&diagnostic))return fail("native-provider-chain-mismatch");
    auto cache=base+cache_rva;
    if (!read(cache+0x28,initialized,sizeof(initialized))||initialized[2]!=1||initialized[3]!=1) return fail("cache-not-ready");
    // This is the same already-initialized CRITICAL_SECTION acquired by the
    // original path getter. Try only: never wait, initialize, or run migrations.
    auto lock=reinterpret_cast<CRITICAL_SECTION*>(cache);
    if (!TryEnterCriticalSection(lock)) return fail("cache-lock-busy");
    bool copied=false;
    try { copied=copy_path(cache,read,path,reason); } catch (...) { reason="provider-copy-failed"; }
    LeaveCriticalSection(lock);
    Chain after;
    if (!copied) return fail("provider-copy-failed");
    if(!provider_chain(base,after,&diagnostic)||!same(before,after))return fail("provider-changed-after-copy");
    return ";providerReady=1;providerPathHex="+hex(path)+chain_diagnostic(after,base,"verified");
}
} // namespace pbz_provider
