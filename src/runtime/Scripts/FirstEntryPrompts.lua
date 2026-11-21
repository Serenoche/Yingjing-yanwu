local Prompts = {}

local MESSAGES = {
    arena = {
        "感谢你的支持！为保证良好游戏体验，本MOD不建议与其他功能性MOD同时使用。",
        "本MOD已设计独立存档，将不会影响你的正式存档，请放心游玩！",
    },
    dream = {
        "这是一个血宫类模式，时间结束即为失败，请在倒计时结束前完成挑战！",
        "击败敌人、通关楼层以及漂亮的战斗将会赢得时间奖励！",
        "在指定层数通关后自动保存。退出或闪退后可从最近的存档点继续，阵亡会清除本轮进度。",
        "达成特定条件后将会解锁相应的成就！",
        "以通关为目标而努力吧！",
    },
    zhuoshi = {
        "本难度将会在每一层通关后自动保存，即使失败与提前退出也不会失去进度！",
        "超时也不会结束游戏！",
        "请尽情享受游戏吧！",
    },
}

local ACKNOWLEDGED = { arena = "1\n", dream = "2\n", zhuoshi = "1\n" }
local readThisSession = {}

local function marker(directory, group)
    return directory .. "PBZFirstEntry-" .. group .. ".txt"
end

function Prompts.pending(directory, group)
    if not directory then return end
    local path = marker(directory, group)
    if readThisSession[path] then return end
    local file = io.open(path, "rb")
    if file then
        local expected = ACKNOWLEDGED[group]
        local value = file:read(#expected + 1)
        file:close()
        if value == expected then
            readThisSession[path] = true
            return
        end
    end
    return MESSAGES[group]
end

function Prompts.acknowledge(directory, group)
    local path = marker(directory, group)
    readThisSession[path] = true
    local file = io.open(path, "wb")
    if not file then return false end
    local written = file:write(ACKNOWLEDGED[group])
    local closed = file:close()
    return written ~= nil and closed == true
end

return Prompts
