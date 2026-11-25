local SceneArena = require("SceneArena")
local Floor = {}
local ROTATION = { Pitch = 0, Yaw = 0, Roll = 0 }
local SCALE = { X = 1, Y = 1, Z = 1 }

local function valid(object)
    return object and object:IsValid()
end

local function owned(actor, world)
    if not valid(actor) or not valid(world) or actor:IsActorBeingDestroyed() then return false end
    local current = SceneArena.runtimeWorld(actor)
    return valid(current) and current:GetAddress() == world:GetAddress()
end

local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "井口空气地板接口未加载 " .. path)
    return object
end

function Floor.reset(tx)
    local actor, box = tx.wellActor, tx.wellBox
    tx.wellActor, tx.wellBox = nil, nil
    if owned(actor, tx.world) then
        if valid(box) then pcall(box.SetCollisionEnabled, box, 0) end
        pcall(actor.K2_DestroyActor, actor)
    end
end

function Floor.ensure(tx, gameplay, pawn)
    local spec = tx.scene.airFloor
    if not spec then return true end
    if owned(tx.wellActor, tx.world) and valid(tx.wellBox) and tx.wellBox:GetCollisionEnabled() == 1 then return true end
    Floor.reset(tx)
    local ok, errorMessage = pcall(function()
        assert(valid(pawn.CapsuleComponent), "等待玩家碰撞体")
        local channel = pawn.CapsuleComponent:GetCollisionObjectType()
        local transform = required("/Script/Engine.Default__KismetMathLibrary"):MakeTransform(spec.center, ROTATION, SCALE)
        local actor = gameplay:BeginDeferredActorSpawnFromClass(pawn, required("/Script/Engine.TriggerBox"), transform, 1, nil, 1)
        assert(valid(actor), "井口空气地板未生成")
        tx.wellActor = actor
        local finished = gameplay:FinishSpawningActor(actor, transform, 1)
        assert(owned(finished, tx.world) and finished:GetAddress() == actor:GetAddress(), "井口空气地板世界不符")
        local box = actor:GetComponentByClass(required("/Script/Engine.BoxComponent"))
        assert(valid(box), "井口空气地板缺少碰撞组件")
        tx.wellBox = box
        box:SetCollisionEnabled(0)
        box:SetGenerateOverlapEvents(false)
        box.bCanEverAffectNavigation = false
        box:SetHiddenInGame(true, false)
        box:SetBoxExtent(spec.extent, false)
        box:SetCollisionObjectType(0)
        box:SetCollisionResponseToAllChannels(0)
        for _, target in ipairs({ 2, 19, channel }) do box:SetCollisionResponseToChannel(target, 2) end
        box:SetCollisionEnabled(1)
        local at = box:K2_GetComponentLocation()
        local x, y, z = at.X, at.Y, at.Z
        local bounds = box:GetScaledBoxExtent()
        local width, length, depth = bounds.X, bounds.Y, bounds.Z
        assert(math.abs(x-spec.center.X) < 1 and math.abs(y-spec.center.Y) < 1 and math.abs(z+depth-spec.top) < 1,
            "井口空气地板放置回读不符")
        assert(math.abs(width-spec.extent.X) < 1 and math.abs(length-spec.extent.Y) < 1
            and box:GetCollisionEnabled() == 1 and box:GetCollisionResponseToChannel(channel) == 2,
            "井口空气地板碰撞回读不符")
        print(("[PBZPangzhenWellFloor] installed scene=%s top=%.1f size=%.1fx%.1f\n")
            :format(tx.scene.id, spec.top, width*2, length*2))
    end)
    if not ok then
        Floor.reset(tx)
        return nil, tostring(errorMessage)
    end
    return true
end

return Floor
