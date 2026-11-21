# Shared-runtime operations deliberately never own or replace the UE4SS root.
# These functions run in the existing installer scope and reuse its save checks.
function Test-PbzSharedRuntime($Prior) {
    if (Test-Path -LiteralPath $active -PathType Leaf) {
        Stop-PbzInstall 'LOADER_CONFLICT' 'UE4SS 的安装目录被同名文件占用。请在原 MOD 管理器中还原前置，或把这个同名文件移出游戏目录后重新检查。' $active
    }
    if ($Prior -and $Prior.PSObject.Properties['installKind'] -and $Prior.installKind -ceq 'shared-v1' -and $Prior.installed) { return $true }
    if (!(Test-Path -LiteralPath $active -PathType Container)) { return $false }
    Assert-OrdinaryPath $active
    if (!@(Get-ChildItem -LiteralPath $active -Force).Count) { return $false }
    $rootMarker = Join-Path $active $ownerName
    if (!(Test-Path -LiteralPath $rootMarker)) { return $true }
    Assert-OrdinaryPath $rootMarker
    if ([IO.File]::ReadAllText($rootMarker).Trim() -cne $owner) { return $false }
    if ($Prior -and $Prior.PSObject.Properties['installKind'] -and $Prior.installKind -ceq 'shared-v1') { return $true }
    if (!$Uninstall -and !$Prior.installed -and (Test-Path -LiteralPath (Join-Path $active $integratedName))) { return $true }
    $modsDirectory = Join-Path $active 'Mods'
    if (Test-Path -LiteralPath $modsDirectory -PathType Container) {
        Assert-OrdinaryPath $modsDirectory
        $otherMods = @(Get-ChildItem -LiteralPath $modsDirectory -Force | Where-Object { $_.Name -notin @('PBZTestArena','shared','mods.txt','mods.json') })
        if ($otherMods.Count) { return $true }
        $sharedFiles = Join-Path $modsDirectory 'shared'
        if ($Prior.installed -and (Test-Path -LiteralPath $sharedFiles -PathType Container)) {
            foreach ($file in @(Get-PbzTreeItems $sharedFiles)) {
                if ($file.PSIsContainer) { continue }
                $relative = $file.FullName.Substring($platform.TrimEnd([char[]]'\/').Length + 1).Replace('\','/')
                $expected = $Prior.runtimeHashes.$relative
                if (!$expected -or (Get-Hash $file.FullName) -cne $expected) { return $true }
            }
        }
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

function Get-PbzSharedDependencies {
    $core = Join-Path $active 'UE4SS.dll'
    if (!(Test-Path -LiteralPath $core -PathType Leaf)) {
        Stop-PbzInstall 'LOADER_CONFLICT' '现有 UE4SS 缺少核心文件，无法复用。请用原 MOD 管理器修复 UE4SS，确认游戏能启动后再点「检查安装」。' $core
    }
    Assert-OrdinaryPath $core
    try { Assert-PbzSharedCore $core } catch {
        $issue = Get-PbzInstallError $_
        if ($issue.code -ne 'CHECK_FAILED') { throw }
        Stop-PbzInstall 'LOADER_CONFLICT' '现有 UE4SS 核心已损坏，或不是 64 位版本。请用原 MOD 管理器重新安装适配游戏的 64 位 UE4SS，再检查。' $core
    }
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
        if ((Get-Item -LiteralPath $settings).Length -gt 2097152) {
            Stop-PbzInstall 'LOADER_CONFLICT' '当前 UE4SS 配置异常，无法检查 MOD 加载位置。请用原 MOD 管理器恢复 UE4SS 的配置，再检查。' $settings
        }
        foreach ($line in [IO.File]::ReadAllLines($settings)) {
            $clean = ($line -replace ';.*$','').Trim()
            if ($clean -match '^\[([^\]]+)\]$') { $section = $Matches[1];continue }
            if ($clean -match '^([+\-]?[A-Za-z][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
                $key,$value = $Matches[1],$Matches[2]
                if ($section -ieq 'Overrides' -and $key -match '^[+\-]?(?:ModsFolderPaths?|ControllingModsTxt)$' -and $value -and $value -notin @('""',"''")) {
                    Stop-PbzInstall 'LOADER_CONFLICT' '现有 UE4SS 使用自定义的 MOD 路径。请在原 MOD 管理器恢复默认路径。如果是手动配置，备份 ue4ss/UE4SS-settings.ini 后，将 [Overrides] 中已有的 ModsFolderPath、ModsFolderPaths 和 ControllingModsTxt 值清空，再检查。' $settings
                }
                $fullKey=$section + '/' + $key
                if ($fullKey -in @('General/EnableHotReloadSystem','General/EnableAutoReloadingLuaMods') -and $values.ContainsKey($fullKey)) { $reloadAmbiguous=$true }
                $values[$fullKey] = $value
            }
        }
    }
    if ($reloadAmbiguous -or $values['General/EnableHotReloadSystem'] -ne '0' -or
        ($values['General/EnableAutoReloadingLuaMods'] -and $values['General/EnableAutoReloadingLuaMods'] -ne '0')) {
        Stop-PbzInstall 'LOADER_CONFLICT' '无法确认 UE4SS 已关闭热重载。请在原 MOD 管理器关闭热重载和 Lua 自动重载。如果是手动配置，请在 ue4ss/UE4SS-settings.ini 的 [General] 下将 EnableHotReloadSystem 设为 0，已有的 EnableAutoReloadingLuaMods 照样设为 0，再检查。' $settings
    }
    foreach ($relative in @('ue4ss/UE4SS-settings.ini','ue4ss/Mods/mods.txt','ue4ss/Mods/mods.json')) {
        $file = Join-Path $platform $relative
        if (Test-Path -LiteralPath $file) {
            $snapshots[$relative] = Get-Hash $file
            $contents = [IO.File]::ReadAllText($file)
            if ($relative.EndsWith('mods.txt') -and $contents -match '(?im)^\s*PBZTestArena\s*:\s*0\b') {
                Stop-PbzInstall 'MOD_DISABLED' '现有 UE4SS 禁用了影境演武。请在原 MOD 管理器启用 PBZTestArena。如果是手动管理，请把 ue4ss/Mods/mods.txt 里的相应一行改成 PBZTestArena : 1，再检查。' $file
            }
            if ($relative.EndsWith('mods.json')) {
                try {
                    if (!$contents.TrimStart().StartsWith('[')) { throw 'The MOD control list must be an array.' }
                    $decoded = $contents | ConvertFrom-Json
                    $entries = if ($null -eq $decoded) { @() } else { @($decoded) }
                    if ($entries.Count -gt 4096) { throw 'The MOD control list is oversized.' }
                    foreach ($entry in $entries) {
                        if (!$entry -or !($entry.mod_name -is [string]) -or !($entry.mod_enabled -is [bool])) { throw 'Invalid MOD control entry types.' }
                    }
                } catch {
                    Stop-PbzInstall 'LOADER_CONFLICT' '无法读取 UE4SS 的 mods.json。请在原 MOD 管理器重新保存启用列表，再检查安装。' $file
                }
                foreach ($entry in $entries) {
                    if ($entry.mod_name -ieq 'PBZTestArena' -and $entry.mod_enabled -eq $false) {
                        Stop-PbzInstall 'MOD_DISABLED' '现有 UE4SS 禁用了影境演武。请在生成 mods.json 的原 MOD 管理器启用 PBZTestArena，再检查。' $file
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

function Assert-PbzSharedMod($Prior, [string] $ModDirectory, [switch] $ReplaceMod) {
    Assert-OrdinaryPath $ModDirectory
    if ($ReplaceMod) {
        if (Test-Path -LiteralPath $ModDirectory -PathType Container) {
            $markers = @((Join-Path $ModDirectory '.PBZTestArenaShared-owner'), (Join-Path $active $integratedName))
            $verified = $false
            foreach ($marker in $markers) {
                if (!(Test-Path -LiteralPath $marker)) { continue }
                Assert-OrdinaryPath $marker
                if ([IO.File]::ReadAllText($marker).Trim() -cne $owner) {
                    Stop-PbzInstall 'MOD_OWNERSHIP_UNKNOWN' '已有同名 MOD，但归属和影境演武不同。请在原 MOD 管理器移除该项后再检查，或导出诊断。' $ModDirectory
                }
                $verified = $true
            }
            if ($verified -or !@(Get-ChildItem -LiteralPath $ModDirectory -Force).Count) { return }
            # Older manual installs may predate the ownership marker.
            $main = Join-Path $ModDirectory 'Scripts/main.lua'
            $barrier = Join-Path $ModDirectory 'Scripts/PBZSaveBarrier.dll'
            if ((Test-Path -LiteralPath $main -PathType Leaf) -and (Test-Path -LiteralPath $barrier -PathType Leaf)) {
                Assert-OrdinaryPath $main
                Assert-OrdinaryPath $barrier
                if ([IO.File]::ReadAllText($main) -match '\[PBZTestArena(?:Native)?\]') { return }
            }
        }
        Stop-PbzInstall 'MOD_OWNERSHIP_UNKNOWN' '发现同名文件或目录，无法确认是旧版演武。请用原 MOD 管理器移除它，或备份并移出 Mods 目录，再检查。' $ModDirectory
    }
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
        Assert-PbzInstalledRuntimeHash $entry.Name $entry.Value
    }
}

function Invoke-PbzSharedRuntime($Prior) {
    $mutex = New-Object Threading.Mutex($false,'Local\PBZTestArenaNativeSession')
    $held=$false; $run=$null
    $rollback = $null
    $loaderBridges = $null
    try {
        try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held=$true }
        if (!$held) { Stop-PbzInstall 'INSTALLER_BUSY' '另一个演武安装器或内测启动器正在运行。请先关闭它，再重试。' }
        Assert-NotRunning
        Assert-PbzOtherTransactions
        $script:pbzInstallerStage = 'receipt'
        $prior = Get-PreviousState -ForInstall:$Install
        $script:pbzInstallerStage = 'loader'
        if (!(Test-PbzSharedRuntime $prior)) {
            Stop-PbzInstall 'LOADER_CONFLICT' '共享加载器在检查后发生变化，请重新检查。'
        }
        $maps = New-PbzMapTransaction $prior $mapPayload
        $loaderBridges = New-PbzLoaderBridgeTransaction $prior $loaderBridgePayload
        if ($Install -and !$prior.installed) { Assert-PbzNoOtherInstallReceipt }
        if (Test-Path -LiteralPath $modDirectory) { Assert-PbzSharedMod $prior $modDirectory -ReplaceMod:$Install }
        elseif ($prior -and $prior.installed) {
            Assert-PbzMissingRuntimeReceipt $prior $true
        }
        if ($dependencies) { Assert-PbzSharedSnapshots $dependencies }
        Assert-PbzInstallAccess $true $maps $loaderBridges
        $script:pbzInstallerStage = 'backup'
        $stamp=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
        $operationName=if($Install){'SharedInstall'}else{'SharedUninstall'}
        $run = New-PbzBackupRun $stamp
        $script:pbzInstallerStage = 'stage'
        Start-PbzTransaction $run $operationName
        $rollback=Join-Path $run 'Replaced.sav'
        foreach($file in @($statePath,$privatePath)) {
            if(Test-Path -LiteralPath $file){Copy-NewFile $file (Join-Path $run ([IO.Path]::GetFileName($file)))}
        }
        $beforeHash=Get-Hash $save
        Copy-NewFile $save (Join-Path $run 'Before.sav')
        Assert-Hash (Join-Path $run 'Before.sav') $beforeHash
        if ($Install) {
            if ($checkpointFlow -eq 'compatibility') {
                $sourceHelper,$sourcePresets=$helper,$presets
                $transaction=Initialize-PbzToolWork
                $staging=Join-Path $transaction 'Staging';Ensure-Directory $staging
                $helper=Join-Path $transaction 'Tools/PBZSaveTool.exe'
                $presets=Join-Path $transaction 'PrivatePresets.pbzs'
                Copy-NewFile $sourceHelper $helper
                Copy-NewFile $sourcePresets $presets
                Assert-Hash $helper $toolBuild.sha256;Assert-Hash $presets $toolBuild.presetsSha256
                $pending=Join-Path $staging 'Pending.sav'
                $priorManifest=if($prior -and $prior.privateManifestSha256){$prior.verifiedPrivatePath}else{''}
                if ($epic) { $priorManifest = '' }
                $prepared=Invoke-SaveTool (Join-Path $run 'Before.sav') $pending $priorManifest
            } else { $prepared = New-PbzUnchangedSaveReport $beforeHash }
            $report=$prepared.report
            Initialize-PbzOwnedProfile
            $stage=Join-Path (Get-PbzTransactionWork) 'Mod'
            $hashes=New-PbzModStage $stage $true
            Assert-PbzSharedSnapshots $dependencies
            Assert-NotRunning
            if ($checkpointFlow -eq 'compatibility') {
                Add-PbzFileChange $save $report.sourceSha256 $report.outputSha256
                [void](Replace-Save $pending $save $report.sourceSha256 $report.outputSha256 $rollback)
            } else { Assert-Hash $save $beforeHash }
        }else{
            $report=[pscustomobject]@{sourceSha256=$beforeHash;outputSha256=$beforeHash}
            Assert-Hash $save $beforeHash
        }
        Assert-NotRunning
        Assert-Hash $game $actualGameHash
        $script:pbzInstallerStage = 'commit'
        Set-PbzMapTransaction $maps $run
        Set-PbzLoaderBridgeTransaction $loaderBridges $run
        if(Test-Path -LiteralPath $modDirectory){
            Assert-PbzSharedMod $prior $modDirectory -ReplaceMod:$Install
            $movedMod=Join-Path $run 'RuntimeBefore';Assert-Contained $movedMod $run
            Move-PbzTransactionPath $modDirectory $movedMod
        }
        if($Install){
            New-PbzTransactionDirectory (Split-Path -Parent $modDirectory)
            Move-PbzTransactionPath $stage $modDirectory
            foreach($entry in $hashes.GetEnumerator()){Assert-Hash (Join-Path $platform $entry.Key) $entry.Value}
            Assert-PbzSharedSnapshots $dependencies
            $privateReceipt = Set-PbzPrivateSaveReceipt $prepared $prior
            $state=[ordered]@{version=3;owner=$owner;installKind='shared-v1';installed=$true;
                installedAt=(Get-Date).ToUniversalTime().ToString('o');launcherRoot=$root;gameExe=$game;savePath=$save;
                profile=$profile;userSid=$UserSid;privateManifestSha256=$privateReceipt;mapFlow=$checkpointFlow;runtimeHashes=$hashes;
                sharedDependencies=$dependencies;mapHashes=$maps.Next;loaderBridgeHashes=$loaderBridges.Next;backup=$run;loaderRetained=$true;otherModsRetained=$true}
        }else{
            $state=[ordered]@{version=3;owner=$owner;installKind='shared-v1';installed=$false;
                uninstalledAt=(Get-Date).ToUniversalTime().ToString('o');privateManifestSha256=$prior.privateManifestSha256;
                savePath=$save;dedicatedSaveBlocksRetained=$true;reportsRetained=$true;loaderRetained=$true;otherModsRetained=$true;backup=$run}
        }
        Write-PbzTransactionText $statePath ($state | ConvertTo-Json -Depth 8)
        Assert-Hash $save $report.outputSha256
        if(Test-Path -LiteralPath $rollback){Assert-Hash $rollback $report.sourceSha256}
        Write-NewText (Join-Path $run 'Result.json') (([ordered]@{success=$true;operation=$operationName;installKind='shared-v1';
            sourceSha256=$report.sourceSha256;outputSha256=$report.outputSha256;loaderRetained=$true;otherModsRetained=$true;gameStarted=$false}) | ConvertTo-Json)
        Complete-PbzTransaction 'TransactionComplete.json'
        if (Test-Path -LiteralPath $rollback) { Remove-Item -LiteralPath $rollback -ErrorAction SilentlyContinue }
        Write-Output ($operationName+' completed. Existing UE4SS, configuration and other MODs retained. No game started.')
    } catch {
        $failure = $_
        Set-PbzTransactionFailure $failure $run
        throw $failure
    }finally{
        if($held){$mutex.ReleaseMutex()};$mutex.Dispose()
    }
}
