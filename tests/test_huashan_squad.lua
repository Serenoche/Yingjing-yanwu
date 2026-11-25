-- Run with the staged 2.1.0 Scripts directory on package.path.
local world = { IsValid = function() return true end, GetAddress = function() return 1 end }
function FName(value) return value end
local serial = 1
local function object(identity)
    serial = serial + 1
    local address = serial
    return {
        GetAddress = function() return address end,
        GetFName = function() return identity end,
        GetWorld = function() return world end,
        IsValid = function(self) return not self.destroyed end,
        IsActorBeingDestroyed = function(self) return self.destroyed end,
        HasAnyFlags = function() return false end,
    }
end

local function enemy(class)
    local actor = object("pawn")
    actor.entranceProtected = true
    actor.AbilitySystemComponent = { GetGameplayTagCount = function(_, tag)
        if tag.TagName == "CharacterState.Unselectable.Force.Protection" then
            return actor.entranceProtected and 1 or 0
        end
        return 0
    end }
    local script = object("native script")
    script.Pawn = actor
    script.GetClass = function() return object("AIScript_PBZMisc_C") end
    script["Stop Invulnerable Before Combat"] = function(self)
        assert(self.Pawn == actor)
        actor.entranceProtected, actor.usedNativeScript = false, true
    end
    actor.ai = {
        SpawnedAIScripts = { script },
        OnActorEnterDomain = function(_, player)
            assert(player:GetFName() == "player")
            actor.domainNotifications = (actor.domainNotifications or 0) + 1
            if not actor.deferDomainRelease then actor.entranceProtected = false end
        end,
    }
    actor.GetClass = function() return class end
    actor.GetAISpawner = function(self) return self.source end
    actor.GetMobGroup = function(self) return self.MobGroup end
    actor.OnSpawnFromSpawner = function(self, source)
        assert(source.SpawnedAI == self)
        self.source = source
    end
    actor.HiddenNPC = function(self, hidden)
        self.bHidden, self.collision, self.ticking = hidden, not hidden, not hidden
    end
    actor.GetActorEnableCollision = function(self) return self.collision end
    actor.IsActorTickEnabled = function(self) return self.ticking end
    actor.K2_GetActorLocation = function(self) return self.transform.position end
    actor.IsAlive = function(self) return not self.dead end
    actor.K2_DestroyActor = function(self) self.destroyed = true end
    return actor
end

local sources, lease, attempts, resolved, unready, broken
local engagements = 0
package.loaded.MeiGuHuOriginalEvents = {
    squadSpawner = function(id) return sources[id] end,
    allowSquadSpawners = function(_, slots) assert(not lease); lease = slots end,
    releaseSquadSpawners = function(slots) assert(lease == slots); lease = nil end,
}
package.loaded.SceneArena = { runtimeWorld = function(actor) return actor.owningWorld or world end }
package.loaded.EncounterEngage = {
    start = function(actor, pawn, request, now)
        assert(pawn:GetFName() == "player" and actor.collision and actor.ticking and not actor.entranceProtected)
        engagements = engagements + 1
        if actor.waitForTarget and now < actor.waitForTarget then return false, "native target pending" end
        actor.hasTarget, request.confirmed = true, true
        return true
    end,
}
package.loaded.CombatSpawn = {
    finish = function(_, _, actor, _, cycle, challenge)
        assert(challenge and actor.source and actor.source:GetPawn() == actor)
        actor.finished, actor.running, actor.level = true, false, 30 + cycle
        return actor, actor.level
    end,
    clearStoryFlow = function(actor) actor.flowCleared = true end,
    challengeAI = function(actor, running) actor.running = running end,
    ai = function(actor) return actor.ai end,
}
package.loaded.StockBellArena = {
    floorAt = function(_, _, point)
        if not unready then return point.Z - 2 end
    end,
}
package.loaded.SpawnClass = { resolve = function(path)
    resolved[path] = (resolved[path] or 0) + 1
    return object(assert(path:match("%.([^.]+)$")))
end }

function StaticFindObject(path)
    local library = object(path)
    if path == "/Script/SGameCombatSystem.Default__FactionUtils" then
        library.GetFactionRelation = function(_, first, second)
            local actor = first:GetFName() == "player" and second or first
            return actor.entranceProtected and 0 or 2
        end
    end
    library.MakeTransform = function(_, position, rotation) return { position = position, rotation = rotation } end
    library.SpawnActorDeferred = function(_, _, class, transform)
        local actor = enemy(class)
        actor.transform = transform
        attempts[#attempts + 1] = actor
        return actor
    end
    return library
end

local Squad = require("HuaShanSquad")
local master = "BP_Monster_HuaShan_Blue"
local ajin = "BP_Monster_HuaShan_RedTroop_BigBro"
local brother, swordswoman = "BP_Monster_HuaShan_JianOu", "BP_Monster_EMei_Sword_JianZhen"
local tower, shore = { id = "zhengdaodaying_sangaota" }, { id = "meiguhu_ajin" }
tower.combatHeight, shore.combatHeight = { min = 6650, max = 7290 }, { min = 520, max = 2050 }
local pair = { id = "gauntlet_sangaota" }
local player = object("player")
player.K2_GetActorLocation = function(self) return self.position end
local function member(id) return { id = id, classPath = id .. "." .. id .. "_C" } end
local function stage(...)
    local result = { members = {} }
    for _, id in ipairs({ ... }) do result.members[#result.members + 1] = member(id) end
    return result
end

local function setup(formation, height)
    sources, attempts, resolved, broken, unready = {}, {}, {}, false, false
    local domain, group = object(formation.domain), object(formation.group)
    local streamedPackage = object("package world")
    domain.GetWorld = function() return streamedPackage end
    group.GetOuter = function() return domain end
    group.GetAliveMemberPawns = function()
        local alive = {}
        for _, source in pairs(sources) do
            local actor = source:GetPawn()
            if actor and actor:IsValid() and actor:IsAlive() then alive[#alive + 1] = actor end
        end
        return alive
    end
    local function source(suffix)
        local key = "BP_AISpawner_C_UAID_" .. suffix
        local spawner = object(key)
        -- UE4SS follows Outer for GetWorld, while this actor belongs to the
        -- actual OwningWorld exposed by the scene helper.
        spawner.GetWorld = function() return streamedPackage end
        spawner.ShouldSpawn = false
        spawner.K2_GetActorLocation = function() return { X = spawner:GetAddress() * 150, Y = 100, Z = height } end
        spawner.K2_GetActorRotation = function() return { Yaw = 70 } end
        spawner.GetMobGroup = function() return group end
        spawner.GetPawn = function(self) return self.SpawnedAI end
        spawner.K2_OnAISpawnReady = function(self, actor)
            assert(self.SpawnedAI == actor and actor.finished and not actor.announced)
            actor.announced = true
            actor:HiddenNPC(true)
            if broken and #attempts == 3 then error("spawn notification failed") end
        end
        spawner.Despawn = function(self)
            assert(self.ShouldSpawn == false)
            if self.SpawnedAI then self.SpawnedAI:K2_DestroyActor() end
            self.SpawnedAI, self.didDespawn = nil, true
        end
        sources[key] = spawner
        return spawner
    end
    local support = {}
    for _, suffix in ipairs(formation.spawners) do
        support[#support + 1] = source(formation.prefix .. suffix)
    end
    local bosses = {}
    for id, suffix in pairs(formation.bosses) do bosses[id] = source(suffix) end
    return support, bosses
end

local function spawn(scene, formation, phase)
    return Squad.spawn(scene, formation, phase, { GetRealTimeSeconds = function() return 5 end }, {}, player, 4)
end

assert(not Squad.select({ id = "night" }, { id = master }, stage(master)))
assert(not Squad.select(tower, { id = "gauntlet_huashan" }, stage(master)))
assert(not Squad.select(tower, pair, stage(brother, "BP_Monster_EMei_Sword_Top")))
assert(not Squad.select(tower, { id = master }, stage(master, ajin)))
assert(Squad.select(tower, pair, stage(master)))

for _, fight in ipairs({ { tower, master, 6838, "BP_Monster_HuaShan_White" },
    { shore, ajin, 738, "BP_Monster_HuaShan_RedTroop_Soldier" } }) do
    local scene, id, height, aid = table.unpack(fight)
    local phase = stage(id)
    local formation = assert(Squad.select(scene, { id = id }, phase))
    local support, bosses = setup(formation, height)
    local session, reason, actors, levels = spawn(scene, formation, phase)
    assert(session and not reason and #attempts == 7 and #actors == 1 and levels[1] == 34)
    assert(resolved["/PBZCombatAsset/ActorData/Mobs/035_HuaShan/" .. aid .. "." .. aid .. "_C"] == 1)
    assert(actors[1] == bosses[id]:GetPawn())
    for _, source in ipairs(support) do
        local actor = source:GetPawn()
        assert(actor.source == source and actor.announced and actor.flowCleared and not actor.bHidden and not actor.running)
        assert(actor.collision and actor.ticking)
        assert(actor.level == 34 and actor.transform.rotation.Yaw == 70)
        assert(session:owns(actor) and not session:owns(source))
    end
    local counts = engagements
    player.position = { X = -10000, Y = 0, Z = height }
    assert(not session:nearPlayer(player, 1650))
    player.position = support[1]:GetPawn():K2_GetActorLocation()
    assert(session:nearPlayer(player, 1))
    session:engage(player, false, 4)
    assert(engagements == counts)
    session:engage(player, true, 4)
    assert(engagements == counts and actors[1].entranceProtected)
    support[1]:GetPawn().deferDomainRelease = true
    session:admitPlayer(player, 4.25)
    session:admitPlayer(player, 4.3)
    assert(support[1]:GetPawn().usedNativeScript)
    for _, actor in ipairs(attempts) do
        assert(session:admitted(actor) and actor.domainNotifications == 1 and not actor.running)
    end
    session:update(true)
    for _, source in ipairs(support) do assert(source:GetPawn().running) end
    actors[1].waitForTarget = 5
    session:engage(player, true, 4.5)
    session:engage(player, true, 4.6)
    assert(engagements == counts + 7 and not actors[1].hasTarget)
    session:engage(player, true, 5)
    assert(engagements == counts + 14 and actors[1].hasTarget)
    session:engage(player, true, 5.5)
    assert(engagements == counts + 14)
    session:update(false)
    for _, source in ipairs(support) do assert(not source:GetPawn().running) end
    session:finish()
    for _, source in ipairs(support) do assert(source.didDespawn and not source:GetPawn()) end
    assert(actors[1]:IsValid())
    session:close()
    assert(not actors[1]:IsValid() and not lease)
    assert(spawn(scene, formation, phase)):close()
    assert(#attempts == 14 and not lease)
end

local phase = stage(brother, swordswoman)
local formation = assert(Squad.select(tower, pair, phase))
local support, bosses = setup(formation, 6838)
local session, _, actors = spawn(tower, formation, phase)
assert(session and #attempts == 2 and #actors == 2)
assert(actors[1] == bosses[brother]:GetPawn() and actors[2] == bosses[swordswoman]:GetPawn())
for _, source in ipairs(support) do assert(not source:GetPawn() and not source.ShouldSpawn) end
local counts = engagements
session:admitPlayer(player, 5)
assert(session:admitted(actors[1]) and session:admitted(actors[2]))
session:engage(player, true, 5)
assert(engagements == counts)
local summoned = enemy(object(formation.support .. "_C"))
support[1].ShouldSpawn, support[1].SpawnedAI = true, summoned
summoned:OnSpawnFromSpawner(support[1])
session:update(true)
assert(summoned.running and summoned.flowCleared and session:owns(summoned))
session:close()
assert(not summoned:IsValid() and not lease)
for _, source in ipairs(support) do assert(source.didDespawn and not source.ShouldSpawn) end

phase = stage(master)
formation = assert(Squad.select(tower, { id = master }, phase))
support, bosses = setup(formation, 6838)
unready = true
assert(not spawn(tower, formation, phase) and #attempts == 0 and not lease)
unready, broken = false, true
assert(not pcall(spawn, tower, formation, phase))
assert(#attempts == 3 and not lease)
for _, source in ipairs(support) do assert(not source:GetPawn()) end
for _, actor in ipairs(attempts) do assert(not actor:IsValid()) end

support = setup(formation, 6838)
support[6].GetMobGroup = function() return nil end
assert(not spawn(tower, formation, phase) and #attempts == 0 and not lease)
support[6].GetMobGroup = function() return object("wrong group") end
support[6].owningWorld = object("other world")
assert(not spawn(tower, formation, phase) and #attempts == 0 and not lease)

print("HuaShan native squad lifecycle passed")

local privateSpawners, privateGroups = {}, {}
local reflected = StaticFindObject
function StaticFindObject(path)
    local library = reflected(path)
    if path:find("Default__KismetSystemLibrary", 1, true) then
        library.Conv_ClassToSoftClassReference = function(_, class) return class end
        library.Conv_ObjectToSoftObjectReference = function(_, value) return value end
    elseif path:find("Default__SGameAIFunctionLibrary", 1, true) then
        local begin = library.SpawnActorDeferred
        function library:SpawnActorDeferred(pawn, class, transform, collision)
            if class:GetFName() ~= "BP_AISpawner_C" then return begin(self, pawn, class, transform, collision) end
            local spawner = object("private spawner")
            privateSpawners[#privateSpawners+1] = spawner
            spawner.SetOwner = function(self, owner) self.owner = owner end
            spawner.GetMobGroup = function(self) return self.MobGroup end
            spawner.GetPawn = function(self) return self.SpawnedAI end
            spawner.SetActorEnableCollision = function() end
            spawner.SetActorHiddenInGame = function() end
            spawner.K2_DestroyActor = function(self) self.destroyed = true end
            spawner.K2_OnAISpawnReady = function(self, value)
                assert(self.SpawnedAI == value and value.finished and self.MobGroup)
                value.announced = true
            end
            spawner.Despawn = function(self)
                assert(not self.ShouldSpawn)
                if self.SpawnedAI then self.SpawnedAI:K2_DestroyActor() end
                self.SpawnedAI = nil
            end
            return spawner
        end
    end
    return library
end

function StaticConstructObject(class, outer)
    assert(class:GetFName() == "/Script/SGameAI.MobGroup" and outer:IsValid())
    local group = object("private MobGroup")
    privateGroups[#privateGroups+1] = group
    function group:GetAliveMemberPawns()
        local result = {}
        for _, source in ipairs(self.Members) do
            local value = source:GetPawn()
            if value and value:IsValid() and value:IsAlive() then result[#result+1] = value end
        end
        return result
    end
    return group
end

local generic = { id = "night", portableBossMechanics = true, spawnPoints = {
    { X = -2700, Y = 0, Z = 100 }, { X = 0, Y = 0, Z = 100 }, { X = 2700, Y = 0, Z = 100 },
} }
require("ArenaTerrain").place = function(_, _, _, pattern, at)
    local points = {}
    for _, offset in ipairs(pattern) do points[#points+1] = { X = at.X+offset[1], Y = at.Y+offset[2], Z = at.Z } end
    return points, { Yaw = 0 }
end
local gameplay = { FinishSpawningActor = function(_, value) return value end }
local function makeLeader(crew, index, id)
    local value = enemy(object(id .. "_C"))
    value.transform = { position = { X = 0, Y = 0, Z = 180 } }
    crew:bindBoss(value, index)
    value.finished = true
    crew:finishBoss(value, index)
    return value
end

local portable = assert(Squad.portable(generic, { id = "custom" }, stage(master, ajin, master), gameplay, {}, player, 4))
assert(#privateSpawners == 21 and #privateGroups == 3 and #portable:activeSupports() == 18)
local leaders = { makeLeader(portable, 1, master), makeLeader(portable, 2, ajin), makeLeader(portable, 3, master) }
for index, leader in ipairs(leaders) do
    local group = leader:GetAISpawner():GetMobGroup()
    assert(group == privateGroups[index] and #group:GetAliveMemberPawns() == 7 and portable:owns(leader))
end
portable:finish()
for _, leader in ipairs(leaders) do assert(leader:IsValid()) end
portable:close()
for _, spawner in ipairs(privateSpawners) do assert(not spawner:IsValid()) end
for _, leader in ipairs(leaders) do assert(not leader:IsValid()) end

privateSpawners, privateGroups = {}, {}
portable = assert(Squad.portable(generic, pair, stage(brother, swordswoman), gameplay, {}, player, 4))
assert(#privateSpawners == 5 and #privateGroups == 1 and #portable:activeSupports() == 0)
assert(makeLeader(portable, 1, brother):GetAISpawner():GetMobGroup() == privateGroups[1])
assert(makeLeader(portable, 2, swordswoman):GetAISpawner():GetMobGroup() == privateGroups[1])
assert(privateSpawners[3].Class:GetFName() == "BP_Monster_HuaShan_CaoOu_C" and not privateSpawners[3].ShouldSpawn)
portable:close()
for _, spawner in ipairs(privateSpawners) do assert(not spawner:IsValid()) end
print("HuaShan portable squads, duplicate leaders and dormant summoning slots passed")
