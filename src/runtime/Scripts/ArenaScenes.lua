local Data = require("GeneratedArenaScenes")
assert(Data.schemaVersion == 1 and Data.defaultScene == "night", "演武场景数据无效")
local Scenes, byId = {}, {}
for _, scene in ipairs(Data.scenes) do
    assert((scene.id == "night" or scene.id == "lake") and not byId[scene.id], "演武场景重复或未知")
    assert(type(scene.map) == "string" and #scene.spawnPoints == 6 and scene.anchor and scene.bell, "演武场景坐标缺失")
    byId[scene.id] = scene
end
assert(byId.night and byId.lake, "演武场景清单不完整")

-- Practice and Challenge use the standalone map with the original private save.
local lakeUpper = {}
for key, value in pairs(byId.lake) do lakeUpper[key] = value end
lakeUpper.map = "PBZ_LakeUpperArena"
lakeUpper.runtimeModule = "LakeUpperArena"
lakeUpper.standaloneLake = true
lakeUpper.presetSceneId = "lake"
lakeUpper.mapContainer = "zzz_PBZLakeUpperArenaTestR8_P"

-- The first YuCong fight is a self-contained part of the stock Xigu world.
-- The first spawn point is the position of its authored encounter spawner.
byId.xigu = {
    id = "xigu", name = "三面封印地", map = "PBZ_Xigu_WP", presetSceneId = "lake",
    runtimeModule = "XiguArena",
    bellSaveId = "BrokenBell_TheEnd01",
    anchor = { X = 5722.8965, Y = 292748.62, Z = 1998494.0 },
    rotation = { Pitch = 0, Yaw = -113.59123, Roll = 0 },
    bellForwardOffset = 150,
    -- On the arena side of FogDoor14, within the original combat volume.
    -- All three boss slots still have more than 30m of starting clearance.
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
    id = "meiguhu", name = "梅谷乐坊", map = "PBZ_MeiGuHuArena", presetSceneId = "lake",
    runtimeModule = "MeiGuHuArena",
    mapContainer = "zzz_PBZMeiGuHuArenaTestR62_P",
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

local source = debug.getinfo(1, "S").source
local installed = source:sub(1, 1) == "@" and source:sub(2):gsub("\\", "/"):lower():match(
    "^(%a:/.*)/platform/[^/]+/ue4ss/mods/pbztestarena/scripts/arenascenes%.lua$")
local function hasMap(container)
    local content = installed and installed .. "/ProjectPBZ/Content"
    if not content and StaticFindObject then
        local system = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        if system and system:IsValid() then
            local ok, path = pcall(function() return system:GetProjectContentDirectory() end)
            if ok then content = type(path) == "string" and path or path and path:ToString() end
        end
    end
    if type(content) ~= "string" or content == "" then return false end
    local base = content:gsub("[/\\]+$", "") .. "/Paks/~mods/" .. container
    for _, suffix in ipairs({ ".pak", ".utoc", ".ucas" }) do
        local file = io.open(base .. suffix, "rb")
        if not file then return false end
        file:close()
    end
    return true
end

function Scenes.normalize(id)
    id = id or Data.defaultScene
    if id == "day" or id == "drill" or id == "cliff" then id = "night" end
    assert(byId[id], "未知演武场景")
    return id
end
function Scenes.get(id, mode)
    id = Scenes.normalize(id)
    if id == "lake" and (mode == "practice" or mode == "challenge") then return lakeUpper end
    return byId[id]
end
function Scenes.list(includeIndependent, mode)
    local choices = { byId.night }
    if Scenes.available("lake", mode) then choices[#choices + 1] = Scenes.get("lake", mode) end
    choices[#choices + 1] = byId.xigu
    if includeIndependent ~= false and Scenes.available("meiguhu", mode) then choices[#choices + 1] = byId.meiguhu end
    return choices
end
function Scenes.available(id, mode)
    local container = Scenes.get(id, mode).mapContainer
    return not container or hasMap(container)
end
function Scenes.preset(scene) return scene and (byId[scene.presetSceneId] or scene) end
function Scenes.forEncounter(encounterId, sceneId, mode)
    assert(encounterId ~= "gauntlet_lengtu" and encounterId ~= "BP_Monster_LengTu", "梦差冷荼挑战已撤下")
    return Scenes.get(sceneId, mode)
end
return Scenes
