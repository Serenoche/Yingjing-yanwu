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
    if ($data.schemaVersion -ne 2 -or $data.slotCount -ne 60 -or
        $data.playableSlotCount -ne 4 -or $data.reservedSlotCount -ne 56) {
        throw '原版地图内测的存点清单无效。'
    }
    return $data
}

function Test-PbzEpicCheckpointInterface {
    $data = Get-PbzCheckpointManifest
    $parser = $data.referenceParser
    if ($parser.rva -ne 0x024D7DF0 -or $parser.bytes -ne 32 -or $parser.kind -cne 'code' -or
        $parser.sha256 -cnotmatch '^[a-f0-9]{64}$') {
        throw '原版地图内测的 Epic 接口清单无效。'
    }
    return @(Check-NativeFile $game @($parser)).Count -eq 0
}

function Select-PbzCheckpointPayload {
    $data = Get-PbzCheckpointManifest
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

function Set-PbzPrivateSaveReceipt($Prepared, $Prior) {
    if ($checkpointFlow -eq 'compatibility') {
        Write-PbzTransactionText $privatePath $Prepared.json
        return (Get-Hash $privatePath)
    }
    # Keep any prior compatibility ownership record for a later downgrade.
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
