local CombatSpawn = require("CombatSpawn")
local Signals = require("ChallengeSignals")
local Menu = require("ChallengeMenu")
local Victory = require("ChallengeVictory")
local PlayerState = require("EncounterPlayerState")
local Encounters = require("EncounterCatalog")
local StageFade = require("StageFade")
local EncounterEngage = require("EncounterEngage")
local SpawnClass = require("SpawnClass")
local PlayerProfile = require("PlayerProfile")
local ChallengeMedicine = require("ChallengeMedicine")
local ArenaScenes = require("ArenaScenes")

local LionArena = require("LionArena")
local JingYeMount = require("JingYeMount")
local ChiLianArena = require("ChiLianArena")
local Challenge = {}
Challenge.__index = Challenge

local ARENA_LEVEL = "PBZ_Duanhun_WP"
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

local function reloadChallenge(gameplay, pawn, slot, scene)
    local instance = gameplay:GetGameInstance(pawn)
    assert(valid(instance), "挑战存档接口不可用")
    local result = { ResultType = 255, LevelName = "", GameModeOptions = "" }
    instance:LoadGame(slot, result)
    local map = stringValue(result.LevelName)
    local expected = scene and scene.map or ARENA_LEVEL
    assert(result.ResultType == 0 and (map == expected or map:sub(-#expected - 1) == "/" .. expected),
        "无法重载所选演武场景的挑战前存档")
    assert(not scene or stringValue(result.GameModeOptions) == scene.gameModeOptions,
        "所选场景的成年角色模式不匹配")
    gameplay:OpenLevel(pawn, FName(map), true, stringValue(result.GameModeOptions))
end

local function returnToTitle(gameplay, pawn)
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

local function spawnBoss(entry, enemyCycle, gameplay, system, pawn, occupied, scene, nativeEncounter, mounts, prepareChiLian)
    local mathLibrary = required("/Script/Engine.Default__KismetMathLibrary")
    local spawner = required("/Script/SGameAI.Default__SGameAIFunctionLibrary")
    local class, reason = SpawnClass.resolve(entry.classPath)
    if not valid(class) then return nil, nil, reason end
    local playerView = pawn:K2_GetActorLocation()
    local playerPosition = { X = playerView.X, Y = playerView.Y, Z = playerView.Z }
    scene = scene or ArenaScenes.get("night")
    local authored = nativeEncounter and scene.lengtuSpawn
    local candidates = authored and { authored.location } or scene.spawnPoints
    local failures = {}
    for index, candidate in ipairs(candidates) do
        local top = { X = candidate.X, Y = candidate.Y, Z = authored and candidate.Z + 300 or scene.spawnTrace.top }
        local bottom = { X = candidate.X, Y = candidate.Y, Z = authored and candidate.Z - 500 or scene.spawnTrace.bottom }
        local hit = {}
        local found = system:LineTraceSingle(pawn, top, bottom, 0, false, {}, 0, hit, true, NO_COLOR, NO_COLOR, 0)
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
                elseif not (distanceSquared(location, playerPosition) >= 3000^2) then failure = "与玩家距离不足3000"
                else
                    local yaw = authored and authored.rotation.Yaw or mathLibrary:FindLookAtRotation(location, playerPosition).Yaw
                    local rotation, scale = { Pitch = 0, Yaw = yaw, Roll = 0 }, { X = 1, Y = 1, Z = 1 }
                    local transform = mathLibrary:MakeTransform(location, rotation, scale)
                    local chiLian
                    if ChiLianArena.required(entry) then
                        local reason
                        chiLian, reason = prepareChiLian(ground, rotation)
                        if not chiLian then return nil, nil, reason end
                    end
                    local deferred = spawner:SpawnActorDeferred(pawn, class, transform, 3)
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
                        return CombatSpawn.finish(gameplay, pawn, deferred, transform, enemyCycle, true)
                    end
                    failure = "延迟生成返回无效对象"
                end
            end
        end
        failures[#failures + 1] = ("候选%d：%s"):format(index, failure)
    end
    return nil, nil, table.concat(failures, "；")
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
    local scene = ArenaScenes.forEncounter(entry.id, slots.sceneId)
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
        mode = slots.mode or "challenge", difficultyMode = slots.difficultyMode or 3,
        sceneId = scene.id, scene = scene,
        onSceneChange = slots.onSceneChange,
        onBeforeLoad=slots.onBeforeLoad,loadoutMemoryPath=slots.loadoutMemoryPath,
    }, Challenge)
    self.onMenuAction = function(action, settings) self:queueAction(action, settings) end
    if slots.resetSlot and skillLevel ~= nil then
        self.ability = require("AbilityChallenge")
        self.pendingSkillLevel = skillLevel
    end
    return self
end

function Challenge:canUseBell()
    return self.status ~= "won" and self.status ~= "error" and self.view ~= "victory"
        and not self.startedAt and not self.reloadAt and not self.reloadRequested
end

function Challenge:menuState(available)
    return {
        available = available, bossId = self.entry.id, bossName = self.entry.name,
        playerCycle = self.playerCycle or 0, enemyCycle = self.enemyCycle, skillLevel = self.skillLevel or 0,
        history = self.history, profilePath = self.profilePath, category = self.entry.category, mode = self.mode, difficultyMode = self.difficultyMode,
        playerProfile = PlayerProfile.id(self.playerCycle or 0),
        sceneId = self.sceneId, sceneName = self.scene.name, bellId = self.scene.bellSaveId,
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

function Challenge:command(gameplay, system, pawn, realNow, command)
    local action, settings = command.name, command.settings
    local victory = self.view == "victory"
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
    if action == "configure" and not victory then
        -- The original ability screen is pushed onto the bell's own menu stack.
        -- Retain its underlying widget while CommonUI temporarily deactivates it.
        if not Menu.suspend() then return end
        local ability = require("AbilityChallenge")
        if self.playerCycle == -1 then
            ability.setProfile(pawn, "lao")
            ability.setCycleSkills(pawn, 0)
            self.abilityProfilePawn = pawn
        end
        local opened, result = pcall(ability.open, gameplay, pawn)
        if opened and result == true then
            self.ability, self.view = ability, "ability"
        else
            pcall(ability.close)
            Menu.resume(realNow)
            print("[PBZTestArenaNative] Ability menu: " .. tostring(result) .. "\n")
        end
        return
    end
    if action == "exit" and victory then
        self:checkpointLoadout(pawn,nil)
        self:close()
        self.reloadRequested = true
        self.status, self.message = "leaving", "正在返回主界面"
        returnToTitle(gameplay, pawn)
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
        local difficulty = settings.difficultyMode or self.difficultyMode
        if type(difficulty) ~= "number" or difficulty % 1 ~= 0 or difficulty < 1 or difficulty > 3 then return end
        local sceneOk, scene = pcall(ArenaScenes.forEncounter, entry.id, settings.sceneId or self.sceneId)
        if not sceneOk then return end
        self.slot = PlayerProfile.slot(playerCycle, self.cyclePrefix, scene.id)
        if self.playerCycle ~= playerCycle then
            self.abilityLoadout = nil
        end
        self.pendingScene = scene.id ~= self.sceneId and scene or nil
        if selectedSkill ~= defaultSkill or self.playerCycle ~= playerCycle then
            self.ability = require("AbilityChallenge")
            self.pendingSkillLevel = selectedSkill
        end
        self.skillLevel = selectedSkill
        self.difficultyMode = difficulty
        self.entry, self.playerCycle, self.enemyCycle = entry, playerCycle, enemyCycle
    elseif action ~= "retry" or not victory then return end
    self:checkpointLoadout(pawn,self.slot)
    if victory then Victory.close() else Menu.close() end
    self.view, self.bellOpen = nil, false
    self.status, self.message, self.reloadAt = "resetting", "正在重读挑战存档", realNow
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

function Challenge:clearStage()
    -- Release native UI registrations while our stage actors still exist.
    local cleared, reason = pcall(function() require("PracticeBossInfo").close() end)
    if not cleared then print("[PBZTestArenaNative] Practice boss info cleanup: " .. tostring(reason) .. "\n") end
    self.practiceBossInfoFault, self.practiceBossInfoRetryAt = nil, nil
    -- Original snake helpers retain unowned summon references. Collect/cancel
    -- them before generic cleanup destroys their native BP containers.
    self:clearChiLianArena()
    -- Cancel native horse spawns while the rider script still exists. Retain
    -- failed cleanup handles so a retry cannot create an untracked second mount.
    self:clearMounts()
    self.engageRequests, self.engageNextPoll, self.engageNextLog = nil, nil, nil
    self.groupAggro = nil
    -- Remove only this encounter's actors and owner-linked summons. Never scan
    -- by location alone: the scene's authored NPCs are not ours to destroy.
    local actors = {}
    local seen = {}
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
    if LionArena.required(self.entry.stages[self.stageIndex]) and not self.lionArena then
        local area,reason=LionArena.new(pawn,self.scene,gameplay,system)
        if not area then spawnWait(self,gameplay,pawn,reason); return false end
        self.lionArena=area
    end
    local actors, levels = {}, {}
    local function prepareChiLian(ground, rotation)
        if self.chiLianArena then return self.chiLianArena end
        local arena, reason = ChiLianArena.new(pawn, gameplay, system, ground, rotation, self.scene)
        if arena then self.chiLianArena = arena end
        return arena, reason
    end
    self.mounts = {}
    local ok, failure = pcall(function()
        for _, member in ipairs(self.entry.stages[self.stageIndex].members) do
            local actor, level, reason = spawnBoss(member, self.enemyCycle, gameplay, system, pawn, actors, self.scene, self.lengtu, self.mounts, prepareChiLian)
            if not valid(actor) then spawnWait(self, gameplay, pawn, reason or "候选生成条件未满足"); return end
            actors[#actors + 1], levels[#levels + 1] = actor, level
            -- Authored story flows may open cutscenes or replace the arena.
            -- Combat abilities and AI remain on the spawned character.
            clearBossFlow(actor)
            local ability = required("/Script/ProjectPBZ.Default__PBZAbilityBlueprintLibrary")
            local asc = actor.AbilitySystemComponent
            assert(valid(asc), "挑战首领没有能力组件")
            local tag = { TagName = FName("CharacterType.AI.Boss") }
            if asc:GetGameplayTagCount(tag) == 0 then
                assert(ability:AddLooseGameplayTag(actor, tag, false), "无法启用原版首领战斗状态")
            end
        end
    end)
    if not ok or #actors ~= #self.entry.stages[self.stageIndex].members then
        self:clearMounts()
        self:clearChiLianArena()
        for _, actor in ipairs(actors) do
            pcall(clearBossFlow, actor)
            pcall(function() actor:K2_DestroyActor() end)
        end
        if not ok then error(failure, 0) end
        return false
    end
    self.bosses = actors
    self.encounterWorld = pawn:GetWorld():GetAddress()
    self.ownedActors = {}
    for _, actor in ipairs(actors) do self.ownedActors[actor:GetAddress()] = true end
    if #self.mounts > 0 then
        self.mountPreparation = { actors = actors, levels = levels, stage = self.stageIndex, world = self.encounterWorld }
        return self:finishMountPreparation(gameplay, pawn)
    end
    self.mounts = nil
    self.boss, self.level = actors[1], levels[1]
    spawnWait(self, gameplay, pawn, nil)
    return true
end

function Challenge:close()
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
    pcall(Victory.close)
    self.view, self.report, self.victoryHoldAt = nil, nil, nil
    self.loadoutApplied, self.action, self.bellOpen = false, nil, false
    self.stageIndex, self.advanceAt, self.anchor, self.encounterWorld = 1, nil, nil, nil
    self.pendingScene = nil
    self.status, self.message = "waiting", "等待故屋幻景的挑战场地加载"
end

function Challenge:fail(message)
    self:closeTransition()
    pcall(function() require("PracticeHud").close() end)
    if self.practice then pcall(self.practice.close, self.practice); self.practice = nil end
    if self.difficulty then pcall(self.difficulty.close, self.difficulty); self.difficulty = nil end
    if self.observer then pcall(self.observer.close, self.observer) end
    self:clearStage()
    self.observer, self.boss = nil, nil
    self.status, self.message = "error", message
    pcall(Menu.close)
    pcall(Victory.close)
    if self.target then pcall(self.target.close) end
    self.view = nil
end

function Challenge:closeTransition()
    if self.stageFade then
        local ok, failure = pcall(self.stageFade.close, self.stageFade)
        if not ok then print("[PBZTestArenaNative] Phase fade cleanup: " .. tostring(failure) .. "\n") end
    end
    self.stageFade, self.transitionStep, self.advanceAt = nil, nil, nil
    self.engagePending, self.engageDeadline = nil, nil
    self.engageRequests, self.engageNextPoll, self.engageNextLog = nil, nil, nil
end

function Challenge:updateTransition(gameplay, system, pawn, now, realNow)
    if not self.transitionStep then return false end
    -- Effects keep running on the same pawn throughout the fade and loading.
    local sample = self.observer:read(now)
    self.lastSample = sample
    if sample.playerDead then
        self:checkpointLoadout(pawn,self.slot)
        self:record(pawn, sample, now, "failure")
        self:closeTransition()
        self.startedAt, self.reloadAt = nil, realNow + 1.5
        self.status, self.message = "resetting", "玩家阵亡，正在从首阶段重置挑战"
        return true
    end
    if self.transitionStep == "waiting" then
        if realNow < self.advanceAt then return true end
        self.stageFade = StageFade.new(gameplay, pawn, realNow)
        self.advanceAt, self.transitionStep = nil, "out"
        return true
    end
    if self.transitionStep == "engage" then
        if self.practice and not self.practice.state.ai then
            self:closeTransition()
            self.awake = true
            self.status, self.message = "combat", "练习目标已就位，AI 已暂停"
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
            self:closeTransition()
            self.awake = true
            self.status, self.message = "combat", "下一阶段开始，继续挑战"
        end
        return true
    end
    local phase = self.stageFade:update(realNow)
    if self.transitionStep == "out" then
        if phase == "black" then self.transitionStep = "swap" end
        -- Present at least one fully black frame before expensive asset loads.
        return true
    end
    if self.transitionStep == "swap" then
        self:clearStage()
        local controller = gameplay:GetPlayerController(pawn, 0)
        local before = PlayerState.capture(pawn, controller)
        assert(PlayerState.teleport(pawn, self.anchor, controller), "阶段回位失败；未恢复玩家状态")
        local same, differences = PlayerState.compare(before, PlayerState.capture(pawn, controller))
        assert(same, "阶段回位意外改变玩家状态：" .. (differences[1] and differences[1].field or "unknown"))
        self.stageIndex, self.transitionStep = self.stageIndex + 1, "loading"
        self.nextSpawn, self.spawnDeadline = realNow, realNow + 12
        self.status, self.message = "transition", "正在准备下一阶段"
    end
    if self.transitionStep == "loading" then
        if not self.boss and realNow >= self.nextSpawn then
            self.nextSpawn = realNow + 0.5
            if self:spawnStage(gameplay, system, pawn) then
                self.observer:setBosses(self.bosses, self.stageIndex == #self.entry.stages)
            else
                assert(realNow < self.spawnDeadline, self.spawnWaitReason or "首领场地未就绪或没有足够的生成空间")
            end
        end
        if self.boss and self.stageFade:canReveal(realNow) then
            self.stageFade:reveal(realNow)
            self.transitionStep = "in"
        end
        return true
    end
    if self.transitionStep == "in" and phase == "done" then
        self:closeTransition()
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
        difficultyMode = self.difficultyMode, difficultyName = ({ "入阵者", "破局者", "逆天者" })[self.difficultyMode],
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
    if self.status == "ready" and not self.bellOpen then
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
        self.bellOpen = ok and active == true
        if self.bellOpen then return true end
    end
    if self.status == "error" then return false end
    if self.reloadAt then
        if realNow < self.reloadAt then return true end
        self:checkpointLoadout(pawn,self.slot)
        self:closeTransition()
        self.reloadRequested = true
        if self.observer then self.observer:close(); self.observer = nil end
        self:clearStage()
        self.stageIndex, self.anchor, self.advanceAt = 1, nil, nil
        self.roundMedicine, self.medicineDeadline = nil, nil
        if self.pendingScene then
            self.scene, self.sceneId = self.pendingScene, self.pendingScene.id
            self.pendingScene = nil
            if self.onSceneChange then self.onSceneChange(self.sceneId, gameplay, pawn) end
        end
        reloadChallenge(gameplay, pawn, self.slot, self.scene)
        return true
    end

    return false
end

function Challenge:tick(gameplay, system, pawn, now)
    if self.reloadRequested or self.status == "error" then return end
    local realNow = gameplay:GetRealTimeSeconds(pawn)
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
        if not self.difficulty then self.difficulty = require("GameplayDifficulty").new(pawn, self.difficultyMode) end
        assert(self.difficulty:update(pawn) ~= false, "挑战难度的玩家或场景已改变")
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
                if now >= (self.practiceHudRetryAt or 0) then
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
                local updated, reason = require("PracticeBossInfo").update(gameplay:GetPlayerController(pawn, 0), self.bosses, now)
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
        if self.nextSpawn and now < self.nextSpawn then return end
        self.nextSpawn = now + 0.5
        if self.playerCycle == nil then
            local native = required("/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary")
            self.playerCycle = native:GetGameCycle(pawn)
        end
        self.skillLevel = PlayerProfile.normalizeSkillLevel(self.playerCycle, self.skillLevel or PlayerProfile.skillCap(self.playerCycle))
        self.ability = self.ability or require("AbilityChallenge")
        self.ability.setProfile(pawn, PlayerProfile.id(self.playerCycle))
        self.abilityProfilePawn = pawn
        if self.playerCycle == -1 then
            self.ability.setCycleSkills(pawn, 0)
            if self.pendingSkillLevel ~= nil then self.pendingSkillLevel = 0 end
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
        -- ArenaLoadoutMemory has already committed the remembered equipment
        -- before arenaContext permits this tick. Fill only the opening attempt,
        -- after that commit; clearStage/spawnStage also run between phases and
        -- must never restore consumables used in the preceding fight.
        if self.stageIndex == 1 then
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
        if not self.anchor and #self.entry.stages > 1 then
            self.anchor = PlayerState.capture(pawn, gameplay:GetPlayerController(pawn, 0))
        end
        if self.observer then
            self.observer:setBosses(self.bosses, self.stageIndex == #self.entry.stages)
        else
            self.observer = Signals.newEncounter(pawn, self.bosses, self.profilePath .. "/PBZChallengeTelemetry.csv",
                self.stageIndex == #self.entry.stages)
        end
        self.pawnAddress = pawn:GetAddress()
        self.status = self.startedAt and "combat" or "ready"
        self.message = self.entry.name .. "（" .. self.stageIndex .. "/" .. #self.entry.stages .. "）已就位，靠近后开始挑战"
        return
    end

    if pawn:GetAddress() ~= self.pawnAddress then
        self:checkpointLoadout(pawn,self.slot)
        if self.startedAt then self:record(pawn, self.observer:read(now), now, "failure") end
        self.startedAt, self.reloadAt = nil, realNow
        self.status, self.message = "resetting", "玩家已重生，正在重置挑战"
        return
    end
    if not self.awake and (not self.practice or self.practice.state.ai) then
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
    local sample = self.observer:read(now)
    self.lastSample = sample
    if self.entry.adapter == "lengtu" and sample.bossDead and valid(self.boss) and self.boss:IsAlive() then
        -- Natural phase abilities may briefly empty HP while the native actor
        -- is still alive. Only its original death state completes the fight.
        sample.bossDead = false
    end
    if #self.bosses > 1 and not sample.playerDead and not sample.bossMissing and not sample.bossDead then
        -- Proximity can start AI, but actual same-player hatred is required to
        -- recruit the other current members. A verified remote pull uses the
        -- original timing branch below, never a separately restarted clock.
        local enabled = not (self.practice and self.practice.state.ai == false)
        self.groupAggro = EncounterEngage.linkGroup(pawn, self.bosses, self.groupAggro, realNow,
            enabled, sample.engaged == true)
        if enabled and self.groupAggro and self.groupAggro.triggered then self.awake = true end
    end
    if self.practice and self.practice.startedCombat then self.awake = true end
    if self.awake and (sample.engaged or (self.practice and self.practice.startedCombat)) and not self.startedAt then
        self.startedAt = sample.startedAt or now
        if self.mode ~= "practice" then
            local captured, loadout = pcall(function() return require("ChallengeLoadout").capture(pawn) end)
            self.openingLoadout = captured and loadout or nil
            if not captured then print("[PBZTestArenaNative] Opening loadout: " .. tostring(loadout) .. "\n") end
        end
        self.status, self.message = "combat", "挑战计时中"
    end
    if sample.playerDead then
        self:checkpointLoadout(pawn,self.slot)
        self:record(pawn, sample, now, "failure")
        self.startedAt = nil
        self.reloadAt = realNow + 1.5
        self.status, self.message = "resetting", "玩家阵亡，正在重置挑战"
        return
    end
    assert(not sample.bossMissing or sample.bossDead, "挑战首领已意外离场")
    if sample.bossDead then
        for _, actor in ipairs(self.bosses) do pcall(clearBossFlow, actor) end
        if self.startedAt or self.mode == "practice" then
            if self.stageIndex < #self.entry.stages then
                self.advanceAt, self.transitionStep = realNow + 0.25, "waiting"
                self.status, self.message = "transition", "阶段完成，准备回位进入下一阶段"
                return
            end
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
