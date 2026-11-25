"""Generate the Jialongshan arenas and their stock checkpoints."""

import json
from pathlib import Path

from . import stock_arena_scenes, zhengdaodaying_scenes
from .arena_scenes import _vector


ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "config/JialongshanScenes.json"
FIRST_SLOT = zhengdaodaying_scenes.FIRST_SLOT + len(zhengdaodaying_scenes.SCENE_IDS)
MAP = "PBZ_DengDingShanDao_WP"
MAP_PATH = "/Game/Maps/DengDingShanDao/PBZ_DengDingShanDao_WP"
SCENE_IDS = (
    "jialongshan_tiesha", "jialongshan_bifeng", "jialongshan_yanyan",
    "jialongshan_jademask", "jialongshan_huangxingzi", "jialongshan_huangxingzi_p2",
)


def load_layout():
    layout = json.loads(CONFIG.read_bytes())
    stock_arena_scenes.validate_layout(layout, "Jialongshan", MAP, MAP_PATH, SCENE_IDS)
    for scene in layout["scenes"]:
        bell = scene.get("checkpointBell")
        if bool(bell) == bool(scene.get("checkpointCreatesBell")) or bell and bell["id"] != scene["bellSaveId"]:
            raise ValueError(f"Invalid Jialongshan bell: {scene['id']}")
        if (not scene["phaseReturnPoints"] or len(scene["combatBoundary"]) < 3
                or scene["combatHeight"]["min"] >= scene["combatHeight"]["max"]):
            raise ValueError(f"Invalid Jialongshan combat placement: {scene['id']}")
        for field in ("spawnPoints", "phaseReturnPoints", "combatBoundary"):
            for point in scene[field]:
                _vector(point, ("X", "Y", "Z"))
        for field in ("bellGround", "entryGround"):
            _vector(scene[field], ("X", "Y", "Z"))
        door = scene.get("openAnimatedDoor")
        doors = (*scene["openStoryDoors"], *scene.get("fixedFogDoors", ()))
        if door:
            doors += (door,)
        if any(not scene["checkpointActors"].get(name) for name in doors):
            raise ValueError(f"Untracked Jialongshan door: {scene['id']}")
    return layout


def runtime_lua(layout):
    return stock_arena_scenes.runtime_lua(layout, FIRST_SLOT, CONFIG.name)


def add_maps(bundle, layout):
    return stock_arena_scenes.add_maps(bundle, layout, FIRST_SLOT, "Jialongshan")


if __name__ == "__main__":
    path = ROOT / "src/runtime/release_210/checkpoint/JialongshanScenes.lua"
    path.write_bytes(runtime_lua(load_layout()))
