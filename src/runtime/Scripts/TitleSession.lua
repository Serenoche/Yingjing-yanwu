local TitleProbe = require("TitleProbe")
local PlayerProfile = require("PlayerProfile")
local Scenes = require("ArenaScenes")

local TitleSession = {}
TitleSession.__index = TitleSession

local TITLE_LEVEL = "PBZ_StartMenu_CE_WP"
local ARENA_LEVEL = "PBZ_Duanhun_WP"
local PRIVATE_SLOT = "PBZArenaTitleProbe"
local MODE_GATE = 2 -- EPBZSaveVetoReason::ModeGate in the pinned build.
local VETO_ID = "PBZTestArena.TitleProbe"

local function valid(object)
    return object ~= nil and object:IsValid()
end

local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "missing reflected object: " .. path)
    return object
end

local function text(value)
    if type(value) == "string" then return value end
    return value and value:ToString() or ""
end

local function saveManager(context)
    local library = required("/Script/Engine.Default__SubsystemBlueprintLibrary")
    local subsystem = library:GetGameInstanceSubsystem(context, required("/Script/ProjectPBZ.PBZSaveLoadSubsystem"))
    assert(valid(subsystem), "test save manager is unavailable")
    return subsystem
end

local function failureMessage(failure, barrier)
    failure = tostring(failure)
    if failure:find("native-runtime-incompatible", 1, true) then
        return "已尝试兼容，但当前游戏的存档接口仍有差异，尚未进入演武。请把本次错误反馈给作者继续调整。"
    end
    if failure:find("save provider differs", 1, true) then
        return "当前游戏的存档账号与 MOD 安装时选择的账号不同。请退出游戏，重新运行安装器选择当前账号。"
    end
    if failure:find("save provider identity", 1, true) then
        return "尚未确认当前游戏的存档账号，请稍后重试；若持续出现，请退出游戏并更新或重新安装 MOD。"
    end
    local reason = barrier and barrier.lastRefusal or tostring(failure)
    if reason and reason:find("queue is busy", 1, true) then
        return "游戏正在处理存档，请稍等几秒再选择 MOD。"
    end
    if barrier and barrier.lastRefusal then
        if reason:find("relay", 1, true) or reason:find("allocation", 1, true) then
            return "MOD 内存准备失败，尚未载入训练档。可以重新选择 MOD；若仍失败，请退出游戏后重试。"
        end
        return "MOD 运行环境检查未通过，尚未载入训练档。请退出游戏后更新 MOD 或重新打开验证入口。"
    end
    return "MOD 启动未完成，请退出游戏后重新打开验证入口。本轮暂不继续载入。"
end

local function reportArrival(gameplay, controller, log)
    local fields = {}
    local function capture(label, read)
        local ok, value = pcall(read)
        fields[#fields + 1] = label .. "=" .. (ok and tostring(value) or "unavailable")
    end
    local function className(object)
        return valid(object) and object:GetClass():GetFName():ToString() or "none"
    end
    capture("moveIgnored", function() return controller:IsMoveInputIgnored() end)
    capture("lookIgnored", function() return controller:IsLookInputIgnored() end)
    capture("cursor", function() return controller.bShowMouseCursor end)
    capture("HUD", function() return className(controller:GetHUD()) end)
    capture("gameMode", function() return className(gameplay:GetGameMode(controller)) end)
    capture("activeTitle", function()
        local count = 0
        for _, menu in ipairs(FindAllOf("WB_StartMenu_V2_C") or {}) do
            if valid(menu) and menu:IsActivated() then count = count + 1 end
        end
        return count
    end)
    log("Title probe arrival input: " .. table.concat(fields, "; "))
end

local function normalizedPath(path)
    local normalized = path:gsub("\\", "/"):gsub("/+$", ""):lower()
    assert(not normalized:find("//", 1, true), "title probe audit path has duplicate separators")
    for part in normalized:gmatch("[^/]+") do
        assert(part ~= "." and part ~= "..", "title probe audit path has a relative segment")
    end
    return normalized
end

local function providerPath(path)
    assert(type(path) == "string" and #path > 0 and #path <= 4096
        and not path:find("[%z\1-\31\127]"), "native save provider identity path is invalid")
    local normalized = normalizedPath(path)
    assert(normalized:match("^[a-z]:/") and not normalized:sub(3):find(":",1,true)
        and not normalized:find('[*?<>|"]'), "native save provider identity path is invalid")
    for part in normalized:gmatch("[^/]+") do
        assert(not part:match("[. ]$"), "native save provider identity path is aliased")
    end
    return normalized
end

local function auditSettings(profile)
    local marker = io.open(profile .. "/PBZTitleProbeAuditSave.txt", "rb")
    if not marker then return nil end
    local path = (marker:read(4096) or ""):gsub("%s+$", "")
    marker:close()
    local normalized = normalizedPath(path)
    local profilePath = normalizedPath(profile)
    assert(profilePath:match("^[a-z]:/.+/arenadata/profile$"), "title probe audit profile is not isolated")
    local prefix = profilePath:gsub("/profile$", "/savegames") .. "/steam/"
    local account = normalized:sub(#prefix + 1):match("^(%d+)/pbzsavegame%.sav$")
    assert(normalized:sub(1, #prefix) == prefix and account and #account == 17,
        "title probe audit save must be inside this isolated profile")
    return { path = path, profile = profile, counter = 0 }
end

local function fileExists(path)
    local stream = io.open(path, "rb")
    if not stream then return false end
    stream:close()
    return true
end

local function writeFile(path, bytes, mode)
    local stream = assert(io.open(path, mode or "wb"), "cannot open title probe audit output")
    local wrote, writeError = stream:write(bytes)
    local closed, closeError = stream:close()
    assert(wrote and closed, writeError or closeError)
end

function TitleSession.new(profile, log, options)
    options = options or {}
    local expected
    if not options.integrated or options.disposable then
        local marker = assert(io.open(profile .. "/PBZTitleProbeExpectedSlot.txt", "rb"), "title probe marker is missing")
        expected = (marker:read(128) or ""):match("^([A-Za-z0-9_]+)%s*$")
        marker:close()
        assert(expected and expected ~= PRIVATE_SLOT, "title probe baseline slot is invalid")
    end
    if options.integrated then
        assert(options.trainingSlot == "PBZArenaIntegratedTraining"
            and options.cyclePrefix == "PBZArenaIntegratedCycle", "installed private slot configuration is invalid")
    end
    local expectedProvider
    if options.integrated and not options.disposable then
        expectedProvider=providerPath(options.savePath)
        local account=expectedProvider:match("/projectpbz/saved/savegames/steam/(%d+)/pbzsavegame%.sav$")
        assert(account and #account==17,"installed MOD save provider configuration is invalid")
    end
    if options.integrated then
        local preferences = options.loadoutMemoryPath and options.loadoutMemoryPath:match("^(.*[/\\])")
        require("EncounterCatalog") -- Install the current ready-member allowlist before reading saved IDs.
        require("CustomChallenges").configure((preferences or (profile .. "/")) .. "PBZCustomChallenges.tsv")
    end
    return setmetatable({ phase = "title", expected = expected, log = log, options = options,
        expectedProvider=expectedProvider,
        audit = (not options.integrated or options.disposable) and auditSettings(profile) or nil }, TitleSession)
end

function TitleSession:providerMatches(context, manager)
    if not self.expectedProvider then return true end
    local ok, actual = pcall(function()
        self.barrier=self.barrier or require("SaveBarrier").new()
        local state=self.barrier:inspect(manager or saveManager(context))
        assert(type(state)=="string","missing native provider response")
        local values={}
        for field in state:gmatch("[^;]+")do
            local key,value=field:match("^(providerReady)=(.*)$")
            if not key then key,value=field:match("^(providerPathHex)=(.*)$")end
            if key then assert(values[key]==nil,"duplicate native provider field");values[key]=value end
        end
        assert(values.providerReady=="1","native provider is not ready")
        local hex=values.providerPathHex
        assert(type(hex)=="string"and #hex>0 and #hex<=8192 and #hex%2==0
            and not hex:find("[^%x]"),"missing or malformed native provider path")
        return providerPath((hex:gsub("..",function(pair)return string.char(tonumber(pair,16))end)))
    end)
    if not ok then return nil,"native save provider identity is unavailable: "..tostring(actual)end
    if actual~=self.expectedProvider then return false,"installed MOD save provider differs from current game account"end
    return true
end

function TitleSession:restoreProviderMatches(controller)
    local matched,reason=self:providerMatches(controller)
    if matched then self.providerWaitReason=nil;return true end
    if matched==false then
        self.phase="blocked"
        self.failureMessage="演武期间存档账号发生变化，保护仍在启用。请完全退出并重新启动游戏，再使用安装器所选的 Steam 账号。"
        TitleProbe.close()
    end
    if self.providerWaitReason~=reason then self.log("Title probe protected restore waiting: "..tostring(reason))end
    self.providerWaitReason=reason
    return false
end

function TitleSession:guardOrdinaryLoads(gameplay, protected)
    local ok, restored, menu=pcall(TitleProbe.setOrdinaryLoadGuard,gameplay,protected)
    local failure=not ok and restored or (not protected and restored~=true and "owned widget cleanup is pending" or nil)
    if failure and self.ordinaryGuardError~=failure then
        self.log("Title probe ordinary-load UI guard: "..tostring(failure))
    end
    self.ordinaryGuardError=failure
    return ok and menu or nil
end

function TitleSession:allowArena()
    return self.phase == "arena" and self.barrier and self.barrier.armed == true
end
function TitleSession:onMapPre()
    -- CommonUI may pool the same title widget/buttons across world changes.
    -- Return their original flags while their captured world/owner still match,
    -- so the next title cannot snapshot our own disabled state as its baseline.
    self:guardOrdinaryLoads(nil,false)
    self.mapEpoch = (self.mapEpoch or 0) + 1
end
local function worldAddress(context)
    local ok, world = pcall(function() return context:GetWorld() end)
    return ok and valid(world) and world:GetAddress() or nil
end

function TitleSession:changeArenaScene(sceneId, gameplay, context)
    assert((self.phase == "arena" or self.phase == "loading") and self.barrier and self.barrier.armed == true,
        "scene changes require an active protected arena transaction")
    local scene = Scenes.get(Scenes.normalize(sceneId))
    if (self.scene and self.scene.id or "night") == scene.id then return true end
    self.scene = scene
    if self.lastSettings then self.lastSettings.sceneId, self.lastSettings.scene = scene.id, scene end
    self.phase = "loading"
    self.loadingMapEpoch, self.loadingWorldAddress = self.mapEpoch or 0, worldAddress(context)
    self.loadingDeadline = gameplay:GetRealTimeSeconds(context) + 30
    self.log("Title probe protected scene transition: " .. scene.id .. "; awaiting " .. scene.map)
    return true
end

function TitleSession:isPrivateSlot(slot)
    return slot == PRIVATE_SLOT or (self.options.integrated and PlayerProfile.isPrivateSlot(slot))
end

function TitleSession:releaseVeto()
    local manager = self.veto
    self.veto = nil
    if valid(manager) then manager:ExitSaveVeto(FName(VETO_ID)) end
end

function TitleSession:logSaveState(context, label, registry, eligibility)
    local manager = saveManager(context)
    local ok, state = pcall(function()
        self.barrier = self.barrier or require("SaveBarrier").new()
        return self.barrier:inspect(manager, eligibility)
    end)
    self.log("Title probe save state [" .. label .. "]: " .. tostring(state))
    if not ok then return end
    if registry then
        local listed, reason = pcall(function()
            manager.SaveObjects:ForEach(function(_, parameter)
                local object = parameter
                if type(object.IsValid) ~= "function" then object = object:get() end
                local named, identity = pcall(function() return object:GetFullName() end)
                local addressed, address = pcall(function() return string.format("%X", object:GetAddress()) end)
                self.log("Title probe save object [" .. label .. "]: "
                    .. (addressed and address or "unknown") .. " " .. (named and identity or "unavailable"))
            end)
        end)
        if not listed then self.log("Title probe save object diagnostics: " .. tostring(reason)) end
    end
end

function TitleSession:installSaveDiagnostics()
    if self.saveDiagnosticsInstalled then return end
    self.saveDiagnosticsInstalled, self.saveDiagnosticsCount, self.saveDiagnosticHooks = true, 0, {}
    local function unwrapped(value)
        if type(value) == "table" or type(value) == "userdata" then
            local ok, getter = pcall(function() return value.get end)
            if ok and type(getter) == "function" then return getter(value) end
        end
        return value
    end
    for _, action in ipairs({ "TrySave", "ForceSave" }) do
        local function trace(stage, context, reason, ...)
            if self.saveDiagnosticsCount >= 64 then return end
            self.saveDiagnosticsCount = self.saveDiagnosticsCount + 1
            local parameters, parameterCount = { ... }, select("#", ...)
            local ok, failure = pcall(function()
                local owner = context:get()
                local slot = "unknown"
                -- Native save hooks also contain scalar enum/policy arguments.
                -- Inspect only struct/object candidates, including parameters
                -- after those scalars; diagnostics never assume an argument's
                -- ordinal is an FSaveGameParam or affect the save transaction.
                for index = 1, parameterCount do
                    local read, value = pcall(function()
                        local options = unwrapped(parameters[index])
                        if type(options) ~= "table" and type(options) ~= "userdata" then return nil end
                        if options.SaveSlotName == nil then return nil end
                        return text(options.SaveSlotName)
                    end)
                    if read and value and value ~= "" then slot = value; break end
                end
                self.log("Title probe native save request " .. action .. "/" .. stage
                    .. "; phase=" .. self.phase .. "; reason=" .. tostring(unwrapped(reason)) .. "; slot=" .. slot)
                local gameplay = required("/Script/Engine.Default__GameplayStatics")
                local ordinary = self.phase == "title" and stage == "before" and action == "TrySave"
                    and text(gameplay:GetCurrentLevelName(owner, true)) ~= TITLE_LEVEL
                    and valid(gameplay:GetPlayerPawn(owner, 0))
                self:logSaveState(owner, action .. "-" .. stage, ordinary, ordinary)
            end)
            if not ok then self.log("Title probe save request diagnostics: " .. tostring(failure)) end
        end
        local ok, pre, post = pcall(RegisterHook, "/Script/ProjectPBZ.PBZSaveLoadSubsystem:" .. action,
            function(context, reason, ...) trace("before", context, reason, ...) end,
            function(context, reason, ...) trace("after", context, reason, ...) end)
        if ok then self.saveDiagnosticHooks[#self.saveDiagnosticHooks + 1] = { pre, post }
        else self.log("Title probe save hook diagnostics: " .. tostring(pre)) end
    end
end

function TitleSession:auditSnapshot(phase, context)
    local audit = self.audit
    if not audit then return end
    if phase == "before" then
        repeat audit.counter = audit.counter + 1
        until not fileExists(audit.profile .. ("/ProbeSave-%03d-before.sav"):format(audit.counter))
        audit.current = audit.counter
    end
    assert(audit.current, "title probe audit entry is missing")
    local filename = ("ProbeSave-%03d-%s.sav"):format(audit.current, phase)
    local destination = audit.profile .. "/" .. filename
    assert(not fileExists(destination), "title probe audit snapshot already exists")
    local input = assert(io.open(audit.path, "rb"), "cannot read isolated title probe audit save")
    local bytes = input:read("*a")
    input:close()
    assert(bytes and #bytes > 0, "isolated title probe audit save is empty")
    writeFile(destination, bytes)
    local continue = text(saveManager(context):GetContinueSlotName()):gsub("[\r\n\t]", " ")
    writeFile(audit.profile .. "/PBZTitleProbeAudit.tsv",
        audit.current .. "\t" .. phase .. "\t" .. filename .. "\t" .. continue .. "\n", "ab")
    self.log("Title probe audit snapshot " .. filename .. "; Continue=" .. continue)
end

function TitleSession:initialize(context)
    if self.initialized then return true end
    local manager = saveManager(context)
    if not manager:IsSummaryCacheReady() then return false end
    local before = text(manager:GetContinueSlotName())
    assert(before:match("^[A-Za-z0-9_]+$") and not self:isPrivateSlot(before)
        and ((self.options.integrated and not self.options.disposable) or before == self.expected),
        "title probe Continue differs from the isolated initial baseline")
    self.initialized = true
    self.log("Title probe initial baseline verified; Continue=" .. before)
    if self.options.diagnostics~=false then
        self:installSaveDiagnostics()
        self:logSaveState(context, "initial-title", false)
    end
    return true
end

function TitleSession:enter(gameplay, menu, settings)
    if self.phase ~= "title" then return end
    if not self.options.integrated or self.options.disposable then
        assert(gameplay:DoesSaveGameExist("PBZTestArenaSeal", 0), "isolated title probe seal is absent")
    end
    local slot = PRIVATE_SLOT
    if self.options.integrated then
        assert(type(settings) == "table" and (settings.mode == "training" or settings.mode == "practice"
            or settings.mode == "challenge"), "invalid MOD mode")
        assert(PlayerProfile.valid(settings.playerCycle), "invalid MOD playerCycle")
        settings.skillLevel = PlayerProfile.normalizeSkillLevel(settings.playerCycle, settings.skillLevel)
        local enemy = settings.enemyCycle
        assert(type(enemy) == "number" and enemy % 1 == 0 and enemy >= 0 and enemy <= 6, "invalid MOD enemyCycle")
        assert(type(settings.skillLevel) == "number" and settings.skillLevel % 1 == 0
            and settings.skillLevel >= 0 and settings.skillLevel <= PlayerProfile.skillCap(settings.playerCycle), "invalid MOD skill level")
        settings.playerProfile = PlayerProfile.id(settings.playerCycle)
        settings.sceneId = Scenes.normalize(settings.sceneId)
        local difficulty = settings.difficultyMode or 3
        assert(type(difficulty) == "number" and difficulty % 1 == 0 and difficulty >= 1 and difficulty <= 3,
            "invalid MOD difficulty")
        settings.difficultyMode = difficulty
        if settings.mode ~= "training" then
            local catalog = require("EncounterCatalog")
            local selectedId = settings.encounterId or settings.bossId
            local encounter, reason = catalog.resolve(selectedId)
            if not encounter and catalog.isRetired(selectedId) then
                encounter = catalog.list(catalog.retiredCategory(selectedId) or settings.category or "duel")[1] or catalog.list("duel")[1]
                if encounter then settings.category = encounter.category end
            end
            assert(encounter and #encounter.stages > 0, reason or "invalid MOD challenge")
            assert(not settings.category or settings.category == encounter.category, "invalid MOD challenge category")
            settings.bossId, settings.encounterId, settings.category = encounter.id, encounter.id, encounter.category
        end
        settings.scene = Scenes.forEncounter(settings.mode ~= "training" and settings.encounterId or nil, settings.sceneId)
        settings.sceneId = settings.scene.id
        slot = PlayerProfile.slot(settings.playerCycle, self.options.cyclePrefix, settings.sceneId)
        self.scene = settings.scene
        self.lastSettings = settings
    end
    local manager = saveManager(menu)
    assert(manager:IsSummaryCacheReady(), "wait for the title save index to finish loading")
    assert(self:initialize(menu), "wait for the title save index to finish loading")
    local matched,providerReason=self:providerMatches(menu,manager)
    assert(matched,providerReason)
    local before = text(manager:GetContinueSlotName())
    assert(before:match("^[A-Za-z0-9_]+$") and not self:isPrivateSlot(before),
        "title probe Continue must name an ordinary save")
    local instance = gameplay:GetGameInstance(menu)
    assert(valid(instance), "title probe game instance is unavailable")
    self.returnContinue = before
    manager:EnterSaveVeto(FName(VETO_ID), MODE_GATE)
    self.veto = manager
    local ok, failure = pcall(function()
        self.barrier = self.barrier or require("SaveBarrier").new()
        self.barrier:arm(manager)
        self.log("Title probe native save transaction armed")
        self:logSaveState(menu, "after-arm", false)
        if self.audit and self.audit.pending then
            self.audit.pending = nil
            self.log("Title probe audit settled snapshot skipped because another MOD entry began too soon")
        end
        self:auditSnapshot("before", menu)
        if not self.options.integrated or self.options.disposable then
            local advancedSaved = manager:SaveAdvancedSaveGameNow()
            assert(advancedSaved == false, "native barrier did not reject the disposable Advanced write probe")
            self.log("Title probe Advanced write probe rejected by the native barrier")
        end
        if self.options.onStart then self.options.onStart(settings, slot) end
        local result = { ResultType = 255, LevelName = "", GameModeOptions = "" }
        instance:LoadGame(slot, result)
        local map = text(result.LevelName)
        local expectedMap = self.scene and self.scene.map or ARENA_LEVEL
        assert(result.ResultType == 0 and (map == expectedMap or map:sub(-#expectedMap - 1) == "/" .. expectedMap),
            "private title probe save could not be loaded")
        assert(not self.scene or text(result.GameModeOptions) == self.scene.gameModeOptions,
            "selected arena save has an unexpected game mode")
        self.log("Title probe loading private slot " .. slot .. "; initial Continue=" .. before)
        self.loadingMapEpoch, self.loadingWorldAddress = nil, nil
        self.phase = "loading"
        self.loadingDeadline = gameplay:GetRealTimeSeconds(menu) + 20
        instance:SetLoadingScreen("PBZ_WP")
        required("/Script/UMG.Default__WidgetBlueprintLibrary"):SetFocusToGameViewport()
        TitleProbe.close()
        local gameModeOptions = self.scene and self.scene.gameModeOptions or text(result.GameModeOptions)
        gameplay:OpenLevel(menu, FName(map), true, gameModeOptions)
    end)
    if not ok then
        if self.barrier and self.barrier.uncertain then
            self.phase = "blocked"
            self.log("Title probe blocked after an unacknowledged native transaction; exit the disposable session")
        elseif self.barrier and self.barrier.armed then
            self.phase = "restorePending"
            TitleProbe.close()
        else
            self.phase = "title"
            self.returnContinue = nil
            self:releaseVeto()
            -- A confirmed pre-mutation refusal is safe to inspect. Preserve
            -- its exact native gate state instead of treating every repeated
            -- refusal as an unexplained transient queue delay.
            if self.barrier and self.barrier.lastRefusal then
                local inspected, reason = pcall(self.logSaveState, self, menu, "entry-refused", false)
                if not inspected then self.log("Title probe refused-entry diagnostics: " .. tostring(reason)) end
            end
        end
        error(failure, 0)
    end
end

function TitleSession:showFailure(menu, failure)
    self.failureMessage = failureMessage(failure, self.barrier)
    local ok, errorMessage = pcall(TitleProbe.showError, menu, self.failureMessage)
    if not ok then self.log("Title probe error dialog: " .. tostring(errorMessage)) end
end

function TitleSession:returnToTitle(gameplay, controller)
    if self.options.onBeforeRestore then
        local ok,why=pcall(self.options.onBeforeRestore)
        if not ok then self.log("Arena services cleanup before ordinary cache restore: "..tostring(why))end
    end
    self:auditSnapshot("return", controller)
    self.phase = "restoring"
    TitleProbe.close()
    -- Native failed-save handling must consume queued requests before the
    -- original master/current/Advanced data and write functions are restored.
    self:releaseVeto()
    self:logSaveState(controller, "after-exit-veto", true)
    self.log("Title probe draining saves with the native barrier still armed")
    return self:finishRestore(gameplay, controller)
end

function TitleSession:finishRestore(gameplay, controller)
    local barrier = assert(self.barrier, "title probe native save transaction is missing")
    if not self:restoreProviderMatches(controller)then return false end
    if not barrier:prepareRestore() then return false end
    if not self.formalReloaded then
        self:logSaveState(controller, "after-prepare", false)
        local manager = saveManager(controller)
        local result = { ResultType = 255, LevelName = "", GameModeOptions = "" }
        -- The stock title's CheckTag uses the subsystem directly for cache-only
        -- loads; the game-instance wrapper also changes StartGameType.
        manager:LoadGame(self.returnContinue, result)
        assert(result.ResultType == 0 and text(result.LevelName) ~= "",
            "title probe could not restore the ordinary current-save cache")
        self.formalReloaded = true
        self:logSaveState(controller, "after-current-cache-load", false)
    end
    local after = text(saveManager(controller):GetContinueSlotName())
    local matched = not self:isPrivateSlot(after) and after == self.returnContinue
    if not matched then
        self.phase = "blocked"
        TitleProbe.close()
        self.log("Title probe blocked after unexpected Continue transition")
        return false
    end
    if not self:restoreProviderMatches(controller)then return false end
    if not barrier:disarm() then return false end
    self:guardOrdinaryLoads(gameplay,false)
    self:logSaveState(controller, "after-disarm", true)
    self.log("Title probe returned; Continue=" .. after .. "; matched baseline=true"
        .. "; entry Continue=" .. tostring(self.returnContinue) .. "; native transaction restored")
    self.phase = "title"
    self.saveDiagnosticsCount = 0
    self.returnContinue, self.formalReloaded = nil, nil
    if self.audit then self.audit.pending = gameplay:GetRealTimeSeconds(controller) + 3 end
    return true
end

function TitleSession:tick(gameplay, controller)
    if not valid(controller) then return end
    local level = text(gameplay:GetCurrentLevelName(controller, true))
    local protected=self.barrier and (self.barrier.armed==true or self.barrier.uncertain==true) or false
    local guardedMenu
    if level==TITLE_LEVEL then guardedMenu=self:guardOrdinaryLoads(gameplay,protected)end
    if self.phase == "blocked" then
        if level == TITLE_LEVEL then
            if protected and valid(guardedMenu) and not self.blockedNoticeShown then
                local shown=pcall(TitleProbe.showError,guardedMenu,self.failureMessage
                    or "存档保护状态尚未确认。请完全退出并重新启动游戏。")
                if shown then self.blockedNoticeShown=true end
            end
            TitleProbe.update(gameplay, function(menu)
                local ok, failure = pcall(TitleProbe.showError, menu, self.failureMessage
                    or "MOD 启动未完成，请退出游戏后重新打开验证入口。")
                if not ok then self.log("Title probe error dialog: " .. tostring(failure)) end
                return false
            end)
        end
        return
    end
    if self.audit and self.audit.pending and level ~= TITLE_LEVEL then
        self.audit.pending = nil
        self.log("Title probe audit settled snapshot skipped because the title was left too soon")
    end
    if level == TITLE_LEVEL then
        if self.phase == "arena" or self.phase == "offroute" or self.phase == "restorePending" then
            if not self:returnToTitle(gameplay, controller) then return end
        elseif self.phase == "restoring" then
            if not self:finishRestore(gameplay, controller) then return end
        elseif self.phase == "loading" then
            if gameplay:GetRealTimeSeconds(controller) < self.loadingDeadline then return end
            if not self:returnToTitle(gameplay, controller) then return end
            self.log("Title probe timed out before the arena loaded")
        end
        if self.audit and self.audit.pending and gameplay:GetRealTimeSeconds(controller) >= self.audit.pending then
            self:auditSnapshot("settled", controller)
            self.audit.pending = nil
        end
        if not self:initialize(controller) then return end
        if self.options.integrated then
            local home = require("TitleHome")
            local updated, failure = pcall(home.update, gameplay)
            if not updated then self.log("Integrated title menu: " .. tostring(failure)) end
            if self.phase ~= "title" then return end
            if not home.isOpen() then TitleProbe.resume() end
        end
        TitleProbe.update(gameplay, function(menu)
            if self.options.integrated then
                local opened, failure = pcall(require("TitleHome").open, menu, menu:GetOwningPlayer(),
                    self.lastSettings or self.options.defaults, function(selected)
                        local loaded, message = pcall(self.enter, self, gameplay, menu, selected)
                        if not loaded then
                            self.log("Integrated title load refused: " .. tostring(message))
                            self:showFailure(menu, message)
                        end
                    end)
                if not opened then self:showFailure(menu, failure) end
                return false
            end
            local ok, failure = pcall(self.enter, self, gameplay, menu)
            if not ok then
                self.log("Title probe refused load: " .. tostring(failure))
                self:showFailure(menu, failure)
            end
            return ok
        end)
    elseif self.phase == "loading" and level == (self.scene and self.scene.map or ARENA_LEVEL)
        and (self.loadingMapEpoch == nil or (self.mapEpoch or 0) > self.loadingMapEpoch
            or (self.loadingWorldAddress and worldAddress(controller)
                and worldAddress(controller) ~= self.loadingWorldAddress)) then
        self.loadingMapEpoch, self.loadingWorldAddress = nil, nil
        self.phase = "arena"
        self.log("Title probe arrived in the arena in the same process")
        reportArrival(gameplay, controller, self.log)
    elseif (level ~= (self.scene and self.scene.map or ARENA_LEVEL) and self.phase == "arena")
        or (self.phase == "loading" and gameplay:GetRealTimeSeconds(controller) >= self.loadingDeadline) then
        -- An unexpected map must not inherit the training permission. Keep the
        -- save veto until the title is reached and Continue has been checked.
        self.phase = "offroute"
        TitleProbe.close()
        self.log("Title probe left the protected arena for unexpected level " .. level .. "; arena disabled")
    elseif self.phase == "title" then
        TitleProbe.close()
        if self.options.integrated then require("TitleHome").close() end
        if self.options.diagnostics==false then self.ordinaryDue=nil;return end
        if not self.ordinaryDue and self.ordinaryLevel ~= level then
            self.ordinaryLevel, self.ordinaryDue = level, gameplay:GetRealTimeSeconds(controller) + 3
        elseif self.ordinaryDue and gameplay:GetRealTimeSeconds(controller) >= self.ordinaryDue then
            if valid(gameplay:GetPlayerPawn(controller, 0)) then
                self:logSaveState(controller, "ordinary-loaded", true, true)
                self.ordinaryDue = nil
            else self.ordinaryDue = gameplay:GetRealTimeSeconds(controller) + 1 end
        end
    end
end

return TitleSession
