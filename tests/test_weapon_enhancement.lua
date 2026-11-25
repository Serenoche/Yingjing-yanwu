-- Run with the staged 2.1.0 checkpoint Scripts directory on package.path.
local SUBSYSTEM_LIBRARY = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local BACKPACK_CLASS = "/Script/ProjectPBZ.PBZBackPackSubsystem"
local MAIN_LEVELS, SHADOW_LEVELS = "WeaponUpLevelDatas", "ShaChiWeaponUpLevelData"

local function object(address)
    return {
        IsValid = function() return true end,
        GetAddress = function() return address end,
    }
end

local function name(value)
    return { ToString = function() return value end }
end

local function parameter(value)
    return {
        get = function() return value end,
        set = function(_, nextValue) value = nextValue end,
    }
end

local function weaponRow(field)
    local levels = {}
    for index = 1, 6 do
        local materials = { { id = "M1", quantity = 2 } }
        function materials:Empty() self[1] = nil end
        levels[index] = { ConsumeDust = 50, Materials = materials }
    end
    return { [field] = levels }
end

local function fixture(mainLevel, shadowLevel, skippedHook)
    local bindings, visitingInventory, nextHook = {}, false, 0
    local calls = { main = 0, shadow = 0, caps = 0 }
    local levels = { main = mainLevel, mainOther = mainLevel, shadow = shadowLevel, ModMissing = 0 }
    local pawn, backpack = object(1), object(2)
    local controller, otherController = object(3), object(4)
    controller.Pawn, otherController.Pawn = pawn, object(5)
    local widget, otherWidget = object(6), object(7)
    function widget:GetOwningPlayer() return controller end
    function otherWidget:GetOwningPlayer() return otherController end

    local function assertOutsideInventory()
        assert(not visitingInventory, "reflected call inside inventory iteration")
    end

    local function map(keys)
        return { ForEach = function(_, callback)
            visitingInventory = true
            for index, key in ipairs(keys) do
                local stop = callback(key)
                if stop then break end
                -- A false callback result can invalidate the next call in UE4SS.
                assert(stop ~= false or index == #keys, "inventory callback returned false before its final entry")
            end
            visitingInventory = false
        end }
    end

    backpack.MainWeaponInfos = map({ name("None"), name("ModMissing"), name("main"), parameter(name("mainOther")) })
    backpack.ShaqiWeaponInfos = map({ "", { Get = function() return name("shadow") end } })

    function backpack:GetWeaponLevel(weapon, isMain)
        assertOutsideInventory()
        local id = weapon:ToString()
        assert((id == "shadow") ~= isMain)
        return assert(levels[id], id)
    end

    local function data(weapon, isMain)
        assertOutsideInventory()
        local family = isMain and "main" or "shadow"
        local method = isMain and "GetMainWeaponTableData" or "GetShaqiWeaponTableData"
        calls[family] = calls[family] + 1
        local result = weaponRow(isMain and MAIN_LEVELS or SHADOW_LEVELS)
        if skippedHook ~= method then bindings[method].post(parameter(backpack), parameter(result), parameter(weapon)) end
        return result
    end

    function backpack:GetMainWeaponTableData(weapon) return data(weapon, true) end
    function backpack:GetShaqiWeaponTableData(weapon) return data(weapon, false) end
    function backpack:GetWeaponMaxLevel(_, isMain)
        assertOutsideInventory()
        calls.caps = calls.caps + 1
        local nativeCap = isMain and 8 or 4
        if skippedHook == "shadowCap" and not isMain then return nativeCap end
        return bindings.GetWeaponMaxLevel.post(parameter(self), parameter(nativeCap)) or nativeCap
    end

    function backpack:UpgradeWeapon(weapon, isMain, increment)
        assertOutsideInventory()
        local id, count = parameter(weapon), parameter(increment)
        bindings.UpgradeWeapon.pre(parameter(self), id, parameter(isMain), count)
        local item, amount = id:get():ToString(), count:get()
        if item ~= "None" then levels[item] = levels[item] + amount end
        return item, amount
    end

    function RegisterHook(path, pre, post)
        local method = assert(path:match(":(%w+)$"))
        assert(not bindings[method])
        bindings[method] = { pre = pre, post = post }
        nextHook = nextHook + 2
        return nextHook - 1, nextHook
    end

    function StaticFindObject(path)
        local result = object(8)
        if path == SUBSYSTEM_LIBRARY then
            function result:GetWorldSubsystem(actualPawn, class)
                assertOutsideInventory()
                assert(actualPawn == pawn and class:IsValid())
                return backpack
            end
        else
            assert(path == BACKPACK_CLASS or path:sub(1, #BACKPACK_CLASS + 1) == BACKPACK_CLASS .. ":")
        end
        return result
    end

    function FName(value)
        assertOutsideInventory()
        return name(value)
    end

    package.loaded.WeaponEnhancement = nil
    return require("WeaponEnhancement"), pawn, backpack, widget, otherWidget, calls, bindings
end

local enhancement, pawn, backpack, widget, otherWidget, calls, bindings = fixture(4, 4)
local atCap = assert(enhancement.prepare(pawn, 4))
assert(calls.main == 1 and calls.shadow == 1 and calls.caps == 2)
assert(backpack:GetMainWeaponTableData(FName("main"))[MAIN_LEVELS][4].ConsumeDust == 50)
atCap:close()

enhancement, pawn, backpack, widget, otherWidget, calls, bindings = fixture(2, 3)
local session = assert(enhancement.prepare(pawn, 4))
assert(calls.main == 1 and calls.shadow == 1 and calls.caps == 2)
assert(not session:attach(otherWidget))
assert(session:attach(widget))
assert(not session:attach(otherWidget))

local main = backpack:GetMainWeaponTableData(FName("main"))[MAIN_LEVELS]
assert(main[1].ConsumeDust == 50 and #main[1].Materials == 1)
for level = 2, 3 do assert(main[level].ConsumeDust == 0 and #main[level].Materials == 0) end
assert(main[4].ConsumeDust == 50 and #main[4].Materials == 1)
local shadow = backpack:GetShaqiWeaponTableData(FName("shadow"))[SHADOW_LEVELS]
assert(shadow[3].ConsumeDust == 0 and #shadow[3].Materials == 0)
assert(shadow[4].ConsumeDust == 50 and #shadow[4].Materials == 1)
assert(backpack:GetWeaponMaxLevel(FName("main"), true) == 4)
assert(backpack:GetWeaponMaxLevel(FName("shadow"), false) == 4)

local foreign = parameter(object(9))
assert(bindings.GetWeaponMaxLevel.post(foreign, parameter(8)) == nil)
local foreignRow = weaponRow(MAIN_LEVELS)
bindings.GetMainWeaponTableData.post(foreign, parameter(foreignRow), parameter(FName("main")))
assert(foreignRow[MAIN_LEVELS][2].ConsumeDust == 50)

local item, count = backpack:UpgradeWeapon(FName("main"), true, 5)
assert(item == "main" and count == 2 and backpack:GetWeaponLevel(FName("main"), true) == 4)
item, count = backpack:UpgradeWeapon(FName("main"), true, 1)
assert(item == "None" and count == 0 and backpack:GetWeaponLevel(FName("main"), true) == 4)
item, count = backpack:UpgradeWeapon(FName("shadow"), false, 2)
assert(item == "shadow" and count == 1 and backpack:GetWeaponLevel(FName("shadow"), false) == 4)

session:close()
assert(backpack:GetWeaponMaxLevel(FName("main"), true) == 8)
assert(backpack:GetMainWeaponTableData(FName("main"))[MAIN_LEVELS][4].ConsumeDust == 50)
item, count = backpack:UpgradeWeapon(FName("main"), true, 1)
assert(item == "main" and count == 1)

for _, skippedHook in ipairs({ "GetMainWeaponTableData", "GetShaqiWeaponTableData", "shadowCap" }) do
    enhancement, pawn = fixture(4, 4, skippedHook)
    local refused, reason = enhancement.prepare(pawn, 4)
    assert(not refused and reason:find("武器强化回调未生效", 1, true), reason)
end

print("武器强化回归通过：背包读取、零消耗、等级上限、原生提交和菜单作用域。")
