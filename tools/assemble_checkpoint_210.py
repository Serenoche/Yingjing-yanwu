"""Assemble the 2.1.0 native-checkpoint installer from verified local inputs."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import sys
from tempfile import TemporaryDirectory

from build import ROOT, sha256
from stage_checkpoint_210 import PRESETS, RUNTIME_DIR, SCRIPTS_DIR


HOST = "影境演武安装器.exe"
BARRIER = "PBZSaveBarrier.dll"
README = """# 影境演武 2.1.0 安装说明

2.1.0 使用 52 场地原版存点运行时。安装器检查 Steam 参考版 CL-302256_JKS-17280、旧 Steam 301524-17219 和已适配的 Epic 参考构建。自订压力按原有接口条件开放。

1. 完整解压到游戏目录外，退出游戏，等待平台同步。
2. 打开「影境演武安装器.exe」，选择对应的游戏位置和存档账号，点击「检查安装」。
3. 按检查结果安装或覆盖，再通过游戏平台正常启动，从标题页进入「影境演武」。
4. 遇到异常时在安装器里选择「导出诊断」。卸载时使用同一安装器的「卸载（保留进度）」。

旧 Steam 和 Epic 的安装、升级、修复及卸载已通过离线回归。52 个场地在这两类客户端上的实际运行尚待确认。
"""


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def write_json(path: Path, data) -> None:
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def copy_verified(source: Path, destination: Path, digest: str) -> None:
    if not source.is_file() or sha256(source) != digest:
        raise ValueError(f"Input file does not match its manifest: {source.name}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)


def local_file(root: Path, name: str) -> Path:
    path = (root / name).resolve()
    if Path(name).is_absolute() or ".." in Path(name).parts or not path.is_relative_to(root.resolve()):
        raise ValueError(f"Invalid manifest path: {name}")
    return path


def file_hashes(root: Path) -> dict[str, str]:
    return {path.relative_to(root).as_posix(): sha256(path)
            for path in sorted(root.rglob("*")) if path.is_file()}


def stage_hashes(stage: Path) -> dict[str, str]:
    profile = read_json(ROOT / "RELEASE_PROFILE.json")
    manifest = read_json(local_file(ROOT, profile["runtimeManifest"]))
    checkpoint = manifest["flows"]["checkpoint"]
    expected = {name: entry["sha256"] for name, entry in checkpoint.items()}
    expected.update({f"UiAssets/{name}": digest for name, digest in manifest["menuBackgrounds"].items()})
    actual = file_hashes(stage)
    if profile["version"] != "2.1.0" or actual.keys() != expected.keys() | {PRESETS}:
        raise ValueError("Staged checkpoint files or menu artwork are incomplete")
    if any(actual[name] != digest for name, digest in expected.items()):
        raise ValueError("Staged checkpoint files differ from the 2.1.0 manifest")
    return actual


def assemble(base: Path, stage: Path, native: Path, installer: Path, output: Path, channel: str) -> dict:
    if output.exists():
        raise FileExistsError(output)

    base_runtime = base / RUNTIME_DIR
    distribution = read_json(base / "PackageManifest.json")
    reference = read_json(base_runtime / "CheckpointPayloadHashes.json")
    loader_hashes = read_json(base_runtime / "PayloadHashes.json")
    compiled = read_json(native / "DirectCheckpointBuild.json")
    host_build = read_json(installer / "InstallerBuild.json")
    scripts = stage / "Scripts"
    staged = stage_hashes(scripts)
    presets = read_json(scripts / PRESETS)
    if (distribution["version"] != "2.0.3" or distribution["channel"] != "release"
            or compiled["referenceParser"] != reference["referenceParser"]
            or compiled["presetSha256"] != staged[PRESETS]
            or presets["slotCapacity"] != 60 or len(presets["maps"]) != 52
            or len(presets["players"]) != 8):
        raise ValueError("The native build, preset bundle and reference package do not match")
    if host_build["runtimeProfile"] != "checkpoint-210" or host_build["file"] != HOST:
        raise ValueError("An installer host built for checkpoint-210 is required")

    output.parent.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(dir=output.parent, prefix="native-210-") as temporary:
        package = Path(temporary) / "package"
        runtime = package / RUNTIME_DIR
        script_prefix = SCRIPTS_DIR.as_posix() + "/"
        common = {name: digest for name, digest in loader_hashes.items() if not name.startswith(script_prefix)}
        for name, digest in common.items():
            copy_verified(local_file(base_runtime / "Payload", name), runtime / "Payload" / name, digest)
        write_json(runtime / "PayloadHashes.json", common)

        checkpoint_root = runtime / "CheckpointPayload"
        overlay = checkpoint_root / SCRIPTS_DIR
        for name, digest in reference["files"].items():
            if not name.startswith(script_prefix):
                raise ValueError(f"Invalid reference checkpoint file path: {name}")
            relative = name[len(script_prefix):]
            if not relative.startswith("UiAssets/") and relative not in {
                "PBZPathIdentity.dll", "PBZDreamPressureNative.dll"
            }:
                continue
            original = local_file(base_runtime / "CheckpointPayload", name)
            copy_verified(original, overlay / relative, digest)
        for name, digest in staged.items():
            copy_verified(local_file(scripts, name), overlay / name, digest)
        copy_verified(native / BARRIER, overlay / BARRIER, compiled["dllSha256"])
        write_json(runtime / "CheckpointPayloadHashes.json", {
            "schemaVersion": 2, "slotCount": 60, "playableSlotCount": 52, "reservedSlotCount": 8,
            "playerProfileCount": 8, "referenceParser": compiled["referenceParser"],
            "files": file_hashes(checkpoint_root),
            "nativeCheckpointAdmission": {
                "schemaVersion": 1, "nativeOnly": True, "legacySteamAllowed": True,
                "legacySteamParser": compiled["legacySteamParser"],
            },
        })

        # These base files contain common assets and read-only diagnostics.
        for name, entry in distribution["files"].items():
            if name.startswith(f"{RUNTIME_DIR}/LoaderBridges/") or name in {
                "Collect-PbzBetaDiagnostics.ps1", "导出问题日志.cmd", f"{RUNTIME_DIR}/ArenaMaps.json",
            }:
                copy_verified(local_file(base, name), package / name, entry["sha256"])
        integrated = package / "IntegratedMenu"
        integrated.mkdir()
        for pattern in ("*.ps1", "*.cmd", "EpicNativeRequirements.json"):
            for path in (ROOT / "src/installer").glob(pattern):
                packaged = stage / path.name if path.name == "CheckpointPayload.ps1" else path
                shutil.copyfile(packaged, integrated / path.name)
        copy_verified(installer / HOST, package / HOST, host_build["sha256"])
        shutil.copyfile(ROOT / "LICENSE", package / "LICENSE")
        shutil.copyfile(ROOT / "THIRD_PARTY_NOTICES.md", package / "THIRD_PARTY_NOTICES.md")
        shutil.copyfile(ROOT / "src/save_tool/vendor/LICENSE.MIT", package / "JSON-LICENSE.MIT")
        (package / "README.md").write_text(README, encoding="utf-8")
        (package / "安装说明.txt").write_text(README, encoding="utf-8-sig")
        write_json(package / "BuildProvenance.json", {
            "schemaVersion": 1, "version": "2.1.0", "channel": channel, "baseVersion": distribution["version"],
            "baseManifestSha256": sha256(base / "PackageManifest.json"),
            "runtimeManifestSha256": sha256(ROOT / "src/runtime/release_210/Manifest.json"),
            "nativeBuild": compiled, "installed": False, "gameLaunched": False,
        })

        inventory = {name: {"bytes": (package / name).stat().st_size, "sha256": digest}
                     for name, digest in file_hashes(package).items()}
        write_json(package / "PackageManifest.json", {
            **distribution, "name": "影境演武 2.1.0", "version": "2.1.0",
            "channel": channel, "files": inventory,
        })
        sums = "".join(f"{entry['sha256']}  {name}\n" for name, entry in inventory.items())
        (package / "SHA256SUMS.txt").write_text(sums, encoding="utf-8")
        package.rename(output)
    return {"version": "2.1.0", "channel": channel, "mapSlots": 52, "files": len(inventory), "output": str(output)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for part in ("base", "stage", "native", "installer", "output"):
        parser.add_argument("--" + part, type=lambda value: Path(value).resolve(), required=True)
    parser.add_argument("--channel", choices=("internal", "release"), default="internal")
    try:
        print(json.dumps(assemble(**vars(parser.parse_args())), ensure_ascii=False, indent=2))
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Checkpoint assembly stopped: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
