"""Generate the Duanhun battlefields and their stock checkpoints."""

import json
from pathlib import Path

from . import stock_arena_scenes, ximeng_scenes
from .arena_scenes import _vector


ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "config/DuanhunScenes.json"
FIRST_SLOT = ximeng_scenes.FIRST_SLOT + len(ximeng_scenes.SCENE_IDS)
MAP = "PBZ_Duanhun_WP"
MAP_PATH = "/Game/Maps/B08_09_12_13/PBZ_Duanhun_WP"
SCENE_IDS = ("duanhun_lizhe", "duanhun_menghua")


def load_layout():
    layout = json.loads(CONFIG.read_bytes())
    stock_arena_scenes.validate_layout(layout, "Duanhun", MAP, MAP_PATH, SCENE_IDS)
    for scene in layout["scenes"]:
        if (scene["bellSaveId"] != scene["checkpointBell"]["id"] or not scene["phaseReturnPoints"]
                or len(scene["combatBoundary"]) < 3 or scene["combatHeight"]["min"] >= scene["combatHeight"]["max"]):
            raise ValueError(f"Invalid Duanhun bell or combat placement: {scene['id']}")
        for field in ("spawnPoints", "phaseReturnPoints", "combatBoundary"):
            for point in scene[field]:
                _vector(point, ("X", "Y", "Z"))
    return layout


def runtime_lua(layout):
    return stock_arena_scenes.runtime_lua(layout, FIRST_SLOT, CONFIG.name)


def add_maps(bundle, layout):
    return stock_arena_scenes.add_maps(bundle, layout, FIRST_SLOT, "Duanhun")


if __name__ == "__main__":
    path = ROOT / "src/runtime/release_210/checkpoint/DuanhunScenes.lua"
    path.write_bytes(runtime_lua(load_layout()))
