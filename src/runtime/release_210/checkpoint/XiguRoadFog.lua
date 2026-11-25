local SceneArena = require("SceneArena")
local Events = require("MeiGuHuOriginalEvents")
local SpawnClass = require("SpawnClass")
local Fog = {}

local FOG_CLASS = "/Game/PBZContent/Blueprint/Item/BP_FogDoor.BP_FogDoor_C"
local BOX_CLASS = "/Script/Engine.BoxComponent"
local MATH = "/Script/Engine.Default__KismetMathLibrary"
local SPAWN = "/Script/SGameAI.Default__SGameAIFunctionLibrary"
local PENDING = 0x08023600
local ROTATION = { Pitch = 0, Yaw = 0, Roll = 0 }
local SCALE = { X = 1, Y = 1, Z = 1 }

local function valid(object)
    return object and type(object.IsValid) == "function" and object:IsValid()
end

local function ready(object)
    return valid(object) and not object:HasAnyFlags(PENDING)
end

local function live(actor, world)
    if not valid(world) or not ready(actor) or actor:IsActorBeingDestroyed() then return false end
    local current = SceneArena.runtimeWorld(actor)
    return valid(current) and current:GetAddress() == world:GetAddress()
end

local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "缺少雾门原版接口 " .. path)
    return object
end

local function component(value)
    if value and type(value.IsValid) ~= "function" then return value:get() end
    return value
end

local function blocked(record, pawnChannel)
    if not record.actor:GetActorEnableCollision() then return false end
    for _, box in ipairs(record.boxes) do
        if not valid(box) or box:GetCollisionEnabled() ~= 1
            or box:GetCollisionResponseToChannel(pawnChannel) ~= 2 then return false end
    end
    return true
end

local function verifySpline(door, points)
    local spline = door.Spline
    assert(valid(spline) and spline:GetNumberOfSplinePoints() == #points, "原版雾门样条未就绪")
    for index, point in ipairs(points) do
        local at = spline:GetLocationAtSplinePoint(index-1, 1)
        assert((at.X-point.X)^2 + (at.Y-point.Y)^2 + (at.Z-point.Z)^2 <= 35^2, "雾门样条位置回读不符")
    end
end

local function addCollision(record, spec, pawnChannel, endPadding)
    local door = record.actor
    local points = spec.points
    local mathLibrary, boxClass = required(MATH), required(BOX_CLASS)
    record.boxes = {}
    for index = 1, #points-1 do
        local first, last = points[index], points[index+1]
        local dx, dy = last.X-first.X, last.Y-first.Y
        local bottom = math.min(first.Z, last.Z) - (spec.collisionBelow or 330)
        if spec.collisionBottom then bottom = math.min(bottom, spec.collisionBottom) end
        local top = math.max(first.Z, last.Z) + 630
        if spec.collisionTop then top = math.max(top, spec.collisionTop) end
        local center = { X = (first.X+last.X)*0.5, Y = (first.Y+last.Y)*0.5, Z = (top+bottom)*0.5 }
        local rotation = { Pitch = 0, Yaw = math.deg(math.atan(dy, dx)), Roll = 0 }
        local transform = mathLibrary:MakeTransform(center, rotation, SCALE)
        local box = door:AddComponentByClass(boxClass, true, transform, true)
        assert(valid(box), "雾门阻挡组件未创建")
        record.boxes[index] = box
        box.bCanEverAffectNavigation = false
        box:SetBoxExtent({ X = math.sqrt(dx*dx+dy*dy)*0.5+endPadding, Y = 60, Z = (top-bottom)*0.5 }, false)
        box:SetCollisionProfileName(FName("Profile_LA_InvisibleWall"), false)
        box:SetCollisionObjectType(0)
        for _, channel in ipairs({ 2, 19, 23, pawnChannel }) do box:SetCollisionResponseToChannel(channel, 2) end
        box:SetCollisionResponseToChannel(3, 0)
        box:SetCollisionResponseToChannel(4, 0)
        box:SetGenerateOverlapEvents(false)
        box:SetHiddenInGame(true, false)
        door:FinishAddComponent(box, true, transform)
        box:SetCollisionEnabled(1)
        local at = box:K2_GetComponentLocation()
        assert((at.X-center.X)^2 + (at.Y-center.Y)^2 + (at.Z-center.Z)^2 < 1, "雾门阻挡位置回读不符")
    end
end

local function rebuild(door, spec)
    local spline = door.Spline
    assert(valid(spline), "缺少原版雾门样条组件")
    -- ConstructFogDoor reads the actual spline and exports its points. Remove
    -- the default construction's meshes before asking it to build this route.
    local walls = door["Spline Mesh Component"]
    local old = {}
    for index = 1, #walls do old[#old+1] = component(walls[index]) end
    walls:Empty()
    door["Spline Points Locations"]:Empty()
    for _, wall in ipairs(old) do
        if valid(wall) then
            wall:SetCollisionEnabled(0)
            wall:SetHiddenInGame(true, false)
            wall:K2_DestroyComponent(wall)
        end
    end
    spline:ClearSplinePoints(false)
    for index, point in ipairs(spec.points) do
        spline:AddSplinePoint(point, 1, false)
        spline:SetSplinePointType(index-1, 0, false)
    end
    spline:UpdateSpline()
    door.bIsClosedSpline = false
    door:ConstructFogDoor()
end

local function closeDoor(door)
    door:SetActorEnableCollision(true)
    door["Close By Mob Script"](door)
end

local function openDoor(door)
    door:OpenByMobScript()
    door:SetActorEnableCollision(false)
end

local function closeRoad(record, pawnChannel)
    if not record.visuals then
        closeDoor(record.actor)
        return
    end
    record.actor:SetActorEnableCollision(true)
    for _, box in ipairs(record.boxes) do
        box:SetCollisionResponseToChannel(pawnChannel, 2)
        box:SetCollisionEnabled(1)
    end
end

local function checkStairVisual(record)
    -- BP_FogDoor uses this Niagara component for the wall. Its collision
    -- boxes can be ready even when the effect is culled, hidden or inactive.
    local effect = record.actor.NS_Common_BossFog_002
    if not ready(effect) or not valid(effect:GetAsset()) then return "waiting" end
    local address = effect:GetAddress()
    if record.visualAddress ~= address then
        effect:SetAllowScalability(false)
        record.visualAddress = address
    end
    local restored = not effect:IsVisible() or effect.bHiddenInGame == true or not effect:IsActive()
    if not effect:IsVisible() then effect:SetVisibility(true, false) end
    if effect.bHiddenInGame == true then effect:SetHiddenInGame(false, false) end
    if not effect:IsActive() then effect:Activate(true) end
    if not effect:IsVisible() or effect.bHiddenInGame == true or not effect:IsActive() then return "waiting" end
    return restored and "restored" or "ready"
end

local function clearRoad(record, world)
    for _, effect in ipairs(record.visuals or {}) do
        if ready(effect) then pcall(effect.K2_DestroyComponent, effect, effect) end
    end
    if live(record.actor, world) then pcall(record.actor.K2_DestroyActor, record.actor) end
end

local function intact(record, world)
    if not live(record.actor, world) then return false end
    for _, effect in ipairs(record.visuals or {}) do
        if not ready(effect) then return false end
    end
    for _, box in ipairs(record.boxes) do
        if not valid(box) then return false end
    end
    return true
end

local function construct(gameplay, pawn, world, spec, pawnChannel, now)
    local class, assets, reason
    local phantom = spec.phantom and require("PhantomRoadFog")
    local emitters = spec.emitters or (spec.emitter and { spec.emitter })
    local fillCenter = emitters and emitters[1].fillCenter == true
    if phantom then
        if not spec.collisionOnly then
            assets, reason = phantom.load(emitters ~= nil and not fillCenter)
            if not assets then return nil, reason end
        end
        class = required("/Script/Engine.Actor")
    else
        class, reason = SpawnClass.resolve(FOG_CLASS)
        if not valid(class) then return nil, reason or "等待雾门资源" end
    end
    local origin = spec.points[1]
    local mathLibrary = required(MATH)
    local transform = mathLibrary:MakeTransform(origin, ROTATION, SCALE)
    local door = required(SPAWN):SpawnActorDeferred(pawn, class, transform, phantom and 3 or 1)
    if not valid(door) then return nil, "无法生成 " .. spec.name end
    local record = { actor = door, visuals = phantom and {} or nil, retryAt = now + 2 }
    local ok, failure = pcall(function()
        if not phantom then
            door["Scale Z"] = spec.scaleZ
            door.bIsClosedSpline = false
        end
        local finished = gameplay:FinishSpawningActor(door, transform, 1)
        assert(live(finished, world) and finished:GetAddress() == door:GetAddress(), "雾门所属世界不符")
        if not phantom then
            rebuild(door, spec)
            verifySpline(door, spec.points)
        end
        -- The authored two-point boxes already include the full span shown on the map.
        addCollision(record, spec, pawnChannel, emitters and 0 or 65)
        if phantom and assets then
            if emitters then
                assert(#record.boxes == 1, "标注雾门应使用单一阻挡 " .. spec.name)
                record.emitters = {}
                for _, emitter in ipairs(emitters) do
                    assert((emitter.fillCenter == true) == fillCenter, "同一雾门的中央雾层配置不符 " .. spec.name)
                    local first = #record.visuals + 1
                    phantom.spawn(pawn, emitter.points or spec.points, assets, record.visuals, emitter.point, fillCenter)
                    local count = #record.visuals - first + 1
                    assert(count == (fillCenter and 2 or 1), "雾门特效数量不符 " .. emitter.name)
                    local at, expected = record.visuals[first]:K2_GetComponentLocation(), emitter.point
                    assert((at.X-expected.X)^2 + (at.Y-expected.Y)^2 + (at.Z-expected.Z)^2 < 1,
                        "雾门特效位置回读不符 " .. emitter.name)
                    record.emitters[#record.emitters + 1] = {
                        name = emitter.name, position = { X = at.X, Y = at.Y, Z = at.Z },
                        count = count, fillCenter = fillCenter,
                    }
                end
            else
                phantom.spawn(pawn, spec.points, assets, record.visuals)
            end
        end
        closeRoad(record, pawnChannel)
    end)
    if not ok then
        clearRoad(record, world)
        return nil, tostring(failure)
    end
    return record
end

local function applyCombatGate(tx)
    if not tx.scene.combatFog then return end
    for _, name in ipairs(tx.scene.additionalCombatFogs or {}) do
        tx.additionalDoors = tx.additionalDoors or {}
        local extra = Events.actor(name)
        local closed = tx.combatClosed == true
        if live(extra, tx.world) and (tx.additionalDoors[name] ~= extra or extra:GetActorEnableCollision() ~= closed) then
            if closed then closeDoor(extra) else openDoor(extra) end
            tx.additionalDoors[name] = extra
        end
    end
    local door = Events.actor(tx.scene.combatFog)
    if not live(door, tx.world) then tx.combatDoor, tx.combatDoorAddress = nil, nil; return end
    local address = door:GetAddress()
    local closed = tx.combatClosed == true
    if tx.combatDoorAddress == address and tx.appliedCombat == closed
        and door:GetActorEnableCollision() == closed then return end
    if closed then closeDoor(door) else openDoor(door) end
    tx.combatDoor, tx.combatDoorAddress, tx.appliedCombat = door, address, closed
    print("[PBZXiguBossArena] scene=" .. tx.scene.id .. " FOG combat=" .. (closed and "closed" or "open") .. "\n")
end

function Fog.setCombat(tx, closed)
    if tx.combatClosed == closed then return end
    tx.combatClosed = closed
    applyCombatGate(tx)
end

local function closeFixedFogs(tx, scene)
    for _, name in ipairs(scene.fixedFogDoors or {}) do
        local door = Events.actor(name)
        if not live(door, tx.world) then return nil, "等待" .. scene.name .. "原版外围雾门" end
        tx.fixedDoors = tx.fixedDoors or {}
        local record = tx.fixedDoors[name]
        local address = door:GetAddress()
        if not record or record.address ~= address then
            tx.fixedDoors[name] = { actor = door, address = address, wasBlocking = door:GetActorEnableCollision() }
            closeDoor(door)
            print("[PBZXiguBossArena] scene=" .. scene.id .. " FOG fixed=" .. name .. "\n")
        elseif not door:GetActorEnableCollision() then
            closeDoor(door)
        end
    end
    return true
end

function Fog.update(tx, gameplay, pawn, scene, now)
    if not scene.roadFogs then return true end
    if now < (tx.nextRoadFog or 0) then return tx.roadReady, tx.roadReason end
    tx.nextRoadFog = now + 0.45
    tx.roadGates = tx.roadGates or {}
    tx.roadReady, tx.roadReason = true, nil
    applyCombatGate(tx)
    local fixed, reason = closeFixedFogs(tx, scene)
    if not fixed then
        tx.roadReady, tx.roadReason = nil, reason
        return nil, reason
    end
    if not valid(pawn.CapsuleComponent) then
        tx.roadReady, tx.roadReason = nil, "等待玩家碰撞体"
        return nil, tx.roadReason
    end
    local pawnChannel = pawn.CapsuleComponent:GetCollisionObjectType()
    for index, spec in ipairs(scene.roadFogs) do
        local record = tx.roadGates[index]
        if not record or not intact(record, tx.world) then
            if record then clearRoad(record, tx.world) end
            tx.roadGates[index] = nil
            local reason
            record, reason = construct(gameplay, pawn, tx.world, spec, pawnChannel, now)
            if not record then
                tx.roadReady, tx.roadReason = nil, "等待" .. spec.name .. "雾门 " .. (reason or "")
                return nil, tx.roadReason
            end
            tx.roadGates[index] = record
        end
        if not blocked(record, pawnChannel) then
            if now >= record.retryAt then
                record.retryAt = now + 2
                closeRoad(record, pawnChannel)
            end
            if not blocked(record, pawnChannel) then
                tx.roadReady, tx.roadReason = nil, "等待" .. spec.name .. "关闭"
                return nil, tx.roadReason
            end
        end
        if scene.id == "cangang" and not record.visuals and now >= (record.nextVisualCheck or 0) then
            record.nextVisualCheck = now + 2
            local checked, status = pcall(checkStairVisual, record)
            if not checked then status = "unavailable " .. tostring(status) end
            if status ~= record.visualStatus then
                record.visualStatus = status
                print("[PBZXiguBossArena] scene=cangang FOG stair_visual=" .. status .. "\n")
            end
        end
        if not record.reported then
            record.reported = true
            local visual = record.visuals and #record.visuals > 0 and " visual=phantom" or ""
            for _, emitter in ipairs(record.emitters or {}) do
                local at = emitter.position
                visual = visual .. (" niagara_id=%s niagara_spawned=%d niagara_xyz_cm=(%.1f,%.1f,%.1f) pawn_block=true")
                    :format(emitter.name, emitter.count, at.X, at.Y, at.Z)
                if emitter.fillCenter then visual = visual .. " center_fill=1" end
            end
            print("[PBZXiguBossArena] scene=" .. scene.id .. " FOG sealed=" .. spec.name .. visual
                .. " blocking_boxes=" .. #record.boxes .. " pawn_channel=" .. pawnChannel .. "\n")
        end
    end
    return true
end

function Fog.reset(tx)
    if live(tx.combatDoor, tx.world) then pcall(openDoor, tx.combatDoor) end
    for _, door in pairs(tx.additionalDoors or {}) do
        if live(door, tx.world) then pcall(openDoor, door) end
    end
    for _, record in pairs(tx.fixedDoors or {}) do
        if live(record.actor, tx.world) then
            pcall(record.wasBlocking and closeDoor or openDoor, record.actor)
        end
    end
    for _, record in pairs(tx.roadGates or {}) do
        clearRoad(record, tx.world)
    end
end

return Fog
