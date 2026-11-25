"""Offline tests for the public config-to-Lua build; no game or save needed."""
import hashlib
import json
from pathlib import Path
import unittest

from arena_scenes import load_scenes
from create_encounter_catalog import make_catalog
from encounter_catalog import DEFAULT_BOSSES, load_and_validate
from generate_runtime_data import BOSS_FIELDS, DEFAULT_OUTPUT, ROOT, TRAINING_MOBS, generated_files


class PublicDataTests(unittest.TestCase):
    def test_minimal_actor_manifest_keeps_order_without_full_cooked_tables(self):
        data = json.loads(DEFAULT_BOSSES.read_text(encoding="utf-8-sig"))
        self.assertEqual(set(data), {"bosses"})
        self.assertEqual(len(data["bosses"]), 75)
        self.assertEqual(len({entry["id"] for entry in data["bosses"]}), 75)
        self.assertTrue(all(set(entry) <= BOSS_FIELDS for entry in data["bosses"]))
        self.assertTrue(all(len(entry["name"]) < 80 for entry in data["bosses"]))

    def test_authored_catalog_regenerates_all_current_configuration(self):
        current = json.loads((ROOT / "config/EncounterCatalog.json").read_text(encoding="utf-8-sig"))
        self.assertEqual(make_catalog(DEFAULT_BOSSES.read_bytes()), current)

    def test_current_catalog_restores_verified_lions_and_preserves_other_combinations(self):
        data = load_and_validate()
        enabled = [entry for entry in data["entries"] if entry["enabled"]]
        self.assertEqual(len(data["entries"]), 92)
        self.assertEqual(len(enabled), 89)
        self.assertEqual([sum(entry["category"] == kind for entry in enabled)
                          for kind in ("duel", "gauntlet", "group")], [67, 15, 7])
        entries = {entry["id"]: entry for entry in data["entries"]}
        for identity in ("BP_Monster_LionDancer", "BP_Monster_LionDancer_P2", "gauntlet_liondancer"):
            self.assertTrue(entries[identity]["enabled"])
            self.assertEqual(entries[identity]["status"], "ready")
            self.assertTrue(entries[identity]["stages"])
        self.assertEqual(entries["group_last_will"]["stages"][0]["members"],
                         ["BP_Monster_WuLengShuang", "BP_Monster_YuBi"])
        self.assertEqual([(entry["id"], index) for entry in enabled for index, stage in enumerate(entry["stages"], 1)
                          if stage.get("cooperation") == "tieyu"],
                         [("gauntlet_muxiaokui", 3), ("group_forest_guardians", 1)])
        self.assertEqual(entries["gauntlet_huashan"]["stages"][1]["members"],
                         ["BP_Monster_HuaShan_JianOu", "BP_Monster_EMei_Sword_Top"])
        self.assertFalse(entries["gauntlet_huashan"]["enabled"])
        self.assertEqual(entries["gauntlet_sangaota"]["name"], "七星鸳鸯阵")
        self.assertEqual([stage["members"] for stage in entries["gauntlet_sangaota"]["stages"]],
                         [["BP_Monster_HuaShan_Blue"], ["BP_Monster_HuaShan_JianOu", "BP_Monster_EMei_Sword_JianZhen"]])
        self.assertEqual(entries["gauntlet_sangaota"]["defaultScene"], "zhengdaodaying_sangaota")
        self.assertEqual([stage["members"] for stage in entries["gauntlet_yucong"]["stages"][:2]],
                         [["BP_Monster_YuCong_FirstTime"], ["BP_Monster_YuCong_P1"]])
        self.assertEqual(entries["gauntlet_miefa"]["stages"][-1],
                         {"sceneId": "scavenger", "members": ["BP_Monster_QiShu_Bing", "BP_Monster_Scavenger"]})
        self.assertNotIn("BP_Monster_EMei_Sword_JianZhen", entries)

    def test_two_scenes_use_only_confirmed_runtime_routes(self):
        scenes = load_scenes()["scenes"]
        self.assertEqual([scene["id"] for scene in scenes], ["night", "lake"])
        self.assertEqual([scene["bellSaveId"] for scene in scenes],
                         ["BrokenBell_TheEnd01", "BrokenBell_LJC_02"])

    def test_training_mob_catalog_contains_the_approved_ordinary_and_unnamed_elite_roster(self):
        rows = json.loads(TRAINING_MOBS.read_text(encoding="utf-8"))["mobs"]
        self.assertEqual(len(rows), 109)
        self.assertEqual(sum(row["rank"] == "ordinary" for row in rows), 85)
        self.assertEqual(sum(row["rank"] == "elite" for row in rows), 24)
        self.assertEqual(len({row["classPath"] for row in rows}), len(rows))
        self.assertTrue(all(row["family"] != "具名精英" for row in rows))

    def test_deterministic_generation_keeps_config_read_only(self):
        inputs = sorted((ROOT / "config").glob("*.json"))
        for path in inputs:
            self.assertNotIn(b"\r", path.read_bytes(), "Public JSON must keep its LF-pinned source hash")
            self.assertFalse(path.read_bytes().startswith(b"\xef\xbb\xbf"), "Public JSON must not add a UTF-8 BOM")
        before = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
        one, two = generated_files(), generated_files()
        self.assertEqual(one, two)
        self.assertEqual(set(one), {"BossCatalog.lua", "GeneratedEncounterCatalog.lua", "GeneratedArenaScenes.lua",
                                    "TrainingMobCatalog.lua"})
        self.assertEqual(before, {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs})
        for name, content in one.items():
            self.assertNotIn(b"\r", content)
            self.assertFalse(content.startswith(b"\xef\xbb\xbf"))
            self.assertEqual((DEFAULT_OUTPUT / name).read_bytes(), content)


if __name__ == "__main__":
    unittest.main()
