local Formation = {}

-- The ice qin variants are catalogued by their status effect.
local ranged = { M066 = true, E018 = true }
for _, mob in ipairs(require("TrainingMobCatalog")) do
    if mob.role == "远程" or mob.role == "投掷" then ranged[mob.id] = true end
end

-- Xigu starts the player facing slot 1. Slots 2 and 3 flank that far point.
local FRONT_SLOTS = { 4, 5, 6, 2, 1, 3 }
local REAR_LAYOUTS = {
    { { 1 }, { 3 }, { 2 } },
    { { 3, 2 }, { 3, 1 }, { 1, 2 } },
    { { 3, 1, 2 } },
}
local REAR_WITH_FOUR_FRONT = { { 3 }, { 1 }, { 2 } }

local function assign(candidates, rearSlots, rear, front)
    local slots, reserved = {}, {}
    local rearDepth, rearDistanceSquared = math.huge, math.huge
    for index, slot in ipairs(rearSlots) do
        local point = candidates[slot]
        if not point or point.depth <= 0 then return end
        slots[rear[index]], reserved[slot] = slot, true
        rearDepth = math.min(rearDepth, point.depth)
        rearDistanceSquared = math.min(rearDistanceSquared, point.distanceSquared)
    end

    local nextFront = 1
    for _, slot in ipairs(FRONT_SLOTS) do
        if nextFront > #front then break end
        local point = candidates[slot]
        if point and not reserved[slot] and point.depth < rearDepth and point.distanceSquared < rearDistanceSquared then
            slots[front[nextFront]] = slot
            nextFront = nextFront + 1
        end
    end
    if nextFront > #front then return slots end
end

local function assignMarkedPoints(candidates, rear, front)
    local ordered = {}
    for slot in pairs(candidates) do ordered[#ordered + 1] = slot end
    if #ordered < #rear + #front then return end

    -- The marked points can swap distance order across player landings.
    -- Keep the rows ordered along the opening direction.
    table.sort(ordered, function(a, b)
        local aDepth, bDepth = candidates[a].depth, candidates[b].depth
        if aDepth == bDepth then return a < b end
        return aDepth > bDepth
    end)
    if candidates[ordered[#rear]].depth <= 0 then return end

    local slots = {}
    for index, member in ipairs(rear) do slots[member] = ordered[index] end
    for index, member in ipairs(front) do slots[member] = ordered[#ordered - index + 1] end
    return slots
end

function Formation.prepare(challenge, stage, pawn)
    if not challenge.palace or challenge.sceneId ~= "xigu" or not stage.regularMobs then return end

    local rear, front = {}, {}
    for index, member in ipairs(stage.members) do
        local group = ranged[member.id] and rear or front
        group[#group + 1] = index
    end
    if #rear == 0 then return end

    local placement = challenge.scene.palacePlacement
    local layouts
    if not placement then
        layouts = #front >= 4 and #rear == 1 and REAR_WITH_FOUR_FRONT or REAR_LAYOUTS[#rear]
        if not layouts then return nil, "浊梦远程杂兵超过后排点位数量" end
    end

    local retry = challenge.palaceFormationRetry
    local rejected = retry and retry.stage == stage and retry.slots or {}
    local location = pawn:K2_GetActorLocation()
    local playerX, playerY = location.X, location.Y
    local points = placement and placement.mobs or challenge.scene.spawnPoints
    local facing = placement and placement.bosses[1] or points[1]
    local forwardX, forwardY = facing.X - playerX, facing.Y - playerY
    local candidates = {}
    for slot, point in ipairs(points) do
        if not rejected[slot] then
            local x, y = point.X - playerX, point.Y - playerY
            candidates[slot] = { depth = x * forwardX + y * forwardY, distanceSquared = x * x + y * y }
        end
    end

    if placement then
        local slots = assignMarkedPoints(candidates, rear, front)
        if slots then return slots end
    else
        for _, rearSlots in ipairs(layouts) do
            local slots = assign(candidates, rearSlots, rear, front)
            if slots then return slots end
        end
    end

    -- Let the next spawn retry recheck all points if the arena was temporarily blocked.
    challenge.palaceFormationRetry = nil
    return nil, "浊梦杂兵没有可用的前后排点位"
end

function Formation.reject(challenge, stage, slot)
    local retry = challenge.palaceFormationRetry
    if not retry or retry.stage ~= stage then
        retry = { stage = stage, slots = {} }
        challenge.palaceFormationRetry = retry
    end
    retry.slots[slot] = true
end

return Formation
