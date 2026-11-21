-- Native CommonUI frontend. Save isolation and loading remain the caller's job.
local Catalog = require("EncounterCatalog")
local Profile = require("PlayerProfile")
local Scenes = require("ArenaScenes")
local Screen = require("NativeScreen")
local Art = require("ArtAssets")
local Feedback = require("ParameterFeedback")
local Home = {}

local DESCRIPTORS = "/Script/CommonGame.Default__CommonGameDialogDescriptor"
local CONFIRMATION = "/Script/CommonGame.Default__AsyncAction_ShowConfirmation"
local MODAL = "W_ConfirmationDefault_C"
local CLICK = "/Script/UMG.Widget:ForceLayoutPrepass"
local DECLINE = "/Script/ProjectPBZ.PBZConfirmationScreen:RegisterDeclineAction"
local TITLE_LEVEL = "PBZ_StartMenu_CE_WP"
local SUBSYSTEMS = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local ROUTER = "/Script/ProjectPBZ.PBZUIActionRouterBase"
local COMMON_INPUT = "/Script/CommonInput.CommonInputSubsystem"
local GAMEPLAY = "/Script/Engine.Default__GameplayStatics"
local UNBOUND_ACTION_ROW = "NewRow"
local RESULTS = { 0, 1, 2 }
local current
local showHome, showPalace
local feedbackWarnings = {}

local function logUI(message)
    print("[PBZDreamPalaceUI] " .. message .. "\n")
end

local function valid(object)
    return object ~= nil and type(object.IsValid) == "function" and object:IsValid()
end

local function unwrap(object)
    if object and type(object.IsValid) ~= "function" then
        local getter = object.get or object.Get
        if type(getter) == "function" then return getter(object) end
    end
    return object
end

local function checked(object, message)
    object = unwrap(object)
    assert(valid(object), message)
    return object
end

local function required(path)
    return checked(StaticFindObject(path), "缺少原版 MOD 菜单接口：" .. path)
end

local function inputRouter(modal)
    return required(SUBSYSTEMS):GetLocalPlayerSubsystem(modal, required(ROUTER))
end

local function routeNativeBack(session)
    -- Confirmation.js writes CancelAction during activation. Its native
    -- RegisterDeclineAction binds directly to CommonUI. NewRow in the same
    -- table has no key on any supported device.
    assert(valid(StaticFindObject(DECLINE)), "缺少原版确认返回接口")
    local restore = {}
    local pre, post = RegisterHook(DECLINE, function(context)
        local modal = unwrap(context)
        if current ~= session or not session.openingModal or not valid(modal)
            or modal:GetClass():GetFName():ToString() ~= MODAL then return end
        local owner = unwrap(modal:GetOwningPlayer())
        local address = modal:GetAddress()
        if not valid(owner) or owner:GetAddress() ~= session.controller:GetAddress()
            or session.before[address] then return end
        local action = modal.CancelAction
        restore[address] = action.RowName:ToString()
        action.RowName = FName(UNBOUND_ACTION_ROW)
    end, function(context)
        local modal = unwrap(context)
        local address = valid(modal) and modal:GetAddress()
        local row = address and restore[address]
        if row then
            modal.CancelAction.RowName = FName(row)
            restore[address] = nil
        end
    end)
    session.declineHook = { pre, post }
end

local function feedback(kind, ...)
    local ok, failure = pcall(Feedback[kind], ...)
    if not ok and not feedbackWarnings[kind] then
        feedbackWarnings[kind] = true
        print("[PBZTestArenaNative] Home " .. kind .. " feedback: " .. tostring(failure) .. "\n")
    end
end

local function restoreHomeSound(session)
    for _, item in ipairs(session.homeSound or {}) do
        if valid(item.button) then item.button.bCanPlaySound = item.enabled end
    end
    session.homeSound = nil
end

local function activateHomeEntry(session)
    local index = session.homeIndex or 1
    feedback("click", session.modal, session.homeEntries[index].button.widget)
    session.page.modeActions[index]()
end

local function updateIllustration(session, index)
    if session.illustrationIndex == index then return end
    session.illustrationIndex = index
    session.illustration = require("DreamPalaceUI").illustration(session.palaceScreen,
        session.illustrationLayer, session.illustration, index)
end

local function updateHomeSelection(session, focused, hovered, mouse, hoverChanged)
    if session.homeEntries then
        updateIllustration(session, session.homeIndex)
        for index, entry in ipairs(session.homeEntries) do
            local active = session.homeIndex == index
            local selected = active and (focused or hovered == index)
            if mouse and not hovered then selected = not hoverChanged and entry.button.selected end
            entry.button:setSelected(selected)
        end
        return
    end
    local skin = session.screen
    if not skin or not session.homeCards then return end
    local gamepad = valid(session.homeInput) and session.homeInput:GetCurrentInputType() == 1
    local focused, hovered
    for index, card in ipairs(session.homeCards) do
        local native = session.buttons[index]
        if native:HasUserFocus(session.controller) or native:HasUserFocusedDescendants(session.controller) then focused = index end
        if card.button:IsHovered() then hovered = index end
    end
    if gamepad and focused and focused ~= session.homeLastFocused then
        feedback("navigate", session.controller, session.modal)
    end
    if focused then session.homeLastFocused = focused end
    local selected = gamepad and focused or hovered
    skin.selectedButton = selected
    for index, card in ipairs(session.homeCards) do
        local active = selected == index
        card.image:SetRenderOpacity(active and 1 or .68)
        card.caption:OverrideTextColor({ SpecifiedColor = {
            R = active and 1 or .76, G = active and .79 or .73, B = active and .43 or .65, A = 1 }, ColorUseRule = 0 })
        for _, line in ipairs(card.lines) do line:SetRenderOpacity(active and 1 or 0) end
    end
end

local function palaceScreen(session)
    if not session.palaceScreen then
        session.palaceScreen = Screen.open(session.modal, session.controller, { behindDialog = true, plainBackdrop = true })
        session.palaceScreen.titleButtonTemplate = unwrap(session.menu.LoadGame)
        session.illustrationLayer = session.palaceScreen:panel(0, 0, 1920, 1080)
        session.illustrationLayer:SetVisibility(3)
        session.illustrationLayer.Slot:SetZOrder(5)
    end
    return session.palaceScreen
end

local function clearHomeLayer(session)
    if not session.homeLayer then return end
    for _, entry in ipairs(session.homeEntries or {}) do entry.button:setSelected(false) end
    session.palaceScreen:releaseButtons(session.homeLayer)
    session.homeLayer:RemoveFromParent()
    session.homeLayer = nil
end

local function closePalaceScreen(session)
    if session.palaceScreen then session.palaceScreen:close() end
    session.palaceScreen, session.illustrationLayer, session.illustration, session.illustrationIndex = nil, nil, nil, nil
end

local function text(value)
    return type(value) == "string" and value or (value and value:ToString() or "")
end

local function number(value, maximum, fallback)
    if type(value) ~= "number" or value ~= math.floor(value) or value < 0 or value > maximum then
        return fallback
    end
    return value
end

local function settingsCopy(settings, mode)
    mode = mode or settings.mode or "training"
    local cycle = Profile.valid(settings.playerCycle) and settings.playerCycle or 6
    local selectedId = settings.encounterId or settings.bossId
    local entry = Catalog.resolve(selectedId)
    if not entry or entry.legacy then
        entry = Catalog.list(Catalog.retiredCategory(selectedId) or settings.category or "duel")[1] or Catalog.list("duel")[1]
    end
    assert(entry, "MOD 挑战名单为空")
    local sceneId = Scenes.normalize(settings.sceneId)
    if not Scenes.available(sceneId, mode) or (mode == "training" and sceneId == "meiguhu") then
        sceneId = Scenes.available("lake", mode) and "lake" or "night"
    end
    return {
        mode = mode, bossId = entry.id, encounterId = entry.id,
        category = entry.category, playerCycle = cycle,
        enemyCycle = number(settings.enemyCycle, 6, 0),
        skillLevel = Profile.normalizeSkillLevel(cycle, number(settings.skillLevel, Profile.skillCap(cycle), Profile.skillCap(cycle))),
        difficultyMode = number(settings.difficultyMode, 3, 3) >= 1 and number(settings.difficultyMode, 3, 3) or 3,
        sceneId = sceneId, musicId = settings.musicId,
    }
end

local function ownModals(controller)
    local found = {}
    for _, candidate in ipairs(FindAllOf(MODAL) or {}) do
        local modal = unwrap(candidate)
        if valid(modal) and modal:IsActivated() then
            local owner = unwrap(modal:GetOwningPlayer())
            if valid(owner) and owner:GetAddress() == controller:GetAddress() then
                found[modal:GetAddress()] = modal
            end
        end
    end
    return found
end

local function setButtons(session, labels, actions, manual, home)
    for index, button in ipairs(session.buttons) do
        local action = actions[index]
        button:SetButtonText(FText(labels[index] or ""))
        button:SetVisibility(action and 0 or 1)
        button:SetIsEnabled(action ~= nil)
        if manual or session.manualNavigation then
            for direction = 0, 3 do button:SetNavigationRuleBase(direction, manual and 3 or 0) end
        end
        session.actions[session.pulses[index]:GetAddress()] = action and { run = action, index = index, home = home } or nil
    end
    session.manualNavigation = manual
end

local function applyPage(session)
    local page = session.page
    if not page or not valid(session.modal) or not session.modal:IsActivated() or #session.buttons ~= #page.labels then return end
    if session.form then session.form:close(); session.form = nil end
    if session.palaceView then session.palaceView:close(); session.palaceView = nil end
    clearHomeLayer(session)
    restoreHomeSound(session)
    session.homeCards, session.homeInput = nil, nil
    session.homeEntries = nil
    if session.screen then session.screen:close(); session.screen = nil end
    local palacePage = page.mount ~= nil or (page.home and session.palacePath)
    if not palacePage then closePalaceScreen(session) end
    session.title:SetText(FText(page.title))
    session.description:SetText(FText(page.body))
    setButtons(session, page.labels, page.actions, palacePage and true or false, page.home)
    session.buttons[page.focus or 2]:SetFocus()
    if page.mount then
        local skin = palaceScreen(session)
        updateIllustration(session, session.homeIndex)
        session.palaceView = page.mount(skin)
    elseif page.model then
        session.form = page.model:mount(session.modal, session.description, session.controller, session.buttons[1], {
            title = page.title,
            onConfirm = page.actions[1], onBack = page.actions[2],
        })
    elseif page.home then
        local skin
        if session.palacePath then skin = palaceScreen(session)
        else
            skin = Screen.open(session.modal, session.controller, { title = "影境演武" })
            session.screen = skin
        end
        session.homeCards, session.homeSound, session.homeLastFocused = {}, {}, page.focus or 1
        session.homeLastHovered = nil
        session.homeInput = checked(required(SUBSYSTEMS):
            GetLocalPlayerSubsystem(session.modal, required(COMMON_INPUT)), "首页输入模式不可用")
        session.homeDirectionHeld, session.homeConfirmHeld = true, true
        if session.palacePath then
            local ui = require("DreamPalaceUI")
            local labels = { "测试场", "练习模式", "挑战模式", require("DreamPalaceProfile").name }
            session.homeIndex = session.homeIndex or 1
            session.homeEntries = {}
            local layer = skin:panel(0, 0, 1920, 1080)
            session.homeLayer = layer
            ui.heading(skin, page.title, layer)
            for index, label in ipairs(labels) do
                local function action()
                    session.homeIndex = index
                    page.modeActions[index]()
                end
                local x, y, width, height = ui.railPosition(index)
                local button = ui.button(skin, label, x, y, width, height, action, layer, false, true)
                session.homeEntries[index] = { button = button }
            end
            ui.footer(skin, layer, nil, true, Home.close)
            updateHomeSelection(session, true)
            logUI("page=home")
            return
        end
        for index, id in ipairs({ "test", "practice", "challenge" }) do
            local x = 80 + (index - 1) * 590
            local texture, meta = Art.home(session.modal, id)
            local image = skin:image(texture, meta, x, 190, 570, 650, nil, true)
            skin:shade(x, 700, 570, 140, .65)
            local button = skin:button(page.labels[index], x, 190, 570, 650, page.actions[index])
            -- Artwork and label remain distinct layers so the click rectangle
            -- is the whole third, not just the caption.
            local caption = skin:textScaled(page.labels[index], x + 55, 730, 460, 100, 2.1, true)
            caption:SetJustification(1)
            skin.buttons[index].caption:SetRenderOpacity(0)
            skin.buttons[index].caption = caption
            local lines = {
                skin:shade(x, 190, 570, 3, 1), skin:shade(x, 837, 570, 3, 1),
                skin:shade(x, 190, 3, 650, 1), skin:shade(x + 567, 190, 3, 650, 1),
            }
            for _, line in ipairs(lines) do
                line:SetBrushColor({ R = .91, G = .72, B = .34, A = 1 })
                line.Slot:SetZOrder(21)
            end
            session.homeCards[index] = { button = button, image = image, caption = caption, lines = lines }
            local native = session.buttons[index]
            assert(type(native.bCanPlaySound) == "boolean", "首页原生按钮没有声音开关")
            session.homeSound[index] = { button = native, enabled = native.bCanPlaySound }
            feedback("configureArrow", native)
        end
        skin:button("返回", 820, 950, 280, 70, Home.close)
        updateHomeSelection(session)
    elseif page.formRows then
        session.screen = Screen.open(session.modal, session.controller, { title = page.title })
        local placeholder, box = session.screen:placeholder()
        session.screen:place(box, 540, 300, 840, 400)
        -- The test field keeps one native form, including the shared scene row;
        -- it is not part of the player/enemy staged selector.
        session.form = require("ParameterForm").open(session.modal, placeholder,
            session.controller, session.buttons[1], page.formRows)
        session.screen:setFooter(page.actions[1], page.actions[2], "进入")
    end
end

local function page(session, title, body, labels, actions, back, focus, formRows, model, home)
    session.page = { title = title, body = body, labels = labels, actions = actions, back = back,
        focus = focus, formRows = formRows, model = model, home = home }
    applyPage(session)
end

local function detach(session)
    if session.form then session.form:close(); session.form = nil end
    if session.palaceView then session.palaceView:close(); session.palaceView = nil end
    clearHomeLayer(session)
    closePalaceScreen(session)
    session.dialog, session.router = nil, nil
    if session.tapZoneVisibility and valid(session.tapZone) then session.tapZone:SetVisibility(session.tapZoneVisibility) end
    session.tapZone, session.tapZoneVisibility = nil, nil
    if session.screen then session.screen:close(); session.screen = nil end
    restoreHomeSound(session)
    session.homeCards, session.homeInput = nil, nil
    session.homeEntries = nil
    local active = valid(session.modal) and session.modal:IsActivated()
    for index, button in ipairs(session.buttons) do
        if active and valid(button) then
            if session.manualNavigation then for direction = 0, 3 do button:SetNavigationRuleBase(direction, 0) end end
            local click = button.OnButtonBaseClicked
            click:Clear()
            for _, binding in ipairs(session.bindings[index] or {}) do
                local object = unwrap(binding.Object)
                if valid(object) then click:Add(object, binding.FunctionName) end
            end
        end
    end
    for _, pulse in ipairs(session.pulses) do
        if valid(pulse) then pulse:RemoveFromParent() end
    end
    session.buttons, session.pulses, session.actions, session.bindings = {}, {}, {}, {}
    session.manualNavigation = nil
end

local function requestModal(session)
    session.before = ownModals(session.controller)
    assert(next(session.before) == nil, "请先关闭当前原版弹窗，再打开 MOD")
    session.deadline = os.time() + 4
    local descriptor = checked(required(DESCRIPTORS):CreateConfirmationOk(
        session.menu, FText(session.page.title), FText(session.page.body)), "无法创建原版 MOD 弹窗描述")
    for index = 1, #session.page.labels do
        descriptor.ButtonActions[index] = {
            Result = RESULTS[index], OptionalDisplayText = FText(session.page.labels[index]),
        }
    end
    session.request = checked(required(CONFIRMATION):ShowConfirmationCustom(session.menu, descriptor),
        "无法请求原版 MOD 弹窗")
    session.openingModal = true
    session.request:Activate()
end

local function attach(session, modal)
    session.modal = modal
    session.openingModal = nil
    local tree = checked(modal.WidgetTree, "原版 MOD 弹窗缺少控件树")
    local root = checked(tree.RootWidget, "原版 MOD 弹窗缺少根控件")
    session.title = checked(modal.Text_Title, "原版 MOD 弹窗缺少标题")
    session.description = checked(modal.RichText_Description, "原版 MOD 弹窗缺少正文")
    local group, entries = unwrap(modal.ButtonGroup)
    if valid(group) then
        assert(group:GetButtonCount() == #session.page.labels, "原版 MOD 弹窗的按钮数量不符")
    else
        entries = checked(modal.EntryBox_Buttons, "原版 MOD 弹窗缺少按钮容器"):GetAllEntries()
        assert(#entries == #session.page.labels, "原版 MOD 弹窗的按钮数量不符")
    end
    for index = 1, #session.page.labels do
        local button = checked(entries and entries[index] or group:GetButtonBaseAtIndex(index - 1),
            "原版 MOD 按钮尚未就绪 " .. index)
        local pulse = checked(StaticConstructObject(required("/Script/UMG.TextBlock"), root),
            "无法创建原版 MOD 按钮回调")
        pulse:SetVisibility(1)
        checked(root:AddChildToOverlay(pulse), "无法挂载原版 MOD 按钮回调")
        session.buttons[index], session.pulses[index] = button, pulse
        local click = button.OnButtonBaseClicked
        session.bindings[index] = click:GetBindings()
        click:Clear()
        click:Add(pulse, FName("ForceLayoutPrepass"))
    end
    if session.palacePath then
        session.router = checked(inputRouter(modal), "原版菜单输入接口未就绪")
        session.backHeld = true
        local tapZone = modal.Border_TapToCloseZone
        if not valid(tapZone) then
            for index = 0, root:GetChildrenCount() - 1 do
                local child = root:GetChildAt(index)
                if child:GetFName():ToString() == "Border_TapToCloseZone" then tapZone = child; break end
            end
        end
        if valid(tapZone) then
            session.tapZone, session.tapZoneVisibility = tapZone, tapZone:GetVisibility()
            tapZone:SetVisibility(3)
        end
    end
    applyPage(session)
end

local function attachIfReady(session)
    local selected
    for address, modal in pairs(ownModals(session.controller)) do
        if not session.before[address] then
            assert(not selected, "存在多个新打开的原版 MOD 弹窗")
            selected = modal
        end
    end
    if selected then attach(session, selected); return true end
    assert(os.time() <= session.deadline, "等待原版 MOD 弹窗超时")
    return false
end

function Home.close()
    local session = current
    if not session then return end
    current = nil
    if session.hook then pcall(UnregisterHook, CLICK, session.hook[1], session.hook[2]) end
    if session.declineHook then pcall(UnregisterHook, DECLINE, session.declineHook[1], session.declineHook[2]) end
    local modal = session.modal
    local ok, failure = pcall(detach, session)
    if not ok then logUI("menu cleanup failed: " .. tostring(failure)) end
    if valid(modal) and modal:IsActivated() then modal:CloseWindowByCancel() end
end

function Home.isOpen()
    return current ~= nil
end

local function start(session, settings, mode)
    local chosen = mode == "bloody-palace" and settings
        or settingsCopy(settings, mode)
    if mode == "training" then chosen.bossId, chosen.encounterId, chosen.category = nil, nil, nil end
    session.starting = chosen
    session.pending = nil
    -- The title caller must not load a map while CommonUI still owns this modal.
    checked(session.modal, "原版 MOD 弹窗已关闭"):CloseWindowByCancel()
end

local function closePalaceDialog(session)
    session.dialog, session.pending = nil, nil
    session.palaceScreen:showNativeDialog(false)
    local view = session.palaceView
    view.layer:SetVisibility(4)
    session.title:SetText(FText(session.page.title))
    session.description:SetText(FText(session.page.body))
    setButtons(session, session.page.labels, session.page.actions, true)
    view:restoreFocus()
    session.backHeld = true
end

local function showPalaceDialog(session, body, buttons, onCancel)
    local function cancel()
        if onCancel then onCancel()
        else closePalaceDialog(session) end
    end
    assert(session.palaceView and #buttons < #session.buttons, "原版确认按钮不足")
    local cancelIndex = #buttons + 1
    session.dialog = { cancel = cancel }
    session.backHeld = true
    session.palaceScreen.pending = {}
    session.palaceView.layer:SetVisibility(3)
    session.palaceScreen:showNativeDialog(true)
    if valid(session.tapZone) then session.tapZone:SetVisibility(3) end
    session.title:SetText(FText(""))
    session.description:SetText(FText(body))
    local labels, actions = {}, {}
    for index, item in ipairs(buttons) do labels[index], actions[index] = item[1], item[2] end
    labels[cancelIndex], actions[cancelIndex] = "取消", cancel
    setButtons(session, labels, actions, false)
    session.buttons[cancelIndex]:SetFocus()
end

showPalace = function(session, state)
    session.homeIndex = 4
    local selectedPage = {
        title = "", body = "", labels = { "", "", "" }, focus = 1,
        actions = { function()
            if session.palaceView then session.palaceView:confirmNative() end
        end },
    }
    selectedPage.back = function() showHome(session) end
    selectedPage.mount = function(screen)
        return require("DreamPalaceUI").open(session, screen, session.palacePath,
            function(settings) start(session, settings, "bloody-palace") end,
            function() showHome(session) end,
            function(body, buttons, onCancel)
                showPalaceDialog(session, body, buttons, onCancel)
            end, state)
    end
    session.page = selectedPage
    applyPage(session)
end

local function showSettings(session, mode)
    local settings = session.settings
    settings.mode = mode
    local rows = {}
    local model
    if mode == "challenge" or mode == "practice" then
        model = require("ChallengeTarget").form(settings, session.initial)
        settings = model.settings
        settings.mode = mode
        session.settings = settings
        rows = model.rows
    else
        if settings.sceneId == "meiguhu" then settings.sceneId = "lake" end
        rows[#rows + 1] = {
            label = "玩家轮回", value = function() return Profile.rank(settings.playerCycle) end,
            change = function(delta)
                local cycle = math.max(-1, math.min(6, settings.playerCycle + delta))
                if cycle ~= settings.playerCycle then
                    settings.playerCycle = cycle
                    settings.skillLevel = Profile.normalizeSkillLevel(cycle,
                        cycle == session.initial.playerCycle and session.initial.skillLevel or Profile.skillCap(cycle))
                end
            end,
        }
        rows[#rows + 1] = {
            label = "敌人轮回",
            value = function() return Profile.rank(settings.enemyCycle, "enemy") end,
            change = function(delta) settings.enemyCycle = math.max(0, math.min(6, settings.enemyCycle + delta)) end,
        }
        rows[#rows + 1] = {
            label = "技能等级",
            value = function() return settings.playerCycle == -1 and "-" or tostring(settings.skillLevel) .. " / " .. tostring(Profile.skillCap(settings.playerCycle)) end,
            enabled = function() return settings.playerCycle ~= -1 end,
            change = function(delta)
                if settings.playerCycle ~= -1 then settings.skillLevel = math.max(0, math.min(Profile.skillCap(settings.playerCycle), settings.skillLevel + delta)) end
            end,
        }
        rows[#rows + 1] = {
            label = "场景", value = function() return Scenes.get(settings.sceneId).name end,
            enabled = function() return #Scenes.list(false) > 1 end,
            change = function(delta)
                local choices, selected = Scenes.list(false), 1
                for index, scene in ipairs(choices) do if scene.id == settings.sceneId then selected = index end end
                settings.sceneId = choices[(selected - 1 + delta) % #choices + 1].id
            end,
        }
    end
    page(session, mode == "challenge" and "挑战模式" or mode == "practice" and "练习模式" or "测试场", "",
        { "进入", "返回", "" }, {
            function()
                if session.form and (model and session.form:confirm() or not model and session.form:canConfirm()) then start(session, settings, mode) end
            end,
            function() showHome(session) end,
        }, function() showHome(session) end, 1, model and nil or rows, model)
end

showHome = function(session)
    local actions = {
        function() showSettings(session, "training") end,
        function() showSettings(session, "practice") end,
        function() showSettings(session, "challenge") end,
    }
    if not session.palacePath then
        page(session, "影境演武", "", { "测试场", "练习模式", "挑战模式" }, actions, Home.close, 1, nil, nil, true)
        return
    end
    actions[4] = function() showPalace(session) end
    session.page = { title = "影境演武", body = "", labels = { "", "", "" }, home = true, focus = 1,
        back = Home.close, modeActions = actions,
        actions = { function()
            if not session.homeConfirmHeld then
                session.homeConfirmHeld = true
                activateHomeEntry(session)
            end
        end },
    }
    applyPage(session)
end

local function openPage(session, show)
    Home.close()
    current = session
    local ok, failure = pcall(function()
        local pre, post = RegisterHook(CLICK, function(context)
            if current ~= session or session.pending or session.starting then return end
            local pulse = unwrap(context:get())
            if valid(pulse) then session.pending = session.actions[pulse:GetAddress()] end
        end)
        session.hook = { pre, post }
        show(session)
        if session.palacePath then routeNativeBack(session) end
        requestModal(session)
        attachIfReady(session)
    end)
    if not ok then
        if session.palacePath then logUI("menu open failed: " .. tostring(failure)) end
        Home.close()
        error(failure, 0)
    end
    return true
end

function Home.open(menu, controller, defaults, onStart, palacePath)
    checked(menu, "找不到原版标题菜单")
    checked(controller, "找不到标题菜单的本地控制器")
    assert(type(onStart) == "function", "缺少 MOD 开始回调")
    local restored = defaults or {}
    if restored.sceneId == "day" then
        local migrated = {}; for key, value in pairs(restored) do migrated[key] = value end
        migrated.sceneId, restored = "night", migrated
    end
    local initial = settingsCopy(restored)
    local session = {
        menu = menu, controller = controller, onStart = onStart, settings = settingsCopy(initial), initial = initial,
        buttons = {}, pulses = {}, actions = {}, bindings = {}, palacePath = palacePath,
    }
    return openPage(session, showHome)
end

function Home.prompt(pawn, controller, title, body, onExit)
    local world = checked(require("SceneArena").runtimeWorld(pawn), "血宫界面场景未就绪")
    local session = { menu = pawn, controller = controller, arenaWorld = world:GetAddress(), onStart = onExit,
        buttons = {}, pulses = {}, actions = {}, bindings = {} }
    local function exit()
        session.starting, session.pending = true, nil
        if valid(session.modal) and session.modal:IsActivated() then session.modal:CloseWindowByCancel() end
    end
    return openPage(session, function()
        page(session, title, body, { "返回主界面", "", "" }, { exit }, exit, 1)
    end)
end

function Home.updatePalaceInput(gameplay)
    local session = current
    if session and session.palacePath and not session.starting then
        session.gameplay = gameplay or session.gameplay or required(GAMEPLAY)
        return Home.update(session.gameplay)
    end
end

function Home.update(gameplay)
    local session = current
    if not session then return false end
    local ok, failure = pcall(function()
        if not valid(session.menu) or not valid(session.controller) then
            Home.close(); return
        end
        if session.arenaWorld then
            local world = require("SceneArena").runtimeWorld(session.menu)
            if not valid(world) or world:GetAddress() ~= session.arenaWorld then Home.close(); return end
        elseif gameplay and text(gameplay:GetCurrentLevelName(session.menu, true)) ~= TITLE_LEVEL then
            Home.close(); return
        end
        if session.starting then
            if valid(session.modal) and session.modal:IsActivated() then return end
            local chosen, callback = session.starting, session.onStart
            Home.close()
            callback(chosen)
        elseif session.modal and (not valid(session.modal) or not session.modal:IsActivated()) then
            local back = session.page and session.page.back
            local innerBack = session.form and session.form.back and session.form:back()
            local returnState = session.palaceView
                and (session.dialog and session.palaceView:pageState() or session.palaceView:backState())
            if session.palaceView then logUI("native modal deactivated before page back") end
            session.pending = nil
            detach(session)
            session.modal = nil
            session.openingModal = nil
            if returnState then showPalace(session, returnState)
            elseif not innerBack then
                if back then back() else Home.close(); return end
            end
            if current == session and not session.starting then
                requestModal(session)
                attachIfReady(session)
            end
        elseif session.pending then
            local action = session.pending
            session.pending = nil
            if action.home and session.page and session.page.home and not session.palacePath then
                feedback("click", session.modal, session.buttons[action.index])
            end
            action.run()
        elseif not session.modal then
            attachIfReady(session)
        end
        if current ~= session or session.starting or not valid(session.modal) then return end
        local wasBackHeld = session.backHeld
        if session.router then session.backHeld = require("DreamPalaceUI").backHeld(session.router) end
        local backPressed = session.backHeld and not wasBackHeld
        if backPressed then
            if session.dialog then session.dialog.cancel()
            elseif session.form then
                if not (session.form.back and session.form:back()) then session.page.back() end
            elseif session.palaceView then session.palaceView:back()
            elseif session.homeEntries then Home.close() end
            return
        elseif session.dialog then return
        elseif session.form then
            session.form:update(gameplay)
        elseif session.palaceView then
            session.palaceView:update()
        end
        if session.screen and not session.starting then
            session.screen:update()
            if session.page.home then updateHomeSelection(session) end
        end
        if session.homeEntries then
            local screen = session.palaceScreen
            local hovered, mouse = require("DreamPalaceUI").pointer(screen, session.homeInput, session.homeEntries)
            screen:update(mouse)
            if current ~= session or session.palaceScreen ~= screen or not session.homeEntries then return end
            local focused = session.modal:HasUserFocus(session.controller)
                or session.modal:HasUserFocusedDescendants(session.controller)
            local hoverChanged = hovered ~= session.homeLastHovered
            if hovered and hoverChanged then
                session.homeIndex = hovered
                feedback("menuSelect", session.controller, session.modal)
            end
            session.homeLastHovered = hovered
            updateHomeSelection(session, focused, hovered, mouse, hoverChanged)
            if not focused and not mouse then return end
            local function held(key) return session.router:IsUIKeyHeld({ KeyName = FName(key) }) end
            local up = held("Up") or held("Gamepad_DPad_Up") or held("Gamepad_LeftStick_Up")
            local down = held("Down") or held("Gamepad_DPad_Down") or held("Gamepad_LeftStick_Down")
            local confirm = held("Enter") or held("SpaceBar") or held("Gamepad_FaceButton_Bottom")
            if (up or down) and not session.homeDirectionHeld then
                session.homeIndex = (session.homeIndex + (up and -1 or 1) - 1) % #session.homeEntries + 1
                feedback("menuSelect", session.controller, session.modal)
                updateHomeSelection(session, true)
            end
            session.homeDirectionHeld = up or down
            if confirm and not session.homeConfirmHeld then activateHomeEntry(session); return end
            session.homeConfirmHeld = confirm
        end
    end)
    if not ok then
        if session.palacePath then logUI("menu update failed: " .. tostring(failure)) end
        Home.close()
        error(failure, 0)
    end
    return current ~= nil
end

return Home
