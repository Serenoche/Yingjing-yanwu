# Shared read-only discovery for the GUI and command-line installer.
function Resolve-PbzGameLayout([string] $GameExe) {
    if ($GameExe -notmatch '^[A-Za-z]:[\\/]' -or $GameExe -match '[\x00-\x1f"<>|*?]' -or
        $GameExe.Substring(2).Contains(':')) { throw 'Choose an absolute local PBZ.exe path.' }
    $game = [IO.Path]::GetFullPath($GameExe)
    if ($game.Replace('\','/') -notmatch '(?i)/platform/steam/PBZ\.exe$') {
        throw 'Choose platform/steam/PBZ.exe inside the game installation.'
    }
    $platform = Split-Path -Parent $game
    $install = Split-Path -Parent (Split-Path -Parent $platform)
    return [pscustomobject]@{ GameExe=$game; Platform=$platform; InstallRoot=$install;
        SaveSteamRoot=(Join-Path $install 'ProjectPBZ/Saved/SaveGames/Steam') }
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
function Get-PbzGameCandidates([string[]] $AdditionalSteamRoots = @()) {
    $found = @{}
    foreach ($library in @(Get-PbzSteamRoots $AdditionalSteamRoots)) {
        $apps = Join-Path $library 'steamapps'
        if (!(Test-Path -LiteralPath $apps -PathType Container)) { continue }
        $directories = New-Object 'System.Collections.Generic.List[string]'
        $directories.Add('PBZ')
        foreach ($file in @(Get-ChildItem -LiteralPath $apps -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue)) {
            if ($file.Length -gt 2097152) { continue }
            $match = [regex]::Match([IO.File]::ReadAllText($file.FullName),'(?im)"installdir"\s+"([^"\r\n]+)"')
            if ($match.Success -and $match.Groups[1].Value -notmatch '[\\/:]') { $directories.Add($match.Groups[1].Value) }
        }
        foreach ($directory in $directories) {
            $exe = Join-Path (Join-Path $apps ('common/' + $directory)) 'platform/steam/PBZ.exe'
            if (Test-Path -LiteralPath $exe -PathType Leaf) {
                $layout = Resolve-PbzGameLayout $exe
                $found[$layout.GameExe.ToLowerInvariant()] = $layout
            }
        }
    }
    return @($found.Values | Sort-Object GameExe)
}
function Get-PbzSaveAccounts([string] $GameExe) {
    $layout = Resolve-PbzGameLayout $GameExe
    if (!(Test-Path -LiteralPath $layout.SaveSteamRoot -PathType Container)) { return @() }
    $accounts = @()
    foreach ($directory in @(Get-ChildItem -LiteralPath $layout.SaveSteamRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($directory.Name -cnotmatch '^\d{17}$') { continue }
        $save = Join-Path $directory.FullName 'PBZSaveGame.sav'
        if (!(Test-Path -LiteralPath $save -PathType Leaf)) { continue }
        $accounts += [pscustomobject]@{ Account=$directory.Name; SavePath=$save;
            Modified=(Get-Item -LiteralPath $save).LastWriteTime; DataRoot=(Join-Path $layout.InstallRoot ('ProjectPBZ/Saved/PBZTestArena/' + $directory.Name)) }
    }
    return @($accounts | Sort-Object Account)
}
