"""Generate runtime scenes and checkpoint presets for a region on a stock map."""

from .arena_scenes import _lua, _vector
from .xigu_checkpoints import STOCK_CAPACITY, TEMPLATE_SLOT, stock_preset


def validate_layout(layout, region, map_name, original_path, scene_ids):
    if (layout["schemaVersion"] != 1 or layout["map"] != map_name
            or layout["originalPath"] != original_path
            or tuple(scene["id"] for scene in layout["scenes"]) != scene_ids):
        raise ValueError(f"Unexpected {region} scene layout")
    for scene in layout["scenes"]:
        _vector(scene["anchor"], ("X", "Y", "Z"))
        _vector(scene["rotation"], ("Pitch", "Yaw", "Roll"))
        count = len(scene["spawnPoints"])
        if count < 6 or any(type(index) is not int or not 1 <= index <= count
                            for index in scene["bossSpawnIndex"].values()):
            raise ValueError(f"Invalid {region} spawn slots: {scene['id']}")
        if set(scene["loadedLayers"]).intersection(scene["unloadedLayers"]):
            raise ValueError(f"Conflicting {region} data layers: {scene['id']}")


def checkpoints(layout, first_slot):
    for number, scene in enumerate(layout["scenes"], first_slot):
        yield f"PBZArenaStockMap{number:02d}", scene


def runtime_lua(layout, first_slot, source):
    lines = [f"-- Generated from config/{source}.", "return {"]
    for slot, data in checkpoints(layout, first_slot):
        scene = dict(data, map=data.get("map", layout.get("map")),
                     originalPath=data.get("originalPath", layout.get("originalPath")),
                     runtimeModule="XiguBossArena", checkpointSlot=slot)
        lines.append("    {")
        lines.extend(f"        [{_lua(key)}] = {_lua(value)}," for key, value in scene.items())
        lines.append("    },")
    return ("\n".join([*lines, "}", ""])).encode("utf-8")


def add_maps(bundle, layout, first_slot, region):
    maps = dict(bundle["maps"])
    if len(maps) != first_slot - 1 or len(maps) + len(layout["scenes"]) > STOCK_CAPACITY:
        raise ValueError(f"Unexpected stock checkpoint capacity before {region}")
    for slot, scene in checkpoints(layout, first_slot):
        if slot in maps:
            raise ValueError(f"{region} checkpoint slot already exists: {slot}")
        maps[slot] = stock_preset(maps[TEMPLATE_SLOT], scene, scene.get("map", layout.get("map")),
                                  scene["loadedLayers"], scene["unloadedLayers"])
    return {**bundle, "maps": maps}
