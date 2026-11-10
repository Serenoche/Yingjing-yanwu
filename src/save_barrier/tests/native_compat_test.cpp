#include "native_compat.hpp"
#include <cstdio>
#include <cstdlib>

namespace {
int checks=0;
void check(bool accepted,const char* label) {
    if(!accepted){std::fprintf(stderr,"FAIL %s\n",label);std::exit(1);}
    ++checks;std::printf("PASS %s\n",label);
}
struct Fixture {
    std::uintptr_t base=0x180000000ULL;
    std::vector<unsigned char> bytes=std::vector<unsigned char>(0x6000);
    std::vector<pbz_compat::Region> regions;
    pbz_compat::Image image;
    std::string code_hash,data_hash,reason;
    pbz_compat::Window windows[2]{};
    pbz_compat::Span spans[1]={{"ProviderCache",0x3000,192,pbz_compat::Kind::mutable_data}};
    int reads=0,queries=0;
    Fixture() {
        IMAGE_DOS_HEADER dos{};dos.e_magic=IMAGE_DOS_SIGNATURE;dos.e_lfanew=128;
        IMAGE_NT_HEADERS64 nt{};nt.Signature=IMAGE_NT_SIGNATURE;nt.FileHeader.Machine=IMAGE_FILE_MACHINE_AMD64;
        nt.FileHeader.NumberOfSections=3;nt.FileHeader.SizeOfOptionalHeader=sizeof(IMAGE_OPTIONAL_HEADER64);
        nt.FileHeader.TimeDateStamp=1234;nt.OptionalHeader.Magic=IMAGE_NT_OPTIONAL_HDR64_MAGIC;
        nt.OptionalHeader.NumberOfRvaAndSizes=16;nt.OptionalHeader.SizeOfHeaders=1024;
        nt.OptionalHeader.SizeOfImage=0x5000;nt.OptionalHeader.ImageBase=0x140000000ULL;
        std::memcpy(bytes.data(),&dos,sizeof(dos));std::memcpy(bytes.data()+128,&nt,sizeof(nt));
        for(unsigned int i=0;i<3;++i) {
            IMAGE_SECTION_HEADER section{};section.VirtualAddress=0x1000*(i+1);section.Misc.VirtualSize=4096;section.SizeOfRawData=4096;
            section.Characteristics=IMAGE_SCN_MEM_READ|(i==0?IMAGE_SCN_MEM_EXECUTE:i==2?IMAGE_SCN_MEM_WRITE:0);
            std::memcpy(bytes.data()+128+sizeof(nt)+i*sizeof(section),&section,sizeof(section));
            regions.push_back({base+section.VirtualAddress,4096,base,MEM_COMMIT,MEM_IMAGE,
                static_cast<DWORD>(i==0?PAGE_EXECUTE_READ:i==2?PAGE_READWRITE:PAGE_READONLY)});
        }
        for(std::size_t i=0;i<512;++i)bytes[0x1100+i]=static_cast<unsigned char>((i*17+3)&255);
        for(std::size_t i=0;i<128;++i)bytes[0x2100+i]=static_cast<unsigned char>((i*31+7)&255);
        refresh_hashes();
        check(parse(),"parse fixture AMD64 PE without any fixed timestamp or image-size identity");
    }
    bool read(std::uintptr_t address,void* output,std::size_t length) {
        ++reads;
        if(address<base || address-base>bytes.size() || length>bytes.size()-(address-base))return false;
        std::memcpy(output,bytes.data()+address-base,length);return true;
    }
    bool query(std::uintptr_t address,pbz_compat::Region& output) {
        ++queries;
        for(const auto& region:regions)if(address>=region.base && address-region.base<region.size){output=region;return true;}
        return false;
    }
    bool parse(){return pbz_compat::image_headers(base,[&](auto address,auto output,auto length){return read(address,output,length);},image);}
    void refresh_hashes() {
        code_hash=pbz_compat::sha256(bytes.data()+0x1100,512);data_hash=pbz_compat::sha256(bytes.data()+0x2100,128);
        windows[0]={"SaveWriter",0x1100,512,pbz_compat::Kind::code,code_hash.c_str(),nullptr,0};
        windows[1]={"ProviderVtable",0x2100,128,pbz_compat::Kind::constant_data,data_hash.c_str(),nullptr,0};
    }
    bool verify(){return pbz_compat::verify(image,windows,2,spans,1,[&](auto a,auto b,auto n){return read(a,b,n);},
        [&](auto a,auto& r){return query(a,r);},reason);}
    template<typename Proof> bool admit(pbz_compat::VerifiedIdentity& verified,bool armed,Proof proof) {
        return pbz_compat::admit(image,windows,2,spans,1,verified,armed,proof,
            [&](auto a,auto b,auto n){return read(a,b,n);},[&](auto a,auto& r){return query(a,r);},reason);
    }
};
}

int main() {
    using namespace pbz_compat;
    const unsigned char abc[]={'a','b','c'};
    check(sha256(abc,3)=="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad","CNG digest matches the independent SHA256 known vector");
    {
        Fixture f;check(f.verify(),"all mandatory code, vtable and mutable-provider spans pass together");
        const std::uint32_t stamp=987654321,size=0x6000;
        std::memcpy(f.bytes.data()+128+8,&stamp,4);std::memcpy(f.bytes.data()+128+24+56,&size,4);
        check(f.parse()&&f.image.timestamp==stamp&&f.image.size==size&&f.verify(),"different reasonable PE timestamp and image extent do not block unchanged interfaces");
        f.bytes[0x1100+300]^=0x5a;
        check(!f.verify()&&f.reason=="native-runtime-incompatible:SaveWriter","code change beyond an identical short prologue refuses by symbol");
    }
    {
        Fixture f;f.bytes[0x2100+90]^=1;
        check(!f.verify()&&f.reason=="native-runtime-incompatible:ProviderVtable","a changed provider-vtable body refuses before cache access");
    }
    {
        Fixture f;f.image.size=0x11ff;f.reads=0;
        check(!f.verify()&&f.reads==0,"out-of-image mandatory span refuses without reading target bytes");
    }
    for(int mode=0;mode<6;++mode) {
        Fixture f;
        switch(mode){
        case 0:f.regions[0].type=MEM_PRIVATE;break;
        case 1:f.regions[0].allocation_base+=0x1000;break;
        case 2:f.regions[0].state=MEM_RESERVE;break;
        case 3:f.regions[0].protection=PAGE_READWRITE;break;
        case 4:f.regions[0].protection=PAGE_EXECUTE_READ|PAGE_GUARD;break;
        default:f.regions[0].protection=PAGE_NOACCESS;break;
        }
        f.reads=0;check(!f.verify()&&f.reads==0,"wrong mapped-image ownership/state/protection refuses before hashing");
    }
    {
        Fixture f;f.regions[0].size=0x180;
        f.regions.insert(f.regions.begin()+1,{f.base+0x1180,0xe80,f.base,MEM_COMMIT,MEM_PRIVATE,PAGE_EXECUTE_READ});
        f.reads=0;
        check(!f.verify()&&f.queries>=2&&f.reads==0,"complete window checks the second VM region rather than only its first page");
    }
    {
        Fixture f;f.spans[0].rva=0x7000;
        check(!f.verify()&&f.reason=="native-runtime-incompatible:ProviderCache","mutable provider globals must be fully inside the actual image");
    }
    {
        Fixture f;f.spans[0].length=0xffffffffu;
        check(!f.verify(),"oversized mutable span refuses before vector allocation");
    }
    {
        Fixture f;const std::uint64_t preferred=0x140002200ULL;
        std::memcpy(f.bytes.data()+0x1100+100,&preferred,8);f.refresh_hashes();
        const Relocation relocations[]={{100,IMAGE_REL_BASED_DIR64}};
        f.windows[0].relocations=relocations;f.windows[0].relocation_count=1;
        const auto relocated=preferred+(f.base-f.image.preferred_base);
        std::memcpy(f.bytes.data()+0x1100+100,&relocated,8);
        check(f.verify(),"only a recorded DIR64 slot is normalized for a real ASLR base difference");
        f.bytes[0x1100+120]^=1;
        check(!f.verify(),"normalizing a relocation never masks neighboring code changes");
        f.bytes[0x1100+120]^=1;
        const Relocation overlapping[]={{100,IMAGE_REL_BASED_DIR64},{104,IMAGE_REL_BASED_HIGHLOW}};
        f.windows[0].relocations=overlapping;f.windows[0].relocation_count=2;
        check(!f.verify(),"overlapping relocation masks are rejected");
        const Relocation invalid[]={{100,123}};f.windows[0].relocations=invalid;f.windows[0].relocation_count=1;
        check(!f.verify(),"unknown relocation types are not guessed");
    }
    {
        Fixture f;VerifiedIdentity verified;
        check(!verified.matches(f.image),"an unverified host never starts with a cached proof");
        check(f.admit(verified,false,[]{return false;}),"first unarmed admission verifies all interfaces and records process identity");
        std::array<unsigned char,8> original{};std::copy_n(f.bytes.data()+0x1100,8,original.data());
        constexpr std::uint64_t replacement=0x9090909090c3c031ULL;
        std::memcpy(f.bytes.data()+0x1100,&replacement,8);
        f.reads=0;
        auto own_patch=[&](){std::uint64_t current;std::memcpy(&current,f.bytes.data()+0x1100,8);return current==replacement;};
        check(f.admit(verified,true,own_patch)&&f.reads==0,"armed inspection accepts cached interfaces only with its verified owned patch word");
        f.bytes[0x1100]^=1;
        check(!f.admit(verified,true,own_patch)&&f.reason=="native-runtime-incompatible:OwnedPatchState","an external alteration to an owned entry refuses despite cached host identity");
        std::copy(original.begin(),original.end(),f.bytes.data()+0x1100);
        check(f.admit(verified,false,[]{return false;}),"disarmed restored functions are fully checked again");
        f.bytes[0x1100+300]^=1;
        check(!f.admit(verified,false,[]{return true;}),"unarmed cached proof cannot hide a later native-body change");
    }
    {
        Fixture f;f.bytes[0x3000+50]=42;check(f.verify(),"runtime-dependent provider values are only read boundedly, never hashed or initialized");
        f.image.sections[1].flags|=IMAGE_SCN_MEM_WRITE;
        check(!f.verify(),"expected constant provider vtables cannot silently move into a writable PE section");
    }
    std::printf("PASS %d native compatibility checks; synthetic memory only\n",checks);
    return 0;
}
