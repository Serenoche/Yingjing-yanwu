-- Private-arena wallet policy. The currency is 意识尘埃 (ConsciousnessDust),
-- saved as Player.Dust. No gameplay attribute, inventory, drop table, days,
-- equipment, collectible or shared default object is modified.
local Economy, Session = {}, {}
Session.__index = Session
local PLAYER = "/Game/RenewalContent/Prototypes/Character/BP_RenewalPlayer.BP_RenewalPlayer_C"
local REWARD_POST = PLAYER .. ":ChangeDustNumInternal"
local UI_EVENT = "/Script/GameplayAbilities.AbilitySystemBlueprintLibrary:SendGameplayEventToActor"
local UI_PAYLOAD = "/Game/PBZContent/UI/UINew/Upgrade/BP_UpdateDustTipsObj.BP_UpdateDustTipsObj_C"
local FORBIDDEN_FLAGS = 0x08023630 -- pending, CDO and archetype
local AUDIT_INTERVAL = 1

local function valid(value)
    return value ~= nil and type(value.IsValid) == "function" and value:IsValid()
end
local function unwrap(value)
    if value then
        local ok, result = pcall(function() return value:get() end)
        if ok then return result end
    end
    return value
end
local function worldId(pawn)
    if not valid(pawn) then return nil end
    local world = pawn:GetWorld()
    return valid(world) and world:GetAddress() or nil
end
local function integer(value)
    return type(value) == "number" and value % 1 == 0 and value >= -2147483648 and value <= 2147483647
end
function Session:owns(pawn)
    if self.closed then return false end
    local active, private = pcall(self.privateScope)
    if not active or private ~= true then return false end
    return valid(pawn) and pawn:GetAddress() == self.pawnAddress and worldId(pawn) == self.world
        and not pawn:IsActorBeingDestroyed() and not pawn:HasAnyFlags(FORBIDDEN_FLAGS)
        and valid(self.playerClass) and not self.playerClass:HasAnyFlags(FORBIDDEN_FLAGS) and pawn:IsA(self.playerClass)
end
function Session:clear(pawn, refresh)
    -- Gate immediately before every mutation, including late Blueprint POST
    -- callbacks. An old pointer/world alone never authorizes ordinary-save IO.
    if not self:owns(pawn) then return false, "private-economy-scope-ended" end
    local balance = pawn.ConsciousnessDust
    assert(integer(balance), "private arena currency is not a native int32")
    if balance ~= 0 then
        if refresh and balance > 0 and self.rewardReady then
            -- Exact original signed-int function: the UI consumes its payload,
            -- not the field each frame. Let this one private negative reset
            -- reach the original UI; nested POST must not recursively reset.
            self.resetting = true
            local ok, reason = pcall(function() pawn:ChangeDustNumInternal(-balance) end)
            self.resetting = false
            if not ok then self.refreshUnavailable = tostring(reason) end
        elseif refresh then self.refreshUnavailable = "original signed currency UI reset unavailable" end
        if not self:owns(pawn) then return false, "private-economy-scope-ended" end
        if refresh and pawn.ConsciousnessDust ~= 0 and not self.refreshUnavailable then
            self.refreshUnavailable = "original signed currency UI reset did not clear the wallet"
        end
        if pawn.ConsciousnessDust ~= 0 then pawn.ConsciousnessDust = 0 end
        assert(pawn.ConsciousnessDust == 0, "private arena currency clear was rejected")
        self.corrections = self.corrections + 1
    end
    return true
end
function Economy.new(pawn, privateScope)
    assert(type(privateScope) == "function", "private arena economy requires a live scope gate")
    local playerClass = StaticFindObject(PLAYER)
    assert(valid(playerClass) and not playerClass:HasAnyFlags(FORBIDDEN_FLAGS), "private arena player class is not ready")
    local self = setmetatable({ pawn = pawn, pawnAddress = valid(pawn) and pawn:GetAddress(), world = worldId(pawn),
        playerClass = playerClass, privateScope = privateScope, corrections = 0 }, Session)
    assert(self.world and self:owns(pawn), "private arena economy cannot own this player/scope")
    assert(integer(pawn.ConsciousnessDust), "private arena player has no verified currency field")
    local ok, failure = pcall(function()
        local metadata = StaticFindObject(REWARD_POST)
        self.rewardReady = valid(metadata) and not metadata:HasAnyFlags(FORBIDDEN_FLAGS)
        if type(RegisterHook) == "function" and self.rewardReady then
            local hooked, pre, post = pcall(RegisterHook, REWARD_POST, function(context)
                if self.closed or self.resetting then return end
                local checked, reason = pcall(function()
                    local actor = unwrap(context)
                    -- Script RegisterHook is POST in the pinned UE4SS build.
                    -- This corrects the instance balance before control returns;
                    -- it does not claim to cancel the original reward/tip event.
                    if self:owns(actor) then self:clear(actor) end
                end)
                if not checked and not self.lastHookError then
                    self.lastHookError = tostring(reason)
                    print("[PBZTestArenaNative] Arena currency POST fallback: " .. self.lastHookError .. "\n")
                end
            end)
            if hooked then self.hook = { pre, post }
            else self.hookUnavailable = tostring(pre) end
        else self.hookUnavailable = "original reward POST metadata unavailable" end
        local uiMetadata, payloadClass = StaticFindObject(UI_EVENT), StaticFindObject(UI_PAYLOAD)
        if type(RegisterHook) == "function" and valid(uiMetadata) and not uiMetadata:HasAnyFlags(FORBIDDEN_FLAGS)
            and valid(payloadClass) and not payloadClass:HasAnyFlags(FORBIDDEN_FLAGS) then
            self.payloadClass = payloadClass
            local hooked, pre, post = pcall(RegisterHook, UI_EVENT, function(_, actorParam, tagParam, payloadParam)
                if self.closed or self.resetting then return end
                -- This is an original native PRE hook (3 pinned UHT inputs).
                -- Cheap scope/address/tag rejection precedes payload access.
                local active, private = pcall(self.privateScope)
                if not active or private ~= true then return end
                local checked, reason = pcall(function()
                    local actor = unwrap(actorParam)
                    if not valid(actor) or actor:GetAddress() ~= self.pawnAddress then return end
                    local tag = unwrap(tagParam)
                    local tagName = tag and tag.TagName
                    local name = type(tagName) == "string" and tagName or (tagName and tagName:ToString())
                    if not name or name:lower() ~= "gameplayevent.updatedusttips" or not self:owns(actor) then return end
                    local payload = unwrap(payloadParam)
                    local object = payload and unwrap(payload.OptionalObject)
                    if not valid(object) or object:HasAnyFlags(FORBIDDEN_FLAGS) or not valid(self.payloadClass)
                        or self.payloadClass:HasAnyFlags(FORBIDDEN_FLAGS) or not object:IsA(self.payloadClass) then return end
                    assert(integer(object.CurrentDustNum) and integer(object.ChangeDustNum), "original currency UI payload has an unexpected schema")
                    -- Only this transient original payload UObject is changed.
                    -- No EventData/Actor/Tag/return/remote struct is rewritten.
                    if object.CurrentDustNum ~= 0 then object.CurrentDustNum = 0 end
                    if object.ChangeDustNum ~= 0 then object.ChangeDustNum = 0 end
                end)
                if not checked and not self.uiHookError then
                    self.uiHookError = tostring(reason)
                    self.uiSynchronized = false
                    print("[PBZTestArenaNative] Arena currency UI filter unavailable: " .. self.uiHookError .. "\n")
                end
            end)
            if hooked then self.uiHook = { pre, post }
            else self.uiHookUnavailable = tostring(pre) end
        else self.uiHookUnavailable = "original native currency UI event/payload unavailable" end
        assert(self:clear(pawn, true))
    end)
    if not ok then self:close(); error(failure, 0) end
    self.uiSynchronized = self.uiHook ~= nil and not self.refreshUnavailable
    self.status = self.hook and (self.uiSynchronized and "post-hook-and-ui-filter" or "balance-only-post") or "sampled-only"
    print("[PBZTestArenaNative] Private arena 意识尘埃=0; policy=" .. self.status
        .. "; original reward event retained; UI=" .. (self.uiSynchronized and "verified-payload-filter" or "not-assured") .. "\n")
    return self
end
function Session:update(pawn, now)
    if not self:owns(pawn) then return false, "private-economy-scope-ended" end
    assert(type(now) == "number" and now > -math.huge and now < math.huge, "private arena currency clock unavailable")
    if self.nextAt and now < self.nextAt then return true end
    self.nextAt = now + AUDIT_INTERVAL
    return self:clear(pawn)
end
function Session:close()
    self.closed = true -- late callbacks become inert even if unregister fails
    self.closeError = nil
    for _, field in ipairs({ "uiHook", "hook" }) do
        local hook = self[field]
        if hook and type(UnregisterHook) == "function" then
            local ok, reason = pcall(UnregisterHook, field == "uiHook" and UI_EVENT or REWARD_POST, hook[1], hook[2])
            if ok then self[field] = nil else self.closeError = tostring(reason) end
        end
    end
    if not self.hook and not self.uiHook then self.pawn, self.privateScope, self.playerClass, self.payloadClass = nil, nil, nil, nil end
    return self.hook == nil and self.uiHook == nil, self.closeError
end
return Economy
