# The standalone packages live under the game content root, outside UE4SS.
# Join their moves to the existing installer transaction and receipt.
function Get-PbzMapNames {
    foreach ($stem in @('zzz_PBZLakeUpperArenaTestR8_P','zzz_PBZMeiGuHuArenaTestR62_P')) {
        foreach ($extension in @('.pak','.utoc','.ucas')) { $stem + $extension }
    }
}

function Get-PbzSettlementAudioNames {
    foreach ($extension in @('.pak','.utoc','.ucas')) { 'zzz_PBZEndingR38_Audio_P' + $extension }
}

function Get-PbzManagedMapNames {
    Get-PbzMapNames
    # Early 2.0.0 receipts can own these files. Only track their removal and rollback.
    Get-PbzSettlementAudioNames
}

function Test-PbzArenaMapBase {
    $manifest = Join-Path $runtimeRoot 'ArenaMaps.json'
    if (!(Test-Path -LiteralPath $manifest -PathType Leaf)) { return $false }
    Assert-OrdinaryPath $manifest
    $data = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($name in @('global.utoc','ProjectPBZ-Windows.utoc')) {
        $expected = $data.referenceBase.$name
        $path = Join-Path $installRoot ('ProjectPBZ/Content/Paks/' + $name)
        if ($expected -cnotmatch '^[a-f0-9]{64}$' -or !(Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        Assert-OrdinaryPath $path
        if ((Get-Hash $path) -cne $expected) { return $false }
    }
    return $true
}

function Get-PbzMapPayload {
    $files = [ordered]@{}
    $path = Join-Path $runtimeRoot 'ArenaMaps.json'
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return $files }
    Assert-OrdinaryPath $path
    $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $names = @(Get-PbzMapNames)
    if ($data.schemaVersion -ne 1 -or @($data.files.PSObject.Properties).Count -ne $names.Count) {
        throw '独立地图文件清单不完整，请重新解压安装包。'
    }
    foreach ($name in $names) {
        $expected = $data.files.$name
        if ($expected -cnotmatch '^[a-f0-9]{64}$') { throw "独立地图校验值无效：$name" }
        Assert-Hash (Join-Path $runtimeRoot ('ArenaMaps/' + $name)) $expected
        $files[$name] = $expected
    }
    return $files
}

function New-PbzMapTransaction($Prior, $Next) {
    $before = [ordered]@{}
    $folder = Join-Path $installRoot 'ProjectPBZ/Content/Paks/~mods'
    $names = @(Get-PbzManagedMapNames)
    $settlementAudioNames = @(Get-PbzSettlementAudioNames)
    foreach ($row in @($Prior.mapHashes.PSObject.Properties)) {
        if (!$row) { continue }
        if ($row.Name -cnotin $names -or $row.Value -cnotmatch '^[a-f0-9]{64}$') { throw '独立地图安装记录无效。' }
        $before[$row.Name] = $row.Value
    }
    foreach ($name in $names) {
        $target = Join-Path $folder $name
        if (!(Test-Path -LiteralPath $target)) { continue }
        if ($before.Contains($name)) { Assert-Hash $target $before[$name] }
        elseif (!$Uninstall -and ($name -cnotin $settlementAudioNames -or $Next.Contains($name))) {
            throw "独立地图已由旧内测或手动安装：$name。请先还原该内测或移走同名地图。"
        }
    }
    if (!$Uninstall) {
        foreach ($file in @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue)) {
            if ($file.Name -match '^zzz_PBZ(?:LakeUpperArena|MeiGuHuArena)Test.+_P\.(?:pak|utoc|ucas)$' -and $file.Name -cnotin $names) {
                throw "检测到旧版独立地图 $($file.Name)。请先还原对应内测。"
            }
        }
    }
    return [pscustomobject]@{Folder=$folder;Before=$before;Next=$Next;
        Installed=[ordered]@{};Saved=[ordered]@{};Pending=[ordered]@{} }
}

function Set-PbzMapTransaction($Maps, [string] $Run) {
    if (!$Maps.Before.Count -and !$Maps.Next.Count) { return }
    Assert-NotRunning
    if ($Maps.Next.Count) { New-PbzTransactionDirectory $Maps.Folder }
    foreach ($name in @(Get-PbzManagedMapNames)) {
        $target = Join-Path $Maps.Folder $name
        if (!$Maps.Before.Contains($name) -and !$Maps.Next.Contains($name)) { continue }
        if ($Maps.Next.Contains($name)) {
            $pending = Join-Path (Get-PbzTransactionWork) ('Maps/' + $name)
            $Maps.Pending[$name] = $pending
            Copy-NewFile (Join-Path $runtimeRoot ('ArenaMaps/' + $name)) $pending
            Assert-Hash $pending $Maps.Next[$name]
        }
        if (Test-Path -LiteralPath $target) {
            if (!$Maps.Before.Contains($name)) { throw "独立地图在安装期间出现：$name" }
            Assert-Hash $target $Maps.Before[$name]
            $saved = Join-Path $Run ('MapsBefore/' + $name)
            Ensure-Directory (Split-Path -Parent $saved)
            Move-PbzTransactionPath $target $saved
            $Maps.Saved[$name] = $saved
        }
        if ($Maps.Next.Contains($name)) {
            Move-PbzTransactionPath $Maps.Pending[$name] $target
            $Maps.Installed[$name] = $Maps.Next[$name]
            $Maps.Pending.Remove($name)
            Assert-Hash $target $Maps.Next[$name]
        }
    }
}

function Get-PbzSettlementAudioPayload {
    $files = [ordered]@{}
    $path = Join-Path $runtimeRoot 'ArenaMaps.json'
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return $files }
    Assert-OrdinaryPath $path
    $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (!$data.settlementAudio -or !@($data.settlementAudio.PSObject.Properties).Count) { return $files }
    $names = @(Get-PbzSettlementAudioNames)
    if ($data.schemaVersion -ne 1 -or @($data.settlementAudio.PSObject.Properties).Count -ne $names.Count) {
        throw '浊梦结算配乐清单不完整，请重新解压安装包。'
    }
    foreach ($name in $names) {
        $expected = $data.settlementAudio.$name
        if ($expected -cnotmatch '^[a-f0-9]{64}$') { throw "浊梦结算配乐校验值无效：$name" }
        Assert-Hash (Join-Path $runtimeRoot ('ArenaMaps/' + $name)) $expected
        $files[$name] = $expected
    }
    return $files
}
