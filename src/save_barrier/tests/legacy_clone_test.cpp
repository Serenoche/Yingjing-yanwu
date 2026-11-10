// Exercise only the clone ownership code with local toy objects and callbacks.
// No PBZ process, executable, UE4SS DLL or game function is loaded/called.
#include "engine_clone.hpp"
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <set>
#include <vector>

namespace {
using pbz_barrier::BorrowedJsonText;
using pbz_barrier::EngineClone;
using pbz_barrier::JsonWrapper;
using pbz_barrier::SharedJson;

struct FakeObject { unsigned char header[0x40]{}; std::vector<int> values; };
struct FakeControl { void* vtable=nullptr; volatile LONG strong=1; LONG weak=1; FakeObject* object=nullptr; };
static_assert(offsetof(FakeControl,strong)==8,"Toy counter must match the verified control layout");
std::set<FakeControl*> owned;
int checks=0, release_calls=0, copy_calls=0, parser_calls=0, constructor_calls=0;
int manager_token=0;
enum class Mode { success, false_empty, false_allocated, change_pointer, change_count, change_text,
    write_wrapper_string, nonempty_object, nonzero_free_count, missing_object };
Mode mode=Mode::success;

void check(bool value,const char* label) {
    if(!value){std::fprintf(stderr,"FAIL %s\n",label);std::exit(1);}
    ++checks;std::printf("PASS %s\n",label);
}
SharedJson make_object() {
    auto object=new FakeObject();auto control=new FakeControl();control->object=object;owned.insert(control);
    return {object,control};
}
void __fastcall release(void* pointer) {
    if(!pointer)return;
    auto control=static_cast<FakeControl*>(pointer);
    check(owned.count(control)==1,"release receives only an owned control, never borrowed input/stack data");
    ++release_calls;
    if(InterlockedDecrement(&control->strong)==0){owned.erase(control);delete control->object;delete control;}
}
void* __fastcall construct(JsonWrapper* wrapper) {
    ++constructor_calls;wrapper->shared=make_object();return wrapper;
}
bool __fastcall parse(JsonWrapper* wrapper,const BorrowedJsonText* input) {
    ++parser_calls;
    check(wrapper->shared.object==nullptr && wrapper->shared.controller==nullptr,"parser receives a zero shared destination");
    const unsigned char empty[16]{};
    check(std::memcmp(wrapper->string,empty,16)==0,"parser receives an empty wrapper string");
    check(input && input->number==3 && input->capacity==3 && input->data
        && input->data[0]==L'{' && input->data[1]==L'}' && input->data[2]==0,
        "parser receives only the expected borrowed empty-object text");
    if(mode==Mode::false_empty)return false;
    wrapper->shared=make_object();
    if(mode==Mode::change_pointer)const_cast<BorrowedJsonText*>(input)->data=L"[]";
    if(mode==Mode::change_count)const_cast<BorrowedJsonText*>(input)->capacity=7;
    if(mode==Mode::change_text)const_cast<wchar_t*>(input->data)[0]=L'[';
    if(mode==Mode::write_wrapper_string)wrapper->string[0]=1;
    if(mode==Mode::nonempty_object){const std::int32_t number=1;std::memcpy(static_cast<unsigned char*>(wrapper->shared.object)+8,&number,4);}
    if(mode==Mode::nonzero_free_count){const std::int32_t number=1;std::memcpy(static_cast<unsigned char*>(wrapper->shared.object)+0x34,&number,4);}
    if(mode==Mode::missing_object)wrapper->shared.object=nullptr;
    return mode!=Mode::false_allocated;
}
void __fastcall copy(void* manager,SharedJson* temporary,const SharedJson* source) {
    ++copy_calls;
    check(manager==&manager_token,"deep copy receives the caller manager token");
    auto destination=static_cast<FakeObject*>(temporary->object);
    auto original=static_cast<const FakeObject*>(source->object);
    auto control=static_cast<FakeControl*>(temporary->controller);
    check(destination!=original && temporary->controller!=source->controller,"deep copy has a distinct object and control");
    check(control->strong==2,"deep copy receives one extra temporary reference");
    destination->values=original->values;
    release(temporary->controller);*temporary={}; // Native merge consumes this temporary owner.
}
EngineClone engine(bool legacy) {
    EngineClone value;value.construct=legacy?nullptr:&construct;value.deep_copy=&copy;value.release=&release;
    value.initialize_json=legacy?&parse:nullptr;return value;
}
void reset_counts() { release_calls=copy_calls=parser_calls=constructor_calls=0; }

void success_case(bool legacy) {
    auto original=make_object();static_cast<FakeObject*>(original.object)->values={2,4,6};
    auto value=engine(legacy);mode=Mode::success;reset_counts();SharedJson destination;std::string reason;
    check(value.clone(&manager_token,original,destination,reason),legacy?"legacy parser route clones successfully":"existing constructor route clones successfully");
    check(copy_calls==1 && release_calls==1,"successful clone consumes exactly one temporary reference");
    check(parser_calls==(legacy?1:0) && constructor_calls==(legacy?0:1),"only the selected initializer route is called");
    check(static_cast<FakeControl*>(destination.controller)->strong==1,"published destination retains exactly one owner");
    check(static_cast<FakeObject*>(destination.object)->values==std::vector<int>({2,4,6}),"clone contains copied values");
    static_cast<FakeObject*>(destination.object)->values.push_back(8);
    check(static_cast<FakeObject*>(original.object)->values==std::vector<int>({2,4,6}),"mutating the clone does not alias the source payload");
    value.drop(destination);check(!destination.object && !destination.controller,"drop clears the transferred owner");
    check(release_calls==2 && owned.size()==1,"drop releases the destination exactly once and keeps source alive");
    value.drop(original);check(owned.empty(),"all toy owners are released after success");
}
void refusal_case(Mode selected,const char* label,bool allocated=true) {
    auto original=make_object();auto value=engine(true);mode=selected;reset_counts();SharedJson destination;std::string reason;
    check(!value.clone(&manager_token,original,destination,reason),label);
    check(reason=="native-runtime-incompatible:LegacyJsonInitialization","parser refusal has a concrete initialization error");
    check(!destination.object && !destination.controller && copy_calls==0,"rejected initialization never publishes or deep-copies a destination");
    check(release_calls==(allocated?1:0) && owned.size()==1,"rejected initialization safely releases its partial shared owner only");
    check(static_cast<FakeControl*>(original.controller)->strong==1,"rejected initialization preserves original ownership");
    value.drop(original);check(owned.empty(),"all toy owners are released after refusal");
}
}

int main() {
    success_case(true);success_case(false);
    refusal_case(Mode::false_empty,"parser false without allocation is refused",false);
    refusal_case(Mode::false_allocated,"parser false after allocation is refused");
    refusal_case(Mode::change_pointer,"changed borrowed input pointer is refused");
    refusal_case(Mode::change_count,"changed borrowed input extent is refused");
    refusal_case(Mode::change_text,"changed borrowed input text is refused");
    refusal_case(Mode::write_wrapper_string,"unexpected wrapper-string write is refused without freeing it");
    refusal_case(Mode::nonempty_object,"nonempty parsed root is refused");
    refusal_case(Mode::nonzero_free_count,"inconsistent empty-map free count is refused");
    refusal_case(Mode::missing_object,"missing parsed object is refused and its control cleaned");
    auto original=make_object();auto value=engine(true);value.construct=&construct;mode=Mode::success;reset_counts();
    SharedJson destination;std::string reason;
    check(value.clone(&manager_token,original,destination,reason),"explicit parser route may coexist with an unused constructor pointer");
    check(parser_calls==1 && constructor_calls==0,"explicit parser route does not fall back to an unverified constructor");
    value.drop(destination);value.drop(original);check(owned.empty(),"coexisting routes leave no toy owner alive");
    std::printf("Legacy clone checks: %d passed\n",checks);return 0;
}
