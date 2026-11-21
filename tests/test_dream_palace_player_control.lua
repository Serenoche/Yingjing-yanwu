-- Run with the staged runtime on package.path.
local Control = require("DreamPalacePlayerControl")
local frost = "TakenReductionMultiplier_FrostDuration"
local breakDuration = "BreakDurationAdditionalMultiplier"
local startTime = "Start TIme"
local electrified = "/PBZCombatAsset/Prototypes/GameplayEffects/Inflictions/GA_Electrified.GA_Electrified_C:OnFinish_BA0FA7504042B3D561B2128960B4EF33"
local lieTimer = "/PBZCombatAsset/Prototypes/Hitreact/BP_HitreactEventListener_LieTimer.BP_HitreactEventListener_LieTimer_C"
local registerHitreact = "/Script/SGameCombatSystem.HitreactEventListenerBase:RegisterOnActor"
local hooks, inGameThread, available, failField = {}, true, true, nil

local function closeTo(actual, expected)
    assert(math.abs(actual - expected) < 0.00001, tostring(actual) .. " != " .. tostring(expected))
end

local function object(fields)
    fields.IsValid = function() return true end
    fields.GetAddress = function() return fields end
    return fields
end

local function pawn()
    return object({ AttributeSetBase = object({
        [frost] = { BaseValue = 1, CurrentValue = 0.8, multiplier = 0.8, addition = 0 },
        [breakDuration] = { BaseValue = 0, CurrentValue = 0.2, multiplier = 1, addition = 0.2 },
    }) })
end

package.loaded.PracticeMode = { setAttributeValue = function(target, field, base)
    if field == failField then error("simulated attribute failure") end
    local attribute = assert(target.AttributeSetBase[field])
    attribute.BaseValue = base
    attribute.CurrentValue = base * attribute.multiplier + attribute.addition
end }
IsInGameThread = function() return inGameThread end
local lieClass = object({})
StaticFindObject = function(path)
    if path == lieTimer then return lieClass end
    assert(path == electrified or path == registerHitreact)
    return available and object({})
end
LoadAsset = function(path) assert(path .. "_C" == electrified:match("^(.+):")) end
RegisterHook = function(path, callback, after)
    assert(not hooks[path] and (after == nil) == (path == electrified))
    hooks[path] = { callback = callback, after = after }
    return 1, 2
end
UnregisterHook = function(path, pre, post)
    assert(pre == 1 and post == 2 and hooks[path])
    hooks[path] = nil
end

local function param(value) return { get = function() return value end } end

local function electrocute(target, time, duringEvent)
    local ability = object({ GetAvatarActorFromActorInfo = function() return target end })
    ability[startTime] = time -- the original OnFinish writes the clock
    if duringEvent then duringEvent(param(ability)) end
    return ability[startTime] + 0.6 - time
end

local function lieDown(target, class, cdo)
    local listener = object({ Time = 0.5, GetClass = function() return class end,
        HasAnyFlags = function(_, flags) assert(flags == 0x10); return cdo end })
    local hook = hooks[registerHitreact]
    if hook then hook.callback(param(listener), param(target)) end
    local nativeTimer = listener.Time
    if hook then hook.after(param(listener), param(target)) end
    closeTo(listener.Time, 0.5)
    return nativeTimer
end

local player, enemy = pawn(), pawn()
local normal = enemy.AttributeSetBase
local attributes = player.AttributeSetBase
local session = assert(Control.start(player))
local callback = hooks[electrified].callback
closeTo(7 * 0.8 * 0.9 * attributes[frost].CurrentValue, 7 * 0.8 * 0.9 * 0.8 / 3)
closeTo(7 * (1 + attributes[breakDuration].CurrentValue), 7 * 1.2 / 3)
closeTo(electrocute(player, 10, callback), 0.2)
closeTo(electrocute(player, 15, callback), 0.2)
closeTo(electrocute(enemy, 10, callback), 0.6)
closeTo(lieDown(player, lieClass, false), 0.5 / 3)
closeTo(lieDown(enemy, lieClass, false), 0.5)
closeTo(lieDown(player, object({}), false), 0.5)
closeTo(lieDown(player, lieClass, true), 0.5)
closeTo(normal[frost].BaseValue, 1)
closeTo(normal[breakDuration].BaseValue, 0)
inGameThread = false
closeTo(electrocute(player, 20, callback), 0.6)
inGameThread = true

session:close()
session:close()
assert(not next(hooks))
closeTo(electrocute(player, 30, callback), 0.6)
closeTo(lieDown(player, lieClass, false), 0.5)
closeTo(attributes[frost].CurrentValue, 0.8)
closeTo(attributes[breakDuration].CurrentValue, 0.2)

local resumed = assert(Control.start(player))
closeTo(attributes[frost].CurrentValue, 0.8 / 3)
resumed:close()
closeTo(attributes[frost].BaseValue, 1)

failField = breakDuration
local failed = assert(Control.start(player))
failField = nil
assert(not next(hooks) and #failed.changes == 0)
closeTo(attributes[frost].BaseValue, 1)
closeTo(attributes[breakDuration].BaseValue, 0)

available = false
assert(Control.start(player) and not next(hooks))
closeTo(attributes[frost].BaseValue, 1)

print("PASS player-only frost, electrified, break and lying duration, modifiers, exit, resume and rollback")
