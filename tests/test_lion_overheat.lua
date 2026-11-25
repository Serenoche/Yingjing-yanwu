-- Run with the staged 2.1.0 Scripts directory on package.path.
local serial, subscriptions = 0, 0
local function object()
    serial = serial + 1
    local id = serial
    return {
        IsValid = function(self) return not self.destroyed end,
        HasAnyFlags = function() return false end,
        IsActorBeingDestroyed = function(self) return self.destroyed end,
        GetAddress = function() return id end,
        GetFName = function() return "Object" .. id end,
        K2_DestroyActor = function(self) self.destroyed = true end,
    }
end

local world, player = object(), object()
package.loaded.SceneArena = { runtimeWorld = function() return world end }
local spawners, failFinish = {}, false
local spawnerClass, mobGroupClass = object(), object()
local aiLibrary = object()
function aiLibrary:SpawnActorDeferred(pawn, class)
    assert(pawn == player and class == spawnerClass)
    local spawner = object()
    spawner.GetMobGroup = function(self) return self.MobGroup end
    spawner.GetPawn = function(self) return self.SpawnedAI end
    spawner.SetActorHiddenInGame = function(_, hidden) assert(hidden) end
    spawner.SetActorEnableCollision = function(_, enabled) assert(not enabled) end
    spawner.SetActorTickEnabled = function(_, enabled) assert(not enabled) end
    spawners[#spawners + 1] = spawner
    return spawner
end
function StaticFindObject(path)
    if path == "/Script/SGameAI.MobGroup" then return mobGroupClass end
    assert(path == "/Script/SGameAI.Default__SGameAIFunctionLibrary")
    return aiLibrary
end
function StaticConstructObject(class, outer)
    assert(class == mobGroupClass and outer == spawners[#spawners])
    local group = object()
    local listeners = {}
    function group:SetFloatParameter(name, value)
        assert(name == "Overheat")
        self.heat = value
        for _, listener in ipairs(listeners) do
            if listener:IsValid() then listener.hot = value >= 100 end
        end
    end
    function group:FindFloatParameter(name)
        assert(name == "Overheat")
        return self.heat
    end
    function group:bindNativePassive(actor)
        assert(not actor.groupBound)
        actor.groupBound = self
        listeners[#listeners + 1] = actor
        subscriptions = subscriptions + 1
    end
    return group
end
function FName(name) return name end
function RegisterHook() error("Overheat must not install a Lua hook") end
function LoopAsync() error("Overheat must not start a Lua timer") end

local gameplay = { FinishSpawningActor = function(_, spawner)
    assert(spawner.ShouldSpawn == false and spawner.InitialSpawn == false and not spawner.SpawnedAI)
    return spawner
end }
local transform = {}
package.loaded.CombatSpawn = {
    class = function() return spawnerClass end,
    finish = function(_, pawn, actor, at, cycle, challenge, stats)
        assert(pawn == player and at == transform and cycle == 2 and challenge and stats == "stats")
        local spawner = assert(actor:GetAISpawner())
        local group = assert(spawner:GetMobGroup())
        assert(group == actor:GetMobGroup() and spawner:GetPawn() == actor)
        if failFinish then error("simulated native FinishSpawning failure") end
        group:bindNativePassive(actor)
        return actor, 100
    end,
}

local function boss()
    local actor = object()
    function actor:OnSpawnFromSpawner(spawner)
        assert(self.Spawner == nil and spawner:GetPawn() == self)
        self.Spawner, self.MobGroup = spawner, spawner:GetMobGroup()
    end
    function actor:GetAISpawner() return self.Spawner end
    function actor:GetMobGroup() return self.MobGroup end
    return actor
end

local overheat = require("LionOverheat")
local first, second = { id = "BP_Monster_LionDancer" }, { id = "BP_Monster_LionDancer_P2" }
assert(overheat.required(first) and overheat.required(second) and not overheat.required({ id = "other" }))
local function finish(run, entry, actor)
    local spawned, level = overheat.finish(run, entry, gameplay, player, actor, transform, 2, "stats")
    assert(spawned == actor and level == 100)
end

local duel = { entry = first, stageIndex = 1 }
local single = boss()
finish(duel, first, single)
assert(single.groupBound.heat == 0 and subscriptions == 1)
single.groupBound:SetFloatParameter("Overheat", 99)
assert(not single.hot)
single.groupBound:SetFloatParameter("Overheat", 100)
assert(single.hot)
single:K2_DestroyActor()
overheat.clear(duel)
assert(not duel.lionOverheatGroups and not spawners[1]:IsValid())

local gauntlet = { entry = { id = "gauntlet_liondancer" }, stageIndex = 1 }
local phase1 = boss()
finish(gauntlet, first, phase1)
local source, group = phase1.Spawner, phase1.groupBound
group:SetFloatParameter("Overheat", 80)
phase1:K2_DestroyActor()
overheat.clear(gauntlet, true)
assert(source:IsValid() and not source.SpawnedAI)
gauntlet.stageIndex = 2
local phase2 = boss()
finish(gauntlet, second, phase2)
assert(phase2.Spawner == source and phase2.groupBound == group and group.heat == 80 and #spawners == 2)
group:SetFloatParameter("Overheat", 100)
assert(phase2.hot and not phase1.hot and subscriptions == 3)
phase2:K2_DestroyActor()
overheat.clear(gauntlet)
assert(not source:IsValid() and not gauntlet.lionOverheatGroups)

gauntlet.stageIndex, failFinish = 1, true
local failed = boss()
assert(not pcall(finish, gauntlet, first, failed))
assert(not failed:IsValid() and not spawners[3]:IsValid() and subscriptions == 3)
overheat.clear(gauntlet)
failFinish = false
local retried = boss()
finish(gauntlet, first, retried)
assert(retried.groupBound.heat == 0 and #spawners == 4 and subscriptions == 4)
retried:K2_DestroyActor()
overheat.clear(gauntlet)

print("Lion overheat spawn ordering, phase continuity and cleanup passed")
