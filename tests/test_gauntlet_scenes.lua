local Catalog = require("EncounterCatalog")
local Scenes = require("ArenaScenes")
local Menus = require("ArenaMenuCatalog")

local expected = {
    gauntlet_hookman = "waterfall", gauntlet_chilian = "forest_silk_tree", gauntlet_yucong = "xigu",
    gauntlet_muxiaokui = "lake", gauntlet_guichai_red = "pangzhen_south_gate", gauntlet_changhong = "pangzhen_changhong",
    gauntlet_liondancer = "pangzhen_lion", gauntlet_mboss = "jialongshan_huangxingzi",
    gauntlet_leidang = "leidang", gauntlet_powerman = "duanhun_lizhe", gauntlet_zuoshang = "night",
    gauntlet_miefa = "lujia_yanru", gauntlet_guaimian = "forest_bridge", gauntlet_rocksolid = "lujia_zhuobi",
    gauntlet_sangaota = "zhengdaodaying_sangaota",
}
assert(#Catalog.list("gauntlet") == 15 and not Catalog.resolve("gauntlet_huashan"))
assert(Catalog.retiredCategory("gauntlet_huashan") == "gauntlet")
assert(Catalog.resolve("gauntlet_sangaota").name == "七星鸳鸯阵")
for _, entry in ipairs(Catalog.list("gauntlet")) do
    for _, mode in ipairs({ "practice", "challenge" }) do
        local scene, choice = Menus.resolveScene(entry, "default", mode)
        assert(scene == expected[entry.id] and choice == "default", entry.id .. " default")
        assert(Menus.resolveScene(entry, "night", mode) == "night")
        assert(Menus.defaultSceneOption({ encounterId = entry.id, mode = mode }).previewName == Scenes.get(scene).name)
    end
    for _, stage in ipairs(entry.stages) do
        if stage.sceneId then assert(Scenes.available(stage.sceneId)) end
    end
end
assert(Menus.resolveScene(Catalog.resolve("group_guichai"), "default", "challenge") == "night")
assert(Menus.resolveScene(Catalog.resolve("BP_Monster_HuaShan_RedTroop_BigBro"), "default", "practice") == "meiguhu_ajin")

local stageIds = {
    gauntlet_yucong = { "xigu", "forest_silk_tree_yucong", "forest_silk_tree_yucong" },
    gauntlet_mboss = { "jialongshan_huangxingzi", "jialongshan_huangxingzi_p2" },
    gauntlet_miefa = { "lujia_yanru", "pangzhen_leiting", "meiguhu_guhe", "scavenger" },
    gauntlet_guaimian = { "forest_bridge", "forest_iron_fist", "forest_trap", "forest_silk_tree", "forest_silk_tree" },
    gauntlet_rocksolid = { "lujia_zhuobi", "pangzhen_wuxuan" },
}
for id, route in pairs(stageIds) do
    local stages = Catalog.resolve(id).stages
    assert(#stages == #route)
    for index, scene in ipairs(route) do
        assert(stages[index].sceneId == scene)
        assert(Scenes.forEncounter(id, scene, "challenge", index).id == scene)
    end
end
local ice = Catalog.resolve("gauntlet_miefa").stages[4].members
assert(ice[1].id == "BP_Monster_QiShu_Bing" and ice[2].id == "BP_Monster_Scavenger")

local function object(fields)
    fields.IsValid = function() return true end
    return fields
end

function FName(value) return value end
local function pawnIn(world, hp, count, ultimate)
    local stats = {}
    for _, field in ipairs({ "Health", "Shachi", "SpiritShadow", "UltimateChargeCount", "UltimateCharge" }) do
        stats[field], stats[field .. "_Max"] = { CurrentValue = ultimate or 0 }, { CurrentValue = 300 }
    end
    stats.Health.CurrentValue = hp
    local info = object({ CurrentTime = count, DisplayTime = count, CurrentLevel = 3 })
    local backpack = object({ MedicineInfos = { Find = function(_, id) assert(id == "Duration"); return info end } })
    return { world = object({ GetAddress = function() return world end }),
        backpack = backpack, medicine = info, AttributeSetBase = object(stats) }
end

local startingPawn, destinationPawn = pawnIn(12, 121, 3, 17), pawnIn(13, 300, 7)
package.loaded.SceneArena = { runtimeWorld = function(pawn) return pawn.world end }
package.loaded.EncounterPlayerState = {
    capture = function(pawn)
        local attributes = {}
        for key, value in pairs(pawn.AttributeSetBase) do
            if type(value) == "table" then attributes[key] = value.CurrentValue end
        end
        return { attributes = attributes,
            medicines = { Duration = { CurrentTime = pawn.medicine.CurrentTime, CurrentLevel = pawn.medicine.CurrentLevel } } }
    end,
    teleport = function(pawn, anchor) pawn.moved = anchor.position; return true end,
}
package.loaded.PracticeMode = { setAttributeValue = function(pawn, field, value)
    pawn.AttributeSetBase[field].CurrentValue = value
end }
package.loaded.ChallengeMedicine = { new = function()
    return { refreshDisplay = function(_, pawn) pawn.refreshed = true end }
end }
package.loaded.XiguBossArena = { phaseDestination = function(_, _, scene)
    return { position = scene.phaseReturnPoints[1], rotation = scene.rotation }
end }
local selected, opened
package.loaded.StockCheckpoint = { open = function(_, pawn, scene, result)
    assert(pawn == startingPawn and result.LevelName == scene.map)
    opened = scene.id
end }
function StaticFindObject()
    return object({ GetWorldSubsystem = function(_, pawn) return pawn.backpack end })
end

local Challenge = require("Challenge")
local origin, destination = Scenes.get("jialongshan_huangxingzi"), Scenes.get("jialongshan_huangxingzi_p2")
local ready = false
local run = setmetatable({
    entry = Catalog.resolve("gauntlet_mboss"), scene = origin, sceneId = origin.id, openingScene = origin,
    sceneChoice = "default", stageIndex = 1, playerCycle = 0, startedAt = 11, mode = "challenge",
    cyclePrefix = "PBZArenaIntegratedCycle",
    observer = { close = function(self) self.closed = true end },
    lastSample = { perfectGuards = 2, damageTaken = 120, damageTakenStatus = "recorded" },
    selectCheckpoint = function(slot, cycle)
        assert(cycle == 0 and slot == destination.checkpointSlot)
        selected = slot
        return ready
    end,
    onSceneChange = function(id) assert(id == destination.id) end,
    clearStage = function(self) assert(self.stageIndex == 1); self.cleared = true end,
}, Challenge)
local gameplay = {
    GetGameInstance = function()
        return object({ LoadGame = function(_, slot, result)
            assert(slot == selected and run.phaseTravel)
            run.phaseTravel.departed = true
            result.LevelName, result.GameModeOptions, result.ResultType = destination.map, "", 0
        end })
    end,
    GetPlayerController = function() return {} end,
}

run:travelToPhase(gameplay, startingPawn, destination, 31, 15)
assert(run.stageIndex == 1 and not opened and not run.cleared)
ready = true
run:travelToPhase(gameplay, startingPawn, destination, 31, 16)
assert(run.cleared and opened == destination.id and run.stageIndex == 2 and run.openingScene == origin)
assert(not run:canUseBell() and not run.observer)
assert(run:restorePhaseTravel(gameplay, {}, destinationPawn, 5, 6))
assert(run.phaseTravel.restored and run.startedAt == -15 and destinationPawn.moved)
assert(destinationPawn.AttributeSetBase.Health.CurrentValue == 121)
assert(destinationPawn.AttributeSetBase.UltimateChargeCount.CurrentValue == 17)
assert(destinationPawn.medicine.CurrentTime == 3 and destinationPawn.medicine.DisplayTime == 3 and destinationPawn.refreshed)
local combined = require("GauntletTravel").report(run.phaseTotals, { perfectGuards = 1, damageTaken = 30, damageTakenStatus = "recorded" })
assert(combined.perfectGuards == 3 and combined.damageTaken == 150)

print("Gauntlet defaults, withdrawn encounter and protected phase travel passed")
