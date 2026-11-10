# Read-only preparation for store support. Never load game DLLs or read saves.
[CmdletBinding()]
param(
    [string] $GameExe,
    [ValidateSet('Unknown','Steam','Epic','WeGame')] [string] $Platform = 'Unknown',
    [string] $OutputDirectory,
    [string] $SaveGamesDirectory,
    [switch] $NoGui
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Get-LocalPath([string] $Value) {
    if (!$Value -or $Value -notmatch '^[A-Za-z]:[\\/]' -or
        $Value -match '[\x00-\x1f"<>|*?]' -or $Value.Substring(2).Contains(':')) {
        throw 'An absolute local path is required.'
    }
    foreach ($part in $Value.Replace('\','/').Substring(3).Split('/')) {
        if ($part -match '[. ]$' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            throw 'Windows path aliases are refused.'
        }
    }
    $path=[IO.Path]::GetFullPath($Value)
    $existing=$path
    $tail=New-Object 'System.Collections.Generic.List[string]'
    while (!(Test-Path -LiteralPath $existing)) {
        $tail.Add([IO.Path]::GetFileName($existing))
        $existing=Split-Path -Parent $existing
        if (!$existing) { throw 'No accessible local path ancestor.' }
    }
    $buffer=New-Object Text.StringBuilder 32768
    $length=[PBZPlatformPath]::GetLongPathName($existing,$buffer,32768)
    if (!$length -or $length -ge 32768) { throw 'The local path could not be canonicalized.' }
    $path=$buffer.ToString()
    for ($i=$tail.Count-1; $i -ge 0; $i--) { $path=Join-Path $path $tail[$i] }
    $check=$path
    while ($check) {
        if (Test-Path -LiteralPath $check) {
            if (([IO.File]::GetAttributes($check) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Linked paths are refused.'
            }
        }
        $parent=[IO.Path]::GetDirectoryName($check.TrimEnd('\','/'))
        if (!$parent -or $parent -eq $check) { break }
        $check=$parent
    }
    return $path
}

function Test-Within([string] $Path, [string] $Root) {
    $rootPath = $Root.TrimEnd('\','/')
    return $Path.Equals($rootPath,[StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($rootPath + '\',[StringComparison]::OrdinalIgnoreCase)
}

function Get-BinaryFingerprint([string] $Path) {
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -lt 64 -or $item.Length -gt 2147483648) { throw 'Unsupported binary size.' }
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object IO.BinaryReader($stream)
        if ($reader.ReadUInt16() -ne 0x5a4d) { throw 'Not a PE executable.' }
        $stream.Position = 0x3c
        $offset = $reader.ReadUInt32()
        if ($offset -lt 64 -or $offset -gt 1048576 -or $offset + 84 -gt $stream.Length) {
            throw 'Invalid PE header.'
        }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550) { throw 'Invalid PE signature.' }
        $machine = $reader.ReadUInt16()
        $sections = $reader.ReadUInt16()
        $timestamp = $reader.ReadUInt32()
        $stream.Position = $offset + 20
        $optionalSize = $reader.ReadUInt16()
        if ($optionalSize -lt 64 -or $offset + 24 + $optionalSize -gt $stream.Length) {
            throw 'Invalid PE optional header.'
        }
        $stream.Position = $offset + 24
        $magic = $reader.ReadUInt16()
        if ($magic -ne 0x20b -and $magic -ne 0x10b) { throw 'Unsupported PE header.' }
        $stream.Position = $offset + 24 + 56
        $imageSize = $reader.ReadUInt32()
        $stream.Position = 0
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose() }
        return [ordered]@{ sha256=$hash; fileBytes=[long]$item.Length;
            machine=('0x{0:x4}' -f $machine); peTimestamp=[long]$timestamp;
            imageBytes=[long]$imageSize; sections=[int]$sections; optionalMagic=('0x{0:x3}' -f $magic) }
    } finally { $stream.Dispose() }
}

function Get-NameShape([string] $Name) {
    $kind = if ($Name -cmatch '^\d+$') { 'digits' }
        elseif ($Name -cmatch '^[0-9a-fA-F]+$') { 'hex' }
        elseif ($Name -cmatch '^[0-9A-Za-z_-]+$') { 'ascii-token' }
        else { 'other' }
    return [ordered]@{ kind=$kind; length=$Name.Length }
}

function Get-SaveTreeShape([string] $Root, [string] $Label) {
    $report = [ordered]@{ root=$Label; present=(Test-Path -LiteralPath $Root -PathType Container);
        linkedEntriesSkipped=0; inaccessibleDirectories=0; truncated=$false; directories=@() }
    if (!$report.present) { return $report }
    $queue = New-Object 'System.Collections.Generic.Queue[object]'
    $queue.Enqueue(@{path=$Root; depth=0; parent=$null})
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $entries = 0
    $providerNames = @('Steam','Epic','EOS','WeGame','Tencent','WindowsNoEditor')
    while ($queue.Count -gt 0 -and $rows.Count -lt 128) {
        $next = $queue.Dequeue()
        $id = $rows.Count
        $name = [IO.Path]::GetFileName($next.path)
        $labelName = if ($next.depth -eq 0) { 'root' } elseif ($providerNames -contains $name) {
            @($providerNames | Where-Object { $_ -ieq $name })[0]
        } else { 'redacted' }
        $row = [ordered]@{ id=$id; parent=$next.parent; depth=$next.depth; name=$labelName;
            nameShape=(Get-NameShape $name); primarySavePresent=$false; savFiles=0;
            otherFiles=0; childDirectories=0 }
        if ($next.depth -eq 0) { $row.nameShape = $null }
        try {
            foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($next.path)) {
                $entries++
                if ($entries -gt 4096) { $report.truncated=$true; break }
                $attributes = [IO.File]::GetAttributes($entry)
                if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $report.linkedEntriesSkipped++; continue
                }
                if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                    $row.childDirectories++
                    if ($next.depth -lt 3 -and $queue.Count -lt 128) {
                        $queue.Enqueue(@{path=$entry; depth=($next.depth+1); parent=$id})
                    } else { $report.truncated=$true }
                } else {
                    if ([IO.Path]::GetFileName($entry) -ieq 'PBZSaveGame.sav') { $row.primarySavePresent=$true }
                    if ([IO.Path]::GetExtension($entry) -ieq '.sav') { $row.savFiles++ }
                    else { $row.otherFiles++ }
                }
            }
        } catch { $report.inaccessibleDirectories++ }
        $rows.Add($row)
        if ($entries -gt 4096) { break }
    }
    if ($queue.Count -gt 0) { $report.truncated=$true }
    $report.directories = @($rows.ToArray())
    return $report
}

function Write-PlatformReport {
    if (!$OutputDirectory) { $script:OutputDirectory = Join-Path $PSScriptRoot 'Reports' }
    if (!$GameExe) {
        if ($NoGui) { throw 'Select PBZ.exe first.' }
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object Windows.Forms.OpenFileDialog
        $dialog.Title = 'Select PBZ.exe (read-only check)'
        $dialog.Filter = 'PBZ.exe|PBZ.exe'
        try {
            if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }
            $script:GameExe = $dialog.FileName
        } finally { $dialog.Dispose() }
    }
    $game = Get-LocalPath $GameExe
    if ([IO.Path]::GetFileName($game) -ine 'PBZ.exe' -or !(Test-Path -LiteralPath $game -PathType Leaf)) {
        throw 'Select an existing PBZ.exe.'
    }
    $binaryRoot = Split-Path -Parent $game
    $installRoot = $null
    $ancestor = $binaryRoot
    for ($depth=0; $depth -lt 7 -and $ancestor; $depth++) {
        if (Test-Path -LiteralPath (Join-Path $ancestor 'ProjectPBZ') -PathType Container) {
            $installRoot = Get-LocalPath $ancestor
            break
        }
        $parent = Split-Path -Parent $ancestor
        if (!$parent -or $parent -eq $ancestor) { break }
        $ancestor=$parent
    }
    if (!$installRoot) { throw 'The ProjectPBZ game root could not be confirmed.' }
    $launchShape = 'unrecognized'
    $observedToken = 'redacted'
    if ((Split-Path -Leaf (Split-Path -Parent $binaryRoot)) -ieq 'platform' -and
        (Split-Path -Parent (Split-Path -Parent $binaryRoot)) -ieq $installRoot) {
        $launchShape = 'platform/<store>/PBZ.exe'
        $token = Split-Path -Leaf $binaryRoot
        if (@('steam','epic','eos','wegame','tencent') -contains $token) { $observedToken=$token.ToLowerInvariant() }
    } elseif ($binaryRoot -ieq $installRoot) {
        $launchShape='PBZ.exe alongside ProjectPBZ'
    } elseif ((Split-Path -Parent $binaryRoot) -ieq (Join-Path $installRoot 'ProjectPBZ/Binaries')) {
        $launchShape='ProjectPBZ/Binaries/<architecture>/PBZ.exe'
    }
    $outputRoot = Get-LocalPath $OutputDirectory
    $saveRoots = New-Object 'System.Collections.Generic.List[object]'
    $saveRoots.Add(@{path=(Join-Path $installRoot 'ProjectPBZ/Saved/SaveGames'); label='game-local SaveGames'})
    if ($SaveGamesDirectory) {
        $extra = Get-LocalPath $SaveGamesDirectory
        if (!(Test-Path -LiteralPath $extra -PathType Container)) { throw 'The selected save directory is unavailable.' }
        $saveRoots.Add(@{path=$extra; label='manually selected SaveGames'})
    }
    foreach ($protected in @($installRoot,$binaryRoot) + @($saveRoots.ToArray() | ForEach-Object { $_.path })) {
        if (Test-Within $outputRoot $protected) { throw 'Place the report folder outside the game and save directories.' }
    }
    $binary = Get-BinaryFingerprint $game
    $loader = @()
    foreach ($relative in @('dwmapi.dll','UE4SS.dll','ue4ss/UE4SS.dll')) {
        $file = Join-Path $binaryRoot $relative
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            try {
                $null = Get-LocalPath $file
                $loader += [ordered]@{ relativePath=$relative; binary=(Get-BinaryFingerprint $file); status='collected' }
            } catch { $loader += [ordered]@{relativePath=$relative; status='unreadable-or-invalid'} }
        }
    }
    $saveShapes = @()
    foreach ($root in $saveRoots) {
        try {
            $null = Get-LocalPath $root.path
            $saveShapes += Get-SaveTreeShape $root.path $root.label
        } catch { $saveShapes += [ordered]@{root=$root.label; status='unavailable-or-linked'} }
    }
    $report = [ordered]@{
        schemaVersion=1; purpose='platform-support-preparation'; declaredStore=$Platform;
        generatedUtc=[DateTime]::UtcNow.ToString('o'); supportVerdict='not-established-by-this-report';
        executable=$binary;
        layout=[ordered]@{launchShape=$launchShape; observedStoreDirectory=$observedToken;
            projectDirectoryPresent=(Test-Path -LiteralPath (Join-Path $installRoot 'ProjectPBZ') -PathType Container);
            paksDirectoryPresent=(Test-Path -LiteralPath (Join-Path $installRoot 'ProjectPBZ/Content/Paks') -PathType Container)};
        loaderBinaries=$loader; saveDirectoryShapes=$saveShapes;
        privacy=[ordered]@{absolutePathsIncluded=$false; accountNamesIncluded=$false;
            accountHashesIncluded=$false; saveContentsRead=$false; saveHashesComputed=$false};
        actions=[ordered]@{gameLaunched=$false; gameAttached=$false; gameFilesWritten=$false;
            saveFilesWritten=$false; installedSupportUnlocked=$false};
        limitations=@('Directory names are redacted except known provider labels.',
            'No save content is opened. Missing local saves do not prove that another save location does not exist.',
            'Only manually selected and game-local save roots are examined; no whole-drive or AppData scan.',
            'A store name or matching version string does not prove native ABI or save compatibility.')
    }
    $json = $report | ConvertTo-Json -Depth 12
    $null = [IO.Directory]::CreateDirectory($outputRoot)
    $destination = Join-Path $outputRoot ('PBZ-Platform-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8) + '.json')
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json + [Environment]::NewLine)
    $stream = [IO.File]::Open($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
    Write-Output ('Report saved: ' + $destination)
}

try {
    if (!('PBZPlatformPath' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Text;
using System.Runtime.InteropServices;
public static class PBZPlatformPath {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern uint GetLongPathName(string path, StringBuilder output, uint capacity);
}
'@
    }
    Write-PlatformReport
}
catch {
    # Raw exceptions can contain personal paths or account names. Do not export them.
    [Console]::Error.WriteLine('Read-only check could not finish. Select a local PBZ.exe and a report folder outside the game/save directories. Linked, inaccessible or invalid inputs are refused.')
    exit 1
}
