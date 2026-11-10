-- Practice-only native boss registrations. AI, hatred, gameplay tags and
-- original HUD visibility remain entirely under their existing owners.
local Health = require("Health")
local Info, current = {}, nil
local HUD_CDO = "/Script/ProjectPBZ.Default__PBZHUDLayout"
local HUD_CLASS = "/Script/ProjectPBZ.PBZHUDLayout"
local INTERVAL = 0.2
local function property(value,name)
    local ok,result = pcall(function() return value[name] end)
    return ok and result or nil
end
local function valid(value)
    local test = value ~= nil and property(value,"IsValid")
    return type(test) == "function" and test(value)
end
local function same(a,b) return valid(a) and valid(b) and a:GetAddress() == b:GetAddress() end
local function unwrap(value)
    for _=1,4 do
        if value == nil then return value end
        local get = property(value,"get")
        if type(get) ~= "function" then
            if type(property(value,"IsValid")) == "function" and type(property(value,"GetAddress")) == "function" then return value end
            get = property(value,"Get")
        end
        if type(get) ~= "function" then return value end
        local nextValue = get(value)
        assert(nextValue ~= value, "practice boss info wrapper cycle")
        value = nextValue
    end
    error("practice boss info wrapper depth")
end
local function actorKey(value)
    for _=1,4 do
        if value == nil then return nil end -- expired weak actor
        local get = property(value,"get")
        if type(get) ~= "function" then
            local test = property(value,"IsValid")
            if type(test) == "function" and not test(value) then return nil end
            -- AActor helpers are Lua functions. Reflected methods such as
            -- IsActorBeingDestroyed are callable UFunction userdata instead.
            if type(property(value,"GetAddress")) == "function" and type(property(value,"GetWorld")) == "function" then return value end
            get = property(value,"Get")
        end
        assert(type(get) == "function", "practice boss info weak actor is unreadable")
        local nextValue = get(value)
        assert(nextValue ~= value, "practice boss info weak actor cycle")
        value = nextValue
    end
    error("practice boss info weak actor depth")
end
local function worldOf(actor)
    return valid(actor) and unwrap(actor:GetWorld()) or nil
end
local function required(path)
    local value = unwrap(StaticFindObject(path))
    assert(valid(value), "practice boss info interface unavailable: " .. path)
    return value
end
local function bound(widget, actor)
    return valid(widget) and same(actorKey(widget.Character), actor)
end

-- Let the native layout resolve its weak actor map. For still-pending entries,
-- query only known actors: WeakObjectProperty GetParam (ForEach keys) is not
-- supported by this loader. Consume each fresh opaque value immediately.
local function registrations(session, wanted)
    local result = {}
    local known = {}
    for address, actor in pairs(wanted) do known[address] = actor end
    for address, record in pairs(session.actors) do
        if valid(record.actor) then known[address] = record.actor end
    end
    local instances = session.layout:GetBossHPBarInstances()
    assert(instances ~= nil, "practice boss info native instance list is unavailable")
    local count = #instances
    assert(type(count) == "number" and count >= 0 and count <= 256, "practice boss info native instance count is invalid")
    local complete = true
    for index=1,count do
        local widget = unwrap(instances[index])
        if valid(widget) then
            local actor = actorKey(widget.Character)
            if valid(actor) then
                local address = actor:GetAddress()
                if known[address] then
                    assert(not result[address], "practice boss info duplicate native instance")
                    result[address] = { actor=actor,widget=widget }
                end
            else complete = false end
        else complete = false end
    end
    local map
    for address, actor in pairs(known) do
        if not result[address] and not complete then
            map = map or session.layout.RegisterBossHandles
            assert(map ~= nil, "practice boss info registry unavailable")
            local present = map:Contains(actor)
            assert(type(present) == "boolean", "practice boss info registry presence is unreadable")
            if present then
                local parameter = map:Find(actor)
                local get = parameter and property(parameter,"get")
                assert(type(get) == "function", "practice boss info native handle is unreadable")
                local handle = get(parameter)
                assert(handle ~= nil, "practice boss info native handle is absent")
                local widget = unwrap(session.layout:GetBossHPBarInstanceByHandle(handle))
                result[address] = { actor=actor,widget=valid(widget) and widget or nil }
            end
        end
    end
    return result
end
local function removeOwnWidget(record)
    if not record.owned or not valid(record.widget) then return end
    local character = actorKey(record.widget.Character)
    -- A native widget may have been recycled for a different living actor.
    if valid(character) and character:GetAddress() ~= record.address then return end
    record.widget:RemoveFromParent()
end
local function retire(session, record, registration)
    if record.owned then
        local localActor = valid(record.actor) and same(worldOf(record.actor), session.world)
        local matching = registration and same(registration.actor, record.actor)
        local pendingCharacter = matching and valid(registration.widget) and actorKey(registration.widget.Character) or nil
        local ownInstance = matching and ((record.pending and not record.widget
                and (not valid(registration.widget) or not valid(pendingCharacter) or same(pendingCharacter,record.actor)))
            or (same(record.widget, registration.widget)
                and (not valid(pendingCharacter) or same(pendingCharacter,record.actor))))
        if valid(session.layout) and localActor and ownInstance then
            session.layout:UnRegisterBossHPBar(record.actor)
        elseif not localActor or not valid(session.layout) then
            -- Never pass an invalid actor to a UFunction. Its old native
            -- registration is weak; dispose only our still-owned visual.
            removeOwnWidget(record)
        end
    end
    session.actors[record.address] = nil
end
function Info.close()
    if not current then return true end
    local session = current
    local snapshot = valid(session.layout) and registrations(session,{}) or {}
    for _, record in pairs(session.actors) do retire(session, record, snapshot[record.address]) end
    current = nil
    return true
end

function Info.update(controller, bosses, now)
    assert(type(now) == "number" and now == now and math.abs(now) < math.huge
        and type(bosses) == "table", "practice boss info update is unavailable")
    controller = unwrap(controller)
    assert(valid(controller), "practice boss info controller is unavailable")
    local world = worldOf(controller)
    assert(valid(world), "practice boss info world is unavailable")
    -- GetUILayOut returns the outer PrimaryGameLayout. Only this native static
    -- getter selects the PBZHUDLayout registered on its game-layer stack.
    local layout = unwrap(required(HUD_CDO):GetHUDLayout(controller))
    assert(valid(layout), "practice boss info native HUD is not ready")
    assert(layout:IsA(required(HUD_CLASS)), "practice boss info receiver is not PBZHUDLayout")
    assert(same(unwrap(layout:GetOwningPlayer()),controller)
        and same(unwrap(layout:GetWorld()),world), "practice boss info layout owner mismatch")
    if current and (not same(current.layout,layout) or not same(current.controller,controller)
        or not same(current.world,world)) then Info.close() end
    if not current then
        current = { layout=layout,controller=controller,world=world,actors={} }
        local named,name = pcall(function()
            local value = layout:GetClass():GetFName()
            return type(value) == "string" and value or value:ToString()
        end)
        if not named or type(name) ~= "string" or not name:match("^[A-Za-z0-9_]+$") then name = "PBZHUDLayout" end
        print("[PBZPracticeBossInfo] native HUD ready; class=" .. name .. "\n")
    end
    local session = current
    if session.nextAt and now < session.nextAt then return true end
    session.nextAt = now + INTERVAL
    local wanted, ordered = {}, {}
    for _, actor in ipairs(bosses) do
        actor = actorKey(actor)
        if valid(actor) and not actor:IsActorBeingDestroyed() then
            assert(same(worldOf(actor),world), "practice boss info target belongs to another world")
            local _, _, dead = Health.read(actor)
            if not dead then
                local address = actor:GetAddress()
                assert(not wanted[address], "practice boss info duplicate target")
                wanted[address] = actor
                ordered[#ordered+1] = { address=address,actor=actor }
            end
        end
    end
    -- Complete the registry snapshot before changing any extension.
    -- Unreadable keys/handles must not be mistaken for absent registrations.
    local snapshot = registrations(session,wanted)
    for address, record in pairs(session.actors) do
        if not wanted[address] then retire(session,record,snapshot[address]) end
    end
    for _, item in ipairs(ordered) do
        local address,actor = item.address,item.actor
        local record, registration = session.actors[address], snapshot[address]
        if registration then
            if not record then
                record = { actor=actor,address=address,owned=false }
                session.actors[address] = record
            elseif record.owned and record.widgetAddress and valid(registration.widget)
                and record.widgetAddress ~= registration.widget:GetAddress() then
                -- The manager has replaced our instance; borrow its new one.
                record.owned, record.pending = false, false
            end
            record.widget = registration.widget
        else
            if record then removeOwnWidget(record) end
            record = { actor=actor,address=address,owned=true,pending=true }
            session.actors[address] = record -- retain ownership if native Init fails
            local handle = layout:RegisterBossHPBar(actor)
            assert(handle ~= nil, "practice boss info registration returned no handle")
            local widget = unwrap(layout:GetBossHPBarInstanceByHandle(handle))
            record.widget = valid(widget) and widget or nil
        end
        if record.owned and valid(record.widget) then
            local character = actorKey(record.widget.Character)
            assert(not valid(character) or same(character,actor), "practice boss info widget belongs to another actor")
            local widgetAddress = record.widget:GetAddress()
            record.widgetAddress = widgetAddress
            if not same(character,actor) and record.initAttempt ~= widgetAddress then
                record.initAttempt = widgetAddress
                record.widget:Init(actor)
            end
            assert(bound(record.widget,actor), "practice boss info Init did not bind its target")
            record.pending = false
        end
    end
    return true
end
return Info
