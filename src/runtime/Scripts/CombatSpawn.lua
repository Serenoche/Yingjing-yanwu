local CombatSpawn = {}

local function valid(object)
    return object ~= nil and object:IsValid()
end

local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "missing reflected object: " .. path)
    return object
end

local function controllerOf(actor)
    local controller = actor:GetController()
    assert(valid(controller), "spawned enemy has no controller")
    return controller
end

local function gameAI(controller)
    local aiClass = required("/Script/SGameAI.SGameAIComponent")
    return controller:GetComponentByClass(aiClass)
end

function CombatSpawn.ai(actor)
    local component = gameAI(controllerOf(actor))
    assert(valid(component), "spawned enemy controller has no SGameAIComponent")
    return component
end

function CombatSpawn.challengeAI(actor, running)
    local controller = controllerOf(actor)
    local component = gameAI(controller)
    if valid(component) then
        if running then component:StartAI() else component:StopAI() end
        return
    end
    local brain = controller.BrainComponent
    assert(valid(brain), "该首领缺少可独立运行的 AI")
    if running then brain:StartLogic() else brain:StopLogic("PBZChallengeStandby") end
end

function CombatSpawn.class(path)
    local class = StaticFindObject(path)
    if valid(class) then return class end
    LoadAsset(path)
    class = StaticFindObject(path)
    if not valid(class) then LoadAsset(path:gsub("_C$", "")) end
    return required(path)
end

function CombatSpawn.finish(gameplay, pawn, deferred, transform, enemyCycle, challenge)
    local actor, level
    local ok, err = pcall(function()
        local gameLibrary = required("/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary")
        local worldCycle = gameLibrary:GetGameCycle(pawn)
        assert(type(worldCycle) == "number" and worldCycle >= 0 and worldCycle <= 6, "无法读取原生周目")
        -- Detached actors do not receive the map spawner's level callback.
        deferred["Init Level"](deferred)
        level = deferred:GetCombatLevel() + 25 * (enemyCycle - worldCycle)
        assert(level >= 1, "测试敌人等级初始化失败")
        deferred.Level = level
        actor = gameplay:FinishSpawningActor(deferred, transform, 1)
        assert(valid(actor), "敌人生成失败")
        local attributes = actor.AttributeSetBase
        assert(valid(attributes) and math.abs(attributes.Level.CurrentValue - level) < 0.01, "测试敌人等级回读失败")
        if not valid(actor:GetController()) then actor:SpawnDefaultController() end
        if challenge then CombatSpawn.challengeAI(actor, false) else CombatSpawn.ai(actor):StopAI() end
    end)
    if not ok then
        if valid(actor) then actor:K2_DestroyActor()
        elseif valid(deferred) then deferred:K2_DestroyActor() end
        error(err, 0)
    end
    return actor, level
end

return CombatSpawn
