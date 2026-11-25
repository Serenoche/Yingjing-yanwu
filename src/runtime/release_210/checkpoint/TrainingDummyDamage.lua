local Damage = {}
Damage.__index = Damage

local ABILITY = "/PBZCombatAsset/Prototypes/Abilities/GA_CommonUtilitiesPassive.GA_CommonUtilitiesPassive_C"
local ON_TAKEN = ABILITY .. ":OnTaken"
local ABILITY_LIBRARY = "/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary"
local ABILITY_UTILS = "/Script/SGameUtils.Default__AbilityUtils"
local GAMEPLAY = "/Script/Engine.Default__GameplayStatics"
local PAYLOAD = "/Script/SGameAttributes.DamageTakenPayload"
local GENERAL = "Damage.Damage.Target.GeneralDamage"
local TRUE_DAMAGE = "Damage.Damage.Target.TrueDamage"
local PENDING = 0x08023600

local function valid(object)
    return object and type(object.IsValid) == "function" and object:IsValid()
end

local function owns(object, address)
    return address ~= nil and valid(object) and object:GetAddress() == address
end

local function unwrap(value)
    if (type(value) == "table" or type(value) == "userdata") and type(value.IsValid) ~= "function" then
        local get = value.get or value.Get
        if type(get) == "function" then return get(value) end
    end
    return value
end

local function addressOfWorld(actor)
    local world = valid(actor) and actor:GetWorld()
    return valid(world) and world:GetAddress() or nil
end

local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "missing training dummy damage interface: " .. path)
    return object
end

local function abilityClass()
    local class = StaticFindObject(ABILITY)
    if not valid(class) or class:HasAnyFlags(PENDING) then
        LoadAsset(ABILITY)
        class = required(ABILITY)
    end
    assert(not class:HasAnyFlags(PENDING), "training dummy damage listener class is still loading")
    local defaults = class:GetCDO()
    assert(valid(defaults) and not defaults:HasAnyFlags(PENDING), "training dummy damage listener defaults are unavailable")
    return class
end

local function readHealthDamage(payload)
    local general, generalComponents, trueDamage, trueComponents = 0, 0, 0, 0
    local data = payload:GetDamageData()
    local function add(key, value)
        key, value = unwrap(key), unwrap(value)
        local tag = type(key) == "string" and key or key and key.TagName
        local name = type(tag) == "string" and tag or tag and tag:ToString() or ""
        if type(value) ~= "number" or value <= 0 or value ~= value or value == math.huge then return end
        if name == GENERAL then general = value
        elseif name:sub(1, #GENERAL + 1) == GENERAL .. "." then generalComponents = generalComponents + value
        elseif name == TRUE_DAMAGE then trueDamage = value
        elseif name:sub(1, #TRUE_DAMAGE + 1) == TRUE_DAMAGE .. "." then trueComponents = trueComponents + value end
    end

    -- UE4SS can marshal a returned TMap as a Lua table of wrapped entries.
    if data and type(data.ForEach) == "function" then
        data:ForEach(add)
    else
        assert(type(data) == "table", "training dummy damage map is unavailable")
        for key, value in pairs(data) do add(key, value) end
    end
    -- Native hits carry typed entries. Use a parent-only value if no typed entry exists.
    return (generalComponents > 0 and generalComponents or general) + (trueComponents > 0 and trueComponents or trueDamage)
end

function Damage:sample(context, event)
    if not self.collecting or not owns(unwrap(context), self.abilityAddress) then return end
    if not owns(self.actor, self.actorAddress) or addressOfWorld(self.actor) ~= self.world then return end
    local data = unwrap(event)
    local payload = data and unwrap(data.OptionalObject)
    if not valid(payload) or not payload:IsA(self.payloadClass) then return end
    local target = unwrap(payload.TargetActor)
    if not valid(target) then target = payload:GetTargetActor() end
    if not owns(target, self.actorAddress) then return end

    local amount = readHealthDamage(payload)
    if amount <= 0 then return end
    local now = self.gameplay:GetTimeSeconds(self.actor)
    assert(type(now) == "number" and now >= 0 and now < math.huge, "training dummy damage clock is unavailable")
    self.firstHit = self.firstHit or now
    self.lastHit = now
    self.total, self.last, self.hits = self.total + amount, amount, self.hits + 1
    if not self.observed then
        self.observed = true
        print(("[PBZTrainingDummy] First native damage event: %.3f HP\n"):format(amount))
    end
end

function Damage:reset()
    self.firstHit, self.lastHit, self.issue = nil, nil, nil
    self.total, self.last, self.hits = 0, 0, 0
end

function Damage:snapshot()
    local elapsed = self.firstHit and math.max(1, self.lastHit - self.firstHit) or 1
    return { total = self.total, last = self.last, hits = self.hits, dps = self.total / elapsed, issue = self.issue }
end

function Damage:close()
    self.collecting = false
    local failures = {}
    if self.pre ~= nil then
        local ok, problem = pcall(UnregisterHook, ON_TAKEN, self.pre, self.post)
        if ok then self.pre, self.post = nil, nil else failures[#failures + 1] = tostring(problem) end
    end
    if self.handle then
        local ok, problem = pcall(function()
            if owns(self.asc, self.ascAddress) and addressOfWorld(self.actor) == self.world then
                self.asc:ClearAbility(self.handle)
            end
        end)
        if ok then self.handle = nil else failures[#failures + 1] = tostring(problem) end
    end
    assert(#failures == 0, table.concat(failures, " / "))
end

function Damage.new(actor, pawn)
    local world = addressOfWorld(actor)
    assert(world and addressOfWorld(pawn) == world, "training dummy damage owner is in another world")
    local asc = actor.AbilitySystemComponent
    assert(valid(asc), "training dummy damage owner has no ability system")
    local class = abilityClass()
    local library = required(ABILITY_LIBRARY)
    local utils = required(ABILITY_UTILS)
    required(ON_TAKEN)
    required("/Script/SGameUtils.AbilityUtils:FindAbilityByClass")
    required("/Script/GameplayAbilities.AbilitySystemBlueprintLibrary:GetGameplayAbilityFromSpecHandle")
    required(PAYLOAD .. ":GetDamageData")
    required(PAYLOAD .. ":GetTargetActor")
    local self = setmetatable({ actor = actor, actorAddress = actor:GetAddress(), world = world,
        asc = asc, ascAddress = asc:GetAddress(), gameplay = required(GAMEPLAY), payloadClass = required(PAYLOAD) }, Damage)
    self:reset()

    local ok, failure = pcall(function()
        local found = utils:FindAbilityByClass(asc, class)
        local id = found and found.Handle
        assert(type(id) == "number" and id % 1 == 0, "training dummy damage ability lookup failed")
        local spec = { Handle = id }
        if id < 0 then
            -- Some training actors lack the normal common passive. Grant it only to this dummy.
            local handle = asc:K2_GiveAbility(class, 1, -1)
            id = handle and handle.Handle
            assert(type(id) == "number" and id >= 0 and id % 1 == 0, "training dummy damage ability grant failed")
            self.handle = { Handle = id }
            spec = self.handle
        end
        local ability = library:GetGameplayAbilityFromSpecHandle(asc, spec, {})
        if not valid(ability) or not library:IsGameplayAbilityActive(ability) then
            assert(asc:TryActivateAbility(spec, false) == true, "training dummy damage ability activation failed")
            ability = library:GetGameplayAbilityFromSpecHandle(asc, spec, {})
        end
        assert(valid(ability) and ability:IsA(class) and not ability:HasAnyFlags(0x10 + PENDING)
            and owns(ability:GetAvatarActorFromActorInfo(), self.actorAddress),
            "training dummy damage listener instance could not be verified")
        self.abilityAddress = ability:GetAddress()

        -- The stock target passive receives GameplayEvent.Damage.Taken. Observe its payload without changing the event.
        self.pre, self.post = RegisterHook(ON_TAKEN, function(context, event)
            local ok, problem = pcall(self.sample, self, context, event)
            if not ok and not self.issue then
                self.issue = tostring(problem)
                print("[PBZTrainingDummy] Native damage sample skipped: " .. self.issue .. "\n")
            end
        end)
        assert(self.pre ~= nil and self.post ~= nil, "training dummy damage hook could not register")
        self.collecting = true
    end)
    if not ok then
        local cleaned, cleanupFailure = pcall(self.close, self)
        if not cleaned then failure = tostring(failure) .. " / " .. tostring(cleanupFailure) end
        error(failure, 0)
    end
    return self
end

return Damage
