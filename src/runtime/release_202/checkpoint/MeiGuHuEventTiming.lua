-- Aggregate Lua hook time between engine ticks, with bounded logging.
local Timing = {}
Timing.__index = Timing

local clock = os.clock
local LONG_GAP = 0.05
local LONG_HOOKS = 0.005
local LOG_INTERVAL = 0.5
local REPORT_INTERVAL = 10
local categories = { "actor_pre", "actor_post", "flow_check", "flow_register" }

function Timing.new(report)
    local self = setmetatable({ report = report, phase = "entry", alive = true, buckets = {},
        frame = 0, last = clock(), nextLog = 0, frames = 0, gaps = 0, maxGap = 0,
        hookFrames = 0, gapsWithCalls = 0, maxGapHookTime = 0 }, Timing)
    for _, name in ipairs(categories) do
        self.buckets[name] = { calls = 0, seconds = 0, peak = 0, totalCalls = 0, totalSeconds = 0, maxHook = 0 }
    end
    self.nextReport = self.last + REPORT_INTERVAL
    if EngineTickAvailable and type(LoopInGameThreadAfterFrames) == "function"
        and type(CancelDelayedAction) == "function" then
        local ok, handle = pcall(LoopInGameThreadAfterFrames, 1, function()
            if self.alive then self:sample(clock()) end
        end)
        if ok and type(handle) == "number" and handle > 0 then self.handle = handle end
    end
    report("TIMING_START engine_tick=" .. (self.handle and "1" or "0"))
    return self
end

function Timing:record(name, began)
    local elapsed = math.max(0, clock() - began)
    local bucket = self.buckets[name]
    bucket.calls = bucket.calls + 1
    bucket.seconds = bucket.seconds + elapsed
    bucket.peak = math.max(bucket.peak, elapsed)
end

function Timing:summary(includePending)
    local fields = {}
    for _, name in ipairs(categories) do
        local row = self.buckets[name]
        fields[#fields + 1] = ("%s_calls=%d %s_ms=%.1f %s_max_ms=%.1f")
            :format(name, row.totalCalls + (includePending and row.calls or 0),
                name, (row.totalSeconds + (includePending and row.seconds or 0)) * 1000,
                name, math.max(row.maxHook, includePending and row.peak or 0) * 1000)
        row.totalCalls, row.totalSeconds, row.maxHook = 0, 0, 0
        if includePending then row.calls, row.seconds, row.peak = 0, 0, 0 end
    end
    self.report(("TIMING_SUMMARY phase=%s frames=%d gaps_ge50=%d max_gap_ms=%.1f hook_frames_ge5=%d gaps_with_hook_calls=%d max_long_gap_hook_ms=%.1f %s")
        :format(self.phase, self.frames, self.gaps, self.maxGap * 1000, self.hookFrames,
            self.gapsWithCalls, self.maxGapHookTime * 1000, table.concat(fields, " ")))
    self.frames, self.gaps, self.maxGap, self.hookFrames = 0, 0, 0, 0
    self.gapsWithCalls, self.maxGapHookTime = 0, 0
end

function Timing:sample(now)
    local gap = math.max(0, now - self.last)
    self.frame, self.last = self.frame + 1, now
    local total, calls = 0, 0
    for _, name in ipairs(categories) do
        local row = self.buckets[name]
        total, calls = total + row.seconds, calls + row.calls
        row.totalCalls = row.totalCalls + row.calls
        row.totalSeconds = row.totalSeconds + row.seconds
        row.maxHook = math.max(row.maxHook, row.peak)
    end
    self.frames = self.frames + 1
    self.maxGap = math.max(self.maxGap, gap)
    if gap >= LONG_GAP then
        self.gaps = self.gaps + 1
        if calls > 0 then self.gapsWithCalls = self.gapsWithCalls + 1 end
        self.maxGapHookTime = math.max(self.maxGapHookTime, total)
    end
    if total >= LONG_HOOKS then self.hookFrames = self.hookFrames + 1 end
    -- Report expensive hook bursts even when the frame itself stays fast.
    if (gap >= LONG_GAP or total >= LONG_HOOKS) and now >= self.nextLog then
        local fields = {}
        for _, name in ipairs(categories) do
            local row = self.buckets[name]
            if row.calls > 0 then
                fields[#fields + 1] = ("%s=%d/%.1fms/max%.1fms"):format(name, row.calls, row.seconds * 1000, row.peak * 1000)
            end
        end
        self.report(("TICK phase=%s n=%d gap_ms=%.1f hook_ms=%.1f hook_calls=%d %s")
            :format(self.phase, self.frame, gap * 1000, total * 1000, calls, table.concat(fields, " ")))
        self.nextLog = now + LOG_INTERVAL
    end
    for _, name in ipairs(categories) do
        local row = self.buckets[name]
        row.calls, row.seconds, row.peak = 0, 0, 0
    end
    if now >= self.nextReport then
        self:summary()
        self.nextReport = now + REPORT_INTERVAL
    end
end

function Timing:mark(phase)
    if self.phase == phase then return end
    self:summary(not self.handle)
    self.phase = phase
    self.nextReport = clock() + REPORT_INTERVAL
    self.report("TIMING_MARK phase=" .. phase)
end

function Timing:close()
    self.alive = false
    if self.handle then CancelDelayedAction(self.handle); self.handle = nil end
    self:summary(true)
end

return Timing
