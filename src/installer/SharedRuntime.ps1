# Shared-runtime operations deliberately never own or replace the UE4SS root.
# These functions run in the existing installer scope and reuse its save checks.
function Test-PbzSharedRuntime($Prior) {
    if ($Prior -and $Prior.PSObject.Properties['installKind'] -and $Prior.installKind -ceq 'shared-v1' -and $Prior.installed) { return $true }
    if (!(Test-Path -LiteralPath $active -PathType Container)) { return $false }
    Assert-OrdinaryPath $active
    if (!@(Get-ChildItem -LiteralPath $active -Force).Count) { return $false }
    $rootMarker = Join-Path $active $ownerName
    if (!(Test-Path -LiteralPath $rootMarker)) { return $true }
    Assert-OrdinaryPath $rootMarker
    if ([IO.File]::ReadAllText($rootMarker).Trim() -cne $owner) { return $false }
    if ($Prior -and $Prior.PSObject.Properties['installKind'] -and $Prior.installKind -ceq 'shared-v1') { return $true }
    $modsDirectory = Join-Path $active 'Mods'
    if (Test-Path -LiteralPath $modsDirectory -PathType Container) {
        Assert-OrdinaryPath $modsDirectory
        return [bool]@(Get-ChildItem -LiteralPath $modsDirectory -Force | Where-Object { $_.Name -notin @('PBZTestArena','shared','mods.txt','mods.json') })
    }
    return $false
}

function Assert-PbzSharedCore([string] $Path) {
    Assert-OrdinaryPath $Path
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        if ($stream.Length -lt 128 -or $stream.Length -gt 2147483648) { throw 'Invalid UE4SS core size.' }
        $reader = New-Object IO.BinaryReader($stream)
        if ($reader.ReadUInt16() -ne 0x5a4d) { throw 'Invalid UE4SS DOS header.' }
        $stream.Position=0x3c; $offset=[long]$reader.ReadUInt32()
        if ($offset -lt 64 -or $offset -gt 1048576 -or $offset+88 -gt $stream.Length) { throw 'Invalid UE4SS PE offset.' }
        $stream.Position=$offset
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) { throw 'UE4SS must be an AMD64 PE library.' }
        $sections=$reader.ReadUInt16()
        $stream.Position=$offset+20; $optional=$reader.ReadUInt16(); $flags=$reader.ReadUInt16()
        if ($sections -lt 1 -or $sections -gt 96 -or $optional -lt 112 -or $offset+24+$optional -gt $stream.Length -or !($flags -band 0x2000)) {
            throw 'Invalid UE4SS DLL header.'
        }
        if ($reader.ReadUInt16() -ne 0x20b) { throw 'UE4SS must use the PE32+ layout.' }
        $stream.Position=$offset+24+56; $image=$reader.ReadUInt32()
        if ($image -lt 4096 -or $image -gt 2147483648) { throw 'Invalid UE4SS image size.' }
    } finally { $stream.Dispose() }
}

function Get-PbzSharedDependencies([switch] $SkipActivationPolicy) {
    $script:sharedActivationBlocked = $null
    $core = Join-Path $active 'UE4SS.dll'
    if (!(Test-Path -LiteralPath $core -PathType Leaf)) { throw '现有 UE4SS 目录缺少可识别的 UE4SS.dll；未替换前置、配置或其他 MOD。' }
    try { Assert-PbzSharedCore $core } catch { throw '现有 UE4SS.dll 不是完整的 AMD64 加载器核心；未改动前置或存档。' }
    # Existing loaders are retained rather than forced to match our bundled
    # build. Optional signatures/helpers may differ or be absent legitimately.
    # Every observed dependency, including missing entries, remains snapshotted.
    $observed = @('dwmapi.dll','dinput8.dll','winmm.dll','version.dll','dxgi.dll','UE4SS.dll',
        'ue4ss/UE4SS.dll','ue4ss/MemberVariableLayout.ini',
        'ue4ss/UE4SS_Signatures/GNatives.lua','ue4ss/UE4SS_Signatures/GUObjectArray.lua',
        'ue4ss/Mods/shared/UEHelpers/UEHelpers.lua')
    $snapshots = @{}
    foreach ($relative in $observed) {
        $file = Join-Path $platform $relative
        if (Test-Path -LiteralPath $file) { $snapshots[$relative] = Get-Hash $file }
        else { $snapshots[$relative] = $null }
    }
    $settings = Join-Path $active 'UE4SS-settings.ini'
    $section = ''; $values = @{}
    $reloadAmbiguous = $false
    if (Test-Path -LiteralPath $settings -PathType Leaf) {
        Assert-OrdinaryPath $settings
        if ((Get-Item -LiteralPath $settings).Length -gt 2097152) { throw 'UE4SS 配置过大，无法确认 MOD 加载位置；原文件未修改。' }
        foreach ($line in [IO.File]::ReadAllLines($settings)) {
            $clean = ($line -replace ';.*$','').Trim()
            if ($clean -match '^\[([^\]]+)\]$') { $section = $Matches[1];continue }
            if ($clean -match '^([+\-]?[A-Za-z][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
                $key,$value = $Matches[1],$Matches[2]
                if ($section -ieq 'Overrides' -and $key -match '^[+\-]?(?:ModsFolderPaths?|ControllingModsTxt)$' -and $value) {
                    throw '当前安装位置需要默认 Mods 目录与控制列表；自定义搜索路径未改动。'
                }
                $fullKey=$section + '/' + $key
                if ($fullKey -in @('General/EnableHotReloadSystem','General/EnableAutoReloadingLuaMods') -and $values.ContainsKey($fullKey)) { $reloadAmbiguous=$true }
                $values[$fullKey] = $value
            }
        }
    }
    if (!$SkipActivationPolicy -and ($reloadAmbiguous -or $values['General/EnableHotReloadSystem'] -ne '0' -or
        ($values['General/EnableAutoReloadingLuaMods'] -and $values['General/EnableAutoReloadingLuaMods'] -ne '0'))) {
        $script:sharedActivationBlocked = '现有 UE4SS 的热重载已开启或未能确认关闭。演武尚未激活，以保护正常存档；加载器及设置保持原样。'
    }
    foreach ($relative in @('ue4ss/UE4SS-settings.ini','ue4ss/Mods/mods.txt','ue4ss/Mods/mods.json')) {
        $file = Join-Path $platform $relative
        if (Test-Path -LiteralPath $file) {
            $snapshots[$relative] = Get-Hash $file
            $contents = [IO.File]::ReadAllText($file)
            if ($relative.EndsWith('mods.txt') -and $contents -match '(?im)^\s*PBZTestArena\s*:\s*0\b') {
                throw '现有 mods.txt 明确禁用了 PBZTestArena；请先在原 MOD 管理器启用这一项，其他内容未修改。'
            }
            if ($relative.EndsWith('mods.json')) {
                try {
                    if (!$contents.TrimStart().StartsWith('[')) { throw 'The MOD control list must be an array.' }
                    $decoded = $contents | ConvertFrom-Json
                    $entries = @($decoded) # PS5.1 pipeline JSON arrays are otherwise nested.
                    if ($entries.Count -gt 4096) { throw 'The MOD control list is oversized.' }
                    foreach ($entry in $entries) {
                        if (!$entry -or !($entry.mod_name -is [string]) -or !($entry.mod_enabled -is [bool])) { throw 'Invalid MOD control entry types.' }
                    }
                } catch { throw '现有 mods.json 无法解析为有效的 MOD 控制列表；文件未修改。' }
                foreach ($entry in $entries) {
                    if ($entry.mod_name -ieq 'PBZTestArena' -and $entry.mod_enabled -eq $false) {
                        throw '现有 mods.json 明确禁用了 PBZTestArena；请先在原 MOD 管理器启用这一项，其他内容未修改。'
                    }
                }
            }
        } else { $snapshots[$relative] = $null }
    }
    return ,$snapshots
}

function Assert-PbzSharedSnapshots($Snapshots) {
    foreach ($relative in $Snapshots.Keys) {
        $file = Join-Path $platform $relative
        if ($null -eq $Snapshots[$relative]) {
            if (Test-Path -LiteralPath $file) { throw ('共用前置在安装期间发生变化，已停止：' + $relative) }
        } else { Assert-Hash $file $Snapshots[$relative] }
    }
}

function Assert-PbzSharedMod($Prior, [string] $ModDirectory) {
    Assert-OrdinaryPath $ModDirectory
    if (!$Prior -or !$Prior.installed) { throw 'PBZTestArena 目录已存在但没有有效安装记录，未覆盖现有 MOD。' }
    $shared = $Prior.PSObject.Properties['installKind'] -and $Prior.installKind -ceq 'shared-v1'
    $marker = if ($shared) { Join-Path $ModDirectory '.PBZTestArenaShared-owner' } else { Join-Path $active $integratedName }
    Assert-OrdinaryPath $marker
    if ([IO.File]::ReadAllText($marker).Trim() -cne $owner) { throw '演武 MOD 的归属标记不匹配；现有文件未覆盖。' }
    foreach ($required in @('main.lua','PBZSaveBarrier.dll','IntegratedConfig.lua')) {
        $key = 'ue4ss/Mods/PBZTestArena/Scripts/' + $required
        if (!$Prior.runtimeHashes.$key) { throw '演武安装记录缺少必需文件，未覆盖现有 MOD。' }
    }
    foreach ($entry in $Prior.runtimeHashes.PSObject.Properties) {
        if (!$entry.Name.StartsWith('ue4ss/Mods/PBZTestArena/',[StringComparison]::Ordinal)) {
            if ($shared) { throw '共用安装记录包含非演武路径，已停止。' }
            continue
        }
        $file = Join-Path $platform $entry.Name
        Assert-Contained $file $ModDirectory
        Assert-Hash $file $entry.Value
    }
}

function Invoke-PbzSharedRuntime($Prior) {
    $modDirectory = Join-Path $active 'Mods/PBZTestArena'
    Assert-Contained $modDirectory (Join-Path $active 'Mods')
    if ($Uninstall -and (!$Prior -or !$Prior.installed)) { throw '未找到可卸载的演武安装记录。' }
    if (Test-Path -LiteralPath $modDirectory) { Assert-PbzSharedMod $Prior $modDirectory }
    elseif ($Prior -and $Prior.installed) { throw '已安装的演武目录缺失，安装记录未改动。' }
    $dependencies = if (!$Uninstall) { Get-PbzSharedDependencies } else { $null }
    if (!$Install -and !$Uninstall) {
        Write-Output 'Shared UE4SS fingerprints and owned MOD paths verified; existing loader/config/mods unchanged. No game started.'
        return
    }
    $mutex = New-Object Threading.Mutex($false,'Local\PBZTestArenaNativeSession')
    $held=$false; $run=$null; $stage=$null; $movedMod=$null; $installedMod=$false; $report=$null
    $writtenReceipts=@{}
    $rollback = $save + '.PBZShared-rollback-' + [Guid]::NewGuid().ToString('N')
    try {
        try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held=$true }
        if (!$held) { throw 'Another PBZ MOD installation or isolated test launcher is running.' }
        Assert-NotRunning
        $prior = Get-PreviousState
        if (Test-Path -LiteralPath $modDirectory) { Assert-PbzSharedMod $prior $modDirectory }
        elseif ($prior -and $prior.installed) { throw '演武目录在安装期间发生变化。' }
        if ($dependencies) { Assert-PbzSharedSnapshots $dependencies }
        $stamp=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
        $operationName=if($Install){'SharedInstall'}else{'SharedUninstall'}
        $dataMarker=Join-Path $dataRoot '.PBZTestArenaData-owner'
        if (Test-Path -LiteralPath $dataMarker) {
            Assert-OrdinaryPath $dataMarker
            if ([IO.File]::ReadAllText($dataMarker).Trim() -cne $owner) { throw 'Persistent arena data belongs to another owner.' }
        } elseif ((Test-Path -LiteralPath $dataRoot) -and @(Get-ChildItem -LiteralPath $dataRoot -Force).Count) {
            throw 'Unowned arena data retained; no files overwritten.'
        } else { Ensure-Directory $dataRoot;Write-NewText $dataMarker $owner }
        Grant-OwnedWriteAccess $dataRoot '.PBZTestArenaData-owner'
        $run=Join-Path $stateRoot ('Backups/'+$stamp);Ensure-Directory $run
        foreach($file in @($statePath,$privatePath)) {
            if(Test-Path -LiteralPath $file){Copy-NewFile $file (Join-Path $run ([IO.Path]::GetFileName($file)))}
        }
        $beforeHash=Get-Hash $save
        Copy-NewFile $save (Join-Path $run 'Before.sav')
        Assert-Hash (Join-Path $run 'Before.sav') $beforeHash
        if ($Install) {
            $sourceHelper,$sourcePresets=$helper,$presets
            $transaction=Join-Path $dataRoot ('Transactions/'+$operationName+'-'+$stamp+'/IntegratedMenu')
            $staging=Join-Path $transaction 'Staging';Ensure-Directory $staging
            $helper=Join-Path $transaction 'Tools/PBZSaveTool.exe'
            $presets=Join-Path $transaction 'PrivatePresets.pbzs'
            Copy-NewFile $sourceHelper $helper
            Copy-NewFile $sourcePresets $presets
            Assert-Hash $helper $toolBuild.sha256;Assert-Hash $presets $toolBuild.presetsSha256
            $pending=Join-Path $staging 'Pending.sav'
            $priorManifest=if($prior -and $prior.privateManifestSha256){$prior.verifiedPrivatePath}else{''}
            $prepared=Invoke-SaveTool $save $pending $priorManifest
            $report=$prepared.report
            $preferenceMarker=Join-Path $preferences '.PBZTestArenaArenaPrefs-owner'
            if(Test-Path -LiteralPath $preferenceMarker){
                Assert-OrdinaryPath $preferenceMarker
                if([IO.File]::ReadAllText($preferenceMarker).Trim() -cne $owner){throw 'Unowned preferences retained.'}
            }elseif((Test-Path -LiteralPath $preferences) -and @(Get-ChildItem -LiteralPath $preferences -Force).Count){throw 'Unowned preferences retained.'}
            else{Ensure-Directory $preferences;Write-NewText $preferenceMarker $owner}
            Ensure-Directory $profile;Ensure-Directory (Join-Path $profile 'ChallengeReports')
            $profileMarker=Join-Path $profile 'PBZIntegratedProfile.txt'
            if(Test-Path -LiteralPath $profileMarker){
                Assert-OrdinaryPath $profileMarker
                if([IO.File]::ReadAllText($profileMarker).Trim() -cne $owner){throw 'Profile ownership differs.'}
            }else{Write-NewText $profileMarker $owner}
            $stage=Join-Path $platform ('.PBZShared-stage-'+[Guid]::NewGuid().ToString('N'))
            Assert-Contained $stage $platform;Ensure-Directory $stage
            $hashes=[ordered]@{}
            foreach($entry in $manifest.PSObject.Properties){
                $prefix='ue4ss/Mods/PBZTestArena/'
                if(!$entry.Name.StartsWith($prefix,[StringComparison]::Ordinal)){continue}
                $destination=Join-Path $stage $entry.Name.Substring($prefix.Length)
                Assert-Contained $destination $stage
                Copy-NewFile (Join-Path $payload $entry.Name) $destination
                Assert-Hash $destination $entry.Value
                $hashes[$entry.Name]=$entry.Value
            }
            if(!$hashes['ue4ss/Mods/PBZTestArena/enabled.txt']){throw 'Shared loading requires the packaged enabled.txt.'}
            Write-NewText (Join-Path $stage '.PBZTestArenaShared-owner') $owner
            $config=(New-Config $save).Replace('    version = 2,',"    version = 2,`n    installMode = `"shared-v1`",")
            Write-NewText (Join-Path $stage 'Scripts/IntegratedConfig.lua') $config
            $generated = @('.PBZTestArenaShared-owner','Scripts/IntegratedConfig.lua')
            if ($script:sharedActivationBlocked) {
                Write-NewText (Join-Path $stage 'Scripts/CompatibilityPending.lua') ("return { schemaVersion = 1, owner = " + (Lua-String $owner) + ", pending = true, reason = `"loader-reload`" }`n")
                $generated += 'Scripts/CompatibilityPending.lua'
            }
            foreach($relative in $generated){
                $hashes['ue4ss/Mods/PBZTestArena/'+$relative]=Get-Hash (Join-Path $stage $relative)
            }
            Grant-OwnedWriteAccess $stage '.PBZTestArenaShared-owner'
            Assert-PbzSharedSnapshots $dependencies
            Assert-NotRunning
            [void](Replace-Save $pending $save $report.sourceSha256 $report.outputSha256 $rollback)
        }else{
            $report=[pscustomobject]@{sourceSha256=$beforeHash;outputSha256=$beforeHash}
            Assert-Hash $save $beforeHash
        }
        Assert-NotRunning
        if(Test-Path -LiteralPath $modDirectory){
            Assert-PbzSharedMod $prior $modDirectory
            $movedMod=Join-Path $run 'RuntimeBefore';Assert-Contained $movedMod $run
            [IO.Directory]::Move($modDirectory,$movedMod)
        }
        if($Install){
            Ensure-Directory (Split-Path -Parent $modDirectory)
            [IO.Directory]::Move($stage,$modDirectory);$stage=$null;$installedMod=$true
            foreach($entry in $hashes.GetEnumerator()){Assert-Hash (Join-Path $platform $entry.Key) $entry.Value}
            Assert-PbzSharedSnapshots $dependencies
            Write-AtomicText $privatePath $prepared.json
            $writtenReceipts[$privatePath]=Get-Hash $privatePath
            $state=[ordered]@{version=3;owner=$owner;installKind='shared-v1';installed=$true;
                installedAt=(Get-Date).ToUniversalTime().ToString('o');launcherRoot=$root;gameExe=$game;savePath=$save;
                profile=$profile;userSid=$UserSid;privateManifestSha256=(Get-Hash $privatePath);runtimeHashes=$hashes;
                sharedDependencies=$dependencies;backup=$run;loaderRetained=$true;otherModsRetained=$true}
        }else{
            $state=[ordered]@{version=3;owner=$owner;installKind='shared-v1';installed=$false;
                uninstalledAt=(Get-Date).ToUniversalTime().ToString('o');privateManifestSha256=$prior.privateManifestSha256;
                savePath=$save;dedicatedSaveBlocksRetained=$true;reportsRetained=$true;loaderRetained=$true;otherModsRetained=$true;backup=$run}
        }
        Write-AtomicText $statePath ($state | ConvertTo-Json -Depth 8)
        $writtenReceipts[$statePath]=Get-Hash $statePath
        Assert-Hash $save $report.outputSha256
        if(Test-Path -LiteralPath $rollback){Assert-Hash $rollback $report.sourceSha256;Remove-Item -LiteralPath $rollback}
        Write-NewText (Join-Path $run 'Result.json') (([ordered]@{success=$true;operation=$operationName;installKind='shared-v1';
            sourceSha256=$report.sourceSha256;outputSha256=$report.outputSha256;loaderRetained=$true;otherModsRetained=$true;gameStarted=$false}) | ConvertTo-Json)
        Write-Output ($operationName+' completed. Existing UE4SS, configuration and other MODs retained. No game started.')
    }catch{
        $failure=$_;$errors=New-Object 'System.Collections.Generic.List[string]'
        try{
            if($installedMod -and (Test-Path -LiteralPath $modDirectory)){
                foreach($entry in $hashes.GetEnumerator()){Assert-Hash (Join-Path $platform $entry.Key) $entry.Value}
                $failed=Join-Path $run 'FailedRuntime';Assert-Contained $failed $run
                [IO.Directory]::Move($modDirectory,$failed)
            }
            if($movedMod -and (Test-Path -LiteralPath $movedMod) -and !(Test-Path -LiteralPath $modDirectory)){
                Assert-Contained $movedMod $run;[IO.Directory]::Move($movedMod,$modDirectory)
            }
        }catch{$errors.Add('Owned MOD rollback: '+$_.Exception.Message)}
        try{
            if($stage -and (Test-Path -LiteralPath $stage) -and $run){
                Assert-Contained $stage $platform
                $retainedStage=Join-Path $run 'UncommittedRuntime';Assert-Contained $retainedStage $run
                [IO.Directory]::Move($stage,$retainedStage)
            }
        }catch{$errors.Add('Stage retention: '+$_.Exception.Message)}
        try{if($report){Restore-Save $save $rollback $report.sourceSha256 $report.outputSha256}}catch{$errors.Add('Save rollback: '+$_.Exception.Message)}
        foreach($file in @($writtenReceipts.Keys)){
            try{
                Assert-Hash $file $writtenReceipts[$file]
                $previous=Join-Path $run ([IO.Path]::GetFileName($file))
                if(Test-Path -LiteralPath $previous){Write-AtomicText $file ([IO.File]::ReadAllText($previous))}
                else{Remove-Item -LiteralPath $file}
            }catch{$errors.Add('Receipt rollback: '+$_.Exception.Message)}
        }
        if($run){Write-AtomicText (Join-Path $run 'Failure.json') (([ordered]@{success=$false;message=$failure.Exception.Message;rollbackErrors=@($errors);gameStarted=$false}) | ConvertTo-Json -Depth 4)}
        if($errors.Count){Write-Warning ($errors -join '; ')}
        throw $failure
    }finally{
        if($held){$mutex.ReleaseMutex()};$mutex.Dispose()
    }
}
