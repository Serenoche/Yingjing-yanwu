-- A detached UMG signal forwards the PuerTS subscription to Lua.
local EffectClock = require("StatusEffectClock")
local Settings = require("ModLoaderSettings")
local Frost = {}
local scope, nextId, retryAt, lastBridgeFailure
local companionAvailable
local serial = 0
local SIGNAL_PATH = "/Script/UMG.Button:SetClickMethod"
local CLOCK = os.clock
local quietRows = {}
local FREEZE_COLOR = {R=.35,G=.77,B=1,A=1}
nextId = 0

local function valid(o)
    local kind = type(o)
    return (kind == "table" or kind == "userdata") and type(o.IsValid) == "function" and o:IsValid()
end

local function unwrap(o)
    local kind = type(o)
    if (kind == "table" or kind == "userdata") and type(o.IsValid) ~= "function"
        and type(o.get) == "function" then return o:get() end
    return o
end

local function path(o)
    return o:GetFullName():match("^%S+ (.+)$")
end

local function responseText(channel)
    local value = channel.response:GetText()
    return type(value) == "string" and value or value:ToString()
end

local function number(n)
    return type(n) == "number" and n == n and math.abs(n) < math.huge
end

local function raw(o, field)
    local ok, result = pcall(function() return o.AttributeSetBase[field].CurrentValue end)
    return ok and number(result) and result or 0
end

local function log(message)
    print("[PBZFrostEvent] " .. message .. "\n")
end

local function parse(message)
    local kind, token, value, old = message:match("^([^|]+)|(%d+)|([^|]+)|?([^|]*)$")
    return kind, tonumber(token), tonumber(value), tonumber(old), value
end

local function wire(channel, message)
    local ok, response = pcall(function()
        channel.command:SetText(FText(message))
        channel.signal.OnClicked:Broadcast()
        return responseText(channel)
    end)
    if ok then return parse(response) end
    return nil, nil, nil, nil, tostring(response)
end

function Frost.close(reason)
    local old = scope
    scope = nil
    if not old then return end
    serial = serial + 1
    local kind, receipt, count, _, details = wire(old, "clear|" .. serial)
    local expected = 0
    for _ in pairs(old.records) do expected = expected + 1 end
    if kind ~= "cleared" or receipt ~= serial or count ~= expected then
        log(("subscription cleanup incomplete; reason=%s expected=%d cancelled=%s receipt=%s")
            :format(reason or "scope end", expected, tostring(count), tostring(details or kind)))
    end
    local ok, failure = pcall(UnregisterHook, SIGNAL_PATH, old.pre, old.post)
    if not ok then log("hook removal failed: " .. tostring(failure)) end
end

local function notify(context)
    local current = scope
    if not current then return end
    local signal = unwrap(context)
    if not valid(signal) or signal:GetAddress() ~= current.signalAddress then return end
    local ok, message = pcall(responseText, current)
    if not ok then return end
    local kind, token, value = parse(message)
    local record = current.tokens[token]
    if kind == "error" and record then current.invalid = true; return end
    if not record or not number(value) then return end
    if kind == "confirmed" then
        record.confirmed = true
        return
    end
    if kind == "freeze" then
        record.frozen = value > 0
        return
    end
    if kind ~= "change" then return end
    record.value, record.rows = math.max(0, value), nil
end

local function open(gameplay, pawn, world, stage)
    local game = unwrap(gameplay:GetGameInstance(pawn))
    if not valid(game) then return nil, "game-instance" end
    local name = path(game)
    if not name then return nil, "game-instance-path" end
    local function owned(object)
        if not valid(object) then return false end
        local outer = object:GetOuter()
        return valid(outer) and outer:GetAddress() == game:GetAddress()
    end
    local function control(suffix)
        local objectName = "PBZFrostR3" .. suffix
        for _, separator in ipairs({":", "."}) do
            local object = StaticFindObject(name .. separator .. objectName)
            if owned(object) then return object end
        end
    end
    local response = control("Response")
    if not response then return nil, "bootstrap-marker-missing" end
    local signal, command = control("Signal"), control("Command")
    local channel = {command=command,response=response,signal=signal}
    if not command or not signal then return nil, "bootstrap-incomplete:" .. responseText(channel) end
    serial = serial + 1
    local kind, receipt, revision, _, details = wire(channel, "ping|" .. serial)
    if kind ~= "pong" or receipt ~= serial or revision ~= 3 then
        return nil, "handshake:" .. tostring(details or kind or responseText(channel))
    end
    local ok, pre, post = pcall(RegisterHook, SIGNAL_PATH, notify)
    if not ok or type(pre) ~= "number" or type(post) ~= "number" then
        return nil, "signal-hook:" .. tostring(pre)
    end
    channel.pre, channel.post = pre, post
    channel.signalAddress, channel.world, channel.stage = channel.signal:GetAddress(), world:GetAddress(), stage
    channel.records, channel.tokens = {}, {}
    return channel
end

local function sync(gameplay, pawn, actors, stage, world)
    if companionAvailable == nil then
        companionAvailable = Settings.companionAvailable("PBZFrostEventR3")
        if not companionAvailable then log("bridge companion unavailable; using ice polling") end
    end
    if not companionAvailable then return end
    if not valid(world) then return end
    if scope and scope.invalid then Frost.close("event delivery failed") end
    if scope and (scope.world ~= world:GetAddress() or scope.stage ~= stage) then Frost.close("target stage changed") end
    if not scope then
        local now = CLOCK()
        if retryAt and now < retryAt then return end
        local opened, channel, why = pcall(open, gameplay, pawn, world, stage)
        if opened then scope = channel end
        if not scope then
            local reason = tostring(opened and why or channel)
            if reason ~= lastBridgeFailure then
                log("bridge unavailable; using ice polling reason=" .. reason)
                lastBridgeFailure = reason
            end
            retryAt = now + 5
            return
        end
        retryAt, lastBridgeFailure = nil, nil
    end
    local current = scope
    local seen, expected = {}, 0
    local complete = true
    for _, actor in ipairs(actors) do
        if valid(actor) then
            local id = actor:GetAddress()
            seen[id] = true
            expected = expected + 1
            local record = current.records[id]
            if not record and CLOCK() >= (current.retryAt or 0) then
                local actorPath = path(actor)
                if actorPath and not actorPath:find("|",1,true) then
                    nextId = nextId + 1
                    local kind, token, value, active, details = wire(current, "bind|" .. nextId .. "|" .. actorPath)
                    if kind == "bound" and token == nextId and number(value) and (active == 0 or active == 1) then
                        record = {token=token, value=math.max(0,value), frozen=active==1, boundAt=CLOCK()}
                        current.records[id], current.tokens[token] = record, record
                    else
                        current.retryAt = CLOCK() + 1
                        log(("bind unavailable token=%d reason=%s"):format(nextId,tostring(details or kind)))
                    end
                end
            end
            if not record or not record.confirmed then
                complete = false
                if record and CLOCK() - record.boundAt >= 2 and not current.warnedDelivery then
                    current.warnedDelivery = true
                    log("subscription active but delivery unconfirmed; using ice polling")
                end
            end
        end
    end
    for id, record in pairs(current.records) do
        if not seen[id] then
            current.records[id], current.tokens[record.token] = nil, nil
            local kind, token, _, _, details = wire(current, "unbind|" .. record.token)
            if kind ~= "unbound" or token ~= record.token then
                log(("unbind failed token=%d reason=%s"):format(record.token, tostring(details or kind)))
            end
        end
    end
    current.ready = complete and expected > 0
end

function Frost.sync(gameplay, pawn, actors, stage, world)
    local ok, failure = pcall(sync, gameplay, pawn, actors, stage, world)
    if not ok then
        Frost.close("subscription error")
        local reason = tostring(failure)
        if reason ~= lastBridgeFailure then log("using ice polling; " .. reason) end
        lastBridgeFailure, retryAt = reason, CLOCK() + 5
    end
end

local function rows(actor, value)
    if value <= .001 then return quietRows end
    local max = raw(actor, "Infliction_Max")
    return {{id="chill",name="冰缓",value=value,ratio=max > 0 and math.min(1,value/max) or nil,
        mode=max > 0 and "buildup" or "unknown",source="native-attribute",color={R=.35,G=.90,B=.95,A=1}}}
end

local function freezeRows(actor)
    local effects = EffectClock.read(actor, actor.AbilitySystemComponent)
    local freeze = effects.frost
    return {{id="frost",name="冰冻",mode="active",color=FREEZE_COLOR,
        ratio=freeze and freeze.ratio, remaining=freeze and freeze.remaining,
        source=freeze and freeze.source or "native-tag"}}
end

function Frost.eventRows(actor)
    local record = scope and scope.ready and scope.records[actor:GetAddress()]
    if not record then return nil end
    if record.frozen then return freezeRows(actor) end
    if not record.rows then record.rows = rows(actor, record.value) end
    return record.rows
end

return Frost
