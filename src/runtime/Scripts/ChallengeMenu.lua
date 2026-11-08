local ChallengeMenu = {}
local HistoryReport = require("HistoryReport")

local BELL_ID = "BrokenBell_TheEnd01"
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
local current, unrecognizedOwner
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

local function matchesBell(gameplay, widget, controller, expectedBellId)
    if not valid(widget) or not same(resolveObject(widget:GetOwningPlayer()), controller) then return false end
    local bell = resolveObject(widget.OwnerBell)
    if not valid(bell) then return false end
    local actual, expected = name(bell.BellID), expectedBellId or BELL_ID
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

local function ownedBellMenu(gameplay, controller, expectedBellId)
    for _, widget in ipairs(FindAllOf("W_BellMenu_C") or {}) do
        if valid(widget) and widget:IsActivated() and same(resolveObject(widget:GetOwningPlayer()), controller) then
            local bell = resolveObject(widget.OwnerBell)
            if valid(bell) then
                if matchesBell(gameplay, widget, controller, expectedBellId) then return widget end
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

local function setHeader(session, title, detail)
    local widget = session.widget
    if valid(widget.CurrentBellNameText) then widget.CurrentBellNameText:SetText(FText(title)) end
    if valid(widget.Text) then
        widget.Text:SetText(FText(detail or ""))
        widget.Text:SetVisibility(detail and detail ~= "" and 4 or COLLAPSED)
    end
end

local function renderBell(session, title, rows, detail, preferredFocus)
    local focused
    local old = preferredFocus or session.group:GetSelectedButtonBase()
    local actions = {}
    assert(#rows > 0 and #rows <= #BUTTONS, "挑战菜单选项数量无效")
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
    if session.reportChild then
        session.reportChild = nil
        pcall(require("ChallengeVictory").close)
    end
    if session.historyBackBound and valid(session.widget) then
        session.widget:ClearBackKey()
        if session.widget:IsActivated() then session.widget:BindBackKey() end
    end
    if session.reportVisibility ~= nil and valid(session.widget) then session.widget:SetVisibility(session.reportVisibility) end
    if session.clickHook then pcall(UnregisterHook, CLICK, table.unpack(session.clickHook)) end
    if session.controlsChanged and valid(session.group) then
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
    for _, original in pairs(session.visibility) do
        if valid(original.widget) then original.widget:SetVisibility(original.visibility) end
    end
    if valid(session.widget) then
        local title, details = session.widget.CurrentBellNameText, session.widget.Text
        if session.title and valid(title) then title:SetText(session.title) end
        if session.details and valid(details) then details:SetText(session.details) end
    end
end

function ChallengeMenu.close()
    local session = current
    if not session then return end
    current = nil
    -- Closing a modal can reactivate the underlying menu. Close that child
    -- first, then release the bell, so a world/owner exit cannot reopen it.
    if session.reportChild then session.reportChild = nil; pcall(require("ChallengeVictory").close) end
    if valid(session.widget) and session.widget:IsActivated() then session.widget:DeactivateWidget() end
    local ok, failure = pcall(disconnect, session)
    if not ok then print("[PBZTestArenaNative] Challenge bell cleanup: " .. tostring(failure) .. "\n") end
end

function ChallengeMenu.suspend()
    local session = current
    if not session or not valid(session.widget) or not session.widget:IsActivated() then return false end
    session.suspended, session.pending = true, nil
    session.returnFocus = session.group:GetSelectedButtonBase()
    return true
end

function ChallengeMenu.resume(realNow)
    if current and current.suspended then current.resumeDeadline = realNow + 2 end
end

local function hideStock(session)
    for _, original in pairs(session.visibility) do
        if original.hide and valid(original.widget) and original.widget:GetVisibility() ~= COLLAPSED then
            original.widget:SetVisibility(COLLAPSED)
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
    local group
    for index, key in ipairs(BUTTONS) do
        local button = widget[key]
        assert(valid(button), "原版铃铛菜单缺少选项：" .. key)
        local container = rowContainer(button, main)
        session.stock[index] = button
        rememberVisibility(session, button)
        rememberVisibility(session, container)
        session.visibility[button:GetAddress()].hide = true
        session.visibility[container:GetAddress()].hide = true
        for _, binding in ipairs(button.OnButtonBaseClicked:GetBindings()) do
            if name(binding.FunctionName) == "OnHandleButtonBaseClicked" and valid(binding.Object) then
                assert(not group or same(group, binding.Object), "铃铛菜单选项属于多个导航组")
                group = binding.Object
            end
        end
    end
    assert(valid(group), "原版铃铛菜单缺少导航组")
    session.group = group
    local pre, post = RegisterHook(CLICK, function(context)
        if current ~= session or session.suspended or session.pending then return end
        local pulse = context:get()
        if valid(pulse) then session.pending = session.actions[pulse:GetAddress()] end
    end)
    session.clickHook = { pre, post }
    session.controlsChanged = true
    for index, template in ipairs(session.stock) do
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
    if valid(widget.CurrentBellNameText) then session.title = widget.CurrentBellNameText:GetText() end
    if valid(widget.Text) then
        rememberVisibility(session, widget.Text)
        session.details = widget.Text:GetText()
    end
    local function show(title, rows, detail, back)
        setPageBack(session, back)
        renderBell(session, title, rows, detail)
    end
    local function menu()
        show(state.sceneName or "故屋幻景", {
            row("更换目标", function() onAction("target") end),
            row("能力调整", function() onAction("configure") end),
            row("挑战记录", function() history(session.state.history, show, menu, function(record, restore)
                openHistory(session, record, restore)
            end) end),
            row("返回", ChallengeMenu.close),
        })
    end
    menu()
end

function ChallengeMenu.update(gameplay, pawn, state, onAction)
    local controller = gameplay:GetPlayerController(pawn, 0)
    if current then
        local session = current
        session.gameplay, session.pawn, session.state = gameplay, pawn, state
        if state.available == false or not matchesBell(gameplay, session.widget, controller, state.bellId) then
            ChallengeMenu.close()
            return false
        end
        if updateHistory(session) then return true end
        if session.suspended then
            if not session.resumeDeadline then return true end
            if not session.widget:IsActivated() then
                if gameplay:GetRealTimeSeconds(pawn) < session.resumeDeadline then return true end
                ChallengeMenu.close()
                return false
            end
            local page = session.page
            hideStock(session)
            renderBell(session, page.title, page.rows, page.detail, session.returnFocus)
            session.suspended, session.resumeDeadline, session.returnFocus = nil, nil, nil
            if session.historyBackBound then session.widget:ClearBackKey() end
            print("[PBZTestArenaNative] Returned to the original challenge bell menu\n")
        elseif not session.widget:IsActivated() then
            ChallengeMenu.close()
            return false
        end
        hideStock(session)
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
    local widget = ownedBellMenu(gameplay, controller, state.bellId)
    if not valid(widget) then return false end
    if state.available == false then
        widget:DeactivateWidget()
        return false
    end
    local session = { widget = widget, controller = controller, gameplay = gameplay, pawn = pawn, state = state,
        stock = {}, buttons = {}, pulses = {}, visibility = {}, actions = {} }
    current = session
    local ok, failure = pcall(attach, session, controller, state, onAction)
    if not ok then
        print("[PBZTestArenaNative] Challenge bell menu: " .. tostring(failure) .. "\n")
        ChallengeMenu.close()
        return false
    end
    print("[PBZTestArenaNative] Native challenge bell attached: " .. (state.bellId or BELL_ID) .. "\n")
    return true
end

return ChallengeMenu
