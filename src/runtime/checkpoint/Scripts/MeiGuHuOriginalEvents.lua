-- Mount no replacement map. Limit these hooks to the arena's own stock-map travel.
local Guard = { map = "PBZ_Pangzhen_WP", path = "/Game/Maps/B08_09_10/PBZ_Pangzhen_WP" }
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
    BP_Teleport_C = "portal", BP_Chest_C = "chest", BP_FlowInteract_MemoryFlower_C = "story",
    BP_FlowActor_C = "story", BP_FlowActor_Wharf_C = "story", BP_FlowInteractActor_C = "story",
    BP_FlowInteractActor_DragonPillar_C = "story", BP_FlowInteractActor_Male_ScareCrow1_C = "story",
}
local session, installed

local function log(line) print("[PBZMeiGuHuOriginal] " .. line .. "\n") end
local function valid(v) return v and type(v.IsValid) == "function" and v:IsValid() end
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
    if not allowRuntime and not name(actor:GetFName()):find("_UAID_", 1, true) then return false end
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
    local kind = STORY_CLASSES[short]
    if not kind and short:find("^BP_Flow") then kind = "story" end
    if not kind and (short:find("^BP_MelodiousBell") or tx.pointMask and short:find("^BP_BrokenBell")) then kind = "bell" end
    local point = tx.pointMask and tx.pointMask:describe(actor, class, short, kind, tx.blockWharf)
    entry = (kind or point) and { kind = kind, aiSpawner = short == "BP_AISpawner_C", point = point, className = short } or false
    tx.classes[address] = entry
    return entry
end

local function filterActor(actor, tx, after)
    if not valid(actor) then return end
    local entry = classify(actor, tx)
    if not entry or not inState(tx, actor, entry.point) then return end
    local kind = entry.kind
    local actorName = (tx.arenaBell and (kind == "bell" or entry.point and entry.point.bell)
        or tx.watch and kind) and name(actor:GetFName())
    local arenaBell = (tx.ownedBell and kind == "bell" and actor:GetAddress() == tx.ownedBell
            and name(actor.BellID) == tx.bellId)
        or (actorName and tx.arenaBell and actorName == tx.arenaBell.name
            and (not after or name(actor.BellID) == tx.arenaBell.id))
    if not after and kind then count(tx, kind .. "_pre") end
    local flow = unwrap(actor.BP_PBZFlowComponent)
    if flow then disableFlow(tx, flow, after) end
    if entry.point and not arenaBell then
        local disabled, regions = tx.pointMask:apply(actor, entry.point, after)
        if after then
            if entry.point.wharf and disabled then count(tx, "wharf_interactions_disabled") end
            if disabled or kind == "story" or kind == "spawner" then
                count(tx, entry.point.resource and "resources_disabled" or "interactions_disabled")
            else
                count(tx, "interaction_unresolved_" .. entry.className)
            end
            tx.counts.interact_regions_disabled = tx.counts.interact_regions_disabled + regions
        end
        if not kind then return end
    end
    if kind == "bell" or arenaBell then
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
    if kind == "chest" then
        disableOverlap(actor.StringTrigger)
        disableOverlap(actor.TriggerBox)
        return
    end
    if kind == "domain" then
        if after then actor:SetEnabled(false) end
        actor:SetActorEnableCollision(false)
    elseif kind == "portal" then
        -- Retain the portal's physical mesh. Only its teleport overlap is disabled.
        disableOverlap(actor.OverlapTriggerbox)
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
        if not inState(tx, owner) then return end
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
    local pointMask = policy == "blocked" and require("MeiGuHuPointMask").new() or nil
    local counts = pointMask and { resources_disabled = 0, interactions_disabled = 0, interact_regions_disabled = 0 } or {}
    local blockWharf = pointMask and scene and scene.id == "meiguhu"
    if blockWharf then counts.wharf_interactions_disabled = 0 end
    local map, path = scene and scene.map or Guard.map, scene and scene.originalPath or Guard.path
    local timing
    if Guard.performanceRequested() then
        local ok, sampler = pcall(function() return require("MeiGuHuEventTiming").new(log) end)
        if ok then timing = sampler else log("TIMING_ERROR " .. tostring(sampler)) end
    end
    session = { previousWorld = valid(before) and before:GetAddress() or nil, pendingTravel = true,
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

return Guard
