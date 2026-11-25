local Art = require("ArtAssets")
local Custom = require("PlayerCustom")
local Slider = {}
Slider.__index = Slider

local TEXTURES = "/Game/PBZContent/UI/Settings/Texture/"
local BAR = "T_SettingsScalarBarActiveDefault"
local THUMB = "T_SettingSliderDefault"
local HOVER = "T_SettingSliderSelected"
local TRACK_X, WIDTH, HANDLE = 345, 756, 48
Slider.rowWidth = 1465

local function stockTexture(screen, id)
    local texture = Art.texture(screen.modal, TEXTURES .. id .. "." .. id)
    assert(texture and texture:IsValid(), "原版滑条素材未就绪：" .. id)
    return texture
end

local function art(screen, canvas, texture, x, y, width, height)
    local widget = screen:make("Image")
    widget:SetVisibility(3)
    widget:SetBrushFromTexture(texture, false)
    return screen:place(widget, x, y, width, height, canvas)
end

function Slider.new(screen, canvas, settings, field, x, y)
    local root = screen:make("CanvasPanel")
    screen:place(root, x, y, Slider.rowWidth, 80, canvas)
    local maximum = Custom.maximum(settings, field)
    local span = maximum - field.min
    local label = screen:text(field.label, 0, 7, 207, 48, true, root, 31)
    -- The compact tick button clips long captions. Set both limits outside
    -- the handle travel using standalone native CommonTextBlock widgets.
    local minimumLabel = screen:text(Custom.endpointText(settings, field, field.min), 210, 9, 106, 44, false, root, 25)
    local maximumLabel = screen:text(Custom.endpointText(settings, field, maximum), 1133, 9, 116, 44, false, root, 25)
    minimumLabel:SetJustification(2)
    maximumLabel:SetJustification(0)
    local points = screen:text("", 1258, 7, 205, 48, true, root, 27)
    art(screen, root, stockTexture(screen, BAR), TRACK_X, 27, WIDTH, 6)
    local normal, hover = stockTexture(screen, THUMB), stockTexture(screen, HOVER)
    local thumb = art(screen, root, normal, TRACK_X, 6, HANDLE, HANDLE)

    -- Use the native Slider for capture and drag, with the game's own
    -- settings track and handle brushes laid over its visible bounds.
    local input = screen:make("Slider")
    local transparent = { R = 1, G = 1, B = 1, A = 0 }
    input:SetVisibility(0)
    input:SetSliderBarColor(transparent)
    input:SetSliderHandleColor(transparent)
    input.IndentHandle = false
    input.IsFocusable = false
    input.MouseUsesStep = true
    input:SetStepSize(1 / math.max(1, span))
    input:SetIsEnabled(span > 0)
    screen:place(input, TRACK_X, 4, WIDTH, 52, root)
    local self = setmetatable({ root = root, input = input, label = label, points = points,
        minimumLabel = minimumLabel, maximumLabel = maximumLabel, maximum = maximum, span = span,
        thumb = thumb, normal = normal, hover = hover, field = field, settings = settings }, Slider)
    self:refresh(false)
    return self
end

function Slider:tickX(value) return TRACK_X + WIDTH * (value - self.field.min) / math.max(1, self.span) end

function Slider:refresh(selected)
    local field, settings = self.field, self.settings
    local value = math.max(field.min, math.min(self.maximum, Custom.value(settings, field)))
    if value ~= self.shown then
        self.input:SetValue((value - field.min) / math.max(1, self.span))
        self.thumb.Slot:SetPosition({ X = self:tickX(value) - HANDLE / 2, Y = 6 })
        self.shown = value
    end
    local caption = Custom.valueText(settings, field)
    if caption ~= self.caption then self.points:SetText(FText(caption)); self.caption = caption end
    local active = selected or self.input:IsHovered()
    if active ~= self.active then
        local color = { SpecifiedColor = { R = 1, G = active and .83 or .93, B = active and .56 or .83, A = 1 }, ColorUseRule = 0 }
        self.label:OverrideTextColor(color)
        self.points:OverrideTextColor(color)
        self.thumb:SetBrushFromTexture(active and self.hover or self.normal, false)
        self.active = active
    end
end

function Slider:read()
    if self.span == 0 then return false end
    local field = self.field
    local position = self.input:GetValue()
    local value = field.min + math.floor(position * self.span + .5)
    if value == self.shown then return false end
    Custom.set(self.settings, field, math.max(field.min, math.min(self.maximum, value)))
    return true
end

function Slider:change(delta)
    if self.span == 0 then return end
    local field, settings = self.field, self.settings
    local value = math.max(field.min, math.min(self.maximum, Custom.value(settings, field) + delta))
    Custom.set(settings, field, value)
end

function Slider:follow()
    if self.span == 0 then return end
    local field, settings = self.field, self.settings
    if field.skill or settings.customPlayer.values[field.id] ~= nil then
        Custom.restore(settings, field)
    else
        Custom.set(settings, field, math.max(field.min, math.min(self.maximum, Custom.value(settings, field))))
    end
end

return Slider
