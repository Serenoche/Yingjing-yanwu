"""Generate the six LuJiaCun battlefields and their stock checkpoints."""

import json
from pathlib import Path

from . import blood_forest_scenes, stock_arena_scenes
from .arena_scenes import _vector


ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "config/LuJiaCunScenes.json"
SCENE_IDS = ("lujia_zhuobi", "lujia_bihai", "lujia_biyuan", "lujia_yuzan", "lujia_yanru", "lujia_danghui")
FIRST_SLOT = blood_forest_scenes.FIRST_SLOT + len(blood_forest_scenes.SCENE_IDS)


def load_layout():
    layout = json.loads(CONFIG.read_bytes())
    stock_arena_scenes.validate_layout(layout, "LuJiaCun", "PBZ_Zhengdaodaying_WP",
                                       "/Game/Maps/B04_05/PBZ_Zhengdaodaying_WP", SCENE_IDS)
    for scene in layout["scenes"]:
        if (scene["bossRecovery"] is not True or not scene["bossSpawnIndex"]
                or not scene["phaseReturnPoints"] or len(scene["combatBoundary"]) < 3
                or not scene["combatHeight"]["min"] < scene["combatHeight"]["max"]):
            raise ValueError(f"Missing LuJiaCun boss placement or recovery bounds: {scene['id']}")
        for field in ("spawnPoints", "phaseReturnPoints", "combatBoundary"):
            for point in scene[field]:
                _vector(point, ("X", "Y", "Z"))
    return layout


def runtime_lua(layout):
    return stock_arena_scenes.runtime_lua(layout, FIRST_SLOT, CONFIG.name)


def add_maps(bundle, layout):
    return stock_arena_scenes.add_maps(bundle, layout, FIRST_SLOT, "LuJiaCun")


if __name__ == "__main__":
    target = ROOT / "src/runtime/release_210/checkpoint/LuJiaCunScenes.lua"
    target.write_bytes(runtime_lua(load_layout()))
