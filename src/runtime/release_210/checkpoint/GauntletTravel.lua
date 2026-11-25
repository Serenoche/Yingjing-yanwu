local PlayerState = require("EncounterPlayerState")
local SceneArena = require("SceneArena")
local Travel = {}

local SUBSYSTEMS = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local BACKPACK = "/Script/ProjectPBZ.PBZBackPackSubsystem"
local RESOURCES = { "Health", "Shachi", "UltimateChargeCount", "UltimateCharge", "SpiritShadow" }
local COUNTS = { "perfectGuards", "perfectDodges", "healthRestored", "damageTaken" }
local PRACTICE = { "ai", "enemyRegen", "invulnerable", "infiniteUltimate", "infiniteSpiritShadow" }

local function valid(object)
    return object and type(object.IsValid) == "function" and object:IsValid()
end

local function unwrap(value)
    if valid(value) or value == nil then return value end
    local ok, object = pcall(function() return value:get() end)
    if ok and object ~= nil then return object end
    return value
end

local function backpackFor(pawn)
    local library, class = StaticFindObject(SUBSYSTEMS), StaticFindObject(BACKPACK)
    assert(valid(library) and valid(class), "转场背包接口未就绪")
    local backpack = unwrap(library:GetWorldSubsystem(pawn, class))
    assert(valid(backpack), "转场背包未就绪")
    return backpack
end

local function medicineInfo(backpack, id)
    local value = unwrap(backpack.MedicineInfos:Find(FName(id)))
    assert(valid(value), "转场药瓶未就绪：" .. id)
    return value
end

function Travel.capture(gameplay, pawn, challenge, now)
    local world = assert(SceneArena.runtimeWorld(pawn), "转场玩家世界未就绪")
    local controller = gameplay:GetPlayerController(pawn, 0)
    local player = PlayerState.capture(pawn, controller)
    local backpack = backpackFor(pawn)
    for id, saved in pairs(player.medicines) do
        local info = medicineInfo(backpack, id)
        assert(type(info.DisplayTime) == "number", "转场药瓶显示数量未就绪")
        saved.display = info.DisplayTime
    end
    local controls
    if challenge.practice then
        controls = {}
        for _, name in ipairs(PRACTICE) do controls[name] = challenge.practice.state[name] end
    end
    return { player = player, controls = controls, departingWorld = world:GetAddress(),
        elapsed = challenge.startedAt and math.max(0, now - challenge.startedAt) or nil }
end

function Travel.restore(gameplay, pawn, transfer)
    local world = assert(SceneArena.runtimeWorld(pawn), "目标场地的玩家世界未就绪")
    assert(world:GetAddress() ~= transfer.departingWorld, "等待目标场地加载")
    local stats = pawn.AttributeSetBase
    assert(valid(stats), "目标场地的玩家属性未就绪")
    local backpack = backpackFor(pawn)
    for id, saved in pairs(transfer.player.medicines) do
        local info = medicineInfo(backpack, id)
        assert(info.CurrentLevel == saved.CurrentLevel, "目标场地的药瓶等级不符：" .. id)
    end
    local setter = require("PracticeMode").setAttributeValue
    local targets = {}
    for _, field in ipairs(RESOURCES) do
        local target = transfer.player.attributes[field]
        local limit = stats[field .. "_Max"].CurrentValue
        assert(type(target) == "number" and type(limit) == "number" and limit >= 0,
            "转场资源读数无效：" .. field)
        targets[field] = math.min(target, limit)
    end
    assert(targets.Health > 0, "等待目标场地的角色生命上限")
    for _, field in ipairs(RESOURCES) do
        local target = targets[field]
        if math.abs(stats[field].CurrentValue - target) > 0.01 then setter(pawn, field, target) end
        assert(math.abs(stats[field].CurrentValue - target) < 0.05, "转场资源回读不符：" .. field)
    end
    for id, saved in pairs(transfer.player.medicines) do
        local info = medicineInfo(backpack, id)
        info.CurrentTime, info.DisplayTime = saved.CurrentTime, saved.display
        info = medicineInfo(backpack, id)
        assert(info.CurrentTime == saved.CurrentTime and info.DisplayTime == saved.display,
            "转场药瓶数量回读不符：" .. id)
    end
    pcall(function()
        require("ChallengeMedicine").new(pawn):refreshDisplay(pawn, gameplay:GetPlayerController(pawn, 0), {})
    end)
end

function Travel.report(previous, sample)
    if not previous then return sample end
    local combined = {}
    for key, value in pairs(sample) do combined[key] = value end
    for _, key in ipairs(COUNTS) do
        local earlier, present = previous[key], sample[key]
        if earlier or present then combined[key] = (earlier or 0) + (present or 0) end
    end
    if previous.damageTakenStatus ~= sample.damageTakenStatus then combined.damageTakenStatus = "partial" end
    if combined.damageTakenStatus == "partial" then combined.damageTakenNote = "受伤量按各阶段可用的记录累计。" end
    combined.metricsNote = (sample.metricsNote or "") .. "换场前后的统计分段采集后累计。"
    return combined
end

return Travel
