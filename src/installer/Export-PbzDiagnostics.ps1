# Read-only collection from the selected PBZ installation.
$script:pbzDiagnosticPackage = Split-Path -Parent $PSScriptRoot

function Get-PbzDiagnosticItem([string] $Path) {
    $file = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (!$file) { return }
    $part = $file
    while ($part) {
        if ($part.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
        $part = if ($part.PSIsContainer) { $part.Parent } else { $part.Directory }
    }
    return $file
}

function Get-PbzDiagnosticFile([string] $Path) {
    $item = Get-PbzDiagnosticItem $Path
    if ($item -and !$item.PSIsContainer) { return $item }
}

function Protect-PbzDiagnosticText([string] $Text, [string] $InstallRoot, [string] $EntryRoot = '') {
    foreach ($entry in @(@{ Path=$EntryRoot; Label='<game>' }, @{ Path=$InstallRoot; Label='<game>' },
            @{ Path=$script:pbzDiagnosticPackage; Label='<installer>' },
            @{ Path=[Environment]::GetFolderPath('UserProfile'); Label='<user>' })) {
        if (!$entry.Path) { continue }
        $windows = $entry.Path.Replace('/','\')
        foreach ($variant in @($windows,$windows.Replace('\','/'),$windows.Replace('\','\\'))) {
            $Text = [regex]::Replace($Text,[regex]::Escape($variant),$entry.Label,'IgnoreCase')
        }
    }
    $Text = $Text -replace '(?i)([A-Z]:[\\/]+(?:Users|Documents and Settings)[\\/]+)[^\\/\r\n"''<>|]+','$1<user>'
    $Text = $Text -replace '(?i)(?<![a-f0-9])(?:[0-9]{17}|[a-f0-9]{32})(?![a-f0-9])','<id>'
    $Text = $Text -replace 'S-1-(?:5-21|12-1)(?:-\d+){4}','<sid>'
    $Text = $Text -replace '(?i)(\b(?:providerPathHex|AUTH_PASSWORD|AUTH_LOGIN|AUTH_TOKEN|access_token|refresh_token|exchange_code)\s*[:=]\s*)(?:"[^"\r\n]*"|''[^''\r\n]*''|[^\s;,]+)','$1<redacted>'
    return $Text
}

function Read-PbzDiagnosticLog($Layout) {
    $paths = @('ue4ss/UE4SS.log','UE4SS.log')
    $file = $null
    foreach ($relative in $paths) {
        $file = Get-PbzDiagnosticFile (Join-Path $Layout.Platform $relative)
        if ($file) { break }
    }
    if (!$file) { return [pscustomobject]@{ status='missing' } }
    $result = [ordered]@{ status='unavailable'; relativePath=$relative; modifiedUtc=$file.LastWriteTimeUtc.ToString('o');
        sessionStarted=$null; truncated=$false; text=$null }
    try {
        $sharing = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,$sharing)
        try {
            $length = $stream.Length
            # Bound memory use for long sessions while retaining the newest log lines.
            $count = [int][Math]::Min($length,16MB)
            $result.truncated = $length -gt $count
            $stream.Position = $length - $count
            $buffer = New-Object byte[] $count
            $read = 0
            while ($read -lt $count) {
                $chunk = $stream.Read($buffer,$read,$count-$read)
                if (!$chunk) { break }
                $read += $chunk
            }
            $logText = [Text.Encoding]::UTF8.GetString($buffer,0,$read).TrimStart([char]0xfeff)
        } finally { $stream.Dispose() }
    } catch { return [pscustomobject]$result }
    if (!$logText.Trim() -or $logText.Contains([string][char]0)) { return [pscustomobject]$result }
    if ($result.truncated) {
        $newline = $logText.IndexOf("`n")
        if ($newline -ge 0) { $logText = $logText.Substring($newline+1) }
    }
    $headers = [regex]::Matches($logText,'(?m)^(?:\[[^\]\r\n]+\][ \t]+Console created\r?\n)?\[(?<time>\d{4}-\d{2}-\d{2} [^\]\r\n]+)\][ \t]+UE4SS - v[^\r\n]*')
    if ($headers.Count) {
        $header = $headers[$headers.Count-1]
        $logText = $logText.Substring($header.Index)
        $result.sessionStarted = $header.Groups['time'].Value
        $result.truncated = $false
    }
    $result.status = 'included'
    $result.text = $logText
    return [pscustomobject]$result
}

function Get-PbzDiagnosticMod($Mods, [string] $Name) {
    $Name = $Name.Trim()
    if (!$Name -or $Name.Length -gt 240 -or $Name -match '[\\/:\x00-\x1f]') { return }
    if (!$Mods.ContainsKey($Name)) {
        $Mods[$Name] = [pscustomobject][ordered]@{ name=$Name; modsTxt=$null; modsJson=$null; enabledTxt=$false }
    }
    return $Mods[$Name]
}

function Get-PbzDiagnosticModConfig([string] $ModsRoot) {
    $mods = @{}
    $issues = @()
    $txt = Get-PbzDiagnosticFile (Join-Path $ModsRoot 'mods.txt')
    if ($txt) {
        try {
            if ($txt.Length -gt 2MB) { throw 'oversized config' }
            foreach ($line in [IO.File]::ReadLines($txt.FullName)) {
                if ($line -match '^\s*([^;#:\r\n]+?)\s*:\s*([01])\s*(?:[;#].*)?$') {
                    $enabled = $Matches[2] -eq '1'
                    $mod = Get-PbzDiagnosticMod $mods $Matches[1]
                    if ($mod) { $mod.modsTxt = $enabled }
                }
            }
        } catch { $issues += 'mods.txt unreadable' }
    }
    $json = Get-PbzDiagnosticFile (Join-Path $ModsRoot 'mods.json')
    if ($json) {
        try {
            if ($json.Length -gt 2MB) { throw 'oversized config' }
            $entries = [IO.File]::ReadAllText($json.FullName) | ConvertFrom-Json
            foreach ($entry in @($entries)) {
                if ($entry.mod_name -is [string] -and $entry.mod_enabled -is [bool]) {
                    $mod = Get-PbzDiagnosticMod $mods $entry.mod_name
                    if ($mod) { $mod.modsJson = $entry.mod_enabled }
                }
            }
        } catch { $issues += 'mods.json unreadable' }
    }
    if (Test-Path -LiteralPath $ModsRoot -PathType Container) {
        foreach ($directory in @(Get-ChildItem -LiteralPath $ModsRoot -Directory -ErrorAction SilentlyContinue)) {
            if (Get-PbzDiagnosticFile (Join-Path $directory.FullName 'enabled.txt')) {
                $mod = Get-PbzDiagnosticMod $mods $directory.Name
                if ($mod) { $mod.enabledTxt = $true }
            }
        }
    }
    return [pscustomobject]@{ mods=@($mods.Values | Where-Object { $_.modsTxt -or $_.modsJson -or $_.enabledTxt } |
        Sort-Object name); issues=$issues }
}

function Add-PbzDiagnosticZipText($Archive,[string] $Name,[string] $Text) {
    $entry = $Archive.CreateEntry($Name)
    $writer = [IO.StreamWriter]::new($entry.Open(),[Text.UTF8Encoding]::new($Name.EndsWith('.txt')))
    try { $writer.Write($Text) } finally { $writer.Dispose() }
}

function Read-PbzDiagnosticTail([string] $Path, [int] $Limit, [string] $InstallRoot, [string] $EntryRoot) {
    $file = Get-PbzDiagnosticFile $Path
    if (!$file) { return }
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,$share)
        try {
            $count = [int][Math]::Min($stream.Length,$Limit)
            $stream.Position = $stream.Length - $count
            $reader = [IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true,4096,$true)
            try {
                if ($stream.Position -gt 0) { [void]$reader.ReadLine() }
                $chars = New-Object char[] $count
                $read = $reader.ReadBlock($chars,0,$count)
                $text = [string]::new($chars,0,$read)
            } finally { $reader.Dispose() }
        } finally { $stream.Dispose() }
        if ($text -and !$text.Contains([string][char]0)) { return (Protect-PbzDiagnosticText $text $InstallRoot $EntryRoot) }
    } catch { return }
}

function Get-PbzLatestCrash($Layout) {
    $root = Join-Path $Layout.InstallRoot 'ProjectPBZ/Saved/Crashes'
    if (!(Get-PbzDiagnosticItem $root)) { return }
    $folders = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { !($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 3)
    foreach ($folder in $folders) {
        if ($folder.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-2)) { continue }
        $path = Join-Path $folder.FullName 'CrashContext.runtime-xml'
        $file = Get-PbzDiagnosticFile $path
        if (!$file -or $file.Length -gt 2MB) { continue }
        try {
            $readerSettings = [Xml.XmlReaderSettings]::new()
            $readerSettings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
            $readerSettings.XmlResolver = $null
            $reader = [Xml.XmlReader]::Create($file.FullName,$readerSettings)
            $xml = [Xml.XmlDocument]::new()
            $xml.XmlResolver = $null
            try { $xml.Load($reader) } finally { $reader.Dispose() }
            $report = [ordered]@{ modifiedUtc=$file.LastWriteTimeUtc.ToString('o') }
            foreach ($name in @('ErrorMessage','CrashType','EngineVersion','BuildVersion','IsAssert','IsEnsure','IsGPUCrash','CallStack','PCallStack')) {
                $node = $xml.SelectSingleNode('/FGenericCrashContext/RuntimeProperties/' + $name)
                if ($node -and $node.InnerText) {
                    $value = $node.InnerText.Substring(0,[Math]::Min($node.InnerText.Length,32768))
                    $report[$name] = Protect-PbzDiagnosticText $value $Layout.InstallRoot $Layout.EntryRoot
                }
            }
            return ($report | ConvertTo-Json -Depth 4)
        } catch { continue }
    }
}

function Get-PbzDiagnosticPackages([string] $InstallRoot) {
    foreach ($name in @('~mods','LogicMods')) {
        $path = Join-Path $InstallRoot ('ProjectPBZ/Content/Paks/' + $name)
        $root = Get-PbzDiagnosticItem $path
        if (!$root -or !$root.PSIsContainer) { continue }
        $folders = [Collections.Generic.Queue[IO.DirectoryInfo]]::new()
        $packages = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $folders.Enqueue($root)
        while ($folders.Count) {
            $folder = $folders.Dequeue()
            foreach ($item in @(Get-ChildItem -LiteralPath $folder.FullName -ErrorAction SilentlyContinue)) {
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                if ($item.PSIsContainer) { $folders.Enqueue($item) }
                elseif ($item.Extension -in @('.pak','.utoc')) {
                    $relative = $item.FullName.Substring($root.FullName.Length+1).Replace('\','/')
                    [void]$packages.Add($relative.Substring(0,$relative.Length-$item.Extension.Length))
                }
            }
        }
        foreach ($package in ($packages | Sort-Object)) {
            [pscustomobject]@{ directory=$name; name=(Protect-PbzDiagnosticText $package $InstallRoot) }
        }
    }
}

function Get-PbzDiagnosticHash([string] $Path) {
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try { return [BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-','').ToLowerInvariant() }
        finally { $sha256.Dispose() }
    } finally { $stream.Dispose() }
}

function Get-PbzDiagnosticPresence([string] $Path, [switch] $Directory) {
    $item = Get-PbzDiagnosticItem $Path
    if (!$item) {
        $status = if (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue) { 'unavailable' } else { 'missing' }
        return @{ status=$status }
    }
    if ([bool]$item.PSIsContainer -ne [bool]$Directory) { return @{ status='wrong_type' } }
    $info = @{ status='present' }
    if (!$Directory) {
        try { $info.sha256 = Get-PbzDiagnosticHash $item.FullName }
        catch { $info.status = 'unreadable' }
    }
    return $info
}

function Get-PbzDiagnosticJson([string] $Path) {
    $file = Get-PbzDiagnosticFile $Path
    if (!$file -or $file.Length -gt 1MB) { return }
    try { Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { return }
}

function Get-PbzDiagnosticReceipt($Layout, [string] $AccountId) {
    $arena = Get-PbzDiagnosticItem $Layout.ArenaDataRoot
    if (!$arena -or !$arena.PSIsContainer) { return }
    $accounts = @(Get-ChildItem -LiteralPath $arena.FullName -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -cmatch $Layout.AccountPattern -and (!$AccountId -or $_.Name -ieq $AccountId) } |
        Select-Object -First 32)
    foreach ($account in $accounts) {
        $stateRoot = Join-Path $account.FullName 'IntegratedMenu'
        if (!(Get-PbzDiagnosticItem $stateRoot)) { continue }
        $receiptPath = Join-Path $stateRoot 'InstallState.json'
        $receipt = Get-PbzDiagnosticJson $receiptPath
        $pending = Get-PbzDiagnosticJson (Join-Path $stateRoot 'InstallerPending.json')
        $summary = [ordered]@{
            receiptPresent=[bool](Get-PbzDiagnosticFile $receiptPath)
            receiptReadable=[bool]$receipt
            ownerMatches=($receipt.owner -ceq '7d5ad307-d21c-47eb-9584-493443190984')
            installed=($receipt.installed -eq $true)
            schema=$(if ($receipt.version -in @(1,2,3)) { [int]$receipt.version })
            installKind=$(if ($receipt.installKind -ceq 'shared-v1') { 'shared-v1' } elseif ($receipt) { 'bundled' })
            mapFlow=$(if ($receipt.mapFlow -cin @('native-checkpoint','compatibility')) { $receipt.mapFlow })
            gameMatches=($receipt.gameExe -ieq $Layout.GameExe)
            saveMatches=($receipt.savePath -ieq (Join-Path $Layout.SaveRoot ($account.Name + '/PBZSaveGame.sav')))
            privateReceiptPresent=[bool](Get-PbzDiagnosticFile (Join-Path $stateRoot 'PrivateSlots.json'))
            recoveryPending=[bool](Get-PbzDiagnosticFile (Join-Path $stateRoot 'InstallerPending.json'))
            recoveryStepCount=$(if ($pending) { @($pending.steps).Count })
        }
        $history = Get-PbzDiagnosticItem (Join-Path $stateRoot 'Backups')
        if ($history -and $history.PSIsContainer) {
            $latest = Get-ChildItem -LiteralPath $history.FullName -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -cmatch '^\d{8}-\d{6}-[a-f0-9]{8}$' } | Sort-Object Name -Descending | Select-Object -First 1
            if ($latest) {
                $failure = Get-PbzDiagnosticJson (Join-Path $latest.FullName 'Failure.json')
                $rolledBack = Get-PbzDiagnosticJson (Join-Path $latest.FullName 'TransactionRolledBack.json')
                if ($rolledBack) {
                    $summary.lastTransactionRollback = if ($rolledBack.newerSaveKept) { 'rolled_back_newer_save_kept' } else { 'rolled_back' }
                } elseif ($failure.rollback -cin @('unchanged','rolled_back','rolled_back_newer_save_kept','needs_recovery')) {
                    $summary.lastTransactionRollback = $failure.rollback
                } elseif (Get-PbzDiagnosticFile (Join-Path $latest.FullName 'TransactionComplete.json')) {
                    $summary.lastTransactionRollback = 'completed'
                }
            }
        }
        [pscustomobject]$summary
    }
}

function Export-PbzDiagnostics([string] $GameExe,[string] $OutputDirectory = '',
    [string] $AccountId = '',[string] $GameRoot = '',[ValidateSet('Steam','Epic')][string] $Store) {
    $layout = if ($GameExe) { Resolve-PbzGameLayout $GameExe } else {
        $choices = @(Get-PbzGameLayoutsAtRoot $GameRoot | Where-Object { !$Store -or $_.Store -eq $Store })
        if ($choices.Count -ne 1) { throw '请选择游戏根目录及对应平台。' }
        $choices[0]
    }
    $exe = Get-PbzDiagnosticPresence $layout.GameExe
    $version = if ($exe.status -eq 'present') {
        try { [Diagnostics.FileVersionInfo]::GetVersionInfo($layout.GameExe) } catch {}
    }
    $game = [ordered]@{ platform=$layout.Store; linkedRoot=[bool]($layout.EntryRoot -and $layout.EntryRoot -ine $layout.InstallRoot);
        executableStatus=$exe.status; fileVersion=$version.FileVersion;
        productVersion=$version.ProductVersion; executableSha256=$exe.sha256 }
    $loader = [ordered]@{}
    foreach ($name in @('dwmapi.dll','dinput8.dll','version.dll','winmm.dll','dxgi.dll','UE4SS.dll','ue4ss/UE4SS.dll')) {
        $loader[$name] = Get-PbzDiagnosticPresence (Join-Path $layout.Platform $name)
    }
    foreach ($name in @('ue4ss','ue4ss/Mods/PBZTestArena','Mods/PBZTestArena')) {
        $loader[$name] = Get-PbzDiagnosticPresence (Join-Path $layout.Platform $name) -Directory
    }
    $package = Get-PbzDiagnosticJson (Join-Path $script:pbzDiagnosticPackage 'PackageManifest.json')
    $installerRevision = if ($package.installerRevision -cmatch '^[A-Za-z0-9.-]{1,24}$') { $package.installerRevision }
    $packageVersion = if ($package.version -cmatch '^[A-Za-z0-9.-]{1,48}$') { $package.version }
    $log = Read-PbzDiagnosticLog $layout
    $logText = if ($log.text) { Protect-PbzDiagnosticText $log.text $layout.InstallRoot $layout.EntryRoot } else { '' }
    $started = @([regex]::Matches($logText,'(?im)^\[[^\]\r\n]+\][ \t]+(?:Starting (?:Lua |C\+\+ )?mod ''(?<name>[^''\r\n]+)''|Mod ''(?<name>[^''\r\n]+)'' has enabled\.txt, starting mod)') |
        ForEach-Object { $_.Groups['name'].Value } | Sort-Object -Unique)
    $modsRoot = Join-Path $layout.Platform 'ue4ss/Mods'
    if ($log.relativePath -eq 'UE4SS.log' -or !(Test-Path -LiteralPath $modsRoot -PathType Container)) {
        $modsRoot = Join-Path $layout.Platform 'Mods'
    }
    $config = Get-PbzDiagnosticModConfig $modsRoot
    foreach ($mod in $config.mods) { $mod.name = Protect-PbzDiagnosticText $mod.name $layout.InstallRoot $layout.EntryRoot }
    $packages = @(Get-PbzDiagnosticPackages $layout.InstallRoot | Select-Object -First 512)
    $scripts = Join-Path $modsRoot 'PBZTestArena/Scripts'
    $runtimePaths = [ordered]@{ 'UE4SS.dll' = (Join-Path (Split-Path -Parent $modsRoot) 'UE4SS.dll') }
    foreach ($name in @('main.lua','ArenaScenes.lua','ArenaSummonAccess.lua','BloodyPalace.lua','BloodyPalaceRoster.lua','PBZSaveBarrier.dll','StockArenaPresets.json',
            'DreamPalacePressure.lua','PressureControls.lua','ChallengeTarget.lua','PBZDreamPressureNative.dll')) {
        $runtimePaths[$name] = Join-Path $scripts $name
    }
    $runtime = [ordered]@{}
    $hashReadIssues = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $runtimePaths.GetEnumerator()) {
        $file = Get-PbzDiagnosticFile $entry.Value
        if (!$file) { continue }
        try { $runtime[$entry.Key] = Get-PbzDiagnosticHash $file.FullName }
        catch { $hashReadIssues.Add($entry.Key) }
    }
    $gameLog = $null
    foreach ($name in @('ProjectPBZ.log','PBZ.log')) {
        $gameLog = Read-PbzDiagnosticTail (Join-Path $layout.InstallRoot ('ProjectPBZ/Saved/Logs/' + $name)) 2MB $layout.InstallRoot $layout.EntryRoot
        if ($gameLog) { break }
    }
    $crash = Get-PbzLatestCrash $layout
    $report = [ordered]@{ schemaVersion=3; createdUtc=[DateTime]::UtcNow.ToString('o'); game=$game;
        installer=@{ version=$packageVersion; revision=$installerRevision }; loaderFiles=$loader;
        installation=@(Get-PbzDiagnosticReceipt $layout $AccountId);
        ue4ss=@{ startedInExportedLog=$started; configuredMods=$config.mods; configurationReadIssues=$config.issues;
            logStatus=$log.status; logPath=$log.relativePath; logModifiedUtc=$log.modifiedUtc;
            sessionStarted=$log.sessionStarted; logTruncated=[bool]$log.truncated };
        runtimeSha256=$runtime; gameLogIncluded=[bool]$gameLog; crashSummaryIncluded=[bool]$crash; contentPackagesFound=$packages }
    if ($hashReadIssues.Count) { $report.runtimeHashReadIssues = $hashReadIssues.ToArray() }
    if ($script:pbzLastInstallerIssue -and $script:pbzLastInstallerIssue.GameExe -iin @($layout.EntryGameExe,$layout.GameExe)) {
        $report.installIssue = @{ action=$script:pbzLastInstallerIssue.Action;
            code=$script:pbzLastInstallerIssue.code; stage=$script:pbzLastInstallerIssue.stage;
            nativeCode=$script:pbzLastInstallerIssue.nativeCode; rollback=$script:pbzLastInstallerIssue.rollback;
            target=(Protect-PbzDiagnosticText $script:pbzLastInstallerIssue.target $layout.InstallRoot $layout.EntryRoot);
            error=(Protect-PbzDiagnosticText $script:pbzLastInstallerIssue.Error $layout.InstallRoot $layout.EntryRoot) }
    }
    if (!$OutputDirectory) {
        $OutputDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'YingjingYanwu/Reports'
    }
    $OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
    [void][IO.Directory]::CreateDirectory($OutputDirectory)
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
    $zipPath = Join-Path $OutputDirectory ('PBZ-Diagnostics-' + $stamp + '.zip')
    $pending = $zipPath + '.tmp'
    Add-Type -AssemblyName System.IO.Compression
    try {
        $stream = [IO.File]::Open($pending,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {
            $archive = [IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
            try {
                Add-PbzDiagnosticZipText $archive 'Diagnostics.json' ($report | ConvertTo-Json -Depth 7)
                if ($log.status -eq 'included') { Add-PbzDiagnosticZipText $archive 'UE4SS.log' $logText }
                if ($gameLog) { Add-PbzDiagnosticZipText $archive 'Game.log' $gameLog }
                if ($crash) { Add-PbzDiagnosticZipText $archive 'Crash.json' $crash }
                Add-PbzDiagnosticZipText $archive '反馈模板.txt' "发生时间（含时区）：`r`n模式、场景、首领或血宫波次：`r`n复现步骤：`r`n预期结果：`r`n实际结果：`r`n复现频率：`r`n截图或录像（可选）：`r`n"
            } finally { $archive.Dispose() }
        } finally { $stream.Dispose() }
        [IO.File]::Move($pending,$zipPath)
    } finally { if ([IO.File]::Exists($pending)) { [IO.File]::Delete($pending) } }
    return [pscustomobject]@{ Path=$zipPath; LogIncluded=$log.status -eq 'included' }
}
