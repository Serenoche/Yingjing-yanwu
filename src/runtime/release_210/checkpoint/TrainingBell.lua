local Menu = require("ChallengeMenu")
local Target = require("TitleHome")
local Ability = require("AbilityChallenge")
local TrainingBell = {}
TrainingBell.__index = TrainingBell

local function valid(object)
    return object ~= nil and type(object.IsValid) == "function" and object:IsValid()
end

local function isInteracting(pawn, bellId, includeCandidate)
    if not bellId then return false end
    local component = pawn.PBZInteract
    if not valid(component) then return nil end
    local actor = component:GetInteractingActor()
    if includeCandidate and not valid(actor) then actor = component:GetInteractActor() end
    return valid(actor) and actor:GetAddress() == bellId
end

function TrainingBell.new(pawn, controller)
    local self = setmetatable({ pawn = pawn, controller = controller }, TrainingBell)
    self.choose = function(action) self.action = action end
    return self
end

function TrainingBell:close()
    if self.child then
        pcall(self.child.close)
        self.child = nil
    end
    Menu.close()
    self.action, self.abilityBefore, self.abilitySnapshot = nil, nil, nil
end

function TrainingBell:update(gameplay, scene, bell, mobId, onTarget, skillsReady, playerCycle, customPlayer)
    local pawn = self.pawn
    local bellId = valid(bell) and bell:GetAddress()
    if self.bellId ~= bellId then
        self:close()
        self.bellId = bellId
    end
    if not bellId then return false end
    -- Use the same native interaction component as the stock menu, so an
    -- idle testing field does not repeatedly enumerate widgets near the bell.
    if not self.child and not Menu.active() then
        local readable, interacting = pcall(isInteracting, pawn, bellId, true)
        if readable and interacting == false then return false end
    end
    local now = gameplay:GetRealTimeSeconds(pawn)
    if self.child then
        local isAbility = self.child == Ability
        local ok, visible = pcall(self.child.update, isAbility and pawn or gameplay)
        if ok and visible then return true end
        if not ok then
            pcall(self.child.close)
            print("[PBZTestArenaNative] Training bell child: " .. tostring(visible) .. "\n")
        elseif isAbility then
            local captured, snapshot = pcall(Ability.capture, pawn)
            if captured then self.abilitySnapshot = snapshot
            else print("[PBZTestArenaNative] Training ability capture: " .. tostring(snapshot) .. "\n") end
        end
        self.child = nil
        Menu.resume(now)
    end

    local action = self.action
    self.action = nil
    if action == "configure" and not skillsReady then
        self.action, action = action, nil
    end
    if action and Menu.suspend() then
        self.child = action == "configure" and Ability or Target
        local opened, result
        if self.child == Ability then
            local captured, before = pcall(Ability.capture, pawn)
            self.abilityBefore = captured and before or nil
            opened, result = pcall(Ability.open, gameplay, pawn)
        else
            opened, result = pcall(Target.openTrainingTarget, pawn, self.controller, mobId, onTarget)
        end
        if opened and result == true then return true end
        pcall(self.child.close)
        self.child = nil
        Menu.resume(now)
        print("[PBZTestArenaNative] Training bell open: " .. tostring(result) .. "\n")
    end
    local active = Menu.update(gameplay, pawn, {
        available = true, mode = "training", sceneName = scene.name, bellName = scene.bellName, bellId = scene.bellSaveId,
        requireBellOwner = true, bellOwner = bell, runtimeModule = scene.runtimeModule,
        playerCycle = playerCycle, customPlayer = customPlayer,
    }, self.choose)
    if not active then self.action = nil end
    return active
end

function TrainingBell:blocksKeys()
    if self.child or Menu.active() then return true end
    local ok, interacting = pcall(isInteracting, self.pawn, self.bellId)
    return ok and interacting == true
end

return TrainingBell
