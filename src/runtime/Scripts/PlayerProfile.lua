local Profile = {}
local PLAYER = { "身手不凡", "锋芒逼人", "技压一方", "威震江湖", "傲视群雄", "独步武林", "天下无双" }
local ENEMY = { "生死相搏", "杀机四伏", "险象环生", "凶多吉少", "命悬一线", "九死一生", "十死无生" }
function Profile.valid(cycle)
    return type(cycle) == "number" and cycle % 1 == 0 and cycle >= -1 and cycle <= 6
end
function Profile.nativeCycle(cycle)
    assert(Profile.valid(cycle), "玩家轮回无效")
    return math.max(0, cycle)
end
function Profile.skillCap(cycle)
    assert(Profile.valid(cycle), "玩家轮回无效")
    return cycle == -1 and 0 or cycle * 5
end
function Profile.normalizeSkillLevel(cycle, level)
    assert(Profile.valid(cycle), "玩家轮回无效")
    -- Older owned menu/cache records used 30 for Lao's three terminal nodes.
    -- Lao now has the base tree only; the terminal selection is always zero.
    if cycle == -1 then return 0 end
    return level
end
function Profile.id(cycle)
    assert(Profile.valid(cycle), "玩家轮回无效")
    return cycle == -1 and "lao" or "cycle-" .. cycle
end
function Profile.slot(cycle, prefix, sceneId)
    assert(Profile.valid(cycle) and type(prefix) == "string", "玩家预设无效")
    sceneId = require("ArenaScenes").normalize(sceneId)
    if sceneId == "lake" then return cycle == -1 and "PBZArenaIntegratedLakeLao" or "PBZArenaIntegratedLakeCycle" .. cycle end
    assert(sceneId == "night", "场景预设已撤下")
    return cycle == -1 and "PBZArenaIntegratedLao" or prefix .. cycle
end
function Profile.privateSlots()
    local names = { "PBZArenaIntegratedTraining" }
    for cycle = 0, 6 do names[#names + 1] = "PBZArenaIntegratedCycle" .. cycle end
    names[#names + 1] = "PBZArenaIntegratedLao"
    names[#names + 1] = "PBZArenaIntegratedLakeTraining"
    for cycle = 0, 6 do names[#names + 1] = "PBZArenaIntegratedLakeCycle" .. cycle end
    names[#names + 1] = "PBZArenaIntegratedLakeLao"
    return names
end
function Profile.isPrivateSlot(slot)
    for _, name in ipairs(Profile.privateSlots()) do if slot == name then return true end end
    -- Retired owned namespaces remain private for Continue isolation; they
    -- are never returned as a playable preset or loaded by slot().
    for _, prefix in ipairs({ "PBZArenaIntegratedDay", "PBZArenaIntegratedDrill", "PBZArenaIntegratedCliff" }) do
        if slot == prefix .. "Training" or slot == prefix .. "Lao" then return true end
        for cycle = 0, 6 do if slot == prefix .. "Cycle" .. cycle then return true end end
    end
    return false
end
function Profile.rank(cycle, side)
    assert(Profile.valid(cycle) and (side ~= "enemy" or cycle >= 0), "轮回称号无效")
    if cycle == -1 then return "牢" end
    return (side == "enemy" and ENEMY or PLAYER)[cycle + 1] .. "（" .. cycle .. "）"
end
function Profile.weaponLevel(cycle)
    assert(Profile.valid(cycle), "玩家轮回无效")
    return cycle == -1 and 1 or 30 + 5 * cycle
end
return Profile
