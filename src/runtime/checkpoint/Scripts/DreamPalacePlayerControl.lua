local Control = {}
local Session = {}
Session.__index = Session

local SCALE = 1 / 3
local EPSILON = 0.0001
local ELECTRIFIED_SECONDS = 0.6
local ELECTRIFIED_ASSET = "/PBZCombatAsset/Prototypes/GameplayEffects/Inflictions/GA_Electrified.GA_Electrified"
local ELECTRIFIED_START = ELECTRIFIED_ASSET .. "_C:OnFinish_BA0FA7504042B3D561B2128960B4EF33"
local ELECTRIFIED_TIME = "Start TIme"
local LIE_TIMER_CLASS = "/PBZCombatAsset/Prototypes/Hitreact/BP_HitreactEventListener_LieTimer.BP_HitreactEventListener_LieTimer"
local REGISTER_HITREACT = "/Script/SGameCombatSystem.HitreactEventListenerBase:RegisterOnActor"
local CLASS_DEFAULT_OBJECT = 0x10

local function valid(object) return object and object:IsValid() end
local function same(a, b) return valid(a) and valid(b) and a:GetAddress() == b:GetAddress() end
local function finite(value) return type(value) == "number" and value > -math.huge and value < math.huge end
local function near(a, b) return finite(a) and math.abs(a - b) < EPSILON end
local function log(reason) print("[PBZDreamPlayerControl] " .. tostring(reason) .. "\n") end

function Session:hook(path, ...)
    local pre, post = RegisterHook(path, ...)
    assert(type(pre) == "number" and type(post) == "number", "control event hook failed " .. path)
    self.hooks[#self.hooks + 1] = { path = path, pre = pre, post = post }
end

function Session:scaleAttribute(field, bias)
    local attribute = self.attributes[field]
    local base, current = attribute.BaseValue, attribute.CurrentValue
    assert(finite(base) and finite(current), "missing player control attribute " .. field)
    local target = (current + bias) * SCALE - bias
    if near(current, target) then return end

    local change = { field = field, original = base, applied = base + target - current }
    self.changes[#self.changes + 1] = change
    local set = require("PracticeMode").setAttributeValue
    set(self.pawn, field, change.applied)
    local updated = self.attributes[field]
    change.applied = updated.BaseValue
    if not near(updated.CurrentValue, target) then
        -- Other native modifiers may also scale the base. Use their observed
        -- response to apply the requested factor to the evaluated attribute.
        local slope = (updated.CurrentValue - current) / (change.applied - base)
        if finite(slope) and slope > EPSILON then
            change.applied = base + (target - current) / slope
            set(self.pawn, field, change.applied)
            change.applied = self.attributes[field].BaseValue
        end
    end
    assert(near(self.attributes[field].CurrentValue, target), "player control attribute did not reach its target " .. field)
end

function Session:watchElectrified()
    if not valid(StaticFindObject(ELECTRIFIED_START)) then LoadAsset(ELECTRIFIED_ASSET) end
    assert(valid(StaticFindObject(ELECTRIFIED_START)), "electrified start event unavailable")
    self:hook(ELECTRIFIED_START, function(context)
        if not self.active or self.electrifiedFault or not IsInGameThread() then return end
        local ok, reason = pcall(function()
            local ability = context:get()
            if not valid(ability) or not same(self.pawn, ability:GetAvatarActorFromActorInfo()) then return end
            -- This event has just applied the named slomo and initialized the
            -- native tick's clock. Advance that clock and let the tick release it.
            local start = ability[ELECTRIFIED_TIME]
            assert(finite(start), "electrified start time unavailable")
            ability[ELECTRIFIED_TIME] = start - ELECTRIFIED_SECONDS * (1 - SCALE)
        end)
        if not ok then self.electrifiedFault = true; log(reason) end
    end)
end

function Session:restoreLieTimer()
    local timer = self.lieTimer
    if not timer then return end
    local ok, reason = pcall(function()
        if valid(timer.listener) then timer.listener.Time = timer.seconds end
    end)
    if ok then self.lieTimer = nil else log(reason) end
end

function Session:watchLieTimer()
    local class = StaticFindObject(LIE_TIMER_CLASS .. "_C")
    if not valid(class) then
        LoadAsset(LIE_TIMER_CLASS)
        class = StaticFindObject(LIE_TIMER_CLASS .. "_C")
    end
    assert(valid(class) and valid(StaticFindObject(REGISTER_HITREACT)), "lying timer unavailable")
    self:hook(REGISTER_HITREACT, function(context, actor)
        if not self.active or self.lieFault or self.lieTimer or not IsInGameThread() then return end
        local ok, reason = pcall(function()
            if not same(self.pawn, actor:get()) then return end
            local listener = context:get()
            if not valid(listener) or not same(listener:GetClass(), class)
                or listener:HasAnyFlags(CLASS_DEFAULT_OBJECT) then return end
            local seconds = listener.Time
            assert(finite(seconds) and seconds > 0, "lying timer duration unavailable")
            -- Native registration copies Time into the actor's Lie timer.
            self.lieTimer = { listener = listener, seconds = seconds }
            listener.Time = seconds * SCALE
        end)
        if not ok then self.lieFault = true; self:restoreLieTimer(); log(reason) end
    end, function(context, actor)
        if self.lieTimer and IsInGameThread() and same(self.pawn, actor:get())
            and same(self.lieTimer.listener, context:get()) then self:restoreLieTimer() end
    end)
end

function Session:close()
    self.active = false
    self:restoreLieTimer()
    for index = #self.hooks, 1, -1 do
        local hook = self.hooks[index]
        local ok, reason = pcall(UnregisterHook, hook.path, hook.pre, hook.post)
        if ok then table.remove(self.hooks, index) else log(reason) end
    end
    if valid(self.pawn) and same(self.attributes, self.pawn.AttributeSetBase) then
        for index = #self.changes, 1, -1 do
            local change = self.changes[index]
            if near(self.attributes[change.field].BaseValue, change.applied) then
                local ok, reason = pcall(require("PracticeMode").setAttributeValue, self.pawn, change.field, change.original)
                if ok then table.remove(self.changes, index) else log(reason) end
            else
                table.remove(self.changes, index)
            end
        end
    else
        self.changes = {}
    end
end

function Control.start(pawn)
    if not IsInGameThread() or not valid(pawn) or not valid(pawn.AttributeSetBase) then return end
    local self = setmetatable({ pawn = pawn, attributes = pawn.AttributeSetBase, changes = {}, hooks = {} }, Session)
    local ok, reason = pcall(function()
        assert(type(UnregisterHook) == "function", "electrified event cleanup unavailable")
        self:watchElectrified()
        -- The native freeze spec multiplies by this factor after resistance
        -- and equipment adjustments. Break recovery uses 1 + its modifier.
        self:scaleAttribute("TakenReductionMultiplier_FrostDuration", 0)
        self:scaleAttribute("BreakDurationAdditionalMultiplier", 1)
        self.active = true
    end)
    if not ok then
        self:close()
        log(reason)
    else
        local lieReady, lieError = pcall(self.watchLieTimer, self)
        if not lieReady then log(lieError) end
    end
    return self
end

return Control
