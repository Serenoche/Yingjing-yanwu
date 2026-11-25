-- Generated from config/XiguCheckpointSlots.json.
local map = "PBZ_Xigu_WP"
local originalPath = "/Game/Maps/B02/PBZ_Xigu_WP"
local unloadedLayers = {"/Game/DataLayers/T01_FirstStage_WP/202405DemoVersion/MainGameFlow/P1_NPC_YiGeBuLiu_XiGu.P1_NPC_YiGeBuLiu_XiGu", "/Game/DataLayers/T01_FirstStage_WP/202405DemoVersion/MainGameFlow/P2_Monster_YiGeBuLiu_XiGu.P2_Monster_YiGeBuLiu_XiGu"}
local checkpoints = {
    pengmeng = {["checkpointSlot"] = "PBZArenaStockMap06", ["anchor"] = {["X"] = -49105, ["Y"] = 261465, ["Z"] = -24348}, ["rotation"] = {["Pitch"] = 0, ["Yaw"] = -137, ["Roll"] = 0}},
    cangang = {["checkpointSlot"] = "PBZArenaStockMap07", ["anchor"] = {["X"] = -24780.914, ["Y"] = 290333.84, ["Z"] = -26448.943}, ["rotation"] = {["Pitch"] = 0, ["Yaw"] = 19.82, ["Roll"] = 0}},
    ahua = {["checkpointSlot"] = "PBZArenaStockMap08", ["anchor"] = {["X"] = -70170, ["Y"] = 209430, ["Z"] = -19428.4}, ["rotation"] = {["Pitch"] = 0, ["Yaw"] = 133.81, ["Roll"] = 0}},
    waterfall = {["checkpointSlot"] = "PBZArenaStockMap09", ["anchor"] = {["X"] = -58328.73, ["Y"] = 197076.62, ["Z"] = -17469.785}, ["rotation"] = {["Pitch"] = 0, ["Yaw"] = -159.73, ["Roll"] = 0}},
    scavenger = {["checkpointSlot"] = "PBZArenaStockMap10", ["anchor"] = {["X"] = -83681.98, ["Y"] = 205337.7, ["Z"] = 2016816.9}, ["rotation"] = {["Pitch"] = 0, ["Yaw"] = -146.74, ["Roll"] = 0}},
    longzhu = {["checkpointSlot"] = "PBZArenaStockMap11", ["anchor"] = {["X"] = -39094.63, ["Y"] = 233204.89, ["Z"] = 10009134.0}, ["rotation"] = {["Pitch"] = 0, ["Yaw"] = 90.09, ["Roll"] = 0}},
}

return function(scene)
    local checkpoint = assert(checkpoints[scene.id], "溪谷场地缺少原版存点：" .. scene.id)
    scene.map, scene.originalPath = map, originalPath
    scene.checkpointSlot = checkpoint.checkpointSlot
    scene.anchor, scene.rotation = checkpoint.anchor, checkpoint.rotation
    scene.unloadedLayers = unloadedLayers
    return scene
end
