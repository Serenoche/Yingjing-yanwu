local Timer = require("DreamPalaceTimer")
local Profile = {}

Profile.name = "浊梦"
Profile.externalAidFlag = "x"
Profile.exactReachFlag = "h"
Profile.mobDefeatFlag = "b"
Profile.combatDifficulty = 3
Profile.tiers = {
    { id = "nightmare", name = "冥使", cycle = 2, award = "clear-nightmare" },
    { id = "sunk", name = "人使", cycle = 3, award = "clear-sunk" },
    { id = "deep", name = "鬼差", cycle = 4, award = "clear-deep" },
    { id = "entry", name = "浊使", cycle = 4, assist = true },
}
Profile.achievements = require("DreamPalaceAchievements")
local Toast = require("DreamPalaceAchievementToast")

local CLEAR_AWARDS = { r = "resume", l = "low-health" }
local WIN_AWARDS = { n = "nonstop", w = "one-weapon", a = "no-accessories", s = "no-shadow",
    o = "solo", u = "untouched", m = "no-medicine" }
local BOSS_AWARDS = { l = "low-health", v = "revenge", d = "no-supplies", g = "bride-no-grab" }
local SPEED_CLEAR_MS = 60 * 60 * 1000
local ASSISTED, NORMAL = 1, 2

local function defeatAward(outcome, flags)
    if outcome ~= "loss" then return end
    if flags:find("t", 1, true) then return "time-out" end
    if flags:find(Profile.mobDefeatFlag, 1, true) then return "mob-defeat" end
end

local function creditAward(earned, id, credit)
    earned[id] = math.max(earned[id] or 0, credit)
end

local function earnFlags(earned, flags, rules, credit)
    for flag, id in pairs(rules) do
        if flags:find(flag, 1, true) then creditAward(earned, id, credit) end
    end
end

-- DT_WeaponData for the supported Steam build. Use the equipable base rows,
-- omitting placeholder configs, forced story loadouts and forged duplicates.
local MAIN_WEAPONS = {
    woodenswordhun = true, tang = true, ironblade = true, double = true, long = true,
    guitoublade = true, chizhecanjian = true, zhanmablade = true, snakedual = true,
    renouqingtongjian = true, dualhook = true, tianshashuangyue = true, pojun = true,
    slitheringsword = true, baishanshuangjian = true, horizontalblade = true, jadedualchakram = true,
    yuublade = true, jigsaw = true, renouyanyuedao = true, ciguhundun = true, baiying = true,
    fanghuaxieshan = true, zimingjian = true, luanying = true,
}
local WEAPON_FORMS = { heimoshang = "tang", xiehuo = "long" }

local function mainWeaponId(id)
    if type(id) ~= "string" then return "" end
    id = id:lower()
    id = WEAPON_FORMS[id] or id
    return MAIN_WEAPONS[id] and id or ""
end

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
    return row and (not row.assist or Profile.zhuoshiUnlocked(path))
end

function Profile.zhuoshiUnlocked(base)
    local file = io.open(base .. ".civilian", "rb")
    if not file then return false end
    local value = file:read(3)
    file:close()
    return value == "1\n"
end

function Profile.canUnlockZhuoshi(base)
    return not Profile.zhuoshiUnlocked(base) and Profile.read(base, "deep").failures >= 6
end

function Profile.unlockZhuoshi(base)
    if Profile.zhuoshiUnlocked(base) then return end
    assert(Profile.canUnlockZhuoshi(base), "浊使难度解锁条件未达成")
    local file = assert(io.open(base .. ".civilian", "wb"))
    local written, reason = file:write("1\n")
    local closed = file:close()
    assert(written and closed, reason or "无法保存浊使难度")
    Toast.refresh(base)
end

local function appendResult(base, tier, record)
    local file = assert(io.open(Profile.checkpoint(base, tier) .. ".results", "ab"))
    -- Start a fresh line even if the previous append was interrupted.
    local written, reason = file:write("\n" .. record .. "\n")
    local closed = file:close()
    assert(written and closed, reason or ("无法记录" .. Profile.name .. "战绩"))
end

function Profile.logReached(base, tier, floor)
    assert(type(floor) == "number" and floor % 1 == 0 and floor >= 1 and floor <= 101, "无效的浊梦楼层")
    appendResult(base, tier, ("reach\t%d"):format(floor))
end

local function enteredFloor(cleared, outcome, flags)
    if outcome == "clear" or outcome == "win" or outcome == "success" then return cleared end
    if outcome == "loss" or outcome == "failure" then
        -- Old loss records only saved the last cleared floor.
        return math.min(101, cleared + (flags:find(Profile.exactReachFlag, 1, true) and 0 or 1))
    end
    return 0
end

function Profile.log(base, tier, cleared, milliseconds, outcome, flags, mainWeapons, remaining, timedOut)
    flags = (flags or "") .. (timedOut and "t" or "")
    local record = ("%d\t%d\t%s\t%s"):format(cleared, milliseconds, outcome, flags)
    if remaining ~= nil then record = record .. ("\t%d"):format(remaining) end
    if mainWeapons and outcome == "win" and cleared == 101 and not Profile.tier(tier).assist then
        local first, second = mainWeaponId(mainWeapons[1]), mainWeaponId(mainWeapons[2])
        if first ~= "" or second ~= "" then
            -- An older reader ignores this extra line and reads the usual result.
            -- Putting the weapon line first ties it to the result's commit line.
            record = ("weapons\t%s\t%s\t%s\n"):format(first, second ~= first and second or "", record) .. record
        end
    end
    appendResult(base, tier, record)
    if not Profile.tier(tier).assist then
        if defeatAward(outcome, flags)
            or (outcome == "loss" and tier == "deep" and Profile.zhuoshiUnlocked(base)) then Toast.refresh(base)
        else Toast.resultWritten(base, cleared, outcome, flags) end
    end
end

function Profile.logBoss(base, tier, floor, stage, outcome, flags)
    if Profile.tier(tier).assist then return end
    appendResult(base, tier, ("boss\t%d\t%d\t%s\t%s"):format(floor, stage, outcome, flags or ""))
    if outcome == "win" and flags and flags ~= "" then Toast.refresh(base) end
end

local function higher(record, best)
    if not best then return true end
    if record.cleared ~= best.cleared then return record.cleared > best.cleared end
    return record.milliseconds < best.milliseconds
end

function Profile.read(base, tier)
    local out = { bestReached = 0, bestClear = 0, bestNormalClear = 0,
        failures = 0, recent = {}, earned = {}, weaponWins = {}, bossLosses = {} }
    local file = io.open(Profile.checkpoint(base, tier) .. ".results", "rb")
    if not file then return out end
    local ranked = not Profile.tier(tier).assist
    local weaponResult, weaponOne, weaponTwo
    local normalFailures = 0
    for line in file:lines() do
        local reached = tonumber(line:match("^reach\t(%d+)$"))
        if reached and reached >= 1 and reached <= 101 then out.bestReached = math.max(out.bestReached, reached) end
        local cleared, ms, outcome, flags, remaining = line:match("^(%d+)\t(%d+)\t([a-z]+)\t([a-z]*)\t([%-]?%d+)$")
        if not cleared then cleared, ms, outcome, flags = line:match("^(%d+)\t(%d+)\t([a-z]+)\t([a-z]*)$") end
        if not cleared then
            cleared, ms, outcome = line:match("^(%d+)\t(%d+)\t([a-z]+)$")
            flags = ""
        end
        cleared, ms = tonumber(cleared), tonumber(ms)
        if cleared and cleared <= 101 and ms and ms <= 9999999999 then
            out.bestReached = math.max(out.bestReached, enteredFloor(cleared, outcome, flags))
            local externalAid = flags:find(Profile.externalAidFlag, 1, true) ~= nil
            local credit = externalAid and ASSISTED or NORMAL
            if ranked and outcome == "win" and cleared == 101 and weaponResult == line then
                if MAIN_WEAPONS[weaponOne] then creditAward(out.weaponWins, weaponOne, credit) end
                if MAIN_WEAPONS[weaponTwo] then creditAward(out.weaponWins, weaponTwo, credit) end
            end
            if outcome == "restore" and ranked and flags:find("r", 1, true) then
                creditAward(out.earned, "resume", credit)
            elseif outcome == "clear" or outcome == "win" then
                out.bestClear = math.max(out.bestClear, cleared)
                if not externalAid then out.bestNormalClear = math.max(out.bestNormalClear, cleared) end
                earnFlags(out.earned, flags, CLEAR_AWARDS, credit)
                if outcome == "win" and cleared == 101 then
                    out.winCredit = math.max(out.winCredit or 0, credit)
                    earnFlags(out.earned, flags, WIN_AWARDS, credit)
                    if externalAid then out.earned["visible-hand"] = ASSISTED end
                    if ms <= SPEED_CLEAR_MS then creditAward(out.earned, "speed-clear", credit) end
                end
            end
            if outcome == "win" or outcome == "loss" then
                local defeat = ranked and defeatAward(outcome, flags)
                if defeat then creditAward(out.earned, defeat, credit) end
                local record = { cleared = cleared, milliseconds = ms, outcome = outcome,
                    remaining = tonumber(remaining), timedOut = flags:find("t", 1, true) ~= nil }
                if higher(record, out.best) then out.best = record end
                table.insert(out.recent, 1, record)
                if #out.recent > 12 then table.remove(out.recent) end
                if outcome == "win" then
                    out.failures, normalFailures = 0, 0
                else
                    out.failures = out.failures + 1
                    normalFailures = externalAid and 0 or normalFailures + 1
                    if tier == "deep" and out.failures >= 6 then
                        local unlockCredit = normalFailures >= 6 and NORMAL or ASSISTED
                        out.zhuoshiCredit = math.max(out.zhuoshiCredit or 0, unlockCredit)
                    end
                end
            end
        elseif ranked and line:sub(1, 5) == "boss\t" then
            local floor, stage, result, flags = line:match("^boss\t(%d+)\t(%d+)\t([a-z]+)\t([a-z]*)$")
            floor, stage = tonumber(floor), tonumber(stage)
            if floor and floor >= 1 and floor <= 101 and stage >= 1 and stage <= 5 then
                if result == "win" or result == "loss" then
                    out.bestReached = math.max(out.bestReached, floor)
                end
                if result == "loss" then out.bossLosses[floor .. ":" .. stage] = true end
                if result == "win" then
                    local credit = flags:find(Profile.externalAidFlag, 1, true) and ASSISTED or NORMAL
                    earnFlags(out.earned, flags, BOSS_AWARDS, credit)
                end
            end
        elseif not cleared and not reached then
            local oldClear, oldTime, oldOutcome = line:match("^(%d+)\t(%d+)\t([a-z]+)$")
            if not oldClear then
                oldClear, oldTime, oldOutcome = line:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ\t(%d+)\t(%d+)\t([a-z]+)$")
            end
            oldClear, oldTime = tonumber(oldClear), tonumber(oldTime)
            if oldClear and oldClear <= 101 and oldTime <= 9999999999 then
                out.bestReached = math.max(out.bestReached, enteredFloor(oldClear, oldOutcome, ""))
            end
        end
        weaponOne, weaponTwo, weaponResult = line:match("^weapons\t([a-z0-9_%-]*)\t([a-z0-9_%-]*)\t(.+)$")
    end
    file:close()
    return out
end

function Profile.hasBossLoss(base, floor, stage)
    local key = floor .. ":" .. stage
    for _, tier in ipairs(Profile.tiers) do
        if not tier.assist and Profile.read(base, tier.id).bossLosses[key] then return true end
    end
    return false
end

function Profile.earned(base, includeAssisted)
    local earned, weaponWins = {}, {}
    local highest, highestNormal = 0, 0
    local zhuoshiUnlocked = Profile.zhuoshiUnlocked(base)
    for i, tier in ipairs(Profile.tiers) do
        if not tier.assist then
            local progress = Profile.read(base, tier.id)
            highest = math.max(highest, progress.bestClear)
            highestNormal = math.max(highestNormal, progress.bestNormalClear)
            for id, credit in pairs(progress.earned) do creditAward(earned, id, credit) end
            if tier.id == "deep" and zhuoshiUnlocked then
                earned["unlock-zhuoshi"] = progress.zhuoshiCredit or NORMAL
            end
            for weapon, credit in pairs(progress.weaponWins) do creditAward(weaponWins, weapon, credit) end
            if progress.winCredit then
                creditAward(earned, "peak", progress.winCredit)
                for index = i, #Profile.tiers - 1 do
                    creditAward(earned, Profile.tiers[index].award, progress.winCredit)
                end
            end
        end
    end
    for _, item in ipairs(Profile.achievements) do
        if item.floor and highest >= item.floor then
            earned[item[1]] = highestNormal >= item.floor and NORMAL or ASSISTED
        end
    end
    local allWeaponsCredit = NORMAL
    for id in pairs(MAIN_WEAPONS) do
        if not weaponWins[id] then allWeaponsCredit = nil; break end
        allWeaponsCredit = math.min(allWeaponsCredit, weaponWins[id])
    end
    earned["all-main-weapons"] = allWeaponsCredit
    local assisted = includeAssisted and {}
    for id, credit in pairs(earned) do
        if assisted and credit == ASSISTED then assisted[id] = true end
        earned[id] = true
    end
    if assisted then return earned, assisted end
    return earned
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
        { "最终剩余时间", record and record.remaining and Timer.format(record.remaining, true) or "—" },
        { "到达层数", record and tostring(record.outcome == "win" and record.cleared or math.min(101, record.cleared + 1)) or "—" },
        { "到达评级", record and Profile.rank(record.cleared) or "—" },
    }
end

return Profile
