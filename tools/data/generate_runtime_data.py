"""Generate functional Lua manifests from the repository's curated MOD config.

Requires only Python's standard library. This does not extract assets, inspect a
game process, read saves, or supply game textures/animations/audio.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re

from arena_scenes import arena_scenes_lua
from encounter_catalog import DEFAULT_BOSSES, encounter_catalog_lua

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = ROOT / "src/runtime/Scripts"
BOSS_FIELDS = {"id", "name", "classPath", "capsuleRadius", "capsuleHalfHeight", "trainingNote"}


def boss_catalog_lua() -> bytes:
    source = json.loads(DEFAULT_BOSSES.read_text(encoding="utf-8-sig"))
    entries = source["bosses"]
    if len(entries) != 74:
        raise ValueError("The supported interoperability manifest must contain 74 ordered actors")
    used, lines = set(), ["return {"]
    for index, entry in enumerate(entries, 1):
        if set(entry) - BOSS_FIELDS:
            raise ValueError("Boss config must remain a minimal interoperability manifest")
        identity, name, path = (entry[key] for key in ("id", "name", "classPath"))
        if not re.fullmatch(r"[A-Za-z0-9_]+", identity) or identity.casefold() in used:
            raise ValueError("Duplicate or invalid actor identifier")
        if not name or any(ord(char) < 32 for char in name):
            raise ValueError("Invalid short actor display name")
        if not re.fullmatch(r"/[A-Za-z0-9_./-]+_C", path):
            raise ValueError("Invalid engine class reference")
        used.add(identity.casefold())
        fields = ", ".join(f"{key} = {json.dumps(entry[key], ensure_ascii=False)}"
                           for key in ("id", "name", "classPath"))
        fields += f", order = {index}"
        note = entry.get("trainingNote")
        if note:
            if not isinstance(note, str) or len(note) > 120 or any(ord(char) < 32 for char in note):
                raise ValueError("Invalid authored compatibility note")
            fields += ", trainingNote = " + json.dumps(note, ensure_ascii=False)
        for key in ("capsuleRadius", "capsuleHalfHeight"):
            value = entry.get(key)
            if value is not None and (type(value) not in (int, float) or not math.isfinite(value) or not 0 < value <= 1000):
                raise ValueError("Invalid actor capsule dimensions")
        # Preserve the shipped runtime schema. Radius remains available in JSON
        # for tools; the runtime reads the live capsule's radius when spawning.
        if entry.get("capsuleHalfHeight") is not None:
            fields += f', capsuleHalfHeight = {entry["capsuleHalfHeight"]}'
        lines.append(f'    ["{identity}"] = {{ {fields} }},')
    lines.append("}")
    return ("\n".join(lines) + "\n").encode("utf-8")


def generated_files() -> dict[str, bytes]:
    return {"BossCatalog.lua": boss_catalog_lua(),
            "GeneratedEncounterCatalog.lua": encounter_catalog_lua(),
            "GeneratedArenaScenes.lua": arena_scenes_lua()}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--check", action="store_true", help="Compare existing output without writing")
    options = parser.parse_args()
    data = generated_files()
    if options.check:
        for name, content in data.items():
            path = options.output / name
            if not path.is_file() or path.read_bytes() != content:
                raise ValueError("Generated runtime manifest is missing or stale: " + name)
    else:
        options.output.mkdir(parents=True, exist_ok=True)
        for name, content in data.items():
            (options.output / name).write_bytes(content)
    print(json.dumps({"passed": True, "checkOnly": options.check,
                      "files": {name: hashlib.sha256(content).hexdigest() for name, content in data.items()}}))


if __name__ == "__main__":
    main()
