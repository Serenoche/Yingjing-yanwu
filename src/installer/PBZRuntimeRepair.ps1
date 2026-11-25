# Restore only the missing runtime when the old installation and save are known.
function Initialize-PbzOwnedProfile {
    $prefMarker = Join-Path $preferences '.PBZTestArenaArenaPrefs-owner'
    $profileMarker = Join-Path $profile 'PBZIntegratedProfile.txt'
    foreach ($marker in @($prefMarker,$profileMarker)) {
        if (Test-Path -LiteralPath $marker) {
            Assert-OrdinaryPath $marker
            if ([IO.File]::ReadAllText($marker).Trim() -cne $owner) {
                Stop-PbzInstall 'RECEIPT_UNVERIFIED' '演武配装或档案目录的归属不符。请导出诊断。' $marker
            }
        }
    }
    if (!(Test-Path -LiteralPath $prefMarker)) {
        if ((Test-Path -LiteralPath $preferences) -and @(Get-ChildItem -LiteralPath $preferences -Force).Count) {
            Stop-PbzInstall 'RECEIPT_UNVERIFIED' '已有配装文件，但缺少目录归属标记。请导出诊断。' $preferences
        }
        New-PbzTransactionDirectory $preferences
        Write-PbzTransactionText $prefMarker $owner
    }
    New-PbzTransactionDirectory (Join-Path $profile 'ChallengeReports')
    if (!(Test-Path -LiteralPath $profileMarker)) { Write-PbzTransactionText $profileMarker $owner }
}

function New-PbzModStage([string] $Directory, [bool] $Shared) {
    Assert-Contained $Directory (Get-PbzTransactionWork)
    Ensure-Directory $Directory
    $prefix = 'ue4ss/Mods/PBZTestArena/'
    $hashes = [ordered]@{}
    foreach ($entry in $manifest.PSObject.Properties) {
        if (!$entry.Name.StartsWith($prefix,[StringComparison]::Ordinal)) { continue }
        $destination = Join-Path $Directory $entry.Name.Substring($prefix.Length)
        Assert-Contained $destination $Directory
        Copy-NewFile (Get-PbzRuntimePayloadFile $entry.Name) $destination
        Assert-Hash $destination $entry.Value
        $hashes[$entry.Name] = $entry.Value
    }
    if (!$hashes[$prefix + 'enabled.txt']) { throw 'The package is missing enabled.txt for PBZTestArena.' }
    $marker = '.PBZTestArenaShared-owner'
    Write-NewText (Join-Path $Directory $marker) $owner
    $config = New-Config $save
    if ($Shared) {
        $config = $config.Replace('    version = 2,', ('    version = 2,' + [char]10 + '    installMode = "shared-v1",'))
    }
    Write-NewText (Join-Path $Directory 'Scripts/IntegratedConfig.lua') $config
    foreach ($relative in @($marker,'Scripts/IntegratedConfig.lua')) {
        $hashes[$prefix+$relative] = Get-Hash (Join-Path $Directory $relative)
    }
    Grant-OwnedWriteAccess $Directory $marker
    return $hashes
}

function Invoke-PbzRuntimeRepair($Prior, [bool] $Shared) {
    $mutex = New-Object Threading.Mutex($false,'Local\PBZTestArenaNativeSession')
    $held = $false
    $run = $null
    try {
        try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held=$true }
        if (!$held) { Stop-PbzInstall 'INSTALLER_BUSY' '另一项安装或游戏会话正在运行，请关闭后重试。' }
        Assert-NotRunning
        Assert-PbzOtherTransactions
        $Prior = Get-PreviousState
        Assert-PbzMissingRuntimeReceipt $Prior $Shared
        if ((Test-PbzSharedRuntime $Prior) -ne $Shared -or (Test-Path -LiteralPath $modDirectory)) {
            Stop-PbzInstall 'PATH_CONFLICT' '演武目录或加载器在检查后发生变化，请重新检查。' $modDirectory
        }
        if (!$Shared) {
            Assert-OwnedRuntime $active -Integrated
            Assert-PreviousRuntime $Prior -AllowMissingMod
        } else {
            $dependencies = Get-PbzSharedDependencies
        }
        Assert-Hash $game $actualGameHash
        Assert-PbzInstallAccess $true $null $null
        $script:pbzInstallerStage = 'backup'
        $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
        $run = Join-Path $stateRoot "Backups/$stamp"
        Ensure-Directory $run
        $before = Get-Hash $save
        Copy-NewFile $save (Join-Path $run 'Before.sav')
        Assert-Hash (Join-Path $run 'Before.sav') $before
        Copy-NewFile $statePath (Join-Path $run 'InstallState.json')
        $script:pbzInstallerStage = 'stage'
        Start-PbzTransaction $run 'Repair'
        Initialize-PbzOwnedProfile
        $stage = Join-Path (Get-PbzTransactionWork) 'Mod'
        $hashes = New-PbzModStage $stage $Shared
        Assert-NotRunning
        Assert-Hash $save $before
        if ($Shared) { Assert-PbzSharedSnapshots $dependencies }
        else { Assert-PreviousRuntime $Prior -AllowMissingMod }
        $script:pbzInstallerStage = 'commit'
        New-PbzTransactionDirectory (Split-Path -Parent $modDirectory)
        Move-PbzTransactionPath $stage $modDirectory
        foreach ($entry in $hashes.GetEnumerator()) { Assert-Hash (Join-Path $platform $entry.Key) $entry.Value }
        if ($Shared) { Assert-PbzSharedSnapshots $dependencies }
        else {
            foreach ($item in $Prior.runtimeHashes.PSObject.Properties) {
                if (!$item.Name.StartsWith('ue4ss/Mods/PBZTestArena/',[StringComparison]::Ordinal)) { $hashes[$item.Name] = $item.Value }
            }
        }
        $Prior.runtimeHashes = $hashes
        $Prior.PSObject.Properties.Remove('verifiedPrivatePath')
        $Prior | Add-Member -NotePropertyName mapFlow -NotePropertyValue $checkpointFlow -Force
        $Prior | Add-Member -NotePropertyName backup -NotePropertyValue $run -Force
        if ($Shared) { $Prior | Add-Member -NotePropertyName sharedDependencies -NotePropertyValue $dependencies -Force }
        Write-PbzTransactionText $statePath ($Prior | ConvertTo-Json -Depth 8)
        Assert-Hash $save $before
        Write-NewText (Join-Path $run 'Result.json') (([ordered]@{success=$true;operation='Repair';sourceSha256=$before;
            outputSha256=$before;gameStarted=$false}) | ConvertTo-Json)
        Complete-PbzTransaction 'TransactionComplete.json'
        Write-Output '已重建演武文件并核验存档。请从游戏平台正常启动。'
    } catch {
        $failure = $_
        Set-PbzTransactionFailure $failure $run
        throw $failure
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
