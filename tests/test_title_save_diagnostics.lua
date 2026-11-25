-- Run against the staged 2.1.0 checkpoint runtime on package.path.
for _, name in ipairs({ "TitleProbe", "PlayerProfile", "PlayerCustom", "ArenaScenes", "ArenaLoadoutMemory", "ArenaLoadoutRestore" }) do
    package.loaded[name] = {}
end

local messages, hooks, snapshots = {}, {}, {}
local gameplayLookups = 0
local level = "PBZ_StartMenu_CE_WP"
local function valid() return true end
local owner = { IsValid = valid }
local registry = {
    ForEach = function() end,
}
local manager = { IsValid = valid, SaveObjects = registry }
local subsystemLibrary = {
    IsValid = valid,
    GetGameInstanceSubsystem = function(_, context)
        assert(context == owner)
        return manager
    end,
}
local gameplay = {
    IsValid = valid,
    GetCurrentLevelName = function() return level end,
    GetPlayerPawn = function() return owner end,
}

function StaticFindObject(path)
    if path == "/Script/Engine.Default__GameplayStatics" then
        gameplayLookups = gameplayLookups + 1
        return gameplay
    end
    if path == "/Script/Engine.Default__SubsystemBlueprintLibrary" then return subsystemLibrary end
    assert(path == "/Script/ProjectPBZ.PBZSaveLoadSubsystem", path)
    return manager
end

function RegisterHook(path, before, after)
    hooks[path] = { before, after }
    return 1, 2
end

package.loaded.SaveBarrier = { new = function()
    return { inspect = function(_, inspected, eligibility)
        assert(inspected == manager)
        snapshots[#snapshots + 1] = { eligibility = eligibility }
        return "fixture snapshot"
    end }
end }

local TitleSession = require("TitleSession")
local session = setmetatable({ log = function(message) messages[#messages + 1] = message end }, TitleSession)
session:installSaveDiagnostics()
local context = { get = function() return owner end }
local function request(phase, action, stage)
    session.phase = phase
    local nextMessage = #messages + 1
    local callback = hooks["/Script/ProjectPBZ.PBZSaveLoadSubsystem:" .. action][stage == "before" and 1 or 2]
    callback(context, 1, { SaveSlotName = "AutoSave0" })
    local expected = "Title probe native save request " .. action .. "/" .. stage
        .. "; phase=" .. phase .. "; reason=1; slot=AutoSave0"
    assert(messages[nextMessage] == expected, messages[nextMessage])
end

for _, phase in ipairs({ "loading", "arena" }) do
    for _, action in ipairs({ "TrySave", "ForceSave" }) do
        request(phase, action, "before")
        request(phase, action, "after")
    end
end
assert(#messages == 8 and #snapshots == 0 and gameplayLookups == 0,
    "loading and arena save hooks should log requests without synchronous snapshots")

request("title", "TrySave", "before")
request("title", "TrySave", "after")
assert(#snapshots == 2 and gameplayLookups == 2 and not snapshots[1].eligibility and not snapshots[2].eligibility)

level = "PBZ_Xigu_WP"
request("title", "TrySave", "before")
assert(#snapshots == 3 and snapshots[3].eligibility, "ordinary game save eligibility diagnostics should still run")
print("PASS save request logging, no snapshots while loading or in the arena, and ordinary save diagnostics")
