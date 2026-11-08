-- Shared two-column presentation for title, bell and result target selection.
-- The model and its original CommonUI confirmation remain the owners of actions.
local Screen = require("NativeScreen")
local Form = require("ParameterForm")
local Art = require("ArtAssets")
local Profile = require("PlayerProfile")
local Portraits = require("PortraitLayout")
local Selection, View = {}, {}
View.__index = View
local function valid(value) return value and type(value.IsValid) == "function" and value:IsValid() end
function View:refresh(form)
    local settings = self.model.settings
    local signature = tostring(settings.playerCycle) .. "|" .. tostring(settings.encounterId)
    if signature ~= self.signature then
        if valid(self.playerArt) then self.playerArt:RemoveFromParent() end
        if self.enemyArt then self.enemyArt:close() end
        local texture, meta = Art.soul(self.screen.modal, settings.playerCycle)
        self.playerArt = self.screen:image(texture, meta, 100, 165, 780, 450)
        self.enemyArt = Portraits.open(self.screen, self.screen.modal, settings.encounterId,
            "chest", { x = 1040, y = 160, w = 760, h = 420 })
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
