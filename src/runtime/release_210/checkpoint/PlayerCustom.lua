local Profile = require("PlayerProfile")
local Custom = {}

Custom.sections = {
    { id = "attributes", label = "属性", fields = {
        { id = "health", label = "生命上限", attribute = "Health_Max", min = 850, fast = 25, group = 4, talent = 17 },
        { id = "shachi", label = "杀气上限", attribute = "Shachi_Max", min = 400, fast = 10, group = 2, talent = 8 },
        { id = "attack", label = "攻击力", attribute = "Attack", min = 100, fast = 5, group = 1, talent = 2 },
        { id = "shachiAttack", label = "对敌杀气削减", attribute = "ShachiAttack", min = 100, fast = 5, group = 1, talent = 2 },
        { id = "infliction", label = "异常累积上限", attribute = "Infliction_Max", min = 1000, fast = 25, group = 4, talent = 0 },
    } },
    { id = "collection", label = "收集品", fields = {
        { id = "blackstone", label = "黑石", min = 0, fast = 5, group = 1 },
        { id = "amber", label = "杀气琥珀", min = 0, fast = 5, group = 2 },
        { id = "flowers", label = "记忆之花", min = 0, fast = 5, group = 4 },
        { id = "skill", label = "技能增幅", min = 0, fast = 5, skill = true },
    } },
    { id = "gear", label = "装备", fields = {
        { id = "weapon", label = "武器等级", min = 0, fast = 5 },
        { id = "medicine", label = "药品等级", min = 0, fast = 1 },
        { id = "accessory", label = "饰品档位", min = 0, fast = 1 },
    } },
}

local fields, bySection = {}, {}
for _, section in ipairs(Custom.sections) do
    bySection[section.id] = section
    for _, field in ipairs(section.fields) do fields[field.id] = field end
end

local collectionKeys = { [1] = "blackstone", [2] = "amber", [4] = "flowers" }
local PRESET_RATES = { 100, 117, 134, 151, 168, 185, 202 }

function Custom.section(id) return bySection[id] end

local function integer(value, minimum, maximum)
    return type(value) == "number" and value % 1 == 0 and value >= minimum and value <= maximum
end

function Custom.bonus(id, cycle)
    if cycle == -1 then return 0 end
    return id == "flowers" and 263 or PRESET_RATES[cycle + 1]
end

local function attributePoints(field, percent, skill)
    return field.min + (field.min * percent + 50) // 100 + skill * field.talent
end

local function attributeCap(field, cycle)
    return attributePoints(field, Custom.bonus(collectionKeys[field.group], cycle), Profile.skillCap(cycle))
end

function Custom.maximum(settings, field)
    local cycle = settings.playerCycle
    if field.skill then return Profile.skillCap(cycle) end
    if field.attribute then return attributeCap(field, cycle) end
    if field.group then return Custom.bonus(field.id, cycle) end
    if cycle == -1 then return 0 end
    if field.id == "weapon" then return Profile.weaponLevel(cycle) end
    if field.id == "medicine" then return 6 end
    return cycle
end

function Custom.weaponCap(cycle, config)
    local maximum = Profile.weaponLevel(cycle)
    local selected = config and config.values and config.values.weapon
    return selected ~= nil and math.max(1, math.min(selected, maximum)) or maximum
end

function Custom.copy(config, cycle)
    local copied = { values = {} }
    if config == nil then return copied end
    assert(Profile.valid(cycle) and type(config) == "table" and type(config.values) == "table", "角色设置无效")
    local settings = { playerCycle = cycle }
    for id, value in pairs(config.values) do
        local field = fields[id]
        local maximum = field and Custom.maximum(settings, field)
        assert(field and not field.skill and maximum > field.min and integer(value, field.min, maximum),
            "角色设置超出档位范围：" .. tostring(id))
        copied.values[id] = value
    end
    if config.skill ~= nil then
        local cap = Profile.skillCap(cycle)
        assert(cap > 0 and integer(config.skill, 0, cap), "技能增幅超出档位范围")
        copied.skill = config.skill
    end
    return copied
end

function Custom.copyProfiles(profiles)
    local copied = {}
    for cycle, config in pairs(profiles or {}) do
        assert(Profile.valid(cycle), "角色设置档位无效")
        copied[cycle] = Custom.copy(config, cycle)
    end
    return copied
end

function Custom.label(settings) return Profile.rank(settings.playerCycle) end

function Custom.stepProfile(settings, delta, baseline)
    local previous = settings.playerCycle
    local cycle = math.max(-1, math.min(6, previous + delta))
    if cycle == previous then return end
    local profiles = settings.customProfiles
    profiles[previous] = Custom.copy(settings.customPlayer, previous)
    settings.customPlayer = Custom.copy(profiles[cycle], cycle)
    settings.playerCycle = cycle
    settings.skillLevel = settings.customPlayer.skill or Profile.normalizeSkillLevel(cycle,
        baseline and cycle == baseline.playerCycle and baseline.skillLevel or Profile.skillCap(cycle))
end

function Custom.groups(config)
    local result = 0
    if config then
        for id in pairs(config.values) do result = result | (fields[id].group or 0) end
    end
    return result
end

function Custom.rate(config, group, cycle)
    local id = collectionKeys[group]
    return config.values[id] or Custom.bonus(id, cycle)
end

function Custom.value(settings, field)
    if field.skill then return settings.skillLevel end
    local value = settings.customPlayer.values[field.id]
    if value ~= nil then return value end
    local cycle = settings.playerCycle
    if field.attribute then
        local percent = Custom.rate(settings.customPlayer, field.group, cycle)
        return attributePoints(field, percent, settings.skillLevel)
    end
    return Custom.maximum(settings, field)
end

function Custom.set(settings, field, value)
    local maximum = Custom.maximum(settings, field)
    assert(integer(value, field.min, maximum), "角色设置超出档位范围")
    if maximum == field.min then return end
    if field.skill then
        settings.skillLevel, settings.customPlayer.skill = value, value
    else
        settings.customPlayer.values[field.id] = value
    end
end

function Custom.setSkill(settings, value)
    Custom.set(settings, fields.skill, value)
end

function Custom.restore(settings, field)
    if field.skill then
        Custom.set(settings, field, Custom.maximum(settings, field))
    else
        settings.customPlayer.values[field.id] = nil
    end
end

function Custom.reset(settings, section)
    for _, field in ipairs(section.fields) do Custom.restore(settings, field) end
end

function Custom.endpointText(settings, field, value)
    if field.skill then return ("+%d%%"):format(value * 2) end
    if field.group and not field.attribute then return ("+%d%%"):format(value) end
    if field.id == "accessory" then return settings.playerCycle == -1 and "未打磨" or "轮回 " .. value end
    return tostring(value)
end

function Custom.ticks(settings, field)
    local maximum = Custom.maximum(settings, field)
    if maximum == field.min then return {} end
    if field.attribute then
        if attributeCap(field, 0) == attributeCap(field, 6) then return {} end
        local ticks = { { field.min, "牢" } }
        for cycle = 0, settings.playerCycle do
            ticks[#ticks + 1] = { attributeCap(field, cycle), tostring(cycle) }
        end
        return ticks
    end
    if field.skill then
        local ticks = {}
        for level = 5, maximum - 1, 5 do
            ticks[#ticks + 1] = { level, Custom.endpointText(settings, field, level) }
        end
        return ticks
    end
    if field.id == "weapon" then
        local ticks = { { 0, "未强化" } }
        for cycle = 0, settings.playerCycle do ticks[#ticks + 1] = { Profile.weaponLevel(cycle), tostring(cycle) } end
        return ticks
    end
    if field.id == "accessory" or field.id == "medicine" then
        local ticks = {}
        for level = 0, maximum do ticks[#ticks + 1] = { level, tostring(level) } end
        return ticks
    end
    if field.id == "blackstone" or field.id == "amber" then
        local ticks = { { 0, "空" } }
        for cycle = 0, settings.playerCycle do ticks[#ticks + 1] = { PRESET_RATES[cycle + 1], tostring(cycle) } end
        return ticks
    end
    if field.id == "flowers" then return { { 0, "空收集" }, { 263, "满收集" } } end
    return {}
end

function Custom.valueText(settings, field)
    local value = Custom.value(settings, field)
    if field.skill then return ("+%d%% · %d级"):format(value * 2, value) end
    if Custom.maximum(settings, field) == field.min then return Custom.endpointText(settings, field, value) end
    local fixed = settings.customPlayer.values[field.id]
    if field.attribute then return fixed ~= nil and tostring(value) or "跟随养成" end
    local prefix = fixed == nil and "档位默认 " or ""
    if field.group or field.id == "accessory" then return prefix .. Custom.endpointText(settings, field, value) end
    if field.id == "weapon" and value == 0 then return "0 未强化" end
    return prefix .. value .. " 级"
end

function Custom.checkpoint(config, equipment)
    if not config then return equipment end
    local values = config.values
    local groups = Custom.groups(config)
    if groups == 0 and values.weapon == nil and values.medicine == nil and values.accessory == nil then return equipment end
    local record = ("custom1,%d,%d,%d,%d"):format(values.weapon or -1, values.medicine or -1, values.accessory or -1, groups)
    return equipment and record .. "\t" .. equipment or record
end

local configuredPath

function Custom.configure(path)
    configuredPath = path
end

local function preferencePath()
    if configuredPath then return configuredPath end
    local source = debug.getinfo(1, "S").source
    local dir = source:sub(1, 1) == "@" and source:sub(2):match("^(.*)[/\\][^/\\]+$")
    return dir and dir .. "/PlayerCustomPreferences.tsv" or nil
end

local function legacyProfiles(enabled, cycle, level, body)
    cycle, level = tonumber(cycle), tonumber(level)
    if not Profile.valid(cycle) or not integer(level, 0, Profile.skillCap(cycle)) then return end
    local config, seen = { values = {} }, {}
    local settings, oldLimit = { playerCycle = cycle }, { playerCycle = 6 }
    for line in body:gmatch("[^\n]+") do
        local id, number = line:match("^([a-zA-Z]+)\t(%d+)$")
        local field, value = fields[id], tonumber(number)
        if not field or field.skill or seen[id] or not integer(value, field.min, Custom.maximum(oldLimit, field)) then return end
        seen[id] = true
        local maximum = Custom.maximum(settings, field)
        if enabled == "1" and maximum > field.min then config.values[id] = math.min(value, maximum) end
    end
    if Profile.skillCap(cycle) > 0 and (enabled == "1" or level ~= Profile.skillCap(cycle)) then config.skill = level end
    return { [cycle] = config }, cycle
end

function Custom.read(path)
    path = path or preferencePath()
    if not path then return end
    local stream = io.open(path, "rb") or io.open(path .. ".previous", "rb")
    if not stream then return end
    local contents = stream:read(4097) or ""
    stream:close()
    if #contents > 4096 then return end
    local enabled, cycle, level, body = contents:match("^PBZPlayerCustom1\t([01])\t(-?%d+)\t(%d+)\n(.*)$")
    if enabled then return legacyProfiles(enabled, cycle, level, body) end
    cycle, body = contents:match("^PBZPlayerCustom2\t(-?%d+)\n(.*)$")
    cycle = tonumber(cycle)
    if not Profile.valid(cycle) then return end
    local profiles = {}
    for line in body:gmatch("[^\n]+") do
        local rank, id, number = line:match("^(-?%d+)\t([a-zA-Z]+)\t(%d+)$")
        rank, number = tonumber(rank), tonumber(number)
        if not Profile.valid(rank) or not fields[id] then return end
        local config = profiles[rank] or { values = {} }
        profiles[rank] = config
        if fields[id].skill then
            if config.skill ~= nil then return end
            config.skill = number
        else
            if config.values[id] ~= nil then return end
            config.values[id] = number
        end
    end
    local ok, clean = pcall(Custom.copyProfiles, profiles)
    if ok then return clean, cycle end
end

function Custom.remember(settings, path)
    if not settings or not settings.customPlayer then return true end
    path = path or preferencePath()
    if not path then return false, "角色设置路径不可用" end
    local cycle = settings.playerCycle
    local profiles = Custom.copyProfiles(settings.customProfiles or Custom.read(path))
    profiles[cycle] = Custom.copy(settings.customPlayer, cycle)
    local rows = { ("PBZPlayerCustom2\t%d"):format(cycle) }
    for rank = -1, 6 do
        local config = profiles[rank]
        if config then
            for _, section in ipairs(Custom.sections) do
                for _, field in ipairs(section.fields) do
                    local value = field.skill and config.skill or config.values[field.id]
                    if value ~= nil then rows[#rows + 1] = ("%d\t%s\t%d"):format(rank, field.id, value) end
                end
            end
        end
    end
    local nextPath, previous = path .. ".next", path .. ".previous"
    local stream, reason = io.open(nextPath, "wb")
    if not stream then return false, reason end
    local written, failure = stream:write(table.concat(rows, "\n"), "\n")
    local closed, closeFailure = stream:close()
    if not written or not closed then return false, failure or closeFailure end
    local old = io.open(path, "rb")
    if old then
        old:close()
        os.remove(previous)
        local moved, moveFailure = os.rename(path, previous)
        if not moved then return false, moveFailure end
    end
    local committed, commitFailure = os.rename(nextPath, path)
    if committed then os.remove(previous)
    elseif old then os.rename(previous, path) end
    return committed ~= nil, commitFailure
end

return Custom
