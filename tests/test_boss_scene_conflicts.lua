-- Run with package.path pointing to either of the assembled 2.0.2 Lua runtimes.
local address = 0
local function object(fields)
    fields = fields or {}
    address = address + 1
    local id = address
    function fields:IsValid() return not self.destroyed end
    function fields:GetAddress() return id end
    return fields
end
local function vector(x, y, z) return {X=x, Y=y, Z=z} end
local origin, unit = vector(0, 0, 0), vector(1, 1, 1)
local flat = {Pitch=0, Yaw=0, Roll=0}
local world, packageWorld, foreignWorld = object(), object(), object()
local actorClass, componentClass = object(), object()
local classes, actors, spawned = {}, {}, {}
local function classFor(path)
    classes[path] = classes[path] or object({path=path})
    return classes[path]
end
local function actor(class, location, owningWorld)
    local value = object({class=class, location=location, rotation=flat, scale=unit})
    value.level = object({OwningWorld=owningWorld or world})
    function value:IsA(kind) return kind == actorClass or kind == self.class end
    function value:GetLevel() return self.level end
    function value:GetWorld() return packageWorld end
    function value:HasAnyFlags() return self.pending == true end
    function value:IsActorBeingDestroyed() return self.destroying == true end
    function value:GetOwner() return self.owner end
    function value:SetOwner(owner) self.owner = owner end
    function value:K2_GetActorLocation() return self.location end
    function value:K2_GetActorRotation() return self.rotation end
    function value:GetActorScale3D() return self.scale end
    function value:K2_SetActorLocationAndRotation(at, rotation)
        self.location, self.rotation = at, rotation
        return true
    end
    function value:K2_SetActorTransform(transform)
        self.location, self.rotation, self.scale = transform.location, transform.rotation, transform.scale
        return true
    end
    function value:K2_DestroyActor() self.destroyed = true end
    function value:SetActorHiddenInGame() end
    function value:SetActorEnableCollision() end
    function value:DespawnSnake() self.despawned = true end
    value.Arrow = object({K2_GetComponentLocation=function() return value.location end})
    actors[#actors + 1] = value
    return value
end
local function areaActor(class, location, extent, owningWorld)
    local area = actor(class, location, owningWorld)
    area.extent = extent
    area.Spline = object()
    area.DynamicMeshComponent = object({SetCollisionEnabled=function() end})
    area.ActivatedPoles, area.DeactivatedPoles, area.PolesPlayerCanJump, area.CabbagePoles = {}, {}, {}, {}
    area.ActivatedLinks, area.DeactivatedLinks = {}, {}
    function area:CheckIfPointLiesInsideArea(at)
        return math.abs(at.X-self.location.X) <= self.extent.X*self.scale.X
            and math.abs(at.Y-self.location.Y) <= self.extent.Y*self.scale.Y
            and math.abs(at.Z-self.location.Z) <= self.extent.Z*self.scale.Z
    end
    function area:GetActorBounds(colliding, outOrigin, outExtent)
        assert(colliding)
        for _, axis in ipairs({"X","Y","Z"}) do
            outOrigin[axis], outExtent[axis] = self.location[axis], self.extent[axis]*self.scale[axis]
        end
    end
    function area:SetActorScale3D(scale) self.scale = scale end
    function area:UpdateSplinePointsArray() end
    function area:TryUpdateActorInTriggerState(_, inside) self.inside = inside end
    function area:SetEnabled(enabled) self.enabled = enabled end
    function area:AddComponentByClass()
        local box = object()
        for _, name in ipairs({"SetBoxExtent","SetCollisionProfileName","SetCollisionResponseToAllChannels",
            "SetCollisionResponseToChannel","SetGenerateOverlapEvents","SetCollisionEnabled"}) do
            box[name] = function() end
        end
        return box
    end
    function area:SpawnPole(transform, _, class)
        local pole = actor(class, transform.location)
        pole.Area = self
        pole.SM_WoodPost_001 = object({SetCollisionEnabled=function() end})
        pole.StandPoint = object({K2_GetComponentLocation=function()
            return vector(pole.location.X,pole.location.Y,pole.location.Z+500)
        end})
        self.ActivatedPoles[#self.ActivatedPoles + 1] = pole
        return pole
    end
    return area
end

local areaPath = "/Game/PBZContent/Blueprint/TriggerVolume/BP_LionDance_Area.BP_LionDance_Area_C"
local whiteRoot = "/PBZCombatAsset/ActorData/Mobs/065_ChiLian_P2/"
local centerClass = classFor(whiteRoot.."BP_ChiLian_P2_Center.BP_ChiLian_P2_Center_C")
local snakePointClass = classFor(whiteRoot.."BP_ChiLian_CA_SnakeSpawner.BP_ChiLian_CA_SnakeSpawner_C")
local pawn = actor(actorClass, origin)
function pawn:GetWorld() return world end
local spawner = object()
function spawner:SpawnActorDeferred(_, class, transform)
    local value
    if class.path == areaPath then value = areaActor(class, transform.location, vector(100,100,100))
    else value = actor(class, transform.location) end
    value.rotation, value.scale = transform.rotation, transform.scale
    spawned[#spawned + 1] = value
    return value
end
local gameplay = object()
function gameplay:GetAllActorsOfClass(context, class, out)
    assert(context == pawn)
    for _, value in ipairs(actors) do
        if value.class == class and value:IsValid() then
            out[#out + 1] = {get=function() return value end}
        end
    end
end
function gameplay:GetActorOfClass(context, class)
    assert(context == pawn)
    for _, value in ipairs(actors) do
        if value.class == class and value:IsValid() and value.level.OwningWorld == world then return value end
    end
end
function gameplay:FinishSpawningActor(value) return value end
function gameplay:BeginDeferredActorSpawnFromClass(context, class, transform, _, owner)
    local value = spawner:SpawnActorDeferred(context,class,transform)
    value:SetOwner(owner)
    return value
end
function gameplay:GetRealTimeSeconds() return 10 end
local system = {}
function system:LineTraceSingle(_, from, _, _, _, _, _, out)
    out.ImpactPoint, out.ImpactNormal = vector(from.X,from.Y,0), vector(0,0,1)
    return true
end
local mathLibrary = object({
    FindLookAtRotation=function() return flat end,
    MakeTransform=function(_, at, rotation, scale)
        return {location=at, rotation=rotation, scale=scale}
    end,
})
local reflected = {
    ["/Script/Engine.Actor"]=actorClass, ["/Script/Engine.ActorComponent"]=componentClass,
    ["/Script/Engine.Default__KismetMathLibrary"]=mathLibrary,
    ["/Script/SGameAI.Default__SGameAIFunctionLibrary"]=spawner,
    ["/Script/Engine.BoxComponent"]=object(),
}
function StaticFindObject(path) return reflected[path] end
function FName(name) return name end
function FindAllOf() return {} end
package.loaded.SpawnClass = {resolve=classFor}

local lion = require("LionArena")
local areaClass = classFor(areaPath)
local scene = {id="lake", anchor=origin, spawnPoints={vector(5000,0,0)}, spawnTrace={top=500,bottom=-500}}
local distant = areaActor(areaClass,vector(16000,0,1500),vector(200,200,800))
local foreign = areaActor(areaClass,vector(2500,0,1500),vector(200,200,800),foreignWorld)
local overlap = areaActor(areaClass,vector(2500,0,1500),vector(200,200,800))
local waiting, reason = lion.new(pawn,scene,gameplay,system)
assert(not waiting and reason:find("重叠",1,true) and #spawned == 0)
overlap.extent = origin
local lionSession = assert(lion.new(pawn,scene,gameplay,system))
assert(lionSession.area.enabled and #lionSession.area.ActivatedPoles == 4)
local exits = lionSession.area.ActivatedPoles
overlap.extent = vector(200,200,800)
local ok = pcall(lionSession.update,lionSession,pawn,2)
assert(not ok)
lionSession:close()
assert(not lionSession.area:IsValid() and distant:IsValid() and foreign:IsValid() and overlap:IsValid())
for _, exit in ipairs(exits) do assert(not exit:IsValid()) end
assert(distant.enabled == nil and foreign.enabled == nil and overlap.enabled == nil)

local white = require("ChiLianArena")
local stockCenter, stockSnakePoint = actor(centerClass,origin), actor(snakePointClass,origin)
local otherCenter = actor(centerClass,origin,foreignWorld)
local first = #spawned
waiting, reason = white.new(pawn,gameplay,system,origin,flat,scene)
assert(not waiting and reason:find("已有",1,true) and #spawned == first)
stockCenter.destroyed = true
waiting = white.new(pawn,gameplay,system,origin,flat,scene)
assert(not waiting and #spawned == first)
stockSnakePoint.destroyed = true
local whiteSession = assert(white.new(pawn,gameplay,system,origin,flat,scene))
assert(#spawned == first+5 and whiteSession:owns(whiteSession.center))
whiteSession:update(pawn,0)
local lateCenter = actor(centerClass,origin)
ok = pcall(whiteSession.update,whiteSession,pawn,1)
assert(not ok)
whiteSession:close()
assert(otherCenter:IsValid() and lateCenter:IsValid())
for _, helper in ipairs(whiteSession.actors) do assert(not helper:IsValid()) end

local cold = require("LengTuArena")
local marker = "BP_LengTu_SummonSlot_02"
local markerClass = classFor("/PBZCombatAsset/ActorData/Mobs/077_LengTu/"..marker.."."..marker.."_C")
local original = vector(-193897.48,-112497.58,62018.957)
local resident = actor(markerClass,original)
resident.rotation = {Pitch=0,Yaw=80,Roll=0}
local markerId = marker.."_C_UAID_E89C25A7512037EE02_2051815571"
function resident:GetFName() return markerId end
local map = "/Game/Maps/B08_09_12_13/PBZ_Duanhun_WP"
local worldName = "PBZ_Duanhun_WP"
local spatialCell = map.."/_Generated_/2UDHA78THAAQTQAEHZG5XTBPY"
resident.package = spatialCell
function resident:GetFullName() return marker.."_C "..self.package.."."..worldName..":PersistentLevel."..markerId end
local desired = {location=vector(50,100,200), rotation=flat}
local points = {toBattle=desired,offBattle=desired,summon1=desired,summon2=desired,summon3=desired}
local coldSession = assert(cold.new(gameplay,pawn,points))
assert(coldSession:ownsMarker(resident) and resident.location.X == desired.location.X)
resident.package = map
assert(coldSession:update(pawn))
coldSession:close()
assert(resident:IsValid() and resident.location.X == original.X and resident.rotation.Yaw == 80)

local callbacks = {}
function RegisterHook(path, callback)
    assert(not callbacks[path])
    callbacks[path] = callback
    return 1,2
end
function UnregisterHook(path) callbacks[path] = nil end
package.loaded.XiguArena = {
    mechanicGround=function() return 0 end,
    portalDestination=function() return {rotation=flat,frontX=1,frontY=0} end,
    phaseDestination=function() return {position=origin} end,
}
local zuo = require("BloodyPalaceMechanics")
local xigu = {id="xigu",portalPoint=origin}
local ending = "BP_Monster_ZuoShang_Ending"
local stage = {members={{id=ending}}}
local root = "/PBZCombatAsset/ActorData/Mobs/054_ZuoShang/"
local snap = "BP_ZuoShang_CA_03_SnapPoint"
local grab = "GA_ZuoShang_CA_GEx_01"
reflected[root.."Ability/Abilities/"..grab.."."..grab.."_C:K2_ActivateAbility"] = object()
local stockSnap = actor(classFor(root..snap.."."..snap.."_C"),vector(4,5,6))
assert(stockSnap:GetWorld() ~= pawn:GetWorld() and stockSnap:GetLevel().OwningWorld == world)
if CHECKPOINT_RUNTIME then
    local night = {id="night", anchor=origin, spawnPoints={origin}, spawnTrace={top=500,bottom=-500}}
    local mechanics = assert(zuo.new(pawn,gameplay,system,night,stage,false,true))
    assert(#mechanics.borrowed == 1 and #mechanics.actors == 3 and stockSnap.location.Z == 1402)
    mechanics:close()
    assert(stockSnap:IsValid() and stockSnap.location.Z == 6 and not next(callbacks))
end

local mechanics = assert(zuo.new(pawn,gameplay,system,xigu,stage,false,false))
assert(#mechanics.borrowed == 1 and #mechanics.actors == 3 and stockSnap.location.Z == 1402)
mechanics:close()
assert(stockSnap:IsValid() and stockSnap.location.Z == 6 and not next(callbacks))
stockSnap:SetOwner(pawn)
ok = pcall(zuo.new,pawn,gameplay,system,xigu,stage,false,false)
assert(not ok and stockSnap:IsValid() and stockSnap.location.Z == 6 and not next(callbacks))

local menuState, actions, preload = nil, nil, 0
local function noop() end
for _, name in ipairs({"CombatSpawn","ChallengeSignals","ChallengeVictory","EncounterPlayerState","StageFade",
    "EncounterEngage","ChallengeMedicine","JingYeMount","BattleMusic","GameplayDifficulty","BloodyPalaceProgress",
    "PracticeBossInfo","PracticeHud","DreamPalaceFormation"}) do
    package.loaded[name] = {close=noop}
end
package.loaded.PlayerProfile = {id=function() return "fixture" end}
package.loaded.ChallengeMenu = {close=noop, update=function(_, _, state, callback)
    menuState,actions=state,callback
    return false
end}
package.loaded.RetryPreload = {close=noop, start=function() preload=preload+1 end}
local Challenge = require("Challenge")
local function run(mode)
    local challenge = setmetatable({entry={id="fixture",name="fixture",stages={{members={}}}},scene=scene,
        mode=mode,stageIndex=1,status="combat",startedAt=2,bosses={},ownedActors={},checkpointLoadout=noop},Challenge)
    challenge.onMenuAction = function(action) challenge:queueAction(action) end
    return challenge
end
for _, mode in ipairs({"challenge","practice"}) do
    local challenge = run(mode)
    assert(not challenge:canUseBell())
    challenge:fail("fixture mechanism conflict")
    challenge:tick(gameplay,system,pawn,10)
    assert(menuState.available and menuState.recoveryMessage=="fixture mechanism conflict")
    actions("retry")
    challenge:tick(gameplay,system,pawn,10)
    assert(challenge.status=="resetting" and challenge.reloadAt==10 and not challenge:canUseBell())
end
assert(preload==2)
local palace = run("bloody-palace")
palace.palace = {close=noop}
palace:fail("fixture mechanism conflict")
assert(not palace:canUseBell())
print("PASS scoped mechanism lookups, streamed and foreign actors, borrowed marker restore, and bell recovery")
