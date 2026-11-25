"""Generate the approved XiMeng arena configurations and stock checkpoints."""

import json
from pathlib import Path

from . import meiguhu_scenes, shengqu_xinchi, stock_arena_scenes


ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "config/XiMengScenes.json"
FIRST_SLOT = meiguhu_scenes.FIRST_SLOT + len(meiguhu_scenes.SCENE_IDS)
MAP = "PBZ_Ximeng_WP"
MAP_PATH = "/Game/Maps/B08_09_12_13/PBZ_Ximeng_WP"
SCENE_IDS = ("ximeng_qiufeng", "ximeng_yuding")


def load_layout():
    layout = json.loads(CONFIG.read_bytes())
    stock_arena_scenes.validate_layout(layout, "XiMeng", MAP, MAP_PATH, SCENE_IDS)
    moved, native = layout["scenes"]
    if not moved.get("moveCheckpointBell") or native.get("moveCheckpointBell"):
        raise ValueError("XiMeng expects a relocated QiuFeng bell and a native YuDing checkpoint")
    for scene in layout["scenes"]:
        if scene["bellSaveId"] != scene["checkpointBell"]["id"] or not scene["phaseReturnPoints"]:
            raise ValueError(f"Invalid XiMeng bell or return point: {scene['id']}")
    return layout


def runtime_lua(layout):
    return stock_arena_scenes.runtime_lua(layout, FIRST_SLOT, CONFIG.name)


def add_maps(bundle, layout):
    (_, moved), (slot, native) = stock_arena_scenes.checkpoints(layout, FIRST_SLOT)
    # QiuFeng's explicit player transform takes precedence over the old BellData
    # transform. YuDing starts from the original Bell_XM_012 checkpoint.
    bundle = stock_arena_scenes.add_maps(bundle, {**layout, "scenes": [moved]}, FIRST_SLOT, "XiMeng")
    return shengqu_xinchi.add_map(bundle, dict(native, map=layout["map"], checkpointSlot=slot))


if __name__ == "__main__":
    path = ROOT / "src/runtime/release_210/checkpoint/XiMengScenes.lua"
    path.write_bytes(runtime_lua(load_layout()))
