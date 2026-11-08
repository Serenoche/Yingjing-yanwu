-- Read only the report explicitly associated with a history row. This parser
-- accepts data, never executable Lua, and never scans other sessions' reports.
local History = {}
local MAX_BYTES, MAX_DEPTH, MAX_VALUES = 1024 * 1024, 24, 65536
local NULL = {}

local function utf8(code)
    if code < 0x80 then return string.char(code) end
    if code < 0x800 then return string.char(0xC0 + math.floor(code / 64), 0x80 + code % 64) end
    if code < 0x10000 then return string.char(0xE0 + math.floor(code / 4096), 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64) end
    return string.char(0xF0 + math.floor(code / 262144), 0x80 + math.floor(code / 4096) % 64,
        0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
end

local function decode(source)
    local at, values = 1, 0
    local function skip() local _, last = source:find("^[ \t\r\n]*", at); at = (last or at - 1) + 1 end
    local function take(expected) assert(source:sub(at, at) == expected, "invalid JSON punctuation"); at = at + 1 end
    local function hex()
        local value = source:sub(at, at + 3)
        assert(#value == 4 and value:match("^%x%x%x%x$"), "invalid JSON unicode escape")
        at = at + 4; return tonumber(value, 16)
    end
    local function quoted()
        take('"'); local chunks, first = {}, at
        while at <= #source do
            local byte = source:byte(at)
            if byte == 34 then
                chunks[#chunks + 1] = source:sub(first, at - 1); at = at + 1; return table.concat(chunks)
            elseif byte == 92 then
                chunks[#chunks + 1] = source:sub(first, at - 1); at = at + 1
                local escaped = source:sub(at, at); at = at + 1
                local simple = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
                if escaped == 'u' then
                    local code = hex()
                    if code >= 0xD800 and code <= 0xDBFF then
                        assert(source:sub(at, at + 1) == '\\u', "missing JSON low surrogate"); at = at + 2
                        local low = hex(); assert(low >= 0xDC00 and low <= 0xDFFF, "invalid JSON low surrogate")
                        code = 0x10000 + (code - 0xD800) * 1024 + low - 0xDC00
                    else assert(code < 0xDC00 or code > 0xDFFF, "unpaired JSON low surrogate") end
                    chunks[#chunks + 1] = utf8(code)
                else assert(simple[escaped], "invalid JSON escape"); chunks[#chunks + 1] = simple[escaped] end
                first = at
            else assert(byte >= 32, "JSON control character"); at = at + 1 end
        end
        error("unterminated JSON string")
    end
    local parse
    parse = function(depth)
        assert(depth <= MAX_DEPTH, "JSON nesting limit")
        values = values + 1; assert(values <= MAX_VALUES, "JSON value limit"); skip()
        local char = source:sub(at, at)
        if char == '"' then return quoted() end
        if char == '{' or char == '[' then
            local object, seen, array = {}, {}, char == '['; at = at + 1; skip()
            local ending = array and ']' or '}'
            if source:sub(at, at) == ending then at = at + 1; return object end
            local index = 1
            while true do
                local key
                if array then key = index; index = index + 1
                else
                    assert(source:sub(at, at) == '"', "JSON object key must be text")
                    key = quoted(); assert(not seen[key], "duplicate JSON key"); seen[key] = true; skip(); take(':')
                end
                object[key] = parse(depth + 1); skip()
                if source:sub(at, at) == ending then at = at + 1; return object end
                take(','); skip()
            end
        end
        for literal, result in pairs({ ['true'] = true, ['false'] = false, ['null'] = NULL }) do
            if source:sub(at, at + #literal - 1) == literal then at = at + #literal; return result end
        end
        local rest = source:sub(at)
        local number = rest:match('^-?%d+%.?%d*[eE][+-]?%d+') or rest:match('^-?%d+%.%d+') or rest:match('^-?%d+')
        assert(number and not number:match('^-?0%d') and not number:match('%.[' .. 'eE' .. ']'), "invalid JSON number")
        local value = tonumber(number); assert(value and value == value and math.abs(value) < math.huge, "non-finite JSON number")
        at = at + #number; return value
    end
    skip(); assert(source:sub(at, at) == '{', "report JSON must be an object")
    local result = parse(1); skip(); assert(at > #source, "trailing JSON data")
    return result
end

local function copy(value, depth, seen)
    if value == NULL then return nil end
    local kind = type(value)
    if kind == "number" then return value == value and math.abs(value) < math.huge and value or nil end
    if kind == "string" or kind == "boolean" then return value end
    if kind ~= "table" or depth > MAX_DEPTH or seen[value] then return nil end
    seen[value] = true
    local result = {}
    for key, child in pairs(value) do
        if type(key) == "string" or (type(key) == "number" and key > 0 and key % 1 == 0) then
            result[key] = copy(child, depth + 1, seen)
        end
    end
    seen[value] = nil; return result
end

local function safeName(filename)
    if type(filename) ~= "string" then return false end
    local stem = filename:match("^(.*)%.json$")
    local device = stem and stem:upper() or ""
    return #filename <= 200
        and filename:match("^[A-Za-z0-9][A-Za-z0-9_%-]*%.json$") ~= nil
        and filename:lower() ~= "latest.json"
        and device ~= "CON" and device ~= "PRN" and device ~= "AUX" and device ~= "NUL"
        and not device:match("^COM[1-9]$") and not device:match("^LPT[1-9]$")
end
local function linked(report, record)
    -- Compare only immutable identifying fields present on both records. Old
    -- localized names can change with the catalog and are not an identity key.
    for _, key in ipairs({ "bossId", "attemptResult" }) do
        if record[key] ~= nil and report[key] ~= nil and record[key] ~= report[key] then return false end
    end
    if record.endedAt ~= nil and report.endedAt ~= nil and tostring(record.endedAt) ~= tostring(report.endedAt) then return false end
    if type(record.timeSeconds) == "number" and type(report.timeSeconds) == "number"
        and math.abs(record.timeSeconds - report.timeSeconds) > 0.000001 then return false end
    return type(report.bossId) == "string" or type(report.bossName) == "string"
end

local TEXT_FIELDS = { "bossId", "bossName", "encounterId", "encounterName", "attemptResult",
    "category", "categoryName", "mode", "playerProfile", "difficultyName", "sceneId", "sceneName",
    "metricsNote", "damageTakenStatus", "damageTakenNote", "reportFile" }
local NUMBER_FIELDS = { "version", "timeSeconds", "perfectGuards", "perfectDodges", "healthRestored",
    "damageTaken", "playerCycle", "nativePlayerCycle", "enemyCycle", "bossLevel", "difficultyMode",
    "stageCount", "completedStages", "authoredPhaseCount", "summonWaveCount" }
local function reportData(value)
    local report = copy(value, 1, {})
    for _, key in ipairs(TEXT_FIELDS) do
        assert(report[key] == nil or (type(report[key]) == "string" and #report[key] <= 4096), "invalid report text field")
    end
    for _, key in ipairs(NUMBER_FIELDS) do assert(report[key] == nil or type(report[key]) == "number", "invalid report number field") end
    assert(report.endedAt == nil or type(report.endedAt) == "string" or type(report.endedAt) == "number", "invalid report timestamp")
    assert(report.loadout == nil or type(report.loadout) == "table", "invalid report loadout")
    for _, group in ipairs({ "mainWeapons", "shadowWeapons", "accessories", "medicines" }) do
        local items = report.loadout and report.loadout[group]
        assert(items == nil or type(items) == "table", "invalid report equipment group")
        if items then
            for _, item in pairs(items) do
                assert(type(item) == "table", "invalid report equipment item")
                for _, key in ipairs({ "kind", "id", "name", "iconPath" }) do
                    assert(item[key] == nil or (type(item[key]) == "string" and #item[key] <= 4096), "invalid equipment text")
                end
                assert(item.level == nil or type(item.level) == "number", "invalid equipment level")
                assert(item.forged == nil or type(item.forged) == "boolean", "invalid equipment forging")
            end
        end
    end
    return report
end

function History.resolve(profilePath, record)
    assert(type(record) == "table", "history record must be data")
    local fallback = reportData(record)
    local reason = "no associated JSON"
    if record.reportFile ~= nil then
        if not safeName(record.reportFile) then reason = "invalid report basename"
        elseif type(profilePath) ~= "string" or profilePath == "" or profilePath:find('%z') then reason = "report profile unavailable"
        else
            local file = io.open(profilePath .. "/ChallengeReports/" .. record.reportFile, "rb")
            if not file then reason = "associated JSON missing"
            else
                local read, content = pcall(file.read, file, MAX_BYTES + 1); file:close()
                if not read or type(content) ~= "string" then reason = "associated JSON unreadable"
                elseif #content > MAX_BYTES then reason = "associated JSON too large"
                else
                    local ok, report = pcall(function() return reportData(decode(content)) end)
                    if not ok then reason = "invalid associated JSON"
                    elseif not linked(report, record) then reason = "associated JSON identity mismatch"
                    else
                        report = copy(report, 1, {}); report.reportFile = record.reportFile
                        return report, { source = "json", complete = type(report.loadout) == "table" }
                    end
                end
            end
        end
    end
    local complete = type(fallback.loadout) == "table"
    return fallback, { source = complete and "memory" or "legacy", complete = complete, reason = reason }
end

return History
