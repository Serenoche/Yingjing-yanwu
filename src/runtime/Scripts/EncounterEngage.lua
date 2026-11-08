-- Continue a multi-stage encounter against the same live player. This module
-- only starts enemy AI and invokes the game's native target/hatred transition.
-- No OffCombat, player tag/GE edits, resource writes or save/map reloads.
local Engage = {}

local AI_CLASS = "/Script/SGameAI.SGameAIComponent"
local HATRED_CLASS = "/SGameAI/Tools/Hatred/BP_SGameHatredManagerComponent.BP_SGameHatredManagerComponent_C"

local function valid(object)
    return object ~= nil and object:IsValid()
end

local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "missing encounter combat interface: " .. path)
    return object
end

local function unwrapped(value)
    local ok, result = pcall(function() return value:get() end)
    if ok then return result end
    return value
end

local function text(value)
    return type(value) == "string" and value or value:ToString()
end

local function contains(list, target)
    local found, targetAddress = false, target:GetAddress()
    list:ForEach(function(_, parameter)
        local actor = unwrapped(parameter)
        if valid(actor) and actor:GetAddress() == targetAddress then found = true end
    end)
    return found
end

local function context(actor, pawn)
    assert(valid(actor) and valid(pawn) and actor:GetAddress() ~= pawn:GetAddress(), "encounter combat actors are unavailable")
    assert(not actor:IsActorBeingDestroyed() and not pawn:IsActorBeingDestroyed(), "encounter combat actor is being destroyed")
    local world, playerWorld = actor:GetWorld(), pawn:GetWorld()
    assert(valid(world) and valid(playerWorld) and world:GetAddress() == playerWorld:GetAddress(),
        "encounter combat actors belong to different worlds")
    local dead = { TagName = FName("CharacterState.Dead") }
    local playerAsc, enemyAsc = pawn.AbilitySystemComponent, actor.AbilitySystemComponent
    assert(valid(playerAsc) and valid(enemyAsc), "encounter combat ability components are unavailable")
    assert(playerAsc:GetGameplayTagCount(dead) == 0, "dead player cannot continue encounter combat")
    local playerAttributes, enemyAttributes = pawn.AttributeSetBase, actor.AttributeSetBase
    assert(valid(playerAttributes) and type(playerAttributes.Health.CurrentValue) == "number"
        and playerAttributes.Health.CurrentValue > 0, "encounter player health is unavailable")
    assert(valid(enemyAttributes) and type(enemyAttributes.Health.CurrentValue) == "number", "encounter enemy health is unavailable")
    if enemyAsc:GetGameplayTagCount(dead) > 0 or enemyAttributes.Health.CurrentValue <= 0 then
        return nil, nil, nil, "already-dead"
    end
    local controller = actor:GetController()
    if not valid(controller) then return nil, nil, nil, "等待首领控制器初始化" end
    local ai = controller:GetComponentByClass(required(AI_CLASS))
    if not valid(ai) then return nil, nil, nil, "等待首领 AI 组件初始化" end
    if not valid(ai.Pawn) then return nil, nil, nil, "等待首领 AI 绑定角色" end
    assert(ai.Pawn:GetAddress() == actor:GetAddress(), "encounter AI component owns another pawn")
    local hatredClass = required(HATRED_CLASS)
    -- Both original RenewalPlayer and RenewalNPC own their hatred component on
    -- the pawn, rather than on the AI controller.
    local enemyHatred, playerHatred = actor:GetComponentByClass(hatredClass), pawn:GetComponentByClass(hatredClass)
    assert(valid(enemyHatred) and valid(playerHatred), "encounter hatred components are not ready")
    return ai, enemyHatred, playerHatred
end

local function read(actor, pawn, ai, enemyHatred, playerHatred)
    local state = ai.CurrentStateTag
    local stateName = state and state.TagName and text(state.TagName) or ""
    assert(type(ai.bAIStarted) == "boolean", "encounter AI start state is unavailable")
    return {
        started = ai.bAIStarted,
        state = stateName,
        inCombat = stateName == "AI.State.Combat" or stateName:sub(1, 16) == "AI.State.Combat.",
        hasTarget = contains(enemyHatred.HatredList, pawn),
        playerThreatened = contains(playerHatred.BeHatredList, actor),
        playerInCombat = pawn.AbilitySystemComponent:GetGameplayTagCount({ TagName = FName("CharacterState.InCombat") }) > 0,
    }
end

local function confirmed(details)
    return details.started and details.inCombat and details.hasTarget and details.playerThreatened
end

function Engage.read(actor, pawn)
    local ai, enemyHatred, playerHatred, reason = context(actor, pawn)
    if reason then return { dead = reason == "already-dead", ready = false, reason = reason } end
    return read(actor, pawn, ai, enemyHatred, playerHatred)
end

-- Retry on subsequent game-thread ticks when initial-action/native setup has
-- not finished. A failed native target acquisition is never reported as success.
-- Starting AI is guarded by its real bAIStarted flag, so retries do not restart
-- the initial action or repeatedly stack AI started/stopped tags.
function Engage.start(actor, pawn)
    local ai, enemyHatred, playerHatred, reason = context(actor, pawn)
    if reason == "already-dead" then return true, reason, { dead = true } end
    if reason then return false, reason end
    local before = read(actor, pawn, ai, enemyHatred, playerHatred)
    if confirmed(before) then return true, nil, before end
    if not before.started then ai:StartAI() end
    assert(type(ai.bAIStarted) == "boolean", "encounter AI start state is unavailable")
    if not ai.bAIStarted then return false, "等待首领 AI 初始化后继承仇恨", before end
    -- Exact original BP_SGameAIComponent function: requires bAIStarted,
    -- AddActorToHatredList succeeds, then Awareness=100 and ToCombat.
    ai:ForceIntoCombat(pawn)
    local after = read(actor, pawn, ai, enemyHatred, playerHatred)
    if confirmed(after) then return true, nil, after end
    return false, "原生首领仇恨或战斗状态尚未确认", after
end

-- Link only the actors explicitly supplied by the current MOD stage. Native
-- AI startup/proximity alone is not a player-aggro signal: first verify that
-- one actor's original hatred lists actually name this same player both ways.
-- The returned state contains identities/counters only and is discarded by
-- Challenge.clearStage. It does not retain actors from another stage/world.
function Engage.linkGroup(pawn, actors, state, now, enabled, engagedSignal)
    assert(type(actors) == "table" and #actors > 1 and type(now) == "number" and now > -math.huge and now < math.huge,
        "encounter group linkage input is unavailable")
    if not valid(pawn) or pawn:IsActorBeingDestroyed() then return nil, false, "player-unavailable" end
    local playerWorld = pawn:GetWorld()
    local asc, attributes = pawn.AbilitySystemComponent, pawn.AttributeSetBase
    if not valid(playerWorld) or not valid(asc) or not valid(attributes)
        or type(attributes.Health.CurrentValue) ~= "number" or not (attributes.Health.CurrentValue > 0)
        or asc:GetGameplayTagCount({ TagName = FName("CharacterState.Dead") }) > 0 then
        return nil, false, "player-unavailable"
    end
    local keys, live, used = { tostring(pawn:GetAddress()), tostring(playerWorld:GetAddress()) }, {}, {}
    for _, actor in ipairs(actors) do
        if valid(actor) and not actor:IsActorBeingDestroyed() then
            local world = actor:GetWorld()
            -- Validate every surviving identity before mutating any member.
            assert(valid(world) and world:GetAddress() == playerWorld:GetAddress(),
                "encounter group actor belongs to another world")
            assert(actor:GetAddress() ~= pawn:GetAddress(), "encounter group cannot target itself")
            assert(not used[actor:GetAddress()], "encounter group contains duplicate actor identities")
            used[actor:GetAddress()] = true
            keys[#keys + 1], live[#live + 1] = tostring(actor:GetAddress()), actor
        end
    end
    local identity = table.concat(keys, ":")
    if not state or state.identity ~= identity then state = { identity = identity, confirmed = {} } end
    if enabled ~= true then
        state.enabled, state.confirmed, state.nextAt, state.deadline, state.complete = false, {}, nil, nil, false
        state.triggered = false
        return state, false, "paused"
    end
    if state.enabled == false then state.nextAt, state.deadline = nil, nil end
    state.enabled = true
    local firstCombatSignal = engagedSignal == true and state.engagedSignal ~= true
    state.engagedSignal = engagedSignal == true
    -- Hatred can be established just before the native Combat state changes.
    -- Poll that read-only proof at a bounded rate; a first Combat signal may
    -- request an immediate check but can never authorize mutation by itself.
    if state.nextAt and now < state.nextAt and not firstCombatSignal then return state, state.complete == true, "waiting-for-native-retry" end
    state.nextAt = now + 0.25
    local pending, hasPlayerHatred = {}, false
    state.confirmed = {}
    for _, actor in ipairs(live) do
        local details = Engage.read(actor, pawn)
        if details.dead then state.confirmed[actor:GetAddress()] = true
        else
            hasPlayerHatred = hasPlayerHatred or (details.hasTarget and details.playerThreatened) or false
            if confirmed(details) then state.confirmed[actor:GetAddress()] = true
            else pending[#pending + 1] = actor end
        end
    end
    -- Leashes and native transitions can drop a relationship later in the
    -- same stage. Recheck actual state, never force from an old trigger/cache.
    if not hasPlayerHatred then
        state.triggered, state.complete, state.deadline = false, false, nil
        return state, false, "waiting-for-player-hatred"
    end
    state.triggered = true
    state.deadline = state.deadline or now + 5
    local complete, reason = true, nil
    for _, actor in ipairs(pending) do
        local address = actor:GetAddress()
        if not state.confirmed[address] then
            local acquired, failure = Engage.start(actor, pawn)
            if acquired then state.confirmed[address] = true
            else complete, reason = false, failure end
        end
    end
    assert(complete or now < state.deadline, "同场首领联动仇恨尚未确认：" .. tostring(reason))
    state.complete = complete
    if complete then state.deadline = nil end
    return state, complete, reason
end

return Engage
