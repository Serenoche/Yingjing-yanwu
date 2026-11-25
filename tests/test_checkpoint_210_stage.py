"""Check the native checkpoint release sources and presets staged for 2.1.0."""

from copy import deepcopy
from hashlib import sha256
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = "ue4ss/Mods/PBZTestArena/Scripts"
BOSS_FIXES = {"BloodyPalaceMechanics.lua", "Challenge.lua", "ChallengeMenu.lua", "ChiLianArena.lua",
              "LengTuArena.lua", "LionArena.lua", "SceneArena.lua", "main.lua"}
FOREST_MODULES = ("BloodForestScenes.lua", "ForestSnakeMarkers.lua", "PhantomRoadFog.lua")
sys.path.insert(0, str(ROOT / "tools"))
import stage_checkpoint_210


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value), encoding="utf-8")


class Checkpoint210StageTests(unittest.TestCase):
    def test_release_stages_only_the_native_checkpoint_runtime(self):
        slots = {f"PBZArenaStockMap{number:02d}": {} for number in range(1, 6)}
        slots["PBZArenaStockMap03"] = {
            "BellSaveID": "",
            "PBZGameSystem": {"LastSaveActorID": "None", "CurrentLevelName": "PBZ_Xigu_WP"},
            "EventPipeline": dict.fromkeys(("ComponentInfoJson", "ComponentsOwnerActorInfo", "GlobalTags",
                                           "ExecuteNodeGuid", "SaveInfoJson", "FlowTags"), {}),
            "BellManager": dict.fromkeys(("ActivateBellIDs", "ActivateCraneBellIDs", "DisableTeleportBellIDs",
                                         "RecentlyInteractedBellIDByMap", "RecentlyInteractedAtByMap"), {}),
        }
        slots["PBZArenaStockMap04"] = deepcopy(slots["PBZArenaStockMap03"])
        presets = {"schemaVersion": 2, "slotCapacity": 60, "maps": slots, "players": [{}] * 8}
        with TemporaryDirectory() as tmp:
            base = Path(tmp) / "base"
            base_runtime = base / "NativeEnemyRuntime"
            output = Path(tmp) / "stage"
            write_json(base / "PackageManifest.json", {"version": "2.0.3", "channel": "release"})
            write_json(base_runtime / "CheckpointPayload" / SCRIPTS / "StockArenaPresets.json", presets)
            profile = json.loads(stage_checkpoint_210.PROFILE.read_bytes())
            runtime = json.loads((ROOT / profile["runtimeManifest"]).read_bytes())
            checkpoint = runtime["flows"]["checkpoint"]
            self.assertTrue(BOSS_FIXES <= checkpoint.keys())
            backgrounds = Path(tmp) / "menu-backgrounds"
            backgrounds.mkdir()
            for name in stage_checkpoint_210.MENU_BACKGROUNDS:
                content = f"local menu background fixture for {name}".encode("ascii")
                (backgrounds / name).write_bytes(content)
                runtime["menuBackgrounds"][name] = sha256(content).hexdigest()
            profile["runtimeManifest"] = str(Path(tmp) / "RuntimeManifest.json")
            write_json(Path(profile["runtimeManifest"]), runtime)
            profile_path = Path(tmp) / "ReleaseProfile.json"
            write_json(profile_path, profile)
            with patch.object(stage_checkpoint_210, "PROFILE", profile_path):
                first_background = backgrounds / stage_checkpoint_210.MENU_BACKGROUNDS[0]
                original = first_background.read_bytes()
                first_background.write_bytes(b"wrong image")
                with self.assertRaisesRegex(ValueError, "Menu background checksum mismatch"):
                    stage_checkpoint_210.stage(None, output, base_release=base, menu_backgrounds=backgrounds)
                self.assertFalse(output.exists())
                first_background.write_bytes(original)
                report = stage_checkpoint_210.stage(None, output, base_release=base, menu_backgrounds=backgrounds)
            self.assertEqual({path.name for path in output.iterdir()}, {"Scripts", "CheckpointPayload.ps1"})
            self.assertEqual(report["luaModules"], 185)
            self.assertEqual(report["menuBackgrounds"], 4)
            self.assertEqual(report["playable"], 52)
            self.assertEqual(report["reserved"], 8)
            scripts = output / "Scripts"
            self.assertEqual({path.name for path in scripts.glob("*.lua")}, checkpoint.keys())
            for name, entry in checkpoint.items():
                with self.subTest(module=name):
                    self.assertEqual(sha256((scripts / name).read_bytes()).hexdigest(), entry["sha256"])
            self.assertTrue((output / "CheckpointPayload.ps1").is_file())
            script = (output / "CheckpointPayload.ps1").read_text(encoding="utf-8-sig")
            self.assertIn("$data.playableSlotCount -ne 52 -or $data.reservedSlotCount -ne 8", script)
            for name in (FOREST_MODULES + ("LuJiaCunScenes.lua",) + stage_checkpoint_210.PANGZHEN_MODULES
                         + stage_checkpoint_210.MEIGUHU_MODULES + stage_checkpoint_210.XIMENG_MODULES
                         + stage_checkpoint_210.DUANHUN_MODULES + stage_checkpoint_210.ZHENGDAODAYING_MODULES
                         + stage_checkpoint_210.JIALONGSHAN_MODULES
                         + stage_checkpoint_210.MENU_MODULES + stage_checkpoint_210.PLAYER_MODULES + stage_checkpoint_210.ITEM_MODULES
                         + stage_checkpoint_210.ARENA_MODULES + stage_checkpoint_210.EQUIPMENT_MODULES
                         + stage_checkpoint_210.TRAINING_DUMMY_MODULES):
                self.assertTrue((output / "Scripts" / name).is_file(), name)
                self.assertIn(f"'{name}'", script)
            built = json.loads((output / "Scripts/StockArenaPresets.json").read_bytes())
            self.assertEqual(list(built["maps"]), [f"PBZArenaStockMap{n:02d}" for n in range(1, 53)])
            self.assertEqual(built["players"], presets["players"])
            for slot, original in presets["maps"].items():
                self.assertEqual(built["maps"][slot], original)
            forest = json.loads((ROOT / "config/BloodForestScenes.json").read_bytes())
            village = json.loads((ROOT / "config/LuJiaCunScenes.json").read_bytes())
            pangzhen = json.loads((ROOT / "config/PangzhenScenes.json").read_bytes())
            meiguhu = json.loads((ROOT / "config/MeiGuHuScenes.json").read_bytes())
            duanhun = json.loads((ROOT / "config/DuanhunScenes.json").read_bytes())
            zhengdaodaying = json.loads((ROOT / "config/ZhengDaoDaYingScenes.json").read_bytes())
            jialongshan = json.loads((ROOT / "config/JialongshanScenes.json").read_bytes())
            for layout, first in ((forest, 12), (village, 17), (pangzhen, 23), (meiguhu, 32), (duanhun, 41),
                                  (zhengdaodaying, 43), (jialongshan, 47)):
                for n, scene in enumerate(layout["scenes"], first):
                    map_name = scene.get("map", layout.get("map"))
                    preset = built["maps"][f"PBZArenaStockMap{n:02d}"]
                    pose = {"Location": scene["anchor"], "Rotation": scene["rotation"]}
                    game = preset["PBZGameSystem"]
                    self.assertEqual(game["CurrentLevelName"], map_name)
                    self.assertEqual(game["PlayerTransform"], pose)
                    self.assertEqual(game["ReviveTransform"], pose)
                    self.assertEqual(preset["EventPipeline"]["LoadedDataLayer"], {map_name: scene["loadedLayers"]})
                    self.assertEqual(preset["EventPipeline"]["UnLoadedDataLayer"], {map_name: scene["unloadedLayers"]})
                    self.assertFalse(preset["BellSaveID"])
                    self.assertFalse(preset["BellManager"]["NeedUnLockBigMapMaskWidgetNames"])
            lijiu, menghua = duanhun["scenes"]
            self.assertEqual(lijiu["bellSaveId"], "Bell_DH_003")
            self.assertEqual(menghua["bellSaveId"], "Bell_DH_004")
            self.assertEqual(menghua["phaseReturnPoints"], [{"X": -194355, "Y": -106234, "Z": 62025.365}])
            self.assertEqual(menghua["anchor"], {"X": -193546.77, "Y": -102948.51, "Z": 61516.68})
            self.assertEqual(menghua["recommendedEncounters"], ["BP_Monster_MengHua"])
            self.assertEqual([scene["id"] for scene in zhengdaodaying["scenes"]], [
                "zhengdaodaying_wanjun", "zhengdaodaying_sangaota", "zhengdaodaying_wulengshuang", "zhengdaodaying_yubi",
            ])
            yubi = zhengdaodaying["scenes"][-1]
            self.assertEqual(yubi["phaseReturnPoints"][0], {"X": 31027, "Y": 55940, "Z": 5889})
            self.assertEqual(yubi["checkpointBell"]["id"], "Bell_YXZR_009")
            for n, scene in enumerate(zhengdaodaying["scenes"], 43):
                game = built["maps"][f"PBZArenaStockMap{n:02d}"]["PBZGameSystem"]
                self.assertEqual(game["ReviveCameraRotation"], scene["reviveCameraRotation"])
            _, _, yanyan, jade, huang_p1, huang_p2 = jialongshan["scenes"]
            self.assertEqual(len(yanyan["roadFogs"][-1]["points"]), 11)
            self.assertEqual(len(yanyan["phaseReturnPoints"]), 1)
            self.assertEqual(jade["bellSaveId"], huang_p1["bellSaveId"])
            self.assertFalse(jade["checkpointBell"].get("relocate"))
            self.assertTrue(huang_p1["checkpointBell"]["relocate"])
            self.assertTrue(huang_p1["blockedTraversal"]["BP_MagicDoor_C_UAID_E89C25A75120FEDA02_1547222481"])
            self.assertEqual(huang_p2["bellSaveId"], "JJYBP_Brokenbell_01")
            self.assertEqual(huang_p2["recommendedEncounters"], ["BP_Monster_MBossVariants"])
            self.assertEqual(built["maps"]["PBZArenaStockMap52"]["PBZGameSystem"]["LastSaveActorID"], "None")
            self.assertGreater(huang_p2["anchor"]["Z"] - huang_p1["anchor"]["Z"], 9_000_000)
            self.assertTrue(all(scene["guardTerrainDefeat"] for scene in pangzhen["scenes"]))
            ximeng = json.loads((ROOT / "config/XiMengScenes.json").read_bytes())
            for n, scene in enumerate(ximeng["scenes"], 39):
                preset = built["maps"][f"PBZArenaStockMap{n:02d}"]
                game = preset["PBZGameSystem"]
                pose = {"Location": scene["anchor"], "Rotation": scene["rotation"]}
                self.assertEqual(game["CurrentLevelName"], ximeng["map"])
                self.assertEqual(game["PlayerTransform"], pose)
                self.assertEqual(game["ReviveTransform"], pose)
                self.assertEqual(preset["EventPipeline"]["UnLoadedDataLayer"], {ximeng["map"]: scene["unloadedLayers"]})
                if scene.get("moveCheckpointBell"):
                    self.assertEqual(game["LastSaveActorID"], "None")
                    self.assertEqual(preset["BellSaveID"], "")
                    self.assertEqual(preset["BellManager"], built["maps"]["PBZArenaStockMap36"]["BellManager"])
                else:
                    self.assertEqual(game["LastSaveActorID"], "Bell_XM_012")
                    self.assertEqual(preset["BellSaveID"], "Bell_XM_012")
                    self.assertEqual(preset["BellManager"]["RecentlyInteractedBellIDByMap"], {"XiMeng": "Bell_XM_012"})
            summer, winter = (scene["loadedLayers"][0] for scene in forest["scenes"][-2:])
            self.assertTrue(summer.endswith(".A03_0_FuJiZhiLin_Summer"))
            self.assertTrue(winter.endswith(".A03_0_FuJiZhiLin_Winter"))
            for name in stage_checkpoint_210.MENU_BACKGROUNDS:
                self.assertEqual((output / "Scripts/UiAssets" / name).read_bytes(), (backgrounds / name).read_bytes())
                self.assertIn(f"'UiAssets/{name}'", script)
