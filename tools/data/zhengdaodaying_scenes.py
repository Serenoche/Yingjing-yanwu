"""Generate the accepted Zheng Dao Da Ying battlefields and checkpoints."""

import json
from pathlib import Path

from . import duanhun_scenes, stock_arena_scenes
from .arena_scenes import _vector


ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "config/ZhengDaoDaYingScenes.json"
FIRST_SLOT = duanhun_scenes.FIRST_SLOT + len(duanhun_scenes.SCENE_IDS)
MAP = "PBZ_Zhengdaodaying_WP"
MAP_PATH = "/Game/Maps/B04_05/PBZ_Zhengdaodaying_WP"
SCENE_IDS = ("zhengdaodaying_wanjun", "zhengdaodaying_sangaota", "zhengdaodaying_wulengshuang", "zhengdaodaying_yubi")


def load_layout():
    layout = json.loads(CONFIG.read_bytes())
    stock_arena_scenes.validate_layout(layout, "Zheng Dao Da Ying", MAP, MAP_PATH, SCENE_IDS)
    for scene in layout["scenes"]:
        checkpoint = scene.get("checkpointBell")
        if bool(checkpoint) == bool(scene.get("checkpointCreatesBell")):
            raise ValueError(f"Expected one bell source: {scene['id']}")
        if checkpoint and checkpoint["id"] != scene["bellSaveId"]:
            raise ValueError(f"Checkpoint bell ID mismatch: {scene['id']}")
        _vector(scene["reviveCameraRotation"], ("Pitch", "Yaw", "Roll"))
        if (not scene["phaseReturnPoints"] or len(scene["combatBoundary"]) < 3
                or scene["combatHeight"]["min"] >= scene["combatHeight"]["max"]):
            raise ValueError(f"Invalid Zheng Dao Da Ying combat placement: {scene['id']}")
        for field in ("spawnPoints", "phaseReturnPoints", "combatBoundary"):
            for point in scene[field]:
                _vector(point, ("X", "Y", "Z"))
    return layout


def runtime_lua(layout):
    return stock_arena_scenes.runtime_lua(layout, FIRST_SLOT, CONFIG.name)


def add_maps(bundle, layout):
    staged = stock_arena_scenes.add_maps(bundle, layout, FIRST_SLOT, "Zheng Dao Da Ying")
    for slot, scene in stock_arena_scenes.checkpoints(layout, FIRST_SLOT):
        staged["maps"][slot]["PBZGameSystem"]["ReviveCameraRotation"] = scene["reviveCameraRotation"]
    return staged


if __name__ == "__main__":
    path = ROOT / "src/runtime/release_210/checkpoint/ZhengDaoDaYingScenes.lua"
    path.write_bytes(runtime_lua(load_layout()))
