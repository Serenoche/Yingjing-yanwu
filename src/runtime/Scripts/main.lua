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
local nextId, autoheal, panelVisible = 1, false, true
local statusPath, notice, playerController, lastPanelError, lastHudError
local enemyCycle = 0
local trainingSceneId = "night"
local lastPreparationMenuError
local perfSceneId, perfMode
local challenge, titleSession
local installedConfig, trainingSkillLevel, trainingSkillsApplied, trainingSkillPawnAddress
local trainingPlayerCycle, trainingDifficultyMode, trainingDifficulty = 6, 3, nil
local loadoutMemoryPath, arenaServices, privateServiceScope
local servicesHooksReady,servicesAllowed=false,false
local serviceMapEpoch,serviceLoadDepth,servicePendingEpoch=0,0,nil
local expectedServiceSlot
local sealedServicesStarted=false
local pendingServiceCleanup,nextServiceCleanup={},0
local lastStatusHudError,statusHudFailedWorld

local function log(message)
    print("[PBZTestArenaNative] " .. message .. "\n")
end

local function valid(object)
    return object ~= nil and object:IsValid()
end

local function text(value)
    if type(value) == "string" then return value end
    return value and value:ToString() or ""
end

local function requiredObject(path)
    local object = StaticFindObject(path)
    assert(valid(object), "missing reflected object: " .. path)
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
local function closeStatusHud()
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
    for _,service in ipairs({old.economy or false,old.mapPolicy or false})do
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
local function checkpointArenaServices(pawn,slot)
    -- This explicit MOD command runs before native LoadGame can change arrays.
    if arenaServices and arenaServices.memory then pcall(arenaServices.memory.beginLoad,arenaServices.memory,pawn)end
    closeArenaServices()
    servicesAllowed=false
    expectedServiceSlot=slot
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
    if not arenaServices.mapPolicyAttempted then
        arenaServices.mapPolicyAttempted=true
        local ok,mapPolicy,reason=pcall(function()return require("ArenaMapPolicy").new(pawn,function()return privateServicesGate(pawn)end)end)
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
    if not arenaServices.initialized then
        arenaServices.initialized=true
        if loadoutMemoryPath then
            local ok,memory,reason=pcall(function()return require("ArenaLoadoutMemory").new(loadoutMemoryPath,privateServicesGate,log)end)
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
    if arenaServices.memory then
        local ok,accepted,reason=pcall(arenaServices.memory.update,arenaServices.memory,pawn,realNow)
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
    local profile, bossId, playerCycle, skillLevel, probe, fullMenu
    profile, enemyCycle, bossId, playerCycle, skillLevel, probe, installedConfig, fullMenu,loadoutMemoryPath = sessionArgs(system)
    if fullMenu then
        installedConfig = { disposable = true, profile = profile, defaultPlayerCycle = 6,
            defaultEnemyCycle = enemyCycle, trainingSlot = "PBZArenaIntegratedTraining", cyclePrefix = "PBZArenaIntegratedCycle",loadoutMemoryPath=loadoutMemoryPath }
    end
    if bossId then
        local entry = assert(require("EncounterCatalog").resolve(bossId), "unknown challenge encounter")
        challenge = require("Challenge").new(entry, enemyCycle, profile, playerCycle, skillLevel,
            {loadoutMemoryPath=loadoutMemoryPath,onBeforeLoad=checkpointArenaServices})
    end
    if installedConfig then
        local options = {
            integrated = true, disposable = installedConfig.disposable,
            trainingSlot = installedConfig.trainingSlot, cyclePrefix = installedConfig.cyclePrefix,
            savePath=installedConfig.savePath, diagnostics=installedConfig.diagnostics,
            loadoutMemoryPath=loadoutMemoryPath,
            onBeforeRestore=function()
                servicesAllowed,expectedServiceSlot=false,nil
                closeArenaServices()
            end,
            defaults = { playerCycle = installedConfig.defaultPlayerCycle, enemyCycle = installedConfig.defaultEnemyCycle,
                skillLevel = 5 * installedConfig.defaultPlayerCycle },
            onStart = function(settings, slot)
                settings.skillLevel = require("PlayerProfile").normalizeSkillLevel(settings.playerCycle, settings.skillLevel)
                closeArenaServices();servicesAllowed=true;expectedServiceSlot=slot
                if challenge then challenge:close() end
                challenge = nil
                targets, selectedId, worldAddress, autoheal, panelVisible = {}, nil, nil, false, true
                enemyCycle, trainingSkillLevel, trainingSkillsApplied = settings.enemyCycle, nil, false
                trainingSkillPawnAddress = nil
                trainingPlayerCycle, trainingDifficultyMode = settings.playerCycle, settings.difficultyMode or 3
                local selectedEncounter = settings.mode ~= "training" and settings.bossId or nil
                trainingSceneId = ArenaScenes.forEncounter(selectedEncounter, settings.sceneId).id
                if settings.mode == "challenge" or settings.mode == "practice" then
                    challenge = require("Challenge").new(assert(require("EncounterCatalog").resolve(settings.bossId)),
                        enemyCycle, profile, settings.playerCycle, settings.skillLevel,
                        { resetSlot = slot, cyclePrefix = installedConfig.cyclePrefix,
                            mode = settings.mode, difficultyMode = settings.difficultyMode or 3,
                            sceneId = trainingSceneId,
                            loadoutMemoryPath=loadoutMemoryPath,onBeforeLoad=checkpointArenaServices,
                            onSceneChange = function(sceneId, gameplay, pawn)
                                if titleSession then titleSession:changeArenaScene(sceneId, gameplay, pawn) end
                            end })
                else
                    trainingSkillLevel = settings.skillLevel
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
    assert((scene.id == "night" and scene.map == "PBZ_Duanhun_WP")
        or (scene.id == "lake" and scene.map == "PBZ_Zhengdaodaying_WP"), "此演武场景已撤下")
    assert(level == scene.map, "requires " .. scene.map .. "; current level: " .. level)
    local class = pawn:GetClass():GetFName():ToString()
    assert(class == ADULT_CLASS, "requires adult Hun; current pawn: " .. class)
    if not installedConfig then requireNativeSeal(gameplay, pawn) end
    local actualWorld = SceneArena.runtimeWorld(pawn)
    assert(valid(actualWorld), "等待角色的真实运行世界")
    local activeWorld = actualWorld:GetAddress()
    -- Input policy needs only the protected private world, not boss-ground or
    -- equipment readiness. It must cover the preparation interval as well.
    updateArenaServices(gameplay,pawn,scene,activeWorld,true)
    if worldAddress ~= activeWorld then
        targets, selectedId, worldAddress = {}, nil, activeWorld
    end
    perfSceneId, perfMode = scene.id, challenge and (challenge.mode or "challenge") or "training"
    local now = gameplay:GetTimeSeconds(pawn)
    local keep = function(actor)
        if SceneArena.owns(actor) or (challenge and challenge:owns(actor)) then return true end
        if valid(actor) then
            for _, target in ipairs(targets) do
                if valid(target.actor) and target.actor:GetAddress() == actor:GetAddress() then return true end
            end
        end
        return false
    end
    local allowBell = challenge ~= nil and challenge.status ~= "error" and challenge.status ~= "won"
        and challenge.view ~= "victory"
    local ready, reason
    if scene.id ~= "night" then
        ready, reason = SceneArena.update(gameplay, pawn, playerController, now, scene, keep, allowBell)
    else
        ready, reason = ClosedArena.update(pawn, playerController, activeWorld, now, keep, allowBell)
    end
    if not ready and serveMenu and challenge then
        -- The original bell UI must remain usable while streaming or optional
        -- anchor calibration waits. This path never spawns or advances combat.
        local served, failure = pcall(challenge.updateMenuOnly, challenge, gameplay, system, pawn, now)
        if not served and failure ~= lastPreparationMenuError then log("Pending-scene bell menu: " .. tostring(failure)) end
        lastPreparationMenuError = not served and failure or nil
    end
    assert(ready, reason or "训练场正在准备")
    local configured,configurationReason=updateArenaServices(gameplay,pawn,scene,activeWorld)
    if not configured and serveMenu and challenge then pcall(challenge.updateMenuOnly,challenge,gameplay,system,pawn,now)end
    assert(configured,configurationReason or "等待演武配装初始化")
    return gameplay, system, pawn, now
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

local function publish(mode, message)
    if not statusPath then return end
    local rows = {}
    if mode == "ready" then
        for _, target in ipairs(targets) do
            rows[#rows + 1] = {
                id = target.id, level = target.level, health = target.health, maxHealth = target.maxHealth,
                ai = target.running, alive = true,
            }
        end
    end
    local snapshot = {
        maxTargets = MAX_TARGETS, selectedId = selectedId, autoheal = autoheal, enemyCycle = enemyCycle,
        mode = mode, visible = not challenge and panelVisible, message = message or notice, targets = rows,
        training = challenge == nil, challenge = challenge ~= nil,
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

local function openFloor(system, pawn, position, x, y)
    for _, target in ipairs(targets) do
        local other = target.actor:K2_GetActorLocation()
        if (x - other.X)^2 + (y - other.Y)^2 < 165^2 then return nil end
    end
    local top = { X = x, Y = y, Z = position.Z + 180 }
    local bottom = { X = x, Y = y, Z = position.Z - 180 }
    local floor, noColor = {}, { R = 0, G = 0, B = 0, A = 0 }
    -- UE4SS's official LineTraceMod passes an empty Lua table for FHitResult.
    local hit = system:LineTraceSingle(pawn, top, bottom, 0, false, {}, 0, floor, true, noColor, noColor, 0.0)
    if hit and floor.ImpactPoint and floor.ImpactNormal and floor.ImpactNormal.Z >= 0.65 then
        local point = floor.ImpactPoint
        return { X = point.X, Y = point.Y, Z = point.Z + ENEMY_CAPSULE_HALF_HEIGHT + 5 }
    end
end

local function spawnPaused(gameplay, system, pawn, now)
    assert(#targets < MAX_TARGETS, "测试单位已满（" .. MAX_TARGETS .. "）")
    local mathLibrary = requiredObject("/Script/Engine.Default__KismetMathLibrary")
    local spawner = requiredObject("/Script/SGameAI.Default__SGameAIFunctionLibrary")
    local class = CombatSpawn.class(ENEMY_CLASS)
    local position, forward = pawn:K2_GetActorLocation(), pawn:GetActorForwardVector()
    local deferred, transform
    for _, offset in ipairs(SPAWN_OFFSETS) do
        local x = position.X + forward.X * offset[1] - forward.Y * offset[2]
        local y = position.Y + forward.Y * offset[1] + forward.X * offset[2]
        local location = openFloor(system, pawn, position, x, y)
        if location then
            local facing = mathLibrary:FindLookAtRotation(location, position)
            local yawOnly = { Pitch = 0, Yaw = facing.Yaw, Roll = 0 }
            transform = mathLibrary:MakeTransform(location, yawOnly, { X = 1, Y = 1, Z = 1 })
            deferred = spawner:SpawnActorDeferred(pawn, class, transform, ADJUST_IF_CLEAR)
            if valid(deferred) then break end
        end
    end
    assert(valid(deferred), "前方没有足够的平地，请换个方向或位置")
    local actor, enemyLevel = CombatSpawn.finish(gameplay, pawn, deferred, transform, enemyCycle)
    targets[#targets + 1] = { id = nextId, actor = actor, level = enemyLevel, running = false, lastDamage = now }
    selectedId, nextId = nextId, nextId + 1
    report(string.format("已生成金面人 #%d · 轮回 %d · Lv.%g，AI 已暂停", selectedId, enemyCycle, enemyLevel))
end

local function toggleAI()
    local target = assert(selected(), "请先按 F8 生成测试单位")
    local ai = CombatSpawn.ai(target.actor)
    if target.running then ai:StopAI() else ai:StartAI() end
    target.running = not target.running
    report("#" .. target.id .. (target.running and " 已恢复 AI" or " 已暂停 AI"))
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
    target.actor:K2_DestroyActor()
    removeTarget(index)
    report("已清除测试单位 #" .. target.id)
end

local function nextTarget()
    assert(#targets > 0, "当前没有测试单位")
    local _, index = selected()
    selectedId = targets[(index or 0) % #targets + 1].id
    report("已选中测试单位 #" .. selectedId)
end

local function updateTargets(now)
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
                removeTarget(index)
                report("测试单位 #" .. target.id .. " 已死亡，位置已释放")
            elseif health and maxHealth then
                target.readError = nil
                if target.health and health < target.health then target.lastDamage = now end
                if autoheal and health < maxHealth and now - target.lastDamage >= HEAL_DELAY_SECONDS then
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

local function bind(key, label, action)
    RegisterKeyBind(key, function()
        ExecuteInGameThread(function()
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
                local gameplay, system, pawn, now = arenaContext()
                ready = true
                updateTargets(now)
                action(gameplay, system, pawn, now)
            end)
            if challenge then
                if not ok and challenge.mode == "practice" then
                    local message = tostring(err):gsub("^.-:%d+: ", "", 1)
                    log("Practice " .. label .. " failed: " .. message)
                end
                return
            end
            if ok then publish("ready")
            else
                local message = tostring(err):gsub("^.-:%d+: ", "", 1)
                log(label .. ": " .. message)
                publish(ready and "ready" or "waiting", message)
            end
        end)
    end)
end

bind(Key.F5, "F5", nextTarget)
bind(Key.F6, "F6", function()
    autoheal = not autoheal
    report(autoheal and "已开启自动回血" or "已关闭自动回血")
end)
bind(Key.F7, "F7", function() panelVisible = not panelVisible end)
bind(Key.F8, "F8", spawnPaused)
bind(Key.F9, "F9", toggleAI)
bind(Key.F10, "F10", clearSelected)

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
            closeArenaServices() -- cached private bytes only; never capture here
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
end
installServiceLoadGuards()

RegisterLoadMapPreHook(function()
    -- Native LoadGame may already have replaced backpack caches. Only flush
    -- the last valid private snapshot here; explicit MOD commands checkpoint
    -- before invoking LoadGame, and raw pre-hooks have already closed scope.
    closeArenaServices();serviceMapEpoch=serviceMapEpoch+1
    if titleSession then titleSession:onMapPre() end
    playerController, worldAddress, targets, selectedId = nil, nil, {}, nil
    if challenge then challenge:close() end
    if trainingDifficulty then pcall(trainingDifficulty.close, trainingDifficulty); trainingDifficulty = nil end
    pcall(function() require("AbilityChallenge").clearProfile() end)
    ClosedArena.reset()
    SceneArena.reset()
    trainingSkillsApplied = false
    trainingSkillPawnAddress = nil
    if installedConfig then pcall(function() require("TrainingHud").close() end) end
end)

local lastTickError, lastArenaError, lastTitleProbeError
local parsedAtBoot, _, _, bossAtBoot, _, _, probeAtBoot = pcall(function()
    return sessionArgs(requiredObject("/Script/Engine.Default__KismetSystemLibrary"))
end)
local serviceInterval = parsedAtBoot and (bossAtBoot or probeAtBoot) and 50 or 250
local function updateStatusHud(gameplay,pawn,now)
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
    local ok,failure=pcall(function()
        require("StatusBuildupHud").update(playerController,actors,gameplay:GetRealTimeSeconds(pawn))
    end)
    if not ok then
        closeStatusHud();statusHudFailedWorld=worldAddress
        if failure~=lastStatusHudError then log("[PBZStatusBuildup] disabled for this scene: "..tostring(failure)) end
        lastStatusHudError=failure
    else lastStatusHudError=nil end
end
local function service()
    drainServiceCleanup()
    if probeAtBoot or titleSession then
        local ok, failure = pcall(function()
            prepareSession(requiredObject("/Script/Engine.Default__KismetSystemLibrary"))
            titleSession:tick(requiredObject("/Script/Engine.Default__GameplayStatics"), UE.GetPlayerController())
        end)
        if not ok and failure ~= lastTitleProbeError then log("Title probe: " .. tostring(failure)) end
        lastTitleProbeError = not ok and failure or nil
        if not titleSession or not titleSession:allowArena() then
            closeArenaServices()
            publish("waiting", "请在测试主菜单中选择 MOD。")
            return
        end
    end
    local ready, gameplay, system, pawn, now = pcall(arenaContext, true)
    if not ready then
        closeStatusHud()
        local message = tostring(gameplay):gsub("^.-:%d+: ", "", 1)
        if statusPath and lastArenaError ~= message then log("waiting: " .. message) end
        lastArenaError = message
        publish("waiting", "请继续游戏进入故屋幻景。" .. message)
        return
    end
    lastArenaError = nil
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
            ability.setCycleSkills(pawn, trainingSkillLevel)
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
        local ok, err = pcall(challenge.tick, challenge, gameplay, system, pawn, now)
        if not ok then
            local message = tostring(err):gsub("^.-:%d+: ", "", 1)
            log("challenge: " .. message)
            challenge:fail(message)
        end
        updateStatusHud(gameplay,pawn,now)
        publish(challenge.status, challenge.message)
        return
    end
    local ok, err = pcall(updateTargets, now)
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
local perfClock = os and type(os.clock) == "function" and os.clock
local perfState
LoopInGameThreadWithDelay(serviceInterval, function()
    local started = perfClock and perfClock()
    perfSceneId, perfMode = nil, nil
    service()
    local finished = perfClock and perfClock()
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
end)
log("Old-house arena Lua loaded.")
