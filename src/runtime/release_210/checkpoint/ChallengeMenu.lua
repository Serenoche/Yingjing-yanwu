local ChallengeMenu = {}
local HistoryReport = require("HistoryReport")

local BELL_ID = "BrokenBell_TheEnd01"
local BELL_WIDGET = "/Game/PBZContent/UI/InGame/Bell/W_BellMenu.W_BellMenu_C"
local BELL_ACTIVATED = BELL_WIDGET .. ":BP_OnActivated"
local BELL_TITLE_STYLE = "/Game/PBZContent/UI/UINew/System/Character/Textstyle_H1_CN.Textstyle_H1_CN_C"
local CLICK = "/Script/UMG.Widget:ForceLayoutPrepass"
local WIDGET_LIBRARY = "/Script/UMG.Default__WidgetBlueprintLibrary"
local PULSE_CLASS = "/Script/UMG.TextBlock"
local SUBSYSTEMS = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local ROUTER = "/Script/ProjectPBZ.PBZUIActionRouterBase"
local BACK_KEYS = { "Gamepad_FaceButton_Right", "Escape" }
local BUTTONS = {
    "TeleportBtn_BrokenBell", "TeleportBtn", "ItemUpgradeButton", "ShopButton",
    "AbilityCultivation", "ManualSave", "JhsyButton", "CloseBtn",
}
local VISIBLE, COLLAPSED = 0, 1
local PAGE_SIZE = 5
local current, dreamAdmission, unrecognizedOwner
local rejectedOwners = {}

local function valid(object)
    return object ~= nil and type(object.IsValid) == "function" and object:IsValid()
end

local function resolveObject(object)
    -- UE4SS exposes BellInteractWidget.OwnerBell as an FWeakObjectPtr.
    if object and type(object.IsValid) ~= "function" and type(object.Get) == "function" then
        return object:Get()
    end
    return object
end

local function same(first, second)
    return valid(first) and valid(second) and first:GetAddress() == second:GetAddress()
end

local function ownsWidget(session)
    local widget = session.widget
    return valid(widget) and (not session.bellOwner
        or same(resolveObject(widget.OwnerBell), session.bellOwner)
            and same(resolveObject(widget:GetOwningPlayer()), session.controller))
end

local function name(value)
    if type(value) == "string" then return value end
    return value and value:ToString() or ""
end

local function row(label, action)
    return { label = label, action = action }
end

local function pages(title, items, choose, show, back, initial)
    local function render(index)
        local count = math.max(1, math.ceil(#items / PAGE_SIZE))
        local rows, first = {}, (index - 1) * PAGE_SIZE + 1
        for position = first, math.min(first + PAGE_SIZE - 1, #items) do
            local item = items[position]
            rows[#rows + 1] = row(item.label, function() choose(item, index) end)
        end
        rows[#rows + 1] = row("上一页", index > 1 and function() render(index - 1) end or nil)
        rows[#rows + 1] = row("下一页", index < count and function() render(index + 1) end or nil)
        rows[#rows + 1] = row("返回", back)
        show(("%s  %d/%d"):format(title, index, count), rows, nil, back)
    end
    render(initial or 1)
end

local function history(records, show, back, openReport)
    if not records or #records == 0 then
        show("挑战记录", { row("暂无记录"), row("返回", back) }, nil, back)
        return
    end
    local items, latest = {}, 1
    for index, record in ipairs(records) do
        local outcome = record.attemptResult == "failure" and "失败" or record.attemptResult == "success" and "胜利" or "结果未记录"
        local target = record.bossName or record.bossId or "未知首领"
        items[index] = { label = outcome .. "　" .. target, target = target, outcome = outcome, record = record }
    end
    local function render()
        pages("挑战记录", items, function(item, page)
            latest = page
            openReport(item.record, render)
        end, show, back, latest)
    end
    render()
end

local function localOwner(gameplay, controller, bell)
    -- A streamed WP actor can report its source package UWorld. The engine's
    -- ULevel.OwningWorld is its current runtime world, unlike the package Outer.
    -- The pinned actor binding exposes GetLevel; OwningWorld is a reflected
    -- ULevel field. If it is unavailable, use the controller-context query.
    local read, actorWorld, controllerWorld = pcall(function()
        return resolveObject(bell:GetLevel().OwningWorld), resolveObject(controller:GetLevel().OwningWorld)
    end)
    if read and valid(actorWorld) and valid(controllerWorld) then return same(actorWorld, controllerWorld) end
    local ok, found = pcall(function()
        local class = bell:GetClass()
        if not valid(class) then return false end
        local actors = {}
        gameplay:GetAllActorsOfClass(controller, class, actors)
        for index = 1, #actors do
            if same(resolveObject(actors[index]), bell) then return true end
        end
        return false
    end)
    return ok and found == true
end

local function usesDreamBell(state)
    return state.mode == "bloody-palace" and state.bellName ~= nil
end

local function matchesBell(gameplay, widget, controller, state)
    if not valid(widget) or not same(resolveObject(widget:GetOwningPlayer()), controller) then return false end
    local bell = resolveObject(widget.OwnerBell)
    if not valid(bell) then return false end
    local actual, expected = name(bell.BellID), state.bellId or BELL_ID
    if (state.requireBellOwner or usesDreamBell(state)) and not same(bell, state.bellOwner) then return false end
    local localActor = actual == expected and localOwner(gameplay, controller, bell)
    if localActor then return true end
    local key = tostring(widget:GetAddress()) .. ":" .. expected
    if not rejectedOwners[key] then
        rejectedOwners[key] = true
        print("[PBZTestArenaNative] Native challenge bell owner rejected: expected=" .. expected
            .. "; actual=" .. actual .. "; nativeWorldMember=" .. tostring(localActor) .. "\n")
    end
    return false
end

local function ownedBellMenu(gameplay, controller, state)
    local widgets
    if state.runtimeModule then
        widgets = require(state.runtimeModule).findBellWidgets("W_BellMenu_C", gameplay:GetRealTimeSeconds(controller))
    else
        widgets = FindAllOf("W_BellMenu_C")
    end
    for _, widget in ipairs(widgets or {}) do
        if valid(widget) and widget:IsActivated() and same(resolveObject(widget:GetOwningPlayer()), controller) then
            local bell = resolveObject(widget.OwnerBell)
            if valid(bell) then
                if matchesBell(gameplay, widget, controller, state) then return widget end
            elseif unrecognizedOwner ~= widget:GetAddress() then
                unrecognizedOwner = widget:GetAddress()
                print("[PBZTestArenaNative] Native bell menu missing owner actor\n")
            end
        end
    end
end

local function rememberVisibility(session, widget)
    local address = widget:GetAddress()
    if session.visibility[address] then return end
    session.visibility[address] = { widget = widget, visibility = widget:GetVisibility() }
end

local function rowContainer(button, main)
    local child, parent = button, button:GetParent()
    while valid(parent) and not same(parent, main) do
        child, parent = parent, parent:GetParent()
    end
    return same(parent, main) and child or button
end

local function setContent(binding, content)
    local slot = binding.parent:SetContent(content)
    assert(valid(slot) and same(binding.parent:GetContent(), content), "无法挂载演武铃铛控件")
    -- Both authored slots are left aligned. The list also aligns to the top.
    slot:SetHorizontalAlignment(1)
    if binding.alignTop then slot:SetVerticalAlignment(1) end
end

local function replaceContent(session, original, replacement, alignTop)
    local parent = original:GetParent()
    assert(valid(parent) and same(parent:GetContent(), original), "演武铃铛缺少独立控件插槽")
    local binding = { parent = parent, original = original, replacement = replacement, alignTop = alignTop }
    session.contents[#session.contents + 1] = binding
    setContent(binding, replacement)
end

local function mountBellTitle(session)
    local widget = session.widget
    local originalTitle = widget.CurrentBellNameText
    local titleClass = StaticFindObject("/Script/CommonUI.CommonTextBlock")
    assert(valid(widget.WidgetTree) and valid(originalTitle) and valid(titleClass), "演武铃铛缺少标题接口")
    local title = StaticConstructObject(titleClass, widget.WidgetTree)
    assert(valid(title), "无法创建演武铃铛标题")
    local style = originalTitle.Style
    if not valid(style) then style = StaticFindObject(BELL_TITLE_STYLE) end
    assert(valid(style), "原版铃铛标题样式不可用")
    title:SetStyle(style)
    title:SetText(FText(session.state.bellName))
    title:SetVisibility(3)
    session.caption = title
    -- Stock activation localizes CurrentBellNameText from the bell ID.
    -- Keep that reference for the game and show the arena title in its slot.
    replaceContent(session, originalTitle, title)
end

local function mountDreamList(session, stockList)
    local listClass = StaticFindObject("/Script/UMG.VerticalBox")
    assert(valid(listClass), "浊梦铃铛缺少列表接口")
    local list = StaticConstructObject(listClass, session.widget.WidgetTree)
    assert(valid(list), "无法创建浊梦铃铛列表")
    list:SetVisibility(4)
    replaceContent(session, stockList, list, true)
    return list
end

local function keepBellContents(session)
    for _, binding in ipairs(session.contents) do
        local displayed = binding.parent:GetContent()
        if same(displayed, binding.original) then
            setContent(binding, binding.replacement)
        else
            assert(same(displayed, binding.replacement), "演武铃铛控件插槽已被其他界面接管")
        end
    end
end

local function setHeader(session, title, detail)
    local widget = session.widget
    local caption = session.caption or widget.CurrentBellNameText
    if valid(caption) then caption:SetText(FText(title)) end
    if valid(widget.Text) then
        widget.Text:SetText(FText(detail or ""))
        widget.Text:SetVisibility(detail and detail ~= "" and 4 or COLLAPSED)
    end
end

local function renderBell(session, title, rows, detail, preferredFocus)
    local focused
    local old = preferredFocus or session.group:GetSelectedButtonBase()
    local actions = {}
    assert(#rows > 0 and #rows <= #session.buttons, "挑战菜单选项数量无效")
    session.group:RemoveAll()
    for index, button in ipairs(session.buttons) do
        local item = rows[index]
        button:SetVisibility(item and VISIBLE or COLLAPSED)
        if item then
            button:SetWidgetText({ ChoiceText = FText(item.label), ChoiceIndex = index - 1, Last = false })
            button:SetRenderOpacity(1)
            button:SetIsEnabled(item.action ~= nil)
            if item.action then
                session.group:AddWidget(button)
                -- Keep CommonUI focus and navigation. Route confirmation only to
                -- this row's private delegate target, outside the stock bell click chain.
                local pulse = session.pulses[index]
                local click = button.OnButtonBaseClicked
                click:Clear()
                click:Add(pulse, FName("ForceLayoutPrepass"))
                actions[pulse:GetAddress()] = item
                if not focused or same(button, old) then focused = button end
            end
        end
    end
    session.actions = actions
    session.page = { title = title, rows = rows, detail = detail }
    setHeader(session, title, detail)
    if valid(focused) then focused:SetFocus() end
end

local function disconnect(session)
    local restore = ownsWidget(session)
    if session.reportChild then
        session.reportChild = nil
        pcall(require("ChallengeVictory").close)
    end
    if session.historyBackBound and restore then
        session.widget:ClearBackKey()
        if session.widget:IsActivated() then session.widget:BindBackKey() end
    end
    if session.reportVisibility ~= nil and restore then session.widget:SetVisibility(session.reportVisibility) end
    if session.clickHook then pcall(UnregisterHook, CLICK, table.unpack(session.clickHook)) end
    if restore and session.controlsChanged and valid(session.group) then
        session.group:RemoveAll()
        for _, button in ipairs(session.stock) do
            if valid(button) then session.group:AddWidget(button) end
        end
    end
    for _, button in ipairs(session.buttons) do
        if valid(button) then button:RemoveFromParent() end
    end
    for _, pulse in ipairs(session.pulses) do
        if valid(pulse) then pulse:RemoveFromParent() end
    end
    for _, binding in ipairs(session.contents) do
        if valid(binding.parent) and same(binding.parent:GetContent(), binding.replacement) then
            if valid(binding.original) then setContent(binding, binding.original)
            else binding.replacement:RemoveFromParent() end
        end
    end
    if restore then
        for _, original in pairs(session.visibility) do
            if valid(original.widget) then
                original.widget:SetVisibility(original.visibility)
                if original.enabled ~= nil then original.widget:SetIsEnabled(original.enabled) end
            end
        end
        local title, details = session.widget.CurrentBellNameText, session.widget.Text
        if session.title and valid(title) then title:SetText(session.title) end
        if session.details and valid(details) then details:SetText(session.details) end
    end
end

local function unwatchDreamActivation(admission)
    local hook = admission.hook
    admission.hook = nil
    if hook then pcall(UnregisterHook, BELL_ACTIVATED, table.unpack(hook)) end
end

function ChallengeMenu.close()
    local admission = dreamAdmission
    dreamAdmission = nil
    if admission then unwatchDreamActivation(admission) end
    local session = current
    if not session then return end
    current = nil
    -- Closing a modal can reactivate the underlying menu. Close that child
    -- first, then release the bell, so a world/owner exit cannot reopen it.
    if session.reportChild then session.reportChild = nil; pcall(require("ChallengeVictory").close) end
    if session.equipment then pcall(session.equipment.close) end
    if ownsWidget(session) and session.widget:IsActivated() then session.widget:DeactivateWidget() end
    local ok, failure = pcall(disconnect, session)
    if not ok then print("[PBZTestArenaNative] Challenge bell cleanup: " .. tostring(failure) .. "\n") end
end

function ChallengeMenu.suspend()
    local session = current
    if not session or not ownsWidget(session) or not session.widget:IsActivated() then return false end
    session.suspended, session.pending = true, nil
    session.returnFocus = session.group:GetSelectedButtonBase()
    return true
end

function ChallengeMenu.active()
    return current ~= nil
end

function ChallengeMenu.resume(realNow)
    if current and current.suspended then current.resumeDeadline = realNow + 2 end
end

local function openEquipment(session)
    local equipment = require("ArenaEquipmentMenu")
    local state = session.state
    local cap = require("PlayerCustom").weaponCap(state.playerCycle, state.customPlayer)
    if not ChallengeMenu.suspend() then return end
    local ok, opened, reason = pcall(equipment.open, session.gameplay, session.pawn, session.widget, cap)
    if ok and opened == true then
        session.equipment = equipment
        print(("[PBZArenaEquipment] 已打开原版武器强化页，上限 Lv.%d\n"):format(cap))
        return
    end
    pcall(equipment.close)
    ChallengeMenu.resume(session.gameplay:GetRealTimeSeconds(session.pawn))
    print("[PBZArenaEquipment] 打开装备调整失败：" .. tostring(ok and reason or opened) .. "\n")
end

local function updateEquipment(session)
    if not session.equipment then return false end
    local ok, active, reason = pcall(session.equipment.update, session.pawn)
    if ok and active == true then return true end
    pcall(session.equipment.close)
    session.equipment = nil
    ChallengeMenu.resume(session.gameplay:GetRealTimeSeconds(session.pawn))
    if not ok or reason then print("[PBZArenaEquipment] 装备调整：" .. tostring(ok and reason or active) .. "\n") end
    return false
end

local function hideStock(session)
    for _, original in pairs(session.visibility) do
        local widget = original.widget
        if original.hide and valid(widget) then
            if widget:GetVisibility() ~= COLLAPSED then widget:SetVisibility(COLLAPSED) end
            if original.enabled ~= nil and widget:GetIsEnabled() then widget:SetIsEnabled(false) end
        end
    end
end

local function setPageBack(session, back)
    if back and not session.historyBackBound then
        local subsystem, class = StaticFindObject(SUBSYSTEMS), StaticFindObject(ROUTER)
        assert(valid(subsystem) and valid(class), "历史列表缺少原生返回输入接口")
        session.router = subsystem:GetLocalPlayerSubsystem(session.widget, class)
        assert(valid(session.router), "历史列表缺少原生 UI 输入路由")
        -- These are the original game's own dynamic Back binding controls
        -- (PersonnelList.js refreshPageInput and Literature.js audio page).
        session.widget:ClearBackKey()
        session.historyBackBound, session.backReady = true, false
    elseif not back and session.historyBackBound then
        session.widget:ClearBackKey(); session.widget:BindBackKey()
        session.historyBackBound, session.backReady = nil, nil
    end
    session.pageBack = back
end

local function openHistory(session, record, restoreList)
    assert(current == session and ChallengeMenu.suspend(), "挑战记录所属铃铛已关闭")
    local report, metadata = HistoryReport.resolve(session.state.profilePath, record)
    local child = { restoreList = restoreList }
    session.reportChild = child
    session.reportVisibility = session.widget:GetVisibility()
    session.widget:SetVisibility(COLLAPSED)
    local ok, failure = pcall(function()
        assert(require("ChallengeVictory").openReport(session.gameplay, session.pawn, report, function()
            -- The child closes its native modal before this callback. Resume on
            -- our next update, never from inside an engine delegate callback.
            if current == session and session.reportChild == child then
                -- CommonUI may have just reactivated the parent and rebound
                -- its default whole-bell Back action. Remove it immediately;
                -- the remaining return gesture must stay inside history.
                if valid(session.widget) then session.widget:ClearBackKey() end
                child.returned = true
            end
        end, session.state.profilePath), "无法打开历史战报")
    end)
    if not ok then
        pcall(require("ChallengeVictory").close)
        child.returned = true
        print("[PBZTestArenaNative] History report open: " .. tostring(failure) .. "\n")
    else
        print("[PBZTestArenaNative] History report opened: source=" .. metadata.source
            .. "; complete=" .. tostring(metadata.complete) .. "; file=" .. tostring(record.reportFile or "memory") .. "\n")
    end
end

local function updateHistory(session)
    local child = session.reportChild
    if not child then return false end
    if not child.returned then
        local ok, active = pcall(require("ChallengeVictory").update, session.gameplay)
        if not ok or active == false then
            pcall(require("ChallengeVictory").close)
            child.returned = true
            if not ok then print("[PBZTestArenaNative] History report update: " .. tostring(active) .. "\n") end
        end
    end
    if child.returned then
        session.reportChild = nil
        session.widget:ClearBackKey()
        if session.reportVisibility ~= nil then session.widget:SetVisibility(session.reportVisibility); session.reportVisibility = nil end
        -- Keep the selected history row and its exact page. Regenerating its
        -- rows does not return to the root bell menu or dispatch a battle action.
        local focus = session.returnFocus
        child.restoreList()
        session.returnFocus = focus
        session.backReady = false
        ChallengeMenu.resume(session.gameplay:GetRealTimeSeconds(session.pawn))
    end
    return true
end

local function historyBack(session)
    if not session.pageBack or session.suspended or not session.widget:IsActivated() then return end
    if not (session.widget:HasUserFocus(session.controller) or session.widget:HasUserFocusedDescendants(session.controller)) then
        session.backReady = false; return
    end
    local down = false
    for _, key in ipairs(BACK_KEYS) do
        if session.router:IsUIKeyHeld({ KeyName = FName(key) }) then down = true; break end
    end
    if not down then session.backReady = true
    elseif session.backReady then session.backReady = false; session.pending = { action = session.pageBack, label = "返回" } end
end

local function attach(session, controller, state, onAction)
    local widget = session.widget
    local main = widget.MainBox
    local library = StaticFindObject(WIDGET_LIBRARY)
    local pulseClass = StaticFindObject(PULSE_CLASS)
    assert(valid(main) and valid(library) and valid(pulseClass), "原版铃铛菜单缺少原生控件接口")
    local xiguMenu = state.runtimeModule == "XiguBossArena"
    if xiguMenu then
        for index = 0, main:GetChildrenCount() - 1 do
            local child = main:GetChildAt(index)
            if valid(child) then
                rememberVisibility(session, child)
                local original = session.visibility[child:GetAddress()]
                original.hide, original.enabled = true, child:GetIsEnabled()
            end
        end
    end
    local group
    for index, key in ipairs(BUTTONS) do
        local button = widget[key]
        assert(valid(button), "原版铃铛菜单缺少选项：" .. key)
        session.stock[index] = button
        if not session.bellOwner then
            local container = rowContainer(button, main)
            rememberVisibility(session, button)
            rememberVisibility(session, container)
            local original = session.visibility[button:GetAddress()]
            original.hide = true
            if xiguMenu then original.enabled = button:GetIsEnabled() end
            session.visibility[container:GetAddress()].hide = true
        end
        for _, binding in ipairs(button.OnButtonBaseClicked:GetBindings()) do
            if name(binding.FunctionName) == "OnHandleButtonBaseClicked" and valid(binding.Object) then
                assert(not group or same(group, binding.Object), "铃铛菜单选项属于多个导航组")
                group = binding.Object
            end
        end
    end
    assert(valid(group), "原版铃铛菜单缺少导航组")
    session.group = group
    if state.bellName then mountBellTitle(session) end
    if session.bellOwner then main = mountDreamList(session, main) end
    local pre, post = RegisterHook(CLICK, function(context)
        if current ~= session or session.suspended or session.pending then return end
        if session.bellOwner and (not ownsWidget(session) or not widget:IsActivated()) then return end
        local pulse = context:get()
        if valid(pulse) then session.pending = session.actions[pulse:GetAddress()] end
    end)
    session.clickHook = { pre, post }
    session.controlsChanged = true
    if xiguMenu then hideStock(session) end
    for index, template in ipairs(session.stock) do
        if session.bellOwner and index > 4 then break end
        local button = library:Create(widget, template:GetClass(), controller)
        assert(valid(button), "无法创建原版铃铛选项")
        session.buttons[index] = button
        button.bOverride_ButtonText = true
        button:SetMinDimensions(template.MinWidth, template.MinHeight)
        button:SetIsFocusable(true)
        local slot = main:AddChildToVerticalBox(button)
        assert(valid(slot), "无法挂载原版铃铛选项")
        slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 10 })
        local pulse = StaticConstructObject(pulseClass, main)
        assert(valid(pulse), "无法创建铃铛选项回调")
        session.pulses[index] = pulse
        pulse:SetVisibility(COLLAPSED)
        assert(valid(main:AddChildToVerticalBox(pulse)), "无法挂载铃铛选项回调")
    end
    hideStock(session)
    if not session.caption and valid(widget.CurrentBellNameText) then session.title = widget.CurrentBellNameText:GetText() end
    if valid(widget.Text) then
        rememberVisibility(session, widget.Text)
        session.details = widget.Text:GetText()
    end
    local function show(title, rows, detail, back)
        setPageBack(session, back)
        renderBell(session, title, rows, detail)
    end
    local equipment = row("装备调整", function() openEquipment(session) end)
    if state.mode == "training" then
        show(state.bellName or state.sceneName or "测试场", {
            row("重选目标", function() onAction("target") end),
            row("能力调整", function() onAction("configure") end),
            equipment,
            row("退出", ChallengeMenu.close),
        })
        return
    end
    if state.mode == "bloody-palace" then
        local floor = state.palacePracticeFloor
        show(state.bellName or "浊梦之间", {
            row(floor and "开始热身" or "开始试炼", function() onAction("palace-start") end),
            row("能力调整", function() onAction("configure") end),
            equipment,
            row("返回", ChallengeMenu.close),
        }, floor and ("第 %d 层"):format(floor) or nil)
        if session.caption then
            print("[PBZTestArenaNative] Dream Palace bell R2 mounted: title=" .. name(session.caption:GetText())
                .. "; rows=" .. tostring(#session.buttons) .. "\n")
        end
        return
    end
    local function menu()
        local rows = {
            row("更换目标", function() onAction("target") end),
            row("能力调整", function() onAction("configure") end),
            equipment,
            row("挑战记录", function() history(session.state.history, show, menu, function(record, restore)
                openHistory(session, record, restore)
            end) end),
        }
        if state.requireBellOwner or state.recoveryMessage then rows[#rows + 1] = row("重试", function() onAction("retry") end) end
        rows[#rows + 1] = row("返回", ChallengeMenu.close)
        show(state.bellName or state.sceneName or "故屋幻景", rows, state.recoveryMessage)
    end
    menu()
end

local function nearBell(pawn, bell)
    local pawnAt = pawn:K2_GetActorLocation()
    local x, y, z = pawnAt.X, pawnAt.Y, pawnAt.Z
    local bellAt = bell:K2_GetActorLocation()
    return (x - bellAt.X)^2 + (y - bellAt.Y)^2 + (z - bellAt.Z)^2 <= 1200^2
end

local function attachWidget(gameplay, pawn, controller, state, onAction, widget)
    local session = { widget = widget, controller = controller, gameplay = gameplay, pawn = pawn, state = state,
        bellOwner = usesDreamBell(state) and state.bellOwner or nil,
        stock = {}, buttons = {}, pulses = {}, visibility = {}, actions = {}, contents = {} }
    current = session
    local ok, failure = pcall(attach, session, controller, state, onAction)
    if not ok then
        print("[PBZTestArenaNative] Challenge bell menu: " .. tostring(failure) .. "\n")
        ChallengeMenu.close()
        return false
    end
    local title = session.caption and "; title=" .. name(session.caption:GetText()) or ""
    print("[PBZTestArenaNative] Native challenge bell attached: " .. (state.bellId or BELL_ID) .. title .. "\n")
    return true
end

local function restoreDreamPage(session)
    local page = session.page
    keepBellContents(session)
    renderBell(session, page.title, page.rows, page.detail, session.returnFocus)
end

local function watchDreamBell(gameplay, pawn, controller, state, onAction)
    local admission = dreamAdmission
    if admission and (not same(admission.pawn, pawn) or not same(admission.controller, controller)
        or not same(admission.state.bellOwner, state.bellOwner)) then
        ChallengeMenu.close()
        admission = nil
    end
    if not admission then
        admission = { pawn = pawn, controller = controller, nextAttempt = 0 }
        dreamAdmission = admission
    end
    admission.state = state
    local hook = admission.hook
    -- Puerts can replace the script function with a native mixin when the first menu is constructed.
    local rebind = hook and hook[1] == hook[2] and not admission.rebound and current and current.caption
    if hook and not rebind then return end
    local now = gameplay:GetRealTimeSeconds(pawn)
    if not rebind and now < admission.nextAttempt then return end
    if rebind then
        admission.rebound = true
        unwatchDreamActivation(admission)
    end
    admission.nextAttempt = now + 1
    local ok, failure = pcall(function()
        if not valid(StaticFindObject(BELL_ACTIVATED)) then
            local class, reason = require("SpawnClass").resolve(BELL_WIDGET)
            assert(valid(class), reason or "等待浊梦铃铛界面资源")
        end
        local installed = {}
        local function afterActivation(context)
            local latest = admission.state
            if dreamAdmission ~= admission or admission.hook ~= installed
                or latest.available == false or not valid(pawn) then return end
            local activated, errorMessage = pcall(function()
                local widget = context:get()
                if not valid(widget) or not widget:IsActivated()
                    or not matchesBell(gameplay, widget, controller, latest) then return end
                -- Returning from ability adjustment runs stock activation again.
                if current then
                    if not same(current.widget, widget) then
                        widget:DeactivateWidget()
                    elseif current.page then
                        restoreDreamPage(current)
                    end
                elseif nearBell(pawn, latest.bellOwner) then
                    attachWidget(gameplay, pawn, controller, latest, onAction, widget)
                end
            end)
            if not activated and admission.activationError ~= errorMessage then
                print("[PBZTestArenaNative] Dream Palace bell activation: " .. tostring(errorMessage) .. "\n")
            end
            admission.activationError = not activated and errorMessage or nil
        end
        installed[1], installed[2] = RegisterHook(BELL_ACTIVATED, function(context)
            -- Script hooks have one ID and run after execution. A native hook
            -- uses its separate post callback, after stock rows are rebuilt.
            if installed[1] == installed[2] then afterActivation(context) end
        end, afterActivation)
        admission.hook = installed
    end)
    if not ok and admission.failure ~= failure then
        print("[PBZTestArenaNative] Dream Palace bell activation: " .. tostring(failure) .. "\n")
    end
    admission.failure = not ok and failure or nil
end

function ChallengeMenu.update(gameplay, pawn, state, onAction)
    local private = usesDreamBell(state)
    if (state.requireBellOwner or private) and not valid(state.bellOwner) then
        if current or dreamAdmission then ChallengeMenu.close() end
        return false
    end
    local controller = gameplay:GetPlayerController(pawn, 0)
    if private and state.available ~= false and valid(controller) then
        watchDreamBell(gameplay, pawn, controller, state, onAction)
    elseif dreamAdmission then
        ChallengeMenu.close()
    end
    if current then
        local session = current
        if state.available == false or not ownsWidget(session)
            or not matchesBell(gameplay, session.widget, controller, state) then
            ChallengeMenu.close()
            return false
        end
        session.gameplay, session.pawn, session.state = gameplay, pawn, state
        if updateHistory(session) then return true end
        if updateEquipment(session) then return true end
        if session.suspended then
            if not session.resumeDeadline then return true end
            if not session.widget:IsActivated() then
                if gameplay:GetRealTimeSeconds(pawn) < session.resumeDeadline then return true end
                ChallengeMenu.close()
                return false
            end
            local page = session.page
            hideStock(session)
            keepBellContents(session)
            renderBell(session, page.title, page.rows, page.detail, session.returnFocus)
            session.suspended, session.resumeDeadline, session.returnFocus = nil, nil, nil
            if session.historyBackBound then session.widget:ClearBackKey() end
            print("[PBZTestArenaNative] Returned to the original challenge bell menu\n")
        elseif not session.widget:IsActivated() then
            ChallengeMenu.close()
            return false
        end
        hideStock(session)
        if session.bellOwner then
            keepBellContents(session)
            if session.group:GetButtonCount() ~= #session.buttons
                or not same(session.group:GetButtonBaseAtIndex(0), session.buttons[1]) then
                restoreDreamPage(session)
            end
        end
        historyBack(session)
        local item = session.pending
        session.pending = nil
        if item then
            print("[PBZTestArenaNative] Native challenge bell selection: " .. item.label .. "\n")
            local ok, failure = pcall(item.action)
            if not ok then
                print("[PBZTestArenaNative] Challenge bell selection: " .. tostring(failure) .. "\n")
                ChallengeMenu.close()
            end
        end
        return current ~= nil
    end
    if state.requireBellOwner or private then
        -- A native menu for this bell can only start within interaction range.
        -- Already-open or suspended menus are handled above regardless of distance.
        if not nearBell(pawn, state.bellOwner) then return false end
    end
    local widget = ownedBellMenu(gameplay, controller, state)
    if not valid(widget) then return false end
    if state.available == false then
        widget:DeactivateWidget()
        return false
    end
    return attachWidget(gameplay, pawn, controller, state, onAction, widget)
end

return ChallengeMenu
