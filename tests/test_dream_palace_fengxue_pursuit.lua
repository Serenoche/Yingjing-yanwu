-- Run with the staged runtime on package.path.
local Pursuit = require("DreamPalaceFengXuePursuit")
local base = "/PBZCombatAsset/ActorData/Mobs/FengXueDaoKe/"
local target = "AI.BlackboardKey.Object.TargetActor"
local bossId = "BP_Monster_FengXueDaoKe"
local lying = "CharacterState.Hitreact.State.Lying"
local launch = "CharacterState.Hitreact.State.LaunchingBack"
local air = "CharacterState.Hitreact.State.Air.Launchingback"
local frozen = "CharacterState.Hitreact.State.Frozen"
local executing = "CharacterState.HitReact.State.Executing"
local hooks, registrations, failAt = {}, 0, nil
local function name(value) return { ToString = function() return value end } end
local function param(value) return { get = function() return value end } end
local function object(fields)
    fields.IsValid = function() return true end
    fields.GetAddress = function() return fields end
    return fields
end
local function asset(assetPath)
    return object({ GetFullName = function() return "Object " .. assetPath end })
end
local function container(...)
    local tags = {}
    for _, text in ipairs({...}) do tags[#tags + 1] = { TagName = name(text) } end
    return { GameplayTags = tags }
end

local world, active = object({}), {}
local pawn = object({
    GetWorld = function() return world end, IsAlive = function(self) return not self.dead end,
    AbilitySystemComponent = object({ GetGameplayTagCount = function(_, tag) return active[tag.TagName] and 1 or 0 end }),
})
local boss = object({
    GetWorld = function() return world end, IsAlive = function(self) return not self.dead end,
    GetClass = function() return asset(base .. "BP_Monster_FengXueDaoKe.BP_Monster_FengXueDaoKe_C") end,
})
local controller = object({ K2_GetPawn = function() return boss end, Blackboard = object({ actor = pawn }) })
local other = object({ K2_GetPawn = function() return object({}) end })
local ai = object({ GetValueAsObjectByTag = function(_, blackboard, tag)
    assert(blackboard == controller.Blackboard and tag.TagName == target)
    return blackboard.actor
end })

FName = function(value) return value end
IsInGameThread = function() return true end
StaticFindObject = function() return ai end
function RegisterHook(path, callback)
    registrations = registrations + 1
    assert(registrations ~= failAt, "mock registration failure")
    assert(not hooks[path])
    hooks[path] = { callback = callback, id = registrations }
    return registrations, registrations
end
function UnregisterHook(path, pre, post)
    assert(hooks[path].id == pre and pre == post)
    hooks[path] = nil
end
local function callbackFor(fragment)
    for path, hook in pairs(hooks) do
        if path:find(fragment, 1, true) then return hook.callback end
    end
    error("missing hook " .. fragment)
end

local common = asset("/PBZCombatAsset/Prototypes/AI/Template/StateConfig/StateTreeConfig_Humaniod.StateTreeConfig_Humaniod")
local attackTree = asset(base .. "AIConfig/BT_Tactic_FengXueDaoKe_Attack.BT_Tactic_FengXueDaoKe_Attack")
local frozenTree = asset(base .. "BehaviorTree/BT_FengXueDaoKe_Frozen_Taunt.BT_FengXueDaoKe_Frozen_Taunt")
local original = container(lying, launch, air, "CharacterState.HitReact.State.Dead", executing,
    "Ability.Action.Execution", "CharacterState.Dead")
local goal = object({ CheckTargetTags = true, GetOuter = function() return common end,
    GetFName = function() return name("Condition_HasTags_C_5") end,
    TargetActor = { TagName = name(target) }, RequiredTags = container(), IgnoredTags = original })
local finish = object({ CheckTargetTags = true, GetOuter = function() return object({ TreeAsset = attackTree }) end,
    TargetActor = { TagName = name(target) }, RequiredTags = original })
local wait = object({ TreeAsset = frozenTree, bInverseCondition = true,
    TargetActorKey = { TagName = name("AI.BlackboardKey.Object.SelfActor") },
    ["Tag Container"] = container("CharacterState.Action.Phase.Cancel") })

assert(not Pursuit.start(pawn, { members = {{ id = "BP_Monster_LeiDang" }} }, { boss }) and not next(hooks))
local stage = { members = {{ id = bossId }} }
local session = assert(Pursuit.start(pawn, stage, { boss }))
local goalHook = callbackFor("Condition_HasTags_C")
local exitHook = callbackFor("Condition_HasAnyTags_C")
local waitHook = callbackFor("BTDecorator_TargetHasTag_C")
local function condition(hook, node, nativeResult)
    local override = hook(param(node), param(controller))
    if override == nil then return nativeResult end
    return override
end
local function canStartAttack()
    return condition(goalHook, goal, not (active[lying] or active[launch] or active[air] or active[executing]))
end
local function endsAttack(tooFar, randomEnd)
    return tooFar or randomEnd or condition(exitHook, finish, active[lying] or active[launch] or active[air] or active[executing] or false)
end
local function waitsForThaw()
    return wait.bInverseCondition ~= condition(waitHook, wait, false)
end

for _, state in ipairs({ lying, launch, air }) do
    active = { [state] = true }
    assert(canStartAttack() and not endsAttack(false, false))
    assert(endsAttack(true, false) and endsAttack(false, true))
end
active = { [frozen] = true }
assert(canStartAttack() and not endsAttack(false, false) and not waitsForThaw())
assert(goalHook(param(goal), param(controller)) == nil and exitHook(param(finish), param(controller)) == nil)
assert(active[frozen], "player freeze was changed")

active = { [lying] = true, [frozen] = true, [executing] = true }
assert(not canStartAttack() and endsAttack(false, false) and waitsForThaw())
active[executing] = nil
pawn.dead = true
assert(goalHook(param(goal), param(controller)) == nil and waitHook(param(wait), param(controller)) == nil)
pawn.dead = false
controller.Blackboard.actor = object({})
assert(goalHook(param(goal), param(controller)) == nil and waitHook(param(wait), param(controller)) == nil)
controller.Blackboard.actor = pawn
assert(goalHook(param(goal), param(other)) == nil and waitHook(param(wait), param(other)) == nil)
wait.TreeAsset = attackTree
assert(waitHook(param(wait), param(controller)) == nil)
wait.TreeAsset = frozenTree
goal.GetFName = function() return name("Condition_HasTags_C_3") end
assert(goalHook(param(goal), param(controller)) == nil)
goal.GetFName = function() return name("Condition_HasTags_C_5") end
goal.RequiredTags = container("Other.Required.Tag")
assert(goalHook(param(goal), param(controller)) == nil)
goal.RequiredTags = container()
active = { ["CharacterState.Hitreact.State"] = true }
assert(goalHook(param(goal), param(controller)) == nil and exitHook(param(finish), param(controller)) == nil
    and waitHook(param(wait), param(controller)) == nil)
session:close()
active = { [lying] = true, [frozen] = true }
assert(not next(hooks) and goalHook(param(goal), param(controller)) == nil and waitHook(param(wait), param(controller)) == nil)
failAt = registrations + 2
assert(not Pursuit.start(pawn, stage, { boss }) and not next(hooks))
print("PASS FengXue knockdown, ground and air launch, freeze wait, target scope and cleanup")
