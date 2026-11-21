local Bell = require("StockBellArena")
local SceneArena = require("SceneArena")

local Arena = { getBell = Bell.getBell, findBellWidgets = Bell.findBellWidgets, phaseDestination = Bell.phaseDestination }
local session
local FOG_CLASS = "/Game/PBZContent/Blueprint/Item/BP_FogDoor.BP_FogDoor_C"
local MATH = "/Script/Engine.Default__KismetMathLibrary"
local NAVIGATION = "/Script/NavigationSystem.Default__NavigationSystemV1"
local SMOKE = "/Game/PBZContent/VFX/SceneFX/SmokeAndFIre/"
local EFFECTS = { { name = "NS_SmokeWall_202", z = 0 }, { name = "NS_SmokeWall_201", z = 50 } }
local ONE = { X = 1, Y = 1, Z = 1 }
local WHITE = { R = 1, G = 1, B = 1, A = 1 }
local PENDING = 0x08023600

local function valid(object)
    return object and type(object.IsValid) == "function" and object:IsValid()
end

local function live(object)
    return valid(object) and not object:HasAnyFlags(PENDING)
end

local function required(path)
    local object = StaticFindObject(path)
    assert(live(object), "等待原版接口 " .. path)
    return object
end

local function inWorld(actor, world)
    if not live(actor) or actor:IsActorBeingDestroyed() then return false end
    local current = SceneArena.runtimeWorld(actor)
    return valid(current) and current:GetAddress() == world:GetAddress()
end

local function unwrap(object)
    if valid(object) then return object end
    return object and object:get()
end

local function log(message)
    print("[PBZShengQuXinChi] " .. message .. "\n")
end

local function distanceSquared(first, second)
    return (first.X - second.X)^2 + (first.Y - second.Y)^2 + (first.Z - second.Z)^2
end

local function nativePath(pawn, stair, boss)
    local navigation = required(NAVIGATION)
    local projected = {}
    for index, point in ipairs({ stair, boss }) do
        local result = {}
        if not navigation:K2_ProjectPointToNavigation(pawn, point, result, nil, nil, { X = 120, Y = 120, Z = 180 })
            or not result.X or distanceSquared(result, point) > 180^2 then
            return nil, "上层原生导航投影 " .. index
        end
        projected[index] = { X = result.X, Y = result.Y, Z = result.Z }
    end
    local path = navigation:FindPathToLocationSynchronously(pawn, projected[1], projected[2], pawn, nil)
    if not valid(path) or path:IsPartial() or #path.PathPoints < 2
        or distanceSquared(path.PathPoints[#path.PathPoints], projected[2]) > 180^2 then
        return nil, "楼梯口至 Boss 点的上层原生路径"
    end
    return true
end

local function findFog(gameplay, pawn, world, scene)
    local actors = {}
    gameplay:GetAllActorsOfClass(pawn, required(FOG_CLASS), actors)
    for _, object in ipairs(actors) do
        local actor = unwrap(object)
        if inWorld(actor, world) then
            local name = actor:GetFName()
            if (type(name) == "string" and name or name:ToString()) == scene.combatFog then return actor end
        end
    end
end

local function fogBoundary(door)
    local spline = door.Spline
    assert(live(spline), "等待原版战斗雾门样条")
    local length = spline:GetSplineLength()
    assert(length > 10000 and length < 40000, "原版战斗雾门样条长度异常")
    local polygon = {}
    local count = math.ceil(length / 400)
    for index = 0, count do
        local point = spline:GetLocationAtDistanceAlongSpline(length * index / count, 1)
        polygon[#polygon + 1] = { X = point.X, Y = point.Y }
    end
    -- The authored spline nearly meets its start point, even if its flag is open.
    assert((polygon[1].X - polygon[#polygon].X)^2 + (polygon[1].Y - polygon[#polygon].Y)^2 < 450^2,
        "原版战斗雾门边界未闭合")
    return polygon
end

local function inside(polygon, at)
    local previous, contained = polygon[#polygon], false
    for _, point in ipairs(polygon) do
        if (point.Y > at.Y) ~= (previous.Y > at.Y)
            and at.X < point.X + (previous.X - point.X) * (at.Y - point.Y) / (previous.Y - point.Y) then
            contained = not contained
        end
        previous = point
    end
    return contained
end

local function loadEffect(name)
    local path = SMOKE .. name .. "." .. name
    local asset = StaticFindObject(path)
    if live(asset) then return asset end
    local ok, loaded, _, complete = pcall(LoadAsset, path)
    if ok and complete == true and live(loaded) then return loaded end
    asset = StaticFindObject(path)
    if live(asset) then return asset end
end

local function clearPassages(passages)
    for _, passage in ipairs(passages) do
        for _, component in ipairs(passage.components) do
            if valid(component) then pcall(component.K2_DestroyComponent, component, component) end
        end
        if valid(passage.actor) then pcall(passage.actor.K2_DestroyActor, passage.actor) end
    end
end

local function makePassage(gameplay, pawn, world, gate, floor, effects, passage)
    local mathLibrary = required(MATH)
    local rotation = { Pitch = 0, Yaw = gate.yaw, Roll = 0 }
    local position = { X = gate.X, Y = gate.Y, Z = floor + 160 }
    local transform = mathLibrary:MakeTransform(position, rotation, ONE)
    local library = required("/Script/SGameAI.Default__SGameAIFunctionLibrary")
    local actor = library:SpawnActorDeferred(pawn, required("/Script/Engine.Actor"), transform, 3)
    assert(inWorld(actor, world), "通道 " .. gate.id .. " 的遮挡对象未创建")
    passage.actor = actor
    local finished = gameplay:FinishSpawningActor(actor, transform, 1)
    assert(valid(finished) and finished:GetAddress() == actor:GetAddress(), "通道遮挡对象未完成生成")

    local box = actor:AddComponentByClass(required("/Script/Engine.BoxComponent"), true, transform, true)
    assert(valid(box), "通道雾门碰撞组件未创建")
    box.bCanEverAffectNavigation = false
    box:SetBoxExtent({ X = gate.halfWidth, Y = 18, Z = 450 }, false)
    box:SetCollisionProfileName(FName("Profile_LA_InvisibleWall"), false)
    box:SetCollisionObjectType(0)
    local pawnChannel = pawn.CapsuleComponent:GetCollisionObjectType()
    for _, channel in ipairs({ 2, 23, pawnChannel }) do box:SetCollisionResponseToChannel(channel, 2) end
    box:SetCollisionResponseToChannel(3, 0)
    box:SetCollisionResponseToChannel(4, 0)
    box:SetGenerateOverlapEvents(false)
    box:SetHiddenInGame(true, false)
    actor:FinishAddComponent(box, true, transform)
    box:SetCollisionEnabled(1)
    assert(box:GetCollisionEnabled() == 1 and box:GetCollisionResponseToChannel(pawnChannel) == 2
        and box:GetCollisionResponseToChannel(23) == 2
        and distanceSquared(box:K2_GetComponentLocation(), position) < 1, "通道雾门碰撞读回异常")

    local niagara = required("/Script/Niagara.Default__NiagaraFunctionLibrary")
    -- The smoke curtain spans local X, the same axis as the collision box.
    local scale = { X = gate.halfWidth / 800, Y = 1, Z = 1 }
    for index, effect in ipairs(EFFECTS) do
        local at = { X = gate.X, Y = gate.Y, Z = floor + effect.z }
        local component = niagara:SpawnSystemAtLocation(pawn, effects[index], at, rotation, scale, false, false, 0, false)
        assert(valid(component), "通道 " .. gate.id .. " 的幻术雾特效未创建")
        passage.components[#passage.components + 1] = component
        component:SetAllowScalability(false)
        component:SetVariableLinearColor(FName("User.UE_Color01"), WHITE)
        if index == 2 then
            component:SetVariableLinearColor(FName("User.UE_Color02"), WHITE)
            component:SetVariableBool(FName("User.UE_OpaqueBackground"), false)
            component:SetVariableBool(FName("User.UE_StartPlayingMusic"), false)
        end
        component:Activate(true)
    end
end

local function prepare(tx, gameplay, system, pawn, scene)
    local door = findFog(gameplay, pawn, tx.world, scene)
    if not door then return nil, "等待圣躯心池原版战斗雾门" end
    local polygon = fogBoundary(door)
    local home, spawn = scene.phaseReturnPoints[1], scene.spawnPoints[1]
    assert(inside(polygon, home) and inside(polygon, spawn), "楼梯口或 Boss 刷新点落在原版战斗雾门外")
    local stairFloor = Bell.floorAt(pawn, system, home, home.Z + 160, home.Z - 220)
    local bossFloor = Bell.floorAt(pawn, system, spawn, scene.spawnTrace.top, scene.spawnTrace.bottom)
    if not stairFloor or not bossFloor then return nil, "等待上层楼梯口和 Boss 点地面" end
    local reachable, reason = nativePath(pawn, { X = home.X, Y = home.Y, Z = stairFloor },
        { X = spawn.X, Y = spawn.Y, Z = bossFloor })
    if not reachable then return nil, "等待" .. reason end
    if not live(pawn.CapsuleComponent) then return nil, "等待玩家胶囊体" end

    local effects = {}
    for index, effect in ipairs(EFFECTS) do
        effects[index] = loadEffect(effect.name)
        if not effects[index] then return nil, "等待幻术雾特效 " .. effect.name end
    end
    local floors = {}
    for index, gate in ipairs(scene.passageFog) do
        floors[index] = Bell.floorAt(pawn, system, gate, gate.top, gate.bottom)
        if not floors[index] then return nil, "等待通道 " .. gate.id .. " 地面" end
    end
    local passages = {}
    local ok, failure = pcall(function()
        for index, gate in ipairs(scene.passageFog) do
            local passage = { components = {} }
            passages[index] = passage
            makePassage(gameplay, pawn, tx.world, gate, floors[index], effects, passage)
        end
        door:SetActorEnableCollision(true)
        door:OpenByMobScript()
    end)
    if not ok then
        clearPassages(passages)
        return nil, tostring(failure)
    end
    tx.passages, tx.door, tx.polygon, tx.fogClosed = passages, door, polygon, false
    log(("READY bell=%s nav=stock room=upper gate_A=%.1f gate_C=%.1f fog_yaw_A=%.1f fog_yaw_C=%.1f native_combat_fog=%s")
        :format(scene.bellSaveId, floors[1], floors[2], scene.passageFog[1].yaw, scene.passageFog[2].yaw, scene.combatFog))
    return true
end

function Arena.update(gameplay, system, pawn, controller, world, now, scene, allowBell)
    if not session or session.world:GetAddress() ~= world:GetAddress() then
        Arena.reset()
        session = { world = world, nextProbe = 0, nextFog = 0 }
    end
    local tx = session
    local bellReady, reason = Bell.update(gameplay, system, pawn, controller, world, now, scene, allowBell)
    if not bellReady then return nil, reason end
    if not tx.ready and now >= tx.nextProbe then
        tx.nextProbe = now + 0.75
        local ok, ready, wait = pcall(prepare, tx, gameplay, system, pawn, scene)
        tx.ready, tx.reason = ok and ready, ok and wait or tostring(ready)
        if not tx.ready and tx.reason ~= tx.lastWait then
            tx.lastWait = tx.reason
            log("WAIT " .. tx.reason)
        end
    end
    return tx.ready, tx.reason
end

local function fogBlocks(door)
    local walls = door["Spline Mesh Component"]
    if not walls or #walls == 0 then return false end
    for index = 1, #walls do
        local wall = unwrap(walls[index])
        if not valid(wall) then return false end
        local mode = wall:GetCollisionEnabled()
        if (mode ~= 1 and mode ~= 3 and mode ~= 5) or wall:GetCollisionResponseToChannel(2) ~= 2 then return false end
    end
    return true
end

function Arena.updateCombat(pawn, active, now, scene)
    local tx = session
    if not tx or not tx.ready or not inWorld(tx.door, tx.world) then return end
    if active == tx.fogClosed then
        if active and not tx.fogVerified and now >= tx.nextFog then
            tx.nextFog = now + 1
            local ok, blocked = pcall(fogBlocks, tx.door)
            if ok and blocked then
                tx.fogVerified = true
                log("COMBAT_FOG blocking=1")
            elseif now >= tx.verifyUntil then
                tx.fogClosed = nil
            end
        end
        return
    end
    if active then
        local at = pawn:K2_GetActorLocation()
        if at.Z < scene.spawnTrace.bottom or not inside(tx.polygon, at) then return end
        if now < tx.nextFog then return end
    end
    if tx.fogRetryFor == active and now < tx.nextFog then return end
    local ok, failure = pcall(function()
        if active then tx.door["Close By Mob Script"](tx.door)
        else tx.door:OpenByMobScript() end
    end)
    if ok then
        tx.fogClosed, tx.fogVerified, tx.fogRetryFor = active, nil, nil
        tx.nextFog, tx.verifyUntil = now + 0.5, now + 4
        log("COMBAT_FOG requested=" .. (active and "closed" or "open"))
    else
        tx.fogRetryFor, tx.nextFog = active, now + 1
        if failure ~= tx.fogError then log("COMBAT_FOG error=" .. tostring(failure)) end
        tx.fogError = failure
    end
end

function Arena.reset()
    local tx = session
    session = nil
    if not tx then return end
    if tx.passages then clearPassages(tx.passages) end
    if inWorld(tx.door, tx.world) then pcall(tx.door.OpenByMobScript, tx.door) end
end

return Arena
