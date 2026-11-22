local CombatSpawn = {}
local LEVELS_PER_CYCLE = 25

local BOMB_MESHES = { M087 = "BombMan", M088 = "BombMan_Bing", M089 = "BombMan_Du" }

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

function CombatSpawn.clearStoryFlow(actor)
    if not valid(actor) then return end
    local readable, flow = pcall(function() return actor.BP_PBZFlowComponent end)
    if not readable or not valid(flow) then return end
    flow.bAutoStartRootFlow = false
    if valid(flow.RootFlow) and valid(flow:GetRootFlowInstance()) then flow:FinishRootFlow(flow.RootFlow, 1) end
    flow:PBZUnregister()
end

function CombatSpawn.prepareMobAppearance(actor, id)
    local expected = BOMB_MESHES[id]
    if not expected then return end
    local ok, reason = pcall(function()
        local mesh = actor.Mesh
        assert(valid(mesh), "爆弹兵骨骼网格未就绪")
        local asset = mesh:GetSkeletalMeshAsset()
        assert(valid(asset) and asset:GetFName():ToString() == expected, "爆弹兵原版网格不匹配")
        -- Apply the authored mesh settings before BeginPlay registers the body.
        mesh:SetAutoRegisterWithBudgetAllocator(false)
        mesh.bEnableUpdateRateOptimizations = false
        mesh:SetForcedLOD(1)
    end)
    if not ok then print("[PBZTestArenaNative] Bombman pose " .. id .. ": " .. tostring(reason) .. "\n") end
end

function CombatSpawn.stabilizeMobAppearance(actor, id)
    if not BOMB_MESHES[id] then return end
    local ok, reason = pcall(function()
        local mesh, tube = actor.Mesh, actor.Tube
        if valid(mesh) then mesh:PrestreamTextures(12, false, 0) end
        if valid(tube) then
            -- The Blueprint finishes constructing the tube during spawn.
            tube.bEnableUpdateRateOptimizations = false
            tube.VisibilityBasedAnimTickOption = 0 -- AlwaysTickPoseAndRefreshBones
            tube:SetForcedLOD(1)
            tube:PrestreamTextures(12, false, 0)
        end
        local cloth = actor:GetComponentByClass(required("/Script/ChaosClothAssetEngine.ChaosClothComponent"))
        if valid(cloth) then
            cloth:SetForcedLOD(1)
            cloth:PrestreamTextures(12, false, 0)
        end
    end)
    if not ok then print("[PBZTestArenaNative] Bombman visuals " .. id .. ": " .. tostring(reason) .. "\n") end
end

function CombatSpawn.destroyMobGroup(roots)
    local actors, seen = {}, {}
    local function collect(actor)
        if not valid(actor) or actor:IsActorBeingDestroyed() then return end
        local address = actor:GetAddress()
        if seen[address] then return end
        seen[address], actors[#actors + 1] = true, actor
        local children = actor.Children
        if children then
            children:ForEach(function(_, value)
                local wrapped, child = pcall(function() return value:get() end)
                if wrapped then value = child end
                collect(value)
            end)
        end
    end
    for _, actor in ipairs(roots) do collect(actor) end
    for _, actor in ipairs(actors) do
        if valid(actor) and not actor:IsActorBeingDestroyed() then actor:K2_DestroyActor() end
    end
end

local function withCycle(level, fromCycle, toCycle)
    return level + LEVELS_PER_CYCLE * ((toCycle or fromCycle) - fromCycle)
end

local function matches(value, expected)
    return math.abs(value - expected) <= math.max(.01, math.abs(expected) * 1e-6)
end

local function positive(value)
    return type(value) == "number" and value > 0 and value < math.huge
end

local function scaledBase(attribute, curve, fromLevel, toLevel)
    assert(valid(curve), "浊梦敌人原版属性曲线未就绪")
    local before, after = curve:GetValue(fromLevel), curve:GetValue(toLevel)
    local base = attribute.BaseValue
    assert(positive(before) and positive(after) and positive(base), "浊梦敌人属性初值无效")
    -- Preserve the native difficulty multiplier while replacing level growth.
    local result = base * (after / before)
    assert(positive(result), "浊梦敌人属性计算异常")
    return result
end

local function scaleAttribute(actor, attributes, field, curve, level, targetLevel, setAttribute)
    local value = scaledBase(attributes[field], curve, level, targetLevel)
    setAttribute(actor, field, value)
    assert(matches(attributes[field].BaseValue, value), "浊梦敌人属性回读不符：" .. field)
end

local function scaleResource(actor, attributes, field, curve, level, targetLevel, setAttribute)
    local maxField = field .. "_Max"
    local current, maximum = attributes[field].CurrentValue, attributes[maxField].CurrentValue
    assert(type(current) == "number" and current >= 0 and current < math.huge and positive(maximum),
        "浊梦敌人初始资源无效：" .. field)
    local fraction = math.min(1, current / maximum)
    scaleAttribute(actor, attributes, maxField, curve, level, targetLevel, setAttribute)
    local newMaximum = attributes[maxField].CurrentValue
    assert(positive(newMaximum), "浊梦敌人资源上限无效：" .. field)
    local value = fraction * newMaximum
    if not matches(attributes[field].CurrentValue, value) then
        setAttribute(actor, field, value)
        assert(matches(attributes[field].CurrentValue, value), "浊梦敌人资源回读不符：" .. field)
    end
end

local function applyStatCycles(actor, attributes, level, enemyCycle, cycles)
    local healthLevel = withCycle(level, enemyCycle, cycles.health)
    local attackLevel = withCycle(level, enemyCycle, cycles.attack)
    local shachiLevel = withCycle(level, enemyCycle, cycles.shachi)
    if healthLevel == level and attackLevel == level and shachiLevel == level then return end
    local config = actor["Actor Config"]
    assert(valid(config), "浊梦敌人原版角色配置未就绪")
    local data = assert(config["Attribute Data"], "浊梦敌人原版属性配置未就绪")
    local setAttribute = require("PracticeMode").setAttributeValue

    if healthLevel ~= level then
        scaleResource(actor, attributes, "Health", data.MaxHealth, level, healthLevel, setAttribute)
    end
    if attackLevel ~= level then
        scaleAttribute(actor, attributes, "Attack", data.Attack, level, attackLevel, setAttribute)
    end
    if shachiLevel ~= level then
        local maxShachi = data.MaxShachi
        -- Identify an absent Shachi pool from the native curve at the spawn level.
        local zeroShachiMax = cycles.allowZeroShachiMax and valid(maxShachi) and maxShachi:GetValue(level) == 0
        if not zeroShachiMax then
            scaleResource(actor, attributes, "Shachi", maxShachi, level, shachiLevel, setAttribute)
        end
        scaleAttribute(actor, attributes, "ShachiAttack", data.ShachiAttack, level, shachiLevel, setAttribute)
    end
end

function CombatSpawn.finish(gameplay, pawn, deferred, transform, enemyCycle, challenge, statCycles)
    local actor, level
    local ok, err = pcall(function()
        local gameLibrary = required("/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary")
        local worldCycle = gameLibrary:GetGameCycle(pawn)
        assert(type(worldCycle) == "number" and worldCycle >= 0 and worldCycle <= 6, "无法读取原生周目")
        -- Detached actors do not receive the map spawner's level callback.
        deferred["Init Level"](deferred)
        level = withCycle(deferred:GetCombatLevel(), worldCycle, enemyCycle)
        assert(level >= 1, "测试敌人等级初始化失败")
        deferred.Level = level
        actor = gameplay:FinishSpawningActor(deferred, transform, 1)
        assert(valid(actor), "敌人生成失败")
        local attributes = actor.AttributeSetBase
        assert(valid(attributes) and math.abs(attributes.Level.CurrentValue - level) < 0.01, "测试敌人等级回读失败")
        if not valid(actor:GetController()) then actor:SpawnDefaultController() end
        if challenge then CombatSpawn.challengeAI(actor, false) else CombatSpawn.ai(actor):StopAI() end
        if statCycles then applyStatCycles(actor, attributes, level, enemyCycle, statCycles) end
    end)
    if not ok then
        if valid(actor) then actor:K2_DestroyActor()
        elseif valid(deferred) then deferred:K2_DestroyActor() end
        error(err, 0)
    end
    return actor, level
end

return CombatSpawn
