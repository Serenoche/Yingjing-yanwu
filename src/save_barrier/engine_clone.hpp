#pragma once
#include "patch_transaction.hpp"

namespace pbz_barrier {
struct SharedJson { void* object = nullptr; void* controller = nullptr; };
struct JsonWrapper { unsigned char string[16]{}; SharedJson shared; };
static_assert(sizeof(SharedJson) == 16 && sizeof(JsonWrapper) == 32, "pinned native wrapper layout");
using WrapperConstructor = void* (__fastcall*)(JsonWrapper*);
using CopyJson = void (__fastcall*)(void*, SharedJson*, const SharedJson*);
using ReleaseShared = void (__fastcall*)(void*);

struct EngineClone {
    WrapperConstructor construct = nullptr;
    CopyJson deep_copy = nullptr;
    ReleaseShared release = nullptr;

    bool clone(void* manager, const SharedJson& source, SharedJson& destination, std::string& reason) const {
        if (!source.object || !source.controller || !construct || !deep_copy || !release) {
            reason = "master clone inputs are unavailable"; return false;
        }
        JsonWrapper wrapper{};
        construct(&wrapper);
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
