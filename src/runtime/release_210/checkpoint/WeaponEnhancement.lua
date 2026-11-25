local Enhancement, Session = {}, {}
Session.__index = Session

local SUBSYSTEMS = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local BACKPACK = "/Script/ProjectPBZ.PBZBackPackSubsystem"
local MAIN_DATA = BACKPACK .. ":GetMainWeaponTableData"
local SHACHI_DATA = BACKPACK .. ":GetShaqiWeaponTableData"
local MAX_LEVEL = BACKPACK .. ":GetWeaponMaxLevel"
local UPGRADE = BACKPACK .. ":UpgradeWeapon"
local hooks, active = {}, nil

local function address(object)
    return object and object:IsValid() and object:GetAddress() or nil
end

local function scoped(context)
    local session = active
    if session and address(context:get()) == session.backpackAddress and address(session.pawn) == session.pawnAddress
        and (not session.widget or address(session.widget) == session.widgetAddress) then
        return session
    end
end

local function keepFailure(session, reason)
    if session.failure then return end
    session.failure = "武器免费强化接口异常：" .. tostring(reason)
    print("[PBZTestArenaNative] " .. session.failure .. "\n")
end

local function zeroCosts(field, isMain)
    return function(context, result, id)
        local session = scoped(context)
        if not session or session.failure then return end
        local ok, reason = pcall(function()
            local weapon = id:get()
            local level = session.backpack:GetWeaponLevel(weapon, isMain)
            if type(level) ~= "number" or level < 1 or (level >= session.cap and not session.probe) then return end

            -- These getters return a copy. The ordinary cost cache and the
            -- multi-level quote both read that copy, including during commit.
            local row = result:get()
            local levels = row[field]
            for index = level, math.min(#levels, session.cap - 1) do
                local cost = levels[index]
                cost.Materials:Empty()
                cost.ConsumeDust = 0
                assert(cost.ConsumeDust == 0 and #cost.Materials == 0, "武器强化费用回读失败")
            end
            if session.probe then session.probe[field] = true end
        end)
        if not ok then keepFailure(session, reason) end
    end
end

local function limit(context, result)
    local session = scoped(context)
    if not session then return end
    local nativeCap = result:get()
    if type(nativeCap) == "number" then
        if session.probe then session.probe.cap = true end
        return math.min(nativeCap, session.failure and 1 or session.cap)
    end
end

local function clampUpgrade(context, id, isMain, increment)
    local session = scoped(context)
    if not session then return end
    local ok, reason = pcall(function()
        local level = session.backpack:GetWeaponLevel(id:get(), isMain:get())
        local requested = increment:get()
        if not session.failure and type(level) == "number" and level >= 1 and level < session.cap
            and type(requested) == "number" and requested > 0 then
            local allowed = session.cap - level
            if requested > allowed then increment:set(allowed) end
            return
        end
        id:set(FName("None"))
        increment:set(0)
    end)
    if not ok then
        id:set(FName("None"))
        increment:set(0)
        keepFailure(session, reason)
    end
end

local function install(path, pre, post)
    if hooks[path] then return end
    assert(address(StaticFindObject(path)), "原生武器强化接口未加载：" .. path)
    local first, last = RegisterHook(path, pre, post)
    assert(first and last, "原生武器强化回调未安装：" .. path)
    hooks[path] = true
end

local function verify(session, map, dataGetter, field, isMain)
    local backpack = session.backpack
    local ids = {}
    backpack[map]:ForEach(function(key)
        if type(key) == "userdata" or type(key) == "table" then
            local getter = key.get or key.Get
            if type(getter) == "function" then key = getter(key) end
        end
        if (type(key) == "userdata" or type(key) == "table") and type(key.ToString) == "function" then
            key = key:ToString()
        end
        if type(key) == "string" and key ~= "" and key:lower() ~= "none" then ids[#ids + 1] = key end
    end)
    -- UE4SS uses true to stop the traversal and nil to continue.
    -- Select the sample after iteration so reflected weapon calls run outside it.
    local sample
    for _, id in ipairs(ids) do
        local weapon = FName(id)
        local level = backpack:GetWeaponLevel(weapon, isMain)
        if type(level) == "number" and level >= 1 then
            sample = weapon
            if level < session.cap then break end
        end
    end
    if not sample then return end
    session.probe.cap = nil
    backpack[dataGetter](backpack, sample)
    local effectiveCap = backpack:GetWeaponMaxLevel(sample, isMain)
    assert(not session.failure, session.failure)
    assert(session.probe[field] and session.probe.cap and effectiveCap <= session.cap, "武器强化回调未生效")
end

function Enhancement.prepare(pawn, cap)
    local session
    local ok, result = pcall(function()
        assert(type(cap) == "number" and cap >= 0 and cap <= 60 and cap % 1 == 0, "武器强化上限无效")
        local pawnAddress = address(pawn)
        assert(pawnAddress, "玩家角色未就绪")
        assert(not active, "装备调整界面已经打开")
        local library, class = StaticFindObject(SUBSYSTEMS), StaticFindObject(BACKPACK)
        assert(address(library) and address(class), "武器强化背包接口未就绪")
        local backpack = library:GetWorldSubsystem(pawn, class)
        local backpackAddress = address(backpack)
        assert(backpackAddress, "武器强化背包未就绪")

        local function noop() end
        install(MAIN_DATA, noop, zeroCosts("WeaponUpLevelDatas", true))
        install(SHACHI_DATA, noop, zeroCosts("ShaChiWeaponUpLevelData", false))
        install(MAX_LEVEL, noop, limit)
        install(UPGRADE, clampUpgrade)

        session = setmetatable({ pawn = pawn, pawnAddress = pawnAddress, backpack = backpack,
            backpackAddress = backpackAddress, cap = math.max(1, cap), probe = {} }, Session)
        active = session
        verify(session, "MainWeaponInfos", "GetMainWeaponTableData", "WeaponUpLevelDatas", true)
        verify(session, "ShaqiWeaponInfos", "GetShaqiWeaponTableData", "ShaChiWeaponUpLevelData", false)
        assert(session.probe.WeaponUpLevelDatas or session.probe.ShaChiWeaponUpLevelData, "武器强化背包未就绪")
        session.probe = nil
        return session
    end)
    if ok then return result end
    if session then session:close() end
    return nil, tostring(result)
end

function Session:attach(widget)
    local widgetAddress = address(widget)
    if active ~= self or not widgetAddress then return false, "装备调整界面未就绪" end
    if self.failure then return false, self.failure end
    if self.widgetAddress and self.widgetAddress ~= widgetAddress then
        return false, "装备调整界面已经绑定"
    end
    local owner = widget:GetOwningPlayer()
    if not address(owner) or address(owner.Pawn) ~= self.pawnAddress then
        return false, "装备调整界面与当前角色不匹配"
    end
    self.widget, self.widgetAddress = widget, widgetAddress
    return true
end

function Session:close()
    if active == self then active = nil end
    self.widget, self.pawn, self.backpack = nil, nil, nil
end

return Enhancement
