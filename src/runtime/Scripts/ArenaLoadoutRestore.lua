local Native = require("ArenaLoadout")
local Restore = {}
Restore.__index = Restore

local GROUPS = {{"mainWeapons", 2}, {"shadowWeapons", 2}, {"accessories", 6}, {"medicines", 2}}
local INITIALIZATION_SECONDS = 12
local NO_PROGRESS_SECONDS = 6

function Restore.checkpointWire(selection)
    if not selection then return nil end
    local fields = {}
    for _, group in ipairs(GROUPS) do
        local slots = selection[group[1]]
        for index = 1, group[2] do
            local item = slots[index]
            if item and (#item > 160 or not item:match("^[A-Za-z0-9_%-]+$")) then return nil end
            fields[#fields + 1] = item or "None"
        end
    end
    return table.concat(fields, "\t")
end

function Restore.new(selection, projected)
    assert(selection, "配装恢复缺少选择快照")
    return setmetatable({ selection = selection, projected = Restore.checkpointWire(selection) == projected and projected or nil }, Restore)
end

-- true: confirmed; nil: still waiting; false: timed out. The Windows process
-- clock keeps the restore budget independent of time jumps on world load.
function Restore:update(pawn)
    local now = os.clock()
    if self.nextAttempt and now < self.nextAttempt then return nil, self.reason end
    self.nextAttempt = now + .10
    self.started = self.started or now
    if self.projected then
        local current, reason = Native.capture(pawn)
        if current and Restore.checkpointWire(current) == self.projected then return true, "native" end
        if now - self.started < INITIALIZATION_SECONDS then
            self.reason = reason or "等待原生存点配装回读"
            return nil, self.reason
        end
        -- The projected slots may have been altered by a game or MOD callback.
        -- Retain the requested snapshot and attempt the checked slot adapter.
        self.projected, self.started = nil, now
    end

    local ready, reason, confirmed = Native.apply(pawn, self.selection)
    if ready then return true, "slots" end
    self.reason = reason
    -- A repeated setter for the same slot does not extend the deadline.
    if confirmed and (not self.confirmed or confirmed > self.confirmed) then
        self.confirmed, self.progressAt = confirmed, now
    end
    local budget = self.progressAt and NO_PROGRESS_SECONDS or INITIALIZATION_SECONDS
    if now - (self.progressAt or self.started) >= budget then return false, reason end
    return nil, reason
end

return Restore
