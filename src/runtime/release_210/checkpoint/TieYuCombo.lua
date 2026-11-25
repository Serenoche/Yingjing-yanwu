local CombatSpawn = require("CombatSpawn")
local SceneArena = require("SceneArena")

local Combo = {}
Combo.__index = Combo

local IRON = "BP_Monster_TieGui"
local JADE = "BP_Monster_Yuu"
local SPAWNER = "/SGameAI/Tools/Spawner/BP_AISpawner.BP_AISpawner_C"
local GROUP = "/Script/SGameAI.MobGroup"
local AI = "/Script/SGameAI.Default__SGameAIFunctionLibrary"
local BLACKBOARD = "/Script/AIModule.Default__AIBlueprintHelperLibrary"
local MATH = "/Script/Engine.Default__KismetMathLibrary"
local PARTNER = "AI.BlackboardKey.Object.Vehicle"
local PENDING = 0x08023600

local function valid(object)
    return object and type(object.IsValid) == "function" and object:IsValid()
end

local function address(object)
    return valid(object) and object:GetAddress() or nil
end

local function live(actor, world)
    return valid(actor) and not actor:HasAnyFlags(PENDING) and not actor:IsActorBeingDestroyed()
        and address(SceneArena.runtimeWorld(actor)) == world
end

local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "缺少铁鬼玉妖联动接口 " .. path)
    return object
end

function Combo:log(event, detail)
    print(("[PBZTieYuCombo] %s target=%s scene=%s %s\n"):format(
        event, self.entry, self.scene, detail or ""))
end

function Combo:close()
    if self.closed then return end
    self.closed = true
    for index, slot in ipairs(self.slots) do
        local actor, spawner = slot.actor, slot.spawner
        local other = self.slots[3 - index]
        local partner = other and other.actor
        if live(actor, self.world) then
            local cleared, detail = pcall(function()
                local board = slot.hasPartner and self.blackboards:GetBlackboard(actor)
                if valid(board) and address(partner)
                    and address(self.ai:GetValueAsObjectByTag(board, self.key)) == address(partner) then
                    self.ai:SetValueAsObjectByTag(board, self.key, nil)
                end
            end)
            if not cleared then self:log("cleanup", tostring(detail)) end
            local detached, reason = pcall(function()
                if valid(spawner) and address(actor:GetAISpawner()) == address(spawner) then actor.Spawner = nil end
                if slot.registered and valid(self.group) then
                    self.group:RemoveRuntimeMember(actor)
                    if address(actor:GetMobGroup()) == address(self.group) then actor.MobGroup = nil end
                end
            end)
            if not detached then self:log("cleanup", tostring(reason)) end
        end
        if live(spawner, self.world) then
            local destroyed, failure = pcall(function()
                spawner.SpawnedAI = nil
                spawner.MobGroup = nil
                spawner:K2_DestroyActor()
            end)
            if not destroyed then self:log("cleanup", tostring(failure)) end
        end
    end
    self.group, self.slots = nil, {}
end

function Combo:update(pawn, now)
    if self.closed or self.ready or now < self.nextAt then return end
    self.nextAt = now + 0.25
    if address(pawn) ~= self.player or address(SceneArena.runtimeWorld(pawn)) ~= self.world then
        self:close()
        return
    end
    for _, slot in ipairs(self.slots) do
        if not live(slot.actor, self.world) or not slot.actor:IsAlive() then self:close(); return end
    end
    local ok, ready = pcall(function()
        local firstSlot, secondSlot = self.slots[1], self.slots[2]
        local first, second = firstSlot.actor, secondSlot.actor
        local a, b = self.blackboards:GetBlackboard(first), self.blackboards:GetBlackboard(second)
        if not valid(a) or not valid(b) then return false end
        firstSlot.hasPartner, secondSlot.hasPartner = true, true
        self.ai:SetValueAsObjectByTag(a, self.key, second)
        self.ai:SetValueAsObjectByTag(b, self.key, first)
        return address(self.ai:GetValueAsObjectByTag(a, self.key)) == address(second)
            and address(self.ai:GetValueAsObjectByTag(b, self.key)) == address(first)
    end)
    if ok and ready then
        self.ready = true
        self:log("ready", "native_members=2 partners=2")
    elseif now >= self.deadline then
        self:log("unavailable", tostring(ok and "搭档黑板未就绪" or ready))
        self:close()
    end
end

function Combo.open(stage, actors, gameplay, pawn, now, entry, scene)
    if stage.cooperation ~= "tieyu" then return end
    local self = setmetatable({
        slots = {}, entry = entry, scene = scene, player = address(pawn),
        world = address(SceneArena.runtimeWorld(pawn)), nextAt = now, deadline = now + 8,
    }, Combo)
    local ok, reason = pcall(function()
        local first, second = stage.members[1].id, stage.members[2].id
        assert(#actors == 2 and ((first == IRON and second == JADE) or (first == JADE and second == IRON)),
            "搭档阶段成员不符")
        assert(self.world, "搭档阶段的战斗世界未就绪")
        self.ai, self.blackboards = required(AI), required(BLACKBOARD)
        self.key = { TagName = FName(PARTNER) }
        local mathLibrary, spawnerClass = required(MATH), CombatSpawn.class(SPAWNER)
        self.group = StaticConstructObject(required(GROUP), actors[1])
        assert(valid(self.group), "无法建立原生临时队伍")
        self.group.bUseMetaAI = false
        for _, actor in ipairs(actors) do
            assert(live(actor, self.world) and actor:IsAlive()
                and not valid(actor:GetAISpawner()) and not valid(actor:GetMobGroup()), "搭档已有出生点或队伍")
            self.slots[#self.slots + 1] = { actor = actor }
        end
        for _, slot in ipairs(self.slots) do
            local actor = slot.actor
            local transform = mathLibrary:MakeTransform(actor:K2_GetActorLocation(), actor:K2_GetActorRotation(),
                { X = 1, Y = 1, Z = 1 })
            local spawner = self.ai:SpawnActorDeferred(pawn, spawnerClass, transform, 3)
            assert(valid(spawner), "无法建立搭档出生点引用")
            slot.spawner = spawner
            spawner.SpawnerID = spawner:GetFName()
            spawner.InitialSpawn, spawner.ShouldSpawn = false, false
            local finished = gameplay:FinishSpawningActor(spawner, transform, 1)
            assert(address(finished) == address(spawner) and live(spawner, self.world), "搭档出生点未就绪")
            spawner.MobGroup, spawner.SpawnedAI = self.group, actor
            -- These are the native OnSpawnFromSpawner links. CombatSpawn has
            -- already finished initializing the sandbox boss's level.
            actor.Spawner, actor.MobGroup = spawner, self.group
            slot.registered = true
            self.group:AddRuntimeMember(actor)
            assert(address(actor:GetAISpawner()) == address(spawner)
                and address(spawner:GetMobGroup()) == address(self.group)
                and address(spawner:GetPawn()) == address(actor), "搭档出生点回读不符")
        end
        assert(#self.group:GetAliveMemberPawns() == 2, "临时队伍成员回读不符")
        for _, slot in ipairs(self.slots) do
            -- This is the exact native member lookup used by the Yuu combo trees.
            assert(#slot.spawner:GetOtherAliveMembersInGroup() == 1, "原版行为树无法找到另一名搭档")
        end
    end)
    if not ok then
        self:log("unavailable", tostring(reason))
        self:close()
        return
    end
    self:update(pawn, now)
    return self
end

return Combo
