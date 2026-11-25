local WeaponSoul = {}
local KISMET = "/Script/Engine.Default__KismetSystemLibrary"
local WEAPON_COMPONENT = "/Script/SGameCombatSystem.CharacterWeaponsComponent"
local MAIN = {
    inventory = "MainWeaponInfos", slots = "MainWeapons", data = "GetMainWeaponTableData",
    soul = "WeaponSnapSoulData", level = "WeaponLevel", index = "GetCurrentMainWeaponIndex",
    equip = "ReplaceWeaponByIndex", tag = "Weapon.Slot.Main",
}
local SHADOW = {
    inventory = "ShaqiWeaponInfos", slots = "ShaqiWeapons", data = "GetShaqiWeaponTableData",
    soul = "ShaChiWeaponSnapSoulData", level = "ShaChiWeaponLevel", index = "GetCurrentShaqiWeaponIndex",
    equip = "ReplaceShaChiWeaponByIndex", tag = "Weapon.Slot.ShaChi",
}

local function valid(object)
    return object ~= nil and type(object.IsValid) == "function" and object:IsValid()
end

local function unwrap(object)
    local kind = type(object)
    if (kind == "table" or kind == "userdata") and type(object.IsValid) ~= "function" then
        local getter = object.get or object.Get
        if type(getter) == "function" then return getter(object) end
    end
    return object
end

local function text(value)
    value = unwrap(value)
    if type(value) == "string" then return value end
    return value and type(value.ToString) == "function" and value:ToString() or ""
end

local function path(kismet, reference)
    if not reference then return nil end
    local result = text(kismet:Conv_SoftObjectReferenceToString(reference))
    return result ~= "" and result:lower() ~= "none" and result or nil
end

local function hasEntries(array)
    return array ~= nil and #array > 0
end

local function hasName(value)
    local name = text(value)
    return name ~= "" and name:lower() ~= "none"
end

local function inspect(backpack, weaponID, isMain)
    if not valid(backpack) or type(isMain) ~= "boolean" then return nil, "武器资料暂不可用" end
    local id = text(weaponID)
    if id == "" or id:lower() == "none" then return nil, "请先选中武器" end
    local group = isMain and MAIN or SHADOW
    local name = FName(id)
    local info = unwrap(backpack[group.inventory]:Find(name))
    if not valid(info) or type(info.bAlreadySnapSoul) ~= "boolean" then return nil, "未找到武器拥有记录" end

    local kismet = StaticFindObject(KISMET)
    assert(valid(kismet), "武器资源接口暂不可用")
    local row = backpack[group.data](backpack, name)
    local soul = row and row[group.soul]
    if not soul then return nil, "这把武器没有铸魂形态" end

    -- Material requirements and text IDs alone can be placeholder data. Soul
    -- effects can also be authored without a replacement weapon configuration.
    local hasEffects = hasEntries(soul.GameplayEffectDatas) or hasEntries(soul.PersistentGEDatas)
        or hasEntries(soul.EPMTagsOnSnapSoul) or hasEntries(row.SnapSoulUIAttributeDatas)
    if not isMain and not hasEffects and soul.BrokenBlockerTagAfterSnapSoul then
        hasEffects = hasName(soul.BrokenBlockerTagAfterSnapSoul.TagName)
    end
    local forgedPath = path(kismet, soul.WeaponConfig)
    -- Both reflections return borrowed views. Read the base row again after conversion.
    row = backpack[group.data](backpack, name)
    local basePath = row and path(kismet, row.WeaponConfig)
    local alternateConfig = forgedPath and (not basePath or forgedPath:lower() ~= basePath:lower())
    if not hasEffects and not alternateConfig then
        row = backpack[group.data](backpack, name)
        local effect = row and row.DefaultSnapSoulGEData
        if effect and effect.SoftClassPtr then
            hasEffects = hasName(kismet:Conv_SoftClassReferenceToString(effect.SoftClassPtr))
        end
    end
    if not hasEffects and not alternateConfig then return nil, "这把武器没有铸魂形态" end
    return { id = id:lower(), name = name, group = group, info = info, basePath = basePath,
        forgedPath = forgedPath or basePath, forged = info.bAlreadySnapSoul, level = info[group.level] }
end

local function slotID(backpack, group, index)
    local slots = backpack[group.slots]
    return index >= 0 and index < #slots and text(slots[index + 1]):lower() or ""
end

local function equippedSlot(backpack, weapon)
    local group = weapon.group
    local slots = backpack[group.slots]
    for index = 1, #slots do
        if text(slots[index]):lower() == weapon.id then return index - 1 end
    end
end

local function configReady(pawn, weapon, slot)
    local class = StaticFindObject(WEAPON_COMPONENT)
    if not valid(pawn) or not valid(class) then return false end
    local component = pawn:GetComponentByClass(class)
    if not valid(component) then return false end
    local data = {}
    local found = component:GetSlotWeapon({ TagName = FName(weapon.group.tag) }, slot, data)
    local config = unwrap(data.WeaponConfig)
    if found ~= true or not valid(config) then return false end
    local expected = weapon.forged and weapon.forgedPath or weapon.basePath
    local actual = config:GetFullName():match("^[^ ]+ (.+)$")
    return actual ~= nil and expected ~= nil and actual:lower() == expected:lower()
end

local function restoreActiveIndex(backpack, group, isMain, index)
    if backpack[group.index](backpack) ~= index then backpack:SetCurrentWeaponByIndex(index, isMain) end
end

local function reequip(backpack, weapon, slot, isMain, forged)
    local group = weapon.group
    local activeIndex = backpack[group.index](backpack)
    local ok, failure = pcall(function()
        -- Identical-ID replacement is ignored by both native slot setters.
        -- Unregister the old weapon before changing its soul-dependent effects.
        backpack:RemoveWeaponByID(weapon.name, isMain)
        assert(slotID(backpack, group, slot) ~= weapon.id, "武器暂不能卸下")
        weapon.info.bAlreadySnapSoul = forged
        assert(weapon.info.bAlreadySnapSoul == forged, "铸魂状态写入失败")
        backpack[group.equip](backpack, weapon.name, slot)
        assert(slotID(backpack, group, slot) == weapon.id, "武器暂不能重新装备")
        restoreActiveIndex(backpack, group, isMain, activeIndex)
    end)
    if not ok then
        local restored = pcall(function()
            if slotID(backpack, group, slot) == weapon.id and weapon.info.bAlreadySnapSoul ~= weapon.forged then
                backpack:RemoveWeaponByID(weapon.name, isMain)
            end
            weapon.info.bAlreadySnapSoul = weapon.forged
            if slotID(backpack, group, slot) ~= weapon.id then backpack[group.equip](backpack, weapon.name, slot) end
            assert(slotID(backpack, group, slot) == weapon.id)
            restoreActiveIndex(backpack, group, isMain, activeIndex)
        end)
        if not restored then error("当前武器装备恢复失败", 0) end
        error(failure, 0)
    end
end

function WeaponSoul.status(backpack, weaponID, isMain)
    local ok, result, reason = pcall(inspect, backpack, weaponID, isMain)
    if not ok then return nil, tostring(result) end
    if not result then return nil, reason end
    return result.forged, nil, result.level
end

function WeaponSoul.toggle(backpack, weaponID, isMain, pawn)
    local ok, success, result = pcall(function()
        local weapon, reason = inspect(backpack, weaponID, isMain)
        if not weapon then return false, reason end
        local forged = not weapon.forged
        local slot = equippedSlot(backpack, weapon)
        if slot ~= nil then
            if backpack:IsWeaponLocked(weapon.name, isMain) then return false, "当前武器处于锁定状态" end
            if not configReady(pawn, weapon, slot) then return false, "武器正在切换，请稍后重试" end
            local targetPath = forged and weapon.forgedPath or weapon.basePath
            if not targetPath then return false, "目标铸魂形态不可用" end
            if not valid(StaticFindObject(targetPath)) then LoadAsset(targetPath) end
            if not valid(StaticFindObject(targetPath)) then return false, "目标武器资源加载失败" end
            reequip(backpack, weapon, slot, isMain, forged)
        else
            weapon.info.bAlreadySnapSoul = forged
            assert(weapon.info.bAlreadySnapSoul == forged, "铸魂状态写入失败")
        end
        return true, forged
    end)
    if not ok then return false, tostring(success) end
    return success, result
end

return WeaponSoul
