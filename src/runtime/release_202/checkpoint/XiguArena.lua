local SceneArena = require("SceneArena")
local SpawnClass = require("SpawnClass")
local Events = require("MeiGuHuOriginalEvents")
local Arena = {}

local MAP = "PBZ_Xigu_WP"
local SPAWNER = "BP_AISpawner_C_UAID_60CF848099092CEE02_1842879658"
local DOMAIN = "BP_MobDomain_C_UAID_60CF848099092CEE02_1842807652"
local FOG_DOORS = {
    BP_FogDoor_C_UAID_60CF848099092CEE02_1842868653 = true,
    BP_FogDoor_C_UAID_60CF848099092CEE02_1842871654 = true,
}
local BELL_CLASS = "/Game/PBZContent/Blueprint/Item/BP_BrokenBell.BP_BrokenBell_C"
local MATH = "/Script/Engine.Default__KismetMathLibrary"
local SUBSYSTEM = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local NATIVE = "/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary"
local PENDING = 0x08023600
local PORTAL_TRIGGER_HEIGHT = 65
-- ObjectTypeQuery1 maps to WorldStatic in this build, as in SceneArena.lua.
-- UEngineTypes::ConvertToObjectType is not exposed to UE4SS as a UFunction.
local WORLD_STATIC = { 0 }
local SCALE, CLEAR = { X = 1, Y = 1, Z = 1 }, { R = 0, G = 0, B = 0, A = 0 }
local clock = os and type(os.clock) == "function" and os.clock
local session

local function valid(object) return object and type(object.IsValid) == "function" and object:IsValid() end
local function same(a, b) return valid(a) and valid(b) and a:GetAddress() == b:GetAddress() end
local function name(value) return type(value) == "string" and value or (value and value:ToString() or "") end
local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "缺少原版接口 " .. path)
    return object
end
local function inWorld(actor, world)
    return valid(actor) and same(SceneArena.runtimeWorld(actor), world)
end
local function distanceSquared(a, b)
    return (a.X - b.X)^2 + (a.Y - b.Y)^2 + (a.Z - b.Z)^2
end
local function log(message) print("[PBZXiguArena] " .. message .. "\n") end

local function findObjects(category, class)
    local began = clock and clock()
    local objects = FindAllOf(class)
    if began and session then
        local entry = session.lookups[category]
        if not entry then entry = { count = 0, ms = 0 }; session.lookups[category] = entry end
        entry.count = entry.count + 1
        entry.ms = entry.ms + (clock() - began) * 1000
    end
    return objects
end

function Arena.findBellWidgets(class, now)
    if not session or now < (session.nextMenuLookup or 0) then return end
    session.nextMenuLookup = now + 0.25
    return findObjects("bell", class)
end
function Arena.findStatusObjects(class) return findObjects("status", class) end

local function reportLookups(tx, now)
    if not clock or now < tx.lookupReportAt then return end
    local parts = {}
    for _, category in ipairs({ "story", "bell", "status" }) do
        local entry = tx.lookups[category]
        parts[#parts + 1] = ("%s=%d/%.1fms"):format(category, entry and entry.count or 0, entry and entry.ms or 0)
    end
    log(("object lookups over %.1fs %s"):format(now - tx.lookupSince, table.concat(parts, " ")))
    tx.lookupSince, tx.lookupReportAt, tx.lookups = now, now + 10, {}
end

local function unwrap(object)
    if valid(object) or not object then return object end
    local get = object.get or object.Get
    if type(get) == "function" then return get(object) end
end

local function linkedFogDoors(tx, spawner)
    local group = unwrap(spawner.MobGroup)
    if not valid(group) and inWorld(tx.domain, tx.world) then
        group = unwrap(tx.domain.MobDomainConfig.MobGroups:Find(FName("DefaultGroup")))
    end
    assert(valid(group) and name(group:GetFName()) == "MobGroup_0", "原版魔偶战斗组未就绪")
    local domain = unwrap(group:GetOuter())
    assert(inWorld(domain, tx.world) and name(domain:GetFName()) == DOMAIN, "原版魔偶战斗组归属不匹配")
    local script
    local scripts = group.Scripts
    for index = 1, #scripts do
        local candidate = unwrap(scripts[index])
        if valid(candidate) and name(candidate:GetFName()) == "MobGroupScript_LinkFogDoor_C_0"
            and same(candidate:GetOuter(), group) and not candidate:HasAnyFlags(PENDING) then
            script = candidate
            break
        end
    end
    assert(valid(script) and script.bRequirePlayerInside == true, "原版雾门联动未就绪")
    local doors, known = {}, {}
    for _, property in ipairs({ "FogDoorsToActivate", "FogDoorsToDeactivateOnClear", "FogDoorsToDeactivateOnOffCombat" }) do
        local list = script[property]
        assert(list and #list == 2, "原版雾门数量不匹配")
        local seen = {}
        for index = 1, #list do
            local door = unwrap(list[index])
            assert(inWorld(door, tx.world) and not door:HasAnyFlags(PENDING), "等待原版溪谷雾门")
            local id = name(door:GetFName())
            assert(FOG_DOORS[id] and not seen[id], "原版雾门身份不匹配")
            seen[id] = true
            if property == "FogDoorsToActivate" then
                doors[#doors + 1], known[id] = door, door
            else
                assert(same(known[id], door), "原版雾门开关引用不匹配")
            end
        end
    end
    return script, doors
end

local function bindFog(tx, spawner)
    local ok, script, doors = pcall(linkedFogDoors, tx, spawner)
    if not ok then return nil, tostring(script) end
    tx.fogScript, tx.fogDoors = script, doors
    log("linked the two original encounter fog doors")
    return true
end

local function openFog(tx, cleared)
    if not tx or not tx.fogArmed then return end
    local ok, failure = pcall(function()
        if cleared then tx.fogScript:DeactivateFogDoorsOnClear()
        else tx.fogScript:DeactivateFogDoorsOnOffCombat() end
    end)
    if ok then
        tx.fogArmed, tx.fogVerified, tx.fogOpenError = nil, nil, nil
        log("original encounter fog doors reopened")
    elseif tx.fogOpenError ~= failure then
        tx.fogOpenError = failure
        log("original fog door release failed: " .. tostring(failure))
    end
end

local function bothDoorsBlock(doors)
    for _, door in ipairs(doors) do
        local walls = door["Spline Mesh Component"]
        if not walls or #walls == 0 then return false end
        for index = 1, #walls do
            local wall = unwrap(walls[index])
            if not valid(wall) then return false end
            local mode = wall:GetCollisionEnabled()
            if (mode ~= 1 and mode ~= 3 and mode ~= 5) or wall:GetCollisionResponseToChannel(2) ~= 2 then return false end
        end
    end
    return true
end

local function armFog(tx, now, keepClosed)
    tx.fogArmed, tx.fogNextOpen, tx.fogVerifyAt = true, 0, now
    tx.fogVerifyUntil = now + (keepClosed and 3 or 20)
    local ok, failure = pcall(function()
        if keepClosed then
            -- The palace reaches this path only after the inside landing is
            -- verified. Use the same door action as the stock MobGroup script.
            for _, door in ipairs(tx.fogDoors) do
                assert(inWorld(door, tx.world), "血宫雾门不在当前场景")
                door["Close By Mob Script"](door)
            end
        else
            tx.fogScript:OnMobGroupInCombat()
        end
    end)
    if ok then
        log(keepClosed and "palace locked the two original fog doors" or "combat armed the original fog doors; waiting for player inside")
    else
        tx.fogStartError = tostring(failure)
        log("original fog door activation failed: " .. tx.fogStartError)
        openFog(tx, false)
    end
end

function Arena.updateCombat(active, cleared, now, keepClosed)
    local tx = session
    if not tx or not tx.ready then return end
    if not active then
        if tx.fogArmed and now >= (tx.fogNextOpen or 0) then
            tx.fogNextOpen = now + 1
            openFog(tx, cleared)
        end
        tx.fogStartError = nil
        return
    end
    if tx.fogStartError then return end
    if tx.fogArmed then
        if now >= tx.fogVerifyAt and (keepClosed or (not tx.fogVerified and now <= tx.fogVerifyUntil)) then
            tx.fogVerifyAt = now + 1
            local ok, blocked = pcall(bothDoorsBlock, tx.fogDoors)
            if ok and blocked then
                if not tx.fogVerified then log("original encounter fog doors now block the player") end
                tx.fogVerified = true
            elseif keepClosed and (tx.fogVerified or now >= tx.fogVerifyUntil) then
                tx.fogVerified = nil
                armFog(tx, now, true)
            end
        end
        return
    end
    if not valid(tx.fogScript) then
        if now < (tx.fogBindAt or 0) or (tx.fogBindAttempts or 0) >= 6 then return end
        tx.fogBindAt, tx.fogBindAttempts = now + 1, (tx.fogBindAttempts or 0) + 1
        local bound, reason = bindFog(tx, tx.spawner)
        if not bound then
            if reason ~= tx.fogBindError then log("original fog doors waiting: " .. reason) end
            tx.fogBindError = reason
            return
        end
    end
    armFog(tx, now, keepClosed)
end

local function walkableHeight(hit)
    local point, normal = hit.ImpactPoint, hit.ImpactNormal
    if point and normal and type(normal.Z) == "number" and normal.Z >= 0.7
        and type(point.Z) == "number" and math.abs(point.Z) < math.huge then return point.Z end
end

local function groundZ(pawn, system, x, y, expectedZ, rise, drop)
    local top = { X = x, Y = y, Z = expectedZ + rise }
    local bottom = { X = x, Y = y, Z = expectedZ - drop }
    local hit = {}
    if system:LineTraceSingle(pawn, top, bottom, 0, false, {}, 0, hit, true, CLEAR, CLEAR, 0) then
        local z = walkableHeight(hit)
        if z then return z end
    end
    -- The stock high-altitude geometry uses FastGeo. Its hit can have a
    -- useful point and normal without a reflected UObject component.
    hit = {}
    if system:LineTraceSingleForObjects(pawn, top, bottom, WORLD_STATIC, false, {}, 0, hit, true, CLEAR, CLEAR, 0) then
        return walkableHeight(hit)
    end
end

function Arena.phaseDestination(pawn, system, scene)
    if not session or not session.ready or scene.map ~= MAP or not inWorld(pawn, session.world) then
        return nil, "等待溪谷擂台就绪"
    end
    local capsule = pawn.CapsuleComponent
    if not valid(capsule) then return nil, "等待玩家胶囊初始化" end
    local height = capsule:GetScaledCapsuleHalfHeight()
    for _, at in ipairs(scene.phaseReturnPoints) do
        local floor = groundZ(pawn, system, at.X, at.Y, at.Z, 160, 220)
        if floor then
            local position = { X = at.X, Y = at.Y, Z = floor + height + 6 }
            local aim = required(MATH):FindLookAtRotation(position, scene.spawnPoints[1])
            return { position = position, rotation = { Pitch = 0, Yaw = aim.Yaw, Roll = 0 } }
        end
    end
    return nil, "等待溪谷擂台内回位点的地面"
end

function Arena.mechanicGround(pawn, system, scene, x, y)
    if not session or not session.ready or scene.map ~= MAP or not inWorld(pawn, session.world) then return end
    return groundZ(pawn, system, x, y, scene.portalPoint.Z, 160, 220)
end

function Arena.portalDestination(pawn, system, scene)
    if not session or not session.ready or scene.map ~= MAP or not inWorld(pawn, session.world) then return end
    local at = scene.portalPoint
    local floor = groundZ(pawn, system, at.X, at.Y, at.Z, 180, 230)
    if not floor then return end
    local position = { X = at.X, Y = at.Y, Z = floor + PORTAL_TRIGGER_HEIGHT }
    local visualPosition = { X = at.X, Y = at.Y, Z = position.Z + 125 }
    local bell = session.bellLocation or scene.anchor
    local aim = required(MATH):FindLookAtRotation(position, bell)
    local radians = math.rad(aim.Yaw)
    -- The visible face of this effect was on the reverse side of the old aim.
    return { position = position, visualPosition = visualPosition, rotation = { Pitch = 0, Yaw = (aim.Yaw + 180) % 360, Roll = 0 },
        frontX = math.cos(radians), frontY = math.sin(radians) }
end

function Arena.portalCamera(pawn, system, portal, cameraZ)
    local point = portal.visualPosition
    local pawnZ = pawn:K2_GetActorLocation().Z
    local feetZ = pawnZ - pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()
    -- Carry the gameplay view's ground clearance over to the portal floor.
    -- Clamp unusual views left by finishers or wall collision.
    local height = math.max(140, math.min(cameraZ - feetZ, 420))
    local eyeZ = portal.position.Z - PORTAL_TRIGGER_HEIGHT + height
    for _, distance in ipairs({ 900, 820, 740 }) do
        local eye = { X = point.X + portal.frontX * distance, Y = point.Y + portal.frontY * distance, Z = eyeZ }
        if not system:LineTraceSingleForObjects(pawn, eye, point, WORLD_STATIC, false, {}, 0, {}, true, CLEAR, CLEAR, 0) then
            local aim = required(MATH):FindLookAtRotation(eye, point)
            return eye, { Pitch = aim.Pitch, Yaw = aim.Yaw, Roll = 0 }
        end
    end
end

function Arena.pushOutsidePortal(pawn, system, scene, portal, clearance)
    local point, at = portal.position, pawn:K2_GetActorLocation()
    local dx, dy = at.X - point.X, at.Y - point.Y
    local radius = math.sqrt(dx * dx + dy * dy)
    local x, y = portal.frontX, portal.frontY
    if radius > 1 then x, y = dx / radius, dy / radius end
    local capsule = pawn.CapsuleComponent
    if not valid(capsule) then return false end
    local height = capsule:GetScaledCapsuleHalfHeight()
    local reach = clearance + 8
    local function outside()
        local location = pawn:K2_GetActorLocation()
        return (location.X - point.X)^2 + (location.Y - point.Y)^2 >= clearance^2
    end
    for _, angle in ipairs({ 0, 45, -45, 90, -90, 180 }) do
        local radians = math.rad(angle)
        local cos, sin = math.cos(radians), math.sin(radians)
        local px, py = point.X + reach * (x * cos - y * sin), point.Y + reach * (x * sin + y * cos)
        local floor = groundZ(pawn, system, px, py, point.Z - PORTAL_TRIGGER_HEIGHT, 120, 150)
        if floor then
            pawn:K2_SetActorLocation({ X = px, Y = py, Z = floor + height + 6 }, true, {}, true)
            if outside() then return true end
        end
    end
    local fallback = Arena.phaseDestination(pawn, system, scene)
    if fallback then
        required("/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary"):PBZActorTeleportTo(
            pawn, fallback.position, pawn:K2_GetActorRotation(), false, false)
        return outside()
    end
    return false
end

local function findStand(pawn, system, scene, position)
    local x, y, z = position.X, position.Y, position.Z
    local capsule = pawn.CapsuleComponent
    if not valid(capsule) then return nil, "等待玩家胶囊初始化" end
    local entry = scene.anchor
    local height = capsule:GetScaledCapsuleHalfHeight()
    local movement = pawn.CharacterMovement
    local mode = valid(movement) and movement.MovementMode or 0
    local grounded = (mode == 1 or mode == 2) and (x - entry.X)^2 + (y - entry.Y)^2 + (z - entry.Z)^2 <= 140^2
    local foot = (grounded and z or entry.Z) - height
    local floor = groundZ(pawn, system, entry.X, entry.Y, foot, 150, 300)
    if floor and (not grounded or math.abs(floor - foot) <= 55) then
        return { X = entry.X, Y = entry.Y, Z = floor + height + 6 }, floor, grounded
    end
    if grounded then
        -- The native capsule already stands on this exact point.
        return { X = x, Y = y, Z = z }, foot, true
    end
    return nil, "等待原版入口地面"
end

local function findBellLocation(pawn, system, scene, floor, groundedEntry)
    local entry = scene.anchor
    local yaw = math.rad(scene.rotation.Yaw)
    local rightX, rightY = -math.sin(yaw), math.cos(yaw)
    local forward = scene.bellForwardOffset
    local originX, originY = entry.X + math.cos(yaw) * forward, entry.Y + math.sin(yaw) * forward
    for _, distance in ipairs({ 220, 270, 180, 320 }) do
        local x, y = originX + rightX * distance, originY + rightY * distance
        local base = groundZ(pawn, system, x, y, floor, 105, 130)
        if base and math.abs(base - floor) <= 100 then
            log(("ground confirmed playerZ=%.2f bellZ=%.2f"):format(floor, base))
            return { X = x, Y = y, Z = base + 2 }
        end
    end
    if groundedEntry and math.abs(floor - (entry.Z - 96)) < 65 then
        -- Cooked entrance props on the right occupy the same deck height.
        log(("bell using grounded entry elevation z=%.2f"):format(floor))
        return { X = originX + rightX * 220, Y = originY + rightY * 220, Z = floor + 2 }
    end
    return nil, "等待出生点右侧地面"
end

local function createBell(gameplay, pawn, tx, scene)
    local class, reason = SpawnClass.resolve(BELL_CLASS)
    if not valid(class) then return nil, reason end
    local rotation = { Pitch = 0, Yaw = scene.rotation.Yaw - 90, Roll = 0 }
    local transform = required(MATH):MakeTransform(tx.bellLocation, rotation, SCALE)
    local deferred = required("/Script/SGameAI.Default__SGameAIFunctionLibrary"):SpawnActorDeferred(pawn, class, transform, 1)
    if not valid(deferred) then return nil, "等待溪谷演武铃铛生成" end
    tx.bell = deferred
    deferred.BellID = FName(scene.bellSaveId)
    deferred.bDisableTeleport = true
    deferred.bTeleportOnBrokenBellLeave = false
    deferred.FlowTagMap:Empty()
    Events.allowCreatedBell(deferred)
    local bell = gameplay:FinishSpawningActor(deferred, transform, 1)
    assert(same(bell, deferred) and inWorld(bell, tx.world), "溪谷演武铃铛归属不匹配")
    assert(name(bell.BellID) == scene.bellSaveId and bell.bDisableTeleport
        and not bell.bTeleportOnBrokenBellLeave and #bell.FlowTagMap == 0, "溪谷演武铃铛设置未生效")
    tx.bell, tx.bellPlaced, tx.interactionMode, tx.nextBellCheck = bell, true, nil, 0
    return true
end

local function readRevive(system, mathLibrary)
    local transform, camera = {}, {}
    system:GetReviveTransform(transform, camera)
    local position, rotation = {}, {}
    mathLibrary:BreakTransform(transform, position, rotation, {})
    return position, rotation
end

local function verifyRevive(tx, pawn, scene)
    local gameSystem = required(SUBSYSTEM):GetWorldSubsystem(pawn, required("/Script/ProjectPBZ.PBZGameSystem"))
    assert(valid(gameSystem), "缺少溪谷原版复活接口")
    local mathLibrary = required(MATH)
    local function matches(at, facing)
        return distanceSquared(at, tx.respawn) <= 4 and math.abs((facing.Yaw - scene.rotation.Yaw + 180) % 360 - 180) < 1
    end
    if tx.armed and matches(readRevive(gameSystem, mathLibrary)) then return end
    gameSystem:SetReviveTransform(mathLibrary:MakeTransform(tx.respawn, scene.rotation, SCALE))
    local at, facing = readRevive(gameSystem, mathLibrary)
    assert(matches(at, facing), "溪谷铃铛复活点回读不匹配")
    tx.armed = true
    log(("native revive set beside bell x=%.2f y=%.2f z=%.2f"):format(at.X, at.Y, at.Z))
end

local function placePlayer(tx, pawn, controller, scene)
    local at = tx.respawn
    if distanceSquared(pawn:K2_GetActorLocation(), at) > 35^2 then
        assert(required(NATIVE):PBZActorTeleportTo(pawn, at, scene.rotation, false, false), "无法在溪谷铃铛旁放置玩家")
        controller:SetControlRotation(scene.rotation)
    end
    tx.pawn = pawn:GetAddress()
end

local function destroyBell(tx)
    if not tx then return end
    pcall(function()
        if inWorld(tx.bell, tx.world) and not tx.bell:IsActorBeingDestroyed() then tx.bell:K2_DestroyActor() end
    end)
end

function Arena.reset()
    local old = session
    session = nil
    openFog(old, false)
    destroyBell(old)
end

function Arena.getBell()
    if session and session.bellPlaced and valid(session.bell) then return session.bell end
end

local function prepareBell(tx, gameplay, system, pawn, scene)
    if not tx.respawn then
        local at, floor, grounded = findStand(pawn, system, scene, pawn:K2_GetActorLocation())
        if not at then return nil, floor end
        tx.respawn, tx.floor, tx.groundedEntry = at, floor, grounded
    end
    if not tx.bellLocation then
        local at, reason = findBellLocation(pawn, system, scene, tx.floor, tx.groundedEntry)
        if not at then
            -- The player may have landed since the first trace near the entry.
            local standing = pawn:K2_GetActorLocation()
            local near, standingZ = distanceSquared(standing, scene.anchor) <= 140^2, standing.Z
            local movement = pawn.CharacterMovement
            local mode = valid(movement) and movement.MovementMode or 0
            if (mode == 1 or mode == 2) and near then
                tx.groundedEntry = math.abs(standingZ - tx.respawn.Z) < 35
            end
            return nil, reason
        end
        tx.bellLocation = at
    end
    local made, reason = createBell(gameplay, pawn, tx, scene)
    if not made then return nil, reason end
    local at = tx.bellLocation
    log(("owned bell ready id=%s x=%.2f y=%.2f z=%.2f"):format(scene.bellSaveId, at.X, at.Y, at.Z))
    return true
end

local function updateBell(tx, gameplay, system, pawn, now, scene, allowBell)
    if not Arena.getBell() and not tx.bellFailure and now >= tx.nextBellAttempt then
        tx.nextBellAttempt = now + 1
        tx.bellAttempts = tx.bellAttempts + 1
        local ok, ready, reason = pcall(prepareBell, tx, gameplay, system, pawn, scene)
        if not ok then
            destroyBell(tx)
            tx.bellFailure = tostring(ready)
        elseif not ready then
            if reason ~= tx.bellWait then log("bell waiting: " .. tostring(reason)); tx.bellWait = reason end
            if tx.bellAttempts >= 12 then tx.bellFailure = tostring(reason) end
        end
        if tx.bellFailure then log("bell preparation stopped: " .. tx.bellFailure) end
    end
    if not Arena.getBell() or tx.interactionFailure then return end
    if tx.allowBell ~= allowBell or now >= (tx.nextBellCheck or 0) then
        tx.nextBellCheck = now + 1
        local ok, failure = pcall(function()
            local sphere = tx.bell.InteractionComp
            if not valid(sphere) then return end
            local collision = sphere:GetCollisionEnabled()
            if not tx.interactionMode then
                if collision == 0 then return end
                tx.interactionMode = collision
            end
            local desired = allowBell and tx.interactionMode or 0
            if collision ~= desired then sphere:SetCollisionEnabled(desired) end
        end)
        tx.allowBell = allowBell
        if not ok then
            tx.interactionFailure = tostring(failure)
            log("bell interaction control failed: " .. tx.interactionFailure)
        end
    end
end

local function updateRevive(tx, pawn, controller, now, scene)
    if not tx.respawn or tx.reviveFailure or now < tx.nextReviveCheck then return end
    tx.nextReviveCheck = now + 1
    local ok, failure = pcall(function()
        local attributes = pawn.AttributeSetBase
        if not valid(attributes) or attributes.Health.CurrentValue <= 0 then return end
        if tx.pawn and tx.pawn ~= pawn:GetAddress() then
            placePlayer(tx, pawn, controller, scene)
            tx.armed = nil
        else
            tx.pawn = pawn:GetAddress()
        end
        verifyRevive(tx, pawn, scene)
    end)
    if not ok then
        tx.reviveFailure = tostring(failure)
        log("native revive verification stopped: " .. tx.reviveFailure)
    end
end

local function update(tx, gameplay, system, pawn, controller, now, scene, allowBell, palace)
    if not tx.ready then
        if now < tx.nextArenaProbe then return nil, tx.reason end
        tx.nextArenaProbe = now + 0.5
        tx.spawner, tx.domain = Events.actor(SPAWNER), Events.actor(DOMAIN)
        if not inWorld(tx.spawner, tx.world) or tx.spawner.ShouldSpawn ~= false then
            tx.reason = "等待三面封印地原版首领点"; return nil, tx.reason
        end
        local bound, reason = bindFog(tx, tx.spawner)
        if not bound then tx.reason = reason; return nil, reason end
        local spawn = scene.spawnPoints[1]
        if not groundZ(pawn, system, spawn.X, spawn.Y, spawn.Z, 250, 350) then
            tx.reason = "等待三面封印地擂台地面"; return nil, tx.reason
        end
        if not palace then
            updateBell(tx, gameplay, system, pawn, now, scene, allowBell)
            if not Arena.getBell() then return nil, tx.bellFailure or tx.bellWait or "等待三面封印地铃铛" end
        end
        tx.ready, tx.reason = true, nil
        log("battle ready at the original YuCong spawn")
    end
    if not palace or allowBell or Arena.getBell() then updateBell(tx, gameplay, system, pawn, now, scene, allowBell) end
    if palace then
        if allowBell and not Arena.getBell() then return nil, tx.bellFailure or tx.bellWait or "正在准备血宫铃铛" end
        return true
    end
    if tx.revivePawn ~= pawn:GetAddress() then
        tx.revivePawn = pawn:GetAddress()
        tx.reviveFailure, tx.nextReviveCheck = nil, 0
    end
    updateRevive(tx, pawn, controller, now, scene)
    return true
end

function Arena.update(gameplay, system, pawn, controller, world, now, scene, allowBell, palace)
    if not session or not same(world, session.world) then
        assert(scene.map == MAP and name(gameplay:GetCurrentLevelName(pawn, true)) == MAP and inWorld(pawn, world),
            "溪谷演武地图或玩家归属不匹配")
        Arena.reset()
        session = { world = world, nextArenaProbe = 0, nextBellAttempt = 0,
            bellAttempts = 0, nextReviveCheck = 0, lookups = {}, lookupSince = now, lookupReportAt = now + 10 }
    end
    if session.failure then return nil, session.failure end
    local ok, ready, reason = pcall(update, session, gameplay, system, pawn, controller, now, scene, allowBell, palace)
    if ok then reportLookups(session, now); return ready, reason end
    session.failure = "溪谷演武场地准备失败：" .. tostring(ready)
    openFog(session, false)
    destroyBell(session)
    log(session.failure)
    return nil, session.failure
end

return Arena
