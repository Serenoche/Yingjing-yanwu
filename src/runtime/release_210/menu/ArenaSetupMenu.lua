local Art = require("ArtAssets")
local Encounters = require("EncounterCatalog")
local Feedback = require("ParameterFeedback")
local Hint = require("InputActionHint")
local Catalog = require("ArenaMenuCatalog")
local Music = require("BattleMusic")
local MusicPanel = require("ArenaMusicPanel")
local Portraits = require("PortraitLayout")
local Profile = require("PlayerProfile")
local Style = require("ParameterStyle")
local UI = require("DreamPalaceUI")

local Menu, View = {}, {}
View.__index = View

local SUBSYSTEMS = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local INPUT = "/Script/CommonInput.CommonInputSubsystem"
local GAMEPLAY = "/Script/Engine.Default__GameplayStatics"
local GAMEPAD = 1
local MOUSE_AND_KEYBOARD = 0
local UNIVERSAL_ACTIONS = "/Game/PBZContent/DataTable/UI/DT_PBZUniversalActions.DT_PBZUniversalActions"
local LINE = "/Game/PBZContent/UI/InGame/SaveLoad/T_SaveLoadGameLine.T_SaveLoadGameLine"
local TITLES = { character = "角色属性", target = "目标", targetChoice = "选择目标", scene = "场景", music = "音乐" }
local TYPES = { duel = "对决", gauntlet = "连战", group = "群战", custom_gauntlet = "自订连战", custom_group = "自订群战" }
local GRID_COLUMNS, GRID_STEP, GRID_TILE = 3, 137, 111
local LIST_ROW_HEIGHT = 62
local REGION_PAGES = { target = true, targetChoice = true, scene = true, music = true }
local SECTIONS = {
    { "character", "角色" }, { "target", "目标" }, { "scene", "场景" }, { "music", "音乐" },
}
local reportedIconFadeFailure

local function valid(value) return value and type(value.IsValid) == "function" and value:IsValid() end
local function required(path)
    local value = StaticFindObject(path)
    assert(valid(value), "演武菜单缺少原生接口 " .. path)
    return value
end
local function remove(widget)
    if valid(widget) then widget:RemoveFromParent() end
end
local function enabled(field)
    return field.enabled == nil or field.enabled == true or type(field.enabled) == "function" and field.enabled()
end
local function held(router, ...)
    for _, key in ipairs({ ... }) do
        if router:IsUIKeyHeld({ KeyName = FName(key) }) then return true end
    end
    return false
end
local function regionKeys(router)
    return held(router, "Q", "Gamepad_LeftTrigger"), held(router, "E", "Gamepad_RightTrigger")
end
local function regionHintRows(gamepad)
    if gamepad then return "LeftTrigger", "RightTrigger" end
    -- The stock shoulder rows supply the keyboard Q/E glyphs.
    return "LeftShoulder", "RightShoulder"
end
local function usesTargetGrid(flow)
    local category = flow.draft.settings.category
    return category ~= "gauntlet" and category ~= "group"
end
local function musicAuditionHeld(router)
    return held(router, "F", "Enter", "Gamepad_FaceButton_Top")
end
local function pageConfirmHeld(router, page)
    if page == "music" then return held(router, "SpaceBar", "Gamepad_FaceButton_Bottom") end
    return UI.confirmHeld(router)
end
local function control(widget, x, y, width, height, select)
    return { widget = widget, x = x, y = y, right = x + width, bottom = y + height,
        setSelected = select or function() end }
end
local function markSelected(entry, selected)
    entry.button:setSelected(selected)
    if entry.slotArt then entry.slotArt:SetRenderOpacity(selected and 1 or .80) end
end

function View:add(entry)
    self.named[entry.key] = entry
    if entry.nav ~= false then
        self.options[#self.options + 1] = entry
        entry.index = #self.options
    end
    if entry.pointer ~= false then self.pointers[#self.pointers + 1] = entry end
    return entry
end

function View:button(key, label, x, y, width, height, action, options)
    local entry = options or {}
    entry.key, entry.action = key, action
    entry.button = UI.button(self.screen, label, x, y, width, height,
        function() self:activate(entry) end, entry.canvas or self.layer, entry.compact ~= false,
        entry.left == true, nil, self.layer)
    return self:add(entry)
end

function View:text(value, x, y, width, height, heading, size, canvas)
    return self.screen:text(value, x, y, width, height, heading, canvas or self.layer, size)
end

function View:line(x, y, width)
    local texture = Art.texture(self.screen.modal, LINE)
    if not valid(texture) then return end
    local image = self.screen:make("Image")
    image:SetVisibility(3)
    image:SetBrushFromTexture(texture, false)
    self.screen:place(image, x, y, width, 2, self.layer).Slot:SetZOrder(11)
end

function View:focus(entry, sound)
    if not entry or entry.nav == false or self.selected == entry then return end
    if self.selected then markSelected(self.selected, false) end
    self.selected, self.flow.focus = entry, entry.key
    markSelected(entry, true)
    if entry.choose then entry.choose() end
    if self.flow.page == "target" and entry.member and entry.member ~= self.flow.member then
        self.flow:showTargets(entry.member)
        self:render()
    end
    if sound then Feedback.menuSelect(self.session.controller, self.session.modal) end
end

function View:activate(entry)
    if self.closed or self.starting or not entry then return end
    self:focus(entry, false)
    if entry.action then entry.action() end
end

function View:stopPreview()
    if self.preview then self.preview:close(); self.preview = nil end
    self.elapsed, self.nextPosition = nil, nil
end

function View:removeDetail()
    if self.portrait then self.portrait:close(); self.portrait = nil end
    remove(self.detail)
    self.detail = nil
end

function View:removeLayer()
    self:stopPreview()
    self:removeDetail()
    if not self.layer then return end
    if self.selected then markSelected(self.selected, false) end
    if self.musicContainer then self.screen:releaseButtons(self.musicContainer) end
    self.screen:releaseButtons(self.layer)
    remove(self.layer)
    self.layer, self.selected, self.musicPanel, self.musicContainer, self.choiceScroll = nil, nil, nil, nil, nil
    self.regionPreviousHint, self.regionNextHint, self.regionHintGamepad = nil, nil, nil
end

function View:back()
    if self.flow:back() and not self.targetOnly then self:render()
    else self.leave() end
end

function View:readPressure()
    local controls = self.pressureControls
    if self.flow.page == "target" and controls and self.fields[controls.sliderIndex] then
        controls.read({ rows = self.flow.draft.screenRows, widgets = self.fields })
    end
end

function View:apply()
    self:readPressure()
    if self.flow.page == "music" then
        if not self.musicPanel then return end
        print("[PBZArenaSetup] 音乐选定 " .. self.flow.picker:current().id .. "\n")
    end
    self.flow:choose()
    if self.targetOnly then
        self.starting = true
        self.start(self.flow:settings())
        return
    end
    self:render()
end

function View:enter()
    local result, reason = self.flow:enter()
    if not result then
        self.notice:SetText(FText(reason or "无法保存所选阵容，请重试"))
        return
    end
    self.starting = true
    self:stopPreview()
    self.start(result)
end

function View:drawOverview()
    local settings = self.flow.model.settings
    local training = settings.mode == "training"
    local sectionCount = training and 3 or #SECTIONS
    for index = 1, sectionCount do
        local section = SECTIONS[index]
        local x, y, width, height = UI.railPosition(index)
        self:button(section[1], section[2], x, y, width, height, function()
            self.flow:open(section[1])
            self:render()
        end, { left = true, compact = false })
    end

    local form = self.flow.model.screenRows
    local rank = form[1].value()
    local growth
    if settings.customPlayer then
        local weapon = settings.customPlayer.values.weapon or Profile.weaponLevel(settings.playerCycle)
        growth = ("技能增幅 +%d%%  ·  武器 %d 级"):format(settings.skillLevel * 2, math.max(1, weapon))
    else
        growth = settings.playerCycle == -1 and "武器 1 级 · 未铸魂"
            or "技能等级 " .. form[2].value() .. "  ·  武器等级 " .. Profile.weaponLevel(settings.playerCycle)
    end
    local rounds = "轮回 " .. form[5].value() .. "  ·  " .. form[6].value()
    local name, roster
    if training then
        local target = require("TrainingTarget")
        local mob = target.option(settings.trainingMobId)
        name, roster = mob.name, target.summary(mob)
    else
        local entry = assert(Encounters.resolve(settings.encounterId))
        local kind = assert(TYPES[entry.category])
        name = entry.name
        roster = entry.category == "duel" and kind or kind .. "  ·  "
            .. (entry.category:find("group", 1, true) and (#entry.stages[1].members .. " 名目标") or (#entry.stages .. " 战"))
    end

    UI.inkPanel(self.screen, self.layer, 1143, 241, 672, 559, .89)
    self:text("对战信息", 1168, 264, 610, 47, true, 35)
    local facts = {
        { "角色属性", rank, 332, growth }, { "目标信息", name, 432, roster or rounds, roster and rounds or nil },
        { "场地", Catalog.sceneLabel(settings), 588 },
    }
    if not training then facts[4] = { "背景音乐", Music.label(settings.musicId), 678 } end
    for _, fact in ipairs(facts) do
        local top = fact[3]
        self:line(1168, top - 10, 621)
        self:text(fact[1], 1174, top + 7, 146, 38, false, 26)
        local value = self:text(fact[2], 1331, top, 457, 59, true, 29)
        value:SetAutoWrapText(true)
        if fact[4] then self:text(fact[4], 1331, top + 48, 457, 36, false, 23) end
        if fact[5] then self:text(fact[5], 1331, top + 85, 457, 35, false, 22) end
    end
    local x, y, width, height = UI.railPosition(sectionCount + 1)
    self:button("enter", self.confirmLabel or "进入战斗", x, y, width, height, function() self:enter() end,
        { left = true, compact = false })
    self.notice = self:text("", 1143, 911, 650, 65, false, 23)
    self.notice:SetAutoWrapText(true)
end

function View:changeParameter(index, delta)
    local slider = self.customSliders[index]
    if slider then slider:change(delta); self:refreshCustomSliders(false); return end
    local model = self.flow.draft
    local field = self.fieldRows[index]
    if not enabled(field) then return end
    local filters = self.flow.trainingFilters
    local bossTarget = self.flow.page == "target" and not filters
    local category, count = model.settings.category, bossTarget and model:customCount()
    local pressure = model.settings.customPressure ~= nil
    local cycle = model.settings.playerCycle
    field.change(delta)
    if filters and index <= #filters.rows then
        self.flow:refreshTrainingTargets()
        self:render()
    elseif bossTarget and (category ~= model.settings.category or count ~= model:customCount()) then
        self.flow:showTargets(self.flow.member)
        self:render()
    elseif pressure ~= (model.settings.customPressure ~= nil) or cycle ~= model.settings.playerCycle then
        self:render()
    else self:refreshFields() end
end

function View:addField(index, x, y, width, height, passive, replacement)
    local screen = self.screen
    local field = replacement or self.flow.draft.screenRows[index]
    self.fieldRows[index] = field
    local specialized = self.pressureControls and self.pressureControls.widget(screen, index)
    local widget = specialized or Style.flatRow(screen.modal, screen.controller, screen.tree, field.label)
    self.fields[index] = widget
    screen:place(widget.root, x, y, width, height, self.layer)
    local active = not passive and enabled(field)
    for _, arrow in pairs({ widget.decrease, widget.increase }) do arrow:SetIsEnabled(active) end
    if widget.slider then widget.slider:SetIsEnabled(active) end
    if passive then widget.root:SetRenderOpacity(.60) end
    if not active then return end
    local entry = self:add({ key = "parameter-" .. index, parameter = index,
        button = control(widget.root, x, y, width, height),
        action = field.activate and function() self:changeParameter(index, 1) end or nil })
    for sign, arrow in pairs({ [-1] = widget.decrease, [1] = widget.increase }) do
        Feedback.configureArrow(arrow)
        screen:listenButton(arrow, function()
            self:focus(entry, false)
            self:changeParameter(index, sign)
        end, self.layer)
    end
end

function View:refreshFields()
    if not self.flow.draft then return end
    local gamepad = self.input:GetCurrentInputType() == GAMEPAD
    local settings = self.flow.draft.settings
    for index, widget in pairs(self.fields) do
        local field = self.fieldRows[index]
        local entry = self.selected
        local value = index == 3 and not self.flow.trainingFilters and TYPES[settings.category]
            or index == 5 and settings.enemyCycle or field.value()
        widget:setInputMode(gamepad, not gamepad)
        widget:refresh(tostring(value), entry and entry.parameter == index)
    end
end

function View:drawCharacter()
    local settings = self.flow.draft.settings
    local texture, meta = Art.soul(self.screen.modal, settings.playerCycle)
    self.screen:image(texture, meta, 100, 165, 780, 450, self.layer)
    self:addField(1, 110, 615, 745, 78)
    if not settings.customPlayer then
        self:addField(2, 110, 695, 745, 78)
        self:text(settings.playerCycle == -1 and "武器 1 级　·　未铸魂　·　饰品、药品未强化"
            or "武器等级 " .. Profile.weaponLevel(settings.playerCycle) .. "　·　全装备",
            120, 805, 730, 40, false, 25)
        return
    end
    local PlayerCustom = require("PlayerCustom")
    for index, section in ipairs(PlayerCustom.sections) do
        self:button("edit-" .. section.id, section.label, 110, 709 + (index - 1) * 76, 524, 70, function()
            self.flow:openCustom(section.id)
            self:render()
        end, { left = true, compact = false })
    end

    local x, y, width, height = 1190, 310, 524, 355
    UI.inkPanel(self.screen, self.layer, x, y, width, height, .92)
    self:text("当前属性预览", x + 34, y + 25, width - 68, 46, true, 34)
    self:line(x + 34, y + 77, width - 68)
    for index, field in ipairs(PlayerCustom.section("attributes").fields) do
        local top = y + 91 + (index - 1) * 46
        self:text(field.label, x + 34, top, 300, 39, false, 27)
        local points = self:text(tostring(PlayerCustom.value(settings, field)), x + 348, top, width - 382, 39, true, 29)
        points:SetJustification(2)
    end
end

function View:refreshCustomSliders(read)
    for index, slider in ipairs(self.customSliders) do
        if read and slider:read() then self:focus(self.named["parameter-" .. index], false) end
        slider:refresh(self.selected and self.selected.parameter == index)
    end
end

function View:drawPlayerCustom()
    local PlayerCustom = require("PlayerCustom")
    local PlayerSlider = require("PlayerCustomSlider")
    local settings = self.flow.draft.settings
    local section = PlayerCustom.section(self.flow.customSection)
    local x, first = 220, #section.fields > 3 and 221 or 265
    UI.inkPanel(self.screen, self.layer, 170, first - 42, 1580, #section.fields * 120 + 51, .88)
    for index, field in ipairs(section.fields) do
        local y = first + (index - 1) * 120
        local slider = PlayerSlider.new(self.screen, self.layer, settings, field, x, y)
        self.customSliders[index] = slider
        self:add({ key = "parameter-" .. index, parameter = index,
            button = control(slider.root, x, y, PlayerSlider.rowWidth, 69, function(selected) slider:refresh(selected) end) })
        local firstRowRight = -math.huge
        for _, tick in ipairs(PlayerCustom.ticks(settings, field)) do
            local points, caption = tick[1], tick[2]
            local center = x + slider:tickX(points)
            local width, top, height = utf8.len(caption) > 2 and 124 or 60, y + 58, 36
            if field.attribute then
                -- Life caps bunch up near the right endpoint. Stagger their
                -- captions and keep each button centered on its exact value.
                width, height = utf8.len(caption) > 1 and 86 or 42, 28
                if center - width / 2 < firstRowRight then
                    top = y + 87
                else
                    firstRowRight, top = center + width / 2, y + 56
                end
                local label = self:text(caption, center - width / 2, top, width, height, false, 22)
                label:SetJustification(1)
                label.Slot:SetZOrder(22)
                caption = ""
            end
            self:button("tick-" .. index .. "-" .. points, caption, center - width / 2, top, width, height, function()
                PlayerCustom.set(settings, field, points)
                self:focus(self.named["parameter-" .. index], false)
                self:refreshCustomSliders(false)
            end, { nav = false, pointer = false })
        end
        if slider.span > 0 then
            self:button("follow-" .. index, field.skill and "恢复" or "跟随", 1580, y + 56, 116, 38, function()
                PlayerCustom.restore(settings, field)
                self:focus(self.named["parameter-" .. index], false)
                self:refreshCustomSliders(false)
            end, { nav = false, pointer = false })
        end
    end
    local hint = section.id == "collection" and "黑石、杀气琥珀的数字刻度对应轮回"
        or section.id == "gear" and "武器刻度数字为轮回参考　·　确认键切换跟随"
        or "数字刻度对应各轮回的属性上限　·　确认键切换跟随养成"
    self:text(hint, 220, 900, 1000, 36, false, 24)
    self:button("reset", "恢复本页", 1190, 943, 272, 64, function()
        PlayerCustom.reset(settings, section)
        self:refreshCustomSliders(false)
    end)
end

function View:beginTargets(member)
    self.flow:openTargets(member)
    self:render()
end

function View:chooseTarget(id)
    local flow = self.flow
    if flow.page == "target" then flow:openTargets(flow.member, id)
    else assert(flow.picker:select(id), "目标已经离开当前地区") end
    self:apply()
end

function View:targetIcon(id, x, y, size, canvas)
    local texture, meta = Art.galleryIcon(self.screen.modal, id)
    if not valid(texture) then return end
    local ok, image = pcall(self.screen.featheredImage, self.screen, texture, meta, x, y, size, canvas)
    if not ok then
        if not reportedIconFadeFailure then
            print("[PBZArenaSetup] 原版头像渐隐：" .. tostring(image) .. "\n")
            reportedIconFadeFailure = true
        end
        image = self.screen:image(texture, meta, x, y, size, size, canvas)
    end
    image.Slot:SetZOrder(22)
    return image
end

function View:drawTargetFields(passive)
    local model = self.flow.draft
    self.pressureControls = model.settings.customPressure and require("PressureControls") or nil
    local top, height = 226, 54
    local function param(index)
        self:addField(index, 113, top, 560, height, passive)
        top = top + height
    end
    param(3)
    local count = model:customCount()
    if count > 0 then param(9) end
    local size, stride = 92, 112
    for index = 1, math.max(count, 1) do
        local member = count > 0 and index or nil
        local x = member and 122 + (index - 1) * stride or 449
        local y = top + 8
        local key = member and "member-" .. member or "opponent"
        local icon = self:targetIcon(model:targetId(member), x + 3, y + 3, size - 6, self.layer)
        local entry = self:button(key, icon and "" or "选择", x, y, size, size,
            function() self:beginTargets(member) end,
            { member = member, slotArt = icon, nav = not passive, pointer = not passive })
        if passive then entry.button.widget:SetIsEnabled(false) end
        if member then
            self:text(tostring(member), x, y + size + 1, size, 27, false, 22):SetJustification(1)
            if icon then icon:SetRenderOpacity(member == self.flow.member and 1 or .75) end
        end
    end
    top = top + size + (count > 0 and 43 or 18)
    param(5)
    param(6)
    if self.pressureControls then
        param(self.pressureControls.sliderIndex)
        param(self.pressureControls.modeIndex)
    end
    if not passive then
        self:button("apply", "确认选择", 113, top + 18, 560, 60, function() self:apply() end, { left = true })
    end
end

function View:drawArrow(key, left, x, y, action)
    local screen = self.screen
    local arrow = Style.arrow(screen.modal, screen.controller, screen.tree, left)
    local entry = self:add({ key = key, nav = false, action = action, button = control(arrow, x, y, 60, 60) })
    Feedback.configureArrow(arrow)
    screen:bindButton(arrow, x, y, 60, 60, function() self:activate(entry) end, self.layer)
end

function View:revealChoice()
    if not self.choiceScroll then return end
    local entry = self.named[self.flow:choiceFocus()]
    if entry then self.choiceScroll:ScrollWidgetIntoView(entry.button.widget, false, 0, 8) end
end

function View:focusChoice(sound)
    local entry = self.named[self.flow:choiceFocus()]
    if not entry or entry.nav == false then
        self.flow.focus = self.flow:choiceFocus()
        self:render()
        return
    end
    self:focus(entry, sound)
    self:revealChoice()
    self:refreshDetail()
end

function View:changeRegion(delta)
    local flow = self.flow
    if #flow.picker.groups <= 1 then return end
    if flow.page == "target" and not flow.trainingFilters then flow:openTargets(flow.member) end
    flow.picker:changeRegion(delta)
    flow.focus = flow:choiceFocus()
    self:render()
end

function View:refreshRegionHints(inputType)
    local gamepad = inputType == GAMEPAD
    if self.regionHintGamepad == nil or self.regionHintGamepad == gamepad then return end
    local previous, following = regionHintRows(gamepad)
    if valid(self.regionPreviousHint) then Hint.setAction(self.regionPreviousHint, previous, UNIVERSAL_ACTIONS) end
    if valid(self.regionNextHint) then Hint.setAction(self.regionNextHint, following, UNIVERSAL_ACTIONS) end
    self.regionHintGamepad = gamepad
end

function View:drawFilters(x, width, top, label)
    local picker = self.flow.picker
    self:line(x, top + 6, width)
    self:text(label or "地区", x + 62, top + 14, width - 124, 32, false, 22):SetJustification(1)
    self:text(picker:regionName(), x + 62, top + 43, width - 124, 43, true, 30):SetJustification(1)
    if #picker.groups > 1 then
        self:drawArrow("region-prev", true, x, top + 30,
            function() self:changeRegion(-1) end)
        self:drawArrow("region-next", false, x + width - 60, top + 30,
            function() self:changeRegion(1) end)
        self.regionHintGamepad = self.input:GetCurrentInputType() == GAMEPAD
        local previous, following = regionHintRows(self.regionHintGamepad)
        self.regionPreviousHint = Hint.create(self.screen, previous, "", x + 64, top + 17, 40, 28, self.layer, UNIVERSAL_ACTIONS)
        self.regionNextHint = Hint.create(self.screen, following, "", x + width - 104, top + 17, 40, 28, self.layer, UNIVERSAL_ACTIONS)
    end
end

function View:pickRow(index, item, x, y, width, height, canvas, thumbnail)
    local flow = self.flow
    local passive = flow.page == "target" and not flow.trainingFilters
    local target = passive or flow.page == "targetChoice"
    local entry = {
        nav = not passive, choice = item, left = not thumbnail,
        canvas = canvas, nativeHitOnly = canvas ~= nil,
        choose = function()
            flow.picker.index = index
            self:refreshDetail()
        end,
    }
    local key = "pick-" .. item.id
    local action
    if flow.trainingFilters then
        action = function()
            flow:chooseTrainingTarget(item.id)
            self.trainingSelected:SetText(FText(item.name))
            self:focus(self.named.apply, false)
        end
    elseif target then action = function() self:chooseTarget(item.id) end
    else action = function() self:apply() end end
    local label = item.name
    if thumbnail then
        entry.thumb = self:targetIcon(item.id, x + 2, y + 2, width - 4, canvas)
    end
    if entry.thumb then label = "" end
    return self:button(key, label, x, y, width, height, action, entry)
end

function View:scrollChoices(x, y, width, height, contentHeight)
    local screen = self.screen
    local scroll = screen:make("ScrollBox")
    scroll:SetVisibility(0)
    scroll:SetClipping(1)
    scroll:SetConsumeMouseWheel(0)
    self.choiceScroll = screen:place(scroll, x, y, width, height, self.layer)
    local frame = screen:make("SizeBox")
    frame:SetHeightOverride(contentHeight + 22)
    local content = screen:make("CanvasPanel")
    frame:SetContent(content)
    scroll:AddChild(frame)
    return content
end

function View:drawTrainingTarget()
    local flow = self.flow
    local target = require("TrainingTarget")
    UI.inkPanel(self.screen, self.layer, 110, 203, 555, self.targetOnly and 317 or 536, .88)
    self:text("筛选", 134, 227, 492, 44, true, 30)
    for index, field in ipairs(flow.trainingFilters.rows) do
        self:addField(index, 134, 282 + (index - 1) * 67, 502, 57, false, field)
    end
    if not self.targetOnly then
        self:line(134, 507, 502)
        self:text("敌人设置", 134, 518, 492, 43, true, 30)
        self:addField(5, 134, 570, 502, 57)
        self:addField(6, 134, 637, 502, 57)
    end

    UI.inkPanel(self.screen, self.layer, 700, 203, 600, 640, .88)
    self:text(("目标（%d）"):format(flow.trainingCount), 724, 227, 546, 44, true, 30)
    self:line(724, 278, 550)
    for index, item in ipairs(flow.picker:entries()) do
        self:pickRow(index, item, 724, 283 + (index - 1) * 54, 550, 54)
    end
    if flow.trainingCount == 0 then self:text("无匹配对象", 754, 302, 490, 46, false, 26) end
    if #flow.picker.groups > 1 then self:drawFilters(724, 550, 852, "页码") end

    UI.inkPanel(self.screen, self.layer, 1335, 203, 479, 418, .88)
    self:line(1360, 449, 429)
    self:text("已选目标", 1360, 467, 429, 37, false, 25)
    local mob = target.option(flow.draft.settings.trainingMobId)
    self.trainingSelected = self:text(mob.name, 1360, 508, 429, 78, true, 31)
    self.trainingSelected:SetAutoWrapText(true)
    self:button("apply", "确认选择", 1514, 943, 290, 64, function() self:apply() end)
end

function View:drawTarget()
    local flow = self.flow
    self:drawTargetFields(flow.page == "targetChoice")
    local entries = flow.picker:entries()
    local grid = usesTargetGrid(flow)
    local height = grid and (math.ceil(#entries / GRID_COLUMNS) - 1) * GRID_STEP + GRID_TILE
        or #entries * LIST_ROW_HEIGHT
    local content = self:scrollChoices(705, 226, 435, 574, height)
    for index, item in ipairs(entries) do
        if grid then
            local slot = index - 1
            self:pickRow(index, item, 12 + (slot % GRID_COLUMNS) * GRID_STEP,
                11 + (slot // GRID_COLUMNS) * GRID_STEP, GRID_TILE, GRID_TILE, content, true)
        else
            self:pickRow(index, item, 12, 11 + (index - 1) * LIST_ROW_HEIGHT, 403, LIST_ROW_HEIGHT, content)
        end
    end
    if grid then self:drawFilters(705, 424, 823) end
end

function View:drawScene()
    local picker = self.flow.picker
    local entries = picker:entries()
    local content = self:scrollChoices(150, 222, 608, 612, (#entries + 1) * LIST_ROW_HEIGHT)
    self:pickRow(0, picker.pinned, 12, 11, 576, LIST_ROW_HEIGHT, content)
    for index, item in ipairs(entries) do
        self:pickRow(index, item, 12, 11 + index * LIST_ROW_HEIGHT, 576, LIST_ROW_HEIGHT, content)
    end
    self:drawFilters(150, 608, 850)
end

function View:drawMusic()
    local screen, picker = self.screen, self.flow.picker
    self.musicContainer = screen:place(screen:make("CanvasPanel"), 0, 0, 1920, 1080, self.layer)
    local ok, panel = pcall(MusicPanel.new, screen, self.musicContainer, picker, {
        previous = function() self:stepMusic(-1) end,
        play = function() self:audition() end,
        next = function() self:stepMusic(1) end,
        choose = function(id) if picker:select(id) then self:apply() end end,
    })
    self.notice = self:text("", 927, 951, 763, 38, false, 23)
    self.notice:SetJustification(1)
    if not ok then
        screen:releaseButtons(self.musicContainer)
        remove(self.musicContainer)
        self.musicContainer = nil
        self.notice:SetText(FText("原版音乐页载入失败"))
        print("[PBZArenaSetup] 原版音乐页载入失败：" .. tostring(panel) .. "\n")
        return
    end
    self.musicPanel = panel
    self:drawFilters(150, 684, 850)
    self.musicAuditionHint = Hint.create(screen, "GenericFaceButtonTop", "试听", 1090, 1012, 138, 30, self.layer)
    Hint.create(screen, "DefaultConfirm", "选定曲目", 150, 969, 175, 30, self.layer, UNIVERSAL_ACTIONS)
    print("[PBZArenaSetup] 原版设定集音乐页已接入\n")
end

function View:refreshPlayer()
    if not self.musicPanel then return end
    local choice = self.flow.picker:current()
    self.musicPanel:refresh(choice, self.preview, self.elapsed)
    local label = self.preview and (self.preview.pausedAt and "继续" or "暂停") or "试听"
    local available = Music.canPreview(choice.id)
    if valid(self.musicAuditionHint) and (self.musicHintLabel ~= label or self.musicHintAvailable ~= available) then
        self.musicHintLabel, self.musicHintAvailable = label, available
        Hint.setText(self.musicAuditionHint, label)
        self.musicAuditionHint:SetVisibility(available and 3 or 1)
    end
end

function View:updateMusic(pointer)
    local panel, picker = self.musicPanel, self.flow.picker
    local cursor = pointer and self.screen:pointerPosition()
    local anchor = self.musicNavigationPointer
    if pointer and anchor then
        if cursor and (cursor.X ~= anchor.X or cursor.Y ~= anchor.Y) then
            self.musicNavigationPointer = nil
        else
            pointer = false
        end
    end
    local hovered = panel:sampleRows(pointer, cursor)
    if hovered and hovered ~= picker:current().id and picker:select(hovered) then
        self:refreshDetail()
        Feedback.menuSelect(self.session.controller, self.session.modal)
    end
    local current = picker:current().id
    local playing = self.preview and not self.preview.pausedAt and current or nil
    panel:refreshRows(hovered, playing)
    panel:updateTransport()
end

function View:refreshDetail()
    local picker = self.flow.picker
    if not picker then return end
    local choice = picker:current()
    if not choice or self.detailId == choice.id then return end
    self.detailId = choice.id
    self:stopPreview()
    self:removeDetail()
    local screen, page = self.screen, self.flow.page
    if page == "music" then
        if self.musicPanel then self.notice:SetText(FText("")); self:refreshPlayer() end
        return
    end
    self.detail = screen:place(screen:make("CanvasPanel"), 0, 0, 1920, 1080, self.layer)
    self.detail:SetVisibility(3)
    if self.flow.trainingFilters then
        self:text(choice.name, 1360, 237, 429, 84, true, 35, self.detail):SetAutoWrapText(true)
        local summary = require("TrainingTarget").summary(choice)
        if summary then self:text(summary, 1360, 332, 429, 76, false, 26, self.detail):SetAutoWrapText(true) end
    elseif page == "target" or page == "targetChoice" then
        self.portrait = Portraits.open(screen, screen.modal, choice.id, "full",
            { x = 1156, y = 193, w = 661, h = 660 })
        self:text(choice.name, 1165, 864, 638, 74, true, 35, self.detail):SetAutoWrapText(true)
        for _, entry in pairs(self.named) do
            if valid(entry.thumb) then entry.thumb:SetRenderOpacity(entry.choice == choice and 1 or .76) end
        end
    elseif page == "scene" then
        local texture, meta = Art.texture(screen.modal, choice.image)
        screen:image(texture, meta, 948, 295, 872, 490, self.detail)
        if not valid(texture) then
            self:text("暂无原版存档画像", 948, 505, 872, 46, false, 26, self.detail):SetJustification(1)
        end
        self:text(choice.previewName or choice.name, 950, 806, 870, 64, true, 34, self.detail):SetAutoWrapText(true)
        if choice.scope then self:text(choice.scope, 952, 872, 850, 34, false, 23, self.detail) end
    end
end

function View:audition()
    if not self.musicPanel then return end
    local choice = self.flow.picker:current()
    if not Music.canPreview(choice.id) then return end
    local now = self.gameplay:GetRealTimeSeconds(self.screen.modal)
    local ok, failure
    if self.preview then
        ok, failure = pcall(self.preview.togglePause, self.preview, now)
        if not ok then self:stopPreview() end
    else
        local preview
        ok, preview, failure = pcall(Music.preview, self.gameplay, self.screen.modal, choice.id)
        if ok and preview then self.preview = preview
        else failure, ok = failure or preview, false end
    end
    if not ok then
        self.notice:SetText(FText("试听未能播放，请重试"))
        print("[PBZArenaSetup] 试听失败 " .. tostring(failure) .. "\n")
    else self.notice:SetText(FText("")) end
    self:refreshPlayer()
end

function View:showMusicSelection()
    -- Moving the list under a stationary mouse must not replace keyboard focus.
    self.musicNavigationPointer = self.screen:pointerPosition()
    self.musicPanel:select(self.flow.picker:current().id)
    self:refreshDetail()
    self:updateMusic(false)
    Feedback.menuSelect(self.session.controller, self.session.modal)
end

function View:stepMusic(delta)
    if not self.musicPanel then return end
    local picker = self.flow.picker
    local previous = picker:current().id
    picker:step(delta)
    local current = picker:current().id
    if current ~= previous then print("[PBZArenaSetup] 音乐切换 " .. current .. "\n") end
    self:showMusicSelection()
end

function View:tickMusic()
    if not self.preview then return end
    local now = self.gameplay:GetRealTimeSeconds(self.screen.modal)
    if not self.preview:update(now) then self:stopPreview(); self:refreshPlayer(); return end
    if not self.nextPosition or now >= self.nextPosition then
        self.nextPosition = now + .25
        self.elapsed = self.preview:seconds() or self.elapsed
        self:refreshPlayer()
    end
end

function View:refreshBackground(page)
    local key = page == "targetChoice" and "target" or page == "playerCustom" and "character" or page
    if key == self.backgroundPage then return end
    remove(self.backgroundLayer)
    self.backgroundLayer, self.backgroundPage = nil, key
    if valid(self.session.illustrationLayer) then
        self.session.illustrationLayer:SetRenderOpacity(page == "overview" and 1 or 0)
    end
    local screen = self.screen
    local texture, meta = Art.arenaBackground(screen.modal, key)
    if valid(texture) then
        self.backgroundLayer = screen:mountBackground(texture, meta)
    elseif meta then
        print("[PBZArenaSetup] 背景图载入失败 " .. key .. " " .. tostring(meta.reason) .. "\n")
    end
end

function View:render()
    self:removeLayer()
    self.layer = self.screen:panel(0, 0, 1920, 1080)
    self.named, self.options, self.pointers, self.fields, self.fieldRows, self.customSliders = {}, {}, {}, {}, {}, {}
    self.customRepeatAt = nil
    self.detailId, self.lastHovered, self.pressureControls = nil, nil, nil
    self.trainingSelected = nil
    self.musicNavigationPointer = nil
    self.musicAuditionHint, self.musicHintLabel, self.musicHintAvailable = nil, nil, nil
    local page = self.flow.page
    self:refreshBackground(page)
    self.confirmHeld, self.directionHeld = pageConfirmHeld(self.router, page), UI.direction(self.router)
    self.regionPreviousHeld, self.regionNextHeld = regionKeys(self.router)
    self.auditionHeld = page == "music" and musicAuditionHeld(self.router)
    local selectedMode = self.flow.model.settings.mode
    local mode = selectedMode == "training" and "测试场" or selectedMode == "practice" and "练习模式" or "挑战模式"
    local title = TITLES[page] or mode
    if self.flow.trainingFilters then title = self.targetOnly and "重选目标" or "测试对象"
    elseif page == "playerCustom" then
        local section = require("PlayerCustom").section(self.flow.customSection)
        title = section.label .. " · " .. Profile.rank(self.flow.draft.settings.playerCycle)
    end
    self:text(title, 110, 62, 740, 91, true, 55)
    if page == "overview" then self:drawOverview()
    elseif page == "character" then self:drawCharacter()
    elseif page == "playerCustom" then self:drawPlayerCustom()
    elseif self.flow.trainingFilters then self:drawTrainingTarget()
    elseif page == "target" or page == "targetChoice" then self:drawTarget()
    elseif page == "scene" then self:drawScene()
    else self:drawMusic() end
    if page == "character" or page == "playerCustom" then
        self:button("apply", "确定", 1514, 943, 290, 64, function() self:apply() end)
    end
    UI.footer(self.screen, self.layer, nil, nil, nil, page ~= "music", function() self:back() end)
    self:focus(self.named[self.flow.focus] or (page ~= "music" and self.options[1] or nil), false)
    self:revealChoice()
    self:refreshFields()
    self:refreshDetail()
    self.session.buttons[1]:SetFocus()
    print("[PBZArenaSetup] " .. mode .. " page=" .. page .. "\n")
end

function View:move(direction)
    local flow, entry = self.flow, self.selected
    local horizontal = direction >= 3
    if flow.page == "music" then
        if horizontal then return end
        if self.musicPanel and flow.picker:move(direction == 1 and -1 or 1) then
            self:showMusicSelection()
        end
        return
    end
    if not entry then return end
    if horizontal and entry.parameter then
        self:changeParameter(entry.parameter, direction == 3 and -1 or 1)
        return
    end
    if flow.page == "target" and entry.key == flow:targetField() then
        if horizontal then
            local neighbor = entry.member and self.named["member-" .. (entry.member + (direction == 3 and -1 or 1))]
            if neighbor then self:focus(neighbor, true) end
        else
            local index = direction == 2 and 5 or entry.member and 9 or 3
            self:focus(self.named["parameter-" .. index], true)
        end
        return
    end
    if entry.choice and not flow.trainingFilters then
        local delta = direction == 1 and -1 or 1
        local grid = flow.page == "targetChoice" and usesTargetGrid(flow)
        if grid and not horizontal then
            local index = flow.picker.index
            delta = delta * GRID_COLUMNS
            if direction == 2 and (index - 1) // GRID_COLUMNS < (#flow.picker:entries() - 1) // GRID_COLUMNS then
                delta = math.min(delta, #flow.picker:entries() - index)
            end
        end
        if grid and horizontal then
            delta = direction == 3 and -1 or 1
            local col = (flow.picker.index - 1) % GRID_COLUMNS
            if col + delta < 0 or col + delta >= GRID_COLUMNS then return end
        end
        if (grid or not horizontal) and flow.picker:move(delta) then self:focusChoice(true) end
        return
    end
    if not horizontal then
        local nextEntry = self.options[entry.index + (direction == 1 and -1 or 1)]
        self:focus(nextEntry, true)
    end
end

function View:confirm()
    if self.closed or self.confirmHeld or self.starting then return end
    self.confirmHeld = true
    if self.flow.page == "music" then
        self:apply()
        return
    end
    local entry = self.selected
    if not entry then return end
    if entry.action then
        if entry.button.widget.bCanPlaySound == false then Feedback.click(self.screen.modal, entry.button.widget) end
        self:activate(entry)
    elseif entry.parameter and self.flow.page == "character" then self:apply()
    elseif entry.parameter and self.flow.page == "playerCustom" then
        self.customSliders[entry.parameter]:follow()
        self:refreshCustomSliders(false)
    end
end

function View:confirmNative()
    if self.flow.page == "music" and not pageConfirmHeld(self.router, "music")
        and (self.auditionHeld or musicAuditionHeld(self.router)) then return end
    self:confirm()
end

function View:update()
    if self.closed or self.starting then return false end
    local modal, controller = self.screen.modal, self.session.controller
    local focused = modal:HasUserFocus(controller) or modal:HasUserFocusedDescendants(controller)
    local layer = self.layer
    local index, mouse
    local inputType = self.input:GetCurrentInputType()
    if inputType ~= GAMEPAD then
        index, mouse = UI.pointer(self.screen, self.input, self.pointers)
    end
    -- Native clicks can arrive before hover and CommonInput have caught up with a mouse press.
    local acceptClick = mouse or self.flow.page == "music"
    if not self.screen:update(acceptClick) or self.closed or self.starting then return false end
    if layer ~= self.layer then return true end
    self:refreshRegionHints(inputType)
    local hover = self.pointers[index or 0]
    if hover ~= self.lastHovered then
        self.lastHovered = hover
        if mouse then self:focus(hover, true) end
    end
    if layer ~= self.layer then return true end
    self:refreshFields()
    if self.flow.page == "playerCustom" then self:refreshCustomSliders(inputType ~= GAMEPAD) end
    self:tickMusic()
    if self.musicPanel then self:updateMusic(inputType == MOUSE_AND_KEYBOARD) end
    if not focused and not mouse then return true end
    self:readPressure()
    local router = self.router
    local page = self.flow.page
    if pageConfirmHeld(router, page) then
        if not self.confirmHeld then self:confirm(); return true end
    else self.confirmHeld = false end
    if REGION_PAGES[page] then
        local previous, following = regionKeys(router)
        local prevPressed, nextPressed = previous and not self.regionPreviousHeld, following and not self.regionNextHeld
        self.regionPreviousHeld, self.regionNextHeld = previous, following
        if prevPressed or nextPressed then self:changeRegion(prevPressed and -1 or 1); return true end
    end
    if page == "music" then
        local audition = musicAuditionHeld(router)
        local pressed = audition and not self.auditionHeld
        self.auditionHeld = audition
        if pressed then self:audition(); return true end
    end
    local direction = UI.direction(router)
    local moved = direction and direction ~= self.directionHeld
    self.directionHeld = direction
    if moved then self:move(direction) end
    if page == "playerCustom" and direction and direction >= 3 then
        local slider = self.selected and self.customSliders[self.selected.parameter]
        if slider then
            local now = self.gameplay:GetRealTimeSeconds(modal)
            if moved or not self.customRepeatAt then self.customRepeatAt = now + .38
            elseif now >= self.customRepeatAt then
                self.customRepeatAt = now + .12
                self:changeParameter(self.selected.parameter, direction == 3 and -slider.field.fast or slider.field.fast)
            end
        end
    else self.customRepeatAt = nil end
    return true
end

function View:close()
    if self.closed then return end
    self.closed = true
    self:removeLayer()
    remove(self.backgroundLayer)
    self.backgroundLayer = nil
    if valid(self.session.illustrationLayer) then self.session.illustrationLayer:SetRenderOpacity(1) end
end

function Menu.open(session, screen, flow, start, leave, targetOnly, confirmLabel)
    local self = setmetatable({
        session = session, screen = screen, flow = flow, start = start, leave = leave, router = session.router,
        targetOnly = targetOnly, confirmLabel = confirmLabel,
    }, View)
    local ok, reason = pcall(function()
        self.gameplay = required(GAMEPLAY)
        self.input = required(SUBSYSTEMS):GetLocalPlayerSubsystem(session.modal, required(INPUT))
        assert(valid(self.input) and valid(self.router), "演武菜单原版输入接口未就绪")
        self:render()
    end)
    if not ok then self:close(); error(reason, 0) end
    return self
end

return Menu
