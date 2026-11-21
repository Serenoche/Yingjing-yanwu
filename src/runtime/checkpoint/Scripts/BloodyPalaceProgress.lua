local Roster = require("BloodyPalaceRoster")
local Encounters = require("EncounterCatalog")
local PressurePolicy = require("DreamPalacePressurePolicy")
local Balance = require("DreamPalaceBalance")
local Progress = { playerCycle = Roster.playerCycle, difficulty = require("DreamPalaceProfile").combatDifficulty,
    count = #Roster.waves, testRange = Roster.testRange, performanceTrace = Roster.performanceTrace == true }

local SAVE_NAME = "PBZDreamPalace"
local LOADOUT_NAME = SAVE_NAME .. "Loadout"
local HEADER = SAVE_NAME .. "/1"
local AID_RECORD = "#external-aid\t1"
local MEDICINE_RECORD = "_PBZDreamPalaceMedicineClean"
local PLAYER_HEALTH = "/Game/RenewalContent/Prototypes/Character/BP_RenewalPlayer.BP_RenewalPlayer_C:Health Post Func"
local GROUPS = { { "mainWeapons", 2 }, { "shadowWeapons", 2 }, { "accessories", 6 }, { "medicines", 2 } }
local LIMIT = 8192

local function killRewardKind(selection, sourceFloor)
    if PressurePolicy.namedElites[selection.id] then return "killNamedElite" end
    -- Some ordinary ranged profiles are promoted by the floor's placement.
    local eliteCycle = sourceFloor <= 10 and 1 or 2
    if selection.id:sub(1, 1) == "E" or selection.enemyCycle == eliteCycle then return "killElite" end
    return "killOrdinary"
end

function Progress.floor(index)
    local floor = assert(Roster.waves[index], "血宫场次无效")
    local id = "bloody_palace_floor_" .. index
    local sourceFloor = floor.sourceFloor or index
    local pressureFloor = sourceFloor >= PressurePolicy.firstFloor and (not floor.members or Progress.isNamedElite(sourceFloor))
        and sourceFloor or nil
    local entry = { id = id, name = floor.label, category = "bloody-palace", categoryName = "血宫",
        stages = {}, statCycles = floor.statCycles, pressureFloor = pressureFloor }
    if floor.members then
        local members = {}
        for _, selection in ipairs(floor.members) do
            local mob = assert(Roster.mobs[selection.id], "血宫杂兵不存在：" .. selection.id)
            members[#members + 1] = { id = selection.id, name = mob.name, classPath = mob.classPath,
                regularMob = true, enemyCycle = selection.enemyCycle,
                killReward = killRewardKind(selection, sourceFloor),
                applyPressure = pressureFloor and PressurePolicy.namedElites[selection.id],
                statCycles = Balance.mobStatCycles(sourceFloor, selection) }
        end
        entry.name = #members == 1 and members[1].name or ("%s · %d 人"):format(floor.label, #members)
        entry.stages[1] = { members = members, regularMobs = true }
        return entry, members[1].enemyCycle, false
    end
    for _, selection in ipairs(floor.stages) do
        local members, names = {}, {}
        for _, id in ipairs(selection.members or { selection.id }) do
            local source, reason = Encounters.resolve(id)
            assert(source and source.selectable and #source.stages == 1 and #source.stages[1].members == 1,
                reason or "血宫首领不可用：" .. id)
            members[#members + 1], names[#names + 1] = source.stages[1].members[1], source.name
        end
        entry.stages[#entry.stages + 1] = { members = members,
            name = table.concat(names, "＋"), enemyCycle = selection.enemyCycle }
    end
    if floor.preset then
        local preset, reason = Encounters.resolve(floor.preset)
        assert(preset and preset.selectable, reason or "血宫连战不可用：" .. floor.preset)
        entry.id, entry.name = preset.id, preset.name
    elseif #entry.stages == 1 and floor.stages[1].id then
        entry.id, entry.name = floor.stages[1].id, entry.stages[1].name
    end
    return entry, entry.stages[1].enemyCycle, floor.restore
end

function Progress.isCheckpoint(index)
    local floor = Roster.waves[index]
    return floor ~= nil and floor.checkpoint == true
end

function Progress.isNamedElite(index)
    return Roster.namedEliteFloors and Roster.namedEliteFloors[index] == true
end

function Progress.sourceFloor(index)
    local floor = assert(Roster.waves[index], "血宫场次无效")
    return floor.sourceFloor or index
end

function Progress.elapsed(startedAt, endedAt)
    if not startedAt then return 0 end
    return math.floor(math.max(0, endedAt - startedAt) * 1000 + .5)
end

function Progress.format(milliseconds)
    local seconds = math.floor(milliseconds / 1000)
    return ("%02d:%02d.%03d"):format(math.floor(seconds / 60), seconds % 60, milliseconds % 1000)
end

function Progress.paths(profile, loadoutMemoryPath)
    local accountPreferences = loadoutMemoryPath and loadoutMemoryPath:match("^(.*[/\\])")
    return (accountPreferences or (profile .. "/")) .. SAVE_NAME .. ".tsv",
        accountPreferences and accountPreferences .. LOADOUT_NAME .. ".tsv"
end

local function read(path)
    local file, reason, code = io.open(path, "rb")
    if not file then
        if code == 2 then return nil end
        error(reason or "无法读取血宫存档", 0)
    end
    local bytes = file:read(LIMIT + 1) or ""
    assert(file:close(), "无法关闭血宫存档")
    assert(#bytes <= LIMIT, "血宫存档长度无效")
    return bytes
end

local function decode(bytes, assist)
    assert(bytes:sub(-1) == "\n", "血宫存档未完整写入")
    local rows = {}
    for line in bytes:gmatch("([^\n]*)\n") do rows[#rows + 1] = line end
    local cleared = tonumber(rows[2])
    local validFloor = cleared and cleared % 1 == 0 and cleared >= 1 and cleared < Progress.count
        and (assist or Progress.isCheckpoint(cleared))
    assert(rows[1] == HEADER and rows[2] == tostring(cleared) and validFloor,
        "血宫存档版本或场次不匹配")
    assert(rows[3] and rows[3]:match("^%d+$") and #rows[3] <= 10, "血宫存档用时无效")
    local externalAid = rows[#rows] == AID_RECORD
    local lastSkill = externalAid and #rows - 1 or #rows
    local reward = rows[lastSkill] and rows[lastSkill]:match("^#time%-rewards\t(%d+)$")
    if reward then
        assert(#reward <= 10, "浊梦存点奖励时间无效")
        lastSkill = lastSkill - 1
    end
    local equipment, ability, cursor = { version = 1 }, {}, 4
    for _, group in ipairs(GROUPS) do
        local slots = {}
        for index = 1, group[2] do
            local id = assert(rows[cursor], "血宫存档缺少配装")
            assert(#id <= 160 and id:match("^[A-Za-z0-9_%-]+$"), "血宫存档配装无效")
            slots[index] = id ~= "-" and id or false
            cursor = cursor + 1
        end
        equipment[group[1]] = slots
    end
    assert(equipment.mainWeapons[1] or equipment.mainWeapons[2], "血宫存档缺少主武器")
    assert(lastSkill >= cursor, "血宫存档缺少技能配置")
    for index = cursor, lastSkill do
        local id, level = rows[index]:match("^([A-Za-z0-9_]+)\t(%d%d?)$")
        assert(id and not ability[id] and tonumber(level) <= 30, "血宫存档技能无效")
        ability[id] = tonumber(level)
    end
    local noMedicine
    if ability[MEDICINE_RECORD] ~= nil then
        assert(ability[MEDICINE_RECORD] == 0 or ability[MEDICINE_RECORD] == 1, "浊梦用药记录无效")
        noMedicine = ability[MEDICINE_RECORD] == 1
        ability[MEDICINE_RECORD] = nil
    end
    return { cleared = cleared, milliseconds = tonumber(rows[3]), equipment = equipment,
        ability = ability, externalAid = externalAid, noMedicine = noMedicine, rewardMilliseconds = tonumber(reward) or 0 }
end

function Progress.load(path, assist)
    local bytes = read(path) or read(path .. ".previous")
    if bytes then return decode(bytes, assist) end
end

function Progress.discard(path)
    local copies = {}
    for _, candidate in ipairs({ path .. ".previous", path }) do
        local bytes = read(candidate)
        if bytes then
            assert(bytes:sub(1, #HEADER + 1) == HEADER .. "\n", "血宫存档标识无法识别")
            copies[#copies + 1] = candidate
        end
    end
    for _, candidate in ipairs(copies) do
        assert(os.remove(candidate), "无法清除血宫续打存档")
    end
end

function Progress.watchDeath(palace, pawn, log)
    if palace.practiceFloor or palace.testRange or (palace.tier and palace.tier.assist)
        or type(RegisterHook) ~= "function" then return end
    local address = pawn:GetAddress()
    local ok, pre, post = pcall(RegisterHook, PLAYER_HEALTH, function(context, after, before)
        if palace.closed or not palace.arenaEntered or palace.state == "result" or palace.playerDied then return end
        local observed, reason = pcall(function()
            local actor = context:get()
            if not actor:IsValid() or actor:GetAddress() ~= address or actor:IsActorBeingDestroyed()
                or after:get() > 0 or before:get() <= 0 or actor.AttributeSetBase.Health.CurrentValue > 0 then return end
            -- The game can quit or replace the pawn before the next service tick.
            palace.playerDied = true
            Progress.discard(palace.path)
            palace.checkpointFloor = nil
        end)
        if not observed then log("checkpoint death notification: " .. tostring(reason)) end
    end)
    if ok and pre ~= nil and post ~= nil then
        return function() pcall(UnregisterHook, PLAYER_HEALTH, pre, post) end
    end
end

function Progress.save(path, cleared, milliseconds, equipment, ability, assist, externalAid, noMedicine, rewardMilliseconds)
    local rows = { HEADER, tostring(cleared), tostring(milliseconds) }
    for _, group in ipairs(GROUPS) do
        for index = 1, group[2] do rows[#rows + 1] = equipment[group[1]][index] or "-" end
    end
    local skills = {}
    for id, level in pairs(ability) do skills[#skills + 1] = id .. "\t" .. level end
    table.sort(skills)
    for _, row in ipairs(skills) do rows[#rows + 1] = row end
    if noMedicine ~= nil then rows[#rows + 1] = MEDICINE_RECORD .. "\t" .. (noMedicine and "1" or "0") end
    if rewardMilliseconds then rows[#rows + 1] = ("#time-rewards\t%d"):format(rewardMilliseconds) end
    if externalAid then rows[#rows + 1] = AID_RECORD end
    local bytes = table.concat(rows, "\n") .. "\n"
    decode(bytes, assist)
    local backup = path .. ".previous"
    local current, previous = read(path), read(backup)
    local existing = current or previous
    if existing == bytes then return end
    if existing then
        local saved = decode(existing, assist)
        assert(saved.cleared < cleared and saved.milliseconds <= milliseconds, "血宫续打存档已有更新的进度")
    end
    if previous and current then decode(previous, assist) end
    local temporary = path .. ".tmp-" .. os.time() .. "-" .. tostring({}):gsub("[^%x]", "")
    local ok, failure = pcall(function()
        local file = assert(io.open(temporary, "wb"))
        local written, why = file:write(bytes)
        local flushed, closed = file:flush(), file:close()
        assert(written and flushed and closed, why or "无法写入血宫存档")
        assert(read(temporary) == bytes, "血宫存档写入回读不一致")
        assert(read(path) == current and read(backup) == previous, "血宫续打存档写入期间发生变化")
        -- Windows cannot rename over an existing file. Keep the last good
        -- checkpoint readable through either path if a write is interrupted.
        if current then
            if previous then assert(os.remove(backup), "无法轮换血宫续打备份") end
            assert(os.rename(path, backup), "无法备份血宫续打存档")
        end
        assert(os.rename(temporary, path), "无法提交血宫存档")
    end)
    if not ok then os.remove(temporary); error(failure, 0) end
end

function Progress.record(path, cleared, milliseconds, result)
    local file = assert(io.open(path .. ".results", "ab"))
    local written = file:write(("%s\t%d\t%d\t%s\n"):format(os.date("!%Y-%m-%dT%H:%M:%SZ"), cleared, milliseconds, result))
    local flushed, closed = file:flush(), file:close()
    assert(written and flushed and closed, "无法记录血宫结果")
end

return Progress
