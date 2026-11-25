-- Mount no replacement map. Limit these hooks to the arena's own stock-map travel.
local Guard = { map = "PBZ_Pangzhen_WP", path = "/Game/Maps/B08_09_10/PBZ_Pangzhen_WP" }
local Items = require("ArenaItems")
local clock = os.clock
local FLOW = "/Script/ProjectPBZ.PBZFlowComponent:"
local SYSTEM = "/Script/Engine.Default__KismetSystemLibrary"
local PERFORMANCE_FLAG = "-PBZArenaPerf"
local PENDING = 0x08023600
local STORY_CLASSES = {
    BP_AISpawner_C = "spawner", BP_NPCSpawner_C = "spawner",
    BP_AICombatTriggerVolume_C = "trigger", BP_AISpawnerTriggerVolume_C = "trigger",
    BP_PBZAISpawnerTriggerVolume_C = "trigger", BP_TeleportTrigger_C = "trigger",
    TriggerVolume = "trigger", TriggerBox = "trigger", TriggerSphere = "trigger", TriggerCapsule = "trigger",
    BP_MobDomain_C = "domain", PBZ_MobDomain_C = "domain",
    BP_Teleport_C = "portal",
    BP_FlowActor_C = "story", BP_FlowActor_Wharf_C = "story", BP_FlowInteractActor_C = "story",
    BP_FlowInteractActor_DragonPillar_C = "story", BP_FlowInteractActor_Male_ScareCrow1_C = "story",
}
local LION_CINEMATIC_CLASSES = { BP_Seq_LionDancer_C = true, BP_Seq_LionDancer_Table_C = true }
local session, installed

local function log(line) print("[PBZMeiGuHuOriginal] " .. line .. "\n") end
local function valid(v)
    local kind = type(v)
    return (kind == "table" or kind == "userdata") and type(v.IsValid) == "function" and v:IsValid()
end
local function unwrap(v)
    if valid(v) then return v end
    if v == nil then return end
    local ok, value = pcall(function() return v:get() end)
    if ok and valid(value) then return value end
end
local function name(v) return type(v) == "string" and v or (v and v:ToString() or "") end
local function count(tx, which) tx.counts[which] = (tx.counts[which] or 0) + 1 end

function Guard.performanceRequested(system)
    local ok, command = pcall(function()
        local reader = system or StaticFindObject(SYSTEM)
        return name(reader:GetCommandLine())
    end)
    if not ok or type(command) ~= "string" then return false end
    -- Read complete arguments so flags inside quoted values cannot enable sampling.
    local word, quoted, slashes = {}, false, 0
    for char in command:gmatch(".") do
        if char == '"' and slashes % 2 == 0 then quoted = not quoted
        elseif not quoted and char:match("%s") then
            if table.concat(word) == PERFORMANCE_FLAG then return true end
            word = {}
        else word[#word + 1] = char end
        slashes = char == "\\" and slashes + 1 or 0
    end
    return not quoted and table.concat(word) == PERFORMANCE_FLAG
end

function Guard.isSampling()
    return session ~= nil and session.timing ~= nil
end

local function stockWorld(tx, world)
    return valid(world) and world:GetFullName():sub(-#tx.worldName) == tx.worldName
end

local function inState(tx, actor, allowRuntime)
    if not valid(actor) or actor:HasAnyFlags(PENDING) then return false end
    if not allowRuntime then
        local identity = name(actor:GetFName())
        if not identity:find("_UAID_", 1, true) and not (tx.watch and tx.watch[identity]) then return false end
    end
    local level = actor:GetLevel()
    local world = valid(level) and level.OwningWorld
    if not valid(world) then return false end
    local address = world:GetAddress()
    if tx.previousWorld == address then return false end
    -- Streamed actors can reside in temporary packages. Match their live
    -- OwningWorld instead of the streamed level's Outer/package path.
    if tx.world then return tx.world == address end
    if not stockWorld(tx, world) then return false end
    tx.world = address
    return true
end

local function fail(tx, step, why)
    if tx.errors[step] then return end
    tx.errors[step] = true
    count(tx, "errors")
    log("ERROR " .. step .. " " .. tostring(why))
end

local function disableFlow(tx, flow, finish)
    if not valid(flow) or flow:HasAnyFlags(PENDING) then return end
    flow.bAutoStartRootFlow = false
    if finish and valid(flow:GetRootFlowInstance()) and valid(flow.RootFlow) then
        flow:FinishRootFlow(flow.RootFlow, 1)
        count(tx, "root_finished")
    end
    if finish then flow:PBZUnregister() end
end

local function disableActorFlow(tx, actor, after)
    local mask = tx.pointMask
    if mask and mask.componentsOnly then
        for _, component in ipairs(actor:K2_GetComponentsByClass(mask.flow) or {}) do
            disableFlow(tx, unwrap(component), after)
        end
    else
        disableFlow(tx, unwrap(actor.BP_PBZFlowComponent), after)
    end
end

local function disableOverlap(component)
    local trigger = unwrap(component)
    if not trigger then return end
    trigger:SetGenerateOverlapEvents(false)
    trigger:SetCollisionEnabled(0)
end

local function classify(actor, tx)
    local class = actor:GetClass()
    local address = class:GetAddress()
    local entry = tx.classes[address]
    if entry ~= nil then return entry end
    local short = name(class:GetFName())
    -- Items only use native actor flags here. Blueprint interaction fields
    -- can be unresolved during BeginPlay.
    if Items.classCategory(class, short) then
        entry = { item = true }
        tx.classes[address] = entry
        return entry
    end
    local kind = STORY_CLASSES[short]
    if not kind and short:find("^BP_Flow") then kind = "story" end
    if tx.pawns and not kind then
        if short:find("NPCSpawner", 1, true) then
            kind = "spawner"
        elseif short == "BP_FogDoor_C" or short == "BP_FogDoorTotalBlock_C" then
            kind = "geometry"
        elseif class:IsChildOf(tx.pawnClass) and not short:find("Player", 1, true) then
            kind = "authored_pawn"
            local base = class
            while valid(base) do
                local className = name(base:GetFName())
                if className:find("^BP_NPC_") or className:find("^PBZNPCCharacter") then
                    kind = "npc"
                    break
                end
                base = base:GetSuperStruct()
            end
        end
    end
    if not kind and (short:find("^BP_MelodiousBell") or tx.pointMask and short:find("^BP_BrokenBell")) then kind = "bell" end
    local point = tx.pointMask and tx.pointMask:describe(actor, class, short, kind, tx.blockWharf)
    entry = (kind or point or tx.itemStoryClasses[short])
        and { kind = kind, aiSpawner = short == "BP_AISpawner_C", point = point, className = short } or false
    tx.classes[address] = entry
    return entry
end

local function retained(tx, actor)
    if not tx.retained or not valid(actor) then return false end
    local identity = tx.retained[actor:GetAddress()]
    return identity ~= nil and identity == name(actor:GetFName())
end

-- Mark the actual deferred actor before its synchronous BeginPlay. Combat
-- classes such as PengMeng inherit BP_NPC_Base just like story residents.
function Guard.allowArenaPawn(actor)
    local tx = session
    if not tx or not tx.retained then return end
    assert(inState(tx, actor, true), "演武单位不在受保护的战区")
    local address = actor:GetAddress()
    tx.retained[address] = name(actor:GetFName())
    tx.pawns[address] = nil
    count(tx, "arena_pawn_allowed")
    log("ARENA_PAWN allowed=" .. tx.retained[address])
end

function Guard.ownsArenaPawn(actor)
    local tx = session
    return tx and retained(tx, actor) and inState(tx, actor, true) or false
end

local function arenaHorse(tx, horse)
    local spawner = unwrap(horse:GetAISpawner())
    if not spawner then return false end
    -- The rider stores VehicleSpawner before the native Spawn call. Its spawned
    -- horse has that source from the deferred AI spawn, even during BeginPlay.
    for _, value in ipairs(FindAllOf("AIScript_Rider_C") or {}) do
        local script = unwrap(value)
        if script then
            local source = unwrap(script.VehicleSpawner)
            local rider = unwrap(script.Pawn)
            if source and source:GetAddress() == spawner:GetAddress() and retained(tx, rider)
                and inState(tx, rider, true) then return true end
        end
    end
    return false
end

local function nativeSquadSummon(tx, actor, className)
    local squad = tx.squadSpawners
    if not squad or not squad.summons[className] then return false end
    local spawner = unwrap(actor:GetAISpawner())
    local slot = spawner and squad.sources[spawner:GetAddress()]
    return slot and slot.dormant and not slot.released and slot.id .. "_C" == className
end

local function mutePortal(actor, after)
    -- The curtain and its physical Box belong to a separate BP_MagicDoor actor.
    local sphere = unwrap(actor.InteractSphere)
    disableOverlap(sphere)
    if after then
        local widget = unwrap(actor.Widget)
        if widget then
            widget:Deactivate()
            widget:SetComponentTickEnabled(false)
            widget:SetVisibility(false, true)
        end
    end
    return sphere and sphere:GetCollisionEnabled() == 0
end

local function isBlockedPortal(tx, actor)
    return tx.blockedPortal and valid(actor) and name(actor:GetFName()) == tx.blockedPortal
        and name(actor:GetClass():GetFName()) == "BP_FlowInteractActor_C" and inState(tx, actor)
end

local function muteObstacleActor(actor)
    actor:SetActorEnableCollision(false)
    actor:SetActorHiddenInGame(true)
    actor:SetActorTickEnabled(false)
end

local function ownRoadblocker(actor, tx)
    local obstacle = unwrap(actor.Obstacle)
    local child = obstacle and unwrap(obstacle.ChildActor)
    if child and inState(tx, child, true) and not child:IsActorBeingDestroyed()
        and name(child:GetClass():GetFName()) == tx.entryBlocker.childClass then return child end
end

local function applyEntryBlocker(tx, actor)
    local child = ownRoadblocker(actor, tx)
    local first = tx.entryBlockerMuted ~= actor:GetAddress()
    if first or actor:GetActorEnableCollision() or actor.bHidden ~= true then muteObstacleActor(actor) end
    if not child then return end
    local address = child:GetAddress()
    if first or address ~= tx.entryBlockerChild or child:GetActorEnableCollision() or child.bHidden ~= true then
        muteObstacleActor(child)
        assert(not actor:GetActorEnableCollision() and not child:GetActorEnableCollision(), "入场锁链碰撞仍启用")
        log("ENTRY_BLOCKER hidden_and_collision_disabled=" .. tx.entryBlocker.name .. " child=" .. name(child:GetFName()))
    end
    tx.entryBlockerMuted, tx.entryBlockerChild = actor:GetAddress(), address
end

local function muteEntryBlocker(actor, tx, after)
    local spec = tx.entryBlocker
    if not spec or name(actor:GetFName()) ~= spec.name or not inState(tx, actor)
        or name(actor:GetClass():GetFName()) ~= spec.class then return false end
    muteObstacleActor(actor)
    if after then
        tx.entryBlockerActor = actor
        disableActorFlow(tx, actor, true)
        disableOverlap(actor.HitBox)
        disableOverlap(actor.TriggerBox)
        applyEntryBlocker(tx, actor)
    end
    return true
end

local function refreshEntryBlocker(tx, now)
    local actor = tx.entryBlockerActor
    if not actor or now < (tx.entryBlockerNextProbe or 0) then return end
    tx.entryBlockerNextProbe = now + 0.75
    if inState(tx, actor) and not actor:IsActorBeingDestroyed() then
        local ok, why = pcall(applyEntryBlocker, tx, actor)
        if not ok then fail(tx, "entry_blocker", why) end
    end
end

local function muteTraversalInteraction(tx, actor, spec, after)
    local muted = {}
    for _, value in ipairs(actor:K2_GetComponentsByClass(tx.pointMask.shape) or {}) do
        local shape = unwrap(value)
        local component = shape and name(shape:GetFName())
        if component and spec.components[component] then
            disableOverlap(shape)
            muted[component] = true
        end
    end
    if not after then return end
    for component in pairs(spec.components) do
        assert(muted[component], "铁链互动组件缺失 " .. component)
    end
    for _, value in ipairs(actor:K2_GetComponentsByClass(tx.pointMask.widget) or {}) do
        local widget = unwrap(value)
        if widget then
            widget:Deactivate()
            widget:SetVisibility(false, true)
            widget:SetComponentTickEnabled(false)
        end
    end
    log("TRAVERSAL interaction disabled=" .. name(actor:GetFName()))
end

local function filterActor(actor, tx, after)
    if not valid(actor) then return end
    local traversal = tx.interactiveTraversal
    if traversal and name(actor:GetFName()) == traversal.name
        and name(actor:GetClass():GetFName()) == traversal.className and inState(tx, actor) then
        if after then log("TRAVERSAL retained=" .. traversal.name) end
        return
    end
    if muteEntryBlocker(actor, tx, after) then return end
    if isBlockedPortal(tx, actor) then
        if after then tx.portal = actor end
        mutePortal(actor, after)
        disableActorFlow(tx, actor, after)
        return
    end
    if tx.blockedTraversal then
        local key = name(actor:GetFName())
        local blocked = tx.blockedTraversal[key]
        if type(blocked) == "table" and name(actor:GetClass():GetFName()) == blocked.className and inState(tx, actor) then
            muteTraversalInteraction(tx, actor, blocked, after)
            return
        elseif blocked == true and inState(tx, actor) then
            if tx.traversal then
                if after then tx.traversal.pending[actor:GetAddress()] = actor end
                return
            end
            actor:SetActorEnableCollision(false)
            actor:SetActorTickEnabled(false)
            if not tx.traversalWidgetClass then actor:SetActorHiddenInGame(true) end
            if after then
                -- Also disable dedicated trigger shapes configured during BeginPlay.
                for _, shape in ipairs(actor:K2_GetComponentsByClass(tx.pointMask.shape) or {}) do
                    disableOverlap(shape)
                end
                if tx.traversalWidgetClass then
                    for _, value in ipairs(actor:K2_GetComponentsByClass(tx.traversalWidgetClass) or {}) do
                        local widget = unwrap(value)
                        if widget then
                            widget:SetVisibility(false, true)
                            widget:SetHiddenInGame(true, true)
                            widget:SetComponentTickEnabled(false)
                        end
                    end
                end
                log("TRAVERSAL disabled=" .. key)
            end
            return
        end
    end
    local entry
    if tx.blockedWharf and name(actor:GetFName()) == tx.blockedWharf
        and name(actor:GetClass():GetFName()) == "BP_Wharf_C" then
        -- This instance has a separate boarding trigger and dock collision.
        entry = { point = { wharf = true }, className = "BP_Wharf_C" }
    else
        entry = classify(actor, tx)
    end
    if not entry then return end
    if entry.item or (tx.itemStoryClasses[entry.className] and Items.isStoryProp(actor, entry.className, tx.scene)) then
        -- Run after native initialization and before the streamed actor is usable.
        -- The arena update owns interaction-cache removal and destruction.
        if after and tx.policy == "blocked" and tx.scene and not tx.pendingTravel
            and inState(tx, actor, true) and Items.suppress(actor) then
            count(tx, tx.arrived and "items_masked_streaming" or "items_masked_loading")
        end
        return
    end
    local kind = entry.kind
    if not kind and not entry.point then return end
    if not inState(tx, actor, entry.point or kind == "npc") then return end
    if kind == "geometry" then
        local key = name(actor:GetFName())
        if after and tx.watch and tx.watch[key] then tx.actors[key] = actor end
        return
    end
    if kind == "npc" or kind == "authored_pawn" then
        if retained(tx, actor) or actor:IsPlayerControlled() then return end
        if (entry.className == "BP_Monster_Horse_JingYe_C" and arenaHorse(tx, actor))
            or nativeSquadSummon(tx, actor, entry.className) then
            Guard.allowArenaPawn(actor)
            return
        end
        disableActorFlow(tx, actor, after)
        actor:SetActorHiddenInGame(true)
        actor:SetActorEnableCollision(false)
        actor:SetActorTickEnabled(false)
        local address = actor:GetAddress()
        -- Release the preparation gate after these two streaming actors are inert.
        if after and tx.muteLionCinematics and LION_CINEMATIC_CLASSES[entry.className]
            and actor.bHidden == true and not actor:GetActorEnableCollision() and not actor:IsActorTickEnabled() then
            tx.pawns[address] = nil
            count(tx, "cinematic_pawns_muted")
            log("CINEMATIC_MUTED actor=" .. name(actor:GetFName()))
        else
            tx.pawns[address] = actor
        end
        return
    end
    if kind == "bell" and (tx.retiredBell or tx.retiredBells) then
        local key = name(actor:GetFName())
        local removed = tx.retiredBells and tx.retiredBells[key]
        if removed or key == tx.retiredBell then
            actor:SetActorHiddenInGame(true)
            actor:SetActorEnableCollision(false)
            actor:SetActorTickEnabled(false)
            if after then
                if removed then
                    disableOverlap(actor.InteractionComp)
                    log("STOCK_BELL_RETIRED actor=" .. key)
                else
                    log("BELL removed=" .. key)
                end
            end
        end
    end
    local actorName = (tx.arenaBell and (kind == "bell" or entry.point and entry.point.bell)
        or tx.watch and kind) and name(actor:GetFName())
    local arenaBell = (tx.ownedBell and kind == "bell" and actor:GetAddress() == tx.ownedBell
            and name(actor.BellID) == tx.bellId)
        or (actorName and tx.arenaBell and actorName == tx.arenaBell.name
            and (not after or name(actor.BellID) == tx.arenaBell.id))
    if not after and kind then count(tx, kind .. "_pre") end
    disableActorFlow(tx, actor, after)
    local componentPoints = entry.point and tx.pointMask.componentsOnly
    if entry.point and not arenaBell then
        local disabled, regions = tx.pointMask:apply(actor, entry.point, after)
        if after then
            if entry.point.wharf and disabled then count(tx, "wharf_interactions_disabled") end
            if disabled or kind == "story" or kind == "spawner" then
                count(tx, "interactions_disabled")
            else
                count(tx, "interaction_unresolved_" .. entry.className)
            end
            tx.counts.interact_regions_disabled = tx.counts.interact_regions_disabled + regions
        end
        if not kind then
            if after and tx.watch then
                local key = name(actor:GetFName())
                if tx.watch[key] then tx.actors[key] = actor end
            end
            return
        end
    end
    if kind == "bell" or arenaBell then
        if componentPoints and not arenaBell then return end
        if arenaBell and tx.arenaBell and tx.arenaBell.ignoreActivationTags and not after then
            local activation = actor.ActiveTags
            if activation then
                if activation.GameplayTags then activation.GameplayTags:Empty() end
                if activation.ParentTags then activation.ParentTags:Empty() end
            end
        end
        actor.bDisableTeleport = true
        actor.bTeleportOnBrokenBellLeave = false
        local tags = actor.FlowTagMap
        if tags and type(tags.IsValid) == "function" and tags:IsValid() then tags:Empty() end
        if not entry.point and not arenaBell and name(actor.BellID) ~= tx.bellId then
            disableOverlap(actor.InteractionComp)
        end
        if arenaBell and after then
            tx.bell = actor
            count(tx, "arena_bell_allowed")
        end
        return
    end
    if kind == "domain" then
        if after then actor:SetEnabled(false) end
        actor:SetActorEnableCollision(false)
    elseif kind == "portal" then
        -- Retain the portal's physical mesh. Only its teleport overlap is disabled.
        if not componentPoints then disableOverlap(actor.OverlapTriggerbox) end
    else
        actor:SetActorEnableCollision(false)
    end
    actor:SetActorTickEnabled(false)
    if kind == "spawner" then
        if entry.aiSpawner then actor.ShouldSpawn = false end
        if after then
            local original = entry.aiSpawner and unwrap(actor:GetPawn())
            actor:Despawn()
            if valid(original) and not original:IsActorBeingDestroyed()
                and not original:HasAnyFlags(PENDING) then original:K2_DestroyActor() end
            count(tx, "spawn_cancelled")
            if entry.aiSpawner and name(actor.SpawnerID) == "YanQianSui" then count(tx, "yanqiansui_spawn_cancelled") end
        end
    end
    if after and tx.watch and tx.watch[actorName] then tx.actors[actorName] = actor end
end

local function actorHook(parameter, after)
    local tx = session
    if not tx then return end
    local timing = tx.timing
    local began = timing and clock()
    local ok, why = pcall(filterActor, unwrap(parameter), tx, after)
    if not ok then fail(tx, after and "actor_post" or "actor_pre", why) end
    if timing then timing:record(after and "actor_post" or "actor_pre", began) end
end

local function withFlow(context, kind, action)
    local tx = session
    if not tx then return end
    local timing = tx.timing
    local began = timing and clock()
    local ok, result = pcall(function()
        local flow = unwrap(context)
        if not flow or flow:HasAnyFlags(PENDING) then return end
        local owner = flow:GetOwner()
        if not inState(tx, owner) or retained(tx, owner) then return end
        return action(tx, flow)
    end)
    if timing then timing:record(kind, began) end
    if not ok then fail(tx, "flow_hook", result); return end
    return result
end

local function registerHooks()
    if installed then return end
    assert(type(RegisterBeginPlayPreHook) == "function" and type(RegisterBeginPlayPostHook) == "function",
        "UE4SS missing BeginPlay hooks")
    local hooks = {}
    local ok, why = pcall(function()
        hooks[1] = { FLOW .. "ShouldStartAfterLoad" }
        hooks[1][2], hooks[1][3] = RegisterHook(hooks[1][1], function() end, function(context)
            return withFlow(context, "flow_check", function(tx, flow)
                disableFlow(tx, flow, false)
                count(tx, "start_denied")
                return false
            end)
        end)
        hooks[2] = { FLOW .. "PBZRegister" }
        hooks[2][2], hooks[2][3] = RegisterHook(hooks[2][1], function(context)
            withFlow(context, "flow_register", function(tx, flow) disableFlow(tx, flow, false) end)
        end, function(context)
            withFlow(context, "flow_register", function(tx, flow)
                disableFlow(tx, flow, true)
                count(tx, "registration_removed")
            end)
        end)
        RegisterBeginPlayPreHook(function(actor) actorHook(actor, false) end)
        RegisterBeginPlayPostHook(function(actor) actorHook(actor, true) end)
    end)
    if not ok then
        for _, hook in ipairs(hooks) do
            if hook[2] and hook[3] then pcall(UnregisterHook, hook[1], hook[2], hook[3]) end
        end
        error(why, 0)
    end
    installed = true
end

function Guard.arm(context, policy, arenaBell, scene)
    if policy ~= "stock" then
        local installedOk, why = pcall(registerHooks)
        if not installedOk then log("ERROR hook_setup " .. tostring(why)); error(why, 0) end
    end
    local before = require("SceneArena").runtimeWorld(context)
    Guard.reset()
    local pointMask = policy == "blocked" and require("MeiGuHuPointMask").new(scene and scene.componentPointMask) or nil
    local counts = pointMask and { interactions_disabled = 0, interact_regions_disabled = 0 } or {}
    local blockWharf = pointMask and scene and scene.id == "meiguhu"
    local blockedWharf = pointMask and scene and scene.blockedWharf
    if blockWharf or blockedWharf then counts.wharf_interactions_disabled = 0 end
    local map, path = scene and scene.map or Guard.map, scene and scene.originalPath or Guard.path
    local timing
    if Guard.performanceRequested() then
        local ok, sampler = pcall(function() return require("MeiGuHuEventTiming").new(log) end)
        if ok then timing = sampler else log("TIMING_ERROR " .. tostring(sampler)) end
    end
    local pawns, pawnClass, retainedPawns
    if scene and scene.runtimeModule == "XiguBossArena" then
        pawns, pawnClass, retainedPawns = {}, StaticFindObject("/Script/Engine.Pawn"), {}
        assert(valid(pawnClass), "缺少试场 NPC 隔离接口")
    end
    local traversalWidgetClass
    if scene and scene.preserveTraversalMeshes then
        traversalWidgetClass = unwrap(StaticFindObject("/Script/UMG.WidgetComponent"))
    end
    session = { previousWorld = valid(before) and before:GetAddress() or nil, pendingTravel = true,
        pawns = pawns, pawnClass = pawnClass, retained = retainedPawns, retiredBell = scene and scene.retiredBell,
        muteLionCinematics = scene and map == "PBZ_Houjie_WP" and scene.id:match("^pangzhen_") ~= nil,
        blockedTraversal = scene and scene.blockedTraversal, traversalWidgetClass = traversalWidgetClass,
        blockedWharf = blockedWharf,
        entryBlocker = scene and scene.entryBlocker, retiredBells = scene and scene.retiredBells,
        interactiveTraversal = scene and scene.interactiveTraversal, scene = scene,
        blockedPortal = scene and scene.blockedPortal,
        itemStoryClasses = Items.storyPropClasses(scene),
        traversal = scene and scene.traversalInteractionOnly
            and { pending = {}, denied = {}, inputLogged = {} },
        counts = counts, errors = {}, classes = {}, timing = timing, pointMask = pointMask, blockWharf = blockWharf,
        policy = policy, arenaBell = arenaBell, bellId = scene and scene.bellSaveId or "Bell_MGH_004",
        worldName = path .. "." .. map, watch = scene and scene.checkpointActors, actors = {},
        canCreateBell = scene and scene.checkpointCreatesBell }
    log("TRAVEL map=" .. path .. " stock_geometry=1 stock_streaming=1"
        .. (policy and " policy=" .. policy or ""))
end

function Guard.arrive(world)
    local tx = session
    if not tx or not stockWorld(tx, world) or world:GetAddress() == tx.previousWorld or tx.world and world:GetAddress() ~= tx.world then
        return nil, "原图事件隔离未绑定当前演武世界"
    end
    tx.world = world:GetAddress()
    tx.pendingTravel = false
    if tx.counts.errors and not tx.policy then return nil, "梅谷乐坊原图事件隔离报错，请导出日志" end
    if not tx.arrived and tx.policy == "blocked" and tx.scene then
        print(("[PBZArenaItems] scene=%s masked_during_load=%d\n")
            :format(tx.scene.id, tx.counts.items_masked_loading or 0))
    end
    tx.arrived = true
    return true
end

local function summary(tx, label, extra)
    local keys, fields = {}, {}
    for key in pairs(tx.counts) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do fields[#fields + 1] = key .. "=" .. tx.counts[key] end
    log(label .. " " .. (extra or "") .. " " .. table.concat(fields, " "))
end

function Guard.ready()
    local tx = session
    if not tx then return end
    tx.counts.yanqiansui_spawn_cancelled = tx.counts.yanqiansui_spawn_cancelled or 0
    local source = tx.policy and "source=native_checkpoint policy=" .. tx.policy or "nav=full"
    summary(tx, "READY", source .. " bell=" .. tx.bellId)
    if tx.timing then tx.timing:mark("arena_ready") end
    tx.nextReport = nil
end

function Guard.actor(id)
    local tx = session
    local actor = tx and (id and tx.actors[id] or not id and tx.bell)
    if valid(actor) and not actor:HasAnyFlags(PENDING) and not actor:IsActorBeingDestroyed() then return actor end
end

-- World Partition can activate a cell before its actors are observed by the
-- BeginPlay post hook. Reconcile only the profiled spawners in the live world.
function Guard.squadSpawner(id, now)
    local tx = session
    if not tx or not tx.arrived or not tx.watch or not tx.watch[id] then return end
    local actor = Guard.actor(id)
    if actor and inState(tx, actor) then return actor end
    if now < (tx.nextSquadSpawnerLookup or 0) then return end
    tx.nextSquadSpawnerLookup = now + 0.75
    for _, value in ipairs(FindAllOf("BP_AISpawner_C") or {}) do
        local candidate = unwrap(value)
        local key = candidate and name(candidate:GetFName())
        if key and tx.watch[key] and not Guard.actor(key) and inState(tx, candidate)
            and not candidate:IsActorBeingDestroyed() then
            filterActor(candidate, tx, true)
        end
    end
    actor = Guard.actor(id)
    if actor and inState(tx, actor) then return actor end
end

function Guard.allowSquadSpawners(scene, slots)
    local tx = assert(session, "原版队伍需要演武事件隔离")
    assert(tx.scene and tx.scene.id == scene.id and tx.policy == "blocked" and tx.arrived
        and not tx.squadSpawners, "原版队伍的场景隔离状态不符")
    local squad = { slots = slots, sources = {}, summons = {} }
    for _, slot in ipairs(slots) do
        local actor = slot.spawner
        local watched = Guard.actor(name(actor:GetFName()))
        assert(watched and watched:GetAddress() == actor:GetAddress() and inState(tx, actor),
            "原版队伍出生点不在场景名单内")
        squad.sources[actor:GetAddress()] = slot
        if slot.dormant then squad.summons[slot.id .. "_C"] = true end
    end
    tx.squadSpawners = squad
end

function Guard.squadSpawnerAllowed(actor)
    local squad = session and session.squadSpawners
    local slot = squad and squad.sources[actor:GetAddress()]
    return slot and not slot.released
end

function Guard.releaseSquadSpawners(slots)
    if session and session.squadSpawners and session.squadSpawners.slots == slots then
        session.squadSpawners = nil
    end
end

function Guard.flushArenaPawns(world, player)
    local tx = session
    if not tx or not tx.pawns or not valid(world) or tx.world ~= world:GetAddress() then
        return nil, "等待溪谷战区的 NPC 隔离会话"
    end
    local removed = 0
    for address, actor in pairs(tx.pawns) do
        if address ~= player:GetAddress() and not retained(tx, actor)
            and inState(tx, actor, true) and not actor:IsActorBeingDestroyed() then
            local ok, why = pcall(actor.K2_DestroyActor, actor)
            if not ok then return nil, "清理原版 NPC 失败：" .. tostring(why) end
            if valid(actor) and not actor:IsActorBeingDestroyed() and not actor:HasAnyFlags(PENDING) then
                return nil, "等待原版 NPC 退出试场：" .. name(actor:GetFName())
            end
            removed = removed + 1
        end
        tx.pawns[address] = nil
    end
    if removed > 0 then
        tx.counts.pawns_removed = (tx.counts.pawns_removed or 0) + removed
        log("NPC_REMOVED total=" .. tx.counts.pawns_removed)
    end
    return true
end

function Guard.allowCreatedBell(actor)
    local tx = assert(session, "arena event guard is not active")
    assert(tx.canCreateBell and tx.world and inState(tx, actor, true)
        and name(actor.BellID) == tx.bellId, "invalid trial bell")
    tx.ownedBell = actor:GetAddress()
end

function Guard.mark(phase)
    if session and session.timing then session.timing:mark(phase) end
end

function Guard.update(system, now)
    local tx = session
    if tx then refreshEntryBlocker(tx, now) end
    if not tx or not tx.timing then return end
    if not tx.nextReport then
        local ok, frame = pcall(function() return system:GetFrameCount() end)
        tx.frame, tx.sampleAt, tx.nextReport = ok and frame or nil, now, now + 10
        return
    end
    if tx.sampleAt and now >= tx.nextReport then
        local ok, frame = pcall(function() return system:GetFrameCount() end)
        local elapsed = now - tx.sampleAt
        local fps = ok and tonumber(frame) and tonumber(tx.frame) and frame >= tx.frame
            and ("%.1f"):format((frame - tx.frame) / elapsed) or "n/a"
        summary(tx, "SAMPLE", ("seconds=%.1f engine_fps=%s"):format(elapsed, fps))
        if not tx.timing.handle then tx.timing:summary(true) end
        tx.frame, tx.sampleAt, tx.nextReport = ok and frame or nil, now, now + 10
    end
end

function Guard.reset()
    local old = session
    session = nil
    if old then
        if old.timing then old.timing:close() end
        summary(old, "EXIT")
    end
end

function Guard.onMapPre()
    if session and session.pendingTravel then session.pendingTravel = false
    else Guard.reset() end
end

-- Mask selected streamed interactions while preserving their scene geometry.
local TRAVERSAL_FUNCTION = "/Script/AdvancedSpecialMove.SpecialMoveVolumeBase:"
local traversalHooks = {}
local traversalTriggers = { BoxA = true, TopCollision = true, BottomCollision = true }
local traversalPrompts = { InteractWidget = true, TopInteractWidget = true, BottomInteractWidget = true }

local function denyTraversal(context)
    local tx = session
    if not tx or not tx.traversal then return end
    local actor = unwrap(context)
    local key = actor and name(actor:GetFName())
    if not key or not tx.blockedTraversal[key] or not inState(tx, actor) then return end
    if not tx.traversal.denied[key] then
        tx.traversal.denied[key] = true
        log("TRAVERSAL denied=" .. key)
    end
    return false
end

local function reportTraversalInput(context)
    local tx = session
    if not tx or not tx.traversal then return end
    local actor = unwrap(context)
    if not inState(tx, actor) then return end
    local key = name(actor:GetFName())
    if tx.traversal.inputLogged[key] then return end
    local at = actor:K2_GetActorLocation()
    log(("TRAVERSAL input=%s affected=%s xyz=(%.1f,%.1f,%.1f)"):format(
        key, tostring(tx.blockedTraversal[key] == true), at.X, at.Y, at.Z))
    tx.traversal.inputLogged[key] = true
end

local function denyInteraction(_, target)
    local tx = session
    if tx and tx.blockedPortal and isBlockedPortal(tx, unwrap(target)) then return false end
    return denyTraversal(target)
end

local function installInteractionHooks(portalOnly)
    local noop = function() end
    local hooks = {
        { "/Script/ProjectPBZ.PBZInteractComponent:CanTriggerInteract", noop, denyInteraction },
    }
    if not portalOnly then
        hooks[#hooks + 1] = { TRAVERSAL_FUNCTION .. "HandleIsValidInteract", noop, denyTraversal }
        hooks[#hooks + 1] = { TRAVERSAL_FUNCTION .. "HandleIsValidInteractOutOverlap", noop, denyTraversal }
        hooks[#hooks + 1] = { TRAVERSAL_FUNCTION .. "HandleOnInteract", reportTraversalInput, noop }
    end
    local label = portalOnly and "PORTAL" or "TRAVERSAL"
    for _, hook in ipairs(hooks) do
        local path = hook[1]
        if not traversalHooks[path] then
            local ok, result = pcall(RegisterHook, path, hook[2], hook[3])
            traversalHooks[path] = ok or nil
            log(label .. " hook=" .. path:match("[^:]+$") .. (ok and " installed" or " error=" .. tostring(result)))
        end
    end
end

local function componentName(component)
    return (name(component:GetFName()):gsub("_%d+$", ""):gsub("_GEN_VARIABLE$", ""))
end

local function maskTraversalComponents(tx, actor)
    actor.DisplayUIDistance = 0
    local triggers, prompts = 0, 0
    for _, value in ipairs(actor:K2_GetComponentsByClass(tx.pointMask.shape) or {}) do
        local shape = unwrap(value)
        if shape and traversalTriggers[componentName(shape)] and tx.pointMask:disableTrigger(shape) then
            triggers = triggers + 1
        end
    end
    local widgetClass = StaticFindObject("/Script/UMG.WidgetComponent")
    if valid(widgetClass) then
        for _, value in ipairs(actor:K2_GetComponentsByClass(widgetClass) or {}) do
            local widget = unwrap(value)
            if widget and traversalPrompts[componentName(widget)] then
                widget:SetHiddenInGame(true, false)
                prompts = prompts + 1
            end
        end
    end
    return triggers, prompts
end

local function clearInteractionCache(player, actor)
    local class = StaticFindObject("/Script/ProjectPBZ.PBZInteractComponent")
    local interaction = valid(class) and unwrap(player:GetComponentByClass(class))
    if not interaction then return false end
    interaction:RemovePotentialInteract(actor)
    return true
end

function Guard.updateBlockedTraversal(world, player)
    local tx = session
    local traversal = tx and tx.traversal
    if not traversal or tx.world ~= world:GetAddress() then return end
    if not traversal.hooksAttempted then
        traversal.hooksAttempted = true
        installInteractionHooks(false)
    end
    for address, actor in pairs(traversal.pending) do
        traversal.pending[address] = nil
        if inState(tx, actor) and not actor:IsActorBeingDestroyed() then
            local key = name(actor:GetFName())
            if tx.blockedTraversal[key] then
                local ok, triggers, prompts = pcall(maskTraversalComponents, tx, actor)
                local cacheOk, cacheCalled = pcall(clearInteractionCache, player, actor)
                if ok then
                    local at = actor:K2_GetActorLocation()
                    count(tx, "traversal_masked")
                    log(("TRAVERSAL masked=%s xyz=(%.1f,%.1f,%.1f) triggers=%d prompts=%d cache_call=%s"):format(
                        key, at.X, at.Y, at.Z, triggers, prompts, tostring(cacheOk and cacheCalled)))
                else
                    log("TRAVERSAL mask_error=" .. key .. " " .. tostring(triggers))
                end
            end
        end
    end
end

function Guard.updateBlockedPortal(world, player, now)
    local tx = session
    if not tx or not tx.blockedPortal or tx.world ~= world:GetAddress() then return end
    if not tx.portalHookAttempted then
        tx.portalHookAttempted = true
        installInteractionHooks(true)
    end
    local portal = tx.portal
    if now < (tx.nextPortalCheck or 0) or not isBlockedPortal(tx, portal) then return end
    tx.nextPortalCheck = now + 0.65
    local ok, masked = pcall(mutePortal, portal, true)
    if not ok then fail(tx, "portal_mask", masked); return end
    if not masked or tx.portalCleared == portal then return end
    local cleared, result = pcall(clearInteractionCache, player, portal)
    if not cleared then fail(tx, "portal_cache", result); return end
    if result then
        tx.portalCleared = portal
        log("PORTAL interaction disabled=" .. tx.blockedPortal .. " sphere=0 cache=cleared")
    end
end

return Guard
