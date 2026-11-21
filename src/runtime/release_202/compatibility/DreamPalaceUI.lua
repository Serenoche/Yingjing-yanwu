local Screen = require("NativeScreen")
local Style = require("ParameterStyle")
local Feedback = require("ParameterFeedback")
local Assets = require("CombatSpawn")
local Profile = require("DreamPalaceProfile")
local Progress = require("BloodyPalaceProgress")
local UI, View = {}, {}
View.__index = View

local MENU_ART = "/Game/PBZContent/UI/Menu/StartMenu/"
local GLOW = { "T_Login_GlowBarL", "T_Login_GlowBarM", "T_Login_GlowBarR" }
local MENU_BUTTON = "/Game/PBZContent/UI/UINew/Common/W_MenuButton_V2_SelectedVersion.W_MenuButton_V2_SelectedVersion_C"
local FULL_BUTTON_FONT = "/Game/PBZContent/UI/Fonts/ZH_ZiKuTangKuangShanKaiShuJF_Font.ZH_ZiKuTangKuangShanKaiShuJF_Font"
-- Complete labels covered by the pinned title selection font's character map.
-- New labels use the complete font until their coverage has been checked.
local NATIVE_SELECTED_LABELS = { ["浊梦"] = true, ["鬼差"] = true, ["平民"] = true, ["进入幻境"] = true }
local NATIVE_GLOW_HEIGHT = 64
local RAIL_HEIGHT, RAIL_INSET = 66, 8
local WIDGET_LIBRARY = "/Script/UMG.Default__WidgetBlueprintLibrary"
local PROMPT = "/Game/PBZContent/UI/Foundation/Widgets/BottomBar/WB_InputWidget.WB_InputWidget_C"
local ACTIONS = "/Game/PBZContent/DataTable/UI/DT_UniversalActions.DT_UniversalActions"
local ROUTER = "/Script/ProjectPBZ.PBZUIActionRouterBase"
local INPUT = "/Script/CommonInput.CommonInputSubsystem"
local SUBSYSTEMS = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local ARTBOOK = "/Game/PBZContent/UI/Menu/BonusCollection/Artbook1017/"
local BONUS_COLLECTION = "/Script/ProjectPBZ.PBZBonusCollectionSubsystem"
-- FullScreenImage from the original DT_BonusArt, in home menu order.
local HOME_ART = {
    { "T_UI_D048", "9_YXZR/", .52 },
    { "T_UI_D079", "15_Hidden/", .48 },
    { "T_UI_D131", "15_Hidden/", .50 },
    { "T_UI_D043", "15_Hidden/", .54 },
}
local FOCUS = { { "Up", "Gamepad_DPad_Up" }, { "Down", "Gamepad_DPad_Down" },
    { "Left", "Gamepad_DPad_Left" }, { "Right", "Gamepad_DPad_Right" } }
local PARENT = { prep = "difficulty", warmup = "prep", records = "prep" }
local source = debug.getinfo(1, "S").source
local directory = assert(source:match("^@(.+)[/\\][^/\\]+$"), "无法定位浊梦素材目录")
local edgeMaskPath = directory .. "/DreamPalaceEdgeMask.png"
local edgeMaskTexture
local artWarning
local appearanceWarning

local function valid(object)
    return object and type(object.IsValid) == "function" and object:IsValid()
end

local function requireObject(path)
    local object = StaticFindObject(path)
    assert(valid(object), "浊梦缺少原生控件接口：" .. path)
    return object
end

local function asset(path)
    local object = StaticFindObject(path)
    if not valid(object) then LoadAsset(path); object = requireObject(path) end
    return object
end

local function ensureCaptionFont(button)
    if not button.fontFallback or not valid(button.caption) then return end
    local font = button.caption.Font
    if valid(font.FontObject) and font.FontObject:GetAddress() == button.fontFallback:GetAddress() then return end
    -- Keep the native decorator's point size and spacing. Replace the font
    -- family after it picks the sparse selected face for this caption.
    font.FontObject = button.fontFallback
    button.caption:SetFont(font)
end

local Button = {}
Button.__index = Button

function Button:setSelected(selected)
    if self.selected == selected then
        if selected then ensureCaptionFont(self) end
        return
    end
    self.selected = selected
    local appearance = self.appearance
    if not valid(appearance) then return end
    if not self.animation then
        appearance:SetVisibility(selected and 3 or 2)
    elseif selected then
        appearance:SetSelectedInternal(true, false, false)
        ensureCaptionFont(self)
        appearance:QueueStopAnimation(appearance.loop)
        appearance:QueuePlayAnimation(self.animation, 0, 0, 0, 1, false)
    else
        appearance:QueueStopAnimation(self.animation)
        appearance:StopAnimation(self.animation)
        appearance:StopAnimation(appearance.loop)
        appearance:SetSelectedInternal(false, false, false)
    end
end

function UI.pointer(screen, input, entries)
    local inputType = input:GetCurrentInputType()
    if inputType == 2 then return nil, false end
    -- The native Slate hit wins even when CommonInput has not yet switched
    -- back from gamepad or a layout frame reports stale pointer coordinates.
    for index, entry in ipairs(entries) do
        if entry.button.widget:IsHovered() then return index, true end
    end
    if inputType ~= 0 then return nil, false end
    local position = screen:pointerPosition()
    if not position or position.X < 0 or position.X >= 1920 or position.Y < 0 or position.Y >= 1080 then
        return nil, false
    end
    for index, entry in ipairs(entries) do
        local button = entry.button
        if position.X >= button.x and position.X < button.right
            and position.Y >= button.y and position.Y < button.bottom then return index, true end
    end
    return nil, true
end

local function nativeAppearance(screen, label, width, height, glow, leftAligned)
    -- The title entry copies these overrides from LoadGame. Keep its own
    -- text block and selected decorator in the same tree as the glow.
    local template = screen.titleButtonTemplate
    local hasTemplate = valid(template)
    local class = hasTemplate and template:GetClass() or Assets.class(MENU_BUTTON)
    local appearance = requireObject(WIDGET_LIBRARY):Create(screen.modal, class, screen.controller)
    assert(valid(appearance), "无法创建原版菜单按钮")
    local animation = appearance.AI_GameSelectSelectedBreathe
    assert(valid(animation), "原版按钮缺少选中动画")
    assert(valid(appearance.loop) and appearance.QueuePlayAnimation and appearance.QueueStopAnimation
        and appearance.StopAnimation and appearance.SetSelectedInternal,
        "原版按钮缺少选中外观接口")
    appearance:SetVisibility(3)
    appearance:SetIsFocusable(false)
    appearance:SetIsSelectable(true)
    appearance.bCanPlaySound = false
    appearance.ChangeTextDecoratorOnSelected = not hasTemplate or template.ChangeTextDecoratorOnSelected
    appearance.SelectedOpacity = hasTemplate and template.SelectedOpacity or 1
    appearance.UnselectedOpacity = hasTemplate and template.UnselectedOpacity or 1
    appearance.bOverride_ButtonText = true
    local text = FText(label)
    appearance.ButtonText = text
    appearance:SetButtonText(text)
    appearance:SetMinDimensions(glow.width, glow.height)
    appearance:SetClipping(0)
    local center = appearance.Image_146:GetParent()
    for _, cap in ipairs({ appearance.Image_62, appearance.Image_105 }) do
        cap.Slot:SetSize({ SizeRule = 1, Value = 1 })
        cap.Slot:SetHorizontalAlignment(0)
    end
    center.Slot:SetSize({ SizeRule = 1, Value = 2 })
    -- The stock row lives in the middle half of the glow. Give it the
    -- full button's text bounds, with clipping at the outer button edge.
    local row = center:GetChildAt(1)
    local centerLeft = glow.x + glow.width / 4
    local centerRight = glow.x + glow.width * .75
    local verticalPadding = (glow.height - height) / 2
    row.Slot:SetHorizontalAlignment(0)
    row.Slot:SetPadding({ Left = (leftAligned and 30 or 6) - centerLeft, Top = verticalPadding,
        Right = centerRight - (width - (leftAligned and 12 or 6)), Bottom = verticalPadding })
    for _, index in ipairs({ 0, 1, 3 }) do row:GetChildAt(index):SetVisibility(1) end
    local textLayers = row:GetChildAt(2)
    textLayers.Slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
    textLayers.Slot:SetSize({ SizeRule = 1, Value = 1 })
    textLayers.Slot:SetHorizontalAlignment(0)
    local caption = textLayers:GetChildAt(1):GetContent()
    assert(valid(caption), "原版按钮缺少文字控件")
    caption:SetClipping(0)
    caption:SetAutoWrapText(false)
    caption:SetJustification(leftAligned and 0 or 1)
    local fontFallback = not NATIVE_SELECTED_LABELS[label] and Assets.class(FULL_BUTTON_FONT) or nil
    return appearance, animation, caption, fontFallback
end

local function buttonAppearance(screen, label, width, height, glow, leftAligned)
    if not appearanceWarning then
        local ok, appearance, animation, caption, fontFallback = pcall(nativeAppearance, screen, label, width, height, glow, leftAligned)
        if ok then return appearance, animation, caption, fontFallback end
        appearanceWarning = appearance
        print("[PBZDreamPalaceUI] native button appearance unavailable: " .. tostring(appearance) .. "\n")
    end
    local highlight = screen:make("HorizontalBox")
    highlight:SetVisibility(2)
    highlight:SetRenderOpacity(.8)
    for i, name in ipairs(GLOW) do
        local image = screen:make("Image")
        image:SetVisibility(3)
        image:SetBrushFromTexture(Assets.class(MENU_ART .. name .. "." .. name), false)
        local slot = highlight:AddChildToHorizontalBox(image)
        slot:SetSize({ SizeRule = 1, Value = i == 2 and 2 or 1 })
        slot:SetVerticalAlignment(0)
    end
    return highlight
end

function UI.button(screen, label, x, y, width, height, callback, canvas, compact, leftAligned)
    local widget, embedded = Style.button(screen.modal, screen.controller, screen.tree, "")
    embedded:SetVisibility(1)
    widget:SetMinDimensions(width, height)
    screen:bindButton(widget, x, y, width, height, callback, canvas)
    Feedback.configureArrow(widget)

    local fontSize = compact and 27 or 39
    local characters = #label:gsub("[\128-\191]", "")
    local glowWidth = math.min(width - 12, math.max(146, characters * fontSize + (compact and 66 or 150)))
    local glowHeight = compact and math.min(height, NATIVE_GLOW_HEIGHT) or 68
    local glow = { x = leftAligned and 0 or (width - glowWidth) / 2, y = (height - glowHeight) / 2,
        width = glowWidth, height = glowHeight }
    local appearance, animation, caption, fontFallback = buttonAppearance(screen, label, width, height, glow, leftAligned)
    local visuals = screen:make("CanvasPanel")
    visuals:SetVisibility(3)
    visuals:SetClipping(1)
    screen:place(visuals, x, y, width, height, canvas).Slot:SetZOrder(21)
    screen:place(appearance, glow.x, glow.y, glow.width, glow.height, visuals)
    if not animation then
        local inset = leftAligned and 30 or 12
        local frame = screen:make("Overlay")
        frame:SetVisibility(3)
        frame:SetClipping(1)
        screen:place(frame, inset, 0, width - inset - 12, height, visuals).Slot:SetZOrder(22)
        local caption = Style.text(screen.tree, label, true, fontSize)
        caption:SetJustification(leftAligned and 0 or 1)
        caption:SetShadowOffset({ X = 1, Y = 2 })
        caption:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = .9 })
        local slot = frame:AddChildToOverlay(caption)
        slot:SetHorizontalAlignment(0)
        slot:SetVerticalAlignment(2)
    end
    return setmetatable({ widget = widget, appearance = appearance, animation = animation,
        caption = caption, fontFallback = fontFallback, selected = false,
        x = x, y = y, right = x + width, bottom = y + height }, Button)
end

local function hint(screen, bar, text, row, canvas, width, action)
    local entry = screen:make("CanvasPanel")
    local box = screen:make("SizeBox")
    box:SetWidthOverride(width)
    box:SetHeightOverride(30)
    entry:SetVisibility(4)
    box:SetContent(entry)
    bar:AddChildToHorizontalBox(box):SetVerticalAlignment(2)
    local prompt = requireObject(WIDGET_LIBRARY):Create(screen.modal,
        Assets.class(PROMPT), screen.controller)
    assert(valid(prompt), "无法创建原版按键提示")
    local handle = { DataTable = asset(ACTIONS), RowName = FName(row) }
    local label = FText(text)
    prompt.InputActions, prompt.DisplayText = handle, label
    prompt.InputActionWidget:SetInputAction(handle)
    prompt.RichText:SetPBZFormatText(label)
    prompt:SetVisibility(3)
    screen:place(prompt, 0, 0, width, 30, entry).Slot:SetZOrder(22)
    if action then
        local hit, empty = Style.button(screen.modal, screen.controller, screen.tree, "")
        empty:SetVisibility(1)
        screen:bindButton(hit, 0, 0, width, 30, action, entry, canvas)
        Feedback.configureArrow(hit)
    end
end

function UI.footer(screen, canvas, pageLabel, showConfirm, onBack)
    if pageLabel then screen:text(pageLabel, 859, 1007, 200, 44, false, canvas, 22):SetJustification(1) end
    local bar = screen:make("HorizontalBox")
    screen:place(bar, 1160, 1012, 660, 30, canvas)
    local spacer = screen:make("Spacer")
    bar:AddChildToHorizontalBox(spacer):SetSize({ SizeRule = 1, Value = 1 })
    local function add(text, row, width, action)
        hint(screen, bar, text, row, canvas, width, action)
        local gap = screen:make("Spacer")
        gap:SetSize({ X = 30, Y = 0 })
        bar:AddChildToHorizontalBox(gap)
    end
    if showConfirm then add("确定", "DefaultConfirm", 98) end
    hint(screen, bar, "返回", "DefaultClose", canvas, 82, onBack)
end

function UI.heading(screen, title, canvas)
    return screen:artHeading(title, 110, canvas)
        or screen:text(title, 110, 67, 740, 84, true, canvas, 56)
end

function UI.railPosition(index)
    return 150, 235 + RAIL_INSET + (index - 1) * RAIL_HEIGHT, 608, RAIL_HEIGHT
end

local function edgeMask(context)
    if not valid(edgeMaskTexture) then
        local rendering = requireObject("/Script/Engine.Default__KismetRenderingLibrary")
        edgeMaskTexture = rendering:ImportFileAsTexture2D(context, edgeMaskPath)
    end
    assert(valid(edgeMaskTexture), "无法载入插图边缘蒙版")
    return edgeMaskTexture
end

local function unlockedArt(context, row)
    local class = StaticFindObject(BONUS_COLLECTION)
    if not valid(class) then return false end
    local system = requireObject(SUBSYSTEMS):GetWorldSubsystem(context, class)
    return valid(system) and system:IsEntryUnlocked(0, FName(row)) == true
end

local ART_WIDTH, ART_HEIGHT = 1344, 1080
local function drawIllustration(screen, canvas, art, index)
    local row, folder, center = table.unpack(HOME_ART[index])
    local ok, unlocked = pcall(unlockedArt, screen.modal, row)
    local source, meta
    if ok and unlocked then
        local name = row .. "_F"
        source, meta = require("ArtAssets").texture(screen.modal, ARTBOOK .. folder .. name .. "." .. name)
    end
    if not valid(source) or not meta or not meta.width or not meta.height then
        if art then art.frame:SetVisibility(2) end
        return art
    end
    local newFrame = art == nil
    if newFrame then
        local maskTexture = edgeMask(screen.modal)
        local crop = screen:make("CanvasPanel")
        crop:SetVisibility(3); crop:SetClipping(1)
        local image = screen:make("Image")
        image:SetVisibility(3)
        screen:place(image, 0, 0, ART_WIDTH, ART_HEIGHT, crop).Slot:SetZOrder(0)
        local mask = screen:make("Image")
        mask:SetVisibility(3)
        mask:SetBrushFromTexture(maskTexture, false)
        mask:SetColorAndOpacity(Screen.backdropTint)
        screen:place(mask, 0, 0, ART_WIDTH, ART_HEIGHT, crop).Slot:SetZOrder(1)
        art = { frame = crop, image = image }
    end
    -- Crop the texture before masking the pane. The original lower 6.5%
    -- contains the watermark; the UMG clip excludes it at every DPI scale.
    local left, top, right, bottom = .012, .012, .988, .935
    local tw, th = meta.width, meta.height
    local scale = math.max(ART_WIDTH / (tw * (right - left)), ART_HEIGHT / (th * (bottom - top)))
    local width, height = tw * scale, th * scale
    local x = math.max(ART_WIDTH - width * right, math.min(-width * left, ART_WIDTH * .5 - width * center))
    art.image:SetBrushFromTexture(source, false)
    art.image.Slot:SetPosition({ X = x, Y = -height * top })
    art.image.Slot:SetSize({ X = width, Y = height })
    art.frame:SetVisibility(3)
    if newFrame then
        screen:place(art.frame, 1920 - ART_WIDTH, 0, ART_WIDTH, ART_HEIGHT, canvas).Slot:SetZOrder(5)
    end
    return art
end

function UI.illustration(screen, canvas, art, index)
    local ok, result = pcall(drawIllustration, screen, canvas, art, index)
    if ok then return result end
    if art then art.frame:SetVisibility(2) end
    if artWarning ~= result then
        artWarning = result
        print("[PBZDreamPalaceUI] illustration failed: " .. tostring(result) .. "\n")
    end
    return art
end

function View:option(label, x, y, width, height, action, compact)
    local entry = { action = action }
    entry.button = UI.button(self.screen, label, x, y, width, height, function()
        self:choose(entry)
    end, self.layer, compact, not compact)
    self.options[#self.options + 1] = entry
    self.pointerEntries[#self.pointerEntries + 1] = entry
end

function View:choose(entry)
    if not entry or self.closed then return end
    for i, item in ipairs(self.options) do
        if item == entry then
            self:select(i, false)
            item.action()
            return
        end
    end
end

function View:showSelection(entry)
    if self.highlighted ~= entry then
        if self.highlighted then self.highlighted.button:setSelected(false) end
        self.highlighted = entry
    end
    if entry then entry.button:setSelected(true) end
end

function View:select(index, playSound)
    local entry = self.options[index]
    if self.index == index or not entry then return end
    self.index = index
    self.hoveredPageButton = nil
    self:showSelection(entry)
    if playSound then Feedback.menuSelect(self.session.controller, self.session.modal) end
end

function View:removeLayer()
    if not self.layer then return end
    self:showSelection(nil)
    self.screen:releaseButtons(self.layer)
    self.layer:RemoveFromParent()
    self.layer = nil
end

function View:go(page)
    self.page = page
    self:removeLayer()
    self.layer = self.screen:panel(0, 0, 1920, 1080)
    self.options, self.pointerEntries, self.index, self.columns, self.initialIndex = {}, {}, nil, 1, 1
    self.confirmHeld, self.directionHeld = true, true
    self.lastMouseHover, self.hoveredPageButton = nil, nil
    self.navigateEdge, self.pageLabel = nil, nil
    self[page](self)
    UI.footer(self.screen, self.layer, self.pageLabel, #self.options > 0,
        function() self:back() end)
    self:select(self.initialIndex, false)
    self.session.buttons[1]:SetFocus()
    print("[PBZDreamPalaceUI] page=" .. page .. "\n")
end

function View:header(title)
    UI.heading(self.screen, title, self.layer)
end

function View:rail(label, index, action)
    local x, y, width, height = UI.railPosition(index)
    self:option(label, x, y, width, height, action)
end

function View:difficulty()
    self:header(Profile.name)
    local count, civilian = 0, Profile.civilian(self.path)
    for _, tier in ipairs(Profile.tiers) do
        if not tier.assist or civilian then
            count = count + 1
            if self.tier == tier.id then self.initialIndex = count end
            self:rail(tier.name, count, function()
                self.tier = tier.id
                self:go("prep")
            end)
        end
    end
end

local INK_ART = "/Game/PBZContent/UI/UINew/System/"
local INK_PARTS = { "T_OpenDoorCondition_T", "T_OpenDoorCondition_M", "T_OpenDoorCondition_B" }
local DIALOG_ART = "/Game/PBZContent/UI/Foundation/Dialogs/"
local SAVE_ART = "/Game/PBZContent/UI/InGame/SaveLoad/"

local function panelTexture(screen, folder, name)
    return require("ArtAssets").texture(screen.modal, folder .. name .. "." .. name)
end

local function panelImage(screen, layer, texture, x, y, width, height, opacity)
    if not texture then return end
    local image = screen:make("Image")
    image:SetVisibility(3)
    image:SetBrushFromTexture(texture, false)
    image:SetRenderOpacity(opacity)
    screen:place(image, x, y, width, height, layer).Slot:SetZOrder(10)
end

local function inkPanel(screen, layer, x, y, width, height, opacity)
    local parts = {}
    for i, name in ipairs(INK_PARTS) do
        parts[i] = panelTexture(screen, INK_ART, name)
        if not parts[i] then return end
    end
    -- The native confirmation widget stretches only the middle slice vertically.
    local cap = width / 8 -- The end textures are 1024 × 128.
    panelImage(screen, layer, parts[1], x, y, width, cap, opacity)
    panelImage(screen, layer, parts[2], x, y + cap, width, height - cap * 2, opacity)
    panelImage(screen, layer, parts[3], x, y + height - cap, width, cap, opacity)
end

function View:scoreboard(record, x, y)
    inkPanel(self.screen, self.layer, x - 22, y - 68, 672, 432, .89)
    self.screen:text("最佳战绩", x, y, 600, 52, true, self.layer, 35)
    local headerLine = panelTexture(self.screen, DIALOG_ART, "T_ConfirmationLine")
    local rowLine = panelTexture(self.screen, SAVE_ART, "T_SaveLoadGameLine")
    panelImage(self.screen, self.layer, headerLine, x, y + 60, 628, 4, 1)
    for index, row in ipairs(Profile.score(record)) do
        local top = y + 82 + (index - 1) * 57
        if index > 1 then
            panelImage(self.screen, self.layer, rowLine, x, top - 5, 628, 2, 1)
        end
        self.screen:text(row[1], x + 19, top + 5, 355, 47, false, self.layer, 27)
        self.screen:text(row[2], x + 382, top + 2, 222, 47, index == 4, self.layer, 31):SetJustification(2)
    end
end

function View:prep()
    self:header(Profile.name)
    local stats = Profile.read(self.path, self.tier)
    self:rail("进入幻境", 1, function()
        local ok, saved = pcall(Progress.load, Profile.checkpoint(self.path, self.tier), self.tier == "entry")
        self.saved = ok and saved or nil
        self:enter()
    end)
    self:rail("热身", 2, function() self.gridPage = 1; self:go("warmup") end)
    self:rail("战斗记录", 3, function() self:go("records") end)
    local tier = Profile.tier(self.tier)
    self.screen:text(("%s　·　起始轮回 %d　·　逆天者"):format(tier.name, tier.cycle),
        150, 163, 818, 48, false, self.layer, 29)
    self:scoreboard(stats.best, 1165, 223)
end

function View:warmupPageButton(label, x, step)
    local button = UI.button(self.screen, label, x, 1002, 176, 62, function()
        self.gridPage = self.gridPage + step
        self:go("warmup")
    end, self.layer, true)
    self.pointerEntries[#self.pointerEntries + 1] = { button = button }
end

function View:warmup()
    local count = Profile.read(self.path, self.tier).bestClear
    self.columns = 8
    local first = (self.gridPage - 1) * 40 + 1
    local pages = math.max(1, math.ceil(count / 40))
    if count == 0 then
        self.screen:text("当前难度暂无已通关层。", 108, 237, 1220, 70, false, self.layer, 36)
    end
    for floor = first, math.min(first + 39, count) do
        local i = floor - first
        self:option(("第 %d 层"):format(floor), 99 + (i % 8) * 220, 216 + math.floor(i / 8) * 106, 202, 77,
            function() self:practice(floor) end, true)
    end
    if pages > 1 then
        if self.gridPage > 1 then self:warmupPageButton("上一页", 605, -1) end
        if self.gridPage < pages then self:warmupPageButton("下一页", 1134, 1) end
        self.navigateEdge = function(direction)
            local delta = direction == 1 and -1 or direction == 2 and 1 or 0
            local nextPage = self.gridPage + delta
            if delta ~= 0 and nextPage >= 1 and nextPage <= pages then self.gridPage = nextPage; self:go("warmup"); return true end
        end
    end
    if pages > 1 then self.pageLabel = self.gridPage .. " / " .. pages end
end

function View:records()
    self:header("战斗记录")
    local rows = Profile.read(self.path, self.tier).recent
    if #rows == 0 then self.screen:text("暂无战斗记录", 111, 230, 750, 52, false, self.layer, 30) end
    for i, entry in ipairs(rows) do
        local y = 187 + (i - 1) * 62
        self.screen:shade(107, y, 1210, 54, .59, self.layer)
        self.screen:text(entry.outcome == "win" and "通关" or "战败", 128, y + 8, 216, 39, true, self.layer, 25)
        self.screen:text("已通过 " .. entry.cleared .. " 层", 360, y + 8, 310, 39, false, self.layer, 25)
        self.screen:text(Profile.time(entry.milliseconds), 730, y + 8, 220, 39, false, self.layer, 25)
        self.screen:text(Profile.rank(entry.cleared), 1042, y + 8, 165, 39, true, self.layer, 27)
    end
end

function View:dialog(detail, buttons, onCancel)
    self:showSelection(nil)
    self.openDialog(detail, buttons, onCancel)
end

function View:enter()
    local tier = self.tier
    if self.saved then
        self:dialog("已保存至第 " .. self.saved.cleared .. " 层。是否继续挑战？", {
            { "继续挑战", function() self.start({ mode = "bloody-palace", palaceTier = tier, palaceResume = true }) end },
            { "重新开始", function() self:restart() end },
        })
    else
        self:dialog("是否以" .. Profile.tier(tier).name .. "难度进入幻境，从第 1 层开始？", {
            { "确定", function() self.start({ mode = "bloody-palace", palaceTier = tier }) end },
        })
    end
end

function View:restart()
    local tier = self.tier
    self:dialog("将从第 1 层开始，现有存点会被覆盖。是否开始新的挑战？", {
        { "确定", function() self.start({ mode = "bloody-palace", palaceTier = tier }) end },
    }, function() self:enter() end)
end

function View:practice(floor)
    local tier = self.tier
    self:dialog(("是否练习第 %d 层？热身成绩不计入战斗记录。"):format(floor), {
        { "确定", function() self.start({ mode = "bloody-palace", palaceTier = tier, palacePractice = floor }) end },
    })
end

function View:back()
    if PARENT[self.page] then self:go(PARENT[self.page]) else self.leave() end
end

function View:restoreFocus()
    self.confirmHeld = true
    self.session.buttons[1]:SetFocus()
end

function View:backState()
    if PARENT[self.page] then
        return { page = PARENT[self.page], tier = self.tier, gridPage = self.gridPage }
    end
end

function View:pageState()
    return { page = self.page, tier = self.tier, index = self.index, gridPage = self.gridPage }
end

function View:accept()
    if self.closed or self.confirmHeld then return end
    local option = self.options[self.index or 0]
    if option then
        Feedback.click(self.session.modal, option.button.widget)
        self:choose(option)
    end
end

function View:canHandleKeys()
    local modal, controller = self.session.modal, self.session.controller
    return modal:HasUserFocus(controller) or modal:HasUserFocusedDescendants(controller)
end

function View:confirmNative()
    if self.confirmHeld then return end
    self:accept()
    self.confirmHeld = true
end

local function held(router, first, second)
    return router:IsUIKeyHeld({ KeyName = FName(first) })
        or (second and router:IsUIKeyHeld({ KeyName = FName(second) })) or false
end

function UI.backHeld(router)
    return held(router, "Escape", "BackSpace") or held(router, "Gamepad_FaceButton_Right")
end

function View:update()
    if self.closed then return false end
    local focused = self:canHandleKeys()
    local hovered, mouse = UI.pointer(self.screen, self.input, self.pointerEntries)
    local layer = self.layer
    if not self.screen:update(mouse) or self.closed then return false end
    if self.session.dialog or self.layer ~= layer then return true end
    local hoverChanged = hovered ~= self.lastMouseHover
    if hoverChanged then
        self.lastMouseHover = hovered
        self.hoveredPageButton = nil
        if hovered then
            if self.options[hovered] then self:select(hovered, false)
            else self.hoveredPageButton = self.pointerEntries[hovered] end
            Feedback.menuSelect(self.session.controller, self.session.modal)
        end
    end
    local active = self.hoveredPageButton or self.options[self.index or 0]
    if mouse and hoverChanged and not hovered then active = nil
    elseif mouse and not hovered then active = self.highlighted
    elseif not focused and not mouse then active = nil end
    self:showSelection(active)
    if not focused and not mouse then return true end
    local router = self.router
    local confirm = held(router, "Enter", "SpaceBar") or held(router, "Gamepad_FaceButton_Bottom")
    if confirm and not self.confirmHeld then
        self:accept()
        self.confirmHeld = true
        return true
    elseif not confirm then
        self.confirmHeld = false
    end
    local direction
    for index, keys in ipairs(FOCUS) do if held(router, keys[1], keys[2]) then direction = index; break end end
    if direction and not self.directionHeld and #self.options > 0 then
        local delta = ({ -self.columns, self.columns, -1, 1 })[direction]
        local nextIndex = self.index + delta
        if nextIndex >= 1 and nextIndex <= #self.options then self:select(nextIndex, true)
        elseif self.navigateEdge then self.navigateEdge(direction) end
    end
    self.directionHeld = direction ~= nil
    return true
end

function View:close()
    if self.closed then return end
    self.closed = true
    self:removeLayer()
end

function UI.open(session, screen, path, start, leave, openDialog, state)
    state = state or {}
    local self = setmetatable({ session = session, screen = screen, path = path, start = start, leave = leave, openDialog = openDialog,
        tier = state.tier, gridPage = state.gridPage or 1 }, View)
    local ok, failure = pcall(function()
        local subsystems = requireObject(SUBSYSTEMS)
        self.router = subsystems:GetLocalPlayerSubsystem(session.modal, requireObject(ROUTER))
        self.input = subsystems:GetLocalPlayerSubsystem(session.modal, requireObject(INPUT))
        assert(valid(self.router) and valid(self.input), "浊梦原版输入接口未就绪")
        self:go(state.page or "difficulty")
        if state.index then self:select(state.index, false) end
    end)
    if not ok then self:close(); error(failure, 0) end
    return self
end

return UI
