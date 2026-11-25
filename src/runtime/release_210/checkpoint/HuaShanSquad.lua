local CombatSpawn = require("CombatSpawn")
local Engage = require("EncounterEngage")
local SceneArena = require("SceneArena")
local SpawnClass = require("SpawnClass")
local Terrain = require("ArenaTerrain")

local Squad = {}
local Session = {}
Session.__index = Session

local MASTER = "BP_Monster_HuaShan_Blue"
local BROTHER = "BP_Monster_HuaShan_JianOu"
local SWORDSWOMAN = "BP_Monster_EMei_Sword_JianZhen"
local AJIN = "BP_Monster_HuaShan_RedTroop_BigBro"
local WHITE = "BP_Monster_HuaShan_White"
local RED = "BP_Monster_HuaShan_RedTroop_Soldier"
local PUPPET = "BP_Monster_HuaShan_CaoOu"
local SANGAOTA = "zhengdaodaying_sangaota"
local PAIR = "gauntlet_sangaota"
local TOWER = "0A6230820DE85F4502_"
local SHORE = "E89C25A750"
local TOWER_DOMAIN = "BP_MobDomain_C_UAID_" .. TOWER .. "1979995676"
local SPAWNER = "BP_AISpawner_C_UAID_"
local FACTION_UTILS = "/Script/SGameCombatSystem.Default__FactionUtils"
local ENTRY_PROTECTION = "CharacterState.Unselectable.Force.Protection"
local HOSTILE = 2
local SPAWNER_CLASS = "/SGameAI/Tools/Spawner/BP_AISpawner.BP_AISpawner_C"
local MOB_GROUP = "/Script/SGameAI.MobGroup"
local SYSTEM = "/Script/Engine.Default__KismetSystemLibrary"
local ACTORS = "/Script/SGameAI.Default__SGameAIFunctionLibrary"
local MATH = "/Script/Engine.Default__KismetMathLibrary"
local SCALE = { X = 1, Y = 1, Z = 1 }
local PENDING = 0x08023600

local formations = {
    [MASTER] = {
        scene = SANGAOTA, domain = TOWER_DOMAIN, group = "MobGroup_0",
        bosses = { [MASTER] = TOWER .. "1979997677" },
        support = WHITE, spawners = { "1980002683", "1979999680", "1980002684",
            "1980000681", "1979998679", "1980001682" }, prefix = TOWER,
    },
    [PAIR] = {
        scene = SANGAOTA, domain = TOWER_DOMAIN, group = "MobGroup_1",
        bosses = { [BROTHER] = TOWER .. "1979998678", [SWORDSWOMAN] = "E89C25A7516AEC7302_1405639150" },
        support = PUPPET, spawners = { "1980005686", "1980006688", "1980006687" }, prefix = TOWER,
        dormant = true,
    },
    [AJIN] = {
        scene = "meiguhu_ajin", domain = "PBZ_MobDomain_C_UAID_E89C25A750C736E302_1126457833",
        group = "MobGroup_0", bosses = { [AJIN] = SHORE .. "C7A0CB02_2042446446" },
        support = RED, spawners = { "C729E302_2019269458", "C72AE302_1256505636", "C72CE302_1744151987",
            "C72DE302_1517928169", "C72DE302_1591131170", "C7F6E102_2002111428" }, prefix = SHORE,
    },
}

local function valid(value)
    return value and type(value.IsValid) == "function" and value:IsValid()
end

local function unwrap(value)
    if valid(value) then return value end
    if value and type(value.get) == "function" then
        local object = value:get()
        if valid(object) then return object end
    end
end

local function address(value)
    value = unwrap(value)
    return value and value:GetAddress()
end

local function live(actor, world)
    return valid(actor) and not actor:HasAnyFlags(PENDING) and not actor:IsActorBeingDestroyed()
        and address(SceneArena.runtimeWorld(actor)) == world
end

local function name(object)
    local value = object:GetFName()
    return type(value) == "string" and value or value:ToString()
end

local function supportPath(id)
    return "/PBZCombatAsset/ActorData/Mobs/035_HuaShan/" .. id .. "." .. id .. "_C"
end

local function log(message)
    print("[PBZHuaShanSquad] " .. message .. "\n")
end

function Squad.select(scene, entry, stage)
    local members = stage.members
    local first = members[1] and members[1].id
    local formation
    if #members == 1 and (entry.id == first or entry.id == PAIR and first == MASTER) then
        formation = formations[first]
    elseif #members == 2 and entry.id == PAIR and first == BROTHER and members[2].id == SWORDSWOMAN then
        formation = formations[PAIR]
    end
    if formation and scene.id == formation.scene then return formation end
end

local function currentPawn(slot, world)
    if not live(slot.spawner, world) then return end
    local actor = unwrap(slot.spawner:GetPawn())
    if live(actor, world) and name(actor:GetClass()) == slot.id .. "_C"
        and address(actor:GetAISpawner()) == slot.spawner:GetAddress() then return actor end
end

function Session:owns(actor)
    return self.owned[actor:GetAddress()] == true
end

local function remove(slot, world)
    local spawner = slot.spawner
    local actor = slot.dormant and currentPawn(slot, world) or slot.actor
    if live(spawner, world) then
        local existing = unwrap(spawner:GetPawn())
        assert(not live(existing, world) or address(existing) == address(actor), "原版出生点已被其他单位占用")
        spawner.ShouldSpawn = false
        spawner:Despawn()
        if valid(actor) and address(spawner.SpawnedAI) == address(actor) then spawner.SpawnedAI = nil end
    end
    if live(actor, world) then
        CombatSpawn.clearStoryFlow(actor)
        actor:K2_DestroyActor()
    end
end

function Session:release(keepBosses)
    for _, slot in ipairs(self.slots) do
        if not slot.released and (not keepBosses or not slot.boss) then
            local ok, reason = pcall(remove, slot, self.world)
            if ok then slot.released = true
            else log("cleanup " .. slot.id .. " " .. tostring(reason)) end
        end
    end
end

function Session:finish()
    self.finished = true
    self:release(true)
end

function Session:close()
    self:release(false)
    if self.events then self.events.releaseSquadSpawners(self.slots) end
    for _, slot in ipairs(self.privateSlots or {}) do
        if slot.released and live(slot.spawner, self.world) then
            slot.spawner.MobGroup = nil
            slot.spawner:K2_DestroyActor()
        end
    end
end

function Session:update(running)
    if self.finished then return end
    for _, slot in ipairs(self.slots) do
        if not slot.boss then
            local member = slot.dormant and currentPawn(slot, self.world) or slot.actor
            if live(member, self.world) and member:IsAlive()
                and (slot.running ~= running or address(slot.actor) ~= address(member)) then
                local memberAddress = member:GetAddress()
                if slot.dormant and not self.owned[memberAddress] then
                    CombatSpawn.clearStoryFlow(member)
                    self.owned[memberAddress] = true
                    log("native summon scene=" .. self.scene .. " class=" .. slot.id)
                end
                CombatSpawn.challengeAI(member, running)
                slot.actor, slot.running = member, running
            end
        end
    end
end

function Session:nearPlayer(pawn, distance)
    local at = pawn:K2_GetActorLocation()
    local x, y, z = at.X, at.Y, at.Z
    for _, slot in ipairs(self.slots) do
        local actor = slot.actor
        if not slot.dormant and live(actor, self.world) and actor:IsAlive() then
            local location = actor:K2_GetActorLocation()
            if (location.X - x)^2 + (location.Y - y)^2 + (location.Z - z)^2 <= distance^2 then return true end
        end
    end
    return false
end

local function entranceState(actor, pawn, factions)
    local protection = actor.AbilitySystemComponent:GetGameplayTagCount({ TagName = FName(ENTRY_PROTECTION) })
    return protection, factions:GetFactionRelation(actor, pawn), factions:GetFactionRelation(pawn, actor)
end

local function enterDomain(actor, pawn, admission, factions)
    local ai = CombatSpawn.ai(actor)
    -- The borrowed spawners keep their original LinkFogDoor group. The
    -- original domain is isolated, so its player-entry notification is ours.
    if not admission.notified then
        ai:OnActorEnterDomain(pawn)
        admission.notified = true
    end
    local protection, towardPlayer, towardActor = entranceState(actor, pawn, factions)
    if protection > 0 or towardPlayer ~= HOSTILE or towardActor ~= HOSTILE then
        -- Use the original script's own effect handle and paired faction
        -- override. Other targeting and invulnerability effects belong to AI.
        for _, value in ipairs(ai.SpawnedAIScripts or {}) do
            local script = unwrap(value)
            if script and name(script:GetClass()) == "AIScript_PBZMisc_C"
                and address(script.Pawn) == actor:GetAddress() then
                script["Stop Invulnerable Before Combat"](script)
                break
            end
        end
        protection, towardPlayer, towardActor = entranceState(actor, pawn, factions)
    end
    local detail = ("protection=%d faction_to_player=%s faction_from_player=%s")
        :format(protection, tostring(towardPlayer), tostring(towardActor))
    return protection == 0 and towardPlayer == HOSTILE and towardActor == HOSTILE, detail
end

function Session:admitPlayer(pawn, now)
    if self.finished or address(pawn) ~= self.player then return end
    local factions = self.factions
    for _, slot in ipairs(self.slots) do
        local actor = slot.actor
        if live(actor, self.world) and actor:IsAlive() then
            local actorAddress = actor:GetAddress()
            local admission = self.admissions[actorAddress] or {}
            self.admissions[actorAddress] = admission
            if not admission.ready and now >= (admission.nextAt or 0) then
                admission.nextAt = now + 0.75
                local ok, ready, detail = pcall(enterDomain, actor, pawn, admission, factions)
                if ok and ready then
                    admission.ready = true
                    if slot.boss then log("domain entered scene=" .. self.scene .. " boss=" .. slot.id .. " " .. detail) end
                elseif now >= (admission.nextLog or 0) then
                    admission.nextLog = now + 5
                    log("domain waiting scene=" .. self.scene .. " actor=" .. name(actor) .. " " .. tostring(ok and detail or ready))
                end
            end
        end
    end
end

function Session:admitted(actor)
    if self.privateSlots and not self:owns(actor) then return true end
    local admission = self.admissions[actor:GetAddress()]
    return admission and admission.ready == true
end

function Session:engage(pawn, running, now)
    if self.finished or not self.openingSupport then return end
    if not running then self.engagement = nil; return end
    local state = self.engagement or { startedAt = now, requests = {} }
    self.engagement = state
    if state.complete or now < (state.nextPoll or 0) then return end
    state.nextPoll = now + 0.25
    local confirmed, waiting, reason = 0, nil, nil
    for _, slot in ipairs(self.slots) do
        local actor = slot.actor
        if live(actor, self.world) and actor:IsAlive() then
            local request = state.requests[slot] or {}
            state.requests[slot] = request
            if self:admitted(actor) then
                local ok, ready, why = pcall(Engage.start, actor, pawn, request, now)
                if ok and ready then confirmed = confirmed + 1
                elseif not waiting then waiting, reason = actor, ok and why or ready end
            elseif not waiting then waiting, reason = actor, "等待原版入场保护解除" end
        end
    end
    if not waiting then
        state.complete = true
        log(("engaged scene=%s native_targets=%d"):format(self.scene, confirmed))
    elseif now >= (state.nextLog or state.startedAt + 2) then
        state.nextLog = now + 5
        local ok, details = pcall(Engage.diagnose, waiting, pawn)
        log(("engagement waiting scene=%s actor=%s reason=%s collision=%s %s"):format(
            self.scene, name(waiting), tostring(reason), tostring(waiting:GetActorEnableCollision()),
            ok and details or "native state unavailable"))
    end
end

local function reveal(actor)
    -- HiddenNPC is the NPC interface used for cinematic staging. It restores
    -- collision, actor ticking and weapon visibility together with the mesh.
    actor:HiddenNPC(false)
    assert(actor.bHidden ~= true and actor:GetActorEnableCollision() and actor:IsActorTickEnabled(),
        "原版队伍单位未完成显形：" .. name(actor))
end

local function bindSlot(slot, actor)
    slot.actor, slot.running = actor, false
    slot.spawner.SpawnedAI = actor
    actor:OnSpawnFromSpawner(slot.spawner)
    assert(address(actor:GetAISpawner()) == slot.spawner:GetAddress(), "原版出生点绑定失败：" .. slot.id)
    if slot.privateGroup then
        actor.MobGroup = slot.privateGroup
        assert(address(actor:GetMobGroup()) == address(slot.privateGroup), "原版队伍成员绑定失败：" .. slot.id)
    end
end

local function announceSlot(session, slot, actor)
    slot.actor = actor
    assert(address(currentPawn(slot, session.world)) == address(actor), "原版出生点回读失败：" .. slot.id)
    slot.spawner:K2_OnAISpawnReady(actor)
    CombatSpawn.clearStoryFlow(actor)
    reveal(actor)
    session.owned[actor:GetAddress()] = true
end

function Session:bindBoss(actor, index)
    local slot = self.bossSlots[index]
    if slot then bindSlot(slot, actor) end
end

function Session:finishBoss(actor, index)
    local slot = self.bossSlots[index]
    if slot then announceSlot(self, slot, actor) end
end

function Session:activeSupports()
    local result = {}
    for _, slot in ipairs(self.slots) do
        if not slot.boss and live(slot.actor, self.world) and slot.actor:IsAlive() then
            result[#result+1] = slot.actor
        end
    end
    return result
end

local formationPattern = {
    {0,0}, {-1150,0}, {-580,-990}, {580,-990}, {1150,0}, {580,990}, {-580,990},
}
local pairPattern = { {-500,0}, {500,0}, {-900,-950}, {0,-1050}, {900,-950} }

local function portableFormations(entry, stage)
    local members = stage.members
    if entry.id == PAIR and #members == 2 and members[1].id == BROTHER and members[2].id == SWORDSWOMAN then
        return { { indices = {1,2}, support = PUPPET, count = 3, dormant = true, pattern = pairPattern } }
    end
    local result = {}
    for index, member in ipairs(members) do
        local data = formations[member.id]
        if data then
            result[#result+1] = { indices = { index }, support = data.support, count = #data.spawners,
                pattern = formationPattern }
        end
    end
    return result
end

function Squad.portable(scene, entry, stage, gameplay, system, pawn, cycle, arrival)
    if not scene.portableBossMechanics then return end
    local specifications = portableFormations(entry, stage)
    if #specifications == 0 then return end
    local world = address(SceneArena.runtimeWorld(pawn))
    if not world then return nil, "等待华山队伍的战斗世界" end
    local spawnerClass, why = SpawnClass.resolve(SPAWNER_CLASS, arrival)
    if not valid(spawnerClass) then return nil, why end
    local groups, reserved = {}, {}
    for index, specification in ipairs(specifications) do
        local points, facing = Terrain.place(pawn, system, scene, specification.pattern, scene.spawnPoints[index], 275, reserved)
        if not points then return nil, "等待华山队伍的安全站位" end
        for _, point in ipairs(points) do reserved[#reserved+1] = point end
        local slots = {}
        groups[#groups+1] = slots
        for slot, memberIndex in ipairs(specification.indices) do
            local member = stage.members[memberIndex]
            local class, reason = SpawnClass.resolve(member.classPath, arrival)
            if not valid(class) then return nil, reason end
            slots[#slots+1] = { id = member.id, boss = true, bossIndex = memberIndex,
                class = class, position = points[slot], rotation = facing }
        end
        local support, reason = SpawnClass.resolve(supportPath(specification.support), arrival)
        if not valid(support) then return nil, reason end
        for slot = 1, specification.count do
            slots[#slots+1] = { id = specification.support, class = support, dormant = specification.dormant,
                position = points[#specification.indices+slot], rotation = facing }
        end
    end
    local mathLibrary, actorLibrary = StaticFindObject(MATH), StaticFindObject(ACTORS)
    local factions, systemLibrary = StaticFindObject(FACTION_UTILS), StaticFindObject(SYSTEM)
    local groupClass = StaticFindObject(MOB_GROUP)
    assert(valid(mathLibrary) and valid(actorLibrary) and valid(factions) and valid(systemLibrary) and valid(groupClass),
        "缺少通用场地的原版队伍接口")
    local session = setmetatable({ slots = {}, privateSlots = {}, bossSlots = {}, world = world, scene = scene.id,
        player = pawn:GetAddress(), factions = factions, owned = {}, admissions = {},
        openingSupport = not specifications[1].dormant }, Session)
    local ok, failure = pcall(function()
        for _, slots in ipairs(groups) do
            local references = {}
            for _, slot in ipairs(slots) do
                local transform = mathLibrary:MakeTransform(slot.position, slot.rotation, SCALE)
                local spawner = actorLibrary:SpawnActorDeferred(pawn, spawnerClass, transform, 3)
                assert(valid(spawner), "原版队伍出生点创建失败")
                slot.spawner = spawner
                session.privateSlots[#session.privateSlots+1] = slot
                session.slots[#session.slots+1] = slot
                spawner.SpawnerID = spawner:GetFName()
                spawner.InitialSpawn, spawner.ShouldSpawn = false, false
                spawner.Class = systemLibrary:Conv_ClassToSoftClassReference(slot.class)
                spawner:SetOwner(pawn)
                assert(address(gameplay:FinishSpawningActor(spawner, transform, 1)) == address(spawner),
                    "原版队伍出生点初始化失败")
                spawner:SetActorEnableCollision(false)
                spawner:SetActorHiddenInGame(true)
                references[#references+1] = systemLibrary:Conv_ObjectToSoftObjectReference(spawner)
            end
            -- Only the native combat membership is portable. The map's story,
            -- drop and fog scripts are bound to its original domain.
            local group = StaticConstructObject(groupClass, slots[1].spawner)
            assert(valid(group), "原版战斗队伍创建失败")
            group.Members = references
            group.bUseMetaAI = false
            assert(#group.Members == #slots, "原版队伍出生点列表注册失败")
            for _, slot in ipairs(slots) do
                slot.privateGroup = group
                slot.spawner.MobGroup = group
                assert(address(slot.spawner:GetMobGroup()) == address(group), "原版队伍归属校验失败")
            end
            local supportCount = 0
            for _, slot in ipairs(slots) do
                if slot.boss then
                    session.bossSlots[slot.bossIndex] = slot
                elseif not slot.dormant then
                    local point = slot.position
                    local spawnAt = { X = point.X, Y = point.Y, Z = point.Z+100 }
                    local transform = mathLibrary:MakeTransform(spawnAt, slot.rotation, SCALE)
                    local actor = actorLibrary:SpawnActorDeferred(pawn, slot.class, transform, 3)
                    assert(valid(actor), "原版队伍助手创建失败：" .. slot.id)
                    bindSlot(slot, actor)
                    local capsule = actor.CapsuleComponent
                    if valid(capsule) then spawnAt.Z = point.Z + capsule:GetScaledCapsuleHalfHeight()+6 end
                    transform = mathLibrary:MakeTransform(spawnAt, slot.rotation, SCALE)
                    actor = CombatSpawn.finish(gameplay, pawn, actor, transform, cycle, true)
                    announceSlot(session, slot, actor)
                    supportCount = supportCount + 1
                end
            end
            assert(#group:GetAliveMemberPawns() >= supportCount, "原版队伍助手未完成原生登记")
        end
    end)
    if not ok then session:close(); error(failure, 0) end
    log(("portable ready scene=%s groups=%d spawners=%d"):format(scene.id, #groups, #session.privateSlots))
    return session
end

function Squad.spawn(scene, formation, stage, gameplay, system, pawn, cycle, classPlan, arrival)
    local Events = require("MeiGuHuOriginalEvents")
    local StockBell = require("StockBellArena")
    local world = assert(address(SceneArena.runtimeWorld(pawn)), "华山队伍的战斗世界未就绪")
    local slots, classes, group = {}, {}, nil
    local function add(id, suffix, boss, path, dormant)
        local key = SPAWNER .. suffix
        local source = Events.squadSpawner(key, gameplay:GetRealTimeSeconds(pawn))
        if not source then return nil, "等待原版队伍出生点 " .. key end
        if not live(source, world) then return nil, "等待当前场地的原版队伍出生点 " .. key end
        local mobGroup = unwrap(source:GetMobGroup())
        if not mobGroup then return nil, "等待原版队伍登记 " .. key end
        local domain = unwrap(mobGroup:GetOuter())
        assert(live(domain, world) and name(domain) == formation.domain and name(mobGroup) == formation.group
            and (not group or address(group) == address(mobGroup)), "原版出生点的队伍归属不符：" .. key)
        if source.ShouldSpawn ~= false or live(unwrap(source:GetPawn()), world) then
            return nil, "等待隔离原版队伍出生点 " .. key
        end
        group = mobGroup
        local slot = { id = id, spawner = source, boss = boss, dormant = dormant }
        if not dormant then
            local class = classes[path]
            if not class then
                local reason
                if boss and classPlan then class, reason = classPlan:resolve(path)
                else class, reason = SpawnClass.resolve(path, arrival) end
                if not valid(class) then return nil, reason end
                classes[path] = class
            end
            local at = source:K2_GetActorLocation()
            local point = { X = at.X, Y = at.Y, Z = at.Z }
            local floor = StockBell.floorAt(pawn, system, point, point.Z + 150, point.Z - 195)
            if not floor or math.abs(floor - point.Z) > 140 or floor < scene.combatHeight.min
                or floor > scene.combatHeight.max then return nil, "等待原版队伍站位地面 " .. key end
            local rotation = source:K2_GetActorRotation()
            slot.class, slot.position = class, { X = point.X, Y = point.Y, Z = floor }
            slot.rotation = { Pitch = 0, Yaw = rotation.Yaw, Roll = 0 }
        end
        slots[#slots + 1] = slot
        return true
    end
    -- The leader's native spawn scripts can immediately look for assistants.
    for _, suffix in ipairs(formation.spawners) do
        local ready, reason = add(formation.support, formation.prefix .. suffix, false,
            supportPath(formation.support), formation.dormant)
        if not ready then return nil, reason end
    end
    for _, member in ipairs(stage.members) do
        local ready, reason = add(member.id, formation.bosses[member.id], true, member.classPath)
        if not ready then return nil, reason end
    end

    local mathLibrary = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    local spawnerLibrary = StaticFindObject("/Script/SGameAI.Default__SGameAIFunctionLibrary")
    local factions = StaticFindObject(FACTION_UTILS)
    assert(valid(mathLibrary) and valid(spawnerLibrary) and valid(factions), "缺少原版队伍生成接口")
    local session = setmetatable({ slots = slots, world = world, scene = scene.id, owned = {},
        player = pawn:GetAddress(), factions = factions, admissions = {}, openingSupport = not formation.dormant,
        events = Events }, Session)
    local actors, levels = {}, {}
    Events.allowSquadSpawners(scene, slots)
    local ok, failure = pcall(function()
        for _, slot in ipairs(slots) do
            if not slot.dormant then
                local position = slot.position
                position.Z = position.Z + 100
                local transform = mathLibrary:MakeTransform(position, slot.rotation, SCALE)
                local actor = spawnerLibrary:SpawnActorDeferred(pawn, slot.class, transform, 3)
                assert(valid(actor), "原版队伍单位延迟生成失败：" .. slot.id)
                bindSlot(slot, actor)
                local capsule = actor.CapsuleComponent
                if valid(capsule) then position.Z = position.Z - 100 + capsule:GetScaledCapsuleHalfHeight() + 6 end
                transform = mathLibrary:MakeTransform(position, slot.rotation, SCALE)
                local level
                actor, level = CombatSpawn.finish(gameplay, pawn, actor, transform, cycle, true)
                announceSlot(session, slot, actor)
                if slot.boss then actors[#actors + 1], levels[#levels + 1] = actor, level end
            end
        end
        local counted, alive = pcall(function() return #group:GetAliveMemberPawns() end)
        log(("ready scene=%s group=%s bosses=%d support=%d dormant=%d native_alive=%s"):format(
            scene.id, formation.group, #actors, formation.dormant and 0 or #formation.spawners,
            formation.dormant and #formation.spawners or 0, counted and tostring(alive) or "unavailable"))
    end)
    if not ok then session:close(); error(failure, 0) end
    return session, nil, actors, levels
end

return Squad
