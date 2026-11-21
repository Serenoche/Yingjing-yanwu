local SpawnClass = require("SpawnClass")
local References = require("PreloadReferences")
local Preload = {}
Preload.__index = Preload
local Frames = {}
Frames.__index = Frames

local MAX_FRAMES = 2048
local MAX_COMBAT_SAMPLE_SECONDS = 1.8
local nextLoadUUID = 0x50425C00

local function log(scope, message)
    print(("[PBZAsyncNextFloor] %s; floor=%d; targetFloor=%d\n"):format(message, scope.fromFloor, scope.floor))
end

local function address(object)
    return object and object:IsValid() and object:GetAddress() or nil
end

local function worldAddress(pawn)
    return address(pawn:GetWorld())
end

local function elapsed(started, at)
    return at and (at - started) * 1000 or -1
end

local function stats(values)
    if #values == 0 then return "n=0" end
    table.sort(values)
    return ("n=%d,p95Ms=%.1f,maxMs=%.1f"):format(#values, values[math.ceil(#values * .95)], values[#values])
end

function Frames.new(phase, fromFloor, floor, started)
    local self = setmetatable({ phase = phase, fromFloor = fromFloor, floor = floor,
        started = started or os.clock(), stamps = {} }, Frames)
    if EngineTickAvailable and type(LoopInGameThreadAfterFrames) == "function"
        and type(CancelDelayedAction) == "function" then
        local ok, handle = pcall(LoopInGameThreadAfterFrames, 1, function()
            local stamps = self.stamps
            if stamps and #stamps <= MAX_FRAMES then stamps[#stamps + 1] = os.clock() end
        end)
        if ok and type(handle) == "number" and handle > 0 then
            self.handle = handle
            log(self, "sampling; phase=" .. phase .. "; clock=wall; lane=engine-tick")
            return self
        end
    end
    log(self, "frame sampler unavailable; phase=" .. phase)
    return self
end

function Frames:finish(reason)
    local stamps = self.stamps
    if not stamps then return end
    self.stamps = nil
    if self.handle then pcall(CancelDelayedAction, self.handle); self.handle = nil end
    local all, before, after = {}, {}, {}
    for index = 2, #stamps do
        local gap = (stamps[index] - stamps[index - 1]) * 1000
        local phase = self.firstRequestAt and stamps[index] > self.firstRequestAt and after or before
        phase[#phase + 1] = gap
        all[#all + 1] = gap
    end
    log(self, ("frame summary; phase=%s; stop=%s; firstRequestMs=%.1f; sample=%s; "
        .. "beforeRequest=%s; afterRequest=%s")
        :format(self.phase, reason, elapsed(self.started, self.firstRequestAt), stats(all), stats(before), stats(after)))
end

function Preload.captureCombat(floor)
    return Frames.new("combat", floor, floor)
end

function Preload.combatWindowDone(sample)
    return os.clock() - sample.started >= MAX_COMBAT_SAMPLE_SECONDS
end

function Preload.new(pawn, fromFloor, floor, members)
    local self = setmetatable({ pawn = address(pawn), world = worldAddress(pawn), fromFloor = fromFloor, floor = floor,
        jobs = {}, byPath = {}, next = 1 }, Preload)
    for _, member in ipairs(members) do
        local path = member.classPath
        if not self.byPath[path] then
            local job = { path = path, unit = member.id }
            self.byPath[path] = job
            self.jobs[#self.jobs + 1] = job
        end
    end
    return self
end

function Preload:matches(pawn)
    return self.pawn and self.world and address(pawn) == self.pawn and worldAddress(pawn) == self.world
end

function Preload:prepareReferences(gameplay, pawn)
    self.referencesAttempted = true
    local ok, failure = pcall(function()
        self.references = References.new(gameplay, pawn)
        self.references:attach()
    end)
    if ok then
        log(self, "retention owner ready")
    else
        self.retentionUnavailable = true
        log(self, "retention unavailable; error=" .. tostring(failure))
    end
end

function Preload:submit(pawn, job)
    local beforeConversion = os.clock()
    local system = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    assert(address(system) and system.MakeSoftClassPath and system.Conv_SoftClassPathToSoftClassRef
        and system.Conv_SoftClassReferenceToString and system.LoadAssetClass, "native async class loader unavailable")
    local softClass = system:Conv_SoftClassPathToSoftClassRef(system:MakeSoftClassPath(job.path))
    local text = system:Conv_SoftClassReferenceToString(softClass)
    if type(text) ~= "string" then text = text:ToString() end
    assert(text == job.path, "soft class path did not round-trip")
    if address(StaticFindObject(job.path)) then return false end

    nextLoadUUID = nextLoadUUID + 1
    local latent = { Linkage = -1, UUID = nextLoadUUID, ExecutionFunction = FName("None"), CallbackTarget = pawn }
    job.requestAt = os.clock()
    self.frames.firstRequestAt = self.frames.firstRequestAt or job.requestAt
    system:LoadAssetClass(pawn, softClass, nil, latent)
    local returned = os.clock()
    log(self, ("request; phase=%s; unit=%s; path=%s; atMs=%.1f; setupMs=%.1f; submitMs=%.1f")
        :format(self.frames.phase, job.unit, job.path, elapsed(self.frames.started, job.requestAt), (job.requestAt - beforeConversion) * 1000,
            (returned - job.requestAt) * 1000))
    return true
end

function Preload:advance(pawn, job)
    if not job.started then
        job.started = os.clock()
        if not address(StaticFindObject(job.path)) and self:submit(pawn, job) then return false end
    end
    local phase = self.frames.phase
    local class, _, proof = SpawnClass.observeReady(job.path)
    if not class then return false end
    job.readyAddress, job.readyCdo, job.preloadProof = address(class), proof.cdo, proof
    local ready = os.clock()
    if not self.retentionUnavailable then
        local ok, held = pcall(self.references.hold, self.references, class)
        if ok then
            job.holdSlot = held
            log(self, ("retained; unit=%s; class=%s; holdMs=%.1f")
                :format(job.unit, job.readyAddress, (os.clock() - ready) * 1000))
        else
            self.retentionUnavailable = true
            log(self, ("retention unavailable; unit=%s; error=%s"):format(job.unit, tostring(held)))
        end
    end
    log(self, ("ready observed; phase=%s; unit=%s; source=%s; atMs=%.1f; sinceStartMs=%.1f; retained=%s")
        :format(phase, job.unit, job.requestAt and "asynchronous" or "resident", elapsed(self.frames.started, ready),
            (ready - (job.requestAt or job.started)) * 1000, tostring(job.holdSlot ~= nil)))
    return true
end

function Preload:beginOpening()
    self.frames = Frames.new("opening", self.fromFloor, self.floor)
    log(self, "queue; phase=opening; classes=" .. #self.jobs)
end

function Preload:endOpening()
    if self.frames and self.frames.phase == "opening" then
        self.frames:finish("portal-open")
        self.frames = nil
        log(self, ("portal available; ready=%d/%d"):format(self.next - 1, #self.jobs))
    end
end

function Preload:advanceOne(pawn)
    local job = self.jobs[self.next]
    if not job then return end
    local ok, ready = pcall(self.advance, self, pawn, job)
    if not ok then
        self.failed = true
        log(self, ("queue stopped; phase=%s; reason=class-error:%s; ready=%d/%d")
            :format(self.frames.phase, tostring(ready), self.next - 1, #self.jobs))
        return
    end
    if ready then
        self.next = self.next + 1
        if self.next > #self.jobs then
            log(self, ("queue ready; phase=%s; classes=%d"):format(self.frames.phase, #self.jobs))
        end
    end
end

function Preload:stepOpening(pawn, gameplay)
    if self.failed or self.retentionUnavailable or self.next > #self.jobs then return end
    if not self:matches(pawn) then self:close("scope-changed"); return end
    if not self.referencesAttempted then
        self:prepareReferences(gameplay, pawn)
        return
    end
    self:advanceOne(pawn)
end

function Preload:stepCovered(pawn, gameplay, realNow, deadline)
    if not self:matches(pawn) then self:close("scope-changed"); return true end
    if not self.blackStarted then
        self:endOpening()
        self.blackStarted = os.clock()
        self.frames = Frames.new("black", self.fromFloor, self.floor, self.blackStarted)
        log(self, ("queue; phase=black; ready=%d/%d"):format(self.next - 1, #self.jobs))
        if not self.referencesAttempted then self:prepareReferences(gameplay, pawn) end
    end
    if self.failed or self.next > #self.jobs then return true end
    if realNow >= deadline or os.clock() - self.blackStarted >= 2 then
        self.failed = true
        log(self, ("queue stopped; phase=black; reason=blackout-budget; ready=%d/%d")
            :format(self.next - 1, #self.jobs))
        return true
    end
    self:advanceOne(pawn)
    return self.failed or self.next > #self.jobs
end

function Preload:noteSync(path, milliseconds, attached)
    local job = self.byPath[path]
    job.syncChecks = (job.syncChecks or 0) + 1
    job.syncMs = (job.syncMs or 0) + milliseconds
    log(self, ("covered asset check; unit=%s; attempt=%d; assetRegistryMs=%.1f; resolved=%s")
        :format(job.unit, job.syncChecks, milliseconds, tostring(attached)))
end

function Preload:reportSpawn(members, actors)
    local reported, reused, retained = {}, 0, 0
    for index, member in ipairs(members) do
        local job = self.byPath[member.classPath]
        if job and not reported[job.path] then
            reported[job.path] = true
            local actorClass = actors[index]:GetClass()
            local usedAddress, usedCdo = address(actorClass), address(actorClass:GetCDO())
            local reuse = job.readyAddress ~= nil and job.readyAddress == usedAddress and job.readyCdo == usedCdo
            local held = job.holdSlot and self.references and self.references:holds(job.holdSlot, job.readyAddress)
            if reuse then reused = reused + 1 end
            if held then retained = retained + 1 end
            log(self, ("spawn; unit=%s; reuse=%s; retained=%s; readyClass=%s; spawnedClass=%s; "
                .. "proofRechecked=%s; syncChecks=%d; assetRegistryMs=%.1f")
                :format(job.unit, tostring(reuse), tostring(held == true), tostring(job.readyAddress),
                    tostring(usedAddress), tostring(job.proofRechecked == true), job.syncChecks or 0, job.syncMs or 0))
        end
    end
    log(self, ("arrival; actors=%d; classes=%d; reused=%d; retained=%d; coveredMs=%.1f")
        :format(#actors, #self.jobs, reused, retained, self.blackStarted and elapsed(self.blackStarted, os.clock()) or -1))
end

function Preload:close(reason)
    self.failed = true
    if self.frames then self.frames:finish(reason); self.frames = nil end
    if self.references then
        local cleared, detached, failures = self.references:release()
        log(self, ("retention released; reason=%s; cleared=%d; ownerDetached=%s; failures=%d")
            :format(reason, cleared, tostring(detached), failures))
        self.references = nil
    end
    for _, job in ipairs(self.jobs) do job.preloadProof, job.holdSlot = nil, nil end
end

return Preload
