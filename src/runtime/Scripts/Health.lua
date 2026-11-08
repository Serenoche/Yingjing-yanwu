local Health = {}

local FULL_HEALTH_ASSET = "/Game/PBZContent/Blueprint/Item/GameplayEffect/GE_RegenFullHealth.GE_RegenFullHealth"
local FULL_HEALTH_EFFECT = FULL_HEALTH_ASSET .. "_C"
local AI_STATES = "/Script/SGameAI.Default__SGameAIStateUtils"
local EPSILON = 0.01

local function valid(object)
    return object ~= nil and object:IsValid()
end

local function finite(value)
    return type(value) == "number" and value > -math.huge and value < math.huge
end

-- The arena caller owns the actor and invokes this module on the game thread.
function Health.read(actor)
    if not valid(actor) or actor:IsActorBeingDestroyed() then return nil, nil, true end

    -- GoldMaskMan inherits BP_RenewalNPC.IsAlive, which calls SGameAIStateUtils.IsDead.
    local alive = actor:IsAlive()
    assert(type(alive) == "boolean", "practice enemy death state is unavailable")

    local attributes = actor.AttributeSetBase
    if not valid(attributes) then return nil, nil, not alive end
    local hp = attributes.Health.CurrentValue
    local maxHp = attributes.Health_Max.CurrentValue
    local dead = not alive or (finite(hp) and hp <= 0)
    if not finite(hp) or not finite(maxHp) or maxHp <= 0 then return nil, nil, dead end
    return hp, maxHp, dead
end

local function findEffect()
    local effect = StaticFindObject(FULL_HEALTH_EFFECT)
    if not valid(effect) then
        LoadAsset(FULL_HEALTH_EFFECT)
        effect = StaticFindObject(FULL_HEALTH_EFFECT)
    end
    if not valid(effect) then
        LoadAsset(FULL_HEALTH_ASSET)
        effect = StaticFindObject(FULL_HEALTH_EFFECT)
    end
    assert(valid(effect), "stock full-health effect is unavailable")
    return effect
end

-- hp and maxHp are the arena's most recent sample after the hit grace period.
function Health.restore(actor, maxHp, hp)
    if not finite(hp) or not finite(maxHp) or hp <= 0 or maxHp <= 0 then
        return false, "health unavailable"
    end
    if maxHp - hp <= EPSILON then return false, "already full" end

    local effect = findEffect()
    local currentHp, currentMax, dead = Health.read(actor)
    if dead then return false, "enemy is dead" end
    if not currentHp then return false, "health unavailable" end
    if math.abs(currentHp - hp) > EPSILON or math.abs(currentMax - maxHp) > EPSILON then
        return false, "health changed"
    end
    if currentMax - currentHp <= EPSILON then return false, "already full" end

    local states = StaticFindObject(AI_STATES)
    assert(valid(states), "native enemy execution state is unavailable")
    local beingExecuted = states:IsBeingExecute(actor)
    assert(type(beingExecuted) == "boolean", "practice enemy execution state is unavailable")
    if beingExecuted then return false, "enemy is being executed" end

    local abilitySystem = actor.AbilitySystemComponent
    assert(valid(abilitySystem), "practice enemy ability system is unavailable")
    -- An empty context asks the native ASC to construct its normal self context.
    abilitySystem:BP_ApplyGameplayEffectToSelf(effect, 1.0, {})

    local restoredHp, restoredMax, nowDead = Health.read(actor)
    if nowDead or not restoredHp or restoredMax - restoredHp > EPSILON then
        return false, "stock full-health effect did not restore the enemy"
    end
    return true, nil, restoredHp, restoredMax
end

return Health
