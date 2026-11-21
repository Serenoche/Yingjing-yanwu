"""Exercise the production Windows scripts on disposable copies of an assembled package.

Pass the package directory (containing IntegratedMenu and NativeEnemyRuntime).
The fixture pins an inert PBZ.exe and isolates the process check in its own
copy. It never runs the game, UE4SS, or any installed MOD.
"""
import argparse
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from zipfile import ZipFile


REFERENCE = "4415933ce33476f14c837abb61a1b60af8b78cd81783896501913a7aac69e423"
OWNER = "7d5ad307-d21c-47eb-9584-493443190984"
STEAM_ID_BASE = 0x0110000100000000
ACCOUNT = str(STEAM_ID_BASE + 1)
PACKAGE = None
FIXTURES = None
SHELL = shutil.which("powershell.exe")


def walk_files(directory):
    return {file.relative_to(directory).as_posix(): hashlib.sha256(file.read_bytes()).hexdigest()
            for file in directory.rglob("*") if file.is_file()}


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


RUNNER = r"""
param([string]$ScriptDir,[string]$Game,[string]$Account,[string]$Action,[string]$Reports,[string]$ExpectedGame,[string]$UserSid,
    [switch]$KeepExistingLoader)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
. (Join-Path $ScriptDir 'PortablePaths.ps1')
. (Join-Path $ScriptDir 'PBZInstallHealth.ps1')
. (Join-Path $ScriptDir 'Export-PbzDiagnostics.ps1')
$installer = Join-Path $ScriptDir 'Install-PbzIntegratedMenu.ps1'
$issue = $null
$report = $null
$result = $null
$arguments = @{GameExe=$Game; AccountId=$Account}
if ($ExpectedGame) { $arguments.ExpectedGameExe = $ExpectedGame }
if ($UserSid) { $arguments.UserSid = $UserSid }
if ($KeepExistingLoader) { $arguments.KeepExistingLoader = $true }
if ($Action -ne 'RootDiagnostics') {
    $arguments[$Action] = $true
    try { $result = & $installer @arguments }
    catch {
        $issue = Get-PbzInstallError $_
        $issue.GameExe = $Game
        $issue.Action = $Action
        $script:pbzLastInstallerIssue = $issue
    }
}
if ($Reports) {
    if ($Action -eq 'RootDiagnostics') {
        $folder = (Resolve-PbzGameLayout $Game).InstallRoot
        $report = Export-PbzDiagnostics -GameRoot $folder -OutputDirectory $Reports
    } else {
        $report = Export-PbzDiagnostics -GameExe $Game -OutputDirectory $Reports -AccountId $Account
    }
}
$message = if ($issue) { Format-PbzIssue $issue -ShowRollback }
Write-Output ('PBZTEST:' + (@{issue=$issue; message=$message; result=$result; report=$report.Path} | ConvertTo-Json -Depth 10 -Compress))
"""


@unittest.skipUnless(os.name == "nt" and SHELL, "Requires Windows PowerShell 5.1")
class InstallerP0Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if PACKAGE is None:
            raise unittest.SkipTest("Run this suite against an assembled installer package")

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="p0-", dir=FIXTURES)
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.assertTrue(self.root.is_relative_to(FIXTURES.resolve()))
        self.package = self.root / "package"
        shutil.copytree(PACKAGE, self.package)
        self.scripts = self.package / "IntegratedMenu"
        self.engine = self.scripts / "Install-PbzIntegratedMenu.ps1"
        self.runner = self.root / "Run.ps1"
        self.runner.write_text(RUNNER, encoding="utf-8-sig")
        self.install = self.root / "game"
        self.platform = self.install / "platform/steam"
        self.platform.mkdir(parents=True)
        self.game = self.platform / "PBZ.exe"
        self.game.write_bytes(b"Inert reference-platform file. Never launch this fixture.")
        fixture_hash = hashlib.sha256(self.game.read_bytes()).hexdigest()
        self.rewrite(self.engine, REFERENCE, fixture_hash)
        self.rewrite(self.engine,
                     "return [bool](Get-Process -Name 'PBZ','ProjectPBZ-Win64-Shipping' -ErrorAction SilentlyContinue)",
                     "return $false")
        build = self.scripts / "Tools/Build.json"
        self.rewrite(build, REFERENCE, fixture_hash)
        self.save = self.install / f"ProjectPBZ/Saved/SaveGames/Steam/{ACCOUNT}/PBZSaveGame.sav"
        self.save.parent.mkdir(parents=True)
        self.save.write_bytes(b"Original campaign save. The four-map path must not change this.")
        self.other_save = self.save.parent.parent / str(STEAM_ID_BASE + 2) / "PBZSaveGame.sav"
        self.other_save.parent.mkdir()
        self.other_save.write_bytes(b"Other account campaign content")
        self.state_root = self.install / f"ProjectPBZ/Saved/PBZTestArena/{ACCOUNT}/IntegratedMenu"
        self.state = self.state_root / "InstallState.json"
        self.pending = self.state_root / "InstallerPending.json"
        self.mod = self.platform / "ue4ss/Mods/PBZTestArena"
        self.proxy = self.platform / "dwmapi.dll"
        self.payload = self.package / "NativeEnemyRuntime/Payload"

    def rewrite(self, path, old, new):
        text = path.read_text(encoding="utf-8-sig")
        self.assertEqual(text.count(old), 1, old)
        path.write_text(text.replace(old, new, 1), encoding="utf-8-sig", newline="\n")

    def operation(self, action, *, reports=False, code=None, account=ACCOUNT, interrupted=False,
                  expected_game=None, keep_loader=False, user_sid=None):
        arguments = [SHELL, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
                     str(self.runner), "-ScriptDir", str(self.scripts), "-Game", str(self.game),
                     "-Account", account, "-Action", action]
        if reports:
            arguments += ["-Reports", str(self.root / "reports")]
        if expected_game:
            arguments += ["-ExpectedGame", str(expected_game)]
        if user_sid:
            arguments += ["-UserSid", user_sid]
        if keep_loader:
            arguments += ["-KeepExistingLoader"]
        result = subprocess.run(arguments, capture_output=True, timeout=150)
        if interrupted:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertTrue(self.pending.is_file(), result.stderr)
            return
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        line, = [line for line in result.stdout.splitlines() if line.startswith(b"PBZTEST:")]
        data = json.loads(line[len(b"PBZTEST:"):])
        if code:
            self.assertIsNotNone(data["issue"], data)
            self.assertEqual(data["issue"]["code"], code, data)
        else:
            self.assertIsNone(data["issue"], data)
        return data

    def junction(self, link, target):
        self.assertTrue(link.parent.resolve().is_relative_to(self.root))
        self.assertTrue(target.resolve().is_relative_to(self.root))
        env = dict(os.environ, PBZ_TEST_JUNCTION=str(link), PBZ_TEST_JUNCTION_TARGET=str(target))
        result = subprocess.run([SHELL, "-NoProfile", "-NonInteractive", "-Command",
                                 "$ErrorActionPreference='Stop'; "
                                 "New-Item -ItemType Junction -Path $env:PBZ_TEST_JUNCTION "
                                 "-Target $env:PBZ_TEST_JUNCTION_TARGET | Out-Null"],
                                env=env, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.addCleanup(os.rmdir, link)

    def shared_loader(self):
        core = self.platform / "ue4ss/UE4SS.dll"
        core.parent.mkdir()
        shutil.copyfile(self.payload / "ue4ss/UE4SS.dll", core)
        self.proxy.write_bytes((self.payload / "dwmapi.dll").read_bytes() + b"Independent distribution")
        (core.parent / "UE4SS-settings.ini").write_text("[General]\nEnableHotReloadSystem=0\n", encoding="ascii")
        other = core.parent / "Mods/PbzMapTracker/Scripts/main.lua"
        other.parent.mkdir(parents=True)
        other.write_bytes(b'error("Fixture MOD; do not run")')
        return walk_files(self.platform)

    def test_game_root_junction_installs_patched_presets_and_uninstalls(self):
        actual_game = self.game
        link = self.root / "Steam entry"
        self.junction(link, self.install)
        self.game = link / self.game.relative_to(self.install)
        self.shared_loader()
        log = self.platform / "ue4ss/UE4SS.log"
        log.write_text(f"[2026-11-21 00:50:19.5] Console created\n{self.game}\n{actual_game}\n",
                       encoding="utf-8")
        loader = walk_files(self.platform)
        save = self.save.read_bytes()
        plan = self.operation("Preflight", reports=True)
        self.assertEqual(Path(plan["result"]["gameExe"]), actual_game)
        with ZipFile(plan["report"]) as archive:
            report = json.loads(archive.read("Diagnostics.json"))
            self.assertTrue(report["game"]["linkedRoot"])
            exported = archive.read("UE4SS.log").decode("utf-8")
            self.assertNotIn(str(self.game.parent), exported)
            self.assertNotIn(str(actual_game.parent), exported)
            self.assertIn("<game>", exported)
        self.operation("Install", expected_game=actual_game)
        receipt = read_json(self.state)
        self.assertEqual(Path(receipt["gameExe"]), actual_game)
        self.assertEqual(Path(receipt["savePath"]), self.save)
        native = self.package / "NativeEnemyRuntime"
        overlay = native / "CheckpointPayload/ue4ss/Mods/PBZTestArena/Scripts"
        for name in ("PBZSaveBarrier.dll", "StockArenaPresets.json"):
            self.assertEqual((self.mod / "Scripts" / name).read_bytes(), (overlay / name).read_bytes())
        dll = "ue4ss/Mods/PBZTestArena/Scripts/PBZSaveBarrier.dll"
        installed_hash = receipt["runtimeHashes"][dll]
        if installed_hash == "c8679bb8fc01224568cd23e7fb40c811081ed1562cb7df5dcc4ac7c3306102d6":
            # Recreate the old receipt left by a manual 2.0.1 DLL replacement.
            receipt["runtimeHashes"][dll] = "edc65b15172e718039e0937325531a2719bb0d144fbd5e9804b6ec98668372d0"
            self.state.write_text(json.dumps(receipt), encoding="utf-8")
        self.operation("Install", expected_game=actual_game)
        self.assertEqual(read_json(self.state)["runtimeHashes"][dll], installed_hash)
        self.game = actual_game
        self.assertEqual(self.operation("Preflight")["result"]["state"], "installed")
        self.game = link / actual_game.relative_to(self.install)
        self.operation("Uninstall", expected_game=actual_game)
        self.assertEqual(self.save.read_bytes(), save)
        self.assertEqual(walk_files(self.platform), loader)
        self.assertEqual(link.resolve(), self.install)

    def test_game_root_junction_rejects_retarget_after_check(self):
        link = self.root / "Steam entry"
        alternate = self.root / "Other installation"
        shutil.copytree(self.install, alternate)
        self.junction(link, alternate)
        actual_game = self.game
        self.game = link / actual_game.relative_to(self.install)
        self.operation("Install", code="GAME_PATH_CHANGED", expected_game=actual_game)
        self.assertFalse(self.mod.exists())
        self.assertFalse((alternate / "platform/steam/ue4ss").exists())

    def test_linked_loader_inside_game_is_still_refused(self):
        loader = self.root / "External loader"
        loader.mkdir()
        canary = loader / "OtherMod"
        canary.write_bytes(b"unchanged")
        self.junction(self.platform / "ue4ss", loader)
        outcome = self.operation("Install", code="LINKED_PATH")
        self.assertIn("原 MOD 管理器", outcome["message"])
        self.assertEqual(canary.read_bytes(), b"unchanged")
        self.assertFalse(self.state.exists())

    def report(self, status):
        archive_path = Path(status["report"])
        with ZipFile(archive_path) as archive:
            self.assertFalse(any(name.endswith((".sav", ".dmp")) for name in archive.namelist()))
            content = archive.read("Diagnostics.json")
            self.assertNotIn(ACCOUNT.encode(), content)
            self.assertNotIn(self.root.name.encode(), content)
            return json.loads(content)

    def test_1118_missing_shared_runtime_repair_and_cleanup(self):
        other = self.shared_loader()
        self.operation("Install")
        saved = walk_files(self.save.parent.parent)
        receipt = self.state.read_bytes()
        preferences = self.state_root.parent / "ArenaPreferences/PBZLoadout.tsv"
        profile = self.state_root / "ArenaData/Profile/PBZChallengeHistory.tsv"
        preferences.write_bytes(b"retained equipment")
        profile.write_bytes(b"retained report history")
        self.mod.rename(self.root / "missing-original")
        before = walk_files(self.install)
        plan = self.operation("Preflight")["result"]
        self.assertEqual((plan["state"], plan["action"]), ("runtime_missing", "Repair"))
        self.assertEqual(walk_files(self.install), before)
        self.assertEqual(self.state.read_bytes(), receipt)
        self.operation("Install")
        self.assertTrue((self.mod / "Scripts/IntegratedConfig.lua").is_file())
        self.assertEqual(walk_files(self.save.parent.parent), saved)
        repaired = read_json(self.state)
        self.assertEqual((Path(repaired["backup"]) / "InstallState.json").read_bytes(), receipt)
        self.assertTrue((Path(repaired["backup"]) / "TransactionComplete.json").is_file())
        for path, digest in other.items():
            self.assertEqual(hashlib.sha256((self.platform / path).read_bytes()).hexdigest(), digest)
        self.mod.rename(self.root / "missing-again")
        self.operation("Uninstall")
        self.assertFalse(read_json(self.state)["installed"])
        self.assertEqual(walk_files(self.save.parent.parent), saved)
        self.assertEqual(preferences.read_bytes(), b"retained equipment")
        self.assertEqual(profile.read_bytes(), b"retained report history")
        self.operation("Install")

    def test_1117_orphan_proxy_preserved_even_if_known_bytes(self):
        for content in (b"Unknown proxy", (self.payload / "dwmapi.dll").read_bytes()):
            with self.subTest(sha=hashlib.sha256(content).hexdigest()):
                self.proxy.write_bytes(content)
                before = walk_files(self.install)
                blocked = self.operation("Preflight", code="LOADER_ORPHAN", reports=True)
                report = self.report(blocked)
                self.assertEqual(report["loaderFiles"]["dwmapi.dll"]["sha256"], hashlib.sha256(content).hexdigest())
                self.assertEqual(report["loaderFiles"]["ue4ss"]["status"], "missing")
                self.assertEqual(report["installIssue"]["rollback"], "unchanged")
                self.operation("Install", code="LOADER_ORPHAN")
                self.assertEqual(walk_files(self.install), before)

    def test_verified_prior_proxy_is_backed_up_for_install(self):
        self.operation("Install")
        proxy = self.proxy.read_bytes()
        self.mod.parents[1].rename(self.root / "missing-owned-loader")
        plan = self.operation("Preflight")["result"]
        self.assertEqual(plan["action"], "Install")
        self.operation("Install")
        result = read_json(Path(read_json(self.state)["backup"]) / "Result.json")
        self.assertEqual(Path(result["proxyBackup"]).read_bytes(), proxy)
        self.assertTrue(self.mod.is_dir())

    def test_1117_locked_uninstall_can_retry(self):
        other = self.shared_loader()
        self.operation("Install")
        before = walk_files(self.install)
        open_file = ctypes.WinDLL("kernel32", use_last_error=True).CreateFileW
        open_file.argtypes = (wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
                              wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE)
        open_file.restype = wintypes.HANDLE
        file = self.mod / "Scripts/main.lua"
        handle = open_file(str(file), 0x80000000, 1, None, 3, 0, None)  # FILE_SHARE_READ only
        self.assertNotEqual(handle, ctypes.c_void_p(-1).value, ctypes.get_last_error())
        close_handle = ctypes.WinDLL("kernel32", use_last_error=True).CloseHandle
        close_handle.argtypes = (wintypes.HANDLE,)
        try:
            status = self.operation("Uninstall", code="FILE_IN_USE", reports=True)
            report = self.report(status)
            self.assertEqual(report["installIssue"]["nativeCode"], 32)
            self.assertEqual(report["installIssue"]["rollback"], "unchanged")
            self.assertEqual(walk_files(self.install), before)
        finally:
            close_handle(handle)
        saved = walk_files(self.save.parent.parent)
        self.operation("Uninstall")
        self.assertFalse(self.mod.exists())
        self.assertFalse(read_json(self.state)["installed"])
        self.assertEqual(walk_files(self.save.parent.parent), saved)
        self.assertEqual(walk_files(self.platform), other)

    def test_uninstall_reports_permission_denial_separately(self):
        self.shared_loader()
        self.operation("Install")
        snapshot = walk_files(self.install)
        health = self.scripts / "PBZInstallHealth.ps1"
        original = health.read_bytes()
        native_call = "return [PbzInstaller.FileAccessProbe]::Check($Path, $Access)"
        # The build agent may have backup/restore privileges. Inject Win32
        # error 5 only for this disposable backup folder.
        self.rewrite(health, native_call, """if ($Access -eq 6 -and (Split-Path -Leaf $Path) -eq 'Backups') { return 5 }
    """ + native_call)
        result = self.operation("Uninstall", code="ACCESS_DENIED", reports=True)
        self.assertEqual(self.report(result)["installIssue"]["nativeCode"], 5)
        self.assertEqual(walk_files(self.install), snapshot)
        health.write_bytes(original)
        self.operation("Uninstall")
        self.assertFalse(self.mod.exists())

    def test_1117_exe_missing_and_root_only_diagnostics(self):
        self.game.rename(self.root / "missing-exe")
        before = walk_files(self.install)
        report = self.report(self.operation("Preflight", code="GAME_EXE_MISSING", reports=True))
        self.assertEqual(report["game"]["executableStatus"], "missing")
        root_report = self.report(self.operation("RootDiagnostics", reports=True))
        self.assertEqual(root_report["game"]["platform"], "Steam")
        self.assertEqual(root_report["game"]["executableStatus"], "missing")
        self.assertIsNone(root_report["game"]["executableSha256"])
        self.assertEqual(walk_files(self.install), before)

    def test_interrupted_uninstall_restores_runtime_and_keeps_newer_save(self):
        self.shared_loader()
        self.operation("Install")
        receipt = self.state.read_bytes()
        runtime = walk_files(self.mod)
        shared_script = self.scripts / "SharedRuntime.ps1"
        original = shared_script.read_bytes()
        anchor = "Move-PbzTransactionPath $modDirectory $movedMod"
        self.rewrite(shared_script, anchor, anchor + "\n            [Environment]::Exit(86)")
        self.operation("Uninstall", interrupted=True)
        self.assertFalse(self.mod.exists())
        shared_script.write_bytes(original)
        self.assertEqual(self.operation("Preflight")["result"]["action"], "Recover")
        self.operation("Install", code="RECOVERY_PENDING")
        # A newer cloud copy arrived while the first operation was interrupted.
        self.save.write_bytes(b"A newer cloud copy")
        self.operation("Recover")
        self.assertFalse(self.pending.exists())
        self.assertEqual(walk_files(self.mod), runtime)
        self.assertEqual(self.state.read_bytes(), receipt)
        self.assertEqual(self.save.read_bytes(), b"A newer cloud copy")
        self.operation("Uninstall")

    def test_failed_install_removes_bundled_runtime_and_live_staging(self):
        original = walk_files(self.install)
        anchor = 'Write-PbzTransactionText $statePath ($state | ConvertTo-Json -Depth 8)'
        self.rewrite(self.engine, anchor, anchor + '\n        throw "Injected install failure"')
        failure = self.operation("Install", code="CHECK_FAILED")
        self.assertIn("本次对游戏、存档和现有 MOD 的改动已撤销", failure["message"])
        self.assertNotIn("Injected install failure", failure["message"])
        self.assertEqual(failure["issue"]["rollback"], "rolled_back")
        self.assertFalse(self.pending.exists())
        active = {name: digest for name, digest in walk_files(self.install).items()
                  if not name.startswith("ProjectPBZ/Saved/PBZTestArena/")}
        self.assertEqual(active, original)
        self.assertFalse((self.state_root / "ArenaData").exists())
        self.assertFalse((self.state_root.parent / "ArenaPreferences").exists())
        run, = (self.state_root / "Backups").iterdir()
        self.assertFalse((run / "Work").exists())

    def test_extraction_path_too_long_reports_a_short_directory(self):
        before = walk_files(self.install)
        package = self.package
        max_relative = max(map(len, read_json(package / "PackageManifest.json")["files"]))
        long_root = self.root / ("x" * (261 - max_relative - len(str(self.root)) - 2))
        self.assertGreaterEqual(len(str(long_root)) + 1 + max_relative, 260)
        package.rename(long_root)
        try:
            self.scripts = long_root / "IntegratedMenu"
            result = self.operation("Preflight", code="PACKAGE_PATH_TOO_LONG")
            self.assertIn("解压路径过长", result["message"])
            self.assertIn("完整解压", result["message"])
            self.assertEqual(walk_files(self.install), before)
        finally:
            long_root.rename(package)

    def test_missing_package_payload_and_unsupported_game_offer_different_actions(self):
        payload = self.payload / "dwmapi.dll"
        data = payload.read_bytes()
        payload.unlink()
        before = walk_files(self.install)
        missing = self.operation("Preflight", code="CHECK_FAILED")
        self.assertIn("重新下载", missing["message"])
        self.assertNotIn("Get-Item", missing["message"])
        self.assertEqual(walk_files(self.install), before)

        payload.write_bytes(data)
        self.game.write_bytes(b"Different game executable")
        before = walk_files(self.install)
        unsupported = self.operation("Install", code="UNSUPPORTED_BUILD")
        self.assertIn("验证游戏文件", unsupported["message"])
        self.assertEqual(walk_files(self.install), before)

    def test_game_library_path_too_long_identifies_game_instead_of_zip(self):
        original = self.install
        before = walk_files(original)
        longer = self.root / ("g" * (139 - len(str(self.root))))
        original.rename(longer)
        try:
            self.game = longer / "platform/steam/PBZ.exe"
            failure = self.operation("Preflight", code="GAME_PATH_TOO_LONG")
            self.assertIn("把游戏移到路径较短的游戏库", failure["message"])
            self.assertEqual(walk_files(longer), before)
        finally:
            longer.rename(original)

    @unittest.skipIf(os.name == "nt" and ctypes.windll.kernel32.GetACP() == 65001,
                     "The fixture requires a non-UTF-8 Windows code page")
    def test_non_ascii_game_root_reports_how_to_move_the_game(self):
        original = self.install
        library = self.root / "中文游戏库"
        original.rename(library)
        try:
            self.game = library / "platform/steam/PBZ.exe"
            before = walk_files(library)
            for action in ("Preflight", "Install"):
                result = self.operation(action, code="GAME_PATH_ENCODING")
                self.assertIn("把游戏移到纯英文路径", result["message"])
                self.assertEqual(walk_files(library), before)
        finally:
            library.rename(original)

    def test_bundled_update_backs_up_modified_and_missing_arena_files(self):
        self.operation("Install")
        scripts = self.mod / "Scripts"
        main = (scripts / "main.lua").read_bytes()
        original = (scripts / "StockArenaPresets.json").read_bytes()
        local = main + b"\n-- local change"
        (scripts / "main.lua").write_bytes(local)
        (scripts / "StockArenaPresets.json").unlink()
        self.assertEqual(self.operation("Preflight")["result"]["action"], "Install")
        self.operation("Install")
        run = Path(read_json(self.state)["backup"])
        moved = Path(read_json(run / "Result.json")["runtimeBackup"])
        self.assertEqual((moved / "Mods/PBZTestArena/Scripts/main.lua").read_bytes(), local)
        self.assertEqual((scripts / "main.lua").read_bytes(), main)
        self.assertEqual((scripts / "StockArenaPresets.json").read_bytes(), original)

    def test_install_restores_verified_bundled_loader_when_core_is_missing(self):
        self.operation("Install")
        core = self.platform / "ue4ss/UE4SS.dll"
        expected = hashlib.sha256(core.read_bytes()).hexdigest()
        core.unlink()
        self.operation("Preflight")
        self.operation("Install")
        self.assertEqual(hashlib.sha256(core.read_bytes()).hexdigest(), expected)
        self.assertTrue(self.mod.is_dir())

    def test_corrupt_receipt_rebuild_preserves_shared_loader_profiles_and_old_copy(self):
        other = self.shared_loader()
        self.operation("Install")
        prefs = self.state_root.parent / "ArenaPreferences/PBZLoadout.tsv"
        prefs.write_bytes(b"player equipment")
        old_main = b"-- Previous installation changed locally"
        (self.mod / "Scripts/main.lua").write_bytes(old_main)
        old_state = b"{bad JSON"
        self.state.write_bytes(old_state)
        before = walk_files(self.install)
        plan = self.desktop_plan(click_check=True)
        self.assertEqual(plan["action"], "Install", plan)
        self.assertEqual(plan["primaryLabel"], "仅覆盖演武 MOD", plan)
        self.assertEqual(walk_files(self.install), before)

        self.operation("Install", keep_loader=True)
        run = Path(read_json(self.state)["backup"])
        self.assertEqual((run / "RuntimeBefore/Scripts/main.lua").read_bytes(), old_main)
        self.assertEqual((run / "InstallState.json").read_bytes(), old_state)
        self.assertEqual(prefs.read_bytes(), b"player equipment")
        installed = walk_files(self.platform)
        self.assertEqual({path: installed[path] for path in other}, other)
        self.assertEqual(self.save.read_bytes(), b"Original campaign save. The four-map path must not change this.")

    def test_matching_legacy_pending_mod_is_overwritten_without_uninstall(self):
        self.shared_loader()
        self.mod.mkdir()
        (self.mod / ".PBZTestArenaShared-owner").write_text(OWNER, encoding="ascii")
        (self.mod / ".PBZTestArenaPending-install.json").write_bytes(b"Old pending receipt")
        self.operation("Install", keep_loader=True)
        backup = Path(read_json(self.state)["backup"]) / "RuntimeBefore"
        self.assertEqual((backup / ".PBZTestArenaPending-install.json").read_bytes(), b"Old pending receipt")
        self.assertFalse((self.mod / ".PBZTestArenaPending-install.json").exists())
        self.assertFalse((self.mod / "Scripts/CompatibilityPending.lua").exists())

    def test_unrecognized_same_name_is_left_in_place(self):
        self.shared_loader()
        self.mod.mkdir()
        (self.mod / "OtherContent.txt").write_bytes(b"Independent mod with the same folder name")
        before = walk_files(self.install)
        outcome = self.operation("Install", code="MOD_OWNERSHIP_UNKNOWN")
        self.assertIn("备份并移出 Mods 目录", outcome["message"])
        self.assertEqual(walk_files(self.install), before)

    def test_shared_ue4ss_incompatible_configs_have_actionable_messages(self):
        self.shared_loader()
        settings = self.platform / "ue4ss/UE4SS-settings.ini"
        base = settings.read_text(encoding="ascii")
        cases = [
            (base + "\n[Overrides]\nModsFolderPaths=R:\\Mods\n", "自定义的 MOD 路径"),
            (base.replace("=0", "=1"), "关闭热重载"),
        ]
        for contents, message in cases:
            with self.subTest(message=message):
                settings.write_text(contents, encoding="ascii")
                before = walk_files(self.install)
                result = self.operation("Preflight", code="LOADER_CONFLICT")
                self.assertIn(message, result["message"])
                self.assertEqual(walk_files(self.install), before)
        settings.write_text(base, encoding="ascii")
        (self.platform / "ue4ss/Mods/mods.txt").write_text("PBZTestArena : 0\n", encoding="ascii")
        before = walk_files(self.install)
        result = self.operation("Install", code="MOD_DISABLED")
        self.assertIn("原 MOD 管理器启用", result["message"])
        self.assertEqual(walk_files(self.install), before)

    def test_reuse_loader_selection_never_installs_bundled_loader(self):
        before = walk_files(self.install)
        result = self.operation("Install", keep_loader=True, code="LOADER_CONFLICT")
        self.assertIn("原 UE4SS 在检查后发生变化", result["message"])
        self.assertEqual(walk_files(self.install), before)

    def test_failed_overlay_restores_old_mod_receipt_permissions_and_player_files(self):
        self.shared_loader()
        self.operation("Install")
        env = dict(os.environ, PBZ_P2_TEST_ACCOUNT_ROOT=str(self.state_root.parent))
        acl = [SHELL, "-NoProfile", "-NonInteractive", "-Command",
               "$ErrorActionPreference='Stop'; $section=[Security.AccessControl.AccessControlSections]::Access; "
               "[IO.Directory]::GetAccessControl($env:PBZ_P2_TEST_ACCOUNT_ROOT,$section).GetSecurityDescriptorSddlForm($section)"]
        before_acl = subprocess.run(acl, env=env, capture_output=True)
        self.assertEqual(before_acl.returncode, 0, before_acl.stderr.decode(errors="replace"))
        before = {name: digest for name, digest in walk_files(self.install).items() if "IntegratedMenu/Backups/" not in name}
        anchor = 'Write-PbzTransactionText $statePath ($state | ConvertTo-Json -Depth 8)'
        self.rewrite(self.scripts / "SharedRuntime.ps1", anchor,
                     anchor + "\n        throw [IO.IOException]::new('Fixture disk full', -2147024784)")
        synthetic_sid = "S-" + "-".join(str(part) for part in (1, 5, 21, 4121, 4122, 4123, 1978))
        result = self.operation("Install", keep_loader=True, code="DISK_FULL", user_sid=synthetic_sid)
        self.assertIn("磁盘空间不足", result["message"])
        self.assertEqual(result["issue"]["rollback"], "rolled_back")
        after = {name: digest for name, digest in walk_files(self.install).items() if "IntegratedMenu/Backups/" not in name}
        self.assertEqual(after, before)
        after_acl = subprocess.run(acl, env=env, capture_output=True)
        self.assertEqual(after_acl.returncode, 0, after_acl.stderr.decode(errors="replace"))
        self.assertEqual(after_acl.stdout, before_acl.stdout)

    def test_interrupted_install_rolls_back_maps_and_bridges_only(self):
        self.shared_loader()
        runtime = self.payload.parent
        manifest_path = runtime / "ArenaMaps.json"
        manifest = read_json(manifest_path)
        manifest["settlementAudio"] = {}
        (runtime / "ArenaMaps").mkdir(exist_ok=True)
        for suffix in ("pak", "utoc", "ucas"):
            name = f"zzz_PBZEndingR38_Audio_P.{suffix}"
            content = f"Fixture only: {name}".encode()
            (runtime / "ArenaMaps" / name).write_bytes(content)
            manifest["settlementAudio"][name] = hashlib.sha256(content).hexdigest()
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

        project = self.install / "ProjectPBZ"
        fixtures = ("Content/Paks/~mods/AnotherMap.pak", "PBZModLoader/mods/AnotherMod/main.js",
                    "PBZModLoader/mods.ini", "Content/JavaScript/PBZModLoader/bootstrap.js",
                    "Content/JavaScript/PBZModLoader/manager.js")
        for relative in fixtures:
            path = project / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(relative.encode())
        before = walk_files(self.install)
        shared_script = self.scripts / "SharedRuntime.ps1"
        anchor = "Set-PbzLoaderBridgeTransaction $loaderBridges $run"
        self.rewrite(shared_script, anchor, anchor + "\n        [Environment]::Exit(86)")
        self.operation("Install", interrupted=True)
        self.assertTrue((project / "Content/Paks/~mods/zzz_PBZEndingR38_Audio_P.pak").exists())
        self.assertTrue((project / "PBZModLoader/mods/PBZFrostEventR3/main.js").exists())
        self.operation("Recover")
        active = {name: digest for name, digest in walk_files(self.install).items()
                  if not name.startswith("ProjectPBZ/Saved/PBZTestArena/")}
        self.assertEqual(active, before)
        self.assertFalse((project / "PBZModLoader/mods/PBZFrostEventR3").exists())

    def test_interrupted_legacy_uninstall_has_recovery(self):
        other = self.shared_loader()
        self.mod.mkdir()
        files = {".PBZTestArenaShared-owner": OWNER.encode(), "main.lua": b"old main", "enabled.txt": b""}
        for name, content in files.items():
            (self.mod / name).write_bytes(content)
        receipt = {"schemaVersion": 1, "owner": OWNER, "kind": "compatibility-pending", "gameExe": str(self.game),
                   "files": {name: hashlib.sha256(content).hexdigest() for name, content in files.items()}}
        (self.mod / ".PBZTestArenaPending-install.json").write_text(json.dumps(receipt), encoding="utf-8")
        before = walk_files(self.install)
        script = self.scripts / "CompatibilityInstall.ps1"
        original = script.read_bytes()
        anchor = "Move-PbzTransactionPath $modDirectory (Join-Path $run 'RuntimeBefore')"
        self.rewrite(script, anchor, anchor + "\n        [Environment]::Exit(86)")
        self.operation("Uninstall", interrupted=True)
        self.assertFalse(self.mod.exists())
        script.write_bytes(original)
        self.operation("Recover")
        active = {name: digest for name, digest in walk_files(self.install).items()
                  if not name.startswith("ProjectPBZ/Saved/PBZTestArena/")}
        self.assertEqual(active, before)
        self.operation("Uninstall")
        self.assertEqual(walk_files(self.platform), other)

    def test_interrupted_shared_install_recovers_after_game_update(self):
        other = self.shared_loader()
        save = self.save.read_bytes()
        shared_script = self.scripts / "SharedRuntime.ps1"
        anchor = "Move-PbzTransactionPath $stage $modDirectory"
        self.rewrite(shared_script, anchor, anchor + "\n            [Environment]::Exit(86)")
        self.operation("Install", interrupted=True)
        self.assertTrue(self.mod.exists())
        self.game.write_bytes(b"The platform installed a new game executable")
        self.assertEqual(self.operation("Preflight")["result"]["action"], "Recover")
        self.operation("Recover")
        self.assertFalse(self.pending.exists())
        self.assertFalse(self.state.exists())
        self.assertEqual(self.save.read_bytes(), save)
        del other["PBZ.exe"]
        active = walk_files(self.platform)
        del active["PBZ.exe"]
        self.assertEqual(active, other)

    def test_conflicted_runtime_does_not_block_independent_undo(self):
        self.shared_loader()
        shared_script = self.scripts / "SharedRuntime.ps1"
        anchor = 'Write-PbzTransactionText $statePath ($state | ConvertTo-Json -Depth 8)'
        self.rewrite(shared_script, anchor, anchor + "\n        [Environment]::Exit(86)")
        self.operation("Install", interrupted=True)
        unexpected = self.mod / "another-tool.txt"
        unexpected.write_bytes(b"Created by another tool after interruption")
        self.operation("Recover", code="RECOVERY_CONFLICT")
        self.assertFalse(self.state.exists())
        self.assertEqual(unexpected.read_bytes(), b"Created by another tool after interruption")
        self.assertTrue(self.pending.is_file())
        unexpected.unlink()
        self.operation("Recover")
        self.assertFalse(self.mod.exists())
        self.assertFalse(self.pending.exists())

    def test_recovery_never_restores_old_save_over_changed_contents(self):
        self.shared_loader()
        self.operation("Install")
        run = Path(read_json(self.state)["backup"])
        old = hashlib.sha256((run / "Before.sav").read_bytes()).hexdigest()
        expected = hashlib.sha256(b"candidate save").hexdigest()
        journal = {"version": 1, "owner": OWNER, "game": str(self.game), "save": str(self.save),
                   "id": run.name, "action": "Install", "newerSaveKept": False,
                   "steps": [{"kind": "file", "target": str(self.save), "before": old, "after": expected}]}
        self.pending.write_text(json.dumps(journal), encoding="utf-8")
        self.save.write_bytes(b"Cloud changed this after the planned save write")
        self.operation("Recover")
        self.assertEqual(self.save.read_bytes(), b"Cloud changed this after the planned save write")
        self.assertTrue(read_json(run / "TransactionRolledBack.json")["newerSaveKept"])

    def test_recovery_restores_newer_copy_displaced_by_atomic_swap(self):
        self.shared_loader()
        self.operation("Install")
        run = Path(read_json(self.state)["backup"])
        before = hashlib.sha256((run / "Before.sav").read_bytes()).hexdigest()
        staged = b"Verified candidate installed by atomic swap"
        newer = b"Cloud save that arrived just before the atomic swap"
        step = {"kind": "file", "target": str(self.save), "before": before,
                "after": hashlib.sha256(staged).hexdigest()}
        self.pending.write_text(json.dumps({"version": 1, "owner": OWNER, "game": str(self.game),
                                            "save": str(self.save), "id": run.name, "action": "Install",
                                            "newerSaveKept": False, "steps": [step]}), encoding="utf-8")
        self.save.write_bytes(staged)
        (run / "Replaced.sav").write_bytes(newer)
        self.operation("Recover")
        self.assertEqual(self.save.read_bytes(), newer)
        self.assertTrue(read_json(run / "TransactionRolledBack.json")["newerSaveKept"])

    def test_interrupted_rollback_recovers_cloud_save_displaced_during_undo(self):
        self.shared_loader()
        self.operation("Install")
        run = Path(read_json(self.state)["backup"])
        before = hashlib.sha256(self.save.read_bytes()).hexdigest()
        candidate = b"Installer save candidate"
        newer = b"A cloud write during rollback"
        step = {"kind": "file", "target": str(self.save), "before": before,
                "after": hashlib.sha256(candidate).hexdigest()}
        self.pending.write_text(json.dumps({"version": 2, "owner": OWNER, "game": str(self.game),
                                            "save": str(self.save), "id": run.name, "action": "Install",
                                            "newerSaveKept": False, "toolWork": False, "steps": [step]}),
                                encoding="utf-8")
        (run / "RecoverySaveDisplaced.sav").write_bytes(newer)
        self.operation("Recover")
        self.assertEqual(self.save.read_bytes(), newer)
        self.assertTrue(read_json(run / "TransactionRolledBack.json")["newerSaveKept"])

    def test_forced_exit_after_compatibility_save_swap_restores_original_bytes(self):
        original = self.save.read_bytes()
        other = self.other_save.read_bytes()
        self.rewrite(self.engine, "    Assert-PortableTools", "    Assert-PortableTools\n    $checkpointFlow = 'compatibility'")
        definition = "function Invoke-SaveTool([string] $SavePath, [string] $Output, [string] $PriorManifest) {"
        self.rewrite(self.engine, definition, definition.replace("Invoke-SaveTool", "Invoke-OriginalSaveTool"))
        anchor = "function Replace-Save("
        self.rewrite(self.engine, anchor, r"""
function Invoke-SaveTool([string] $SavePath, [string] $Output, [string] $PriorManifest) {
    Write-NewText $Output 'Synthetic compatibility save candidate'
    return @{report=@{sourceSha256=(Get-Hash $SavePath);outputSha256=(Get-Hash $Output)};json='{}'}
}

""" + anchor)
        swap = "[IO.File]::Replace($pending,$Destination,$Rollback)"
        self.rewrite(self.engine, swap, swap + "\n        [Environment]::Exit(86)")
        self.operation("Install", interrupted=True)
        self.assertEqual(self.save.read_bytes(), b"Synthetic compatibility save candidate")
        self.operation("Recover")
        self.assertEqual(self.save.read_bytes(), original)
        self.assertEqual(self.other_save.read_bytes(), other)
        self.assertFalse(self.mod.exists())
        self.assertEqual(list((self.state_root.parent / "T").iterdir()), [])

    def test_bundled_runtime_repair_keeps_loader_ownership(self):
        self.operation("Install")
        save = self.save.read_bytes()
        before = walk_files(self.platform)
        self.mod.rename(self.root / "missing-owned-mod")
        self.assertEqual(self.operation("Preflight")["result"]["action"], "Repair")
        self.operation("Repair")
        self.assertEqual(read_json(self.state)["version"], 2)
        for name in ("dwmapi.dll", "ue4ss/UE4SS.dll"):
            self.assertEqual(hashlib.sha256((self.platform / name).read_bytes()).hexdigest(), before[name])
        self.operation("Uninstall")
        self.assertFalse(self.proxy.exists())
        self.assertEqual(self.save.read_bytes(), save)

    def test_uninstall_keeps_mod_added_to_bundled_shared_folder(self):
        self.operation("Install")
        dependency = self.platform / "ue4ss/Mods/shared/AnotherMod/main.lua"
        dependency.parent.mkdir(parents=True)
        dependency.write_bytes(b"Shared library installed by another MOD")
        save = self.save.read_bytes()
        proxy = self.proxy.read_bytes()
        self.operation("Uninstall")
        self.assertFalse(self.mod.exists())
        self.assertEqual(dependency.read_bytes(), b"Shared library installed by another MOD")
        self.assertEqual(self.proxy.read_bytes(), proxy)
        self.assertEqual(self.save.read_bytes(), save)

    def desktop_plan(self, *, click_check):
        gui = self.scripts / "Open-PbzInstaller.ps1"
        probe = self.scripts / "UiFixture.ps1"
        probe.write_bytes(gui.read_bytes())
        click = r"""
$flags = [System.Reflection.BindingFlags]'Instance,NonPublic'
$onClick = $checkButton.GetType().GetMethod('OnClick',$flags)
[void]$onClick.Invoke($checkButton,@([EventArgs]::Empty))
""" if click_check else ""
        self.rewrite(probe, "[void]$form.ShowDialog()", r"""
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
""" + click + r"""
Write-Output ('PBZUI:' + (@{action=$script:pbzPlan.action; diagnostic=$diagnosticsButton.Enabled;
    primary=$installButton.Enabled; primaryLabel=$installButton.Text; uninstall=$uninstallButton.Enabled;
    status=$status.Text} | ConvertTo-Json -Compress))
$form.Dispose()
""".strip())
        result = subprocess.run([SHELL, "-NoProfile", "-NonInteractive", "-STA", "-ExecutionPolicy", "Bypass",
                                 "-File", str(probe), "-GameExe", str(self.game), "-AccountId", ACCOUNT],
                                capture_output=True, timeout=40)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        line, = [line for line in result.stdout.splitlines() if line.startswith(b"PBZUI:")]
        return json.loads(line[len(b"PBZUI:"):])

    def test_desktop_check_enables_expected_primary_action(self):
        summary = self.desktop_plan(click_check=True)
        self.assertEqual(summary["action"], "Install", summary)
        self.assertTrue(summary["diagnostic"] and summary["primary"], summary)

    def test_desktop_preflight_dependency_missing_guides_reextraction(self):
        (self.scripts / "PBZRuntimeRepair.ps1").unlink()
        summary = self.desktop_plan(click_check=True)
        self.assertTrue(summary["diagnostic"], summary)
        self.assertFalse(summary["primary"], summary)
        self.assertIn("完整解压 ZIP", summary["status"])

    def test_desktop_reopen_offers_recovery_without_manual_check(self):
        self.shared_loader()
        shared_script = self.scripts / "SharedRuntime.ps1"
        anchor = "Start-PbzTransaction $run $operationName"
        self.rewrite(shared_script, anchor, anchor + "\n        [Environment]::Exit(86)")
        self.operation("Install", interrupted=True)
        summary = self.desktop_plan(click_check=False)
        self.assertEqual(summary["action"], "Recover", summary)
        self.assertTrue(summary["diagnostic"] and summary["primary"], summary)
        self.assertFalse(summary["uninstall"], summary)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("--fixtures", type=Path, required=True, help="Existing writable directory for disposable trees")
    options, tests = parser.parse_known_args()
    PACKAGE, FIXTURES = options.package.resolve(strict=True), options.fixtures.resolve(strict=True)
    unittest.main(argv=[__file__, *tests], verbosity=2)
