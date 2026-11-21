local CombatSpawn = require("CombatSpawn")
local Charge, Session = {}, {}
Session.__index = Session

local ROOT = "/PBZCombatAsset/ActorData/Players/Hun/Weapon/ShuangYue/GameplayEffects/"
local PREFIX = "GE_ShuangYue_ChargeState_CombatListener_"
local LINGERING = ROOT .. PREFIX .. "Lingering." .. PREFIX .. "Lingering_C"
local CLEANUP = ROOT .. PREFIX .. "RemoveState." .. PREFIX .. "RemoveState_C"
local COMPLETION_COMPONENT = "/Script/GameplayAbilities.AdditionalEffectsGameplayEffectComponent"
local PENDING = 0x08023600
local active

local function address(object)
    return object and object:IsValid() and object:GetAddress() or nil
end

local function ready(object)
    return address(object) ~= nil and not object:HasAnyFlags(PENDING)
end

local function unwrap(value)
    local wrapped, object = pcall(function() return value:get() end)
    return wrapped and object or value
end

local function collect(records, owner, field, cleanup)
    local classes = owner[field]
    if classes == nil or #classes == 0 then return end
    local cleanupAddress = address(cleanup)
    assert(cleanupAddress and #classes == 1 and address(unwrap(classes[1])) == cleanupAddress,
        "双钺脱战回调与已验证的原版资源不符")
    records[#records + 1] = { owner = owner, field = field }
end

function Charge.new(mode, log)
    if mode ~= "practice" and mode ~= "challenge" and mode ~= "training" then return nil end
    return setmetatable({ mode = mode, log = log }, Session)
end

function Session:close()
    if active ~= self then return true end
    local current = StaticFindObject(LINGERING)
    -- A collected package will deserialize its original defaults on the next load.
    if address(current) == self.classAddress then
        for _, record in ipairs(self.records) do
            local classes = record.owner[record.field]
            if #classes == 0 then
                local cleanup = CombatSpawn.class(CLEANUP)
                classes[1] = cleanup
                assert(#classes == 1 and address(unwrap(classes[1])) == address(cleanup),
                    "双钺脱战回调恢复失败")
            end
        end
    end
    active, self.records = nil, nil
    self.log("双钺原版脱战回调已恢复")
    return true
end

function Session:update()
    -- The weapon loads these definitions. The arena's existing one-second service
    -- tick also covers switching to the weapon or reloading a collected package.
    local class = StaticFindObject(LINGERING)
    if not ready(class) then return end
    local defaults = class:GetCDO()
    if not ready(defaults) or self.lastDefaults == defaults:GetAddress() then return end
    Charge.restore()
    self.lastDefaults = defaults:GetAddress()

    local cleanup = StaticFindObject(CLEANUP)
    local componentClass = StaticFindObject(COMPLETION_COMPONENT)
    local records = {}
    if address(componentClass) then
        local components = defaults.GEComponents
        for index = 1, #components do
            local component = unwrap(components[index])
            if ready(component) and component:IsA(componentClass) then
                collect(records, component, "OnCompleteNormal", cleanup)
            end
        end
    end
    collect(records, defaults, "RoutineExpirationEffectClasses", cleanup)
    assert(#records > 0, "找不到双钺原版脱战清理回调")

    -- These are the completion lists for this exact 3-second effect. Keep the
    -- premature-completion and enhancement callbacks on their native paths.
    self.classAddress, self.records, active = class:GetAddress(), records, self
    local ok, failure = pcall(function()
        for _, record in ipairs(records) do
            local classes = record.owner[record.field]
            classes:Empty()
            assert(#classes == 0, "双钺脱战清理回调停用失败")
        end
    end)
    if not ok then
        self:close()
        error(failure, 0)
    end
    self.log("双钺已保留脱战煞气（" .. self.mode .. "）")
end

function Charge.restore()
    if active then return active:close() end
    return true
end

return Charge
