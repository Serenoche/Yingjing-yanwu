local Rules = { firstFloor = 41 }
local Sequence = {}
Sequence.__index = Sequence

local ATTACK_STRATEGIES = {
    ["AI.Strategy.Command"] = true,
    ["AI.Strategy.WhiffPunish"] = true,
    ["AI.Strategy.AntiCharge"] = true,
    ["AI.Strategy.AntiMelee"] = true,
    ["AI.Strategy.AntiApproach"] = true,
    ["AI.Strategy.AntiProjectile"] = true,
    ["AI.Strategy.PunishCounter"] = true,
    ["AI.Strategy.Bluffing"] = true,
}
local ATTACK_TREE_PARTS = {
    "_Attack", "CommandAttack", "WhiffPunish", "PunishCounter", "AntiCharge",
    "AntiMelee", "AntiApproach", "AntiProjectile",
}
local PENDING_TIME, ROUND_TIME, COUNTER_TIME, RANGED_RECOVERY = .45, 4, 1, .65

function Rules.attackStrategy(name)
    return name == "AI.Strategy.Attack" or name:sub(1, #"AI.Strategy.Attack.") == "AI.Strategy.Attack."
        or ATTACK_STRATEGIES[name] == true
end

function Rules.attackTree(name)
    for _, part in ipairs(ATTACK_TREE_PARTS) do
        if name:find(part, 1, true) then return true end
    end
    return false
end

function Rules.new(floor)
    local late = floor >= 71
    return setmetatable({
        limit = late and 3 or 2, startsPerRound = late and 4 or 3, spacing = late and .30 or .45,
        used = 0, slots = {}, counts = { admitted = 0, started = 0, expired = 0, outside = 0, peak = 0, windows = 0 },
    }, Sequence)
end

function Sequence:observe(now, members, playerReady)
    local counts = self.counts
    local running, occupied, frontline = 0, 0, false
    for _, member in ipairs(members) do
        local id = member.id
        local slot = self.slots[id]
        if member.alive and not member.ranged then frontline = true end
        if member.attackTree then
            running = running + 1
            if not slot or slot.tree ~= member.attackTree then
                -- Native entries that bypass the selector still occupy capacity.
                slot = { tree = member.attackTree, ranged = member.ranged }
                self.slots[id] = slot
                counts.outside = counts.outside + 1
            end
            if not slot.running then
                slot.running = true
                self.used = self.used + 1
                self.roundStarted = self.roundStarted or now
                self.lastStart = now
                counts.started = counts.started + 1
            end
        elseif slot then
            local finishing = slot.running and member.tail
            local waiting = not slot.running and member.eligible and now < slot.expires
            if not finishing and not waiting then
                if not slot.running then counts.expired = counts.expired + 1
                elseif slot.ranged then self.rangedReadyAt = now + RANGED_RECOVERY end
                self.slots[id], slot = nil, nil
            end
        end
        if slot then occupied = occupied + 1 end
    end
    self.frontline = frontline
    counts.peak = math.max(counts.peak, running)

    if self.roundStarted and (self.used >= self.startsPerRound or now - self.roundStarted >= ROUND_TIME) then
        self.blocked = true
    end
    if occupied > 0 or not playerReady then
        self.quietSince = nil
    elseif self.roundStarted then
        self.quietSince = self.quietSince or now
        if now - self.quietSince >= COUNTER_TIME then
            if self.blocked then counts.windows = counts.windows + 1 end
            self.used, self.roundStarted, self.blocked, self.quietSince = 0, nil, nil, nil
        end
    end
end

function Sequence:canConsider(member)
    if not member.eligible or self.blocked then return false end
    local occupied = 0
    for _ in pairs(self.slots) do occupied = occupied + 1 end
    return occupied < self.limit
end

function Sequence:admit(member, tree, now)
    if not member.eligible or self.blocked then return false end
    local existing = self.slots[member.id]
    if existing then return not existing.running and existing.tree == tree and now < existing.expires end
    local occupied, pending, ranged = 0, 0, false
    for _, slot in pairs(self.slots) do
        occupied = occupied + 1
        if not slot.running then pending = pending + 1 end
        ranged = ranged or slot.ranged
    end
    if occupied >= self.limit or self.used + pending >= self.startsPerRound then return false end
    if self.frontline and member.ranged and (ranged or now < (self.rangedReadyAt or 0)) then return false end
    local last = math.max(self.lastStart or -math.huge, self.lastAdmission or -math.huge)
    if now - last < self.spacing then return false end
    self.slots[member.id] = { tree = tree, ranged = member.ranged, expires = now + PENDING_TIME }
    self.lastAdmission, self.quietSince = now, nil
    self.counts.admitted = self.counts.admitted + 1
    return true
end

return Rules
