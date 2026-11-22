-- Pending installations expose only a title notice. Dispatch before loading
-- gameplay modules, registering keys/hooks, or inspecting any save subsystem.
do
    local info = type(debug) == "table" and type(debug.getinfo) == "function" and debug.getinfo(1, "S")
    local source = info and info.source
    local scripts = type(source) == "string" and source:sub(1, 1) == "@"
        and source:sub(2):match("^(.*)[/\\][^/\\]+$")
    local modRoot = scripts and scripts:match("^(.*)[/\\][^/\\]+$")
    if not modRoot or type(io) ~= "table" or type(io.open) ~= "function" then
        print("[PBZTestArenaNative] 演武入口暂未启用：无法确认本地配置，正常游戏不受影响。\n")
        return
    end
    local opened, marker, _, code = pcall(io.open, scripts .. "/CompatibilityPending.lua", "rb")
    if not opened or (not marker and code ~= 2) then
        print("[PBZTestArenaNative] 演武入口暂未启用：无法读取本地配置，正常游戏不受影响。\n")
        return
    end
    if marker then
        pcall(marker.close, marker)
        local loaded, entry = pcall(require, "PendingEntry")
        if loaded and type(entry) == "table" and type(entry.start) == "function" then
            local ok = pcall(entry.start, scripts)
            if not ok then print("[PBZTestArenaNative] 演武待适配提示暂不可用，正常游戏不受影响。\n") end
        else
            print("[PBZTestArenaNative] 演武待适配提示暂不可用，正常游戏不受影响。\n")
        end
        return
    end
end

-- Some UE4SS distributions keep their helpers elsewhere or omit this optional
-- Lua sidecar. Use their helper when available; keep our fallback MOD-local.
local helperLoaded, UE = pcall(require, "UEHelpers")
if not helperLoaded or type(UE) ~= "table" or UE.GetPlayerController == nil then
    UE = { GetPlayerController = function()
        local controllers = FindAllOf("PlayerController") or {}
        if #controllers == 0 then controllers = FindAllOf("Controller") or {} end
        for _, controller in ipairs(controllers) do
            local usable, accepted = pcall(function()
                if not controller:IsValid() then return false end
                local localOk, isLocal = pcall(function() return controller:IsLocalPlayerController() end)
                if localOk then return isLocal == true end
                local player = controller.Player
                local localClass = StaticFindObject("/Script/Engine.LocalPlayer")
                return player ~= nil and player:IsValid() and localClass ~= nil and localClass:IsValid()
                    and player:IsA(localClass) == true
            end)
            if usable and accepted then return controller end
        end
        return type(CreateInvalidObject) == "function" and CreateInvalidObject() or nil
    end }
end
local Health = require("Health")
local Panel = require("Panel")
local ClosedArena = require("ClosedArena")
local CombatSpawn = require("CombatSpawn")
local ArenaScenes = require("ArenaScenes")
local SceneArena = require("SceneArena")
local StockBellArena = require("StockBellArena")
local ShengQuXinChi = require("ShengQuXinChiArena")
local StockEvents = require("MeiGuHuOriginalEvents")
local stockArrivalWorld, stockReadyWorld, stockBossAddress
local XiguArena = require("XiguArena")
local MeiGuHuArena = require("MeiGuHuArena")
local XiguStreaming = require("XiguStreaming")
local DisplayPreferences = require("DisplayPreferences")
require("ModLoaderSettingsWrite").configure(debug.getinfo(1, "S").source)

local ARENA_LEVEL = "PBZ_Duanhun_WP"
local ADULT_CLASS = "BP_Renewal_Hun_C"
local SAVE_SEAL = "PBZTestArenaSeal"
local MANUAL_SEAL = "ManualSave947631"
local ENEMY_NAME = "BP_Monster_GoldMaskMan"
local ENEMY_PACKAGE = "/Game/RenewalContent/Actors/Mobs/Normal/" .. ENEMY_NAME
local ENEMY_CLASS = ENEMY_PACKAGE .. "." .. ENEMY_NAME .. "_C"
local ENEMY_CAPSULE_HALF_HEIGHT = 100  -- GoldMaskMan's cooked CollisionCylinder, cm
local ADJUST_IF_CLEAR = 3  -- ESpawnActorCollisionHandlingMethod
local MAX_TARGETS = 6
local HEAL_DELAY_SECONDS = 1.2
local SPAWN_OFFSETS = {
    { 325, 0 }, { 325, -200 }, { 325, 200 },
    { 525, 0 }, { 525, -200 }, { 525, 200 },
    { 325, -400 }, { 325, 400 },
}

local targets, selectedId, worldAddress = {}, nil, nil
local nextId, panelVisible = 1, true
local trainingMob, trainingBell, lastTrainingBellError
local trainingHealthMode, trainingAbilitySnapshot = "normal", nil
local updateTrainingBell
local statusPath, notice, playerController, lastPanelError, lastHudError
local enemyCycle = 0
local trainingSceneId = "night"
local lastPreparationMenuError
local perfSceneId, perfMode
local perfClock = os and type(os.clock) == "function" and os.clock
local sceneServiceAfter, perfSampling
local challenge, titleSession, pendingSettlement
local installedConfig, trainingSkillLevel, trainingSkillsApplied, trainingSkillPawnAddress
local trainingSkillMemory
local trainingPlayerCycle, trainingDifficultyMode, trainingDifficulty = 6, 3, nil
local loadoutMemoryPath, arenaServices, privateServiceScope
local servicesHooksReady,servicesAllowed=false,false
local serviceMapEpoch,serviceLoadDepth,servicePendingEpoch=0,0,nil
local expectedServiceSlot
local sealedServicesStarted=false
local pendingServiceCleanup,nextServiceCleanup={},0
local lastStatusHudError,statusHudFailedWorld
local statusHudActive
local Frost = require("FrostEvent")
local bossEntry, trainingPreload

local function log(message)
    print("[PBZTestArenaNative] " .. message .. "\n")
end

local function releaseTargetLock(target)
    if target.healthGuard then
        target.healthGuard:close()
        target.healthGuard = nil
    end
end

local function resetTrainingTargets()
    for _, target in ipairs(targets) do
        local ok, reason = pcall(releaseTargetLock, target)
        if not ok then log("清理测试目标锁血 #" .. target.id .. "：" .. tostring(reason)) end
    end
    targets, selectedId, worldAddress = {}, nil, nil
    trainingPreload = nil
end

local function closeTrainingBell()
    local bell = trainingBell
    trainingBell = nil
    if not bell then return end
    local ok, failure = pcall(bell.close, bell)
    if not ok then log("Training bell cleanup: " .. tostring(failure)) end
end

local function valid(object)
    return object ~= nil and object:IsValid()
end

local function text(value)
    if type(value) == "string" then return value end
    return value and value:ToString() or ""
end

local stableEngineObjects = {
    ["/Script/Engine.Default__KismetSystemLibrary"] = false,
    ["/Script/Engine.Default__GameplayStatics"] = false,
}
local function requiredObject(path)
    local cached = stableEngineObjects[path]
    if cached and valid(cached) then return cached end
    local object = StaticFindObject(path)
    assert(valid(object), "missing reflected object: " .. path)
    if cached ~= nil then stableEngineObjects[path] = object end
    return object
end

local function normalizedPath(value)
    local path = value:lower():gsub("\\", "/"):gsub("/+$", "")
    assert(not path:find("//", 1, true), "arena path has duplicate separators")
    for part in path:gmatch("[^/]+") do
        assert(part ~= "." and part ~= "..", "arena path has a relative segment")
    end
    return path
end

local function privateServicesGate(pawn)
    local scope=privateServiceScope
    if not servicesHooksReady or not servicesAllowed or not scope or not scope.active or not valid(pawn)
        or pawn:GetAddress()~=scope.pawn:GetAddress() then return false end
    if titleSession and not titleSession:allowArena()then return false end
    local world=SceneArena.runtimeWorld(pawn)
    if not valid(world)or world:GetAddress()~=scope.world then return false end
    return text(scope.gameplay:GetCurrentLevelName(pawn,true))==scope.map
        and text(pawn:GetClass():GetFName())==ADULT_CLASS
end
local function closeStatusHud(reason)
    statusHudActive = nil
    Frost.close(reason)
    local hud=package.loaded.StatusBuildupHud
    if type(hud)=="table" and type(hud.close)=="function" then pcall(hud.close) end
    statusHudFailedWorld=nil
end
local function closeArenaServices()
    closeStatusHud()
    if privateServiceScope then privateServiceScope.active=false end
    local old=arenaServices;arenaServices=nil
    if not old then return end
    if old.memory then pcall(old.memory.close,old.memory)end
    for _,service in ipairs({old.shuangYueCharge or false,old.summonAccess or false,old.economy or false,old.mapPolicy or false})do
        if service then
            local ok,closed=pcall(service.close,service)
            if not ok or closed~=true then pendingServiceCleanup[#pendingServiceCleanup+1]=service end
        end
    end
end
local function drainServiceCleanup()
    if #pendingServiceCleanup==0 or os.time()<nextServiceCleanup then return end
    nextServiceCleanup=os.time()+1
    local previous=pendingServiceCleanup;pendingServiceCleanup={}
    for _,service in ipairs(previous)do
        local ok,closed=pcall(service.close,service)
        if not ok or closed~=true then pendingServiceCleanup[#pendingServiceCleanup+1]=service end
    end
end
local function clearPhasePreload(run)
    if run then run.phasePreloadPlan, run.phasePreloadScope = nil, nil end
end

local function closeBossEntry()
    local old = bossEntry
    bossEntry = nil
    if not old then return end
    old.run.entryPreloadPlan = nil
    local ok, closed, failure = pcall(old.close, old)
    if not ok or not closed then
        pendingServiceCleanup[#pendingServiceCleanup + 1] = old
        log("Boss entry cover cleanup: " .. tostring(ok and failure or closed))
    end
end

local function prepareBossEntry(gameplay, system, pawn, world)
    local run = challenge
    if bossEntry and (bossEntry.run ~= run or not bossEntry:owns(pawn, world)
        or bossEntry.entry ~= run.entry or bossEntry.stage ~= run.stageIndex) then
        clearPhasePreload(bossEntry.run)
        closeBossEntry()
    end
    if not run or run.palace or run.status ~= "waiting" or run.boss or run.stageIndex ~= 1 then return true end
    local ok, ready = pcall(function()
        if not bossEntry then
            local prepareHookmanPhase = run.sceneId == "xigu" and run.mode == "practice"
                and run.entry.id == "gauntlet_hookman"
            local followingStage = prepareHookmanPhase and run.entry.stages[2] or nil
            bossEntry = require("BossEntryPreload").new(run, pawn, world, followingStage)
        end
        return bossEntry:update(gameplay, system, pawn, world)
    end)
    if not ok then
        log("Boss entry preload fallback: " .. tostring(ready))
        clearPhasePreload(run)
        closeBossEntry()
        return true
    end
    return ready
end

local function checkpointArenaServices(_,slot)
    closeArenaServices()
    servicesAllowed=false
    expectedServiceSlot=slot
end
local function rememberBellLoadout(pawn)
    if not arenaServices or not arenaServices.initialized then return false end
    local palace = challenge and challenge.palace
    local memory = palace and palace.loadout or arenaServices.memory
    return not memory or memory:remember(pawn) ~= nil
end

local function updateArenaServices(gameplay,pawn,scene,world,mapOnly)
    if not servicesHooksReady then return true end -- optional services fail closed
    if servicePendingEpoch and serviceMapEpoch<=servicePendingEpoch then return true end
    if not titleSession and not installedConfig and not sealedServicesStarted then
        servicesAllowed=true;sealedServicesStarted=true -- initial sealed isolated admission only
    end
    if not servicesAllowed then return true end
    servicePendingEpoch=nil
    privateServiceScope={active=true,pawn=pawn,world=world,map=scene.map,gameplay=gameplay}
    if arenaServices and (arenaServices.pawn~=pawn:GetAddress()or arenaServices.world~=world)then closeArenaServices();privateServiceScope.active=true end
    if not arenaServices then arenaServices={pawn=pawn:GetAddress(),world=world} end
    if not arenaServices.mapPolicyAttempted and not (challenge and challenge.palace) then
        arenaServices.mapPolicyAttempted=true
        local ok,mapPolicy,reason=pcall(function()return require("ArenaMapPolicy").only(pawn,nil,function()return privateServicesGate(pawn)end,"Character","System")end)
        if ok then arenaServices.mapPolicy=mapPolicy end
        if not ok or not mapPolicy then log("演武地图策略未启用："..tostring(ok and reason or mapPolicy))end
    end
    local realNow=gameplay:GetRealTimeSeconds(pawn)
    if arenaServices.mapPolicy and arenaServices.mapUpdatedAt~=realNow then
        arenaServices.mapUpdatedAt=realNow
        local ok,accepted,reason=pcall(arenaServices.mapPolicy.update,arenaServices.mapPolicy,pawn,realNow)
        if not ok or accepted==false then
            local closed,finished=pcall(arenaServices.mapPolicy.close,arenaServices.mapPolicy)
            if not closed or finished~=true then pendingServiceCleanup[#pendingServiceCleanup+1]=arenaServices.mapPolicy end
            arenaServices.mapPolicy=nil
            log("演武地图策略已停用："..tostring(ok and reason or accepted))
        end
    end
    if mapOnly then return true end
    if not arenaServices.shadowInventoryChecked then
        local ok, done, reason = pcall(require("ArenaLoadout").pruneUnavailableShadowWeapons, pawn, privateServicesGate)
        local deadline = arenaServices.shadowInventoryDeadline or (realNow + 5)
        arenaServices.shadowInventoryDeadline = deadline
        if ok and done == false and realNow < deadline then return false, reason end
        arenaServices.shadowInventoryChecked = true
        if not ok or not done then log("演武影之武装清理未完成：" .. tostring(ok and reason or done)) end
    end
    if realNow >= (arenaServices.nextSummonAccess or 0) then
        arenaServices.nextSummonAccess = realNow + 1
        local mode = challenge and challenge.mode or "training"
        if (mode == "training" or mode == "practice" or mode == "challenge") and not (challenge and challenge.palace) then
            local ok, failure = pcall(function()
                if not arenaServices.shuangYueCharge then
                    arenaServices.shuangYueCharge = require("ShuangYueCharge").new(mode, log)
                end
                arenaServices.shuangYueCharge:update()
            end)
            if not ok and failure ~= arenaServices.shuangYueError then
                log("双钺脱战煞气调整未生效 " .. tostring(failure))
            end
            arenaServices.shuangYueError = not ok and failure or nil
        end
        local ok, failure = pcall(function()
            if not arenaServices.summonAccess then
                arenaServices.summonAccess = require("ArenaSummonAccess").new(pawn, world, privateServicesGate)
            end
            arenaServices.summonAccess:update(pawn)
        end)
        if not ok and failure ~= arenaServices.summonError then log("演武召唤许可：" .. tostring(failure)) end
        arenaServices.summonError = not ok and failure or nil
    end
    if not arenaServices.initialized then
        arenaServices.initialized=true
        if loadoutMemoryPath and not (challenge and challenge.palace) then
            local projected = titleSession and titleSession.barrier and titleSession.barrier.projectedLoadout
            local ok,memory,reason=pcall(function()
                return require("ArenaLoadoutMemory").new(loadoutMemoryPath,privateServicesGate,log,projected)
            end)
            if ok then arenaServices.memory=memory end
            if not ok or not memory then log("配装记忆未启用，演武继续："..tostring(ok and reason or memory))end
        end
        local ok,economy=pcall(function()return require("ArenaEconomy").new(pawn,function()return privateServicesGate(pawn)end)end)
        if ok then arenaServices.economy=economy else log("演武意识尘埃服务未启用："..tostring(economy))end
    end
    if arenaServices.economy and realNow>=(arenaServices.nextEconomy or 0)then
        arenaServices.nextEconomy=realNow+1
        local ok,accepted,reason=pcall(arenaServices.economy.update,arenaServices.economy,pawn,realNow)
        if not ok or accepted==false then
            local closed,finished=pcall(arenaServices.economy.close,arenaServices.economy)
            if not closed or finished~=true then pendingServiceCleanup[#pendingServiceCleanup+1]=arenaServices.economy end
            arenaServices.economy=nil
            log("演武意识尘埃服务已停用："..tostring(ok and reason or accepted))
        end
    end
    if arenaServices.memory and arenaServices.memory.state == "pending" then
        local ok,accepted,reason=pcall(arenaServices.memory.update,arenaServices.memory,pawn)
        if not ok then
            pcall(arenaServices.memory.close,arenaServices.memory);arenaServices.memory=nil
            log("配装记忆本次停用，演武继续："..tostring(accepted))
        elseif accepted==false then return false,reason or "等待演武配装恢复"end
    end
    return true
end

local function requireArenaArgs(system)
    -- Steam can quote the whole argument or just the value. Tokenize without
    -- consuming the Windows path separators before checking exact switches.
    local commandLine = text(system:GetCommandLine())
    local flags, probeFlags, menuFlags, words, quoted = 0, 0, 0, {}, false
    local dirs, cycle, bossId, playerCycle, skillLevel, memory = {}, nil, nil, nil, nil,nil
    local function finishWord()
        local word = table.concat(words)
        words = {}
        if word:lower() == "-pbztestarenanative" then flags = flags + 1 end
        if word:lower() == "-pbzarenatitleprobe" then probeFlags = probeFlags + 1 end
        if word:lower() == "-pbzarenamenutest" then menuFlags = menuFlags + 1 end
        local name, value = word:match("^%-([%a]+)=(.*)$")
        if not name then return end
        name = name:lower()
        if name == "savegamesdir" or name == "userdir" then
            assert(dirs[name] == nil, "duplicate -" .. name)
            dirs[name] = normalizedPath(value)
        elseif name == "pbzarenaenemycycle" then
            assert(cycle == nil and value:match("^[0-6]$"), "invalid arena enemy cycle")
            cycle = tonumber(value)
        elseif name == "pbzarenachallenge" then
            assert(bossId == nil and value:match("^[%a%d_]+$"), "invalid challenge boss")
            bossId = value
        elseif name == "pbzarenaplayercycle" then
            assert(playerCycle == nil and value:match("^[0-6]$"), "invalid arena player cycle")
            playerCycle = tonumber(value)
        elseif name == "pbzarenaskilllevel" then
            assert(skillLevel == nil and value:match("^%d%d?$") and tonumber(value) <= 30, "invalid arena skill level")
            skillLevel = tonumber(value)
        elseif name=="pbzarenaloadoutmemory"then
            assert(memory==nil,"duplicate loadout memory path")
            memory=normalizedPath(value)
            assert(memory:match("/arenapreferences/pbzloadout%.tsv$"),"invalid loadout memory path")
        end
    end
    for char in commandLine:gmatch(".") do
        if char == '"' then
            quoted = not quoted
        elseif not quoted and char:match("%s") then
            if #words > 0 then finishWord() end
        else
            words[#words + 1] = char
        end
    end
    assert(not quoted, "malformed command line quotes")
    if #words > 0 then finishWord() end
    assert(flags == 1, "requires exactly one -PBZTestArenaNative")
    local saves = dirs.savegamesdir
    local profileKind = bossId and "challengearena" or "oldhousearena"
    assert(saves and saves:match("^[a-z]:/.+/" .. profileKind .. "/arenadata/savegames$"), "isolated arena SaveGamesDir required")
    assert(dirs.userdir == saves:gsub("/savegames$", "/profile"), "matching isolated UserDir required")
    assert(probeFlags == 0 or (probeFlags == 1 and not bossId
        and saves:match("/titleprobe/[^/]+/oldhousearena/arenadata/savegames$")), "isolated title probe path required")
    assert(menuFlags == 0 or (menuFlags == 1 and probeFlags == 1), "full menu requires the disposable title probe")
    if playerCycle ~= nil then
        local profile = require("PlayerProfile")
        skillLevel = profile.normalizeSkillLevel(playerCycle, skillLevel)
        assert(skillLevel == nil or skillLevel <= profile.skillCap(playerCycle), "invalid skill level for player cycle")
    end
    return dirs.userdir, cycle or 0, bossId, playerCycle, skillLevel, probeFlags == 1, menuFlags == 1,memory
end

local function sessionArgs(system)
    local ok, profile, cycle, bossId, playerCycle, skillLevel, probe, menu,memory = pcall(requireArenaArgs, system)
    if ok then return profile, cycle, bossId, playerCycle, skillLevel, probe, nil, menu,memory end
    local installed = require("Integration").load(system)
    if installed then return installed.profile, installed.defaultEnemyCycle, nil, nil, nil, true, installed,nil,installed.loadoutMemoryPath end
    error(profile, 0)
end

local function prepareSession(system)
    if statusPath then return end
    perfSampling = perfClock and StockEvents.performanceRequested(system)
    local profile, bossId, playerCycle, skillLevel, probe, fullMenu
    profile, enemyCycle, bossId, playerCycle, skillLevel, probe, installedConfig, fullMenu,loadoutMemoryPath = sessionArgs(system)
    if installedConfig then require("DreamPalacePressure").configure(installedConfig) end
    if fullMenu then
        installedConfig = { disposable = true, profile = profile, defaultPlayerCycle = 6,
            defaultEnemyCycle = enemyCycle, trainingSlot = "PBZArenaIntegratedTraining", cyclePrefix = "PBZArenaIntegratedCycle",loadoutMemoryPath=loadoutMemoryPath }
    end
    if bossId then
        local entry = assert(require("EncounterCatalog").resolve(bossId), "unknown challenge encounter")
        challenge = require("Challenge").new(entry, enemyCycle, profile, playerCycle, skillLevel,
            {loadoutMemoryPath=loadoutMemoryPath,onBeforeLoad=checkpointArenaServices,onBellSave=rememberBellLoadout})
    end
    if installedConfig then
        log("版本 2.0.3；平台=" .. (installedConfig.platform or "steam")
            .. "; 地图=单存点套用轮回; 测试场=" .. #ArenaScenes.list() .. "图自选杂兵; 主轮询=100ms; 双钺脱战保留煞气")
        local palacePath, palaceLoadoutPath = require("BloodyPalaceProgress").paths(profile, loadoutMemoryPath)
        local options = {
            integrated = true, disposable = installedConfig.disposable,
            trainingSlot = installedConfig.trainingSlot, cyclePrefix = installedConfig.cyclePrefix,
            savePath=installedConfig.savePath, platform=installedConfig.platform, diagnostics=installedConfig.diagnostics,
            loadoutMemoryPath=loadoutMemoryPath, palacePath = palacePath, palaceLoadoutPath = palaceLoadoutPath,
            onBeforeRestore=function()
                servicesAllowed,expectedServiceSlot=false,nil
                closeArenaServices()
                if challenge then challenge:closeMusic() end
                if challenge and challenge.palace then
                    local run = challenge
                    challenge = nil
                    run:close()
                end
            end,
            defaults = { playerCycle = installedConfig.defaultPlayerCycle, enemyCycle = installedConfig.defaultEnemyCycle,
                skillLevel = 5 * installedConfig.defaultPlayerCycle },
            onStart = function(settings, slot)
                settings.skillLevel = require("PlayerProfile").normalizeSkillLevel(settings.playerCycle, settings.skillLevel)
                closeArenaServices();servicesAllowed=true;expectedServiceSlot=slot
                if settings.mode == "bloody-palace" and package.loaded.ShuangYueCharge then
                    package.loaded.ShuangYueCharge.restore()
                end
                if challenge then challenge:close() end
                challenge = nil
                closeTrainingBell()
                resetTrainingTargets()
                trainingMob, trainingHealthMode, trainingAbilitySnapshot, panelVisible = nil, "normal", nil, true
                enemyCycle, trainingSkillLevel, trainingSkillsApplied = settings.enemyCycle, nil, false
                trainingSkillPawnAddress = nil
                trainingPlayerCycle, trainingDifficultyMode = settings.playerCycle, settings.difficultyMode or 3
                local selectedEncounter = settings.mode ~= "training" and settings.bossId or nil
                trainingSceneId = ArenaScenes.forEncounter(selectedEncounter, settings.sceneId, settings.mode).id
                local palace = settings.mode == "bloody-palace"
                local skillMemory
                if not palace and loadoutMemoryPath then
                    local ok, result = pcall(require("ArenaLoadoutMemory").skills, loadoutMemoryPath, privateServicesGate, log)
                    if ok then skillMemory = result else log("账号技能本次未启用：" .. tostring(result)) end
                end
                trainingSkillMemory = settings.mode == "training" and skillMemory or nil
                if settings.mode == "challenge" or settings.mode == "practice" or palace then
                    local entry = palace and require("BloodyPalaceProgress").floor(1)
                        or assert(require("EncounterCatalog").resolve(settings.bossId))
                    local memoryPath, beforeLoad = loadoutMemoryPath, checkpointArenaServices
                    if settings.palacePractice then memoryPath, beforeLoad = nil, nil end
                    challenge = require("Challenge").new(entry,
                        enemyCycle, profile, settings.playerCycle, settings.skillLevel,
                        { resetSlot = slot, cyclePrefix = installedConfig.cyclePrefix,
                            mode = settings.mode, difficultyMode = settings.difficultyMode or 3,
                            customPressure = settings.customPressure,
                            sceneId = trainingSceneId, musicId = settings.musicId,
                            loadoutMemoryPath=memoryPath,onBeforeLoad=beforeLoad,
                            skillMemory = skillMemory, onBellSave = rememberBellLoadout,
                            selectCheckpoint = function(targetSlot, cycle)
                                return titleSession:selectCheckpoint(targetSlot, cycle)
                            end,
                            onSceneChange = function(sceneId, gameplay, pawn)
                                if titleSession then titleSession:changeArenaScene(sceneId, gameplay, pawn) end
                            end })
                    if palace then
                        local dream = require("DreamPalaceProfile")
                        local runPath = dream.checkpoint(palacePath, settings.palaceTier)
                        if not settings.palacePractice and not dream.tier(settings.palaceTier).assist then
                            require("DreamPalaceAchievementToast").watch(palacePath, dream.earned)
                        end
                        local privateLoadout = not settings.palacePractice and not settings.palaceResume and settings.palaceLoadoutPath or nil
                        challenge.palace = require("BloodyPalace").new(runPath,
                            function() return titleSession and titleSession:allowArena() end,
                            function(menu) pendingServiceCleanup[#pendingServiceCleanup+1] = menu end,
                            privateLoadout, privateServicesGate,
                            { base = palacePath, tier = settings.palaceTier, practice = settings.palacePractice,
                                resume = settings.palaceResume, checkpoint = settings.palaceCheckpoint,
                                warmupEquipment = settings.warmupEquipment, projectedLoadout = titleSession.barrier.projectedLoadout,
                                returnToArenaMenu = function()
                                    if titleSession then titleSession:requestArenaMenu() end
                                end })
                        log(("浊梦档位=%s; playerCycle=%d; difficulty=%d; warmup=%s; resume=%s")
                            :format(settings.palaceTier, settings.playerCycle, settings.difficultyMode,
                                tostring(settings.palacePractice or "-"), tostring(settings.palaceResume == true)))
                    end
                else
                    trainingSkillLevel = settings.skillLevel
                    if settings.trainingMobId then
                        trainingMob = assert(require("TrainingTarget").resolve(settings.trainingMobId), "测试场目标无效")
                    end
                    log("Training settings: scene=" .. trainingSceneId .. "; target=" .. (trainingMob and trainingMob.id or "金面人"))
                end
                log("Integrated MOD mode=" .. settings.mode .. "; playerCycle=" .. settings.playerCycle
                    .. "; enemyCycle=" .. settings.enemyCycle .. "; skillLevel=" .. settings.skillLevel)
            end,
        }
        titleSession = require("TitleSession").new(profile, log, options)
    elseif probe then titleSession = require("TitleSession").new(profile, log) end
    statusPath = profile .. "/PBZTestArenaPanel.json"
end

local function requireNativeSeal(gameplay, pawn)
    if gameplay:DoesSaveGameExist(SAVE_SEAL, 0) then return end
    local subsystemLibrary = requiredObject("/Script/Engine.Default__SubsystemBlueprintLibrary")
    local saveClass = requiredObject("/Script/ProjectPBZ.PBZSaveLoadSubsystem")
    local saves = subsystemLibrary:GetGameInstanceSubsystem(pawn, saveClass)
    assert(valid(saves), "native save subsystem is unavailable")

    local continueOk, continue = pcall(function() return text(saves:GetContinueSlotName()) end)
    if continueOk and continue == MANUAL_SEAL then return end
    local summaries = saves:GetManualSaveSummariesSorted()
    assert(summaries, "native manual save summaries are unavailable")
    for index = 1, #summaries do
        local row = summaries[index]
        if row and text(row.SlotName) == MANUAL_SEAL then return end
    end
    error("isolated native save seal is absent")
end

local function arenaContext(serveMenu)
    local system = requiredObject("/Script/Engine.Default__KismetSystemLibrary")
    prepareSession(system)
    assert(not titleSession or titleSession:allowArena(), "use MOD from the isolated title probe menu")
    local gameplay = requiredObject("/Script/Engine.Default__GameplayStatics")
    if not valid(playerController) then playerController = UE.GetPlayerController() end
    assert(valid(playerController), "load the isolated arena save first")
    local pawn = gameplay:GetPlayerPawn(playerController, 0)
    assert(valid(pawn), "load the isolated arena save first")
    local level = text(gameplay:GetCurrentLevelName(pawn, true))
    local scene = challenge and challenge.scene or ArenaScenes.get(trainingSceneId)
    local stock = titleSession and installedConfig and scene.originalPath
    assert(stock or (scene.id == "night" and not installedConfig), "此演武场景未获得原版存点许可")
    assert(level == scene.map, "requires " .. scene.map .. "; current level: " .. level)
    local class = pawn:GetClass():GetFName():ToString()
    assert(class == ADULT_CLASS, "requires adult Hun; current pawn: " .. class)
    if not installedConfig then requireNativeSeal(gameplay, pawn) end
    local actualWorld = SceneArena.runtimeWorld(pawn)
    assert(valid(actualWorld), "等待角色的真实运行世界")
    local activeWorld = actualWorld:GetAddress()
    if stock and stockArrivalWorld ~= activeWorld then
        local entered, why = StockEvents.arrive(actualWorld)
        assert(entered, why)
        local at, anchor = pawn:K2_GetActorLocation(), scene.anchor
        assert((at.X - anchor.X)^2 + (at.Y - anchor.Y)^2 + (at.Z - anchor.Z)^2 <= 800^2,
            "等待" .. scene.name .. "原版存点附近的角色")
        stockArrivalWorld = activeWorld
        log(("Stock arena arrival scene=%s bell=%s"):format(scene.id, scene.bellSaveId))
    end
    local bossClassesReady = not serveMenu or not stock or prepareBossEntry(gameplay, system, pawn, actualWorld)
    local bossCoverVisible = bossEntry and bossEntry.cover ~= nil
    -- Input policy needs only the protected private world, not boss-ground or
    -- equipment readiness. It must cover the preparation interval as well.
    updateArenaServices(gameplay,pawn,scene,activeWorld,true)
    if worldAddress ~= activeWorld then
        resetTrainingTargets()
        worldAddress = activeWorld
    end
    perfSceneId, perfMode = scene.id, challenge and (challenge.mode or "challenge") or "training"
    local now = gameplay:GetTimeSeconds(pawn)
    -- Unbind the world soundtrack before scene triggers or boss spawning run.
    if serveMenu and challenge then challenge:updateMusic(gameplay, pawn, gameplay:GetRealTimeSeconds(pawn)) end
    local training = not challenge and installedConfig ~= nil and titleSession ~= nil
    local allowBell = training or (challenge ~= nil and challenge:canUseBell())
    local ready, reason
    if scene.id == "xigu" then
        local realNow = gameplay:GetRealTimeSeconds(pawn)
        local palace = challenge and challenge.palace
        local shot = palace and (palace.ending or palace.gateScene)
        if serveMenu and palace and palace.performance then
            palace.performance:update(system, activeWorld, realNow, palace, challenge, XiguStreaming.isActive())
        end
        ready, reason = XiguArena.update(gameplay, system, pawn, playerController, actualWorld, realNow, scene,
            allowBell, palace ~= nil)
        if palace then
            XiguStreaming.update(gameplay, actualWorld, pawn, playerController, realNow, ready == true, shot and shot.camera)
        end
    elseif scene.id == "meiguhu" then
        ready, reason = MeiGuHuArena.update(gameplay, system, pawn, playerController, actualWorld,
            gameplay:GetRealTimeSeconds(pawn), scene, allowBell)
    elseif scene.id == "leidang" then
        ready, reason = ShengQuXinChi.update(gameplay, system, pawn, playerController, actualWorld,
            gameplay:GetRealTimeSeconds(pawn), scene, allowBell)
    elseif stock then
        ready, reason = StockBellArena.update(gameplay, system, pawn, playerController, actualWorld,
            gameplay:GetRealTimeSeconds(pawn), scene, allowBell)
    else
        ready, reason = ClosedArena.update(pawn, playerController, activeWorld, now, function(actor)
            if challenge and challenge:owns(actor) then return true end
            for _, target in ipairs(targets) do
                if valid(target.actor) and target.actor:GetAddress() == actor:GetAddress() then return true end
            end
            return false
        end, allowBell)
    end
    if stock and scene.id ~= "meiguhu" then
        if ready and stockReadyWorld ~= activeWorld then
            stockReadyWorld = activeWorld
            StockEvents.ready()
        end
        if stockReadyWorld == activeWorld and StockEvents.isSampling() then
            StockEvents.update(system, gameplay:GetRealTimeSeconds(pawn))
        end
    end
    if not ready and serveMenu and challenge and not bossCoverVisible
        and (not scene.runtimeModule or require(scene.runtimeModule).getBell()) then
        -- The original bell UI must remain usable while streaming or optional
        -- anchor calibration waits. This path never spawns or advances combat.
        local served, failure = pcall(challenge.updateMenuOnly, challenge, gameplay, system, pawn, now)
        if not served and failure ~= lastPreparationMenuError then log("Pending-scene bell menu: " .. tostring(failure)) end
        lastPreparationMenuError = not served and failure or nil
    end
    if not ready and serveMenu and training then updateTrainingBell(gameplay, pawn, scene) end
    assert(ready, reason or "训练场正在准备")
    local configured,configurationReason=updateArenaServices(gameplay,pawn,scene,activeWorld)
    if not configured and serveMenu and challenge and not bossCoverVisible then
        pcall(challenge.updateMenuOnly,challenge,gameplay,system,pawn,now)
    end
    if not configured and serveMenu and training then updateTrainingBell(gameplay, pawn, scene) end
    assert(configured,configurationReason or "等待演武配装初始化")
    return gameplay, system, pawn, now, bossClassesReady
end

local function selected()
    for index, target in ipairs(targets) do
        if target.id == selectedId then return target, index end
    end
    return nil, nil
end

local function report(message)
    notice = message
    log(message)
end

local function selectTrainingTarget(settings)
    local mobId = settings.trainingMobId
    local mob = mobId and assert(require("TrainingTarget").resolve(mobId), "测试对象无效")
    trainingMob = mob or nil
    if titleSession then titleSession:rememberTrainingTarget(mobId) end
    report("测试对象：" .. (trainingMob and trainingMob.name or "金面人"))
end

updateTrainingBell = function(gameplay, pawn, scene)
    local ok, active = pcall(function()
        if not trainingBell or not valid(trainingBell.pawn) or trainingBell.pawn:GetAddress() ~= pawn:GetAddress() then
            closeTrainingBell()
            trainingBell = require("TrainingBell").new(pawn, playerController)
        end
        local bell = require(scene.runtimeModule).getBell()
        local handled = trainingBell:update(gameplay, scene, bell, trainingMob and trainingMob.id, selectTrainingTarget,
            trainingSkillsApplied and trainingSkillPawnAddress == pawn:GetAddress())
        if trainingBell.abilitySnapshot then
            trainingAbilitySnapshot = trainingBell.abilitySnapshot
            if trainingSkillMemory then
                trainingSkillMemory:remember(pawn, trainingBell.abilityBefore, trainingAbilitySnapshot)
            end
            trainingBell.abilityBefore, trainingBell.abilitySnapshot = nil, nil
        end
        if arenaServices then
            if not handled then arenaServices.bellLoadoutHandled = nil
            elseif not arenaServices.bellLoadoutHandled then
                arenaServices.bellLoadoutHandled = rememberBellLoadout(pawn)
            end
        end
        return handled
    end)
    if not ok then
        closeTrainingBell()
        if active ~= lastTrainingBellError then log("Training bell: " .. tostring(active)) end
    end
    lastTrainingBellError = not ok and active or nil
    return ok and active
end

local function publish(mode, message, palace, combatHud)
    if not statusPath then return end
    local rows = {}
    if mode == "ready" then
        for _, target in ipairs(targets) do
            rows[#rows + 1] = {
                id = target.id, level = target.level, health = target.health, maxHealth = target.maxHealth,
                ai = target.running, engaging = target.engagement ~= nil, alive = true,
                name = target.mob and target.mob.name or "金面人",
            }
        end
    end
    local snapshot = {
        maxTargets = MAX_TARGETS, selectedId = selectedId,
        autoheal = trainingHealthMode ~= "normal", healthMode = trainingHealthMode, enemyCycle = enemyCycle,
        trainingTarget = trainingMob and trainingMob.name or "金面人",
        mode = mode, visible = not challenge and panelVisible, message = message or notice, targets = rows,
        training = challenge == nil, challenge = challenge ~= nil, palace = palace, combatHud = combatHud,
    }
    if installedConfig then
        local drawn, failure = pcall(function() require("TrainingHud").update(playerController, snapshot) end)
        if not drawn and failure ~= lastHudError then log("training HUD: " .. tostring(failure)) end
        lastHudError = not drawn and failure or nil
    end
    local ok, saved, err = pcall(Panel.publish, statusPath, snapshot)
    if not ok or not saved then
        local failure = tostring(ok and err or saved)
        if failure ~= lastPanelError then log("panel: " .. failure) end
        lastPanelError = failure
    else
        lastPanelError = nil
    end
end

local function openFloor(system, pawn, position, x, y, allowObjectTrace)
    for _, target in ipairs(targets) do
        if valid(target.actor) then
            local other = target.actor:K2_GetActorLocation()
            if (x - other.X)^2 + (y - other.Y)^2 < 165^2 then return nil end
        end
    end
    local top = { X = x, Y = y, Z = position.Z + 180 }
    local bottom = { X = x, Y = y, Z = position.Z - 180 }
    local floor, noColor = {}, { R = 0, G = 0, B = 0, A = 0 }
    -- UE4SS's official LineTraceMod passes an empty Lua table for FHitResult.
    local hit = system:LineTraceSingle(pawn, top, bottom, 0, false, {}, 0, floor, true, noColor, noColor, 0.0)
    if allowObjectTrace and not hit then
        hit = system:LineTraceSingleForObjects(pawn, top, bottom, { 0 }, false, {}, 0, floor, true, noColor, noColor, 0.0)
    end
    if hit and floor.ImpactPoint and floor.ImpactNormal and floor.ImpactNormal.Z >= 0.65 then
        local point = floor.ImpactPoint
        return { X = point.X, Y = point.Y, Z = point.Z }
    end
end

local function applyTargetLock(target)
    target.healthGuard = target.healthGuard or require("EnemyHealthGuard").new(target.actor)
    target.healthGuard:enable()
end

local function prepareTrainingTarget(gameplay, pawn)
    local path = trainingMob and trainingMob.classPath or ENEMY_CLASS
    local preload = trainingPreload
    if preload and preload.path == path and preload.finished then return end
    if gameplay:IsGamePaused(pawn) then return end
    local realNow = gameplay:GetRealTimeSeconds(pawn)
    if not preload or preload.path ~= path then
        preload = { path = path, deadline = realNow + 2 }
        trainingPreload = preload
    end
    local ok, ready = pcall(function()
        preload.plan = preload.plan or require("SpawnClass").preload({ trainingMob or { classPath = path } })
        return preload.plan:step()
    end)
    if not ok then log("Training target preload: " .. tostring(ready)) end
    preload.finished = not ok or ready or realNow >= preload.deadline
end

local function spawnPaused(gameplay, system, pawn, now)
    assert(#targets < MAX_TARGETS, "测试单位已满（" .. MAX_TARGETS .. "）")
    local mob, class = trainingMob
    local path = mob and mob.classPath or ENEMY_CLASS
    local preload = trainingPreload
    local reason
    if preload and preload.path == path and preload.plan then
        class, reason = preload.plan:resolve(path)
    elseif mob then
        class, reason = require("SpawnClass").resolve(mob.classPath)
    end
    if not valid(class) and not mob then
        class = CombatSpawn.class(ENEMY_CLASS)
    end
    if not valid(class) then return false, reason end
    local mathLibrary = requiredObject("/Script/Engine.Default__KismetMathLibrary")
    local spawner = requiredObject("/Script/SGameAI.Default__SGameAIFunctionLibrary")
    local origin = pawn:K2_GetActorLocation()
    local position = { X = origin.X, Y = origin.Y, Z = origin.Z }
    local forward = pawn:GetActorForwardVector()
    local forwardX, forwardY = forward.X, forward.Y
    local name = mob and mob.name or "金面人"
    local scene = ArenaScenes.get(trainingSceneId)
    local target = { id = nextId, running = false, lastDamage = now, mob = mob }
    local deferred
    local ok, spawned, reason = pcall(function()
        local transform, ground, rotation
        local scale = { X = 1, Y = 1, Z = 1 }
        local halfHeight = mob and 180 or ENEMY_CAPSULE_HALF_HEIGHT
        for _, offset in ipairs(SPAWN_OFFSETS) do
            local distance = offset[1] + (mob and 150 or 0)
            local x = position.X + forwardX * distance - forwardY * offset[2]
            local y = position.Y + forwardY * distance + forwardX * offset[2]
            ground = openFloor(system, pawn, position, x, y, mob ~= nil or scene.spawnTrace.worldStaticFallback)
            if ground then
                local location = { X = ground.X, Y = ground.Y, Z = ground.Z + halfHeight + 5 }
                rotation = { Pitch = 0, Yaw = mathLibrary:FindLookAtRotation(location, position).Yaw, Roll = 0 }
                transform = mathLibrary:MakeTransform(location, rotation, scale)
                deferred = spawner:SpawnActorDeferred(pawn, class, transform, ADJUST_IF_CLEAR)
                if valid(deferred) then break end
            end
        end
        if not valid(deferred) then return false, "前方没有足够的平地，请换个方向或位置" end
        local mechanics
        if mob then
            local capsule = deferred.CapsuleComponent
            if valid(capsule) then
                local location = { X = ground.X, Y = ground.Y, Z = ground.Z + capsule:GetScaledCapsuleHalfHeight() + 6 }
                transform = mathLibrary:MakeTransform(location, rotation, scale)
            end
            mechanics = require("BloodyPalaceMechanics")
            mechanics.prepareAppearance(deferred, mob.id)
        end
        target.actor, target.level = CombatSpawn.finish(gameplay, pawn, deferred, transform, enemyCycle, mob ~= nil)
        deferred = nil
        if mob then
            CombatSpawn.clearStoryFlow(target.actor)
            mechanics.stabilizeAppearance(target.actor, mob.id)
        end
        if trainingHealthMode == "lock" then applyTargetLock(target) end
        return true
    end)
    if not ok then
        pcall(releaseTargetLock, target)
        local actor = target.actor or deferred
        if valid(actor) then pcall(CombatSpawn.destroyMobGroup, { actor }) end
        error(spawned, 0)
    end
    if not spawned then return false, reason end
    targets[#targets + 1] = target
    selectedId, nextId = nextId, nextId + 1
    log(("Training spawn: %s; target=#%d; cycle=%d; level=%g; healthMode=%s"):format(
        mob and (mob.id .. " " .. name) or name, selectedId, enemyCycle, target.level, trainingHealthMode))
    report(string.format("已生成%s #%d，AI 已暂停", name, selectedId))
    return true
end

local function toggleAI(_, _, _, now)
    local target = assert(selected(), "请先按 F8 生成测试单位")
    if not target.running and target.mob then
        target.engagement = { deadline = now + 8 }
    else
        CombatSpawn.challengeAI(target.actor, not target.running)
        target.engagement = nil
    end
    target.running = not target.running
    report("#" .. target.id .. (target.engagement and " 正在接战" or target.running and " 已恢复 AI" or " 已暂停 AI"))
end

local function removeTarget(index)
    local target = table.remove(targets, index)
    if target.id == selectedId then
        local nextTarget = targets[index] or targets[#targets]
        selectedId = nextTarget and nextTarget.id or nil
    end
    return target
end

local function clearSelected()
    local target, index = selected()
    assert(target, "当前没有可清除的测试单位")
    releaseTargetLock(target)
    CombatSpawn.destroyMobGroup({ target.actor })
    removeTarget(index)
    report("已清除测试单位 #" .. target.id)
end

local function nextTarget()
    assert(#targets > 0, "当前没有测试单位")
    local _, index = selected()
    selectedId = targets[(index or 0) % #targets + 1].id
    report("已选中测试单位 #" .. selectedId)
end

local function cycleTrainingHealth(now)
    local nextMode = ({ normal = "regen", regen = "lock", lock = "normal" })[trainingHealthMode]
    local action = nextMode == "lock" and applyTargetLock or releaseTargetLock
    local ok, reason = pcall(function()
        for _, target in ipairs(targets) do action(target) end
    end)
    if not ok then
        local rollback = trainingHealthMode == "lock" and applyTargetLock or releaseTargetLock
        for _, target in ipairs(targets) do
            local restored, err = pcall(rollback, target)
            if not restored then log("恢复测试目标锁血 #" .. target.id .. "：" .. tostring(err)) end
        end
        error("切换测试目标生命模式失败：" .. tostring(reason), 0)
    end
    trainingHealthMode = nextMode
    for _, target in ipairs(targets) do target.lastDamage = now end
    report(({ normal = "生命：正常", regen = "生命：自动回血", lock = "生命：锁血＋回血" })[nextMode])
end

local function updateTargets(now, gameplay, pawn)
    for index = #targets, 1, -1 do
        local target = targets[index]
        if not valid(target.actor) then
            removeTarget(index)
            report("测试单位 #" .. target.id .. " 已离场")
        else
            local readOk, health, maxHealth, dead = pcall(Health.read, target.actor)
            if not readOk then
                if target.readError ~= health then log("health #" .. target.id .. ": " .. tostring(health)) end
                target.readError, target.health, target.maxHealth = health, nil, nil
            elseif dead then
                -- Keep stock death and execution animations; release the active slot immediately.
                local released, reason = pcall(releaseTargetLock, target)
                if not released then log("清理死亡目标锁血 #" .. target.id .. "：" .. tostring(reason)) end
                removeTarget(index)
                report("测试单位 #" .. target.id .. " 已死亡，位置已释放")
            elseif health and maxHealth then
                local engagement = target.engagement
                if engagement and now >= (engagement.nextCheck or 0) then
                    engagement.nextCheck = now + .25
                    local ok, started, reason = pcall(require("EncounterEngage").start, target.actor, pawn,
                        engagement, gameplay:GetRealTimeSeconds(pawn))
                    if ok and started then
                        target.engagement = nil
                        report("#" .. target.id .. " 已恢复 AI")
                    elseif not ok or now >= engagement.deadline then
                        target.engagement = nil
                        local stopped = pcall(CombatSpawn.challengeAI, target.actor, false)
                        if stopped then target.running = false end
                        report("目标 #" .. target.id .. " 接战失败：" .. tostring(ok and reason or started))
                    end
                end
                target.readError = nil
                if target.health and health < target.health then target.lastDamage = now end
                if trainingHealthMode ~= "normal" and health < maxHealth and now - target.lastDamage >= HEAL_DELAY_SECONDS then
                    local healOk, healed, reason, restored, restoredMax = pcall(Health.restore, target.actor, maxHealth, health)
                    if healOk and healed then
                        health, maxHealth = restored or maxHealth, restoredMax or maxHealth
                        target.healError = nil
                    elseif not healOk or reason == "stock full-health effect did not restore the enemy" then
                        local failure = tostring(healOk and reason or healed)
                        if failure ~= target.healError then log("auto-heal #" .. target.id .. ": " .. failure) end
                        target.healError = failure
                    end
                    target.lastDamage = now
                end
                target.health, target.maxHealth = health, maxHealth
            end
        end
    end
end

local function arenaKeyHandler(label, action)
    return function()
        local ready = false
        local ok, err = pcall(function()
            prepareSession(requiredObject("/Script/Engine.Default__KismetSystemLibrary"))
            if challenge then
                if challenge.mode == "practice" then
                    local gameplay, _, pawn = arenaContext()
                    local applied, reason = challenge:practiceKey(label, gameplay, pawn)
                    if applied == false and reason then log("Practice " .. label .. ": " .. tostring(reason)) end
                end
                return
            end
            if not action then return end
            local gameplay, system, pawn, now = arenaContext()
            ready = true
            if trainingBell and trainingBell:blocksKeys() then return end
            updateTargets(now, gameplay, pawn)
            action(gameplay, system, pawn, now)
        end)
        if challenge then
            if not ok and challenge.mode == "practice" then
                local message = tostring(err):gsub("^.-:%d+: ", "", 1)
                log("Practice " .. label .. " failed: " .. message)
            end
            return
        end
        if not action then return end
        if ok then publish("ready")
        else
            local message = tostring(err):gsub("^.-:%d+: ", "", 1)
            log(label .. ": " .. message)
            publish(ready and "ready" or "waiting", message)
        end
    end
end

local arenaKeys = {
    { name = "F5", action = nextTarget },
    { name = "F6", action = function(_, _, _, now) cycleTrainingHealth(now) end },
    { name = "F7", action = function() panelVisible = not panelVisible end },
    { name = "F8", action = function(gameplay, system, pawn, now)
        local ok, reason = spawnPaused(gameplay, system, pawn, now)
        assert(ok, reason)
    end },
    { name = "F9", action = toggleAI },
    { name = "F10", action = clearSelected, trainingOnly = true },
}

local modifierNames = { "LeftShift", "RightShift", "LeftControl", "RightControl", "LeftAlt", "RightAlt" }
local modifierKeys
local arenaKeyInput

local function stopArenaKeys()
    local input = arenaKeyInput
    arenaKeyInput = nil
    if input and input.handle then pcall(CancelDelayedAction, input.handle) end
end

local function currentArenaKeyMode()
    if not challenge then return "training" end
    if challenge.mode == "practice" then return "practice" end
end

local function streamingKeyAvailable()
    return titleSession ~= nil and titleSession.scene ~= nil and titleSession.scene.id == "xigu"
        and challenge ~= nil and not not challenge.palace
end

local function modifierDown(controller)
    if not modifierKeys then
        modifierKeys = {}
        for index, name in ipairs(modifierNames) do modifierKeys[index] = { KeyName = FName(name) } end
    end
    for _, key in ipairs(modifierKeys) do
        if controller:IsInputKeyDown(key) then return true end
    end
    return false
end

local function keyDown(controller, key)
    return controller:IsInputKeyDown(key) or controller:WasInputKeyJustPressed(key)
end

local function readArenaKeys(input)
    if arenaKeyInput ~= input then return end
    local controller = input.controller
    if playerController ~= controller or titleSession ~= input.session or challenge ~= input.run
        or (titleSession and not titleSession:allowArena()) or not valid(controller)
        or (input.mode and currentArenaKeyMode() ~= input.mode)
        or streamingKeyAvailable() ~= input.streaming then
        stopArenaKeys()
        return
    end

    for _, key in ipairs(input.keys) do
        if arenaKeyInput ~= input then return end
        local ok, down = pcall(keyDown, controller, key.value)
        if ok then
            local pressed = key.armed and down
            key.armed, key.error = not down, nil
            if pressed then
                local fired, failure = pcall(function()
                    if not modifierDown(controller) then key.press() end
                end)
                if not fired then log(key.name .. ": " .. tostring(failure)) end
            end
        else
            if down ~= key.error then log(key.name .. " input: " .. tostring(down)) end
            key.error, key.armed = down, false
        end
    end
end

local function scheduleArenaKeys(input)
    if type(CancelDelayedAction) ~= "function" then return end
    local function tick() readArenaKeys(input) end
    local ok, handle
    if EngineTickAvailable and type(LoopInGameThreadAfterFrames) == "function" then
        ok, handle = pcall(LoopInGameThreadAfterFrames, 1, tick)
    end
    if not ok or type(handle) ~= "number" or handle <= 0 then
        ok, handle = pcall(LoopInGameThreadWithDelay, 4, tick)
    end
    if ok and type(handle) == "number" and handle > 0 then input.handle = handle end
end

local function syncArenaKeys(ready)
    local mode = ready and currentArenaKeyMode() or nil
    local streaming = streamingKeyAvailable()
    if (not mode and not streaming) or not valid(playerController)
        or (titleSession and not titleSession:allowArena()) then
        stopArenaKeys()
        return
    end

    local input = arenaKeyInput
    if input and input.controller == playerController and input.session == titleSession and input.run == challenge
        and input.mode == mode and input.streaming == streaming then
        if not input.handle then readArenaKeys(input) end
        return
    end

    stopArenaKeys()
    local keys = {}
    local function add(name, press)
        keys[#keys + 1] = { name = name, press = press, value = { KeyName = FName(name) } }
    end
    if streaming then add("F1", XiguStreaming.toggle) end
    if mode == "practice" then
        local key = require("PracticeHud").toggleKey
        add(key, arenaKeyHandler(key))
    end
    if mode then
        for _, key in ipairs(arenaKeys) do
            if mode == "training" or not key.trainingOnly then
                add(key.name, arenaKeyHandler(key.name, key.action))
            end
        end
    end
    input = { controller = playerController, session = titleSession, run = challenge,
        mode = mode, streaming = streaming, keys = keys }
    arenaKeyInput = input
    -- Arm each key after it is released in this session.
    readArenaKeys(input)
    if arenaKeyInput == input then scheduleArenaKeys(input) end
end

local combatHudSession

local function closeCombatHud(reason)
    local session = combatHudSession
    if not session then return end
    combatHudSession = nil
    if session.timer then session.timer:stop(reason) end
    if session.hud then pcall(session.hud.close) end
end

local function combatHudPalace(run)
    local palace = run and run.palace
    if not palace or not palace.arenaEntered or palace.closed or palace.ending or palace.state == "result"
        or run.status == "error" or run.reloadAt or run.reloadRequested
        or (palace.state == "combat" and not run.startedAt and not palace.fade) then return end
    return palace
end

local function drawCombatHud(session, gameNow)
    local at = os.clock()
    if session.retryAt and at < session.retryAt then return false end
    local ok, shown = pcall(function()
        session.hud = session.hud or require("DreamPalaceCombatHud")
        local pawn, gameplay = session.pawn, session.gameplay
        local snapshot = session.palace:battleHud(session.run, gameNow or gameplay:GetTimeSeconds(pawn))
        return session.hud.update(session.controller, snapshot, gameplay:GetRealTimeSeconds(pawn))
    end)
    if not ok then
        if session.hud then pcall(session.hud.close) end
        local message = tostring(shown)
        if session.lastError ~= message then log("Dream Palace combat HUD: " .. message) end
        session.lastError, session.retryAt = message, at + 1
        return false
    end
    session.lastError, session.retryAt = nil, nil
    return shown == true
end

local function syncCombatHud(run, gameplay, now)
    local palace = combatHudPalace(run)
    if not palace or not valid(playerController) or not valid(palace.pawn) then
        closeCombatHud("view closed")
        return
    end
    local session = combatHudSession
    if session and (session.run ~= run or session.palace ~= palace or session.pawn ~= palace.pawn
        or session.controllerAddress ~= playerController:GetAddress()) then
        closeCombatHud("view owner changed")
        session = nil
    end
    if not session then
        session = { run=run, palace=palace, pawn=palace.pawn, gameplay=gameplay, controller=playerController,
            controllerAddress=playerController:GetAddress() }
        combatHudSession = session
    end
    if session.timer or not drawCombatHud(session, now) or session.timerUnavailable then return end
    local timer, reason = require("UiUpdateTimer").start("palace-combat-hud", function()
        if combatHudSession ~= session then return false end
        if challenge ~= run or combatHudPalace(run) ~= palace or palace.pawn ~= session.pawn
            or not valid(session.pawn) or not valid(playerController)
            or playerController:GetAddress() ~= session.controllerAddress
            or (titleSession and not titleSession:allowArena()) then
            closeCombatHud("view owner left")
            return false
        end
        -- Hidden or unmounted views fall back to their existing owner tick
        -- until visible. Keep the mounted view to retain animation position.
        return drawCombatHud(session)
    end, function(reason)
        session.timer = nil
        if reason == "callback error" then
            if session.hud then pcall(session.hud.close) end
            session.retryAt = os.clock() + 1
        end
    end)
    session.timer = timer
    if not timer then
        session.timerUnavailable = true
        log("Dream Palace combat HUD ticker: " .. tostring(reason))
    end
end

local function installServiceLoadGuards()
    if type(RegisterHook)~="function"then log("演武配装/经济服务未启用：缺少原生载档前守卫");return end
    local installed,outerSlot={},nil
    local function slotName(value)
        local ok,result=pcall(function()
            if type(value)=="table"or type(value)=="userdata"then
                if type(value.get)=="function"then value=value:get()end
            end
            return type(value)=="string"and value or value and value:ToString()
        end)
        return ok and result or nil
    end
    local function before(_,slot)
        -- Disable the live guard before touching any native/cache boundary.
        if privateServiceScope then privateServiceScope.active=false end
        if serviceLoadDepth==0 then
            local ticket=expectedServiceSlot;expectedServiceSlot=nil
            sealedServicesStarted=true -- a real load must use its explicit private-slot ticket
            servicesAllowed=false
            outerSlot=slotName(slot)
            closeArenaServices()
            if challenge and challenge.palace then pcall(challenge.palace.closeLoadoutMemory, challenge.palace) end
            servicePendingEpoch=serviceMapEpoch
            servicesAllowed=ticket~=nil and outerSlot==ticket
        elseif slotName(slot)~=outerSlot then servicesAllowed=false end
        serviceLoadDepth=serviceLoadDepth+1
    end
    local function after()serviceLoadDepth=math.max(0,serviceLoadDepth-1)end
    for _,path in ipairs({"/Script/ProjectPBZ.PBZGameInstance:LoadGame","/Script/ProjectPBZ.PBZSaveLoadSubsystem:LoadGame"})do
        local ok,pre,post=pcall(RegisterHook,path,before,after)
        if not ok or not pre or not post then
            for _,hook in ipairs(installed)do pcall(UnregisterHook,hook.path,hook.pre,hook.post)end
            log("演武配装/经济服务未启用：无法安装原生载档前守卫 "..path)
            return
        end
        installed[#installed+1]={path=path,pre=pre,post=post}
    end
    servicesHooksReady=true
    local function beforeExit()
        closeCombatHud("game exit")
        local home = package.loaded.TitleHome
        if home then home.stopPalaceInput("game exit") end
        local palace = challenge and challenge.palace
        if not palace then return end
        local ok, failure = pcall(function()
            if not palace.pawn or not privateServicesGate(palace.pawn) then return end
            if palace.loadout then palace:closeLoadoutMemory(palace.pawn) end
        end)
        if not ok then log("Bloody Palace preparation loadout: " .. tostring(failure)) end
    end
    for _,path in ipairs({"/Script/Engine.GameplayStatics:OpenLevel", "/Script/Engine.KismetSystemLibrary:QuitGame"}) do
        local ok = pcall(RegisterHook, path, beforeExit)
        if not ok then log("Bloody Palace exit checkpoint hook unavailable: " .. path) end
    end
end
installServiceLoadGuards()

local outsideCleanupPhase, outsideCleanupRun, retryStreamingReset
RegisterLoadMapPreHook(function()
    stopArenaKeys()
    local home = package.loaded.TitleHome
    if home then home.stopPalaceInput("map transition") end
    closeCombatHud("map transition")
    closeStatusHud("map transition")
    outsideCleanupPhase, outsideCleanupRun, retryStreamingReset = nil, nil, nil
    closeBossEntry()
    clearPhasePreload(challenge)
    trainingPreload = nil
    StockEvents.onMapPre()
    stockArrivalWorld, stockReadyWorld, stockBossAddress = nil, nil, nil
    local achievementToast = package.loaded.DreamPalaceAchievementToast
    if achievementToast then achievementToast.onMapPre() end
    local palace = challenge and challenge.palace
    local gameplay = (palace or pendingSettlement) and StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if pendingSettlement then
        if not pendingSettlement:preserveAcrossMap(gameplay) then pendingSettlement = nil end
    end
    if palace then
        -- Keep only the pending admission through its protected initial travel.
        local arriving = palace.state == "preparing" and not palace.pawnAddress and not palace.closed
            and titleSession and titleSession:isLoadingArena(challenge.scene)
        if not arriving then
            local run = challenge
            challenge = nil
            if palace.pawnAddress then
                local ok, failure = pcall(palace.onMapPre, palace, run)
                if not ok then log("Bloody Palace map exit: " .. tostring(failure)) end
            end
            local settlement = palace.settlement
            if settlement and settlement:preserveAcrossMap(gameplay) then
                pendingSettlement = settlement
                local world = valid(playerController) and SceneArena.runtimeWorld(playerController)
                settlement.departingWorld = valid(world) and world:GetAddress() or settlement.departingWorld
                palace.settlement = nil
            end
            local ok, failure = pcall(run.close, run)
            if not ok then log("Bloody Palace cleanup: " .. tostring(failure)) end
        end
    end
    XiguStreaming.reset("map transition")
    sceneServiceAfter = nil
    closeArenaServices();serviceMapEpoch=serviceMapEpoch+1
    if titleSession then titleSession:onMapPre() end
    closeTrainingBell()
    resetTrainingTargets()
    playerController = nil
    if challenge and not palace then challenge:close(true) end
    if trainingDifficulty then pcall(trainingDifficulty.close, trainingDifficulty); trainingDifficulty = nil end
    pcall(function() require("AbilityChallenge").clearProfile() end)
    ClosedArena.reset()
    ShengQuXinChi.reset()
    StockBellArena.reset()
    XiguArena.reset()
    MeiGuHuArena.reset()
    trainingSkillsApplied = false
    trainingSkillPawnAddress = nil
    if installedConfig then pcall(function() require("TrainingHud").close() end) end
end)

local lastTickError, lastArenaError, lastTitleProbeError
local parsedAtBoot, _, _, bossAtBoot, _, _, probeAtBoot = pcall(function()
    return sessionArgs(requiredObject("/Script/Engine.Default__KismetSystemLibrary"))
end)
local serviceInterval = 100
local function updateStatusHud(gameplay,pawn,now)
    if not DisplayPreferences.statusHudEnabled() then
        if statusHudActive then closeStatusHud("preference disabled") end
        return
    end
    local actors={}
    if challenge then
        if (challenge.status=="ready" or challenge.status=="combat") and not challenge.reloadRequested
            and not challenge.reloadAt and not challenge.view then
            actors=challenge.bosses or {}
        end
    else
        for _,target in ipairs(targets) do actors[#actors+1]=target.actor end
    end
    if #actors==0 then closeStatusHud();return end
    if statusHudFailedWorld~=nil and statusHudFailedWorld==worldAddress then return end
    statusHudActive = true
    local ok,failure=pcall(function()
        local lookup = perfSceneId == "xigu" and XiguArena.findStatusObjects or nil
        local frost = not (challenge and challenge.palace) and Frost or nil
        local stage = challenge and challenge.stageIndex
        if frost then frost.sync(gameplay, pawn, actors, stage, playerController:GetWorld()) end
        require("StatusBuildupHud").update(playerController, actors, gameplay:GetRealTimeSeconds(pawn), lookup, stage, frost)
    end)
    if not ok then
        closeStatusHud();statusHudFailedWorld=worldAddress
        if failure~=lastStatusHudError then log("[PBZStatusBuildup] disabled for this scene: "..tostring(failure)) end
        lastStatusHudError=failure
    else lastStatusHudError=nil end
end
local function service()
    drainServiceCleanup()
    if challenge and challenge.retryPreload then require("RetryPreload").expire(challenge) end
    if probeAtBoot or titleSession then
        local ok, failure = pcall(function()
            prepareSession(requiredObject("/Script/Engine.Default__KismetSystemLibrary"))
            local controller
            if titleSession.phase == "arena" and titleSession.scene and titleSession.scene.runtimeModule then
                if not valid(playerController) then playerController = UE.GetPlayerController() end
                controller = playerController
            else
                controller = UE.GetPlayerController()
            end
            local gameplay = requiredObject("/Script/Engine.Default__GameplayStatics")
            titleSession:tick(gameplay, controller)
            local achievementToast = package.loaded.DreamPalaceAchievementToast
            if achievementToast then achievementToast.update(gameplay, controller) end
        end)
        if not ok and failure ~= lastTitleProbeError then log("Title probe: " .. tostring(failure)) end
        lastTitleProbeError = not ok and failure or nil
        if pendingSettlement then
            stopArenaKeys()
            closeCombatHud("settlement")
            local settlement, controller = pendingSettlement, UE.GetPlayerController()
            if not valid(controller) then return end
            local served, reason = pcall(function()
                local gameplay = requiredObject("/Script/Engine.Default__GameplayStatics")
                if settlement:update(gameplay, controller, gameplay:GetRealTimeSeconds(controller)) then
                    if text(gameplay:GetCurrentLevelName(controller, true)) ~= "PBZ_StartMenu_CE_WP" then
                        require("Challenge").returnToTitle(gameplay, controller)
                    end
                    settlement:detach(gameplay)
                    pendingSettlement = nil
                end
            end)
            if not served and settlement.lastServiceError ~= reason then log("Retained settlement: " .. tostring(reason)) end
            settlement.lastServiceError = not served and reason or nil
            return
        end
        if not titleSession or not titleSession:allowArena() then
            stopArenaKeys()
            closeCombatHud("arena exit")
            closeBossEntry()
            clearPhasePreload(challenge)
            local phase = titleSession and titleSession.phase or "waiting"
            if challenge and challenge.retryPreload and phase ~= "loading" then require("RetryPreload").close(challenge) end
            if outsideCleanupPhase ~= phase or outsideCleanupRun ~= challenge then
                retryStreamingReset = XiguStreaming.reset("private session ended") == false
                XiguArena.reset()
                MeiGuHuArena.reset()
                ShengQuXinChi.reset()
                if phase ~= "loading" then
                    StockBellArena.reset()
                    StockEvents.reset()
                end
                closeTrainingBell()
                trainingPreload = nil
                if challenge then challenge:closeMusic() end
                closeArenaServices()
                outsideCleanupPhase, outsideCleanupRun = phase, challenge
            elseif retryStreamingReset then
                retryStreamingReset = XiguStreaming.reset("private session ended") == false
            end
            publish("waiting", "请在测试主菜单中选择 MOD。")
            return
        end
    end
    outsideCleanupPhase, outsideCleanupRun, retryStreamingReset = nil, nil, nil
    local palace = challenge and challenge.palace
    if palace and palace.state == "result" and not palace.ending and valid(playerController) then
        syncArenaKeys(false)
        closeCombatHud("settlement")
        local run = challenge
        local served, reason = pcall(function()
            local gameplay = requiredObject("/Script/Engine.Default__GameplayStatics")
            if run.action then
                local context = gameplay:GetPlayerPawn(playerController, 0)
                if not valid(context) then context = playerController end
                run:updateMenuOnly(gameplay, nil, context, gameplay:GetTimeSeconds(context))
            else
                palace:updateResult(run, gameplay, playerController, gameplay:GetRealTimeSeconds(playerController))
            end
        end)
        if not served and reason ~= lastTickError then log("Dream Palace settlement: " .. tostring(reason)) end
        lastTickError = not served and reason or nil
        if challenge == run then publish(run.status, run.message, nil, palace.arenaEntered == true) end
        return
    end
    local ready, gameplay, system, pawn, now, bossClassesReady = pcall(arenaContext, true)
    if not ready then
        syncArenaKeys(false)
        closeCombatHud("arena unavailable")
        closeStatusHud()
        local message = tostring(gameplay):gsub("^.-:%d+: ", "", 1)
        if statusPath and lastArenaError ~= message then log("waiting: " .. message) end
        lastArenaError = message
        local scene = challenge and challenge.scene or ArenaScenes.get(trainingSceneId)
        if scene.runtimeModule and perfClock then sceneServiceAfter = perfClock() + 0.25 end
        publish("waiting", "等待" .. scene.name .. "就绪。" .. message)
        return
    end
    lastArenaError = nil
    if titleSession and titleSession.profileCheckPending then
        local verified, failure = pcall(titleSession.verifyCheckpointPlayer, titleSession, pawn)
        if not verified then
            syncArenaKeys(false)
            if failure ~= lastTickError then log("CHECKPOINT_PROFILE " .. tostring(failure)) end
            lastTickError = failure
            publish("waiting", "正在确认当前地图的玩家轮回")
            return
        end
    end
    syncArenaKeys(true)
    if installedConfig and not challenge then
        local configured, failure = pcall(function()
            if trainingSkillPawnAddress and trainingSkillPawnAddress ~= pawn:GetAddress() and trainingDifficulty then
                trainingDifficulty:close(); trainingDifficulty = nil
            end
            if not trainingDifficulty then trainingDifficulty = require("GameplayDifficulty").new(pawn, trainingDifficultyMode) end
            local applied, reason = trainingDifficulty:update(pawn)
            if applied == false then trainingDifficulty = nil; error(reason or "训练场景已改变") end
        end)
        if not configured then
            if failure ~= lastTickError then log("training difficulty: " .. tostring(failure)) end
            lastTickError = failure
            publish("waiting", "正在应用训练难度设置")
            return
        end
    end
    if installedConfig and not challenge and trainingSkillLevel ~= nil
        and (not trainingSkillsApplied or trainingSkillPawnAddress ~= pawn:GetAddress()) then
        local applied, failure = pcall(function()
            local ability = require("AbilityChallenge")
            ability.setProfile(pawn, require("PlayerProfile").id(trainingPlayerCycle))
            if trainingAbilitySnapshot then
                ability.restore(pawn, trainingAbilitySnapshot)
            elseif not trainingSkillMemory or not trainingSkillMemory:apply(pawn, ability, trainingSkillLevel) then
                ability.setCycleSkills(pawn, trainingSkillLevel)
            end
        end)
        if not applied then
            publish("waiting", "正在应用训练技能设置")
            if failure ~= lastTickError then log("training skill settings: " .. tostring(failure)) end
            lastTickError = failure
            return
        end
        trainingSkillsApplied = true
        trainingSkillPawnAddress = pawn:GetAddress()
    end
    if challenge then
        if not bossClassesReady then return end
        local run = challenge
        local ok, err = pcall(run.tick, run, gameplay, system, pawn, now)
        if bossEntry and (not ok or challenge ~= run or run.status == "error" or run.reloadRequested) then
            closeBossEntry()
        elseif bossEntry and #run.bosses == bossEntry.targetCount and valid(run.boss) then
            closeBossEntry()
        end
        if not ok or challenge ~= run or run.status == "error" or run.reloadRequested then clearPhasePreload(run) end
        if challenge ~= run or (titleSession and not titleSession:allowArena()) then
            closeCombatHud("challenge ended")
            return
        end
        if not ok then
            closeCombatHud("challenge error")
            local message = tostring(err):gsub("^.-:%d+: ", "", 1)
            log("challenge: " .. message)
            run:fail(message)
        elseif run.palace or combatHudSession then
            syncCombatHud(run, gameplay, now)
        end
        run:updateMusic(gameplay, pawn, gameplay:GetRealTimeSeconds(pawn))
        local palace = run.palace
        local active = not palace and run.startedAt ~= nil and not run.reloadAt and not run.reloadRequested
            and run.status ~= "won" and run.status ~= "error" and run.view ~= "victory"
        if perfSceneId == "xigu" then
            local keepClosed = palace and palace.arenaEntered and not palace.closed
            XiguArena.updateCombat(active or keepClosed, run.status == "won" or run.status == "gate",
                gameplay:GetRealTimeSeconds(pawn), keepClosed)
        elseif perfSceneId == "meiguhu" then
            MeiGuHuArena.updateCombat(pawn, active)
        elseif perfSceneId == "leidang" then
            ShengQuXinChi.updateCombat(pawn, active, gameplay:GetRealTimeSeconds(pawn), run.scene)
        elseif perfSceneId == "lake" then
            StockBellArena.updateCombat(pawn, active, run.scene)
        end
        local boss = valid(run.boss) and run.boss:GetAddress() or nil
        if boss and stockBossAddress ~= boss then
            log(("Stock arena boss ready scene=%s target=%s stage=%d"):format(run.sceneId, run.entry.id, run.stageIndex))
            StockEvents.mark("boss_ready")
        end
        stockBossAddress = boss
        updateStatusHud(gameplay,pawn,now)
        publish(run.status, run.message, palace and palace:hud(run, now), palace and palace.arenaEntered == true)
        return
    end
    if installedConfig and updateTrainingBell(gameplay, pawn, ArenaScenes.get(trainingSceneId)) then
        publish("ready")
        return
    end
    if installedConfig then prepareTrainingTarget(gameplay, pawn) end
    local ok, err = pcall(updateTargets, now, gameplay, pawn)
    updateStatusHud(gameplay,pawn,now)
    if not ok then
        if err ~= lastTickError then log("maintenance: " .. tostring(err)) end
        lastTickError = err
        publish("error", "部分单位状态读取失败，请查看测试日志")
    else
        lastTickError = nil
        publish("ready")
    end
end

-- Approximate elapsed time of this Lua service only, including its native
-- calls. os.clock resolution is platform-dependent; this is not a CPU/GPU or
-- whole-frame profiler. It performs no extra engine queries or per-tick I/O.
local perfState
local function runServiceLoop()
    local started = (sceneServiceAfter or perfSampling) and perfClock and perfClock()
    if started and sceneServiceAfter and started < sceneServiceAfter then return end
    sceneServiceAfter = nil
    perfSceneId, perfMode = nil, nil
    service()
    if not perfSampling then return end
    local finished = perfClock()
    if not perfSceneId then perfState = nil; return end
    if not started or not finished or finished < started then return end
    if not perfState or perfState.scene ~= perfSceneId or perfState.mode ~= perfMode
        or perfState.world ~= worldAddress then
        perfState = { scene = perfSceneId, mode = perfMode, world = worldAddress,
            since = finished, samples = 0, total = 0, maximum = 0 }
    end
    local elapsed = (finished - started) * 1000
    perfState.samples = perfState.samples + 1
    perfState.total = perfState.total + elapsed
    perfState.maximum = math.max(perfState.maximum, elapsed)
    if finished - perfState.since >= 10 then
        log(("MOD loop timing (os.clock approximate elapsed): scene=%s; mode=%s; samples=%d; avgMs=%.3f; maxMs=%.3f; serviceIntervalMs=%d")
            :format(perfState.scene, perfState.mode, perfState.samples, perfState.total / perfState.samples,
                perfState.maximum, serviceInterval))
        perfState.since, perfState.samples, perfState.total, perfState.maximum = finished, 0, 0, 0
    end
end

LoopInGameThreadWithDelay(serviceInterval, runServiceLoop)
log("Old-house arena Lua loaded.")
