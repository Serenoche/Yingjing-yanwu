#include "provider_identity.hpp"
#include <cstdio>
#include <thread>
#include <atomic>

namespace {
int checks=0;
void check(bool ok,const char* label) {if(!ok){std::fprintf(stderr,"FAIL %s\n",label);std::exit(1);}++checks;std::printf("PASS %s\n",label);}
struct Cache {
    alignas(8) unsigned char bytes[0xC0]{};
    std::wstring root=L"D:\\Games\\PBZ\\ProjectPBZ\\Saved\\SaveGames", public_root=L"C:/Engine/Saved/SaveGames";
    std::wstring requested=L"Steam/12345678901234568", scope=L"Steam/12345678901234567", override_directory;
    std::vector<pbz_provider::FString> slots;
    Cache(){InitializeCriticalSection(reinterpret_cast<CRITICAL_SECTION*>(bytes));bytes[0x2A]=bytes[0x2B]=1;bind();}
    ~Cache(){DeleteCriticalSection(reinterpret_cast<CRITICAL_SECTION*>(bytes));}
    void put(std::size_t offset,const std::wstring& value){const pbz_provider::FString s{reinterpret_cast<std::uintptr_t>(value.c_str()),static_cast<std::int32_t>(value.size()+1),static_cast<std::int32_t>(value.size()+1)};std::memcpy(bytes+offset,&s,16);}
    void bind(){put(0x30,root);put(0x40,public_root);put(0x60,requested);put(0x70,scope);put(0x80,override_directory);
        const pbz_provider::Array a{reinterpret_cast<std::uintptr_t>(slots.data()),static_cast<std::int32_t>(slots.size()),static_cast<std::int32_t>(slots.size())};std::memcpy(bytes+0x50,&a,16);}
};
const auto read=[](const void* a,void* b,std::size_t n){return pbz_barrier::read_bytes(a,b,n);};
bool path(Cache& cache,std::string& result,std::string& reason){return pbz_provider::copy_path(cache.bytes,read,result,reason);}
bool ready_path(const std::string& diagnostic,const std::string& expected){
    return diagnostic.find(";providerReady=1;providerPathHex="+pbz_provider::hex(expected)+";")==0;
}
}
int main(){
    Cache cache;std::string result,reason;
    std::array<unsigned char,sizeof(cache.bytes)> saved{};std::memcpy(saved.data(),cache.bytes,saved.size());
    check(path(cache,result,reason)&&result=="D:/Games/PBZ/ProjectPBZ/Saved/SaveGames/Steam/12345678901234567/PBZSaveGame.sav","actual migrated scope is used instead of requested different account");
    check(!std::memcmp(saved.data(),cache.bytes,saved.size()),"provider read changes no cache or string header bytes");
    cache.override_directory=L"E:/Actual/MigratedAccount";cache.bind();
    check(path(cache,result,reason)&&result=="E:/Actual/MigratedAccount/PBZSaveGame.sav","actual override takes precedence over root and account scope");
    std::wstring master=L"PBZSaveGame";cache.slots={{reinterpret_cast<std::uintptr_t>(master.c_str()),12,12}};cache.bind();
    check(path(cache,result,reason)&&result=="C:/Engine/Saved/SaveGames/PBZSaveGame.sav","original public-slot registry chooses public saved directory even with override");
    cache.slots.clear();cache.override_directory.clear();cache.scope.clear();cache.bind();
    check(path(cache,result,reason)&&result=="D:/Games/PBZ/ProjectPBZ/Saved/SaveGames/PBZSaveGame.sav","unscoped initialized provider reports its real root rather than guessing an account");
    cache.root=L"Z:/\x6E38\x620F/\x6D4B\x8BD5";cache.scope=L"Steam/12345678901234567";cache.bind();
    check(path(cache,result,reason)&&result.find("\xE6\xB8\xB8\xE6\x88\x8F/\xE6\xB5\x8B\xE8\xAF\x95")!=std::string::npos,"Unicode installation directories encode as valid UTF-8 without a locale conversion");
    check(pbz_provider::hex("A\xE6\xB8\xB8") == "41e6b8b8","status transport is plain UTF-8 hex with no delimiters or locale loss");
    cache.bytes[0x2B]=0;check(!path(cache,result,reason),"uninitialized root cache is refused without initializing it");cache.bytes[0x2B]=1;
    cache.bytes[0x2A]=0;check(!path(cache,result,reason),"uninitialized config cache is refused without a native getter");cache.bytes[0x2A]=1;
    pbz_provider::FString original{};std::memcpy(&original,cache.bytes+0x30,16);
    auto invalid=original;invalid.data=0x10000;std::memcpy(cache.bytes+0x30,&invalid,16);
    check(!path(cache,result,reason),"unreadable native string pointer fails closed");cache.bind();
    invalid=original;invalid.number=4098;std::memcpy(cache.bytes+0x30,&invalid,16);
    check(!path(cache,result,reason),"oversized FString count is refused before copying memory");cache.bind();
    invalid=original;invalid.capacity=invalid.number-1;std::memcpy(cache.bytes+0x30,&invalid,16);
    check(!path(cache,result,reason),"native string capacity smaller than count is refused");cache.bind();
    std::wstring embedded=L"D:/good";embedded.push_back(0);embedded+=L"/hidden";cache.root=embedded;cache.bind();
    check(!path(cache,result,reason),"embedded NUL cannot disguise a different provider path");
    wchar_t unterminated[3]={L'D',L':',L'/'};invalid={reinterpret_cast<std::uintptr_t>(unterminated),3,3};std::memcpy(cache.bytes+0x30,&invalid,16);
    check(!path(cache,result,reason),"a native string without its final NUL is refused");
    cache.root=L"D:/safe";cache.scope=L"../other";cache.bind();check(!path(cache,result,reason),"parent traversal in actual scope is refused rather than resolved using guessed context");
    cache.scope=L"E:/other";cache.bind();check(!path(cache,result,reason),"absolute account scope cannot override the native root branch");
    cache.root=L"relative/Saved";cache.scope=L"Steam/1";cache.bind();check(!path(cache,result,reason),"relative native root is refused without consulting an unrelated working directory");
    cache.root=L"D:/safe";cache.scope=L"Steam/1";cache.bind();
    const pbz_provider::Array bad_array{0xFFFFFFFFFFFFFFF8ull,1,1};std::memcpy(cache.bytes+0x50,&bad_array,16);
    check(!path(cache,result,reason),"overflowing public-slot pointer is rejected before element arithmetic");cache.bind();
    const pbz_provider::Array large_array{0,257,257};std::memcpy(cache.bytes+0x50,&large_array,16);
    check(!path(cache,result,reason),"unbounded public-slot registry is refused");cache.bind();
    int headers=0;auto race=[&](const void* a,void* b,std::size_t n){const bool ok=read(a,b,n);if(a==cache.bytes+0x28&&++headers==2)static_cast<unsigned char*>(b)[0]^=1;return ok;};
    check(!pbz_provider::copy_path(cache.bytes,race,result,reason),"header changes during a snapshot are refused");
    int roots=0;auto string_race=[&](const void* a,void* b,std::size_t n){const bool ok=read(a,b,n);if(a==cache.root.c_str()&&++roots==2)static_cast<wchar_t*>(b)[0]=L'E';return ok;};
    check(!pbz_provider::copy_path(cache.bytes,string_race,result,reason),"in-place string changes between copied snapshots are refused");
    cache.root=std::wstring(4095,L'\x6E38');cache.root.replace(0,3,L"D:/");cache.bind();
    check(!path(cache,result,reason),"UTF-8 path exceeding the Lua identity bound is refused");
    cache.root=L"D:/safe";cache.root.push_back(static_cast<wchar_t>(0xD800));cache.bind();
    check(!path(cache,result,reason),"unpaired UTF-16 surrogates are refused by strict UTF-8 conversion");
    cache.root=L"D:/safe";cache.bind();
    std::atomic<bool> locked{false},release{false};
    std::thread worker([&]{EnterCriticalSection(reinterpret_cast<CRITICAL_SECTION*>(cache.bytes));locked=true;while(!release.load())SwitchToThread();LeaveCriticalSection(reinterpret_cast<CRITICAL_SECTION*>(cache.bytes));});
    while(!locked.load())SwitchToThread();
    const bool acquired=TryEnterCriticalSection(reinterpret_cast<CRITICAL_SECTION*>(cache.bytes))!=0;
    if(acquired)LeaveCriticalSection(reinterpret_cast<CRITICAL_SECTION*>(cache.bytes));release=true;worker.join();
    check(!acquired,"real provider critical section can be probed without waiting on another thread");
    check(TryEnterCriticalSection(reinterpret_cast<CRITICAL_SECTION*>(cache.bytes))!=0,"real provider lock is available after its owner releases it");LeaveCriticalSection(reinterpret_cast<CRITICAL_SECTION*>(cache.bytes));
    // Full inspection, with a synthetic sparse image and no game code calls.
    auto image=static_cast<unsigned char*>(VirtualAlloc(nullptr,0x0E015000,MEM_RESERVE,PAGE_NOACCESS));
    check(image!=nullptr,"reserve synthetic image for the complete read-only provider chain");
    auto page=[&](std::uint32_t rva){auto p=image+(rva&~0xFFFu);MEMORY_BASIC_INFORMATION m{};VirtualQuery(p,&m,sizeof(m));
        if(m.State!=MEM_COMMIT)check(VirtualAlloc(p,4096,MEM_COMMIT,PAGE_READWRITE)!=nullptr,"commit sparse provider fixture page");};
    for(const auto& signature:pbz_provider::signatures){page(signature.rva);std::memcpy(image+signature.rva,signature.bytes,signature.length);}
    for(const auto rva:{pbz_provider::cache_rva,pbz_provider::platform_global_rva,pbz_provider::platform_vtable_rva,pbz_provider::save_object_rva,pbz_provider::save_vtable_rva})page(rva);
    void* module_table=image+pbz_provider::platform_vtable_rva;void* module=&module_table;
    std::memcpy(image+pbz_provider::platform_global_rva,&module,8);
    void* module_getter=image+0x048511D0;std::memcpy(image+pbz_provider::platform_vtable_rva+0x40,&module_getter,8);
    void* save_table=image+pbz_provider::save_vtable_rva;std::memcpy(image+pbz_provider::save_object_rva,&save_table,8);
    void* path_method=image+0x0484B070;std::memcpy(image+pbz_provider::save_vtable_rva+0x78,&path_method,8);
    auto native_cache=image+pbz_provider::cache_rva;
    InitializeCriticalSection(reinterpret_cast<CRITICAL_SECTION*>(native_cache));
    std::memcpy(native_cache+0x28,cache.bytes+0x28,0x98);
    alignas(8)unsigned char manager[0x660]{};
    native_cache[0x2B]=0;
    check(pbz_provider::inspect(manager,image).find("providerReady=0;providerReason=cache-not-ready")!=std::string::npos,"complete reader refuses uninitialized provider cache independently of the summary index");native_cache[0x2B]=1;
    check(ready_path(pbz_provider::inspect(manager,image),"D:/safe/Steam/1/PBZSaveGame.sav"),
        "initialized actual provider path is readable when manager summary index is zero, without changing that index");
    manager[0x3A0]=1;
    const auto complete=pbz_provider::inspect(manager,image);
    check(ready_path(complete,"D:/safe/Steam/1/PBZSaveGame.sav"),"complete reader verifies actual provider module, method and initialized cache before emitting exact path");
    module_table=nullptr;
    check(pbz_provider::inspect(manager,image).find("providerReady=0;providerReason=native-provider-chain-mismatch")!=std::string::npos,"another active platform module cannot reuse a stale PBZ cache identity");module_table=image+pbz_provider::platform_vtable_rva;
    native_cache[0x2B]=0;
    check(pbz_provider::inspect(manager,image).find("providerReady=0;providerReason=cache-not-ready")!=std::string::npos,"complete reader never acquires an uninitialized cache lock");native_cache[0x2B]=1;
    image[pbz_provider::signatures[0].rva]^=1;
    const auto signature_failure=pbz_provider::inspect(manager,image);
    check(signature_failure.find("providerReady=0;providerReason=native-provider-chain-mismatch")!=std::string::npos
        &&signature_failure.find("providerSigRva=00000000048511D0")!=std::string::npos
        &&signature_failure.find("providerSigExpected=e95b95ffffcccccc")!=std::string::npos
        &&signature_failure.find("providerSigActual=e85b95ffffcccccc")!=std::string::npos,
        "changed pinned provider code is refused and records the exact failed RVA and expected versus actual bytes");image[pbz_provider::signatures[0].rva]^=1;
    // Actual installed Windows config: PlatformFeatures=WindowsPlatformFeatures,
    // SaveGameSystemModule=PBZSaveGameSystem. The outer module is not the provider.
    for(const auto rva:{pbz_provider::windows_vtable_rva,pbz_provider::windows_provider_rva,pbz_provider::windows_loaded_rva,pbz_provider::windows_getter_rva})page(rva);
    std::memcpy(image+pbz_provider::windows_getter_rva,pbz_provider::windows_signature.bytes,pbz_provider::windows_signature.length);
    void* windows_getter=image+pbz_provider::windows_getter_rva;
    std::memcpy(image+pbz_provider::windows_vtable_rva+0x40,&windows_getter,8);
    void* current_provider=image+pbz_provider::save_object_rva;
    std::memcpy(image+pbz_provider::windows_provider_rva,&current_provider,8);image[pbz_provider::windows_loaded_rva]=1;
    module_table=image+pbz_provider::windows_vtable_rva;
    const auto windows_report=pbz_provider::inspect(manager,image);
    check(ready_path(windows_report,"D:/safe/Steam/1/PBZSaveGame.sav")
        &&windows_report.find("providerRoute=windows-cached")!=std::string::npos
        &&windows_report.find("providerModuleVtableRva=000000000B4EFFA0")!=std::string::npos
        &&windows_report.find("providerActualRva=000000000DB242F0")!=std::string::npos,
        "actual Windows outer module resolves only its initialized cached exact PBZ provider and emits route/pointer diagnostics");
    image[pbz_provider::windows_loaded_rva]=0;
    check(pbz_provider::inspect(manager,image).find("providerStage=windows-cache-not-ready")!=std::string::npos,
        "Windows provider cache not yet loaded is refused without running its lazy getter");image[pbz_provider::windows_loaded_rva]=1;
    void* foreign_provider=image+pbz_provider::save_object_rva+16;
    std::memcpy(image+pbz_provider::windows_provider_rva,&foreign_provider,8);
    check(pbz_provider::inspect(manager,image).find("providerStage=windows-provider-pointer")!=std::string::npos,
        "foreign Windows cached save provider cannot borrow the original PBZ path cache");
    std::memcpy(image+pbz_provider::windows_provider_rva,&current_provider,8);
    void* foreign_getter=image+0x0484A730;
    std::memcpy(image+pbz_provider::windows_vtable_rva+0x40,&foreign_getter,8);
    check(pbz_provider::inspect(manager,image).find("providerStage=windows-getter")!=std::string::npos,
        "a changed Windows virtual getter is refused rather than invoked");
    std::memcpy(image+pbz_provider::windows_vtable_rva+0x40,&windows_getter,8);
    image[pbz_provider::windows_getter_rva]^=1;
    check(pbz_provider::inspect(manager,image).find("providerSigRva=00000000047B7490")!=std::string::npos,
        "Windows wrapper prolog mismatch is reported separately from unknown provider pointers");image[pbz_provider::windows_getter_rva]^=1;
    int pointer_reads=0;auto pointer_race=[&](const void* a,void* b,std::size_t n){const bool ok=read(a,b,n);
        if(a==image+pbz_provider::windows_provider_rva&&n==sizeof(foreign_provider)&&++pointer_reads==2)std::memcpy(b,&foreign_provider,n);return ok;};
    pbz_provider::Chain raced;std::string race_diagnostic;
    check(!pbz_provider::read_chain(image,pointer_race,raced,&race_diagnostic)
        &&race_diagnostic.find("providerStage=windows-cache-changed")!=std::string::npos,
        "Windows cached provider pointer changing during the chain snapshot fails closed");
    int flag_reads=0;auto flag_race=[&](const void* a,void* b,std::size_t n){const bool ok=read(a,b,n);
        if(a==image+pbz_provider::windows_loaded_rva&&++flag_reads==2)*static_cast<unsigned char*>(b)=0;return ok;};
    raced={};race_diagnostic.clear();
    check(!pbz_provider::read_chain(image,flag_race,raced,&race_diagnostic)
        &&race_diagnostic.find("providerStage=windows-cache-changed")!=std::string::npos,
        "Windows cached provider readiness changing during the chain snapshot fails closed");
    pbz_provider::Chain first_chain,second_chain;
    check(pbz_provider::provider_chain(image,first_chain),"stable original Windows cached provider chain is readable without callbacks");
    void* second_module_table=module_table;void* second_module=&second_module_table;
    std::memcpy(image+pbz_provider::platform_global_rva,&second_module,8);
    check(pbz_provider::provider_chain(image,second_chain)&&!pbz_provider::same(first_chain,second_chain),
        "an outer module identity change between before/after snapshots cannot be mistaken for the same chain");
    std::memcpy(image+pbz_provider::platform_global_rva,&module,8);
    pbz_provider::Header before_read{};std::memcpy(before_read.data(),native_cache+0x28,before_read.size());
    check(ready_path(pbz_provider::inspect(manager,image),"D:/safe/Steam/1/PBZSaveGame.sav")
        &&!std::memcmp(before_read.data(),native_cache+0x28,before_read.size())
        &&image[pbz_provider::windows_loaded_rva]==1,
        "successful Windows-chain inspection leaves native path cache and provider-loaded state unchanged");
    DeleteCriticalSection(reinterpret_cast<CRITICAL_SECTION*>(native_cache));VirtualFree(image,0,MEM_RELEASE);
    std::printf("PASS %d offline native provider identity checks\n",checks);return 0;
}
