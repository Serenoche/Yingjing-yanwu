local StageScreen = require("StageScreen")

local Hud = {}
Hud.__index = Hud

local COLLAPSED, HIT_TEST_INVISIBLE = 1, 3
local LEFT, TOP, WIDTH = 20, 88, 240
local BACKGROUND = { R = .025, G = .03, B = .035, A = .82 }
local TITLE = { R = .95, G = .85, B = .57, A = 1 }
local TEXT = { R = .90, G = .91, B = .92, A = 1 }
local MUTED = { R = .65, G = .68, B = .71, A = 1 }

local function valid(object)
    return object ~= nil and type(object.IsValid) == "function" and object:IsValid()
end

local function same(a, b)
    return valid(a) and valid(b) and a:GetAddress() == b:GetAddress()
end

local function make(kind, outer)
    local class = StaticFindObject("/Script/UMG." .. kind)
    assert(valid(class), "缺少木桩统计控件类型 " .. kind)
    local widget = StaticConstructObject(class, outer)
    assert(valid(widget), "无法创建木桩统计控件 " .. kind)
    widget:SetVisibility(HIT_TEST_INVISIBLE)
    return widget
end

local function label(body, size, color)
    local widget = make("TextBlock", body)
    -- Keep the existing Slate fallback when a custom font cannot be set.
    pcall(function()
        local font = widget.Font
        font.Size = size
        widget:SetFont(font)
    end)
    widget:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 })
    body:AddChildToVerticalBox(widget):SetPadding({ Left = 0, Top = 1, Right = 0, Bottom = 2 })
    return widget
end

local function mount(view, kind, resetKeyLabel)
    local root = view.root
    local panel = make("SizeBox", root)
    view.panel = panel
    panel:SetVisibility(COLLAPSED)
    panel:SetWidthOverride(WIDTH)

    local border = make("Border", panel)
    border:SetBrushColor(BACKGROUND)
    border:SetPadding({ Left = 12, Top = 10, Right = 12, Bottom = 10 })
    panel:SetContent(border)
    local body = make("VerticalBox", border)
    border:SetContent(body)
    label(body, 18, TITLE):SetText(FText("木桩伤害"))
    view.lines = {}
    for index = 1, 4 do view.lines[index] = label(body, 14, TEXT) end
    view.issue = label(body, 14, MUTED)
    view.issue:SetText(FText("本轮有伤害读取失败"))
    label(body, 14, MUTED):SetText(FText(resetKeyLabel .. "  清零"))

    if kind == "CanvasPanel" then
        local slot = root:AddChildToCanvas(panel)
        slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } })
        slot:SetAlignment({ X = 0, Y = 0 })
        slot:SetPosition({ X = LEFT, Y = TOP })
        slot:SetAutoSize(true)
    else
        local slot = root:AddChildToOverlay(panel)
        slot:SetHorizontalAlignment(1)
        slot:SetVerticalAlignment(1)
        slot:SetPadding({ Left = LEFT, Top = TOP, Right = 0, Bottom = 0 })
    end
end

local function number(value, decimals)
    if type(value) ~= "number" or value ~= value or value < 0 or value == math.huge then return "—" end
    if value >= 1e12 then return ("%.3g"):format(value) end
    if not decimals then return ("%.0f"):format(value) end
    return ("%.2f"):format(value):gsub("0+$", ""):gsub("%.$", "")
end

local function refresh(view, stats)
    local lines = {
        "最近伤害　" .. number(stats.last, true),
        "累计伤害　" .. number(stats.total, true),
        "命中次数　" .. number(stats.hits, false),
        "DPS　" .. number(stats.dps, true),
    }
    for index, line in ipairs(lines) do
        if line ~= view.text[index] then
            view.lines[index]:SetText(FText(line))
            view.text[index] = line
        end
    end
    local hasIssue = stats.issue ~= nil
    if view.hasIssue ~= hasIssue then
        view.issue:SetVisibility(hasIssue and HIT_TEST_INVISIBLE or COLLAPSED)
        view.hasIssue = hasIssue
    end
end

function Hud.new(ctx)
    return setmetatable({ ctx = ctx }, Hud)
end

function Hud:hide()
    local view = self.view
    self.view = nil
    if view and valid(view.panel) then pcall(view.panel.RemoveFromParent, view.panel) end
end

function Hud:show(stats)
    local ok, shown = pcall(function()
        local controller = self.ctx.controller
        if type(controller) == "function" then controller = controller() end
        if not valid(controller) then self:hide(); return false end
        local layout, root, kind = StageScreen.gameLayout(controller)
        local view = self.view
        if view and (not same(view.controller, controller) or not same(view.layout, layout)
            or not same(view.root, root) or not valid(view.panel) or not same(view.panel:GetParent(), root)) then
            self:hide()
            view = nil
        end
        self.gameLayer = self.gameLayer or { TagName = FName("UI.Layer.Game") }
        local covered = layout:HasModal() or layout:HasWidgetAboveLayer(self.gameLayer, true)
        if covered then
            if view and not view.covered then
                view.panel:SetVisibility(COLLAPSED)
                view.covered = true
            end
            return false
        end
        if not view then
            view = { controller = controller, layout = layout, root = root, text = {}, covered = true }
            self.view = view
            mount(view, kind, self.ctx.resetKeyLabel)
        end
        refresh(view, stats)
        if view.covered then
            view.panel:SetVisibility(HIT_TEST_INVISIBLE)
            view.covered = false
        end
        return true
    end)
    if not ok then
        self:hide()
        local reason = tostring(shown)
        if self.lastError ~= reason then
            print("[PBZTestArenaNative] 木桩统计面板：" .. reason .. "\n")
            self.lastError = reason
        end
        return false, reason
    end
    self.lastError = nil
    return shown
end

return Hud
