#pragma once
#include "patch_transaction.hpp"
#include <bcrypt.h>
#include <algorithm>
#include <array>
#include <iterator>
#include <limits>
#pragma comment(lib,"bcrypt.lib")

// Compare the native interfaces actually used by the companion. A whole-file
// version, linker timestamp or image extent is not an admission allowlist.
namespace pbz_compat {
enum class Kind { code, constant_data, mutable_data };
struct Section { std::uint32_t rva, size, flags; };
struct Image {
    std::uintptr_t base=0;
    std::uint64_t preferred_base=0;
    std::uint32_t size=0, timestamp=0;
    std::vector<Section> sections;
};
struct Region {
    std::uintptr_t base=0, size=0, allocation_base=0;
    DWORD state=0, type=0, protection=0;
};
struct Relocation { std::uint32_t offset; std::uint16_t type; };
struct Window {
    const char* name;
    std::uint32_t rva, length;
    Kind kind;
    const char* sha256;
    const Relocation* relocations;
    std::size_t relocation_count;
};
struct Span { const char* name; std::uint32_t rva, length; Kind kind; };

template<typename Read> bool image_headers(std::uintptr_t base,Read read,Image& output) {
    if(!base || base>std::numeric_limits<std::uintptr_t>::max()-1024*1024)return false;
    IMAGE_DOS_HEADER dos{};IMAGE_NT_HEADERS64 nt{};
    if(!read(base,&dos,sizeof(dos)) || dos.e_magic!=IMAGE_DOS_SIGNATURE || dos.e_lfanew<64 || dos.e_lfanew>1024*1024
        || !read(base+static_cast<std::uintptr_t>(dos.e_lfanew),&nt,sizeof(nt))
        || nt.Signature!=IMAGE_NT_SIGNATURE || nt.FileHeader.Machine!=IMAGE_FILE_MACHINE_AMD64
        || nt.FileHeader.SizeOfOptionalHeader!=sizeof(IMAGE_OPTIONAL_HEADER64)
        || nt.OptionalHeader.Magic!=IMAGE_NT_OPTIONAL_HDR64_MAGIC || nt.OptionalHeader.NumberOfRvaAndSizes!=16
        || nt.FileHeader.NumberOfSections<1 || nt.FileHeader.NumberOfSections>96
        || nt.OptionalHeader.SizeOfImage<4096 || nt.OptionalHeader.SizeOfImage>0x80000000u
        || base>std::numeric_limits<std::uintptr_t>::max()-nt.OptionalHeader.SizeOfImage)return false;
    const auto table=static_cast<std::uint32_t>(dos.e_lfanew)+static_cast<std::uint32_t>(sizeof(nt));
    const auto table_size=static_cast<std::uint32_t>(nt.FileHeader.NumberOfSections)*static_cast<std::uint32_t>(sizeof(IMAGE_SECTION_HEADER));
    if(nt.OptionalHeader.SizeOfHeaders<table || table_size>nt.OptionalHeader.SizeOfHeaders-table
        || nt.OptionalHeader.SizeOfHeaders>1024*1024 || nt.OptionalHeader.SizeOfHeaders>nt.OptionalHeader.SizeOfImage)return false;
    std::vector<IMAGE_SECTION_HEADER> headers(nt.FileHeader.NumberOfSections);
    if(!read(base+table,headers.data(),table_size))return false;
    Image image;image.base=base;image.size=nt.OptionalHeader.SizeOfImage;
    image.timestamp=nt.FileHeader.TimeDateStamp;image.preferred_base=nt.OptionalHeader.ImageBase;
    for(const auto& header:headers) {
        const auto extent=(std::max)(header.Misc.VirtualSize,header.SizeOfRawData);
        if(!extent || header.VirtualAddress<nt.OptionalHeader.SizeOfHeaders || header.VirtualAddress>=image.size
            || extent>image.size-header.VirtualAddress)return false;
        for(const auto& previous:image.sections) {
            if(header.VirtualAddress<previous.rva+previous.size && previous.rva<header.VirtualAddress+extent)return false;
        }
        image.sections.push_back({header.VirtualAddress,extent,header.Characteristics});
    }
    output=std::move(image);return true;
}

inline bool bounded(const Image& image,std::uint32_t rva,std::uint32_t length) {
    return length && rva<image.size && length<=image.size-rva
        && image.base<=std::numeric_limits<std::uintptr_t>::max()-image.size;
}
inline bool executable(DWORD protection) {
    const auto value=protection&0xff;
    return value==PAGE_EXECUTE || value==PAGE_EXECUTE_READ || value==PAGE_EXECUTE_READWRITE || value==PAGE_EXECUTE_WRITECOPY;
}
inline bool readable(DWORD protection) {
    const auto value=protection&0xff;
    return value==PAGE_READONLY || value==PAGE_READWRITE || value==PAGE_WRITECOPY
        || value==PAGE_EXECUTE_READ || value==PAGE_EXECUTE_READWRITE || value==PAGE_EXECUTE_WRITECOPY;
}
inline bool section_accepts(const Image& image,std::uint32_t rva,std::uint32_t length,Kind kind) {
    if(!bounded(image,rva,length))return false;
    for(const auto& section:image.sections) {
        if(rva<section.rva || rva-section.rva>=section.size || length>section.size-(rva-section.rva))continue;
        if(kind==Kind::code)return (section.flags&IMAGE_SCN_MEM_EXECUTE)!=0;
        if(!(section.flags&IMAGE_SCN_MEM_READ))return false;
        return kind!=Kind::constant_data || !(section.flags&(IMAGE_SCN_MEM_WRITE|IMAGE_SCN_MEM_EXECUTE));
    }
    return false;
}
template<typename Query> bool mapped_span(const Image& image,std::uint32_t rva,std::uint32_t length,Kind kind,Query query) {
    if(!section_accepts(image,rva,length,kind))return false;
    const auto end=image.base+rva+length;
    for(auto cursor=image.base+rva;cursor<end;) {
        Region region;
        if(!query(cursor,region) || region.base>cursor || !region.size
            || region.size>std::numeric_limits<std::uintptr_t>::max()-region.base
            || cursor>=region.base+region.size || region.state!=MEM_COMMIT || region.type!=MEM_IMAGE
            || region.allocation_base!=image.base || (region.protection&(PAGE_GUARD|PAGE_NOACCESS))
            || (kind==Kind::code?!executable(region.protection):!readable(region.protection)))return false;
        cursor=(std::min)(end,region.base+region.size);
    }
    return true;
}
inline std::string sha256(const unsigned char* bytes,std::size_t length) {
    BCRYPT_ALG_HANDLE algorithm=nullptr;
    BCRYPT_HASH_HANDLE hash=nullptr;
    std::vector<unsigned char> object;
    std::array<unsigned char,32> digest{};
    auto cleanup=[&](){if(hash)BCryptDestroyHash(hash);if(algorithm)BCryptCloseAlgorithmProvider(algorithm,0);};
    if(BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0)<0)return {};
    ULONG object_length=0,written=0;
    if(BCryptGetProperty(algorithm,BCRYPT_OBJECT_LENGTH,reinterpret_cast<PUCHAR>(&object_length),sizeof(object_length),&written,0)<0
        || written!=sizeof(object_length) || !object_length || object_length>1024*1024){cleanup();return {};}
    object.resize(object_length);
    if(BCryptCreateHash(algorithm,&hash,object.data(),object_length,nullptr,0,0)<0
        || length>std::numeric_limits<ULONG>::max()
        || BCryptHashData(hash,const_cast<PUCHAR>(bytes),static_cast<ULONG>(length),0)<0
        || BCryptFinishHash(hash,digest.data(),static_cast<ULONG>(digest.size()),0)<0){cleanup();return {};}
    cleanup();
    constexpr char digits[]="0123456789abcdef";
    std::string output;output.reserve(64);
    for(auto value:digest){output+=digits[value>>4];output+=digits[value&15];}
    return output;
}
inline bool normalize_relocations(const Image& image,const Window& window,std::vector<unsigned char>& bytes) {
    const auto delta=static_cast<std::uint64_t>(image.base)-image.preferred_base;
    for(std::size_t i=0;i<window.relocation_count;++i) {
        const auto& relocation=window.relocations[i];
        const std::size_t width=relocation.type==IMAGE_REL_BASED_DIR64?8:relocation.type==IMAGE_REL_BASED_HIGHLOW?4:0;
        if(!width || relocation.offset>bytes.size() || width>bytes.size()-relocation.offset)return false;
        for(std::size_t j=0;j<i;++j) {
            const auto& previous=window.relocations[j];
            const std::size_t previous_width=previous.type==IMAGE_REL_BASED_DIR64?8:4;
            if(relocation.offset<previous.offset+previous_width && previous.offset<relocation.offset+width)return false;
        }
        if(width==8){std::uint64_t value;std::memcpy(&value,bytes.data()+relocation.offset,8);value-=delta;std::memcpy(bytes.data()+relocation.offset,&value,8);}
        else{std::uint32_t value;std::memcpy(&value,bytes.data()+relocation.offset,4);value-=static_cast<std::uint32_t>(delta);std::memcpy(bytes.data()+relocation.offset,&value,4);}
    }
    return true;
}
template<typename Read,typename Query> bool verify(const Image& image,const Window* windows,std::size_t count,
    const Span* spans,std::size_t span_count,Read read,Query query,std::string& reason) {
    auto fail=[&](const char* symbol){reason=std::string("native-runtime-incompatible:")+symbol;return false;};
    for(std::size_t i=0;i<count;++i) {
        const auto& window=windows[i];
        if(!window.length || window.length>4096 || !mapped_span(image,window.rva,window.length,window.kind,query))return fail(window.name);
        std::vector<unsigned char> bytes(window.length);
        if(!read(image.base+window.rva,bytes.data(),bytes.size()) || !normalize_relocations(image,window,bytes))return fail(window.name);
        const auto hash=sha256(bytes.data(),bytes.size());
        if(hash.empty() || hash!=window.sha256)return fail(window.name);
    }
    for(std::size_t i=0;i<span_count;++i) {
        const auto& span=spans[i];
        if(span.length>4096 || !mapped_span(image,span.rva,span.length,span.kind,query))return fail(span.name);
        // Prove the complete mutable provider span is readable without touching
        // locks or relying on its runtime-dependent contents as a fingerprint.
        std::vector<unsigned char> bytes(span.length);
        if(!read(image.base+span.rva,bytes.data(),bytes.size()))return fail(span.name);
    }
    return true;
}
struct VerifiedIdentity {
    std::uintptr_t base=0;std::uint64_t preferred_base=0;std::uint32_t size=0,timestamp=0;
    bool matches(const Image& image)const{return base && base==image.base && preferred_base==image.preferred_base && size==image.size && timestamp==image.timestamp;}
    void remember(const Image& image){base=image.base;preferred_base=image.preferred_base;size=image.size;timestamp=image.timestamp;}
};
template<typename Read,typename Query,typename OwnPatchProof> bool admit(const Image& image,
    const Window* windows,std::size_t count,const Span* spans,std::size_t span_count,
    VerifiedIdentity& verified,bool armed,OwnPatchProof owned_patches,Read read,Query query,std::string& reason) {
    if(armed && verified.matches(image)) {
        if(!owned_patches()){reason="native-runtime-incompatible:OwnedPatchState";return false;}
        return true;
    }
    if(!verify(image,windows,count,spans,span_count,read,query,reason))return false;
    verified.remember(image);return true;
}
} // namespace pbz_compat
