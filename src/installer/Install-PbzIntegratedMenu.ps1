param(
    [switch] $Install,
    [switch] $Uninstall,
    [string] $SteamRoot = '',
    [string] $GameExe = '',
    [string] $SteamAccount = '',
    [string] $UserSid = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PortablePaths.ps1')
if ($Install -and $Uninstall) { throw 'Choose Install or Uninstall, not both.' }
$owner = '7d5ad307-d21c-47eb-9584-493443190984'
$saveOwner = 'PBZTestArena.IntegratedMenu'
$expectedGameHash = '4415933ce33476f14c837abb61a1b60af8b78cd81783896501913a7aac69e423'
$ownerName = '.PBZTestArenaNative-owner'
$integratedName = '.PBZTestArenaIntegrated-owner'
$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$integratedRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$runtimeRoot = Join-Path $root 'NativeEnemyRuntime'
$payload = Join-Path $runtimeRoot 'Payload'
$manifestPath = Join-Path $runtimeRoot 'PayloadHashes.json'
$helper = Join-Path $integratedRoot 'Tools/PBZSaveTool.exe'
$toolBuildPath = Join-Path $integratedRoot 'Tools/Build.json'
$presets = Join-Path $integratedRoot 'PrivatePresets.pbzs'
$legacyStatePath = Join-Path $integratedRoot 'InstallState.json'
$legacyPrivatePath = Join-Path $integratedRoot 'PrivateSlots.json'
if (!$GameExe -and $SteamRoot) { $GameExe = Join-Path $SteamRoot 'steamapps/common/PBZ/platform/steam/PBZ.exe' }
if (!$GameExe) {
    $candidates = @(Get-PbzGameCandidates)
    if ($candidates.Count -ne 1) { throw 'Choose PBZ.exe in the installer window, or pass -GameExe; no unique Steam game was found.' }
    $GameExe = $candidates[0].GameExe
}
$layout = Resolve-PbzGameLayout $GameExe
$game,$platform,$installRoot = $layout.GameExe,$layout.Platform,$layout.InstallRoot
$active = Join-Path $platform 'ue4ss'
$proxy = Join-Path $platform 'dwmapi.dll'
$saveSteamRoot = Join-Path $installRoot 'ProjectPBZ/Saved/SaveGames/Steam'
$utf8 = New-Object Text.UTF8Encoding($false)
if (!$UserSid) { $UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
if ($UserSid -cnotmatch '^S-1-(?:5-21|12-1)(?:-\d+){4}$') { throw 'A normal Windows user SID is required for private MOD write access.' }

function Assert-OrdinaryPath([string] $Path) {
    $item = Get-Item -LiteralPath $Path -Force
    while ($null -ne $item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked paths are not supported: $Path" }
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
    if (!(Test-Path -LiteralPath $Path -PathType Container)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    Assert-OrdinaryPath $Path
}

function Get-Hash([string] $Path) {
    Assert-OrdinaryPath $Path
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-Hash([string] $Path, [string] $Expected) {
    if ((Get-Hash $Path) -cne $Expected.ToLowerInvariant()) { throw "File hash mismatch: $Path" }
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

function Write-AtomicText([string] $Path, [string] $Text) {
    Ensure-Directory (Split-Path -Parent $Path)
    $pending = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    Write-NewText $pending $Text
    try {
        if (Test-Path -LiteralPath $Path) { Assert-OrdinaryPath $Path; [IO.File]::Replace($pending,$Path,[NullString]::Value) }
        else { [IO.File]::Move($pending,$Path) }
    } finally { if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending } }
}

function Test-GameRunning {
    return [bool](Get-Process -Name 'PBZ','ProjectPBZ-Win64-Shipping' -ErrorAction SilentlyContinue)
}

function Assert-NotRunning {
    if (Test-GameRunning) { throw 'Exit PBZ before changing the installed MOD menu.' }
}

function Grant-OwnedWriteAccess([string] $Directory, [string] $Marker) {
    Assert-OrdinaryPath $Directory
    $proof = Join-Path $Directory $Marker
    Assert-OrdinaryPath $proof
    if ([IO.File]::ReadAllText($proof).Trim() -cne $owner) { throw 'Refusing ACL changes outside an owned MOD directory.' }
    $identity = New-Object Security.Principal.SecurityIdentifier($UserSid)
    $acl = [IO.Directory]::GetAccessControl($Directory)
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
    $acl.SetAccessRule($rule)
    [IO.Directory]::SetAccessControl($Directory,$acl)
}

function Assert-OwnedRuntime([string] $Directory, [switch] $Integrated) {
    Assert-OrdinaryPath $Directory
    $marker = Join-Path $Directory $ownerName
    Assert-OrdinaryPath $marker
    if ([IO.File]::ReadAllText($marker).Trim() -cne $owner) { throw 'An unowned UE4SS installation is present.' }
    if ($Integrated) {
        $persistent = Join-Path $Directory $integratedName
        Assert-OrdinaryPath $persistent
        if ([IO.File]::ReadAllText($persistent).Trim() -cne $owner) { throw 'The persistent menu ownership marker differs.' }
    }
    $mods = Join-Path $Directory 'Mods'
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
    return @"
return {
    version = 2,
    owner = $(Lua-String $owner),
    profile = $(Lua-String $profile),
    savePath = $(Lua-String $SavePath),
    gameSha256 = $(Lua-String $expectedGameHash),
    loadoutMemoryPath = $(Lua-String (Join-Path $preferences 'PBZLoadout.tsv')),
    trainingSlot = "PBZArenaIntegratedTraining",
    cyclePrefix = "PBZArenaIntegratedCycle",
    defaultPlayerCycle = 6,
    defaultEnemyCycle = 0,
}
"@
}

function Get-PreviousState {
    $readState,$readPrivate = $statePath,$privatePath
    if (!(Test-Path -LiteralPath $readState -PathType Leaf) -and (Test-Path -LiteralPath $legacyStatePath -PathType Leaf)) {
        $readState,$readPrivate = $legacyStatePath,$legacyPrivatePath
    }
    if (!(Test-Path -LiteralPath $readState -PathType Leaf)) { return $null }
    Assert-OrdinaryPath $readState
    $state = Get-Content -LiteralPath $readState -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.version -notin @(1,2) -or $state.owner -cne $owner) { throw 'Unknown integrated-menu installation state.' }
    if ($state.installed) {
        if ([IO.Path]::GetFullPath($state.gameExe) -ine [IO.Path]::GetFullPath($game) -or
            [IO.Path]::GetFullPath($state.savePath) -ine [IO.Path]::GetFullPath($save)) { throw 'This installation state belongs to another game or account.' }
    }
    if ($state.privateManifestSha256) { Assert-Hash $readPrivate $state.privateManifestSha256 }
    elseif ($state.installed) { throw 'The installation has no private save ownership receipt.' }
    $state | Add-Member -NotePropertyName verifiedPrivatePath -NotePropertyValue $readPrivate -Force
    return $state
}

function Assert-PreviousRuntime($State) {
    if (Test-Path -LiteralPath $active) {
        Assert-OwnedRuntime $active
        $persistent = Join-Path $active $integratedName
        if (Test-Path -LiteralPath $persistent) {
            Assert-OwnedRuntime $active -Integrated
            if (!$State -or !$State.installed) { throw 'The installed menu is missing its ownership receipt; refusing to replace it.' }
            foreach ($entry in $State.runtimeHashes.PSObject.Properties) {
                Assert-Hash (Join-Path $platform $entry.Name) $entry.Value
            }
        }
    }
    if (Test-Path -LiteralPath $proxy) {
        if (!(Test-Path -LiteralPath $active) -and (!$State -or !$State.installed)) { throw 'An unowned dwmapi.dll is present.' }
        $expected = $manifest.'dwmapi.dll'
        if ($State -and $State.installed) { $expected = $State.runtimeHashes.'dwmapi.dll' }
        Assert-Hash $proxy $expected
    }
}

function Invoke-SaveTool([string] $SavePath, [string] $Output, [string] $PriorManifest) {
    $arguments = @('stage','--game',$game,'--source',$SavePath,'--presets',$presets,'--output',$Output)
    if ($PriorManifest) { $arguments += @('--prior',$PriorManifest) }
    $json = & $helper @arguments
    if ($LASTEXITCODE -ne 0) { throw 'The portable save tool refused staging; no formal save was replaced.' }
    $text = $json -join [Environment]::NewLine
    $result = $text | ConvertFrom-Json
    if ($result.schemaVersion -ne 1 -or $result.owner -cne $saveOwner -or $result.operation -cne 'stage' -or
        $result.sourceSha256 -cnotmatch '^[a-f0-9]{64}$' -or $result.outputSha256 -cnotmatch '^[a-f0-9]{64}$' -or
        $result.gameSha256 -cne $expectedGameHash -or $result.presetsSha256 -cne $toolBuild.presetsSha256 -or
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
    if (!$ordinary.Count) { throw '请先新游戏并创建一次正常存档，退出后安装。' }
    $verificationArguments = @('verify','--game',$game,'--before',$SavePath,'--after',$Output,'--presets',$presets)
    if ($PriorManifest) { $verificationArguments += @('--prior',$PriorManifest) }
    $verificationJson = & $helper @verificationArguments
    if ($LASTEXITCODE -ne 0) { throw 'The portable save tool rejected the candidate during independent verification.' }
    $verification = ($verificationJson -join [Environment]::NewLine) | ConvertFrom-Json
    if ($verification.operation -cne 'verify' -or $verification.sourceSha256 -cne $result.sourceSha256 -or
        $verification.outputSha256 -cne $result.outputSha256 -or $verification.originalBlockIdentity -ne $true -or
        $verification.advancedSha256Before -cne $result.advancedSha256Before -or
        $verification.advancedSha256After -cne $result.advancedSha256After -or
        $verification.continue.verification -cne 'opaque-Advanced-block-identical' -or $verification.continue.changed -ne $false) {
        throw 'The independent candidate verification differs from staging.'
    }
    Assert-Hash $SavePath $result.sourceSha256
    Assert-Hash $Output $result.outputSha256
    return @{ report = $result; json = $text }
}

function Replace-Save([string] $Source, [string] $Destination, [string] $BeforeHash,
    [string] $AfterHash, [string] $Rollback) {
    Assert-NotRunning
    Assert-Hash $Destination $BeforeHash
    if ($BeforeHash -ceq $AfterHash) { return $false }
    $pending = $Destination + '.PBZIntegrated-' + [Guid]::NewGuid().ToString('N') + '.tmp'
    Assert-Contained $pending (Split-Path -Parent $Destination)
    Copy-NewFile $Source $pending
    try {
        Assert-Hash $pending $AfterHash
        Assert-Hash $Destination $BeforeHash
        [IO.File]::Replace($pending,$Destination,$Rollback)
        Assert-Hash $Destination $AfterHash
        Assert-Hash $Rollback $BeforeHash
    } finally { if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending } }
    return $true
}

function Restore-Save([string] $SavePath, [string] $Rollback, [string] $BeforeHash, [string] $AfterHash) {
    if (!(Test-Path -LiteralPath $Rollback)) { return }
    Assert-Hash $Rollback $BeforeHash
    Assert-Hash $SavePath $AfterHash
    [IO.File]::Replace($Rollback,$SavePath,[NullString]::Value)
    Assert-Hash $SavePath $BeforeHash
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
    Copy-NewFile $Source $Destination
    Assert-Hash $Destination $digest
    $script:migratedFiles[$Destination] = $digest
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

Assert-OrdinaryPath $integratedRoot
Assert-OrdinaryPath $platform
if ($Uninstall) { Assert-OrdinaryPath $game } else { Assert-Hash $game $expectedGameHash }
Assert-NotRunning
Assert-Payload
if (!$Uninstall) { Assert-PortableTools }
$accounts = @(Get-ChildItem -LiteralPath $saveSteamRoot -Directory | Where-Object { $_.Name -match '^\d{17}$' })
if ($SteamAccount) {
    if ($SteamAccount -cnotmatch '^\d{17}$') { throw 'Invalid Steam account directory name.' }
    $accounts = @($accounts | Where-Object { $_.Name -ceq $SteamAccount })
}
if ($accounts.Count -ne 1) { throw 'Expected one formal Steam save account; use -SteamAccount if more than one exists.' }
$account = $accounts[0].Name
$save = Join-Path $accounts[0].FullName 'PBZSaveGame.sav'
Assert-OrdinaryPath $save
$dataRoot = Join-Path $installRoot ('ProjectPBZ/Saved/PBZTestArena/' + $account)
$stateRoot = Join-Path $dataRoot 'IntegratedMenu'
$statePath = Join-Path $stateRoot 'InstallState.json'
$privatePath = Join-Path $stateRoot 'PrivateSlots.json'
$profile = Join-Path $stateRoot 'ArenaData/Profile'
$preferences = Join-Path $dataRoot 'ArenaPreferences'
$prior = Get-PreviousState
Assert-PreviousRuntime $prior
if (!$Install -and !$Uninstall) {
    Write-Output 'Integrated-menu payload, game build and formal save paths verified. No files changed; no game started.'
    return
}

$mutex = New-Object Threading.Mutex($false,'Local\PBZTestArenaNativeSession')
$held = $false
$run = $null
$runtimeStage = $null
$proxyStage = $null
$movedActive = $null
$movedProxy = $null
$installedActive = $false
$installedProxy = $false
$saveReplaced = $false
$restoreInitialActive = $null
$restoreInitialProxy = $null
$writtenReceipts = @{}
$migratedFiles = @{}
$migrationNotes = New-Object 'System.Collections.Generic.List[string]'
$report = $null
$rollback = $save + '.PBZIntegrated-rollback-' + [Guid]::NewGuid().ToString('N')
try {
    try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (!$held) { throw 'Another PBZ MOD installation or isolated test launcher is running.' }
    Assert-NotRunning
    $prior = Get-PreviousState
    Assert-PreviousRuntime $prior
    if ($Uninstall -and (!$prior -or !$prior.installed)) { throw 'No owned persistent menu installation was found.' }
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
    $operationName = if ($Install) { 'Install' } else { 'Uninstall' }
    if (Test-Path -LiteralPath $dataRoot) { Assert-OrdinaryPath $dataRoot }
    $dataMarker = Join-Path $dataRoot '.PBZTestArenaData-owner'
    if (Test-Path -LiteralPath $dataMarker) {
        Assert-OrdinaryPath $dataMarker
        if ([IO.File]::ReadAllText($dataMarker).Trim() -cne $owner) { throw 'The persistent arena data belongs to another owner.' }
    } elseif ((Test-Path -LiteralPath $dataRoot) -and @(Get-ChildItem -LiteralPath $dataRoot -Force).Count) {
        throw 'An unowned arena data directory already exists; no contents were overwritten.'
    } else { Ensure-Directory $dataRoot;Write-NewText $dataMarker $owner }
    Grant-OwnedWriteAccess $dataRoot '.PBZTestArenaData-owner'
    $run = Join-Path $stateRoot "Backups/$stamp"
    Ensure-Directory $run
    if ($Install) {
        $sourceHelper,$sourcePresets = $helper,$presets
        $transaction = Join-Path $dataRoot "Transactions/$operationName-$stamp/IntegratedMenu"
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
    $pendingSave = if ($Install) { Join-Path $staging 'Pending.sav' } else { $null }
    $priorManifest = if ($prior -and $prior.privateManifestSha256) { $prior.verifiedPrivatePath } else { '' }
    if ($Install) { $prepared = Invoke-SaveTool $save $pendingSave $priorManifest }
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
        $preferenceMarker = Join-Path $preferences '.PBZTestArenaArenaPrefs-owner'
        if (Test-Path -LiteralPath $preferenceMarker) {
            Assert-OrdinaryPath $preferenceMarker
            if ([IO.File]::ReadAllText($preferenceMarker).Trim() -cne $owner) { throw 'The equipment preference directory belongs to another owner.' }
        } elseif ((Test-Path -LiteralPath $preferences) -and @(Get-ChildItem -LiteralPath $preferences -Force).Count) {
            throw 'Existing unowned preferences were not modified.'
        } else { Ensure-Directory $preferences;Write-NewText $preferenceMarker $owner }
        Ensure-Directory $profile
        Ensure-Directory (Join-Path $profile 'ChallengeReports')
        $profileMarker = Join-Path $profile 'PBZIntegratedProfile.txt'
        if (Test-Path -LiteralPath $profileMarker) {
            Assert-OrdinaryPath $profileMarker
            if ([IO.File]::ReadAllText($profileMarker).Trim() -cne $owner) { throw 'The integrated profile marker differs.' }
        } else { Write-NewText $profileMarker $owner }
        Migrate-LegacyUserData $prior
        $runtimeStage = Join-Path $platform ('.PBZIntegrated-stage-' + [Guid]::NewGuid().ToString('N'))
        Assert-Contained $runtimeStage $platform
        Ensure-Directory $runtimeStage
        foreach ($entry in $manifest.PSObject.Properties) {
            if (!$entry.Name.StartsWith('ue4ss/')) { continue }
            $destination = Join-Path $runtimeStage $entry.Name.Substring(6)
            Copy-NewFile (Join-Path $payload $entry.Name) $destination
            Assert-Hash $destination $entry.Value
        }
        Write-NewText (Join-Path $runtimeStage $ownerName) $owner
        Write-NewText (Join-Path $runtimeStage $integratedName) $owner
        $config = Join-Path $runtimeStage 'Mods/PBZTestArena/Scripts/IntegratedConfig.lua'
        Write-NewText $config (New-Config $save)
        $proxyStage = Join-Path $platform ('.PBZIntegrated-proxy-' + [Guid]::NewGuid().ToString('N') + '.dll')
        Copy-NewFile (Join-Path $payload 'dwmapi.dll') $proxyStage
        Assert-Hash $proxyStage $manifest.'dwmapi.dll'
        Assert-OwnedRuntime $runtimeStage -Integrated
        Grant-OwnedWriteAccess $runtimeStage $ownerName
    }

    Assert-NotRunning
    if ($Install) { $saveReplaced = Replace-Save $pendingSave $save $report.sourceSha256 $report.outputSha256 $rollback }
    else { Assert-Hash $save $beforeHash }
    if (Test-Path -LiteralPath $active) {
        Assert-OwnedRuntime $active
        $movedActive = Join-Path $platform ('.PBZIntegrated-runtime-backup-' + $stamp)
        Assert-Contained $movedActive $platform
        [IO.Directory]::Move($active,$movedActive)
    }
    if (Test-Path -LiteralPath $proxy) {
        $movedProxy = Join-Path $platform ('.PBZIntegrated-proxy-backup-' + $stamp + '.dll')
        Assert-Contained $movedProxy $platform
        [IO.File]::Move($proxy,$movedProxy)
    }
    if ($Install) {
        [IO.Directory]::Move($runtimeStage,$active); $runtimeStage = $null; $installedActive = $true
        [IO.File]::Move($proxyStage,$proxy); $proxyStage = $null; $installedProxy = $true
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
        Write-AtomicText $privatePath $prepared.json
        $writtenReceipts[$privatePath] = Get-Hash $privatePath
        $state = [ordered]@{ version=2; owner=$owner; installed=$true; installedAt=(Get-Date).ToUniversalTime().ToString('o');
            launcherRoot=$root; gameExe=[IO.Path]::GetFullPath($game); savePath=[IO.Path]::GetFullPath($save);
            profile=[IO.Path]::GetFullPath($profile); userSid=$UserSid; privateManifestSha256=(Get-Hash $privatePath);
            runtimeHashes=$hashes; previousActiveBackup=$initialActive; previousProxyBackup=$initialProxy;
            previousProxySha256=$initialProxyHash; backup=$run }
        Write-AtomicText $statePath ($state | ConvertTo-Json -Depth 8)
        $writtenReceipts[$statePath] = Get-Hash $statePath
    } else {
        if ($prior.previousActiveBackup) {
            Assert-Contained $prior.previousActiveBackup $platform
            Assert-OwnedRuntime $prior.previousActiveBackup
            if (Test-Path -LiteralPath (Join-Path $prior.previousActiveBackup $integratedName)) { throw 'Refusing to restore another integrated installation during uninstall.' }
            [IO.Directory]::Move($prior.previousActiveBackup,$active)
            $restoreInitialActive = $prior.previousActiveBackup
        }
        if ($prior.previousProxyBackup) {
            Assert-Contained $prior.previousProxyBackup $platform
            Assert-Hash $prior.previousProxyBackup $prior.previousProxySha256
            [IO.File]::Move($prior.previousProxyBackup,$proxy)
            $restoreInitialProxy = $prior.previousProxyBackup
        }
        $state = [ordered]@{version=2;owner=$owner;installed=$false;uninstalledAt=(Get-Date).ToUniversalTime().ToString('o');
            privateManifestSha256=$prior.privateManifestSha256;savePath=[IO.Path]::GetFullPath($save);
            dedicatedSaveBlocksRetained=$true;reportsRetained=$true;backup=$run}
        Write-AtomicText $statePath ($state | ConvertTo-Json -Depth 4)
        $writtenReceipts[$statePath] = Get-Hash $statePath
    }
    Assert-Hash $save $report.outputSha256
    if (Test-Path -LiteralPath $rollback) { Assert-Hash $rollback $report.sourceSha256; Remove-Item -LiteralPath $rollback }
    Write-NewText (Join-Path $run 'Result.json') (([ordered]@{operation=$operationName;success=$true;
        sourceSha256=$report.sourceSha256;outputSha256=$report.outputSha256;runtimeBackup=$movedActive;proxyBackup=$movedProxy;
        gameStarted=$false}) | ConvertTo-Json -Depth 5)
    if ($Uninstall) { Write-Output "Uninstall completed; dedicated saves and reports were retained. PBZ was not started. Backup: $run" }
    else { Write-Output "Install completed. PBZ was not started. Backup: $run" }
} catch {
    $failure = $_
    $rollbackErrors = New-Object 'System.Collections.Generic.List[string]'
    try {
        if ($installedProxy -and (Test-Path -LiteralPath $proxy)) {
            Assert-Hash $proxy $manifest.'dwmapi.dll'
            [IO.File]::Move($proxy,(Join-Path $platform ('.PBZIntegrated-failed-proxy-' + [Guid]::NewGuid().ToString('N') + '.dll')))
        }
        if ($installedActive -and (Test-Path -LiteralPath $active)) {
            Assert-OwnedRuntime $active -Integrated
            [IO.Directory]::Move($active,(Join-Path $platform ('.PBZIntegrated-failed-runtime-' + [Guid]::NewGuid().ToString('N'))))
        }
        if ($restoreInitialProxy -and (Test-Path -LiteralPath $proxy)) { [IO.File]::Move($proxy,$restoreInitialProxy) }
        if ($restoreInitialActive -and (Test-Path -LiteralPath $active)) { [IO.Directory]::Move($active,$restoreInitialActive) }
        if ($movedActive -and (Test-Path -LiteralPath $movedActive) -and !(Test-Path -LiteralPath $active)) { [IO.Directory]::Move($movedActive,$active) }
        if ($movedProxy -and (Test-Path -LiteralPath $movedProxy) -and !(Test-Path -LiteralPath $proxy)) { [IO.File]::Move($movedProxy,$proxy) }
    } catch { $rollbackErrors.Add('Runtime rollback: ' + $_.Exception.Message) }
    try {
        if ($report -and (Test-Path -LiteralPath $rollback)) { Restore-Save $save $rollback $report.sourceSha256 $report.outputSha256 }
    } catch { $rollbackErrors.Add('Save rollback refused: ' + $_.Exception.Message) }
    foreach ($file in @($migratedFiles.Keys)) {
        try { if (Test-Path -LiteralPath $file) { Assert-Hash $file $migratedFiles[$file];Remove-Item -LiteralPath $file } }
        catch { $rollbackErrors.Add('Legacy profile rollback refused: ' + $_.Exception.Message) }
    }
    try {
        if ($run) {
            foreach ($file in @($statePath,$privatePath)) {
                if (!$writtenReceipts.ContainsKey($file)) { continue }
                $backupFile = Join-Path $run ([IO.Path]::GetFileName($file))
                if ($writtenReceipts[$file] -eq 'missing') {
                    if (Test-Path -LiteralPath $file) { throw 'A receipt changed during rollback.' }
                } else { Assert-Hash $file $writtenReceipts[$file] }
                if (Test-Path -LiteralPath $backupFile) { Write-AtomicText $file ([IO.File]::ReadAllText($backupFile)) }
                elseif (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
            }
            Write-AtomicText (Join-Path $run 'Failure.json') (([ordered]@{success=$false;message=$failure.Exception.Message;
                rollbackErrors=@($rollbackErrors);runtimeStage=$runtimeStage;proxyStage=$proxyStage;gameStarted=$false}) | ConvertTo-Json -Depth 5)
        }
    } catch { $rollbackErrors.Add('Receipt rollback: ' + $_.Exception.Message) }
    if ($rollbackErrors.Count) { Write-Warning ($rollbackErrors -join [Environment]::NewLine) }
    throw $failure
} finally {
    if ($held) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
