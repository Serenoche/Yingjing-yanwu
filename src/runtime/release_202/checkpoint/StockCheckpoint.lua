local Events = require("MeiGuHuOriginalEvents")

local Checkpoint = {}

local function text(value)
    return type(value) == "string" and value or (value and value:ToString() or "")
end

function Checkpoint.open(gameplay, context, scene, result)
    local map = text(result.LevelName)
    assert(scene.originalPath and result.ResultType == 0
        and (map == scene.map or map == scene.originalPath),
        "演武存点与原版地图不符：" .. scene.id)
    local options = text(result.GameModeOptions)
    assert(options == "", "演武原版存点使用了未知游戏模式")
    Events.arm(context, "blocked", scene.checkpointBell, scene)
    local ok, failure = pcall(function()
        print(("[PBZStockCheckpoint] OPEN scene=%s map=%s\n"):format(scene.id, map))
        gameplay:OpenLevel(context, FName(map), true, options)
    end)
    if not ok then Events.reset(); error(failure, 0) end
end

return Checkpoint
