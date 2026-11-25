-- The native companion loads arena checkpoints through a private master while
-- the original save manager's disk writes are blocked.
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
    local selectCheckpoint, selectError = package.loadlib(path, "PBZBarrierSelectCheckpoint")
    assert(selectCheckpoint, "native map checkpoint interface is missing: " .. tostring(selectError))
    local disarm, disarmError = package.loadlib(path, "PBZBarrierDisarm")
    assert(disarm, "native save barrier restore interface is missing: " .. tostring(disarmError))
    local prepare, prepareError = package.loadlib(path, "PBZBarrierPrepareRestore")
    assert(prepare, "native save barrier transaction interface is missing: " .. tostring(prepareError))
    local inspect, inspectError = package.loadlib(path, "PBZBarrierInspect")
    assert(inspect, "native save barrier diagnostics interface is missing: " .. tostring(inspectError))
    local eligibility, eligibilityError = package.loadlib(path, "PBZBarrierInspectEligibility")
    assert(eligibility, "native save eligibility diagnostics interface is missing: " .. tostring(eligibilityError))
    local loadout = package.loadlib(path, "PBZBarrierCheckpointLoadoutV1")
    local custom = package.loadlib(path, "PBZBarrierPlayerCustomV1")
    return setmetatable({ path = path, armNative = arm, selectNative = selectCheckpoint, prepareNative = prepare,
        disarmNative = disarm, inspectNative = inspect, eligibilityNative = eligibility, armed = false,
        supportsLoadout = type(loadout) == "function", supportsPlayerCustom = type(custom) == "function" }, SaveBarrier)
end

function SaveBarrier:request(action, expected, allowBusy, selection)
    serial = serial + 1
    local nonce = os.date("!%Y%m%d%H%M%S") .. "_" .. serial .. "_" .. tostring(math.floor(os.clock() * 1000000))
    writeFile(self.path .. ".request", nonce .. "\t" .. self.managerAddress .. (selection or ""))
    action()
    local result = readFile(self.path .. ".status") or ""
    local inspected = nonce .. "\tinspect\t"
    if expected == "inspect" and result:sub(1, #inspected) == inspected and result:sub(-1) == "\n" then
        return result:sub(#inspected + 1, -2)
    end
    if allowBusy and result == nonce .. "\tbusy\n" then return false, "native save queue is busy" end
    if (expected == "armed" or expected == "selected") and result == nonce .. "\t" .. expected .. "\tprojected\n" then
        return true, nil, true
    end
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

local function checkpointRequest(slot, cycle, loadout)
    assert(type(slot) == "string" and slot:match("^PBZArenaStockMap%d%d$"), "原版地图存点无效")
    assert(type(cycle) == "number" and cycle % 1 == 0 and cycle >= -1 and cycle <= 6, "玩家轮回无效")
    return ("\t%s\t%d"):format(slot, cycle) .. (loadout and "\t" .. loadout or "")
end

function SaveBarrier:arm(manager, slot, cycle, loadout)
    assert(not self.uncertain, "native save transaction state is unknown; restart the disposable session")
    if self.armed then return end
    assert(not loadout or loadout:sub(1, 8) ~= "custom1," or self.supportsPlayerCustom, "自订角色需要内测存点组件")
    loadout = self.supportsLoadout and loadout or nil
    self.lastRefusal = nil
    self.managerAddress = string.format("%X", manager:GetAddress())
    local ok, accepted, reason, projected = pcall(self.request, self, self.armNative, "armed", true, checkpointRequest(slot, cycle, loadout))
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
    self.slot, self.cycle = slot, cycle
    self.loadoutRequest = loadout
    self.projectedLoadout = projected and (loadout:gsub("^custom1,[^\t]*\t", "")) or nil
end

function SaveBarrier:selectCheckpoint(slot, cycle, loadout)
    assert(self.armed and not self.uncertain, "演武存点会话未就绪")
    assert(not loadout or loadout:sub(1, 8) ~= "custom1," or self.supportsPlayerCustom, "自订角色需要内测存点组件")
    loadout = self.supportsLoadout and loadout or nil
    if self.slot == slot and self.cycle == cycle and self.loadoutRequest == loadout then return true end
    local ok, why, projected = self:request(self.selectNative, "selected", true, checkpointRequest(slot, cycle, loadout))
    if ok then
        self.slot, self.cycle = slot, cycle
        self.loadoutRequest = loadout
        self.projectedLoadout = projected and (loadout:gsub("^custom1,[^\t]*\t", "")) or nil
    end
    return ok, why
end

function SaveBarrier:prepareRestore()
    assert(self.armed, "native save barrier is not armed")
    return self:request(self.prepareNative, "prepared", true)
end

function SaveBarrier:disarm()
    if not self.armed then return true end
    if not self:request(self.disarmNative, "idle", true) then return false end
    self.armed = false
    self.loadoutRequest, self.projectedLoadout = nil, nil
    return true
end

return SaveBarrier
