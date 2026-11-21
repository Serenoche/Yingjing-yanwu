local Preferences = {}
local OFF = "off\n"
local markerPath
local statusHudEnabled = true

local function read(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local bytes = file:read(#OFF + 1) or ""
    file:close()
    return bytes
end

function Preferences.configure(directory)
    local nextPath = directory .. "PBZStatusBuildupDisabled.txt"
    if nextPath == markerPath then return end
    markerPath = nextPath
    statusHudEnabled = read(markerPath) ~= OFF
end

function Preferences.statusHudEnabled()
    return statusHudEnabled
end

function Preferences.setStatusHudEnabled(enabled)
    if not markerPath or type(enabled) ~= "boolean" then return false end
    local existing = read(markerPath)
    if enabled then
        local removed, _, code = os.remove(markerPath)
        if not removed and code ~= 2 then return false end
    elseif existing ~= OFF then
        local temporary = markerPath .. ".pending"
        local file = io.open(temporary, "wb")
        if not file then return false end
        local written = file:write(OFF)
        local closed = file:close()
        if not written or not closed or read(temporary) ~= OFF then
            os.remove(temporary)
            return false
        end
        -- A malformed marker already means enabled. Removing it preserves that
        -- state if the verified replacement cannot be moved into place.
        if (existing ~= nil and not os.remove(markerPath)) or not os.rename(temporary, markerPath) then
            os.remove(temporary)
            return false
        end
    end
    statusHudEnabled = enabled
    print("[PBZDisplayPreferences] status_hud=" .. tostring(enabled) .. "\n")
    return true
end

return Preferences
