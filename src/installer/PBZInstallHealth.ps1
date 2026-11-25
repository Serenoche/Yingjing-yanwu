# Status and read-only checks shared by the installer UI and engine.
function Stop-PbzInstall([string] $Code, [string] $Message, [string] $Target = '', [int] $NativeCode = 0) {
    $errorInfo = [InvalidOperationException]::new($Message)
    $errorInfo.Data['PbzCode'] = $Code
    $errorInfo.Data['PbzTarget'] = $Target
    $errorInfo.Data['PbzNativeCode'] = $NativeCode
    $errorInfo.Data['PbzStage'] = $script:pbzInstallerStage
    throw $errorInfo
}

function Get-PbzInstallError($Record) {
    $code = $null
    $native = 0
    $target = ''
    $rollback = ''
    $stage = $script:pbzInstallerStage
    for ($cause = $Record.Exception; $cause; $cause = $cause.InnerException) {
        if ($cause.Data['PbzStage']) { $stage = [string]$cause.Data['PbzStage'] }
        if (!$rollback -and $cause.Data['PbzRollback']) { $rollback = [string]$cause.Data['PbzRollback'] }
        if (!$code -and $cause.Data['PbzCode']) {
            $code = [string]$cause.Data['PbzCode']
            $target = [string]$cause.Data['PbzTarget']
            $native = [int]$cause.Data['PbzNativeCode']
        } elseif (!$code -and $cause -is [IO.PathTooLongException]) {
            $code = 'PATH_TOO_LONG'
            $native = 206
        } elseif (!$code -and ($cause.HResult -band 0xffff) -in @(5,19,32,33,39,112,206)) {
            $native = $cause.HResult -band 0xffff
        }
    }
    if (!$code) {
        $code = switch ($native) {
            5 { 'ACCESS_DENIED' }
            19 { 'WRITE_PROTECTED' }
            { $_ -in @(32,33) } { 'FILE_IN_USE' }
            { $_ -in @(39,112) } { 'DISK_FULL' }
            206 { 'PATH_TOO_LONG' }
            default { 'CHECK_FAILED' }
        }
    }
    if (!$rollback -and $code -in @('RECOVERY_PENDING','RECOVERY_UNSAFE','RECOVERY_CONFLICT')) { $rollback = 'needs_recovery' }
    return @{ code=$code; target=$target; nativeCode=$native; error=$Record.Exception.Message;
        stage=$stage; rollback=if($rollback) { $rollback } else { 'unchanged' } }
}

function Format-PbzIssue($Issue, [switch] $ShowRollback) {
    $message = switch ($Issue.code) {
        'PACKAGE_PATH_TOO_LONG' { '解压路径过长。请把 ZIP 重新完整解压到磁盘根目录下的短文件夹，例如 D:\演武，再打开安装器。' }
        'GAME_PATH_TOO_LONG' { '游戏或安装备份路径过长。请在 Steam 或 Epic 中把游戏移到路径较短的游戏库，再选择新位置。' }
        'PATH_TOO_LONG' {
            if ($Issue.stage -in @('package','startup')) { '解压路径过长。请把 ZIP 重新完整解压到较短的目录，例如 D:\演武。' }
            else { '游戏或安装备份路径过长。请在游戏平台中把游戏移到路径较短的游戏库，再选择新位置。' }
        }
        'FILE_IN_USE' { '有文件正被使用。请完全退出游戏、MOD 管理器及打开该文件的程序，再重试。' }
        'ACCESS_DENIED' { 'Windows 拒绝写入。请按提示用管理员权限重试。若仍失败，请检查游戏目录的写入权限，再导出诊断。' }
        'WRITE_PROTECTED' { '安装目标所在磁盘禁止写入。请解除写保护，或在游戏平台中将游戏移到可写磁盘，再重试。' }
        'DISK_FULL' { '磁盘空间不足。请清理游戏所在磁盘的空间，再重新检查安装。' }
        'CHECK_FAILED' {
            switch ($Issue.stage) {
                { $_ -in @('package','startup') } { '安装包缺少文件或校验失败。请重新下载，完整解压 ZIP 后再打开安装器。' }
                { $_ -in @('selection','game_path','account') } { '无法读取所选游戏或存档目录。请从游戏平台打开「浏览本地文件」，重新选择游戏目录和存档账号。' }
                'game_version' { '无法核对游戏版本。请在 Steam 或 Epic 中验证游戏文件，再重试。' }
                'receipt' { '无法读取演武的旧安装记录。请选回原游戏目录和原存档账号。若仍失败，请导出诊断。' }
                'loader' { '无法读取现有 UE4SS。请用原 MOD 管理器修复前置并确认游戏可正常启动，再重新检查。' }
                'content' { '无法核对演武地图或配套文件。请先还原对应的旧地图内测，再重新检查。若未装过内测，请导出诊断。' }
                'recovery' { '无法读取上次安装的恢复记录。请保留备份并导出诊断。' }
                'diagnostics' { '诊断包未能写出。请确认桌面或下载目录可写且有可用空间，再导出一次。' }
                default { '安装器未能完成文件操作。请完全退出游戏和 MOD 管理器后重试。若再次失败，点击「导出诊断」。' }
            }
        }
        default { $Issue.error }
    }
    if (!$ShowRollback) { return $message }
    $state = switch ($Issue.rollback) {
        'needs_recovery' { '请退出游戏及 MOD 管理器，点击「恢复上次操作」。若仍无法恢复，请导出诊断，保留备份。' }
        'rolled_back' { '本次对游戏、存档和现有 MOD 的改动已撤销。' }
        'rolled_back_newer_save_kept' { '本次安装文件已回退，恢复期间更新的存档已保留。' }
        default { '本次操作没有改动游戏、存档或现有 MOD。' }
    }
    return $message + [Environment]::NewLine + [Environment]::NewLine + $state
}

# Windows PowerShell and the installer use legacy Windows file APIs.
function Assert-PbzPathLength([string] $Path, [string] $Code = 'GAME_PATH_TOO_LONG', [switch] $Directory) {
    $limit = if ($Directory) { 248 } else { 260 }
    if ($Path.Length -ge $limit) { Stop-PbzInstall $Code 'Windows path length limit' $Path 206 }
}

function Assert-PbzPackagePaths([string] $Root) {
    $list = [IO.Path]::Combine($Root,'SHA256SUMS.txt')
    Assert-PbzPathLength $list 'PACKAGE_PATH_TOO_LONG'
    if (![IO.File]::Exists($list)) { return }
    foreach ($line in [IO.File]::ReadLines($list)) {
        if ($line -match '^[a-fA-F0-9]{64}  ([^\\/:][^:]*[^:])$') {
            Assert-PbzPathLength ($Root.TrimEnd([char]'\') + '\' + $Matches[1]) 'PACKAGE_PATH_TOO_LONG'
        }
    }
}

function Initialize-PbzFileAccessProbe {
    if (!('PbzInstaller.FileAccessProbe' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace PbzInstaller {
    public static class FileAccessProbe {
        [DllImport("kernel32.dll")]
        public static extern uint GetACP();

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string path, uint access, uint share, IntPtr security, uint mode, uint flags, IntPtr template);

        public static int Check(string path, uint access) {
            using (SafeFileHandle handle = CreateFile(path, access, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
                return handle.IsInvalid ? Marshal.GetLastWin32Error() : 0;
            }
        }
    }
}
'@
    }
}

function Assert-PbzLuaGamePath($Layout) {
    foreach ($path in @($Layout.InstallRoot, $Layout.EntryRoot)) {
        if ($path -cmatch '[^\x00-\x7f]') {
            Initialize-PbzFileAccessProbe
            if ([PbzInstaller.FileAccessProbe]::GetACP() -ne 65001) {
                Stop-PbzInstall 'GAME_PATH_ENCODING' '游戏安装目录含中文或其他非 ASCII 字符，当前 UE4SS 可能无法读取演武配置。请在 Steam 或 Epic 中把游戏移到纯英文路径的游戏库，再点击「检查安装」。' $path
            }
        }
    }
}

function Get-PbzPathAccess([string] $Path, [uint32] $Access) {
    Initialize-PbzFileAccessProbe
    return [PbzInstaller.FileAccessProbe]::Check($Path, $Access)
}

function Get-PbzTreeItems([string] $Directory) {
    # Do not descend into a junction or follow linked files in an installation.
    Assert-OrdinaryPath $Directory
    foreach ($item in Get-ChildItem -LiteralPath $Directory -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Stop-PbzInstall 'LINKED_PATH' '安装目录包含链接，无法安全移动。请用原 MOD 管理器处理该目录。' $item.FullName
        }
        $item
        if ($item.PSIsContainer) { Get-PbzTreeItems $item.FullName }
    }
}

function Assert-PbzMoveReady([string] $Path) {
    if (!(Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    Assert-OrdinaryPath $item.FullName
    $items = if ($item.PSIsContainer) { @($item) + @(Get-PbzTreeItems $item.FullName) } else { @($item) }
    $denied = ''
    foreach ($entry in $items) {
        # DELETE access is checked without opening for write, renaming, or deleting.
        $native = Get-PbzPathAccess $entry.FullName 0x10000
        if ($native -in @(32,33)) {
            Stop-PbzInstall 'FILE_IN_USE' '演武文件被占用。请退出游戏和 MOD 管理器，关闭正在使用该目录的程序后重试。' $entry.FullName $native
        }
        # Renaming the directory needs access to its root, not DELETE on
        # each descendant. Descendant probes detect sharing violations.
        if ($native -eq 5 -and $entry.FullName -ieq $item.FullName) { $denied = $entry.FullName }
        if ($native -notin @(0,5)) {
            Stop-PbzInstall 'PATH_UNAVAILABLE' '文件在检查时发生变化或无法访问，请重新检查后重试。' $entry.FullName $native
        }
    }
    if ($denied) {
        Stop-PbzInstall 'ACCESS_DENIED' '当前账号没有移动该文件或目录的权限。请检查权限，或使用管理员权限重试。' $denied 5
    }
}

function Assert-PbzWriteReady([string] $Directory) {
    $parent = [IO.Path]::GetFullPath($Directory)
    while (!(Test-Path -LiteralPath $parent -PathType Container)) {
        if (Test-Path -LiteralPath $parent) {
            Stop-PbzInstall 'PATH_CONFLICT' "备份或安装目录被同名文件占用。请先将该文件移到其他目录，再重试。`n$parent" $parent
        }
        $parent = Split-Path -Parent $parent
        if (!$parent) { Stop-PbzInstall 'PATH_UNAVAILABLE' '无法访问安装目标所在的磁盘。' $Directory }
    }
    Assert-OrdinaryPath $parent
    # FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY
    $native = Get-PbzPathAccess $parent 6
    if ($native -eq 5) {
        Stop-PbzInstall 'ACCESS_DENIED' '当前账号无权写入安装或备份目录。可以使用管理员权限重试。' $parent $native
    }
    if ($native -ne 0) { Stop-PbzInstall 'PATH_UNAVAILABLE' '安装或备份目录暂时无法访问。' $parent $native }
}

function Get-PbzOtherDataRoots {
    if (!(Test-Path -LiteralPath $layout.ArenaDataRoot -PathType Container)) { return }
    Assert-OrdinaryPath $layout.ArenaDataRoot
    foreach ($directory in Get-ChildItem -LiteralPath $layout.ArenaDataRoot -Directory -Force) {
        if ($directory.Name -cnotmatch $layout.AccountPattern -or $directory.FullName -ieq $dataRoot) { continue }
        Assert-OrdinaryPath $directory.FullName
        $directory.FullName
    }
}

function Assert-PbzNoOtherInstallReceipt {
    # Runtime files are shared even by an account whose campaign save vanished.
    foreach ($directory in @(Get-PbzOtherDataRoots)) {
        $receipt = Join-Path $directory 'IntegratedMenu/InstallState.json'
        if (!(Test-Path -LiteralPath $receipt)) { continue }
        Assert-OrdinaryPath $receipt
        try { $candidate = Get-Content -LiteralPath $receipt -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch {
            Stop-PbzInstall 'ACCOUNT_CONFLICT' '同一个游戏目录中，另一账号的演武安装记录无法读取。请选回原安装账号，仍失败时导出诊断。' $receipt
        }
        if ($candidate.installed -and $candidate.gameExe -and [IO.Path]::GetFullPath($candidate.gameExe) -ieq $game) {
            Stop-PbzInstall 'ACCOUNT_CONFLICT' '这份游戏还有另一个标记为已安装的账号。请先核对原账号和对应安装记录。'
        }
    }
}

function Assert-PbzMissingRuntimeReceipt($Prior, [bool] $Shared) {
    if (!$Prior -or $Prior.installed -ne $true -or !(Test-Path -LiteralPath $statePath -PathType Leaf)) {
        Stop-PbzInstall 'RECEIPT_UNVERIFIED' '无法核对原账号的安装登记，请导出诊断。'
    }
    $marker = Join-Path $dataRoot '.PBZTestArenaData-owner'
    if (!(Test-Path -LiteralPath $marker -PathType Leaf)) {
        Stop-PbzInstall 'RECEIPT_UNVERIFIED' '演武账号数据缺少归属标记，请导出诊断。' $marker
    }
    Assert-OrdinaryPath $marker
    if ([IO.File]::ReadAllText($marker).Trim() -cne $owner -or !$Prior.profile -or
            [IO.Path]::GetFullPath($Prior.profile) -ine [IO.Path]::GetFullPath($profile)) {
        Stop-PbzInstall 'RECEIPT_UNVERIFIED' '演武目录的归属或账号档案位置与安装登记不符，请导出诊断。'
    }
    $prefix = 'ue4ss/Mods/PBZTestArena/'
    foreach ($name in @('Scripts/main.lua','Scripts/PBZSaveBarrier.dll','Scripts/IntegratedConfig.lua')) {
        if ($Prior.runtimeHashes.($prefix + $name) -cnotmatch '^[a-f0-9]{64}$') {
            Stop-PbzInstall 'RECEIPT_UNVERIFIED' '安装登记缺少可验证的演武文件指纹。'
        }
    }
    foreach ($entry in $Prior.runtimeHashes.PSObject.Properties) {
        if ($entry.Name -cnotmatch '^(?:dwmapi\.dll|ue4ss/(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+)$' -or
                $entry.Name -match '(?:^|/)\.{1,2}(?:/|$)' -or $entry.Value -cnotmatch '^[a-f0-9]{64}$' -or
                ($Shared -and !$entry.Name.StartsWith($prefix,[StringComparison]::Ordinal))) {
            Stop-PbzInstall 'RECEIPT_UNVERIFIED' '安装登记包含无效路径或不属于演武的文件。'
        }
    }
    Assert-PbzNoOtherInstallReceipt
}

function New-PbzPreflight([string] $State, [string] $Action, [string] $Message) {
    if ($layout.EntryRoot -ine $layout.InstallRoot) { $Message = '已识别游戏目录联接。' + $Message }
    return [pscustomobject]@{ state=$State; action=$Action; message=$Message;
        platform=$layout.Store; gameExe=$game; gameSha256=$actualGameHash; flow=$checkpointFlow; reuseLoader=[bool]$shared }
}

function Assert-PbzOtherTransactions {
    foreach ($directory in @(Get-PbzOtherDataRoots)) {
        if (Test-Path -LiteralPath (Join-Path $directory 'IntegratedMenu/InstallerPending.json')) {
            Stop-PbzInstall 'OTHER_ACCOUNT_RECOVERY' '这份游戏的另一个账号有未完成的安装操作。请先选择原账号恢复。'
        }
    }
}

function Assert-PbzInstallAccess([bool] $Shared, $Maps, $Bridges) {
    $script:pbzInstallerStage = 'permissions'
    $sampleRun = Join-Path $stateRoot 'Backups/20000101-000000-00000000'
    Assert-PbzPathLength ($sampleRun + '\Work\00000000000000000000000000000000.tmp')
    if (!$Uninstall) {
        $modPrefix = 'ue4ss/Mods/PBZTestArena/'
        foreach ($entry in $manifest.PSObject.Properties) {
            if ($Shared -and !$entry.Name.StartsWith($modPrefix)) { continue }
            Assert-PbzPathLength ($platform + '\' + $entry.Name)
            if ($Shared) { Assert-PbzPathLength ($sampleRun + '\Work\Mod\' + $entry.Name.Substring($modPrefix.Length)) }
            elseif ($entry.Name.StartsWith('ue4ss/')) {
                Assert-PbzPathLength ($sampleRun + '\Work\Runtime\' + $entry.Name.Substring(6))
            }
        }
    }
    Assert-PbzWriteReady (Join-Path $stateRoot 'Backups')
    if ($Shared) {
        Assert-PbzMoveReady $modDirectory
        if (!$Uninstall) {
            Assert-PbzWriteReady $platform
            Assert-PbzWriteReady (Split-Path -Parent $modDirectory)
        }
    } else {
        Assert-PbzMoveReady $active
        Assert-PbzMoveReady $proxy
        Assert-PbzWriteReady $platform
    }
    if ($Maps -and ($Maps.Before.Count -or $Maps.Next.Count)) {
        Assert-PbzWriteReady $Maps.Folder
        foreach ($name in $Maps.Before.Keys) { Assert-PbzMoveReady (Join-Path $Maps.Folder $name) }
    }
    if ($Bridges) {
        foreach ($bridge in $Bridges.Files.Values) {
            if ($bridge.Before -ceq $bridge.After) { continue }
            Assert-PbzMoveReady $bridge.Target
            if ($bridge.After) { Assert-PbzWriteReady (Split-Path -Parent $bridge.Target) }
        }
    }
}

function Test-PbzPreflightAccess([bool] $Shared, $Maps, $Bridges) {
    try {
        Assert-PbzInstallAccess $Shared $Maps $Bridges
        return ''
    } catch {
        $issue = Get-PbzInstallError $_
        if ($issue.code -ne 'ACCESS_DENIED') { throw }
        return ' 当前账号缺少写入权限。点击操作后，可按提示使用管理员权限。'
    }
}
