"""Generate the MeiGuHu battlefields and their stock checkpoints."""

import json
from pathlib import Path

from . import pangzhen_scenes, stock_arena_scenes
from .arena_scenes import _vector


ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "config/MeiGuHuScenes.json"
FIRST_SLOT = pangzhen_scenes.FIRST_SLOT + len(pangzhen_scenes.SCENE_MAPS)
MAP = "PBZ_Pangzhen_WP"
MAP_PATH = "/Game/Maps/B08_09_10/PBZ_Pangzhen_WP"
SCENE_IDS = ("meiguhu_duyan", "meiguhu_youlong", "meiguhu_ajin", "meiguhu_duanchang",
             "meiguhu_fengxue", "meiguhu_guhe", "meiguhu_huodao")


def load_layout():
    layout = json.loads(CONFIG.read_bytes())
    stock_arena_scenes.validate_layout(layout, "MeiGuHu", MAP, MAP_PATH, SCENE_IDS)
    if not set(layout["recommendedScenes"].values()) <= set(SCENE_IDS):
        raise ValueError("Recommended encounter points outside MeiGuHu")
    for scene in layout["scenes"]:
        if (not scene["bossRecovery"] or not scene["guardTerrainDefeat"]
                or not scene["phaseReturnPoints"] or len(scene["combatBoundary"]) < 3
                or scene["combatHeight"]["min"] >= scene["combatHeight"]["max"]):
            raise ValueError(f"Invalid MeiGuHu placement or protection bounds: {scene['id']}")
        for field in ("spawnPoints", "phaseReturnPoints", "combatBoundary"):
            for point in scene[field]:
                _vector(point, ("X", "Y", "Z"))
    return layout


def runtime_lua(layout):
    targets = layout["recommendedScenes"]
    scenes = [dict(scene, recommendedEncounters=[target for target, scene_id in targets.items() if scene_id == scene["id"]])
              for scene in layout["scenes"]]
    return stock_arena_scenes.runtime_lua({**layout, "scenes": scenes}, FIRST_SLOT, CONFIG.name)


def add_maps(bundle, layout):
    return stock_arena_scenes.add_maps(bundle, layout, FIRST_SLOT, "MeiGuHu")


if __name__ == "__main__":
    path = ROOT / "src/runtime/release_210/checkpoint/MeiGuHuScenes.lua"
    path.write_bytes(runtime_lua(load_layout()))
