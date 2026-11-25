local CombatSpawn = require("CombatSpawn")
local SceneArena = require("SceneArena")

local Overheat = {}
local FIRST = "BP_Monster_LionDancer"
local SECOND = "BP_Monster_LionDancer_P2"
local GAUNTLET = "gauntlet_liondancer"
local SPAWNER = "/SGameAI/Tools/Spawner/BP_AISpawner.BP_AISpawner_C"
local AI_LIBRARY = "/Script/SGameAI.Default__SGameAIFunctionLibrary"
local GROUP = "/Script/SGameAI.MobGroup"
local PENDING = 0x08023600

local function valid(object)
    return object and type(object.IsValid) == "function" and object:IsValid()
end

local function address(object)
    if valid(object) then return object:GetAddress() end
    if object and type(object.get) == "function" then
        local value = object:get()
        if valid(value) then return value:GetAddress() end
    end
end

local function live(actor, world)
    return valid(actor) and not actor:HasAnyFlags(PENDING) and not actor:IsActorBeingDestroyed()
        and address(SceneArena.runtimeWorld(actor)) == world
end

local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "缺少舞狮过热接口 " .. path)
    return object
end

local function release(slot, keepGroup)
    local spawner = slot.spawner
    if not live(spawner, slot.world) then return end
    local cleared, reason = pcall(function() spawner.SpawnedAI = nil end)
    if not cleared then print("[PBZLionOverheat] cleanup " .. tostring(reason) .. "\n") end
    if not keepGroup then
        local destroyed, failure = pcall(spawner.K2_DestroyActor, spawner)
        if not destroyed then print("[PBZLionOverheat] cleanup " .. tostring(failure) .. "\n") end
    end
end

function Overheat.clear(run, keepGauntlet)
    local groups = run.lionOverheatGroups
    if not groups then return end
    for key, slot in pairs(groups) do
        local keep = keepGauntlet and key == GAUNTLET and live(slot.spawner, slot.world)
        release(slot, keep)
        if not keep then groups[key] = nil end
    end
    if not next(groups) then run.lionOverheatGroups = nil end
end

function Overheat.required(member)
    return member.id == FIRST or member.id == SECOND
end

function Overheat.finish(run, member, gameplay, pawn, deferred, transform, cycle, statCycles)
    -- The two authored gauntlet phases share a single native parameter store.
    local key = run.entry.id == GAUNTLET and GAUNTLET or deferred:GetAddress()
    local groups = run.lionOverheatGroups or {}
    run.lionOverheatGroups = groups
    local slot, created, attached, actor, level
    local ok, reason = pcall(function()
        local world = assert(address(SceneArena.runtimeWorld(pawn)), "舞狮过热的战斗世界未就绪")
        slot = groups[key]
        local heatKey = FName("Overheat")
        if not slot then
            local groupClass = required(GROUP)
            local spawner = required(AI_LIBRARY):SpawnActorDeferred(pawn, CombatSpawn.class(SPAWNER), transform, 3)
            assert(valid(spawner), "无法创建舞狮的原生出生点")
            slot = { spawner = spawner, world = world }
            groups[key], created = slot, true
            spawner.SpawnerID = spawner:GetFName()
            spawner.InitialSpawn, spawner.ShouldSpawn = false, false
            local finished = gameplay:FinishSpawningActor(spawner, transform, 1)
            assert(address(finished) == address(spawner) and live(spawner, world), "舞狮出生点未就绪")
            spawner:SetActorHiddenInGame(true)
            spawner:SetActorEnableCollision(false)
            spawner:SetActorTickEnabled(false)
            -- The native passive needs this group's float parameter and delegate.
            -- The private group has no map scripts and never activates a spawner.
            local group = StaticConstructObject(groupClass, spawner)
            assert(valid(group), "无法创建舞狮的原生过热队伍")
            group.bUseMetaAI = false
            group:SetFloatParameter(heatKey, 0)
            spawner.MobGroup, slot.group = group, group
        end
        local spawner, group = slot.spawner, slot.group
        assert(slot.world == world and live(spawner, world) and valid(group)
            and not live(spawner:GetPawn(), world) and address(spawner:GetMobGroup()) == address(group),
            "舞狮的过热队伍尚未清理上一阶段单位")
        -- The passive caches GetAISpawner()->GetMobGroup() during BeginPlay.
        attached = true
        spawner.SpawnedAI = deferred
        deferred:OnSpawnFromSpawner(spawner)
        assert(address(deferred:GetAISpawner()) == address(spawner)
            and address(deferred:GetMobGroup()) == address(group), "舞狮过热队伍绑定回读失败")
        actor, level = CombatSpawn.finish(gameplay, pawn, deferred, transform, cycle, true, statCycles)
        assert(valid(actor) and address(actor) == address(deferred) and address(actor:GetAISpawner()) == address(spawner)
            and address(actor:GetMobGroup()) == address(group),
            "舞狮生成时丢失过热出生点")
        print(("[PBZLionOverheat] bound target=%s stage=%d boss=%s heat=%s\n"):format(
            run.entry.id, run.stageIndex, member.id, tostring(group:FindFloatParameter(heatKey))))
    end)
    if not ok then
        if valid(deferred) and not deferred:IsActorBeingDestroyed() then
            pcall(deferred.K2_DestroyActor, deferred)
        end
        if created or attached then release(slot, not created) end
        if created then groups[key] = nil end
        error(reason, 0)
    end
    return actor, level
end

return Overheat
