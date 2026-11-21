local Balance = {}
local EARLY_MOB_CYCLES = { health = 1, attack = 1, shachi = 1 }
local PLAYER_SHACHI_CYCLE = { nightmare = 3, sunk = 4, deep = 5, entry = 5 }
local TALENT_CURVE = "/PBZCombatAsset/Prototypes/GameplayEffects/Talent/CurveTable/CT_Talent_IncreaseAttack.CT_Talent_IncreaseAttack"
local CURVE_LIBRARY = "/Script/Engine.Default__DataTableFunctionLibrary"
local ABILITY_LIBRARY = "/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary"
local ATTACK_TALENT = "GE_Talent_IncreaseAttack_C"
local BREAK = "CharacterState.Stand.Break"
local DEAD = "CharacterState.Dead"
local EPSILON = .01

local RECOVERY_START_FLOOR, RECOVERY_PEAK_FLOOR = 41, 90
-- Peak rates are fractions of the effective Shachi maximum per game second.
local RECOVERY = {
    nightmare = { boss = { rate = .20, delay = 1.00 }, namedElite = { rate = .18, delay = 1.30 } },
    sunk = { boss = { rate = .20, delay = 1.10 }, namedElite = { rate = .18, delay = 1.45 } },
    deep = { boss = { rate = .20, delay = 1.20 }, namedElite = { rate = .18, delay = 1.60 } },
    entry = { boss = { rate = .18, delay = 1.50 }, namedElite = { rate = .16, delay = 1.90 } },
}

local function valid(object) return object and object:IsValid() end
local function finite(value) return type(value) == "number" and value > -math.huge and value < math.huge end

function Balance.mobStatCycles(floor, selection)
    if floor < 10 and selection.enemyCycle == 0 and selection.id:sub(1, 1) == "M" then
        return EARLY_MOB_CYCLES
    end
end

local function shachiTalent(library, curve, level)
    if level == 0 then return 0 end
    local result, magnitude = {}, {}
    library:EvaluateCurveTableRow(curve, FName("IncreaseShachiAttackLevel"), level, result, magnitude, "DreamPalace")
    assert(result.OutResult == 0 and finite(magnitude.OutXY), "无法读取原版黑石杀气攻击成长曲线")
    return magnitude.OutXY
end

local function talentCurve()
    local library = StaticFindObject(CURVE_LIBRARY)
    local curve = StaticFindObject(TALENT_CURVE)
    if not valid(curve) then
        LoadAsset(TALENT_CURVE)
        curve = StaticFindObject(TALENT_CURVE)
    end
    assert(valid(library) and valid(curve), "原版杀气攻击曲线未就绪")
    return library, curve
end

local function unwrap(value)
    if value and type(value.get) == "function" then return value:get() end
    return value
end

local function talentModel(pawn, level, library, curve)
    if level < 2 then return end
    local abilities, asc = StaticFindObject(ABILITY_LIBRARY), pawn.AbilitySystemComponent
    if not valid(abilities) or not valid(asc) then return end
    local effects = asc:GetActiveEffectsWithAllTags({ GameplayTags = {}, ParentTags = {} })
    for index = 1, #effects do
        local item = unwrap(effects[index])
        local handle = { Handle = item.Handle, bPassedFiltersAndWasExecuted = item.bPassedFiltersAndWasExecuted }
        local effect = abilities:GetGameplayEffectFromActiveEffectHandle(handle)
        if valid(effect) and effect:GetClass():GetFName():ToString() == ATTACK_TALENT then
            local stacks = abilities:GetActiveGameplayEffectStackCount(handle)
            if #effect.Modifiers ~= 2 or (stacks ~= 1 and stacks ~= level) then return end
            local attribute = unwrap(unwrap(effect.Modifiers[2]).Attribute)
            if attribute.AttributeName:ToString() ~= "ShachiAttack" then return end
            -- GAS exposes the evaluated magnitude per stack, before applying the stack count.
            local raw = asc:GetGameplayEffectMagnitude(handle, attribute)
            if not finite(raw) then return end
            local usesLevel = math.abs(raw - shachiTalent(library, curve, level)) <= EPSILON
            if usesLevel or math.abs(raw - shachiTalent(library, curve, 1)) <= EPSILON then
                return { usesLevel = usesLevel, usesStacks = stacks == level and effect.bFactorInStackCount ~= false }
            end
            return
        end
    end
end

function Balance.readPlayerTalentModel(pawn, level)
    local ok, model = pcall(function()
        local library, curve = talentCurve()
        return talentModel(pawn, level, library, curve)
    end)
    if ok then return model end
end

local function talentContribution(library, curve, level, model)
    if level == 0 then return 0 end
    local evaluationLevel = model and not model.usesLevel and 1 or level
    local stacks = model and model.usesStacks and level or 1
    return shachiTalent(library, curve, evaluationLevel) * stacks
end

function Balance.restorePlayerShachi(pawn, base)
    local attributes = pawn.AttributeSetBase
    assert(valid(attributes), "浊梦玩家属性未就绪")
    if math.abs(attributes.ShachiAttack.BaseValue - base) > EPSILON then
        require("PracticeMode").setAttributeValue(pawn, "ShachiAttack", base)
    end
    assert(math.abs(attributes.ShachiAttack.BaseValue - base) <= EPSILON, "浊梦玩家杀气攻击力回读不符")
    return attributes.ShachiAttack.CurrentValue
end

function Balance.setPlayerShachi(pawn, tier, talentLevel, model)
    local cycle = assert(PLAYER_SHACHI_CYCLE[tier], "浊梦杀气攻击轮回无效")
    local targetLevel = cycle * 5
    assert(finite(talentLevel) and talentLevel >= 0 and talentLevel % 1 == 0 and talentLevel <= 30,
        "浊梦黑石修行等级无效")
    local library, curve = talentCurve()
    model = model or Balance.readPlayerTalentModel(pawn, talentLevel)
    local delta = talentContribution(library, curve, targetLevel, model)
        - talentContribution(library, curve, talentLevel, model)
    local attributes = pawn.AttributeSetBase
    assert(valid(attributes), "浊梦玩家属性未就绪")
    local base = attributes.ShachiAttack.BaseValue + delta
    assert(finite(base) and base >= 0, "浊梦玩家杀气攻击力无效")
    return cycle, Balance.restorePlayerShachi(pawn, base), base
end

function Balance.recoveryTargets(stage, actors, floor, tier)
    local rules = RECOVERY[tier]
    if not rules or floor < RECOVERY_START_FLOOR then return end
    local progress = math.min(1, (floor - RECOVERY_START_FLOOR) / (RECOVERY_PEAK_FLOOR - RECOVERY_START_FLOOR))
    local multiplier = .5 + .5 * progress
    local namedElites = require("DreamPalacePressurePolicy").namedElites
    local targets
    for index, member in ipairs(stage.members) do
        local rule = namedElites[member.id] and rules.namedElite or not stage.regularMobs and rules.boss
        if rule then
            targets = targets or {}
            targets[#targets + 1] = { actor = actors[index], rate = rule.rate * multiplier, delay = rule.delay,
                breakTag = { TagName = FName(BREAK) }, deadTag = { TagName = FName(DEAD) } }
        end
    end
    return targets
end

function Balance.recoverShachi(targets, now)
    for _, target in ipairs(targets) do
        local actor = target.actor
        if not now or not valid(actor) or actor:IsActorBeingDestroyed() then
            target.lastAt = nil
        else
            local attributes, asc = actor.AttributeSetBase, actor.AbilitySystemComponent
            if valid(attributes) and valid(asc) then
                local current = attributes.Shachi.CurrentValue
                local maximum = attributes.Shachi_Max.CurrentValue
                local active = current > EPSILON and current <= maximum and attributes.Health.CurrentValue > 0
                    and asc:GetGameplayTagCount(target.breakTag) == 0 and asc:GetGameplayTagCount(target.deadTag) == 0
                if not active or target.blocked or not target.lastAt or current < target.lastShachi - EPSILON then
                    target.resumeAt = now + target.delay
                else
                    local elapsed = now - math.max(target.lastAt, target.resumeAt)
                    local recovery = math.min(maximum - current, maximum * target.rate * elapsed)
                    if recovery > 0 then
                        require("PracticeMode").setAttributeValue(actor, "Shachi", attributes.Shachi.BaseValue + recovery)
                        current = attributes.Shachi.CurrentValue
                    end
                end
                target.lastAt, target.lastShachi, target.blocked = now, current, not active
            end
        end
    end
end

return Balance
