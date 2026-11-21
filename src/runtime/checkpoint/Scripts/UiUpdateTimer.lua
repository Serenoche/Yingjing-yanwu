local Timer = {}
Timer.__index = Timer
local INTERVAL_MS = 33

local function log(timer, event, detail)
    print(("[PBZUiUpdate] %s owner=%s handle=%s%s\n")
        :format(event, timer.owner, tostring(timer.handle), detail and (" " .. detail) or ""))
end

local function unregister(self)
    if not self.handle then return true end
    local ok, removed = pcall(CancelDelayedAction, self.handle)
    if ok and removed ~= true and type(IsValidDelayedActionHandle) == "function" then
        local checked, live = pcall(IsValidDelayedActionHandle, self.handle)
        removed = checked and live == false
    end
    if ok and removed == true then
        self.handle = nil
        return true
    end
    if not self.cancelReported then
        self.cancelReported = true
        log(self, "cancel-pending", "reason=" .. self.reason .. " result=" .. tostring(removed))
    end
    return false
end

function Timer:stop(reason)
    if self.closed then return unregister(self) end
    self.closed, self.reason = true, reason or "closed"
    local cancelled = unregister(self)
    local onStop = self.onStop
    self.onStop = nil
    if onStop then
        local ok, failure = pcall(onStop, self.reason)
        if not ok then log(self, "cleanup-error", tostring(failure)) end
    end
    return cancelled
end

function Timer.start(owner, update, onStop)
    local self = setmetatable({owner=owner, onStop=onStop}, Timer)
    if type(LoopInGameThreadWithDelay) ~= "function" or type(CancelDelayedAction) ~= "function" then
        return nil, "no native scheduler"
    end
    local ok, handle = pcall(LoopInGameThreadWithDelay, INTERVAL_MS, function()
        -- A native ready list can still dispatch a callback that was cancelled
        -- by another action in the same frame.
        if self.closed then unregister(self); return end
        local updated, result = pcall(update)
        if not updated then
            log(self, "update-error", tostring(result))
            self:stop("callback error")
        elseif result == false then
            self:stop("closed")
        end
    end)
    if not ok or type(handle) ~= "number" or handle <= 0 then
        return nil, ok and "invalid native scheduler handle" or tostring(handle)
    end
    self.handle = handle
    return self
end

return Timer
