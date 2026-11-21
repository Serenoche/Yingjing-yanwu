-- Run with Lua 5.4 from the repo root, optionally passing a staged pressure script.
local script = arg[1] or "src/runtime/Scripts/DreamPalacePressure.lua"
local registry = debug.getregistry()
local savedFNameMetatable = registry.FNameUserdata
local fnameMetatable = {}
local fnameValue = io.stdin
local savedStdinMetatable = debug.getmetatable(fnameValue)
debug.setmetatable(fnameValue, fnameMetatable)

local function target(address, hasSession, valid)
    local actor = {}
    function actor:IsValid() return valid ~= false end
    function actor:GetAddress()
        assert(self:IsValid(), "GetAddress called on an invalid actor")
        return address
    end
    return { actor = actor, id = tostring(address), hasSession = hasSession }
end

local function check(spec)
    registry.FNameUserdata = fnameMetatable
    if spec.missingMetatable then registry.FNameUserdata = nil end

    local events, active = {}, {}
    local targets = spec.targets or { target(90, true) }
    for _, member in ipairs(targets) do active[member.actor] = member.hasSession end

    local function record(event, value)
        events[#events + 1] = value and (event .. ":" .. value) or event
    end

    local telemetry = { IsValid = function() return true end, GetAddress = function() return 500 end }
    function telemetry:HasActiveSessionForBoss(actor)
        assert(actor:IsValid(), "telemetry called on an invalid actor")
        return active[actor]
    end
    function telemetry:EndBossEncounter(actor, reason)
        record("end", actor:GetAddress())
        assert(active[actor], "ended an inactive session")
        assert(rawequal(reason, fnameValue), "non-FName reached EndBossEncounter")
        active[actor] = false
    end
    function telemetry:AutoBeginEncounterWithDefaultProfile(actor)
        record("begin", actor:GetAddress())
        active[actor] = true
    end

    local pawn = {}
    local subsystemClass = { IsValid = function() return true end }
    local library = { IsValid = function() return true end }
    function library:GetWorldSubsystem(context, class)
        assert(context == pawn and class == subsystemClass, "incorrect world subsystem lookup")
        return telemetry
    end

    local numBinds = 0
    local function dispatch(command, first, second, rule)
        if command == 6 then return first, -13.25 end -- Lua bridge probe
        if command == 4 then return 1 end -- prepare
        if command == 2 then record("release", first); return end
        assert(command == 1 and first == 500 and rule == 90, "incorrect floor pressure bind")
        record("bind", second)
        numBinds = numBinds + 1
        return assert(spec.tokens[numBinds], "unexpected bind attempt")
    end

    local globals = setmetatable({
        IsInGameThread = function() return true end,
        StaticFindObject = function(path)
            if path == "/Script/Engine.Default__SubsystemBlueprintLibrary" then return library end
            assert(path == "/Script/TensionMeter.TensionWorldSubsystem", "unknown reflected object")
            return subsystemClass
        end,
        FName = function(text)
            assert(text == "PressureRebind", "incorrect rebind reason")
            record("fname")
            if spec.makeName then return spec.makeName() end
            return fnameValue
        end,
        package = {
            loadlib = function(path, symbol)
                assert(path:match("/PBZDreamPressureNative%.dll$") and symbol == "PBZPressureDispatch")
                return dispatch
            end,
        },
        print = function() end,
    }, { __index = _G })

    local pressure = assert(loadfile(script, "t", globals))()
    pressure.configure({
        platform = "steam",
        gameSha256 = "4415933ce33476f14c837abb61a1b60af8b78cd81783896501913a7aac69e423",
    })
    assert(pressure.available(), "mock pressure backend unavailable")
    local ok, result = pcall(pressure.new, pawn, targets, 90, 1)
    if ok then result:close() end
    local trace = table.concat(events, ",")
    assert(trace == spec.trace, ("%s: expected %q, got %q"):format(spec.label, spec.trace, trace))
    if spec.failure then
        assert(not ok and tostring(result):find(spec.failure, 1, true), spec.label .. ": " .. tostring(result))
        if spec.keepSession then
            assert(active[targets[#targets].actor] == true, "lost the original session")
        end
    else
        assert(ok, spec.label .. ": " .. tostring(result))
    end
    print("ok - " .. spec.label)
end

check({ label = "rebind a shared session", tokens = { -5, 301 },
    trace = "bind:90,fname,end:90,begin:90,bind:90,release:301" })
check({ label = "reuse an already bindable session", tokens = { 301 }, trace = "bind:90,release:301" })
check({ label = "start a fresh session", targets = { target(90, false) }, tokens = { 301 },
    trace = "begin:90,bind:90,release:301" })
check({ label = "rebind only once after a second rejection", tokens = { -5, -5 },
    trace = "bind:90,fname,end:90,begin:90,bind:90", failure = "原版压力配置未为此单位分配独立实例" })

local invalidNames = {
    { label = "reject a Lua string", makeName = function() return "PressureRebind" end },
    { label = "reject nil", makeName = function() return nil end },
    { label = "reject another userdata", makeName = function() return io.stdout end },
    { label = "reject a table carrying the FName metatable", makeName = function()
        return setmetatable({}, fnameMetatable)
    end },
    { label = "reject a missing registry type", missingMetatable = true },
}
for _, spec in ipairs(invalidNames) do
    spec.tokens, spec.trace = { -5 }, "bind:90,fname"
    spec.failure, spec.keepSession = "AI 压力重绑需要有效的 FName", true
    check(spec)
end

check({ label = "release the first target's token after the second is rejected",
    targets = { target(89, true), target(90, true) }, tokens = { 301, -5 },
    makeName = function() return io.stdout end, trace = "bind:89,bind:90,fname,release:301",
    failure = "AI 压力重绑需要有效的 FName", keepSession = true })
check({ label = "reject an invalid boss before calling telemetry", targets = { target(90, true, false) },
    tokens = {}, trace = "", failure = "战斗单位或压力子系统已经失效" })

debug.setmetatable(fnameValue, savedStdinMetatable)
registry.FNameUserdata = savedFNameMetatable
