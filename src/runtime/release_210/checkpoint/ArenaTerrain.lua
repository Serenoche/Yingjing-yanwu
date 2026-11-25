local Terrain = {}

local NAV = "/Script/NavigationSystem.Default__NavigationSystemV1"
local CLEAR = { R = 0, G = 0, B = 0, A = 0 }
local WORLD_STATIC = { 0 }

-- World-space samples from the stock Zuoshang and YuCong combat domains
-- and the Lake fog spline. The standalone Lake uses the same coordinates.
local stockBoundaries = {
    night = {
        {-195794,-120800}, {-194884,-121220}, {-193623,-121399}, {-192233,-121352},
        {-190938,-121093}, {-189961,-120638}, {-189423,-119910}, {-189114,-118737},
        {-189024,-117334}, {-189160,-115942}, {-189532,-114804}, {-190176,-114138},
        {-191346,-113793}, {-192879,-113680}, {-194487,-113787}, {-195883,-114104},
        {-196780,-114618}, {-197153,-115507}, {-197208,-116793}, {-196998,-118231},
        {-196580,-119576}, {-196009,-120582},
    },
    lake = {
        {-67016,83681}, {-68728,83670}, {-70175,83293}, {-71308,82527},
        {-72134,81605}, {-72731,80471}, {-73029,79072}, {-72909,77289},
        {-72380,75787}, {-71425,74561}, {-70030,73602}, {-68148,73210},
        {-66265,73472}, {-64718,74410}, {-63648,75656}, {-62958,76995},
        {-62635,78343}, {-62763,79834}, {-63331,81272}, {-64207,82643}, {-66278,83609},
    },
    xigu = {
        {4628,284194}, {5356,285026}, {5914,286252}, {6313,287168}, {6532,287946},
        {6397,288488}, {5879,288754}, {5207,289047}, {4379,289533}, {3555,289969},
        {2987,290184}, {2528,290225}, {1934,290044}, {1232,289650}, {717,288930},
        {361,287741}, {385,286600}, {1064,285840}, {2079,285257}, {3073,284669}, {4114,284179},
    },
    -- This original fog spline is also used by the standalone Songhouse map.
    meiguhu = {
        {-126496,72697}, {-126265,71965}, {-125896,71473}, {-125536,71172},
        {-124947,71075}, {-124104,71416}, {-123703,71746}, {-123338,72331},
        {-123381,73115}, {-123473,73418}, {-123612,73610}, {-124320,74222},
        {-125094,74211}, {-125661,73889}, {-126375,73244}, {-126464,73040},
    },
}

local function valid(object)
    return object and type(object.IsValid) == "function" and object:IsValid()
end

local function distanceSquared(first, second)
    return (first.X-second.X)^2 + (first.Y-second.Y)^2 + (first.Z-second.Z)^2
end

function Terrain.protect(scene, portableBossMechanics)
    local outline = stockBoundaries[scene.id]
    if not scene.combatBoundary and outline then
        scene.combatBoundary = {}
        for index, point in ipairs(outline) do
            scene.combatBoundary[index] = { X = point[1], Y = point[2] }
        end
    end
    assert(scene.combatBoundary and #scene.combatBoundary >= 3, "通用场地缺少战斗边界：" .. scene.id)
    scene.combatHeight = scene.combatHeight or { min = scene.spawnTrace.bottom, max = scene.spawnTrace.top }
    scene.bossRecovery, scene.guardTerrainDefeat, scene.edgeProtection = true, true, true
    scene.portableBossMechanics = portableBossMechanics == true
end

function Terrain.contains(at, polygon)
    local previous, inside = polygon[#polygon], false
    for _, point in ipairs(polygon) do
        if (point.Y > at.Y) ~= (previous.Y > at.Y)
            and at.X < point.X + (previous.X-point.X) * (at.Y-point.Y) / (previous.Y-point.Y) then
            inside = not inside
        end
        previous = point
    end
    return inside
end

function Terrain.distanceToBoundarySquared(at, scene)
    local polygon = scene.combatBoundary
    if Terrain.contains(at, polygon) then return 0 end
    local nearest = math.huge
    local previous = polygon[#polygon]
    for _, point in ipairs(polygon) do
        local x, y = point.X-previous.X, point.Y-previous.Y
        local dx, dy = at.X-previous.X, at.Y-previous.Y
        local lengthSquared = x*x+y*y
        local t = lengthSquared > 0 and math.max(0, math.min(1, (dx*x+dy*y)/lengthSquared)) or 0
        nearest = math.min(nearest, (dx-t*x)^2+(dy-t*y)^2)
        previous = point
    end
    return nearest
end

function Terrain.floorAt(pawn, system, point, top, bottom, ignore)
    local from, to = { X = point.X, Y = point.Y, Z = top }, { X = point.X, Y = point.Y, Z = bottom }
    local hit = {}
    if not system:LineTraceSingle(pawn, from, to, 0, false, ignore or {}, 0, hit, true, CLEAR, CLEAR, 0) then
        hit = {}
        if not system:LineTraceSingleForObjects(pawn, from, to, WORLD_STATIC, false, ignore or {},
            0, hit, true, CLEAR, CLEAR, 0) then return end
    end
    if hit.ImpactPoint and hit.ImpactNormal and hit.ImpactNormal.Z >= .65 then return hit.ImpactPoint.Z end
end

function Terrain.project(navigation, pawn, point)
    local result = {}
    if navigation:K2_ProjectPointToNavigation(pawn, point, result, nil, nil, { X = 120, Y = 120, Z = 130 })
        and result.X and distanceSquared(result, point) <= 145^2 then
        return { X = result.X, Y = result.Y, Z = result.Z }
    end
end

function Terrain.hasPath(navigation, pawn, start, destination, boundary)
    local path = navigation:FindPathToLocationSynchronously(pawn, start, destination, pawn, nil)
    if not valid(path) or path:IsPartial() then return false end
    local points = path.PathPoints
    if #points < 2 or distanceSquared(points[#points], destination) > 145^2 then return false end
    if boundary then
        for index = 1, #points do
            if not Terrain.contains(points[index], boundary) then return false end
        end
    end
    return true
end

function Terrain.ground(pawn, system, scene, point, ignored)
    if not Terrain.contains(point, scene.combatBoundary) then return end
    local top = point.Z and point.Z + 150 or scene.spawnTrace.top
    local bottom = point.Z and point.Z - 195 or scene.spawnTrace.bottom
    local z = Terrain.floorAt(pawn, system, point, top, bottom, ignored)
    if z and (not point.Z or math.abs(z-point.Z) <= 110)
        and z >= scene.combatHeight.min and z <= scene.combatHeight.max then
        return { X = point.X, Y = point.Y, Z = z }
    end
end

local function safeOrigin(navigation, pawn, system, scene, ignored)
    local point = scene.phaseReturnPoints and scene.phaseReturnPoints[1]
    local projected = point and Terrain.project(navigation, pawn, point)
    if projected and Terrain.contains(projected, scene.combatBoundary) then return projected end
    if scene.edgeProtection then
        for _, spawn in ipairs(scene.spawnPoints) do
            local ground = Terrain.ground(pawn, system, scene, spawn, ignored)
            projected = ground and Terrain.project(navigation, pawn, ground)
            if projected and Terrain.contains(projected, scene.combatBoundary) then return projected end
        end
    end
end

function Terrain.recoveryGround(pawn, system, scene, point, ignored)
    local floor = Terrain.ground(pawn, system, scene, point, ignored)
    if not floor then return end
    local navigation = StaticFindObject(NAV)
    if not valid(navigation) then return end
    local at = Terrain.project(navigation, pawn, floor)
    if not at or not Terrain.contains(at, scene.combatBoundary) then return end
    local start = safeOrigin(navigation, pawn, system, scene, ignored)
    if start and (distanceSquared(start, at) < 50^2
        or Terrain.hasPath(navigation, pawn, start, at, scene.combatBoundary)) then return floor end
end

-- A pattern is expressed relative to its centre in the horizontal plane.
-- Keep the entire pattern on reachable ground before spawning any objects.
local function separated(point, occupied)
    for _, other in ipairs(occupied or {}) do
        if (point.X-other.X)^2 + (point.Y-other.Y)^2 < 350^2 and math.abs(point.Z-other.Z) < 300 then
            return false
        end
    end
    return true
end

function Terrain.place(pawn, system, scene, pattern, preferred, overheadClearance, occupied)
    local candidates = {}
    if preferred then candidates[#candidates + 1] = preferred end
    if scene.chiLianUltimate then candidates[#candidates + 1] = scene.chiLianUltimate.center end
    local midpoint = { X = 0, Y = 0 }
    for _, point in ipairs(scene.combatBoundary) do
        midpoint.X, midpoint.Y = midpoint.X + point.X, midpoint.Y + point.Y
    end
    midpoint.X, midpoint.Y = midpoint.X / #scene.combatBoundary, midpoint.Y / #scene.combatBoundary
    candidates[#candidates+1] = midpoint
    for _, point in ipairs(scene.spawnPoints) do candidates[#candidates+1] = point end

    for _, candidate in ipairs(candidates) do
        local center = Terrain.recoveryGround(pawn, system, scene, candidate)
        if center then
            for _, scale in ipairs({ 1, .75, .55 }) do
                for _, turn in ipairs({ 0, 90, 45, 135 }) do
                    local yaw = (scene.rotation.Yaw+turn)%360
                    local angle = math.rad(yaw)
                    local cosine, sine = math.cos(angle), math.sin(angle)
                    local points = {}
                    for _, offset in ipairs(pattern) do
                        local x = center.X + scale*(offset[1]*cosine-offset[2]*sine)
                        local y = center.Y + scale*(offset[1]*sine+offset[2]*cosine)
                        local point = Terrain.recoveryGround(pawn, system, scene, { X = x, Y = y, Z = center.Z })
                        if not point or not separated(point, occupied) then break end
                        if overheadClearance and system:LineTraceSingleForObjects(pawn,
                            { X = x, Y = y, Z = point.Z+20 }, { X = x, Y = y, Z = point.Z+overheadClearance },
                            WORLD_STATIC, false, {}, 0, {}, true, CLEAR, CLEAR, 0) then break end
                        points[#points+1] = point
                    end
                    if #points == #pattern then
                        return points, { Pitch = 0, Yaw = yaw, Roll = 0 }, center
                    end
                end
            end
        end
    end
end

return Terrain
