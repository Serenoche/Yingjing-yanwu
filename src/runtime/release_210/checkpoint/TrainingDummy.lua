local Dummy = {}
Dummy.__index = Dummy
Dummy.resetKey = "Delete"

local CLASS = "BP_Monster_GoldMaskMan_Dummy_OnlyHit"
local MESH = "/Game/PBZContent/Environments/Arch/Camp/Mesh/Wooden_Stake/SM_Wooden_Stake_001.SM_Wooden_Stake_001"
local STATIC_MESH = "/Script/Engine.StaticMesh"
local PENDING = 0x08023600
local HEALTH_TOLERANCE = .05
local WOODEN_STAKE_HEIGHT = 211 -- cm, stock mesh pivot at floor level
Dummy.floorClearance = 6

Dummy.target = {
    id = "training-dummy", name = "木桩", rank = "dummy", role = "固定靶", family = "训练器材",
    classPath = "/Game/RenewalContent/Actors/Mobs/Normal/" .. CLASS .. "." .. CLASS .. "_C",
}

local function valid(object)
    return object and type(object.IsValid) == "function" and object:IsValid()
end

local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "木桩缺少原生接口 " .. path)
    return object
end

local function makeWoodenVisual(actor)
    local mesh = StaticFindObject(MESH)
    if not valid(mesh) or mesh:HasAnyFlags(PENDING) then
        LoadAsset(MESH)
        mesh = StaticFindObject(MESH)
    end
    assert(valid(mesh) and not mesh:HasAnyFlags(PENDING) and mesh:IsA(required(STATIC_MESH)), "木桩模型未就绪")
    local mathLibrary = required("/Script/Engine.Default__KismetMathLibrary")
    local half = actor.CapsuleComponent:GetScaledCapsuleHalfHeight()
    local scale = 2 * half / WOODEN_STAKE_HEIGHT
    local transform = mathLibrary:MakeTransform({ X = 0, Y = 0, Z = -half - Dummy.floorClearance },
        { Pitch = 0, Yaw = 0, Roll = 0 }, { X = scale, Y = scale, Z = scale })
    local shell = actor:AddComponentByClass(required("/Script/Engine.StaticMeshComponent"), false, transform, false)
    assert(valid(shell), "木桩模型组件未就绪")
    shell:SetMobility(2)
    shell:SetGenerateOverlapEvents(false)
    shell:SetCollisionEnabled(0)
    assert(shell:SetStaticMesh(mesh), "木桩模型无法挂载")
    -- The native NPC remains the hit and lock-on target, including its bone collision.
    actor.Mesh.VisibilityBasedAnimTickOption = 0 -- AlwaysTickPoseAndRefreshBones
    actor.Mesh:SetVisibility(false, true)
    actor.CharacterMovement:DisableMovement()
end

function Dummy.new(actor, pawn, controller)
    local self = setmetatable({ actor = actor }, Dummy)
    local ok, reason = pcall(function()
        -- This guard uses the common PBZ ASC and full-health floor. The dummy
        -- has the same interface and owns a separate effect and execution tag.
        self.guard = require("PlayerDamageGuard").new(actor)
        self.guard:enable()
        makeWoodenVisual(actor)
        self.damage = require("TrainingDummyDamage").new(actor, pawn)
        self.hud = require("TrainingDummyHud").new({ controller = controller, resetKeyLabel = Dummy.resetKey })
    end)
    if not ok then
        pcall(self.close, self)
        error(reason, 0)
    end
    print("[PBZTrainingDummy] 木桩已锁血，伤害统计已启用\n")
    return self
end

function Dummy:lockIntact(health, maximum)
    local minimum = self.actor.AttributeSetBase.Health_Min.CurrentValue
    return type(minimum) == "number" and minimum >= maximum - HEALTH_TOLERANCE
        and health >= maximum - HEALTH_TOLERANCE
end

function Dummy:draw(visible)
    if not self.hud or not self.damage then return end
    if visible then self.hud:show(self.damage:snapshot()) else self.hud:hide() end
end

function Dummy:reset()
    self.damage:reset()
end

function Dummy:close()
    local failures = {}
    if self.hud then self.hud:hide(); self.hud = nil end
    for _, field in ipairs({ "damage", "guard" }) do
        local resource = self[field]
        if resource then
            local ok, reason = pcall(resource.close, resource)
            if ok then self[field] = nil else failures[#failures + 1] = tostring(reason) end
        end
    end
    assert(#failures == 0, table.concat(failures, "；"))
end

return Dummy
