-- Reuse the game's setting visuals without constructing a GameSetting row or
-- assigning any GameSetting/Registry/data source. Input stays in ParameterForm.
local Assets = require("CombatSpawn")
local Style = {}
local EDITORS = "/Game/PBZContent/UI/Settings/Editors/"
local CHARACTER = "/Game/PBZContent/UI/UINew/System/Character/"
local DECORATORS = "/Game/PBZContent/UI/UINew/System/Setting/"
local WHITE = { SpecifiedColor = { R = 1, G = 1, B = 1, A = 1 }, ColorUseRule = 0 }
local BLACK = { SpecifiedColor = { R = 0, G = 0, B = 0, A = 1 }, ColorUseRule = 0 }

local function valid(object) return object ~= nil and type(object.IsValid) == "function" and object:IsValid() end
local function unwrap(object)
    if object and type(object.IsValid) ~= "function" then
        local getter = object.get or object.Get
        if type(getter) == "function" then return getter(object) end
    end
    return object
end
local function checked(object, message) object = unwrap(object); assert(valid(object), message); return object end
local function required(path) return checked(StaticFindObject(path), "缺少原生设置样式接口：" .. path) end
local function asset(folder, name) return Assets.class(folder .. name .. "." .. name .. "_C") end
local function native(kind, tree)
    return checked(StaticConstructObject(required("/Script/UMG." .. kind), tree), "无法创建设置布局：" .. kind)
end
local function create(context, controller, name)
    local widget = checked(required("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(context,
        asset(EDITORS, name), controller), "无法创建游戏设置样式：" .. name)
    widget:SetVisibility(4)
    return widget
end
local function locText(tree, heading)
    local widget = checked(StaticConstructObject(required("/Script/ProjectPBZ.PBZCommonLocText"), tree),
        "无法创建原生设置字体")
    -- The original templates intentionally contain null Font/magenta color.
    -- Set the real style class, with the original language decorator retained
    -- so culture changes keep using the game's own typography rules.
    widget.LanguageTextDecoratorClass = asset(DECORATORS, heading and "BP_Decorator_H3_SettingEntry" or "BP_Decorator2")
    widget:SetStyle(asset(CHARACTER, heading and "Textstyle_H3_CN" or "Textstyle_Main_CN"))
    widget:SetVisibility(3)
    return widget
end
local function box(tree, child, width)
    local result = native("SizeBox", tree)
    result:SetVisibility(4)
    if width then result:SetWidthOverride(width) end
    result:SetContent(child)
    return result
end
local function add(line, child, fill)
    local slot = checked(line:AddChildToHorizontalBox(child), "无法排列原生设置行")
    slot:SetVerticalAlignment(2)
    if fill then slot:SetSize({ SizeRule = 1, Value = 1 }) end
end
local function buttonOverlay(button)
    local widget = checked(checked(button.WidgetTree, "原生设置按钮缺少控件树").RootWidget, "原生设置按钮没有内容")
    for _ = 1, 8 do
        local name = widget:GetClass():GetFName():ToString()
        if name == "Overlay" then return widget end
        -- CommonButtonBase wraps the blueprint root inside its native internal
        -- button during Initialize. Follow its Content rather than replacing it.
        widget = checked(widget:GetContent(), "原生设置按钮内容不是 Overlay")
    end
    error("原生设置按钮容器层数异常")
end
local function arrow(context, controller, tree, left)
    local button = create(context, controller, "W_SettingBaseButton")
    button:SetVisibility(0)
    button:SetIsFocusable(false)
    button:SetMinDimensions(60, 60)
    button.bCanPlaySound = false -- ParameterFeedback owns one click event.
    local overlay = buttonOverlay(button)
    -- Reuse the game's authored arrow-hover artwork, behind its normal setting
    -- arrow. This adds no button style, sound, input binding or generated frame.
    local glow = native("Image", tree)
    glow:SetVisibility(3)
    local hoverName = "T_Literature_Arrow" .. (left and "L" or "R") .. "_Hover"
    glow:SetBrushFromTexture(Assets.class("/Game/PBZContent/UI/InGame/Literature/" .. hoverName .. "." .. hoverName), true)
    local glowBox = box(tree, glow, 60)
    glowBox:SetHeightOverride(60); glowBox:SetVisibility(1)
    local glowSlot = checked(overlay:AddChildToOverlay(glowBox), "无法挂载原生箭头光晕")
    glowSlot:SetHorizontalAlignment(2); glowSlot:SetVerticalAlignment(2)
    local image = native("Image", tree)
    image:SetVisibility(3)
    image:SetBrushFromTexture(Assets.class("/Game/PBZContent/UI/Settings/Texture/T_SettingArrow.T_SettingArrow"), false)
    if left then image:SetRenderTransformAngle(180) end
    local slot = checked(overlay:AddChildToOverlay(image), "无法挂载原生设置箭头")
    slot:SetHorizontalAlignment(2); slot:SetVerticalAlignment(2)
    return button, glowBox
end

function Style.row(context, controller, tree, label)
    local background = create(context, controller, "W_SettingEntryBackground")
    local line = native("HorizontalBox", tree)
    line:SetVisibility(4)
    checked(background.Content, "原生设置背景缺少 Content 插槽"):SetContent(line)
    local name = locText(tree, true)
    name:SetText(FText(label))
    add(line, box(tree, name, 240))
    local decrease, decreaseGlow = arrow(context, controller, tree, true)
    add(line, decrease)
    local rotator = create(context, controller, "W_SettingBaseRotator")
    rotator:SetIsFocusable(false)
    rotator:SetVisibility(3) -- Visual fragment only; no native rotator input.
    local value = checked(rotator.MyText, "原生参数值缺少 MyText")
    -- Use its real native style, including the existing DownOnly ScaleBox for
    -- long boss names. No fallback Font or generic text renderer is inserted.
    value.LanguageTextDecoratorClass = asset(DECORATORS, "BP_Decorator2")
    value:SetStyle(asset(CHARACTER, "Textstyle_Main_CN"))
    add(line, rotator, true)
    local increase, increaseGlow = arrow(context, controller, tree, false)
    add(line, increase)
    local row = { root = background, label = name, value = value, rotator = rotator,
        decrease = decrease, increase = increase, decreaseGlow = decreaseGlow, increaseGlow = increaseGlow,
        gamepad = true }
    function row:setInputMode(gamepad)
        gamepad = gamepad == true
        if self.gamepad == gamepad then return end
        self.gamepad, self.selected = gamepad, nil
        if self.lastValue ~= nil then self:refresh(self.lastValue, self.logicalSelected) end
    end
    function row:refresh(content, selected)
        self.logicalSelected = selected == true
        selected = self.gamepad and self.logicalSelected
        if self.lastValue ~= content then
            self.value:SetText(FText(content))
            self.lastValue = content
        end
        -- Text is the BP's cached cast of MyText, initialized by Construct.
        -- The controls are already mounted before ParameterForm refreshes them.
        if self.selected ~= selected then
            if selected then self.root:OnSelected() else self.root["Not Selected"](self.root) end
            self.label:OverrideTextColor(selected and BLACK or WHITE)
            self.label:SetOutlineOverrideEnabled(selected)
            self.rotator:SetSelectedAppearance(selected)
            self.selected = selected
        end
        -- Tint only the authored background brush. The Border and its NamedSlot
        -- content stay mounted/visible, so arrows and values remain interactive.
        checked(self.root.AnimBoundEntryBorder, "原生设置行缺少背景笔刷"):SetBrushColor({ R = 1, G = 1, B = 1, A = self.gamepad and 1 or 0 })
        self.decreaseHovered = not self.gamepad and self.decrease:IsHovered()
        self.increaseHovered = not self.gamepad and self.increase:IsHovered()
        self.hovered = self.decreaseHovered or self.increaseHovered
        self.decreaseGlow:SetVisibility(self.decreaseHovered and 3 or 1)
        self.increaseGlow:SetVisibility(self.increaseHovered and 3 or 1)
        -- The MOD's values are not the game's discrete option model; no fake
        -- progress pips are displayed, while the original text/style is kept.
        local pips = self.rotator.OptionsScalingSizeBox
        if valid(pips) then pips:SetVisibility(1) end
    end
    return row
end

-- Standalone visual fragments for the full-screen pages. They never acquire a
-- CommonUI action binding; the existing confirmation remains the input owner.
function Style.setTextSize(widget, size)
    assert(type(size) == "number" and size == size and size >= 1 and size <= 256,
        "原生文字字号无效")
    -- Font is the instance's reflected FSlateFontInfo, not the style CDO or
    -- shared font asset. Preserve its face, material, spacing and outline.
    local font = widget.Font
    font.Size = size
    widget:SetFont(font)
    return widget
end

function Style.scaleText(widget, scale)
    assert(type(scale) == "number" and scale == scale and scale > 0 and scale <= 12,
        "原生文字字号比例无效")
    local baseSize = widget.Font.Size
    assert(type(baseSize) == "number" and baseSize > 0, "原生字体样式尚未就绪")
    return Style.setTextSize(widget, baseSize * scale)
end

function Style.text(tree, value, heading, size)
    local widget = locText(tree, heading == true)
    widget:SetText(FText(value or ""))
    -- Standalone page labels use their complete layout width. Automatic
    -- wrapping can hide the last character in a one-line Canvas slot.
    -- Explicit newlines (missing-art text) are still retained.
    widget:SetAutoWrapText(false)
    if size then Style.setTextSize(widget, size) end
    return widget
end

function Style.button(context, controller, tree, label)
    local button = create(context, controller, "W_SettingBaseButton")
    button:SetIsFocusable(false)
    button.bCanPlaySound = false
    local overlay = buttonOverlay(button)
    local caption = locText(tree, true)
    caption:SetText(FText(label or ""))
    caption:SetJustification(1)
    local slot = checked(overlay:AddChildToOverlay(caption), "无法挂载全屏菜单按钮")
    slot:SetHorizontalAlignment(0); slot:SetVerticalAlignment(2)
    return button, caption
end

function Style.flatRow(context, controller, tree, label)
    local row = Style.row(context, controller, tree, label)
    local refresh = row.refresh
    function row:refresh(content, selected)
        refresh(self, content, selected)
        -- The approved artwork has no setting-row rectangle. Selection is a
        -- warm text accent; the authored arrow hover is still used for mouse.
        checked(self.root.AnimBoundEntryBorder, "原生设置行缺少背景笔刷")
            :SetBrushColor({ R = 1, G = 1, B = 1, A = 0 })
        local active = self.gamepad and selected
        self.label:OverrideTextColor({ SpecifiedColor = { R = active and 1 or .88,
            G = active and .77 or .85, B = active and .43 or .77, A = 1 }, ColorUseRule = 0 })
        self.label:SetOutlineOverrideEnabled(false)
        self.value:OverrideTextColor({ SpecifiedColor = { R = 1, G = active and .77 or .93,
            B = active and .43 or .83, A = 1 }, ColorUseRule = 0 })
        self.value:SetOutlineOverrideEnabled(false)
    end
    return row
end

return Style
