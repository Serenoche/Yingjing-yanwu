-- Runtime-only practice controls for the supplied pawn and owned enemy list.
local CombatSpawn = require("CombatSpawn")
local EncounterEngage = require("EncounterEngage")
local Health = require("Health")
local HealthGuard = require("EnemyHealthGuard")
local PlayerDamageGuard = require("PlayerDamageGuard")
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
        state = { ai = true, enemyRegen = false, damageMode = "off", invulnerable = false, infiniteUltimate = false, infiniteSpiritShadow = false },
        startedCombat = false }, Mode)
end

function Mode:getState()
    return { ai = self.state.ai, enemyRegen = self.state.enemyRegen,
        damageMode = self.state.damageMode or "off", invulnerable = self.state.invulnerable, infiniteUltimate = self.state.infiniteUltimate,
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

function Mode:applyInvulnerability()
    local tag = { TagName = FName(INVULNERABLE) }
    local before = self.asc:GetGameplayTagCount(tag)
    -- Use the same original single-tag path as the existing invincible mode.
    local added = required(SINGLE_TAG_LIBRARY):AddLooseGameplayTag(self.pawn, tag, false)
    assert(added == true, "practice invulnerability tag could not be applied")
    self.invulnerabilityOwned, self.invulnerabilityTag = true, tag
    if self.asc:GetGameplayTagCount(tag) ~= before + 1 then
        self:removeInvulnerability()
        error("practice invulnerability tag count did not increase by one")
    end
end

function Mode:removeNoDamage()
    if self.noDamageGuard then self.noDamageGuard:close(); self.noDamageGuard = nil end
end

function Mode:setDamageMode(name)
    assert(not self.closed and (name == "off" or name == "no_damage" or name == "invulnerable"), "invalid damage mode")
    assert(self:ownsPlayer(self.pawn), "practice player changed")
    -- Selection advances even if an optional native effect fails. Keep this
    -- cursor separate from the actually active state shown by the HUD, so a
    -- broken no-damage asset cannot trap F7 before the old invincible mode.
    self.damageCycleCursor = name
    if (self.state.damageMode or "off") == name then return true end
    local ok, why = pcall(function()
        self:removeNoDamage()
        self:removeInvulnerability()
        self.state.damageMode, self.state.invulnerable = "off", false
        if name == "no_damage" then
            self.noDamageGuard = PlayerDamageGuard.new(self.pawn)
            self.noDamageGuard:enable()
        elseif name == "invulnerable" then
            self:applyInvulnerability()
        end
    end)
    if not ok then
        -- Release only our native effect/tag. Retain failed cleanup references
        -- so close() can retry instead of silently dropping a live handle.
        local cleaned, cleanup = pcall(function() self:removeNoDamage(); self:removeInvulnerability() end)
        local checked, active = pcall(function() return self.noDamageGuard and self.noDamageGuard:active() end)
        self.state.damageMode = self.invulnerabilityOwned and "invulnerable" or
            (checked and active and "no_damage" or "off")
        self.state.invulnerable = self.invulnerabilityOwned == true
        self.lastError = name == "no_damage" and "无伤模式暂不可用，再按一次切换无敌" or "防护模式暂不可用，可继续切换"
        print("[PBZTestArenaNative] Practice damage mode: " .. tostring(why) .. (cleaned and "" or "; cleanup=" .. tostring(cleanup)) .. "\n")
        return false, tostring(why)
    end
    self.state.damageMode, self.state.invulnerable = name, name == "invulnerable"
    self.lastError = nil
    print("[PBZTestArenaNative] Practice damageMode=" .. name .. "; native binding verified\n")
    return true
end

function Mode:cycleDamageMode()
    local following = { off = "no_damage", no_damage = "invulnerable", invulnerable = "off" }
    return self:setDamageMode(following[self.damageCycleCursor or self.state.damageMode or "off"])
end

function Mode:set(name, enabled)
    assert(not self.closed and OPTIONS[name] and type(enabled) == "boolean", "invalid practice option")
    assert(self:ownsPlayer(self.pawn), "practice player changed")
    if name == "invulnerable" then
        local ok, why = self:setDamageMode(enabled and "invulnerable" or "off")
        assert(ok, why) -- retain the explicit binary setter's historical failure contract
        return true
    end
    if self.state[name] == enabled then return true end
    if name == "enemyRegen" then
        local ok, failure = pcall(function()
            for _, entry in pairs(self.enemies) do
                if enabled then
                    -- A key can run after death but before the next control tick.
                    -- Never create a guard for a retired or foreign-world actor.
                    if valid(entry.actor) and not entry.actor:IsActorBeingDestroyed() then
                        assert(worldOf(entry.actor) == self.world, "practice enemy belongs to another world")
                        local _, _, dead = Health.read(entry.actor)
                        if not dead then
                            entry.healthGuard = entry.healthGuard or HealthGuard.new(entry.actor)
                            entry.healthGuard:enable()
                        end
                    end
                elseif entry.healthGuard then
                    entry.healthGuard:close(); entry.healthGuard = nil
                end
            end
        end)
        if not ok then
            -- The option must never claim lethal-hit protection while its
            -- native effect failed. Preserve any unremoved handle for cleanup.
            if enabled then
                for _, entry in pairs(self.enemies) do
                    if entry.healthGuard then
                        local removed = pcall(entry.healthGuard.close, entry.healthGuard)
                        if removed then entry.healthGuard = nil end
                    end
                end
            end
            self.lastError = "首领回血与锁血暂不可用，详见日志"
            print("[PBZTestArenaNative] Practice health guard: " .. tostring(failure) .. "\n")
            return false, tostring(failure)
        end
        self.lastError = nil
    end
    if RESOURCES[name] and enabled then
        -- Reject unsupported/missing native structs while the option is still
        -- off. Never fall back to rebuilding a lossy FGameplayAttribute table.
        local ok, failure = pcall(function()
            for _, field in ipairs(RESOURCES[name].fields) do nativeAttribute(self, field) end
            resourceSnapshot(self.pawn, RESOURCES[name])
        end)
        if not ok then return self:resourceFault(name, failure) end
    end

    self.state[name] = enabled
    if name == "ai" then
        for _, entry in pairs(self.enemies) do entry.engageRequest = nil end
    end
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
    if entry.healthGuard then entry.healthGuard:close(); entry.healthGuard = nil end
    if valid(entry.actor) and worldOf(entry.actor) == self.world then
        local _, _, dead = Health.read(entry.actor)
        if dead then return end
        local started = aiState(entry.actor)
        if started ~= entry.originalAI then CombatSpawn.challengeAI(entry.actor, entry.originalAI) end
    end
end

function Mode:update(pawn, bosses, awake, now, externalAI)
    assert(not self.closed and type(bosses) == "table" and finite(now), "invalid practice update")
    if not self:ownsPlayer(pawn) then self:close(); return false, "practice player or world changed" end
    local seen = {}
    -- Retired group members remain in the complete challenge roster.
    -- Only this controller filters them; victory and phase accounting retain
    -- their original actors. A live foreign-world actor is still rejected.
    for _, actor in ipairs(bosses) do
        if valid(actor) and not actor:IsActorBeingDestroyed() then
            assert(worldOf(actor) == self.world, "practice enemy belongs to another world")
            -- Native death can remove the controller before destroying the
            -- actor. Do not request AI or create a new entry for that corpse.
            local hp, maximum, dead = Health.read(actor)
            if dead then self.startedCombat = true
            else
                local address = actor:GetAddress()
                assert(not seen[address], "duplicate practice enemy")
                seen[address] = true
                local entry = self.enemies[address]
                if not entry then
                    entry = { actor = actor, originalAI = aiState(actor), lastDamage = now }
                    self.enemies[address] = entry
                end
                if entry.health and hp and hp < entry.health - EPSILON then self.startedCombat = true end
                entry.dead = false
                if self.state.enemyRegen then
                    entry.healthGuard = entry.healthGuard or HealthGuard.new(actor)
                    entry.healthGuard:enable()
                elseif entry.healthGuard then
                    entry.healthGuard:close(); entry.healthGuard = nil
                end
                local running = self.state.ai and awake == true
                if externalAI == true and self.state.ai == true then
                    -- Continue resource/health observation, while the stage
                    -- coordinator alone starts and confirms the new phase's AI.
                    -- An explicit user AI-off remains authoritative below.
                elseif not running then
                    if aiState(actor) then CombatSpawn.challengeAI(actor, false) end
                    entry.resumeCombat = true
                    entry.engageRequest = nil
                elseif entry.resumeCombat then
                    -- Retrying native acquisition preserves hatred; StopAI never
                    -- turns a practice toggle into a fresh encounter or a heal.
                    entry.engageRequest = entry.engageRequest or {}
                    if EncounterEngage.start(actor, pawn, entry.engageRequest, now) then
                        entry.resumeCombat, entry.engageRequest = nil, nil
                    end
                elseif not aiState(actor) then
                    entry.engageRequest = entry.engageRequest or {}
                    if EncounterEngage.start(actor, pawn, entry.engageRequest, now) then
                        entry.resumeCombat, entry.engageRequest = nil, nil
                    else entry.resumeCombat = true end
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
    end
    for address, entry in pairs(self.enemies) do
        if not seen[address] then self:restoreEnemy(entry); self.enemies[address] = nil end
    end
    if not alive(pawn) and (self.state.damageMode or "off") ~= "off" then
        self:removeNoDamage(); self:removeInvulnerability()
        self.state.damageMode, self.state.invulnerable = "off", false
    elseif self.state.damageMode == "no_damage" then
        local ok, why = pcall(self.noDamageGuard.enable, self.noDamageGuard)
        if not ok then self:setDamageMode("off"); self.lastError = "无伤模式已关闭，详见日志"; print("[PBZTestArenaNative] No-damage verification: " .. tostring(why) .. "\n") end
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
    local released, releaseError = pcall(self.removeNoDamage, self)
    if not released then failures[#failures + 1] = tostring(releaseError) end
    local removed, reason = pcall(self.removeInvulnerability, self)
    if not removed then failures[#failures + 1] = tostring(reason) end
    for address, entry in pairs(self.enemies) do
        local restored, failure = pcall(self.restoreEnemy, self, entry)
        if restored then self.enemies[address] = nil else failures[#failures + 1] = tostring(failure) end
    end
    self.state = { ai = false, enemyRegen = false, damageMode = "off", invulnerable = false, infiniteUltimate = false, infiniteSpiritShadow = false }
    self.damageCycleCursor = "off"
    self.startedCombat = false
    self.attributeReady = nil
    self.resources, self.lastError, self.lastErrorOption = nil, nil, nil
    assert(#failures == 0, table.concat(failures, "; "))
    return true
end

return Practice
