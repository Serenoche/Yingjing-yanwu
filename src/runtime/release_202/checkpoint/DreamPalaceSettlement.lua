local Home = require("TitleHome")
local Dream = require("DreamPalaceProfile")
local Scene = require("SceneArena")
local Timer = require("DreamPalaceTimer")
local Settlement = {}
Settlement.__index = Settlement

local QUESTIONS = {
    "魂大人这就支撑不住了吗？",
    "想体验真正的力量吗？",
    "即使抛弃过往也在所不惜吗？",
}

local function valid(object) return object and object:IsValid() end
local function log(message) print("[PBZBloodyPalace] " .. message .. "\n") end

function Settlement.new(title, body, unlockBase, death, report, floorResult, failureCause)
    local failurePage = failureCause and require("DreamPalaceFailureScreen").new(failureCause)
    local offer = unlockBase ~= nil
    if offer then log("zhuoshi offer available after consecutive deep-tier losses") end
    return setmetatable({ title = title, body = body, report = report, floorResult = floorResult,
        unlockBase = unlockBase, step = offer and not failurePage and 1 or nil,
        holdRespawn = failurePage ~= nil or offer and death, failurePage = failurePage }, Settlement)
end

function Settlement:hasReturnChoices()
    return not (self.floorResult or self.notice or self.step) and (self.failurePage ~= nil or self.report and self.report.fullClear == true)
end

function Settlement:labels()
    if self.floorResult then
        local result = self.floorResult
        local floor = require("BloodyPalaceProgress").sourceFloor(result.floor)
        return "通关" .. Timer.floorLabel(floor), ("本层奖励时间  %s\n本层耗时  %s\n本层时间  %s")
            :format(Timer.format(result.reward, false), Timer.format(result.spent, false),
                Timer.format(result.reward - result.spent, false, true)), "继续"
    end
    if self.notice then return "", self.notice, "确定" end
    if self.step then return "", QUESTIONS[self.step], "确定", "取消" end
    if self:hasReturnChoices() then return self.title, self.body, "返回演武", "返回主菜单" end
    return self.title, self.body, "返回主界面"
end

function Settlement:answer(accepted)
    if self.notice then self.notice = nil; return self.returnAfterOffer ~= nil end
    if not self.step then return true end
    if not accepted then
        log("zhuoshi offer declined at step " .. self.step)
        self.step = nil
        return self.returnAfterOffer ~= nil
    end
    log("zhuoshi confirmation accepted; step=" .. self.step)
    self.step = self.step + 1
    if self.step <= #QUESTIONS then return false end
    self.step = nil
    local ok, failure = pcall(Dream.unlockZhuoshi, self.unlockBase)
    if ok then
        self.notice = "已解锁「浊使」难度"
        log("zhuoshi unlocked after three confirmations")
    else
        self.notice = "浊使难度解锁保存失败"
        log("zhuoshi unlock: " .. tostring(failure))
    end
    return false
end

function Settlement:freezeRespawn(gameplay, controller)
    if not self.holdRespawn or gameplay:IsGamePaused(controller) then return end
    if gameplay:SetGamePaused(controller, true) then
        self.pausedController = controller
        if self.failurePage and not self.pauseLogged then
            self.pauseLogged = true
            log("failure held in place until a return selection; cause=" .. self.failurePage.cause)
        end
    elseif not self.pauseWarning then
        self.pauseWarning = true
        log("could not pause stock failure world")
    end
end

function Settlement:detach(gameplay)
    if self.failurePage then self.failurePage:detach() end
    if self.open then pcall(Home.close); self.open = nil end
    local controller = self.pausedController
    self.pausedController, self.nextOpen = nil, nil
    if valid(controller) and valid(gameplay) then pcall(gameplay.SetGamePaused, gameplay, controller, false) end
end

function Settlement:preserveAcrossMap(gameplay)
    self:detach(gameplay)
    if self.exit or not (self.failurePage or self.unlockBase or self.report and self.report.failure) then return false end
    -- A stock reset that already began can finish across the map boundary.
    -- Keep the page data and abandon all old-world widget/pause ownership.
    self.holdRespawn = false
    self.departingWorld = self.worldAddress or self.departingWorld
    log("settlement retained during native map change; step=" .. tostring(self.step or 0))
    return true
end

function Settlement:update(gameplay, controller, now)
    if self.exit then return true end
    local world = Scene.runtimeWorld(controller)
    if not valid(world) then return false end
    local address = world:GetAddress()
    if address == self.departingWorld then return false end
    self.worldAddress, self.departingWorld = address, nil
    self:freezeRespawn(gameplay, controller)
    if self.failurePage then
        if not self.failurePage:update(controller, now) then return false end
        self.failurePage:uncover(now, Home.settlementReady(self))
    end
    if self.open then
        local confirmingFloor = self.floorResult ~= nil
        local ok, opened = pcall(Home.update, gameplay)
        if self.exit then return true end
        if confirmingFloor and not self.floorResult then return false end
        if ok and opened then return false end
        self.open, self.nextOpen = nil, now + .25
        if not ok then log("settlement UI update: " .. tostring(opened)) end
    elseif now >= (self.nextOpen or 0) then
        local ok, opened = pcall(Home.prompt, controller, self, function(destination)
            if self.floorResult then
                self.floorResult, self.open, self.nextOpen = nil, nil, nil
                log("final floor confirmation accepted")
            elseif self.failurePage and self.unlockBase and not self.returnAfterOffer then
                self.returnAfterOffer, self.step = destination == "arena" and "arena" or "title", 1
                Home.close()
                self.open, self.nextOpen = nil, nil
            else
                self.exit = self.returnAfterOffer or (destination == "arena" and "arena" or "title")
                if self.failurePage then log("failure return selected; destination=" .. self.exit) end
            end
        end)
        if ok and opened then self.open = true
        else
            self.nextOpen = now + .4
            if opened ~= self.lastError then
                self.lastError = opened
                log("settlement UI: " .. tostring(opened))
            end
        end
    end
    return false
end

return Settlement
