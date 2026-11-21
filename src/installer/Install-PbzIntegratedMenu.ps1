param(
    [switch] $Install,
    [switch] $Uninstall,
    [switch] $Preflight,
    [switch] $Repair,
    [switch] $Recover,
    [string] $SteamRoot = '',
    [string] $GameExe = '',
    [string] $SteamAccount = '',
    [string] $UserSid = '',
    [Alias('EpicAccount')][string] $AccountId = '',
    [string] $ExpectedGameExe = '',
    [switch] $KeepExistingLoader
)

$ErrorActionPreference = 'Stop'
$script:pbzInstallerStage = 'package'
. (Join-Path $PSScriptRoot 'PBZInstallHealth.ps1')
try {
. (Join-Path $PSScriptRoot 'PBZInstallRecovery.ps1')
. (Join-Path $PSScriptRoot 'PBZRuntimeRepair.ps1')
. (Join-Path $PSScriptRoot 'PortablePaths.ps1')
. (Join-Path $PSScriptRoot 'SharedRuntime.ps1')
. (Join-Path $PSScriptRoot 'ArenaMaps.ps1')
$script:pbzTransaction = $null
$owner = '7d5ad307-d21c-47eb-9584-493443190984'
$saveOwner = 'PBZTestArena.IntegratedMenu'
$expectedGameHash = '4415933ce33476f14c837abb61a1b60af8b78cd81783896501913a7aac69e423'
$legacyGameHash = '7b4fcd286a350780faf0824d73aa150b21cbf1bccde883e6a96386cbe09973b4'
$epicGameHash = '0d2569748593c59a29ae461aeab5c2735e727c0e706430d24bb02699c49770be'
$ownerName = '.PBZTestArenaNative-owner'
$integratedName = '.PBZTestArenaIntegrated-owner'
$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
Assert-PbzPackagePaths $root
$integratedRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$runtimeRoot = Join-Path $root 'NativeEnemyRuntime'
$payload = Join-Path $runtimeRoot 'Payload'
$manifestPath = Join-Path $runtimeRoot 'PayloadHashes.json'
. (Join-Path $PSScriptRoot 'CheckpointPayload.ps1')
$hasCheckpoint = (Test-Path -LiteralPath $checkpointManifestPath) -or (Test-Path -LiteralPath $checkpointPayloadRoot)
. (Join-Path $PSScriptRoot 'PBZModLoaderBridges.ps1')
$helper = Join-Path $integratedRoot 'Tools/PBZSaveTool.exe'
$toolBuildPath = Join-Path $integratedRoot 'Tools/Build.json'
$presets = Join-Path $integratedRoot 'PrivatePresets.pbzs'
$legacyStatePath = Join-Path $integratedRoot 'InstallState.json'
$legacyPrivatePath = Join-Path $integratedRoot 'PrivateSlots.json'
$script:pbzInstallerStage = 'selection'
if (@(@($Install,$Uninstall,$Repair,$Recover) | Where-Object { $_ }).Count -gt 1) {
    Stop-PbzInstall 'ACTION_REQUIRED' '请在安装器中只选择一项操作。'
}
if (!$GameExe -and $SteamRoot) { $GameExe = Join-Path $SteamRoot 'steamapps/common/PBZ/platform/steam/PBZ.exe' }
if (!$GameExe) {
    $candidates = @(Get-PbzGameCandidates)
    if ($candidates.Count -ne 1) { throw '请在安装器中选择游戏平台和 PBZ.exe。' }
    $GameExe = $candidates[0].GameExe
}
$layout = Resolve-PbzGameLayout $GameExe
if ($ExpectedGameExe -and $layout.GameExe -ine $ExpectedGameExe) {
    Stop-PbzInstall 'GAME_PATH_CHANGED' '游戏目录联接在检查后指向了不同的位置，请重新选择目录并检查。' $layout.EntryGameExe
}
$epic = $layout.Store -eq 'Epic'
$game,$platform,$installRoot = $layout.GameExe,$layout.Platform,$layout.InstallRoot
Assert-PbzPathLength $game
$active = Join-Path $platform 'ue4ss'
$proxy = Join-Path $platform 'dwmapi.dll'
$modDirectory = Join-Path $active 'Mods/PBZTestArena'
$utf8 = New-Object Text.UTF8Encoding($false)
if (!$UserSid) { $UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
if ($UserSid -cnotmatch '^S-1-(?:5-21|12-1)(?:-\d+){4}$') { throw 'A normal Windows user SID is required for private MOD write access.' }

function Assert-OrdinaryPath([string] $Path) {
    $item = Get-Item -LiteralPath $Path -Force
    while ($null -ne $item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $message = if ($script:pbzInstallerStage -eq 'package') {
                '安装包内有指向其他位置的链接。请在本机新建一个文件夹并完整解压 ZIP 后重试。'
            } else {
                '游戏内部的目录或文件使用了链接，当前安装器无法安全覆盖。请用原 MOD 管理器将前置和 MOD 还原到游戏内的普通目录，再检查。'
            }
            Stop-PbzInstall 'LINKED_PATH' $message $item.FullName
        }
        $item = if ($item.PSIsContainer) { $item.Parent } else { $item.Directory }
    }
}

function Assert-Contained([string] $Path, [string] $Directory) {
    $full = [IO.Path]::GetFullPath($Path).Replace('\','/')
    $parent = [IO.Path]::GetFullPath($Directory).Replace('\','/').TrimEnd('/') + '/'
    if (!$full.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase)) { throw "Path escaped its expected directory: $Path" }
}

function Ensure-Directory([string] $Path) {
    $ancestor = [IO.Path]::GetFullPath($Path)
    while (!(Test-Path -LiteralPath $ancestor)) { $ancestor = Split-Path -Parent $ancestor }
    Assert-OrdinaryPath $ancestor
    if (!(Test-Path -LiteralPath $Path -PathType Container)) {
        Assert-PbzPathLength $Path -Directory
        [void][IO.Directory]::CreateDirectory($Path)
    }
    Assert-OrdinaryPath $Path
}

function Get-Hash([string] $Path) {
    Assert-OrdinaryPath $Path
    $stream=[IO.File]::OpenRead($Path)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose(); $stream.Dispose() }
}

function Assert-Hash([string] $Path, [string] $Expected) {
    if ((Get-Hash $Path) -cne $Expected.ToLowerInvariant()) { throw "File hash mismatch: $Path" }
}

function Assert-PbzInstalledRuntimeHash([string] $Relative, [string] $Expected) {
    $path = Join-Path $platform $Relative
    if ($Relative -ceq 'ue4ss/Mods/PBZTestArena/Scripts/PBZSaveBarrier.dll' -and
        $Expected -ceq 'edc65b15172e718039e0937325531a2719bb0d144fbd5e9804b6ec98668372d0') {
        # Accept the one published internal replacement for this exact installed file.
        if ((Get-Hash $path) -cnotin @($Expected,'c8679bb8fc01224568cd23e7fb40c811081ed1562cb7df5dcc4ac7c3306102d6')) {
            throw "File hash mismatch: $path"
        }
        return
    }
    Assert-Hash $path $Expected
}

function Copy-NewFile([string] $Source, [string] $Destination) {
    Assert-OrdinaryPath $Source
    Ensure-Directory (Split-Path -Parent $Destination)
    $inputStream = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $inputStream.CopyTo($outputStream); $outputStream.Flush($true) }
        finally { $outputStream.Dispose() }
    } finally { $inputStream.Dispose() }
}

function Write-NewText([string] $Path, [string] $Text) {
    $bytes = $utf8.GetBytes($Text)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
}

function Write-AtomicText([string] $Path, [string] $Text, [string] $Workspace, [switch] $CreateOnly) {
    Ensure-Directory (Split-Path -Parent $Path)
    $pending = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    if ($Workspace) {
        Ensure-Directory $Workspace
        $pending = Join-Path $Workspace ([Guid]::NewGuid().ToString('N') + '.tmp')
    }
    try {
        Write-NewText $pending $Text
        if (!$CreateOnly -and (Test-Path -LiteralPath $Path)) { Assert-OrdinaryPath $Path; [IO.File]::Replace($pending,$Path,[NullString]::Value) }
        else { [IO.File]::Move($pending,$Path) }
    } finally { if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending } }
}

function Test-GameRunning {
    return [bool](Get-Process -Name 'PBZ','ProjectPBZ-Win64-Shipping' -ErrorAction SilentlyContinue)
}

function Assert-NotRunning {
    if (Test-GameRunning) { Stop-PbzInstall 'GAME_RUNNING' '请完全退出影之刃零，再检查或修改演武安装。' }
}

function Grant-OwnedWriteAccess([string] $Directory, [string] $Marker, [switch] $AccountData) {
    Assert-OrdinaryPath $Directory
    $proof = Join-Path $Directory $Marker
    Assert-OrdinaryPath $proof
    if ([IO.File]::ReadAllText($proof).Trim() -cne $owner) { throw 'Refusing ACL changes outside an owned MOD directory.' }
    $identity = New-Object Security.Principal.SecurityIdentifier($UserSid)
    $sections = [Security.AccessControl.AccessControlSections]::Access
    $acl = [IO.Directory]::GetAccessControl($Directory,$sections)
    $inherit = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    foreach ($existing in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if ($existing.IdentityReference.Value -ceq $UserSid -and
            $existing.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            ($existing.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Modify) -eq [Security.AccessControl.FileSystemRights]::Modify -and
            ($existing.InheritanceFlags -band $inherit) -eq $inherit -and
            !($existing.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)) { return }
    }
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity,
        [Security.AccessControl.FileSystemRights]::Modify,
        $inherit,
        [Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
    $before = $acl.GetSecurityDescriptorSddlForm($sections)
    $acl.SetAccessRule($rule)
    if ($AccountData) {
        Add-PbzTransactionStep ([ordered]@{kind='acl';target=$Directory;before=$before;
            after=$acl.GetSecurityDescriptorSddlForm($sections)})
    }
    [IO.Directory]::SetAccessControl($Directory,$acl)
}

function Assert-OwnedRuntime([string] $Directory, [switch] $Integrated) {
    Assert-OrdinaryPath $Directory
    $marker = Join-Path $Directory $ownerName
    if (!(Test-Path -LiteralPath $marker -PathType Leaf)) {
        # An uninstaller may leave an empty ue4ss directory. Move it into the
        # existing transaction backup; restore it on uninstall or rollback.
        # Never infer ownership of any nonempty third-party installation.
        if (!$Integrated -and @(Get-ChildItem -LiteralPath $Directory -Force).Count -eq 0) { return }
        Stop-PbzInstall 'LOADER_CONFLICT' '游戏里有无法识别的 UE4SS 文件夹。请先通过原 MOD 管理器修复或还原加载器，再点「检查安装」。' $Directory
    }
    Assert-OrdinaryPath $marker
    if ([IO.File]::ReadAllText($marker).Trim() -cne $owner) {
        Stop-PbzInstall 'LOADER_CONFLICT' '游戏里的 UE4SS 由其他安装工具管理，无法自动替换。请在原管理器修复前置后重试。' $Directory
    }
    if ($Integrated) {
        $persistent = Join-Path $Directory $integratedName
        Assert-OrdinaryPath $persistent
        if ([IO.File]::ReadAllText($persistent).Trim() -cne $owner) { throw 'The persistent menu ownership marker differs.' }
    }
    $mods = Join-Path $Directory 'Mods'
    if (!(Test-Path -LiteralPath $mods)) { return }
    Assert-OrdinaryPath $mods
    $foreign = @(Get-ChildItem -LiteralPath $mods -Force | Where-Object { $_.Name -notin @('PBZTestArena','shared','mods.txt','mods.json') })
    if ($foreign.Count) { throw 'The owned UE4SS directory contains additional mods; preserve them before installing this package.' }
}

function Assert-Payload {
    Assert-OrdinaryPath $manifestPath
    $script:manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($entry in $manifest.PSObject.Properties) {
        if ($entry.Name -notmatch '^[A-Za-z0-9_./-]+$' -or $entry.Name -match '(^|/)\.\.(/|$)' -or
            ($entry.Name -ne 'dwmapi.dll' -and !$entry.Name.StartsWith('ue4ss/'))) { throw 'Invalid payload manifest path.' }
        if ($entry.Value -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid payload manifest hash.' }
        Assert-PbzPathLength ($payload + '\' + $entry.Name) 'PACKAGE_PATH_TOO_LONG'
        Assert-Hash (Join-Path $payload $entry.Name) $entry.Value
    }
    if (!$manifest.'dwmapi.dll' -or !$manifest.'ue4ss/Mods/PBZTestArena/Scripts/PBZSaveBarrier.dll') {
        throw 'The complete native save-isolation payload is required.'
    }
}

function Assert-PortableTools {
    Assert-OrdinaryPath $toolBuildPath
    $script:toolBuild = Get-Content -LiteralPath $toolBuildPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($toolBuild.schemaVersion -ne 1 -or $toolBuild.privateSlotCount -ne 18 -or $toolBuild.file -cne 'PBZSaveTool.exe' -or
        $toolBuild.gameSha256 -cne $expectedGameHash -or $toolBuild.sha256 -cnotmatch '^[a-f0-9]{64}$' -or
        $toolBuild.presetsSha256 -cnotmatch '^[a-f0-9]{64}$' -or
        $toolBuild.continueVerification -cne 'opaque-Advanced-block-identical' -or
        $toolBuild.uninstallPolicy -cne 'retain-dedicated-save-blocks-and-reports') {
        throw 'Unsupported portable save helper manifest.'
    }
    Assert-Hash $helper $toolBuild.sha256
    Assert-Hash $presets $toolBuild.presetsSha256
}

function Lua-String([string] $Value) {
    if ($Value -match '[\x00-\x1f]') { throw 'Control characters are not valid in integrated paths.' }
    return '"' + $Value.Replace('\','/').Replace('"','\"') + '"'
}

function New-Config([string] $SavePath) {
    $legacyMaps = if ($checkpointFlow -eq 'native-checkpoint' -or !$mapPayload.Count) { 'true' } else { 'false' }
    return @"
return {
    version = 2,
    platform = $(Lua-String $layout.Store.ToLowerInvariant()),
    mapFlow = $(Lua-String $checkpointFlow),
    legacyMaps = $legacyMaps,
    owner = $(Lua-String $owner),
    profile = $(Lua-String $profile),
    savePath = $(Lua-String $SavePath),
    gameSha256 = $(Lua-String $actualGameHash),
    loadoutMemoryPath = $(Lua-String (Join-Path $preferences 'PBZLoadout.tsv')),
    trainingSlot = "PBZArenaIntegratedTraining",
    cyclePrefix = "PBZArenaIntegratedCycle",
    defaultPlayerCycle = 6,
    defaultEnemyCycle = 0,
}
"@
}

function Get-PreviousState([switch] $ForInstall) {
    $readState,$readPrivate = $statePath,$privatePath
    if (!(Test-Path -LiteralPath $readState -PathType Leaf) -and (Test-Path -LiteralPath $legacyStatePath -PathType Leaf)) {
        $readState,$readPrivate = $legacyStatePath,$legacyPrivatePath
    }
    if (!(Test-Path -LiteralPath $readState -PathType Leaf)) { return $null }
    Assert-OrdinaryPath $readState
    $text = Get-Content -LiteralPath $readState -Raw -Encoding UTF8
    try { $state = $text | ConvertFrom-Json } catch { $state = $null }
    if ($state.owner -and $state.owner -cne $owner) {
        Stop-PbzInstall 'RECEIPT_UNVERIFIED' '旧安装记录属于其他安装器。请使用原工具还原，或导出诊断核对。' $readState
    }
    if ($state.installed -and (($state.gameExe -and $state.gameExe -ine $game -and $state.gameExe -ine $layout.EntryGameExe) -or
            ($state.savePath -and $state.savePath -ine $save))) {
        Stop-PbzInstall 'ACCOUNT_CONFLICT' '旧安装记录属于另一个游戏位置或存档。请重新选择原游戏目录及账号。' $readState
    }
    if ($state.owner -cne $owner -or $state.installed -isnot [bool] -or $state.version -notin @(1,2,3) -or
            ($state.version -eq 3 -and $state.installKind -cne 'shared-v1') -or
            ($state.installed -and (!$state.gameExe -or !$state.savePath -or !$state.runtimeHashes -or
                ($state.version -ne 3 -and $state.runtimeHashes.'dwmapi.dll' -cnotmatch '^[a-f0-9]{64}$')))) {
        if ($ForInstall) { return $null } # The old record is kept in the transaction backup.
        Stop-PbzInstall 'RECEIPT_UNVERIFIED' '无法核对旧安装记录。请先点「检查安装」备份并覆盖演武，再卸载；若检查失败，请导出诊断。' $readState
    }
    if ($state.privateManifestSha256) {
        $privateHash = if (Test-Path -LiteralPath $readPrivate -PathType Leaf) { Get-Hash $readPrivate }
        if ($privateHash -cne $state.privateManifestSha256) {
            if ($ForInstall -and $checkpointFlow -eq 'native-checkpoint') { $state.privateManifestSha256 = $null }
            else { Stop-PbzInstall 'RECEIPT_UNVERIFIED' '无法核对旧安装的演武槽位记录。请保留原存档和备份，并导出诊断。' $readPrivate }
        }
    } elseif ($state.installed -and $state.mapFlow -cne 'native-checkpoint') {
        if ($ForInstall -and $checkpointFlow -eq 'native-checkpoint') { return $null }
        Stop-PbzInstall 'RECEIPT_UNVERIFIED' '旧版演武槽位记录缺失。请保留存档和旧安装备份，点「导出诊断」核对。' $readState
    }
    $state | Add-Member -NotePropertyName verifiedPrivatePath -NotePropertyValue $readPrivate -Force
    return $state
}

function Assert-PreviousRuntime($State, [switch] $AllowMissingMod, [switch] $ReplaceMod) {
    if ((Test-Path -LiteralPath $proxy) -and !(Test-Path -LiteralPath (Join-Path $active 'UE4SS.dll') -PathType Leaf)) {
        Assert-OrdinaryPath $proxy
        if (!$State -or !$State.installed -or !$State.runtimeHashes.'dwmapi.dll') {
            Stop-PbzInstall 'LOADER_ORPHAN' '发现 dwmapi.dll，但找不到配套 UE4SS。请用原 MOD 管理器修复前置。若确认是已卸载 MOD 的残留，可先把它移出游戏目录备份再重试。无法确认时请导出诊断。' $proxy
        }
        Assert-PbzMissingRuntimeReceipt $State $false
        Assert-Hash $proxy $State.runtimeHashes.'dwmapi.dll'
    }
    if (Test-Path -LiteralPath $active) {
        Assert-OwnedRuntime $active
        $persistent = Join-Path $active $integratedName
        if (Test-Path -LiteralPath $persistent) {
            Assert-OwnedRuntime $active -Integrated
            if (!$State -or !$State.installed) { throw 'The installed menu is missing its ownership receipt; refusing to replace it.' }
            foreach ($entry in $State.runtimeHashes.PSObject.Properties) {
                if (($AllowMissingMod -or $ReplaceMod) -and $entry.Name.StartsWith('ue4ss/Mods/PBZTestArena/',[StringComparison]::Ordinal)) { continue }
                $existing = Join-Path $platform $entry.Name
                Assert-Contained $existing $platform
                if ($ReplaceMod -and $entry.Name.StartsWith('ue4ss/',[StringComparison]::Ordinal) -and
                        !(Test-Path -LiteralPath $existing)) { continue }
                Assert-PbzInstalledRuntimeHash $entry.Name $entry.Value
            }
        }
    }
    if (Test-Path -LiteralPath $proxy) {
        $expected = $manifest.'dwmapi.dll'
        if ($State -and $State.installed) { $expected = $State.runtimeHashes.'dwmapi.dll' }
        Assert-Hash $proxy $expected
    }
}

function Invoke-SaveTool([string] $SavePath, [string] $Output, [string] $PriorManifest) {
    Assert-Hash $game $actualGameHash
    $arguments = @('stage','--game',$game,'--source',$SavePath,'--presets',$presets,'--output',$Output)
    if ($PriorManifest) { $arguments += @('--prior',$PriorManifest) }
    $json = & $helper @arguments
    if ($LASTEXITCODE -ne 0) {
        Stop-PbzInstall 'SAVE_UNVERIFIED' '无法为当前存档准备演武槽位。请从游戏平台正常继续游戏、保存一次并退出后重试。若仍失败，请保留原档并导出诊断。' $save
    }
    $text = $json -join [Environment]::NewLine
    $result = $text | ConvertFrom-Json
    if ($result.schemaVersion -ne 1 -or $result.owner -cne $saveOwner -or $result.operation -cne 'stage' -or
        $result.sourceSha256 -cnotmatch '^[a-f0-9]{64}$' -or $result.outputSha256 -cnotmatch '^[a-f0-9]{64}$' -or
        $result.gameSha256 -cne $actualGameHash -or $result.presetsSha256 -cne $toolBuild.presetsSha256 -or
        $result.originalBlockIdentity -ne $true -or $result.continue.changed -ne $false -or
        $result.continue.verification -cne 'opaque-Advanced-block-identical' -or
        $result.advancedSha256Before -cnotmatch '^[a-f0-9]{64}$' -or $result.advancedSha256Before -cne $result.advancedSha256After) {
        throw 'The staged opaque-block verification report is invalid.'
    }
    Assert-Hash $SavePath $result.sourceSha256
    Assert-Hash $Output $result.outputSha256
    $expectedSlots = @('PBZArenaIntegratedTraining') + @(0..6 | ForEach-Object { 'PBZArenaIntegratedCycle' + $_ }) + @('PBZArenaIntegratedLao','PBZArenaIntegratedLakeTraining') + @(0..6 | ForEach-Object { 'PBZArenaIntegratedLakeCycle' + $_ }) + @('PBZArenaIntegratedLakeLao')
    $names = @($result.privateSlots.PSObject.Properties.Name)
    if ($names.Count -ne 18 -or @(Compare-Object ($expectedSlots | Sort-Object) ($names | Sort-Object)).Count) {
        throw 'The staged private slot namespace is incomplete.'
    }
    $ordinary = @($result.originalSlots.PSObject.Properties.Name | Where-Object { $_ -cmatch '^(?:AutoSave|ManualSave)\d+$' })
    if (!$ordinary.Count) { Stop-PbzInstall 'ACCOUNT_REQUIRED' '请先在游戏中创建一次正常存档，退出后重新检查安装。' }
    $verificationArguments = @('verify','--game',$game,'--before',$SavePath,'--after',$Output,'--presets',$presets)
    if ($PriorManifest) { $verificationArguments += @('--prior',$PriorManifest) }
    $verificationJson = & $helper @verificationArguments
    if ($LASTEXITCODE -ne 0) { throw 'The portable save tool rejected the candidate during independent verification.' }
    $verification = ($verificationJson -join [Environment]::NewLine) | ConvertFrom-Json
    if ($verification.operation -cne 'verify' -or $verification.gameSha256 -cne $actualGameHash -or $verification.sourceSha256 -cne $result.sourceSha256 -or
        $verification.outputSha256 -cne $result.outputSha256 -or $verification.originalBlockIdentity -ne $true -or
        $verification.advancedSha256Before -cne $result.advancedSha256Before -or
        $verification.advancedSha256After -cne $result.advancedSha256After -or
        $verification.continue.verification -cne 'opaque-Advanced-block-identical' -or $verification.continue.changed -ne $false) {
        throw 'The independent candidate verification differs from staging.'
    }
    Assert-Hash $SavePath $result.sourceSha256
    Assert-Hash $Output $result.outputSha256
    Assert-Hash $game $actualGameHash
    return @{ report = $result; json = $text }
}

function Replace-Save([string] $Source, [string] $Destination, [string] $BeforeHash,
    [string] $AfterHash, [string] $Rollback) {
    Assert-NotRunning
    Assert-Hash $Destination $BeforeHash
    if ($BeforeHash -ceq $AfterHash) { return $false }
    $folder = Split-Path -Parent $Source
    $pending = Join-Path $folder ('Swap-' + [Guid]::NewGuid().ToString('N').Substring(0,8) + '.tmp')
    Assert-Contained $pending $folder
    Copy-NewFile $Source $pending
    try {
        Assert-Hash $pending $AfterHash
        Assert-Hash $Destination $BeforeHash
        [IO.File]::Replace($pending,$Destination,$Rollback)
        $replacedHash = Get-Hash $Rollback
        if ($replacedHash -cne $BeforeHash) {
            throw '安装期间存档发生变化。请等游戏平台完成同步后再试。'
        }
        Assert-Hash $Destination $AfterHash
    } finally { if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending } }
    return $true
}

function Copy-LegacyUserFile([string] $Source, [string] $Destination, [string] $Relative) {
    Assert-OrdinaryPath $Source
    $digest = Get-Hash $Source
    if (Test-Path -LiteralPath $Destination) {
        Assert-OrdinaryPath $Destination
        if ((Get-Hash $Destination) -ceq $digest) { return }
        $conflict = Join-Path $run ('LegacyProfileConflicts/' + $Relative)
        Copy-NewFile $Source $conflict
        Assert-Hash $conflict $digest
        $script:migrationNotes.Add('Existing newer destination retained; legacy copy: ' + $Relative)
        return
    }
    Add-PbzFileChange $Destination '' $digest
    $temporary = Join-Path $run ('Migration-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    Copy-NewFile $Source $temporary
    Assert-Hash $temporary $digest
    Ensure-Directory (Split-Path -Parent $Destination)
    [IO.File]::Move($temporary,$Destination)
    Assert-Hash $Destination $digest
    $script:migrationNotes.Add('Copied without changing the legacy source: ' + $Relative)
}

function Migrate-LegacyUserData($State) {
    if (!$State -or $State.version -ne 1 -or !$State.privateManifestSha256 -or !$State.profile) { return }
    $oldProfile = [IO.Path]::GetFullPath($State.profile)
    if ($oldProfile -ieq [IO.Path]::GetFullPath($profile) -or !(Test-Path -LiteralPath $oldProfile -PathType Container)) { return }
    Assert-OrdinaryPath $oldProfile
    $marker = Join-Path $oldProfile 'PBZIntegratedProfile.txt'
    Assert-OrdinaryPath $marker
    if ([IO.File]::ReadAllText($marker).Trim() -cne $owner) { throw 'The legacy profile ownership marker differs; no legacy data was migrated.' }
    $history = Join-Path $oldProfile 'PBZChallengeHistory.tsv'
    if (Test-Path -LiteralPath $history -PathType Leaf) { Copy-LegacyUserFile $history (Join-Path $profile 'PBZChallengeHistory.tsv') 'PBZChallengeHistory.tsv' }
    $reports = Join-Path $oldProfile 'ChallengeReports'
    if (Test-Path -LiteralPath $reports -PathType Container) {
        Assert-OrdinaryPath $reports
        foreach ($file in @(Get-ChildItem -LiteralPath $reports -File -Force)) {
            if ($file.Name -cnotmatch '^[A-Za-z0-9_-]+\.json$') { continue }
            Copy-LegacyUserFile $file.FullName (Join-Path $profile ('ChallengeReports/' + $file.Name)) ('ChallengeReports/' + $file.Name)
        }
    }
    if ($State.launcherRoot) {
        $oldPreferences = Join-Path ([IO.Path]::GetFullPath($State.launcherRoot)) 'ArenaPreferences'
        $oldMarker = Join-Path $oldPreferences '.PBZTestArenaArenaPrefs-owner'
        $oldMemory = Join-Path $oldPreferences 'PBZLoadout.tsv'
        if ((Test-Path -LiteralPath $oldMarker -PathType Leaf) -and (Test-Path -LiteralPath $oldMemory -PathType Leaf)) {
            Assert-OrdinaryPath $oldMarker
            if ([IO.File]::ReadAllText($oldMarker).Trim() -ceq $owner) {
                Copy-LegacyUserFile $oldMemory (Join-Path $preferences 'PBZLoadout.tsv') 'ArenaPreferences/PBZLoadout.tsv'
            }
        }
    }
    Write-NewText (Join-Path $run 'LegacyProfileMigration.json') (([ordered]@{source=$oldProfile;notes=@($migrationNotes);oldFilesRetained=$true}) | ConvertTo-Json -Depth 4)
}

$script:pbzInstallerStage = 'account'
$accounts = @(Get-PbzSaveAccounts -Layout $layout)
if (!$AccountId) { $AccountId = $SteamAccount }
if ($AccountId) {
    if ($AccountId -cnotmatch $layout.AccountPattern) { throw '所选账号与游戏的存档平台不匹配。' }
    $accounts = @($accounts | Where-Object { $_.Account -ieq $AccountId })
}
if ($accounts.Count -ne 1 -and !(Test-Path -LiteralPath $game -PathType Leaf)) {
    Stop-PbzInstall 'GAME_EXE_MISSING' "找不到 $($layout.Store) 版 PBZ.exe。请从游戏平台核对游戏位置并验证游戏文件，也可以直接导出诊断。" $game
}
if ($accounts.Count -ne 1) {
    Stop-PbzInstall 'ACCOUNT_REQUIRED' '请选择一个存档账号。没有存档时，请先在游戏中保存一次。'
}
$save = $accounts[0].SavePath
$dataRoot = $accounts[0].DataRoot
$stateRoot = Join-Path $dataRoot 'IntegratedMenu'
$statePath = Join-Path $stateRoot 'InstallState.json'
$privatePath = Join-Path $stateRoot 'PrivateSlots.json'
$profile = Join-Path $stateRoot 'ArenaData/Profile'
$preferences = Join-Path $dataRoot 'ArenaPreferences'
$script:pbzInstallerStage = 'recovery'
Assert-PbzOtherTransactions
if (Test-Path -LiteralPath (Get-PbzPendingPath)) {
    Read-PbzTransaction
    if ($Preflight) { return New-PbzPreflight 'recovery_pending' 'Recover' '上次安装有未完成的文件操作。请先恢复，再重新检查。' }
    if (!$Recover) { Stop-PbzInstall 'RECOVERY_PENDING' '上次安装尚未完成，请先点击「恢复上次操作」。' }
    Invoke-PbzPendingRecovery
    return
}
if ($Recover) { Stop-PbzInstall 'NO_RECOVERY' '当前账号没有需要恢复的操作。' }

$script:pbzInstallerStage = 'game_path'
if (!(Test-Path -LiteralPath $game -PathType Leaf)) {
    Stop-PbzInstall 'GAME_EXE_MISSING' "找不到 $($layout.Store) 版 PBZ.exe。请从游戏平台核对游戏位置并验证游戏文件，也可以直接导出诊断。" $game
}
Assert-OrdinaryPath $platform
Assert-OrdinaryPath $game
Assert-OrdinaryPath $save
Assert-NotRunning
if (!$Uninstall) { Assert-PbzLuaGamePath $layout }
$script:pbzInstallerStage = 'package'
Assert-OrdinaryPath $integratedRoot
Assert-Payload
$script:pbzInstallerStage = 'game_version'
$pendingReceipt=Join-Path $active 'Mods/PBZTestArena/.PBZTestArenaPending-install.json'
$actualGameHash=Get-Hash $game
if (!$Uninstall -and !$Recover) {
    if ($epic) {
        if (Test-Path -LiteralPath (Join-Path $active 'Mods/PBZTestArena/.PBZEpicInternal-owner')) {
            Stop-PbzInstall 'INTERNAL_BUILD_PRESENT' '检测到旧的 Epic 隔离内测。请运行原内测包里的「还原」入口，再检查安装。'
        }
        $script:pbzInstallerStage = 'package'
        $requirementsPath = Join-Path $PSScriptRoot 'EpicNativeRequirements.json'
        Assert-OrdinaryPath $requirementsPath
        $requirements = Get-Content -LiteralPath $requirementsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($requirements.Count -ne 18) { throw 'Epic 兼容接口清单不完整。' }
        . (Join-Path $PSScriptRoot 'EpicNativeCheck.ps1')
        $script:pbzInstallerStage = 'game_version'
        if (@(Check-NativeFile $game $requirements).Count) {
            Stop-PbzInstall 'UNSUPPORTED_BUILD' '这个 Epic 游戏版本暂无法适配。请在 Epic 中验证游戏文件并检查是否有新版演武安装包。仍失败时请导出诊断。' $game
        }
    } elseif ($actualGameHash -cnotin @($expectedGameHash,$legacyGameHash)) {
        Stop-PbzInstall 'UNSUPPORTED_BUILD' '这个 Steam 游戏版本暂无法适配。请验证游戏文件并检查是否有新版演武安装包。仍失败时请导出诊断。' $game
    }
}
$script:pbzInstallerStage = 'package'
$mapPayload = [ordered]@{}
$loaderBridgePayload = [ordered]@{}
$checkpointFlow = 'compatibility'
if (!$Uninstall -and !$Recover) {
    $stockSteam = !$epic -and $actualGameHash -ceq $expectedGameHash
    $stockEpic = $epic -and $actualGameHash -ceq $epicGameHash -and (Test-PbzArenaMapBase)
    if ($hasCheckpoint -and ($stockSteam -or ($stockEpic -and (Test-PbzEpicCheckpointInterface)))) {
        Select-PbzCheckpointPayload
        $loaderBridgePayload = Get-PbzLoaderBridgePayload
        $mapPayload = Get-PbzSettlementAudioPayload
        $checkpointFlow = 'native-checkpoint'
    } elseif (!$hasCheckpoint -and ($stockSteam -or $stockEpic)) {
        $mapPayload = Get-PbzMapPayload
    }
    Assert-PortableTools
}
if ($Uninstall -and (Test-Path -LiteralPath $pendingReceipt -PathType Leaf)) {
    if ($Preflight) { return New-PbzPreflight 'pending_internal' 'Uninstall' '可以卸载上次的兼容内测，保留其他 MOD 和存档。' }
    . (Join-Path $PSScriptRoot 'CompatibilityInstall.ps1')
    Remove-PbzPendingInstall
    return
}
$script:pbzInstallerStage = 'receipt'
$prior = Get-PreviousState -ForInstall:(!$Uninstall -and !$Repair)
$script:pbzInstallerStage = 'loader'
$shared = Test-PbzSharedRuntime $prior
if ($KeepExistingLoader -and !$shared -and !$Uninstall) {
    Stop-PbzInstall 'LOADER_CONFLICT' '原 UE4SS 在检查后发生变化。请重新点击「检查安装」，再选择安装方式。'
}
$missing = $prior -and $prior.installed -and !(Test-Path -LiteralPath $modDirectory)
if ($missing) { Assert-PbzMissingRuntimeReceipt $prior $shared }
if (!$Uninstall -and !$prior.installed) {
    Assert-PbzNoOtherInstallReceipt
}
if ($Uninstall -and (!$prior -or !$prior.installed)) {
    Stop-PbzInstall 'NOT_INSTALLED' '所选账号没有可卸载的演武安装登记。'
}
if ($Repair -and !$missing) { Stop-PbzInstall 'NO_REPAIR_REQUIRED' '没有检测到可修复的演武目录缺失。请重新检查。' }
$runtimeOnly = $missing -and ($shared -or (Test-Path -LiteralPath $active -PathType Container))
$script:pbzInstallerStage = 'loader'
if ($Uninstall -and !$missing) {
    Assert-PbzMoveReady $(if ($shared) { $modDirectory } else { $active })
}
if ($shared) {
    if (!$missing -and (Test-Path -LiteralPath $modDirectory)) { Assert-PbzSharedMod $prior $modDirectory -ReplaceMod:(!$Uninstall) }
    if (!$Uninstall) {
        if ((Test-Path -LiteralPath $proxy -PathType Leaf) -and
                !(Test-Path -LiteralPath (Join-Path $active 'UE4SS.dll') -PathType Leaf)) {
            Stop-PbzInstall 'LOADER_ORPHAN' '发现 dwmapi.dll，但 UE4SS 核心缺失。请用原 MOD 管理器修复前置，再点「检查安装」。如果找不到原管理器，请导出诊断。' $proxy
        }
        $dependencies = Get-PbzSharedDependencies
    }
} else {
    Assert-PreviousRuntime $prior -AllowMissingMod:$missing -ReplaceMod:(!$Uninstall)
}
if ($runtimeOnly -and !$Uninstall -and $checkpointFlow -eq 'native-checkpoint') {
    if ($Preflight) {
        $accessNote = Test-PbzPreflightAccess $true $null $null -RuntimeOnly
        return New-PbzPreflight 'runtime_missing' 'Repair' ('已核对原账号的安装登记。可修复演武目录，也可清理残留并保留进度。' + $accessNote)
    }
    if ($Repair -or $Install) { Invoke-PbzRuntimeRepair $prior $shared; return }
}
if ($Repair) {
    $Repair = $false
    $Install = $true
}

$script:pbzInstallerStage = 'content'
$maps = New-PbzMapTransaction $prior $mapPayload
$loaderBridges = New-PbzLoaderBridgeTransaction $prior $loaderBridgePayload
if ($Preflight) {
    $accessNote = Test-PbzPreflightAccess $shared $maps $loaderBridges
    if ($Uninstall) {
        if ($missing) { return New-PbzPreflight 'runtime_missing' 'Uninstall' ('可以清理残留，保留存档、配装和战报。' + $accessNote) }
        return New-PbzPreflight 'installed' 'Uninstall' ('已核对可卸载的演武文件。' + $accessNote)
    }
    if ($shared) {
        $state = if ($prior.installed) { 'installed' } else { 'ready' }
        return New-PbzPreflight $state 'Install' ('可以沿用现有 UE4SS。点击「仅覆盖演武 MOD」，安装器会先备份旧演武文件。' + $accessNote)
    }
    if (($prior -and $prior.installed) -or (Test-Path -LiteralPath $modDirectory)) {
        return New-PbzPreflight 'installed' 'Install' ('已找到现有演武，可以备份后覆盖安装。' + $accessNote)
    }
    return New-PbzPreflight 'ready' 'Install' ('安装检查通过。可以备份存档并安装。' + $accessNote)
}
if (!$Install -and !$Uninstall) { Write-Output '检查通过，未修改游戏和存档。'; return }
if ($shared) { Invoke-PbzSharedRuntime $prior; return }

$mutex = New-Object Threading.Mutex($false,'Local\PBZTestArenaNativeSession')
$held = $false
$run = $null
$runtimeStage = $null
$proxyStage = $null
$movedActive = $null
$movedProxy = $null
$migrationNotes = New-Object 'System.Collections.Generic.List[string]'
$report = $null
$rollback = $null
try {
    try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (!$held) { Stop-PbzInstall 'INSTALLER_BUSY' '另一个演武安装器或内测启动器正在运行。请先关闭它，再重试。' }
    Assert-NotRunning
    Assert-PbzOtherTransactions
    $script:pbzInstallerStage = 'receipt'
    $prior = Get-PreviousState -ForInstall:$Install
    $script:pbzInstallerStage = 'loader'
    if (Test-PbzSharedRuntime $prior) { Stop-PbzInstall 'LOADER_CONFLICT' '检查后加载器发生了变化。请重新检查，根据提示安装。' }
    $missing = $prior -and $prior.installed -and !(Test-Path -LiteralPath $modDirectory)
    if ($missing) { Assert-PbzMissingRuntimeReceipt $prior $false }
    if (!$Uninstall -and !$prior.installed) { Assert-PbzNoOtherInstallReceipt }
    Assert-PreviousRuntime $prior -AllowMissingMod:$missing -ReplaceMod:$Install
    $maps = New-PbzMapTransaction $prior $mapPayload
    $loaderBridges = New-PbzLoaderBridgeTransaction $prior $loaderBridgePayload
    if ($Uninstall -and (!$prior -or !$prior.installed)) { throw 'No owned persistent menu installation was found.' }
    Assert-PbzInstallAccess $false $maps $loaderBridges
    $script:pbzInstallerStage = 'backup'
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
    $operationName = if ($Install) { 'Install' } else { 'Uninstall' }
    if (Test-Path -LiteralPath $dataRoot) { Assert-OrdinaryPath $dataRoot }
    $run = New-PbzBackupRun $stamp
    $rollback = Join-Path $run 'Replaced.sav'
    $script:pbzInstallerStage = 'stage'
    Start-PbzTransaction $run $operationName
    if ($Install -and $checkpointFlow -eq 'compatibility') {
        $sourceHelper,$sourcePresets = $helper,$presets
        # Keep native staging paths short, including the tool's .manifest.json output.
        $transaction = Initialize-PbzToolWork
        $staging = Join-Path $transaction 'Staging'
        Ensure-Directory $staging
        $helper = Join-Path $transaction 'Tools/PBZSaveTool.exe'
        $presets = Join-Path $transaction 'PrivatePresets.pbzs'
        Copy-NewFile $sourceHelper $helper
        Copy-NewFile $sourcePresets $presets
        Assert-Hash $helper $toolBuild.sha256
        Assert-Hash $presets $toolBuild.presetsSha256
    }
    $beforeHash = Get-Hash $save
    Copy-NewFile $save (Join-Path $run 'Before.sav')
    Assert-Hash (Join-Path $run 'Before.sav') $beforeHash
    foreach ($file in @($statePath,$privatePath)) {
        if (Test-Path -LiteralPath $file -PathType Leaf) { Copy-NewFile $file (Join-Path $run ([IO.Path]::GetFileName($file))) }
    }
    $pendingSave = if ($Install -and $checkpointFlow -eq 'compatibility') { Join-Path $staging 'Pending.sav' } else { $null }
    $priorManifest = if ($prior -and $prior.privateManifestSha256) { $prior.verifiedPrivatePath } else { '' }
    if ($epic) { $priorManifest = '' }
    if ($pendingSave) { $prepared = Invoke-SaveTool (Join-Path $run 'Before.sav') $pendingSave $priorManifest }
    elseif ($Install) { $prepared = New-PbzUnchangedSaveReport $beforeHash }
    else {
        $retained = [ordered]@{schemaVersion=1;owner=$saveOwner;operation='uninstall-retain';sourceSha256=$beforeHash;
            outputSha256=$beforeHash;dedicatedSaveBlocksRetained=$true;reportsRetained=$true;
            continue=@{changed=$false;verification='all-save-bytes-identical'};gameStarted=$false}
        $prepared = @{report=($retained | ConvertTo-Json -Depth 6 | ConvertFrom-Json);json=($retained | ConvertTo-Json -Depth 6)}
    }
    $report = $prepared.report
    if ($report.sourceSha256 -cne $beforeHash) { throw 'The formal save changed during preparation.' }
    Write-NewText (Join-Path $run 'SaveChange.json') $prepared.json
    if ($Install) {
        Initialize-PbzOwnedProfile
        Migrate-LegacyUserData $prior
        $runtimeStage = Join-Path (Get-PbzTransactionWork) 'Runtime'
        Ensure-Directory $runtimeStage
        foreach ($entry in $manifest.PSObject.Properties) {
            if (!$entry.Name.StartsWith('ue4ss/')) { continue }
            $destination = Join-Path $runtimeStage $entry.Name.Substring(6)
            Copy-NewFile (Get-PbzRuntimePayloadFile $entry.Name) $destination
            Assert-Hash $destination $entry.Value
        }
        Write-NewText (Join-Path $runtimeStage $ownerName) $owner
        Write-NewText (Join-Path $runtimeStage $integratedName) $owner
        $config = Join-Path $runtimeStage 'Mods/PBZTestArena/Scripts/IntegratedConfig.lua'
        Write-NewText $config (New-Config $save)
        $proxyStage = Join-Path (Get-PbzTransactionWork) 'Proxy.dll'
        Copy-NewFile (Join-Path $payload 'dwmapi.dll') $proxyStage
        Assert-Hash $proxyStage $manifest.'dwmapi.dll'
        Assert-OwnedRuntime $runtimeStage -Integrated
        Grant-OwnedWriteAccess $runtimeStage $ownerName
    }

    Assert-NotRunning
    Assert-Hash $game $actualGameHash
    Assert-PreviousRuntime $prior -AllowMissingMod:$missing -ReplaceMod:$Install
    $script:pbzInstallerStage = 'commit'
    Set-PbzMapTransaction $maps $run
    Set-PbzLoaderBridgeTransaction $loaderBridges $run
    if ($pendingSave) {
        Add-PbzFileChange $save $report.sourceSha256 $report.outputSha256
        [void](Replace-Save $pendingSave $save $report.sourceSha256 $report.outputSha256 $rollback)
    }
    else { Assert-Hash $save $beforeHash }
    if (Test-Path -LiteralPath $active) {
        Assert-OwnedRuntime $active
        $movedActive = Join-Path $platform ('.PBZIntegrated-runtime-backup-' + $stamp)
        Assert-Contained $movedActive $platform
        Move-PbzTransactionPath $active $movedActive
        Assert-OwnedRuntime $movedActive
    }
    if (Test-Path -LiteralPath $proxy) {
        $movedProxy = Join-Path $platform ('.PBZIntegrated-proxy-backup-' + $stamp + '.dll')
        Assert-Contained $movedProxy $platform
        Move-PbzTransactionPath $proxy $movedProxy
    }
    if ($Install) {
        Move-PbzTransactionPath $runtimeStage $active
        Move-PbzTransactionPath $proxyStage $proxy
        $hashes = [ordered]@{}
        foreach ($entry in $manifest.PSObject.Properties) { $hashes[$entry.Name] = $entry.Value }
        foreach ($relative in @("ue4ss/$ownerName","ue4ss/$integratedName",'ue4ss/Mods/PBZTestArena/Scripts/IntegratedConfig.lua')) {
            $hashes[$relative] = Get-Hash (Join-Path $platform $relative)
        }
        foreach ($entry in $hashes.GetEnumerator()) { Assert-Hash (Join-Path $platform $entry.Key) $entry.Value }
        $initialActive = $movedActive
        $initialProxy = $movedProxy
        $initialProxyHash = if ($movedProxy) { Get-Hash $movedProxy } else { $null }
        if ($prior -and $prior.installed) {
            $initialActive = $prior.previousActiveBackup; $initialProxy = $prior.previousProxyBackup
            $initialProxyHash = $prior.previousProxySha256
        }
        $privateReceipt = Set-PbzPrivateSaveReceipt $prepared $prior
        $state = [ordered]@{ version=2; owner=$owner; installed=$true; installedAt=(Get-Date).ToUniversalTime().ToString('o');
            launcherRoot=$root; gameExe=[IO.Path]::GetFullPath($game); savePath=[IO.Path]::GetFullPath($save);
            profile=[IO.Path]::GetFullPath($profile); userSid=$UserSid; privateManifestSha256=$privateReceipt;mapFlow=$checkpointFlow;
            runtimeHashes=$hashes; mapHashes=$maps.Next; loaderBridgeHashes=$loaderBridges.Next; previousActiveBackup=$initialActive; previousProxyBackup=$initialProxy;
            previousProxySha256=$initialProxyHash; backup=$run }
        Write-PbzTransactionText $statePath ($state | ConvertTo-Json -Depth 8)
    } else {
        if ($prior.previousActiveBackup) {
            Assert-Contained $prior.previousActiveBackup $platform
            Assert-OwnedRuntime $prior.previousActiveBackup
            if (Test-Path -LiteralPath (Join-Path $prior.previousActiveBackup $integratedName)) { throw 'Refusing to restore another integrated installation during uninstall.' }
            Move-PbzTransactionPath $prior.previousActiveBackup $active
        }
        if ($prior.previousProxyBackup) {
            Assert-Contained $prior.previousProxyBackup $platform
            Assert-Hash $prior.previousProxyBackup $prior.previousProxySha256
            Move-PbzTransactionPath $prior.previousProxyBackup $proxy
        }
        $state = [ordered]@{version=2;owner=$owner;installed=$false;uninstalledAt=(Get-Date).ToUniversalTime().ToString('o');
            privateManifestSha256=$prior.privateManifestSha256;savePath=[IO.Path]::GetFullPath($save);
            dedicatedSaveBlocksRetained=$true;reportsRetained=$true;backup=$run}
        Write-PbzTransactionText $statePath ($state | ConvertTo-Json -Depth 4)
    }
    Assert-Hash $save $report.outputSha256
    if (Test-Path -LiteralPath $rollback) { Assert-Hash $rollback $report.sourceSha256 }
    Write-NewText (Join-Path $run 'Result.json') (([ordered]@{operation=$operationName;success=$true;
        sourceSha256=$report.sourceSha256;outputSha256=$report.outputSha256;runtimeBackup=$movedActive;proxyBackup=$movedProxy;
        gameStarted=$false}) | ConvertTo-Json -Depth 5)
    Complete-PbzTransaction 'TransactionComplete.json'
    if (Test-Path -LiteralPath $rollback) { Remove-Item -LiteralPath $rollback -ErrorAction SilentlyContinue }
    if ($Uninstall) { Write-Output "Uninstall completed; dedicated saves and reports were retained. PBZ was not started. Backup: $run" }
    else { Write-Output "Install completed. PBZ was not started. Backup: $run" }
} catch {
    $failure = $_
    Set-PbzTransactionFailure $failure $run
    throw $failure
} finally {
    if ($held) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
} catch {
    if (!$_.Exception.Data['PbzStage']) { $_.Exception.Data['PbzStage'] = $script:pbzInstallerStage }
    throw
}
