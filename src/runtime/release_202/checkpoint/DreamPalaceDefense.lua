local Defense = {}
Defense.__index = Defense

local GUARD = "/PBZCombatAsset/Prototypes/Abilities/GA_CommonUtilitiesPassive.GA_CommonUtilitiesPassive_C:OnTaken"
local DODGE = "/PBZDeflectSystem/Abilities/BP_PlayerDodge_Base.BP_PlayerDodge_Base_C:"
local COUNTER = "/PBZDeflectSystem/Abilities/BP_PlayerPerfectDodge_Base.BP_PlayerPerfectDodge_Base_C:Do Perfect Dodge"
local IMPACT = "/PBZDeflectSystem/BPL_DeflectUtils.BPL_DeflectUtils_C:Send Impact Event"
local BULLET_HAS_TAG = "/Script/SGameCombatSystem.BulletInterface:HasTag"
local EXECUTION = "/SGameExecution/GA/GA_ExecutionAbilityBase.GA_ExecutionAbilityBase_C"
local PERFECT_GUARD = { ["Damage.Cause.Deflect.Perfect"] = true, ["Damage.Cause.Deflect.BreakPerfect"] = true }
local RED = "Bullet.Tag.Feature.Deflect.RedEye"
-- The stock projectile and stance BlueEye branches both use this exact tag.
local BLUE = "Bullet.Tag.Feature.Deflect.CanDodgeAfterDeflect"

local function valid(value) return value and type(value.IsValid) == "function" and value:IsValid() end
local function unwrap(value)
    if type(value) ~= "userdata" and type(value) ~= "table" then return value end
    if value and type(value.get) == "function" then return value:get() end
    if value and type(value.Get) == "function" then return value:Get() end
    return value
end
local function address(value) return valid(value) and value:GetAddress() or nil end

local function interfaceObject(value)
    value = unwrap(value)
    if valid(value) then return value end
    if value then
        local system = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        if valid(system) then return system:Conv_InterfaceToObject(value) end
    end
end

local function bulletColor(bullet, redTag, blueTag, hasTag)
    bullet = interfaceObject(bullet)
    if not valid(bullet) then return end
    -- HasTag is a native interface UFunction and may not be resolved on the
    -- concrete bullet's Lua wrapper. Call it explicitly on the bullet.
    hasTag = bullet.HasTag or hasTag
    if hasTag(bullet, redTag, false) == true then return "red" end
    local blue = hasTag(bullet, blueTag, false)
    if blue == true then return "blue" end
    if blue == false then return "normal" end
end

local function actionColor(sourceAction)
    local action = unwrap(sourceAction)
    if not valid(action) then return end
    local kind = action.DeflectBulletType or action.DeflectType or action["Deflect Bullet Type"]
    if kind == 2 then return "blue" end -- EDeflectBulletType::BlueEye
    if kind == 3 then return "red" end  -- EDeflectBulletType::RedEye
end

function Defense:attackColor(bullet, sourceAction, details)
    local ok, color = pcall(bulletColor, bullet, self.redTag, self.blueTag, self.hasTag)
    if ok and (color == "red" or color == "blue") then return color, "bullet-tag" end
    if sourceAction then
        local known, fromAction = pcall(actionColor, sourceAction)
        if known and fromAction then return fromAction, "source-action" end
    end
    if details then return details.color, details.evidence end
    return ok and color or "unknown", ok and color and "bullet-tag" or "unavailable"
end

function Defense:observe(kind, route, attacker, bullet, sourceAction, details)
    local source = address(attacker)
    if not source or source == self.pawnAddress or not self.challenge:owns(attacker) then return end
    local gameTime = self.gameplay:GetTimeSeconds(self.pawn)
    local last = self.last[kind]
    if not last or last.gameTime ~= gameTime then
        last = { gameTime = gameTime, sources = {} }
        self.last[kind] = last
    end
    if last.sources[source] then return end
    local color, evidence = self:attackColor(bullet, sourceAction, details)
    local realTime = self.gameplay:GetRealTimeSeconds(self.pawn)
    if self.credit(kind, gameTime, realTime, color, route, evidence) then
        last.sources[source] = true
    end
end

function Defense:watch(path, route, read, static)
    local hook = StaticFindObject(path)
    if not valid(hook) then return false end
    local function inspect(ability, ...)
        ability = unwrap(ability)
        if valid(ability) and address(ability:GetAvatarActorFromActorInfo()) == self.pawnAddress then read(ability, ...) end
    end
    local ok, pre, post = pcall(RegisterHook, path, function(context, ...)
        if self.closed then return end
        local success, failure = pcall(function(...)
            if not self.active() then return end
            if static then inspect(...) else inspect(context, ...) end
        end, ...)
        if not success and not self.warned[route] then
            self.warned[route] = true
            print("[PBZBloodyPalace] countdown signal " .. route .. ": " .. tostring(failure) .. "\n")
        end
    end)
    if not ok or type(pre) ~= "number" or type(post) ~= "number" then return false end
    self.hooks[#self.hooks + 1] = { path, pre, post }
    return true
end

function Defense:creditExecution(abilityId, gameTime, realTime, evidence)
    local execution = self.executions[abilityId]
    self.executions[abilityId] = nil
    if execution and execution.stage == self.challenge.ownedActors then
        self.credit("execution", gameTime, realTime, "normal", "execution", evidence)
    end
end

function Defense:creditLethalExecutions(observer, gameTime, realTime)
    if self.closed or not self.active() then return end
    for abilityId, execution in pairs(self.executions) do
        local record = observer.recordsByAddress[execution.target]
        if record and record.dead then
            self:creditExecution(abilityId, record.endedAt or gameTime, realTime, "confirmed-target-death")
        elseif execution.stage ~= self.challenge.ownedActors then
            self.executions[abilityId] = nil
        end
    end
end

function Defense:watchExecutions()
    local playing = EXECUTION .. ":Play Execution"
    local finished = EXECUTION .. ":K2_OnEndAbility"
    if not valid(StaticFindObject(playing)) then pcall(require("SpawnClass").resolve, EXECUTION) end
    -- The blueprint's Finish broadcast also runs on cancellation. Pair the
    -- player's playback with normal ability end, or confirmed defeat if the
    -- target leaves the roster before the executor's final animation ends.
    local ended = self:watch(finished, "execution-end", function(ability, cancelled)
        local abilityId = ability:GetAddress()
        if unwrap(cancelled) ~= false then
            self.executions[abilityId] = nil
            return
        end
        if self.executions[abilityId] then
            self:creditExecution(abilityId, self.gameplay:GetTimeSeconds(self.pawn),
                self.gameplay:GetRealTimeSeconds(self.pawn), "native-ability-end")
        end
    end)
    local started = ended and self:watch(playing, "execution-play", function(ability)
        local abilityId = ability:GetAddress()
        self.executions[abilityId] = nil
        local info = ability["Execution Info"]
        if not info or info.IsTarget ~= false or address(unwrap(info.Executor)) ~= self.pawnAddress then return end
        local target = unwrap(info.Target)
        if not self.challenge:owns(target) then return end
        self.executions[abilityId] = { target = target:GetAddress(), stage = self.challenge.ownedActors }
    end)
    print(("[PBZBloodyPalace] countdown execution hooks play=%s end=%s\n")
        :format(tostring(started), tostring(ended)))
end

function Defense.new(pawn, challenge, gameplay, active, credit)
    local self = setmetatable({ pawn = pawn, pawnAddress = pawn:GetAddress(), challenge = challenge,
        gameplay = gameplay, active = active, credit = credit, hooks = {}, warned = {}, last = {}, executions = {},
        redTag = { TagName = FName(RED) }, blueTag = { TagName = FName(BLUE) },
        hasTag = StaticFindObject(BULLET_HAS_TAG) }, Defense)
    -- The common passive receives the confirmed damage cause. Unlike the
    -- talent's pretake callback, it fires once for each resolved guard.
    local guard = self:watch(GUARD, "guard", function(_, event)
        local data = unwrap(event)
        local payload = data and data.OptionalObject
        if valid(payload) and PERFECT_GUARD[payload.DamageCause.TagName:ToString()]
            and address(payload:GetTargetActor()) == self.pawnAddress then
            local attacker = payload:GetDamageSourceOwner()
            local details = self.guardImpact
            self.guardImpact = nil
            if details and (details.attacker ~= address(attacker)
                or details.at ~= gameplay:GetTimeSeconds(self.pawn)) then details = nil end
            local bullet
            if not details then
                local hasBullet, sourceBullet = pcall(function()
                    local module = interfaceObject(payload.DamageSource)
                    if valid(module) then return module.Bullet end
                end)
                if hasBullet then bullet = sourceBullet end
            end
            self:observe("guard", "guard", attacker, bullet, nil, details)
        end
    end)
    -- Stock Play Impact sends this with the exact source bullet immediately
    -- before applying damage. Keep scalar metadata for the matching OnTaken.
    local impact = self:watch(IMPACT, "guard-impact", function(_, param)
        self.guardImpact = nil
        local frame = unwrap(param)
        local attacker = frame and address(frame.SourceAvatar)
        if not attacker then return end
        local color, evidence = self:attackColor(frame.SourceBullet, frame.SourceAction)
        if color ~= "unknown" then
            self.guardImpact = { attacker = attacker, color = color, evidence = evidence,
                at = gameplay:GetTimeSeconds(self.pawn) }
        end
    end, true)
    -- The ordinary dodge checks HitDodge.Target.Perfect before forwarding
    -- this bool. The separate perfect counter consumes its own deflect frame.
    local evade = self:watch(DODGE .. "OnEvadeDamage", "evade", function(ability, source, bullet, perfect)
        if unwrap(perfect) == true and ability.EvadedDamage == true then
            self:observe("dodge", "evade", unwrap(source), bullet)
        end
    end)
    local counter = self:watch(COUNTER, "counter", function(ability, _, receiveFrame)
        local result, frame = ability["Current Frame"], unwrap(receiveFrame)
        if result then
            self:observe("dodge", "counter", result.SourceAvatar,
                frame and frame.Bullet or result.SourceBullet, frame and frame.SourceAction or result.SourceAction)
        end
    end)
    print(("[PBZBloodyPalace] countdown signals guard=%s impact=%s evade=%s counter=%s\n")
        :format(tostring(guard), tostring(impact), tostring(evade), tostring(counter)))
    local watched, failure = pcall(self.watchExecutions, self)
    if not watched then print("[PBZBloodyPalace] countdown execution unavailable: " .. tostring(failure) .. "\n") end
    return self
end

function Defense:close()
    self.closed = true
    for _, hook in ipairs(self.hooks) do pcall(UnregisterHook, table.unpack(hook)) end
    self.hooks, self.executions = {}, {}
end

return Defense
