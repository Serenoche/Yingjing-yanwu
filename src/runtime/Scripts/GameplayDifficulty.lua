-- Change only the active MOD world's real difficulty. No user settings file,
-- shared CDO, save-provider routing, or ordinary-world state is written here.
local Difficulty = {}
local Session = {}
Session.__index = Session
local current

local LIBRARY = "/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary"
local SUBSYSTEMS = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local GAME_SYSTEM = "/Script/ProjectPBZ.PBZGameSystem"
local SETTING_CLASS = "/Script/ProjectPBZ.DemoSetting_Difficulty"
local SETTER = SETTING_CLASS .. ":SetReallyDifficulty"
local ROW_CLASS = "/Game/PBZContent/UI/Settings/Editors/W_SettingsListEntry_Discrete.W_SettingsListEntry_Discrete_C"
local ROW_EVENT = ROW_CLASS .. ":OnListItemObjectSet"
local PENDING = 0x08023600
Difficulty.choices = { { id = 1, name = "入阵者" }, { id = 2, name = "破局者" }, { id = 3, name = "逆天者" } }

local function valid(object)
    return object ~= nil and type(object.IsValid) == "function" and object:IsValid()
end
local function unwrap(value)
    local ok, object = pcall(function() return value:get() end)
    if ok then return object end
    return value
end
local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "missing difficulty interface: " .. path)
    return object
end
local function worldOf(object)
    if not valid(object) then return nil end
    local world = object:GetWorld()
    return valid(world) and world:GetAddress() or nil
end
local function read(pawn)
    return required(LIBRARY):GetDiffcultMode(pawn)
end
local function label(id)
    return Difficulty.choices[id] and Difficulty.choices[id].name or tostring(id)
end

function Session:owns(pawn)
    return valid(pawn) and pawn:GetAddress() == self.pawnAddress and worldOf(pawn) == self.world
        and valid(self.system) and worldOf(self.system) == self.world
end

function Session:restoreRow(address)
    local entry = self.rows[address]
    if not entry then return end
    if valid(entry.widget) and worldOf(entry.widget) == self.world then entry.widget:SetIsEnabled(entry.enabled) end
    self.rows[address] = nil
end

function Session:assignRow(widget, setting)
    if self.closed or not self:owns(self.pawn) or not valid(widget) or worldOf(widget) ~= self.world then return end
    local address = widget:GetAddress()
    if not valid(setting) or not setting:IsA(self.settingClass) or worldOf(setting) ~= self.world then
        self:restoreRow(address)
        return
    end
    local entry = self.rows[address]
    if not entry then
        entry = { widget = widget, enabled = widget:GetIsEnabled() }
        self.rows[address] = entry
    end
    widget:SetIsEnabled(false)
end

function Session:installRowHook()
    if self.rowHook then return end
    local event = StaticFindObject(ROW_EVENT)
    if not valid(event) then
        -- This preloads the original editor class; it does not construct UI.
        pcall(LoadAsset, ROW_CLASS)
        event = StaticFindObject(ROW_EVENT)
        if not valid(event) then
            pcall(LoadAsset, (ROW_CLASS:gsub("_C$", "")))
            event = StaticFindObject(ROW_EVENT)
        end
    end
    if not valid(event) or event:HasAnyFlags(PENDING) then return end
    -- For non-/Script/ functions UE4SS's second callback argument is post-call.
    local pre, post = RegisterHook(ROW_EVENT, function(context, item)
        self:assignRow(unwrap(context), unwrap(item))
    end)
    self.rowHook = { pre, post }
end

function Difficulty.new(pawn, selected)
    assert(type(selected) == "number" and selected % 1 == 0 and selected >= 1 and selected <= 3,
        "MOD difficulty must be 1, 2 or 3")
    assert(valid(pawn) and worldOf(pawn), "MOD difficulty player is unavailable")
    if current and not current.cleaned then current:close() end
    local original = read(pawn)
    assert(type(original) == "number" and original >= 0 and original <= 4, "original world difficulty is unavailable")
    local system = required(SUBSYSTEMS):GetWorldSubsystem(pawn, required(GAME_SYSTEM))
    assert(valid(system) and worldOf(system) == worldOf(pawn), "MOD difficulty game system is unavailable")
    local session = setmetatable({ pawn = pawn, pawnAddress = pawn:GetAddress(), world = worldOf(pawn),
        system = system, original = original, selected = selected, rows = {}, settingClass = required(SETTING_CLASS) }, Session)
    current = session
    local ok, failure = pcall(function()
        assert(valid(StaticFindObject(SETTER)), "native difficulty settings setter is unavailable")
        local pre, post = RegisterHook(SETTER, function(context, value)
            local setting = unwrap(context)
            if session.closed or not session:owns(session.pawn) or not valid(setting)
                or not setting:IsA(session.settingClass) or worldOf(setting) ~= session.world then return end
            -- Pin only this live world's difficulty, including whole-page reset.
            -- RemoteUnrealParam:set writes the original function parameter.
            value:set(session.selected)
        end)
        session.setterHook = { pre, post }
        system:SetDifficultMode(selected)
        assert(read(pawn) == selected, "native world difficulty readback did not match")
        session:installRowHook()
    end)
    if not ok then
        local restored, reason = pcall(session.close, session)
        error(tostring(failure) .. (restored and "" or ("; rollback: " .. tostring(reason))), 0)
    end
    print("[PBZTestArenaNative] MOD world difficulty applied: " .. selected .. " " .. label(selected) .. "\n")
    return session
end

function Session:update(pawn)
    assert(not self.closed, "MOD difficulty session is closed")
    if not self:owns(pawn) then self:close(); return false, "MOD difficulty world changed" end
    if read(pawn) ~= self.selected then
        self.system:SetDifficultMode(self.selected)
        assert(read(pawn) == self.selected, "native MOD difficulty could not be kept")
    end
    self:installRowHook()
    for address, entry in pairs(self.rows) do
        if not valid(entry.widget) or worldOf(entry.widget) ~= self.world then self.rows[address] = nil
        elseif entry.widget:GetIsEnabled() then entry.widget:SetIsEnabled(false) end
    end
    return true
end

function Session:close()
    if self.cleaned then return true end
    self.closed = true
    local failures = {}
    for _, hook in ipairs({ { SETTER, "setterHook" }, { ROW_EVENT, "rowHook" } }) do
        local ids = self[hook[2]]
        if ids then
            local removed, failure = pcall(UnregisterHook, hook[1], ids[1], ids[2])
            if removed then self[hook[2]] = nil else failures[#failures + 1] = tostring(failure) end
        end
    end
    for address in pairs(self.rows) do
        local restored, failure = pcall(self.restoreRow, self, address)
        if not restored then failures[#failures + 1] = tostring(failure) end
    end
    -- A stale MOD pawn must never be used to resolve and write the new world's
    -- subsystem. Restore only the exact captured world/system, while it exists.
    if self:owns(self.pawn) then
        local restored, failure = pcall(function()
            if read(self.pawn) ~= self.original then self.system:SetDifficultMode(self.original) end
            assert(read(self.pawn) == self.original, "original world difficulty could not be restored")
        end)
        if not restored then failures[#failures + 1] = tostring(failure) end
    end
    assert(#failures == 0, table.concat(failures, "; "))
    self.cleaned = true
    if current == self then current = nil end
    return true
end

return Difficulty
