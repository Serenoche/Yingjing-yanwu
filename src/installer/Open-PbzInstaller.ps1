param(
    [ValidateSet('Install','Uninstall','Repair','Recover')][string] $Mode = 'Install',
    [string] $GameExe = '', [Alias('SteamAccount','EpicAccount')][string] $AccountId = '',
    [string] $UserSid = '', [switch] $RunAction, [string] $ExpectedGameExe = '', [switch] $KeepExistingLoader
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$script:pbzInstallerStage = 'startup'
$startupError = '安装器文件不完整。请重新下载 Windows 安装包，完整解压后打开安装器。'
try {
    . (Join-Path $PSScriptRoot 'PBZInstallHealth.ps1')
    Assert-PbzPackagePaths (Split-Path -Parent $PSScriptRoot)
    foreach ($dependency in @('PortablePaths.ps1','Export-PbzDiagnostics.ps1','Install-PbzIntegratedMenu.ps1')) {
        if (!(Test-Path -LiteralPath (Join-Path $PSScriptRoot $dependency) -PathType Leaf)) { throw $startupError }
    }
    foreach ($dependency in @('PortablePaths.ps1','Export-PbzDiagnostics.ps1')) {
        . (Join-Path $PSScriptRoot $dependency)
    }
} catch {
    if (Get-Command Format-PbzIssue -ErrorAction SilentlyContinue) { $startupError = Format-PbzIssue (Get-PbzInstallError $_) }
    [void][Windows.Forms.MessageBox]::Show($startupError,'影境演武',0,16)
    exit 1
}
if (!$UserSid) { $UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
$installer = Join-Path $PSScriptRoot 'Install-PbzIntegratedMenu.ps1'
$ps = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$nl = [Environment]::NewLine

function Invoke-Installer([string] $Action, [string] $Exe, [string] $Account, [string] $CheckedExe = '', [bool] $ReuseLoader = $false) {
    $arguments = @{GameExe=$Exe; AccountId=$Account; UserSid=$UserSid}
    if ($CheckedExe) { $arguments.ExpectedGameExe = $CheckedExe }
    if ($ReuseLoader) { $arguments.KeepExistingLoader = $true }
    $arguments[$Action] = $true
    try {
        $result = & $installer @arguments
        $script:pbzLastInstallerIssue = $null
        return $result
    } catch {
        $issue = Get-PbzInstallError $_
        $issue.GameExe = $Exe
        $issue.Action = $Action
        $script:pbzLastInstallerIssue = $issue
        throw
    }
}

function Show-PbzDiagnosticExport([string] $Exe, [string] $Account) {
    $result = Export-PbzDiagnostics -GameExe $Exe -AccountId $Account
    $message = if ($result.LogIncluded) { '已生成诊断包。' } else { '已生成诊断包。这个目录没有可读取的 UE4SS 日志。' }
    [void][Windows.Forms.MessageBox]::Show($message + $nl + $nl + $result.Path,'影境演武 · 诊断已导出',0,64)
    Invoke-Item -LiteralPath (Split-Path -Parent $result.Path) -ErrorAction SilentlyContinue
}

function Show-PbzDiagnosticFailure($Failure) {
    $issue = Get-PbzInstallError $Failure
    $issue.stage = 'diagnostics'
    [void][Windows.Forms.MessageBox]::Show((Format-PbzIssue $issue),'影境演武 · 导出失败',0,16)
}

function Show-PbzInstallResult([string] $Action) {
    $message = switch ($Action) {
        'Install' { '影境演武已安装并校验。请从平时使用的游戏平台启动游戏，在标题页进入「影境演武」。' }
        'Repair' { '演武文件已修复。请从原游戏平台启动，确认主菜单出现入口。' }
        'Uninstall' { '已卸载演武，玩家进度已保留。' }
        'Recover' { '恢复已完成。请重新检查安装。' }
    }
    [void][Windows.Forms.MessageBox]::Show($message,'影境演武',0,64)
}

function Start-PbzElevated([string] $Action, [string] $Exe, [string] $Account, [string] $CheckedExe = '', [bool] $ReuseLoader = $false) {
    $args = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$PSCommandPath,
        '-RunAction','-Mode',$Action,'-GameExe',$Exe,'-AccountId',$Account,'-UserSid',$UserSid)
    if ($CheckedExe) { $args += @('-ExpectedGameExe',$CheckedExe) }
    if ($ReuseLoader) { $args += '-KeepExistingLoader' }
    $quoted = foreach ($argument in $args) {
        if ($argument -match '["\x00-\x1f]' -or $argument.EndsWith('\')) { throw '安装参数包含无效字符。' }
        '"' + $argument + '"'
    }
    Start-Process -FilePath $ps -ArgumentList ($quoted -join ' ') -Verb RunAs -WindowStyle Hidden | Out-Null
}

if ($RunAction) {
    try {
        Invoke-Installer $Mode $GameExe $AccountId $ExpectedGameExe ([bool]$KeepExistingLoader) | Out-Null
        Show-PbzInstallResult $Mode
    } catch {
        $issue = $script:pbzLastInstallerIssue
        if (!$issue) { $issue = Get-PbzInstallError $_ }
        if ([Windows.Forms.MessageBox]::Show((Format-PbzIssue $issue -ShowRollback) + $nl + $nl + '要导出本次诊断吗？',
                '影境演武 · 操作未完成',4,16) -eq 'Yes') {
            try { Show-PbzDiagnosticExport $GameExe $AccountId }
            catch { Show-PbzDiagnosticFailure $_ }
        }
        exit 1
    }
    exit 0
}

[Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object Windows.Forms.Form
$form.Text = '影境演武 · 安装与修复'
$form.ClientSize = New-Object Drawing.Size(814,411)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$label = New-Object Windows.Forms.Label
$label.Text = '游戏位置与平台（Steam / Epic）'
$label.Location = New-Object Drawing.Point(24,24)
$label.AutoSize = $true
$games = New-Object Windows.Forms.ComboBox
$games.Location = New-Object Drawing.Point(24,49)
$games.Size = New-Object Drawing.Size(638,30)
$games.DropDownStyle = 'DropDownList'
$accountLabel = New-Object Windows.Forms.Label
$accountLabel.Text = '存档账号（有多个账号时请选择本次使用的账号）'
$accountLabel.Location = New-Object Drawing.Point(24,98)
$accountLabel.AutoSize = $true
$accounts = New-Object Windows.Forms.ComboBox
$accounts.Location = New-Object Drawing.Point(24,124)
$accounts.Size = New-Object Drawing.Size(765,30)
$accounts.DropDownStyle = 'DropDownList'
$accounts.DisplayMember = 'Label'
$status = New-Object Windows.Forms.Label
$status.Location = New-Object Drawing.Point(24,184)
$status.Size = New-Object Drawing.Size(765,115)
$form.Controls.AddRange(@($label,$games,$accountLabel,$accounts,$status))

function New-PbzButton([string] $Label, [int] $X, [int] $Y, [int] $Width, [int] $Height) {
    $button = New-Object Windows.Forms.Button
    $button.Text = $Label
    $button.Location = New-Object Drawing.Point($X,$Y)
    $button.Size = New-Object Drawing.Size($Width,$Height)
    $form.Controls.Add($button)
    return $button
}
$browse = New-PbzButton '选择目录…' 672 48 117 28
$checkButton = New-PbzButton '检查安装' 24 320 155 42
$installButton = New-PbzButton '安装 / 更新' 190 320 190 42
$uninstallButton = New-PbzButton '卸载（保留进度）' 391 320 219 42
$diagnosticsButton = New-PbzButton '导出诊断' 621 320 168 42

function Set-PbzPlan($Plan) {
    $script:pbzPlan = $Plan
    $hasAccount = [bool]($games.SelectedItem -and $accounts.SelectedItem)
    $checkButton.Enabled = [bool]$games.SelectedItem
    $diagnosticsButton.Enabled = [bool]$games.SelectedItem
    $installButton.Enabled = $hasAccount -and [bool]$Plan
    $uninstallButton.Enabled = $hasAccount -and $Plan.action -ne 'Recover'
    $installButton.Text = switch ($Plan.action) {
        'Repair' { '修复安装' }
        'Recover' { '恢复上次操作' }
        default { if ($Plan.reuseLoader) { '仅覆盖演武 MOD' } else { '安装 / 更新' } }
    }
    $uninstallButton.Text = if ($Plan.state -eq 'runtime_missing') { '清理残留（保留进度）' } else { '卸载（保留进度）' }
}

function Show-PbzPendingRecoveryPlan {
    Set-PbzPlan $null
    if (!$games.SelectedItem -or !$accounts.SelectedItem) { return }
    try {
        $pending = Join-Path $accounts.SelectedItem.DataRoot 'IntegratedMenu/InstallerPending.json'
        if (!(Test-Path -LiteralPath $pending -PathType Leaf)) { return }
        $plan = Invoke-Installer 'Preflight' ([string]$games.SelectedItem) ([string]$accounts.SelectedItem.Account)
        Set-PbzPlan $plan
        $status.Text = $plan.message
    } catch {
        $issue = if ($script:pbzLastInstallerIssue) { $script:pbzLastInstallerIssue } else { Get-PbzInstallError $_ }
        $status.Text = Format-PbzIssue $issue
    }
}

$accounts.add_SelectedIndexChanged({
    if ($accounts.SelectedItem) { $status.Text = '请先退出游戏，等云存档同步完成，再点击「检查安装」。' }
    Show-PbzPendingRecoveryPlan
})
$games.add_SelectedIndexChanged({
    $accounts.Items.Clear()
    $gamesPath = [string]$games.SelectedItem
    if ($gamesPath) {
        try {
            $layout = Resolve-PbzGameLayout $gamesPath
            $label.Text = '游戏位置（' + $layout.Store + '）'
            foreach ($account in @(Get-PbzSaveAccounts -Layout $layout)) {
                $account | Add-Member -NotePropertyName Label -NotePropertyValue ($account.Account + '  |  ' + $account.Modified.ToString('yyyy-MM-dd HH:mm'))
                [void]$accounts.Items.Add($account)
            }
        } catch {
            Set-PbzPlan $null
            $issue = Get-PbzInstallError $_
            if (!$issue.stage -or $issue.stage -eq 'startup') { $issue.stage = 'selection' }
            $status.Text = Format-PbzIssue $issue
            return
        }
        if ($accounts.Items.Count -eq 1) { $accounts.SelectedIndex=0 }
        if (!(Test-Path -LiteralPath $gamesPath -PathType Leaf)) {
            $status.Text = '这个游戏目录缺少 PBZ.exe。请从游戏平台核对安装位置并验证游戏文件，也可直接导出诊断。'
        } elseif (!$accounts.Items.Count) { $status.Text = '没有找到存档。请在游戏内保存一次并退出，或导出诊断。' }
        elseif ($accounts.Items.Count -gt 1) { $status.Text = '请选择本次使用的存档账号，再检查安装。' }
    }
    Show-PbzPendingRecoveryPlan
})
$browse.add_Click({
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description = '选择影之刃零游戏根目录，或 platform 下对应平台的目录。'
    $dialog.ShowNewFolderButton = $false
    try {
        if ($dialog.ShowDialog() -ne 'OK') { return }
        $choices = @(Get-PbzGameLayoutsAtRoot $dialog.SelectedPath)
        if (!$choices.Count) {
            Stop-PbzInstall 'GAME_FOLDER_REQUIRED' '没找到 Steam 或 Epic 游戏目录。请在游戏平台中打开「浏览本地文件」，再选择打开的目录。'
        }
        foreach ($choice in $choices) {
            if (!$games.Items.Contains($choice.EntryGameExe)) { [void]$games.Items.Add($choice.EntryGameExe) }
        }
        if ($choices.Count -eq 1) { $games.SelectedItem = $choices[0].EntryGameExe }
        else { $games.SelectedIndex = -1; $status.Text = '找到多个平台目录，请选择平时使用的游戏。' }
    } catch { [void][Windows.Forms.MessageBox]::Show((Format-PbzIssue (Get-PbzInstallError $_)),'影境演武',0,48) }
    finally { $dialog.Dispose() }
})

$checkButton.add_Click({
    if (!$games.SelectedItem) { return }
    Set-PbzPlan $null
    $status.Text = '正在检查安装包、游戏版本和安装登记…'
    $form.Refresh()
    try {
        $plan = Invoke-Installer 'Preflight' ([string]$games.SelectedItem) ([string]$accounts.SelectedItem.Account)
        Set-PbzPlan $plan
        $status.Text = $plan.message
    } catch {
        $status.Text = Format-PbzIssue $script:pbzLastInstallerIssue
    }
})

$perform = {
    param([string] $Action)
    if (!$games.SelectedItem -or !$accounts.SelectedItem -or !$Action) { return }
    $exe = [string]$games.SelectedItem
    $account = [string]$accounts.SelectedItem.Account
    $installButton.Enabled=$false; $uninstallButton.Enabled=$false
    $status.Text = '正在备份、校验并处理文件，请稍候…'
    $form.Refresh()
    $planAfter = $script:pbzPlan
    try {
        Invoke-Installer $Action $exe $account $planAfter.gameExe ([bool]$planAfter.reuseLoader) | Out-Null
        Show-PbzInstallResult $Action
        $status.Text = '操作完成。数据与备份可在游戏的 ProjectPBZ/Saved/PBZTestArena 下查看。'
        $planAfter = $null
    } catch {
        $issue = $script:pbzLastInstallerIssue
        if (!$issue) { $issue = Get-PbzInstallError $_ }
        $status.Text = Format-PbzIssue $issue -ShowRollback
        if ($issue.rollback -eq 'needs_recovery' -or $issue.code -eq 'RECOVERY_PENDING') {
            $planAfter = [pscustomobject]@{action='Recover';state='recovery_pending';gameExe=$planAfter.gameExe}
        }
        if ($issue.code -eq 'ACCESS_DENIED' -and !$isAdmin -and ($issue.rollback -ne 'needs_recovery' -or $Action -eq 'Recover')) {
            if ([Windows.Forms.MessageBox]::Show($status.Text + $nl + $nl + '使用管理员权限重试同一操作？',
                    '影境演武 · 写入权限不足',4,48) -eq 'Yes') {
                try { Start-PbzElevated $Action $exe $account $planAfter.gameExe ([bool]$planAfter.reuseLoader); $form.Close() }
                catch { $status.Text = '管理员权限申请未通过。可重新点击操作并同意授权，或将游戏移到可写的游戏库后重试。' }
            }
        } else {
            [void][Windows.Forms.MessageBox]::Show($status.Text,'影境演武 · 操作未完成',0,48)
        }
    } finally {
        Set-PbzPlan $planAfter
        if ($Action -eq 'Uninstall' -and $script:pbzLastInstallerIssue.code -eq 'FILE_IN_USE') {
            $uninstallButton.Text = '重试卸载（保留进度）'
        }
    }
}
$installButton.add_Click({ & $perform $script:pbzPlan.action })
$uninstallButton.add_Click({ & $perform 'Uninstall' })
$diagnosticsButton.add_Click({
    if (!$games.SelectedItem) { return }
    try { Show-PbzDiagnosticExport ([string]$games.SelectedItem) ([string]$accounts.SelectedItem.Account) }
    catch { Show-PbzDiagnosticFailure $_ }
})

$script:pbzInstallerStage = 'selection'
$status.Text = '正在查找 Steam 和 Epic 游戏库…'
try {
    foreach ($candidate in @(Get-PbzGameCandidates)) { [void]$games.Items.Add($candidate.EntryGameExe) }
    if ($GameExe) {
        $selected = Resolve-PbzGameLayout $GameExe
        if (!$games.Items.Contains($selected.EntryGameExe)) { [void]$games.Items.Add($selected.EntryGameExe) }
        $games.SelectedItem=$selected.EntryGameExe
    } elseif ($games.Items.Count -eq 1) { $games.SelectedIndex=0 }
    else { $status.Text = '请选择游戏位置，或点击「选择目录」。' }
} catch { $status.Text = Format-PbzIssue (Get-PbzInstallError $_) }
if ($AccountId) {
    for ($i=0; $i -lt $accounts.Items.Count; $i++) {
        if ($accounts.Items[$i].Account -ieq $AccountId) { $accounts.SelectedIndex=$i; break }
    }
}
Show-PbzPendingRecoveryPlan
$form.AcceptButton = if ($script:pbzPlan.action -eq 'Recover') { $installButton }
    elseif ($Mode -eq 'Uninstall') { $uninstallButton } else { $checkButton }
[void]$form.ShowDialog()
