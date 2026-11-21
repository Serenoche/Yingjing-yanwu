-- Run with the staged runtime on package.path.
local Rules = require("DreamPalaceMobPressureRules")
local selector = "/Script/SGameAI.SGameAIStrategyConfig:SelectBehavior"
local strategy = "/SGameAI/Core/AICondition/Condition_DoesStrategyValid.Condition_DoesStrategyValid_C:EvaluateCondition"
local goal = "/SGameAI/Core/AICondition/Condition_IsLeaderAI.Condition_IsLeaderAI_C:EvaluateCondition"
local leader = "/SGameAI/MetaAI/Decorators/BTDecorator_IsLeaderAI.BTDecorator_IsLeaderAI_C:PerformConditionCheckAI"
local attack = "AI.Strategy.Attack"

local nextAddress, now, hookCount = 0, 0, 0
local hooks, failAt = {}, nil
local function name(value) return { ToString = function() return value end } end
local function param(value) return { get = function() return value end } end
local function object(properties)
    nextAddress = nextAddress + 1
    local address = nextAddress
    properties.IsValid = function(self) return not self.destroyed end
    properties.GetAddress = function() return address end
    return properties
end
local function tree(label) return object({ GetFName = function() return name(label) end }) end
local function asc()
    return object({ tags = {}, GetGameplayTagCount = function(self, tag) return self.tags[tag.TagName] and 1 or 0 end })
end
local function actor()
    local brain = object({ GetRunningBehaviorTree = function(self) return self.tree end })
    local ai = object({ CurrentStateTag = { TagName = name("AI.State.Combat") } })
    local controller = object({ BrainComponent = brain, GetMetaAI = function(self) return self.group end })
    local pawn = object({ AbilitySystemComponent = asc(), IsActorBeingDestroyed = function() return false end,
        GetController = function() return controller end, ai = ai })
    return pawn, controller, brain
end
local gameplay = object({ GetTimeSeconds = function() return now end })
FName = function(value) return value end
IsInGameThread = function() return true end
StaticFindObject = function() return gameplay end
function RegisterHook(path, pre, post)
    hookCount = hookCount + 1
    assert(hookCount ~= failAt, "mock hook failure")
    assert(not hooks[path])
    hooks[path] = { pre = pre, post = post, id = hookCount }
    return hookCount, hookCount
end
function UnregisterHook(path, pre, post)
    assert(hooks[path].id == pre and pre == post)
    hooks[path] = nil
end

package.loaded.CombatSpawn = { ai = function(pawn) return pawn.ai end }
local Pressure = require("DreamPalaceMobPressure")
local player = actor()
local a, ca, ba = actor()
local b, cb, bb = actor()
local c, cc, bc = actor()
local _, outside = actor()
local actors = { a, b, c }
local members = { { id = "E006", regularMob = true }, { id = "M014", regularMob = true },
    { id = "E009", regularMob = true } }
local group = object({ GetMemberPawns = function() return actors end })
ca.group, cb.group = group, group
local attackTree, footwork = tree("BT_Tactic_Attack"), tree("BT_SharedTactic_Footsies")
local preview = param({ ["Strategy Tag"] = { TagName = name(attack) } })

assert(not Pressure.start(player, actors, members, 40) and hookCount == 0)
local middle, late = Rules.new(70), Rules.new(71)
assert(middle.limit == 2 and middle.startsPerRound == 3 and middle.spacing == .45)
assert(late.limit == 3 and late.startsPerRound == 4 and late.spacing == .30)

local session = assert(Pressure.start(player, actors, members, 70))
local choose = assert(hooks[selector].post)
local function choice(controller, asset, tag)
    local result = { BehaviorTree = asset, nativeCooldown = 20 }
    choose(param(nil), param(result), param({ TagName = name(tag or attack) }), param(controller))
    assert(result.nativeCooldown == 20)
    return result.BehaviorTree
end
local function step(at)
    now = at
    assert(session:step(now))
end

for _ = 1, 20 do
    assert(hooks[goal].pre(param(nil), param(ca)) == true)
    assert(hooks[strategy].pre(preview, param(ca)) == nil)
end
assert(choice(outside, attackTree) == attackTree)
assert(choice(ca, nil) == nil and choice(ca, footwork, "AI.Strategy.Footsies") == footwork)
assert(not next(session.sequence.slots) and session.sequence.counts.admitted == 0)
assert(hooks[leader].pre(param(nil), param(ca)) == nil)
assert(choice(ca, attackTree) == attackTree)
assert(hooks[leader].pre(param(nil), param(ca)) == true)
step(.10)
assert(choice(ca, attackTree) == attackTree and session.sequence.counts.admitted == 1)
step(.46)
assert(not next(session.sequence.slots) and session.sequence.used == 0 and session.sequence.counts.expired == 1)

assert(choice(cb, attackTree) == attackTree)
bb.tree = attackTree
step(.48)
step(.90)
assert(choice(ca, attackTree) == nil)
step(.95)
assert(choice(ca, attackTree) == attackTree)
ba.tree = attackTree
step(.96)
step(1.45)
assert(session.sequence.counts.peak == 2 and choice(cc, attackTree) == nil)
ba.tree = footwork
a.AbilitySystemComponent.tags["CharacterState.Action.Phase.Act"] = true
step(1.50)
assert(choice(cc, attackTree) == nil)
a.AbilitySystemComponent.tags["CharacterState.Action.Phase.Act"] = nil
step(1.51)
assert(choice(cc, attackTree) == attackTree)
assert(hooks[leader].pre(param(nil), param(cc)) == true)
bc.tree = attackTree
step(1.52)
assert(session.sequence.blocked and session.sequence.counts.started == 3)
bb.tree, bc.tree = nil, nil
player.AbilitySystemComponent.tags["CharacterState.Hitreact.State"] = true
step(2)
assert(not session.sequence.quietSince)
player.AbilitySystemComponent.tags["CharacterState.Hitreact.State"] = nil
step(2.25)
step(3.24)
assert(choice(ca, attackTree) == nil)
step(3.25)
assert(choice(ca, attackTree) == attackTree and session.sequence.counts.windows == 1)

session:close()
assert(not next(hooks) and choice(ca, attackTree) == attackTree)
failAt = hookCount + 3
assert(not Pressure.start(player, actors, members, 70) and not next(hooks))

local fighters = {}
for id = 1, 4 do fighters[id] = { id = id, alive = true, eligible = true } end
for id = 1, 3 do
    local time = id * .4
    assert(late:admit(fighters[id], id, time))
    fighters[id].attackTree = id
    late:observe(time + .01, fighters, true)
end
assert(late.counts.peak == 3 and not late:admit(fighters[4], 4, 1.60))
fighters[4].attackTree = 4
late:observe(1.7, fighters, true)
assert(late.counts.outside == 1 and late.blocked)
print("PASS mob pressure prechecks, confirmed starts, expiry, limits, counter window and hook cleanup")
