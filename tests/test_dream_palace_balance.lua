-- Run against a staged runtime with TEST_ROOT set to a disposable directory.
local Balance = require("DreamPalaceBalance")
local Progress = require("BloodyPalaceProgress")
local Roster = require("BloodyPalaceRoster")
local Spawn = require("CombatSpawn")

local function yes() return true end
local function noop() end
local function object(fields)
    fields.IsValid = yes
    return fields
end
local function attribute(base, current)
    return { BaseValue = base, CurrentValue = current or base }
end
local function near(actual, expected) assert(math.abs(actual - expected) < .001, tostring(actual)) end
local function setAttribute(actor, field, value)
    local attr = actor.AttributeSetBase[field]
    attr.CurrentValue = attr.CurrentValue + value - attr.BaseValue
    attr.BaseValue = value
end
package.loaded.PracticeMode = { setAttributeValue = setAttribute }
FName = function(name) return { ToString = function() return name end } end

local adjusted = 0
for floor = 1, Progress.count do
    local raw = Roster.waves[floor]
    local entry = Progress.floor(floor)
    for index, selection in ipairs(raw.members or {}) do
        local member = entry.stages[1].members[index]
        assert(member.enemyCycle == selection.enemyCycle)
        if member.statCycles then
            assert(floor < 10 and member.killReward == "killOrdinary")
            assert(member.statCycles.health == 1 and member.statCycles.attack == 1 and member.statCycles.shachi == 1)
            adjusted = adjusted + 1
        end
    end
end
assert(adjusted == 29 and not Progress.floor(10).stages[1].members[1].statCycles)

local function curve(perCycle)
    return object({ GetValue = function(_, level) return 100 + perCycle * ((level - 1) / 25) end })
end
local aiClass, ai = object({}), object({ StopAI = noop })
local controller = object({ GetComponentByClass = function(_, class) assert(class == aiClass); return ai end })
local native = object({ GetGameCycle = function() return 6 end })
local curveAsset = object({})
local curveLib = object({ EvaluateCurveTableRow = function(_, asset, row, level, result, xy)
    assert(asset == curveAsset and row:ToString() == "IncreaseShachiAttackLevel")
    result.OutResult, xy.OutXY = 0, level * 2
end })
local effect = object({ bFactorInStackCount = true,
    GetClass = function() return { GetFName = function() return FName("GE_Talent_IncreaseAttack_C") end } end,
    Modifiers = { {}, { Attribute = { AttributeName = FName("ShachiAttack") } } },
})
local abilityLib = object({ GetGameplayEffectFromActiveEffectHandle = function() return effect end,
    GetActiveGameplayEffectStackCount = function(_, handle) return handle.Handle end })
function StaticFindObject(path)
    if path:match("SGameAIComponent$") then return aiClass end
    if path:match("PBZBlueprintFunctionLibrary$") then return native end
    if path:match("DataTableFunctionLibrary$") then return curveLib end
    if path:match("CT_Talent_IncreaseAttack$") then return curveAsset end
    if path:match("AbilitySystemBlueprintLibrary$") then return abilityLib end
end

local function enemy()
    local tags = {}
    return object({
        IsActorBeingDestroyed = function() return false end,
        tags = tags,
        AbilitySystemComponent = object({ GetGameplayTagCount = function(_, tag) return tags[tag.TagName:ToString()] or 0 end }),
        AttributeSetBase = object({ Health_Max = attribute(200), Health = attribute(100), Attack = attribute(70),
            Shachi_Max = attribute(1000), Shachi = attribute(500), ShachiAttack = attribute(80), Defense = attribute(20) }),
        ["Actor Config"] = object({ ["Attribute Data"] = { MaxHealth = curve(20), Attack = curve(40),
            MaxShachi = curve(50), ShachiAttack = curve(10) } }),
        ["Init Level"] = noop, GetCombatLevel = function() return 151 end,
        GetController = function() return controller end,
    })
end
local gameplay = { FinishSpawningActor = function(_, actor)
    actor.AttributeSetBase.Level = attribute(actor.Level)
    return actor
end }
local ordinary = Progress.floor(1).stages[1].members[1]
local actor = Spawn.finish(gameplay, nil, enemy(), nil, ordinary.enemyCycle, true, ordinary.statCycles)
local a = actor.AttributeSetBase
assert(a.Level.CurrentValue == 1 and a.Defense.CurrentValue == 20)
near(a.Health_Max.CurrentValue, 240)
near(a.Health.CurrentValue, 120)
near(a.Attack.CurrentValue, 98)
near(a.Shachi_Max.CurrentValue, 1500)
near(a.Shachi.CurrentValue, 750)
near(a.ShachiAttack.CurrentValue, 88)
local late = Spawn.finish(gameplay, nil, enemy(), nil, 2, true, { health = 3, attack = 5 })
assert(late.AttributeSetBase.Shachi_Max.CurrentValue == 1000 and late.AttributeSetBase.ShachiAttack.CurrentValue == 80)

for _, case in ipairs({ {"nightmare", 10, 3}, {"sunk", 15, 4}, {"deep", 20, 5}, {"entry", 20, 5} }) do
    local tier, old, target = table.unpack(case)
    local player = enemy()
    player.AbilitySystemComponent.GetActiveEffectsWithAllTags = function() return { { Handle = old } } end
    player.AbilitySystemComponent.GetGameplayEffectMagnitude = function() return 2 * old end
    player.AttributeSetBase.ShachiAttack = attribute(80, 80 + 2 * old * old)
    local cycle, value, base = Balance.setPlayerShachi(player, tier, old)
    assert(cycle == target and player.AttributeSetBase.Attack.CurrentValue == 70)
    near(value, 80 + 2 * (5 * target)^2)
    setAttribute(player, "ShachiAttack", 80)
    near(Balance.restorePlayerShachi(player, base), 80 + 2 * (5 * target)^2)

    local model = assert(Balance.readPlayerTalentModel(player, old))
    player.AttributeSetBase.ShachiAttack = attribute(80)
    cycle, value = Balance.setPlayerShachi(player, tier, 0, model)
    near(value, 80 + 2 * (5 * target)^2)
end

local boss, named, other = enemy(), enemy(), enemy()
local bossStage = { members = {{ id = "boss" }} }
local groupStage = { regularMobs = true, members = {{ id = "E044" }, { id = "M001" }} }
assert(not Balance.recoveryTargets(bossStage, { boss }, 40, "nightmare"))
assert(not Balance.recoveryTargets(groupStage, { named, other }, 40, "nightmare"))
assert(not Balance.recoveryTargets(bossStage, { boss }, 90))

for _, case in ipairs({
    {"nightmare", .20, 1.00, .18, 1.30},
    {"sunk", .20, 1.10, .18, 1.45},
    {"deep", .20, 1.20, .18, 1.60},
    {"entry", .18, 1.50, .16, 1.90},
}) do
    local tier, bossRate, bossDelay, eliteRate, eliteDelay = table.unpack(case)
    for _, point in ipairs({{41, .5}, {65, 73 / 98}, {89, 97 / 98}, {90, 1}, {101, 1}}) do
        local floor, multiplier = table.unpack(point)
        local targets = Balance.recoveryTargets(bossStage, { boss }, floor, tier)
        local group = Balance.recoveryTargets(groupStage, { named, other }, floor, tier)
        assert(#targets == 1 and targets[1].actor == boss and #group == 1 and group[1].actor == named)
        near(targets[1].rate, bossRate * multiplier)
        near(targets[1].delay, bossDelay)
        near(group[1].rate, eliteRate * multiplier)
        near(group[1].delay, eliteDelay)
    end
end

local targets = Balance.recoveryTargets(bossStage, { boss }, 90, "nightmare")
local group = Balance.recoveryTargets(groupStage, { named, other }, 41, "nightmare")
Balance.recoverShachi(targets, 0)
Balance.recoverShachi(targets, 1)
near(boss.AttributeSetBase.Shachi.CurrentValue, 500)
Balance.recoverShachi(targets, 1.5)
near(boss.AttributeSetBase.Shachi.CurrentValue, 600)
setAttribute(boss, "Shachi", 400)
Balance.recoverShachi(targets, 2)
Balance.recoverShachi(targets, 3)
near(boss.AttributeSetBase.Shachi.CurrentValue, 400)
boss.tags["CharacterState.Stand.Break"] = 1
Balance.recoverShachi(targets, 4)
near(boss.AttributeSetBase.Shachi.CurrentValue, 400)
boss.tags["CharacterState.Stand.Break"] = nil
Balance.recoverShachi(targets, nil)
Balance.recoverShachi(targets, 30)
near(boss.AttributeSetBase.Shachi.CurrentValue, 400)
Balance.recoverShachi(targets, 40)
near(boss.AttributeSetBase.Shachi.CurrentValue, 1000)
setAttribute(boss, "Shachi", 0)
Balance.recoverShachi(targets, 41)
Balance.recoverShachi(targets, 50)
near(boss.AttributeSetBase.Shachi.CurrentValue, 0)
Balance.recoverShachi(group, 0)
Balance.recoverShachi(group, 1.3)
near(named.AttributeSetBase.Shachi.CurrentValue, 500)
Balance.recoverShachi(group, 2.3)
near(named.AttributeSetBase.Shachi.CurrentValue, 590)
near(other.AttributeSetBase.Shachi.CurrentValue, 500)

local deathHook, unregistered
RegisterHook = function(_, callback) deathHook = callback; return 1, 2 end
UnregisterHook = function(_, before, after) assert(before == 1 and after == 2); unregistered = true end
local function parameter(value) return { get = function() return value end } end
local path = TEST_ROOT .. "/lethal-health.tsv"
local gear = { mainWeapons = { "tang", false }, shadowWeapons = { false, false },
    accessories = { false, false, false, false, false, false }, medicines = { false, false } }
Progress.save(path, 20, 1000, gear, { HeiShi8 = 10 }, false)
Progress.save(path, 40, 2000, gear, { HeiShi8 = 10 }, false)
local palace = { arenaEntered = true, state = "combat", checkpointFloor = 40, path = path }
local player = enemy()
player.GetAddress = function() return 10 end
local stop = assert(Progress.watchDeath(palace, player, error))
local foreign = enemy()
foreign.GetAddress = function() return 20 end
foreign.AttributeSetBase.Health.CurrentValue = 0
deathHook(parameter(foreign), parameter(0), parameter(10))
assert(Progress.load(path).cleared == 40)
deathHook(parameter(player), parameter(0), parameter(10))
assert(Progress.load(path).cleared == 40)
player.AttributeSetBase.Health.CurrentValue = 0
deathHook(parameter(player), parameter(0), parameter(10))
assert(palace.playerDied and not palace.checkpointFloor and not Progress.load(path))
stop()
assert(unregistered)
assert(not Progress.watchDeath({ tier = { assist = true } }, player, error))
print("PASS early mob curves, four ShachiAttack profiles, floor-scaled recovery and lethal-health checkpoint handling")
