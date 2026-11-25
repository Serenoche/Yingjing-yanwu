local Arena = require("XiguBossArena")
local SceneArena = require("SceneArena")
local Markers = {}

local PENDING = 0x08023600
local CLEAR = { R = 0, G = 0, B = 0, A = 0 }

local function valid(object)
    return object and type(object.IsValid) == "function" and object:IsValid()
end

local function live(actor, world)
    return valid(actor) and not actor:HasAnyFlags(PENDING) and not actor:IsActorBeingDestroyed()
        and SceneArena.actorIsInWorld(actor, world)
end

local function byName(gameplay, pawn, world, class, count)
    local actors = SceneArena.actorsOfClass(gameplay, pawn, world, class)
    if #actors ~= count then return end
    local names = {}
    for _, actor in ipairs(actors) do
        if not live(actor, world) then return end
        local label = actor:GetFName()
        local name = type(label) == "string" and label or label:ToString()
        if names[name] then return end
        names[name] = actor
    end
    return names
end

local function markerPosition(actor, expected)
    if not actor or not valid(actor.Arrow) then return end
    local arrow = actor.Arrow:K2_GetComponentLocation()
    local position = { X = arrow.X, Y = arrow.Y, Z = arrow.Z }
    if (position.X-expected.X)^2 + (position.Y-expected.Y)^2 + (position.Z-expected.Z)^2 <= 150^2 then
        return position
    end
end

function Markers.bind(pawn, gameplay, system, world, scene, centerClass, spawnerClass)
    local spec = scene.nativeSnake
    local centers = byName(gameplay, pawn, world, centerClass, 1)
    local actors = byName(gameplay, pawn, world, spawnerClass, #spec.spawners)
    local center = centers and centers[spec.center]
    local home = markerPosition(center, scene.chiLianUltimate.center)
    if not home or not actors then return nil, "等待巨树战场的原版召蛇定位对象" end
    local resolved = gameplay:GetActorOfClass(pawn, centerClass)
    if not live(resolved, world) or resolved:GetAddress() ~= center:GetAddress() then
        return nil, "巨树战场的原版召蛇中心尚未就绪"
    end
    local floor = Arena.mechanicFloor(pawn, system, scene.chiLianUltimate.center)
    if not floor then return nil, "等待巨树战场的原版召蛇地面" end
    local spawners = {}
    for _, item in ipairs(spec.spawners) do
        local actor = actors[item.name]
        local position = markerPosition(actor, item.ground)
        local ground = position and Arena.mechanicFloor(pawn, system, item.ground)
        if not ground or not Arena.mechanicRoute(pawn, scene, floor, ground) then
            return nil, "等待巨树战场的原版召蛇通路"
        end
        local base = { X = position.X, Y = position.Y, Z = ground.Z+20 }
        local above = { X = position.X, Y = position.Y, Z = ground.Z+450 }
        if system:LineTraceSingleForObjects(pawn, base, above, { 0 }, false, {}, 0, {}, true, CLEAR, CLEAR, 0) then
            return nil, "巨树战场的原版召蛇点上方有阻挡"
        end
        if live(actor.SnakeActor, world) then return nil, "等待巨树战场的上轮召蛇清理" end
        spawners[#spawners + 1] = actor
    end
    print("[PBZChiLianArena] " .. scene.id .. " reused original center and 4 snake markers\n")
    return { center = center, position = home, spawners = spawners }
end

return Markers
