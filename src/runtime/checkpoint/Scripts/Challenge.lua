local CombatSpawn = require("CombatSpawn")
local Signals = require("ChallengeSignals")
local Menu = require("ChallengeMenu")
local Victory = require("ChallengeVictory")
local PlayerState = require("EncounterPlayerState")
local Encounters = require("EncounterCatalog")
local StageFade = require("StageFade")
local EncounterEngage = require("EncounterEngage")
local SpawnClass = require("SpawnClass")
local RetryPreload = require("RetryPreload")
local PlayerProfile = require("PlayerProfile")
local ChallengeMedicine = require("ChallengeMedicine")
local ArenaScenes = require("ArenaScenes")

local LionArena = require("LionArena")
local JingYeMount = require("JingYeMount")
local ChiLianArena = require("ChiLianArena")
local Music = require("BattleMusic")
local Difficulty = require("GameplayDifficulty")
local PalaceMechanics = require("BloodyPalaceMechanics")
local PalaceFormation = require("DreamPalaceFormation")
local PalaceProgress = require("BloodyPalaceProgress")
local Challenge = {}
Challenge.__index = Challenge

local ARENA_LEVEL = "PBZ_Duanhun_WP"
local BELL_DATA = "/Script/ProjectPBZ.BellManager:GetBellData"
local RESET_SLOT = "ManualSave947631"
local WAKE_DISTANCE = 1650
local NO_COLOR = { R = 0, G = 0, B = 0, A = 0 }

local function valid(object)
    return object ~= nil and object:IsValid()
end

local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "missing reflected object: " .. path)
    return object
end

local function stringValue(value)
    if type(value) == "string" then return value end
    return value and value:ToString() or ""
end

local function distanceSquared(a, b)
    return (a.X - b.X)^2 + (a.Y - b.Y)^2 + (a.Z - b.Z)^2
end

local function jsonValue(value, seen, depth)
    if type(value) == "number" and value == value and math.abs(value) < math.huge then return tostring(value) end
    if type(value) == "boolean" then return value and "true" or "false" end
    if type(value) == "table" then
        seen, depth = seen or {}, (depth or 0) + 1
        assert(depth <= 12 and not seen[value], "invalid nested challenge report")
        seen[value] = true
        local keys, array = {}, true
        for key in pairs(value) do
            keys[#keys + 1] = key
            if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #value then array = false end
        end
        local parts = {}
        if array and #keys > 0 then
            for index = 1, #value do parts[#parts + 1] = jsonValue(value[index], seen, depth) end
        else
            table.sort(keys)
            for _, key in ipairs(keys) do
                assert(type(key) == "string", "challenge report keys must be strings")
                parts[#parts + 1] = jsonValue(key) .. ":" .. jsonValue(value[key], seen, depth)
            end
        end
        seen[value] = nil
        return (array and #keys > 0 and "[" or "{") .. table.concat(parts, ",")
            .. (array and #keys > 0 and "]" or "}")
    end
    if type(value) ~= "string" then return "null" end
    return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
        if char == '"' or char == '\\' then return '\\' .. char end
        return string.format("\\u%04x", char:byte())
    end) .. '"'
end

local function writeFile(path, value)
    local stream = assert(io.open(path, "wb"))
    local wrote, errorMessage = stream:write(value)
    local closed, closeError = stream:close()
    assert(wrote and closed, errorMessage or closeError)
end

local function saveReport(directory, report)
    local fields = {
        "version", "attemptResult", "bossId", "bossName", "timeSeconds", "perfectGuards", "perfectDodges", "healthRestored",
        "damageTaken", "damageTakenStatus", "damageTakenNote",
        "playerCycle", "enemyCycle", "bossLevel", "endedAt", "metricsNote",
        "category", "categoryName", "stageCount", "completedStages",
        "mode", "playerProfile", "nativePlayerCycle", "difficultyMode", "difficultyName", "loadout",
        "sceneId", "sceneName", "authoredPhaseCount", "summonWaveCount",
    }
    local rows = {}
    for _, field in ipairs(fields) do
        rows[#rows + 1] = "  " .. jsonValue(field) .. ": " .. jsonValue(report[field])
    end
    local payload = "{\n" .. table.concat(rows, ",\n") .. "\n}\n"
    local filename = os.date("!%Y%m%d-%H%M%S") .. "-" .. report.bossId
    local path = directory .. "/" .. filename .. ".json"
    local index = 1
    while true do
        local existing = io.open(path, "rb")
        if not existing then break end
        existing:close()
        index = index + 1
        path = directory .. "/" .. filename .. "-" .. index .. ".json"
    end
    writeFile(path .. ".tmp", payload)
    assert(os.rename(path .. ".tmp", path))
    if report.attemptResult == "success" then
        local latest = directory .. "/latest.json"
        writeFile(latest .. ".tmp", payload)
        os.remove(latest)
        assert(os.rename(latest .. ".tmp", latest))
    end
    return path
end

local function readHistory(profilePath)
    local history = {}
    local file = io.open(profilePath .. "/PBZChallengeHistory.tsv", "rb")
    if not file then return history end
    for row in file:lines() do
        local columns = {}
        for value in (row:gsub("\r$", "") .. "\t"):gmatch("([^\t]*)\t") do columns[#columns + 1] = value end
        local name, seconds, result, stamp, guards, dodges, healed =
            columns[1], columns[2], columns[3], columns[4], columns[5], columns[6], columns[7]
        local damage = tonumber(columns[8])
        if not damage or damage ~= damage or damage < 0 or damage == math.huge then damage = nil end
        local reportFile = columns[11]
        if type(reportFile) ~= "string" or not reportFile:match("^[A-Za-z0-9_-]+%.json$")
            or reportFile:lower() == "latest.json" then reportFile = nil end
        if (#columns == 7 or #columns == 10 or #columns == 11) and name and tonumber(seconds) and (result == "success" or result == "failure") then
            history[#history + 1] = {
                bossName = name, timeSeconds = tonumber(seconds), attemptResult = result, endedAt = stamp,
                perfectGuards = tonumber(guards), perfectDodges = tonumber(dodges), healthRestored = tonumber(healed),
                damageTaken = damage, damageTakenStatus = columns[9] ~= "" and columns[9] or nil,
                damageTakenNote = columns[10] ~= "" and columns[10] or nil,
                reportFile = reportFile,
            }
        end
    end
    file:close()
    return history
end

local function appendHistory(profilePath, report)
    local columns = {}
    for _, field in ipairs({ "bossName", "timeSeconds", "attemptResult", "endedAt", "perfectGuards", "perfectDodges",
        "healthRestored", "damageTaken", "damageTakenStatus", "damageTakenNote", "reportFile" }) do
        local value = report[field]
        columns[#columns + 1] = value == nil and "" or tostring(value):gsub("[\r\n\t]", " ")
    end
    local file = assert(io.open(profilePath .. "/PBZChallengeHistory.tsv", "ab"))
    local wrote, reason = file:write(table.concat(columns, "\t") .. "\n")
    local closed, closeReason = file:close()
    assert(wrote and closed, reason or closeReason)
end

local function clearBossFlow(actor)
    if not valid(actor) then return end
    local readable, flow = pcall(function() return actor.BP_PBZFlowComponent end)
    if not readable then return end -- Some enemy classes have no story component.
    if not valid(flow) then return end
    flow.bAutoStartRootFlow = false
    if valid(flow.RootFlow) and valid(flow:GetRootFlowInstance()) then flow:FinishRootFlow(flow.RootFlow, 1) end
    flow:PBZUnregister()
end

local function destroyPalaceMobs(roots)
    local actors, seen = {}, {}
    local function collect(actor)
        if not valid(actor) or actor:IsActorBeingDestroyed() then return end
        local address = actor:GetAddress()
        if seen[address] then return end
        seen[address], actors[#actors + 1] = true, actor
        local children = actor.Children
        if children then
            children:ForEach(function(_, value)
                local wrapped, child = pcall(function() return value:get() end)
                if wrapped then value = child end
                collect(value)
            end)
        end
    end
    for _, actor in ipairs(roots) do collect(actor) end
    -- The audited mob path clears story flow when spawning. At death, avoid
    -- reading reflected Blueprint flow properties from disappearing corpses.
    for _, actor in ipairs(actors) do
        if valid(actor) and not actor:IsActorBeingDestroyed() then actor:K2_DestroyActor() end
    end
end

local function reloadChallenge(gameplay, pawn, slot, scene, onSceneChange)
    local instance = gameplay:GetGameInstance(pawn)
    assert(valid(instance), "挑战存档接口不可用")
    local result = { ResultType = 255, LevelName = "", GameModeOptions = "" }
    instance:LoadGame(slot, result)
    local map = stringValue(result.LevelName)
    local preset = scene
    local expected = preset and preset.map or ARENA_LEVEL
    assert(result.ResultType == 0 and (map == expected or map:sub(-#expected - 1) == "/" .. expected),
        "无法重载所选演武场景的挑战前存档")
    assert(not preset or stringValue(result.GameModeOptions) == (preset.gameModeOptions or ""),
        "所选场景的成年角色模式不匹配")
    if onSceneChange then onSceneChange(scene.id, gameplay, pawn) end
    if scene and scene.originalPath then
        require("StockCheckpoint").open(gameplay, pawn, scene, result)
    else
        gameplay:OpenLevel(pawn, FName(map), true, stringValue(result.GameModeOptions))
    end
end

function Challenge.returnToTitle(gameplay, pawn)
    -- Follow the stock settings panel's return route rather than quitting the
    -- process or loading a hard-coded map with the old game type still active.
    local instance = gameplay:GetGameInstance(pawn)
    assert(valid(instance), "返回主界面的游戏实例不可用")
    local native = required("/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary")
    local subsystem = required("/Script/Engine.Default__SubsystemBlueprintLibrary")
        :GetWorldSubsystem(pawn, required("/Script/ProjectPBZ.PBZGameSystem"))
    assert(valid(subsystem), "返回主界面的游戏系统不可用")
    instance:EndTutorial()
    instance:ChangeGameType(0)
    if subsystem:InTutorial() then
        instance:SetDemoVersionLoadingScreen(true)
    else
        local packageVersion = subsystem:GetPackageVersion()
        if packageVersion == 0 then instance:SetLoadingScreen("PBZ_WP")
        elseif packageVersion == 1 then instance:SetDemoVersionLoadingScreen(false) end
    end
    local dataPolicy = native:GetGameDataPolicy()
    assert(valid(dataPolicy) and valid(dataPolicy.StartMenuPolicy), "返回主界面的场景策略不可用")
    local result = {}
    dataPolicy.StartMenuPolicy:GetCorrectStartMenuMapName(result)
    local map = stringValue(result.MapName)
    assert(map ~= "" and map ~= "None", "返回主界面的地图名称不可用")
    -- TitleSession restores the original master/current/Continue caches after
    -- arrival, with its save barrier still armed throughout this transition.
    gameplay:OpenLevel(pawn, FName(map), true, "")
end

local function showZhan(gameplay, pawn)
    for _, widget in ipairs(FindAllOf("W_BossDead_Red_C") or {}) do
        if valid(widget) and widget:IsActivated() then return end
    end
    local library = required("/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary")
    local player = library:GetLocalPlayer(gameplay:GetPlayerController(pawn, 0))
    assert(valid(player), "无法取得原版结算界面的本地玩家")
    local class = CombatSpawn.class("/Game/PBZContent/UI/InGame/Dead/W_BossDead_Red.W_BossDead_Red_C")
    local extensions = required("/Script/CommonGame.Default__CommonUIExtensions")
    return extensions:PushContentToLayer_ForPlayer(player, { TagName = FName("UI.Layer.Game") }, class)
end

local function spawnBoss(entry, enemyCycle, gameplay, system, pawn, occupied, scene, nativeEncounter, mounts, prepareChiLian,
    palaceMechanics, statCycles, classPlan, spawnClearance, arrivalPreload, spawnSlot)
    local mathLibrary = required("/Script/Engine.Default__KismetMathLibrary")
    local spawner = required("/Script/SGameAI.Default__SGameAIFunctionLibrary")
    local class, reason
    if classPlan then
        class, reason = classPlan:resolve(entry.classPath)
    else
        class, reason = SpawnClass.resolve(entry.classPath, arrivalPreload)
    end
    if not valid(class) then return nil, nil, reason end
    local playerView = pawn:K2_GetActorLocation()
    local playerPosition = { X = playerView.X, Y = playerView.Y, Z = playerView.Z }
    scene = scene or ArenaScenes.get("night")
    local authored = nativeEncounter and scene.lengtuSpawn
    local candidates = authored and { authored.location }
        or spawnSlot and { scene.spawnPoints[spawnSlot] } or scene.spawnPoints
    local minimumDistance = entry.regularMob and 1100 or (spawnClearance or 3000)
    local failures = {}
    for index, candidate in ipairs(candidates) do
        local top = { X = candidate.X, Y = candidate.Y, Z = authored and candidate.Z + 300 or scene.spawnTrace.top }
        local bottom = { X = candidate.X, Y = candidate.Y, Z = authored and candidate.Z - 500 or scene.spawnTrace.bottom }
        local hit = {}
        local found = system:LineTraceSingle(pawn, top, bottom, 0, false, {}, 0, hit, true, NO_COLOR, NO_COLOR, 0)
        if (entry.regularMob or scene.spawnTrace.worldStaticFallback) and not found then
            hit = {}
            found = system:LineTraceSingleForObjects(pawn, top, bottom, { 0 }, false, {}, 0, hit, true, NO_COLOR, NO_COLOR, 0)
        end
        local failure
        if not found then failure = "未碰到地面"
        elseif not hit.ImpactPoint or not hit.ImpactNormal then failure = "地面命中数据未就绪"
        else
            -- OutHit vectors are borrowed views into native parameter storage.
            -- Copy their scalars before any subsequent native call can reuse it.
            local ground = { X = hit.ImpactPoint.X, Y = hit.ImpactPoint.Y, Z = hit.ImpactPoint.Z }
            local normalZ = hit.ImpactNormal.Z
            if not (normalZ >= 0.7) then failure = "地面法线不足0.70"
            else
                local location = { X = ground.X, Y = ground.Y, Z = ground.Z + (entry.capsuleHalfHeight or 180) + 6 }
                local clear = true
                for _, actor in ipairs(occupied or {}) do
                    if valid(actor) and distanceSquared(location, actor:K2_GetActorLocation()) < 750^2 then clear = false end
                end
                if not clear then failure = "与已有首领距离不足750"
                elseif distanceSquared(location, playerPosition) < minimumDistance^2 then failure = "与玩家距离不足" .. minimumDistance
                else
                    local yaw = authored and authored.rotation.Yaw or mathLibrary:FindLookAtRotation(location, playerPosition).Yaw
                    local rotation, scale = { Pitch = 0, Yaw = yaw, Roll = 0 }, { X = 1, Y = 1, Z = 1 }
                    local chiLian
                    if ChiLianArena.required(entry) then
                        local reason, tryNext
                        chiLian, reason, tryNext = prepareChiLian(ground, rotation)
                        if not chiLian then
                            if not tryNext then return nil, nil, reason end
                            failure = reason
                        end
                    end
                    local transform, deferred
                    if not failure then
                        transform = mathLibrary:MakeTransform(location, rotation, scale)
                        deferred = spawner:SpawnActorDeferred(pawn, class, transform, 3)
                    end
                    if valid(deferred) then
                        local capsule = deferred.CapsuleComponent
                        if valid(capsule) then
                            location.Z = ground.Z + capsule:GetScaledCapsuleHalfHeight() + 6
                            transform = mathLibrary:MakeTransform(location, rotation, scale)
                        end
                        -- Bind before FinishSpawningActor: BeginPlay can grant and
                        -- immediately activate this boss's internal summon GAs.
                        if nativeEncounter then nativeEncounter:bindBoss(deferred) end
                        if chiLian then chiLian:bind(deferred) end
                        if palaceMechanics then palaceMechanics:bind(deferred, entry.id, ground) end
                        if entry.regularMob then PalaceMechanics.prepareAppearance(deferred, entry.id) end
                        if JingYeMount.required(entry) then
                            local prepared, mount, pending = pcall(function()
                                local session, reason = JingYeMount.new(pawn, gameplay, ground, rotation)
                                if session then
                                    mounts[#mounts + 1] = session -- retain if binding/Finish fails
                                    session:bind(deferred)
                                end
                                return session, reason
                            end)
                            if not prepared then
                                if valid(deferred) then deferred:K2_DestroyActor() end
                                error(mount, 0)
                            end
                            if not mount then
                                deferred:K2_DestroyActor()
                                return nil, nil, pending
                            end
                        end
                        return CombatSpawn.finish(gameplay, pawn, deferred, transform, enemyCycle, true, statCycles)
                    end
                    failure = failure or "延迟生成返回无效对象"
                end
            end
        end
        failures[#failures + 1] = ("候选%d：%s"):format(spawnSlot or index, failure)
    end
    return nil, nil, table.concat(failures, "；"), spawnSlot
end

function Challenge.new(entry, enemyCycle, profilePath, playerCycle, skillLevel, slots)
    slots = slots or {}
    if playerCycle ~= nil then skillLevel = PlayerProfile.normalizeSkillLevel(playerCycle, skillLevel) end
    assert(entry and not Encounters.isRetired(entry.id) and entry.adapter ~= "lengtu", "此挑战已撤下或不可用")
    for _, stage in ipairs(entry.stages or {}) do
        for _, member in ipairs(stage.members or {}) do
            assert(member.id ~= "BP_Monster_LengTu", "梦差冷荼挑战已撤下")
        end
    end
    -- Single-boss callers from older launchers remain valid. New selections are
    -- resolved against the encounter catalog before reaching this constructor.
    if not entry.stages then
        entry = { id = entry.id, name = entry.name, category = "duel", categoryName = "一决高下",
            stages = { { members = { entry } } } }
    end
    assert(#entry.stages > 0, "挑战尚未完成场景适配")
    local mode = slots.mode or "challenge"
    local customPressure = (mode == "practice" or mode == "challenge") and Difficulty.copyPressure(slots.customPressure) or nil
    local scene = ArenaScenes.forEncounter(entry.id, slots.sceneId, mode)
    local resetSlot = slots.resetSlot
    if resetSlot and playerCycle ~= nil then
        resetSlot = PlayerProfile.slot(playerCycle, slots.cyclePrefix or "PBZArenaCycle", scene.id)
    end
    local self = setmetatable({
        entry = entry, enemyCycle = enemyCycle, profilePath = profilePath,
        playerCycle = playerCycle, skillLevel = skillLevel, slot = resetSlot or RESET_SLOT,
        cyclePrefix = slots.cyclePrefix or "PBZArenaCycle", history = readHistory(profilePath),
        status = "waiting", message = "等待" .. scene.name .. "的挑战场地加载",
        stageIndex = 1, bosses = {}, ownedActors = {},
        mode = mode, customPressure = customPressure,
        difficultyMode = customPressure and Difficulty.customBase or slots.difficultyMode or 3,
        musicId = Music.normalize(slots.musicId),
        sceneId = scene.id, scene = scene,
        onSceneChange = slots.onSceneChange,
        onBeforeLoad=slots.onBeforeLoad,loadoutMemoryPath=slots.loadoutMemoryPath,
        skillMemory = slots.skillMemory, selectCheckpoint = slots.selectCheckpoint, onBellSave = slots.onBellSave,
    }, Challenge)
    self.onMenuAction = function(action, settings) self:queueAction(action, settings) end
    if slots.resetSlot and skillLevel ~= nil then
        self.ability = require("AbilityChallenge")
        self.pendingSkillLevel = skillLevel
    end
    if scene.bellMetadataId then
        local bellId = FName(scene.bellSaveId, 1)
        assert(bellId:ToString() == scene.bellSaveId, "浊梦铃铛编号无法注册")
        local metadataId = FName(scene.bellMetadataId)
        -- The stock widget reads authored bell metadata during activation.
        -- Translate that read only. The actor and its interaction keep their own ID.
        self.bellDataHook = { RegisterHook(BELL_DATA, function(_, id)
            if self.bellDataHook and id:get():ToString() == scene.bellSaveId then id:set(metadataId) end
        end) }
    end
    return self
end

function Challenge:canUseBell()
    if self.palace then return self.status ~= "error" and self.palace:canUseBell() end
    return self.status ~= "won" and self.status ~= "error" and self.view ~= "victory"
        and not self.startedAt and not self.reloadAt and not self.reloadRequested
end

function Challenge:menuState(available)
    local arena = self.scene.runtimeModule and require(self.scene.runtimeModule)
    return {
        available = available, bossId = self.entry.id, bossName = self.entry.name,
        playerCycle = self.playerCycle or 0, enemyCycle = self.enemyCycle, skillLevel = self.skillLevel or 0,
        history = self.history, profilePath = self.profilePath, category = self.entry.category, mode = self.mode,
        difficultyMode = self.difficultyMode, customPressure = self.customPressure,
        playerProfile = PlayerProfile.id(self.playerCycle or 0),
        sceneId = self.sceneId, sceneName = self.scene.name, bellId = self.scene.bellSaveId,
        bellName = self.scene.bellName,
        palacePracticeFloor = self.palace and self.palace.practiceFloor,
        musicId = self.musicId, runtimeModule = self.scene.runtimeModule,
        requireBellOwner = arena ~= nil, bellOwner = arena and arena.getBell() or nil,
    }
end

local function cycleValue(value)
    if type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 6 then return value end
end

function Challenge:queueAction(action, settings)
    if not self.action then self.action = { name = action, settings = settings } end
end

function Challenge:checkpointLoadout(pawn,slot)
    if self.onBeforeLoad then
        local ok,why=pcall(self.onBeforeLoad,pawn,slot)
        if not ok and self.loadoutCheckpointError~=why then print("[PBZTestArenaNative] Arena preference checkpoint: "..tostring(why).."\n")end
        self.loadoutCheckpointError=not ok and why or nil
    end
end

function Challenge:applyAbilityLoadout(pawn)
    self.ability = self.ability or require("AbilityChallenge")
    self.ability.setProfile(pawn, PlayerProfile.id(self.playerCycle))
    self.abilityProfilePawn = pawn
    if self.playerCycle == -1 then
        self.ability.setCycleSkills(pawn, 0)
        if self.pendingSkillLevel ~= nil then self.pendingSkillLevel = 0 end
    end
    if self.skillMemory and not self.loadoutApplied and not self.abilityLoadout then
        local restored = self.skillMemory:apply(pawn, self.ability, self.skillLevel)
        if restored then
            self.abilityLoadout, self.loadoutApplied, self.pendingSkillLevel = restored, true, nil
        end
    end
    if self.abilityLoadout and not self.loadoutApplied then
        self.ability.restore(pawn, self.abilityLoadout)
        if self.playerCycle == -1 then self.abilityLoadout = self.ability.capture(pawn) end
        self.loadoutApplied = true
    end
    if self.pendingSkillLevel then
        self.ability.setCycleSkills(pawn, self.pendingSkillLevel)
        self.abilityLoadout = self.ability.capture(pawn)
        self.loadoutApplied, self.pendingSkillLevel = true, nil
    end
end

function Challenge:command(gameplay, system, pawn, realNow, command)
    local action, settings = command.name, command.settings
    local victory = self.view == "victory"
    if action == "configure" and not victory and (not self.palace or self.bellOpen and self:canUseBell()) then
        -- The original ability screen is pushed onto the bell's own menu stack.
        if not Menu.suspend() then return end
        local ability = require("AbilityChallenge")
        self.abilityBeforeEdit = nil
        local opened, result = pcall(function()
            if self.skillMemory and self.playerCycle ~= nil then
                self:applyAbilityLoadout(pawn)
                self.abilityBeforeEdit = ability.capture(pawn)
            elseif self.playerCycle == -1 then
                ability.setProfile(pawn, "lao")
                ability.setCycleSkills(pawn, 0)
                self.abilityProfilePawn = pawn
            end
            return ability.open(gameplay, pawn)
        end)
        if opened and result == true then
            self.ability, self.view = ability, "ability"
        else
            pcall(ability.close)
            Menu.resume(realNow)
            print("[PBZTestArenaNative] Ability menu: " .. tostring(result) .. "\n")
        end
        return
    end
    if self.palace then
        if action == "palace-exit" and (not self.palace.arenaEntered or self.palace.state == "result") then
            self:checkpointLoadout(pawn, nil)
            self:close()
            self.reloadRequested = true
            Challenge.returnToTitle(gameplay, pawn)
        elseif self.bellOpen and self:canUseBell()
            and action == "palace-start" then
            Menu.close()
            self.bellOpen = false
            self.palace:bellAction(self, action, realNow)
        end
        return
    end
    if action == "target" and not victory then
        if not Menu.suspend() then return end
        local target = require("ChallengeTarget")
        local opened, result = pcall(target.open, gameplay, pawn, self:menuState(true), function(chosen)
            self:queueAction("change", chosen)
        end, function() end)
        if opened and result == true then
            self.target, self.view = target, "target"
        else
            pcall(target.close)
            Menu.resume(realNow)
            print("[PBZTestArenaNative] Target menu: " .. tostring(result) .. "\n")
        end
        return
    end
    if action == "exit" and victory then
        self:checkpointLoadout(pawn,nil)
        self:close()
        self.reloadRequested = true
        self.status, self.message = "leaving", "正在返回主界面"
        Challenge.returnToTitle(gameplay, pawn)
        return
    end
    if action == "change" and type(settings) == "table" then
        local playerCycle = tonumber(settings.playerCycle)
        local enemyCycle = cycleValue(tonumber(settings.enemyCycle))
        local entry = Encounters.resolve(settings.bossId or "")
        if not entry or not PlayerProfile.valid(playerCycle) or enemyCycle == nil then return end
        local defaultSkill = self.playerCycle == playerCycle and self.skillLevel or PlayerProfile.skillCap(playerCycle)
        local selectedSkill = PlayerProfile.normalizeSkillLevel(playerCycle,
            settings.skillLevel == nil and defaultSkill or tonumber(settings.skillLevel))
        if not selectedSkill or selectedSkill % 1 ~= 0 or selectedSkill < 0
            or selectedSkill > PlayerProfile.skillCap(playerCycle) then return end
        local validPressure, customPressure = pcall(Difficulty.copyPressure, settings.customPressure)
        if not validPressure then return end
        if customPressure and not require("DreamPalacePressure").available() then return end
        local difficulty = customPressure and Difficulty.customBase or settings.difficultyMode or self.difficultyMode
        if not Difficulty.valid(difficulty) then return end
        local sceneOk, scene = pcall(ArenaScenes.forEncounter, entry.id, settings.sceneId or self.sceneId, self.mode)
        if not sceneOk or not ArenaScenes.available(scene.id, self.mode) then return end
        self.slot = PlayerProfile.slot(playerCycle, self.cyclePrefix, scene.id)
        if self.playerCycle ~= playerCycle or (self.skillMemory and selectedSkill ~= defaultSkill) then
            self.abilityLoadout = nil
        end
        self.pendingScene = scene.id ~= self.sceneId and scene or nil
        if selectedSkill ~= defaultSkill or self.playerCycle ~= playerCycle then
            self.ability = require("AbilityChallenge")
            self.pendingSkillLevel = selectedSkill
        end
        self.skillLevel = selectedSkill
        self.difficultyMode, self.customPressure = difficulty, customPressure
        self.musicId = Music.normalize(settings.musicId or self.musicId)
        self.entry, self.playerCycle, self.enemyCycle = entry, playerCycle, enemyCycle
    elseif action ~= "retry" or (not victory and (not self.scene.runtimeModule or not self:canUseBell())) then return end
    self:checkpointLoadout(pawn,self.slot)
    if victory then Victory.close() else Menu.close() end
    self.view, self.bellOpen = nil, false
    self.status, self.message, self.reloadAt = "resetting", "正在重读挑战存档", realNow
    if action == "retry" then RetryPreload.start(self, gameplay, pawn, realNow)
    else RetryPreload.close(self) end
end

function Challenge:owns(actor)
    if not valid(actor) then return false end
    if self.encounterWorld then
        local readable, world = pcall(function() return actor:GetWorld() end)
        if not readable or not valid(world) or world:GetAddress() ~= self.encounterWorld then return false end
    end
    if self.lengtu and self.lengtu:owns(actor) then return true end
    if self.chiLianArena and self.chiLianArena:owns(actor) then return true end
    for _, mount in ipairs(self.mounts or {}) do if mount:owns(actor) then return true end end
    local candidate = actor
    for _ = 1, 8 do
        if not valid(candidate) then return false end
        if self.ownedActors[candidate:GetAddress()] then return true end
        local ok, owner = pcall(function() return candidate:GetOwner() end)
        if not ok or owner == candidate then return false end
        candidate = owner
    end
    return false
end

function Challenge:clearMounts()
    local pending, errors = {}, {}
    for _, mount in ipairs(self.mounts or {}) do
        local ok, reason = pcall(mount.close, mount)
        if not ok then pending[#pending + 1] = mount; errors[#errors + 1] = tostring(reason) end
    end
    self.mounts = #pending > 0 and pending or nil
    self.mountCleanupError = #errors > 0 and table.concat(errors, "; ") or nil
    self.mountPreparation = nil
    if self.mountCleanupError then print("[PBZJingYeMount] cleanup pending: " .. self.mountCleanupError .. "\n") end
end

function Challenge:updateMounts()
    local running = (self.awake == true or self.transitionStep == "engage")
        and self.status ~= "won" and not self.reloadAt
        and not (self.practice and self.practice.state.ai == false)
    for _, mount in ipairs(self.mounts or {}) do mount:update(running == true) end
end

function Challenge:clearChiLianArena()
    if not self.chiLianArena then return end
    local cleaned, reason = pcall(self.chiLianArena.close, self.chiLianArena)
    if cleaned then self.chiLianArena, self.chiLianCleanupError = nil, nil
    else
        self.chiLianCleanupError = tostring(reason)
        print("[PBZChiLianArena] cleanup pending: " .. self.chiLianCleanupError .. "\n")
    end
end

function Challenge:closeStagePressure()
    local pressure = self.pressure
    if not pressure then return end
    self.pressure = nil
    local closed, failure = pcall(pressure.close, pressure)
    if not closed then print("[PBZTestArenaNative] AI pressure cleanup: " .. tostring(failure) .. "\n") end
end

local function usesPreparedPracticeTransition(challenge)
    return challenge.mode == "practice" and challenge.sceneId == "xigu" and challenge.entry.id == "gauntlet_hookman"
end

local function phasePreloadFor(challenge, pawn)
    local scope = challenge.phasePreloadScope
    if scope and scope.pawn == pawn:GetAddress() and scope.world == pawn:GetWorld():GetAddress() then
        return challenge.phasePreloadPlan
    end
end

local function arrivalPreloadFor(challenge, pawn)
    local palace = challenge.palace
    local preload = palace and challenge.stageIndex == 1 and palace.arrivalPreload
    if preload and preload.floor == palace.floor and preload:matches(pawn) then return preload end
end

local function closeGauntletPreload(challenge, reason)
    local preload = challenge.gauntletPreload
    challenge.gauntletPreload = nil
    if preload then preload:close(reason) end
end

local function gauntletPreloadFor(challenge, pawn, stageIndex)
    local preload = challenge.gauntletPreload
    if not preload then return end
    if preload:matches(challenge, pawn, stageIndex) then return preload end
    closeGauntletPreload(challenge, "scope-changed")
end

local function advanceGauntletOpening(challenge, gameplay, system, pawn)
    local category = challenge.entry.category
    if challenge.palace or challenge.practicePhaseTransition
        or (category ~= "gauntlet" and category ~= "custom_gauntlet")
        or gameplay:IsGamePaused(pawn) then return end
    local preload = gauntletPreloadFor(challenge, pawn, challenge.stageIndex + 1)
    if not preload then
        preload = require("GauntletPreload").new(challenge, pawn)
        challenge.gauntletPreload = preload
    end
    if preload then preload:advance(gameplay, system, pawn, "fade-out") end
end

local function stagePreloadFor(challenge, pawn)
    local preload = challenge.stagePreload
    if not preload then return end
    if preload.stage == challenge.entry.stages[challenge.stageIndex]
        and preload.pawn == pawn:GetAddress() and preload.world == pawn:GetWorld():GetAddress() then
        return preload
    end
    challenge.stagePreload = nil
end

-- Advance only while an existing transition covers the scene. If a class is
-- still unavailable, retain any successful proofs and allow the usual spawn
-- resolver to finish preparation under the same cover.
local function prepareCoveredStage(challenge, gameplay, system, pawn, realNow)
    if challenge.practicePhaseTransition and phasePreloadFor(challenge, pawn) then return true end
    local preload = stagePreloadFor(challenge, pawn)
    if not preload then
        preload = { stage = challenge.entry.stages[challenge.stageIndex], pawn = pawn:GetAddress(),
            world = pawn:GetWorld():GetAddress(), deadline = realNow + 2 }
        challenge.stagePreload = preload
    end
    if preload.finished then return true end
    local arrival = arrivalPreloadFor(challenge, pawn)
    if arrival and not arrival:stepCovered(pawn, gameplay, realNow, preload.deadline) then return false end
    local gauntlet = gauntletPreloadFor(challenge, pawn, challenge.stageIndex)
    if gauntlet then
        if gameplay:IsGamePaused(pawn) then return false end
        -- Use only the opening part of the existing black-screen hold.
        local deadline = math.min(preload.deadline, challenge.stageFade.blackAt + 0.25)
        if not gauntlet:stepCovered(gameplay, system, pawn, realNow, deadline) then return false end
    end
    if realNow >= preload.deadline then
        preload.finished = true
        print("[PBZTestArenaNative] Stage preload timed out: " .. tostring(preload.lastReason or challenge.entry.id) .. "\n")
        return true
    end
    local ok, done, reason = pcall(function()
        preload.plan = preload.plan or SpawnClass.preload(preload.stage.members, arrival or gauntlet)
        return preload.plan:step()
    end)
    if not ok then
        preload.plan, preload.finished = nil, true
        print("[PBZTestArenaNative] Stage preload fallback: " .. tostring(done) .. "\n")
        return true
    end
    preload.finished, preload.lastReason = done, reason
    return done
end

function Challenge:closeMobPressure()
    local session = self.mobPressure
    if not session then return end
    self.mobPressure = nil
    session:close()
end

function Challenge:clearStage(retirePracticeBossBars, keepGauntletPreload)
    self.palaceFormationRetry = nil
    if not keepGauntletPreload then closeGauntletPreload(self, "stage-cleared") end
    self.stagePreload = nil
    if not retirePracticeBossBars then self.practicePhaseTransition, self.phasePreloadPlan, self.phasePreloadScope = nil, nil, nil end
    self:closeStagePressure()
    self:closeMobPressure()
    if self.fengXuePursuit then
        self.fengXuePursuit:close()
        self.fengXuePursuit = nil
    end
    -- Release native UI registrations while our stage actors still exist.
    local retiring = retirePracticeBossBars and self.bosses or nil
    local cleared, reason = pcall(function() require("PracticeBossInfo").close(retiring) end)
    if not cleared then print("[PBZTestArenaNative] Practice boss info cleanup: " .. tostring(reason) .. "\n") end
    self.practiceBossInfoFault, self.practiceBossInfoRetryAt = nil, nil
    -- Original snake helpers retain unowned summon references. Collect/cancel
    -- them before generic cleanup destroys their native BP containers.
    self:clearChiLianArena()
    -- Cancel native horse spawns while the rider script still exists. Retain
    -- failed cleanup handles so a retry cannot create an untracked second mount.
    self:clearMounts()
    if self.palaceMechanics then
        self.palaceMechanics:close()
        self.palaceMechanics = nil
    end
    self.engageRequests, self.engageNextPoll, self.engageNextLog = nil, nil, nil
    self.groupAggro = nil
    -- Remove only this encounter's actors and owner-linked summons. Never scan
    -- by location alone: the scene's authored NPCs are not ours to destroy.
    local stage = self.entry.stages[self.stageIndex]
    if self.palace and stage and stage.regularMobs then
        destroyPalaceMobs(self.bosses)
    else
        local actors, seen = {}, {}
        for _, actor in ipairs(FindAllOf("Actor") or {}) do
            if self:owns(actor) and not seen[actor:GetAddress()] then
                actors[#actors + 1], seen[actor:GetAddress()] = actor, true
            end
        end
        for _, actor in ipairs(self.bosses) do
            if valid(actor) and not seen[actor:GetAddress()] then actors[#actors + 1] = actor end
        end
        for _, actor in ipairs(actors) do
            pcall(clearBossFlow, actor)
            pcall(function() actor:K2_DestroyActor() end)
        end
    end
    if self.lionArena then
        local cleaned,reason=pcall(self.lionArena.close,self.lionArena)
        if cleaned then self.lionArena=nil; self.lionArenaCleanupError=nil
        else
            self.lionArenaCleanupError=tostring(reason)
            print("[PBZLionArena] cleanup pending: "..tostring(reason).."\n")
        end
    end
    if self.lengtu then
        local cleaned, reason = pcall(self.lengtu.close, self.lengtu)
        if cleaned then self.lengtu, self.markerCleanupError = nil, nil
        else
            self.markerCleanupError = tostring(reason)
            print("[PBZTestArenaNative] LengTu summon cleanup pending: " .. self.markerCleanupError .. "\n")
        end
    end
    self.bosses, self.ownedActors, self.boss, self.awake = {}, {}, nil, false
end

function Challenge:prepareNativeEncounter(gameplay, system, pawn)
    if self.markerCleanupError and self.lengtu then
        local cleaned, reason = pcall(self.lengtu.close, self.lengtu)
        if not cleaned then self.spawnWaitReason = "等待冷荼助战控制清理：" .. tostring(reason); return false end
        self.lengtu, self.markerCleanupError = nil, nil
    end
    if self.entry.adapter ~= "lengtu" then return true end
    assert(self.sceneId == "cliff", "冷荼连战必须使用原断魂崖场景")
    if self.lengtu then return self.lengtu:update(pawn) end
    -- In its authored arena, retain all five original snap points and the
    -- original enemy summon/nav/phase behavior. Only friendly support is off.
    local session, reason = require("LengTuSummons").new(pawn)
    if not session then self.spawnWaitReason = reason; return false end
    self.lengtu, self.spawnWaitReason = session, nil
    return true
end

local function spawnWait(self, gameplay, pawn, reason)
    self.spawnWaitReason = reason
    if not reason then
        self.lastSpawnWaitLog, self.nextSpawnWaitLog = nil, nil
    elseif reason ~= self.lastSpawnWaitLog then
        local now = gameplay:GetRealTimeSeconds(pawn)
        if now >= (self.nextSpawnWaitLog or -math.huge) then
            print("[PBZTestArenaNative] Boss spawn waiting [" .. self.entry.id .. ", stage " .. self.stageIndex .. "]: " .. reason .. "\n")
            self.lastSpawnWaitLog, self.nextSpawnWaitLog = reason, now + 2
        end
    end
end

function Challenge:bindStagePressure(pawn)
    local rule = self.customPressure
    if self.palace then rule = self.entry.pressureFloor end
    if not rule then return end
    local targets = {}
    for index, member in ipairs(self.entry.stages[self.stageIndex].members) do
        if not member.regularMob or (self.palace and member.applyPressure) then
            targets[#targets + 1] = { actor = self.bosses[index], id = member.id }
        end
    end
    if #targets == 0 then return end
    local Pressure = require("DreamPalacePressure")
    local ok, run = pcall(function()
        assert(Pressure.available(), "当前游戏或 UE4SS 版本不支持 AI 压力")
        return Pressure.new(pawn, targets, rule, self.stageIndex)
    end)
    if ok then
        self.pressure = run
        if self.palace then
            print(("[PBZBloodyPalace] AI pressure configured floor=%d stage=%d targets=%d\n")
                :format(rule, self.stageIndex, #targets))
        end
    else
        print(("[PBZTestArenaNative] AI pressure unavailable target=%s stage=%d rule=%s reason=%s\n")
            :format(self.entry.id, self.stageIndex, type(rule) == "table" and rule.mode or rule, tostring(run)))
    end
end

function Challenge:finishMountPreparation(gameplay, pawn)
    local pending = self.mountPreparation
    assert(pending and pending.stage == self.stageIndex
        and pending.world == pawn:GetWorld():GetAddress(), "荆野准备阶段或场景已改变")
    for _, mount in ipairs(self.mounts or {}) do
        local ready, reason = mount:prepare(gameplay:GetRealTimeSeconds(pawn))
        if not ready then spawnWait(self, gameplay, pawn, reason); return false end
    end
    self.boss, self.level = pending.actors[1], pending.levels[1]
    self.mountPreparation = nil
    self.stagePreload = nil
    self:bindStagePressure(pawn)
    spawnWait(self, gameplay, pawn, nil)
    return true
end

function Challenge:spawnStage(gameplay, system, pawn)
    if self.mountCleanupError then
        self:clearMounts()
        if self.mountCleanupError then spawnWait(self, gameplay, pawn, self.mountCleanupError); return false end
    end
    -- Async native horse spawning must retain this rider; do not spawn another
    -- copy on each normal asset/ground retry, or arm aggro before the horse exists.
    if self.mountPreparation then return self:finishMountPreparation(gameplay, pawn) end
    if self.chiLianCleanupError then
        self:clearChiLianArena()
        if self.chiLianCleanupError then spawnWait(self, gameplay, pawn, self.chiLianCleanupError); return false end
    end
    if not self:prepareNativeEncounter(gameplay, system, pawn) then return false end
    if self.lionArenaCleanupError then
        assert(self.lionArena,"舞狮机制清理记录不完整")
        self.lionArena:close()
        self.lionArena,self.lionArenaCleanupError=nil,nil
    end
    local stage = self.entry.stages[self.stageIndex]
    local slots, formationReason = PalaceFormation.prepare(self, stage, pawn)
    if formationReason then spawnWait(self, gameplay, pawn, formationReason); return false end
    if LionArena.required(stage) and not self.lionArena then
        local area,reason=LionArena.new(pawn,self.scene,gameplay,system)
        if not area then spawnWait(self,gameplay,pawn,reason); return false end
        self.lionArena=area
    end
    if not self.palaceMechanics then
        local mechanics, reason = PalaceMechanics.new(pawn, gameplay, system, self.scene, stage,
            self.stageIndex < #self.entry.stages, not self.palace)
        if reason then spawnWait(self, gameplay, pawn, reason); return false end
        self.palaceMechanics = mechanics
    end
    local actors, levels = {}, {}
    local statCycles = self.palace and self.entry.statCycles or nil
    local spawnClearance = self.stageIndex > 1 and self.scene.phaseSpawnClearance or self.scene.spawnClearance
    local function prepareChiLian(ground, rotation)
        if self.chiLianArena then return self.chiLianArena end
        local arena, reason, tryNext = ChiLianArena.new(pawn, gameplay, system, ground, rotation, self.scene)
        if arena then self.chiLianArena = arena end
        return arena, reason, tryNext
    end
    self.mounts = {}
    local prepared = stagePreloadFor(self, pawn)
    local classPlan = prepared and prepared.plan or self.stageIndex == 1 and self.entryPreloadPlan or nil
    if self.stageIndex == 2 and self.practicePhaseTransition then
        classPlan = phasePreloadFor(self, pawn) or classPlan
    end
    local ok, failure = pcall(function()
        local arrival = arrivalPreloadFor(self, pawn)
        for index, member in ipairs(stage.members) do
            local cycle = self.enemyCycle
            if self.palace then cycle = member.enemyCycle or stage.enemyCycle or cycle end
            local actor, level, reason, rejectedSlot = spawnBoss(member, cycle, gameplay, system, pawn, actors, self.scene,
                self.lengtu, self.mounts, prepareChiLian, self.palaceMechanics, member.statCycles or statCycles,
                classPlan, spawnClearance, arrival, slots and slots[index])
            if not valid(actor) then
                if rejectedSlot then PalaceFormation.reject(self, stage, rejectedSlot) end
                spawnWait(self, gameplay, pawn, reason or "候选生成条件未满足")
                return
            end
            actors[#actors + 1], levels[#levels + 1] = actor, level
            if self.palace then PalaceMechanics.stabilizeAppearance(actor, member.id) end
            -- Authored story flows may open cutscenes or replace the arena.
            -- Combat abilities and AI remain on the spawned character.
            clearBossFlow(actor)
            if not member.regularMob then
                local ability = required("/Script/ProjectPBZ.Default__PBZAbilityBlueprintLibrary")
                local asc = actor.AbilitySystemComponent
                assert(valid(asc), "挑战首领没有能力组件")
                local tag = { TagName = FName("CharacterType.AI.Boss") }
                if asc:GetGameplayTagCount(tag) == 0 then
                    assert(ability:AddLooseGameplayTag(actor, tag, false), "无法启用原版首领战斗状态")
                end
            end
        end
    end)
    if not ok or #actors ~= #stage.members then
        self:clearMounts()
        self:clearChiLianArena()
        if self.palaceMechanics then
            self.palaceMechanics:close()
            self.palaceMechanics = nil
        end
        if self.palace and stage.regularMobs then
            destroyPalaceMobs(actors)
        else
            for _, actor in ipairs(actors) do
                pcall(clearBossFlow, actor)
                pcall(function() actor:K2_DestroyActor() end)
            end
        end
        if not ok then error(failure, 0) end
        return false
    end
    self.palaceFormationRetry = nil
    self.bosses = actors
    RetryPreload.close(self)
    self.encounterWorld = pawn:GetWorld():GetAddress()
    self.ownedActors = {}
    for _, actor in ipairs(actors) do self.ownedActors[actor:GetAddress()] = true end
    if self.sceneId == "xigu" then
        print(("[PBZXiguArena] boss stage spawned target=%s stage=%d count=%d\n")
            :format(self.entry.id, self.stageIndex, #actors))
    end
    if #self.mounts > 0 then
        self.mountPreparation = { actors = actors, levels = levels, stage = self.stageIndex, world = self.encounterWorld }
        return self:finishMountPreparation(gameplay, pawn)
    end
    self.mounts = nil
    self.boss, self.level = actors[1], levels[1]
    self.stagePreload = nil
    self:bindStagePressure(pawn)
    spawnWait(self, gameplay, pawn, nil)
    return true
end

function Challenge:closeMusic()
    if self.music then self.music:close(); self.music = nil end
end

function Challenge:updateMusic(gameplay, pawn, now)
    if self.palace then return end
    if self.reloadAt or self.reloadRequested or self.status == "error" or self.status == "won" then
        self:closeMusic()
        return
    end
    if self.musicFailed then return end
    if not self.music then
        if now < (self.musicRetryAt or 0) then return end
        local cue, target = Music.resolve(self.entry, self.musicId)
        if not cue then
            self.musicFailed = true
            print("[PBZArenaMusic] 未找到目标的原版战斗曲 " .. tostring(target) .. "\n")
            return
        end
        local player, reason = Music.new(gameplay, pawn, cue)
        if not player then
            self.musicRetryAt = now + 1
            if self.musicError ~= reason then print("[PBZArenaMusic] " .. tostring(reason) .. "\n") end
            self.musicError = reason
            return
        end
        self.music, self.musicError = player, nil
    end
    local ok, reason = pcall(self.music.update, self.music, now, self.startedAt ~= nil)
    if ok then
        if reason then self.musicErrors = 0 end
        return
    end
    self.musicErrors = (self.musicErrors or 0) + 1
    if self.musicError ~= reason then print("[PBZArenaMusic] " .. tostring(reason) .. "\n") end
    self.musicError = reason
    if self.musicErrors >= 3 then self:closeMusic(); self.musicFailed = true end
end

local function releaseBellData(self)
    if not self.bellDataHook then return end
    local hook = self.bellDataHook
    self.bellDataHook = nil
    pcall(UnregisterHook, BELL_DATA, table.unpack(hook))
end

function Challenge:close(mapTransition)
    RetryPreload.close(self, mapTransition)
    self:closeStagePressure()
    self:closeMusic()
    self.musicRetryAt, self.musicError, self.musicErrors, self.musicFailed = nil, nil, nil, nil
    if self.palace then self.palace:close() end
    self:closeTransition()
    pcall(function() require("PracticeHud").close() end)
    if self.practice then pcall(self.practice.close, self.practice); self.practice = nil end
    self.practiceFault, self.practiceRetryAt = nil, nil
    self.practiceHudFault, self.practiceHudRetryAt = nil, nil
    self.practiceBossInfoFault, self.practiceBossInfoRetryAt = nil, nil
    if self.difficulty then pcall(self.difficulty.close, self.difficulty); self.difficulty = nil end
    if self.ability and self.ability.clearProfile then self.ability.clearProfile(self.abilityProfilePawn) end
    self.abilityProfilePawn, self.openingLoadout = nil, nil
    self.roundMedicine, self.medicineDeadline = nil, nil
    if self.observer then pcall(self.observer.close, self.observer) end
    self:clearStage()
    self.observer, self.boss, self.level, self.awake, self.startedAt = nil, nil, nil, false, nil
    self.pawnAddress, self.nextSpawn, self.spawnDeadline, self.reloadAt = nil, nil, nil, nil
    self.reloadRequested = false
    if self.ability and self.ability.close then pcall(self.ability.close) end
    if self.target then pcall(self.target.close) end
    pcall(Menu.close)
    releaseBellData(self)
    pcall(Victory.close)
    self.view, self.report, self.victoryHoldAt = nil, nil, nil
    self.loadoutApplied, self.action, self.bellOpen = false, nil, false
    self.stageIndex, self.advanceAt, self.anchor, self.encounterWorld = 1, nil, nil, nil
    self.pendingScene = nil
    self.status, self.message = "waiting", "等待" .. self.scene.name .. "的挑战场地加载"
end

function Challenge:fail(message)
    RetryPreload.close(self)
    self:closeStagePressure()
    if self.palace then self.palace:close() end
    self:closeTransition()
    pcall(function() require("PracticeHud").close() end)
    if self.practice then pcall(self.practice.close, self.practice); self.practice = nil end
    if self.difficulty then pcall(self.difficulty.close, self.difficulty); self.difficulty = nil end
    if self.observer then pcall(self.observer.close, self.observer) end
    self:clearStage()
    self.observer, self.boss = nil, nil
    self.status, self.message = "error", message
    if self.palace and self.view == "ability" then pcall(self.ability.close) end
    pcall(Menu.close)
    releaseBellData(self)
    pcall(Victory.close)
    if self.target then pcall(self.target.close) end
    self.view = nil
end

function Challenge:closeTransition()
    closeGauntletPreload(self, "transition-closed")
    if self.stageFade then
        local ok, failure = pcall(self.stageFade.close, self.stageFade)
        if not ok then print("[PBZTestArenaNative] Phase fade cleanup: " .. tostring(failure) .. "\n") end
    end
    self.stageFade, self.transitionStep, self.advanceAt = nil, nil, nil
    self.phaseDestination, self.phaseDestinationDeadline = nil, nil
    self.phaseHealth = nil
    self.engagePending, self.engageDeadline = nil, nil
    self.engageRequests, self.engageNextPoll, self.engageNextLog = nil, nil, nil
    self.phaseReadyDeadline = nil
end

local function clearPhaseBullets(pawn)
    local subsystems = required("/Script/Engine.Default__SubsystemBlueprintLibrary")
    local bullets = subsystems:GetWorldSubsystem(pawn, required("/Script/SGameCombatSystem.BulletSubsystem"))
    assert(valid(bullets), "玩家转场弹体接口未就绪")
    bullets:DestroyBulletsOfActor(pawn)
end

local function resetPhaseAction(pawn)
    local asc, movement = pawn.AbilitySystemComponent, pawn.CharacterMovement
    assert(valid(asc) and valid(movement), "玩家转场重置接口未就绪")
    local actions = required("/Script/SGameUtils.Default__AbilityUtils")
    actions:CancelAbilitiesByTag(asc, {GameplayTags={{TagName=FName("Ability.Action")}}, ParentTags={}},
        {GameplayTags={}, ParentTags={}})
    local montage = pawn:GetCurrentMontage()
    if valid(montage) then pawn:StopAnimMontage(montage) end
    pawn:ConsumeMovementInputVector()
    movement:StopMovementImmediately()
    clearPhaseBullets(pawn)
end

local function isPhaseActionIdle(pawn)
    local asc = pawn.AbilitySystemComponent
    assert(valid(asc), "玩家转场能力组件未就绪")
    return not valid(pawn:GetCurrentMontage())
        and asc:GetGameplayTagCount({TagName=FName("CharacterState.Action")}) == 0
end

local function verifyPhaseResources(before, pawn, controller)
    local same, differences = PlayerState.compare(before, PlayerState.capture(pawn, controller))
    assert(same, "阶段回位意外改变玩家状态：" .. (differences[1] and differences[1].field or "unknown"))
end

function Challenge:updateTransition(gameplay, system, pawn, now, realNow)
    if not self.transitionStep then return false end
    local practiceTransition = self.practicePhaseTransition
    -- Persistent resources stay on the same pawn as the stage changes.
    local sample = self.observer:read(now)
    self.lastSample = sample
    if sample.playerDead then
        if self.palace then self.palace:finish(self, now, "failure", realNow); return true end
        self:checkpointLoadout(pawn,self.slot)
        self:record(pawn, sample, now, "failure")
        self:closeTransition()
        self.startedAt, self.reloadAt = nil, realNow + 1.5
        self.status, self.message = "resetting", "玩家阵亡，正在从首阶段重置挑战"
        return true
    end
    if self.palace and self.startedAt and self.palace:checkTime(self, now, realNow) then return true end
    if self.palace and gameplay:IsGamePaused(pawn) then
        if self.stageFade then self.stageFade:update(realNow) end
        return true
    end
    if self.transitionStep == "waiting" or self.transitionStep == "out" then
        advanceGauntletOpening(self, gameplay, system, pawn)
    end
    if self.transitionStep == "waiting" then
        if realNow < self.advanceAt then return true end
        if self.scene.runtimeModule then
            local destination, reason = require(self.scene.runtimeModule).phaseDestination(pawn, system, self.scene)
            if not destination then
                self.phaseDestinationDeadline = self.phaseDestinationDeadline or realNow + 5
                assert(realNow < self.phaseDestinationDeadline, reason)
                self.advanceAt, self.message = realNow + 0.25, reason
                return true
            end
            self.phaseDestination = destination
        end
        self.stageFade = StageFade.new(gameplay, pawn, realNow, self.palace ~= nil)
        if self.palace then
            self.palace.menu:holdPlayer()
            if self.palace.music then self.palace.music:duck(realNow) end
        end
        self.advanceAt, self.transitionStep = nil, "out"
        return true
    end
    if self.transitionStep == "engage" then
        if self.practice and not self.practice.state.ai then
            self:closeTransition()
            self.awake = true
            self.status, self.message = "combat", "练习目标已就位，AI 已暂停"
            self.practicePhaseTransition, self.phasePreloadPlan, self.phasePreloadScope = nil, nil, nil
            return true
        end
        if self.engageNextPoll and realNow < self.engageNextPoll then return true end
        self.engageNextPoll = realNow + 0.25
        self.engageRequests = self.engageRequests or {}
        local complete = true
        for _, actor in ipairs(self.bosses) do
            local address = actor:GetAddress()
            if not self.engagePending[address] then
                local request = self.engageRequests[address] or {}
                self.engageRequests[address] = request
                local engaged, reason = EncounterEngage.start(actor, pawn, request, realNow)
                if engaged then self.engagePending[address] = true
                else
                    complete = false
                    -- A live, correctly owned boss waiting for its native AI is
                    -- not an invalid encounter. A diagnostic deadline must not
                    -- route through fail() and destroy the new phase actor.
                    if realNow >= self.engageDeadline and realNow >= (self.engageNextLog or 0) then
                        self.engageNextLog = realNow + 5
                        local diagnosed, details = pcall(EncounterEngage.diagnose, actor, pawn)
                        print("[PBZTestArenaNative] Phase engagement pending; boss=" .. address
                            .. "; reason=" .. tostring(reason) .. "; " .. tostring(details) .. "\n")
                        self.message = "首领已保留，正在等待原生 AI 接续战斗"
                    end
                end
            end
        end
        if complete then
            self.awake = true
            if self.palace then
                local carriedHp = self.phaseHealth
                local hp = pawn.AttributeSetBase.Health.CurrentValue
                if carriedHp and hp > carriedHp + .01 then
                    require("PracticeMode").setAttributeValue(pawn, "Health", carriedHp)
                    hp = pawn.AttributeSetBase.Health.CurrentValue
                end
                print(("[PBZBloodyPalace] phase resources carried; floor=%d; stage=%d; hpBefore=%.2f; hpAfter=%.2f\n")
                    :format(PalaceProgress.sourceFloor(self.palace.floor), self.stageIndex, carriedHp or hp, hp))
                self.stageFade:reveal(realNow)
                self.palace.menu:releasePlayer()
                self.palace:playMusic(self, realNow)
                self.transitionStep = "in"
            else
                self:closeTransition()
                self.status, self.message = "combat", "下一阶段开始，继续挑战"
                self.practicePhaseTransition, self.phasePreloadPlan, self.phasePreloadScope = nil, nil, nil
            end
        elseif self.palace then
            assert(now < self.phaseReadyDeadline, "血宫下一阶段未完成接战")
        end
        return true
    end
    local phase = self.stageFade:update(realNow)
    if self.transitionStep == "out" then
        if phase == "black" then
            if self.gauntletPreload then self.gauntletPreload.blackClock = os.clock() end
            self.transitionStep = "swap"
        end
        -- Present at least one fully covered frame before expensive asset loads.
        return true
    end
    if self.transitionStep == "swap" then
        if self.palaceMechanics then self.palaceMechanics:preserveLeiDangHealth() end
        if self.palace then self.phaseHealth = pawn.AttributeSetBase.Health.CurrentValue end
        self:clearStage(usesPreparedPracticeTransition(self), true)
        local controller = gameplay:GetPlayerController(pawn, 0)
        local before = PlayerState.capture(pawn, controller)
        if practiceTransition then resetPhaseAction(pawn) end
        local anchor = self.anchor
        if self.phaseDestination then
            local destination = self.phaseDestination
            anchor = {
                pawnAddress = before.pawnAddress, worldAddress = before.worldAddress,
                abilitySystemAddress = before.abilitySystemAddress, controllerAddress = before.controllerAddress,
                position = destination.position, rotation = destination.rotation, controlRotation = destination.rotation,
            }
        end
        assert(PlayerState.teleport(pawn, anchor, controller), "阶段回位失败；未恢复玩家状态")
        verifyPhaseResources(before, pawn, controller)
        if self.phaseDestination then
            local at = pawn:K2_GetActorLocation()
            assert(distanceSquared(at, anchor.position) <= 75^2, self.scene.name .. "阶段回位偏离擂台内落点")
            print(("[PBZTestArenaNative] phase return inside arena scene=%s stage=%d x=%.2f y=%.2f z=%.2f\n")
                :format(self.scene.id, self.stageIndex + 1, at.X, at.Y, at.Z))
        end
        self.stageIndex, self.transitionStep = self.stageIndex + 1, "loading"
        if self.gauntletPreload then self.gauntletPreload.returnClock = os.clock() end
        self.nextSpawn, self.spawnDeadline = realNow, realNow + 12
        self.status, self.message = "transition", "正在准备下一阶段"
        if practiceTransition then
            practiceTransition.playerResetAt = realNow
            -- The fade is already covered and the first stage has been torn down.
            local members = self.entry.stages[self.stageIndex].members
            local plan = phasePreloadFor(self, pawn)
            if not plan then
                plan = SpawnClass.preload(members)
                self.phasePreloadPlan = plan
                self.phasePreloadScope = { pawn=pawn:GetAddress(), world=pawn:GetWorld():GetAddress() }
            end
            plan:resolve(members[1].classPath)
            return true -- Let the native action cancellation settle on its own tick.
        end
    end
    if self.transitionStep == "loading" then
        if not self.boss and not prepareCoveredStage(self, gameplay, system, pawn, realNow) then return true end
        if not self.boss and realNow >= self.nextSpawn then
            if practiceTransition then
                if realNow <= practiceTransition.playerResetAt or not self.stageFade:canReveal(realNow) then return true end
                local controller = gameplay:GetPlayerController(pawn, 0)
                local before = PlayerState.capture(pawn, controller)
                if not isPhaseActionIdle(pawn) then
                    assert(realNow < self.spawnDeadline, "玩家动作未退出，二阶段生成等待超时")
                    resetPhaseAction(pawn)
                    verifyPhaseResources(before, pawn, controller)
                    practiceTransition.playerResetAt = realNow
                    return true
                end
                clearPhaseBullets(pawn)
                verifyPhaseResources(before, pawn, controller)
            end
            self.nextSpawn = realNow + 0.5
            if self:spawnStage(gameplay, system, pawn) then
                self.observer:setBosses(self.bosses, self.stageIndex == #self.entry.stages)
                if self.palace then self.palace:onStageReady(self) end
                local preload = gauntletPreloadFor(self, pawn, self.stageIndex)
                if preload and preload:spawned(self.entry.stages[self.stageIndex].members, self.bosses) then
                    self.stageFade.hold = math.min(self.stageFade.hold, 0.25)
                end
            else
                assert(realNow < self.spawnDeadline, self.spawnWaitReason or "首领场地未就绪或没有足够的生成空间")
            end
        end
        if self.boss and self.stageFade:canReveal(realNow) then
            if self.palace then
                self.transitionStep, self.engagePending, self.engageDeadline = "engage", {}, realNow + 5
                self.phaseReadyDeadline = now + 12
            else
                self.stageFade:reveal(realNow)
                local preload = gauntletPreloadFor(self, pawn, self.stageIndex)
                if preload then preload:reveal() end
                self.transitionStep = "in"
            end
        end
        return true
    end
    if self.transitionStep == "in" and phase == "done" then
        self:closeTransition()
        if self.palace then
            self.status, self.message = "combat", "下一阶段开始，继续挑战"
            return true
        end
        -- A new actor does not inherit its predecessor's hatred relationship.
        -- Resume the existing fight explicitly once the screen is visible;
        -- stage one alone uses the initial distance-based start gate.
        self.transitionStep, self.engagePending, self.engageDeadline = "engage", {}, realNow + 5
        self.status, self.message = "transition", "正在接续下一阶段战斗"
    end
    return true
end

function Challenge:record(pawn, sample, now, result)
    -- Practice has no ranked attempt, archive or history entry. Its result is
    -- only an in-memory navigation choice, supplied at the final stage below.
    if self.mode == "practice" then return nil end
    if not self.startedAt then return nil end
    local native = required("/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary")
    local duration = math.max((result == "success" and sample.endedAt or now) - self.startedAt, 0)
    local report = {
        version = 3, attemptResult = result, bossId = self.entry.id, bossName = self.entry.name,
        timeSeconds = math.floor(duration * 1000 + 0.5) / 1000,
        perfectGuards = sample.perfectGuards, perfectDodges = sample.perfectDodges, healthRestored = sample.healthRestored,
        damageTaken = sample.damageTaken, damageTakenStatus = sample.damageTakenStatus, damageTakenNote = sample.damageTakenNote,
        playerCycle = self.playerCycle, nativePlayerCycle = native:GetGameCycle(pawn),
        playerProfile = PlayerProfile.id(self.playerCycle), mode = self.mode,
        difficultyMode = self.difficultyMode,
        difficultyName = self.customPressure and ("自订 · %s %d"):format(
            self.customPressure.mode == "fixed" and "固定" or "最低", self.customPressure.value)
            or Difficulty.choices[self.difficultyMode].name,
        enemyCycle = self.enemyCycle, bossLevel = self.level, loadout = self.openingLoadout,
        endedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"), metricsNote = sample.metricsNote,
        category = self.entry.category, categoryName = self.entry.categoryName,
        stageCount = #self.entry.stages,
        completedStages = result == "success" and #self.entry.stages or self.stageIndex - 1,
        sceneId = self.sceneId, sceneName = self.scene.name,
        authoredPhaseCount = self.entry.authoredPhaseCount, summonWaveCount = self.entry.summonWaveCount,
    }
    local path = saveReport(self.profilePath .. "/ChallengeReports", report)
    report.reportFile = path:match("([^/\\]+)$")
    local indexed, indexError = pcall(appendHistory, self.profilePath, report)
    if not indexed then print("[PBZTestArenaNative] Challenge history index: " .. tostring(indexError) .. "\n") end
    table.insert(self.history, 1, report)
    print("[PBZTestArenaNative] Challenge report saved: " .. path .. "\n")
    return report
end

-- Called by the active MOD context even while SceneArena calibration is
-- waiting. The native CommonUI bell remains input owner throughout.
function Challenge:updateMenuOnly(gameplay, system, pawn, now)
    if self.reloadRequested then return false end
    local realNow = gameplay:GetRealTimeSeconds(pawn)
    if self.action then
        local command = self.action
        self.action = nil
        self:command(gameplay, system, pawn, realNow, command)
        return true
    end
    if self.view == "target" then
        local ok, visible = pcall(self.target.update, gameplay)
        if not ok then
            pcall(self.target.close)
            print("[PBZTestArenaNative] Target menu: " .. tostring(visible) .. "\n")
        end
        if not ok or not visible then
            self.view = nil
            Menu.resume(realNow)
        end
        return true
    elseif self.view == "ability" then
        local ok, visible = pcall(self.ability.update, pawn)
        if not ok then
            pcall(self.ability.close)
            print("[PBZTestArenaNative] Ability menu: " .. tostring(visible) .. "\n")
            self.view = nil
            Menu.resume(realNow)
        elseif not visible then
            self.view = nil
            local captured, loadout = pcall(self.ability.capture, pawn)
            if captured and type(loadout) == "table" then
                self.abilityLoadout = loadout
                if self.palace then self.palace:rememberAbility(pawn, loadout)
                elseif self.skillMemory then self.skillMemory:remember(pawn, self.abilityBeforeEdit, loadout) end
                self.abilityBeforeEdit = nil
                -- A hand-edited native tree supersedes the launcher's initial
                -- blanket level, including when opened before arena readiness.
                self.loadoutApplied, self.pendingSkillLevel = true, nil
            else
                print("[PBZTestArenaNative] Ability loadout capture retained prior configuration: " .. tostring(loadout) .. "\n")
            end
            Menu.resume(realNow)
        end
        return true
    elseif self.view == "victory" then
        if not self.victoryHoldAt then
            local updated, visible = pcall(Victory.update, gameplay)
            if (not updated or visible == false) and not self.action then
                if not updated then print("[PBZTestArenaNative] Victory UI retry: " .. tostring(visible) .. "\n") end
                pcall(Victory.close)
                self.victoryHoldAt = now + 0.25
            end
        elseif now >= self.victoryHoldAt then
            self.victoryHoldAt = nil
            local ok, result = pcall(Victory.open, gameplay, pawn, self.report, self.onMenuAction,
                self.profilePath, self:menuState(false))
            if not ok or result == false then
                pcall(Victory.close)
                print("[PBZTestArenaNative] Native victory menu: " .. tostring(result) .. "\n")
                -- A delayed/temporarily unavailable native widget is not a
                -- decision to leave settlement. Keep the won encounter and
                -- its bell guard until the choice UI can attach successfully.
                self.victoryHoldAt = now + 1
            end
        end
        return true
    end
    if self.palace and not self:canUseBell() then return false end
    if not self.palace and self.status == "ready" and not self.bellOpen then
        self.ability = self.ability or require("AbilityChallenge")
        local ok, reason = pcall(self.ability.captureInput, gameplay, pawn)
        if not ok and reason ~= self.inputCaptureError then
            print("[PBZTestArenaNative] Challenge ability input capture: " .. tostring(reason) .. "\n")
        end
        self.inputCaptureError = not ok and reason or nil
    end
    -- The active native menu's OwnerBell is authoritative. Authored save-point
    -- distance or incomplete ground calibration must not suppress its service.
    do
        local ok, active = pcall(Menu.update, gameplay, pawn, self:menuState(self:canUseBell()), self.onMenuAction)
        if not ok then
            pcall(Menu.close)
            if self.bellError ~= active then print("[PBZTestArenaNative] Native bell menu: " .. tostring(active) .. "\n") end
        end
        self.bellError = not ok and active or nil
        local opened = ok and active == true
        if not opened or not self.bellOpen then self.bellLoadoutHandled = nil end
        if opened and self.onBellSave and not self.bellLoadoutHandled then
            self.bellLoadoutHandled = self.onBellSave(pawn)
        end
        self.bellOpen = opened
        if self.bellOpen or self.palace then return self.bellOpen end
    end
    if self.status == "error" then return false end
    if self.reloadAt then
        if realNow < self.reloadAt then return true end
        if not RetryPreload.beforeReload(self, gameplay, pawn, realNow) then return true end
        self:checkpointLoadout(pawn,self.slot)
        if self.selectCheckpoint then
            local selected, reason = self.selectCheckpoint(self.slot, self.playerCycle)
            if not selected then
                self.reloadProfileDeadline = self.reloadProfileDeadline or (realNow + 10)
                assert(realNow < self.reloadProfileDeadline, reason or "等待演武存点超时")
                self.reloadAt = realNow + 0.25
                return true
            end
            self.reloadProfileDeadline = nil
        end
        self:closeTransition()
        self.reloadRequested = true
        if self.observer then self.observer:close(); self.observer = nil end
        self:clearStage()
        self.stageIndex, self.anchor, self.advanceAt = 1, nil, nil
        self.roundMedicine, self.medicineDeadline = nil, nil
        if self.pendingScene then
            self.scene, self.sceneId = self.pendingScene, self.pendingScene.id
            self.pendingScene = nil
        end
        reloadChallenge(gameplay, pawn, self.slot, self.scene, self.onSceneChange)
        return true
    end

    return false
end

function Challenge:tick(gameplay, system, pawn, now)
    if self.reloadRequested or self.status == "error" then return end
    local realNow = gameplay:GetRealTimeSeconds(pawn)
    if self.palace then
        self.lastPalaceTime = now
        if self.palace:beforeTick(self, gameplay, system, pawn, now, realNow) then return end
    end
    if self.pawnAddress and pawn:GetAddress() ~= self.pawnAddress and not self.reloadAt then
        self:checkpointLoadout(pawn,self.slot)
        if self.startedAt then self:record(pawn, self.lastSample or {}, now, "failure") end
        self:closeTransition()
        if self.practice then pcall(self.practice.close, self.practice); self.practice = nil end
        if self.difficulty then pcall(self.difficulty.close, self.difficulty); self.difficulty = nil end
        self.startedAt, self.reloadAt = nil, realNow
        self.status, self.message = "resetting", "玩家已重生，正在从首阶段重置挑战"
    end
    if not self.reloadAt then
        if self.lionArena then self.lionArena:update(pawn,realNow) end
        if self.chiLianArena and self.status ~= "won" then self.chiLianArena:update(pawn,realNow) end
        if not self.palace then
            if not self.difficulty then self.difficulty = require("GameplayDifficulty").new(pawn, self.difficultyMode) end
            assert(self.difficulty:update(pawn) ~= false, "挑战难度的玩家或场景已改变")
        end
        if self.lengtu and not self.markerCleanupError and self.status ~= "won" then
            local running = self.awake == true and not (self.mode == "practice" and self.practice and self.practice.state.ai == false)
            self.lengtu:update(pawn, running)
        end
    end
    if self.mode == "practice" and not self.reloadAt and self.status ~= "won" then
        if now >= (self.practiceRetryAt or 0) then
            local updated, stateOrFailure = pcall(function()
                if not self.practice then self.practice = require("PracticeMode").new(pawn, gameplay:GetPlayerController(pawn, 0)) end
                -- Phase acquisition owns AI until it has confirmed engagement.
                local phaseOwnsAI = self.transitionStep == "engage"
                assert(self.practice:update(pawn, self.bosses, self.awake, now, phaseOwnsAI) ~= false, "练习控制的角色或场景已改变")
                local state = self.practice:getState()
                if self.practiceFault and not state.lastError then state.lastError = "练习控制已复位，详见日志" end
                return state
            end)
            if not updated then
                -- Genuine control faults release only optional practice state.
                local message = tostring(stateOrFailure)
                if self.practiceFault ~= message then print("[PBZTestArenaNative] Practice controls reset: " .. message .. "\n") end
                self.practiceFault, self.practiceRetryAt = message, now + 1
                if self.practice then pcall(self.practice.close, self.practice); self.practice = nil end
                pcall(function() require("PracticeHud").close() end)
                self.practiceHudRetryAt = nil
            else
                self.practiceRetryAt = nil
                -- A transient layout/widget failure must not revoke gameplay
                -- switches. Retry presentation independently, with a short backoff.
                if not self.practiceHudHidden and now >= (self.practiceHudRetryAt or 0) then
                    local drawn, failure = pcall(function()
                        require("PracticeHud").update(gameplay:GetPlayerController(pawn, 0), stateOrFailure, self.entry.name)
                    end)
                    if not drawn then
                        local message = tostring(failure)
                        if self.practiceHudFault ~= message then print("[PBZTestArenaNative] Practice HUD waiting: " .. message .. "\n") end
                        self.practiceHudFault, self.practiceHudRetryAt = message, now + 0.25
                        pcall(function() require("PracticeHud").close() end)
                    else
                        if self.practiceHudFault then print("[PBZTestArenaNative] Practice HUD recovered; controls retained\n") end
                        self.practiceHudFault, self.practiceHudRetryAt = nil, nil
                    end
                end
            end
        end
    elseif self.mode == "practice" then
        -- The native game retires defeated actors after their death animation.
        -- Settlement owns the UI from this point; it must not keep sampling a
        -- corpse, fail the completed encounter, or expose the underlying bell.
        require("PracticeHud").close()
    end
    self:updateMounts()
    -- Native boss information follows owned living targets, independently of
    -- AI state and optional practice-control/panel retries.
    if self.mode == "practice" and not self.reloadAt and self.status ~= "won" and #self.bosses > 0 then
        if now >= (self.practiceBossInfoRetryAt or 0) then
            local shown, failure = pcall(function()
                local targets = self.observer and self.observer:livingGroup() or self.bosses
                local practiceBossStage = usesPreparedPracticeTransition(self) and self.stageIndex or nil
                local updated, reason = require("PracticeBossInfo").update(
                    gameplay:GetPlayerController(pawn, 0), targets, now, practiceBossStage,
                    self.practice and self.practice.state.ai == false)
                assert(updated ~= false, reason or "练习首领信息暂未就绪")
            end)
            if not shown then
                local message = tostring(failure)
                if self.practiceBossInfoFault ~= message then print("[PBZTestArenaNative] Practice boss info waiting: " .. message .. "\n") end
                self.practiceBossInfoFault, self.practiceBossInfoRetryAt = message, now + 0.25
            else
                if self.practiceBossInfoFault then print("[PBZTestArenaNative] Practice boss info recovered\n") end
                self.practiceBossInfoFault, self.practiceBossInfoRetryAt = nil, nil
            end
        end
    elseif self.mode == "practice" then
        pcall(function() require("PracticeBossInfo").close() end)
        self.practiceBossInfoFault, self.practiceBossInfoRetryAt = nil, nil
    end
    if self:updateMenuOnly(gameplay, system, pawn, now) then return end

    if self.pawnAddress and pawn:GetAddress() ~= self.pawnAddress then
        self:checkpointLoadout(pawn,self.slot)
        if self.startedAt then self:record(pawn, self.lastSample or {}, now, "failure") end
        self:closeTransition()
        self.startedAt, self.reloadAt = nil, realNow
        self.status, self.message = "resetting", "玩家已重生，正在从首阶段重置挑战"
        return
    end

    if self:updateTransition(gameplay, system, pawn, now, realNow) then return end

    if not self.boss then
        if self.palace and self.palace.fade and self.palace.fade.phase == "black"
            and not gameplay:IsGamePaused(pawn) and not prepareCoveredStage(self, gameplay, system, pawn, realNow) then return end
        if not RetryPreload.beforeSpawn(self, gameplay, pawn) then return end
        if self.nextSpawn and now < self.nextSpawn then return end
        self.nextSpawn = now + 0.5
        if self.playerCycle == nil then
            local native = required("/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary")
            self.playerCycle = native:GetGameCycle(pawn)
        end
        self.skillLevel = PlayerProfile.normalizeSkillLevel(self.playerCycle, self.skillLevel or PlayerProfile.skillCap(self.playerCycle))
        self:applyAbilityLoadout(pawn)
        -- ArenaLoadoutMemory has already applied the remembered equipment
        -- before arenaContext permits this tick. Fill only the opening attempt,
        -- after that commit; clearStage/spawnStage also run between phases and
        -- must never restore consumables used in the preceding fight.
        if self.stageIndex == 1 and not self.palace then
            self.roundMedicine = self.roundMedicine or ChallengeMedicine.new(pawn)
            self.medicineDeadline = self.medicineDeadline or now + 12
            local full, reason = self.roundMedicine:update(pawn, now, gameplay:GetPlayerController(pawn, 0))
            if not full then
                assert(now < self.medicineDeadline, reason or "挑战药瓶未就绪")
                self.status, self.message = "waiting", "正在准备本轮挑战的药瓶"
                return
            end
            self.medicineDeadline = nil
        end
        self.spawnDeadline = self.spawnDeadline or now + 12
        if not self:spawnStage(gameplay, system, pawn) then
            assert(now < self.spawnDeadline, self.spawnWaitReason or "首领场地未就绪或没有足够的生成空间")
            -- Preserve death handling if asset/ground streaming delays a phase.
            if self.observer then
                local sample = self.observer:read(now)
                if sample.playerDead then
                    self:checkpointLoadout(pawn,self.slot)
                    self:record(pawn, sample, now, "failure")
                    self.startedAt, self.reloadAt = nil, realNow + 1.5
                end
            end
            return
        end
        if not self.scene.runtimeModule and not self.anchor and #self.entry.stages > 1 then
            self.anchor = PlayerState.capture(pawn, gameplay:GetPlayerController(pawn, 0))
        end
        if self.observer then
            self.observer:setBosses(self.bosses, self.stageIndex == #self.entry.stages)
        else
            local telemetryPath = not self.palace and self.profilePath .. "/PBZChallengeTelemetry.csv" or nil
            self.observer = Signals.newEncounter(pawn, self.bosses, telemetryPath, self.stageIndex == #self.entry.stages)
        end
        if self.scene.standaloneLake then
            require("LakeUpperArena").refreshWater(gameplay, pawn)
        end
        self.pawnAddress = pawn:GetAddress()
        if self.palace then self.palace:onStageReady(self) end
        self.status = self.startedAt and "combat" or "ready"
        self.message = self.palace and "敌人已就位，正在接战"
            or self.entry.name .. "（" .. self.stageIndex .. "/" .. #self.entry.stages .. "）已就位，靠近后开始挑战"
        return
    end

    if pawn:GetAddress() ~= self.pawnAddress then
        self:checkpointLoadout(pawn,self.slot)
        if self.startedAt then self:record(pawn, self.observer:read(now), now, "failure") end
        self.startedAt, self.reloadAt = nil, realNow
        self.status, self.message = "resetting", "玩家已重生，正在重置挑战"
        return
    end
    if self.palace then
        self.palace:engage(self, pawn, realNow, now)
        self.palace:keepArenaTargets(self, gameplay, pawn, realNow)
    end
    if not self.awake and not self.palace and (not self.practice or self.practice.state.ai) then
        for _, actor in ipairs(self.bosses) do
            if valid(actor) and distanceSquared(pawn:K2_GetActorLocation(), actor:K2_GetActorLocation()) <= WAKE_DISTANCE^2 then
                for _, member in ipairs(self.bosses) do
                    if valid(member) then CombatSpawn.challengeAI(member, true) end
                end
                self.awake = true
                break
            end
        end
    end
    self:updateMounts()
    if self.palaceMechanics then self.palaceMechanics:update(realNow) end
    if self.pressure then self.pressure:sample(realNow) end
    local sample = self.observer:read(now)
    self.lastSample = sample
    if self.entry.adapter == "lengtu" and sample.bossDead and valid(self.boss) and self.boss:IsAlive() then
        -- Natural phase abilities may briefly empty HP while the native actor
        -- is still alive. Only its original death state completes the fight.
        sample.bossDead = false
    end
    if not self.palace and #self.bosses > 1 and not sample.playerDead and not sample.bossMissing and not sample.bossDead then
        -- Proximity can start AI, but actual same-player hatred is required to
        -- recruit the other current members. A verified remote pull uses the
        -- original timing branch below, never a separately restarted clock.
        local living = self.observer:livingGroup()
        if #living > 1 then
            local enabled = not (self.practice and self.practice.state.ai == false)
            self.groupAggro = EncounterEngage.linkGroup(pawn, living, self.groupAggro, realNow,
                enabled, sample.engaged == true)
            if enabled and self.groupAggro and self.groupAggro.triggered then self.awake = true end
        else
            self.groupAggro = nil
        end
    end
    if self.practice and self.practice.startedCombat then self.awake = true end
    local combatStarted = self.awake and (sample.engaged or (self.practice and self.practice.startedCombat))
        or (self.palace and (sample.engaged or sample.bossDead))
    if combatStarted and not self.startedAt then
        self.startedAt = sample.startedAt or now
        if self.palace then
            print("[PBZBloodyPalace] timer started; floor=" .. self.palace.floor .. "\n")
        elseif self.mode ~= "practice" then
            local captured, loadout = pcall(function() return require("ChallengeLoadout").capture(pawn) end)
            self.openingLoadout = captured and loadout or nil
            if not captured then print("[PBZTestArenaNative] Opening loadout: " .. tostring(loadout) .. "\n") end
        end
        self.status, self.message = "combat", "挑战计时中"
    end
    if sample.playerDead then
        if self.palace then self.palace:finish(self, now, "failure", realNow); return end
        self:checkpointLoadout(pawn,self.slot)
        self:record(pawn, sample, now, "failure")
        self.startedAt = nil
        self.reloadAt = realNow + 1.5
        self.status, self.message = "resetting", "玩家阵亡，正在重置挑战"
        return
    end
    if self.palace then
        self.palace:creditKills(self, now, realNow)
        if self.palace.defense then self.palace.defense:creditLethalExecutions(self.observer, now, realNow) end
    end
    local resolvedAt = sample.bossDead and sample.endedAt or now
    if self.palace and self.startedAt and self.palace:checkTime(self, resolvedAt, realNow) then return end
    assert(not sample.bossMissing or sample.bossDead, "挑战首领已意外离场")
    if sample.bossDead then
        if not (self.palace and self.entry.stages[self.stageIndex].regularMobs) then
            for _, actor in ipairs(self.bosses) do pcall(clearBossFlow, actor) end
        end
        if self.startedAt or self.mode == "practice" then
            if self.stageIndex < #self.entry.stages then
                if self.palace then self.palace:onStageDefeated(self, sample, realNow) end
                if self.stageIndex == 1 and usesPreparedPracticeTransition(self) then
                    self.practicePhaseTransition = {}
                end
                self.advanceAt, self.transitionStep = realNow + 0.25, "waiting"
                self.status, self.message = "transition", "阶段完成，准备回位进入下一阶段"
                return
            end
            if self.palace then self.palace:clearRound(self, sample, now, realNow); return end
            if self.mode == "practice" then
                self.report = { mode = "practice", bossId = self.entry.id, bossName = self.entry.name }
                self.status, self.message = "won", "练习结束"
            else
                self.report = self:record(pawn, sample, now, "success")
                self.status, self.message = "won", "挑战成功，战报已保存"
            end
            self.view = "victory"
            if self.mode == "practice" then self.victoryHoldAt = now
            else
                local played, err = pcall(showZhan, gameplay, pawn)
                if not played then print("[PBZTestArenaNative] Stock victory animation: " .. tostring(err) .. "\n") end
                self.victoryHoldAt = now + 2.6
            end
        else
            self.status, self.message = "resetting", "首领在进入战斗前倒下，正在重置挑战"
            self.reloadAt = realNow
        end
    end
end

function Challenge:practiceKey(key, gameplay, pawn)
    if self.mode ~= "practice" or self.reloadAt or self.reloadRequested or self.status == "error"
        or self.status == "won" or self.view then return false end
    local hud = require("PracticeHud")
    if key == hud.toggleKey then
        self.practiceHudHidden = not self.practiceHudHidden
        self.practiceHudRetryAt = nil
        if self.practiceHudHidden then hud.close() end
        return true
    end
    local name = ({ F5 = "ai", F6 = "enemyRegen", F7 = "invulnerable", F8 = "infiniteUltimate", F9 = "infiniteSpiritShadow" })[key]
    if not name then return false end
    if not self.practice then self.practice = require("PracticeMode").new(pawn, gameplay:GetPlayerController(pawn, 0)) end
    local applied, reason
    if name == "invulnerable" then applied, reason = self.practice:cycleDamageMode()
    else applied, reason = self.practice:set(name, not self.practice.state[name]) end
    if applied then self.practiceFault = nil end
    return applied, reason
end

return Challenge
