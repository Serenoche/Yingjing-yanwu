local SpawnClass = require("SpawnClass")
local Cover = require("BossLoadCover")
local RetryPreload = require("RetryPreload")

local Entry = {}
Entry.__index = Entry

local function frameCount(system)
    local ok, count = pcall(function() return system:GetFrameCount() end)
    return ok and tonumber(count) or nil
end

function Entry.new(run, pawn, world, followingStage)
    local stage = run.entry.stages[run.stageIndex]
    local members = stage.members
    if followingStage then
        members = {}
        for _, member in ipairs(stage.members) do members[#members + 1] = member end
        for _, member in ipairs(followingStage.members) do members[#members + 1] = member end
    end
    return setmetatable({ run = run, pawn = pawn:GetAddress(), world = world:GetAddress(),
        entry = run.entry, stage = run.stageIndex, targetCount = #stage.members,
        followingStage = followingStage, plan = SpawnClass.preload(members) }, Entry)
end

function Entry:owns(pawn, world)
    return self.pawn == pawn:GetAddress() and self.world == world:GetAddress()
end

function Entry:close()
    if not self.cover then return true end
    local closed, reason = self.cover:close()
    if closed then self.cover = nil end
    return closed, reason
end

function Entry:update(gameplay, system, pawn, world)
    local now = gameplay:GetRealTimeSeconds(pawn)
    if not self.deadline then
        self.deadline, self.coverDeadline = now + 18, now + 2
    end
    if self.cover and not self.closing and now < self.deadline and not self.cover:isOwned(pawn, world) then
        self.closing = true
    end
    if self.closing or now >= self.deadline then
        self.finished, self.closing = true, true
        local closed = self:close()
        return closed
    end
    if self.finished then return true end
    if not self.cover then
        local cover, reason, partial = Cover.new(gameplay, pawn, world)
        if not cover then
            if partial then self.cover, self.closing = partial, true end
            if partial or now >= self.coverDeadline then
                print("[PBZTestArenaNative] 首领载入遮罩未就绪：" .. tostring(reason) .. "\n")
                self.finished = true
                return not partial
            end
            return false
        end
        self.cover, self.coverFrame = cover, frameCount(system)
        return false
    end
    if self.coverFrame then
        local current = frameCount(system)
        if current and current <= self.coverFrame then return false end
        self.coverFrame = nil
    end
    if not RetryPreload.beforeSpawn(self.run, gameplay, pawn) or not self.plan:step() then return false end
    self.finished = true
    self.run.entryPreloadPlan = self.plan
    if self.followingStage then
        self.run.phasePreloadPlan = self.plan
        self.run.phasePreloadScope = { pawn=self.pawn, world=self.world }
    end
    return true
end

return Entry
