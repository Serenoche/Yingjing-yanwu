-- Read PBZModLoader's pending choices and replace only the selected MOD setting.
local Settings = {}
local iniPath, replaceFile
local UTF8_BOM = "\239\187\191"
local UTF16_LE_BOM = "\255\254"
local SELF = {pbzmodfeaturesr1 = true, pbzmodfeaturesr2 = true}

local function trim(text)
    return (text:gsub("^[ \t]+", ""):gsub("[ \t]+$", ""))
end

local function validId(id)
    return type(id) == "string" and id:match("^[A-Za-z0-9_-]+$") ~= nil
end

local function readRaw(path)
    local file = path and io.open(path, "rb")
    if not file then return nil, "无法读取 PBZModLoader 的 mods.ini。" end
    local bytes = file:read("*a")
    file:close()
    if bytes == nil then return nil, "无法读取 PBZModLoader 的 mods.ini。" end
    return bytes
end

-- Shadow each UTF-16 code unit with one byte so we can find ASCII keys without
-- decoding, rewriting, or losing any surrounding non-ASCII text.
local function iniText(bytes)
    local bom = bytes:sub(1, 3)
    if bom == UTF8_BOM then bytes = bytes:sub(4) else bom = "" end
    local first = bytes:sub(1, 2)
    if first == UTF16_LE_BOM and bom == "" then
        local data = bytes:sub(3)
        if #data % 2 ~= 0 then return nil end
        return (data:gsub("(.)(.)", function(low, high)
            return high == "\0" and low:byte() < 128 and low or "\128"
        end)), first, 2
    end
    if bytes:find("\0", 1, true) or first == "\254\255" then return nil end
    return bytes, bom, 1
end

local function encode(text, width)
    if width == 2 then return (text:gsub(".", "%0\0")) end
    return text
end

local function booleanToken(text)
    local prefix, number, suffix = text:match("^([ \t]*)([01])(.*)$")
    if not prefix then
        local quote
        prefix, quote, number, suffix = text:match("^([ \t]*)([\"'])([01])%2(.*)$")
        if prefix then prefix = prefix .. quote end
    end
    if not prefix then return nil end
    suffix = trim(suffix)
    if suffix ~= "" and not suffix:match("^[;#]") then return nil end
    return number == "1", #prefix + 1
end

local function legacyCount(value)
    local token = value and trim(value):match("^(%d+)")
    local count = token and tonumber(token)
    return count and math.min(count, 128) or 0
end

local function parse(bytes)
    local source, bom, width = iniText(bytes)
    if not source then return nil, "mods.ini 的编码无法安全编辑。" end
    local snapshot = {bytes = bytes, source = source, bom = bom, width = width,
        overrides = {}, legacy = {}, ending = "\r\n"}
    local loader, legacy = {}, {}
    local section, offset, haveEnding = "", 1, false
    while offset <= #source do
        local first = source:find("[\r\n]", offset)
        local line = source:sub(offset, (first or #source + 1) - 1)
        local ending = first and source:sub(first, first) or ""
        if ending == "\r" and source:sub(first + 1, first + 1) == "\n" then ending = "\r\n" end
        local nextLine = offset + #line + #ending
        if ending ~= "" and not haveEnding then snapshot.ending, haveEnding = ending, true end
        local header = line:match("^[ \t]*%[([^%]]+)%]")
        if header then
            section = trim(header):lower()
            if section == "mods" then
                if snapshot.mods then return nil, "mods.ini 含多个 [Mods] 段，无法安全保存。" end
                snapshot.mods = {after = nextLine, ending = ending}
            elseif section:match("^mod%.%d+$") and not legacy[section] then
                legacy[section] = {}
            end
        else
            local prefix, key, equals, value = line:match("^([ \t]*)([A-Za-z0-9_-]+)([ \t]*=[ \t]*)(.*)$")
            if key and section == "mods" then
                local id = key:lower()
                if snapshot.overrides[id] then
                    snapshot.overrides[id].duplicate = true
                else
                    local enabled, index = booleanToken(value)
                    snapshot.overrides[id] = {enabled = enabled,
                        position = index and offset + #prefix + #key + #equals + index - 1 or nil}
                end
            elseif key and (section == "loader" or legacy[section]) then
                local fields = section == "loader" and loader or legacy[section]
                key = key:lower()
                if fields[key] == nil then fields[key] = trim(value) end
            end
        end
        offset = nextLine
    end
    for index = 0, legacyCount(loader.count) - 1 do
        local row = legacy["mod." .. index]
        if row then
            local id = row.id and (row.id:match("^([\"'])(.-)%1$") and row.id:sub(2, -2) or row.id)
            if validId(id) then
                local enabled = row.enabled == nil and true or booleanToken(row.enabled)
                if enabled ~= nil then snapshot.legacy[id:lower()] = enabled end
            end
        end
    end
    return snapshot
end

function Settings.configure(path, writer)
    iniPath = type(path) == "string" and path ~= "" and path or nil
    replaceFile = type(writer) == "function" and writer or nil
end

function Settings.read()
    local bytes, reason = readRaw(iniPath)
    if bytes == nil then return nil, reason end
    return parse(bytes)
end

function Settings.enabled(snapshot, id)
    if not snapshot or not validId(id) then return nil end
    id = id:lower()
    local row = snapshot.overrides[id]
    if row then
        if not row.duplicate then return row.enabled end
        return nil
    end
    local old = snapshot.legacy[id]
    if old ~= nil then return old end
    return true
end

function Settings.companionAvailable(id)
    if not iniPath or not validId(id) then return false end
    local directory = iniPath:match("^(.*[/\\])[^/\\]+$")
    local script = directory and io.open(directory .. "mods/" .. id .. "/main.js", "rb")
    if not script then return false end
    local firstByte = script:read(1)
    script:close()
    return firstByte ~= nil and Settings.enabled(Settings.read(), id) == true
end

local function splice(snapshot, position, skip, inserted)
    local first = #snapshot.bom + (position - 1) * snapshot.width
    return snapshot.bytes:sub(1, first) .. encode(inserted, snapshot.width)
        .. snapshot.bytes:sub(first + skip * snapshot.width + 1)
end

local function withOverride(snapshot, id, value)
    local existing = snapshot.overrides[id:lower()]
    if existing then
        if existing.duplicate or not existing.position then
            return nil, "该 MOD 的配置重复或无法识别，请先检查 mods.ini。"
        end
        return splice(snapshot, existing.position, 1, value)
    end

    local row = id .. "=" .. value
    local mods = snapshot.mods
    if mods then
        local insertion = mods.ending ~= "" and row .. mods.ending or snapshot.ending .. row
        return splice(snapshot, mods.after, 0, insertion)
    end
    local last = snapshot.source:sub(-1)
    local hasEnding = last == "\n" or last == "\r"
    local boundary = not hasEnding and #snapshot.source > 0 and snapshot.ending or ""
    local endOfRow = hasEnding and snapshot.ending or ""
    local insertion = boundary .. "[Mods]" .. snapshot.ending .. row .. endOfRow
    return splice(snapshot, #snapshot.source + 1, 0, insertion)
end

function Settings.setEnabled(id, enabled)
    if not validId(id) or SELF[id:lower()] or type(enabled) ~= "boolean" then
        return false, "无效的 MOD 开关。"
    end
    if not replaceFile then return false, "mods.ini 的保存接口不可用。" end
    local snapshot, reason = Settings.read()
    if not snapshot then return false, reason end
    if Settings.enabled(snapshot, id) == enabled then return true end
    local updated, failure = withOverride(snapshot, id, enabled and "1" or "0")
    if not updated then return false, failure end

    local check = parse(updated)
    if not check or Settings.enabled(check, id) ~= enabled then
        return false, "无法验证 MOD 开关，已保留原设置。"
    end
    local ok, saved, errorMessage = pcall(replaceFile, iniPath, snapshot.bytes, updated)
    if not ok or not saved then
        return false, ok and errorMessage or "保存 mods.ini 失败，原设置未确认修改。"
    end
    return true
end

return Settings
