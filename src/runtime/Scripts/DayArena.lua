-- The daylight arena uses the authored ZhuLinGuWu terrain, not its tutorial.
-- The caller must already own a MOD/save-barrier session before calling update.
local DayArena = {}
local ArenaScenes = require("ArenaScenes")
local SpawnClass = require("SpawnClass")

local DAY_MAP = "PBZ_WP_ZhuLinGuWu"
local BELL_CLASS = "/Game/PBZContent/Blueprint/Item/BP_BrokenBell.BP_BrokenBell_C"
local BELL_ID = "BrokenBell_TheEnd01"
local NO_COLOR = { R = 0, G = 0, B = 0, A = 0 }
local HIDE_INTERACT = { TagName = nil }
local PENDING = 0x08023600
local CONTROLLERS = { "BP_FlowActor_C", "BP_FlowActor_ChapterUI_C", "BP_AISpawner_C", "BP_NPCSpawner_C" }
local DOMAINS = { "BP_PBZAISpawnerTriggerVolume_C", "BP_AISpawnerTriggerVolume_C", "BP_MobDomain_C" }
local STORY_ROOTS = {
    BPF_YuYeZuoShang_Death = true, BPF_play005_1 = true, BPF_DualBlademan_Dead = true,
    BPF_HookMan_Dead = true, BPF_SeqTest = true, BPF_SeqTest_ZuoShang = true,
    BPF_ShaoNianZuoShang_CheckPoint = true, BPF_ZLGW_BattleUI = true, BPF_ShaoNianZuoShang_Idle = true,
}
local worldAddress, pawnAddress, player, bell, teleported, nextScan
local restores, handled, interactionModes = {}, {}, {}
local tagOwned = false
local holding, sceneSnapshot, prepared, candidate, stable, nextProbe, wasDead, lastSafetyLog
local nextDiagnostic, deadTag = 0, nil

local function copy(value)
    local result = {}
    for key, item in pairs(value) do result[key] = item end
    return result
end

local function valid(object)
    return object ~= nil and type(object.IsValid) == "function" and object:IsValid()
end

local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "缺少白天场景原生接口：" .. path)
    return object
end

local function sameWorld(object)
    if not valid(object) then return false end
    local world = object:GetWorld()
    return valid(world) and world:GetAddress() == worldAddress
end

local function protected(actor, keep)
    if not valid(actor) then return true end
    local address = actor:GetAddress()
    return address == pawnAddress or (valid(bell) and address == bell:GetAddress())
        or (keep and keep(actor))
end

local function removeTag()
    if tagOwned and valid(player) then
        local library = required("/Script/ProjectPBZ.Default__PBZAbilityBlueprintLibrary")
        assert(library:RemoveLooseGameplayTag(player, HIDE_INTERACT, false), "无法恢复白天场景交互标签")
    end
    tagOwned = false
end

local function releaseHold()
    local previous = holding
    holding = nil -- Never carry a failed old-world release into a new scope.
    if previous and previous.owned and previous.world == worldAddress and sameWorld(previous.movement)
        and previous.address == previous.movement:GetAddress() then
        previous.movement:StopMovementImmediately()
        previous.movement:SetMovementMode(previous.mode, previous.custom)
    end
end

local function restoreScene()
    if sceneSnapshot then
        local source = sceneSnapshot
        source.scene.anchor, source.scene.reviveLocation, source.scene.bell = source.anchor, source.reviveLocation, source.bell
    end
    sceneSnapshot = nil
end

function DayArena.reset()
    -- Never find/destroy a different world's bell by class or BellID.
    if sameWorld(bell) then pcall(function() bell:K2_DestroyActor() end) end
    pcall(removeTag)
    local released, failure = pcall(releaseHold)
    if not released then print("[PBZTestArenaNative] Daylight movement restore failed: " .. tostring(failure) .. "\n") end
    restoreScene()
    for index = #restores, 1, -1 do pcall(restores[index]) end
    worldAddress, pawnAddress, player, bell, teleported, nextScan = nil, nil, nil, nil, false, 0
    restores, handled, interactionModes, tagOwned = {}, {}, {}, false
    prepared, candidate, stable, nextProbe, wasDead, lastSafetyLog, nextDiagnostic = nil, 1, nil, 0, false, nil, 0
end

local function stopFlow(flow)
    if not valid(flow) then return end
    assert(not flow:HasAnyFlags(PENDING), "等待白天剧情组件完成载入")
    local address = flow:GetAddress()
    if handled[address] then return end
    flow.bAutoStartRootFlow = false
    if valid(flow:GetRootFlowInstance()) then
        assert(valid(flow.RootFlow), "白天剧情根流程尚未就绪")
        flow:FinishRootFlow(flow.RootFlow, 1)
        assert(not valid(flow:GetRootFlowInstance()), "白天剧情根流程尚未关闭")
    end
    flow:PBZUnregister()
    handled[address] = true
end

local function disableShape(shape)
    if not valid(shape) then return end
    assert(not shape:HasAnyFlags(PENDING), "等待白天剧情触发组件完成载入")
    local address = shape:GetAddress()
    if handled[address] then return end
    local enabled = shape:GetCollisionEnabled()
    shape:SetCollisionEnabled(0)
    assert(shape:GetCollisionEnabled() == 0, "白天剧情触发区域尚未关闭")
    restores[#restores + 1] = function()
        if sameWorld(shape) then shape:SetCollisionEnabled(enabled) end
    end
    handled[address] = true
end

local function storyFlow(flow)
    return valid(flow) and valid(flow.RootFlow) and STORY_ROOTS[flow.RootFlow:GetFName():ToString()] == true
end

local function storyShape(shape)
    return valid(shape) and shape:GetCollisionProfileName():ToString() == "Profile_NpcFlowInteract"
end

local function suppressStory(keep)
    -- Components can belong to scenery. Abort/unregister the component without
    -- deleting that owner, so meshes, terrain and collision remain authored.
    for _, flow in ipairs(FindAllOf("BP_PBZFlowComponent_C") or {}) do
        if sameWorld(flow) then
            local owner = flow:GetOwner()
            if sameWorld(owner) and not protected(owner, keep) and storyFlow(flow) then stopFlow(flow) end
        end
    end
    -- Flow-created overlap boxes are not always owned by a BP_FlowActor.
    for _, node in ipairs(FindAllOf("SetExcuteType_C") or {}) do
        if sameWorld(node) and sameWorld(node.ShapeActor) and not protected(node.ShapeActor, keep)
            and storyShape(node.ShapeComponent) then
            disableShape(node.ShapeComponent)
        end
    end
    for _, name in ipairs(DOMAINS) do
        for _, actor in ipairs(FindAllOf(name) or {}) do
            if sameWorld(actor) and not protected(actor, keep) and not handled[actor:GetAddress()] then
                assert(not actor:HasAnyFlags(PENDING), "等待白天剧情区域完成载入")
                local enabled = actor:IsEnabled()
                actor:SetEnabled(false)
                assert(not actor:IsEnabled(), "白天剧情区域关闭失败")
                restores[#restores + 1] = function()
                    if sameWorld(actor) then actor:SetEnabled(enabled) end
                end
                handled[actor:GetAddress()] = true
            end
        end
    end
    for _, actor in ipairs(FindAllOf("TriggerBox") or {}) do
        if sameWorld(actor) and not protected(actor, keep) and storyShape(actor.CollisionComponent) then
            disableShape(actor.CollisionComponent)
        end
    end
    for _, name in ipairs(CONTROLLERS) do
        for _, actor in ipairs(FindAllOf(name) or {}) do
            if sameWorld(actor) and not protected(actor, keep) and not handled[actor:GetAddress()] then
                assert(not actor:HasAnyFlags(PENDING), "等待白天剧情控制器完成载入")
                -- Three authored BPF_PreLoad_* roots actively enable/disable
                -- streaming sources. Unknown/environment roots must survive.
                if name ~= "BP_FlowActor_C" or storyFlow(actor.BP_PBZFlowComponent) then
                    actor:SetActorEnableCollision(false)
                    stopFlow(actor.BP_PBZFlowComponent)
                    if name == "BP_NPCSpawner_C" then actor:Despawn() end
                    actor:K2_DestroyActor()
                    handled[actor:GetAddress()] = true
                end
            end
        end
    end
end

local function diagnostic(message, now)
    if now and now < nextDiagnostic then return end
    if message ~= lastSafetyLog then
        print("[PBZTestArenaNative] Daylight safety: " .. message .. "\n")
        lastSafetyLog = message
    end
    if now then nextDiagnostic = now + 2 end
end

local function unwrap(value)
    if value ~= nil then
        local ok, object = pcall(function() return value:Get() end)
        if ok then return object end
    end
    return value
end

local function blockingFloor(hit)
    -- Do not inspect packed FHitResult bools from a Lua OutStruct table:
    -- pinned UE4SS GetNonTrivialLocal reads their byte without FieldMask.
    -- The trace's native return plus physical body checks are authoritative.
    if not hit.ImpactPoint or not hit.ImpactNormal or hit.ImpactNormal.Z < 0.7 then
        return nil, "no walkable impact normal"
    end
    local component = unwrap(hit.Component)
    if not sameWorld(component) or component:HasAnyFlags(PENDING) then return nil, "hit component unavailable/pending" end
    -- Object queries do not themselves prove that a character capsule blocks
    -- the object. Verify its physical query body and Pawn response explicitly.
    local enabled = component:GetCollisionEnabled()
    if enabled ~= 1 and enabled ~= 3 and enabled ~= 5 then return nil, "hit has no query collision" end
    if component:GetCollisionResponseToChannel(2) ~= 2 then return nil, "hit ignores/overlaps Pawn" end
    if component.Mobility ~= 0 then return nil, "hit is not static terrain/architecture" end
    return hit.ImpactPoint, component
end

local function trace(pawn, x, y, top, bottom)
    local system = required("/Script/Engine.Default__KismetSystemLibrary")
    local hit = {}
    local ignored = valid(bell) and { bell } or {}
    local found = system:LineTraceSingleForObjects(pawn, { X = x, Y = y, Z = top }, { X = x, Y = y, Z = bottom },
        { system:ConvertToObjectType(0) }, false, ignored, 0, hit, true, NO_COLOR, NO_COLOR, 0)
    if not found then return nil, "no WorldStatic physical hit" end
    return blockingFloor(hit)
end

local function support(pawn, location, radius, safety)
    local floor, component = trace(pawn, location.X, location.Y, safety.floorMax + 200, safety.floorMin - 100)
    if not floor then return nil, component end
    if floor.Z < safety.floorMin or floor.Z > safety.floorMax then return nil, "hit outside authored arena height band" end
    -- A single ray can hit a twig, trim, or the corner of an unloaded floor.
    -- Require support over the character's actual capsule footprint.
    for _, offset in ipairs({ { radius, 0 }, { -radius, 0 }, { 0, radius }, { 0, -radius } }) do
        local at, reason = trace(pawn, location.X + offset[1], location.Y + offset[2], safety.floorMax + 200, safety.floorMin - 100)
        if not at then return nil, "footprint " .. tostring(reason) end
        if math.abs(at.Z - floor.Z) > safety.maxSpread then return nil, "uneven/narrow footprint" end
    end
    return { X = location.X, Y = location.Y, Z = floor.Z }, component
end

local function capsuleClear(pawn, at, radius, halfHeight)
    local system = required("/Script/Engine.Default__KismetSystemLibrary")
    local hit = {}
    local endPoint = { X = at.X, Y = at.Y, Z = at.Z + 0.2 }
    local found = system:CapsuleTraceSingleForObjects(pawn, at, endPoint, radius, halfHeight,
        { system:ConvertToObjectType(0) }, false, valid(bell) and { bell } or {}, 0, hit, true, NO_COLOR, NO_COLOR, 0)
    if not found then return true end
    -- Even an overlapping decoration is conservatively unsuitable here: do
    -- not let its first hit hide a different blocking body in the same sweep.
    return false
end

local function beginHold(pawn, scene)
    local movement = pawn.CharacterMovement
    assert(sameWorld(movement), "等待白天角色移动组件")
    if not holding or holding.world ~= worldAddress or holding.address ~= movement:GetAddress() then
        holding = { movement = movement, address = movement:GetAddress(), world = worldAddress,
            mode = movement.MovementMode, custom = movement.CustomMovementMode or 0 }
    end
    -- Preserve an authored MOVE_None, but take ownership if normal movement
    -- starts while streaming is still incomplete. No gravity/input setting is changed.
    if movement.MovementMode ~= 0 then
        if not holding.owned then holding.mode, holding.custom = movement.MovementMode, movement.CustomMovementMode or 0 end
        movement:SetMovementMode(0, 0)
        holding.owned = true
    end
    movement:StopMovementImmediately()
    local point = assert(scene.loadingLocation, "白天安全等待位置缺失")
    local position = pawn:K2_GetActorLocation()
    if math.abs(position.X - point.X) > 10 or math.abs(position.Y - point.Y) > 10 or math.abs(position.Z - point.Z) > 10 then
        local library = required("/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary")
        assert(library:PBZActorTeleportTo(pawn, point, scene.rotation, false, false), "无法固定白天流式加载等待位置")
    end
end

local function publishScene(scene, at, bellAt)
    if not sceneSnapshot then sceneSnapshot = { scene = scene, anchor = scene.anchor, reviveLocation = scene.reviveLocation, bell = scene.bell } end
    scene.anchor, scene.reviveLocation = copy(at), copy(at)
    scene.bell = copy(sceneSnapshot.bell)
    scene.bell.location = copy(bellAt)
    scene.bell.interactionPoint = { X = bellAt.X, Y = bellAt.Y, Z = at.Z }
end

local function createBell(gameplay, pawn, scene, location)
    local class, reason = SpawnClass.resolve(BELL_CLASS)
    if not valid(class) then return nil, reason end
    local mathLibrary = required("/Script/Engine.Default__KismetMathLibrary")
    local spawner = required("/Script/SGameAI.Default__SGameAIFunctionLibrary")
    local at = { X = location.X, Y = location.Y, Z = location.Z + (scene.bell.groundOffset or 0) }
    local transform = mathLibrary:MakeTransform(at, scene.bell.rotation, { X = 1, Y = 1, Z = 1 })
    local deferred = spawner:SpawnActorDeferred(pawn, class, transform, 1)
    if not valid(deferred) then return nil, "等待白天铃铛生成" end
    -- Own it before construction/BeginPlay: cleanup must also cover an error
    -- during native FinishSpawningActor or the initial interaction setup.
    bell = deferred
    local ok, actor = pcall(function()
        deferred.BellID = FName(BELL_ID)
        deferred.bDisableTeleport = true
        deferred.bTeleportOnBrokenBellLeave = false
        -- Pinned UE4SS 1ceefac8 LuaTMap.cpp exports Empty(); this map contains only
        -- GameplayTag/FName values. Empty only this newly spawned instance,
        -- never its shared CDO or the world's global narrative tags.
        local tags = deferred.FlowTagMap
        assert(type(tags) == "userdata" and type(tags.type) == "function" and tags:type() == "TMap"
            and tags:IsValid() and type(tags.Empty) == "function", "缺少铃铛剧情映射的原生容器接口")
        tags:Empty()
        assert(#tags == 0, "白天铃铛剧情映射清理失败")
        -- BP_BrokenBell has no FlowComponent by default. Do not look up an
        -- invented component/property or start an authored flow for this bell.
        local finished = gameplay:FinishSpawningActor(deferred, transform, 1)
        assert(valid(finished) and finished:GetAddress() == deferred:GetAddress(), "白天铃铛初始化失败")
        assert(sameWorld(finished), "白天铃铛生成到了其他世界")
        assert(finished.BellID:ToString() == BELL_ID and finished.bDisableTeleport
            and not finished.bTeleportOnBrokenBellLeave and #finished.FlowTagMap == 0,
            "白天铃铛初始化后设置回读失败")
        return finished
    end)
    if not ok then
        if sameWorld(deferred) then pcall(function() deferred:K2_DestroyActor() end) end
        bell = nil
        error(actor)
    end
    bell = actor
    print("[PBZTestArenaNative] Daylight native bell ready: " .. BELL_ID .. "\n")
    return true
end

local function setInteraction(pawn, allowed)
    local sphere = bell.InteractionComp
    assert(valid(sphere), "等待白天铃铛交互组件")
    if interactionModes.sphere ~= sphere:GetAddress() then
        interactionModes = { sphere = sphere:GetAddress(), collision = sphere:GetCollisionEnabled() }
    end
    sphere:SetCollisionEnabled(allowed and interactionModes.collision or 0)
    if allowed then
        removeTag()
    else
        local abilities = required("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
        local asc = abilities:GetAbilitySystemComponent(pawn)
        assert(valid(asc), "等待白天训练角色能力组件")
        if asc:GetGameplayTagCount(HIDE_INTERACT) == 0 then
            local library = required("/Script/ProjectPBZ.Default__PBZAbilityBlueprintLibrary")
            assert(library:AddLooseGameplayTag(pawn, HIDE_INTERACT, false), "无法关闭白天训练场交互")
            tagOwned = true
        end
        assert(asc:GetGameplayTagCount(HIDE_INTERACT) > 0 and sphere:GetCollisionEnabled() == 0,
            "白天训练场交互限制回读失败")
    end
end

local function deadState(pawn)
    local asc = pawn.AbilitySystemComponent
    if valid(asc) and asc:GetGameplayTagCount(deadTag) > 0 then return true end
    local attrs = pawn.AttributeSetBase
    if valid(attrs) then
        local hp = attrs.Health.CurrentValue
        if type(hp) == "number" and hp > -math.huge and hp < math.huge then return hp <= 0 end
    end
end

local function prepareSpawn(pawn, scene, now)
    if now < nextProbe then return nil, "等待白天承重地面连续确认" end
    local safety = scene.spawnSafety
    nextProbe = now + safety.probeInterval
    local capsule = pawn.CapsuleComponent
    assert(sameWorld(capsule), "等待白天角色胶囊体")
    local radius, halfHeight = capsule:GetScaledCapsuleRadius(), capsule:GetScaledCapsuleHalfHeight()
    assert(radius > 0 and halfHeight >= radius, "白天角色胶囊尺寸无效")
    local origin = sceneSnapshot and sceneSnapshot.anchor or scene.anchor
    local originalBell = sceneSnapshot and sceneSnapshot.bell or scene.bell
    local point = safety.candidates[candidate]
    local floor, component = support(pawn, point, radius * 0.85, safety)
    local bellPoint = { X = point.X + originalBell.location.X - origin.X,
        Y = point.Y + originalBell.location.Y - origin.Y }
    local bellFloor, bellReason
    if floor then bellFloor, bellReason = support(pawn, bellPoint, 38, safety) end
    local reason
    if not floor then reason = component
    elseif not bellFloor then reason = "bell " .. tostring(bellReason)
    elseif math.abs(bellFloor.Z - floor.Z) > 100 then reason = "bell/player support layers differ"
    else
        local at = { X = point.X, Y = point.Y, Z = floor.Z + halfHeight + 6 }
        if not capsuleClear(pawn, at, radius, halfHeight) then reason = "capsule overlaps solid architecture"
        else
            if not stable or stable.index ~= candidate or stable.body ~= component:GetAddress()
                or math.abs(stable.z - floor.Z) > 1 or math.abs(stable.bellZ - bellFloor.Z) > 1 then
                stable = { index = candidate, z = floor.Z, bellZ = bellFloor.Z,
                    body = component:GetAddress(), count = 0, since = now }
            end
            stable.count = stable.count + 1
            if stable.count < safety.stableSamples or now - stable.since < safety.stableSeconds then
                return nil, "等待白天承重地面连续确认"
            end
            return { at = at, floor = floor, bell = bellFloor, component = component }
        end
    end
    stable = nil
    diagnostic(("candidate=%d x=%.2f y=%.2f probeZ=%.2f..%.2f; %s"):format(
        candidate, point.X, point.Y, safety.floorMin, safety.floorMax, tostring(reason)), now)
    candidate = candidate % #safety.candidates + 1
    return nil, "等待白天训练场物理地面：" .. tostring(reason)
end

local function restartPreparation(reason)
    if sameWorld(bell) then bell:K2_DestroyActor() end
    bell, prepared, teleported, stable, candidate, nextProbe = nil, nil, false, nil, 1, 0
    interactionModes = {}
    diagnostic(reason)
end

local function update(gameplay, pawn, controller, now, config, keep, allowBell)
    local scene = config or ArenaScenes.get("day")
    assert(scene and scene.map == DAY_MAP and scene.anchor and scene.bell and scene.bell.location
        and scene.bell.rotation and scene.loadingLocation and scene.spawnSafety, "白天场地配置不完整")
    if not valid(pawn) or not valid(controller) then return nil, "等待白天场景角色" end
    local level = gameplay:GetCurrentLevelName(pawn, true)
    if type(level) ~= "string" then level = level:ToString() end
    if level ~= DAY_MAP then
        if worldAddress then DayArena.reset() end
        return nil, "等待读入白天故屋场景"
    end
    local world = pawn:GetWorld()
    if not valid(world) then return nil, "等待白天场景世界" end
    if worldAddress ~= world:GetAddress() or pawnAddress ~= pawn:GetAddress() then
        DayArena.reset()
        worldAddress, pawnAddress, player = world:GetAddress(), pawn:GetAddress(), pawn
        HIDE_INTERACT.TagName = FName("Flow.HideInteract")
        deadTag = { TagName = FName("CharacterState.Dead") }
    end
    if not sameWorld(controller) then return nil, "等待白天场景控制器" end
    local dead = deadState(pawn)
    if dead then
        wasDead = true
        releaseHold()
        -- A running encounter must still observe its normal death/failure
        -- state; only initial, never-ready loading remains gated.
        return teleported and true or nil, "等待白天角色原生复活"
    elseif wasDead then
        if dead == nil then return nil, "等待白天复活角色生命状态" end
        wasDead = false
        restartPreparation("same pawn revived; reacquiring physical support")
    end
    if teleported then
        local position = pawn:K2_GetActorLocation()
        local loading = scene.loadingLocation
        if math.abs(position.X - loading.X) < 100 and math.abs(position.Y - loading.Y) < 100
            and math.abs(position.Z - loading.Z) < 150 then
            restartPreparation("same pawn returned to loading transform")
        elseif prepared and position.Z < prepared.floor.Z - scene.spawnSafety.recoveryDepth then
            local capsule = pawn.CapsuleComponent
            local feet = position.Z - capsule:GetScaledCapsuleHalfHeight()
            local below = trace(pawn, position.X, position.Y, feet + 40, feet - 250)
            if not below then restartPreparation("pawn below verified floor with no local physical support") end
        end
    end
    -- Freeze before any story cleanup or physical query can fail/await a cell.
    -- The holding point keeps the normal player streaming source near the arena.
    if not teleported then beginHold(pawn, scene) end
    if now >= nextScan then
        suppressStory(keep)
        nextScan = now + 0.5
    end
    if not teleported then
        local confirmed, reason = prepareSpawn(pawn, scene, now)
        if not confirmed then return nil, reason end
        prepared = confirmed
        if not valid(bell) then
            local made, failure = createBell(gameplay, pawn, scene, confirmed.bell)
            if not made then return nil, failure end
        end
        local library = required("/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary")
        if not library:PBZActorTeleportTo(pawn, confirmed.at, scene.rotation, false, false) then
            return nil, "无法定位白天训练场角色"
        end
        publishScene(scene, confirmed.at, confirmed.bell)
        controller:SetControlRotation(scene.camera)
        teleported = true
        releaseHold()
        diagnostic(("ready x=%.2f y=%.2f groundZ=%.2f capsuleZ=%.2f; %s"):format(
            confirmed.at.X, confirmed.at.Y, confirmed.floor.Z, confirmed.at.Z, confirmed.component:GetFullName()))
    end
    if not valid(bell) then
        local ok, reason = createBell(gameplay, pawn, scene, prepared.bell)
        if not ok then return nil, reason end
    end
    setInteraction(pawn, allowBell == true)
    return true
end

function DayArena.update(...)
    local ok, ready, reason = pcall(update, ...)
    if not ok then return nil, "白天场地准备失败：" .. tostring(ready) end
    return ready, reason
end

function DayArena.owns(actor)
    return sameWorld(actor) and valid(bell) and actor:GetAddress() == bell:GetAddress()
end

function DayArena.getBell()
    if sameWorld(bell) then return bell end
end

return DayArena
