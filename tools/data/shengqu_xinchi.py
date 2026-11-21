"""Generate the Shengqu Xinchi runtime scene and extend the stock checkpoint bundle."""

from copy import deepcopy
import json
from pathlib import Path

from arena_scenes import _lua


CONFIG = Path(__file__).resolve().parents[2] / "config/ShengQuXinChi.json"
TEMPLATE_SLOT = "PBZArenaStockMap04"
SAVE_ONLY_FIELDS = {"reviveCameraYaw", "unloadedLayers"}


def load_scene():
    scene = json.loads(CONFIG.read_bytes())
    if scene["id"] != "leidang" or scene["bellSaveId"] != scene["checkpointBell"]["id"]:
        raise ValueError("Shengqu Xinchi scene and native bell are inconsistent")
    return scene


def runtime_lua(scene):
    runtime = {name: value for name, value in scene.items() if name not in SAVE_ONLY_FIELDS}
    return ("-- Generated from config/ShengQuXinChi.json.\nreturn " + _lua(runtime) + "\n").encode("utf-8")


def add_map(bundle, scene):
    slot = scene["checkpointSlot"]
    maps = bundle["maps"]
    if (bundle["schemaVersion"] != 2 or bundle["slotCapacity"] != 60
            or TEMPLATE_SLOT not in maps or slot in maps or len(maps) >= bundle["slotCapacity"]):
        raise ValueError("The stock checkpoint bundle has no expected base map or free slot")

    # Reuse the shape of an ordinary native bell checkpoint. Story progress
    # and player inventory come from the existing shared/player fragments.
    preset = deepcopy(maps[TEMPLATE_SLOT])
    map_id, bell_id = scene["map"], scene["bellSaveId"]
    transform = {"Location": scene["anchor"], "Rotation": scene["rotation"]}
    preset["PBZGameSystem"].update(
        CurrentLevelName=map_id, LastSaveActorID=bell_id, PlayerTransform=transform, ReviveTransform=transform,
        ReviveCameraRotation={"Pitch": 0, "Yaw": scene["reviveCameraYaw"], "Roll": 0})
    preset["BellSaveID"] = bell_id
    preset["BellManager"].update(
        ActivateBellIDs=[bell_id], SaveBellID=bell_id, RecentlyInteractedBellID=bell_id,
        RecentlyInteractedBellIDByMap={"XiMeng": bell_id}, RecentlyInteractedAtByMap={},
        NeedUnLockBigMapMaskWidgetNames=["XiMeng"])
    flow = preset["EventPipeline"]
    flow["LoadedDataLayer"] = {map_id: []}
    flow["UnLoadedDataLayer"] = {map_id: scene["unloadedLayers"]}
    for field in ("ComponentInfoJson", "ComponentsOwnerActorInfo"):
        flow[field] = {name: value for name, value in flow[field].items() if name.startswith(map_id + "-")}
    for field in ("GlobalTags", "ExecuteNodeGuid", "FlowTags"):
        flow[field] = [] if isinstance(flow[field], list) else {}
    flow["SaveInfoJson"] = {}
    preset["LevelActorManager"] = {}
    return {**bundle, "maps": {**maps, slot: preset}}
