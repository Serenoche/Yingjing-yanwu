local Data = require("GeneratedArenaScenes")
local Encounters = require("EncounterCatalog")
local menuData = require("ArenaMenuData")
local Terrain = require("ArenaTerrain")
local sceneDisplay = menuData.scenes
assert(Data.schemaVersion == 1 and Data.defaultScene == "night", "演武场景数据无效")
local Scenes, byId = {}, {}
for _, scene in ipairs(Data.scenes) do
    assert((scene.id == "night" or scene.id == "lake") and not byId[scene.id], "演武场景重复或未知")
    assert(type(scene.map) == "string" and #scene.spawnPoints == 6 and scene.anchor and scene.bell, "演武场景坐标缺失")
    byId[scene.id] = scene
end
assert(byId.night and byId.lake, "演武场景清单不完整")

-- The first YuCong fight is a self-contained part of the stock Xigu world.
-- The first spawn point is the position of its authored encounter spawner.
byId.xigu = {
    id = "xigu", name = "三面封印地", map = "PBZ_Xigu_WP", presetSceneId = "lake",
    runtimeModule = "XiguArena",
    bellSaveId = "BrokenBell_TheEnd01",
    anchor = { X = 5722.8965, Y = 292748.62, Z = 1998494.0 },
    rotation = { Pitch = 0, Yaw = -113.59123, Roll = 0 },
    bellForwardOffset = 150,
    portalPoint = { X = 3203.68, Y = 287458.64, Z = 1999306.1 },
    -- The first three slots are over 30m from these in-arena return points.
    -- Slots 5 and 6 provide reserve placements when the preferred slots are obstructed.
    phaseSpawnClearance = 2000,
    phaseReturnPoints = {
        { X = 3523.15, Y = 289520.81, Z = 1999306.1 },
        { X = 3340.32, Y = 289559.21, Z = 1999306.1 },
        { X = 3599.42, Y = 289537.60, Z = 1999306.1 },
    },
    chiLianUltimate = {
        -- Halfway between the world-space spline midpoints of FogDoor14 and FogDoor15.
        center = { X = 3203.68, Y = 287458.64 },
        -- Stock marker order, with corners aligned to the axis between the gates.
        snakes = {
            { X = 3889.19, Y = 285944.51 },
            { X = 4745.59, Y = 288079.13 },
            { X = 2518.17, Y = 288972.77 },
            { X = 1661.76, Y = 286838.15 },
        },
    },
    spawnTrace = { top = 1999617.6, bottom = 1998817.6 },
    spawnPoints = {
        { X = 2718.9087, Y = 286374.38, Z = 1999317.6 },
        { X = 3618.9087, Y = 286374.38 },
        { X = 1818.9087, Y = 286374.38 },
        { X = 2718.9087, Y = 288174.38 },
        { X = 4518.9087, Y = 287274.38 },
        { X = 1818.9087, Y = 288174.38 },
    },
}

byId.meiguhu = {
    id = "meiguhu", name = "梅谷乐坊", map = "PBZ_Pangzhen_WP", presetSceneId = "lake",
    runtimeModule = "MeiGuHuArena",
    bellSaveId = "Bell_MGH_004",
    bellLocation = { X = -127147.79, Y = 73264.97, Z = 750.7722 },
    anchor = { X = -127268.59, Y = 73244.38, Z = 881.0736 },
    rotation = { Pitch = 0, Yaw = -2.12028, Roll = 0 },
    -- Inside the authored fog spline, with four boss slots at least 14m away.
    phaseReturnPoints = {
        { X = -125950, Y = 72960, Z = 745 },
        { X = -125900, Y = 72750, Z = 745 },
        { X = -125950, Y = 73150, Z = 745 },
    },
    chiLianUltimate = {
        center = { X = -124850, Y = 73000 },
        snakes = {
            { X = -125610, Y = 72170 }, { X = -124090, Y = 72170 },
            { X = -124090, Y = 73830 }, { X = -125610, Y = 73830 },
        },
    },
    spawnClearance = 1400,
    spawnTrace = { top = 1020, bottom = 520, worldStaticFallback = true },
    spawnPoints = {
        { X = -124130.28, Y = 73061.55, Z = 739.5012 },
        { X = -124130, Y = 72050 },
        { X = -124290, Y = 73815 },
        { X = -124950, Y = 71625 },
        { X = -125050, Y = 72400 },
        { X = -125050, Y = 73700 },
    },
}

byId.night.checkpointSlot = "PBZArenaStockMap01"
byId.night.originalPath = "/Game/Maps/B08_09_12_13/PBZ_Duanhun_WP"
byId.night.checkpointBell = { id = byId.night.bellSaveId, class = "BP_BrokenBell_C",
    name = "BP_BrokenBell_C_UAID_E89C25A751207AE802_1375855971" }
byId.night.runtimeModule = "StockBellArena"
byId.night.spawnTrace.worldStaticFallback = true

byId.lake.checkpointSlot = "PBZArenaStockMap02"
byId.lake.originalPath = "/Game/Maps/B04_05/PBZ_Zhengdaodaying_WP"
byId.lake.checkpointBell = { id = byId.lake.bellSaveId, class = byId.lake.bell.class, name = byId.lake.bell.actorName }
byId.lake.runtimeModule = "StockBellArena"
byId.lake.spawnTrace.worldStaticFallback = true
-- Lake phase return points are inside the fog ring, closer to the spawn slots than the entry bell.
byId.lake.phaseSpawnClearance = 1200

byId.xigu.checkpointSlot = "PBZArenaStockMap03"
byId.xigu.originalPath = "/Game/Maps/B02/PBZ_Xigu_WP"
byId.xigu.checkpointActors = { BP_AISpawner_C_UAID_60CF848099092CEE02_1842879658 = true, BP_MobDomain_C_UAID_60CF848099092CEE02_1842807652 = true }
byId.xigu.checkpointCreatesBell = true
byId.xigu.spawnTrace.worldStaticFallback = true

local palacePlacement = require("DreamPalacePlacement")
local dreamPalace = setmetatable({
    bellSaveId = "PBZDreamPalaceBell",
    bellName = "浊梦之间",
    bellMetadataId = byId.xigu.bellSaveId,
    palacePlacement = palacePlacement,
    phaseReturnPoints = palacePlacement.returns,
    bossRecovery = false,
}, { __index = byId.xigu })

byId.meiguhu.checkpointSlot = "PBZArenaStockMap04"
byId.meiguhu.originalPath = "/Game/Maps/B08_09_10/PBZ_Pangzhen_WP"
byId.meiguhu.checkpointBell = { id = byId.meiguhu.bellSaveId, name = require("MeiGuHuStandaloneLayout").bell }

byId.leidang = require("ShengQuXinChiScene")
byId.pengmeng = require("PengMengScene")
local independent = { byId.meiguhu, byId.leidang, byId.pengmeng }
local recommendedScenes = {}
for target, id in pairs(menuData.bossScenes) do recommendedScenes[target] = id end
for _, region in ipairs({ require("XiguBossScenes"), require("BloodForestScenes"), require("LuJiaCunScenes"),
    require("PangzhenScenes"), require("MeiGuHuScenes"), require("XiMengScenes"), require("DuanhunScenes"),
    require("ZhengDaoDaYingScenes"), (require("JialongshanScenes")) }) do
    for _, scene in ipairs(region) do
        assert(not byId[scene.id], "演武场地重复：" .. scene.id)
        byId[scene.id] = scene
        independent[#independent + 1] = scene
        for _, encounter in ipairs(scene.recommendedEncounters or {}) do recommendedScenes[encounter] = scene.id end
    end
end

for id, scene in pairs(byId) do
    if not menuData.exclusiveScenes[id] then Terrain.protect(scene, not menuData.soloScenes[id]) end
    local display = sceneDisplay[id]
    if display then
        scene.name = display.label or scene.name
        scene.bellName = display.bellName or scene.bellName
    end
end

function Scenes.normalize(id)
    id = id or Data.defaultScene
    if id == "day" or id == "drill" or id == "cliff" then id = "night" end
    assert(byId[id], "未知演武场景")
    return id
end
function Scenes.get(id, mode)
    id = Scenes.normalize(id)
    if id == "xigu" and mode == "bloody-palace" then return dreamPalace end
    return byId[id]
end
function Scenes.list(includeIndependent)
    if includeIndependent == false then return { byId.night, byId.lake, byId.xigu } end
    return { byId.night, byId.lake, byId.xigu, table.unpack(independent) }
end
function Scenes.available(id) return byId[id] ~= nil end
function Scenes.preset(scene) return scene and (byId[scene.presetSceneId] or scene) end
function Scenes.recommendedForEncounter(encounterId)
    local encounter = recommendedScenes[encounterId] and Encounters.resolve(encounterId)
    if encounter and encounter.selectable and encounter.category == "duel" then return recommendedScenes[encounterId] end
end

function Scenes.forEncounter(encounterId, sceneId, mode, stageIndex)
    assert(encounterId ~= "gauntlet_lengtu" and encounterId ~= "BP_Monster_LengTu", "梦差冷荼挑战已撤下")
    local id = Scenes.normalize(sceneId)
    local encounter = Encounters.resolve(encounterId)
    local preferred = encounter and (encounter.category == "duel" and recommendedScenes[encounter.id]
        or encounter.defaultScene)
    if menuData.allowsScene(id, mode, encounter) or menuData.allowsAuthoredScene(id, mode, encounter, preferred, stageIndex) then
        return Scenes.get(id, mode)
    end
    return Scenes.get(Data.defaultScene, mode)
end
return Scenes
