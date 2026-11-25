"""Generate the five Blood Forest scenes and their stock checkpoint entries."""

import json
from pathlib import Path

from . import stock_arena_scenes
from .xigu_checkpoints import BASE_SLOT_COUNT, SCENE_IDS as XIGU_SCENES


ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "config/BloodForestScenes.json"
SCENE_IDS = ("forest_bridge", "forest_trap", "forest_iron_fist", "forest_silk_tree", "forest_silk_tree_yucong")
FIRST_SLOT = BASE_SLOT_COUNT + len(XIGU_SCENES) + 1


def load_layout():
    layout = json.loads(CONFIG.read_bytes())
    stock_arena_scenes.validate_layout(layout, "Blood Forest", "PBZ_Fujizhilin_WP",
                                       "/Game/Maps/B03/PBZ_Fujizhilin_WP", SCENE_IDS)
    return layout


def checkpoints(layout):
    return stock_arena_scenes.checkpoints(layout, FIRST_SLOT)


def runtime_lua(layout):
    return stock_arena_scenes.runtime_lua(layout, FIRST_SLOT, CONFIG.name)


def add_maps(bundle, layout):
    return stock_arena_scenes.add_maps(bundle, layout, FIRST_SLOT, "Blood Forest")


if __name__ == "__main__":
    target = ROOT / "src/runtime/release_210/checkpoint/BloodForestScenes.lua"
    target.write_bytes(runtime_lua(load_layout()))
