local SpawnClass = require("SpawnClass")
local References = require("PreloadReferences")
local Async = require("AsyncClassLoad")

local Preload = {}
Preload.__index = Preload

local function address(object)
    return object and type(object.IsValid) == "function" and object:IsValid() and object:GetAddress() or nil
end

local function worldAddress(pawn)
    return address(pawn) and address(pawn:GetWorld()) or nil
end

local function log(self, message)
    print(("[PBZGauntletPreload] %s; scene=%s; target=%s; mode=%s; stage=%d->%d\n")
        :format(message, self.scene.id, self.entry.id, self.mode, self.fromStage, self.fromStage + 1))
end

local function milliseconds(start)
    return start and (os.clock() - start) * 1000 or -1
end

function Preload.new(run, pawn)
    local stage = run.entry.stages[run.stageIndex + 1]
    local pawnId, worldId = address(pawn), worldAddress(pawn)
    if not stage or not pawnId or not worldId then return nil end
    local self = setmetatable({
        pawn = pawnId, world = worldId, entry = run.entry, scene = run.scene, mode = run.mode,
        fromStage = run.stageIndex, stage = stage, jobs = {}, byPath = {}, nextJob = 1,
        clock = os.clock(),
    }, Preload)
    for _, member in ipairs(stage.members) do
        local path = member.classPath
        if not self.byPath[path] then
            local job = { path = path, id = member.id }
            self.byPath[path] = job
            self.jobs[#self.jobs + 1] = job
        end
    end
    log(self, ("started; classes=%d"):format(#self.jobs))
    return self
end

function Preload:matches(run, pawn, stageIndex)
    return not self.closed and self.entry == run.entry and self.scene == run.scene and self.mode == run.mode
        and stageIndex == self.fromStage + 1 and self.stage == run.entry.stages[stageIndex]
        and self.pawn == address(pawn) and self.world == worldAddress(pawn)
end

function Preload:submit(pawn, job)
    if address(StaticFindObject(job.path)) then return false end
    job.requestAt = os.clock()
    Async.request(pawn, job.path)
    log(self, ("async request; unit=%s; submitMs=%.1f"):format(job.id, milliseconds(job.requestAt)))
    return true
end

function Preload:advance(gameplay, system, pawn, phase)
    local job = self.jobs[self.nextJob]
    if self.asyncDisabled or not job then return true end

    local ok, frame = pcall(function() return tonumber(system:GetFrameCount()) end)
    if ok and frame then
        if frame == self.lastFrame then return false end
        self.lastFrame = frame
    end
    local processed, failure = pcall(function()
        if not self.references then
            self.references = References.new(gameplay, pawn)
            self.references:attach()
            return
        end
        if not job.started then
            job.started = os.clock()
            if not address(StaticFindObject(job.path)) and self:submit(pawn, job) then return end
        end
        local class, _, proof = SpawnClass.observeReady(job.path)
        if not class then return end
        job.readyAddress, job.readyCdo, job.preloadProof = address(class), proof.cdo, proof
        job.holdSlot = self.references:hold(class)
        self.nextJob = self.nextJob + 1
        log(self, ("async ready; phase=%s; unit=%s; elapsedMs=%.1f; ready=%d/%d")
            :format(phase, job.id, milliseconds(job.started), self.nextJob - 1, #self.jobs))
    end)
    if not processed then
        self.asyncDisabled = true
        log(self, "async fallback; reason=" .. tostring(failure))
    end
    return self.asyncDisabled or self.nextJob > #self.jobs
end

function Preload:stepCovered(gameplay, system, pawn, now, deadline)
    if self.asyncDisabled or self.nextJob > #self.jobs then return true end
    if now >= deadline then
        self.asyncDisabled = true
        log(self, ("covered budget reached; ready=%d/%d"):format(self.nextJob - 1, #self.jobs))
        return true
    end
    return self:advance(gameplay, system, pawn, "black")
end

function Preload:noteSync(path, elapsed, resolved)
    local job = self.byPath[path]
    job.syncChecks = (job.syncChecks or 0) + 1
    log(self, ("asset registry; unit=%s; attempt=%d; elapsedMs=%.1f; resolved=%s")
        :format(job.id, job.syncChecks, elapsed, tostring(resolved)))
end

function Preload:reportSpawn(members, actors)
    local counted, reused, held = {}, 0, 0
    for index, member in ipairs(members) do
        local job = self.byPath[member.classPath]
        if job and not counted[job] then
            counted[job] = true
            local class = actors[index]:GetClass()
            if job.readyAddress and address(class) == job.readyAddress and address(class:GetCDO()) == job.readyCdo then
                reused = reused + 1
            end
            if job.holdSlot and self.references:holds(job.holdSlot, job.readyAddress) then held = held + 1 end
        end
    end
    log(self, ("spawned; actors=%d; classes=%d; reused=%d; held=%d; sinceReturnMs=%.1f; blackMs=%.1f")
        :format(#actors, #self.jobs, reused, held, milliseconds(self.returnClock), milliseconds(self.blackClock)))
    return #self.jobs > 0 and reused == #self.jobs
end

function Preload:release(reason)
    if self.references then
        local cleared, detached, failures = self.references:release()
        log(self, ("references released; reason=%s; cleared=%d; detached=%s; failures=%d")
            :format(reason, cleared, tostring(detached), failures))
        self.references = nil
    end
    for _, job in ipairs(self.jobs) do job.preloadProof, job.holdSlot = nil, nil end
end

function Preload:spawned(members, actors)
    local ok, reused = pcall(self.reportSpawn, self, members, actors)
    if not ok then log(self, "spawn diagnostics unavailable; reason=" .. tostring(reused)) end
    self:release("spawned")
    return ok and reused == true
end

function Preload:reveal()
    log(self, ("reveal; transitionMs=%.1f; blackMs=%.1f")
        :format(milliseconds(self.clock), milliseconds(self.blackClock)))
end

function Preload:close(reason)
    if self.closed then return end
    self.closed = true
    self:release(reason)
end

return Preload
