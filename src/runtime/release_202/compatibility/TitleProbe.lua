-- A native title entry for the isolated test profile. The caller owns save loading.
local TitleProbe = {}

local TITLE_CLASS = "WB_StartMenu_V2_C"
local TITLE_LEVEL = "PBZ_StartMenu_CE_WP"
local WIDGETS = "/Script/UMG.Default__WidgetBlueprintLibrary"
local LIBRARY = "/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary"
local PULSE_CLASS = "/Script/UMG.TextBlock"
local PULSE = "ForceLayoutPrepass"
local CLICK = "/Script/UMG.Widget:" .. PULSE
local COLLAPSED, NAV_UP, NAV_DOWN = 1, 2, 3
local ENTRY_TEXT = "影境演武"

local current, lastFailure
local noticeRequest
local ordinaryGuards = {}

local function unwrap(object)
    if object and type(object.IsValid) ~= "function" then
        local getter = object.get or object.Get
        if type(getter) == "function" then return getter(object) end
    end
    return object
end

local function valid(object)
    return object ~= nil and type(object.IsValid) == "function" and object:IsValid()
end

local function same(first, second)
    first, second = unwrap(first), unwrap(second)
    return valid(first) and valid(second) and first:GetAddress() == second:GetAddress()
end

local function checked(object, message)
    object = unwrap(object)
    assert(valid(object), message)
    return object
end

local function name(value)
    if type(value) == "string" then return value end
    return value and value:ToString() or ""
end

local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "缺少原版标题菜单接口：" .. path)
    return object
end

local function activeTitle(gameplay)
    for _, menu in ipairs(FindAllOf(TITLE_CLASS) or {}) do
        if valid(menu) and menu:IsActivated() and name(gameplay:GetCurrentLevelName(menu, true)) == TITLE_LEVEL then
            local controller, group = menu:GetOwningPlayer(), menu.ButtonGroup
            if valid(controller) and valid(group) then return menu, controller, group end
        end
    end
end

local function blocked(session)
    local layout = session.library:GetUILayOut(session.menu)
    return valid(layout) and (layout:HasModal()
        or layout:HasWidgetAboveLayer({ TagName = FName("UI.Layer.Menu") }, true))
end

local function contains(group, button)
    for index = 0, group:GetButtonCount() - 1 do
        if same(group:GetButtonBaseAtIndex(index), button) then return true end
    end
    return false
end

local function guardLive(object)
    return valid(object) and not object:HasAnyFlags(0x08023630)
end
local function guardIdentity(record)
    local menu, button, owner = record.menu, record.button, record.owner
    if not guardLive(menu) or not guardLive(button) or not guardLive(owner)
        or not same(menu:GetOwningPlayer(), owner) or not same(button:GetOwningPlayer(), owner)
        or not same(unwrap(menu[record.field]), button)
        or menu:GetFullName() ~= record.menuName or button:GetFullName() ~= record.buttonName
        or not same(button:GetClass(), record.class) then return false end
    local world = menu:GetWorld()
    return valid(world) and world:GetAddress() == record.world
end

function TitleProbe.setOrdinaryLoadGuard(gameplay, enabled)
    if not enabled then
        if #ordinaryGuards == 0 then return true end
        local remaining = {}
        for _, record in ipairs(ordinaryGuards) do
            local ok = pcall(function()
                if guardIdentity(record) then record.button:SetIsEnabled(record.enabled) end
            end)
            if not ok then remaining[#remaining + 1] = record end
        end
        ordinaryGuards = remaining
        return #remaining == 0
    end
    local menu, owner, group = activeTitle(gameplay)
    if not menu then return false end -- original menu is not mounted yet
    if not guardLive(menu) or not guardLive(owner) then return false end
    local world = checked(menu:GetWorld(), "原标题菜单运行世界尚未就绪")
    for _, field in ipairs({ "ContinueGame", "NewGame", "LoadGame" }) do
        local button = checked(menu[field], "原标题菜单缺少加载选项：" .. field)
        assert(guardLive(button), "原标题加载选项尚未就绪")
        assert(contains(group, button) and same(button:GetOwningPlayer(), owner), "原标题加载选项不属于本地菜单")
        local record
        for _, previous in ipairs(ordinaryGuards) do
            if same(previous.button, button) and guardIdentity(previous) then record = previous; break end
        end
        if not record then
            local state = button:GetIsEnabled()
            assert(type(state) == "boolean", "原标题加载选项启用状态无效")
            record = { menu = menu, button = button, owner = owner, field = field,
                menuName = menu:GetFullName(), buttonName = button:GetFullName(),
                class = checked(button:GetClass(), "原标题加载选项类型无效"), world = world:GetAddress(), enabled = state }
            -- Keep the original state even if a setter mutates then throws.
            ordinaryGuards[#ordinaryGuards + 1] = record
        end
        if button:GetIsEnabled() then button:SetIsEnabled(false) end
    end
    return true, menu
end

local function slotState(widget)
    local slot = checked(widget.Slot, "原标题菜单选项没有插槽")
    local padding, size = slot.Padding, slot.Size
    return { widget = widget, horizontal = slot.HorizontalAlignment, vertical = slot.VerticalAlignment,
        padding = { Left = padding.Left, Top = padding.Top, Right = padding.Right, Bottom = padding.Bottom },
        size = { SizeRule = size.SizeRule, Value = size.Value } }
end

local function restoreSlot(slot, state)
    slot:SetPadding(state.padding)
    slot:SetHorizontalAlignment(state.horizontal)
    slot:SetVerticalAlignment(state.vertical)
    slot:SetSize(state.size)
end

local function mountAfterLoadGame(session, parent, anchor)
    -- VerticalBox has no reflected InsertChildAt. Reappend only the following
    -- native containers, retaining their widget identities, delegates and full
    -- VerticalBoxSlot settings. This is not a DynamicEntryBox/pool operation.
    assert(name(parent:GetClass():GetFName()) == "VerticalBox", "原标题菜单列表不是原生 VerticalBox")
    local found, tail = false, {}
    for index = 0, parent:GetChildrenCount() - 1 do
        local child = checked(parent:GetChildAt(index), "原标题菜单选项尚未就绪")
        if same(child, anchor) then found = true
        elseif found then tail[#tail + 1] = slotState(child) end
    end
    assert(found, "载入游戏不在原标题菜单列表中")
    local ok, failure = pcall(function()
        for index = #tail, 1, -1 do assert(parent:RemoveChild(tail[index].widget), "无法排列原标题菜单") end
        local slot = checked(parent:AddChildToVerticalBox(session.button), "无法挂载原生影境演武入口")
        slot:SetPadding({ Left = 0, Top = 2, Right = 0, Bottom = 0 })
        for _, item in ipairs(tail) do
            restoreSlot(checked(parent:AddChildToVerticalBox(item.widget), "无法恢复原标题菜单选项"), item)
        end
    end)
    if not ok then
        -- Roll back before exposing a partial title menu. All tail references
        -- were captured before mutation and stay alive in this local table.
        if same(session.button:GetParent(), parent) then parent:RemoveChild(session.button) end
        for _, item in ipairs(tail) do
            if same(item.widget:GetParent(), parent) then parent:RemoveChild(item.widget) end
        end
        for _, item in ipairs(tail) do
            restoreSlot(checked(parent:AddChildToVerticalBox(item.widget), "原标题菜单排列回滚失败"), item)
        end
        error(failure, 0)
    end
end

local function mountGroup(session, group)
    if same(session.group, group) and contains(group, session.button) then return end
    if valid(session.group) and contains(session.group, session.button) then
        session.group:RemoveWidget(session.button)
    end
    session.group = group
    if contains(group, session.button) then group:RemoveWidget(session.button) end
    local anchor, tail, original = nil, {}, {}
    for index = 0, group:GetButtonCount() - 1 do
        local candidate = checked(group:GetButtonBaseAtIndex(index), "原标题按钮组尚未就绪")
        original[#original + 1] = candidate
        if same(candidate, session.menu.LoadGame) then anchor = #original
        elseif anchor then tail[#tail + 1] = candidate end
    end
    assert(anchor, "原标题按钮组没有载入游戏")
    local selected = unwrap(group:GetSelectedButtonBase())
    local reordered, failure = pcall(function()
        for index = #tail, 1, -1 do group:RemoveWidget(tail[index]) end
        group:AddWidget(session.button)
        for _, button in ipairs(tail) do group:AddWidget(button) end
    end)
    if not reordered then
        if contains(group, session.button) then group:RemoveWidget(session.button) end
        for _, button in ipairs(tail) do if contains(group, button) then group:RemoveWidget(button) end end
        for _, button in ipairs(tail) do group:AddWidget(button) end
        error(failure, 0)
    end
    -- Retain the group's own selected/hovered/click delegates. StartMenu.js
    -- already plays the authored highlight, font decorator and breathe loop
    -- for every member, including this same-class native entry.
    local click = session.button.OnButtonBaseClicked
    local bound = false
    for _, binding in ipairs(click:GetBindings()) do
        if same(binding.Object, session.pulse) and name(binding.FunctionName) == PULSE then bound = true end
    end
    if not bound then click:Add(session.pulse, FName(PULSE)) end
    if valid(selected) then
        for index = 0, group:GetButtonCount() - 1 do
            if same(group:GetButtonBaseAtIndex(index), selected) then group:SelectButtonAtIndex(index, false); break end
        end
    end
    local position = anchor -- zero-based index of our entry after insertion.
    local count = group:GetButtonCount()
    for _, direction in ipairs({ { NAV_UP, -1 }, { NAV_DOWN, 1 } }) do
        for offset = 1, count - 1 do
            local candidate = unwrap(group:GetButtonBaseAtIndex((position + offset * direction[2]) % count))
            if valid(candidate) and session.library:CanFocusToWidget(candidate) then
                session.button:SetNavigationRuleExplicit(direction[1], candidate); break
            end
        end
    end
end

function TitleProbe.close()
    local session = current
    if not session then return end
    current = nil
    if session.hook then pcall(UnregisterHook, CLICK, table.unpack(session.hook)) end
    if valid(session.button) then
        pcall(function()
            if valid(session.group) and contains(session.group, session.button) then
                session.group:RemoveWidget(session.button)
            end
        end)
        pcall(function() session.button.OnButtonBaseClicked:Clear() end)
        pcall(function() session.button:RemoveFromParent() end)
    end
    if valid(session.pulse) then pcall(function() session.pulse:RemoveFromParent() end) end
end

function TitleProbe.showError(menu, message)
    local request = required("/Script/CommonGame.Default__AsyncAction_ShowConfirmation")
        :ShowConfirmationOk(menu, FText("MOD 未能启动"), FText(message))
    assert(valid(request), "无法打开原版 MOD 错误提示")
    noticeRequest = request
    request:Activate()
end

function TitleProbe.resume()
    if current then current.starting = false end
end

local function attach(session, group)
    local menu = session.menu
    local template = unwrap(menu.LoadGame)
    assert(valid(template), "找不到原版标题菜单按钮")
    local parent = checked(menu.NewGame, "找不到原标题菜单新游戏按钮"):GetParent()
    assert(valid(parent), "找不到原版标题菜单列表")
    local anchor = template
    for _ = 1, 8 do
        if same(anchor:GetParent(), parent) then break end
        anchor = checked(anchor:GetParent(), "找不到载入游戏的原生容器")
    end
    assert(same(anchor:GetParent(), parent), "载入游戏不在原标题菜单容器中")
    session.library = required(LIBRARY)
    local button = required(WIDGETS):Create(menu, template:GetClass(), session.controller)
    assert(valid(button), "无法创建原生 MOD 入口")
    session.button = button
    -- These are per-instance overrides on all stock StartMenu entries, not
    -- defaults of W_MenuButton_V2_SelectedVersion_C. Without the first flag,
    -- selection never switches to the original enlarged/gold title decorator.
    button.ChangeTextDecoratorOnSelected = template.ChangeTextDecoratorOnSelected
    button.SelectedOpacity, button.UnselectedOpacity = template.SelectedOpacity, template.UnselectedOpacity
    button.bOverride_ButtonText = true
    button.ButtonText = FText(ENTRY_TEXT)
    button:SetButtonText(FText(ENTRY_TEXT))
    button:SetMinDimensions(template.MinWidth, template.MinHeight)
    button:SetIsFocusable(true)
    button:SetIsSelectable(true)
    mountAfterLoadGame(session, parent, anchor)

    local pulse = StaticConstructObject(required(PULSE_CLASS), parent)
    assert(valid(pulse), "无法创建标题 MOD 回调")
    session.pulse = pulse
    pulse:SetVisibility(COLLAPSED)
    assert(valid(parent:AddChildToVerticalBox(pulse)), "无法挂载标题 MOD 回调")
    local pre, post = RegisterHook(CLICK, function(context)
        if current == session and not session.starting and same(context:get(), session.pulse) then
            session.pending = true
        end
    end)
    session.hook = { pre, post }
    mountGroup(session, group)
    print("[PBZTestArenaNative] Native title entry attached after LoadGame; label=" .. ENTRY_TEXT .. "\n")
end

function TitleProbe.update(gameplay, onStart)
    local menu, controller, group = activeTitle(gameplay)
    if not valid(menu) then
        -- Settings and native popups can temporarily deactivate this same title widget.
        if current and not valid(current.menu) then TitleProbe.close() end
        if current then current.pending = false end
        return false
    end
    if current and not same(menu, current.menu) then TitleProbe.close() end
    local ok, failure = pcall(function()
        if not current then
            local session = { menu = menu, controller = controller }
            current = session
            attach(session, group)
        else
            mountGroup(current, group)
        end
        local session = current
        if not session.pending then return end
        session.pending = false
        if blocked(session) then return end
        session.starting = true
        local called, accepted = pcall(onStart, session.menu, session.controller)
        if not called or accepted == false then session.starting = false end
        if not called then print("[PBZTestArenaNative] Native title MOD selection: " .. tostring(accepted) .. "\n") end
    end)
    if not ok then
        pcall(TitleProbe.close)
        if failure ~= lastFailure then print("[PBZTestArenaNative] Native title MOD probe: " .. tostring(failure) .. "\n") end
        lastFailure = failure
        return false
    end
    lastFailure = nil
    return true
end

return TitleProbe
