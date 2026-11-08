-- Copy the actual equipped set at combat start. The result contains only plain
-- Lua strings/numbers/booleans/tables and remains valid after world replacement.
local Loadout = {}
local Art = require("ArtAssets")
local SUBSYSTEMS = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local BACKPACK = "/Script/ProjectPBZ.PBZBackPackSubsystem"
local BACKPACK_CDO = "/Script/ProjectPBZ.Default__PBZBackPackSubsystem"
local LIBRARY = "/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary"

local function valid(value)
    return value ~= nil and type(value.IsValid) == "function" and value:IsValid()
end
local function unwrap(value)
    local kind = type(value)
    if value and (kind == "table" or kind == "userdata") and type(value.IsValid) ~= "function" then
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
local function field(value, name)
    if not value then return nil end
    local ok, result = pcall(function() return value[name] end)
    if ok then return unwrap(result) end
    return nil
end
local function number(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge and value or nil
end
local function lookup(map)
    local result = {}
    if map and type(map.ForEach) == "function" then
        map:ForEach(function(key, parameter)
            local id, value = text(key), unwrap(parameter)
            if id ~= "" and id ~= "None" then
                result[id] = {
                    level = number(field(value, "WeaponLevel")) or number(field(value, "ShaChiWeaponLevel"))
                        or number(field(value, "CurrentLevel")),
                    forged = field(value, "bAlreadySnapSoul"),
                }
            end
        end)
    end
    return result
end
local function key(value)
    return text(field(value, "Key"))
end
local function localized(library, textKey, fallback)
    if textKey ~= "" and valid(library) then
        local ok, result = pcall(function() return text(library:MakeTextByKey(textKey)) end)
        if ok and result ~= "" then return result end
    end
    return fallback
end
local function empty(kind)
    return { kind = kind, id = nil, name = "未装备", level = nil, forged = false, iconPath = nil, empty = true }
end

function Loadout.capture(pawn)
    local result = { version = 1, mainWeapons = {}, shadowWeapons = {}, accessories = {}, medicines = {}, errors = {} }
    local groups = {
        { name = "mainWeapons", kind = "main", count = 2, source = "MainWeapons", info = "MainWeaponInfos" },
        { name = "shadowWeapons", kind = "shadow", count = 2, source = "ShaqiWeapons", info = "ShaqiWeaponInfos" },
        { name = "accessories", kind = "accessory", count = 6, source = "AssemblyAccessory", info = "Accessories" },
        { name = "medicines", kind = "medicine", count = 2, info = "MedicineInfos" },
    }
    for _, group in ipairs(groups) do
        for index = 1, group.count do result[group.name][index] = empty(group.kind) end
    end
    local ok, failure = pcall(function()
        assert(valid(pawn), "当前挑战角色不可用")
        local subsystems, class = StaticFindObject(SUBSYSTEMS), StaticFindObject(BACKPACK)
        assert(valid(subsystems) and valid(class), "当前世界背包接口不可用")
        local bp = subsystems:GetWorldSubsystem(pawn, class)
        assert(valid(bp), "当前世界背包尚未初始化")
        local defaults, library = StaticFindObject(BACKPACK_CDO), StaticFindObject(LIBRARY)
        for _, group in ipairs(groups) do
            local mapOk, infos = pcall(lookup, field(bp, group.info))
            if not mapOk then
                result.errors[#result.errors + 1] = group.name .. ": " .. tostring(infos)
                infos = {}
            end
            local array = group.source and field(bp, group.source)
            for index = 1, group.count do
                local itemOk, itemFailure = pcall(function()
                    local id
                    if group.kind == "medicine" then
                        id = text(bp:GetMedicineByIndex(index == 1 and 1 or 0)) -- Top then Bottom.
                    elseif array then
                        -- UE4SS LuaTArray indexes are one-based, unlike native TArray.
                        local countOk, count = pcall(function() return #array end)
                        if countOk and index <= count then id = text(array[index]) end
                    end
                    if not id or id == "" or id == "None" then return end
                    local owned = infos[id] or {}
                    local item = { kind = group.kind, id = id, name = id, level = owned.level,
                        forged = false, empty = false }
                    if group.kind == "main" or group.kind == "shadow" then
                        item.forged = nil
                        if type(owned.forged) == "boolean" then item.forged = owned.forged end
                    end
                    result[group.name][index] = item
                    local row, nameKey
                    if group.kind == "main" or group.kind == "shadow" then
                        row = group.kind == "main" and bp:GetMainWeaponTableData(FName(id)) or bp:GetShaqiWeaponTableData(FName(id))
                        nameKey = key(field(row, "WeaponName"))
                        if item.forged then
                            local snap = field(row, group.kind == "main" and "WeaponSnapSoulData" or "ShaChiWeaponSnapSoulData")
                            local snapId = text(field(snap, "SnapSoulTextID"))
                            local snapKey = key(field(snap, "WeaponSnapSoulName"))
                            if snapId ~= "" and snapId ~= "None" then
                                local snapOk, nameRow = pcall(function() return bp:GetSnapSoulTextData(FName(snapId)) end)
                                if snapOk and key(field(nameRow, "SnapSoulName")) ~= "" then
                                    snapKey = key(field(nameRow, "SnapSoulName"))
                                end
                            end
                            if snapKey ~= "" then nameKey = snapKey end
                        end
                    elseif group.kind == "accessory" and valid(defaults) then
                        row = defaults:GetAccessoryData(FName(id)); nameKey = key(field(row, "AccessoryName"))
                    elseif group.kind == "medicine" and valid(defaults) then
                        row = defaults:GetMedicineData(FName(id)); nameKey = key(field(row, "Name"))
                        local levels = field(row, "MedicineLevelData")
                        if levels and item.level and item.level >= 1 then
                            local levelOk, level = pcall(function() return levels[item.level] end)
                            if levelOk and key(field(level, "MedicineName")) ~= "" then nameKey = key(field(level, "MedicineName")) end
                        end
                    end
                    item.name = localized(library, nameKey or "", id)
                    local path, meta = Art.equipmentPath(pawn, group.kind, id, item.level, item)
                    item.iconPath = path
                    if not path and meta and meta.reason then item.iconError = meta.reason end
                    if not owned.level then item.levelError = "拥有记录等级未读到" end
                    result[group.name][index] = item
                end)
                if not itemOk then
                    result.errors[#result.errors + 1] = group.name .. "[" .. index .. "]: " .. tostring(itemFailure)
                    result[group.name][index].unavailable = true
                end
            end
        end
    end)
    if not ok then
        result.available = false
        result.errors[#result.errors + 1] = tostring(failure)
    else
        result.available = true
    end
    return result
end

return Loadout
