#pragma once
#define NOMINMAX
#include <windows.h>
#include <bcrypt.h>
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>
#pragma comment(lib,"bcrypt.lib")

namespace pbz_save {
using Bytes = std::vector<unsigned char>;
inline void require(bool condition, const char* text) { if (!condition) throw std::runtime_error(text); }
inline void win_check(bool condition, const char* stage) {
    if (!condition) throw std::runtime_error(std::string(stage)+" (Win32="+std::to_string(GetLastError())+")");
}
inline void crypto_check(NTSTATUS status, const char* stage) {
    if (status < 0) throw std::runtime_error(std::string(stage)+" (NTSTATUS="+std::to_string(static_cast<std::uint32_t>(status))+")");
}
struct Handle {
    HANDLE value = INVALID_HANDLE_VALUE;
    Handle() = default;
    explicit Handle(HANDLE handle):value(handle){}
    ~Handle(){if(value && value!=INVALID_HANDLE_VALUE)CloseHandle(value);}
    Handle(const Handle&)=delete;Handle& operator=(const Handle&)=delete;
};
inline std::wstring full_path(const std::wstring& path) {
    require(!path.empty() && path.rfind(L"\\\\",0)!=0,"UNC and device paths are not supported");
    std::vector<wchar_t> buffer(32768);
    const DWORD length=GetFullPathNameW(path.c_str(),static_cast<DWORD>(buffer.size()),buffer.data(),nullptr);
    win_check(length && length<buffer.size(),"Resolve path");
    std::wstring output(buffer.data(),length);
    require(output.size()>3 && output[1]==L':' && output[2]==L'\\',"Expected an absolute local path");
    require(output.find(L':',2)==std::wstring::npos,"NTFS alternate data streams are not supported");
    return output;
}
inline std::wstring parent_path(const std::wstring& path) {
    const auto at=path.find_last_of(L"\\/");
    require(at!=std::wstring::npos && at>=2,"Missing parent directory");
    return path.substr(0,at==2?3:at);
}
inline std::wstring filename(const std::wstring& path) {
    const auto at=path.find_last_of(L"\\/");return path.substr(at==std::wstring::npos?0:at+1);
}
inline bool equal_path(const std::wstring& first,const std::wstring& second) {
    return CompareStringOrdinal(first.c_str(),static_cast<int>(first.size()),second.c_str(),static_cast<int>(second.size()),TRUE)==CSTR_EQUAL;
}
inline void ordinary_path(std::wstring path) {
    for(;;){
        const DWORD attributes=GetFileAttributesW(path.c_str());
        win_check(attributes!=INVALID_FILE_ATTRIBUTES,"Read path attributes");
        require(!(attributes&FILE_ATTRIBUTE_REPARSE_POINT),"Linked paths are not supported");
        if(path.size()<=3)break;
        path=parent_path(path);
    }
}
inline bool below(const std::wstring& root,const std::wstring& path) {
    const auto prefix=root+L"\\";
    return path.size()>prefix.size() && CompareStringOrdinal(path.c_str(),static_cast<int>(prefix.size()),
        prefix.c_str(),static_cast<int>(prefix.size()),TRUE)==CSTR_EQUAL;
}
inline bool exists(const std::wstring& path){return GetFileAttributesW(path.c_str())!=INVALID_FILE_ATTRIBUTES;}
inline std::wstring module_path(){
    std::vector<wchar_t> buffer(32768);const DWORD length=GetModuleFileNameW(nullptr,buffer.data(),static_cast<DWORD>(buffer.size()));
    win_check(length && length<buffer.size(),"Find tool path");return full_path(std::wstring(buffer.data(),length));
}
inline std::string utf8(const std::wstring& text){
    if(text.empty())return{};
    const int size=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,text.data(),static_cast<int>(text.size()),nullptr,0,nullptr,nullptr);
    win_check(size>0,"Encode UTF-8");std::string result(static_cast<std::size_t>(size),'\0');
    win_check(WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,text.data(),static_cast<int>(text.size()),result.data(),size,nullptr,nullptr)==size,"Encode UTF-8");
    return result;
}
inline void valid_utf8(const std::string& text){
    require(!text.empty(),"Empty slot name");
    win_check(MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,text.data(),static_cast<int>(text.size()),nullptr,0)>0,"Validate UTF-8");
}
class ReadOnlyFile {
    Handle handle_,mapping_;const unsigned char* view_=nullptr;std::size_t size_=0;
public:
    std::wstring path;
    explicit ReadOnlyFile(const std::wstring& argument,std::uint64_t limit=512ULL*1024*1024):path(full_path(argument)){
        ordinary_path(path);
        handle_.value=CreateFileW(path.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);
        win_check(handle_.value!=INVALID_HANDLE_VALUE,"Open read-only input");
        BY_HANDLE_FILE_INFORMATION info{};win_check(GetFileInformationByHandle(handle_.value,&info)!=FALSE,"Read input information");
        require(!(info.dwFileAttributes&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_DIRECTORY)),"Expected an ordinary input file");
        LARGE_INTEGER size{};win_check(GetFileSizeEx(handle_.value,&size)!=FALSE,"Read input size");
        require(size.QuadPart>0 && static_cast<std::uint64_t>(size.QuadPart)<=limit,"Input size exceeds supported bounds");
        size_=static_cast<std::size_t>(size.QuadPart);
        mapping_.value=CreateFileMappingW(handle_.value,nullptr,PAGE_READONLY,0,0,nullptr);
        win_check(mapping_.value!=nullptr,"Map read-only input");
        view_=static_cast<const unsigned char*>(MapViewOfFile(mapping_.value,FILE_MAP_READ,0,0,0));
        win_check(view_!=nullptr,"View read-only input");
    }
    ~ReadOnlyFile(){if(view_)UnmapViewOfFile(view_);}
    const unsigned char* data()const{return view_;}std::size_t size()const{return size_;}
    Bytes bytes()const{return Bytes(view_,view_+size_);}
};
inline std::string hex(const unsigned char* data,std::size_t size){
    constexpr char digits[]="0123456789abcdef";std::string output;output.reserve(size*2);
    for(std::size_t i=0;i<size;++i){output+=digits[data[i]>>4];output+=digits[data[i]&15];}return output;
}
class Algorithm {
public:BCRYPT_ALG_HANDLE value=nullptr;
    explicit Algorithm(LPCWSTR name){crypto_check(BCryptOpenAlgorithmProvider(&value,name,nullptr,0),"Open CNG algorithm");}
    ~Algorithm(){if(value)BCryptCloseAlgorithmProvider(value,0);}Algorithm(const Algorithm&)=delete;Algorithm&operator=(const Algorithm&)=delete;
    ULONG property(LPCWSTR name){ULONG output=0,amount=0;crypto_check(BCryptGetProperty(value,name,reinterpret_cast<PUCHAR>(&output),sizeof(output),&amount,0),"Get CNG property");
        require(amount==sizeof(output),"Unexpected CNG property size");return output;}
};
inline std::string sha256(const unsigned char* bytes,std::size_t size){
    Algorithm algorithm(BCRYPT_SHA256_ALGORITHM);Bytes object(algorithm.property(BCRYPT_OBJECT_LENGTH));BCRYPT_HASH_HANDLE handle=nullptr;
    crypto_check(BCryptCreateHash(algorithm.value,&handle,object.data(),static_cast<ULONG>(object.size()),nullptr,0,0),"Create SHA-256");
    try{
        for(std::size_t at=0;at<size;){const ULONG chunk=static_cast<ULONG>((std::min)(size-at,static_cast<std::size_t>(1024*1024)));
            crypto_check(BCryptHashData(handle,const_cast<PUCHAR>(bytes+at),chunk,0),"Hash input");at+=chunk;}
        std::array<unsigned char,32> digest{};crypto_check(BCryptFinishHash(handle,digest.data(),static_cast<ULONG>(digest.size()),0),"Finish SHA-256");
        BCryptDestroyHash(handle);return hex(digest.data(),digest.size());
    }catch(...){BCryptDestroyHash(handle);throw;}
}
inline std::string sha256(const Bytes& bytes){return sha256(bytes.data(),bytes.size());}
inline std::string sha256(const ReadOnlyFile& file){return sha256(file.data(),file.size());}
inline void game_image(const ReadOnlyFile& game){
    require(equal_path(filename(game.path),L"PBZ.exe"),"Expected the selected PBZ.exe client");
    require(game.size()>=sizeof(IMAGE_DOS_HEADER),"Executable DOS header is truncated");
    IMAGE_DOS_HEADER dos{};std::memcpy(&dos,game.data(),sizeof(dos));
    require(dos.e_magic==IMAGE_DOS_SIGNATURE && dos.e_lfanew>=64 && dos.e_lfanew<=1024*1024,
        "Executable DOS header is invalid");
    const auto offset=static_cast<std::size_t>(dos.e_lfanew);
    require(offset<=game.size() && sizeof(IMAGE_NT_HEADERS64)<=game.size()-offset,"Executable PE header is truncated");
    IMAGE_NT_HEADERS64 nt{};std::memcpy(&nt,game.data()+offset,sizeof(nt));
    require(nt.Signature==IMAGE_NT_SIGNATURE && nt.FileHeader.Machine==IMAGE_FILE_MACHINE_AMD64
        && nt.FileHeader.SizeOfOptionalHeader==sizeof(IMAGE_OPTIONAL_HEADER64)
        && nt.OptionalHeader.Magic==IMAGE_NT_OPTIONAL_HDR64_MAGIC && nt.OptionalHeader.NumberOfRvaAndSizes==16,
        "Expected a bounded AMD64 PE32+ client");
    const auto count=nt.FileHeader.NumberOfSections;
    const auto table=offset+sizeof(nt);
    require(count>=1 && count<=96 && table<=game.size() && static_cast<std::size_t>(count)*sizeof(IMAGE_SECTION_HEADER)<=game.size()-table,
        "Executable section table is invalid");
    const auto headers=nt.OptionalHeader.SizeOfHeaders,image=nt.OptionalHeader.SizeOfImage;
    require(headers>=table+static_cast<std::size_t>(count)*sizeof(IMAGE_SECTION_HEADER) && headers<=game.size()
        && image>=headers && image<=2ULL*1024*1024*1024,"Executable image extent is invalid");
    std::vector<std::pair<std::uint64_t,std::uint64_t>> raw_ranges,virtual_ranges;
    for(WORD index=0;index<count;++index){
        IMAGE_SECTION_HEADER section{};std::memcpy(&section,game.data()+table+static_cast<std::size_t>(index)*sizeof(section),sizeof(section));
        const auto extent=(std::max)(section.Misc.VirtualSize,section.SizeOfRawData);
        require(extent && section.VirtualAddress>=headers && section.VirtualAddress<=image && extent<=image-section.VirtualAddress,
            "Executable section virtual extent is invalid");
        virtual_ranges.emplace_back(section.VirtualAddress,static_cast<std::uint64_t>(section.VirtualAddress)+extent);
        if(section.SizeOfRawData){
            require(section.PointerToRawData>=headers && section.PointerToRawData<=game.size()
                && section.SizeOfRawData<=game.size()-section.PointerToRawData,"Executable section raw extent is invalid");
            raw_ranges.emplace_back(section.PointerToRawData,static_cast<std::uint64_t>(section.PointerToRawData)+section.SizeOfRawData);
        }
    }
    for(auto* ranges:{&raw_ranges,&virtual_ranges}){
        std::sort(ranges->begin(),ranges->end());
        for(std::size_t index=1;index<ranges->size();++index)
            require((*ranges)[index-1].second<=(*ranges)[index].first,"Executable sections overlap");
    }
}
constexpr unsigned char block_header[8]={0x50,0x42,0x5A,0x53,1,1,0,0};
class Cipher {
    Algorithm algorithm_{BCRYPT_AES_ALGORITHM};Bytes object_;BCRYPT_KEY_HANDLE key_=nullptr;
public:
    explicit Cipher(const std::array<unsigned char,32>& key){
        crypto_check(BCryptSetProperty(algorithm_.value,BCRYPT_CHAINING_MODE,reinterpret_cast<PUCHAR>(const_cast<wchar_t*>(BCRYPT_CHAIN_MODE_GCM)),sizeof(BCRYPT_CHAIN_MODE_GCM),0),"Set AES-GCM");
        object_.resize(algorithm_.property(BCRYPT_OBJECT_LENGTH));
        crypto_check(BCryptGenerateSymmetricKey(algorithm_.value,&key_,object_.data(),static_cast<ULONG>(object_.size()),const_cast<PUCHAR>(key.data()),static_cast<ULONG>(key.size()),0),"Create AES-256 key");
    }
    ~Cipher(){if(key_)BCryptDestroyKey(key_);SecureZeroMemory(object_.data(),object_.size());}
    Bytes open(const unsigned char* sealed,std::size_t size){
        require(size>=36 && std::memcmp(sealed,block_header,8)==0,"Invalid PBZS sealed block framing");
        std::array<unsigned char,12> nonce{};std::array<unsigned char,16>tag{};
        std::memcpy(nonce.data(),sealed+8,12);std::memcpy(tag.data(),sealed+20,16);
        Bytes output(size-36);BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info;BCRYPT_INIT_AUTH_MODE_INFO(info);
        info.pbNonce=nonce.data();info.cbNonce=12;info.pbTag=tag.data();info.cbTag=16;ULONG written=0;
        crypto_check(BCryptDecrypt(key_,const_cast<PUCHAR>(sealed+36),static_cast<ULONG>(size-36),&info,nullptr,0,
            output.data(),static_cast<ULONG>(output.size()),&written,0),"Authenticate PBZS block");
        require(written==output.size(),"AES-GCM plaintext extent differs");return output;
    }
    Bytes seal(const Bytes& input){
        Bytes output(input.size()+36);std::memcpy(output.data(),block_header,8);
        crypto_check(BCryptGenRandom(nullptr,output.data()+8,12,BCRYPT_USE_SYSTEM_PREFERRED_RNG),"Generate directory nonce");
        BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info;BCRYPT_INIT_AUTH_MODE_INFO(info);
        info.pbNonce=output.data()+8;info.cbNonce=12;info.pbTag=output.data()+20;info.cbTag=16;ULONG written=0;
        crypto_check(BCryptEncrypt(key_,const_cast<PUCHAR>(input.data()),static_cast<ULONG>(input.size()),&info,nullptr,0,
            output.data()+36,static_cast<ULONG>(input.size()),&written,0),"Seal PBZS directory");
        require(written==input.size(),"AES-GCM ciphertext extent differs");return output;
    }
};
inline std::array<unsigned char,32> game_key(const ReadOnlyFile& game){
    constexpr wchar_t text[]=L"sealed but block is PLAINTEXT";static_assert(sizeof(wchar_t)==2,"Windows UTF-16 required");
    const auto anchor=reinterpret_cast<const unsigned char*>(text);const auto length=sizeof(text)-sizeof(wchar_t);
    const auto end=game.data()+game.size();const auto at=std::search(game.data(),end,anchor,anchor+length);
    require(at!=end && std::search(at+1,end,anchor,anchor+length)==end,"Executable save-key anchor is absent or ambiguous");
    require(static_cast<std::size_t>(end-at)>=130,"Executable save-key material is truncated");
    require(sha256(at+66,64)=="cec857d9b81593cc8340b18e5b0d65a6f7aee2dfc8603f755b2d41ceb3951692","Unsupported save-key material fingerprint");
    std::array<unsigned char,32> result{};for(std::size_t i=0;i<32;++i)result[i]=at[66+i]^at[98+i];return result;
}
inline void write_exclusive(const std::wstring& path,const unsigned char* bytes,std::size_t size){
    Handle file(CreateFileW(path.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_WRITE_THROUGH,nullptr));
    win_check(file.value!=INVALID_HANDLE_VALUE,"Create exclusive staged output");
    for(std::size_t at=0;at<size;){const DWORD chunk=static_cast<DWORD>((std::min)(size-at,static_cast<std::size_t>(1024*1024)));DWORD written=0;
        win_check(WriteFile(file.value,bytes+at,chunk,&written,nullptr)!=FALSE && written==chunk,"Write staged output");at+=written;}
    win_check(FlushFileBuffers(file.value)!=FALSE,"Flush staged output");
}
} // namespace pbz_save
