-- Same-world encounter transitions: observe resources, change only transform.
-- This is not a save-state serializer. In particular it never reconstructs GAS
-- effects, refills items, changes attributes, respawns, loads a save or a map.
local PlayerState = {}

local LIBRARY = "/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary"
local SUBSYSTEMS = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local BACKPACK = "/Script/ProjectPBZ.PBZBackPackSubsystem"
local ATTRIBUTES = { "Health", "Health_Max", "Shachi", "Shachi_Max",
    "UltimateCharge", "UltimateChargeCount", "SpiritShadow" }
local MEDICINE_FIELDS = { "CurrentTime", "CurrentLevel" }

local function valid(object)
    return object ~= nil and object:IsValid()
end

local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "missing reflected object: " .. path)
    return object
end

local function finite(value)
    return type(value) == "number" and value > -math.huge and value < math.huge
end

local function address(object)
    assert(valid(object), "encounter player object is no longer valid")
    return object:GetAddress()
end

local function unwrapped(value)
    local ok, result = pcall(function() return value:get() end)
    if ok then return result end
    return value
end

local function nameText(value)
    value = unwrapped(value)
    if type(value) == "string" then return value end
    return value:ToString()
end

local function vector(value, fields)
    local result = {}
    for _, field in ipairs(fields) do
        assert(value and finite(value[field]), "invalid encounter transform " .. field)
        result[field] = value[field]
    end
    return result
end

local function position(value)
    return vector(value, { "X", "Y", "Z" })
end

local function rotation(value)
    return vector(value, { "Pitch", "Yaw", "Roll" })
end

local function owner(pawn, controller)
    local world = pawn:GetWorld()
    assert(valid(world), "encounter player world is unavailable")
    if controller ~= nil then
        assert(valid(controller) and address(controller:GetWorld()) == address(world),
            "encounter controller belongs to another world")
        assert(address(controller:K2_GetPawn()) == address(pawn), "encounter controller owns another pawn")
    end
    return world
end

function PlayerState.capture(pawn, controller)
    assert(valid(pawn) and not pawn:IsActorBeingDestroyed(), "encounter player is unavailable")
    local world = owner(pawn, controller)
    local asc, attributes = pawn.AbilitySystemComponent, pawn.AttributeSetBase
    assert(valid(asc) and valid(attributes), "encounter player attributes are not initialized")
    local snapshot = {
        pawnAddress = address(pawn), worldAddress = address(world), abilitySystemAddress = address(asc),
        position = position(pawn:K2_GetActorLocation()), rotation = rotation(pawn:K2_GetActorRotation()),
        attributes = {}, medicines = {},
    }
    if controller ~= nil then
        snapshot.controllerAddress = address(controller)
        snapshot.controlRotation = rotation(controller:GetControlRotation())
    end
    for _, field in ipairs(ATTRIBUTES) do
        local value = attributes[field].CurrentValue
        assert(finite(value), "encounter attribute is unavailable: " .. field)
        snapshot.attributes[field] = value
    end
    local backpack = required(SUBSYSTEMS):GetWorldSubsystem(pawn, required(BACKPACK))
    assert(valid(backpack), "encounter player backpack is unavailable")
    snapshot.backpackAddress = address(backpack)
    backpack.MedicineInfos:ForEach(function(key, parameter)
        local id, medicine = nameText(key), unwrapped(parameter)
        assert(id ~= "" and id ~= "None" and snapshot.medicines[id] == nil,
            "encounter medicine identifier is invalid or duplicated")
        local entry = {}
        for _, field in ipairs(MEDICINE_FIELDS) do
            local value = medicine[field]
            assert(finite(value), "encounter medicine field is unavailable: " .. id .. "." .. field)
            entry[field] = value
        end
        -- Duration may naturally tick between phases. Retain it for diagnostics,
        -- but do not freeze, restore or treat it as a resource-count mismatch.
        local hasDuration, duration = pcall(function() return medicine.BuffRemainTime end)
        if hasDuration and finite(duration) then entry.BuffRemainTime = duration end
        snapshot.medicines[id] = entry
    end)
    return snapshot
end

function PlayerState.compare(before, after, tolerance)
    assert(type(before) == "table" and type(after) == "table", "missing encounter player snapshot")
    tolerance = tolerance or 0.01
    assert(finite(tolerance) and tolerance >= 0, "invalid encounter comparison tolerance")
    local differences = {}
    local function compare(path, old, new, exact)
        if old == new then return end
        if not exact and finite(old) and finite(new) and math.abs(old - new) <= tolerance then return end
        differences[#differences + 1] = { field = path, before = old, after = new }
    end
    for _, field in ipairs({ "pawnAddress", "worldAddress", "abilitySystemAddress", "backpackAddress", "controllerAddress" }) do
        compare(field, before[field], after[field], true)
    end
    for _, field in ipairs(ATTRIBUTES) do
        compare("attributes." .. field, before.attributes[field], after.attributes[field])
    end
    local ids = {}
    for id in pairs(before.medicines) do ids[id] = true end
    for id in pairs(after.medicines) do ids[id] = true end
    for id in pairs(ids) do
        local old, new = before.medicines[id], after.medicines[id]
        if old == nil or new == nil then
            compare("medicines." .. id, old ~= nil, new ~= nil, true)
        else
            for _, field in ipairs(MEDICINE_FIELDS) do
                compare("medicines." .. id .. "." .. field, old[field], new[field], true)
            end
        end
    end
    return #differences == 0, differences
end

-- The caller must supply the captured, ground-verified arena anchor from this
-- same living pawn/world. Native failure is returned; no reset/heal fallback.
function PlayerState.teleport(pawn, anchor, controller)
    assert(type(anchor) == "table", "missing encounter player anchor")
    assert(valid(pawn) and not pawn:IsActorBeingDestroyed(), "encounter player is unavailable")
    local world = owner(pawn, controller)
    assert(address(pawn) == anchor.pawnAddress and address(world) == anchor.worldAddress,
        "encounter anchor belongs to another pawn or world")
    assert(address(pawn.AbilitySystemComponent) == anchor.abilitySystemAddress,
        "encounter player ability system changed")
    local hp = pawn.AttributeSetBase.Health.CurrentValue
    assert(finite(hp) and hp > 0, "dead encounter player cannot enter another phase")
    assert(pawn.AbilitySystemComponent:GetGameplayTagCount({ TagName = FName("CharacterState.Dead") }) == 0,
        "dead encounter player cannot enter another phase")
    local destination, facing = position(anchor.position), rotation(anchor.rotation)
    if controller ~= nil and anchor.controllerAddress ~= nil then
        assert(address(controller) == anchor.controllerAddress, "encounter anchor controller changed")
    end
    local camera = controller ~= nil and anchor.controlRotation and rotation(anchor.controlRotation) or nil
    local success = required(LIBRARY):PBZActorTeleportTo(pawn, destination, facing, false, false)
    assert(type(success) == "boolean", "native encounter teleport did not return a result")
    if not success then return false, "native encounter teleport rejected the destination" end
    if camera then controller:SetControlRotation(camera) end
    return true
end

return PlayerState
