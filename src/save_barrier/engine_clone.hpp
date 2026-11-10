#pragma once
#include "patch_transaction.hpp"

namespace pbz_barrier {
struct SharedJson { void* object = nullptr; void* controller = nullptr; };
struct JsonWrapper { unsigned char string[16]{}; SharedJson shared; };
static_assert(sizeof(SharedJson) == 16 && sizeof(JsonWrapper) == 32, "pinned native wrapper layout");
using WrapperConstructor = void* (__fastcall*)(JsonWrapper*);
using CopyJson = void (__fastcall*)(void*, SharedJson*, const SharedJson*);
using ReleaseShared = void (__fastcall*)(void*);
struct BorrowedJsonText { const wchar_t* data; std::int32_t number, capacity; };
using JsonParser = bool (__fastcall*)(JsonWrapper*, const BorrowedJsonText*);

struct EngineClone {
    WrapperConstructor construct = nullptr;
    CopyJson deep_copy = nullptr;
    ReleaseShared release = nullptr;
    JsonParser initialize_json = nullptr;

    static bool empty_parsed_object(const SharedJson& value) {
        std::int32_t number=-1,free_number=-1,strong=0;
        SIZE_T amount=0;
        if(!value.object || !value.controller
            || !ReadProcessMemory(GetCurrentProcess(),static_cast<unsigned char*>(value.controller)+8,&strong,4,&amount) || amount!=4 || strong<1 || strong>65536
            || !ReadProcessMemory(GetCurrentProcess(),static_cast<unsigned char*>(value.object)+8,&number,4,&amount) || amount!=4
            || !ReadProcessMemory(GetCurrentProcess(),static_cast<unsigned char*>(value.object)+0x34,&free_number,4,&amount) || amount!=4)return false;
        return number==0 && free_number==0;
    }

    bool clone(void* manager, const SharedJson& source, SharedJson& destination, std::string& reason) const {
        if (!source.object || !source.controller || (!construct && !initialize_json) || !deep_copy || !release) {
            reason = "master clone inputs are unavailable"; return false;
        }
        JsonWrapper wrapper{};
        if(initialize_json) {
            // The legacy parser assigns only wrapper.shared and supports a
            // zero destination. The input FString borrows our stack text;
            // neither the parser nor this companion owns that buffer.
            wchar_t text[3]={L'{',L'}',L'\0'};
            BorrowedJsonText input{text,3,3};
            const bool parsed=initialize_json(&wrapper,&input);
            const unsigned char empty_string[16]{};
            const bool unchanged=input.data==text && input.number==3 && input.capacity==3
                && text[0]==L'{' && text[1]==L'}' && text[2]==0;
            if(!parsed || !unchanged || std::memcmp(wrapper.string,empty_string,16)!=0 || !empty_parsed_object(wrapper.shared)) {
                // Only release a control block whose counter can be read. An
                // unexpected string is never passed to a guessed allocator.
                LONG strong=0;SIZE_T amount=0;
                if(wrapper.shared.controller && ReadProcessMemory(GetCurrentProcess(),static_cast<unsigned char*>(wrapper.shared.controller)+8,&strong,4,&amount)
                    && amount==4 && strong>0 && strong<=65536)release(wrapper.shared.controller);
                reason="native-runtime-incompatible:LegacyJsonInitialization";return false;
            }
        } else construct(&wrapper);
        if (!wrapper.shared.object || !wrapper.shared.controller) {
            if (wrapper.shared.controller) release(wrapper.shared.controller);
            reason = "native JSON wrapper allocation failed"; return false;
        }
        // The exact pinned caller pattern increments the temporary destination
        // owner; DeepCopy consumes that temporary with the native ref-release.
        SharedJson temporary = wrapper.shared;
        InterlockedIncrement(reinterpret_cast<volatile LONG*>(static_cast<unsigned char*>(temporary.controller) + 8));
        deep_copy(manager, &temporary, &source);
        destination = wrapper.shared; // Transfer the wrapper's remaining owner.
        wrapper.shared = {};
        return true;
    }
    void drop(SharedJson& owner) const {
        const auto controller = owner.controller;
        owner = {};
        if (controller) release(controller);
    }
};
} // namespace pbz_barrier
