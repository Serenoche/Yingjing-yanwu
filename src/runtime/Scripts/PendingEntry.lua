-- UI-only notice for an installed but unapproved native/loader environment.
-- This module must never require gameplay/save modules or register game keys.
local PendingEntry = {}
local OWNER = "7d5ad307-d21c-47eb-9584-493443190984"
local TITLE_CLASS, TITLE_LEVEL = "WB_StartMenu_V2_C", "PBZ_StartMenu_CE_WP"
local NOTICES = {
    ["native-profile"] = "已安装；当前游戏存档接口尚未适配，演武暂未启用，正常游戏不受影响。",
    ["loader-reload"] = "已安装；现有 UE4SS 开启了热重载。请在原 MOD 管理器关闭热重载和自动重载后，再安装或更新影境演武。演武暂未启用，正常游戏不受影响。",
}
local started, probe, wasTitle = false, nil, false
local ticks, lastLogAt = 0, -math.huge

local function time()
    if type(os) == "table" and type(os.time) == "function" then
        local ok, value = pcall(os.time)
        if ok and type(value) == "number" then return value end
    end
    return ticks * 0.5
end
local function log(code)
    local now = time()
    if now - lastLogAt < 30 then return end
    lastLogAt = now
    print("[PBZTestArenaNative] 演武已安装但暂未启用，正常游戏不受影响（" .. code .. "）。\n")
end
local function read(path, maximum)
    local stream = io.open(path, "rb")
    if not stream then return nil end
    local ok, value = pcall(stream.read, stream, maximum + 1)
    pcall(stream.close, stream)
    if not ok or type(value) ~= "string" or #value > maximum then return nil end
    return value
end
local function normalized(path)
    assert(type(path) == "string" and #path <= 4096 and not path:find("[%z\1-\31\127]"), "invalid pending path")
    path = path:gsub("\\", "/"):gsub("/+$", "")
    assert(path:match("^[A-Za-z]:/") and not path:find("//", 1, true) and not path:sub(3):find(":", 1, true), "invalid pending path")
    assert(not path:find('[*?<>|"]'), "invalid pending path")
    for part in path:gmatch("[^/]+") do assert(part ~= "." and part ~= ".." and not part:match("[. ]$"), "aliased pending path") end
    assert(path:lower():match("/pbztestarena/scripts$"), "invalid pending MOD layout")
    return path
end
local function configuration(scripts)
    scripts = normalized(scripts)
    local modRoot = assert(scripts:match("^(.*)/[^/]+$"))
    local owner = assert(read(modRoot .. "/.PBZTestArenaShared-owner", 128), "pending owner missing")
    assert(owner:match("^%s*(.-)%s*$") == OWNER, "pending owner differs")
    local source = assert(read(scripts .. "/CompatibilityPending.lua", 8192), "pending configuration missing")
    assert(source:match("^%s*return%s*{") and source:match("}%s*$") and source:byte(1) ~= 27, "invalid pending configuration text")
    assert(not source:find("[()%[%]]"), "pending configuration must be a literal table")
    local chunk
    if type(loadstring) == "function" and type(setfenv) == "function" then
        chunk = assert(loadstring(source, "PBZPendingConfig"))
        setfenv(chunk, {}) -- Lua 5.1; no game or global APIs are available here.
    else
        chunk = assert(load(source, "PBZPendingConfig", "t", {}))
    end
    local config = chunk()
    assert(type(config) == "table" and config.schemaVersion == 1 and config.owner == OWNER and config.pending == true,
        "invalid pending configuration identity")
    local allowed = { schemaVersion = true, owner = true, pending = true, reason = true }
    for key in pairs(config) do assert(allowed[key], "unknown pending configuration field") end
    local reason = config.reason or "native-profile"
    assert(reason == "native-profile" or reason == "loader-reload", "unknown pending reason")
    return NOTICES[reason]
end
local function valid(object)
    return object ~= nil and type(object.IsValid) == "function" and object:IsValid()
end
local function text(value)
    if type(value) == "string" then return value end
    return value and value:ToString() or ""
end
local function activeTitle(gameplay)
    for _, menu in ipairs(FindAllOf(TITLE_CLASS) or {}) do
        if valid(menu) and menu:IsActivated() and text(gameplay:GetCurrentLevelName(menu, true)) == TITLE_LEVEL then return true end
    end
    return false
end

function PendingEntry.start(scripts)
    if started then return false end
    started = true
    local ok, notice = pcall(configuration, scripts)
    if not ok then log("配置未确认"); return false end
    for _, name in ipairs({ "LoopInGameThreadWithDelay", "StaticFindObject", "FindAllOf", "StaticConstructObject", "RegisterHook", "UnregisterHook" }) do
        if type(_G[name]) ~= "function" then log("缺少菜单调度接口"); return false end
    end
    if FName == nil or FText == nil then log("缺少菜单文本接口"); return false end
    local function tick()
        ticks = ticks + 1
        local accepted = pcall(function()
            local gameplay = StaticFindObject("/Script/Engine.Default__GameplayStatics")
            if not valid(gameplay) then return end
            if not activeTitle(gameplay) then
                if wasTitle and probe then pcall(probe.close) end
                wasTitle = false
                return
            end
            wasTitle = true
            if not probe then probe = require("TitleProbe") end
            probe.update(gameplay, function(menu)
                local shown = pcall(probe.showError, menu, notice)
                if not shown then log("菜单提示暂不可用") end
                return false -- Reset the owned entry; ordinary title controls stay enabled.
            end)
        end)
        if not accepted then log("菜单接口暂不可用") end
    end
    local scheduled = pcall(LoopInGameThreadWithDelay, 500, tick)
    if not scheduled then log("菜单调度暂不可用"); return false end
    print("[PBZTestArenaNative] " .. notice .. "\n")
    return true
end

return PendingEntry
