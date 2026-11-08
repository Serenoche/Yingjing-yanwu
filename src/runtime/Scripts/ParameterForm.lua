-- A native UMG form inside an existing CommonUI confirmation page. The modal
-- retains its input mode, Back handling and native confirmation delegate.
local Form = {}
local Style = require("ParameterStyle")
local Feedback = require("ParameterFeedback")
local Instance = {}
Instance.__index = Instance
local CLICK = "/Script/UMG.Widget:ForceLayoutPrepass"
local SUBSYSTEM = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local ROUTER = "/Script/ProjectPBZ.PBZUIActionRouterBase"
local COMMON_INPUT = "/Script/CommonInput.CommonInputSubsystem"
local DIRECTIONS = {
    { "Gamepad_DPad_Up", "Up" }, { "Gamepad_DPad_Down", "Down" },
    { "Gamepad_DPad_Left", "Left" }, { "Gamepad_DPad_Right", "Right" },
}
local CONFIRM = { "Gamepad_FaceButton_Bottom", "Enter", "SpaceBar" }
local feedbackFailures = {}

local function feedback(action, ...)
    local ok, failure = pcall(Feedback[action], ...)
    if not ok and not feedbackFailures[action] then
        feedbackFailures[action] = true
        print("[PBZTestArenaNative] Parameter feedback " .. action .. ": " .. tostring(failure) .. "\n")
    end
end

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
local function checked(object, message)
    object = unwrap(object); assert(valid(object), message); return object
end
local function same(first, second)
    return valid(first) and valid(second) and first:GetAddress() == second:GetAddress()
end
local function hasFocus(session)
    return session.modal:HasUserFocus(session.controller)
        or session.modal:HasUserFocusedDescendants(session.controller)
end
local function required(path)
    return checked(StaticFindObject(path), "缺少原生参数菜单接口：" .. path)
end
local function make(kind, outer)
    local widget = checked(StaticConstructObject(required("/Script/UMG." .. kind), outer), "无法创建参数菜单控件：" .. kind)
    -- SelfHitTestInvisible preserves mouse interaction on child buttons.
    widget:SetVisibility(4)
    return widget
end
local function size(outer, child, width, height)
    local box = make("SizeBox", outer)
    if width then box:SetWidthOverride(width) end
    if height then box:SetHeightOverride(height) end
    box:SetContent(child)
    return box
end
local function held(router, names)
    for _, name in ipairs(names) do
        if router:IsUIKeyHeld({ KeyName = FName(name) }) then return true, name end
    end
    return false
end

function Instance:isConfirmHeld() return held(self.router, CONFIRM) end
function Instance:syncInputMode()
    if valid(self.commonInput) then
        local readable, inputType = pcall(function() return self.commonInput:GetCurrentInputType() end)
        if readable then self.gamepadMode = inputType == 1 end
    end
    -- Native confirmation delegates can run before this frame's form update.
    -- The router already records the physical A press at that point.
    if self.router:IsUIKeyHeld({ KeyName = FName("Gamepad_FaceButton_Bottom") }) then self.gamepadMode = true end
    return self.gamepadMode == true
end
function Instance:focusConfirm(initial)
    if not valid(self.modal) or not self.modal:IsActivated() or (not initial and not hasFocus(self)) then return end
    local target = self.focusForRegion and self.focusForRegion(self) or self.confirm
    if valid(target) then target:SetFocus() end
end
function Instance:consumeConfirm()
    self.confirmReady = false
    -- A queued native click may already have been released before update. In
    -- that case reserve the next update too, so a second native callback cannot
    -- consume the same click after the caller and the form both update.
    self.skipReleasedConfirm = not self:isConfirmHeld()
end

function Instance:refresh()
    for index, row in ipairs(self.rows) do
        local widget = self.widgets[index]
        local value = row.value()
        assert(type(value) == "string" or type(value) == "number", "参数值必须为文本或数字")
        widget:setInputMode(self.gamepadMode == true)
        local enabled = row.enabled == nil or (type(row.enabled) == "function" and row.enabled() or row.enabled == true)
        widget.decrease:SetIsEnabled(enabled)
        widget.increase:SetIsEnabled(enabled)
        widget:refresh(tostring(value), index == self.selected
            and (not self.groups or #self.groups[self.region] > 0))
    end
    if self.onRefresh then self.onRefresh(self) end
end

function Instance:setRegion(region)
    if not self.groups then return end
    self.region = math.max(1, math.min(#self.groups, region))
    local group = self.groups[self.region]
    self.selected = group[1] or self.selected
    self:refresh()
    self:focusConfirm()
end

function Instance:advanceConfirm()
    if not self:canConfirm() then return false end
    if self.groups then self:syncInputMode(); self:consumeConfirm() end
    if self.groups and self.gamepadMode and self.region < #self.groups then
        self:setRegion(self.region + 1)
        return false
    end
    return true
end

function Instance:back()
    if self.groups and self.gamepadMode and self.region > 1 then
        self:setRegion(self.region - 1)
        self.confirmReady = false
        return true
    end
    return false
end

function Instance:change(index, delta)
    self.selected = index
    self.rows[index].change(delta)
    self:refresh()
    self:focusConfirm()
end

function Instance:close()
    if self.closed then return end
    self.closed, self.confirmReady, self.pending = true, false, {}
    if self.hook then pcall(UnregisterHook, CLICK, self.hook[1], self.hook[2]); self.hook = nil end
    for _, binding in ipairs(self.arrowDelegates) do
        if valid(binding.button) then pcall(function() binding.delegate:Clear() end) end
    end
    -- Deactivated modals are still valid while CommonUI animates them out.
    -- Restore only our own content, never another page's replacement.
    if valid(self.parent) and valid(self.root) then
        local ok, content = pcall(function() return unwrap(self.parent:GetContent()) end)
        if ok and same(content, self.root) and valid(self.description) then
            pcall(function()
                local slot = checked(self.parent:SetContent(self.description), "无法恢复参数正文插槽")
                slot:SetHorizontalAlignment(self.originalSlot.horizontal)
                slot:SetVerticalAlignment(self.originalSlot.vertical)
                slot:SetPadding(self.originalSlot.padding)
            end)
        end
    end
    for _, pulse in ipairs(self.pulses) do
        if valid(pulse) then pcall(function() pulse:RemoveFromParent() end) end
    end
    if self.external then
        for _, widget in ipairs(self.widgets or {}) do
            if valid(widget.root) then pcall(function() widget.root:RemoveFromParent() end) end
        end
    end
    if valid(self.root) then pcall(function() self.root:RemoveFromParent() end) end
    if self.navigationChanged then
        for _, target in ipairs(self.navigationTargets or {}) do
            if valid(target) then
                for direction = 0, 3 do pcall(function() target:SetNavigationRuleBase(direction, 0) end) end
            end
        end
    end
    self.actions, self.pulses, self.arrowButtons, self.arrowDelegates = {}, {}, {}, {}
end

function Instance:canConfirm()
    return not self.closed and self.confirmReady == true and valid(self.modal) and self.modal:IsActivated()
        and valid(self.controller) and hasFocus(self)
end

function Instance:update(gameplay)
    if self.closed then return false end
    if not valid(self.modal) or not self.modal:IsActivated() or not valid(self.router) or not valid(self.controller)
        or not same(unwrap(self.modal:GetOwningPlayer()), self.controller)
        or (self.external and not valid(self.parent))
        or (not self.external and (not valid(self.parent) or not same(unwrap(self.parent:GetContent()), self.root))) then
        self:close(); return false
    end
    local ok, failure = pcall(function()
        if not hasFocus(self) then
            self.directionBlocked, self.activeDirection, self.nextRepeat = true, nil, nil
            self.confirmReady, self.pending = false, {}
            return
        end
        local now = gameplay:GetRealTimeSeconds(self.modal)
        assert(type(now) == "number" and now == now, "参数菜单时间不可用")
        if self.lastTime and now < self.lastTime then self.directionBlocked, self.activeDirection = true, nil end
        self.lastTime = now
        self:syncInputMode()
        if held(self.router, CONFIRM) then self.skipReleasedConfirm = nil
        elseif self.skipReleasedConfirm then self.skipReleasedConfirm = nil
        else self.confirmReady = true end
        local direction, directionKey, count = nil, nil, 0
        for index, keys in ipairs(DIRECTIONS) do
            local down, key = held(self.router, keys)
            if down then direction, directionKey, count = index, key, count + 1 end
        end
        if count == 0 then
            self.directionBlocked, self.activeDirection, self.nextRepeat = false, nil, nil
        elseif count > 1 then
            self.directionBlocked, self.activeDirection, self.nextRepeat = true, nil, nil
        elseif not self.directionBlocked then
            local step = self.activeDirection ~= direction
            if step then self.activeDirection, self.nextRepeat = direction, now + 0.35
            elseif now >= self.nextRepeat then step, self.nextRepeat = true, now + 0.12 end
            if step then
                local gamepadStep = directionKey:sub(1, 8) == "Gamepad_"
                self.gamepadMode = gamepadStep
                local group = self.groups and self.groups[self.region]
                if group then
                    if #group > 0 then
                        local localIndex = 1
                        for candidate, rowIndex in ipairs(group) do if rowIndex == self.selected then localIndex = candidate end end
                        if direction == 1 then self.selected = group[(localIndex - 2) % #group + 1]
                        elseif direction == 2 then self.selected = group[localIndex % #group + 1]
                        else self:change(self.selected, direction == 3 and -1 or 1) end
                    end
                elseif direction == 1 then self.selected = (self.selected - 2) % #self.rows + 1
                elseif direction == 2 then self.selected = self.selected % #self.rows + 1
                else self:change(self.selected, direction == 3 and -1 or 1) end
                if gamepadStep then feedback("navigate", self.controller, self.modal) end
                self:focusConfirm()
            end
        end
        local pending = self.pending
        self.pending = {}
        for _, action in ipairs(pending) do
            self.gamepadMode = false
            self:change(action.index, action.delta)
            feedback("click", self.modal, action.button)
        end
        self:refresh()
    end)
    if not ok then self:close(); error(failure, 0) end
    return true
end

local function arrow(session, index, delta, button)
    feedback("configureArrow", button)
    session.arrowButtons[#session.arrowButtons + 1] = button
    local pulse = make("TextBlock", session.tree)
    pulse:SetVisibility(1)
    session.body:AddChildToVerticalBox(pulse)
    session.pulses[#session.pulses + 1] = pulse
    session.actions[pulse:GetAddress()] = { index = index, delta = delta, button = button }
    local delegate = button.OnButtonBaseClicked
    delegate:Add(pulse, FName("ForceLayoutPrepass"))
    session.arrowDelegates[#session.arrowDelegates + 1] = { button = button, delegate = delegate }
end

function Form.open(modal, description, controller, confirmButton, rows, options)
    options = options or {}
    assert(type(rows) == "table" and #rows >= 1 and #rows <= 8, "参数菜单必须包含一至八行")
    for _, row in ipairs(rows) do
        assert(type(row) == "table" and type(row.label) == "string" and type(row.value) == "function"
            and type(row.change) == "function", "参数行定义无效")
    end
    local session = setmetatable({ modal = checked(modal, "参数弹窗无效"),
        description = checked(description, "参数弹窗正文无效"), controller = checked(controller, "参数菜单控制器无效"),
        confirm = checked(confirmButton, "参数菜单确认按钮无效"), rows = rows, selected = 1,
        pending = {}, actions = {}, pulses = {}, arrowButtons = {}, arrowDelegates = {}, widgets = {},
        directionBlocked = true, confirmReady = false, external = options.host ~= nil,
        groups = options.groups, region = options.region or 1, onRefresh = options.onRefresh,
        focusForRegion = options.focusForRegion }, Instance)
    local ok, failure = pcall(function()
        assert(session.modal:IsActivated(), "参数弹窗尚未激活")
        assert(same(unwrap(session.modal:GetOwningPlayer()), session.controller), "参数弹窗属于其他控制器")
        session.parent = session.external and checked(options.host, "全屏参数容器无效")
            or checked(session.description:GetParent(), "参数正文没有原生容器")
        if not session.external then
        assert(same(unwrap(session.parent:GetContent()), session.description), "参数正文容器已经改变")
        -- ContentWidget:SetContent creates a new slot each time. Copy the
        -- original values before replacing it; the old slot may be collected.
        local originalSlot = checked(session.description.Slot, "参数正文没有原生插槽")
        local padding = originalSlot.Padding
        session.originalSlot = { horizontal = originalSlot.HorizontalAlignment, vertical = originalSlot.VerticalAlignment,
            padding = { Left = padding.Left, Top = padding.Top, Right = padding.Right, Bottom = padding.Bottom } }
        end
        session.tree = checked(session.modal.WidgetTree, "参数弹窗没有原生控件树")
        session.router = checked(required(SUBSYSTEM):GetLocalPlayerSubsystem(session.modal, required(ROUTER)),
            "找不到参数菜单的原生输入路由")
        local inputClass = StaticFindObject(COMMON_INPUT)
        if valid(inputClass) then
            local readable, input = pcall(function()
                return required(SUBSYSTEM):GetLocalPlayerSubsystem(session.modal, inputClass)
            end)
            if readable and valid(input) then
                session.commonInput = input
                local typed, inputType = pcall(function() return input:GetCurrentInputType() end)
                if typed then session.gamepadMode = inputType == 1 end
            end
        end
        session.root = make("SizeBox", session.tree)
        session.root:SetWidthOverride(options.width or 740)
        session.body = make("VerticalBox", session.tree)
        session.root:SetContent(session.body)
        for index, row in ipairs(rows) do
            local styled = (options.flat and Style.flatRow or Style.row)(session.modal, session.controller, session.tree, row.label)
            arrow(session, index, -1, styled.decrease)
            arrow(session, index, 1, styled.increase)
            if options.mountRow then options.mountRow(index, styled.root)
            else session.body:AddChildToVerticalBox(size(session.tree, styled.root, nil, 76.5)) end
            session.widgets[index] = styled
        end
        local pre, post = RegisterHook(CLICK, function(context)
            if session.closed or not valid(session.modal) or not session.modal:IsActivated() then return end
            local target = unwrap(context:get())
            local action = valid(target) and session.actions[target:GetAddress()] or nil
            if action then session.pending[#session.pending + 1] = action end
        end)
        session.hook = { pre, post }
        session.navigationTargets = {}
        local buttons = { session.confirm }
        for _, button in ipairs(options.navigationButtons or {}) do buttons[#buttons + 1] = button end
        for _, button in ipairs(buttons) do
            session.navigationTargets[#session.navigationTargets + 1] = button
            local buttonTree = unwrap(button.WidgetTree)
            local buttonRoot = valid(buttonTree) and unwrap(buttonTree.RootWidget) or nil
            if valid(buttonRoot) and not same(buttonRoot, button) then
                session.navigationTargets[#session.navigationTargets + 1] = buttonRoot
            end
        end
        session.navigationChanged = true
        for _, target in ipairs(session.navigationTargets) do
            for direction = 0, 3 do target:SetNavigationRuleBase(direction, 3) end
        end
        if session.external then
            local slot = checked(session.parent:AddChildToCanvas(session.root), "无法挂载全屏参数回调")
            slot:SetPosition({ X = 0, Y = 0 }); slot:SetSize({ X = 0, Y = 0 })
        else
            local formSlot = checked(session.parent:SetContent(session.root), "无法挂载原生参数表单")
            formSlot:SetHorizontalAlignment(0)
            formSlot:SetVerticalAlignment(2)
            formSlot:SetPadding(session.originalSlot.padding)
        end
        if session.groups then session:setRegion(session.region) end
        session:refresh()
        session:focusConfirm(true)
    end)
    if not ok then session:close(); error(failure, 0) end
    return session
end

return Form
