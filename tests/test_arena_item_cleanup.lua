local Items = require("ArenaItems")
local Scenes = require("ArenaScenes")

local nextAddress = 0
local function object(fields)
    nextAddress = nextAddress + 1
    fields.address = nextAddress
    fields.IsValid = function(self) return not self.destroyed end
    fields.GetAddress = function(self) return self.address end
    fields.GetFName = function(self) return self.name end
    return fields
end

local actorClass = object({ name = "Actor" })
local pickupClass = object({ name = "PBZPickupActor" })
local interactionClass = object({})
local function class(name, pickup)
    return object({
        name = name,
        IsChildOf = function(_, parent) return parent == pickupClass and pickup == true end,
    })
end

local chest = class("BP_Chest_C")
local memoryFlower = class("BP_FlowInteract_MemoryFlower_C")
local hangingGift = class("BP_HangingGift_C")
local giftSpawner = class("BP_MultiChaosSpawner_HangingGift_C")
local container = class("BP_Rubbish_b_C")
local pickup = class("NativeSpawnedPickup", true)
local story = class("BP_FlowInteractActor_C")
local characterProp = class("BP_FlowInteractActor_Character_C")
local bell = class("BP_MelodiousBell_C")
local door = class("BP_SingleDoor_C")
local skeletal = class("SkeletalMeshActor")
local storyName = next(require("ArenaItemActors").BP_FlowInteractActor_C)

local beginPlay
function RegisterBeginPlayPostHook(callback)
    assert(not beginPlay)
    beginPlay = callback
end
function StaticFindObject(path)
    return ({
        ["/Script/Engine.Actor"] = actorClass,
        ["/Script/ProjectPBZ.PBZPickupActor"] = pickupClass,
        ["/Script/ProjectPBZ.PBZInteractComponent"] = interactionClass,
    })[path]
end

local pawn = {
    GetComponentByClass = function(_, wanted)
        assert(wanted == interactionClass)
        return object({ RemovePotentialInteract = function(_, actor) actor.cacheCleared = true end })
    end,
}
local listed, scans = {}, 0
local clock = 0
local gameplay = {
    GetRealTimeSeconds = function(_, context)
        assert(context == pawn)
        return clock
    end,
    GetAllActorsOfClass = function(_, context, base, out)
        assert(context == pawn and base == actorClass)
        scans = scans + 1
        for _, actor in ipairs(listed) do out[#out + 1] = actor end
    end,
}
local function place(kind, world, id)
    local level = object({ OwningWorld = world })
    return object({
        name = id or kind.name,
        world = world,
        bHidden = false, collision = true, ticking = true, destroyCalls = 0,
        GetClass = function() return kind end,
        HasAnyFlags = function(self) return self.unloading == true end,
        IsActorBeingDestroyed = function(self) return self.destroyed == true end,
        GetLevel = function() return level end,
        SetActorEnableCollision = function(self, value)
            if not self.refuseIsolation then self.collision = value end
        end,
        SetActorHiddenInGame = function(self, value) self.bHidden = value end,
        SetActorTickEnabled = function(self, value) self.ticking = value end,
        GetActorEnableCollision = function(self) return self.collision end,
        IsActorTickEnabled = function(self) return self.ticking end,
        K2_GetComponentsByClass = function() return {} end,
        K2_DestroyActor = function(self)
            assert(self.cacheCleared, "stale interaction cache")
            self.destroyCalls = self.destroyCalls + 1
            if not self.refuseDestroy then self.destroyed = true end
        end,
    })
end

local scenes = Scenes.list()
assert(#scenes == 52)
for _, scene in ipairs(scenes) do
    local world = object({ name = scene.map })
    local other = object({ name = scene.map })
    local items = {
        place(chest, world), place(memoryFlower, world), place(hangingGift, world), place(giftSpawner, world),
        place(container, world), place(pickup, world), place(story, world, storyName),
    }
    if scene.cinematicProps then
        items[#items + 1] = place(skeletal, world, next(scene.cinematicProps))
    end
    if scene.hiddenStoryProps then
        items[#items + 1] = place(characterProp, world, next(scene.hiddenStoryProps))
    end
    local untouched = { place(chest, other), place(bell, world), place(door, world, storyName), place(story, world, "DoorFlow") }
    listed = {}
    for _, actor in ipairs(items) do listed[#listed + 1] = actor end
    for _, actor in ipairs(untouched) do listed[#listed + 1] = actor end
    assert(Items.update(gameplay, pawn, world, scene))
    for _, item in ipairs(items) do assert(item.destroyed, scene.id .. ":" .. item.name) end
    for _, item in ipairs(untouched) do assert(not item.destroyed and not item.cacheCleared) end

    local late = place(chest, world, "LateChest")
    beginPlay({ get = function() return late end })
    assert(not late.destroyed, "must defer destruction until after BeginPlay")
    assert(Items.update(gameplay, pawn, world, scene))
    assert(late.destroyed)
end
assert(scans == 52, "sweep each world once")

local scene = scenes[1]
local world = object({ name = scene.map })
local temporary = place(container, world, "StreamingContainer")
temporary.refuseDestroy = true
listed = { temporary }
assert(Items.update(gameplay, pawn, world, scene))
assert(temporary.bHidden and temporary.cacheCleared and not temporary.collision and not temporary.ticking)
assert(not temporary.destroyed and temporary.destroyCalls == 1)

local late = place(pickup, world, "StreamingPickup")
beginPlay(late)
clock = 0.5
assert(Items.update(gameplay, pawn, world, scene) and late.destroyed and temporary.destroyCalls == 1)
clock = 1.1
temporary.refuseDestroy = false
assert(Items.update(gameplay, pawn, world, scene) and temporary.destroyed and temporary.destroyCalls == 2)

local stubborn = place(chest, world, "StubbornChest")
stubborn.refuseDestroy, stubborn.refuseIsolation = true, true
beginPlay(stubborn)
local clean, why = Items.update(gameplay, pawn, world, scene)
assert(not clean and why:find("StubbornChest", 1, true))
stubborn.refuseDestroy = false
assert(Items.update(gameplay, pawn, world, scene) and stubborn.destroyed)

local unloading = place(chest, world, "UnloadingChest")
beginPlay(unloading)
unloading.unloading = true
assert(Items.update(gameplay, pawn, world, scene))
assert(not unloading.cacheCleared)

local departed = place(chest, world, "DepartedChest")
beginPlay(departed)
Items.reset()
beginPlay(departed)
local newWorld = object({ name = scene.map })
local reloaded = place(chest, newWorld, "DepartedChest")
listed = { departed, reloaded }
assert(Items.update(gameplay, pawn, newWorld, scene))
assert(reloaded.destroyed and not departed.destroyed)

-- Stock travel suppresses streamed items before the player can interact.
-- Blueprint field wrappers and destruction remain outside the load callback.
local pre, post
local find = StaticFindObject
function StaticFindObject(path)
    return find(path) or object({ name = path, DoesImplementInterface = function() return false end })
end
function RegisterHook() return 1, 2 end
function RegisterBeginPlayPreHook(callback) pre = callback end
function RegisterBeginPlayPostHook(callback) post = callback end
local events = require("MeiGuHuOriginalEvents")
require("SceneArena").runtimeWorld = function() return world end
function newWorld:GetFullName() return "World " .. scene.originalPath .. "." .. scene.map end
world.GetFullName = newWorld.GetFullName
local otherWorld = object({ GetFullName = function() return "World /Game/Maps/Other.Other" end })
local loadScene = setmetatable({
    hiddenStoryProps = { LoadingCorpse = { className = characterProp.name } },
    cinematicProps = { LoadingCinematicProp = true },
}, { __index = scene })
Items.reset()
events.arm(nil, "blocked", loadScene.checkpointBell, loadScene)
local examined = 0
local loadingChest = setmetatable(place(chest, newWorld), {
    __index = function(_, field)
        if field:find("Interact", 1, true) or field == "BP_PBZFlowComponent" then
            examined = examined + 1
            error("Blueprint fields may be unavailable during map load")
        end
    end,
})
local loadingItems = {
    loadingChest, place(memoryFlower, newWorld), place(hangingGift, newWorld), place(giftSpawner, newWorld),
    place(container, newWorld), place(pickup, newWorld), place(story, newWorld, storyName),
    place(characterProp, newWorld, "LoadingCorpse"), place(skeletal, newWorld, "LoadingCinematicProp"),
}
post(loadingChest)
assert(not loadingChest.bHidden, "wait for the authorized map transition")
events.onMapPre()
local previousChest, foreignChest = place(chest, world), place(chest, otherWorld)
post(previousChest)
post(foreignChest)
assert(not previousChest.bHidden and not foreignChest.bHidden)

pre(loadingChest)
assert(not loadingChest.bHidden and loadingChest.collision and loadingChest.ticking)
for _, item in ipairs(loadingItems) do
    post({ get = function() return item end })
    assert(item.bHidden and not item.collision and not item.ticking and item.destroyCalls == 0)
    assert(not item.cacheCleared, "the load callback has no player interaction cache")
end
assert(examined == 0, "inspect native actor flags only")

local keepBell = place(bell, newWorld, loadScene.checkpointBell.name)
keepBell.BellID = loadScene.checkpointBell.id
local keepDoor = place(door, newWorld, "AllowedDoor")
local keepMesh = place(skeletal, newWorld, "AllowedScenery")
for _, actor in ipairs({keepBell, keepDoor, keepMesh}) do
    post(actor)
    assert(not actor.bHidden and actor.collision and actor.ticking and actor.destroyCalls == 0)
end

local say = print
local log = {}
print = function(message) log[#log + 1] = message; say(message) end
assert(events.arrive(newWorld))
assert(log[#log]:find("masked_during_load=" .. #loadingItems, 1, true))
local streamedChest = place(chest, newWorld, "StreamedAfterArrival")
post(streamedChest)
assert(streamedChest.bHidden and not streamedChest.collision and streamedChest.destroyCalls == 0)
events.ready()
assert(log[#log]:find("items_masked_streaming=1", 1, true))
print = say

listed = loadingItems
listed[#listed + 1] = streamedChest
listed[#listed + 1] = keepBell
listed[#listed + 1] = keepDoor
listed[#listed + 1] = keepMesh
assert(Items.update(gameplay, pawn, newWorld, loadScene))
assert(loadingChest.destroyed and streamedChest.destroyed)
assert(not keepBell.destroyed and not keepDoor.destroyed and not keepMesh.destroyed)
events.reset()
local afterExit = place(chest, newWorld, "AfterExit")
post(afterExit)
assert(not afterExit.bHidden and afterExit.collision)

print("PASS 52 scenes, load and streaming suppression, previous-world exclusion, preserved bell/geometry and deferred destruction")
