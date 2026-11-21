local Profile = {}

Profile.name = "浊梦"
Profile.combatDifficulty = 3
Profile.tiers = {
    { id = "nightmare", name = "冥使", cycle = 2 },
    { id = "sunk", name = "人使", cycle = 3 },
    { id = "deep", name = "鬼差", cycle = 4 },
    { id = "entry", name = "平民", cycle = 4, assist = true },
}
function Profile.tier(id)
    for i, tier in ipairs(Profile.tiers) do if tier.id == id then return tier, i end end
end

function Profile.checkpoint(base, tier)
    assert(Profile.tier(tier), Profile.name .. "难度无效")
    return (assert(base:match("^(.+)%.tsv$"), Profile.name .. "存档路径无效")) .. "-" .. tier .. ".tsv"
end

function Profile.loadout(path, tier)
    if not path then return end
    assert(Profile.tier(tier), Profile.name .. "难度无效")
    return (assert(path:match("^(.+)%.tsv$"), Profile.name .. "配装路径无效")) .. "-" .. tier .. ".tsv"
end

function Profile.available(path, tier)
    local row = Profile.tier(tier)
    return row and (not row.assist or Profile.civilian(path))
end

function Profile.civilian(base)
    local file = io.open(base .. ".civilian", "rb")
    if not file then return false end
    local value = file:read(3)
    file:close()
    return value == "1\n"
end

function Profile.unlockCivilian(base)
    if Profile.civilian(base) then return end
    local file = assert(io.open(base .. ".civilian", "wb"))
    local written, reason = file:write("1\n")
    local closed = file:close()
    assert(written and closed, reason or "无法保存平民难度")
end

function Profile.log(base, tier, cleared, milliseconds, outcome)
    local path = Profile.checkpoint(base, tier) .. ".results"
    local file = assert(io.open(path, "ab"))
    local written, reason = file:write(("%d\t%d\t%s\n"):format(cleared, milliseconds, outcome))
    local closed = file:close()
    assert(written and closed, reason or ("无法记录" .. Profile.name .. "战绩"))
end

local function higher(record, best)
    if not best then return true end
    if record.cleared ~= best.cleared then return record.cleared > best.cleared end
    return record.milliseconds < best.milliseconds
end

function Profile.read(base, tier)
    local out = { bestClear = 0, failures = 0, recent = {} }
    local file = io.open(Profile.checkpoint(base, tier) .. ".results", "rb")
    if not file then return out end
    for line in file:lines() do
        local cleared, ms, outcome = line:match("^(%d+)\t(%d+)\t([a-z]+)$")
        cleared, ms = tonumber(cleared), tonumber(ms)
        if cleared and cleared <= 101 and ms and ms <= 9999999999 then
            if outcome == "clear" or outcome == "win" then
                out.bestClear = math.max(out.bestClear, cleared)
            end
            if outcome == "win" or outcome == "loss" then
                local record = { cleared = cleared, milliseconds = ms, outcome = outcome }
                if higher(record, out.best) then out.best = record end
                table.insert(out.recent, 1, record)
                if #out.recent > 12 then table.remove(out.recent) end
                out.failures = outcome == "win" and 0 or out.failures + 1
            end
        end
    end
    file:close()
    return out
end

function Profile.time(milliseconds)
    if not milliseconds then return "—" end
    local seconds = math.floor(milliseconds / 1000)
    return ("%d:%02d:%02d"):format(math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60)
end

function Profile.rank(cleared)
    if cleared == 101 then return "甲" end
    if cleared >= 90 then return "乙" end
    if cleared >= 80 then return "丙" end
    if cleared >= 40 then return "丁" end
    if cleared > 0 then return "戊" end
    return "—"
end

function Profile.score(record)
    return {
        { "总用时", Profile.time(record and record.milliseconds) },
        { "最终剩余时间", "—" },
        { "到达层数", record and tostring(record.outcome == "win" and record.cleared or math.min(101, record.cleared + 1)) or "—" },
        { "到达评级", record and Profile.rank(record.cleared) or "—" },
    }
end

return Profile
