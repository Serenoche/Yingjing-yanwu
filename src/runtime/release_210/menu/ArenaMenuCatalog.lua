local Encounters = require("EncounterCatalog")
local Music = require("BattleMusic")
local MusicData = require("BattleMusicData")
local Scenes = require("ArenaScenes")
local Data = require("ArenaMenuData")
local Menu = {}

local BELL_ART = "/Game/PBZContent/UI/InGame/SaveLoad/BellTexture/"
local MUSIC_ART = "/Game/PBZContent/UI/Menu/BonusCollection/Art/"
local REGION_ORDER = {
    "序章", "悲泣溪谷", "血色森林", "陆家村地区", "正道大营", "庞镇地区",
    "梅谷湖", "枷笼山", "戏梦山庄", "断魂山", "跨地区", "其他原声", "其他地区",
}
local REGIONS = {
    XiGu = "悲泣溪谷", FuJiZhiLin = "血色森林", LuJiaCun = "陆家村地区",
    ZhengDaoDaYing = "正道大营", PangZhen = "庞镇地区", VS2 = "枷笼山",
    XiMengShanZhuang = "戏梦山庄", DuanHun = "断魂山", Prologue = "序章",
}
-- Original encounter locations for bosses with shared or reused Wwise groups.
local BOSS_REGION = {
    BP_Monster_YuCong_FirstTime = "悲泣溪谷",
    BP_Monster_YanQianSui = "梅谷湖",
    BP_Monster_DuYanBoss = "梅谷湖",
    BP_Monster_Maddoctor_Elite = "庞镇地区",
    BP_Monster_QiShu_Du = "庞镇地区",
    BP_Monster_YouLong_SecondBrother = "庞镇地区",
    BP_Monster_YouLong_Harpoon = "梅谷湖",
    BP_Monster_HuaShan_RedTroop_BigBro = "梅谷湖",
    BP_Monster_GuiChai_Cyan_ShuangYue = "梅谷湖",
    BP_Monster_HuoDaoDuiZhang = "梅谷湖",
}

local function path(folder, name) return folder .. name .. "." .. name end

local function area(id)
    local music = MusicData.bosses[id]
    return BOSS_REGION[id] or (music and REGIONS[music[1]]) or "其他地区"
end

local function encounterRegion(entry)
    local result
    for _, stage in ipairs(entry.stages) do
        for _, boss in ipairs(stage.members) do
            local region = area(boss.id)
            if result and result ~= region then return "跨地区" end
            result = region
        end
    end
    return result or "其他地区"
end

function Menu.targets(model, member)
    local category = model.settings.category
    local byRegion = category ~= "gauntlet" and category ~= "group"
    local entries = {}
    for _, option in ipairs(model:targetChoices(member)) do
        local encounter = assert(Encounters.resolve(option.id))
        entries[#entries + 1] = { id = option.id, name = option.name,
            region = byRegion and encounterRegion(encounter) or nil, encounter = encounter }
    end
    if not byRegion then return { { entries = entries } } end
    return Menu.group(entries)
end

local function sceneOption(scene)
    local ref = Data.scenes[scene.id]
    return { id = scene.id, name = ref and ref.label or scene.name,
        region = ref and ref.region or "其他地区", image = ref and ref.image and path(BELL_ART, ref.image),
        scope = Data.exclusiveScenes[scene.id] and "BOSS 专属场地"
            or Data.soloScenes[scene.id] and "SOLO通用场地" or "通用场地" }
end

local function canChooseScene(id, mode, encounter)
    return Scenes.available(id, mode) and Data.allowsScene(id, mode, encounter)
end

function Menu.resolveScene(encounter, choice, mode)
    local encounterId = encounter and encounter.id
    local id
    if choice ~= nil and choice ~= "default" then
        local known, candidate = pcall(Scenes.normalize, choice)
        if known and canChooseScene(candidate, mode, encounter) then id = candidate end
    end
    local automatic = not id
    id = id or Scenes.normalize()
    if automatic and (mode == "practice" or mode == "challenge")
        and encounter and encounter.selectable and (encounter.category == "duel" or encounter.category == "gauntlet") then
        local preferred = encounter.defaultScene
        if encounter.category == "duel" then
            preferred = Scenes.recommendedForEncounter and Scenes.recommendedForEncounter(encounter.id)
                or Data.bossScenes[encounter.id]
        end
        for _, scene in ipairs(Scenes.list(true, mode)) do
            if scene.id == preferred then id = preferred; break end
        end
    end
    if not Scenes.available(id, mode) then id = Scenes.available("lake", mode) and "lake" or "night" end
    id = Scenes.forEncounter(encounterId, id, mode).id
    return id, automatic and "default" or id
end

function Menu.sceneLabel(settings)
    local name = sceneOption(Scenes.get(settings.sceneId, settings.mode)).name
    return settings.sceneChoice == "default" and ("默认（" .. name .. "）") or name
end

function Menu.defaultSceneOption(settings)
    local encounter = settings.mode ~= "training" and Encounters.resolve(settings.encounterId) or nil
    local id = Menu.resolveScene(encounter, "default", settings.mode)
    local preview = sceneOption(Scenes.get(id, settings.mode))
    return { id = "default", name = "默认", previewName = preview.name, image = preview.image, scope = preview.scope }
end

function Menu.sceneChoices(mode, encounterId)
    local choices = {}
    local encounter = Encounters.resolve(encounterId)
    for _, scene in ipairs(Scenes.list(true, mode)) do
        if canChooseScene(scene.id, mode, encounter) then
            choices[#choices + 1] = scene
        end
    end
    return choices
end

function Menu.scenes(mode, encounterId)
    local entries = {}
    for _, scene in ipairs(Menu.sceneChoices(mode, encounterId)) do
        entries[#entries + 1] = sceneOption(scene)
    end
    return Menu.group(entries)
end

function Menu.music()
    local entries = {}
    for _, track in ipairs(MusicData.tracks) do
        local id = track[1]
        local ref = Data.music[id]
        entries[#entries + 1] = { id = id, name = Music.label(id),
            region = ref and ref.region or "其他原声", image = ref and path(MUSIC_ART, ref.cover),
            boss = ref and ref.boss, seconds = ref and ref.seconds }
    end
    return Menu.group(entries)
end

function Menu.group(entries)
    local byName, result = {}, {}
    for _, item in ipairs(entries) do
        local group = byName[item.region]
        if not group then
            group = { name = item.region, entries = {} }
            byName[item.region] = group
        end
        group.entries[#group.entries + 1] = item
    end
    for _, name in ipairs(REGION_ORDER) do
        if byName[name] then result[#result + 1] = byName[name]; byName[name] = nil end
    end
    assert(next(byName) == nil and #result > 0, "演武地区清单不完整")
    return result
end

return Menu
