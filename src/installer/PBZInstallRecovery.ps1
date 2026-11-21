# Persist undo entries before touching live files. Recovery is scoped to the
# selected account and to known installer paths.
function Get-PbzPendingPath {
    return Join-Path $stateRoot 'InstallerPending.json'
}

function Get-PbzTransactionWork {
    return Join-Path $script:pbzTransactionRun 'Work'
}

function Get-PbzToolWork {
    return Join-Path $dataRoot ('T/' + $script:pbzTransaction.id.Substring(16) + '/IntegratedMenu')
}

function Initialize-PbzToolWork {
    $path = Get-PbzToolWork
    if (Test-Path -LiteralPath (Split-Path -Parent $path)) { throw 'Installer tool workspace already exists.' }
    $script:pbzTransaction.toolWork = $true
    Write-PbzJournal
    Ensure-Directory $path
    return $path
}

function Clear-PbzTransactionWork {
    if ($script:pbzTransaction.version -ne 2) { return }
    $workspaces = @(Get-PbzTransactionWork)
    if ($script:pbzTransaction.toolWork) { $workspaces += Split-Path -Parent (Get-PbzToolWork) }
    foreach ($directory in $workspaces) {
        if (!(Test-Path -LiteralPath $directory)) { continue }
        Assert-Contained $directory $dataRoot
        Assert-OrdinaryPath $directory
        $entries = @(Get-PbzTreeItems $directory | Sort-Object { $_.FullName.Length } -Descending)
        foreach ($entry in $entries) {
            if ($entry.PSIsContainer) { [IO.Directory]::Delete($entry.FullName, $false) }
            else { [IO.File]::Delete($entry.FullName) }
        }
        [IO.Directory]::Delete($directory, $false)
    }
}

function Get-PbzTextHash([string] $Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($Text))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-PbzPathIdentity([string] $Path) {
    if (!(Test-Path -LiteralPath $Path)) { return '' }
    Assert-OrdinaryPath $Path
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return 'f:' + (Get-Hash $Path) }
    $rows = foreach ($entry in @(Get-PbzTreeItems $Path | Sort-Object FullName)) {
        $relative = $entry.FullName.Substring($Path.TrimEnd([char[]]'\/').Length + 1).Replace('\','/')
        if ($entry.PSIsContainer) { 'd:' + $relative } else { 'f:' + (Get-Hash $entry.FullName) + ':' + $relative }
    }
    return 'd:' + (Get-PbzTextHash ($rows -join [char]10))
}

function Get-PbzMoveRole([string] $Path, [string] $JournalRun) {
    Assert-Contained $Path $installRoot
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -ieq $active) { return 'runtime' }
    if ($full -ieq $proxy) { return 'proxy' }
    if ($full -ieq $modDirectory) { return 'mod' }
    if ($full -ieq (Join-Path $JournalRun 'RuntimeBefore')) { return 'mod-stage' }
    $work = Join-Path $JournalRun 'Work'
    if ($full -ieq (Join-Path $work 'Mod')) { return 'mod-stage' }
    if ($full -ieq (Join-Path $work 'Runtime')) { return 'runtime-stage' }
    if ($full -ieq (Join-Path $work 'Proxy.dll')) { return 'proxy-stage' }
    $parent = Split-Path -Parent $full
    $leaf = Split-Path -Leaf $full
    if ($parent -ieq $platform) {
        if ($leaf -cmatch '^\.PBZShared-stage-[a-f0-9]{32}$') { return 'mod-stage' }
        if ($leaf -cmatch '^\.PBZIntegrated-(?:stage-[a-f0-9]{32}|runtime-backup-\d{8}-\d{6}-[a-f0-9]{8})$') { return 'runtime-stage' }
        if ($leaf -cmatch '^\.PBZIntegrated-(?:proxy-[a-f0-9]{32}|proxy-backup-\d{8}-\d{6}-[a-f0-9]{8})\.dll$') { return 'proxy-stage' }
    }
    $mapsFolder = Join-Path $installRoot 'ProjectPBZ/Content/Paks/~mods'
    if ($parent -ieq $mapsFolder -and $leaf -cmatch '^\.PBZArenaMap-[a-f0-9]{32}\.tmp$') { return 'map-stage' }
    if ($leaf -cin @(Get-PbzManagedMapNames)) {
        if ($parent -ieq (Join-Path $work 'Maps')) { return 'map-stage:' + $leaf }
        if ($parent -ieq $mapsFolder) { return 'map:' + $leaf }
        if ($parent -ieq (Join-Path $JournalRun 'MapsBefore')) { return 'map-backup:' + $leaf }
    }
    foreach ($id in $pbzLoaderBridgeIds) {
        if ($full -ieq (Join-Path $installRoot "ProjectPBZ/PBZModLoader/mods/$id/main.js")) { return 'bridge:' + $id }
        if ($full -ieq (Join-Path $JournalRun "LoaderBridgesBefore/$id/main.js")) { return 'bridge-backup:' + $id }
        if ($full -ieq (Join-Path $work "LoaderBridges/$id/main.js")) { return 'bridge-stage:' + $id }
    }
    Stop-PbzInstall 'RECOVERY_UNSAFE' '恢复记录包含无法核对的路径。请保留备份并导出诊断。'
}

function Assert-PbzJournalMove([string] $From, [string] $To, [string] $JournalRun) {
    $sourceRole = Get-PbzMoveRole $From $JournalRun
    $targetRole = Get-PbzMoveRole $To $JournalRun
    foreach ($role in @('mod','runtime','proxy')) {
        if (($sourceRole -ceq $role -and $targetRole -ceq "$role-stage") -or
                ($targetRole -ceq $role -and $sourceRole -ceq "$role-stage")) { return }
    }
    if ($sourceRole.StartsWith('map:') -and $targetRole -ceq ('map-backup:' + $sourceRole.Substring(4))) { return }
    if ($sourceRole -ceq 'map-stage' -and $targetRole.StartsWith('map:')) { return }
    if ($targetRole.StartsWith('map:') -and $sourceRole -ceq ('map-stage:' + $targetRole.Substring(4))) { return }
    if ($sourceRole.StartsWith('bridge:') -and $targetRole -ceq ('bridge-backup:' + $sourceRole.Substring(7))) { return }
    if ($targetRole.StartsWith('bridge:') -and $sourceRole -ceq ('bridge-stage:' + $targetRole.Substring(7))) { return }
    Stop-PbzInstall 'RECOVERY_UNSAFE' '恢复记录包含不受支持的文件移动。请保留备份并导出诊断。'
}

function Get-PbzJournalBackup([string] $Target, [string] $JournalRun) {
    Assert-Contained $Target $installRoot
    $full = [IO.Path]::GetFullPath($Target)
    if ($full -ieq $save) { return Join-Path $JournalRun 'Before.sav' }
    if ($full -ieq $statePath) { return Join-Path $JournalRun 'InstallState.json' }
    if ($full -ieq $privatePath) { return Join-Path $JournalRun 'PrivateSlots.json' }
    if ($full -ieq (Join-Path $preferences 'PBZLoadout.tsv') -or $full -ieq (Join-Path $profile 'PBZChallengeHistory.tsv') -or
        $full -ieq (Join-Path $profile 'PBZIntegratedProfile.txt') -or $full -ieq (Join-Path $preferences '.PBZTestArenaArenaPrefs-owner') -or
        ((Split-Path -Parent $full) -ieq (Join-Path $profile 'ChallengeReports') -and
            (Split-Path -Leaf $full) -cmatch '^[A-Za-z0-9_-]+\.json$')) {
        return '' # Migration only copies into previously empty destinations.
    }
    foreach ($id in $pbzLoaderBridgeIds) {
        $bridge = Join-Path $installRoot "ProjectPBZ/PBZModLoader/mods/$id/main.js"
        if ($full -ieq $bridge) { return Join-Path $JournalRun "LoaderBridgesBefore/$id/main.js" }
    }
    Stop-PbzInstall 'RECOVERY_UNSAFE' '恢复记录包含不受支持的文件替换。请保留备份并导出诊断。'
}

function Assert-PbzJournalDirectory([string] $Path) {
    $allowed = @($preferences, (Join-Path $stateRoot 'ArenaData'), $profile,
        (Join-Path $profile 'ChallengeReports'), (Join-Path $active 'Mods'),
        (Join-Path $installRoot 'ProjectPBZ/Content'), (Join-Path $installRoot 'ProjectPBZ/Content/Paks'),
        (Join-Path $installRoot 'ProjectPBZ/Content/Paks/~mods'),
        (Join-Path $installRoot 'ProjectPBZ/PBZModLoader/mods'))
    foreach ($id in $pbzLoaderBridgeIds) { $allowed += Join-Path $installRoot "ProjectPBZ/PBZModLoader/mods/$id" }
    if ([IO.Path]::GetFullPath($Path) -notin @($allowed | ForEach-Object { [IO.Path]::GetFullPath($_) })) {
        Stop-PbzInstall 'RECOVERY_UNSAFE' '恢复记录包含不受支持的目录。请保留备份并导出诊断。'
    }
}

function New-PbzTransactionDirectory([string] $Path) {
    if (!(Test-Path -LiteralPath $Path)) {
        Assert-PbzJournalDirectory $Path
        $parent = Split-Path -Parent $Path
        if (!(Test-Path -LiteralPath $parent)) { New-PbzTransactionDirectory $parent }
        Assert-OrdinaryPath $parent
        Add-PbzTransactionStep ([ordered]@{kind='directory';target=$Path})
        [void][IO.Directory]::CreateDirectory($Path)
    }
    Assert-OrdinaryPath $Path
    if (!(Test-Path -LiteralPath $Path -PathType Container)) { throw "Expected a directory: $Path" }
}

function Start-PbzTransaction([string] $Run, [string] $Action) {
    $path = Get-PbzPendingPath
    if (Test-Path -LiteralPath $path) { Stop-PbzInstall 'RECOVERY_PENDING' '请先恢复上次中断的操作。' $path }
    $data = [pscustomobject]@{version=2; owner=$owner; game=$game; save=$save;
        id=(Split-Path -Leaf $Run); action=$Action; steps=@(); newerSaveKept=$false; toolWork=$false}
    Write-AtomicText $path ($data | ConvertTo-Json -Depth 7) $Run -CreateOnly
    $script:pbzTransaction = $data
    $script:pbzTransactionRun = $Run
    Grant-OwnedWriteAccess $dataRoot '.PBZTestArenaData-owner' -AccountData
}

function New-PbzBackupRun([string] $Stamp) {
    $marker = Join-Path $dataRoot '.PBZTestArenaData-owner'
    if (Test-Path -LiteralPath $marker) {
        Assert-OrdinaryPath $marker
        if ([IO.File]::ReadAllText($marker).Trim() -cne $owner) {
            Stop-PbzInstall 'RECEIPT_UNVERIFIED' '演武数据目录的归属与安装器不符。请核对游戏和存档账号，仍失败时导出诊断。' $dataRoot
        }
    } else {
        if ((Test-Path -LiteralPath $dataRoot) -and @(Get-ChildItem -LiteralPath $dataRoot -Force).Count) {
            Stop-PbzInstall 'RECEIPT_UNVERIFIED' '已有演武数据，但缺少旧安装的归属记录。请保留该目录及存档，点击「导出诊断」核对。' $dataRoot
        }
        Ensure-Directory $dataRoot
        Write-AtomicText $marker $owner (Split-Path -Parent $dataRoot) -CreateOnly
    }
    $directory = Join-Path $stateRoot "Backups/$Stamp"
    Ensure-Directory $directory
    return $directory
}

function Read-PbzTransaction {
    $path = Get-PbzPendingPath
    Assert-OrdinaryPath $path
    if ((Get-Item -LiteralPath $path).Length -gt 1MB) { Stop-PbzInstall 'RECOVERY_UNSAFE' '恢复记录过大，请导出诊断。' }
    try { $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Stop-PbzInstall 'RECOVERY_UNSAFE' '无法读取恢复记录。请保留备份并导出诊断。' }
    $marker = Join-Path $dataRoot '.PBZTestArenaData-owner'
    Assert-OrdinaryPath $marker
    if ($data.version -notin @(1,2) -or ($data.version -eq 2 -and $data.toolWork -isnot [bool]) -or
        $data.owner -cne $owner -or $data.game -ine $game -or $data.save -ine $save -or
        $data.id -cnotmatch '^\d{8}-\d{6}-[a-f0-9]{8}$' -or @($data.steps).Count -gt 256 -or
        [IO.File]::ReadAllText($marker).Trim() -cne $owner) {
        Stop-PbzInstall 'RECOVERY_UNSAFE' '恢复记录与所选游戏或账号不符。请保留备份并导出诊断。'
    }
    $journalRun = Join-Path $stateRoot ('Backups/' + $data.id)
    Assert-OrdinaryPath $journalRun
    foreach ($step in $data.steps) {
        if ($step.kind -ceq 'move' -and $step.identity -cmatch '^[df]:[a-f0-9]{64}$') {
            $step.from = [IO.Path]::GetFullPath($step.from)
            $step.to = [IO.Path]::GetFullPath($step.to)
            Assert-PbzJournalMove $step.from $step.to $journalRun
        } elseif ($step.kind -ceq 'file' -and $step.before -cmatch '^(?:[a-f0-9]{64})?$' -and
                $step.after -cmatch '^(?:[a-f0-9]{64})?$' -and ($step.before -or $step.after)) {
            $step.target = [IO.Path]::GetFullPath($step.target)
            $backup = Get-PbzJournalBackup $step.target $journalRun
            if ($step.before -and !$backup) { Stop-PbzInstall 'RECOVERY_UNSAFE' '恢复记录缺少可验证的备份路径。' }
        } elseif ($data.version -eq 2 -and $step.kind -ceq 'directory') {
            $step.target = [IO.Path]::GetFullPath($step.target)
            Assert-PbzJournalDirectory $step.target
        } elseif ($data.version -eq 2 -and $step.kind -ceq 'acl' -and
                $step.target -ieq $dataRoot -and $step.before -cmatch '^D:' -and $step.after -cmatch '^D:') {
            $step.target = $dataRoot
        } else { Stop-PbzInstall 'RECOVERY_UNSAFE' '恢复记录格式不正确，请导出诊断。' }
    }
    $script:pbzTransaction = $data
    $script:pbzTransactionRun = $journalRun
}

function Add-PbzTransactionStep($Step) {
    if (!$script:pbzTransaction) { throw 'Internal installer error: no active transaction.' }
    if ($script:pbzTransaction.steps.Count -ge 256) { Stop-PbzInstall 'TOO_MANY_CHANGES' '本次安装涉及的文件操作过多，已停止。' }
    $script:pbzTransaction.steps += $Step
    Write-PbzJournal
}

function Write-PbzJournal {
    Write-AtomicText (Get-PbzPendingPath) ($script:pbzTransaction | ConvertTo-Json -Depth 7) $script:pbzTransactionRun
}

function Move-PbzTransactionPath([string] $From, [string] $To) {
    Assert-PbzJournalMove $From $To $script:pbzTransactionRun
    Assert-OrdinaryPath (Split-Path -Parent $To)
    if (Test-Path -LiteralPath $To) { Stop-PbzInstall 'PATH_CONFLICT' '目标路径在安装期间已被占用。' $To }
    $identity = Get-PbzPathIdentity $From
    if (!$identity) { Stop-PbzInstall 'PATH_UNAVAILABLE' '要移动的文件在安装期间已消失。' $From }
    Add-PbzTransactionStep ([ordered]@{kind='move';from=$From;to=$To;identity=$identity})
    try {
        if ($identity.StartsWith('d:')) { [IO.Directory]::Move($From,$To) } else { [IO.File]::Move($From,$To) }
    } catch {
        $failure = $_
        # Directory.Move may report access denied for a nested file lock.
        Assert-PbzMoveReady $From
        throw $failure
    }
}

function Add-PbzFileChange([string] $Target, [string] $Before, [string] $After) {
    if ($Before -ceq $After) { return }
    $backup = Get-PbzJournalBackup $Target $script:pbzTransactionRun
    if ($Before) { Assert-Hash $backup $Before; Assert-Hash $Target $Before }
    elseif (Test-Path -LiteralPath $Target) { Stop-PbzInstall 'PATH_CONFLICT' '目标文件在安装期间已出现。' $Target }
    Add-PbzTransactionStep ([ordered]@{kind='file';target=$Target;before=$Before;after=$After})
}

function Write-PbzTransactionText([string] $Target, [string] $Text) {
    $before = if (Test-Path -LiteralPath $Target) { Get-Hash $Target } else { '' }
    Add-PbzFileChange $Target $before (Get-PbzTextHash $Text)
    Write-AtomicText $Target $Text (Get-PbzTransactionWork) -CreateOnly:(!$before)
}

function Complete-PbzTransaction([string] $Result) {
    $path = Get-PbzPendingPath
    $resultPath = Join-Path $script:pbzTransactionRun $Result
    Assert-OrdinaryPath $path
    Assert-OrdinaryPath $script:pbzTransactionRun
    if ($Result -ceq 'TransactionRolledBack.json') { Clear-PbzTransactionWork }
    [IO.File]::Move($path, $resultPath)
    if ($Result -ceq 'TransactionComplete.json') {
        try { Clear-PbzTransactionWork } catch { Write-Warning $_.Exception.Message }
    }
    $script:pbzTransaction = $null
}

function Restore-PbzJournalFile($Step) {
    $target = [string]$Step.target
    $current = if (Test-Path -LiteralPath $target) { Get-Hash $target } else { '' }
    $journalRun = $script:pbzTransactionRun
    $backup = Get-PbzJournalBackup $target $journalRun
    $restoreHash = $Step.before
    $restoreDisplaced = Join-Path $journalRun ('Displaced-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    if ($target -ieq $save) {
        # Replace-Save's atomic swap can displace a cloud update before its
        # post-swap check ran. That file is newer than the preparation backup.
        $displacedSave = Join-Path $journalRun 'Replaced.sav'
        if (Test-Path -LiteralPath $displacedSave) {
            $restoreHash = Get-Hash $displacedSave
            $backup = $displacedSave
            if ($restoreHash -cne $Step.before) { $script:pbzTransaction.newerSaveKept = $true }
        }
        $restoreDisplaced = Join-Path $journalRun 'RecoverySaveDisplaced.sav'
        $concurrentBackup = Join-Path $journalRun 'RecoverySaveConcurrent.sav'
        if (Test-Path -LiteralPath $concurrentBackup) {
            if ((Get-Hash $concurrentBackup) -cne $restoreHash) {
                Stop-PbzInstall 'RECOVERY_CONFLICT' '恢复期间存档再次变化，两个版本均已保留。请保留备份并导出诊断。' $target
            }
            $script:pbzTransaction.newerSaveKept = $true
            return
        }
        if (Test-Path -LiteralPath $restoreDisplaced) {
            $captured = Get-Hash $restoreDisplaced
            if ($captured -cne $Step.after -and $current -ceq $restoreHash) {
                Assert-Hash $target $restoreHash
                [IO.File]::Replace($restoreDisplaced, $target, $concurrentBackup)
                if ((Get-Hash $concurrentBackup) -cne $restoreHash) {
                    Stop-PbzInstall 'RECOVERY_CONFLICT' '恢复期间存档再次变化，两个版本均已保留。请保留备份并导出诊断。' $target
                }
            }
            if ($captured -cne $Step.after -or $current -cne $restoreHash) { $script:pbzTransaction.newerSaveKept = $true }
            return
        }
    }
    if ($current -ceq $restoreHash) { return }
    if ($current -cne $Step.after) {
        if ($target -ieq $save) { $script:pbzTransaction.newerSaveKept=$true; return }
        Stop-PbzInstall 'RECOVERY_CONFLICT' '文件在安装器之外发生了变化，已保留现有内容。请保留备份并导出诊断。' $target
    }
    if (!$Step.before) {
        Assert-Hash $target $Step.after
        [IO.File]::Move($target, (Join-Path $journalRun ('Undo-' + [Guid]::NewGuid().ToString('N'))))
    } else {
        Assert-Hash $backup $restoreHash
        $temporary = Join-Path (Get-PbzTransactionWork) ('Restore-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        Copy-NewFile $backup $temporary
        Assert-Hash $temporary $restoreHash
        if (!$current) { [IO.File]::Move($temporary, $target) }
        else {
            Assert-Hash $target $current
            [IO.File]::Replace($temporary, $target, $restoreDisplaced)
            if ((Get-Hash $restoreDisplaced) -cne $current) {
                if ($target -ieq $save) { Restore-PbzJournalFile $Step; return }
                Stop-PbzInstall 'RECOVERY_CONFLICT' '恢复时文件再次变化，现有文件及备份均已保留。请导出诊断。' $target
            }
        }
    }
    if ($restoreHash) { Assert-Hash $target $restoreHash }
    elseif (Test-Path -LiteralPath $target) { throw 'A file appeared during installer recovery.' }
}

function Undo-PbzTransactionStep($Step) {
    if ($Step.kind -ceq 'acl') {
        Assert-OrdinaryPath $dataRoot
        $sections = [Security.AccessControl.AccessControlSections]::Access
        $acl = [IO.Directory]::GetAccessControl($dataRoot,$sections)
        $current = $acl.GetSecurityDescriptorSddlForm($sections)
        if ($current -ceq $Step.before) { return }
        if ($current -cne $Step.after) {
            Stop-PbzInstall 'RECOVERY_CONFLICT' '演武目录的权限在恢复前已发生变化。请保留备份并导出诊断。' $dataRoot
        }
        $acl.SetSecurityDescriptorSddlForm($Step.before,$sections)
        [IO.Directory]::SetAccessControl($dataRoot,$acl)
    } elseif ($Step.kind -ceq 'directory') {
        if ((Test-Path -LiteralPath $Step.target -PathType Container) -and
                !@(Get-ChildItem -LiteralPath $Step.target -Force).Count) {
            Assert-OrdinaryPath $Step.target
            [IO.Directory]::Delete($Step.target, $false)
        }
    } elseif ($Step.kind -ceq 'move') {
        $from = Get-PbzPathIdentity $Step.from
        $to = Get-PbzPathIdentity $Step.to
        if (!$from -and $to -ceq $Step.identity) {
            Assert-OrdinaryPath (Split-Path -Parent $Step.from)
            if ($to.StartsWith('d:')) { [IO.Directory]::Move($Step.to,$Step.from) }
            else { [IO.File]::Move($Step.to,$Step.from) }
        } elseif ($from -cne $Step.identity -or $to) {
            Stop-PbzInstall 'RECOVERY_CONFLICT' '移动的文件在安装器之外发生了变化，请保留备份并导出诊断。' $Step.from
        }
    } else { Restore-PbzJournalFile $Step }
}

function Undo-PbzTransaction {
    # Reopen the durable record. An operation may have stopped immediately
    # after an OS call returned, before any in-memory state could be updated.
    Read-PbzTransaction
    $remaining = [Collections.Generic.List[object]]::new()
    $remaining.AddRange([object[]]@($script:pbzTransaction.steps))
    $blockedPaths = [Collections.Generic.List[string]]::new()
    $firstFailure = $null
    for ($index = $remaining.Count - 1; $index -ge 0; $index--) {
        Assert-NotRunning
        $step = $remaining[$index]
        $paths = if ($step.kind -ceq 'move') { @($step.from, $step.to) } else { @($step.target) }
        $overlap = foreach ($path in $paths) {
            foreach ($blocked in $blockedPaths) {
                if ($path -ieq $blocked -or $path.StartsWith($blocked + '\', [StringComparison]::OrdinalIgnoreCase) -or
                        $blocked.StartsWith($path + '\', [StringComparison]::OrdinalIgnoreCase)) { $true }
            }
        }
        if ($overlap) { $blockedPaths.AddRange([string[]]@($paths)); continue }
        try { Undo-PbzTransactionStep $step } catch {
            if (!$firstFailure) { $firstFailure = $_ }
            $blockedPaths.AddRange([string[]]@($paths))
            continue
        }
        $remaining.RemoveAt($index)
        $script:pbzTransaction.steps = $remaining.ToArray()
        Write-PbzJournal
    }
    if ($firstFailure) { throw $firstFailure }
    $kept = $script:pbzTransaction.newerSaveKept
    Complete-PbzTransaction 'TransactionRolledBack.json'
    return $kept
}

function Set-PbzFailureRollback($Failure, [string] $Rollback) {
    $Failure.Exception.Data['PbzRollback'] = $Rollback
}

function Set-PbzTransactionFailure($Failure, [string] $Run) {
    $rollback = 'unchanged'
    $recoveryError = ''
    if ($script:pbzTransaction -and (Test-Path -LiteralPath (Get-PbzPendingPath))) {
        try {
            $kept = Undo-PbzTransaction
            $rollback = if ($kept) { 'rolled_back_newer_save_kept' } else { 'rolled_back' }
        } catch {
            $rollback = 'needs_recovery'
            $recoveryError = $_.Exception.Message
        }
    }
    Set-PbzFailureRollback $Failure $rollback
    if (!$Failure.Exception.Data['PbzStage']) { $Failure.Exception.Data['PbzStage'] = $script:pbzInstallerStage }
    if ($Run) {
        try {
            $record = Get-PbzInstallError $Failure
            $record.success = $false
            $record.recoveryError = $recoveryError
            $record.rollbackErrors = @(if ($recoveryError) { $recoveryError })
            Write-AtomicText (Join-Path $Run 'Failure.json') ($record | ConvertTo-Json -Depth 5)
        } catch { Write-Warning $_.Exception.Message }
    }
}

function Invoke-PbzPendingRecovery {
    $mutex = New-Object Threading.Mutex($false,'Local\PBZTestArenaNativeSession')
    $held = $false
    try {
        try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held=$true }
        if (!$held) { Stop-PbzInstall 'INSTALLER_BUSY' '另一项安装或游戏会话正在运行，请关闭后重试。' }
        Assert-NotRunning
        $kept = Undo-PbzTransaction
        if ($kept) { Write-Output '已恢复安装文件，并保留了期间更新的存档。请重新检查安装。' }
        else { Write-Output '已恢复上次操作前的文件和安装登记。请重新检查安装。' }
    } catch {
        Set-PbzFailureRollback $_ 'needs_recovery'
        throw
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
