-- Run with either staged 2.1.0 script directory on package.path.
local Scenes = require("ArenaScenes")
local Data = require("ArenaMenuData")
local Menus = require("ArenaMenuCatalog")
local Encounters = require("EncounterCatalog")
local Target = require("ChallengeTarget")
local Flow = require("ArenaSetupFlow")

local function options(mode, id)
    local result = {}
    for _, group in ipairs(Menus.scenes(mode, id)) do
        for _, entry in ipairs(group.entries) do
            assert(not result[entry.id], "场地重复：" .. entry.id)
            result[entry.id] = entry.scope
        end
    end
    return result
end

local function settings(mode, boss, scene)
    return { mode = mode, bossId = boss, sceneChoice = scene, playerCycle = 0, enemyCycle = 0, skillLevel = 0 }
end

local generic = "BP_Monster_MobMan_Elite_Sword"
local interactive = "BP_Monster_ChiLian_P2"
local loadedScenes = Scenes.list(true, "challenge")
local native = #loadedScenes == 52
local counts = { general = 0, solo = 0, exclusive = 0 }
local scopes = { general = "通用场地", solo = "SOLO通用场地", exclusive = "BOSS 专属场地" }

for _, scene in ipairs(loadedScenes) do
    local id = scene.id
    local owners, solo = Data.exclusiveScenes[id], Data.soloScenes[id]
    assert(not (owners and solo), id)
    local scope = owners and "exclusive" or solo and "solo" or "general"
    counts[scope] = counts[scope] + 1
    for _, mode in ipairs({ "practice", "challenge" }) do
        assert(options(mode, generic)[id] == (not owners and scopes[scope] or nil), id)
        assert(options(mode, interactive)[id] == (scope == "general" and scopes.general or nil), id)
        if owners then
            for owner in pairs(owners) do
                assert(options(mode, owner)[id] == scopes.exclusive, owner .. " · " .. id)
                assert(Scenes.forEncounter(owner, id, mode).id == id)
            end
            assert(Scenes.forEncounter(generic, id, mode).id ~= id)
            local old = Target.form(settings(mode, generic, id)):getSettings()
            assert(old.sceneId ~= id and old.sceneChoice == "default", id)
        end
        for _, category in ipairs({ "group", "custom_group", "custom_gauntlet" }) do
            local entry = Encounters.list(category)[1]
            if entry then
                assert(options(mode, entry.id)[id] == (scope == "general" and scopes.general or nil), id)
            end
        end
    end
    if Scenes.available(id, "training") then
        assert(options("training", generic)[id] == (scope == "general" and scopes.general or nil), id)
    end
end

if native then
    assert(counts.general == 13 and counts.solo == 27 and counts.exclusive == 12)
    assert(Data.scenes.pangzhen_changhong.size == "大型")

    local addedExclusive = {
        zhengdaodaying_yubi = "BP_Monster_YuBi",
        meiguhu_huodao = "BP_Monster_HuoDaoDuiZhang",
        jialongshan_tiesha = "BP_Monster_MobMan_Elite",
        meiguhu_guhe = "BP_Monster_QiShu_Du",
    }
    local Custom = require("CustomChallenges")
    for id, owner in pairs(addedExclusive) do
        assert(options("challenge", owner)[id] == scopes.exclusive)
        local custom = assert(Custom.encode("custom_gauntlet", { owner, generic }))
        assert(not options("challenge", custom)[id])
    end
    assert(options("challenge", "gauntlet_leidang").leidang == scopes.exclusive)
    assert(options("practice", "gauntlet_guichai_red").pangzhen_south_gate == scopes.exclusive)
    local sangaota = Encounters.resolve("gauntlet_sangaota")
    local sangaotaChoices = options("challenge", sangaota.id)
    assert(not sangaotaChoices.zhengdaodaying_sangaota and not sangaotaChoices.cangang)
    assert(Menus.resolveScene(sangaota, "default", "challenge") == "zhengdaodaying_sangaota")
    local master = Encounters.resolve("BP_Monster_HuaShan_Blue")
    assert(not options("challenge", master.id).zhengdaodaying_sangaota)
    assert(Menus.resolveScene(master, "default", "challenge") == "zhengdaodaying_sangaota")

    local guaimian = "gauntlet_guaimian"
    local route = Encounters.resolve(guaimian)
    assert(Menus.resolveScene(route, "default", "challenge") == "forest_bridge")
    assert(not options("challenge", guaimian).forest_bridge and not options("challenge", guaimian).forest_trap)
    assert(Scenes.forEncounter(guaimian, "forest_trap", "challenge", 3).id == "forest_trap")
    assert(Scenes.forEncounter(guaimian, "forest_trap", "challenge", 2).id == "night")
    assert(not options("challenge", "gauntlet_miefa").meiguhu_guhe)
    assert(Scenes.forEncounter("gauntlet_miefa", "meiguhu_guhe", "challenge", 3).id == "meiguhu_guhe")

    local rocksolid = Encounters.resolve("gauntlet_rocksolid")
    assert(Menus.resolveScene(rocksolid, "default", "challenge") == "lujia_zhuobi")
    local choices = options("challenge", rocksolid.id)
    assert(choices.lujia_zhuobi == scopes.solo and choices.pangzhen_wuxuan == scopes.solo)
    assert(not choices.forest_trap and not choices.lujia_danghui)
    assert(Scenes.forEncounter(rocksolid.id, "pangzhen_wuxuan", "challenge", 2).id == "pangzhen_wuxuan")
    assert(Scenes.forEncounter(rocksolid.id, "pangzhen_wuxuan", "challenge", 1).id == "pangzhen_wuxuan")

    local lion = "BP_Monster_LionDancer_P2"
    local preview = Menus.defaultSceneOption({ mode = "challenge", encounterId = lion })
    assert(preview.scope == scopes.solo and preview.previewName == Scenes.get("pangzhen_lion").name)
    assert(not options("challenge", lion).pangzhen_lion)
    local legacy = Target.form(settings("challenge", lion, "pangzhen_lion")):getSettings()
    assert(legacy.sceneId == "pangzhen_lion" and legacy.sceneChoice == "default")
    assert(options("challenge", "BP_Monster_LionDancer").pangzhen_lion == scopes.solo)
    assert(Scenes.forEncounter(nil, "xigu", "bloody-palace").bellName == "浊梦之间")
end

local function testSceneSwitch(id, allowedBoss, restrictedBoss, scope)
    local flow = Flow.new(settings("challenge", allowedBoss, "default"))
    flow:open("scene")
    assert(flow.picker:select(id))
    assert(flow.picker:current().scope == scope)
    flow:choose()
    assert(flow:settings().sceneChoice == id)
    flow.model:chooseTarget(restrictedBoss)
    assert(flow:settings().sceneChoice == "default" and flow:settings().sceneId ~= id)
    flow:open("scene")
    assert(not flow.picker:select(id) and flow.picker:select("night"))
    flow:choose()
    flow.model:chooseTarget(allowedBoss)
    assert(flow:settings().sceneChoice == "night")
    assert(not pcall(function() Target.form(settings("challenge", restrictedBoss)):chooseScene(id) end))
    assert(Menus.resolveScene(nil, id, "training") ~= id)

    local cycle = Target.form(settings("challenge", allowedBoss, "default"))
    local found = false
    for _ = 1, #loadedScenes + 1 do
        cycle.screenRows[7].change(1)
        found = found or cycle:getSettings().sceneChoice == id
    end
    assert(found)
    cycle:chooseTarget(restrictedBoss)
    for _ = 1, #loadedScenes + 1 do
        cycle.screenRows[7].change(1)
        assert(cycle:getSettings().sceneId ~= id)
    end
end

for _, mode in ipairs({ "practice", "challenge" }) do
    local stale = Flow.new(settings(mode, generic, "removed_scene")):settings()
    assert(stale.sceneChoice == "default")
    if native then
        local flow = Flow.new(settings(mode, generic, "cangang"))
        flow:open("target")
        flow.draft.screenRows[3].change(2)
        flow:showTargets()
        flow:openTargets(nil, "group_guichai")
        flow:choose()
        flow:choose()
        assert(flow:settings().sceneChoice == "default" and flow:settings().sceneId == "night")
        flow:open("scene")
        assert(flow.picker:current().id == "default")
        assert(not flow.picker:select("cangang") and not flow.picker:select("pangzhen_gouhun"))
        assert(flow.picker:select("night"))
        flow:back()

        flow:open("target")
        flow.draft.screenRows[3].change(-2)
        flow:choose()
        flow:open("scene")
        assert(flow.picker:select("cangang"))
    end
end

if native then testSceneSwitch("cangang", generic, interactive, scopes.solo) end
if Scenes.available("meiguhu", "challenge") then
    testSceneSwitch("meiguhu", generic, interactive, scopes.solo)
end

print(("Scene access passed for %d loaded arenas."):format(#loadedScenes))
