local Screen = require("NativeScreen")
local Art = require("ArtAssets")
local Spawn = require("CombatSpawn")

local View = {}
View.__index = View
local Floor = {}
Floor.__index = Floor
local INK = "/Game/PBZContent/UI/InGame/SaveLoad/T_Save_InkBar_Default.T_Save_InkBar_Default"
local RULE = "/Game/PBZContent/UI/Foundation/Dialogs/T_ConfirmationLine.T_ConfirmationLine"
local FONT = "/Game/PBZContent/UI/Fonts/ZH_ZiKuTangKuangShanKaiShuJF_Font.ZH_ZiKuTangKuangShanKaiShuJF_Font"
local GAMEPLAY = "/Script/Engine.Default__GameplayStatics"
local RENDERING = "/Script/Engine.Default__KismetRenderingLibrary"
local RANK_IMAGES = {
    ["甲"] = "BloodyPalaceRankJia.png",
    ["乙"] = "BloodyPalaceRankYi.png",
    ["丙"] = "BloodyPalaceRankBing.png",
    ["丁"] = "BloodyPalaceRankDing.png",
    ["戊"] = "BloodyPalaceRankWu.png",
}
local PAINT = { R = 1, G = 1, B = 1, A = 1 }
local IVORY = { R = .98, G = .94, B = .86, A = 1 }
local GOLD = { R = 1, G = .82, B = .53, A = 1 }
local SHADOW = { R = .035, G = .011, B = .006, A = .94 }
local FLOOR_BUTTON_INK = { SpecifiedColor = { R = 0, G = 0, B = 0, A = 1 }, ColorUseRule = 0 }
local RANK_START, RANK_LAND, RANK_SETTLED = .055, .25, .48
local ROW_START, ROW_SPACING, VALUE_DELAY = .41, .26, .10
local FOOTER_START, INTRO_END, EXIT_DURATION = 1.54, 1.78, .34
local FRAME_FALLBACK_AFTER = .18

local function valid(object) return object and type(object.IsValid) == "function" and object:IsValid() end

local function log(message) print("[PBZDreamPalaceUI] settlement " .. message .. "\n") end

local function fraction(elapsed, start, duration)
    return math.max(0, math.min(1, (elapsed - start) / duration))
end

local function smooth(t) return t * t * (3 - 2 * t) end

local function slide(track, t, x, y)
    if t == track.progress then return end
    track.progress = t
    local offset = (1 - t)^3
    track.widget:SetRenderTranslation({ X = x * offset, Y = y * offset })
    track.widget:SetRenderOpacity(smooth(t))
end

local function displayText(screen, face, parent, text, size, color, x, y, width, height, center)
    -- The localized CommonUI widget refreshes its own style on the first Slate
    -- pass. An ordinary TextBlock can keep the native face at a display size.
    local widget = screen:make("TextBlock")
    widget:SetVisibility(3)
    local font = widget.Font
    font.FontObject, font.TypefaceFontName, font.Size = face, FName("Default"), size
    font.LetterSpacing = 0
    widget:SetFont(font)
    widget:SetText(FText(text))
    widget:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 })
    widget:SetShadowColorAndOpacity(SHADOW)
    widget:SetShadowOffset(center and { X = 13, Y = 20 } or { X = 3, Y = 5 })
    if center then widget:SetJustification(1) end
    return screen:place(widget, x, y, width, height, parent)
end

local function brush(screen, parent, texture, x, y, width, height, tint)
    if not valid(texture) then return screen:shade(x, y, width, height, tint.A, parent) end
    local image = screen:make("Image")
    image:SetVisibility(3)
    image:SetBrushFromTexture(texture, false)
    image:SetColorAndOpacity(tint)
    screen:place(image, x, y, width, height, parent).Slot:SetZOrder(5)
    return image
end

function Floor:accept()
    if self.closed or not self.ready or self.accepted then return end
    self.accepted = true
    self.onConfirm()
end

function Floor:applyCaptionColor()
    local caption = self.buttonCaption
    if not valid(caption) then return end
    -- The native focus and hover states can reapply the caption's own style.
    local color = caption.ColorAndOpacity
    local rgba = color.SpecifiedColor
    if color.ColorUseRule ~= 0 or rgba.R ~= 0 or rgba.G ~= 0 or rgba.B ~= 0 or rgba.A ~= 1 then
        caption:SetColorAndOpacity(FLOOR_BUTTON_INK)
    end
end

function Floor:update(input)
    if self.closed or not valid(self.modal) or not self.modal:IsActivated()
        or self.screen.closed then return false end
    if not self.arrived then
        local elapsed = self.gameplay:GetRealTimeSeconds(self.controller) - self.startedAt
        self.arrived = self.hud.advanceFloorResult(self.panel, elapsed, true)
        if self.arrived then
            self.button:SetIsEnabled(true)
            self.button:SetFocus()
        end
    end
    self:applyCaptionColor()
    -- Discard a press that started before the button could take input.
    self.ready = self.arrived and not (input and input.release)
end

function Floor:close()
    if self.closed then return end
    self.closed = true
    local layout = self.footerLayout
    if layout and valid(layout.widget) and valid(layout.parent) then
        local ok, reason = pcall(function()
            local current = layout.widget:GetParent()
            if not valid(current) or current:GetAddress() ~= layout.parent:GetAddress() then
                layout.widget:RemoveFromParent()
                local slot = layout.parent:AddChildToVerticalBox(layout.widget)
                assert(valid(slot), "无法还原原版确认按钮容器")
                slot:SetPadding(layout.padding)
                slot:SetSize(layout.size)
                slot:SetHorizontalAlignment(layout.horizontal)
                slot:SetVerticalAlignment(layout.vertical)
            end
        end)
        if not ok then log("native floor button restore: " .. tostring(reason)) end
    end
    if valid(self.button) then
        pcall(function()
            if self.focusGlyph then self.button:SetSettingsConfirmationFocusGlyphEnabled(false) end
            self.button:SetIsEnabled(true)
        end)
    end
    if valid(self.buttonCaption) then
        pcall(self.buttonCaption.SetColorAndOpacity, self.buttonCaption, self.originalCaptionColor)
    end
    self.screen:close()
end

function View.openFloor(modal, controller, result, button, onConfirm)
    local screen = Screen.open(modal, controller, { transparent = true })
    local self = setmetatable({ screen = screen, modal = modal, controller = controller,
        button = button, onConfirm = onConfirm }, Floor)
    local ok, failure = pcall(function()
        self.gameplay = assert(StaticFindObject(GAMEPLAY), "找不到层结算时钟")
        self.hud = require("DreamPalaceCombatHud")
        self.panel = self.hud.mountFloorResult(screen.canvas, true)
        self.hud.setFloorResult(self.panel, result)
        self.hud.advanceFloorResult(self.panel, 0, true)
        -- Keep the dialog's DynamicEntryBox, pooled button, focus, input
        -- action and delegates together when moving the container.
        local footer = modal.EntryBox_Buttons
        assert(valid(footer) and valid(button), "原版确认按钮未就绪")
        local parent, original = footer:GetParent(), footer.Slot
        assert(valid(parent) and valid(original), "原版确认按钮容器不是纵向布局")
        local last = parent:GetChildAt(parent:GetChildrenCount() - 1)
        assert(valid(last) and last:GetAddress() == footer:GetAddress(), "原版确认按钮容器顺序异常")
        local padding, size = original.Padding, original.Size
        self.footerLayout = { widget = footer, parent = parent,
            padding = { Left = padding.Left, Top = padding.Top, Right = padding.Right, Bottom = padding.Bottom },
            size = { SizeRule = size.SizeRule, Value = size.Value },
            horizontal = original.HorizontalAlignment, vertical = original.VerticalAlignment }
        self.panel.widget:SetVisibility(4)
        local buttonBox = screen:make("SizeBox")
        screen:place(buttonBox, 0, 0, 0, 0, self.panel.widget)
        local slot = buttonBox.Slot
        assert(valid(slot), "无法挂载原版确认按钮")
        slot:SetAlignment({ X = 1, Y = .5 })
        slot:SetPosition({ X = 829, Y = 366 })
        slot:SetAutoSize(true)
        footer:RemoveFromParent()
        buttonBox:SetContent(footer)
        local caption = button.ButtonTextBlock
        local color = valid(caption) and caption.ColorAndOpacity
        if color then
            local rgba = color.SpecifiedColor
            self.buttonCaption = caption
            self.originalCaptionColor = { ColorUseRule = color.ColorUseRule,
                SpecifiedColor = { R = rgba.R, G = rgba.G, B = rgba.B, A = rgba.A } }
        end
        self.focusGlyph = pcall(function() button:SetSettingsConfirmationFocusGlyphEnabled(true) end)
        button:SetIsEnabled(false)
        self:applyCaptionColor()
        self.startedAt = self.gameplay:GetRealTimeSeconds(controller)
    end)
    if not ok then self:close(); error(failure, 0) end
    return self
end

local function equipmentRow(screen, data, face, y, groups)
    local canvas = screen:panel(132, y, 960, 128)
    local size, spacing = 82, 138
    for _, group in ipairs(groups) do
        displayText(screen, face, canvas, group.label, 26, IVORY, group.x, 0, 230, 37)
        local items = data and data[group.id]
        for index = 1, group.count do
            local x = group.x + (index - 1) * spacing
            local rim = screen:shade(x, 40, size, size, .82, canvas)
            rim:SetBrushColor({ R = .29, G = .22, B = .19, A = .65 })
            rim.Slot:SetZOrder(3)
            screen:shade(x + 1, 41, size - 2, size - 2, .82, canvas).Slot:SetZOrder(4)
            local item = items and items[index]
            if item and not item.empty and item.id and item.id ~= "None" then
                local texture, meta = Art.equipment(screen.modal, item.kind, item.id, item.level, item)
                if valid(texture) then
                    screen:image(texture, meta, x + 6, 46, size - 12, size - 12, canvas)
                else
                    local name = displayText(screen, face, canvas, item.name or item.id, 16,
                        IVORY, x + 5, 50, size - 10, 54, true)
                    name:SetAutoWrapText(true)
                end
                if type(item.level) == "number" then
                    local enhanced = item.kind == "medicine" or item.kind == "accessory"
                    local level = (enhanced and "+" or "") .. tostring(item.level)
                    displayText(screen, face, canvas, level, 21, GOLD, x + 7, 95, size - 14, 28)
                end
            end
        end
    end
    return { widget = canvas }
end

local function rankTexture(context, rank)
    local filename = RANK_IMAGES[rank]
    if not filename then return end
    local ok, texture = pcall(function()
        local directory = assert(debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]+$"), "结算贴图目录不可用")
        local renderer = StaticFindObject(RENDERING)
        assert(valid(renderer), "结算贴图导入接口不可用")
        local image = renderer:ImportFileAsTexture2D(context, directory .. "/" .. filename)
        assert(valid(image) and image:Blueprint_GetSizeX() == image:Blueprint_GetSizeY(), "结算评级贴图不可用")
        return image
    end)
    if ok then return texture end
    log(filename .. " unavailable: " .. tostring(texture))
end

function View:mount(report, exitLabel)
    local screen, modal = self.screen, self.modal
    local fullClear = report.fullClear == true
    local face = Spawn.class(FONT)
    local line, ink = Art.texture(modal, RULE), Art.texture(modal, INK)
    local heading = screen:panel(132, 57, 960, 260)
    displayText(screen, face, heading, "结算", 108, IVORY, 0, 0, 580, 170)
    brush(screen, heading, line, 4, 171, 640, 5, { R = .91, G = .57, B = .38, A = .94 })
    local subtitle = report.failure and ("浊梦 · " .. report.failure) or "浊梦"
    displayText(screen, face, heading, subtitle, 48, GOLD, 5, 184, 760, 76)
    self.heading = { widget = heading }

    local function label(text, x, y, width, height, size, color, parent, right)
        local widget = screen:text(text, x, y, width, height, not right, parent, size)
        widget:OverrideTextColor({ SpecifiedColor = color, ColorUseRule = 0 })
        widget:SetShadowColorAndOpacity(SHADOW)
        widget:SetShadowOffset({ X = 2, Y = 3 })
        if right then widget:SetJustification(2) end
        return widget
    end
    local rows = {
        { "完成时间", report.time },
        { "结算时间", report.remaining },
        { "职阶", report.tierName or "—" },
        { report.warmupFloor and "热身楼层" or "通关层数", tostring(report.warmupFloor or report.cleared) },
    }
    for index, row in ipairs(rows) do
        local y = fullClear and (308 + (index - 1) * 78) or (343 + (index - 1) * 106)
        local height = fullClear and 65 or 86
        local textTop = fullClear and 7 or 17
        local panel = screen:panel(132, y, 960, height)
        brush(screen, panel, ink, 0, 0, 960, height, { R = 1, G = 1, B = 1, A = .86 })
        label(row[1], 37, textTop, 225, 54, 33, IVORY, panel)
        local value = label(row[2], 275, textTop, 634, 54, 36, GOLD, panel, true)
        self.rows[index] = { widget = panel, value = { widget = value }, start = ROW_START + (index - 1) * ROW_SPACING }
    end
    if fullClear then
        self.loadout = {
            equipmentRow(screen, report.loadout, face, 620, {
                { label = "武器", id = "mainWeapons", x = 0, count = 2 },
                { label = "影之武装", id = "shadowWeapons", x = 276, count = 2 },
                { label = "药品", id = "medicines", x = 552, count = 2 },
            }),
            equipmentRow(screen, report.loadout, face, 754, {
                { label = "首饰", id = "accessories", x = 0, count = 6 },
            }),
        }
    end

    local grade = screen:panel(1152, 203, 676, 676)
    grade:SetRenderTransformPivot({ X = .5, Y = .5 })
    self.grade = grade
    local texture = rankTexture(modal, report.rank)
    if valid(texture) then
        brush(screen, grade, texture, 0, 0, 676, 676, PAINT)
    else
        displayText(screen, face, grade, report.rank, 385, GOLD, 0, 12, 676, 660, true)
    end
    local footer = screen:panel(132, fullClear and 924 or 826, 960, 74)
    footer:SetVisibility(3)
    self.footer = { widget = footer }
    if fullClear or report.failure then
        screen:button(exitLabel, 0, 0, 300, 74, function() self:requestExit("arena") end, footer)
        screen:button("返回主菜单", 660, 0, 300, 74, function() self:requestExit("title") end, footer)
    else
        screen:button(exitLabel, 39, 0, 350, 74, function() self:requestExit("title") end, footer)
    end
    screen.selectedButton = 1

    self.blur, self.shade = screen.blur, screen.blur:GetContent()
    self.blur:SetApplyAlphaToBlur(true)
    self.blur:SetRenderOpacity(0)
end

function View:advanceRank(elapsed)
    if self.rankSettled then return end
    local approach = (1 - fraction(elapsed, RANK_START, RANK_LAND - RANK_START))^3
    local settle = fraction(elapsed, RANK_LAND, RANK_SETTLED - RANK_LAND)
    local recoil = math.sin(math.pi * settle) * (1 - settle)
    local scale = 1 + .16 * approach - .04 * recoil
    self.grade:SetRenderScale({ X = scale, Y = scale })
    self.grade:SetRenderTranslation({ X = 56 * approach, Y = -18 * approach + 9 * recoil })
    self.grade:SetRenderOpacity(smooth(fraction(elapsed, RANK_START, .14)))
    self.rankSettled = settle >= 1
end

function View:advanceIntro(elapsed)
    if not self.blurReady then
        local blur = smooth(fraction(elapsed, 0, .45))
        self.blur:SetRenderOpacity(blur)
        self.blurReady = blur >= 1
    end
    self:advanceRank(elapsed)
    slide(self.heading, fraction(elapsed, .29, .34), -54, 0)
    for _, row in ipairs(self.rows) do
        slide(row, fraction(elapsed, row.start, .24), -64, 0)
        slide(row.value, fraction(elapsed, row.start + VALUE_DELAY, .23), 25, 0)
    end
    for index, row in ipairs(self.loadout or {}) do
        slide(row, fraction(elapsed, 1.40 + (index - 1) * .10, .24), -36, 0)
    end
    slide(self.footer, fraction(elapsed, FOOTER_START, INTRO_END - FOOTER_START), 0, 12)
    if elapsed >= INTRO_END then
        self.entered = true
        self.footer.widget:SetVisibility(4)
        self:stopFrames()
    end
end

function View:stopFrames()
    local handle = self.frameAction
    self.frameAction = nil
    if handle then pcall(CancelDelayedAction, handle) end
end

function View:finishExit()
    if self.finished then return end
    self.finished = true
    self:stopFrames()
    self.onExit(self.destination)
end

function View:advance()
    local now = self.gameplay:GetRealTimeSeconds(self.controller)
    self.lastAdvanceAt = now
    if self.exitAt then
        if self.exitCovered then self:finishExit(); return end
        local fade = smooth(fraction(now, self.exitAt, EXIT_DURATION))
        local rest = 1 - fade
        self.screen.root:SetRenderOpacity(rest)
        self.shade:SetBrushColor({ R = .020 * rest, G = .012 * rest, B = .017 * rest, A = .22 + .78 * fade })
        -- Give black a rendered frame. Keep it in place until the arena exits.
        self.exitCovered = fade >= 1
    elseif not self.entered then
        self:advanceIntro(math.max(0, now - self.start))
    end
end

function View:frame()
    if self.closed or not valid(self.controller) or not valid(self.modal) or not self.modal:IsActivated() then
        self:stopFrames()
        return
    end
    local ok, reason = pcall(self.advance, self)
    if ok then return end
    log("animation fallback: " .. tostring(reason))
    if self.exitAt then self:finishExit() else self:close() end
end

function View:startFrames()
    if self.frameAction or type(CancelDelayedAction) ~= "function" then return end
    local function tick()
        if self.frameAction then self:frame() end
    end
    local ok, handle
    if EngineTickAvailable and type(LoopInGameThreadAfterFrames) == "function" then
        ok, handle = pcall(LoopInGameThreadAfterFrames, 1, tick)
    end
    if not (ok and type(handle) == "number" and handle > 0) and type(LoopInGameThreadWithDelay) == "function" then
        ok, handle = pcall(LoopInGameThreadWithDelay, 16, tick)
    end
    if ok and type(handle) == "number" and handle > 0 then self.frameAction = handle end
end

function View:requestExit(destination)
    if self.exitAt or self.finished then return end
    if not (self.entered or self.closed) then return end
    self.destination = destination
    if self.closed then self:finishExit(); return end
    self.exitAt = self.gameplay:GetRealTimeSeconds(self.controller)
    self.lastAdvanceAt = self.exitAt
    self.footer.widget:SetVisibility(3)
    self:startFrames()
end

function View:update(input)
    if self.closed or self.finished then return end
    if not self.entered or self.exitAt then
        if not self.frameAction or self.gameplay:GetRealTimeSeconds(self.controller) - self.lastAdvanceAt > FRAME_FALLBACK_AFTER then
            self:frame()
        end
    end
    if self.entered and not self.exitAt then
        if input then self.screen.selectedButton = input.selected end
        self.screen:update()
    end
end

function View:close()
    if self.closed then return end
    self.closed = true
    self:stopFrames()
    self.screen:close()
end

function View.open(modal, controller, report, exitLabel, onExit, endingTitle)
    local options = { blurStrength = 16 }
    if report.failure then
        options.mountBackdrop = require("DreamPalaceFailureScreen").backdrop
    elseif endingTitle then
        options.mountBackdrop = function(root)
            return require("BloodyPalaceEndingTitle").placeBehindBlur(endingTitle, root)
        end
    end
    local screen = Screen.open(modal, controller, options)
    local self = setmetatable({ screen = screen, modal = modal, controller = controller, onExit = onExit,
        rows = {} }, View)
    local ok, reason = pcall(function()
        self.gameplay = assert(StaticFindObject(GAMEPLAY), "找不到结算实时时钟")
        self:mount(report, exitLabel)
        self.start = self.gameplay:GetRealTimeSeconds(controller)
        self.lastAdvanceAt = self.start
        self:advanceIntro(0)
        self:startFrames()
    end)
    if not ok then self:close(); error(reason, 0) end
    return self
end

return View
