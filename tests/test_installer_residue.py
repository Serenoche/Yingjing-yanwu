"""Windows-only ownership checks; never install or inspect a game or save."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name == "nt", "Windows PowerShell filesystem semantics")
class InstallerResidueTests(unittest.TestCase):
    def test_empty_uninstaller_residue_and_foreign_files(self):
        build = ROOT / "build"
        build.mkdir(exist_ok=True)
        fixture = Path(tempfile.mkdtemp(prefix="installer-ownership-", dir=build)).resolve()
        self.assertTrue(fixture.is_relative_to(build.resolve()))
        source = ROOT / "src/installer/Install-PbzIntegratedMenu.ps1"
        script = r'''
param([string]$Source,[string]$Fixture)
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Source did not parse'}
# Load only the two preflight functions, not the installer entry point.
foreach($name in @('Assert-OrdinaryPath','Assert-OwnedRuntime')) {
    $definition=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    if(!$definition){throw 'Missing preflight function'}
    . ([ScriptBlock]::Create($definition.Extent.Text))
}
$owner='7d5ad307-d21c-47eb-9584-493443190984'
$ownerName='.PBZTestArenaNative-owner';$integratedName='.PBZTestArenaIntegrated-owner'
$empty=Join-Path $Fixture 'empty';[void][IO.Directory]::CreateDirectory($empty)
Assert-OwnedRuntime $empty
if(@(Get-ChildItem -LiteralPath $empty -Force).Count){throw 'Empty preflight wrote files'}
$rejected=$false
try{Assert-OwnedRuntime $empty -Integrated}catch{$rejected=$true}
if(!$rejected){throw 'An empty directory was mistaken for an integrated installation'}
$foreign=Join-Path $Fixture 'foreign';[void][IO.Directory]::CreateDirectory($foreign)
$config=Join-Path $foreign 'UE4SS-settings.ini';[IO.File]::WriteAllText($config,'FOREIGN_KEEP')
$rejected=$false;$message=''
try{Assert-OwnedRuntime $foreign}catch{$rejected=$true;$message=$_.Exception.Message}
if(!$rejected -or $message -notlike '*UE4SS*'){throw 'Foreign installation was not clearly rejected'}
if([IO.File]::ReadAllText($config) -cne 'FOREIGN_KEEP' -or @(Get-ChildItem -LiteralPath $foreign -Force).Count -ne 1){throw 'Foreign files changed'}
$owned=Join-Path $Fixture 'owned';[void][IO.Directory]::CreateDirectory((Join-Path $owned 'Mods/PBZTestArena'))
[IO.File]::WriteAllText((Join-Path $owned $ownerName),$owner)
[IO.File]::WriteAllText((Join-Path $owned $integratedName),$owner)
Assert-OwnedRuntime $owned -Integrated
[void][IO.Directory]::CreateDirectory((Join-Path $owned 'Mods/AnotherMod'))
$rejected=$false
try{Assert-OwnedRuntime $owned -Integrated}catch{$rejected=$true}
if(!$rejected){throw 'Additional mods were not preserved by refusal'}
Write-Output 'empty, integrated, foreign and owned preflight checks passed; no game started'
'''
        runner = fixture / "check.ps1"
        runner.write_text(script, encoding="utf-8-sig")
        powershell = Path(os.environ["WINDIR"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
        result = subprocess.run([str(powershell), "-NoProfile", "-ExecutionPolicy", "Bypass",
                                 "-File", str(runner), "-Source", str(source), "-Fixture", str(fixture)],
                                capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout.decode("utf-8", "replace") +
                         result.stderr.decode("utf-8", "replace"))


if __name__ == "__main__":
    unittest.main()
