-- Arena equipment selection only. No file IO, level/forge/resource setters or
-- direct writes to backpack arrays. The owner retries apply while it waits for
-- native asynchronous weapon configs, then starts capture/persistence.
local Loadout = {}
local SUBSYSTEMS = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local BACKPACK = "/Script/ProjectPBZ.PBZBackPackSubsystem"
local WEAPONS = "/Script/SGameCombatSystem.CharacterWeaponsComponent"
local KISMET = "/Script/Engine.Default__KismetSystemLibrary"
local GROUPS = {
    { name = "mainWeapons", array = "MainWeapons", map = "MainWeaponInfos", count = 2, tag = "Weapon.Slot.Main" },
    { name = "shadowWeapons", array = "ShaqiWeapons", map = "ShaqiWeaponInfos", count = 2, tag = "Weapon.Slot.ShaChi" },
    { name = "accessories", array = "AssemblyAccessory", map = "Accessories", count = 6 },
    { name = "medicines", map = "MedicineInfos", count = 2 },
}
local function valid(value) return value ~= nil and type(value.IsValid) == "function" and value:IsValid() end
local function unwrap(value)
    if value and (type(value) == "table" or type(value) == "userdata") and type(value.IsValid) ~= "function" then
        local getter = value.get or value.Get
        if type(getter) == "function" then return getter(value) end
    end
    return value
end
local function text(value)
    value = unwrap(value)
    if type(value) == "string" then return value end
    if value and type(value.ToString) == "function" then return value:ToString() end
    return ""
end
local function id(value)
    local result = text(value)
    return result ~= "" and result:lower() ~= "none" and result or false
end
local function owned(map, weapons)
    assert(map and type(map.ForEach) == "function", "waiting:inventory map unavailable")
    local result = {}
    map:ForEach(function(key, value)
        local item = id(key)
        if item then
            value = unwrap(value)
            result[item] = { forged = weapons and value and value.bAlreadySnapSoul == true or false }
        end
    end)
    return result
end
local function read(pawn)
    assert(valid(pawn), "waiting:arena pawn unavailable")
    local subsystems, class = StaticFindObject(SUBSYSTEMS), StaticFindObject(BACKPACK)
    assert(valid(subsystems) and valid(class), "waiting:backpack interface unavailable")
    local bp = subsystems:GetWorldSubsystem(pawn, class)
    assert(valid(bp), "waiting:world backpack unavailable")
    local snapshot, inventory = { version = 1 }, {}
    for _, group in ipairs(GROUPS) do
        snapshot[group.name], inventory[group.name] = {}, owned(bp[group.map], group.tag ~= nil)
        local array = group.array and bp[group.array]
        local length = array and #array or 0
        if group.array then assert(array and length <= group.count, "waiting:equipped array unavailable") end
        for index = 1, group.count do
            snapshot[group.name][index] = group.name == "medicines" and id(bp:GetMedicineByIndex(index == 1 and 1 or 0))
                or index <= length and id(array[index]) or false
            local item = snapshot[group.name][index]
            assert(not item or inventory[group.name][item], "waiting:equipped item inventory not ready")
        end
    end
    assert(next(inventory.mainWeapons), "waiting:main weapon inventory not ready")
    return bp, snapshot, inventory
end
local function validate(snapshot)
    assert(type(snapshot) == "table" and snapshot.version == 1, "invalid:unsupported loadout version")
    local allowed = { version = true }
    for _, group in ipairs(GROUPS) do
        allowed[group.name] = true
        local slots, seen = snapshot[group.name], {}
        assert(type(slots) == "table" and #slots == group.count, "invalid:loadout slot count " .. group.name)
        for key, value in pairs(slots) do
            assert(type(key) == "number" and key % 1 == 0 and key >= 1 and key <= group.count, "invalid:loadout slot key")
            assert(value == false or (type(value) == "string" and #value > 0 and #value <= 160
                and value:match("^[A-Za-z0-9_%-]+$") and value:lower() ~= "none"), "invalid:equipment ID")
            if value then assert(not seen[value], "invalid:duplicate equipment ID"); seen[value] = true end
        end
    end
    for key in pairs(snapshot) do assert(allowed[key], "invalid:loadout contains non-selection fields") end
    assert(snapshot.mainWeapons[1] or snapshot.mainWeapons[2], "invalid:at least one main weapon is required")
end
local function path(value)
    if value == nil then return nil end
    local kismet = StaticFindObject(KISMET)
    assert(valid(kismet), "waiting:weapon config path interface unavailable")
    local result = text(kismet:Conv_SoftObjectReferenceToString(value))
    return result ~= "" and result ~= "None" and result or nil
end
local function configPath(bp, group, item, info)
    if info.forged then
        local row = group.name == "mainWeapons" and bp:GetMainWeaponTableData(FName(item)) or bp:GetShaqiWeaponTableData(FName(item))
        local snap = group.name == "mainWeapons" and row.WeaponSnapSoulData or row.ShaChiWeaponSnapSoulData
        local upgraded = snap and path(snap.WeaponConfig)
        if upgraded then return upgraded end
    end
    -- Re-read the table row after any path-conversion native call rather than
    -- retaining an out-struct view across another native call.
    local row = group.name == "mainWeapons" and bp:GetMainWeaponTableData(FName(item)) or bp:GetShaqiWeaponTableData(FName(item))
    return path(row.WeaponConfig)
end
local function configurationsReady(pawn, bp, snapshot, inventory)
    local class = StaticFindObject(WEAPONS)
    assert(valid(class), "waiting:weapon component class unavailable")
    local component = pawn:GetComponentByClass(class)
    assert(valid(component), "waiting:weapon component unavailable")
    for groupIndex = 1, 2 do
        local group = GROUPS[groupIndex]
        for index = 1, group.count do
            local item = snapshot[group.name][index]
            if item then
                -- Exactly the original TsHelper.getMainWeaponData out-struct
                -- path. GetSlotWeapon reads current committed slot data, not a
                -- speculative pending config. Copy the config object first.
                local out = {}
                local found = component:GetSlotWeapon({ TagName = FName(group.tag) }, index - 1, out)
                local config = unwrap(out.WeaponConfig)
                assert(found == true and valid(config), "waiting:weapon config " .. group.name .. ":" .. index)
                local actual = config:GetFullName():match("^[^ ]+ (.+)$")
                local expected = configPath(bp, group, item, inventory[group.name][item])
                assert(expected and actual == expected, "waiting:weapon config commit " .. group.name .. ":" .. index)
            end
        end
    end
end
local function somewhere(slots, item, except)
    for index = 1, #slots do if index ~= except and slots[index] == item then return index end end
end
local function preflight(bp, snapshot, inventory)
    local capacity = bp:GetCanAssembleAccessoryNum()
    assert(type(capacity) == "number" and capacity >= 0 and capacity <= 6, "waiting:accessory slot capacity unavailable")
    for _, group in ipairs(GROUPS) do
        for index = 1, group.count do
            local item = snapshot[group.name][index]
            assert(not item or inventory[group.name][item], "unavailable:missing " .. group.name .. ":" .. tostring(item))
            assert(group.name ~= "accessories" or not item or index <= capacity, "unavailable:accessory slot locked")
        end
    end
end
local function perform(bp, current, wanted)
    for _, group in ipairs(GROUPS) do
        local from, to = current[group.name], wanted[group.name]
        local order = {}
        -- Fill/move every required main slot before clearing unwanted ones.
        -- Otherwise {X,false}->{false,Y} would remove the last main weapon and
        -- strand the following readiness check on an empty initial loadout.
        if group.name == "mainWeapons" then
            for index = 1, group.count do if to[index] then order[#order + 1] = index end end
            for index = 1, group.count do if not to[index] then order[#order + 1] = index end end
        else for index = 1, group.count do order[#order + 1] = index end end
        for _, index in ipairs(order) do
            local item, previous = to[index], from[index]
            if item ~= previous then
                local other = item and somewhere(from, item, index)
                if group.name == "mainWeapons" then
                    -- Native main Replace swaps two occupied slots. With an
                    -- empty target, its contains guard needs a native removal
                    -- first; remove+equip stays in this one game-thread call.
                    if item then
                        if other and not previous then bp:RemoveWeaponByID(FName(item), true) end
                        bp:ReplaceWeaponByIndex(FName(item), index - 1)
                    else bp:RemoveWeaponByID(FName(previous), true) end
                elseif group.name == "shadowWeapons" then
                    if other then bp:RemoveWeaponByID(FName(item), false)
                    elseif item then bp:ReplaceShaChiWeaponByIndex(FName(item), index - 1)
                    else bp:RemoveWeaponByID(FName(previous), false) end
                elseif group.name == "accessories" then
                    if other then bp:TakeOffAccessory(other - 1)
                    elseif item then bp:AssembleAccessory(FName(item), index - 1)
                    else bp:TakeOffAccessory(index - 1) end
                else
                    local nativeIndex = index == 1 and 1 or 0
                    if other then bp:TakeOffMedicineByIndex(other == 1 and 1 or 0)
                    elseif item then bp:ReplaceMedicineByIndex(nativeIndex, FName(item), false)
                    else bp:TakeOffMedicineByIndex(nativeIndex) end
                end
                return false, "waiting:native equip commit " .. group.name .. ":" .. index
            end
        end
    end
    return true
end

function Loadout.capture(pawn)
    local ok, result = pcall(function()
        local bp, snapshot, inventory = read(pawn)
        validate(snapshot)
        configurationsReady(pawn, bp, snapshot, inventory)
        return snapshot
    end)
    if ok then return result end
    return nil, tostring(result)
end
function Loadout.apply(pawn, snapshot)
    local ok, result, reason = pcall(function()
        validate(snapshot)
        local bp, current, inventory = read(pawn)
        preflight(bp, snapshot, inventory)
        assert(current.mainWeapons[1] or current.mainWeapons[2], "waiting:initial main weapon slots not ready")
        -- Native equip/config delivery is asynchronous. Wait for the existing
        -- preset/previous operation to commit before issuing another mutation.
        configurationsReady(pawn, bp, current, inventory)
        local complete, wait = perform(bp, current, snapshot)
        if not complete then return false, wait end
        configurationsReady(pawn, bp, snapshot, inventory)
        return true
    end)
    if ok then return result, reason end
    return false, tostring(result)
end

return Loadout
