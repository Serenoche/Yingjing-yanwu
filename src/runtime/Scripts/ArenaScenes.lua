local Data = require("GeneratedArenaScenes")
assert(Data.schemaVersion == 1 and Data.defaultScene == "night", "演武场景数据无效")
local Scenes, byId = {}, {}
for _, scene in ipairs(Data.scenes) do
    assert((scene.id == "night" or scene.id == "lake") and not byId[scene.id], "演武场景重复或未知")
    assert(type(scene.map) == "string" and #scene.spawnPoints == 6 and scene.anchor and scene.bell, "演武场景坐标缺失")
    byId[scene.id] = scene
end
assert(byId.night and byId.lake, "演武场景清单不完整")
function Scenes.normalize(id)
    id = id or Data.defaultScene
    if id == "day" or id == "drill" or id == "cliff" then id = "night" end
    assert(byId[id], "未知演武场景")
    return id
end
function Scenes.get(id) return byId[Scenes.normalize(id)] end
function Scenes.list() return { byId.night, byId.lake } end
function Scenes.forEncounter(encounterId, sceneId)
    assert(encounterId ~= "gauntlet_lengtu" and encounterId ~= "BP_Monster_LengTu", "梦差冷荼挑战已撤下")
    return Scenes.get(sceneId)
end
return Scenes
