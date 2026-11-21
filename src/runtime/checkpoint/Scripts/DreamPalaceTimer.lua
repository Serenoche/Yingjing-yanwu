local Timer = {}

Timer.initial = 180000
-- Countdown credits in milliseconds.
Timer.clearBonus = 15000
Timer.noDamageBonus = 30000
Timer.rewardValues = { guard = 1000, dodge = 1000, precision = 3000, execution = 10000,
    killOrdinary = 3000, killElite = 6000, killNamedElite = 12000,
    bossClear = 35000, bossRelayClear = 50000, finalRelayClear = 75000,
    clear = Timer.clearBonus, clean = Timer.noDamageBonus }
Timer.rewardLabels = { precision = "精准处理", execution = "处决奖励",
    killOrdinary = "击杀小怪", killElite = "击杀精英", killNamedElite = "击杀具名精英",
    bossClear = "首领通关奖励", bossRelayClear = "首领通关奖励", finalRelayClear = "首领通关奖励",
    clear = "通关奖励", clean = "无伤奖励" }
Timer.bossClearKinds = { [1] = "bossClear", [2] = "bossRelayClear", [5] = "finalRelayClear" }

local ENTER, EXIT = .22, .18

function Timer.visibleReward(queue, now)
    while queue[1] do
        local reward, following = queue[1], queue[2]
        local fullHold = reward.start + ENTER + (reward.brief and .5 or 2)
        local fade = following and math.min(fullHold, math.max(reward.start + ENTER + .5, following.at)) or fullHold
        local finish = fade + EXIT
        if now < finish then
            local progress = math.max(0, math.min(1, (now - reward.start) / ENTER))
            local enter = 1 - (1 - progress)^3
            return reward, now < fade and enter or math.max(0, 1 - (now - fade) / EXIT), -90 * (1 - enter)
        end
        table.remove(queue, 1)
        if following then following.start = math.max(finish, following.at) end
    end
end

function Timer.queueReward(queue, kind, now)
    local amount = assert(Timer.rewardValues[kind], "unknown countdown reward")
    Timer.visibleReward(queue, now)
    queue[#queue + 1] = { kind = kind, amount = amount, at = now, start = now, brief = #queue > 0 }
    return amount
end

function Timer.left(credited, spent)
    return Timer.initial + credited - spent
end

function Timer.format(milliseconds, decimals, showPlus)
    local negative = milliseconds < 0
    local centiseconds = math.ceil(math.abs(milliseconds) / 10)
    local seconds = math.floor(centiseconds / 100)
    local sign = negative and "-" or showPlus and "+" or ""
    local value = ("%s%02d:%02d:%02d"):format(sign, math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60)
    return decimals and value .. (".%02d"):format(centiseconds % 100) or value
end

local digits = { "一", "二", "三", "四", "五", "六", "七", "八", "九" }
function Timer.floorLabel(floor)
    if floor == 101 then return "第一百零一层" end
    if floor == 100 then return "第一百层" end
    if floor < 10 then return "第" .. digits[floor] .. "层" end
    local tens, ones = math.floor(floor / 10), floor % 10
    return "第" .. (tens == 1 and "" or digits[tens]) .. "十" .. (digits[ones] or "") .. "层"
end

return Timer
