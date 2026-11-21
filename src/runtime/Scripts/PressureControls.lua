local Difficulty = require("GameplayDifficulty")
local Feedback = require("ParameterFeedback")
local Style = require("ParameterStyle")
local Controls = { sliderIndex = 15, modeIndex = 16 }

local MINIMUM, MAXIMUM = -100, 100
local SPAN = MAXIMUM - MINIMUM
local modes = { fixed = "固定", minimum = "最低" }

local function selectColor(label, active)
    label:OverrideTextColor({ SpecifiedColor = {
        R = 1, G = active and .77 or .93, B = active and .43 or .83, A = 1,
    }, ColorUseRule = 0 })
end

function Controls.add(model, pressure)
    local settings = model.settings
    local choices = Difficulty.choices
    local draft = Difficulty.copyPressure(pressure) or { mode = "fixed", value = 0 }
    settings.customPressure = pressure and draft or nil
    if pressure then settings.difficultyMode = Difficulty.customBase end
    local function enabled() return settings.customPressure ~= nil end
    local function setValue(value) draft.value = math.max(MINIMUM, math.min(MAXIMUM, value)) end
    local function toggle() draft.mode = draft.mode == "fixed" and "minimum" or "fixed" end
    model.screenRows[6] = {
        label = "难度",
        value = function() return enabled() and "自订" or choices[settings.difficultyMode].name end,
        change = function(delta)
            local choice = enabled() and #choices + 1 or settings.difficultyMode
            choice = math.max(1, math.min(#choices + 1, choice + delta))
            settings.customPressure = choice > #choices and draft or nil
            settings.difficultyMode = enabled() and Difficulty.customBase or choice
        end,
    }
    model.screenRows[Controls.sliderIndex] = {
        label = "压力值", value = function() return draft.value end, enabled = enabled,
        change = function(delta) setValue(draft.value + delta) end, setValue = setValue, repeatStep = 5,
    }
    model.screenRows[Controls.modeIndex] = {
        label = "压力模式", value = function() return modes[draft.mode] end, enabled = enabled,
        change = toggle, activate = true,
    }
end

function Controls.widget(screen, index)
    if index == Controls.modeIndex then
        local button, caption = Style.button(screen.modal, screen.controller, screen.tree, "固定")
        button:SetMinDimensions(120, 48)
        local widget = { root = button, increase = button }
        function widget:setInputMode(gamepad) self.gamepad = gamepad end
        function widget:refresh(value, selected)
            if self.value ~= value then caption:SetText(FText(value)); self.value = value end
            local active = self.gamepad and selected or button:IsHovered()
            if active ~= self.active then selectColor(caption, active); self.active = active end
        end
        return widget
    end
    if index ~= Controls.sliderIndex then return end
    local root = screen:make("CanvasPanel")
    local label = screen:text("压力值", 0, 8, 118, 40, true, root, 28)
    local value = screen:text("", 480, 8, 85, 40, false, root, 28)
    value:SetJustification(1)
    local slider = screen:make("Slider")
    slider:SetVisibility(0)
    slider.IsFocusable = false
    slider.MouseUsesStep = true
    slider:SetStepSize(1 / SPAN)
    slider:SetSliderBarColor({ R = .83, G = .79, B = .7, A = 1 })
    screen:place(slider, 120, 3, 352, 48, root)
    local widget = { root = root, slider = slider }
    function widget:setInputMode(gamepad) self.gamepad = gamepad end
    function widget:refresh(content, selected)
        local numeric = tonumber(content)
        if self.value ~= numeric then
            slider:SetValue((numeric - MINIMUM) / SPAN)
            value:SetText(FText(content))
            self.value = numeric
        end
        local active = self.gamepad and selected or slider:IsHovered()
        if active ~= self.active then
            selectColor(label, active)
            selectColor(value, active)
            self.active = active
        end
    end
    return widget
end

function Controls.read(form)
    local index = Controls.sliderIndex
    local row, widget = form.rows[index], form.widgets[index]
    if not row.enabled() then return end
    local value = MINIMUM + math.floor(widget.slider:GetValue() * SPAN + .5)
    if value ~= widget.value then
        row.setValue(value)
        form.selected, form.gamepadMode = index, false
    end
end

function Controls.focused(form)
    local index = Controls.sliderIndex
    local row = form.rows[index]
    if not row or not row.enabled() then return false end
    if form.gamepadMode then return form.region == 2 and form.selected == index end
    return form.selected == index or form.widgets[index].slider:IsHovered()
end

function Controls.activate(form)
    if not Controls.focused(form) then return false end
    form.rows[Controls.modeIndex].change(1)
    form:refresh()
    pcall(Feedback.navigate, form.controller, form.modal)
    return true
end

return Controls
