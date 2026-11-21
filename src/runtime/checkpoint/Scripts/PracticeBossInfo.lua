-- Practice-only native boss registrations. AI, hatred, gameplay tags and
-- original HUD visibility remain entirely under their existing owners.
local Health = require("Health")
local Info, current, previousPhase = {}, nil, nil
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
    for _ = 1, 4 do
        if value == nil then return nil end
        -- UObject validity is a native Lua method. Probing an absent get
        -- on a retired UObject would enter the loader's reflection walker.
        local test = property(value, "IsValid")
        if type(test) == "function" then
            if not test(value) then return nil end
            if type(property(value, "GetAddress")) == "function" then return value end
        end
        local get = property(value, "get")
        if type(get) ~= "function" then get = property(value, "Get") end
        if type(get) ~= "function" then return value end
        local nextValue = get(value)
        assert(nextValue ~= value, "practice boss info wrapper cycle")
        value = nextValue
    end
    error("practice boss info wrapper depth")
end
local function actorKey(value)
    local actor = unwrap(value)
    if actor == nil then return nil end
    assert(valid(actor) and type(property(actor, "GetWorld")) == "function",
        "practice boss info weak actor is unreadable")
    return actor
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
local function registrations(session, wanted, exactTargets)
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
        if not result[address] and (not complete or exactTargets and wanted[address]) then
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
                result[address] = { actor=actor,widget=valid(widget) and widget or nil,exact=true }
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
local function clearFallback(session)
    if not session.fallback then return end
    require("PracticePhaseBossBar").remove(session.fallback)
    session.fallback = nil
end

local function updateFallback(session, actor, record, now)
    if not actor or bound(record.widget,actor) then
        session.fallbackWaitAt = nil
        clearFallback(session)
        return
    end
    local address = actor:GetAddress()
    if session.fallbackTarget ~= address then
        clearFallback(session)
        session.fallbackTarget, session.fallbackWaitAt = address, now
        session.fallbackAttempted = nil
    end
    session.fallbackWaitAt = session.fallbackWaitAt or now
    if not session.fallbackAttempted and now >= session.fallbackWaitAt + .8 then
        session.fallbackAttempted = true
        session.fallback = require("PracticePhaseBossBar").create(session.layout,session.controller,actor)
    end
end

function Info.close(retiringBosses)
    -- Transition ticks have no roster; leave the just-retired identities
    -- available while the incoming phase is loading.
    if not current then return true end
    local session = current
    clearFallback(session)
    local retiring = {}
    for _, value in ipairs(retiringBosses or {}) do
        local actor = actorKey(value)
        if valid(actor) and not actor:IsActorBeingDestroyed() and same(worldOf(actor),session.world) then
            retiring[actor:GetAddress()] = actor
        end
    end
    local snapshot = valid(session.layout) and registrations(session,retiring,retiringBosses ~= nil) or {}
    -- Retain identity within this HUD/world until the next roster binds.
    previousPhase = retiringBosses and {layout=session.layout,world=session.world,actors=retiring} or nil
    if retiringBosses then
        for address, actor in pairs(retiring) do
            local registration = snapshot[address]
            if registration and bound(registration.widget,actor) then
                -- Stage cleanup owns these exact actors and will destroy them next.
                -- Detach the native bar even if its original registration was borrowed.
                session.layout:UnRegisterBossHPBar(actor)
                session.actors[address] = nil
            end
        end
    end
    for _, record in pairs(session.actors) do retire(session, record, snapshot[record.address]) end
    current = nil
    return true
end

function Info.update(controller, bosses, now, phase, aiOff)
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
    local recover = phase and phase > 1 and aiOff == true
    if previousPhase and (not same(previousPhase.layout,layout) or not same(previousPhase.world,world)) then
        previousPhase = nil
    end
    local snapshot = registrations(session,wanted,recover)
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
        -- An opaque handle may outlive the transition that removed its widget.
        -- Replace only our own still-pending registration, once per target.
        if recover and not valid(record.widget) and record.owned and record.pending then
            record.pendingSince = record.pendingSince or now
            if registration and registration.exact and not record.retried and now >= record.pendingSince + .6 then
                record.retried = true
                local handle = layout:RegisterBossHPBar(actor)
                assert(handle ~= nil, "practice boss info registration retry returned no handle")
                local widget = unwrap(layout:GetBossHPBarInstanceByHandle(handle))
                record.widget = valid(widget) and widget or nil
            end
        else
            record.pendingSince = nil
        end
        local character = (record.owned or recover) and valid(record.widget) and actorKey(record.widget.Character) or nil
        local retired = recover and previousPhase and valid(character)
            and same(previousPhase.actors[character:GetAddress()],character)
            and select(3,Health.read(character)) == true
        local retryBinding = recover and registration and registration.exact and (not valid(character) or retired)
        if (record.owned or retryBinding) and valid(record.widget) then
            assert(not valid(character) or same(character,actor) or retryBinding,
                "practice boss info widget belongs to another actor")
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
    local fallbackTarget = recover and #ordered == 1 and ordered[1]
    if fallbackTarget then
        updateFallback(session,fallbackTarget.actor,session.actors[fallbackTarget.address],now)
    else
        updateFallback(session,nil,nil,now)
    end
    return true
end
return Info
