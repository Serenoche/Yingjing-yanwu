local Pursuit = {}
local Session = {}
Session.__index = Session

local MOB = "/PBZCombatAsset/ActorData/Mobs/FengXueDaoKe/"
local CLASS = MOB .. "BP_Monster_FengXueDaoKe.BP_Monster_FengXueDaoKe_C"
local ATTACK_TREE = MOB .. "AIConfig/BT_Tactic_FengXueDaoKe_Attack.BT_Tactic_FengXueDaoKe_Attack"
local FROZEN_TREE = MOB .. "BehaviorTree/BT_FengXueDaoKe_Frozen_Taunt.BT_FengXueDaoKe_Frozen_Taunt"
local HUMANOID = "/PBZCombatAsset/Prototypes/AI/Template/StateConfig/StateTreeConfig_Humaniod.StateTreeConfig_Humaniod"
local AI_LIBRARY = "/Script/SGameAI.Default__SGameAIFunctionLibrary"
local TARGET = "AI.BlackboardKey.Object.TargetActor"
local SELF = "AI.BlackboardKey.Object.SelfActor"
local CONDITION = "/SGameAI/Core/AICondition/"
local DECORATOR = "/SGameAI/BehaviorTree/Decorator/"

local KNOCKDOWN = {
    "CharacterState.Hitreact.State.LaunchingBack",
    "CharacterState.Hitreact.State.Lying",
    "CharacterState.Hitreact.State.Air.Launchingback",
}
local PROTECTED = {
    "CharacterState.HitReact.State.Dead",
    "CharacterState.HitReact.State.Executing",
    "Ability.Action.Execution",
    "CharacterState.Dead",
}
local EXCLUDED = {}
for _, name in ipairs(KNOCKDOWN) do EXCLUDED[#EXCLUDED + 1] = name end
for _, name in ipairs(PROTECTED) do EXCLUDED[#EXCLUDED + 1] = name end
local FROZEN = { "CharacterState.Hitreact.State.Frozen" }
local CANCEL = { "CharacterState.Action.Phase.Cancel" }
local EMPTY = {}

local function valid(object) return object and object:IsValid() end
local function same(a, b) return valid(a) and valid(b) and a:GetAddress() == b:GetAddress() end
local function path(object) return valid(object) and object:GetFullName():match("^%S+ (.+)$") end
local function log(message) print("[PBZFengXuePursuit] " .. message .. "\n") end

local function exactTags(container, expected)
    local tags = container.GameplayTags
    if #tags ~= #expected then return false end
    local names = {}
    for index = 1, #tags do
        local tag = tags[index]
        if type(tag.get) == "function" then tag = tag:get() end
        names[tag.TagName:ToString():lower()] = true
    end
    for _, name in ipairs(expected) do
        if not names[name:lower()] then return false end
    end
    return true
end

local function attackGoal(node)
    return node:GetFName():ToString() == "Condition_HasTags_C_5" and path(node:GetOuter()) == HUMANOID
        and node.CheckTargetTags and node.TargetActor.TagName:ToString() == TARGET
        and not node.bInverseCondition and exactTags(node.RequiredTags, EMPTY) and exactTags(node.IgnoredTags, EXCLUDED)
end

local function attackExit(node)
    local outer = node:GetOuter()
    return valid(outer) and path(outer.TreeAsset) == ATTACK_TREE
        and node.CheckTargetTags and node.TargetActor.TagName:ToString() == TARGET
        and not node.bInverseCondition and exactTags(node.RequiredTags, EXCLUDED)
end

local function frozenWait(node)
    return path(node.TreeAsset) == FROZEN_TREE and node.bInverseCondition
        and node.TargetActorKey.TagName:ToString() == SELF and exactTags(node["Tag Container"], CANCEL)
end

local GATES = {
    { path = CONDITION .. "Condition_HasTags.Condition_HasTags_C:EvaluateCondition",
        matches = attackGoal, state = "knockdown", result = true },
    { path = CONDITION .. "Condition_HasAnyTags.Condition_HasAnyTags_C:EvaluateCondition",
        matches = attackExit, state = "knockdown", result = false },
    -- The wait decorator is inverted. A true raw result skips its wait task
    -- and lets the existing successful fallback advance to the attack subtree.
    { path = DECORATOR .. "BTDecorator_TargetHasTag.BTDecorator_TargetHasTag_C:PerformConditionCheckAI",
        matches = frozenWait, state = "frozen", result = true },
}

local function gameplayTags(names)
    local tags = {}
    for index, name in ipairs(names) do tags[index] = { TagName = FName(name) } end
    return tags
end

local function hasAny(asc, tags)
    for _, tag in ipairs(tags) do
        if asc:GetGameplayTagCount(tag) > 0 then return true end
    end
    return false
end

function Session:override(gate, context, owner)
    local controller = owner:get()
    if not valid(controller) or not same(self.boss, controller:K2_GetPawn()) or not self.boss:IsAlive() then return end
    local node = context:get()
    if not valid(node) or not gate.matches(node) then return end
    local pawn = self.pawn
    if not valid(pawn) or not pawn:IsAlive() then return end
    local asc, blackboard = pawn.AbilitySystemComponent, controller.Blackboard
    if not valid(asc) or not valid(blackboard) or not hasAny(asc, self.tags[gate.state])
        or hasAny(asc, self.tags.protected) then return end
    if same(pawn, self.library:GetValueAsObjectByTag(blackboard, self.target)) then return gate.result end
end

function Session:close()
    self.active = false
    for _, hook in ipairs(self.hooks) do
        local ok, reason = pcall(UnregisterHook, hook.path, hook.pre, hook.post)
        if not ok then log("清理失败 " .. tostring(reason)) end
    end
    self.hooks, self.pawn, self.boss = {}, nil, nil
end

function Session:install()
    for _, gate in ipairs(GATES) do
        if not valid(StaticFindObject(gate.path)) then LoadAsset(gate.path:match("^(.+)_C:")) end
        assert(valid(StaticFindObject(gate.path)), "原版选招接口未就绪 " .. gate.path)
    end
    for _, gate in ipairs(GATES) do
        local pre, post = RegisterHook(gate.path, function(context, controller)
            if not self.active or not IsInGameThread() then return end
            local ok, result = pcall(self.override, self, gate, context, controller)
            if ok then return result end
            self.active = false
            log("使用原版追击规则 " .. tostring(result))
        end)
        assert(type(pre) == "number" and type(post) == "number", "原版选招接口注册失败 " .. gate.path)
        self.hooks[#self.hooks + 1] = { path = gate.path, pre = pre, post = post }
    end
    self.active = true
end

function Pursuit.start(pawn, stage, actors)
    if stage.regularMobs or #stage.members ~= 1 or stage.members[1].id ~= "BP_Monster_FengXueDaoKe" then return end
    local boss = actors[1]
    local self = setmetatable({ pawn = pawn, boss = boss, hooks = {} }, Session)
    local ok, reason = pcall(function()
        assert(IsInGameThread() and valid(pawn) and valid(boss) and type(UnregisterHook) == "function",
            "浊梦战斗接口未就绪")
        assert(path(boss:GetClass()) == CLASS and same(pawn:GetWorld(), boss:GetWorld()), "风雪刀客不属于当前战场")
        self.library = StaticFindObject(AI_LIBRARY)
        assert(valid(self.library), "原版 AI 黑板接口未就绪")
        self.target = { TagName = FName(TARGET) }
        self.tags = { knockdown = gameplayTags(KNOCKDOWN), frozen = gameplayTags(FROZEN), protected = gameplayTags(PROTECTED) }
        self:install()
    end)
    if ok then return self end
    self:close()
    log("使用原版追击规则 " .. tostring(reason))
end

return Pursuit
