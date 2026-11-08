local Panel = {}
local lastPath, lastContents

local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function stringValue(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
        return escapes[char] or string.format("\\u%04x", char:byte())
    end) .. '"'
end

local function scalar(value)
    local kind = type(value)
    if kind == "string" then return stringValue(value) end
    if kind == "number" and value == value and math.abs(value) < math.huge then return tostring(value) end
    if kind == "boolean" then return value and "true" or "false" end
    return "null"
end

local function object(fields, values)
    local encoded = {}
    for _, field in ipairs(fields) do
        encoded[#encoded + 1] = stringValue(field) .. ':' .. scalar(values[field])
    end
    return '{' .. table.concat(encoded, ',') .. '}'
end

local function array(rows, fields)
    local encoded = {}
    for _, row in ipairs(rows or {}) do
        encoded[#encoded + 1] = object(fields, row)
    end
    return '[' .. table.concat(encoded, ',') .. ']'
end

local function encode(snapshot)
    return '{"version":1,"updatedAt":' .. tostring(os.time()) .. ',"maxTargets":' .. scalar(snapshot.maxTargets)
        .. ',"selectedId":' .. scalar(snapshot.selectedId) .. ',"autoheal":' .. scalar(snapshot.autoheal)
        .. ',"visible":' .. scalar(snapshot.visible ~= false) .. ',"mode":' .. scalar(snapshot.mode)
        .. ',"message":' .. scalar(snapshot.message) .. ',"enemyCycle":' .. scalar(snapshot.enemyCycle)
        .. ',"targets":' .. array(snapshot.targets, { "id", "level", "health", "maxHealth", "ai", "alive" })
        .. ',"controls":' .. array(snapshot.controls, { "key", "action" }) .. '}\n'
end

function Panel.publish(path, snapshot)
    if type(path) ~= "string" then return nil, "missing isolated arena panel status path" end
    local normalized = path:lower():gsub("\\", "/")
    if not normalized:match("^[a-z]:/.+/arenadata/profile/pbztestarenapanel%.json$")
        or normalized:find("//", 1, true) or normalized:find("/../", 1, true) or normalized:find("/./", 1, true) then
        return nil, "panel status path is outside the isolated arena profile"
    end
    local ok, contents = pcall(encode, snapshot)
    if not ok then return nil, contents end
    if path == lastPath and contents == lastContents then return true end
    local temporary = path .. ".tmp"
    local stream, openError = io.open(temporary, "wb")
    if not stream then return nil, openError end
    local wrote, writeError = stream:write(contents)
    local closed, closeError = stream:close()
    if not wrote or not closed then
        os.remove(temporary)
        return nil, writeError or closeError
    end
    -- Windows Lua cannot rename over an existing file. The viewer keeps the
    -- last valid snapshot through the brief gap between remove and rename.
    os.remove(path)
    local renamed, renameError = os.rename(temporary, path)
    if renamed then
        lastPath, lastContents = path, contents
    else
        os.remove(temporary)
    end
    return renamed, renameError
end

return Panel
