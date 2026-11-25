"""Build the XiGu checkpoint rows and their corresponding Lua arrival settings."""

from copy import deepcopy
import json
from pathlib import Path

from .arena_scenes import _lua


CONFIG = Path(__file__).resolve().parents[2] / "config/XiguCheckpointSlots.json"
STOCK_CAPACITY = 60
BASE_SLOT_COUNT = 5
BASE_SLOTS = {f"PBZArenaStockMap{number:02d}" for number in range(1, BASE_SLOT_COUNT + 1)}
TEMPLATE_SLOT = "PBZArenaStockMap03"
SCENE_IDS = ("pengmeng", "cangang", "ahua", "waterfall", "scavenger", "longzhu")


def load_layout():
    layout = json.loads(CONFIG.read_bytes())
    if (layout["schemaVersion"] != 1 or layout["map"] != "PBZ_Xigu_WP"
            or tuple(scene["id"] for scene in layout["scenes"]) != SCENE_IDS):
        raise ValueError("Unexpected XiGu checkpoint layout")
    return layout


def checkpoints(layout):
    for number, scene in enumerate(layout["scenes"], BASE_SLOT_COUNT + 1):
        yield f"PBZArenaStockMap{number:02d}", scene


def runtime_lua(layout):
    header = ("-- Generated from config/XiguCheckpointSlots.json.\n"
              "local map = " + _lua(layout["map"]) + "\n"
              "local originalPath = " + _lua(layout["originalPath"]) + "\n"
              "local unloadedLayers = " + _lua(layout["unloadedLayers"]) + "\n"
              "local checkpoints = {\n")
    rows = []
    for slot, scene in checkpoints(layout):
        placement = {"checkpointSlot": slot, "anchor": scene["anchor"], "rotation": scene["rotation"]}
        rows.append(f"    {scene['id']} = {_lua(placement)},\n")
    return (header + "".join(rows) + """}

return function(scene)
    local checkpoint = assert(checkpoints[scene.id], "溪谷场地缺少原版存点：" .. scene.id)
    scene.map, scene.originalPath = map, originalPath
    scene.checkpointSlot = checkpoint.checkpointSlot
    scene.anchor, scene.rotation = checkpoint.anchor, checkpoint.rotation
    scene.unloadedLayers = unloadedLayers
    return scene
end
""").encode("utf-8")


def stock_preset(template, scene, map_name, loaded, unloaded, reveal=()):
    preset = deepcopy(template)
    transform = {"Location": scene["anchor"], "Rotation": scene["rotation"]}
    preset["PBZGameSystem"].update(CurrentLevelName=map_name, PlayerTransform=transform,
                                   ReviveTransform=transform, ReviveCameraRotation=scene["rotation"])
    flow = preset["EventPipeline"]
    for field in ("ComponentInfoJson", "ComponentsOwnerActorInfo", "GlobalTags",
                  "ExecuteNodeGuid", "SaveInfoJson", "FlowTags"):
        flow[field] = type(flow[field])()
    flow["LoadedDataLayer"] = {map_name: loaded}
    flow["UnLoadedDataLayer"] = {map_name: unloaded}
    preset["LevelActorManager"] = {}
    manager = preset["BellManager"]
    for field in ("ActivateBellIDs", "ActivateCraneBellIDs", "DisableTeleportBellIDs",
                  "RecentlyInteractedBellIDByMap", "RecentlyInteractedAtByMap"):
        manager[field] = type(manager[field])()
    manager["NeedUnLockBigMapMaskWidgetNames"] = list(reveal)
    return preset


def add_maps(bundle, layout):
    if (bundle["schemaVersion"] != 2 or bundle["slotCapacity"] != STOCK_CAPACITY
            or set(bundle["maps"]) != BASE_SLOTS or len(bundle["players"]) != 8):
        raise ValueError("Expected the five-map stock checkpoint bundle")
    template = bundle["maps"][TEMPLATE_SLOT]
    game = template["PBZGameSystem"]
    if (template["BellSaveID"] != "" or game["LastSaveActorID"] != "None"
            or game["CurrentLevelName"] != layout["map"]):
        raise ValueError("Expected the XiGu checkpoint with an explicit player transform")

    maps = dict(bundle["maps"])
    for slot, scene in checkpoints(layout):
        reveal = ("XiGu",) if scene.get("revealMap") else ()
        maps[slot] = stock_preset(template, scene, layout["map"], [], layout["unloadedLayers"], reveal)
    return {**bundle, "maps": maps}


if __name__ == "__main__":
    target = CONFIG.parent.parent / "src/runtime/release_210/checkpoint/XiguCheckpoint.lua"
    target.write_bytes(runtime_lua(load_layout()))
