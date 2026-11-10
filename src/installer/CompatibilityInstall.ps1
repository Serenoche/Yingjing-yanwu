# Installation without save preparation for a game whose native profile is not ready.
# Own only this MOD folder; preserve an existing loader, settings and all other MODs.
function Assert-PbzPendingPe([string] $Path) {
    Assert-OrdinaryPath $Path
    $stream=[IO.File]::OpenRead($Path)
    try {
        $reader=New-Object IO.BinaryReader($stream)
        if($stream.Length -lt 256 -or $reader.ReadUInt16() -ne 0x5a4d){throw 'Not a PE file.'}
        $stream.Position=0x3c;$offset=[long]$reader.ReadUInt32()
        if($offset -lt 64 -or $offset -gt 1048576 -or $offset+88 -gt $stream.Length){throw 'Invalid PE header.'}
        $stream.Position=$offset
        if($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664){throw 'An x64 client/loader is required.'}
        $stream.Position=$offset+24
        if($reader.ReadUInt16() -ne 0x20b){throw 'An x64 PE32+ client/loader is required.'}
    } finally {$stream.Dispose()}
}

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

function Invoke-PbzPendingInstall {
    Assert-PbzPendingPe $game
    $mod=Join-Path $active 'Mods/PBZTestArena'
    Assert-Contained $mod $active
    $receipt=$null
    if(Test-Path -LiteralPath $mod){$receipt=Read-PbzPendingReceipt $mod}
    if($Uninstall -and !$receipt){throw 'No pending installation to remove.'}
    if(!$Install -and !$Uninstall){Write-Output 'Game version is not an installation blocker. Save preparation is pending; no files changed.';return}
    $mutex=New-Object Threading.Mutex($false,'Local\PBZTestArenaNativeSession')
    $held=$false;$stage=$null;$backup=$null;$placed=$false
    $created=New-Object 'System.Collections.Generic.List[object]'
    try {
        try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(!$held){throw 'Another MOD installation or isolated session is running.'}
        Assert-NotRunning
        if(Test-Path -LiteralPath $mod){$receipt=Read-PbzPendingReceipt $mod}elseif($receipt){throw 'The pending MOD changed during installation.'}
        $stamp=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
        if($Install){
            $core=Join-Path $active 'UE4SS.dll'
            $reuse=Test-Path -LiteralPath $core -PathType Leaf
            $snapshots=@{}
            $sharedSnapshots=$null
            if($reuse){Assert-PbzPendingPe $core;$sharedSnapshots=Get-PbzSharedDependencies -SkipActivationPolicy}
            elseif(Test-Path -LiteralPath (Join-Path $platform 'UE4SS.dll')){
                throw 'This existing root-level UE4SS layout requires a matching MOD search path; it was preserved.'
            }
            $loaderFiles=@('dwmapi.dll','ue4ss/LICENSE','ue4ss/UE4SS.dll','ue4ss/MemberVariableLayout.ini',
                'ue4ss/UE4SS-settings.ini','ue4ss/UE4SS_Signatures/GNatives.lua',
                'ue4ss/UE4SS_Signatures/GUObjectArray.lua','ue4ss/Mods/shared/UEHelpers/UEHelpers.lua',
                'ue4ss/Mods/mods.txt','ue4ss/Mods/mods.json')
            foreach($relative in $loaderFiles){
                $destination=Join-Path $platform $relative
                if(Test-Path -LiteralPath $destination){$snapshots[$relative]=Get-Hash $destination}
                else{$snapshots[$relative]=$null}
            }
            if(!$reuse -and $snapshots['dwmapi.dll'] -and $snapshots['dwmapi.dll'] -cne $manifest.'dwmapi.dll'){
                throw 'An existing proxy DLL was preserved. Its loader must be identified before adding another one.'
            }
            $stage=Join-Path $platform ('.PBZPending-stage-'+[Guid]::NewGuid().ToString('N'))
            Assert-Contained $stage $platform;Ensure-Directory $stage
            $hashes=[ordered]@{}
            foreach($entry in $manifest.PSObject.Properties){
                $prefix='ue4ss/Mods/PBZTestArena/'
                if(!$entry.Name.StartsWith($prefix,[StringComparison]::Ordinal)){continue}
                $relative=$entry.Name.Substring($prefix.Length)
                $destination=Join-Path $stage $relative;Assert-Contained $destination $stage
                Copy-NewFile (Join-Path $payload $entry.Name) $destination;Assert-Hash $destination $entry.Value
                $hashes[$relative]=$entry.Value
            }
            Write-NewText (Join-Path $stage '.PBZTestArenaShared-owner') $owner
            Write-NewText (Join-Path $stage 'Scripts/CompatibilityPending.lua') @"
return { schemaVersion = 1, owner = $(Lua-String $owner), pending = true }
"@
            foreach($relative in @('.PBZTestArenaShared-owner','Scripts/CompatibilityPending.lua')){$hashes[$relative]=Get-Hash (Join-Path $stage $relative)}
            $record=[ordered]@{schemaVersion=1;owner=$owner;kind='compatibility-pending';gameExe=[IO.Path]::GetFullPath($game);
                gameSha256=(Get-Hash $game);installedAt=[DateTime]::UtcNow.ToString('o');files=$hashes;
                existingUE4SSReused=[bool]$reuse;normalSaveReadOrWritten=$false}
            Write-NewText (Join-Path $stage '.PBZTestArenaPending-install.json') ($record | ConvertTo-Json -Depth 6)
            # Recheck all pre-existing loader/control files before any changes.
            foreach($relative in $snapshots.Keys){
                $destination=Join-Path $platform $relative
                if($snapshots[$relative]){Assert-Hash $destination $snapshots[$relative]}
                elseif(Test-Path -LiteralPath $destination){throw 'The loader changed during installation.'}
            }
            if($sharedSnapshots){Assert-PbzSharedSnapshots $sharedSnapshots}
            if(!$reuse){
                foreach($relative in $loaderFiles){
                    if($snapshots[$relative]){continue} # preserve existing settings/control files and sidecars
                    $source=Join-Path $payload $relative
                    if(!(Test-Path -LiteralPath $source -PathType Leaf)){continue}
                    $destination=Join-Path $platform $relative
                    # Copy and verify outside the live loader paths first. A
                    # partial copy can never become UE4SS.dll/dwmapi.dll.
                    $temporary=Join-Path $platform ('.PBZPending-loader-'+[Guid]::NewGuid().ToString('N')+'.tmp')
                    Assert-Contained $temporary $platform
                    try {
                        Copy-NewFile $source $temporary
                        Assert-Hash $temporary $manifest.$relative
                        Ensure-Directory (Split-Path -Parent $destination)
                        $change=@{path=$destination;sha256=$manifest.$relative;placed=$false}
                        $created.Add($change)
                        [IO.File]::Move($temporary,$destination);$change.placed=$true
                        Assert-Hash $destination $manifest.$relative
                    } finally {
                        if(Test-Path -LiteralPath $temporary){Assert-OrdinaryPath $temporary;Remove-Item -LiteralPath $temporary}
                    }
                }
            }
        }
        Assert-NotRunning
        if($receipt){
            $null=Read-PbzPendingReceipt $mod
            $backup=Join-Path $platform ('.PBZPending-backup-'+$stamp)
            Assert-Contained $backup $platform;Assert-Contained $mod $active
            [IO.Directory]::Move($mod,$backup)
        }
        if($Install){
            Ensure-Directory (Split-Path -Parent $mod)
            [IO.Directory]::Move($stage,$mod);$stage=$null;$placed=$true
            Grant-OwnedWriteAccess $mod '.PBZTestArenaShared-owner'
            $null=Read-PbzPendingReceipt $mod
            Write-Output 'Installed using the existing UE4SS, or added it only when absent. This game awaits native save-interface adaptation; ordinary saves were not opened or changed.'
        }else{Write-Output 'Pending MOD removed. UE4SS, settings, other MODs and all saves were retained.'}
    } catch {
        $failure=$_
        $rollbackErrors=New-Object 'System.Collections.Generic.List[string]'
        try {
            if($placed -and (Test-Path -LiteralPath $mod)){
                # The candidate itself may have failed its receipt/hash check.
                # Preserve it by moving our marked folder rather than requiring
                # that damaged receipt again and aborting all other rollback.
                Assert-OrdinaryPath $mod
                $proof=Join-Path $mod '.PBZTestArenaShared-owner';Assert-OrdinaryPath $proof
                if([IO.File]::ReadAllText($proof).Trim() -cne $owner){throw 'Candidate ownership changed.'}
                $failed=Join-Path $platform ('.PBZPending-failed-'+[Guid]::NewGuid().ToString('N'))
                Assert-Contained $failed $platform;Assert-Contained $mod $active
                [IO.Directory]::Move($mod,$failed)
            }
        } catch {$rollbackErrors.Add('Candidate retained; ownership or file access changed.')}
        try {
            if($backup -and (Test-Path -LiteralPath $backup) -and !(Test-Path -LiteralPath $mod)){
                Assert-Contained $backup $platform;Assert-Contained $mod $active
                [IO.Directory]::Move($backup,$mod)
            }
        } catch {$rollbackErrors.Add('Previous MOD retained in its backup folder.')}
        foreach($entry in $created){
            try {
                if($entry.placed -and (Test-Path -LiteralPath $entry.path)){
                    Assert-Contained $entry.path $platform;Assert-Hash $entry.path $entry.sha256;Remove-Item -LiteralPath $entry.path
                }
            } catch {$rollbackErrors.Add('A newly added loader file changed and was retained.')}
        }
        if($rollbackErrors.Count){throw ('Pending install failed. '+($rollbackErrors -join ' '))}
        throw $failure
    } finally {if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
