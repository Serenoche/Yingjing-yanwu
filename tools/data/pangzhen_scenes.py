"""Generate the nine Pangzhen battlefields and their stock checkpoints."""

import json
from pathlib import Path

from . import lujia_village_scenes, stock_arena_scenes
from .arena_scenes import _vector


ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "config/PangzhenScenes.json"
FIRST_SLOT = lujia_village_scenes.FIRST_SLOT + len(lujia_village_scenes.SCENE_IDS)
TOWN = "PBZ_Pangzhen_WP"
HOUJIE = "PBZ_Houjie_WP"
MAPS = {
    TOWN: "/Game/Maps/B08_09_10/PBZ_Pangzhen_WP",
    HOUJIE: "/Game/Maps/B09/PBZ_Houjie_WP",
}
SCENE_MAPS = {
    "pangzhen_south_gate": TOWN, "pangzhen_zhanqi": TOWN,
    "pangzhen_wuxuan": HOUJIE, "pangzhen_guwanyue": HOUJIE, "pangzhen_youlong": HOUJIE,
    "pangzhen_changhong": HOUJIE, "pangzhen_lion": HOUJIE, "pangzhen_gouhun": TOWN,
    "pangzhen_leiting": HOUJIE,
}


def load_layout():
    layout = json.loads(CONFIG.read_bytes())
    scenes = layout["scenes"]
    if layout["schemaVersion"] != 1 or tuple(scene["id"] for scene in scenes) != tuple(SCENE_MAPS):
        raise ValueError("Unexpected Pangzhen scene layout")
    targets = layout["recommendedScenes"]
    if not set(targets.values()) <= SCENE_MAPS.keys():
        raise ValueError("Recommended encounter points outside Pangzhen")
    for scene in scenes:
        scene_id = scene["id"]
        map_name = SCENE_MAPS[scene_id]
        path = MAPS[map_name]
        if (scene["map"] != map_name or scene["originalPath"] != path
                or scene["bossRecovery"] is not True or scene["guardTerrainDefeat"] is not True
                or not scene["phaseReturnPoints"] or len(scene["combatBoundary"]) < 3
                or scene["combatHeight"]["min"] >= scene["combatHeight"]["max"]):
            raise ValueError(f"Invalid Pangzhen placement or protection bounds: {scene_id}")
        stock_arena_scenes.validate_layout(
            {"schemaVersion": 1, "map": map_name, "originalPath": path, "scenes": [scene]},
            "Pangzhen", map_name, path, (scene_id,),
        )
        for field in ("spawnPoints", "phaseReturnPoints", "combatBoundary"):
            for point in scene[field]:
                _vector(point, ("X", "Y", "Z"))
    return layout


def runtime_lua(layout):
    targets = layout["recommendedScenes"]
    scenes = [dict(scene, recommendedEncounters=[target for target, scene_id in targets.items() if scene_id == scene["id"]])
              for scene in layout["scenes"]]
    return stock_arena_scenes.runtime_lua({"scenes": scenes}, FIRST_SLOT, CONFIG.name)


def add_maps(bundle, layout):
    return stock_arena_scenes.add_maps(bundle, layout, FIRST_SLOT, "Pangzhen")


if __name__ == "__main__":
    path = ROOT / "src/runtime/release_210/checkpoint/PangzhenScenes.lua"
    path.write_bytes(runtime_lua(load_layout()))
