"""Build original Windows components. This script never installs or starts the game."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
JSON_SHA256 = "9bea4c8066ef4a1c206b2be5a36302f8926f7fdc6087af5d20b417d0cf103ea6"
GAME_SHA256 = "4415933ce33476f14c837abb61a1b60af8b78cd81783896501913a7aac69e423"
RUNTIME_DATA = ("BossCatalog.lua", "GeneratedEncounterCatalog.lua",
                "GeneratedArenaScenes.lua", "NativeUiAssetsData.lua")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def preset_digest(path: Path, count: int) -> str:
    """Only check framing here. The built tool authenticates every block at runtime."""
    if not path.is_file():
        raise ValueError(f"Local-only preset input is missing: {path}")
    with path.open("rb") as source:
        header = source.read(12)
    if (len(header) != 12 or header[:6] != b"PBZS\x03\x01"
            or struct.unpack_from("<H", header, 6)[0] != count):
        raise ValueError(f"Expected a local PBZS v3 bundle with exactly {count} blocks")
    extent = struct.unpack_from("<I", header, 8)[0]
    if extent < 36 or path.stat().st_size < 12 + extent:
        raise ValueError("Local preset container is truncated")
    return sha256(path)


def find_toolchain(args: argparse.Namespace) -> tuple[str, dict[str, str]]:
    if os.name != "nt":
        raise ValueError("Native builds require Windows and x64 MSVC. Source checks work on other hosts.")
    env = os.environ.copy()
    if args.msvc_root:
        msvc = Path(args.msvc_root).resolve()
        compiler = msvc / "bin/Hostx64/x64/cl.exe"
        sdk_arg = args.windows_sdk_root or env.get("WindowsSdkDir")
        if not sdk_arg:
            program_files = env.get("ProgramFiles(x86)")
            if program_files:
                sdk_arg = str(Path(program_files) / "Windows Kits/10")
        if not sdk_arg:
            raise ValueError("Pass --windows-sdk-root or set WindowsSdkDir")
        sdk = Path(sdk_arg).resolve()
        version = args.sdk_version or env.get("WindowsSDKVersion", "").strip("\\/")
        if not version:
            versions = [p.name for p in (sdk / "Include").glob("*")
                        if (p / "um/Windows.h").is_file()]
            versions.sort(key=lambda s: tuple(int(x) for x in s.split(".")), reverse=True)
            if not versions:
                raise ValueError("No Windows SDK include directory found; pass --sdk-version")
            version = versions[0]
        includes = [msvc / "include"] + [sdk / "Include" / version / name
                                         for name in ("ucrt", "shared", "um")]
        libraries = [msvc / "lib/x64"] + [sdk / "Lib" / version / name / "x64"
                                          for name in ("ucrt", "um")]
        for path in [compiler, *includes, *libraries]:
            if not path.exists():
                raise ValueError(f"Toolchain path is missing: {path}")
        env["INCLUDE"] = os.pathsep.join(map(str, includes))
        env["LIB"] = os.pathsep.join(map(str, libraries))
        env["PATH"] = str(compiler.parent) + os.pathsep + env.get("PATH", "")
        return str(compiler), env
    compiler = args.cl or shutil.which("cl.exe")
    if not compiler:
        raise ValueError("Use an x64 Native Tools command prompt, --cl, or --msvc-root")
    if not env.get("INCLUDE") or not env.get("LIB"):
        raise ValueError("MSVC INCLUDE/LIB are unset; use an x64 Native Tools prompt or --msvc-root")
    return str(compiler), env


def run(command: list[str], output: Path, env: dict[str, str] | None = None) -> None:
    subprocess.run(command, cwd=output, env=env, check=True)


def native(args: argparse.Namespace) -> None:
    parts = ("barrier", "save-tool") if args.component == "all" else (args.component,)
    preset_sha = legacy_sha = ""
    if "save-tool" in parts:
        if not args.presets:
            raise ValueError("SaveTool requires --presets <local eighteen-block bundle>; no game-derived templates are included")
        preset_sha = preset_digest(Path(args.presets), 18)
        if args.legacy_presets:
            legacy_sha = preset_digest(Path(args.legacy_presets), 8)
        if sha256(ROOT / "src/save_tool/vendor/json.hpp") != JSON_SHA256:
            raise ValueError("Vendored nlohmann/json 3.11.3 header checksum differs")
    compiler, env = find_toolchain(args)
    base = [compiler, "/nologo", "/std:c++17", "/O2", "/W4", "/WX", "/EHsc", "/MT", "/utf-8", "/Brepro"]
    output_root = Path(args.output).resolve()
    for part in parts:
        output = output_root / part
        output.mkdir(parents=True, exist_ok=True)
        if part == "barrier":
            source = ROOT / "src/save_barrier"
            target = output / "PBZSaveBarrier.dll"
            run(base + ["/LD", str(source / "barrier.cpp"), "/Fo" + str(output / "barrier.obj"),
                        "/link", "/Brepro", "/OUT:" + str(target)], output, env)
            if args.tests:
                for name in ("barrier_test", "provider_identity_test"):
                    test = output / (name + ".exe")
                    run(base + ["/I" + str(source), str(source / "tests" / (name + ".cpp")),
                                "/Fo" + str(output / (name + ".obj")), "/link", "/Brepro", "/OUT:" + str(test)], output, env)
                    run([str(test)], output)
                run([sys.executable, str(source / "tests/test_wrong_host.py"), "--dll", str(target)], output)
        else:
            source = ROOT / "src/save_tool"
            generated = output / "generated"
            generated.mkdir(exist_ok=True)
            (generated / "build_config.hpp").write_text(
                "#pragma once\nnamespace pbz_build {\n"
                f'inline constexpr const char* presets_sha="{preset_sha}";\n'
                f'inline constexpr const char* legacy_presets_sha="{legacy_sha}";\n'
                f'inline constexpr bool legacy_presets_enabled={str(bool(legacy_sha)).lower()};\n'
                "}\n", encoding="ascii")
            target = output / "PBZSaveTool.exe"
            run(base + ["/I" + str(generated), str(source / "main.cpp"),
                        "/Fo" + str(output / "main.obj"), "/link", "/Brepro", "/OUT:" + str(target)], output, env)
        report = {"component": part, "file": target.name, "sha256": sha256(target),
                  "supportedGameSha256": GAME_SHA256, "installedOrGameLaunched": False}
        if part == "save-tool":
            report.update(presetsSha256=preset_sha, legacyPresetsSha256=legacy_sha or None,
                          jsonHeaderSha256=JSON_SHA256, privateSlotCount=18,
                          scope="Compiled component only; no template or release payload copied")
        (output / "Build.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(report))


def installer(args: argparse.Namespace) -> None:
    if os.name != "nt":
        raise ValueError("The installer host requires Windows .NET Framework csc.exe")
    csc = args.csc
    if not csc:
        windir = os.environ.get("WINDIR")
        if not windir:
            raise ValueError("Pass --csc or set WINDIR")
        csc = str(Path(windir) / "Microsoft.NET/Framework64/v4.0.30319/csc.exe")
    if not Path(csc).is_file():
        raise ValueError("csc.exe is missing; pass --csc <.NET Framework compiler>")
    source = ROOT / "src/installer"
    output = Path(args.output).resolve() / "installer"
    output.mkdir(parents=True, exist_ok=True)
    target = output / "影境演武安装器.exe"
    run([csc, "/nologo", "/target:winexe", "/platform:x64", "/optimize+",
         "/reference:System.Windows.Forms.dll", "/out:" + str(target), str(source / "InstallerHost.cs")], output)
    for pattern in ("*.ps1", "*.cmd"):
        for path in source.glob(pattern):
            shutil.copyfile(path, output / path.name)
    report = {"component": "installer-host", "file": target.name, "sha256": sha256(target),
              "completeRelease": False, "guiStarted": False}
    (output / "InstallerBuild.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False))


def check(args: argparse.Namespace) -> None:
    external = Path(args.external_inputs).resolve() if args.external_inputs else ROOT / "local-inputs"
    missing = []
    missing_generated = [name for name in RUNTIME_DATA
                         if not (ROOT / "src/runtime/Scripts" / name).is_file()]
    for name in ("UIAssets/Manifest.json", "PrivatePresets.pbzs", "UE4SS-release.zip"):
        if not (external / name).is_file():
            missing.append(name)
    report = {"coreSourceReady": all((ROOT / "src" / path).is_file() for path in
                                    ("runtime/Scripts/main.lua", "save_barrier/barrier.cpp", "save_tool/main.cpp", "installer/InstallerHost.cs")),
              "jsonHeaderChecksumValid": sha256(ROOT / "src/save_tool/vendor/json.hpp") == JSON_SHA256,
              "generatedRuntimeDataPresent": not missing_generated,
              "missingGeneratedRuntimeData": missing_generated,
              "completeReleaseInputsPresent": not missing and not missing_generated, "missingLocalOnlyInputs": missing,
              "note": "Presence check only; release packaging must validate schemas, hashes and input rights separately."}
    print(json.dumps(report, indent=2))
    if not report["coreSourceReady"] or not report["jsonHeaderChecksumValid"] or (args.require_release_inputs and (missing or missing_generated)):
        raise ValueError("Source check failed or required local-only release inputs are missing")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    sub = result.add_subparsers(dest="command", required=True)
    p = sub.add_parser("check", help="Cross-platform source and missing-input inventory; no installation")
    p.add_argument("--external-inputs")
    p.add_argument("--require-release-inputs", action="store_true")
    p.set_defaults(action=check)
    p = sub.add_parser("native", help="Compile Windows native components")
    p.add_argument("--component", choices=("barrier", "save-tool", "all"), default="barrier")
    p.add_argument("--output", default=str(ROOT / "build"))
    p.add_argument("--cl")
    p.add_argument("--msvc-root", help="MSVC toolset directory containing bin/Hostx64/x64/cl.exe")
    p.add_argument("--windows-sdk-root")
    p.add_argument("--sdk-version")
    p.add_argument("--presets", help="Read-only local eighteen-block PBZS bundle; never distributed by this script")
    p.add_argument("--legacy-presets", help="Optional read-only local eight-block bundle for legacy ownership migration")
    p.add_argument("--tests", action="store_true", help="Compile/run synthetic barrier and wrong-host tests only")
    p.set_defaults(action=native)
    p = sub.add_parser("installer", help="Compile host and copy its source scripts, without launching GUI")
    p.add_argument("--csc")
    p.add_argument("--output", default=str(ROOT / "build"))
    p.set_defaults(action=installer)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        args.action(args)
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Build stopped: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
