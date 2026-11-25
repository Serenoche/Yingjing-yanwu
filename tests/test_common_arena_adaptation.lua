local Terrain = require("ArenaTerrain")
local Scenes = require("ArenaScenes")
local Menu = require("ArenaMenuData")

local general, solo = 0, 0
for _, scene in ipairs(Scenes.list(true, "challenge")) do
    if not Menu.exclusiveScenes[scene.id] then
        local isSolo = Menu.soloScenes[scene.id] == true
        assert(scene.bossRecovery and scene.guardTerrainDefeat and scene.edgeProtection, scene.id)
        assert(scene.portableBossMechanics == (not isSolo), scene.id)
        assert(#scene.combatBoundary >= 3 and scene.combatHeight.min < scene.combatHeight.max, scene.id)
        local inBounds = 0
        for _, point in ipairs(scene.spawnPoints) do
            if Terrain.contains(point, scene.combatBoundary) then inBounds = inBounds + 1 end
        end
        assert(inBounds >= 3, scene.id .. " has fewer than three in-bounds spawn options")
        if isSolo then solo = solo + 1 else general = general + 1 end
    else
        assert(not scene.edgeProtection and not scene.portableBossMechanics, scene.id)
    end
end
if #Scenes.list(true, "challenge") == 52 then
    assert(general == 13 and solo == 27 and not Scenes.get("xigu", "bloody-palace").bossRecovery)
end
assert(Scenes.get("meiguhu", "challenge").edgeProtection)

local nextAddress = 0
local function object(properties)
    local value = properties or {}
    nextAddress = nextAddress + 1
    value.address = nextAddress
    function value:IsValid() return not self.destroyed end
    function value:GetAddress() return self.address end
    function value:GetFName() return "object_" .. self.address end
    return value
end

local world, foreignWorld = object(), object()
local function actor(point, currentWorld)
    local value = object({ location = point, world = currentWorld or world,
        angles = { Pitch = 0, Yaw = 0, Roll = 0 }, Tags = {}, Settings = {} })
    function value:HasAnyFlags() return false end
    function value:IsActorBeingDestroyed() return self.destroyed == true end
    function value:IsAlive() return not self.dead end
    function value:K2_GetActorLocation() return self.location end
    function value:K2_GetActorRotation() return self.angles end
    function value:K2_SetActorLocationAndRotation(at, angles) self.location, self.angles = at, angles; return true end
    function value:SetOwner(owner) self.owner = owner end
    function value:GetOwner() return self.owner end
    function value:SetActorEnableCollision(enabled) self.collision = enabled end
    function value:SetActorHiddenInGame(hidden) self.hidden = hidden end
    function value:K2_DestroyActor() self.destroyed = true end
    function value:ActorHasTag(tag)
        for _, item in ipairs(self.Tags) do if item == tag then return true end end
        return false
    end
    function value:GetAISpawner() return self.origin end
    function value:OnSpawnFromSpawner(origin) self.origin = origin end
    function value:GetCurrentMontage() return nil end
    value.Arrow = object()
    value.CharacterMovement = object({ MovementMode = 1, Velocity = { Z = 0 } })
    function value.CharacterMovement:StopMovementImmediately() self.Velocity.Z = 0 end
    function value.CharacterMovement:SetMovementMode(mode) self.MovementMode = mode end
    value.CapsuleComponent = object({
        GetScaledCapsuleHalfHeight = function() return 85 end,
        GetScaledCapsuleRadius = function() return 55 end,
    })
    value.AttributeSetBase = object({ Health = { CurrentValue = 100 } })
    value.AbilitySystemComponent = object({ GetGameplayTagCount = function() return 0 end })
    return value
end

package.loaded.SceneArena = {
    runtimeWorld = function(value) return value and value.world end,
    actorIsInWorld = function(value, expected)
        return value and value:IsValid() and value.world == expected
    end,
}
local engagementCalls = 0
package.loaded.EncounterEngage = { start = function()
    engagementCalls = engagementCalls + 1
    return true
end }
local classes, spawned, native = {}, {}, {}
package.loaded.SpawnClass = { resolve = function(path)
    classes[path] = classes[path] or object({ path = path })
    return classes[path]
end }

local scene = {
    id = "test_portable", name = "离线战区", rotation = { Yaw = 0 },
    combatHeight = { min = 80, max = 150 }, spawnTrace = { top = 300, bottom = 0 },
    combatBoundary = { {X=-2500,Y=-2000}, {X=2500,Y=-2000}, {X=2500,Y=2000}, {X=-2500,Y=2000} },
    phaseReturnPoints = { {X=0,Y=0,Z=100} },
    spawnPoints = { {X=-1000,Y=0,Z=100}, {X=1000,Y=0,Z=100}, {X=0,Y=900,Z=100} },
}
Terrain.protect(scene, true)

local mathLibrary = object({ MakeTransform = function(_, at, facing) return { at = at, facing = facing } end })
local actorLibrary = object({ SpawnActorDeferred = function(_, _, class, transform)
    local value = actor(transform.at)
    value.class = class
    spawned[#spawned+1] = value
    return value
end })
local navigation = object({
    K2_ProjectPointToNavigation = function(_, _, at, out)
        out.X, out.Y, out.Z = at.X, at.Y, at.Z
        return true
    end,
    FindPathToLocationSynchronously = function(_, _, from, to)
        return object({ PathPoints = { from, to }, IsPartial = function() return false end })
    end,
})
local nativeTeleport = object({ PBZActorTeleportTo = function(_, value, at)
    value.location, value.returns = at, (value.returns or 0)+1
    return true
end })
local api = {
    KismetMathLibrary = mathLibrary,
    SGameAIFunctionLibrary = actorLibrary,
    NavigationSystemV1 = navigation,
    PBZBlueprintFunctionLibrary = nativeTeleport,
    AbilityUtils = object({ CancelAbilitiesByTag = function() end }),
    PostProcessVolume = object(),
}
function StaticFindObject(path) return api[path:match("([%w_]+)$"):gsub("^Default__", "")] end
function FName(value) return value end

local system = {}
function system:LineTraceSingle(_, from, to, _, _, _, _, hit)
    if from.Z < 100 or to.Z > 100 or not Terrain.contains(from, scene.combatBoundary) then return false end
    if self.gap and from.X > 900 then return false end
    hit.ImpactPoint = { X = from.X, Y = from.Y, Z = 100 }
    hit.ImpactNormal = { Z = 1 }
    return true
end
system.LineTraceSingleForObjects = system.LineTraceSingle
function system:ConvertToObjectType(value) return value end
function system:CapsuleTraceSingleForObjects() return self.blocked == true end
local gameplay = {}
function gameplay:FinishSpawningActor(value) return value end
function gameplay:IsGamePaused() return false end
function gameplay:GetActorOfClass(_, class)
    for _, list in ipairs({ native, spawned }) do
        for _, value in ipairs(list) do if value:IsValid() and value.class == class then return value end end
    end
end
function gameplay:GetAllActorsOfClass(_, class, out)
    for _, list in ipairs({ native, spawned }) do
        for _, value in ipairs(list) do if value:IsValid() and value.class == class then out[#out+1] = value end end
    end
end

local pawn = actor({ X = 0, Y = 550, Z = 185 })
local duyan = "BP_Monster_DuYanBoss"
local leiDang = "BP_Monster_LeiDang_P2"
local scavenger = "BP_Monster_Scavenger"
local centerClass = require("SpawnClass").resolve(
    "/PBZCombatAsset/ActorData/Mobs/059_DuYan/BP_DuYan_CA_Snap_Center.BP_DuYan_CA_Snap_Center_C")
local marker = actor({ X = 9400, Y = 100, Z = 120 })
marker.class = centerClass
native[1] = marker
local Props = require("ArenaBossMechanics")
local selected = { members = { {id=duyan}, {id=leiDang}, {id=scavenger} } }
local props = assert(Props.new(pawn, gameplay, system, scene, selected))
assert(Terrain.contains(marker.location, scene.combatBoundary) and #props.created == 6)
local lei = actor({ X = -950, Y = 0, Z = 185 })
props:bind(lei, { id = leiDang }, { X = -950, Y = 0, Z = 100 }, scene.rotation)
assert(lei.origin.SpawnedAI == lei and lei.origin.location.Z == 100 and not lei.origin.ShouldSpawn)
props:close()
assert(marker:IsValid() and marker.location.X == 9400 and #props.created == 0)
for _, value in ipairs(spawned) do assert(not value:IsValid()) end

native[1] = actor({ X = 9400, Y = 100, Z = 120 }, foreignWorld)
native[1].class = centerClass
assert(not pcall(Props.new, pawn, gameplay, system, scene, selected))
assert(native[1]:IsValid() and native[1].location.X == 9400)

local Recovery = require("XiguBossRecovery")
local boss = actor({ X = -1000, Y = 0, Z = 185 })
local run = { scene = scene, entry = {id="boss"}, stageIndex = 1, encounterWorld = world:GetAddress(),
    ownedActors = { [boss:GetAddress()] = true }, status = "combat", bosses = { boss }, startedAt = 1 }
assert(not Recovery.update(run, gameplay, system, pawn, 1))
boss.location.Z = 4600
boss.CharacterMovement.MovementMode = 3
assert(not Recovery.update(run, gameplay, system, pawn, 1.15) and not boss.returns)
boss.location = { X = 2640, Y = 0, Z = 225 }
boss.CharacterMovement.Velocity.Z = -700
assert(Recovery.update(run, gameplay, system, pawn, 1.30) and boss.returns == 1)
assert(Terrain.contains(boss.location, scene.combatBoundary) and boss.CharacterMovement.MovementMode == 1)

boss.location = { X = 1100, Y = 0, Z = 225 }
boss.CharacterMovement.MovementMode, boss.CharacterMovement.Velocity.Z = 3, -700
assert(not Recovery.update(run, gameplay, system, pawn, 2.2) and boss.returns == 1)
system.gap = true
assert(Recovery.update(run, gameplay, system, pawn, 2.35) and boss.returns == 2)
system.gap = false

boss.dead, boss.location.Z = true, 185
local pending, reason = Recovery.update(run, gameplay, system, pawn, 2.5, true)
assert(not pending and not reason, "normal in-bounds defeat should count")
boss.location.Z = -300
pending, reason = Recovery.update(run, gameplay, system, pawn, 2.6, true)
assert(not pending and reason, "terrain death must be trapped before settlement")

boss.dead, boss.location.Z = false, -300
run.bossRecoveryState = nil
system.blocked = true
assert(Recovery.update(run, gameplay, system, pawn, 3))
pending, reason = Recovery.update(run, gameplay, system, pawn, 4.10)
assert(not pending and reason and boss.returns == 2, "unsafe recovery should restart instead of teleporting")

system.blocked = false
Terrain.protect(scene)
assert(not Props.new(pawn, gameplay, system, scene, selected), "SOLO keeps its original scene mechanics")
local arriving = actor({ X = -1000, Y = 0, Z = -300 })
local address = arriving:GetAddress()
run.status, run.stageIndex, run.transitionStep = "transition", 2, "out"
run.bosses, run.ownedActors = { arriving }, { [address] = true }
run.restartAfterBossExit = function(self, cause) self.restartReason = cause end
assert(not Recovery.protectArrival(run, gameplay, system, pawn, 5))
assert(not arriving.returns and not run.restartReason)

run.transitionStep = "loading"
local callsBeforeArrival = engagementCalls
assert(Recovery.protectArrival(run, gameplay, system, pawn, 5.1) and arriving.returns == 1)
assert(not Recovery.protectArrival(run, gameplay, system, pawn, 6))
run.transitionStep = "engage"
run.engagePending, run.engageRequests = { [address] = true }, { [address] = {} }
arriving.location.Z = -300
assert(Recovery.protectArrival(run, gameplay, system, pawn, 6.1) and arriving.returns == 2)
assert(not run.engagePending[address] and not run.engageRequests[address])
assert(not Recovery.protectArrival(run, gameplay, system, pawn, 6.3) and engagementCalls == callsBeforeArrival)
assert(not run.restartReason, "recovery must leave engagement to the phase transition")

arriving.dead = true
assert(not Recovery.protectArrival(run, gameplay, system, pawn, 6.5))
arriving.destroyed = true
assert(not Recovery.protectArrival(run, gameplay, system, pawn, 6.7), "a defeated actor may retire normally")
local lost = actor({ X = -1000, Y = 0, Z = 185 })
run.bosses, run.ownedActors = { lost }, { [lost:GetAddress()] = true }
run.transitionStep, run.phaseTravel = nil, { restored = false }
lost.destroyed = true
assert(not Recovery.protectArrival(run, gameplay, system, pawn, 7))
run.phaseTravel.restored = true
assert(Recovery.protectArrival(run, gameplay, system, pawn, 7) and run.restartReason,
    "a newly spawned boss disappearing after map travel must restart")

local rider = actor({ X = -1000, Y = 0, Z = -300 })
run.bosses, run.ownedActors = { rider }, { [rider:GetAddress()] = true }
run.mountPreparation, run.mounts = {}, { { rider = rider } }
local handled, restarted = Recovery.protectArrival(run, gameplay, system, pawn, 8)
assert(handled and restarted and not rider.returns and run.restartReason:find("骑乘组合", 1, true),
    "an unfinished mounted pair must restart together")

print(("Arena protection passed for %d general and %d SOLO maps, including phase arrival"):format(general, solo))
