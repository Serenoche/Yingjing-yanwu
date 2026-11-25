"""Compile the 2.1.0 dual-profile checkpoint component from repository source."""

from hashlib import sha256
import json
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src/save_barrier"
SLOT_CAPACITY = 60
PLAYABLE_SLOTS = 52


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate checkpoint field: {key}")
        result[key] = value
    return result


def read_preset_pin(path: Path) -> str:
    if path.name != "StockArenaPresets.json" or not path.is_file():
        raise ValueError("Expected a staged StockArenaPresets.json")
    content = path.read_bytes()
    layout = json.loads(content, object_pairs_hook=unique_object)
    slots = {f"PBZArenaStockMap{number:02d}" for number in range(1, PLAYABLE_SLOTS + 1)}
    players = {str(cycle) for cycle in range(-1, 7)}
    if (not isinstance(layout, dict) or layout.get("schemaVersion") != 2
            or layout.get("slotCapacity") != SLOT_CAPACITY or not isinstance(layout.get("shared"), dict)
            or not isinstance(layout.get("maps"), dict) or layout["maps"].keys() != slots
            or not isinstance(layout.get("players"), dict) or layout["players"].keys() != players):
        raise ValueError("Expected 52 playable checkpoint slots, 8 reserved slots and 8 player profiles")
    return sha256(content).hexdigest()


def parser_window(source: Path, name: str) -> dict:
    window = re.search(rf'"{name}"\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*(\d+)\s*,\s*pbz_compat::Kind::code\s*,'
                       r'\s*"([a-f0-9]{64})"\s*,\s*nullptr\s*,\s*0', source.read_text(encoding="utf-8"))
    if not window:
        raise ValueError(f"Missing verified parser code window: {name}")
    return {"name": name, "kind": "code", "rva": int(window[1], 16), "bytes": int(window[2]), "sha256": window[3]}


def compile_native(stage: Path, presets: Path, compiler: str, env: dict, *, tests: bool = False) -> dict:
    """Compile the checkpoint DLL and seal it with the preset and parser pins."""
    preset_sha = read_preset_pin(presets)
    reference = parser_window(SOURCE / "checkpoint_parser_profiles.hpp", "StockCheckpointJsonParser")
    legacy = parser_window(SOURCE / "native_legacy_301524.hpp", "JsonObjectFromString")
    stage = stage.resolve()
    stage.mkdir(parents=True, exist_ok=True)
    metadata = stage / "DirectCheckpointBuild.json"
    metadata.unlink(missing_ok=True)
    config = stage / "checkpoint_build_config.hpp"
    config.write_text(
        '#pragma once\nnamespace pbz_checkpoint_build {\n'
        f'inline constexpr const char* preset_sha256 = "{preset_sha}";\n'
        '}\n', encoding="utf-8", newline="\n")
    dll = stage / "PBZSaveBarrier.dll"
    flags = [compiler, "/nologo", "/std:c++17", "/O2", "/W4", "/WX", "/EHsc", "/MT", "/utf-8", "/Brepro",
             "/I" + str(stage), "/I" + str(SOURCE), "/I" + str(ROOT / "src/save_tool")]
    subprocess.run([*flags, "/DPBZ_STOCK_CHECKPOINT", "/LD", str(SOURCE / "barrier.cpp"),
                    "/link", "/Brepro", f"/OUT:{dll}"], cwd=stage, env=env, check=True)
    if tests:
        for name, arguments in (("stock_preset_import_test", []),
                                ("stock_checkpoint_bundle_test", [str(presets.resolve()), preset_sha])):
            executable = stage / f"{name}.exe"
            subprocess.run([*flags, str(SOURCE / "tests" / f"{name}.cpp"), "/link", "/Brepro",
                            f"/OUT:{executable}"], cwd=stage, env=env, check=True)
            subprocess.run([str(executable), *arguments], cwd=stage, env=env, check=True)
        subprocess.run([sys.executable, str(SOURCE / "tests/test_wrong_host.py"), "--dll", str(dll), "--checkpoint"],
                       cwd=stage, env=env, check=True)
    if read_preset_pin(presets) != preset_sha:
        raise ValueError("Checkpoint presets changed during the native build")
    report = {"dllSha256": sha256(dll.read_bytes()).hexdigest(), "presetSha256": preset_sha,
              "referenceParser": reference, "legacySteamParser": legacy}
    metadata.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8", newline="\n")
    return report
