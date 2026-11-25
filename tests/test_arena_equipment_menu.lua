-- Run with the staged 2.1.0 checkpoint Scripts directory on package.path.
local function check(fixtureMode)
    local currentTime, held, forged, toggles, closeCount, refreshCount = 0, false, false, 0, 0, 0
    local levelRefreshCount = 0
    local physicalOnly = fixtureMode == "property" or fixtureMode == "hud"
    local hooks, seq = {}, 0
    local function object(api)
        seq = seq + 1
        local address = seq
        api.IsValid = function() return true end
        api.GetAddress = function() return address end
        return api
    end
    local function visual()
        return object({ visibility = 4, GetVisibility = function(self) return self.visibility end,
            SetVisibility = function(self, value) self.visibility = value end })
    end
    local function remote(value)
        return { get = function() return value end, set = function(_, nextValue) value = nextValue end }
    end
    local function callable(callback)
        return setmetatable({}, { __call = function(_, ...) return callback(...) end })
    end
    local controller, pawn = object({ IsInputKeyDown = callable(function(_, key)
        return physicalOnly and key.KeyName == "Gamepad_FaceButton_Bottom" and held
    end) }), object({})
    local backpack = object({})
    local gameplay = object({ GetPlayerController = function() return controller end,
        GetRealTimeSeconds = function() return currentTime end })
    local router = object({ IsUIKeyHeld = function(_, key)
        return not physicalOnly and key.KeyName == "Gamepad_FaceButton_Bottom" and held
    end })
    local hold, costs = visual(), visual()
    local button = object({})
    if fixtureMode == "blueprint" then
        button["Get Item ID"] = callable(function(_, out) out.ItemID = remote("TestWeapon") end)
    elseif fixtureMode == "hud" then
        button.WeaponID = { ToString = function() return "TestWeapon" end }
        function button:GetItem() error("HUD WeaponID should avoid Blueprint out marshalling") end
    elseif fixtureMode == "property" then
        button.Item = { ToString = function() return "TestWeapon" end }
    else
        function button:GetItem(out) out.ItemID = "TestWeapon" end
    end
    button["Init Level"] = callable(function(_, level, nextState)
        assert(level == 3 and nextState == forged)
        levelRefreshCount = levelRefreshCount + 1
    end)
    local group = object({ GetSelectedButtonBase = function() return button end,
        GetSelectedButtonIndex = function() return 0 end, GetButtonCount = function() return 1 end,
        DeselectAll = function() end, SelectButtonAtIndex = function() refreshCount = refreshCount + 1 end })
    local logic = object({ ReCheckItemUpgradeState = function() end })
    function logic:GetItemUpgradeState(id, out)
        local state = remote(0)
        for path, callback in pairs(hooks) do
            if path:find("GetItemUpgradeState", 1, true) then callback(remote(logic), remote(id), state) end
        end
        out.ItemUpgradeState = state:get()
    end
    local slot = object({ SetHorizontalAlignment = function() end, SetVerticalAlignment = function() end,
        SetPadding = function() end })
    local widget = object({ activated = false, focused = true, IsZhuHun = false,
        FirstTab = object({ GetActiveTab = function() return "Weapon" end }),
        W_SystemPanel = object({ ButtonGroup = group }),
        W_UnifiedTextDescription_Weapon = object({ W_LongPressButton = hold, W_Upgrade_NeedItemPanel = costs }),
        WidgetSwitcher_64 = object({ GetActiveWidgetIndex = function() return 0 end }),
        UIGameplayLogicComponent = logic,
        WidgetTree = object({ RootWidget = object({ AddChildToOverlay = function() return slot end }) }),
        GetOwningPlayer = function() return controller end, IsActivated = function(self) return self.activated end,
        DeactivateWidget = function(self) self.activated = false end,
        HasUserFocus = function(self) return fixtureMode ~= "hud" and self.focused end,
        HasUserFocusedDescendants = function() return false end })
    local layout = object({ HasModal = function(self) return self.modal == true end })
    local library = object({
        GetUILayOut = callable(function() return layout end),
        WidgetIsInFocusPath = callable(function(_, candidate) return candidate == button and widget.focused end),
    })
    local bell = object({ GetOwningPlayer = function() return controller end, IsActivated = function() return true end })
    local helpers = object({ GetLocalPlayerFromController = function() return object({}) end,
        PushContentToLayer_ForPlayer = function() widget.activated = true; return widget end })
    local subsystems = object({ GetWorldSubsystem = function() return backpack end,
        GetLocalPlayerSubsystem = function() return router end })
    function StaticFindObject(path)
        if path:find("CommonUIExtensions", 1, true) then return helpers end
        if path:find("PBZBlueprintFunctionLibrary", 1, true) then return library end
        if path:find("SubsystemBlueprintLibrary", 1, true) then return subsystems end
        if path:find("CommonInputSubsystem", 1, true) or path:find("IsHiddenState", 1, true) then return end
        return object({})
    end
    function StaticConstructObject()
        local hint = visual()
        hint.SetShadowOffset = function() end
        hint.SetShadowColorAndOpacity = function() end
        hint.SetText = function() end
        hint.RemoveFromParent = function() end
        return hint
    end
    function FName(value) return value end
    function FText(value) return value end
    function FindAllOf() return {} end
    function RegisterHook(path, callback) hooks[path] = callback; return 1, 2 end
    function UnregisterHook(path) hooks[path] = nil end
    package.loaded.CombatSpawn = { class = function() return object({}) end }
    package.loaded.WeaponEnhancement = { prepare = function(givenPawn, cap)
        assert(givenPawn == pawn and cap == 30)
        return { attach = function(_, actual) return actual == widget end, close = function() closeCount = closeCount + 1 end }
    end }
    local eligible = true
    package.loaded.WeaponSoul = { status = function(_, id, main)
        assert(id == "TestWeapon" and main)
        if eligible then return forged, nil, 3 end
    end, toggle = function()
        assert(eligible)
        forged, toggles = not forged, toggles + 1
        return true, forged
    end }
    package.loaded.ArenaEquipmentMenu = nil
    local menu = require("ArenaEquipmentMenu")
    local function tick(time, down)
        currentTime, held = time, down
        local active, reason = menu.update(pawn)
        assert(active, reason)
    end
    assert(menu.open(gameplay, pawn, bell, 30))
    tick(0, false)
    tick(1, true)
    tick(2, true)
    assert(toggles == 0 and hold.visibility == 4)
    widget.IsZhuHun = true
    tick(3, true)
    tick(4, true)
    assert(toggles == 0 and hold.visibility == 1 and costs.visibility == 1)
    local state = {}
    logic:GetItemUpgradeState("TestWeapon", state)
    assert(state.ItemUpgradeState == 1)
    tick(4.1, false)
    tick(5, true)
    tick(5.5, true)
    assert(toggles == 0)
    tick(5.7, true)
    tick(7, true)
    assert(toggles == 1 and forged and refreshCount == 1 and levelRefreshCount == 1)
    tick(8, false)
    tick(9, true)
    widget.focused = false
    tick(10, true)
    widget.focused = true
    tick(11, true)
    assert(toggles == 1)
    tick(12, false)
    tick(13, true)
    tick(14, true)
    assert(toggles == 2 and not forged and levelRefreshCount == 2)
    layout.modal = true
    tick(14.1, false)
    tick(14.2, true)
    tick(14.9, true)
    layout.modal = false
    assert(toggles == 2)
    eligible = false
    tick(15, false)
    tick(16, true)
    tick(17, true)
    assert(toggles == 2)
    widget.IsZhuHun = false
    tick(18, false)
    assert(hold.visibility == 4 and costs.visibility == 4)
    logic:GetItemUpgradeState("TestWeapon", state)
    assert(state.ItemUpgradeState == 0)
    widget.activated = false
    assert(menu.update(pawn) == false and closeCount == 1 and not next(hooks))
    print(("Equipment menu lifecycle, hold, focus, state guard and eligibility (%s): OK"):format(fixtureMode))
end

for _, mode in ipairs({ "interface", "blueprint", "property", "hud" }) do
    check(mode)
end
