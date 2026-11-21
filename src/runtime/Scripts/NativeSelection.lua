-- Shared two-column presentation for title, bell and result target selection.
-- The model and its original CommonUI confirmation remain the owners of actions.
local Screen = require("NativeScreen")
local Form = require("ParameterForm")
local Art = require("ArtAssets")
local Profile = require("PlayerProfile")
local Portraits = require("PortraitLayout")
local Custom = require("CustomChallenges")
local Music = require("BattleMusic")
local Pressure = require("PressureControls")
local Hint = require("InputActionHint")
local Selection, View = {}, {}
View.__index = View
local MUSIC_ROW, COUNT_ROW = 8, 9
local function valid(value) return value and type(value.IsValid) == "function" and value:IsValid() end
local function focusedMusic(form) return form.selected == MUSIC_ROW and (not form.gamepadMode or form.region == 3) end

local function shortcutKey(form)
    if not form.gamepadMode then return "F" end
    if not valid(form.commonInput) then return "Y / △" end
    local ok, family = pcall(function()
        local value = form.commonInput:GetCurrentGamepadName()
        return type(value) == "string" and value or value:ToString()
    end)
    if not ok then return "Y / △" end
    if family == "PS5" or family == "PS4" then return "△" end
    if family == "NS" then return "X" end
    return "Y"
end

function View:stopPreview()
    if self.preview then self.preview:close(); self.preview = nil end
end

function View:refreshShortcut(form)
    local id = self.model.settings.musicId
    if self.preview and self.preview.track ~= id then self:stopPreview() end
    local label
    if Pressure.focused(form) then label = "切换压力模式"
    elseif focusedMusic(form) and Music.canPreview(id) then label = self.preview and "停止试听" or "试听" end
    if label and not self.nativeShortcutHint then label = shortcutKey(form) .. "  " .. label end
    if self.shortcutLabel == label then return end
    self.shortcutLabel = label
    self.shortcutHint:SetVisibility(label and 3 or 1)
    if not label then return end
    if self.nativeShortcutHint then Hint.setText(self.shortcutHint, label)
    else self.shortcutHint:SetText(FText(label)) end
end

function View:updateShortcut(gameplay)
    local form, modal, controller = self.form, self.form.modal, self.form.controller
    if not modal:HasUserFocus(controller) and not modal:HasUserFocusedDescendants(controller) then
        self.shortcutHeld = true
        self:stopPreview()
        return
    end
    if self.preview and not self.preview:update(gameplay:GetRealTimeSeconds(modal)) then self.preview = nil end
    local down = form.router:IsUIKeyHeld({ KeyName = FName("F") })
        or form.router:IsUIKeyHeld({ KeyName = FName("Gamepad_FaceButton_Top") })
    local pressed = down and not self.shortcutHeld
    self.shortcutHeld = down
    local id = self.model.settings.musicId
    if pressed and Pressure.focused(form) then Pressure.activate(form)
    elseif pressed and focusedMusic(form) and Music.canPreview(id) then
        if self.preview then self:stopPreview()
        else
            local ok, preview, reason = pcall(Music.preview, gameplay, modal, id)
            if ok and preview then self.preview = preview
            else print("[PBZArenaMusic] 试听失败 " .. tostring(reason or preview) .. "\n") end
        end
    end
    self:refreshShortcut(form)
end

function View:refresh(form)
    local settings = self.model.settings
    local custom = self.model.isCustom and self.model:isCustom() or false
    local count = custom and self.model:customCount() or 0
    local pressure = settings.customPressure ~= nil
    local layout = tostring(settings.category) .. "|" .. count .. "|" .. tostring(pressure)
    if self.layout ~= layout then
        local group = custom and { 3, COUNT_ROW } or { 3, 4, 5, 6 }
        if custom then
            for index = 1, count do group[#group + 1] = COUNT_ROW + index end
            group[#group + 1], group[#group + 2] = 5, 6
        end
        if pressure then
            group[#group + 1], group[#group + 2] = Pressure.sliderIndex, Pressure.modeIndex
        end
        form.groups[2] = group
        if form.region == 2 then
            local found = false; for _, index in ipairs(group) do if index == form.selected then found = true end end
            if not found then form.selected = custom and COUNT_ROW or 3 end
        end
        for index, widget in ipairs(form.widgets) do
            if index >= Pressure.sliderIndex then
                local modeButton = index == Pressure.modeIndex
                widget.root:SetVisibility(pressure and (modeButton and 0 or 4) or 1)
                widget.root.Slot:SetPosition({ X = modeButton and 618 or 40, Y = custom and 665 or 700 })
                widget.root.Slot:SetSize({ X = modeButton and 167 or 565, Y = 50 })
            else
                local visible = index <= MUSIC_ROW and (not custom or index ~= 4)
                    or custom and index >= COUNT_ROW and index <= COUNT_ROW + count
                widget.root:SetVisibility(visible and 4 or 1)
            end
            if index > 2 and index ~= 7 and index ~= MUSIC_ROW and index < Pressure.sliderIndex then
                local y, height = 430 + (index - 3) * 80, 76
                if custom then
                    local position = index == 3 and 0 or index == COUNT_ROW and 1
                        or index > COUNT_ROW and index - COUNT_ROW + 1 or index == 5 and 7 or 8
                    y, height = 175 + position * 60, 60
                end
                widget.root.Slot:SetPosition({ X = 40, Y = y - (pressure and 52 or 0) })
                widget.root.Slot:SetSize({ X = 745, Y = height })
                if index > COUNT_ROW then widget.label:SetText(FText((settings.category == "custom_gauntlet" and "第 " or "目标 ")
                    .. (index - COUNT_ROW) .. (settings.category == "custom_gauntlet" and " 战" or ""))) end
            end
        end
        self.layout = layout
    end
    if self.customNote then
        self.customNote:SetVisibility(custom and 3 or 1)
        self.customNote:SetText(FText(Custom.notice() or (settings.category == "custom_gauntlet"
            and "按列表顺序逐个出战 · 进入时保存" or "列表目标同时出战 · 进入时保存")))
    end
    local signature = tostring(settings.playerCycle) .. "|" .. tostring(settings.encounterId) .. "|" .. tostring(pressure)
    if signature ~= self.signature then
        if valid(self.playerArt) then self.playerArt:RemoveFromParent() end
        if self.enemyArt then self.enemyArt:close() end
        local texture, meta = Art.soul(self.screen.modal, settings.playerCycle)
        self.playerArt = self.screen:image(texture, meta, 100, 165, 780, 450)
        self.enemyArt = Portraits.open(self.screen, self.screen.modal, settings.encounterId,
            "chest", { x = 1040, y = 160, w = 760, h = (custom and 150 or 420) - (pressure and 52 or 0) })
        self.signature = signature
    end
    self.playerNote:SetText(FText(settings.playerCycle == -1 and "武器 1 级　·　未铸魂　·　饰品、药品未强化"
        or "武器等级 " .. Profile.weaponLevel(settings.playerCycle) .. "　·　全装备"))
    local gamepad = form.gamepadMode == true
    self.playerCanvas:SetRenderOpacity(gamepad and form.region ~= 1 and .56 or 1)
    self.enemyCanvas:SetRenderOpacity(gamepad and form.region ~= 2 and .56 or 1)
    self.sceneCanvas:SetRenderOpacity(gamepad and form.region ~= 3 and .56 or 1)
    if valid(self.playerArt) then self.playerArt:SetRenderOpacity(gamepad and form.region ~= 1 and .56 or 1) end
    if self.enemyArt then self.enemyArt:updateOpacity(gamepad and form.region ~= 2 and .56 or 1) end
    self.screen.enterCaption:SetText(FText("进入场地"))
    self.screen.enterButton:SetIsFocusable(gamepad and form.region == 4)
    self.screen.selectedButton = gamepad and form.region == 4 and 1 or nil
    self:refreshShortcut(form)
end
function View:confirm()
    if not self.form:advanceConfirm() then return false end
    self:stopPreview()
    return true
end
function View:back() self:stopPreview(); return self.form:back() end
function View:canConfirm() return self.form:canConfirm() end

function View:update(gameplay)
    if self.closed then return false end
    if not self.form:update(gameplay) then self:close(); return false end
    if not self.screen:update() then self:close(); return false end
    self:updateShortcut(gameplay)
    return true
end
function View:close()
    if self.closed then return end
    self.closed = true
    self:stopPreview()
    self.model.region = self.form and self.form.region or self.model.region
    if self.enemyArt then self.enemyArt:close(); self.enemyArt = nil end
    if self.form then self.form:close() end
    if self.screen then self.screen:close() end
end
function Selection.open(model, modal, description, controller, confirm, options)
    options = options or {}
    local self = setmetatable({ model = model, shortcutHeld = true }, View)
    local ok, failure = pcall(function()
        self.screen = Screen.open(modal, controller, { title = options.title
            or (model.settings.mode == "practice" and "练习模式" or "挑战模式") })
        self.playerCanvas = self.screen:panel(70, 145, 825, 750)
        self.enemyCanvas = self.screen:panel(1010, 145, 825, 750)
        self.sceneCanvas = self.screen:panel(587.5, 888, 745, 120)
        self.playerNote = self.screen:text("", 120, 805, 730, 40, false)
        self.customNote = self.screen:text("", 1050, 865, 745, 28, false, nil, 20)
        self.shortcutHint = Hint.create(self.screen, "GenericFaceButtonTop", "", 1575, 1025, 260, 42)
        self.nativeShortcutHint = self.shortcutHint ~= nil
        if not self.nativeShortcutHint then
            self.shortcutHint = self.screen:text("", 1575, 1025, 260, 42, false, nil, 24)
            self.shortcutHint:SetJustification(2)
        end
        self.shortcutHint:SetVisibility(1)
        self.screen:setFooter(function()
            local enter = self.screen.enterButton
            local nativeConfirm = self.form:syncInputMode() and (self.form:isConfirmHeld()
                or enter:HasUserFocus(controller) or enter:HasUserFocusedDescendants(controller))
            if nativeConfirm and self.form.region ~= 4 then return end
            if not nativeConfirm then self.form.gamepadMode = false end
            if self.form:canConfirm() then
                self:stopPreview()
                if options.onConfirm then options.onConfirm() else model.pendingAction = "confirm" end
            end
        end, function()
            self:stopPreview()
            self.form.gamepadMode = false
            if options.onBack then options.onBack() else model.pendingAction = "back" end
        end)
        self.screen.enterButton.Slot:SetPosition({ X = 700, Y = 1015 })
        self.screen.enterButton.Slot:SetSize({ X = 300, Y = 60 })
        self.screen.backButton.Slot:SetPosition({ X = 1030, Y = 1015 })
        self.screen.backButton.Slot:SetSize({ X = 210, Y = 60 })
        self.form = Form.open(modal, description, controller, confirm, model.screenRows, {
            host = self.screen.canvas, flat = true, groups = { { 1, 2 }, { 3, 4, 5, 6 }, { 7, MUSIC_ROW }, {} },
            region = model.region or 1,
            readInputs = model.screenRows[Pressure.sliderIndex] and Pressure.read,
            widget = function(index) return Pressure.widget(self.screen, index) end,
            navigationButtons = { self.screen.enterButton },
            focusForRegion = function(form)
                return form.gamepadMode and form.region == 4 and self.screen.enterButton or confirm
            end,
            mountRow = function(index, widget)
                if index == 7 or index == MUSIC_ROW then
                    self.screen:place(widget, 0, index == 7 and 0 or 60, 745, 58, self.sceneCanvas)
                elseif index <= 2 then
                    self.screen:place(widget, 40, 470 + (index - 1) * 80, 745, 78, self.playerCanvas)
                else self.screen:place(widget, 40, 430 + (index - 3) * 80, 745, 76, self.enemyCanvas) end
            end,
            onRefresh = function(form) self:refresh(form) end,
        })
        self:refresh(self.form)
    end)
    if not ok then self:close(); error(failure, 0) end
    return self
end
return Selection
