# Uninstall older compatibility builds that had not activated their save integration.
function Read-PbzPendingReceipt([string] $Directory) {
    Assert-OrdinaryPath $Directory
    $marker=Join-Path $Directory '.PBZTestArenaShared-owner'
    Assert-OrdinaryPath $marker
    if([IO.File]::ReadAllText($marker).Trim() -cne $owner){throw 'Existing MOD ownership differs.'}
    $path=Join-Path $Directory '.PBZTestArenaPending-install.json'
    Assert-OrdinaryPath $path
    $receipt=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if($receipt.schemaVersion -ne 1 -or $receipt.owner -cne $owner -or $receipt.kind -cne 'compatibility-pending' -or
        [IO.Path]::GetFullPath($receipt.gameExe) -ine [IO.Path]::GetFullPath($game)) {throw 'Existing MOD is not this pending installation.'}
    $entries=@($receipt.files.PSObject.Properties)
    if($entries.Count -lt 3 -or $entries.Count -gt 256){throw 'Invalid pending file receipt.'}
    foreach($entry in $entries){
        if($entry.Name -notmatch '^[A-Za-z0-9_./-]+$' -or $entry.Name -match '(^|/)\.\.(/|$)' -or
            $entry.Value -cnotmatch '^[a-f0-9]{64}$'){throw 'Invalid pending file ownership.'}
        $file=Join-Path $Directory $entry.Name;Assert-Contained $file $Directory;Assert-Hash $file $entry.Value
    }
    return $receipt
}

function Remove-PbzPendingInstall {
    $mutex = New-Object Threading.Mutex($false,'Local\PBZTestArenaNativeSession')
    $held = $false
    $run = $null
    try {
        try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (!$held) { Stop-PbzInstall 'INSTALLER_BUSY' '另一项安装或游戏会话正在运行，请关闭后重试。' }
        Assert-NotRunning
        Assert-PbzOtherTransactions
        Assert-PbzMoveReady $modDirectory
        $null = Read-PbzPendingReceipt $modDirectory
        $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
        $run = New-PbzBackupRun $stamp
        Start-PbzTransaction $run 'PendingUninstall'
        Move-PbzTransactionPath $modDirectory (Join-Path $run 'RuntimeBefore')
        Complete-PbzTransaction 'TransactionComplete.json'
        Write-Output '旧兼容内测已卸载，原加载器、其他 MOD 和存档已保留。'
    } catch {
        $failure = $_
        Set-PbzTransactionFailure $failure $run
        throw $failure
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
