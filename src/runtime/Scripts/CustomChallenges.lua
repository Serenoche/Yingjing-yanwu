-- Self-contained versioned IDs keep retries/history independent of later edits.
-- Only current, ready, single-actor duel entries may become custom members.
local Custom = { maximum = 5 }
local modes = { custom_gauntlet = "g", custom_group = "m" }
local categories = { g = "custom_gauntlet", m = "custom_group" }
local names = { custom_gauntlet = "自订连战", custom_group = "自订群战" }
local choices, byId, drafts, tokens, fromToken = {}, {}, {}, {}, {}
local storePath, lastBytes, loadWarning
local HEADER = "PBZCustomChallenges\t1\n"
local function copy(source)
    local result = {}; for index, value in ipairs(source) do result[index] = value end; return result
end
local function token(id)
    -- The product stays below 2^53, including on a number-only Lua 5.1 VM.
    -- Collision checks below cover the entire selectable catalog. Eight-byte
    -- member tokens also leave room for the game's long report directory.
    local first = 5381
    for index = 1, #id do
        first = (first * 131 + id:byte(index)) % 4294967296
    end
    return ("%08x"):format(first)
end
function Custom.isCategory(category) return modes[category] ~= nil end
function Custom.setChoices(source)
    choices, byId, tokens, fromToken = {}, {}, {}, {}
    for _, entry in ipairs(source) do
        if entry.selectable and entry.category == "duel" and #entry.stages == 1
            and #entry.stages[1].members == 1 and not entry.adapter
            and entry.id:match("^[A-Za-z0-9_]+$") and not entry.id:find("__", 1, true) then
            choices[#choices + 1], byId[entry.id] = entry, entry
            local key = token(entry.id)
            assert(not fromToken[key], "自订目标标识重复")
            tokens[entry.id], fromToken[key] = key, entry.id
        end
    end
    assert(#choices > 0, "没有可编排的挑战目标")
end
function Custom.choices() return copy(choices) end
function Custom.encode(category, members)
    if not modes[category] or type(members) ~= "table" or #members < 1 or #members > Custom.maximum then
        return nil, "自订挑战需要 1–5 个目标"
    end
    for key, id in pairs(members) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #members or not byId[id] then
            return nil, "自订目标不可用，请重新选择"
        end
    end
    for index = 1, #members do if not byId[members[index]] then return nil, "自订列表有空位" end end
    local encoded = {}; for index, id in ipairs(members) do encoded[index] = tokens[id] end
    return "custom_v1_" .. modes[category] .. "__" .. table.concat(encoded, "__")
end
function Custom.parse(id)
    if type(id) ~= "string" or #id > 1024 then return nil, "自订挑战 ID 无效" end
    local mode, rest = id:match("^custom_v1_([gm])__(.+)$")
    if not mode then return nil, "自订挑战格式无效" end
    local members, position = {}, 1
    while true do
        local separator = rest:find("__", position, true)
        local key = rest:sub(position, separator and separator - 1 or #rest)
        local member = fromToken[key]
        if not member then return nil, "自订目标不可用，请重新选择" end
        members[#members + 1] = member
        if #members > Custom.maximum then return nil, "自订挑战最多 5 个目标" end
        if not separator then break end
        position = separator + 2
    end
    local category = categories[mode]
    local encoded, reason = Custom.encode(category, members)
    if encoded ~= id then return nil, reason or "自订挑战编码无效" end
    return { id = id, category = category, members = members }
end
function Custom.resolve(id)
    local definition, reason = Custom.parse(id)
    if not definition then return nil, reason end
    local stages, portraits = {}, {}
    for index, memberId in ipairs(definition.members) do
        local boss = byId[memberId].stages[1].members[1]
        if definition.category == "custom_gauntlet" then stages[index] = { members = { boss } }
        else
            stages[1] = stages[1] or { members = {} }
            stages[1].members[#stages[1].members + 1] = boss
        end
        portraits[#portraits + 1] = boss
    end
    return { id = id, name = names[definition.category] .. " · " .. #definition.members
            .. (definition.category == "custom_gauntlet" and " 连战" or " 目标"),
        category = definition.category, categoryName = names[definition.category], custom = true,
        enabled = true, selectable = true, status = "ready", stages = stages, portraitMembers = portraits,
        customMembers = copy(definition.members) }
end
function Custom.default(category)
    assert(modes[category], "未知自订类型")
    local saved = drafts[category] and Custom.resolve(drafts[category])
    return saved or assert(Custom.resolve(assert(Custom.encode(category, { choices[1].id }))))
end
local function read(path)
    local file = io.open(path, "rb"); if not file then return nil end
    local bytes = file:read(4097); file:close(); return bytes
end
function Custom.configure(path)
    assert(type(path) == "string" and #path > 0 and not path:find("[%z\r\n]"), "自订列表保存路径无效")
    if path == storePath then return end
    storePath, drafts, lastBytes, loadWarning = path, {}, nil, nil
    local bytes = read(path)
    if not bytes then
        -- Recover a last-good file after an interrupted replacement on Windows.
        bytes = read(path .. ".previous")
        if bytes then loadWarning = "已从备份读取列表" end
    end
    if not bytes then return end
    local restored = {}
    local valid = #bytes <= 4096 and bytes:sub(1, #HEADER) == HEADER
    if valid then
        local tail = bytes:sub(#HEADER + 1)
        for line in tail:gmatch("([^\n]+)\n") do
            local category, id = line:match("^([^\t]+)\t([^\t]+)$")
            local definition = Custom.parse(id)
            if not definition or category ~= definition.category or restored[category] then valid = false; break end
            restored[category] = id
        end
        if tail ~= "" and tail:sub(-1) ~= "\n" then valid = false end
    end
    if valid then
        local canonical = { HEADER }
        for _, category in ipairs({ "custom_gauntlet", "custom_group" }) do
            if restored[category] then canonical[#canonical + 1] = category .. "\t" .. restored[category] .. "\n" end
        end
        valid = table.concat(canonical) == bytes
    end
    if valid then drafts, lastBytes = restored, bytes
    else loadWarning = "旧列表不可用，请重新编排" end
end
function Custom.notice() return loadWarning end
function Custom.remember(id)
    local definition, reason = Custom.parse(id)
    if not definition then return nil, reason end
    drafts[definition.category] = id
    if not storePath then return true end
    local lines = { HEADER }
    for _, category in ipairs({ "custom_gauntlet", "custom_group" }) do
        if drafts[category] then lines[#lines + 1] = category .. "\t" .. drafts[category] .. "\n" end
    end
    local bytes = table.concat(lines)
    if bytes == lastBytes and read(storePath) == bytes then return true end
    local temporary, backup = storePath .. ".pending", storePath .. ".previous"
    local file = io.open(temporary, "wb")
    if not file then loadWarning = "列表未保存：无法写入偏好目录"; return nil, loadWarning end
    local written = file:write(bytes); local closed = file:close()
    if not written or not closed or read(temporary) ~= bytes then
        os.remove(temporary); loadWarning = "列表未保存：写入校验失败"; return nil, loadWarning
    end
    local existed = read(storePath) ~= nil
    if existed then
        os.remove(backup)
        if not os.rename(storePath, backup) then
            os.remove(temporary); loadWarning = "列表未保存：无法备份旧列表"; return nil, loadWarning
        end
    end
    if not os.rename(temporary, storePath) then
        if existed then os.rename(backup, storePath) end
        os.remove(temporary); loadWarning = "列表未保存：无法替换文件"; return nil, loadWarning
    end
    lastBytes, loadWarning = bytes, nil
    return true
end
return Custom
