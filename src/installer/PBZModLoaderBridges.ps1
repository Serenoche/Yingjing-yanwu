# Companion mods are installed only through an existing PBZModLoader.
$pbzLoaderBridgeIds = @('PBZModFeaturesR1', 'PBZFrostEventR3')

function Get-PbzLoaderBridgePayload {
    $folder = Join-Path $runtimeRoot 'LoaderBridges'
    $manifestFile = Join-Path $folder 'Hashes.json'
    Assert-OrdinaryPath $manifestFile
    $manifest = Get-Content -LiteralPath $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or @($manifest.files.PSObject.Properties).Count -ne $pbzLoaderBridgeIds.Count) {
        throw 'The PBZModLoader companion manifest is incomplete.'
    }
    $files = [ordered]@{}
    foreach ($id in $pbzLoaderBridgeIds) {
        $hash = $manifest.files.$id
        if ($hash -cnotmatch '^[a-f0-9]{64}$') { throw "Invalid PBZModLoader companion hash: $id" }
        Assert-Hash (Join-Path $folder "$id/main.js") $hash
        $files[$id] = $hash
    }
    return $files
}

function New-PbzLoaderBridgeTransaction($Prior, $Payload) {
    $files = [ordered]@{}
    $priorHashes = [ordered]@{}
    foreach ($entry in $Prior.loaderBridgeHashes.PSObject.Properties) {
        if ($entry.Name -cnotin $pbzLoaderBridgeIds -or $entry.Value -cnotmatch '^[a-f0-9]{64}$') {
            throw 'Invalid ownership record for PBZModLoader companions.'
        }
        $priorHashes[$entry.Name] = $entry.Value
    }

    $loader = Join-Path $installRoot 'ProjectPBZ/PBZModLoader'
    $runtime = Join-Path $installRoot 'ProjectPBZ/Content/JavaScript/PBZModLoader'
    $next = [ordered]@{}
    $loaderReady = [bool]$Payload.Count
    if ($loaderReady) {
        foreach ($path in @((Join-Path $loader 'mods.ini'), (Join-Path $runtime 'bootstrap.js'), (Join-Path $runtime 'manager.js'))) {
            if (!(Test-Path -LiteralPath $path -PathType Leaf)) { $loaderReady = $false; break }
            Assert-OrdinaryPath $path
        }
    }
    foreach ($id in $pbzLoaderBridgeIds) {
        if (!$loaderReady -and !$priorHashes.Contains($id)) { continue }
        $directory = Join-Path $loader "mods/$id"
        $target = Join-Path $directory 'main.js'
        Assert-Contained $target $loader
        $current = $null
        if (Test-Path -LiteralPath $target) {
            if (!$priorHashes.Contains($id)) {
                Write-Warning "Existing PBZModLoader mod retained: $id"
                continue
            }
            Assert-Hash $target $priorHashes[$id]
            $current = $priorHashes[$id]
        }
        if ($loaderReady -and $Payload.Contains($id)) {
            if ((Test-Path -LiteralPath $directory) -and !(Test-Path -LiteralPath $directory -PathType Container)) {
                Write-Warning "Existing PBZModLoader path retained: $id"
            } elseif (Test-Path -LiteralPath (Join-Path $directory 'main.ts')) {
                Write-Warning "Existing PBZModLoader mod retained: $id"
            } else { $next[$id] = $Payload[$id] }
        }
        $files[$id] = [pscustomobject]@{Target=$target; Before=$current; After=$next[$id]}
    }
    return [pscustomobject]@{Files=$files; Next=$next}
}

function Set-PbzLoaderBridgeTransaction($Transaction, [string] $Run) {
    Assert-NotRunning
    foreach ($item in $Transaction.Files.GetEnumerator()) {
        $entry = $item.Value
        if ($entry.Before -ceq $entry.After) {
            if ($entry.Before) { Assert-Hash $entry.Target $entry.Before }
            continue
        }
        if ($entry.After) {
            $source = Join-Path $runtimeRoot ('LoaderBridges/' + $item.Key + '/main.js')
            $staged = Join-Path (Get-PbzTransactionWork) ('LoaderBridges/' + $item.Key + '/main.js')
            Copy-NewFile $source $staged
            Assert-Hash $staged $entry.After
            New-PbzTransactionDirectory (Split-Path -Parent $entry.Target)
        }
        if ($entry.Before) {
            Assert-Hash $entry.Target $entry.Before
            $backup = Join-Path $Run ('LoaderBridgesBefore/' + $item.Key + '/main.js')
            Ensure-Directory (Split-Path -Parent $backup)
            Move-PbzTransactionPath $entry.Target $backup
            Assert-Hash $backup $entry.Before
        }
        if ($entry.After) {
            Move-PbzTransactionPath $staged $entry.Target
            Assert-Hash $entry.Target $entry.After
        }
    }
}
