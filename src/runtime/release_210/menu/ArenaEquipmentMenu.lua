local CombatSpawn = require("CombatSpawn")
local Enhancement = require("WeaponEnhancement")
local Soul = require("WeaponSoul")

local Menu = {}
local WIDGET = "/Game/PBZContent/UI/UINew/System/Upgrade/W_UpgradeActivatableWidget_V1.W_UpgradeActivatableWidget_V1_C"
local COMMON_UI = "/Script/CommonGame.Default__CommonUIExtensions"
local COMMON_INPUT = "/Script/CommonInput.CommonInputSubsystem"
local LIBRARY = "/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary"
local SUBSYSTEMS = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local BACKPACK = "/Script/ProjectPBZ.PBZBackPackSubsystem"
local ROUTER = "/Script/ProjectPBZ.PBZUIActionRouterBase"
local FOOTER_STYLE = "/Game/PBZContent/UI/Foundation/Text/TextStyle_Regular.TextStyle_Regular_C"
local SOUL_STATE = "/Game/PBZContent/UI/Component/BP_UIGameplayLogicComponent.BP_UIGameplayLogicComponent_C:GetItemUpgradeState"
local CAN_FORGE, BLOCKED = 0, 1
local HOLD_SECONDS = 0.65
local current

local function valid(object)
    return object and type(object.IsValid) == "function" and object:IsValid()
end

local function same(first, second)
    return valid(first) and valid(second) and first:GetAddress() == second:GetAddress()
end

local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "装备调整缺少原版接口 " .. path)
    return object
end

local function name(value)
    local kind = type(value)
    if kind == "string" then return value end
    if kind == "userdata" or kind == "table" then
        if type(value.ToString) == "function" then return value:ToString() end
        local getter = value.get or value.Get
        if type(getter) == "function" then
            local raw = getter(value)
            if type(raw) == "string" then return raw end
            local rawType = type(raw)
            if (rawType == "userdata" or rawType == "table") and type(raw.ToString) == "function" then
                return raw:ToString()
            end
        end
    end
end

local function report(message)
    print("[PBZArenaEquipment] " .. message .. "\n")
end

local function hintKey(session)
    local input = session.input
    if valid(input) and input:GetCurrentInputType() == 1 then
        local gamepad = name(input:GetCurrentGamepadName())
        if gamepad == "PS4" or gamepad == "PS5" then return "×" end
        if gamepad == "NS" then return "B" end
        return "A"
    end
    return valid(input) and "空格" or "A／空格"
end

local function setHint(session, label)
    local hint = session.hint
    if label == session.label or not valid(hint) then return end
    session.label = label
    hint:SetVisibility(label and 3 or 1)
    if label then hint:SetText(FText(label)) end
end

local function addHint(session)
    local widget = session.widget
    local root = widget.WidgetTree.RootWidget
    assert(valid(root), "原版强化界面没有装备调整提示插槽")
    local hint = StaticConstructObject(required("/Script/UMG.TextBlock"), widget.WidgetTree)
    assert(valid(hint), "无法创建铸魂切换提示")
    session.hint = hint
    pcall(function() hint:SetFont(CombatSpawn.class(FOOTER_STYLE):GetCDO().Font) end)
    hint:SetShadowOffset({ X = 0, Y = 1 })
    hint:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.85 })
    hint:SetVisibility(1)
    local slot = root:AddChildToOverlay(hint)
    assert(valid(slot), "无法显示铸魂切换提示")
    slot:SetHorizontalAlignment(3)
    slot:SetVerticalAlignment(3)
    slot:SetPadding({ Left = 0, Top = 0, Right = 72, Bottom = 104 })
end

local function weaponTab(widget)
    local tab = valid(widget.FirstTab) and name(widget.FirstTab:GetActiveTab())
    tab = tab and tab:lower()
    if tab == "weapon" or tab == "shachiweapon" then return tab end
end

local function itemId(value)
    local id = name(value)
    if id and id ~= "" and id:lower() ~= "none" then return id end
end

local function selection(widget, tab)
    local panel = widget.W_SystemPanel
    local group = valid(panel) and panel.ButtonGroup
    local button = valid(group) and group:GetSelectedButtonBase()
    if not valid(button) then return end
    -- Both HUD weapon buttons store the slot's ID in this reflected FName.
    local id = itemId(button.WeaponID)
    if not id then
        local result = {}
        local getter = button.GetItem or button["Get Item ID"]
        if getter then
            local called, returned = pcall(getter, button, result)
            if called then id = itemId(result.ItemID) or itemId(result["Item ID"]) or itemId(returned) end
        end
    end
    id = id or itemId(button.Item)
    if id then return id, tab == "weapon", group, button end
    return nil, nil, nil, button
end

local function refreshSelection(session, group, button, state, level)
    local logic = session.widget.UIGameplayLogicComponent
    if valid(logic) and logic.ReCheckItemUpgradeState then
        logic:ReCheckItemUpgradeState(session.backpack)
    end
    local index = group:GetSelectedButtonIndex()
    if index < 0 or index >= group:GetButtonCount() then return end
    local levelRefresh = button["Init Level"]
    if levelRefresh then levelRefresh(button, level, state) end
    group:DeselectAll()
    group:SelectButtonAtIndex(index, false)
end

local function inSoulPage(widget)
    local switcher = widget.WidgetSwitcher_64
    return widget.IsZhuHun == true and valid(switcher) and switcher:GetActiveWidgetIndex() ~= 1
        and weaponTab(widget) ~= nil
end

local function hasFocus(session, button)
    local widget, library = session.widget, session.library
    if valid(library) and library.GetUILayOut then
        local layout = library:GetUILayOut(widget)
        if valid(layout) and layout:HasModal() then return false end
    end
    return widget:HasUserFocus(session.controller) or widget:HasUserFocusedDescendants(session.controller)
        or (valid(library) and library.WidgetIsInFocusPath and library:WidgetIsInFocusPath(button))
end

local function keyDown(session, keys)
    for index, key in ipairs(keys) do
        if session.router:IsUIKeyHeld(key) then return index end
        if session.controller.IsInputKeyDown and session.controller:IsInputKeyDown(key) then
            return index
        end
    end
end

local function observePage(session, onSoulPage)
    local pressed = keyDown(session, session.pageKeys) ~= nil
    if onSoulPage ~= session.soulPage then
        report(onSoulPage and "已进入铸魂页" or "已退出铸魂页")
    elseif pressed and not session.pageKeyDown and not onSoulPage then
        local border = session.widget.ZhuHunVisibilityBorder
        local hidden = valid(border) and border:IsHiddenState()
        report(("铸魂页入口按键，分类=%s，原版入口隐藏=%s"):format(
            weaponTab(session.widget) or "非武器", tostring(hidden == true)))
    end
    session.pageKeyDown = pressed
end

local function installSoulGuard(session)
    required(SOUL_STATE)
    local pre, post = RegisterHook(SOUL_STATE, function(context, _, state)
        local widget = session.widget
        if current ~= session or not valid(widget) or not inSoulPage(widget)
            or not same(context:get(), widget.UIGameplayLogicComponent) then return end
        local ok, errorText = pcall(function()
            if state:get() == CAN_FORGE then state:set(BLOCKED) end
        end)
        session.soulGuardActive = ok
        if not ok then session.soulFailure = tostring(errorText) end
    end)
    assert(pre and post, "无法接管原版铸魂长按")
    session.soulGuard = { pre, post }
end

local function updateNativeSoulControls(session, hide)
    local description = session.widget.W_UnifiedTextDescription_Weapon
    if hide and valid(description) then
        local controls = { description.W_LongPressButton, description.W_Upgrade_NeedItemPanel }
        for _, control in ipairs(controls) do
            if valid(control) then
                local previous = control:GetVisibility()
                local address = control:GetAddress()
                session.hiddenControls[address] = session.hiddenControls[address] or { control, previous }
                if previous ~= 1 then control:SetVisibility(1) end
            end
        end
    elseif next(session.hiddenControls) then
        for _, entry in pairs(session.hiddenControls) do
            local control, original = table.unpack(entry)
            if valid(control) and control:GetVisibility() == 1 then control:SetVisibility(original) end
        end
        session.hiddenControls = {}
    end
end

function Menu.close()
    local session = current
    if not session then return end
    current = nil
    if session.soulGuard then pcall(UnregisterHook, SOUL_STATE, table.unpack(session.soulGuard)) end
    local logic = valid(session.widget) and session.widget.UIGameplayLogicComponent
    pcall(function()
        if valid(session.hint) then session.hint:RemoveFromParent() end
        if valid(session.widget) then updateNativeSoulControls(session, false) end
        if valid(session.widget) and same(session.widget:GetOwningPlayer(), session.controller)
            and session.widget:IsActivated() then session.widget:DeactivateWidget() end
    end)
    session.enhancement:close()
    if valid(logic) and valid(session.pawn) and valid(session.backpack) then
        pcall(logic.ReCheckItemUpgradeState, logic, session.backpack)
    end
end

function Menu.open(gameplay, pawn, bellWidget, cap)
    if current then return false, "装备调整已打开" end
    local ok, opened, reason = pcall(function()
        local controller = gameplay:GetPlayerController(pawn, 0)
        assert(valid(controller) and valid(bellWidget) and bellWidget:IsActivated()
            and same(bellWidget:GetOwningPlayer(), controller), "当前铃铛界面已关闭")
        local subsystems = required(SUBSYSTEMS)
        local backpack = subsystems:GetWorldSubsystem(pawn, required(BACKPACK))
        local router = subsystems:GetLocalPlayerSubsystem(bellWidget, required(ROUTER))
        assert(valid(backpack) and valid(router), "装备调整未找到背包或原版输入路由")
        local commonUI = required(COMMON_UI)
        local player = commonUI:GetLocalPlayerFromController(controller)
        assert(valid(player), "装备调整未找到本地玩家")
        for _, widget in ipairs(FindAllOf("W_UpgradeActivatableWidget_V1_C") or {}) do
            if valid(widget) and same(widget:GetOwningPlayer(), controller) and widget:IsActivated() then
                return false, "请先关闭已经打开的装备强化界面"
            end
        end
        local class = CombatSpawn.class(WIDGET)
        local inputClass = StaticFindObject(COMMON_INPUT)
        local session = {
            gameplay = gameplay, pawn = pawn, controller = controller, backpack = backpack, router = router,
            input = valid(inputClass) and subsystems:GetLocalPlayerSubsystem(bellWidget, inputClass),
            hiddenControls = {}, library = StaticFindObject(LIBRARY), soulPage = false,
            keys = { { KeyName = FName("SpaceBar") }, { KeyName = FName("Gamepad_FaceButton_Bottom") } },
            pageKeys = { { KeyName = FName("P") }, { KeyName = FName("Gamepad_FaceButton_Left") } },
        }
        local enhancement, failure = Enhancement.prepare(pawn, cap)
        if not enhancement then return false, failure end
        session.enhancement = enhancement
        current = session
        -- The bell's PushWeaponUpgrade uses this CommonUI layer and the same class.
        -- Its class default is already Weapon. The synchronous push identifies the
        -- exact pooled instance so the overrides never attach to a different menu.
        local widget = commonUI:PushContentToLayer_ForPlayer(player, { TagName = FName("UI.Layer.Menu") }, class)
        session.widget = widget
        assert(valid(widget) and same(widget:GetOwningPlayer(), controller), "无法打开原版装备强化界面")
        local attached, attachFailure = enhancement:attach(widget)
        assert(attached, attachFailure)
        installSoulGuard(session)
        addHint(session)
        return true
    end)
    if ok and opened then return true end
    Menu.close()
    return false, ok and reason or opened
end

local function updateSession(session)
    local widget = session.widget
    if not widget:IsActivated() then return false end
    if session.enhancement.failure then return false, session.enhancement.failure end
    if session.soulFailure then return false, "原版铸魂操作接管失败：" .. session.soulFailure end
    local soulPage = inSoulPage(widget) == true
    observePage(session, soulPage)
    local id, isMain, group, button
    if soulPage then id, isMain, group, button = selection(widget, weaponTab(widget)) end
    local address = valid(button) and button:GetAddress() or nil
    local changed = session.id ~= id or session.isMain ~= isMain or session.buttonAddress ~= address
        or session.soulPage ~= soulPage
    if changed then
        session.id, session.isMain, session.buttonAddress = id, isMain, address
        session.soulPage = soulPage
        session.holdAt, session.heldKey, session.armed, session.feedback = nil, nil, false, nil
        session.lastEligibility, session.lastBlocked = nil, nil
        if soulPage then
            report(id and ("已选武器 " .. id) or (address and "未读到武器编号" or "尚未选中武器"))
        end
    end
    updateNativeSoulControls(session, soulPage)
    if not id then
        setHint(session, soulPage and (address and "暂时无法读取所选武器" or "请选择武器") or nil)
        return true
    end
    if not session.soulGuardActive then
        local logic = widget.UIGameplayLogicComponent
        local state = {}
        logic:GetItemUpgradeState(FName(id), state)
        if not session.soulGuardActive or type(state.ItemUpgradeState) ~= "number" or state.ItemUpgradeState == CAN_FORGE then
            return false, "未能接管此界面的原版铸魂操作"
        end
    end
    local state, reason, level = Soul.status(session.backpack, id, isMain)
    local key = hintKey(session)
    local action = state == nil and (reason or "此武器无法切换铸魂")
        or ("长按 %s  %s铸魂"):format(key, state and "关闭" or "开启")
    local eligibility = state == nil and action or "可切换"
    if session.lastEligibility ~= eligibility then
        session.lastEligibility = eligibility
        report(("铸魂状态 %s：%s"):format(id, eligibility))
    end
    local focused = hasFocus(session, button)
    local down = keyDown(session, session.keys)
    if not focused or state == nil then
        session.holdAt, session.heldKey, session.armed = nil, nil, false
        local blocked = down and (state == nil and action or "武器页未取得输入焦点")
        if blocked and blocked ~= session.lastBlocked then report("忽略铸魂长按：" .. blocked) end
        session.lastBlocked = blocked
        setHint(session, action)
        return true
    end
    local now = session.gameplay:GetRealTimeSeconds(session.pawn)
    if not down then
        session.holdAt, session.heldKey, session.armed = nil, nil, true
        session.lastBlocked = nil
    elseif session.armed then
        if session.heldKey and session.heldKey ~= down then
            session.holdAt, session.heldKey, session.armed = nil, nil, false
        elseif not session.holdAt then
            session.holdAt, session.heldKey = now, down
            report("开始铸魂长按：" .. id)
        elseif now - session.holdAt >= HOLD_SECONDS then
            session.holdAt, session.heldKey, session.armed = nil, nil, false
            local toggled, result = Soul.toggle(session.backpack, id, isMain, session.pawn)
            if toggled then
                session.feedback = result and "已开启铸魂" or "已关闭铸魂"
                refreshSelection(session, group, button, result, level)
            else
                session.feedback = tostring(result or "铸魂切换失败")
            end
            session.feedbackUntil = now + 2
            report(("%s：%s"):format(id, session.feedback))
        end
    end
    if session.feedback and now >= session.feedbackUntil then session.feedback = nil end
    setHint(session, session.feedback or action)
    return true
end

function Menu.update(pawn)
    local session = current
    if not session then return false end
    if not same(pawn, session.pawn) or not valid(session.widget)
        or not same(session.widget:GetOwningPlayer(), session.controller) then
        Menu.close()
        return false
    end
    local ok, active, failure = pcall(updateSession, session)
    if ok and active then return true end
    Menu.close()
    return false, ok and failure or active
end

return Menu
