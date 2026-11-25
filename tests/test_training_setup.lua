-- Run with the staged 2.1.0 checkpoint Scripts directory on package.path.
local Flow = require("ArenaSetupFlow")
local Training = require("TrainingTarget")
local Mobs = require("TrainingMobCatalog")
local Dummy = require("TrainingDummy")
local Custom = require("PlayerCustom")

assert(Dummy.resetKey == "Delete")
assert(Custom.weaponCap(-1) == 1)
assert(Custom.weaponCap(0, { values = {} }) == 30)
assert(Custom.weaponCap(6, { values = { weapon = 42 } }) == 42)
assert(Custom.weaponCap(6, { values = { weapon = 0 } }) == 1)

local flow = Flow.new({ mode = "training", playerCycle = 6, skillLevel = 30, enemyCycle = 0,
    sceneChoice = "cangang", trainingMobId = "retired-mob" })
local initial = flow:settings()
assert(initial.mode == "training" and initial.trainingMobId == nil)
assert(initial.sceneChoice == "default")

flow:open("target")
local seen = {}
for _, group in ipairs(flow.picker.groups) do
    assert(#group.entries <= 10)
    for _, mob in ipairs(group.entries) do
        assert(not seen[mob.id], mob.id)
        seen[mob.id] = true
    end
end
assert(flow.trainingCount == #Mobs + 2 and flow.picker:current().name == "金面人")
assert(seen[Dummy.target.id] and flow.picker.groups[1].entries[2] == Dummy.target)
for _, mob in ipairs(Mobs) do assert(seen[mob.id], mob.id) end
assert(flow.picker:changeRegion(1) and flow:choiceFocus())

local function setFilter(index, label)
    local field = flow.trainingFilters.rows[index]
    local start = field.value()
    while field.value() ~= label do
        field.change(1)
        assert(field.value() ~= start, "Missing filter: " .. label)
    end
    flow:refreshTrainingTargets()
end

setFilter(1, "普通怪")
setFilter(2, "远程")
setFilter(3, "山匪")
assert(flow.trainingCount > 0 and flow.picker:select("M010"))
for _, group in ipairs(flow.picker.groups) do
    for _, mob in ipairs(group.entries) do
        assert(mob.rank == "ordinary" and mob.family == "山匪")
        assert(mob.role == "远程" or mob.role == "投掷")
    end
end
flow:chooseTrainingTarget("M010")
setFilter(2, "飞行")
assert(flow.trainingCount == 0 and flow:choiceFocus() == nil)
assert(flow.draft.settings.trainingMobId == "M010")
assert(not pcall(flow.chooseTrainingTarget, flow, "M010"))
assert(flow:back() and flow:settings().trainingMobId == nil)

flow:open("target")
flow:chooseTrainingTarget("M010")
flow.draft.screenRows[5].change(4)
flow.draft.screenRows[6].change(-1)
flow:choose()
assert(flow:settings().trainingMobId == "M010" and flow:settings().enemyCycle == 4 and flow:settings().difficultyMode == 2)
flow:open("target")
assert(flow.picker:current().id == "M010")
flow:chooseTrainingTarget(Training.option(nil).id)
flow:back()
assert(flow:settings().trainingMobId == "M010")

flow:open("character")
flow:openCustom("attributes")
local attributes = Custom.section("attributes").fields
Custom.set(flow.draft.settings, attributes[1], 2500)
flow:back()
assert(flow.draft.settings.customPlayer.values.health == nil)
flow:openCustom("attributes")
Custom.set(flow.draft.settings, attributes[1], 2500)
Custom.set(flow.draft.settings, attributes[5], 1700)
flow:choose()
flow:openCustom("collection")
Custom.setSkill(flow.draft.settings, 12)
flow:choose()
flow:openCustom("gear")
Custom.set(flow.draft.settings, Custom.section("gear").fields[1], 42)
flow:choose()
flow.draft.screenRows[1].change(-1)
assert(flow.draft.settings.customPlayer.values.health == nil)
flow.draft.screenRows[1].change(1)
flow:choose()

flow:open("scene")
assert(not flow.picker:select("cangang") and flow.picker:select("xigu"))
flow:choose()
local chosen = assert(flow:enter())
assert(chosen.mode == "training" and chosen.sceneId == "xigu" and chosen.sceneChoice == "xigu")
assert(chosen.trainingMobId == "M010" and chosen.enemyCycle == 4 and chosen.difficultyMode == 2)
assert(chosen.skillLevel == 12 and chosen.customPlayer.values.health == 2500)
assert(chosen.customPlayer.values.infliction == 1700 and chosen.customPlayer.values.weapon == 42)
assert(Custom.checkpoint(chosen.customPlayer) == "custom1,42,-1,-1,4")

flow:open("target")
flow:chooseTrainingTarget(Training.option(nil).id)
flow:choose()
assert(flow:enter().trainingMobId == nil)

flow:open("target")
setFilter(1, "木桩")
assert(flow.trainingCount == 1 and flow.picker:current() == Dummy.target)
flow:chooseTrainingTarget(Dummy.target.id)
flow:choose()
assert(flow:enter().trainingMobId == Dummy.target.id)
flow:open("target")
assert(flow.picker:current() == Dummy.target and Training.option(Dummy.target.id) == Dummy.target)

print("Training setup passed: filters, paging, cancellation, player profiles and scene handoff.")
