# Shared read-only discovery for the GUI and command-line installer.
function ConvertTo-PbzLocalPath([string] $Path) {
    if ($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path -match '[\x00-\x1f"<>|*?]' -or
        $Path.Substring(2).Contains(':')) { throw '请选择本机磁盘上的绝对路径。' }
    if ($Path.Length -ge 260) { throw [IO.PathTooLongException]::new('游戏路径过长。') }
    return [IO.Path]::GetFullPath($Path)
}

function Resolve-PbzInstallRoot([string] $Root) {
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    while ($visited.Count -lt 32 -and $visited.Add($Root)) {
        $parent = [IO.Path]::GetPathRoot($Root)
        $parts = @($Root.Substring($parent.Length).Split([char]'\',[StringSplitOptions]::RemoveEmptyEntries))
        for ($index = 0; $index -lt $parts.Count; $index++) {
            $path = [IO.Path]::Combine($parent,$parts[$index])
            $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            if (!$item) {
                if ($visited.Count -eq 1) { return $Root }
                throw "游戏目录联接的目标不存在或无法访问：$path"
            }
            if (!$item.PSIsContainer) { throw "游戏目录被同名文件占用：$path" }
            if (!($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $parent = $path
                continue
            }
            $targets = @($item.Target)
            if ($item.LinkType -notin @('Junction','SymbolicLink') -or $targets.Count -ne 1 -or !$targets[0]) {
                throw "游戏目录使用了无法识别的联接：$path"
            }
            $target = [string]$targets[0]
            if ($target -match '^\\\\\?\\[A-Za-z]:\\') { $target = $target.Substring(4) }
            if (![IO.Path]::IsPathRooted($target)) { $target = [IO.Path]::Combine($parent,$target) }
            $target = ConvertTo-PbzLocalPath $target
            $suffix = $Root.Substring($path.Length).TrimStart([char]'\')
            $Root = [IO.Path]::GetFullPath([IO.Path]::Combine($target,$suffix))
            break
        }
        if ($index -eq $parts.Count) { return $Root }
    }
    throw '游戏目录联接形成了循环，或联接层数过多。'
}

function Resolve-PbzGameLayout([string] $GameExe) {
    $entryExe = ConvertTo-PbzLocalPath $GameExe
    if ($entryExe.Replace('\','/') -notmatch '(?i)/platform/(steam|epicgamestore)/PBZ\.exe$') {
        throw '请选择 Steam 或 Epic 安装目录下的 platform/steam/PBZ.exe 或 platform/epicgamestore/PBZ.exe。'
    }
    $epic = $Matches[1] -ieq 'epicgamestore'
    $entryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $entryExe))
    $install = Resolve-PbzInstallRoot $entryRoot
    $relative = $entryExe.Substring($entryRoot.Length).TrimStart([char]'\')
    $game = [IO.Path]::Combine($install,$relative)
    $platform = Split-Path -Parent $game
    $provider = if ($epic) { 'EOS' } else { 'Steam' }
    return [pscustomobject]@{ GameExe=$game; Platform=$platform; InstallRoot=$install; Store=if ($epic) { 'Epic' } else { 'Steam' };
        EntryGameExe=$entryExe; EntryRoot=$entryRoot;
        SaveRoot=(Join-Path $install ('ProjectPBZ/Saved/SaveGames/' + $provider));
        ArenaDataRoot=(Join-Path $install $(if ($epic) { 'ProjectPBZ/Saved/PBZTestArena/EOS' } else { 'ProjectPBZ/Saved/PBZTestArena' }));
        AccountPattern=if ($epic) { '^[a-fA-F0-9]{32}$' } else { '^\d{17}$' } }
}
function Get-PbzSteamRoots([string[]] $AdditionalRoots = @()) {
    $roots = New-Object 'System.Collections.Generic.List[string]'
    foreach ($value in $AdditionalRoots) { if ($value) { $roots.Add($value) } }
    foreach ($key in @('HKCU:/Software/Valve/Steam','HKLM:/SOFTWARE/Valve/Steam','HKLM:/SOFTWARE/WOW6432Node/Valve/Steam')) {
        $item = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($item) { foreach ($name in @('SteamPath','InstallPath')) { if ($item.$name) { $roots.Add([string]$item.$name) } } }
    }
    foreach ($parent in @(${env:ProgramFiles(x86)},$env:ProgramFiles)) {
        if ($parent) { $roots.Add((Join-Path $parent 'Steam')) }
    }
    $found = @{}
    foreach ($candidate in @($roots.ToArray())) {
        try {
            $path = [IO.Path]::GetFullPath($candidate)
            if (!(Test-Path -LiteralPath $path -PathType Container)) { continue }
            $found[$path.ToLowerInvariant()] = $path
            $vdf = Join-Path $path 'steamapps/libraryfolders.vdf'
            if (!(Test-Path -LiteralPath $vdf -PathType Leaf)) { continue }
            if ((Get-Item -LiteralPath $vdf).Length -gt 2097152) { continue }
            $content = [IO.File]::ReadAllText($vdf)
            foreach ($match in [regex]::Matches($content,'(?im)"(?:path|\d+)"\s+"([A-Za-z]:\\[^"\r\n]+)"')) {
                $library = [IO.Path]::GetFullPath($match.Groups[1].Value.Replace('\\','\'))
                if (Test-Path -LiteralPath $library -PathType Container) { $found[$library.ToLowerInvariant()] = $library }
            }
        } catch { continue }
    }
    return @($found.Values | Sort-Object)
}
function Get-PbzGameCandidates([string[]] $AdditionalSteamRoots = @(), [string] $EpicManifests = '') {
    $found = @{}
    foreach ($library in @(Get-PbzSteamRoots $AdditionalSteamRoots)) {
        $apps = Join-Path $library 'steamapps'
        if (!(Test-Path -LiteralPath $apps -PathType Container)) { continue }
        $directories = New-Object 'System.Collections.Generic.List[string]'
        $directories.Add('PBZ')
        foreach ($file in @(Get-ChildItem -LiteralPath $apps -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue)) {
            if ($file.Length -gt 2097152) { continue }
            try { $match = [regex]::Match([IO.File]::ReadAllText($file.FullName),'(?im)"installdir"\s+"([^"\r\n]+)"') }
            catch { continue }
            if ($match.Success -and $match.Groups[1].Value -notmatch '[\\/:]') { $directories.Add($match.Groups[1].Value) }
        }
        foreach ($directory in $directories) {
            $exe = Join-Path (Join-Path $apps ('common/' + $directory)) 'platform/steam/PBZ.exe'
            if (Test-Path -LiteralPath $exe -PathType Leaf) {
                try {
                    $layout = Resolve-PbzGameLayout $exe
                    $found[$layout.GameExe.ToLowerInvariant()] = $layout
                } catch { continue }
            }
        }
    }
    if (!$EpicManifests -and $env:ProgramData) {
        $EpicManifests = Join-Path $env:ProgramData 'Epic/EpicGamesLauncher/Data/Manifests'
    }
    if ($EpicManifests -and (Test-Path -LiteralPath $EpicManifests -PathType Container)) {
        foreach ($file in @(Get-ChildItem -LiteralPath $EpicManifests -Filter '*.item' -File -ErrorAction SilentlyContinue)) {
            if ($file.Length -gt 2MB -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            try {
                $item = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
                if ($item.bIsIncompleteInstall -or $item.InstallLocation -notmatch '^[A-Za-z]:[\\/]') { continue }
                $exe = Join-Path $item.InstallLocation 'platform/epicgamestore/PBZ.exe'
                if (!(Test-Path -LiteralPath $exe -PathType Leaf)) { continue }
                $layout = Resolve-PbzGameLayout $exe
                $found[$layout.GameExe.ToLowerInvariant()] = $layout
            } catch { continue }
        }
    }
    return @($found.Values | Sort-Object GameExe)
}
function Get-PbzGameLayoutsAtRoot([string] $Directory) {
    if (!$Directory) { return }
    $path = [IO.Path]::GetFullPath($Directory)
    if (!(Test-Path -LiteralPath $path -PathType Container)) { return }
    if ($path.Replace('\','/').TrimEnd('/') -match '(?i)/platform/(steam|epicgamestore)$') {
        return Resolve-PbzGameLayout (Join-Path $path 'PBZ.exe')
    }
    foreach ($storePath in @('steam','epicgamestore')) {
        $platformPath = Join-Path $path "platform/$storePath"
        if (Test-Path -LiteralPath $platformPath -PathType Container) {
            Resolve-PbzGameLayout (Join-Path $platformPath 'PBZ.exe')
        }
    }
}

function Get-PbzSaveAccounts([string] $GameExe, $Layout) {
    if (!$Layout) { $Layout = Resolve-PbzGameLayout $GameExe }
    if (!(Test-Path -LiteralPath $layout.SaveRoot -PathType Container)) { return @() }
    $accounts = @()
    foreach ($directory in @(Get-ChildItem -LiteralPath $layout.SaveRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($directory.Name -cnotmatch $layout.AccountPattern -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
        $save = Join-Path $directory.FullName 'PBZSaveGame.sav'
        $data = Join-Path $layout.ArenaDataRoot $directory.Name
        $pending = Join-Path $data 'IntegratedMenu/InstallerPending.json'
        $hasSave = Test-Path -LiteralPath $save -PathType Leaf
        if (!$hasSave -and !(Test-Path -LiteralPath $pending -PathType Leaf)) { continue }
        $modifiedSource = if ($hasSave) { $save } else { $pending }
        $accounts += [pscustomobject]@{ Account=$directory.Name; SavePath=$save;
            Modified=(Get-Item -LiteralPath $modifiedSource).LastWriteTime; DataRoot=$data }
    }
    return @($accounts | Sort-Object Account)
}
