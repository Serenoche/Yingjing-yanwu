"""Run the read-only store preflight against synthetic PE files and save trees."""
from __future__ import annotations

import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools/Collect-PbzPlatformInfo.ps1"
SHELL = shutil.which("powershell.exe")


def synthetic_pe() -> bytes:
    result = bytearray(512)
    result[:2] = b"MZ"
    struct.pack_into("<I", result, 0x3C, 128)
    result[128:132] = b"PE\0\0"
    struct.pack_into("<HHI", result, 132, 0x8664, 3, 1700000000)
    struct.pack_into("<H", result, 148, 240)
    struct.pack_into("<H", result, 152, 0x20B)
    struct.pack_into("<I", result, 208, 0x9000)
    return bytes(result)


@unittest.skipUnless(SHELL, "Windows PowerShell is required")
class PlatformInfoTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "build").mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / "build", prefix="platform-probe-")
        self.base = Path(self.temp.name).resolve()
        self.assertTrue(self.base.is_relative_to((ROOT / "build").resolve()))
        self.addCleanup(self.temp.cleanup)
        self.game = self.base / "private-install" / "platform" / "steam" / "PBZ.exe"
        self.game.parent.mkdir(parents=True)
        self.game.write_bytes(synthetic_pe())
        self.install = self.game.parents[2]
        (self.install / "ProjectPBZ/Content/Paks").mkdir(parents=True)
        self.account = "12345678901234567"
        self.saves = self.install / "ProjectPBZ/Saved/SaveGames"
        self.save = self.saves / "Steam" / self.account / "PBZSaveGame.sav"
        self.save.parent.mkdir(parents=True)
        self.save.write_bytes(b"Synthetic save content must never be inspected by the collector.")
        self.reports = self.base / "reports"

    def run_probe(self, *extra, exe=None, output=None, ok=True):
        result = subprocess.run(
            [SHELL, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(SCRIPT),
             "-GameExe", str(exe or self.game), "-OutputDirectory", str(output or self.reports),
             "-NoGui", *map(str, extra)], capture_output=True, timeout=20,
        )
        self.assertEqual(result.returncode == 0, ok, result.stderr.decode(errors="replace"))
        if not ok:
            self.assertNotIn(self.account.encode(), result.stderr)
            return None
        files = sorted((output or self.reports).glob("PBZ-Platform-*.json"))
        self.assertTrue(files)
        return json.loads(files[-1].read_text(encoding="utf-8-sig"))

    def test_report_preserves_inputs_and_redacts_identity(self):
        before = {p.relative_to(self.install): p.read_bytes() for p in self.install.rglob("*") if p.is_file()}
        report = self.run_probe("-Platform", "Steam")
        after = {p.relative_to(self.install): p.read_bytes() for p in self.install.rglob("*") if p.is_file()}
        self.assertEqual(before, after)
        self.assertEqual(report["executable"]["sha256"], hashlib.sha256(synthetic_pe()).hexdigest())
        self.assertEqual(report["executable"]["machine"], "0x8664")
        self.assertEqual(report["executable"]["imageBytes"], 0x9000)
        raw = json.dumps(report)
        self.assertNotIn(self.account, raw)
        self.assertNotIn("private-install", raw)
        self.assertNotIn(str(self.base), raw)
        self.assertNotIn("Synthetic save content", raw)
        self.assertTrue(all(v is False for v in report["privacy"].values()))
        self.assertTrue(all(v is False for v in report["actions"].values()))
        rows = report["saveDirectoryShapes"][0]["directories"]
        self.assertTrue(any(r["primarySavePresent"] for r in rows))
        self.assertTrue(any(r["name"] == "redacted" and r["nameShape"] == {"kind": "digits", "length": 17} for r in rows))

    def test_save_content_does_not_need_read_access(self):
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32,
                                      ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
        kernel.CreateFileW.restype = ctypes.c_void_p
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        handle = kernel.CreateFileW(str(self.save), 0x80000000, 0, None, 3, 0, None)
        self.assertNotEqual(handle, ctypes.c_void_p(-1).value)
        try:
            report = self.run_probe()
            rows = report["saveDirectoryShapes"][0]["directories"]
            self.assertTrue(any(r["primarySavePresent"] for r in rows))
            self.assertEqual(report["saveDirectoryShapes"][0]["inaccessibleDirectories"], 0)
        finally:
            kernel.CloseHandle(handle)

    def test_game_and_save_output_locations_are_refused(self):
        for target in (self.install, self.game.parent / "Reports", self.saves / "Reports"):
            with self.subTest(target=target.name):
                self.run_probe(output=target, ok=False)
                self.assertFalse(list(target.glob("PBZ-Platform-*.json")))

    def test_supplied_save_root_is_redacted_and_protected(self):
        external = self.base / "private-user-save-location"
        account = "a1b2c3d4" * 4
        (external / account).mkdir(parents=True)
        (external / account / "PBZSaveGame.sav").write_bytes(b"not read")
        report = self.run_probe("-SaveGamesDirectory", external, "-Platform", "Epic")
        raw = json.dumps(report)
        self.assertEqual(report["declaredStore"], "Epic")
        self.assertNotIn(account, raw)
        self.assertNotIn("private-user-save-location", raw)
        self.assertTrue(any(row["primarySavePresent"] for row in report["saveDirectoryShapes"][1]["directories"]))
        self.run_probe("-SaveGamesDirectory", external, output=external / "Reports", ok=False)

    def test_unknown_layout_is_reported_without_unlocking_support(self):
        custom = self.install / "platform/private-user-token/PBZ.exe"
        custom.parent.mkdir(parents=True)
        custom.write_bytes(synthetic_pe())
        report = self.run_probe("-Platform", "WeGame", exe=custom)
        self.assertEqual(report["layout"]["observedStoreDirectory"], "redacted")
        self.assertNotIn("private-user-token", json.dumps(report))
        self.assertEqual(report["supportVerdict"], "not-established-by-this-report")
        self.assertFalse(report["actions"]["installedSupportUnlocked"])

    def test_invalid_executable_fails_without_writing(self):
        for content in (b"not a PE", b"MZ" + b"\0" * 510):
            self.game.write_bytes(content)
            self.run_probe(ok=False)
        self.assertFalse(self.reports.exists())

    def test_nested_engine_layout_uses_actual_game_root(self):
        nested = self.install / "ProjectPBZ/Binaries/Win64/PBZ.exe"
        nested.parent.mkdir(parents=True)
        nested.write_bytes(synthetic_pe())
        report = self.run_probe(exe=nested)
        self.assertEqual(report["layout"]["launchShape"], "ProjectPBZ/Binaries/<architecture>/PBZ.exe")
        self.assertTrue(report["saveDirectoryShapes"][0]["present"])
        for target in (self.install / "Reports", self.saves / "Reports"):
            self.run_probe(exe=nested, output=target, ok=False)
            self.assertFalse(target.exists())

    def test_unconfirmed_game_root_fails_without_writing(self):
        isolated = self.base / "unrecognized/PBZ.exe"
        isolated.parent.mkdir()
        isolated.write_bytes(synthetic_pe())
        self.run_probe(exe=isolated, ok=False)
        self.assertFalse(self.reports.exists())

    def test_existing_reports_and_unrelated_files_are_preserved(self):
        self.reports.mkdir()
        unrelated = self.reports / "preserve.txt"
        unrelated.write_text("keep", encoding="utf-8")
        self.run_probe()
        self.run_probe()
        self.assertEqual(len(list(self.reports.glob("PBZ-Platform-*.json"))), 2)
        self.assertEqual(unrelated.read_text(encoding="utf-8"), "keep")

    def test_collection_is_bounded(self):
        for index in range(140):
            (self.saves / f"opaque-{index}").mkdir()
        report = self.run_probe()
        shape = report["saveDirectoryShapes"][0]
        self.assertTrue(shape["truncated"])
        self.assertLessEqual(len(shape["directories"]), 128)

    def test_linked_save_children_are_not_followed(self):
        external = self.base / "outside-save-tree"
        external.mkdir()
        (external / "PBZSaveGame.sav").write_bytes(b"not collected")
        junction = self.saves / "linked-account"
        script = self.base / "junction.ps1"
        script.write_text("param($Link,$Target)\n$ErrorActionPreference='Stop'\n$null=New-Item -ItemType Junction -Path $Link -Value $Target\n", encoding="utf-8-sig")
        subprocess.run([SHELL, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
                        str(script), str(junction), str(external)], check=True, capture_output=True)
        try:
            report = self.run_probe()
            shape = report["saveDirectoryShapes"][0]
            self.assertEqual(shape["linkedEntriesSkipped"], 1)
            self.assertEqual(sum(bool(r["primarySavePresent"]) for r in shape["directories"]), 1)
            self.run_probe("-SaveGamesDirectory", junction, ok=False)
        finally:
            # Removing a verified junction does not recurse into its target.
            self.assertEqual(junction.parent.resolve(), self.saves.resolve())
            os.rmdir(junction)

    def test_unicode_and_brackets_in_paths(self):
        target = self.base / "reports [test] 检查"
        report = self.run_probe(output=target)
        self.assertEqual(report["schemaVersion"], 1)

    def test_default_output_works_in_windows_powershell(self):
        tool=self.base/"tool"
        tool.mkdir()
        script=tool/SCRIPT.name
        shutil.copyfile(SCRIPT,script)
        result=subprocess.run([SHELL,"-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File",
                               str(script),"-GameExe",str(self.game),"-NoGui"],capture_output=True,timeout=20)
        self.assertEqual(result.returncode,0,result.stderr.decode(errors="replace"))
        self.assertEqual(len(list((tool/"Reports").glob("*.json"))),1)

    def test_trailing_dot_game_alias_cannot_receive_reports(self):
        target=Path(str(self.install)+".")/"Reports"
        self.run_probe(output=target,ok=False)
        self.assertFalse((self.install/"Reports").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
