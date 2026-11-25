local SceneArena = require("SceneArena")
local Events = require("MeiGuHuOriginalEvents")
local SpawnClass = require("SpawnClass")
local StockBell = require("StockBellArena")
local Terrain = require("ArenaTerrain")
local RoadFog = require("XiguRoadFog")
local WellFloor = require("PangzhenWellFloor")
local Arena = {}
local session

local BELL_CLASS = "/Game/PBZContent/Blueprint/Item/BP_BrokenBell.BP_BrokenBell_C"
local MATH = "/Script/Engine.Default__KismetMathLibrary"
local NAV = "/Script/NavigationSystem.Default__NavigationSystemV1"
local NATIVE = "/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary"
local SUBSYSTEM = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local GAME_SYSTEM = "/Script/ProjectPBZ.PBZGameSystem"
local SCALE = { X = 1, Y = 1, Z = 1 }
local PENDING = 0x08023600

local function valid(value)
    return value and type(value.IsValid) == "function" and value:IsValid()
end

local function unwrap(value)
    if valid(value) then return value end
    if value ~= nil then
        local ok, object = pcall(function() return value:get() end)
        if ok and valid(object) then return object end
    end
end

local function text(value)
    return type(value) == "string" and value or (value and value:ToString() or "")
end

local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "缺少原版接口 " .. path)
    return object
end

local function live(actor, world)
    if not valid(actor) or actor:HasAnyFlags(PENDING) or actor:IsActorBeingDestroyed() then return false end
    local owner = SceneArena.runtimeWorld(actor)
    return valid(owner) and valid(world) and owner:GetAddress() == world:GetAddress()
end

local function dist2(first, second)
    return (first.X - second.X)^2 + (first.Y - second.Y)^2 + (first.Z - second.Z)^2
end

local function log(message)
    local tagging = session and session.scene and session.scene.walkIn
    local prefix = tagging and "[PBZXiguBossArena] scene=" .. session.scene.id .. " " or "[PBZPengMengArena] "
    print(prefix .. message .. "\n")
end

local insideBoundary, project, hasPath = Terrain.contains, Terrain.project, Terrain.hasPath

function Arena.inside(pawn, scene)
    local at = pawn:K2_GetActorLocation()
    local height = scene.combatHeight
    return at.Z >= (height and height.min or -24750) and at.Z <= (height and height.max or -24005)
        and insideBoundary(at, scene.combatBoundary)
end

local function grounded(pawn, system, point, above, below, ignored)
    local z = StockBell.floorAt(pawn, system, point, point.Z + above, point.Z - below, ignored)
    if z then return { X = point.X, Y = point.Y, Z = z } end
end

function Arena.mechanicFloor(pawn, system, point)
    local floor = grounded(pawn, system, point, 150, 195)
    if floor and math.abs(floor.Z - point.Z) <= 110 then return floor end
end

function Arena.mechanicRoute(pawn, scene, start, destination)
    local navigation = required(NAV)
    local from, to = project(navigation, pawn, start), project(navigation, pawn, destination)
    return from and to and hasPath(navigation, pawn, from, to, scene.combatBoundary)
end

Arena.combatDistanceSquared = Terrain.distanceToBoundarySquared
Arena.recoveryGround = Terrain.recoveryGround

local function setDoors(tx, close)
    for _, door in ipairs(tx.doors) do
        if live(door, tx.world) then
            if close then
                door:SetActorEnableCollision(true)
                door["Close By Mob Script"](door)
            else
                door:OpenByMobScript()
            end
        else
            assert(not close, "原版雾门已卸载")
        end
    end
end

local function doorsBlock(tx)
    for _, door in ipairs(tx.doors) do
        if not live(door, tx.world) or not door:GetActorEnableCollision() then return false end
        local walls = door["Spline Mesh Component"]
        if not walls or #walls == 0 then return false end
        for index = 1, #walls do
            local wall = unwrap(walls[index])
            if not valid(wall) then return false end
            local mode = wall:GetCollisionEnabled()
            local blocksPawn = (mode == 1 or mode == 3 or mode == 5) and wall:GetCollisionResponseToChannel(2) == 2
            if not blocksPawn then return false end
        end
    end
    return true
end

local function seal(tx, scene, now)
    if now < tx.nextFogProbe then return tx.sealed, tx.fogWait end
    tx.nextFogProbe = now + (tx.sealed and 1 or 0.3)
    if not tx.doors then
        local doors = {}
        for index, name in ipairs(scene.fogDoors) do
            local door = Events.actor(name)
            if not live(door, tx.world) then return nil, "等待原版雾门 " .. index end
            doors[index] = door
        end
        tx.doors = doors
        for index, door in ipairs(doors) do
            local at = door:K2_GetActorLocation()
            log(("FOG stock_gate=%s x=%.1f y=%.1f z=%.1f"):format(scene.fogDoors[index], at.X, at.Y, at.Z))
        end
    end
    if doorsBlock(tx) then
        if not tx.sealed then log("FOG blocking=2") end
        tx.sealed, tx.fogWait = true, nil
        return true
    end
    tx.sealed, tx.fogWait = nil, "等待两道原版雾门封闭"
    if now >= tx.nextFogRequest then
        tx.nextFogRequest = now + 3
        local ok, why = pcall(setDoors, tx, true)
        if not ok then
            tx.fogWait = "原版雾门封闭失败：" .. tostring(why)
            tx.doors = nil  -- Rebind if the original gate streamed out.
        else
            log("FOG requested=closed")
        end
    end
    return nil, tx.fogWait
end

local function dropBell(tx)
    if live(tx.bell, tx.world) then
        local move = tx.bellMove
        if move and move.address == tx.bell:GetAddress() then
            tx.bell:K2_SetActorLocation(move.origin, false, {}, true)
            if move.mobility ~= 2 and valid(tx.bell.RootComponent) then
                tx.bell.RootComponent:SetMobility(move.mobility)
            end
        end
        if tx.ownedBell then tx.bell:K2_DestroyActor()
        elseif valid(tx.bell.InteractionComp) and tx.bellCollision then
            tx.bell.InteractionComp:SetCollisionEnabled(tx.bellCollision)
        end
    end
    tx.bell, tx.bellCollision, tx.allowBell = nil, nil, nil
    tx.ownedBell, tx.bellMove = nil, nil
end

local function configureArenaBell(bell, scene)
    if not scene.arenaOnlyBell then return end
    -- GA_InteractBell calls ActivateBell only for an inactive bell. Register
    -- this instance as already active locally so interaction cannot unlock a
    -- region or add a story destination to the native bell list.
    bell.bActive = true
    bell.IsFirstSave = false
    bell.bDisableTeleport = true
    bell.bTeleportOnBrokenBellLeave = false
    assert(bell.bActive and not bell.IsFirstSave and bell.bDisableTeleport and not bell.bTeleportOnBrokenBellLeave,
        "演武铃铛状态未生效")
end

local function spawnBell(tx, gameplay, pawn, scene, at)
    local class, reason = SpawnClass.resolve(BELL_CLASS)
    if not valid(class) then return nil, reason or "等待演武铃铛资源" end
    at.Z = at.Z + 2
    local facing = { Pitch = 0, Yaw = scene.rotation.Yaw - 90, Roll = 0 }
    local transform = required(MATH):MakeTransform(at, facing, SCALE)
    local deferred = required("/Script/SGameAI.Default__SGameAIFunctionLibrary"):SpawnActorDeferred(pawn, class, transform, 1)
    if not valid(deferred) then return nil, "等待门口铃铛生成" end
    tx.bell, tx.ownedBell = deferred, true
    deferred.BellID = FName(scene.bellSaveId)
    deferred.bDisableTeleport = true
    deferred.bTeleportOnBrokenBellLeave = false
    deferred.FlowTagMap:Empty()
    configureArenaBell(deferred, scene)
    Events.allowCreatedBell(deferred)
    local actor = gameplay:FinishSpawningActor(deferred, transform, 1)
    assert(live(actor, tx.world) and actor:GetAddress() == deferred:GetAddress(), "门口铃铛不在当前演武场地")
    assert(actor.bDisableTeleport and not actor.bTeleportOnBrokenBellLeave and #actor.FlowTagMap == 0,
        "门口铃铛交互设置未生效")
    configureArenaBell(actor, scene)
    tx.bellCollision, tx.allowBell = nil, nil
    return true
end

local function moveStockBell(bell, pawn, position)
    if not position then return false end
    if dist2(bell:K2_GetActorLocation(), position) <= 2^2 then return true end

    -- Share XY with the checkpoint while keeping the original interaction volume.
    local channel = pawn.CapsuleComponent:GetCollisionObjectType()
    local meshClass = required("/Script/Engine.MeshComponent")
    local parts = bell:K2_GetComponentsByClass(meshClass) or {}
    local box = bell.CollisionBox
    if valid(box) and box:GetAddress() ~= bell.InteractionComp:GetAddress()
        and box:GetCollisionResponseToChannel(channel) == 2 then
        box:SetCollisionResponseToChannel(channel, 0)
    end
    for _, item in ipairs(parts) do
        local mesh = unwrap(item)
        if valid(mesh) and mesh:GetCollisionResponseToChannel(channel) == 2 then
            mesh:SetCollisionResponseToChannel(channel, 0)
        end
    end
    bell:K2_SetActorLocation(position, false, {}, true)
    if dist2(bell:K2_GetActorLocation(), position) > 2^2 then
        local root = bell.RootComponent
        if not valid(root) then return false end
        root:SetMobility(2)
        bell:K2_SetActorLocation(position, false, {}, true)
    end
    if dist2(bell:K2_GetActorLocation(), position) > 2^2 then return false end
    log(("BELL_MOVED x=%.2f y=%.2f z=%.2f"):format(position.X, position.Y, position.Z))
    return true
end

local function bindStockBell(tx, gameplay, pawn, scene)
    local spec, bell = scene.checkpointBell, Events.actor()
    if not live(bell, tx.world) then
        local class = StaticFindObject(spec.classPath)
        if not valid(class) then return nil, "等待原版铃铛资源" end
        local actors = {}
        gameplay:GetAllActorsOfClass(pawn, class, actors)
        for _, value in ipairs(actors) do
            local candidate = unwrap(value)
            if live(candidate, tx.world) and text(candidate:GetFName()) == spec.name
                and text(candidate.BellID) == spec.id then bell = candidate; break end
        end
    end
    if not live(bell, tx.world) or text(bell.BellID) ~= spec.id then return nil, "等待" .. scene.name .. "原版铃铛" end
    if not valid(bell.InteractionComp) then return nil, "等待原版铃铛交互组件" end
    if scene.moveCheckpointBell and not moveStockBell(bell, pawn, tx.bellPlacement) then
        return nil, "等待" .. scene.name .. "原铃迁到入场点"
    end
    bell.bDisableTeleport = true
    bell.bTeleportOnBrokenBellLeave = false
    if #bell.FlowTagMap > 0 then bell.FlowTagMap:Empty() end
    if spec.ignoreActivationTags then
        bell:SetActorHiddenInGame(false)
        bell:SetActorEnableCollision(true)
        bell:SetActorTickEnabled(true)
    end
    configureArenaBell(bell, scene)
    tx.bell, tx.bellCollision, tx.allowBell = bell, nil, nil
    if tx.bellDestination then
        assert(text(bell:GetFName()) == spec.name, "原版铃铛实例不符")
        local target = tx.bellDestination
        local location = bell:K2_GetActorLocation()
        if dist2(location, target) > 4 then
            local root = bell.RootComponent
            assert(valid(root), "原版铃铛根组件未加载")
            tx.bellMove = { address = bell:GetAddress(), mobility = root.Mobility,
                origin = { X = location.X, Y = location.Y, Z = location.Z } }
            if root.Mobility ~= 2 then root:SetMobility(2) end
            assert(bell:K2_SetActorLocation(target, false, {}, true)
                and dist2(bell:K2_GetActorLocation(), target) <= 4, "原版铃铛搬移回读不符")
            local at = bell:K2_GetActorLocation()
            log(("BELL relocated id=%s x=%.1f y=%.1f z=%.1f"):format(spec.id, at.X, at.Y, at.Z))
        end
    end
    return true
end

local function openAnimatedDoor(tx, name)
    local door = Events.actor(name)
    if not live(door, tx.world) then return end
    local address = door:GetAddress()
    if tx.openedDoors[name] == address and not door:GetActorEnableCollision() then return end

    door:SetActorEnableCollision(false)
    local posed, why = pcall(function()
        local mesh, clip = unwrap(door.SkeletalMesh), unwrap(door["Anim Asset"])
        assert(mesh and clip, "木门开启动画未加载")
        local length = clip:GetPlayLength()
        assert(length > 0, "木门开启动画时长无效")
        mesh:PlayAnimation(clip, false)
        mesh:Stop()
        mesh:SetPosition(length, false)
        assert(math.abs(mesh:GetPosition() - length) < 0.05, "木门开启姿态回读不符")
    end)
    door:SetActorHiddenInGame(not posed)
    tx.openedDoors[name] = address
    log("DOOR open=" .. name .. (posed and " pose=stock" or " pose=hidden " .. tostring(why)))
end

local function keepEntryOpen(tx, scene, now)
    if now < tx.nextFogProbe then return end
    tx.nextFogProbe = now + 0.75
    if scene.openAnimatedDoor then openAnimatedDoor(tx, scene.openAnimatedDoor) end
    for _, name in ipairs(scene.openStoryDoors) do
        local door = Events.actor(name)
        if live(door, tx.world) and (tx.openedDoors[name] ~= door:GetAddress() or door:GetActorEnableCollision()) then
            door:OpenByMobScript()
            door:SetActorEnableCollision(false)
            tx.openedDoors[name] = door:GetAddress()
        end
    end
end

local function updatePlayer(tx, pawn, controller, scene)
    local attributes = pawn.AttributeSetBase
    if not valid(attributes) or attributes.Health.CurrentValue <= 0 then return false end
    local address = pawn:GetAddress()
    local newPawn = tx.pawn ~= address
    local mathLibrary = required(MATH)
    local gameSystem = required(SUBSYSTEM):GetWorldSubsystem(pawn, required(GAME_SYSTEM))
    assert(valid(gameSystem), "等待内测复活接口")
    local function currentReviveMatches()
        local transform, camera, position, rotation = {}, {}, {}, {}
        gameSystem:GetReviveTransform(transform, camera)
        mathLibrary:BreakTransform(transform, position, rotation, {})
        return position.X and rotation.Yaw and dist2(position, tx.landing) <= 4
            and math.abs((rotation.Yaw - scene.rotation.Yaw + 180) % 360 - 180) < 1
    end
    if newPawn or not currentReviveMatches() then
        gameSystem:SetReviveTransform(mathLibrary:MakeTransform(tx.landing, scene.rotation, SCALE))
        assert(currentReviveMatches(), "门口复活点回读不符")
    end
    if newPawn then
        if dist2(pawn:K2_GetActorLocation(), tx.landing) > 35^2 then
            assert(required(NATIVE):PBZActorTeleportTo(pawn, tx.landing, scene.rotation, false, false), "门口落点定位失败")
        end
        controller:SetControlRotation(scene.rotation)
        tx.pawn = address
        log(("REVIVE x=%.1f y=%.1f z=%.1f"):format(tx.landing.X, tx.landing.Y, tx.landing.Z))
    end
    return true
end

local function spawnersIsolated(tx, scene)
    if not scene.walkIn then
        local native, trigger = Events.actor(scene.storySpawner), Events.actor(scene.storyTrigger)
        if not live(native, tx.world) or not live(trigger, tx.world) or trigger:GetActorEnableCollision() then
            return false
        end
    end
    for _, name in ipairs(scene.storySpawners or { scene.storySpawner }) do
        local native = Events.actor(name)
        if live(native, tx.world) and not Events.squadSpawnerAllowed(native)
            and (native.ShouldSpawn ~= false or live(unwrap(native:GetPawn()), tx.world)) then
            return false
        end
    end
    return true
end

local function prepare(tx, gameplay, system, pawn, controller, scene)
    if not spawnersIsolated(tx, scene) then return nil, "等待" .. scene.name .. "原版刷怪隔离" end

    local entry = scene.entryGround or { X = scene.anchor.X, Y = scene.anchor.Y, Z = scene.anchor.Z - 130 }
    local floor = grounded(pawn, system, entry, 135, 155)
    local bell = scene.checkpointBell and not scene.relocateCheckpointBell and scene.bellGround
        or grounded(pawn, system, scene.bellGround, 105, 130)
    local checkCombatGround = not scene.entryBeforeCombat
    local stand = checkCombatGround and grounded(pawn, system, scene.phaseReturnPoints[1], 155, 160)
    if not floor or not bell or (checkCombatGround and not stand) or not valid(pawn.CapsuleComponent) then
        return nil, "等待场内复活点、钟位和战斗站位的地面"
    end
    if scene.bellClampToNav then bell.Z = math.min(bell.Z, scene.bellGround.Z) end
    if not scene.allowSeparateBellFloor and math.abs(bell.Z - floor.Z) > 90 then
        return nil, "门口铃铛与玩家落点不在同一段路面"
    end
    local navigation, inside
    if checkCombatGround then
        navigation = required(NAV)
        local routeStart = floor
        if scene.entryPathStart then
            -- Start walking navigation on the combat side of the original ledge.
            routeStart = grounded(pawn, system, scene.entryPathStart, 150, 195)
            if not routeStart then return nil, "等待原版入场路线的地面" end
        end
        local start = project(navigation, pawn, routeStart)
        inside = project(navigation, pawn, stand)
        if not start or not inside or not hasPath(navigation, pawn, start, inside) then
            return nil, "等待复活位到战斗区的原版导航"
        end
    end
    local nearest = math.huge
    for index, point in ipairs(scene.spawnPoints) do
        local distance = math.sqrt((point.X - floor.X)^2 + (point.Y - floor.Y)^2)
        if distance < scene.reviveClearance or (scene.walkIn and
            (point.X - bell.X)^2 + (point.Y - bell.Y)^2 < scene.reviveClearance^2) then
            return nil, "铃铛或复活位离 BOSS 刷点过近 " .. index
        end
        nearest = math.min(nearest, distance)
        if checkCombatGround then
            local top = scene.walkIn and point.Z + 150 or scene.spawnTrace.top
            local bottom = scene.walkIn and point.Z - 195 or scene.spawnTrace.bottom
            local z = StockBell.floorAt(pawn, system, point, top, bottom)
            if not z then return nil, "等待战斗刷新点地面 " .. index end
            local target = project(navigation, pawn, { X = point.X, Y = point.Y, Z = z })
            if not target or not hasPath(navigation, pawn, target, inside) then
                return nil, "等待原版寻路到战斗刷新点 " .. index
            end
        end
    end
    if scene.moveCheckpointBell then tx.bellPlacement = { X = floor.X, Y = floor.Y, Z = floor.Z } end
    floor.Z = floor.Z + pawn.CapsuleComponent:GetScaledCapsuleHalfHeight() + 6
    tx.landing = floor
    if not updatePlayer(tx, pawn, controller, scene) then return nil, "等待玩家加载" end
    local made, why
    if scene.relocateCheckpointBell then
        tx.bellDestination = { X = bell.X, Y = bell.Y, Z = bell.Z + 2 }
    elseif scene.checkpointBell and scene.checkpointBell.relocate then
        tx.bellDestination = bell
    end
    if scene.checkpointBell then made, why = bindStockBell(tx, gameplay, pawn, scene)
    else made, why = spawnBell(tx, gameplay, pawn, scene, bell) end
    if not made then return nil, why end
    assert(valid(tx.bell.InteractionComp), "门口铃铛交互组件未就绪")
    log(("READY nav=stock slots=%d sealed=%d revive_min_m=%.1f bell=(%.1f,%.1f,%.1f) story_spawn=disabled")
        :format(#scene.spawnPoints, scene.walkIn and (tx.roadReady and #(scene.roadFogs or {}) or 0) or 2, nearest / 100, bell.X, bell.Y, bell.Z))
    return true
end

function Arena.getBell()
    if session and session.ready and live(session.bell, session.world) then return session.bell end
end

function Arena.findBellWidgets(class, now)
    if not session or now < (session.nextMenu or 0) then return end
    session.nextMenu = now + 0.25
    return FindAllOf(class)
end

function Arena.phaseDestination(pawn, system, scene)
    local capsule = pawn.CapsuleComponent
    if not valid(capsule) then return nil, "等待玩家碰撞体" end
    for _, point in ipairs(scene.phaseReturnPoints) do
        local at = grounded(pawn, system, point, 155, 160)
        if at then
            at.Z = at.Z + capsule:GetScaledCapsuleHalfHeight() + 6
            local facing = required(MATH):FindLookAtRotation(at, scene.spawnPoints[1])
            return { position = at, rotation = { Pitch = 0, Yaw = facing.Yaw, Roll = 0 } }
        end
    end
    return nil, "等待" .. scene.name .. "战区回位点"
end

function Arena.update(gameplay, system, pawn, controller, world, now, scene, allowBell)
    if not session or session.scene ~= scene or not valid(session.world) or session.world:GetAddress() ~= world:GetAddress() then
        Arena.reset()
        session = { world = world, scene = scene, nextProbe = 0, nextPlayer = 0, nextFogProbe = 0, nextFogRequest = 0,
            openedDoors = {} }
    end
    local tx = session
    if scene.blockedPortal then Events.updateBlockedPortal(world, pawn, now) end
    local isolated, reason = Events.flushArenaPawns(world, pawn)
    if not isolated then return nil, reason end
    local covered, coverError = WellFloor.ensure(tx, gameplay, pawn)
    if not covered then return nil, coverError end
    if scene.walkIn then
        keepEntryOpen(tx, scene, now)
        local ready, why = RoadFog.update(tx, gameplay, pawn, scene, now)
        if not ready and (scene.requireRoads or not scene.checkpointCreatesBell) then return nil, why end
        -- The temporary bell and the boss can prepare while the fog class streams.
        if not ready and tx.reportedFogWait ~= why then log("FOG waiting=" .. why) end
        tx.reportedFogWait = why
    else
        local sealed, why = seal(tx, scene, now)
        if not sealed then return nil, why end
    end
    if tx.ready and not live(tx.bell, world) then
        if not scene.checkpointBell then tx.ready = nil
        elseif now >= tx.nextProbe and dist2(pawn:K2_GetActorLocation(), scene.anchor) < 2000^2 then
            tx.nextProbe = now + 0.65
            if tx.bellDestination then
                local ok, bound, why = pcall(bindStockBell, tx, gameplay, pawn, scene)
                if not ok or not bound then
                    pcall(dropBell, tx)
                    tx.ready = nil
                    return nil, tostring(ok and why or bound)
                end
            else
                bindStockBell(tx, gameplay, pawn, scene)
            end
        end
    end
    if not tx.ready and now >= tx.nextProbe then
        tx.nextProbe = now + 0.65
        local ok, ready, why = pcall(prepare, tx, gameplay, system, pawn, controller, scene)
        tx.ready = ok and ready
        if not tx.ready then
            pcall(dropBell, tx)
            tx.reason = tostring(ok and why or ready)
            if tx.reason ~= tx.lastWait then log("WAIT " .. tx.reason); tx.lastWait = tx.reason end
        end
    end
    if not tx.ready then return nil, tx.reason or "等待" .. scene.name .. "战区" end
    local sphere = live(tx.bell, world) and tx.bell.InteractionComp
    if not valid(sphere) and not scene.checkpointBell then return nil, "门口铃铛交互组件已卸载" end
    if valid(sphere) and allowBell and scene.arenaOnlyBell
        and (not tx.bell.bActive or not tx.bell.bDisableTeleport or tx.bell.bTeleportOnBrokenBellLeave) then
        configureArenaBell(tx.bell, scene)
    end
    if valid(sphere) and tx.allowBell ~= allowBell then
        tx.bellCollision = tx.bellCollision or sphere:GetCollisionEnabled()
        if tx.bellCollision == 0 then tx.bellCollision = 1 end
        sphere:SetCollisionEnabled(allowBell and tx.bellCollision or 0)
        tx.allowBell = allowBell
    end
    if now >= tx.nextPlayer then
        tx.nextPlayer = now + 1
        local ok, why = pcall(updatePlayer, tx, pawn, controller, scene)
        if not ok then return nil, tostring(why) end
    end
    if scene.traversalInteractionOnly then
        local ok, why = pcall(Events.updateBlockedTraversal, world, pawn)
        if not ok and why ~= tx.traversalError then
            tx.traversalError = why
            log("TRAVERSAL update_error=" .. tostring(why))
        end
    end
    return true
end

function Arena.updateCombat(pawn, active, scene)
    local tx = session
    if not tx or tx.scene ~= scene or not scene.combatFog then return end
    RoadFog.setCombat(tx, active and (tx.combatClosed == true or Arena.inside(pawn, scene)))
end

function Arena.reset()
    local tx = session
    session = nil
    if not tx then return end
    if tx.doors then pcall(setDoors, tx, false) end
    RoadFog.reset(tx)
    WellFloor.reset(tx)
    pcall(dropBell, tx)
end

return Arena
