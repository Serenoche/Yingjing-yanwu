-- One pre-combat medicine restock per owner-created round session. Selection,
-- medicine level, buffs and player attributes are never changed here.
local Medicine, Session = {}, {}
Session.__index = Session
local SUBSYSTEMS = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local BACKPACK = "/Script/ProjectPBZ.PBZBackPackSubsystem"
local HUD_CDO = "/Script/ProjectPBZ.Default__PBZHUDLayout"
local HUD_CLASS = "/Script/ProjectPBZ.PBZHUDLayout"
local QUICK_SLOT = "/Game/PBZContent/UI/UINew/Hud/WB_quickslot.WB_quickslot_C"
local STABLE_SECONDS, DISPLAY_BUDGET = 0.1, 64
local MAX_INT = 2147483647
local function valid(value)
    return value ~= nil and type(value.IsValid) == "function" and value:IsValid()
end
local function unwrap(value)
    if value and type(value.IsValid) ~= "function" then
        local get = value.get or value.Get
        if type(get) == "function" then return get(value) end
    end
    return value
end
local function required(path)
    local value = StaticFindObject(path)
    assert(valid(value), "medicine restock interface is not ready: " .. path)
    return value
end
local function integer(value)
    return type(value) == "number" and value >= 0 and value <= MAX_INT and value % 1 == 0
end
local function medicineId(value)
    value = unwrap(value)
    local id = type(value) == "string" and value or value and value:ToString() or ""
    if id == "" or id:lower() == "none" then return false end
    assert(#id <= 256 and id:match("^[A-Za-z0-9_%-]+$"), "medicine restock slot ID is invalid")
    return id
end
local function slotIds(bp)
    return { medicineId(bp:GetMedicineByIndex(1)), medicineId(bp:GetMedicineByIndex(0)) }
end
local function sameIds(a,b) return a[1] == b[1] and a[2] == b[2] end
local function read(bp)
    local ids, slots = slotIds(bp), {}
    local map = bp.MedicineInfos
    assert(map ~= nil, "medicine inventory is not ready")
    for index=1,2 do
        local id = ids[index]
        if not id then slots[index] = false
        else
            -- Copy primitive fields before any further UFunction can reuse the
            -- borrowed UScriptStruct view returned by the inventory map.
            local info = unwrap(map:Find(FName(id)))
            assert(info ~= nil, "equipped medicine info is not ready")
            local current, display, level, base = info.CurrentTime, info.DisplayTime, info.CurrentLevel, info.MaxTime
            assert(integer(current) and integer(display) and integer(level) and integer(base),
                "equipped medicine counts or level are not ready")
            local maximum = bp:GetMedicineTotalMaxUsage(FName(id))
            assert(integer(maximum), "equipped medicine capacity is not ready")
            slots[index] = { id=id,current=current,display=display,level=level,base=base,maximum=maximum }
        end
    end
    assert(sameIds(ids,slotIds(bp)), "medicine slots changed while reading inventory")
    return slots
end
local function sameSelection(a,b)
    for index=1,2 do
        local left,right = a[index],b[index]
        if not left or not right then
            if left ~= right then return false end
        elseif left.id ~= right.id or left.level ~= right.level or left.base ~= right.base
            or left.maximum ~= right.maximum then return false end
    end
    return true
end
local function full(slots)
    for index=1,2 do
        local item = slots[index]
        if item and (item.current < item.maximum or item.display < item.maximum) then return false end
    end
    return true
end
function Medicine.new(pawn)
    assert(valid(pawn), "medicine round player is unavailable")
    local world = unwrap(pawn:GetWorld())
    assert(valid(world), "medicine round world is unavailable")
    return setmetatable({ pawnAddress=pawn:GetAddress(),worldAddress=world:GetAddress() },Session)
end
function Session:backpack(pawn)
    assert(valid(pawn) and pawn:GetAddress() == self.pawnAddress, "medicine round player changed")
    local world = unwrap(pawn:GetWorld())
    assert(valid(world) and world:GetAddress() == self.worldAddress, "medicine round world changed")
    local bp = unwrap(required(SUBSYSTEMS):GetWorldSubsystem(pawn,required(BACKPACK)))
    assert(valid(bp), "medicine round backpack is not ready")
    local address = bp:GetAddress()
    assert(not self.backpackAddress or self.backpackAddress == address, "medicine round backpack changed")
    self.backpackAddress = address
    return bp
end
function Session:waitFor(slots,now)
    self.selection,self.since = slots,now
    return false,"waiting for equipped medicine slots and capacity to settle"
end
function Session:refreshDisplay(pawn,controller)
    if not valid(controller) then return false end
    local world = unwrap(controller:GetWorld())
    local controlled = unwrap(controller:K2_GetPawn())
    if not valid(world) or world:GetAddress() ~= self.worldAddress
        or not valid(controlled) or controlled:GetAddress() ~= pawn:GetAddress() then return false end
    local hud = unwrap(required(HUD_CDO):GetHUDLayout(controller))
    if not valid(hud) or not hud:IsA(required(HUD_CLASS)) then return false end
    local owner,hudWorld = unwrap(hud:GetOwningPlayer()),unwrap(hud:GetWorld())
    if not valid(owner) or owner:GetAddress() ~= controller:GetAddress()
        or not valid(hudWorld) or hudWorld:GetAddress() ~= self.worldAddress then return false end
    local slot = unwrap(hud.WB_quickslot)
    if not valid(slot) or not slot:IsA(required(QUICK_SLOT)) then return false end
    local slotOwner,slotWorld = unwrap(slot:GetOwningPlayer()),unwrap(slot:GetWorld())
    if not valid(slotOwner) or slotOwner:GetAddress() ~= controller:GetAddress()
        or not valid(slotWorld) or slotWorld:GetAddress() ~= self.worldAddress then return false end
    slot:UpdateNum()
    return true
end
function Session:update(pawn,now,controller)
    if self.done then return true end -- no reads or refills after this round is armed
    local ok,ready,reason = pcall(function()
        assert(type(now) == "number" and now == now and math.abs(now) < math.huge, "medicine restock clock is invalid")
        local bp = self:backpack(pawn)
        local slots = read(bp)
        if not self.selection or not sameSelection(self.selection,slots) or now < self.since then return self:waitFor(slots,now) end
        if now-self.since+0.000001 < STABLE_SECONDS then return false,"waiting for stable equipped medicine slots" end
        local function refresh()
            local current = read(self:backpack(pawn))
            if not sameSelection(slots,current) then self:waitFor(current,now); return nil end
            slots = current
            return current
        end
        local displayBudget = DISPLAY_BUDGET
        for index=1,2 do
            local item = slots[index]
            if item then
                if item.current < item.maximum then
                    assert(bp:AddMedicineAmount(FName(item.id),item.maximum-item.current) == true,
                        "native medicine refill was not accepted")
                    if not refresh() then return false,"medicine selection changed during refill" end
                    item = slots[index]
                    if item.current < item.maximum then return false,"waiting for native medicine amount to settle" end
                end
                while item.display < item.maximum and displayBudget > 0 do
                    local previous = item.display
                    bp:AddMedicineDisplayNum(FName(item.id),1)
                    displayBudget = displayBudget-1
                    if not refresh() then return false,"medicine selection changed during display refill" end
                    item = slots[index]
                    if item.display <= previous then return false,"waiting for native medicine display count to settle" end
                end
            end
        end
        if not refresh() then return false,"medicine selection changed before confirmation" end
        if not full(slots) then return false,"finishing native medicine display counts" end
        local refreshFailed = false
        if controller ~= nil then
            self.displayRefreshAttempted = true
            local refreshed,result = pcall(self.refreshDisplay,self,pawn,controller)
            self.displayRefreshed = refreshed and result == true
            refreshFailed = not refreshed
        end
        self.done,self.selection,self.since = true,nil,nil
        local lines = {}
        for index=1,2 do
            local item = slots[index]
            lines[#lines+1] = item and ("slot%d=%s current=%d display=%d max=%d"):format(
                index,item.id,item.current,item.display,item.maximum) or ("slot%d=empty"):format(index)
        end
        pcall(print,"[PBZChallengeMedicine] ready; " .. table.concat(lines,"; ") .. "\n")
        if refreshFailed then pcall(print,"[PBZChallengeMedicine] quick-slot refresh unavailable; medicine counts are full\n") end
        return true
    end)
    if not ok then return false,tostring(ready) end
    return ready,reason
end
return Medicine
