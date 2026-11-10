param(
    [ValidateSet('Install','Uninstall')][string] $Mode = 'Install',
    [string] $GameExe = '', [string] $SteamAccount = '', [string] $UserSid = '', [switch] $RunAction
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'PortablePaths.ps1')
if (!$UserSid) { $UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
$installer = Join-Path $PSScriptRoot 'Install-PbzIntegratedMenu.ps1'
$ps = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
function Quote-Argument([string] $Value) {
    if ($Value -match '["\x00-\x1f]' -or $Value.EndsWith('\')) { throw 'Invalid installer argument.' }
    return '"' + $Value + '"'
}
function Invoke-SelectedOperation([string] $Action, [string] $Exe, [string] $Account) {
    $arguments = @{ GameExe=$Exe;SteamAccount=$Account;UserSid=$UserSid }
    $arguments[$Action]=$true
    $message = (& $installer @arguments | Out-String)
    [Windows.Forms.MessageBox]::Show("操作完成。`r`n请从 Steam 正常启动游戏。`r`n`r`n" + $message,'影境演武',0,64) | Out-Null
}
function Assert-NoLink([string] $Directory) {
    $item=Get-Item -LiteralPath $Directory -Force
    while ($item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '不支持链接或重解析点目录。' }
        $item=$item.Parent
    }
}
function Test-NeedElevation($Layout,$Account) {
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return $false }
    foreach ($directory in @($Layout.Platform,(Split-Path -Parent $Account.SavePath),(Join-Path $Layout.InstallRoot 'ProjectPBZ/Saved'))) {
        Assert-NoLink $directory
        $probe=Join-Path $directory ('.PBZIntegrated-permission-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        try {
            $stream=[IO.File]::Open($probe,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            $stream.Dispose();Remove-Item -LiteralPath $probe
        } catch { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -ErrorAction SilentlyContinue };return $true }
    }
    if (Test-Path -LiteralPath $Account.DataRoot) {
        Assert-NoLink $Account.DataRoot
        $acl=[IO.Directory]::GetAccessControl($Account.DataRoot)
        $sid=New-Object Security.Principal.SecurityIdentifier($UserSid)
        $rights=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | Where-Object {
            $_.IdentityReference -eq $sid -and $_.AccessControlType -eq 'Allow' -and
            ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Modify) -eq [Security.AccessControl.FileSystemRights]::Modify })
        if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $UserSid -and !$rights.Count) { return $true }
    }
    return $false
}
if ($RunAction) {
    try { Invoke-SelectedOperation $Mode $GameExe $SteamAccount }
    catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'影境演武：操作未完成',0,16) | Out-Null;exit 1 }
    exit
}
[Windows.Forms.Application]::EnableVisualStyles()
$form=New-Object Windows.Forms.Form
$form.Text='影境演武 · 安装与卸载';$form.ClientSize=New-Object Drawing.Size(760,425)
$form.StartPosition='CenterScreen';$form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false
$label=New-Object Windows.Forms.Label;$label.Text='游戏位置（platform/steam/PBZ.exe）';$label.Location=New-Object Drawing.Point(24,24);$label.AutoSize=$true;$form.Controls.Add($label)
$games=New-Object Windows.Forms.ComboBox;$games.Location=New-Object Drawing.Point(24,50);$games.Size=New-Object Drawing.Size(615,30);$games.DropDownStyle='DropDownList';$form.Controls.Add($games)
$browse=New-Object Windows.Forms.Button;$browse.Text='选择文件…';$browse.Location=New-Object Drawing.Point(650,49);$browse.Size=New-Object Drawing.Size(87,28);$form.Controls.Add($browse)
$accountLabel=New-Object Windows.Forms.Label;$accountLabel.Text='存档账号（多个账号时，请明确选择）';$accountLabel.Location=New-Object Drawing.Point(24,100);$accountLabel.AutoSize=$true;$form.Controls.Add($accountLabel)
$accounts=New-Object Windows.Forms.ComboBox;$accounts.Location=New-Object Drawing.Point(24,127);$accounts.Size=New-Object Drawing.Size(713,30);$accounts.DropDownStyle='DropDownList';$accounts.DisplayMember='Label';$form.Controls.Add($accounts)
$note=New-Object Windows.Forms.Label;$note.Location=New-Object Drawing.Point(24,180);$note.Size=New-Object Drawing.Size(710,112)
$baseNoteText="先退出游戏。已有 UE4SS 则沿用；没有时才安装，保留其他 MOD 与设置。`r`n安装时自动备份存档，保留原进度、战报与配装记忆。`r`n本轮直接尝试兼容，不按版本号拦截；进入演武时核对实际接口，不匹配再反馈处理。"
$note.Text=$baseNoteText;$form.Controls.Add($note)
$installButton=New-Object Windows.Forms.Button;$installButton.Text='安装 / 更新';$installButton.Location=New-Object Drawing.Point(160,325);$installButton.Size=New-Object Drawing.Size(195,42);$form.Controls.Add($installButton)
$uninstallButton=New-Object Windows.Forms.Button;$uninstallButton.Text='卸载（保留进度）';$uninstallButton.Location=New-Object Drawing.Point(385,325);$uninstallButton.Size=New-Object Drawing.Size(215,42);$form.Controls.Add($uninstallButton)
$status=New-Object Windows.Forms.Label;$status.Location=New-Object Drawing.Point(24,387);$status.Size=New-Object Drawing.Size(710,25);$status.Text='正在查找 Steam 游戏库…';$form.Controls.Add($status)
$games.add_SelectedIndexChanged({
    $accounts.Items.Clear()
    $note.Text=$baseNoteText
    if ($games.SelectedItem) {
        if (([string]$games.SelectedItem) -match '[^\x00-\x7f]') {
            $note.Text += "`r`n安装器支持中文路径；游戏内 Lua 对中文游戏目录尚待实测，建议使用当前已验证的英文目录。"
        }
        foreach ($account in @(Get-PbzSaveAccounts ([string]$games.SelectedItem))) {
            $account | Add-Member -NotePropertyName Label -NotePropertyValue ($account.Account + '  |  ' + $account.Modified.ToString('yyyy-MM-dd HH:mm'))
            [void]$accounts.Items.Add($account)
        }
        if ($accounts.Items.Count -eq 1) { $accounts.SelectedIndex=0 } else { $accounts.SelectedIndex=-1 }
        $status.Text=if ($accounts.Items.Count) { '请选择账号，再点击安装或卸载。' } else { '未找到存档。请先正常进入游戏并创建存档后再安装。' }
    }
})
$browse.add_Click({
    $dialog=New-Object Windows.Forms.OpenFileDialog;$dialog.Filter='PBZ.exe|PBZ.exe';$dialog.Title='选择 platform/steam/PBZ.exe'
    if ($dialog.ShowDialog() -eq 'OK') {
        try {
            $layout=Resolve-PbzGameLayout $dialog.FileName
            if (!$games.Items.Contains($layout.GameExe)) { [void]$games.Items.Add($layout.GameExe) }
            $games.SelectedItem=$layout.GameExe
        } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'请选择正确的游戏文件',0,48) | Out-Null }
    }
})
$perform={param([string]$Action)
    if (!$games.SelectedItem -or !$accounts.SelectedItem) { [Windows.Forms.MessageBox]::Show('请选择游戏位置和存档账号。','影境演武',0,48) | Out-Null;return }
    try {
        if (Get-Process -Name 'PBZ','ProjectPBZ-Win64-Shipping' -ErrorAction SilentlyContinue) { throw '请先退出游戏。' }
        $layout=Resolve-PbzGameLayout ([string]$games.SelectedItem);$account=$accounts.SelectedItem
        if (Test-NeedElevation $layout $account) {
            $args=@('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-RunAction','-Mode',$Action,'-GameExe',$layout.GameExe,'-SteamAccount',$account.Account,'-UserSid',$UserSid)
            $quoted=@($args | ForEach-Object { Quote-Argument $_ }) -join ' '
            Start-Process -FilePath $ps -ArgumentList $quoted -Verb RunAs -WindowStyle Hidden | Out-Null
            $form.Close();return
        }
        $installButton.Enabled=$false;$uninstallButton.Enabled=$false;$status.Text='正在备份、校验并处理文件，请稍候…';$form.Refresh()
        Invoke-SelectedOperation $Action $layout.GameExe $account.Account
        $status.Text='操作完成。数据与备份位于游戏 ProjectPBZ/Saved/PBZTestArena 下。'
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'影境演武：操作未完成',0,16) | Out-Null;$status.Text='未完成。请查看错误说明；原有备份会保留。' }
    finally { $installButton.Enabled=$true;$uninstallButton.Enabled=$true }
}
$installButton.add_Click({ & $perform 'Install' });$uninstallButton.add_Click({ & $perform 'Uninstall' })
foreach ($candidate in @(Get-PbzGameCandidates)) { [void]$games.Items.Add($candidate.GameExe) }
if ($GameExe) { $layout=Resolve-PbzGameLayout $GameExe;if (!$games.Items.Contains($layout.GameExe)) { [void]$games.Items.Add($layout.GameExe) };$games.SelectedItem=$layout.GameExe }
elseif ($games.Items.Count -eq 1) { $games.SelectedIndex=0 }
else { $games.SelectedIndex=-1;$status.Text='请选择游戏位置，或点击“选择文件”。' }
if ($SteamAccount) { for ($i=0;$i-lt$accounts.Items.Count;$i++) { if ($accounts.Items[$i].Account-ceq$SteamAccount) { $accounts.SelectedIndex=$i } } }
if ($Mode-eq'Uninstall') { $form.AcceptButton=$uninstallButton } else { $form.AcceptButton=$installButton }
[void]$form.ShowDialog()
