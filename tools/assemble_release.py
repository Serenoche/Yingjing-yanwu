"""Assemble a local Windows release from verified local-only inputs.

No downloads, installation, game launch, asset extraction or save decompression.
Game-derived inputs are deliberately absent from this source repository.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import importlib.util
from io import BytesIO
import json
import os
from pathlib import Path
import re
import struct
import sys
import tempfile
from zipfile import ZipFile
import zlib

ROOT = Path(__file__).resolve().parents[1]
GAME_SHA256 = "4415933ce33476f14c837abb61a1b60af8b78cd81783896501913a7aac69e423"
UE4SS_SHA256 = "0b6b7f9430502c1fbeadb09740e586063dce42fe4f7d7a3ee7be51c9bd6ca304"
JSON_SHA256 = "9bea4c8066ef4a1c206b2be5a36302f8926f7fdc6087af5d20b417d0cf103ea6"
MATERIAL_SHA256 = "cec857d9b81593cc8340b18e5b0d65a6f7aee2dfc8603f755b2d41ceb3951692"
SEALED_HEADER = bytes.fromhex("50425a5301010000")
LOADER_FILES = (
    "dwmapi.dll", "ue4ss/LICENSE", "ue4ss/MemberVariableLayout.ini", "ue4ss/UE4SS.dll",
    "ue4ss/UE4SS-settings.ini", "ue4ss/UE4SS_Signatures/GNatives.lua",
    "ue4ss/UE4SS_Signatures/GUObjectArray.lua", "ue4ss/Mods/shared/UEHelpers/UEHelpers.lua",
)
RUNTIME_FILES = (
    "main.lua", "Health.lua", "Panel.lua", "ClosedArena.lua", "CombatSpawn.lua", "ChallengeSignals.lua",
    "ChallengeMenu.lua", "ChallengeVictory.lua", "AbilityChallenge.lua", "Challenge.lua", "TitleProbe.lua",
    "TitleSession.lua", "SaveBarrier.lua", "Integration.lua", "ParameterStyle.lua", "ParameterFeedback.lua",
    "ParameterForm.lua", "ChallengeTarget.lua", "TitleHome.lua", "TrainingHud.lua", "BossCatalog.lua",
    "EncounterCatalog.lua", "EncounterPlayerState.lua", "StageFade.lua", "StageScreen.lua", "EncounterEngage.lua",
    "SpawnClass.lua", "PlayerProfile.lua", "GameplayDifficulty.lua", "PracticeMode.lua", "PracticeHud.lua",
    "ArtAssets.lua", "NativeUiAssetsData.lua", "NativeScreen.lua", "NativeSelection.lua", "ChallengeLoadout.lua",
    "PortraitLayout.lua", "HistoryReport.lua", "ArenaLoadout.lua", "ArenaLoadoutMemory.lua", "ArenaEconomy.lua",
    "ArenaMapPolicy.lua", "LengTuArena.lua", "LengTuSummons.lua", "DayArena.lua", "SceneArena.lua", "ArenaScenes.lua",
    "GeneratedEncounterCatalog.lua", "GeneratedArenaScenes.lua", "LionArena.lua", "EnemyHealthGuard.lua", "StampPress.lua",
    "JingYeMount.lua", "ChiLianArena.lua", "PlayerDamageGuard.lua", "CustomChallenges.lua", "KryptonDemo.lua", "PendingEntry.lua",
    "StatusBuildup.lua", "StatusBuildupHud.lua", "StatusEffectClock.lua", "PracticeBossInfo.lua", "ChallengeMedicine.lua",
)
EXPECTED_RUNTIME_COUNT = 63
EXPECTED_PAYLOAD_COUNT = 89
GENERATED = ("BossCatalog.lua", "GeneratedEncounterCatalog.lua", "GeneratedArenaScenes.lua")
INSTALLER_FILES = ("Install-PbzIntegratedMenu.ps1", "Open-PbzInstaller.ps1", "PortablePaths.ps1", "SharedRuntime.ps1", "CompatibilityInstall.ps1",
                   "安装主菜单入口.cmd", "卸载主菜单入口.cmd")
ASSET_NAMES = {"home-test.png", "home-practice.png", "home-challenge.jpg", "ink-background.png",
               "challenge-zhan.png", "soul-lao.png", *(f"soul-{index}.png" for index in range(7))}
PRIVATE_NAMES = ("PBZArenaIntegratedTraining", *(f"PBZArenaIntegratedCycle{x}" for x in range(7)),
                 "PBZArenaIntegratedLao", "PBZArenaIntegratedLakeTraining",
                 *(f"PBZArenaIntegratedLakeCycle{x}" for x in range(7)), "PBZArenaIntegratedLakeLao")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def linked(path: Path) -> bool:
    try:
        return path.is_symlink() or bool(getattr(path.lstat(), "st_file_attributes", 0) & 0x400)
    except FileNotFoundError:
        return False


def regular(path: Path) -> Path:
    path = path.absolute()
    for item in (path, *path.parents):
        require(not linked(item),
                f"Linked inputs/outputs are unsupported: {path.name}")
    require(path.is_file(), f"Required input is missing: {path.name}")
    return path


def read(path: Path) -> bytes:
    return regular(path).read_bytes()


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=True, indent=2) + "\n").encode("ascii")


def read_json(path: Path, data: bytes | None = None) -> dict:
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, f"Duplicate JSON key in {path.name}")
            result[key] = value
        return result
    value = json.loads((read(path) if data is None else data).decode("utf-8-sig"), object_pairs_hook=unique)
    require(isinstance(value, dict), f"Expected an object in {path.name}")
    return value


def derive_game_key(path: Path) -> bytes:
    """Read a pinned local executable; do not emit, cache or package key material."""
    regular(path)
    anchor = "sealed but block is PLAINTEXT".encode("utf-16le")
    checksum, positions, tail, total = hashlib.sha256(), set(), b"", 0
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            checksum.update(block)
            window = tail + block
            start = 0
            while (index := window.find(anchor, start)) >= 0:
                positions.add(total - len(tail) + index)
                start = index + 1
            total += len(block)
            tail = window[-(len(anchor) - 1):]
        require(checksum.hexdigest() == GAME_SHA256, "Unsupported local game executable fingerprint")
        require(len(positions) == 1, "Local game save-key anchor is ambiguous")
        source.seek(next(iter(positions)) + 66)
        material = source.read(64)
    require(digest(material) == MATERIAL_SHA256, "Local game save-key material fingerprint differs")
    return bytes(material[x] ^ material[x + 32] for x in range(32))


class CngGcm:
    """Windows CNG AES-GCM, used only to authenticate local preset blocks."""
    class AuthInfo(ctypes.Structure):
        _fields_ = [("cbSize", ctypes.c_uint32), ("dwInfoVersion", ctypes.c_uint32),
                    ("pbNonce", ctypes.c_void_p), ("cbNonce", ctypes.c_uint32),
                    ("pbAuthData", ctypes.c_void_p), ("cbAuthData", ctypes.c_uint32),
                    ("pbTag", ctypes.c_void_p), ("cbTag", ctypes.c_uint32),
                    ("pbMacContext", ctypes.c_void_p), ("cbMacContext", ctypes.c_uint32),
                    ("cbAAD", ctypes.c_uint32), ("cbData", ctypes.c_uint64), ("dwFlags", ctypes.c_uint32)]

    def __init__(self, key: bytes):
        require(os.name == "nt", "Preset authentication requires Windows CNG; no crypto fallback is supplied")
        self.dll = ctypes.WinDLL("bcrypt.dll")
        handle, pointer, ulong = ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32
        signatures = {
            "BCryptOpenAlgorithmProvider": [ctypes.POINTER(handle), ctypes.c_wchar_p, ctypes.c_wchar_p, ulong],
            "BCryptSetProperty": [handle, ctypes.c_wchar_p, pointer, ulong, ulong],
            "BCryptGetProperty": [handle, ctypes.c_wchar_p, pointer, ulong, ctypes.POINTER(ulong), ulong],
            "BCryptGenerateSymmetricKey": [handle, ctypes.POINTER(handle), pointer, ulong, pointer, ulong, ulong],
            "BCryptDecrypt": [handle, pointer, ulong, pointer, pointer, ulong, pointer, ulong, ctypes.POINTER(ulong), ulong],
            "BCryptDestroyKey": [handle], "BCryptCloseAlgorithmProvider": [handle, ulong],
        }
        for name, parameters in signatures.items():
            function = getattr(self.dll, name)
            function.argtypes, function.restype = parameters, ctypes.c_int32
        self.algorithm, self.key = handle(), handle()
        try:
            self.check(self.dll.BCryptOpenAlgorithmProvider(ctypes.byref(self.algorithm), "AES", None, 0))
            mode = ctypes.create_unicode_buffer("ChainingModeGCM")
            self.check(self.dll.BCryptSetProperty(self.algorithm, "ChainingMode", mode, ctypes.sizeof(mode), 0))
            length, written = ulong(), ulong()
            self.check(self.dll.BCryptGetProperty(self.algorithm, "ObjectLength", ctypes.byref(length), 4, ctypes.byref(written), 0))
            require(0 < length.value <= 1024 * 1024, "Unexpected CNG key-object length")
            self.object = ctypes.create_string_buffer(length.value)
            secret = ctypes.create_string_buffer(key)
            try:
                self.check(self.dll.BCryptGenerateSymmetricKey(self.algorithm, ctypes.byref(self.key), self.object,
                    length.value, secret, len(key), 0))
            finally:
                ctypes.memset(secret, 0, ctypes.sizeof(secret))
        except Exception:
            self.close()
            raise

    @staticmethod
    def check(status: int) -> None:
        require(status >= 0, f"CNG authentication failed (NTSTATUS {status & 0xffffffff:08X})")

    def open(self, block: bytes) -> bytes:
        require(len(block) >= 36 and block[:8] == SEALED_HEADER, "Invalid sealed PBZS block framing")
        nonce = ctypes.create_string_buffer(block[8:20])
        tag = ctypes.create_string_buffer(block[20:36])
        ciphertext = ctypes.create_string_buffer(block[36:])
        output = ctypes.create_string_buffer(max(len(block) - 36, 1))
        info = self.AuthInfo()
        info.cbSize, info.dwInfoVersion = ctypes.sizeof(info), 1
        info.pbNonce, info.cbNonce = ctypes.addressof(nonce), 12
        info.pbTag, info.cbTag = ctypes.addressof(tag), 16
        length = ctypes.c_uint32()
        self.check(self.dll.BCryptDecrypt(self.key, ciphertext, len(block) - 36, ctypes.byref(info), None, 0,
            output, len(output), ctypes.byref(length), 0))
        require(length.value == len(block) - 36, "Unexpected authenticated PBZS plaintext length")
        return output.raw[:length.value]

    def close(self):
        if self.key.value:
            self.dll.BCryptDestroyKey(self.key)
            self.key.value = None
        if self.algorithm.value:
            self.dll.BCryptCloseAlgorithmProvider(self.algorithm, 0)
            self.algorithm.value = None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def verify_presets(data: bytes, cipher: CngGcm) -> dict:
    require(48 <= len(data) <= 512 * 1024 * 1024 and data[:6] == b"PBZS\x03\x01", "Unsupported preset container")
    count, size = struct.unpack_from("<HI", data, 6)
    require(count == 18 and 36 <= size <= 8 * 1024 * 1024 and 12 + size <= len(data),
            "Presets must contain exactly eighteen complete private blocks")
    table = cipher.open(data[12:12 + size])
    require(table[:12] == data[:12], "Authenticated preset directory echo differs")
    cursor, end, result = 12, 0, {}
    for expected in PRIVATE_NAMES:
        require(cursor + 2 <= len(table), "Truncated preset directory")
        length = struct.unpack_from("<H", table, cursor)[0]
        cursor += 2
        require(0 < length <= 1024 and cursor + length + 14 <= len(table), "Truncated preset entry")
        name = table[cursor:cursor + length].decode("utf8")
        cursor += length
        algorithm, flag, raw, offset, sealed = struct.unpack_from("<BBIII", table, cursor)
        cursor += 14
        require(name == expected, "Preset directory must contain only the canonical private names in order")
        require(algorithm <= 2 and raw > 0 and offset == end and sealed >= 36 and 12 + size + end + sealed <= len(data),
                "Preset block has an invalid extent/compression declaration")
        block = data[12 + size + end:12 + size + end + sealed]
        cipher.open(block)  # Authenticate opaque compressed bytes; never decompress or inspect gameplay state.
        result[name] = {"sha256": digest(block), "algorithm": algorithm, "flag": flag, "rawSize": raw, "sealedSize": sealed}
        end += sealed
    require(cursor == len(table) and 12 + size + end == len(data), "Preset entries do not cover the input exactly")
    return result


def image_size(data: bytes, name: str) -> tuple[int, int]:
    if name.endswith(".png"):
        require(data[:8] == b"\x89PNG\r\n\x1a\n", f"Invalid PNG: {name}")
        cursor, dimensions, ended = 8, None, False
        while cursor + 12 <= len(data):
            length = struct.unpack_from(">I", data, cursor)[0]
            require(length <= len(data) - cursor - 12, f"Truncated PNG: {name}")
            kind, content = data[cursor + 4:cursor + 8], data[cursor + 8:cursor + 8 + length]
            require(zlib.crc32(kind + content) & 0xffffffff == struct.unpack_from(">I", data, cursor + 8 + length)[0], f"PNG CRC differs: {name}")
            if cursor == 8:
                require(kind == b"IHDR" and length == 13, f"Missing PNG dimensions: {name}")
                dimensions = struct.unpack_from(">II", content)
            cursor += 12 + length
            if kind == b"IEND":
                require(length == 0 and cursor == len(data), f"Invalid PNG end: {name}")
                ended = True
                break
        require(ended and dimensions is not None, f"Incomplete PNG: {name}")
        return dimensions
    require(name.endswith(".jpg") and data[:2] == b"\xff\xd8" and data[-2:] == b"\xff\xd9", f"Invalid JPEG: {name}")
    cursor = 2
    while cursor + 4 <= len(data):
        require(data[cursor] == 255, f"Invalid JPEG marker: {name}")
        while cursor < len(data) and data[cursor] == 255:
            cursor += 1
        require(cursor < len(data), f"Truncated JPEG marker: {name}")
        marker = data[cursor]
        cursor += 1
        if marker in (1, *range(0xd0, 0xda)):
            continue
        length = struct.unpack_from(">H", data, cursor)[0]
        require(length >= 2 and cursor + length <= len(data), f"Truncated JPEG: {name}")
        if marker in (0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf):
            require(length >= 8, f"Missing JPEG dimensions: {name}")
            height, width = struct.unpack_from(">HH", data, cursor + 3)
            return width, height
        cursor += length
    raise ValueError(f"Missing JPEG image frame: {name}")


def load_assets(directory: Path, metadata: bytes, manifest_data: bytes | None = None) -> tuple[dict[str, bytes], dict]:
    manifest = read_json(directory / "Manifest.json", manifest_data)
    require(manifest.get("schemaVersion") == 1 and manifest.get("owner") == "PBZTestArena.NativeUiAssets.v1"
            and manifest.get("dataSha256") in metadata_hashes(metadata), "Source UI manifest does not match NativeUiAssetsData.lua")
    entries = manifest.get("files")
    require(isinstance(entries, list) and len(entries) == 13, "Source UI manifest must declare thirteen images")
    dimensions = {}
    pattern = r'\["file"\]\s*=\s*"([A-Za-z0-9_.-]+)"\s*,\s*\["width"\]\s*=\s*(\d+)\s*,\s*\["height"\]\s*=\s*(\d+)'
    for name, width, height in re.findall(pattern, metadata.decode("utf8")):
        value = int(width), int(height)
        require(name not in dimensions or dimensions[name] == value, "Inconsistent local-image metadata")
        dimensions[name] = value
    require(set(dimensions) == ASSET_NAMES, "NativeUiAssetsData.lua local-image metadata is incomplete")
    names, assets, deployed = set(), {}, []
    for entry in entries:
        require(isinstance(entry, dict), "Invalid UI manifest entry")
        name = entry.get("file")
        require(isinstance(name, str) and name in ASSET_NAMES and name not in names, "Unknown/duplicate UI image filename")
        names.add(name)
        data = read(directory / name)
        require(digest(data) == entry.get("sha256") and len(data) == entry.get("bytes"), f"UI image checksum/length differs: {name}")
        width, height = image_size(data, name)
        require(type(entry.get("width")) is int and type(entry.get("height")) is int
                and (width, height) == (entry["width"], entry["height"]) and 0 < width <= 8192 and 0 < height <= 8192,
                f"UI image dimensions differ: {name}")
        require((width, height) == dimensions[name], f"Image dimensions differ from native UI metadata: {name}")
        assets[name] = data
        deployed.append({key: entry[key] for key in ("file", "sha256", "width", "height", "bytes")})
    require(names == ASSET_NAMES, "UI image set is incomplete")
    require({path.name for path in directory.iterdir()} == ASSET_NAMES | {"Manifest.json"}, "Unexpected files in local UI input directory")
    return assets, {"schemaVersion": 1, "owner": manifest["owner"], "files": deployed}


def metadata_hashes(metadata: bytes) -> set[str]:
    # Git may normalize this source-only Lua table from the original CRLF to LF.
    # Accept precisely that transformation; never ignore arbitrary content edits.
    lf = metadata.replace(b"\r\n", b"\n")
    return {digest(metadata), digest(lf), digest(lf.replace(b"\n", b"\r\n"))}


def component(directory: Path, name: str, filename: str) -> tuple[bytes, dict]:
    metadata = read_json(directory / "Build.json")
    data = read(directory / filename)
    require(metadata.get("component") == name and metadata.get("file") == filename and metadata.get("sha256") == digest(data)
            and metadata.get("supportedGameSha256") == GAME_SHA256 and metadata.get("installedOrGameLaunched") is False,
            f"Compiled {name} metadata/checksum is invalid")
    pe64(data, filename)
    return data, metadata


def pe64(data: bytes, name: str) -> None:
    require(len(data) >= 64 and data[:2] == b"MZ", f"Compiled component is not a PE image: {name}")
    offset = struct.unpack_from("<I", data, 0x3c)[0]
    require(offset + 26 <= len(data) and data[offset:offset + 4] == b"PE\0\0"
            and struct.unpack_from("<H", data, offset + 4)[0] == 0x8664
            and struct.unpack_from("<H", data, offset + 24)[0] == 0x20b, f"Compiled component is not x64 PE32+: {name}")


def generated_data(directory: Path) -> dict[str, bytes]:
    source = ROOT / "tools/data/generate_runtime_data.py"
    sys.path.insert(0, str(source.parent))
    try:
        spec = importlib.util.spec_from_file_location("yingjing_release_data", source)
        require(spec is not None and spec.loader is not None, "Runtime data generator is missing")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        expected = module.generated_files()
    finally:
        sys.path.pop(0)
    require(set(expected) == set(GENERATED), "Unexpected generated runtime data set")
    for name, data in expected.items():
        require(read(directory / name) == data, f"Generated data is missing/stale; run tools/data/generate_runtime_data.py: {name}")
    return expected


def load_runtime(directory: Path, data_directory: Path | None = None) -> tuple[dict[str, bytes], bytes, dict[str, bytes]]:
    """Load one complete runtime; a data directory validates only its generated tables.

    Never mix ordinary modules or enabled.txt from the repository into an
    explicitly selected runtime. Generated data must also match that runtime;
    --data-dir is not a second, partial runtime override.
    """
    script_directory = directory / "Scripts"
    require(script_directory.is_dir(), "Runtime directory must contain Scripts/ and enabled.txt")
    declared = set(RUNTIME_FILES)
    actual = {path.name for path in script_directory.iterdir() if path.suffix.lower() == ".lua"}
    require(len(RUNTIME_FILES) == EXPECTED_RUNTIME_COUNT and len(declared) == EXPECTED_RUNTIME_COUNT,
            "Unexpected runtime allowlist; update the release contract explicitly")
    require(actual == declared,
            f"Runtime module set differs (missing: {', '.join(sorted(declared - actual)) or 'none'}; "
            f"extra: {', '.join(sorted(actual - declared)) or 'none'})")
    scripts = {name: read(script_directory / name) for name in RUNTIME_FILES}
    enabled = read(directory / "enabled.txt")
    require(len(enabled) <= 64 and not enabled.strip(), "Runtime enabled.txt must be an empty/whitespace UE4SS sentinel")
    expected = generated_data(data_directory if data_directory is not None else script_directory)
    for name, data in expected.items():
        require(scripts[name] == data, f"Generated data differs from the selected runtime: {name}")
    return scripts, enabled, expected


def assemble(args: argparse.Namespace) -> dict:
    raw_output = Path(args.output).absolute()
    for parent in (raw_output, *raw_output.parents):
        require(not linked(parent), "Linked output paths are unsupported")
    output = raw_output.resolve()
    dist = (ROOT / "dist").resolve()
    require(output != dist and dist in output.parents and not output.exists(), "Output must be a new child directory under this repository's dist/")
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,63}", args.version) is not None, "Invalid local release version")
    runtime = Path(args.runtime_dir)
    data_directory = Path(args.data_dir) if args.data_dir is not None else None
    scripts, enabled, expected = load_runtime(runtime, data_directory)
    build, assets_dir, presets, archive, game = map(Path, (args.build_dir, args.assets_dir, args.presets, args.ue4ss_zip, args.game_exe))
    archive_data = read(archive)
    require(digest(archive_data) == UE4SS_SHA256, "UE4SS must be the exact pinned PBZ 1195/1ceefac8 release archive")
    barrier, barrier_build = component(build / "barrier", "barrier", "PBZSaveBarrier.dll")
    save_tool, save_build = component(build / "save-tool", "save-tool", "PBZSaveTool.exe")
    preset_data = read(presets)
    require(save_build.get("presetsSha256") == digest(preset_data) and save_build.get("privateSlotCount") == 18
            and save_build.get("jsonHeaderSha256") == JSON_SHA256, "Preset input differs from the SaveTool's compiled build configuration")
    legacy = save_build.get("legacyPresetsSha256")
    require(legacy is None or isinstance(legacy, str) and re.fullmatch("[a-f0-9]{64}", legacy) is not None, "Invalid legacy preset pin")
    with CngGcm(derive_game_key(game)) as cipher:
        private = verify_presets(preset_data, cipher)
    source_ui = read(assets_dir / "Manifest.json")
    assets, deployed_assets = load_assets(assets_dir, scripts["NativeUiAssetsData.lua"], source_ui)
    with ZipFile(BytesIO(archive_data)) as zipped:
        require(len(zipped.namelist()) == len(set(zipped.namelist())), "Duplicate UE4SS ZIP entries")
        payload = {name: zipped.read(name) for name in LOADER_FILES}
    base = "ue4ss/Mods/PBZTestArena/"
    payload[base + "enabled.txt"] = enabled
    payload.update({base + "Scripts/" + name: data for name, data in scripts.items()})
    payload[base + "Scripts/PBZSaveBarrier.dll"] = barrier
    payload.update({base + "Scripts/UiAssets/" + name: data for name, data in assets.items()})
    payload[base + "Scripts/UiAssets/Manifest.json"] = json_bytes(deployed_assets)
    payload["ue4ss/Mods/mods.txt"] = b"PBZTestArena : 1\r\n"
    payload["ue4ss/Mods/mods.json"] = b'[{"mod_name":"PBZTestArena","mod_enabled":true}]\n'
    require(len(payload) == EXPECTED_PAYLOAD_COUNT, "Incomplete native runtime payload")
    files = {"NativeEnemyRuntime/Payload/" + name: data for name, data in payload.items()}
    payload_hashes = {name: digest(data) for name, data in payload.items()}
    files["NativeEnemyRuntime/PayloadHashes.json"] = json_bytes(payload_hashes)
    installer = build / "installer"
    installer_build = read_json(installer / "InstallerBuild.json")
    host_name = "影境演武安装器.exe"
    host = read(installer / host_name)
    require(installer_build.get("component") == "installer-host" and installer_build.get("file") == host_name
            and installer_build.get("sha256") == digest(host) and installer_build.get("guiStarted") is False
            and installer_build.get("completeRelease") is False, "Installer host build metadata/checksum is invalid")
    pe64(host, host_name)
    files[host_name] = host
    for name in INSTALLER_FILES:
        data = read(installer / name)
        require(data == read(ROOT / "src/installer" / name), f"Installer source was changed after compilation: {name}")
        files["IntegratedMenu/" + name] = data
    tool_manifest = {"schemaVersion": 1, "file": "PBZSaveTool.exe", "sha256": digest(save_tool),
        "gameSha256": GAME_SHA256, "presetsSha256": digest(preset_data), "jsonHeaderSha256": JSON_SHA256,
        "runtimeDependencies": ["Windows CNG"], "privateSlotCount": 18, "legacyOwnedSlotCount": 8 if legacy else 0,
        "operations": ["stage", "verify"], "uninstallPolicy": "retain-dedicated-save-blocks-and-reports",
        "continueVerification": "opaque-Advanced-block-identical"}
    files["IntegratedMenu/Tools/PBZSaveTool.exe"] = save_tool
    files["IntegratedMenu/Tools/Build.json"] = json_bytes(tool_manifest)
    files["IntegratedMenu/Tools/JSON-LICENSE.MIT"] = read(ROOT / "src/save_tool/vendor/LICENSE.MIT")
    files["IntegratedMenu/PrivatePresets.pbzs"] = preset_data
    files["LICENSE"] = read(ROOT / "LICENSE")
    release_readme = read(ROOT / "docs/RELEASE_README.md").decode("utf8")
    files["README.md"] = release_readme.replace("@VERSION@", args.version).replace("@GAME_SHA256@", GAME_SHA256).encode("utf8")
    files["THIRD_PARTY_NOTICES.md"] = read(ROOT / "THIRD_PARTY_NOTICES.md")
    inputs = {
        "game": {"sha256": GAME_SHA256, "copied": False},
        "ue4ssArchive": {"sha256": UE4SS_SHA256, "selectedFiles": len(LOADER_FILES)},
        "uiSourceManifest": {"sha256": digest(source_ui), "imageCount": 13},
        "nativeUiMetadata": {"sha256": digest(scripts["NativeUiAssetsData.lua"]),
            "sourceManifestDataSha256": read_json(assets_dir / "Manifest.json", source_ui)["dataSha256"],
            "acceptedNormalization": "exact-content-or-LF/CRLF-only"},
        "privatePresets": {"sha256": digest(preset_data), "blocks": private, "authentication": "all-GCM-blocks-canonical-private-names"},
        "components": {"barrier": barrier_build, "saveTool": save_build, "installer": installer_build},
        "config": {path.name: sha256(path) for path in sorted((ROOT / "config").glob("*.json"))},
        "generatedData": {name: digest(data) for name, data in expected.items()},
        "sourceRuntime": {name: digest(data) for name, data in scripts.items()},
        "runtimeLayout": {"scripts": "runtime-dir/Scripts", "enabled": "runtime-dir/enabled.txt",
                          "enabledSha256": digest(enabled), "generatedDataPolicy": "validate-selected-runtime-no-overrides"},
    }
    files["BuildProvenance.json"] = json_bytes({"schemaVersion": 1, "inputs": inputs,
        "payloadFiles": EXPECTED_PAYLOAD_COUNT, "gameLaunched": False, "installed": False, "saveDecompressed": False})
    manifest = {"schemaVersion": 1, "owner": "PBZTestArena.PortableDistribution", "name": "影境演武",
        "version": args.version, "gameSha256": GAME_SHA256, "supportedBuild": "CL-302256_JKS-17280",
        "files": {name: {"sha256": digest(data), "bytes": len(data)} for name, data in sorted(files.items())}}
    files["PackageManifest.json"] = json_bytes(manifest)
    files["SHA256SUMS.txt"] = ("\n".join(f"{digest(data)}  {name}" for name, data in sorted(files.items())) + "\n").encode("utf8")
    # Nothing is written until every input has passed. Never overwrite or install.
    dist.mkdir(exist_ok=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".assemble-", dir=output.parent))
    for name, data in files.items():
        target = stage / name
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as stream:
            stream.write(data)
        require(sha256(target) == digest(data), f"Release read-back differs: {name}")
    stage.rename(output)
    return {"passed": True, "output": str(output), "payloadFiles": EXPECTED_PAYLOAD_COUNT, "images": 13, "privateSlots": 18,
            "gameSha256": GAME_SHA256, "presetsSha256": digest(preset_data), "installed": False,
            "gameLaunched": False, "manifestSha256": sha256(output / "PackageManifest.json")}


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--build-dir", default=str(ROOT / "build"))
    result.add_argument("--runtime-dir", default=str(ROOT / "src/runtime"),
                        help="Complete runtime root containing exactly the allowed Lua modules in Scripts/ plus enabled.txt")
    result.add_argument("--data-dir", default=None,
                        help="Optional generated-table validation directory; defaults to runtime-dir/Scripts, never overrides runtime modules")
    result.add_argument("--assets-dir", required=True, help="Local directory with original source Manifest.json and exactly thirteen images")
    result.add_argument("--presets", required=True, help="Local eighteen-private-block PBZS bundle matching the compiled SaveTool")
    result.add_argument("--ue4ss-zip", required=True, help="Locally obtained pinned PBZ 1195/1ceefac8 ZIP; never downloaded")
    result.add_argument("--game-exe", required=True, help="Read-only supported PBZ.exe used to authenticate presets; never copied")
    result.add_argument("--output", default=str(ROOT / "dist/yingjing-yanwu-local"))
    result.add_argument("--version", default="local")
    return result


def main() -> int:
    try:
        print(json.dumps(assemble(parser().parse_args()), ensure_ascii=True))
        return 0
    except (OSError, ValueError, KeyError, UnicodeError, struct.error) as error:
        print(f"Release assembly stopped: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
