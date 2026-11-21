param([string] $GameExe = '', [string] $OutputDirectory = '')

$ErrorActionPreference = 'Stop'
$kit = Join-Path $PSScriptRoot 'IntegratedMenu'
$script:pbzInstallerStage = 'diagnostics'
try {
. (Join-Path $kit 'PBZInstallHealth.ps1')
Assert-PbzPackagePaths $PSScriptRoot
. (Join-Path $kit 'PortablePaths.ps1')
. (Join-Path $kit 'Export-PbzDiagnostics.ps1')

if (!$GameExe) {
    $candidates = @(Get-PbzGameCandidates)
    if ($candidates.Count -eq 1) {
        $GameExe = $candidates[0].EntryGameExe
    } else {
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            Write-Host ('{0}. [{1}] {2}' -f ($i+1), $candidates[$i].Store, $candidates[$i].EntryGameExe)
        }
        $inputPath = (Read-Host '请输入列表序号，或粘贴游戏根目录 / PBZ.exe 的完整路径').Trim().Trim('"')
        $index = 0
        if ([int]::TryParse($inputPath,[ref]$index) -and $index -ge 1 -and $index -le $candidates.Count) {
            $GameExe = $candidates[$index-1].EntryGameExe
        } else { $GameExe = $inputPath }
    }
}
if (Test-Path -LiteralPath $GameExe -PathType Container) {
    $choices = @(Get-PbzGameLayoutsAtRoot $GameExe)
    if ($choices.Count -ne 1) {
        Stop-PbzInstall 'GAME_FOLDER_REQUIRED' '请在游戏平台中打开「浏览本地文件」，再输入找到的游戏目录。若目录下有两个平台，请选择平时使用的平台目录。'
    }
    $GameExe = $choices[0].EntryGameExe
}
$result = Export-PbzDiagnostics $GameExe $OutputDirectory
Write-Output $result.Path
if (!$OutputDirectory) { Invoke-Item -LiteralPath (Split-Path -Parent $result.Path) -ErrorAction SilentlyContinue }
} catch {
    $message = if (Get-Command Format-PbzIssue -ErrorAction SilentlyContinue) {
        Format-PbzIssue (Get-PbzInstallError $_)
    } else {
        '诊断工具文件不完整。请把 ZIP 完整解压到短文件夹，再打开「导出问题日志」。'
    }
    Write-Host $message
    exit 1
}
