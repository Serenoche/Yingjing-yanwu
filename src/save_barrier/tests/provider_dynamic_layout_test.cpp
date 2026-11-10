#include "provider_identity.hpp"
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <thread>

namespace {
int checks=0;
void check(bool value,const char* message){if(!value){std::fprintf(stderr,"FAIL %s\n",message);std::exit(1);}++checks;std::printf("PASS %s\n",message);}
bool read(const void* source,void* destination,std::size_t bytes){return pbz_barrier::read_bytes(source,destination,bytes);}
using Kind=pbz_provider::RegionKind;
struct Segment {std::uint32_t rva,length;Kind kind;};
struct Fixture {
    unsigned char* image=nullptr;pbz_provider::Layout layout{};
    std::vector<Segment> segments;
    std::wstring root=L"E:/old-client",scope=L"Steam/test";
    void* table=nullptr;void* module=nullptr;
    bool reject_tables=false,reject_code=false;
    Fixture(){
        image=static_cast<unsigned char*>(VirtualAlloc(nullptr,0x20000,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE));
        check(image!=nullptr,"allocate inert provider metadata fixture without executable pages");
        layout.image_size=0x20000;layout.platform_global_rva=0xA000;layout.windows_provider_rva=0xB000;
        layout.windows_loaded_rva=0xB008;layout.cache_rva=0xC000;layout.windows_getter_rva=0x4000;
        layout.path_getter_rva=0x5000;layout.caller_verified_code=true;
        layout.discover_tables_from_getters=true;layout.read_only_cache_snapshots=true;
        layout.platform_vtable_rva=0;layout.windows_vtable_rva=0;layout.save_vtable_rva=0;layout.save_object_rva=0;
        layout.direct_getter_rva=0;layout.static_object_thunk_rva=0;
        layout.host_region_check=proof;layout.host_region_context=this;
        segments={{0x2000,8,Kind::code},{0x3000,8,Kind::code},{0x4000,8,Kind::code},{0x5000,128,Kind::code},
            {0x6000,0x100,Kind::read_only_data},{0x7000,0x100,Kind::read_only_data},{0x8000,0x100,Kind::read_only_data},
            {0x9000,8,Kind::readable_data},{0xA000,8,Kind::readable_data},{0xB000,16,Kind::readable_data},
            {0xC000,0xC0,Kind::readable_data}};
        table=image+0x6000;module=&table;put(layout.platform_global_rva,module);
        void* getter=image+0x2000;put(0x6040,getter);
        void* windows_getter=image+0x4000;put(0x7040,windows_getter);
        void* save_table=image+0x8000;put(0x9000,save_table);
        void* path=image+0x5000;put(0x8078,path);
        void* provider=image+0x9000;put(layout.windows_provider_rva,provider);image[layout.windows_loaded_rva]=1;
        image[0x2000]=0xE9;rel(0x2001,0x3000,0x2005);image[0x2005]=image[0x2006]=image[0x2007]=0xCC;
        image[0x3000]=0x48;image[0x3001]=0x8D;image[0x3002]=0x05;rel(0x3003,0x9000,0x3007);image[0x3007]=0xC3;
        bind();
    }
    ~Fixture(){VirtualFree(image,0,MEM_RELEASE);}
    template<typename T>void put(std::uint32_t rva,const T& value){std::memcpy(image+rva,&value,sizeof(value));}
    void rel(std::uint32_t at,std::uint32_t target,std::uint32_t next){const auto delta=static_cast<std::int32_t>(target-next);put(at,delta);}
    void bind(){
        auto bytes=image+layout.cache_rva;bytes[0x2A]=bytes[0x2B]=1;
        const pbz_provider::FString root_value{reinterpret_cast<std::uintptr_t>(root.c_str()),static_cast<std::int32_t>(root.size()+1),static_cast<std::int32_t>(root.size()+1)};
        const pbz_provider::FString scope_value{reinterpret_cast<std::uintptr_t>(scope.c_str()),static_cast<std::int32_t>(scope.size()+1),static_cast<std::int32_t>(scope.size()+1)};
        std::memcpy(bytes+0x30,&root_value,16);std::memcpy(bytes+0x70,&scope_value,16);
    }
    static bool proof(const void* pointer,std::size_t bytes,Kind kind,void* context){
        const auto& self=*static_cast<Fixture*>(context);
        if((kind==Kind::read_only_data&&self.reject_tables)||(kind==Kind::code&&self.reject_code))return false;
        const auto at=reinterpret_cast<std::uintptr_t>(pointer)-reinterpret_cast<std::uintptr_t>(self.image);
        for(const auto& segment:self.segments){
            const bool accepted=kind==segment.kind || (kind==Kind::readable_data&&segment.kind==Kind::read_only_data);
            if(accepted&&at>=segment.rva&&at-segment.rva<segment.length&&bytes<=segment.length-(at-segment.rva))return true;
        }
        return false;
    }
    std::string inspect(){return pbz_provider::inspect(nullptr,image,layout);}
    bool chain(std::string& diagnostic){pbz_provider::Chain value;return pbz_provider::read_chain(image,read,value,&diagnostic,layout);}
    bool ready(){return inspect().find(";providerReady=1;providerPathHex="+pbz_provider::hex("E:/old-client/Steam/test/PBZSaveGame.sav")+";")==0;}
};
}

int main(){
    Fixture f;
    check(f.ready(),"direct getter E9 to exact LEA/RET resolves the static provider without invoking code");
    const auto direct=f.inspect();
    check(direct.find("providerActualRva=0000000000009000")!=std::string::npos,
        "direct target is decoded independently of unknown static object and vtable RVAs");
    void* direct_lea=f.image+0x3000;f.put(0x6040,direct_lea);
    check(f.ready(),"direct getter can be exact LEA/RET itself without calling it");
    void* direct_jump=f.image+0x2000;f.put(0x6040,direct_jump);
    f.layout.caller_verified_code=false;std::string diagnostic;
    check(!f.chain(diagnostic)&&diagnostic.find("profile-code-not-verified")!=std::string::npos,
        "dynamic discovery refuses a caller without admitted native code");
    check(f.inspect().find("snapshot-profile-not-verified")!=std::string::npos,
        "unlocked snapshot mode requires the complete caller proof");f.layout.caller_verified_code=true;
    f.layout.discover_tables_from_getters=false;
    check(f.inspect().find("snapshot-profile-not-verified")!=std::string::npos,
        "unlocked snapshot mode cannot be enabled alone");f.layout.discover_tables_from_getters=true;
    f.layout.host_region_check=nullptr;
    check(f.inspect().find("providerStage=platform-vtable-region")!=std::string::npos,
        "native region proof rejects MEM_PRIVATE fake tables rather than treating them as a host image");
    f.layout.host_region_check=Fixture::proof;
    f.reject_tables=true;
    check(f.inspect().find("providerStage=platform-vtable-region")!=std::string::npos,
        "a writable or unproved platform vtable cannot be accepted");f.reject_tables=false;
    f.reject_code=true;
    check(f.inspect().find("providerStage=platform-getter-region")!=std::string::npos,
        "provider getter must be proved readable executable host code");f.reject_code=false;
    f.table=f.image+0x1FFC0;
    check(f.inspect().find("providerStage=platform-vtable-region")!=std::string::npos,
        "slot range escaping actual image bounds is rejected before reading it");f.table=f.image+0x6000;
    f.image[0x2000]=0xEB;
    check(f.inspect().find("providerStage=direct-getter-shape")!=std::string::npos,
        "an unknown direct getter instruction shape is refused instead of called");f.image[0x2000]=0xE9;
    f.image[0x2007]=0x90;
    check(f.inspect().find("providerStage=direct-getter-shape")!=std::string::npos,
        "relative jump padding must match the known direct thunk shape");f.image[0x2007]=0xCC;
    const std::int32_t outside=std::numeric_limits<std::int32_t>::min();f.put(0x2001,outside);
    check(f.inspect().find("providerStage=static-object-thunk")!=std::string::npos,
        "negative out-of-host jump target is bounded before reading");f.rel(0x2001,0x3000,0x2005);
    f.image[0x3007]=0x90;
    check(f.inspect().find("providerStage=static-object-thunk")!=std::string::npos,
        "static object accessor must be exact LEA/RET");f.image[0x3007]=0xC3;
    f.put(0x3003,outside);
    check(f.inspect().find("providerStage=static-object-address")!=std::string::npos,
        "out-of-host static object address is refused");f.rel(0x3003,0x9000,0x3007);
    void* non_table=f.image+0x9000;f.put(0x9000,non_table);
    check(f.inspect().find("providerStage=save-vtable-region")!=std::string::npos,
        "save object's vtable cannot be mutable data");void* save_table=f.image+0x8000;f.put(0x9000,save_table);
    void* wrong_path=f.image+0x2000;f.put(0x8078,wrong_path);
    check(f.inspect().find("providerStage=save-path-method")!=std::string::npos,
        "discovered vtable must point to the admitted path getter");void* path=f.image+0x5000;f.put(0x8078,path);
    f.table=f.image+0x7000;
    check(f.ready()&&f.inspect().find("providerRoute=windows-cached")!=std::string::npos,
        "known Windows getter resolves only its initialized cache without invoking it");
    f.image[f.layout.windows_loaded_rva]=0;
    check(f.inspect().find("providerStage=windows-cache-not-ready")!=std::string::npos,
        "Windows provider must already be loaded");f.image[f.layout.windows_loaded_rva]=1;
    auto heap_object=new void*(save_table);void* external_provider=heap_object;f.put(f.layout.windows_provider_rva,external_provider);
    check(f.inspect().find("providerStage=save-object-region")!=std::string::npos,
        "Windows cached heap provider remains refused by default");
    f.layout.allow_heap_cached_provider=true;
    check(f.ready(),"admitted legacy Windows route accepts readable heap object with trusted host vtable and path method");
    f.layout.caller_verified_code=false;
    check(f.inspect().find("snapshot-profile-not-verified")!=std::string::npos,
        "heap provider flag does not bypass complete native caller proof");f.layout.caller_verified_code=true;
    *heap_object=non_table;
    check(f.inspect().find("providerStage=save-vtable-region")!=std::string::npos,
        "heap object still requires a readonly host vtable");*heap_object=save_table;
    f.put(0x8078,wrong_path);
    check(f.inspect().find("providerStage=save-path-method")!=std::string::npos,
        "heap object still requires the exact admitted path method");f.put(0x8078,path);
    void* provider=f.image+0x9000;f.put(f.layout.windows_provider_rva,provider);
    delete heap_object;f.layout.allow_heap_cached_provider=false;
    auto bytes=f.image+f.layout.cache_rva;
    unsigned char cs_before[0x28]{};std::memcpy(cs_before,bytes,sizeof(cs_before));
    check(f.ready()&&!std::memcmp(cs_before,bytes,sizeof(cs_before)),
        "read-only snapshot succeeds with an uninitialized opaque lock and leaves lock bytes unchanged");
    InitializeCriticalSection(reinterpret_cast<CRITICAL_SECTION*>(bytes));
    std::atomic<bool> held{false},release{false};
    std::thread locker([&]{EnterCriticalSection(reinterpret_cast<CRITICAL_SECTION*>(bytes));held=true;
        while(!release.load())SwitchToThread();LeaveCriticalSection(reinterpret_cast<CRITICAL_SECTION*>(bytes));});
    while(!held.load())SwitchToThread();
    const bool copied_without_lock=f.ready();release=true;locker.join();
    check(copied_without_lock,"legacy read-only snapshot does not wait for or acquire an opaque cache lock");
    DeleteCriticalSection(reinterpret_cast<CRITICAL_SECTION*>(bytes));
    int reads=0;auto raced=[&](const void* a,void* b,std::size_t n){const bool ok=read(a,b,n);
        if(a==f.image+f.layout.windows_provider_rva&&n==sizeof(void*)&&++reads==2){void* changed=f.image+0x9008;std::memcpy(b,&changed,8);}return ok;};
    pbz_provider::Chain chain;diagnostic.clear();
    check(!pbz_provider::read_chain(f.image,raced,chain,&diagnostic,f.layout)
        &&diagnostic.find("providerStage=windows-cache-changed")!=std::string::npos,
        "dynamic Windows provider pointer races remain refused");
    int flags=0;auto flag_raced=[&](const void* a,void* b,std::size_t n){const bool ok=read(a,b,n);
        if(a==f.image+f.layout.windows_loaded_rva&&n==1&&++flags==2)*static_cast<unsigned char*>(b)=0;return ok;};
    chain={};diagnostic.clear();
    check(!pbz_provider::read_chain(f.image,flag_raced,chain,&diagnostic,f.layout)
        &&diagnostic.find("providerStage=windows-cache-changed")!=std::string::npos,
        "dynamic Windows readiness races remain refused");
    pbz_provider::Header first{};std::memcpy(first.data(),bytes+0x28,first.size());
    check(f.ready()&&!std::memcmp(first.data(),bytes+0x28,first.size()),
        "successful unlocked copy changes no cache header or account strings");
    std::printf("PASS %d dynamic provider layout checks\n",checks);return 0;
}
