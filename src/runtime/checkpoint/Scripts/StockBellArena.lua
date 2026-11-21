local SceneArena = require("SceneArena")
local Events = require("MeiGuHuOriginalEvents")
local Lake = require("LakeUpperArena")
local Arena = {}
local session

local MATH = "/Script/Engine.Default__KismetMathLibrary"
local WORLD_STATIC = { 0 }
local CLEAR = { R = 0, G = 0, B = 0, A = 0 }
local PENDING = 0x08023600

local function valid(value)
    return value and type(value.IsValid) == "function" and value:IsValid()
end

local function required(path)
    local value = StaticFindObject(path)
    assert(valid(value), "缺少原版场景接口 " .. path)
    return value
end

local function name(value)
    return type(value) == "string" and value or (value and value:ToString() or "")
end

local function sameWorld(actor, world)
    if not valid(actor) or actor:HasAnyFlags(PENDING) or actor:IsActorBeingDestroyed() then return false end
    local live = SceneArena.runtimeWorld(actor)
    return valid(live) and live:GetAddress() == world:GetAddress()
end

local function bindBell(tx, sphere)
    tx.sphere, tx.mode = sphere, sphere:GetCollisionEnabled()
    if tx.mode == 0 then tx.mode = 1 end
    tx.bell.bDisableTeleport = true
    tx.bell.bTeleportOnBrokenBellLeave = false
    if #tx.bell.FlowTagMap > 0 then tx.bell.FlowTagMap:Empty() end
end

local function floorAt(pawn, system, point, top, bottom, ignore)
    local from, to = { X = point.X, Y = point.Y, Z = top }, { X = point.X, Y = point.Y, Z = bottom }
    local hit = {}
    if not system:LineTraceSingle(pawn, from, to, 0, false, ignore or {}, 0, hit, true, CLEAR, CLEAR, 0) then
        hit = {}
        if not system:LineTraceSingleForObjects(pawn, from, to, WORLD_STATIC, false, ignore or {},
            0, hit, true, CLEAR, CLEAR, 0) then return end
    end
    if hit.ImpactPoint and hit.ImpactNormal and hit.ImpactNormal.Z >= 0.65 then return hit.ImpactPoint.Z end
end

Arena.floorAt = floorAt

function Arena.getBell()
    if session and sameWorld(session.bell, session.world) then return session.bell end
end

function Arena.findBellWidgets(class, now)
    if not session or now < session.nextMenu then return end
    session.nextMenu = now + 0.25
    return FindAllOf(class)
end

local function findBell(gameplay, pawn, tx, scene)
    local bell = Events.actor()
    if sameWorld(bell, tx.world) then return bell end
    local spec = scene.checkpointBell
    local base = spec.class:gsub("_C$", "")
    local class = StaticFindObject("/Game/PBZContent/Blueprint/Item/" .. base .. "." .. spec.class)
    if not valid(class) then return end
    local actors = {}
    gameplay:GetAllActorsOfClass(pawn, class, actors)
    for _, item in ipairs(actors) do
        local actor = valid(item) and item or item:get()
        if sameWorld(actor, tx.world) and name(actor:GetFName()) == spec.name
            and name(actor.BellID) == scene.bellSaveId then return actor end
    end
end

local function prepare(gameplay, system, pawn, controller, tx, scene, now)
    tx.bell = Arena.getBell() or findBell(gameplay, pawn, tx, scene)
    if not tx.bell then return nil, "等待" .. scene.name .. "原版铃铛" end
    local sphere = tx.bell.InteractionComp
    if not valid(sphere) then return nil, "等待原版铃铛交互组件" end
    if not valid(tx.sphere) or tx.sphere:GetAddress() ~= sphere:GetAddress() then bindBell(tx, sphere) end
    if scene.id == "lake" and not tx.calibrated then
        -- The original map's native bell/support calibration and lift cover
        -- stay in use. Event masking owns all story actors before that step.
        local ready, why = SceneArena.update(gameplay, pawn, controller, now, scene, nil, true, tx.bell)
        if not ready then return nil, why end
        tx.calibrated = true
    end
    local at = scene.anchor
    local movement = pawn.CharacterMovement
    local walking = valid(movement) and movement.MovementMode == 1
    if (not walking and not floorAt(pawn, system, at, at.Z - 20, at.Z - 280, { tx.bell }))
        or not floorAt(pawn, system, scene.spawnPoints[1], scene.spawnTrace.top, scene.spawnTrace.bottom) then
        return nil, "等待" .. scene.name .. "地面"
    end
    if scene.id == "lake" then
        return Lake.prepareStock(gameplay, system, pawn, tx.world, scene)
    end
    return true
end

function Arena.update(gameplay, system, pawn, controller, world, now, scene, allowBell)
    if not session or session.world:GetAddress() ~= world:GetAddress() then
        Arena.reset()
        session = { world = world, nextProbe = 0, nextMenu = 0, nextBellCheck = 0 }
    end
    local tx = session
    if not tx.ready and now >= tx.nextProbe then
        tx.nextProbe = now + 0.5
        tx.ready, tx.reason = prepare(gameplay, system, pawn, controller, tx, scene, now)
    elseif tx.ready and not Arena.getBell() and now >= tx.nextProbe then
        local at, bell = pawn:K2_GetActorLocation(), scene.anchor
        tx.nextProbe = now + 1
        if (at.X - bell.X)^2 + (at.Y - bell.Y)^2 + (at.Z - bell.Z)^2 < 1800^2 then
            tx.bell = findBell(gameplay, pawn, tx, scene)
            tx.sphere = nil
        end
    end
    if Arena.getBell() and (allowBell ~= tx.allowBell or now >= tx.nextBellCheck) then
        local sphere = tx.bell.InteractionComp
        if valid(sphere) then
            local mode = sphere:GetCollisionEnabled()
            if not valid(tx.sphere) or tx.sphere:GetAddress() ~= sphere:GetAddress() then bindBell(tx, sphere) end
            local desired = allowBell and tx.mode or 0
            if mode ~= desired then sphere:SetCollisionEnabled(desired) end
        end
        tx.allowBell, tx.nextBellCheck = allowBell, now + 0.75
    end
    return tx.ready, tx.reason
end

function Arena.phaseDestination(pawn, system, scene)
    if not session or not session.ready or not sameWorld(pawn, session.world) then
        return nil, "等待" .. scene.name .. "场地就绪"
    end
    if scene.id == "lake" then return Lake.phaseDestination(pawn, system, scene) end
    for _, at in ipairs(scene.phaseReturnPoints or { scene.anchor }) do
        local top = at.Z + (scene.phaseReturnPoints and 160 or -20)
        local z = floorAt(pawn, system, at, top, at.Z - 280, session.bell and { session.bell })
        if z then
            local destination = { X = at.X, Y = at.Y, Z = z + pawn.CapsuleComponent:GetScaledCapsuleHalfHeight() + 6 }
            local aim = required(MATH):FindLookAtRotation(destination, scene.spawnPoints[1])
            if scene.phaseReturnPoints then
                print(("[PBZShengQuXinChi] PHASE_RETURN stairs=(%.2f,%.2f,%.2f)\n"):format(at.X, at.Y, destination.Z))
            end
            return { position = destination, rotation = { Pitch = 0, Yaw = aim.Yaw, Roll = 0 } }
        end
    end
    return nil, "等待" .. scene.name .. "回位点的地面"
end

function Arena.updateCombat(pawn, active, scene)
    if scene.id == "lake" then Lake.updateCombat(pawn, scene, active) end
end

function Arena.reset()
    local old = session
    session = nil
    if not old then return end
    if sameWorld(old.bell, old.world) and valid(old.sphere) then
        pcall(function() old.sphere:SetCollisionEnabled(old.mode) end)
    end
    Lake.resetStock()
    SceneArena.reset()
end

return Arena
