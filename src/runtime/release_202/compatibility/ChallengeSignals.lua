local Signals = {}
local Observer = {}
Observer.__index = Observer

local TELEMETRY_CLASS = "/Script/TensionMeter.TensionWorldSubsystem"
local SUBSYSTEM_LIBRARY = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local SYSTEM_LIBRARY = "/Script/Engine.Default__KismetSystemLibrary"
local AI_CLASS = "/Script/SGameAI.SGameAIComponent"
local AI_STATES = "/Script/SGameAI.Default__SGameAIStateUtils"
local HEALTH_HOOK = "/Game/RenewalContent/Prototypes/Character/BP_RenewalPlayer.BP_RenewalPlayer_C:Health Post Func"
local BOSS_DESTROY_HOOK = "/Script/TensionMeter.TensionWorldSubsystem:OnBossDestroyed"
local EVENT_HEADER = "session_idx,boss,event_time,outcome,source_event,base_w,final_w,routed_dim,clamped"
local PERFECT_GUARD = "Outcome.Defense.PerfectDeflect"
local PERFECT_DODGE = "Outcome.Dodge.PerfectDodge"
local EPSILON = 0.01

local function valid(object)
    return object ~= nil and object:IsValid()
end

local function finite(value)
    return type(value) == "number" and value > -math.huge and value < math.huge
end

local function health(actor)
    if not valid(actor) then return nil, nil end
    local attrs = actor.AttributeSetBase
    if not valid(attrs) then return nil, nil end
    local hp, maximum = attrs.Health.CurrentValue, attrs.Health_Max.CurrentValue
    if finite(hp) and finite(maximum) and maximum > 0 then return hp, maximum end
end

local function worldAddress(actor)
    if not valid(actor) then return nil end
    local world = actor:GetWorld()
    if valid(world) then return world:GetAddress() end
end

local function hasTag(actor, tag)
    local asc = valid(actor) and actor.AbilitySystemComponent or nil
    return valid(asc) and asc:GetGameplayTagCount(tag) > 0
end

local function isDead(actor, tag)
    if not valid(actor) then return false end
    if hasTag(actor, tag) then return true end
    local states = StaticFindObject(AI_STATES)
    if not valid(states) then return false end
    local ok, result = pcall(function() return states:IsDead(actor) end)
    return ok and result == true
end

local function nameText(value)
    if type(value) == "string" then return value end
    if value then return value:ToString() end
end

local function unpackParameter(value)
    if type(value) ~= "table" and type(value) ~= "userdata" then return value end
    local ok, unpacked = pcall(function() return value:get() end)
    if ok then return unpacked end
    return value
end

local function getTelemetry(pawn)
    local library = StaticFindObject(SUBSYSTEM_LIBRARY)
    local class = StaticFindObject(TELEMETRY_CLASS)
    if valid(library) and valid(class) then return library:GetWorldSubsystem(pawn, class) end
end

local function activeTelemetry(observer, record)
    return observer.telemetry:HasActiveSessionForBoss(record.actor) == true
end

local function beginTelemetry(observer, record)
    local system = StaticFindObject(SYSTEM_LIBRARY)
    if valid(system) then
        local checked, enabled = pcall(function()
            return system:GetConsoleVariableIntValue("pbz.Tension.Enable")
        end)
        if checked and enabled == 0 then return false end
    end
    observer.telemetry:AutoBeginEncounterWithDefaultProfile(record.actor)
    return activeTelemetry(observer, record)
end

local function aiInCombat(boss)
    if not valid(boss) then return false end
    local controller = boss:GetController()
    local class = StaticFindObject(AI_CLASS)
    if not valid(controller) or not valid(class) then return false end
    local ai = controller:GetComponentByClass(class)
    if not valid(ai) then return false end
    local tag = ai.CurrentStateTag
    local name = tag and nameText(tag.TagName)
    return name == "AI.State.Combat" or (name and name:sub(1, 16) == "AI.State.Combat.") or false
end

local function finalBossesDead(observer)
    if not observer.damageFinalStage or #observer.currentRecords == 0 then return false end
    for _, record in ipairs(observer.currentRecords) do
        if not record.dead and not (worldAddress(record.actor) == observer.world
            and isDead(record.actor, observer.deadTag)) then return false end
    end
    return true
end

local function damageCombat(observer)
    if observer.engaged then return true end
    -- A native health notification can precede the next observer poll. Prove
    -- the owned boss is already fighting before counting that opening hit.
    for _, record in ipairs(observer.currentRecords) do
        if not record.dead and worldAddress(record.actor) == observer.world then
            if hasTag(record.actor, observer.combatTag) then return true end
            local ok, combat = pcall(aiInCombat, record.actor)
            if ok and combat then return true end
        end
    end
    return false
end

local function clampedHealth(value, maximum) return math.max(0, math.min(maximum, value)) end

local function damageEvent(observer, after, before, current, maximum)
    if observer.damageStopped then return end
    if finalBossesDead(observer) then observer.damageStopped = true; return end
    if not finite(after) or not finite(before) or not current or math.abs(current - after) > EPSILON then
        if damageCombat(observer) then observer.damageEventGap = true end
        return
    end
    if not observer.damageStarted and not damageCombat(observer) then
        observer.damageCursorHp, observer.damageCursorMax = after, maximum
        return
    end
    if not observer.damageStarted then
        observer.damageStarted = true
        observer.damageCursorHp = before
        observer.damageCoverage = true
    end
    if (observer.damageCursorMax and math.abs(maximum - observer.damageCursorMax) > EPSILON)
        or before > maximum + EPSILON or after > maximum + EPSILON then
        -- Attribute rescaling/clamping is not damage. Exclude this interval;
        -- simultaneous damage cannot be separated and is explicitly partial.
        observer.damageMaxChanged = true
        observer.damageCursorHp, observer.damageCursorMax = after, maximum
        return
    end
    if observer.damageCursorHp and math.abs(observer.damageCursorHp - before) > EPSILON then
        if math.abs(observer.damageCursorHp - after) <= EPSILON then return end -- duplicate notification
        observer.damageEventGap = true
    end
    local loss = math.max(0, clampedHealth(before, maximum) - clampedHealth(after, maximum))
    observer.damage = observer.damage + loss
    observer.damageHookPending = observer.damageHookPending + loss
    observer.damageEventCount = observer.damageEventCount + 1
    observer.damageCursorHp, observer.damageCursorMax = after, maximum
end

local function sampleDamage(observer, hp, maximum, finalDeath, playerDead)
    if not observer.damageStarted and observer.engaged then
        observer.damageStarted = true
        observer.damageCoverage = hp ~= nil and observer.lastHp ~= nil
        if not observer.damageCoverage then observer.damageEventGap = true end
        -- No event evidence can attribute a pre-poll delta to the exact first
        -- combat instant. Start a sampling baseline here rather than invent it.
        if hp and observer.lastHp and math.abs(hp - observer.lastHp) > EPSILON then
            observer.damageEventGap = true
        end
        observer.damageCursorHp, observer.damageCursorMax = hp, maximum
    elseif observer.damageStarted and not observer.damageStopped and not finalDeath and hp and observer.lastHp then
        if observer.lastMax and math.abs(maximum - observer.lastMax) <= EPSILON then
            local loss = math.max(0, clampedHealth(observer.lastHp, maximum) - clampedHealth(hp, maximum))
            local missing = math.max(0, loss - observer.damageHookPending)
            if missing > EPSILON then
                observer.damage = observer.damage + missing
                observer.damageUsedSampling = true
            end
            if observer.damageHookReady and observer.damageCursorHp and math.abs(hp - observer.damageCursorHp) > EPSILON then
                observer.damageEventGap = true
            end
        else observer.damageMaxChanged = true end
        observer.damageCoverage = true
        observer.damageCursorHp, observer.damageCursorMax = hp, maximum
    end
    if observer.damageStarted and not hp then observer.damageEventGap = true end
    observer.damageHookPending = 0
    if finalDeath or playerDead then observer.damageStopped = true end
    local exact = observer.damageStarted and observer.damageCoverage and observer.damageHookReady
        and not observer.healthHookFailed and not observer.damageUsedSampling
        and not observer.damageEventGap and not observer.damageMaxChanged
    local status = exact and "attribute-events" or (observer.damageStarted and "sampled-hp" or "unavailable")
    if not exact and observer.damageHookReady and observer.damageEventCount > 0 then status = "partial-attribute-events" end
    local note = exact and "受到伤害按本人生命属性变化累计；过量伤害仅计实际扣除生命，开战首击按首领战斗状态核对。"
        or "受到伤害仅累计可验证的生命下降；采样间同窗治疗可能抵消损伤，开战及结束边界未获事件时不推算。"
    if observer.damageMaxChanged then note = note .. "最大生命变化区间已排除。" end
    -- A valid full event window can certify zero (including invulnerability).
    -- Missing/partial observations with no loss cannot certify zero damage.
    local value = (exact or (observer.damageStarted and observer.damage > EPSILON)) and observer.damage or nil
    if value == nil then note = note .. "未取得完整零伤害证据，数值留空。" end
    return value, status, note
end

local function startHealthHook(observer)
    if type(RegisterHook) ~= "function" or not valid(StaticFindObject(HEALTH_HOOK)) then return end
    local pre, post = RegisterHook(HEALTH_HOOK, function(context, newValue, oldValue)
        local ok = pcall(function()
            if observer.closed then return end
            local actor = unpackParameter(context)
            if not valid(actor) or actor:GetAddress() ~= observer.pawnAddress or worldAddress(actor) ~= observer.world then return end
            local after, before = unpackParameter(newValue), unpackParameter(oldValue)
            local current, maximum = health(actor)
            damageEvent(observer, after, before, current, maximum)
            if not observer.engaged or not finite(after) or not finite(before) or after - before <= EPSILON then return end
            if not current or math.abs(current - after) > EPSILON then return end
            if observer.lastMax and math.abs(maximum - observer.lastMax) > EPSILON then return end
            observer.hookHealing = observer.hookHealing + after - before
            observer.healthEventSeen = true
        end)
        if not ok then observer.healthHookFailed = true end
    end)
    observer.healthHook = { pre, post }
    observer.damageHookReady = pre ~= nil and post ~= nil
end

local function asciiCsv(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local bytes = file:read("*a")
    file:close()
    if not bytes or #bytes > 8 * 1024 * 1024 then return nil end
    if bytes:sub(1, 2) == "\255\254" then
        -- Relevant actor identifiers, outcome tags and columns are ASCII.
        bytes = bytes:sub(3):gsub("(.)\0", "%1")
    end
    return bytes
end

local function readTelemetry(observer)
    os.remove(observer.csvPath)
    observer.telemetry:ExportHistoryToCSV(observer.csvPath)
    local csv = asciiCsv(observer.csvPath)
    if not csv or not csv:find(EVENT_HEADER, 1, true) then return false, {} end

    local counts, matched = {}, {}
    for line in csv:gmatch("[^\r\n]+") do
        local session, boss, at, outcome, source = line:match("^(%d+),([^,]+),([%d.]+),([^,]+),([^,]*),")
        local ownerKey = boss and (boss .. "," .. session)
        local record = ownerKey and observer.sessionOwners[ownerKey]
        if not record and boss then
            local candidate = observer.recordsByName[boss]
            if candidate and not candidate.ignoredSessions[session] then
                record = candidate
                observer.sessionOwners[ownerKey] = record
            end
        end
        if record then
            observer.sessionsByBoss[boss] = observer.sessionsByBoss[boss] or {}
            observer.sessionsByBoss[boss][session] = true
            matched[record] = true
        end
        if record and (outcome == PERFECT_GUARD or outcome:sub(1, #PERFECT_GUARD + 1) == PERFECT_GUARD .. "."
                or outcome == PERFECT_DODGE or outcome:sub(1, #PERFECT_DODGE + 1) == PERFECT_DODGE .. ".") then
            -- Native timestamps may restart in another CSV session. Separate
            -- both actor attribution and session identity before counting rows.
            local key = boss .. "," .. session .. "," .. at .. "," .. outcome .. "," .. source
            local occurrences = (counts[key] or 0) + 1
            counts[key] = occurrences
            if occurrences > (observer.seenEvents[key] or 0) then
                observer.seenEvents[key] = occurrences
                local add = true
                if record.groupSize > 1 then
                    -- Native CSV has no unique player-event ID. The same event
                    -- can be attributed to several bosses; conservatively keep
                    -- the largest occurrence count seen for any one actor.
                    local playerKey = record.stage .. "," .. at .. "," .. outcome .. "," .. source
                    local group = observer.groupEvents[playerKey]
                    if not group then group = { maximum = 0, actors = {} }; observer.groupEvents[playerKey] = group end
                    local count = (group.actors[record] or 0) + 1
                    group.actors[record] = count
                    add = count > group.maximum
                    if add then group.maximum = count end
                end
                if add then
                    if outcome:sub(1, #PERFECT_GUARD) == PERFECT_GUARD then observer.guards = observer.guards + 1
                    else observer.dodges = observer.dodges + 1 end
                end
            end
        end
    end
    return true, matched
end

local function allCurrentDead(observer)
    if #observer.currentRecords == 0 then return false end
    for _, record in ipairs(observer.currentRecords) do if not record.dead then return false end end
    return true
end

local function markDead(observer, record, at)
    if not record.dead then
        record.dead = true
        if finite(at) then record.endedAt = at end
    end
    if allCurrentDead(observer) then
        local last
        for _, current in ipairs(observer.currentRecords) do
            if finite(current.endedAt) then last = math.max(last or current.endedAt, current.endedAt) end
        end
        observer.endedAt = last
    end
end

local function sampleTelemetry(observer, record, active)
    local sampled, exported, matched = pcall(readTelemetry, observer)
    local available = sampled and exported and (active or matched[record]) or false
    if available then record.telemetryReady = true end
    return available
end

local function startBossDestroyHook(observer)
    if type(RegisterHook) ~= "function" or not valid(StaticFindObject(BOSS_DESTROY_HOOK)) then return end
    local pre, post = RegisterHook(BOSS_DESTROY_HOOK, function(_, actorParam)
        pcall(function()
            if observer.closed or not observer.engaged then return end
            local actor = unpackParameter(actorParam)
            if not actor then return end
            local record = observer.recordsByAddress[actor:GetAddress()]
            if not record then return end
            if not isDead(actor, observer.deadTag) then return end
            local gameplay = StaticFindObject("/Script/Engine.Default__GameplayStatics")
            local at = valid(gameplay) and gameplay:GetTimeSeconds(observer.pawn) or observer.lastNow
            markDead(observer, record, at)
            if observer.csvPath and valid(observer.telemetry) then
                local checked, active = pcall(activeTelemetry, observer, record)
                local available = sampleTelemetry(observer, record, checked and active)
                record.finishedTelemetry, record.finalTelemetryAvailable = true, available
            end
        end)
    end)
    observer.bossDestroyHook = { pre, post }
end

function Signals.newEncounter(pawn, bosses, telemetryCsvPath, finalStage)
    assert(valid(pawn) and type(bosses) == "table" and #bosses > 0, "challenge actors are unavailable")
    local world = worldAddress(pawn)
    assert(world, "challenge player world is unavailable")
    local hp, maximum = health(pawn)
    local observer = setmetatable({
        pawn = pawn, world = world, pawnAddress = pawn:GetAddress(),
        lastHp = hp, lastMax = maximum, guards = 0, dodges = 0, healing = 0,
        hookHealing = 0, seenEvents = {}, sessionsByBoss = {}, sessionOwners = {}, groupEvents = {},
        damage = 0, damageHookPending = 0, damageEventCount = 0, damageCursorHp = hp, damageCursorMax = maximum,
        records = {}, recordsByAddress = {}, recordsByName = {}, currentRecords = {},
        deadTag = { TagName = FName("CharacterState.Dead") },
        combatTag = { TagName = FName("CharacterState.InCombat") },
    }, Observer)
    observer:setBosses(bosses, finalStage)
    if type(telemetryCsvPath) == "string" and telemetryCsvPath:match("[/\\]PBZChallengeTelemetry%.csv$") then
        observer.csvPath = telemetryCsvPath
        local ok, telemetry = pcall(getTelemetry, pawn)
        if ok then observer.telemetry = telemetry end
    end
    pcall(startHealthHook, observer)
    pcall(startBossDestroyHook, observer)
    return observer
end

function Signals.new(pawn, boss, telemetryCsvPath)
    return Signals.newEncounter(pawn, { boss }, telemetryCsvPath)
end

function Observer:setBosses(bosses, finalStage)
    assert(not self.closed and worldAddress(self.pawn) == self.world, "challenge observer is unavailable")
    assert(type(bosses) == "table" and #bosses > 0, "challenge phase has no actors")
    assert(#self.currentRecords == 0 or allCurrentDead(self), "previous challenge phase is still alive")
    local records, used, stage = {}, {}, (self.stageCount or 0) + 1
    for _, boss in ipairs(bosses) do
        assert(valid(boss) and worldAddress(boss) == self.world, "challenge actors belong to different worlds")
        local address, name = boss:GetAddress(), boss:GetFName():ToString()
        assert(not used[address], "challenge phase contains a duplicate actor")
        used[address] = true
        local ignored = {}
        for session in pairs(self.sessionsByBoss[name] or {}) do ignored[session] = true end
        records[#records + 1] = { actor = boss, address = address, name = name, ignoredSessions = ignored,
            stage = stage, groupSize = #bosses }
    end
    -- Retain old stage metrics, not dead UObject proxies. A later native actor
    -- may legitimately reuse the memory address after Unreal garbage collection.
    for _, previous in ipairs(self.currentRecords) do
        self.recordsByAddress[previous.address] = nil
        previous.actor, previous.active = nil, nil
    end
    for _, record in ipairs(records) do
        self.records[#self.records + 1] = record
        self.recordsByAddress[record.address], self.recordsByName[record.name] = record, record
    end
    self.currentRecords, self.bosses, self.endedAt = records, {}, nil
    self.damageFinalStage = finalStage ~= false
    self.stageCount = stage
    self.hasGroup = self.hasGroup or #records > 1
    for _, record in ipairs(records) do self.bosses[#self.bosses + 1] = record.actor end
    self.boss, self.bossAddress, self.bossName = records[1].actor, records[1].address, records[1].name
    return true
end

function Observer:read(now)
    assert(not self.closed, "challenge observer is closed")
    assert(worldAddress(self.pawn) == self.world, "challenge player left the recorded world")
    if finite(now) then self.lastNow = now end
    local playerHp, playerMax = health(self.pawn)
    local playerDead = isDead(self.pawn, self.deadTag)
    local canObserveTelemetry = self.csvPath and valid(self.telemetry)
    local bossMissing, activeSession, dueFinal = false, false, false
    for _, record in ipairs(self.currentRecords) do
        local present = worldAddress(record.actor) == self.world
        if present and isDead(record.actor, self.deadTag) then markDead(self, record, now) end
        if not present and not record.dead then bossMissing = true end
        local active = false
        if canObserveTelemetry and present then
            local ok, result = pcall(activeTelemetry, self, record)
            active = ok and result == true
        end
        local combat = false
        if present and not record.dead and (not self.engaged or not record.telemetryBeginChecked or self.hasGroup) then
            local ok, aiCombat = pcall(aiInCombat, record.actor)
            combat = hasTag(record.actor, self.combatTag) or (ok and aiCombat) or false
        end
        self.engaged = self.engaged or active or combat
        if active then
            record.telemetryBeginChecked, record.everActive = true, true
        elseif canObserveTelemetry and combat and not record.dead and not playerDead and not record.telemetryBeginChecked then
            record.telemetryBeginChecked = true
            local began, result = pcall(beginTelemetry, self, record)
            active = began and result == true
            record.everActive = active
        elseif self.hasGroup and record.everActive and combat and not record.dead then
            record.coverageLost = true
        end
        record.active = active
        activeSession = activeSession or active
        if record.dead and not record.finishedTelemetry then dueFinal = true end
    end
    local bossDead = allCurrentDead(self)
    if self.engaged and not self.startedAt and finite(now) then self.startedAt = now end
    if self.engaged then
        if not playerDead and playerHp and self.lastHp and self.lastMax and math.abs(playerMax - self.lastMax) <= EPSILON then
            local observed = math.max(0, playerHp - self.lastHp)
            if observed > self.hookHealing + EPSILON then self.healthUsedSampling = true end
            self.healing = self.healing + math.max(observed, self.hookHealing)
        end
        if canObserveTelemetry and (dueFinal or (activeSession and (not finite(now) or not self.nextTelemetryAt or now >= self.nextTelemetryAt))) then
            local sampled, exported, matched = pcall(readTelemetry, self)
            for _, record in ipairs(self.currentRecords) do
                local available = sampled and exported and (record.active or matched[record]) or false
                if available then record.telemetryReady = true end
                if record.dead and not record.finishedTelemetry then
                    record.finishedTelemetry, record.finalTelemetryAvailable = true, available
                end
            end
            if finite(now) then self.nextTelemetryAt = now + 0.5 end
        end
    end
    local damageTaken, damageStatus, damageNote = sampleDamage(self, playerHp, playerMax,
        self.damageFinalStage and bossDead, playerDead)
    self.hookHealing = 0
    self.lastHp, self.lastMax = playerHp, playerMax
    self.hasHealthSample = self.hasHealthSample or playerHp ~= nil
    local healingStatus = (self.healthEventSeen and not self.healthHookFailed and not self.healthUsedSampling)
        and "attribute-events" or "sampled-hp"
    local allTelemetry, anyTelemetry = true, false
    for _, record in ipairs(self.records) do
        anyTelemetry = anyTelemetry or record.telemetryReady == true
        if not record.telemetryReady or record.coverageLost or (record.dead and not record.finalTelemetryAvailable) then
            allTelemetry = false
        end
    end
    self.telemetryReady = anyTelemetry
    local partialDefense = anyTelemetry and (not allTelemetry or self.hasGroup)
    local defenseNote = self.telemetryReady and "完美格挡和闪避按游戏战斗记录统计。"
        or "这场战斗未读到原版防御记录，完美格挡和闪避次数留空。"
    if self.telemetryReady and partialDefense then
        if self.hasGroup then
            defenseNote = "群体记录缺少唯一玩家事件ID，已保守合并相同时间、结果与来源的重复归属，统计仅供参考。"
            if not allTelemetry then defenseNote = defenseNote .. "部分首领记录还可能缺失。" end
        else
            defenseNote = #self.records == 1
                and "首领倒下时原版已清理战斗记录，格挡和闪避按最后一次读取统计，可能少记收尾事件。"
                or "部分首领未取得完整原版记录，格挡和闪避仅累计已取得部分，可能遗漏事件。"
        end
    end
    local healingNote = healingStatus == "attribute-events" and "回复量取已核对的生命变化。"
        or "回复量根据生命值采样，同一采样间隔内的受伤可能抵消部分读数。"
    return {
        engaged = self.engaged, playerDead = playerDead, bossDead = bossDead,
        bossMissing = bossMissing,
        startedAt = self.startedAt, endedAt = self.endedAt,
        perfectGuards = self.telemetryReady and self.guards or nil,
        perfectDodges = self.telemetryReady and self.dodges or nil,
        healthRestored = self.hasHealthSample and self.healing or nil,
        damageTaken = damageTaken, damageTakenStatus = damageStatus, damageTakenNote = damageNote,
        defenseStatus = self.telemetryReady and (partialDefense and "partial-native-history" or "native-history") or "unavailable",
        healingStatus = healingStatus, metricsNote = defenseNote .. healingNote .. damageNote,
    }
end

function Observer:close()
    if self.closed then return end
    self.closed = true
    if self.healthHook and type(UnregisterHook) == "function" then
        pcall(UnregisterHook, HEALTH_HOOK, self.healthHook[1], self.healthHook[2])
    end
    if self.bossDestroyHook and type(UnregisterHook) == "function" then
        pcall(UnregisterHook, BOSS_DESTROY_HOOK, self.bossDestroyHook[1], self.bossDestroyHook[2])
    end
    if self.csvPath then os.remove(self.csvPath) end
    self.pawn, self.boss, self.bosses, self.telemetry = nil, nil, nil, nil
    self.records, self.currentRecords, self.recordsByAddress, self.recordsByName = nil, nil, nil, nil
end

return Signals
