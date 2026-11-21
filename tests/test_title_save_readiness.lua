-- Run against the installed or staged runtime on package.path. Pass "installed"
-- to validate the installer-generated configuration and ownership markers too.
local ready, continueSlot, titleClicked = false, "", false
local mounted, vetoAttempts, providerChecks = 0, 0, 0
local notice, selectMode, providerPath
local function valid() return true end
local menu = { GetOwningPlayer = function() return {} end }
local controller = { IsValid = valid }
local game = {
    GetCurrentLevelName = function() return "PBZ_StartMenu_CE_WP" end,
    GetGameInstance = function() return controller end,
    GetCommandLine = function() return "PBZ.exe" end,
}
local manager = {
    IsValid = valid,
    IsSummaryCacheReady = function() return ready end,
    GetContinueSlotName = function() return continueSlot end,
    EnterSaveVeto = function()
        vetoAttempts = vetoAttempts + 1
        error("fixture stopped before the native save transaction")
    end,
}
function StaticFindObject()
    return { IsValid = valid, GetGameInstanceSubsystem = function() return manager end }
end
function FName(name) return name end
package.loaded.TitleProbe = {
    setOrdinaryLoadGuard = function(_, protected) assert(not protected); return true end,
    resume = function() end,
    update = function(_, open)
        mounted = mounted + 1
        if titleClicked then titleClicked = false; open(menu) end
    end,
    showError = function(_, message) notice = message end,
}
package.loaded.TitleHome = {
    update = function() end,
    isOpen = function() return false end,
    open = function(_, _, _, choose) selectMode = choose end,
}
package.loaded.SaveBarrier = { new = function()
    return { inspect = function()
        providerChecks = providerChecks + 1
        return ";providerReady=1;providerPathHex=" .. providerPath:gsub(".", function(byte)
            return ("%02x"):format(byte:byte())
        end) .. ";"
    end }
end }

local options = {
    integrated = true, diagnostics = false,
    trainingSlot = "PBZArenaIntegratedTraining", cyclePrefix = "PBZArenaIntegratedCycle",
    savePath = "C:/Fixture/ProjectPBZ/Saved/SaveGames/Steam/" .. tostring(0x0110000100000001) .. "/PBZSaveGame.sav",
}
if arg and arg[1] == "installed" then options = assert(require("Integration").load(game)) end
local title = require("TitleSession").new(options.profile or "C:/Fixture/Profile", function() end, options)
title:tick(game, controller)
assert(mounted == 1 and not title.initialized, "entry should mount before the native index is ready")

local function choose()
    titleClicked = true
    title:tick(game, controller)
    assert(selectMode, "the entry should open the mode selector")
    selectMode({ mode = "training", sceneId = "xigu", playerCycle = 0, enemyCycle = 0, skillLevel = 0 })
end
choose()
assert(notice:find("正在读取存档", 1, true) and vetoAttempts == 0 and providerChecks == 0)
ready = true
choose()
assert(notice:find("没有可继续的普通存档", 1, true) and vetoAttempts == 0 and providerChecks == 0)
continueSlot, providerPath = "ContinueFixture", options.savePath:gsub("PBZSaveGame%.sav$", "Other.sav")
choose()
assert(notice:find("账号不同", 1, true) and vetoAttempts == 0 and providerChecks == 1)
providerPath = arg and arg[2] or options.savePath
choose()
assert(title.initialized and providerChecks == 2 and vetoAttempts == 1, "validated entry should reach the guarded transaction")
print("PASS title entry before index readiness, ordinary slot and account gates, and retry")
