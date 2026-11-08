"""Offline tests for the public config-to-Lua build; no game or save needed."""
import hashlib
import json
from pathlib import Path
import unittest

from arena_scenes import load_scenes
from create_encounter_catalog import make_catalog
from encounter_catalog import DEFAULT_BOSSES, load_and_validate
from generate_runtime_data import BOSS_FIELDS, DEFAULT_OUTPUT, ROOT, generated_files


class PublicDataTests(unittest.TestCase):
    def test_minimal_actor_manifest_keeps_order_without_full_cooked_tables(self):
        data = json.loads(DEFAULT_BOSSES.read_text(encoding="utf-8-sig"))
        self.assertEqual(set(data), {"bosses"})
        self.assertEqual(len(data["bosses"]), 74)
        self.assertEqual(len({entry["id"] for entry in data["bosses"]}), 74)
        self.assertTrue(all(set(entry) <= BOSS_FIELDS for entry in data["bosses"]))
        self.assertTrue(all(len(entry["name"]) < 80 for entry in data["bosses"]))

    def test_authored_catalog_regenerates_all_current_configuration(self):
        current = json.loads((ROOT / "config/EncounterCatalog.json").read_text(encoding="utf-8-sig"))
        self.assertEqual(make_catalog(DEFAULT_BOSSES.read_bytes()), current)

    def test_current_catalog_preserves_retired_lions_and_other_combinations(self):
        data = load_and_validate()
        enabled = [entry for entry in data["entries"] if entry["enabled"]]
        self.assertEqual(len(data["entries"]), 90)
        self.assertEqual(len(enabled), 85)
        self.assertEqual([sum(entry["category"] == kind for entry in enabled)
                          for kind in ("duel", "gauntlet", "group")], [65, 14, 6])
        entries = {entry["id"]: entry for entry in data["entries"]}
        for identity in ("BP_Monster_LionDancer", "BP_Monster_LionDancer_P2", "gauntlet_liondancer"):
            self.assertFalse(entries[identity]["enabled"])
            self.assertTrue(entries[identity]["stages"])
        self.assertEqual(entries["group_last_will"]["stages"][0]["members"],
                         ["BP_Monster_WuLengShuang", "BP_Monster_YuBi"])
        self.assertEqual(entries["gauntlet_huashan"]["stages"][1]["members"],
                         ["BP_Monster_HuaShan_JianOu", "BP_Monster_EMei_Sword_Top"])

    def test_two_scenes_use_only_confirmed_runtime_routes(self):
        scenes = load_scenes()["scenes"]
        self.assertEqual([scene["id"] for scene in scenes], ["night", "lake"])
        self.assertEqual([scene["bellSaveId"] for scene in scenes],
                         ["BrokenBell_TheEnd01", "BrokenBell_LJC_02"])

    def test_deterministic_generation_keeps_config_read_only(self):
        inputs = sorted((ROOT / "config").glob("*.json"))
        for path in inputs:
            self.assertNotIn(b"\r", path.read_bytes(), "Public JSON must keep its LF-pinned source hash")
            self.assertFalse(path.read_bytes().startswith(b"\xef\xbb\xbf"), "Public JSON must not add a UTF-8 BOM")
        before = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
        one, two = generated_files(), generated_files()
        self.assertEqual(one, two)
        self.assertEqual(set(one), {"BossCatalog.lua", "GeneratedEncounterCatalog.lua", "GeneratedArenaScenes.lua"})
        self.assertEqual(before, {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs})
        for name, content in one.items():
            self.assertNotIn(b"\r", content)
            self.assertFalse(content.startswith(b"\xef\xbb\xbf"))
            self.assertEqual((DEFAULT_OUTPUT / name).read_bytes(), content)


if __name__ == "__main__":
    unittest.main()
