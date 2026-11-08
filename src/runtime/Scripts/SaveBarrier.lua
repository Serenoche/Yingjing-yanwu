-- The native companion detaches the original master and blocks disk writes.
-- It is loaded only for the disposable title experiment until live validation.
local SaveBarrier = {}
SaveBarrier.__index = SaveBarrier

local serial = 0

local function readFile(path)
    local stream = io.open(path, "rb")
    if not stream then return nil end
    local bytes = stream:read(262144)
    stream:close()
    return bytes
end

local function writeFile(path, bytes)
    local stream = assert(io.open(path, "wb"), "cannot open native save barrier request")
    local wrote, writeError = stream:write(bytes)
    local closed, closeError = stream:close()
    assert(wrote and closed, writeError or closeError)
end

function SaveBarrier.new()
    local source = debug.getinfo(1, "S").source
    assert(source:sub(1, 1) == "@", "native save barrier needs its installed script path")
    local directory = assert(source:sub(2):match("^(.*)[/\\][^/\\]+$"), "native save barrier script directory is missing")
    local path = directory .. "/PBZSaveBarrier.dll"
    local arm, armError = package.loadlib(path, "PBZBarrierArm")
    assert(arm, "native save barrier could not be loaded: " .. tostring(armError))
    local disarm, disarmError = package.loadlib(path, "PBZBarrierDisarm")
    assert(disarm, "native save barrier restore interface is missing: " .. tostring(disarmError))
    local prepare, prepareError = package.loadlib(path, "PBZBarrierPrepareRestore")
    assert(prepare, "native save barrier transaction interface is missing: " .. tostring(prepareError))
    local inspect, inspectError = package.loadlib(path, "PBZBarrierInspect")
    assert(inspect, "native save barrier diagnostics interface is missing: " .. tostring(inspectError))
    local eligibility, eligibilityError = package.loadlib(path, "PBZBarrierInspectEligibility")
    assert(eligibility, "native save eligibility diagnostics interface is missing: " .. tostring(eligibilityError))
    return setmetatable({ path = path, armNative = arm, prepareNative = prepare,
        disarmNative = disarm, inspectNative = inspect, eligibilityNative = eligibility, armed = false }, SaveBarrier)
end

function SaveBarrier:request(action, expected, allowBusy)
    serial = serial + 1
    local nonce = os.date("!%Y%m%d%H%M%S") .. "_" .. serial .. "_" .. tostring(math.floor(os.clock() * 1000000))
    writeFile(self.path .. ".request", nonce .. "\t" .. self.managerAddress)
    action()
    local result = readFile(self.path .. ".status") or ""
    local inspected = nonce .. "\tinspect\t"
    if expected == "inspect" and result:sub(1, #inspected) == inspected and result:sub(-1) == "\n" then
        return result:sub(#inspected + 1, -2)
    end
    if allowBusy and result == nonce .. "\tbusy\n" then return false, "native save queue is busy" end
    local refusal = nonce .. "\trefused\t"
    if expected == "armed" and result:sub(1, #refusal) == refusal
        and result:sub(-1) == "\n" and not result:sub(#refusal + 1, -2):find("[\r\n]") then
        return false, result:sub(#refusal + 1, -2)
    end
    assert(result == nonce .. "\t" .. expected .. "\n",
        "native save barrier rejected " .. expected .. ": " .. result:gsub("[\r\n]", " "))
    return true
end

function SaveBarrier:inspect(manager, eligibility)
    local address = self.managerAddress
    self.managerAddress = string.format("%X", manager:GetAddress())
    local ok, state = pcall(self.request, self, eligibility and self.eligibilityNative or self.inspectNative, "inspect")
    self.managerAddress = address
    assert(ok, state)
    return state
end

function SaveBarrier:arm(manager)
    assert(not self.uncertain, "native save transaction state is unknown; restart the disposable session")
    if self.armed then return end
    self.lastRefusal = nil
    self.managerAddress = string.format("%X", manager:GetAddress())
    local ok, accepted, reason = pcall(self.request, self, self.armNative, "armed", true)
    if ok and accepted == false then
        self.lastRefusal = reason
        error(reason, 0)
    end
    if not ok then
        -- An unacknowledged Arm may already have changed native state. Keep
        -- the session dormant until process exit instead of assuming it failed.
        self.uncertain = true
        error(accepted, 0)
    end
    self.armed = true
end

function SaveBarrier:prepareRestore()
    assert(self.armed, "native save barrier is not armed")
    return self:request(self.prepareNative, "prepared", true)
end

function SaveBarrier:disarm()
    if not self.armed then return true end
    if not self:request(self.disarmNative, "idle", true) then return false end
    self.armed = false
    return true
end

return SaveBarrier
