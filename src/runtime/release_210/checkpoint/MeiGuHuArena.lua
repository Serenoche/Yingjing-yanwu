local SceneArena = require("SceneArena")
local Layout = require("MeiGuHuStandaloneLayout")
local Events = require("MeiGuHuOriginalEvents")
local Arena = {}
local MAP = Events.map
local TITLE = "PBZ_StartMenu_CE_WP"
local BELL_CLASS = "/Game/PBZContent/Blueprint/Item/BP_MelodiousBell.BP_MelodiousBell_C"
local FOG_CLASS = "/Game/PBZContent/Blueprint/Item/BP_FogDoor.BP_FogDoor_C"
local MATH = "/Script/Engine.Default__KismetMathLibrary"
local NATIVE = "/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary"
local SUBSYSTEM = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local NAVIGATION = "/Script/NavigationSystem.Default__NavigationSystemV1"
local CLEAR = { R = 0, G = 0, B = 0, A = 0 }
local SCALE = { X = 1, Y = 1, Z = 1 }
local IDENTITY_ROTATION = { Pitch = 0, Yaw = 0, Roll = 0 }
local PENDING = 0x08023600
local WORLD_STATIC = { 0 }
local FOG_SAMPLE_STEP = 200
local FOG_BOX_HALF_WIDTH = 22
local FOG_BOX_HEIGHT = 650
local session

local function event(message) print("[PBZMeiGuHuOriginal] " .. message .. "\n") end
local function valid(object) return object and type(object.IsValid) == "function" and object:IsValid() end
local function same(a, b) return valid(a) and valid(b) and a:GetAddress() == b:GetAddress() end
local function name(value) return type(value) == "string" and value or (value and value:ToString() or "") end
local function distanceSquared(a, b) return (a.X - b.X)^2 + (a.Y - b.Y)^2 + (a.Z - b.Z)^2 end
local function unwrap(value)
    if valid(value) then return value end
    local ok, object = pcall(function() return value:get() end)
    return ok and object or nil
end

local function inWorld(actor, world)
    return valid(actor) and not actor:HasAnyFlags(PENDING) and same(SceneArena.runtimeWorld(actor), world)
end

local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object) and not object:HasAnyFlags(PENDING), "缺少关卡接口 " .. path)
    return object
end

local function findBell(gameplay, pawn, tx, scene)
    local actors = {}
    gameplay:GetAllActorsOfClass(pawn, required(BELL_CLASS), actors)
    for _, item in ipairs(actors) do
        local actor = unwrap(item)
        if inWorld(actor, tx.world) and name(actor:GetFName()) == Layout.bell and name(actor.BellID) == scene.bellSaveId
            and distanceSquared(actor:K2_GetActorLocation(), scene.bellLocation) <= 25 then
            return actor
        end
    end
end

local function floorAt(pawn, system, point, above, below)
    local top = { X = point.X, Y = point.Y, Z = point.Z + (above or 180) }
    local bottom = { X = point.X, Y = point.Y, Z = point.Z - (below or 220) }
    local hit = {}
    if system:LineTraceSingle(pawn, top, bottom, 0, false, {}, 0, hit, true, CLEAR, CLEAR, 0)
        and hit.ImpactNormal and hit.ImpactNormal.Z >= 0.7 and hit.ImpactPoint then
        return hit.ImpactPoint.Z
    end
    hit = {}
    if system:LineTraceSingleForObjects(pawn, top, bottom, WORLD_STATIC, false, {}, 0, hit, true, CLEAR, CLEAR, 0)
        and hit.ImpactNormal and hit.ImpactNormal.Z >= 0.7 and hit.ImpactPoint then
        return hit.ImpactPoint.Z
    end
end

local function prepareRespawn(tx, pawn, system, scene)
    local capsule = pawn.CapsuleComponent
    if not valid(capsule) then return nil, "等待玩家胶囊初始化" end
    local height = capsule:GetScaledCapsuleHalfHeight()
    local entry = scene.anchor
    local ground = floorAt(pawn, system, { X = entry.X, Y = entry.Y, Z = entry.Z - height })
    if not ground then return nil, "等待梅谷乐坊铃铛旁的原版地面" end
    if not floorAt(pawn, system, scene.spawnPoints[1]) then return nil, "等待梅谷乐坊擂台原版碰撞" end
    tx.respawn = { X = entry.X, Y = entry.Y, Z = ground + height + 6 }
    return true
end

local function checkNavigation(pawn, context)
    local navigation = required(NAVIGATION)
    local points = {}
    for i, point in ipairs(Layout.navPoints) do
        if i == 1 and valid(context) then
            local position = context:K2_GetActorLocation()
            local capsule = context.CapsuleComponent
            local halfHeight = valid(capsule) and capsule:GetScaledCapsuleHalfHeight() or 0
            point = { X = position.X, Y = position.Y, Z = position.Z - halfHeight }
        end
        local at = {}
        if not navigation:K2_ProjectPointToNavigation(pawn, point, at, nil, nil, { X = 120, Y = 120, Z = 180 })
            or not at.X or distanceSquared(at, point) > 180^2 then
            return false, "nav_projection_" .. i
        end
        points[i] = at
    end
    for i = 2, #points do
        local path = navigation:FindPathToLocationSynchronously(pawn, points[1], points[i], context or pawn, nil)
        if not valid(path) or path:IsPartial() or #path.PathPoints < 2 then
            return false, "nav_path_" .. i
        end
        local finish = path.PathPoints[#path.PathPoints]
        -- UE4SS maps its UObject validity check to IsValid. A complete
        -- NavigationPath still needs non-partial points ending on the target.
        if distanceSquared(finish, points[i]) > 120^2 then return false, "nav_endpoint_" .. i end
    end
    return true
end

local function spawn(gameplay, pawn, tx, class, transform)
    local actor = gameplay:BeginDeferredActorSpawnFromClass(pawn, class, transform, 1, nil, 1)
    assert(inWorld(actor, tx.world), "无法创建梅谷乐坊场地对象")
    tx.owned[#tx.owned + 1] = actor
    assert(same(gameplay:FinishSpawningActor(actor, transform, 1), actor), "无法完成梅谷乐坊场地对象生成")
    return actor
end

local function createCharacterBarrier(actor, boxClass, transform, extent, pawnChannel, walkable)
    local box = actor:AddComponentByClass(boxClass, true, transform, true)
    assert(valid(box), "梅谷乐坊阻挡组件创建失败")
    box.bCanEverAffectNavigation = false
    box:SetBoxExtent(extent, false)
    box:SetCollisionProfileName(FName("Profile_LA_InvisibleWall"), false)
    box:SetCollisionObjectType(0)
    box:SetCollisionResponseToChannel(2, 2)
    box:SetCollisionResponseToChannel(23, 2) -- Original fog-door AIPawn response.
    if pawnChannel ~= 2 and pawnChannel ~= 23 then box:SetCollisionResponseToChannel(pawnChannel, 2) end
    -- A floor participates in ground and foot IK queries. Walls leave sight clear.
    if not walkable then box:SetCollisionResponseToChannel(3, 0) end
    box:SetCollisionResponseToChannel(4, 0)
    box:SetGenerateOverlapEvents(false)
    box:SetCollisionEnabled(0)
    box:SetHiddenInGame(true, false)
    actor:FinishAddComponent(box, true, transform)
    assert(box:GetCollisionResponseToChannel(pawnChannel) == 2 and box:GetCollisionResponseToChannel(23) == 2,
        "梅谷乐坊碰撞组件未阻挡角色")
    return box
end

local function createBridgeDeck(actor, boxClass, system, pawn, mathLibrary, pawnChannel, deck)
    local transform = mathLibrary:MakeTransform(deck.position, deck.rotation, SCALE)
    local floor = createCharacterBarrier(actor, boxClass, transform, deck.extent, pawnChannel, true)
    floor.CanCharacterStepUpOn = 1 -- ECB_Yes
    floor:SetCollisionEnabled(3)
    assert(floor:GetCollisionEnabled() == 3 and floor.CanCharacterStepUpOn == 1
        and distanceSquared(floor:K2_GetComponentLocation(), deck.position) < 1, "梅谷乐坊桥尾承重面设置回读不符")

    local yaw = math.rad(deck.rotation.Yaw)
    local cos, sin = math.cos(yaw), math.sin(yaw)
    local hits, lowest, highest = 0, math.huge, -math.huge
    for _, along in ipairs({ -370, -185, 0, 185, 360 }) do
        for _, across in ipairs({ -90, 0, 90 }) do
            local x = deck.position.X + cos * along - sin * across
            local y = deck.position.Y + sin * along + cos * across
            local hit = {}
            if system:LineTraceSingleForObjects(pawn, { X = x, Y = y, Z = 950 }, { X = x, Y = y, Z = 700 },
                    WORLD_STATIC, false, {}, 0, hit, true, CLEAR, CLEAR, 0) then
                local z = hit.ImpactPoint and hit.ImpactPoint.Z
                local normal = hit.ImpactNormal and hit.ImpactNormal.Z
                local component = unwrap(hit.Component)
                if z and z >= 735 and z <= 815 and normal and normal >= 0.7 and valid(component)
                    and component:GetCollisionResponseToChannel(pawnChannel) == 2 then
                    hits, lowest, highest = hits + 1, math.min(lowest, z), math.max(highest, z)
                end
            end
        end
    end
    local heights = hits > 0 and ("%.1f..%.1f"):format(lowest, highest) or "none"
    event(("BRIDGE_DECK player_support=%d/15 z=%s"):format(hits, heights))
end

local function createBridgeGuard(gameplay, system, pawn, tx, mathLibrary)
    local guard = Layout.bridgeGuard
    if not guard then return end
    local capsule = unwrap(pawn.CapsuleComponent)
    assert(valid(capsule), "梅谷乐坊木桥缺少角色胶囊体")
    local pawnChannel = capsule:GetCollisionObjectType()
    local boxClass = required("/Script/Engine.BoxComponent")
    local actorClass = required("/Script/Engine.Actor")
    local actor = spawn(gameplay, pawn, tx, actorClass,
        mathLibrary:MakeTransform(guard.route[1], IDENTITY_ROTATION, SCALE))
    if guard.deck then createBridgeDeck(actor, boxClass, system, pawn, mathLibrary, pawnChannel, guard.deck) end
    local function trace(from, to)
        local hit = {}
        if system:LineTraceSingleForObjects(pawn, from, to, WORLD_STATIC, false, {}, 0, hit, true, CLEAR, CLEAR, 0) then
            return unwrap(hit.Component)
        end
    end
    for _, edge in ipairs(guard.edges) do
        local hits = 0
        for i = 2, #edge.points do
            local a, b = edge.points[i - 1], edge.points[i]
            local dx, dy = b.X - a.X, b.Y - a.Y
            local length = math.sqrt(dx * dx + dy * dy)
            local center = { X = (a.X + b.X) * 0.5, Y = (a.Y + b.Y) * 0.5, Z = guard.centerZ }
            local rotation = { Pitch = 0, Yaw = math.deg(math.atan(dy, dx)), Roll = 0 }
            local transform = mathLibrary:MakeTransform(center, rotation, SCALE)
            -- Extend each box into the next one so there is no gap at a bend.
            local extent = { X = length * 0.5 + 30, Y = edge.halfThickness or 16, Z = guard.halfHeight }
            local box = createCharacterBarrier(actor, boxClass, transform, extent, pawnChannel)
            box:SetCollisionEnabled(1)
            assert(box:GetCollisionEnabled() == 1 and distanceSquared(box:K2_GetComponentLocation(), center) < 1,
                "梅谷乐坊木桥空气墙设置回读不符")
            local nx, ny = -dy * 65 / length, dx * 65 / length
            local from = { X = center.X + nx, Y = center.Y + ny, Z = guard.probeHeight }
            local to = { X = center.X - nx, Y = center.Y - ny, Z = guard.probeHeight }
            if same(trace(from, to), box) or same(trace(to, from), box) then hits = hits + 1 end
        end
        local count = #edge.points - 1
        event(("BRIDGE_GUARD side=%s boxes=%d traces=%d/%d"):format(edge.name, count, hits, count))
    end
    local clear, deck = 0, 0
    for i, point in ipairs(guard.route) do
        if i > 1 and not valid(trace(guard.route[i - 1], point)) then clear = clear + 1 end
        local z = floorAt(pawn, system, point, 0, 330)
        if z and z >= 680 and z <= 875 then deck = deck + 1 end
    end
    event(("BRIDGE_ROUTE clear=%d/%d deck=%d/%d"):format(clear, #guard.route - 1, deck, #guard.route))
end

local function createFogCollision(gameplay, system, pawn, tx, mathLibrary, spline)
    local transform = mathLibrary:MakeTransform({ X = 0, Y = 0, Z = 0 }, IDENTITY_ROTATION, SCALE)
    local actor = spawn(gameplay, pawn, tx, required("/Script/Engine.Actor"), transform)
    local boxClass = required("/Script/Engine.BoxComponent")
    local length = spline:GetSplineLength()
    local count = math.ceil(length / FOG_SAMPLE_STEP)
    assert(count > 0, "梅谷乐坊雾门样条长度无效")
    tx.fogSegments, tx.fogSystem = {}, system
    local first = spline:GetLocationAtDistanceAlongSpline(0, 1)
    local previous = first
    local capsule = unwrap(pawn.CapsuleComponent)
    assert(valid(capsule), "梅谷乐坊雾门缺少角色胶囊体")
    local pawnChannel = capsule:GetCollisionObjectType()
    local function addSegment(a, b, probe)
        local dx, dy = b.X - a.X, b.Y - a.Y
        local width = math.sqrt(dx * dx + dy * dy)
        if width < 1 then return end
        local center = { X = (a.X + b.X) * 0.5, Y = (a.Y + b.Y) * 0.5, Z = (a.Z + b.Z) * 0.5 + 160 }
        local rotation = { Pitch = 0, Yaw = math.deg(math.atan(dy, dx)), Roll = 0 }
        local worldTransform = mathLibrary:MakeTransform(center, rotation, SCALE)
        local extent = { X = width * 0.5 + 12, Y = FOG_BOX_HALF_WIDTH, Z = FOG_BOX_HEIGHT }
        local box = createCharacterBarrier(actor, boxClass, worldTransform, extent, pawnChannel)
        assert(distanceSquared(box:K2_GetComponentLocation(), center) < 1, "梅谷乐坊雾门碰撞位置不符")
        local offsetX, offsetY = dy * 45 / width, -dx * 45 / width
        tx.fogSegments[#tx.fogSegments + 1] = { box = box, probe = probe,
            from = { X = center.X + offsetX, Y = center.Y + offsetY, Z = center.Z },
            to = { X = center.X - offsetX, Y = center.Y - offsetY, Z = center.Z } }
    end
    for i = 1, count do
        local point = spline:GetLocationAtDistanceAlongSpline(i * length / count, 1)
        addSegment(previous, point, i > 3 and i <= count - 3)
        previous = point
    end
    -- The original open spline's two ends overlap near the bell-side entry.
    assert(#tx.fogSegments == count, "梅谷乐坊雾门碰撞段数不符")
end

local FOG_NAME = "BP_FogDoor_C_UAID_E89C25A750C7E9CB02_1646099519"
local function bindFog(gameplay, system, pawn, tx, mathLibrary)
    if inWorld(tx.fog, tx.world) then return true end
    local fog = StaticFindObject(Events.path .. "." .. MAP .. ":PersistentLevel." .. FOG_NAME)
    if not inWorld(fog, tx.world) then
        local actors, class = {}, StaticFindObject(FOG_CLASS)
        if valid(class) then
            gameplay:GetAllActorsOfClass(pawn, class, actors)
            for _, item in ipairs(actors) do
                local actor = unwrap(item)
                if valid(actor) and name(actor:GetFName()) == FOG_NAME and inWorld(actor, tx.world) then
                    fog = actor
                    break
                end
            end
        end
    end
    local spline = inWorld(fog, tx.world) and unwrap(fog.Spline)
    if not valid(spline) or spline:GetSplineLength() <= 0 then return nil, "等待梅谷乐坊原版雾门" end
    createBridgeGuard(gameplay, system, pawn, tx, mathLibrary)
    createFogCollision(gameplay, system, pawn, tx, mathLibrary, spline)
    tx.fog = fog
    tx.fogOriginal = { collision = fog:GetActorEnableCollision(), passthrough = fog.bInitiallyPassthrough }
    fog.bInitiallyPassthrough = true
    fog:UpdateAfterOpen()
    fog:SetActorEnableCollision(false)
    event(("FOG existing=true collision_components=%d"):format(#tx.fogSegments))
    return true
end

local function armRevive(tx, pawn, controller, scene)
    local gameSystem = required(SUBSYSTEM):GetWorldSubsystem(pawn, required("/Script/ProjectPBZ.PBZGameSystem"))
    assert(valid(gameSystem), "缺少梅谷乐坊复活接口")
    local at, mathLibrary = tx.respawn, required(MATH)
    if distanceSquared(pawn:K2_GetActorLocation(), at) > 60^2 then
        assert(required(NATIVE):PBZActorTeleportTo(pawn, at, scene.rotation, false, false), "无法回到梅谷乐坊铃铛旁")
        controller:SetControlRotation(scene.rotation)
    end
    gameSystem:SetReviveTransform(mathLibrary:MakeTransform(at, scene.rotation, SCALE))
    local transform, camera, position, rotation = {}, {}, {}, {}
    gameSystem:GetReviveTransform(transform, camera)
    mathLibrary:BreakTransform(transform, position, rotation, {})
    assert(distanceSquared(position, at) <= 4, "梅谷乐坊复活点回读不匹配")
    tx.pawn = pawn:GetAddress()
end

local function updateBell(tx, enabled)
    local sphere = tx.bell.InteractionComp
    if not valid(sphere) then return end
    local mode = sphere:GetCollisionEnabled()
    if not same(tx.interaction, sphere) then
        if mode == 0 then return end
        tx.interaction, tx.bellMode = sphere, mode
    end
    local desired = enabled and tx.bellMode or 0
    if mode ~= desired then sphere:SetCollisionEnabled(desired) end
end

function Arena.getBell()
    if session and inWorld(session.bell, session.world) then return session.bell end
end

function Arena.findBellWidgets(class, now)
    if not session or now < session.nextMenuLookup then return end
    session.nextMenuLookup = now + 0.25
    return FindAllOf(class)
end

function Arena.phaseDestination(pawn, system, scene)
    if not session or not session.ready or not inWorld(pawn, session.world) then return nil, "等待梅谷乐坊场地就绪" end
    local height = pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()
    for _, at in ipairs(scene.phaseReturnPoints) do
        local ground = floorAt(pawn, system, at)
        if ground then
            local position = { X = at.X, Y = at.Y, Z = ground + height + 6 }
            local aim = required(MATH):FindLookAtRotation(position, scene.spawnPoints[1])
            return { position = position, rotation = { Pitch = 0, Yaw = aim.Yaw, Roll = 0 } }
        end
    end
    return nil, "等待梅谷乐坊场内回位点的地面"
end

function Arena.updateCombat(pawn, active)
    local tx = session
    if not tx or not tx.ready or tx.fogClosed == active or not inWorld(tx.fog, tx.world) then return end
    -- Closing only inside the ring keeps the bell-side approach accessible
    -- if the enemy engages a player who is still outside.
    local at, center = pawn:K2_GetActorLocation(), Layout.floor.position
    if active and (at.X - center.X)^2 + (at.Y - center.Y)^2 > 850^2 then return end
    if tx.fogFailed == active then return end
    local ok, failure = pcall(function()
        local mode = active and 1 or 0 -- QueryOnly is sufficient for the character movement sweep.
        for _, segment in ipairs(tx.fogSegments) do segment.box:SetCollisionEnabled(mode) end
        tx.fog.bInitiallyPassthrough = not active
        if active then tx.fog:UpdateAfterClose() else tx.fog:UpdateAfterOpen() end
        local hits, probes = 0, 0
        for _, segment in ipairs(tx.fogSegments) do
            assert(segment.box:GetCollisionEnabled() == mode, "梅谷乐坊雾门碰撞状态不符")
            if segment.probe then
                probes = probes + 1
                local hit = {}
                if tx.fogSystem:LineTraceSingleForObjects(pawn, segment.from, segment.to, WORLD_STATIC, false, {}, 0,
                        hit, true, CLEAR, CLEAR, 0) and same(unwrap(hit.Component), segment.box) then
                    hits = hits + 1
                end
            end
        end
        event(("FOG_COLLISION closed=%s boxes=%d hits=%d/%d"):format(tostring(active), #tx.fogSegments, hits, probes))
    end)
    if ok then
        tx.fogClosed, tx.fogFailed = active, nil
        event("FOG_STATE closed=" .. tostring(active))
    else
        for _, segment in ipairs(tx.fogSegments) do
            pcall(function() segment.box:SetCollisionEnabled(0) end)
        end
        pcall(function()
            tx.fog.bInitiallyPassthrough = true
            tx.fog:UpdateAfterOpen()
        end)
        tx.fogClosed = false
        tx.fogFailed = active
        event("ERROR fog_state " .. tostring(failure))
    end
end

function Arena.reset()
    local old = session
    session = nil
    if not old then return end
    if inWorld(old.bell, old.world) and valid(old.interaction) then
        pcall(function() old.interaction:SetCollisionEnabled(old.bellMode) end)
    end
    if inWorld(old.fog, old.world) then
        pcall(function()
            old.fog.bInitiallyPassthrough = old.fogOriginal.passthrough
            if old.fogOriginal.passthrough then old.fog:UpdateAfterOpen() end
            old.fog:SetActorEnableCollision(old.fogOriginal.collision)
        end)
    end
    for _, actor in ipairs(old.owned) do
        if inWorld(actor, old.world) and not actor:IsActorBeingDestroyed() then
            pcall(function() actor:K2_DestroyActor() end)
        end
    end
end

function Arena.abort()
    Arena.reset()
    Events.reset()
end

function Arena.onMapPre()
    Events.onMapPre()
end

function Arena.update(gameplay, system, pawn, controller, world, now, scene, allowBell)
    assert(scene.map == MAP and name(gameplay:GetCurrentLevelName(pawn, true)) == MAP and inWorld(pawn, world),
        "梅谷乐坊原版地图或角色归属不匹配")
    local entered, reason = Events.arrive(world)
    if not entered then return nil, reason end
    if not session or not same(session.world, world) then
        Arena.reset()
        session = { world = world, owned = {}, nextProbe = 0, nextMenuLookup = 0, nextBellCheck = 0,
            deadline = now + 25, fogClosed = false }
        event("MAP_LOADED name=" .. MAP)
    end
    local tx = session
    if tx.failure then return nil, tx.failure end
    if not tx.ready then
        if now < tx.nextProbe then return nil, tx.waiting end
        tx.nextProbe = now + 0.5
        local function waiting(message)
            tx.waiting = message
            if now >= tx.deadline and not tx.waitLogged then
                tx.waitLogged = true
                event("READINESS_WAIT " .. tostring(message))
            end
            return nil, message
        end
        tx.bell = Arena.getBell() or findBell(gameplay, pawn, tx, scene)
        if not tx.bell then return waiting("等待梅谷乐坊原版铃铛") end
        local grounded, groundReason = prepareRespawn(tx, pawn, system, scene)
        if not grounded then return waiting(groundReason) end
        local navigation, navReason = checkNavigation(pawn)
        if not navigation then return waiting("等待原版寻路区块注册 " .. navReason) end
        local ok, fog, fogReason = pcall(bindFog, gameplay, system, pawn, tx, required(MATH))
        if not ok then tx.failure = tostring(fog); event("ERROR fog_setup " .. tx.failure); return nil, tx.failure end
        if not fog then return waiting(fogReason) end
        local armed, reviveError = pcall(armRevive, tx, pawn, controller, scene)
        if not armed then return waiting(tostring(reviveError)) end
        tx.ready = true
        Events.ready()
    elseif tx.pawn ~= pawn:GetAddress() and now >= (tx.nextReviveCheck or 0) then
        tx.nextReviveCheck = now + 1
        local armed, reviveError = pcall(armRevive, tx, pawn, controller, scene)
        if not armed and tx.reviveError ~= reviveError then event("REVIVE_WAIT " .. tostring(reviveError)) end
        tx.reviveError = not armed and reviveError or nil
    end
    if not Arena.getBell() and now >= (tx.nextBellLookup or 0) and
        distanceSquared(pawn:K2_GetActorLocation(), scene.bellLocation) <= 1800^2 then
        tx.nextBellLookup = now + 1
        tx.bell = findBell(gameplay, pawn, tx, scene)
    end
    if Arena.getBell() and (allowBell ~= tx.allowBell or now >= tx.nextBellCheck) then
        updateBell(tx, allowBell)
        tx.allowBell, tx.nextBellCheck = allowBell, now + 0.75
    end
    Events.update(system, now)
    return true
end

return Arena
