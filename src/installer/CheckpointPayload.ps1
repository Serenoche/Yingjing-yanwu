$checkpointPayloadFiles = @{}
$checkpointPayloadRoot = Join-Path $runtimeRoot 'CheckpointPayload'
$checkpointManifestPath = Join-Path $runtimeRoot 'CheckpointPayloadHashes.json'

function Get-PbzRuntimePayloadFile([string] $Relative) {
    if ($checkpointPayloadFiles.ContainsKey($Relative)) { return Join-Path $checkpointPayloadRoot $Relative }
    return Join-Path $payload $Relative
}

function Get-PbzCheckpointManifest {
    Assert-OrdinaryPath $checkpointManifestPath
    $data = Get-Content -LiteralPath $checkpointManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $admission = $data.nativeCheckpointAdmission
    if ($data.schemaVersion -ne 2 -or $data.slotCount -ne 60 -or
        $data.playableSlotCount -ne 52 -or $data.reservedSlotCount -ne 8 -or
        $admission.schemaVersion -ne 1 -or $admission.nativeOnly -isnot [bool] -or
        !$admission.nativeOnly -or $admission.legacySteamAllowed -isnot [bool]) {
        throw '52 图原版存点的安装准入清单无效。'
    }
    if ($admission.legacySteamAllowed) {
        $parser = $admission.legacySteamParser
        if ($parser.name -cne 'JsonObjectFromString' -or $parser.kind -cne 'code' -or
            $parser.rva -ne 0x024D8550 -or $parser.bytes -ne 195 -or
            $parser.sha256 -cne '74d3e71e1c3731a79456a430268d49e383a4c7c630b7e056833116af19bb5dbc') {
            throw '52 图原版存点的旧 Steam 接口清单无效。'
        }
    }
    return $data
}

function Test-PbzLegacySteamArenaMapBase {
    foreach ($name in @('global.utoc', 'ProjectPBZ-Windows.utoc')) {
        $path = Join-Path $installRoot ('ProjectPBZ/Content/Paks/' + $name)
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        Assert-OrdinaryPath $path
        if ((Get-Item -LiteralPath $path).Length -eq 0) { return $false }
    }
    return $true
}

function Test-PbzEpicCheckpointInterface($Parser) {
    if ($parser.rva -ne 0x024D7DF0 -or $parser.bytes -ne 32 -or $parser.kind -cne 'code' -or
        $parser.sha256 -cnotmatch '^[a-f0-9]{64}$') {
        throw '原版地图内测的 Epic 接口清单无效。'
    }
    return @(Check-NativeFile $game @($parser)).Count -eq 0
}

function Select-PbzCheckpointPayload($Data) {
    $required = @('main.lua','ArenaScenes.lua','PlayerProfile.lua','TitleSession.lua','Challenge.lua',
        'StockCheckpoint.lua','SaveBarrier.lua','MeiGuHuOriginalEvents.lua','PBZSaveBarrier.dll','StockArenaPresets.json')
    $prefix = 'ue4ss/Mods/PBZTestArena/Scripts/'
    foreach ($name in $required) {
        if (!$data.files.($prefix + $name)) { throw "原版地图内测缺少文件 $name。" }
    }
    foreach ($entry in $data.files.PSObject.Properties) {
        if ($entry.Name -cnotmatch '^ue4ss/Mods/PBZTestArena/Scripts/(?:[A-Za-z0-9_]+\.(?:lua|dll|json|png)|UiAssets/[A-Za-z0-9_][A-Za-z0-9_-]*\.(?:png|jpg|json))$' -or
            $entry.Value -cnotmatch '^[a-f0-9]{64}$') {
            throw '原版地图内测的文件清单含有无效路径或校验值。'
        }
        Assert-Hash (Join-Path $checkpointPayloadRoot $entry.Name) $entry.Value
        $checkpointPayloadFiles.Add($entry.Name, $entry.Value)
        Add-Member -InputObject $manifest -MemberType NoteProperty -Name $entry.Name -Value $entry.Value -Force
    }
}

function New-PbzUnchangedSaveReport([string] $Hash) {
    $data = [ordered]@{ schemaVersion=1; owner=$saveOwner; operation='native-checkpoint';
        sourceSha256=$Hash; outputSha256=$Hash; gameStarted=$false;
        continue=@{changed=$false; verification='all-save-bytes-identical'} }
    return @{report=[pscustomobject]$data; json=($data | ConvertTo-Json -Depth 5)}
}

function Set-PbzPrivateSaveReceipt($Prior) {
    # Preserve the ownership record of any dedicated slots created by an older installer.
    if ($Prior -and $Prior.privateManifestSha256) {
        if ($Prior.verifiedPrivatePath -ine $privatePath -and !(Test-Path -LiteralPath $privatePath)) {
            Add-PbzFileChange $privatePath '' $Prior.privateManifestSha256
            $privateStage = Join-Path $script:pbzTransactionRun 'PrivateSlotsPrepared.json'
            Copy-NewFile $Prior.verifiedPrivatePath $privateStage
            Assert-Hash $privateStage $Prior.privateManifestSha256
            [IO.File]::Move($privateStage,$privatePath)
        }
        Assert-Hash $privatePath $Prior.privateManifestSha256
        return $Prior.privateManifestSha256
    }
    return $null
}
