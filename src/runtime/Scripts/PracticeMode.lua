-- Runtime-only practice controls for the supplied pawn and owned enemy list.
local CombatSpawn = require("CombatSpawn")
local EncounterEngage = require("EncounterEngage")
local Health = require("Health")
local Practice = {}
local Mode = {}
Mode.__index = Mode

local ABILITY_LIBRARY = "/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary"
local SINGLE_TAG_LIBRARY = "/Script/ProjectPBZ.Default__PBZAbilityBlueprintLibrary"
local ATTRIBUTE_LIBRARY = "/Script/SGameAttributes.Default__AttributeUtils"
local VALID_ATTRIBUTE = "/Script/GameplayAbilities.AbilitySystemBlueprintLibrary:IsValid"
local GAMEPLAY_EFFECT = "/Script/GameplayAbilities.GameplayEffect"
local PENDING = 0x08023600
local ATTRIBUTE_EFFECTS = {
    UltimateCharge = "/PBZCombatAsset/Config/AttributesModifyEffect/GE_MA_UltimateCharge_1_Override.GE_MA_UltimateCharge_1_Override",
    UltimateChargeCount = "/PBZCombatAsset/Config/AttributesModifyEffect/GE_MA_UltimateChargeCount_1_Override.GE_MA_UltimateChargeCount_1_Override",
    SpiritShadow = "/PBZCombatAsset/Config/AttributesModifyEffect/GE_MA_SpiritShadow_1_Override.GE_MA_SpiritShadow_1_Override",
}
local INVULNERABLE = "CharacterState.Stand.Invulnerable.Debug"
local DEAD = "CharacterState.Dead"
local HEAL_DELAY, EPSILON, REFILL_INTERVAL = 1.2, 0.01, 0.05
local OPTIONS = { ai = true, enemyRegen = true, invulnerable = true, infiniteUltimate = true, infiniteSpiritShadow = true }
local RESOURCES = {
    infiniteUltimate = { label = "无限大招", fields = { "UltimateChargeCount", "UltimateCharge" } },
    infiniteSpiritShadow = { label = "无限暗源", fields = { "SpiritShadow" } },
}
local VERIFY_SECONDS, MAX_MISSES = 0.5, 3

local function valid(object) return object ~= nil and object:IsValid() end
local function finite(value) return type(value) == "number" and value > -math.huge and value < math.huge end
local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "missing practice interface: " .. path)
    return object
end
local function unwrap(value)
    local ok, result = pcall(function() return value:get() end)
    if ok then return result end
    return value
end
local function stringValue(value)
    return type(value) == "string" and value or value:ToString()
end
local function nativeAttribute(mode, field)
    local path = assert(ATTRIBUTE_EFFECTS[field], "unknown practice attribute")
    local effect = StaticFindObject(path)
    mode.attributeReady = mode.attributeReady or {}
    if not valid(effect) or mode.attributeReady[field] ~= effect:GetAddress() or effect:HasAnyFlags(PENDING) then
        -- StaticFind can expose objects from an incomplete async package. The
        -- original registry loader must confirm a full load at least once.
        local loaded, asset, _, didLoad = pcall(LoadAsset, path)
        assert(loaded and didLoad == true and valid(asset), "practice attribute package could not be fully loaded: " .. field)
        effect = StaticFindObject(path)
    end
    assert(valid(effect) and not effect:HasAnyFlags(PENDING), "practice attribute asset is not initialized: " .. field)
    local effectClass = required(GAMEPLAY_EFFECT)
    local defaults = effectClass:GetCDO()
    assert(not effectClass:HasAnyFlags(PENDING) and valid(defaults) and not defaults:HasAnyFlags(PENDING)
        and effect:IsA(effectClass), "practice attribute source is not a ready native gameplay effect")
    -- Read the original asset's live FGameplayAttribute. UFunction struct
    -- returns become Lua tables in this pinned bridge, dropping FieldPath.
    -- A native UScriptStruct property is copied with CopyCompleteValue instead.
    -- Reacquire on every refill; never retain a pointer into a GC'd asset.
    local modifiers = effect.Modifiers
    -- This pinned LuaTArray indexer grows even on an out-of-range GET. Both
    -- original assets have exactly one modifier; reject before any index read.
    assert(#modifiers == 1, "practice attribute effect has an unexpected modifier layout: " .. field)
    local modifier = unwrap(modifiers[1])
    local attribute = unwrap(modifier.Attribute)
    assert(type(attribute) == "userdata" and attribute:type() == "UScriptStruct" and valid(attribute)
        and attribute:IsMappedToObject() and attribute:IsMappedToProperty()
        and stringValue(attribute:GetFName()) == "GameplayAttribute",
        "practice requires a mapped native gameplay attribute, not a Lua table: " .. field)
    assert(stringValue(attribute.AttributeName) == field, "practice attribute asset names another resource")
    -- IsValid is also a LuaUObject method. Resolve this exact reflected static
    -- UFunction explicitly so validation really checks the gameplay attribute.
    assert(required(VALID_ATTRIBUTE)(required(ABILITY_LIBRARY), attribute) == true,
        "practice native gameplay attribute is invalid: " .. field)
    mode.attributeReady[field] = effect:GetAddress()
    return attribute
end
local function resourceSnapshot(pawn, resource)
    local attributes, snapshot = pawn.AttributeSetBase, {}
    assert(valid(attributes), "practice player attributes are unavailable")
    for _, field in ipairs(resource.fields) do
        local value, maximum = attributes[field].CurrentValue, attributes[field .. "_Max"].CurrentValue
        assert(finite(value) and finite(maximum) and maximum >= 0, "practice resource is not initialized: " .. field)
        snapshot[field] = { value = value, maximum = maximum }
    end
    return snapshot
end
local function resourceReady(name, snapshot)
    -- A complete ultimate stock is usable even if the engine converts the
    -- progress bar into a charge and resets that bar during the native callback.
    local charges = snapshot.UltimateChargeCount
    if name == "infiniteUltimate" and charges.maximum > 0 then return charges.value >= charges.maximum - EPSILON end
    for _, item in pairs(snapshot) do
        if item.maximum > 0 and item.value < item.maximum - EPSILON then return false end
    end
    return true
end
local function worldOf(object)
    if not valid(object) then return nil end
    local world = object:GetWorld()
    return valid(world) and world:GetAddress() or nil
end
local function alive(pawn)
    local asc, attributes = pawn.AbilitySystemComponent, pawn.AttributeSetBase
    return valid(asc) and valid(attributes) and attributes.Health.CurrentValue > 0
        and asc:GetGameplayTagCount({ TagName = FName(DEAD) }) == 0
end
local function aiState(actor)
    local ai = CombatSpawn.ai(actor)
    assert(type(ai.bAIStarted) == "boolean", "practice enemy AI state is unavailable")
    return ai.bAIStarted
end

function Practice.new(pawn, controller)
    assert(valid(pawn) and worldOf(pawn), "practice player is unavailable")
    local asc = pawn.AbilitySystemComponent
    assert(valid(asc), "practice ability system is unavailable")
    if controller ~= nil then
        assert(valid(controller) and worldOf(controller) == worldOf(pawn)
            and controller:K2_GetPawn():GetAddress() == pawn:GetAddress(), "practice controller owns another player")
    end
    return setmetatable({ pawn = pawn, controller = controller, world = worldOf(pawn),
        pawnAddress = pawn:GetAddress(), asc = asc, ascAddress = asc:GetAddress(), enemies = {},
        state = { ai = true, enemyRegen = false, invulnerable = false, infiniteUltimate = false, infiniteSpiritShadow = false },
        startedCombat = false }, Mode)
end

function Mode:getState()
    return { ai = self.state.ai, enemyRegen = self.state.enemyRegen,
        invulnerable = self.state.invulnerable, infiniteUltimate = self.state.infiniteUltimate,
        infiniteSpiritShadow = self.state.infiniteSpiritShadow, lastError = self.lastError }
end

function Mode:resourceFault(name, reason)
    self.state[name] = false
    if self.resources then self.resources[name] = nil end
    self.lastErrorOption = name
    self.lastError = RESOURCES[name].label .. "暂不可用，已关闭"
    print("[PBZTestArenaNative] Practice resource disabled: " .. name .. "; " .. tostring(reason) .. "\n")
    return false, tostring(reason)
end

function Mode:ownsPlayer(pawn)
    return valid(pawn) and pawn:GetAddress() == self.pawnAddress and worldOf(pawn) == self.world
        and valid(pawn.AbilitySystemComponent) and pawn.AbilitySystemComponent:GetAddress() == self.ascAddress
end

function Mode:removeInvulnerability()
    if not self.invulnerabilityOwned then return end
    if self:ownsPlayer(self.pawn) then
        local removed = required(SINGLE_TAG_LIBRARY):RemoveLooseGameplayTag(self.pawn, self.invulnerabilityTag, false)
        assert(removed == true, "practice invulnerability tag could not be released")
    end
    self.invulnerabilityOwned, self.invulnerabilityTag = false, nil
end

function Mode:set(name, enabled)
    assert(not self.closed and OPTIONS[name] and type(enabled) == "boolean", "invalid practice option")
    assert(self:ownsPlayer(self.pawn), "practice player changed")
    if self.state[name] == enabled then return true end
    if RESOURCES[name] and enabled then
        -- Reject unsupported/missing native structs while the option is still
        -- off. Never fall back to rebuilding a lossy FGameplayAttribute table.
        local ok, failure = pcall(function()
            for _, field in ipairs(RESOURCES[name].fields) do nativeAttribute(self, field) end
            resourceSnapshot(self.pawn, RESOURCES[name])
        end)
        if not ok then return self:resourceFault(name, failure) end
    end
    if name == "invulnerable" then
        if enabled then
            local tag = { TagName = FName(INVULNERABLE) }
            local before = self.asc:GetGameplayTagCount(tag)
            -- The existing boss adapter uses this original single-tag API.
            -- Avoid returning a tag container whose TArray wrappers can outlive
            -- the temporary UFunction result buffer in this pinned Lua bridge.
            local added = required(SINGLE_TAG_LIBRARY):AddLooseGameplayTag(self.pawn, tag, false)
            assert(added == true, "practice invulnerability tag could not be applied")
            -- Record ownership before readback, so even a failed verification
            -- can release our one count rather than leaking an untracked tag.
            self.invulnerabilityOwned, self.invulnerabilityTag = true, tag
            if self.asc:GetGameplayTagCount(tag) ~= before + 1 then
                self:removeInvulnerability()
                error("practice invulnerability tag count did not increase by one")
            end
        else self:removeInvulnerability() end
    end
    self.state[name] = enabled
    if RESOURCES[name] then
        self.resources = self.resources or {}
        self.resources[name] = nil
        if self.lastErrorOption == name then self.lastErrorOption, self.lastError = nil, nil end
    end
    if name == "invulnerable" or RESOURCES[name] then
        print("[PBZTestArenaNative] Practice " .. name .. "=" .. tostring(enabled) .. "; native binding verified\n")
    end
    return true
end

function Mode:refillResource(name, now)
    local resource = RESOURCES[name]
    self.resources = self.resources or {}
    local tracking = self.resources[name] or { misses = 0 }
    self.resources[name] = tracking
    if tracking.nextAt and now < tracking.nextAt then return end
    tracking.nextAt = now + REFILL_INTERVAL
    local snapshot = resourceSnapshot(self.pawn, resource)
    if resourceReady(name, snapshot) then tracking.pending, tracking.misses = nil, 0; return end
    if tracking.pending then
        local progressed = false
        for field, item in pairs(snapshot) do
            if item.value > tracking.pending.before[field].value + EPSILON then progressed = true end
        end
        if progressed then tracking.pending, tracking.misses = nil, 0
        elseif now - tracking.pending.at >= VERIFY_SECONDS then
            tracking.pending, tracking.misses = nil, tracking.misses + 1
            if tracking.misses >= MAX_MISSES then
                local values = {}
                for _, field in ipairs(resource.fields) do
                    values[#values + 1] = field .. "=" .. snapshot[field].value .. "/" .. snapshot[field].maximum
                end
                error("native resource made no progress across three verification windows: " .. table.concat(values, ","))
            end
        end
    end
    tracking.pending = tracking.pending or { at = now, before = snapshot }
    for _, field in ipairs(resource.fields) do
        local value, maximum = snapshot[field].value, snapshot[field].maximum
        if maximum > 0 and value < maximum - EPSILON then
            local attribute = nativeAttribute(self, field)
            required(ATTRIBUTE_LIBRARY):ModifyCharacterAttributeValue(self.pawn, attribute, 3, maximum)
            -- Native post-execute callbacks may settle on the next tick or
            -- convert full progress into a charge. Never fail the encounter
            -- because this same call's CurrentValue is not exactly its input.
        end
    end
end

function Mode:restoreEnemy(entry)
    if valid(entry.actor) and worldOf(entry.actor) == self.world then
        local _, _, dead = Health.read(entry.actor)
        if dead then return end
        local started = aiState(entry.actor)
        if started ~= entry.originalAI then CombatSpawn.challengeAI(entry.actor, entry.originalAI) end
    end
end

function Mode:update(pawn, bosses, awake, now)
    assert(not self.closed and type(bosses) == "table" and finite(now), "invalid practice update")
    if not self:ownsPlayer(pawn) then self:close(); return false, "practice player or world changed" end
    local seen = {}
    for _, actor in ipairs(bosses) do
        assert(valid(actor) and worldOf(actor) == self.world, "practice enemy belongs to another world")
        local address = actor:GetAddress()
        assert(not seen[address], "duplicate practice enemy")
        seen[address] = true
        local entry = self.enemies[address]
        if not entry then
            entry = { actor = actor, originalAI = aiState(actor), lastDamage = now }
            self.enemies[address] = entry
        end
        local hp, maximum, dead = Health.read(actor)
        if (entry.health and hp and hp < entry.health - EPSILON) or dead then self.startedCombat = true end
        entry.dead = dead
        if not dead then
            local running = self.state.ai and awake == true
            if not running then
                if aiState(actor) then CombatSpawn.challengeAI(actor, false) end
                entry.resumeCombat = true
            elseif entry.resumeCombat then
                -- Retrying native acquisition preserves hatred; StopAI never
                -- turns a practice toggle into a fresh encounter or a heal.
                if EncounterEngage.start(actor, pawn) then entry.resumeCombat = nil end
            elseif not aiState(actor) then
                if EncounterEngage.start(actor, pawn) then entry.resumeCombat = nil else entry.resumeCombat = true end
            end
            if hp and maximum then
                if (entry.health and hp < entry.health - EPSILON) or (entry.maximum and math.abs(maximum - entry.maximum) > EPSILON) then
                    entry.lastDamage = now
                end
                if self.state.enemyRegen and hp < maximum - EPSILON and now - entry.lastDamage >= HEAL_DELAY then
                    local restored, reason, current, currentMax = Health.restore(actor, maximum, hp)
                    if restored then hp, maximum = current or maximum, currentMax or maximum
                    elseif reason == "stock full-health effect did not restore the enemy" then error(reason) end
                    entry.lastDamage = now
                end
                entry.health, entry.maximum = hp, maximum
            end
        end
    end
    for address, entry in pairs(self.enemies) do
        if not seen[address] then self:restoreEnemy(entry); self.enemies[address] = nil end
    end
    if alive(pawn) then
        for _, name in ipairs({ "infiniteUltimate", "infiniteSpiritShadow" }) do
            if self.state[name] then
                local ok, failure = pcall(self.refillResource, self, name, now)
                if not ok then self:resourceFault(name, failure) end
            end
        end
    end
    return true, self.lastError
end

function Mode:close()
    self.closed = true
    local failures = {}
    local removed, reason = pcall(self.removeInvulnerability, self)
    if not removed then failures[#failures + 1] = tostring(reason) end
    for address, entry in pairs(self.enemies) do
        local restored, failure = pcall(self.restoreEnemy, self, entry)
        if restored then self.enemies[address] = nil else failures[#failures + 1] = tostring(failure) end
    end
    self.state = { ai = false, enemyRegen = false, invulnerable = false, infiniteUltimate = false, infiniteSpiritShadow = false }
    self.startedCombat = false
    self.attributeReady = nil
    self.resources, self.lastError, self.lastErrorOption = nil, nil, nil
    assert(#failures == 0, table.concat(failures, "; "))
    return true
end

return Practice
