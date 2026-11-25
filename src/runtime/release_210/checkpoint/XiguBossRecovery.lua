local Terrain = require("ArenaTerrain")
local Engage = require("EncounterEngage")
local SceneArena = require("SceneArena")
local Recovery = {}

local NATIVE = "/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary"
local ACTIONS = "/Script/SGameUtils.Default__AbilityUtils"
local CLEAR = { R = 0, G = 0, B = 0, A = 0 }
local PENDING = 0x08023600

local function valid(object)
    return object and type(object.IsValid) == "function" and object:IsValid()
end

local function live(actor, world)
    if not valid(actor) or actor:HasAnyFlags(PENDING) or actor:IsActorBeingDestroyed() then return false end
    local owner = SceneArena.runtimeWorld(actor)
    return valid(owner) and owner:GetAddress() == world
end

local function finite(value)
    return type(value) == "number" and value > -math.huge and value < math.huge
end

local function threat(at, halfHeight, scene, movement, safeGround, pawn, system, actor)
    if not (finite(at.X) and finite(at.Y) and finite(at.Z)) then return "坐标失效", true end
    local foot = at.Z - halfHeight
    if foot < scene.combatHeight.min - 120 then return "跌出战区地面", true, true end
    local edge = Terrain.distanceToBoundarySquared(at, scene)
    if scene.edgeProtection and valid(movement) and movement.MovementMode == 3 then
        local velocity = movement.Velocity
        local safeFloor = safeGround and math.max(scene.combatHeight.min, safeGround.Z-280) or scene.combatHeight.min
        if velocity and finite(velocity.Z) and velocity.Z < -350 and foot + velocity.Z*.25 < safeFloor then
            if edge > 120^2 then return "越界后向下坠落", true, true end
            local floor = Terrain.floorAt(pawn, system, at, foot+45, scene.combatHeight.min-50, { actor })
            if not floor or floor < scene.combatHeight.min then return "战区内失去落脚地面", true, true end
        end
    end
    if edge > 1500^2 then return "远离战区边界", true end
    if edge > 450^2 or (not scene.edgeProtection and foot > scene.combatHeight.max + 2200) then
        return "持续离开战区", false
    end
end

local function freeAt(position, pawn, actor, run, system, radius, halfHeight)
    local offset = pawn:K2_GetActorLocation()
    if (position.X-offset.X)^2 + (position.Y-offset.Y)^2 < (radius+175)^2
        and math.abs(position.Z-offset.Z) < halfHeight+160 then return false end
    for _, other in ipairs(run.bosses) do
        if other ~= actor and live(other, run.encounterWorld) and other:IsAlive() then
            local at = other:K2_GetActorLocation()
            if (position.X-at.X)^2 + (position.Y-at.Y)^2 < (radius+200)^2
                and math.abs(position.Z-at.Z) < halfHeight+250 then return false end
        end
    end
    local above = { X = position.X, Y = position.Y, Z = position.Z+2 }
    return not system:CapsuleTraceSingleForObjects(pawn, position, above, radius, halfHeight,
        { system:ConvertToObjectType(0), system:ConvertToObjectType(1) }, false, { actor },
        0, {}, true, CLEAR, CLEAR, 0)
end

local function chooseLanding(record, actor, pawn, system, run, radius, halfHeight)
    local points = {}
    if record.safeGround then points[1] = record.safeGround end
    for _, point in ipairs(run.scene.spawnPoints) do points[#points+1] = point end
    for _, point in ipairs(run.scene.phaseReturnPoints or {}) do points[#points+1] = point end
    local ignore = { actor }
    for _, point in ipairs(points) do
        local ground = Terrain.recoveryGround(pawn, system, run.scene, point, ignore)
        if ground then
            local at = { X = ground.X, Y = ground.Y, Z = ground.Z+halfHeight+10 }
            if freeAt(at, pawn, actor, run, system, radius, halfHeight) then return at end
        end
    end
end

local function stopAndReturn(actor, position)
    local movement, asc = actor.CharacterMovement, actor.AbilitySystemComponent
    local actions, native = StaticFindObject(ACTIONS), StaticFindObject(NATIVE)
    if not (valid(movement) and valid(asc) and valid(actions) and valid(native)) then return false end
    actions:CancelAbilitiesByTag(asc, { GameplayTags = { { TagName = FName("Ability.Action") } }, ParentTags = {} },
        { GameplayTags = {}, ParentTags = {} })
    if not valid(actor) or actor:IsActorBeingDestroyed() or not actor:IsAlive() then return false end
    local montage = actor:GetCurrentMontage()
    if valid(montage) then actor:StopAnimMontage(montage) end
    movement:StopMovementImmediately()
    local facing = { Pitch = 0, Yaw = actor:K2_GetActorRotation().Yaw, Roll = 0 }
    if not native:PBZActorTeleportTo(actor, position, facing, false, false) then return false end
    movement:StopMovementImmediately()
    if movement.MovementMode ~= 1 and movement.MovementMode ~= 2 then movement:SetMovementMode(1, 0) end
    local at = actor:K2_GetActorLocation()
    return (at.X-position.X)^2 + (at.Y-position.Y)^2 + (at.Z-position.Z)^2 <= 90^2
end

local function resumeCombat(run, record, actor, pawn, now)
    if not record.engageUntil then return end
    local at, height = pawn:K2_GetActorLocation(), run.scene.combatHeight
    if not run.startedAt or (run.practice and run.practice.state.ai == false) or at.Z < height.min or at.Z > height.max
        or not Terrain.contains(at, run.scene.combatBoundary) then
        record.engageUntil, record.engage = nil, nil
        return
    end
    local ok, acquired = pcall(Engage.start, actor, pawn, record.engage, now)
    if ok and acquired then record.engageUntil, record.engage = nil, nil; return end
    if now >= record.engageUntil then return "首领回位后未能继续接战" end
end

local function watchBoss(record, actor, pawn, system, run, now, arriving)
    local sustainedExit = run.scene.guardTerrainDefeat and record.dangerAt and now-record.dangerAt >= .45
    if not live(actor, run.encounterWorld) then
        if record.recoveryDeadline or sustainedExit then return false, "首领在越界后离场" end
        if arriving and not record.defeated then return false, "首领在入场期间意外消失" end
        return
    end
    if not run.ownedActors[actor:GetAddress()] then return end
    local capsule = actor.CapsuleComponent
    if not valid(capsule) then return end
    local half = capsule:GetScaledCapsuleHalfHeight()
    local position = actor:K2_GetActorLocation()
    local at = { X = position.X, Y = position.Y, Z = position.Z }
    local movement = actor.CharacterMovement
    local reason, urgent, fell = threat(at, half, run.scene, movement, record.safeGround, pawn, system, actor)
    if not actor:IsAlive() then
        if fell or record.recoveryDeadline or sustainedExit or (run.scene.guardTerrainDefeat and urgent) then
            return false, "首领因地形异常离场"
        end
        record.defeated = true
        return
    end
    record.defeated = nil
    local mounted
    for _, mount in ipairs(run.mounts or {}) do
        if valid(mount.rider) and mount.rider:GetAddress() == actor:GetAddress() then
            mounted = run.mountPreparation ~= nil
            if live(mount.horse, run.encounterWorld) and mount:owns(mount.horse) and mount.horse:IsAlive() then
                mounted = true
                local horseCapsule = mount.horse.CapsuleComponent
                if valid(horseCapsule) then
                    local horseReason, horseUrgent = threat(mount.horse:K2_GetActorLocation(),
                        horseCapsule:GetScaledCapsuleHalfHeight(), scene, mount.horse.CharacterMovement, record.safeGround,
                        pawn, system, mount.horse)
                    reason, urgent = reason or horseReason, urgent or horseUrgent
                end
            end
            break
        end
    end
    if not reason then
        record.dangerAt, record.recoveryDeadline = nil, nil
        if record.checkMovementAt and now >= record.checkMovementAt then
            record.checkMovementAt = nil
            if valid(movement) and movement.MovementMode == 0 and not valid(actor:GetCurrentMontage()) then
                return false, "首领回位后移动状态未恢复"
            end
        end
        local foot = at.Z-half
        if foot >= run.scene.combatHeight.min and foot <= run.scene.combatHeight.max
            and valid(movement) and (movement.MovementMode == 1 or movement.MovementMode == 2)
            and Terrain.contains(at, run.scene.combatBoundary) then
            record.safeGround = { X = at.X, Y = at.Y, Z = foot }
        end
        if not arriving then return false, resumeCombat(run, record, actor, pawn, now) end
        return
    end
    record.dangerAt = record.dangerAt or now
    if not urgent and now-record.dangerAt < .45 then return end
    -- Native mount attachment and damage redirection belong to the rider script.
    if mounted then return false, "骑乘组合离场，需一起重置" end
    if record.lastReturn and now-record.lastReturn < .8 then return false, "技能中断后仍反复将首领拉出场地" end
    if not record.returnWindow or now-record.returnWindow > 10 then record.returnWindow, record.returns = now, 0 end
    if record.returns >= 3 then return false, "首领连续多次离场" end
    record.recoveryDeadline = record.recoveryDeadline or now+1.0
    if now >= record.recoveryDeadline then return false, "首领无法安全回位：" .. reason end

    local ok, returned = pcall(function()
        local radius = capsule:GetScaledCapsuleRadius()
        local position = chooseLanding(record, actor, pawn, system, run, radius, half)
        return position and stopAndReturn(actor, position)
    end)
    if ok and returned then
        record.dangerAt, record.recoveryDeadline, record.lastReturn = nil, nil, now
        record.returns = record.returns+1
        if arriving then
            local address = actor:GetAddress()
            if run.engagePending then run.engagePending[address] = nil end
            if run.engageRequests then run.engageRequests[address] = nil end
        else
            record.engageUntil, record.engage = now+2, {}
        end
        record.checkMovementAt = now+1.25
        print(("[PBZXiguBossRecovery] scene=%s target=%s stage=%d returned reason=%s\n")
            :format(run.scene.id, run.entry.id, run.stageIndex, reason))
        return true
    end
    if not ok and record.lastError ~= returned then
        record.lastError = returned
        print("[PBZXiguBossRecovery] retry " .. tostring(returned) .. "\n")
    end
    return true
end

local function sample(run, gameplay, system, pawn, now, terminalSample, arriving)
    if not run.scene.bossRecovery or not run.encounterWorld or not run.ownedActors or gameplay:IsGamePaused(pawn)
        or not live(pawn, run.encounterWorld) then return end
    local attributes, asc = pawn.AttributeSetBase, pawn.AbilitySystemComponent
    local hp = valid(attributes) and attributes.Health.CurrentValue
    if not finite(hp) or hp <= 0 or not valid(asc)
        or asc:GetGameplayTagCount({ TagName = FName("CharacterState.Dead") }) ~= 0 then return end
    local state = run.bossRecoveryState
    if not state or state.bosses ~= run.bosses then
        state = { bosses = run.bosses, records = {}, nextSample = 0 }
        run.bossRecoveryState = state
    end
    if not terminalSample and now < state.nextSample then return state.waiting end
    state.nextSample, state.waiting = now+.10, false
    for index, actor in ipairs(state.bosses) do
        local record = state.records[index] or {}
        state.records[index] = record
        local pending, reason = watchBoss(record, actor, pawn, system, run, now, arriving)
        if reason then return false, reason end
        if pending then state.waiting = true end
    end
    return state.waiting
end

function Recovery.update(run, gameplay, system, pawn, now, terminalSample)
    if run.status ~= "ready" and run.status ~= "combat" then return end
    return sample(run, gameplay, system, pawn, now, terminalSample)
end

function Recovery.protectArrival(run, gameplay, system, pawn, now)
    if run.palace or run.stageIndex <= 1 or not run.bosses[1] then return end
    local step = run.transitionStep
    if step ~= "loading" and step ~= "in" and step ~= "engage"
        and not (run.phaseTravel and run.phaseTravel.restored) then return end
    local pending, reason = sample(run, gameplay, system, pawn, now, run.mountPreparation ~= nil, true)
    if reason then
        run:restartAfterBossExit(reason, now)
        return true, true
    end
    return pending
end

return Recovery
