-- Shared two-column presentation for title, bell and result target selection.
-- The model and its original CommonUI confirmation remain the owners of actions.
local Screen = require("NativeScreen")
local Form = require("ParameterForm")
local Art = require("ArtAssets")
local Profile = require("PlayerProfile")
local Portraits = require("PortraitLayout")
local Custom = require("CustomChallenges")
local Selection, View = {}, {}
View.__index = View
local function valid(value) return value and type(value.IsValid) == "function" and value:IsValid() end
function View:refresh(form)
    local settings = self.model.settings
    local custom = self.model.isCustom and self.model:isCustom() or false
    local count = custom and self.model:customCount() or 0
    local layout = tostring(settings.category) .. "|" .. count
    if self.layout ~= layout then
        local group = custom and { 3, 8 } or { 3, 4, 5, 6 }
        if custom then
            for index = 1, count do group[#group + 1] = 8 + index end
            group[#group + 1], group[#group + 2] = 5, 6
        end
        form.groups[2] = group
        if form.region == 2 then
            local found = false; for _, index in ipairs(group) do if index == form.selected then found = true end end
            if not found then form.selected = custom and 8 or 3 end
        end
        for index, widget in ipairs(form.widgets) do
            local visible = index <= 7 and (not custom or index ~= 4) or custom and index >= 8 and index <= 8 + count
            widget.root:SetVisibility(visible and 4 or 1)
            if index > 2 and index ~= 7 then
                local y, height = 430 + (index - 3) * 80, 76
                if custom then
                    local position = index == 3 and 0 or index == 8 and 1 or index >= 9 and index - 7 or index == 5 and 7 or 8
                    y, height = 175 + position * 60, 60
                end
                widget.root.Slot:SetPosition({ X = 40, Y = y })
                widget.root.Slot:SetSize({ X = 745, Y = height })
                if index >= 9 then widget.label:SetText(FText((settings.category == "custom_gauntlet" and "第 " or "目标 ")
                    .. (index - 8) .. (settings.category == "custom_gauntlet" and " 战" or ""))) end
            end
        end
        self.layout = layout
    end
    if self.customNote then
        self.customNote:SetVisibility(custom and 3 or 1)
        self.customNote:SetText(FText(Custom.notice() or (settings.category == "custom_gauntlet"
            and "按列表顺序逐个出战 · 进入时保存" or "列表目标同时出战 · 进入时保存")))
    end
    local signature = tostring(settings.playerCycle) .. "|" .. tostring(settings.encounterId)
    if signature ~= self.signature then
        if valid(self.playerArt) then self.playerArt:RemoveFromParent() end
        if self.enemyArt then self.enemyArt:close() end
        local texture, meta = Art.soul(self.screen.modal, settings.playerCycle)
        self.playerArt = self.screen:image(texture, meta, 100, 165, 780, 450)
        self.enemyArt = Portraits.open(self.screen, self.screen.modal, settings.encounterId,
            "chest", { x = 1040, y = 160, w = 760, h = custom and 150 or 420 })
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
end
function View:confirm() return self.form:advanceConfirm() end
function View:back() return self.form:back() end
function View:canConfirm() return self.form:canConfirm() end
function View:update(gameplay)
    if self.closed then return false end
    if not self.form:update(gameplay) then self:close(); return false end
    if not self.screen:update() then self:close(); return false end
    return true
end
function View:close()
    if self.closed then return end
    self.closed = true
    self.model.region = self.form and self.form.region or self.model.region
    if self.enemyArt then self.enemyArt:close(); self.enemyArt = nil end
    if self.form then self.form:close() end
    if self.screen then self.screen:close() end
end
function Selection.open(model, modal, description, controller, confirm, options)
    options = options or {}
    local self = setmetatable({ model = model }, View)
    local ok, failure = pcall(function()
        self.screen = Screen.open(modal, controller, { title = options.title
            or (model.settings.mode == "practice" and "练习模式" or "挑战模式") })
        self.playerCanvas = self.screen:panel(70, 145, 825, 750)
        self.enemyCanvas = self.screen:panel(1010, 145, 825, 750)
        self.sceneCanvas = self.screen:panel(587.5, 900, 745, 78)
        self.playerNote = self.screen:text("", 120, 805, 730, 40, false)
        self.customNote = self.screen:text("", 1050, 865, 745, 28, false, nil, 20)
        self.screen:setFooter(function()
            local enter = self.screen.enterButton
            local nativeConfirm = self.form:syncInputMode() and (self.form:isConfirmHeld()
                or enter:HasUserFocus(controller) or enter:HasUserFocusedDescendants(controller))
            if nativeConfirm and self.form.region ~= 4 then return end
            if not nativeConfirm then self.form.gamepadMode = false end
            if self.form:canConfirm() then
                if options.onConfirm then options.onConfirm() else model.pendingAction = "confirm" end
            end
        end, function()
            self.form.gamepadMode = false
            if options.onBack then options.onBack() else model.pendingAction = "back" end
        end)
        self.screen.enterButton.Slot:SetPosition({ X = 700, Y = 1000 })
        self.screen.enterButton.Slot:SetSize({ X = 300, Y = 60 })
        self.screen.backButton.Slot:SetPosition({ X = 1030, Y = 1000 })
        self.screen.backButton.Slot:SetSize({ X = 210, Y = 60 })
        self.form = Form.open(modal, description, controller, confirm, model.screenRows, {
            host = self.screen.canvas, flat = true, groups = { { 1, 2 }, { 3, 4, 5, 6 }, { 7 }, {} },
            region = model.region or 1,
            navigationButtons = { self.screen.enterButton },
            focusForRegion = function(form)
                return form.gamepadMode and form.region == 4 and self.screen.enterButton or confirm
            end,
            mountRow = function(index, widget)
                if index == 7 then self.screen:place(widget, 0, 0, 745, 78, self.sceneCanvas)
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
