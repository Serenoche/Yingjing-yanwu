-- Keep discovery separate from the regular reads of already attached bars.
local Schedule = {}
local SOURCE_KEYS = {"common", "erosion"}

local function address(object)
    if object and type(object.IsValid) == "function" and object:IsValid() then
        return object:GetAddress()
    end
end

local function reset(session, now)
    session.scan, session.barsAt, session.sourcesAt = nil, now, now
    session.settleUntil, session.updateAt = now + 2, now
end

function Schedule.sync(session, allowed, stage, lostBar, now)
    local previous = session.owners or {}
    local owners, byASC = {}, {}
    local newStage = session.stage ~= stage
    local changed, lostSource = session.owners == nil or newStage, false
    for id, actor in pairs(allowed) do
        local asc = address(actor.AbilitySystemComponent)
        owners[id] = asc or false
        if asc then byASC[asc] = id end
        if newStage or previous[id] ~= owners[id] then
            session.abilities[id] = nil
            changed = true
        end
    end
    for id in pairs(previous) do
        if owners[id] == nil then
            session.abilities[id] = nil
            changed = true
        end
    end
    for _, owned in pairs(session.abilities) do
        for _, key in ipairs(SOURCE_KEYS) do
            if owned[key] and not address(owned[key]) then
                owned[key], lostSource = nil, true
            end
        end
        for row, object in pairs(owned.charges or {}) do
            if not address(object) then owned.charges[row], lostSource = nil, true end
        end
    end
    session.owners, session.stage = owners, stage
    if changed or lostBar then
        reset(session, now)
    elseif lostSource then
        if session.scan and session.scan.kind == "sources" then session.scan = nil end
        session.sourcesAt = now
    end
    return byASC
end

function Schedule.due(session, now)
    return session.scan ~= nil or now >= session.barsAt
        or (now >= session.sourcesAt and next(session.views) ~= nil)
end

function Schedule.step(session, allowed, byASC, now, find, discovery)
    local scan = session.scan
    if not scan then
        if now >= session.barsAt then
            scan = {kind = "bars", index = 1}
        elseif now >= session.sourcesAt and next(session.views) then
            scan = {kind = "sources", index = 1, found = {}}
        else
            return
        end
        session.scan = scan
    end
    if scan.kind == "bars" then
        if discovery.readBar(session, allowed, discovery.bars[scan.index], find) then
            session.sourcesAt, session.updateAt = math.min(session.sourcesAt, now), now
        end
        if scan.index == #discovery.bars then
            local attached = {}
            for _, view in pairs(session.views) do attached[view.actor:GetAddress()] = true end
            local interval = now < session.settleUntil and .45 or 4
            for id in pairs(allowed) do
                if not attached[id] then interval = math.min(interval, 1.25); break end
            end
            session.barsAt, session.scan = now + interval, nil
        end
    elseif discovery.abilities[scan.index] then
        discovery.readAbility(scan.found, allowed, byASC, discovery.abilities[scan.index], find)
    else
        discovery.readCharge(scan.found, allowed, byASC, find)
        session.abilities, session.scan = scan.found, nil
        session.sourcesAt = now + (now < session.settleUntil and .65 or 8)
    end
    scan.index = scan.index + 1
end

return Schedule
