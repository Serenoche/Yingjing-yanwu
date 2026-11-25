"""Stage the 2.1.0 native checkpoint runtime and presets."""

from hashlib import sha256
import json
from pathlib import Path
import re
from tempfile import TemporaryDirectory

from data import (
    blood_forest_scenes, duanhun_scenes, jialongshan_scenes, lujia_village_scenes, meiguhu_scenes, pangzhen_scenes,
    ximeng_scenes, zhengdaodaying_scenes,
)
from data.xigu_checkpoints import STOCK_CAPACITY, add_maps, load_layout, runtime_lua


ROOT = Path(__file__).resolve().parents[1]
PROFILE = ROOT / "RELEASE_PROFILE.json"
PRESETS = "StockArenaPresets.json"
PLAYABLE_SLOTS = 52
RUNTIME_DIR = "NativeEnemyRuntime"
SCRIPTS_DIR = Path("ue4ss/Mods/PBZTestArena/Scripts")
ITEM_MODULES = ("ArenaItems.lua", "ArenaItemActors.lua")
PALACE_MODULES = ("DreamPalacePlacement.lua",)
ARENA_MODULES = ("ArenaTerrain.lua", "ArenaBossMechanics.lua", "LionOverheat.lua")
EQUIPMENT_MODULES = ("ArenaEquipmentMenu.lua", "WeaponEnhancement.lua", "WeaponSoul.lua")
TRAINING_DUMMY_MODULES = ("TrainingDummy.lua", "TrainingDummyDamage.lua", "TrainingDummyHud.lua")
XIGU_MODULES = ("PengMengScene.lua", "XiguBossArena.lua", "XiguBossRecovery.lua",
                "XiguBossScenes.lua", "XiguCheckpoint.lua", "XiguRoadFog.lua")
FOREST_MODULES = ("BloodForestScenes.lua", "ForestSnakeMarkers.lua", "PhantomRoadFog.lua")
LUJIACUN_MODULES = ("LuJiaCunScenes.lua",)
PANGZHEN_MODULES = ("PangzhenScenes.lua", "PangzhenWellFloor.lua")
MEIGUHU_MODULES = ("MeiGuHuScenes.lua",)
XIMENG_MODULES = ("XiMengScenes.lua",)
DUANHUN_MODULES = ("DuanhunScenes.lua",)
ZHENGDAODAYING_MODULES = ("ZhengDaoDaYingScenes.lua",)
JIALONGSHAN_MODULES = ("JialongshanScenes.lua",)
MENU_MODULES = ("ArenaGalleryData.lua", "ArenaMenuCatalog.lua", "ArenaMenuData.lua",
                "ArenaMusicPanel.lua", "ArenaSetupFlow.lua", "ArenaSetupMenu.lua")
PLAYER_MODULES = ("PlayerCustom.lua", "PlayerCustomSlider.lua", "PlayerCustomStats.lua")
MENU_BACKGROUNDS = tuple(f"arena-background-{page}.png" for page in ("music", "scene", "target", "character"))


def read_sources(entries):
    scripts = {}
    for name, entry in entries.items():
        if not re.fullmatch(r"[A-Za-z0-9_]+\.lua", name):
            raise ValueError(f"Invalid Lua filename: {name}")
        path = (ROOT / entry["source"]).resolve()
        if not path.is_relative_to(ROOT / "src"):
            raise ValueError(f"Lua source outside src: {name}")
        content = path.read_bytes().replace(b"\r\n", b"\n")
        if sha256(content).hexdigest() != entry["sha256"]:
            raise ValueError(f"Lua source checksum mismatch: {name}")
        scripts[name] = content
    return scripts


def read_menu_backgrounds(entries, directory):
    if entries.keys() != set(MENU_BACKGROUNDS):
        raise ValueError("Invalid 2.1.0 menu background manifest")
    artwork = {}
    for name, expected in entries.items():
        path = directory / name
        content = path.read_bytes()
        if sha256(content).hexdigest() != expected:
            raise ValueError(f"Menu background checksum mismatch: {path}")
        artwork[f"UiAssets/{name}"] = content
    return artwork


def write_files(directory, files):
    for name, content in files.items():
        destination = directory / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(content)


def installer_check():
    template = (ROOT / "src/installer/CheckpointPayload.ps1").read_text(encoding="utf-8-sig")
    required = "'PBZSaveBarrier.dll','StockArenaPresets.json')"
    if template.count(required) != 1:
        raise ValueError("Checkpoint installer template changed")
    extra = ("StockBellArena.lua", "ShengQuXinChiScene.lua", "ShengQuXinChiArena.lua", "HuaShanSquad.lua", "GauntletTravel.lua",
             "TieYuCombo.lua",
             *ITEM_MODULES, *PALACE_MODULES, *ARENA_MODULES, *EQUIPMENT_MODULES, *TRAINING_DUMMY_MODULES,
             *XIGU_MODULES, *FOREST_MODULES,
             *LUJIACUN_MODULES, *PANGZHEN_MODULES, *MEIGUHU_MODULES, *XIMENG_MODULES, *DUANHUN_MODULES,
             *ZHENGDAODAYING_MODULES, *JIALONGSHAN_MODULES,
             *MENU_MODULES, *PLAYER_MODULES, "InputActionHint.lua", *(f"UiAssets/{name}" for name in MENU_BACKGROUNDS))
    names = ",\n        ".join(repr(name) for name in extra)
    return template.replace(required, required[:-1] + ",\n        " + names + ")").encode("utf-8-sig")


def load_runtime_sources():
    """Read the current release profile and verify every listed Lua source."""
    profile = json.loads(PROFILE.read_bytes())
    manifest = json.loads((ROOT / profile["runtimeManifest"]).read_bytes())
    checkpoint = manifest["flows"]["checkpoint"]
    background_hashes = manifest["menuBackgrounds"]
    native_scene_modules = (XIGU_MODULES + FOREST_MODULES + LUJIACUN_MODULES
                            + PANGZHEN_MODULES + MEIGUHU_MODULES + XIMENG_MODULES + DUANHUN_MODULES
                            + ZHENGDAODAYING_MODULES + JIALONGSHAN_MODULES)
    if (profile["schemaVersion"] != 2 or profile["version"] != "2.1.0" or manifest["schemaVersion"] != 1
            or manifest.keys() != {"schemaVersion", "flows", "menuBackgrounds"}
            or manifest["flows"].keys() != {"checkpoint"}
            or profile["runtimeModules"] != {"checkpoint": len(checkpoint)}
            or not {"HuaShanSquad.lua", "GauntletTravel.lua", "TieYuCombo.lua"} <= checkpoint.keys()
            or not set(native_scene_modules + MENU_MODULES + PLAYER_MODULES + ITEM_MODULES + PALACE_MODULES
                       + ARENA_MODULES + EQUIPMENT_MODULES + TRAINING_DUMMY_MODULES) <= checkpoint.keys()
            or background_hashes.keys() != set(MENU_BACKGROUNDS)):
        raise ValueError("Invalid 2.1.0 runtime source profile")

    return profile, manifest, read_sources(checkpoint)


def stage(base_presets, output, *, base_release=None, menu_backgrounds=None):
    profile, manifest, scripts = load_runtime_sources()

    if base_release is not None:
        base = json.loads((base_release / "PackageManifest.json").read_bytes())
        if base["version"] != profile["baseVersion"] or base["channel"] != "release":
            raise ValueError(f"Expected the {profile['baseVersion']} release directory")
        base_presets = base_release / RUNTIME_DIR / "CheckpointPayload" / SCRIPTS_DIR / PRESETS
        menu_backgrounds = menu_backgrounds or ROOT / "local-inputs/ArenaMenuBackgrounds"

    artwork = read_menu_backgrounds(manifest["menuBackgrounds"], menu_backgrounds) if menu_backgrounds is not None else {}

    layout = load_layout()
    if scripts["XiguCheckpoint.lua"] != runtime_lua(layout):
        raise ValueError("Regenerate XiguCheckpoint.lua from config/XiguCheckpointSlots.json")
    forest = blood_forest_scenes.load_layout()
    if scripts["BloodForestScenes.lua"] != blood_forest_scenes.runtime_lua(forest):
        raise ValueError("Regenerate BloodForestScenes.lua from config/BloodForestScenes.json")
    village = lujia_village_scenes.load_layout()
    if scripts["LuJiaCunScenes.lua"] != lujia_village_scenes.runtime_lua(village):
        raise ValueError("Regenerate LuJiaCunScenes.lua from config/LuJiaCunScenes.json")
    pangzhen = pangzhen_scenes.load_layout()
    if scripts["PangzhenScenes.lua"] != pangzhen_scenes.runtime_lua(pangzhen):
        raise ValueError("Regenerate PangzhenScenes.lua from config/PangzhenScenes.json")
    lake = meiguhu_scenes.load_layout()
    if scripts["MeiGuHuScenes.lua"] != meiguhu_scenes.runtime_lua(lake):
        raise ValueError("Regenerate MeiGuHuScenes.lua from config/MeiGuHuScenes.json")
    ximeng = ximeng_scenes.load_layout()
    if scripts["XiMengScenes.lua"] != ximeng_scenes.runtime_lua(ximeng):
        raise ValueError("Regenerate XiMengScenes.lua from config/XiMengScenes.json")
    duanhun = duanhun_scenes.load_layout()
    if scripts["DuanhunScenes.lua"] != duanhun_scenes.runtime_lua(duanhun):
        raise ValueError("Regenerate DuanhunScenes.lua from config/DuanhunScenes.json")
    zhengdaodaying = zhengdaodaying_scenes.load_layout()
    if scripts["ZhengDaoDaYingScenes.lua"] != zhengdaodaying_scenes.runtime_lua(zhengdaodaying):
        raise ValueError("Regenerate ZhengDaoDaYingScenes.lua from config/ZhengDaoDaYingScenes.json")
    jialongshan = jialongshan_scenes.load_layout()
    if scripts["JialongshanScenes.lua"] != jialongshan_scenes.runtime_lua(jialongshan):
        raise ValueError("Regenerate JialongshanScenes.lua from config/JialongshanScenes.json")
    try:
        bundle = add_maps(json.loads(base_presets.read_bytes()), layout)
        bundle = blood_forest_scenes.add_maps(bundle, forest)
        bundle = lujia_village_scenes.add_maps(bundle, village)
        bundle = pangzhen_scenes.add_maps(bundle, pangzhen)
        bundle = meiguhu_scenes.add_maps(bundle, lake)
        bundle = ximeng_scenes.add_maps(bundle, ximeng)
        bundle = duanhun_scenes.add_maps(bundle, duanhun)
        bundle = zhengdaodaying_scenes.add_maps(bundle, zhengdaodaying)
        bundle = jialongshan_scenes.add_maps(bundle, jialongshan)
    except (KeyError, TypeError) as error:
        raise ValueError("Invalid stock checkpoint template") from error
    playable = len(bundle["maps"])
    if playable != PLAYABLE_SLOTS:
        raise ValueError(f"Expected {PLAYABLE_SLOTS} native checkpoint presets, got {playable}")
    installer = installer_check()
    presets = (json.dumps(bundle, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
    if output.exists():
        raise FileExistsError(f"Checkpoint staging directory already exists: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(dir=output.parent, prefix="checkpoint-210-") as directory:
        staged = Path(directory) / "Checkpoint"
        scripts_dir = staged / "Scripts"
        write_files(scripts_dir, {**scripts, **artwork})
        (scripts_dir / PRESETS).write_bytes(presets)
        (staged / "CheckpointPayload.ps1").write_bytes(installer)
        staged.rename(output)
    return {"total": STOCK_CAPACITY, "playable": playable, "reserved": STOCK_CAPACITY - playable,
            "playerProfiles": len(bundle["players"]), "luaModules": len(scripts),
            "menuBackgrounds": len(artwork),
            "presetSha256": sha256(presets).hexdigest()}
