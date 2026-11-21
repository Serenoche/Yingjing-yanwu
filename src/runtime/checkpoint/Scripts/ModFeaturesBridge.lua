-- Query the loader through the companion's detached UMG controls.
local Bridge = {}
local GAMEPLAY = "/Script/Engine.Default__GameplayStatics"
local PREFIX = "PBZModFeaturesR1"
local Settings = require("ModLoaderSettings")
local serial = 0

local STATUS = {
    loaded = true, disabled = true, failed = true, stopped = true,
    ["reload-blocked"] = true, unknown = true,
}
local REASONS = {
    ["loader-pending"] = "PBZModLoader 仍在加载。请返回后重新打开此菜单。",
    ["loader-unavailable"] = "当前无法取得 PBZModLoader 的列表。",
    ["companion-unavailable"] = "列表组件未安装或未启用。可查看 UE4SS 和 PAK 分类。",
    ["native-call-failed"] = "读取 PBZModLoader 列表失败。请返回后重试。",
}

local function valid(object)
    local kind = type(object)
    return (kind == "table" or kind == "userdata")
        and type(object.IsValid) == "function" and object:IsValid()
end

local function unwrap(object)
    local kind = type(object)
    if (kind == "table" or kind == "userdata") and type(object.IsValid) ~= "function"
        and type(object.get) == "function" then
        return object:get()
    end
    return object
end

local function toText(value)
    return type(value) == "string" and value or value:ToString()
end

local function findControl(game, path, suffix, className)
    local name = PREFIX .. suffix
    for _, separator in ipairs({":", "."}) do
        local object = StaticFindObject(path .. separator .. name)
        if valid(object) then
            local outer = object:GetOuter()
            if valid(outer) and outer:GetAddress() == game:GetAddress()
                and toText(object:GetFName()) == name and toText(object:GetClass():GetFName()) == className then
                return object
            end
        end
    end
end

local function parse(message, token)
    local header, body = message:gsub("\r\n", "\n"):match("^([^\n]+)\n?(.*)$")
    if header ~= "listed|" .. token then
        local reason = header and header:match("^error|" .. token .. "|([a-z0-9-]+)$")
        return nil, REASONS[reason] or REASONS["native-call-failed"]
    end
    local rows, seen = {}, {}
    for line in body:gmatch("[^\n]+") do
        local id, status = line:match("^([A-Za-z0-9_-]+)|([a-z-]+)$")
        if not id or seen[id] or not STATUS[status] then
            return nil, REASONS["native-call-failed"]
        end
        seen[id] = true
        rows[#rows + 1] = {id = id, status = status}
    end
    table.sort(rows, function(a, b)
        local left, right = a.id:lower(), b.id:lower()
        if left == right then return a.id < b.id end
        return left < right
    end)
    return rows
end

local function request(controller)
    if not valid(controller) or not valid(unwrap(controller:GetWorld())) then
        return nil, REASONS["loader-unavailable"]
    end
    local gameplay = StaticFindObject(GAMEPLAY)
    if not valid(gameplay) then return nil, REASONS["loader-unavailable"] end
    local game = unwrap(gameplay:GetGameInstance(controller))
    if not valid(game) then return nil, REASONS["loader-unavailable"] end
    local path = game:GetFullName():match("^%S+ (.+)$")
    if not path then return nil, REASONS["loader-unavailable"] end
    local response = findControl(game, path, "Response", "TextBlock")
    if not response then return nil, REASONS["loader-unavailable"] end
    local command = findControl(game, path, "Command", "TextBlock")
    local signal = findControl(game, path, "Signal", "Button")
    if not command or not signal then return nil, REASONS["loader-unavailable"] end

    serial = serial % 2147483647 + 1
    local token = tostring(serial)
    command:SetText(FText("list|" .. token))
    signal.OnClicked:Broadcast()
    return parse(toText(response:GetText()), token)
end

function Bridge.list(controller)
    if not Settings.companionAvailable(PREFIX) then return nil, REASONS["companion-unavailable"] end
    local ok, rows, reason = pcall(request, controller)
    if not ok then
        print("[PBZModFeatures] loader list query failed: " .. tostring(rows) .. "\n")
        return nil, REASONS["native-call-failed"]
    end
    if rows then print(("[PBZModFeatures] loader list ready mods=%d\n"):format(#rows)) end
    return rows, reason
end

return Bridge
