local Pressure = {}
local Run = {}
Run.__index = Run

local WORLD_LIBRARY = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local TENSION_CLASS = "/Script/TensionMeter.TensionWorldSubsystem"
local NATIVE_MODULE = "PBZDreamPressureNative"
local STEAM_GAME_SHA256 = "4415933ce33476f14c837abb61a1b60af8b78cd81783896501913a7aac69e423"
local BIND, RELEASE, SAMPLE, PREPARE, CUSTOM_BIND, PROBE = 1, 2, 3, 4, 5, 6
local CUSTOM_MODES = { fixed = 1, minimum = 2 }
local BIND_ERRORS = {
    [-1] = "当前 Steam 版本的压力接口未通过校验",
    [-2] = "战斗单位或压力子系统已经失效",
    [-3] = "原版压力计算器不可用",
    [-4] = "场内压力会话已满",
    [-5] = "原版压力配置未为此单位分配独立实例",
}
local native, diagnostics, available
local configFailure = "not_initialized"

local function valid(object)
    return object ~= nil and object:IsValid()
end

function Pressure.configure(config)
    if not config then
        configFailure = "missing"
    elseif config.platform ~= nil and config.platform ~= "steam" then
        configFailure = "platform"
    elseif config.gameSha256 == nil then
        configFailure = "game_hash_missing"
    elseif config.gameSha256 ~= STEAM_GAME_SHA256 then
        configFailure = "game_hash_mismatch"
    else
        configFailure = nil
    end
    diagnostics = config and config.diagnostics == true
    available = nil
end

function Pressure.backend()
    if native then return native end
    local source = debug.getinfo(1, "S").source
    local directory = source:sub(1, 1) == "@" and source:sub(2):match("^(.*)[/\\][^/\\]+$")
    if not directory then error("AI 压力模块路径不可用 (stage=script_path)", 0) end
    local path = directory .. "/" .. NATIVE_MODULE .. ".dll"
    local dispatcher, failure, step = package.loadlib(path, "PBZPressureDispatch")
    if not dispatcher then
        local file = io.open(path, "rb")
        if file then file:close() end
        error(("AI 压力模块载入失败 (stage=loadlib step=%s file=%s) %s"):format(
            step or "unknown", file and "readable" or "unreadable", tostring(failure)), 0)
    end
    -- Probe the Lua bridge without preparing pressure hooks or accessing game objects.
    local cookie = 0x123456789abcdef
    local echoed, fraction = dispatcher(PROBE, cookie)
    if echoed ~= cookie or math.type(echoed) ~= "integer" or fraction ~= -13.25 then
        error("当前 UE4SS 版本的压力接口未通过校验 (stage=native_init reason=lua_bridge_probe)", 0)
    end
    native = dispatcher
    return native
end

function Pressure.available()
    if available == nil then
        local reason
        if configFailure then
            available, reason = false, "stage=config reason=" .. configFailure
        else
            available, reason = pcall(Pressure.backend)
        end
        local status = available and "status=ready" or ("status=unavailable " .. tostring(reason):gsub("%c", " "))
        print("[PBZPressure] " .. status .. "\n")
    end
    return available
end

local function log(self, record, message)
    local prefix = self.floor and ("[PBZBloodyPalace] pressure floor=%d"):format(self.floor)
        or ("[PBZTestArenaNative] Custom pressure mode=%s value=%d"):format(self.rule.mode, self.rule.value)
    print(("%s stage=%d unit=%s %s\n"):format(prefix, self.stage, record.id, message))
end

local function bind(self, actor)
    assert(valid(actor), BIND_ERRORS[-2])
    local telemetry, native = self.telemetry, self.native
    local function attach()
        local observe = self.observe and 1 or 0
        if self.floor then return native(BIND, telemetry:GetAddress(), actor:GetAddress(), self.floor, observe) end
        return native(CUSTOM_BIND, telemetry:GetAddress(), actor:GetAddress(), self.rule.value, observe,
            CUSTOM_MODES[self.rule.mode])
    end
    if telemetry:HasActiveSessionForBoss(actor) then
        local token = attach()
        if token ~= -5 then return token end
        -- Some bosses start from the original shared asset during BeginPlay.
        -- Only replace the session belonging to this newly spawned actor.
        -- UE4SS's FName parameter setter assumes the userdata's native layout.
        local reason = FName("PressureRebind")
        local nameMetatable = debug.getregistry().FNameUserdata
        assert(type(reason) == "userdata" and type(nameMetatable) == "table"
            and rawequal(debug.getmetatable(reason), nameMetatable), "AI 压力重绑需要有效的 FName")
        telemetry:EndBossEncounter(actor, reason)
    end
    telemetry:AutoBeginEncounterWithDefaultProfile(actor)
    return attach()
end

function Pressure.new(pawn, targets, rule, stage, observe)
    assert(IsInGameThread(), "AI 压力只能在游戏线程设置")
    if observe == nil then observe = diagnostics end
    local floor = type(rule) == "number" and rule or nil
    assert(floor or type(rule) == "table" and CUSTOM_MODES[rule.mode], "自订压力模式无效")
    local native = Pressure.backend()
    assert(native(PREPARE) == 1, BIND_ERRORS[-1])
    local library, class = StaticFindObject(WORLD_LIBRARY), StaticFindObject(TENSION_CLASS)
    assert(valid(library) and valid(class), "原版压力子系统类型不可用")
    local telemetry = library:GetWorldSubsystem(pawn, class)
    assert(valid(telemetry), "当前战场没有原版压力子系统")
    local self = setmetatable({ native = native, telemetry = telemetry, floor = floor, rule = rule, stage = stage,
        observe = observe, records = {} }, Run)
    local ok, failure = pcall(function()
        for index, target in ipairs(targets) do
            local record = { id = target.id }
            self.records[index] = record
            local token = bind(self, target.actor)
            assert(token > 0, BIND_ERRORS[token] or "原版压力会话未就绪")
            record.token = token
            if observe then
                local message = floor and ("bound min=%d fixed=%s"):format(math.min(floor, 100), tostring(floor >= 100))
                    or "bound"
                log(self, record, message)
            end
        end
    end)
    if not ok then self:close(); error(failure, 0) end
    return self
end

function Run:sample(now, final)
    if not self.observe or not final and now < (self.nextSample or 0) then return end
    self.nextSample = now + 2
    for _, record in ipairs(self.records) do
        if record.token then
            local raw, effective, tier, confidence, updates, reads, aiQueries = self.native(SAMPLE, record.token)
            if effective then
                log(self, record, ("native=%.2f effective=%.2f tier=%d confidence=%.2f updates=%d readouts=%d aiQueries=%d%s")
                    :format(raw, effective, tier, confidence, updates, reads, aiQueries, final and " final=true" or ""))
            elseif final then
                log(self, record, "session ended before final sample")
            end
        end
    end
end

function Run:close()
    self:sample(0, true)
    for _, record in ipairs(self.records) do
        if record.token then self.native(RELEASE, record.token) end
    end
    -- The subsystem closes its session when clearStage destroys the actor.
    self.records = {}
end

return Pressure
