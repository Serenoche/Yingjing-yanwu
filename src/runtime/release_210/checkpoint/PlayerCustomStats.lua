local Custom = require("PlayerCustom")
local Stats = {}

local EPSILON = .06
local RESOURCES = { Health_Max = "Health", Shachi_Max = "Shachi" }

local function numeric(value)
    return type(value) == "number" and value > -math.huge and value < math.huge
end

local function read(set, key)
    local data = assert(set[key], "玩家属性未就绪：" .. key)
    assert(numeric(data.BaseValue) and numeric(data.CurrentValue), "玩家属性读数无效：" .. key)
    return data.BaseValue, data.CurrentValue
end

local function setBase(pawn, set, setter, key, value)
    setter(pawn, key, value)
    local base, current = read(set, key)
    assert(math.abs(base - value) < EPSILON, "属性基值回读不符：" .. key)
    return base, current
end

local function setFinal(pawn, set, setter, key, original, current, target)
    if math.abs(target - current) < EPSILON then return end
    local base, configured = setBase(pawn, set, setter, key, original + target - current)
    if math.abs(configured - target) >= EPSILON then
        -- Accessory multipliers can change the response per point of base value.
        local slope = (configured - current) / (base - original)
        assert(numeric(slope) and slope > 0, "属性倍率回读无效：" .. key)
        local _, adjusted = setBase(pawn, set, setter, key, original + (target - current) / slope)
        configured = adjusted
    end
    assert(math.abs(configured - target) < EPSILON, "固定属性回读不符：" .. key)
end

function Stats.apply(pawn, config, cycle)
    local groups = Custom.groups(config)
    if groups == 0 then return end
    local set = pawn.AttributeSetBase
    assert(set and set:IsValid(), "正在等待角色属性")
    local setter = require("PracticeMode").setAttributeValue
    local changes = {}
    local ok, reason = pcall(function()
        for _, field in ipairs(Custom.sections[1].fields) do
            if (groups & field.group) ~= 0 then
                local key = field.attribute
                local base, current = read(set, key)
                local resource = RESOURCES[key]
                local beforeResource = resource and read(set, resource) or nil
                changes[#changes + 1] = { key = key, base = base, resource = resource, resourceBase = beforeResource }
                local fixed = config.values[field.id]
                if fixed ~= nil then
                    setFinal(pawn, set, setter, key, base, current, fixed)
                else
                    local _, levelOne = read(set, key .. "_Lv1")
                    assert(levelOne > 0, "角色初始属性未就绪：" .. key)
                    local addition = levelOne * Custom.rate(config, field.group, cycle) / 100
                    if addition ~= 0 then setBase(pawn, set, setter, key, base + addition) end
                end
            end
        end
        -- A new attempt starts with full resources. The existing cross-map
        -- carry restore follows this step and replaces these two current values.
        for _, change in ipairs(changes) do
            if change.resource then
                local _, maximum = read(set, change.key)
                assert(maximum > 0, "玩家资源上限无效：" .. change.key)
                setter(pawn, change.resource, maximum)
                local _, current = read(set, change.resource)
                assert(math.abs(current - maximum) < EPSILON, "玩家资源回读不符：" .. change.resource)
            end
        end
    end)
    if not ok then
        local failure
        for index = #changes, 1, -1 do
            local change = changes[index]
            local restored, errorMessage = pcall(function()
                setBase(pawn, set, setter, change.key, change.base)
                if change.resource then setter(pawn, change.resource, change.resourceBase) end
            end)
            if not restored then failure = errorMessage end
        end
        error(failure and (tostring(reason) .. " / 属性回滚失败 " .. tostring(failure)) or reason, 0)
    end
    local values = {}
    for _, field in ipairs(Custom.sections[1].fields) do
        local _, value = read(set, field.attribute)
        values[#values + 1] = field.attribute .. "=" .. ("%.2f"):format(value)
    end
    print("[PBZPlayerCustom] " .. table.concat(values, " ") .. "\n")
end

return Stats
