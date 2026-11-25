-- Native CommonUI frontend. Save isolation and loading remain the caller's job.
local Catalog = require("EncounterCatalog")
local Profile = require("PlayerProfile")
local PlayerCustom = require("PlayerCustom")
local Menus = require("ArenaMenuCatalog")
local Screen = require("NativeScreen")
local Art = require("ArtAssets")
local Feedback = require("ParameterFeedback")
local FirstEntry = require("FirstEntryPrompts")
local DisplayPreferences = require("DisplayPreferences")
local ModLoaderSettings = require("ModLoaderSettings")
local Home = {}

local DESCRIPTORS = "/Script/CommonGame.Default__CommonGameDialogDescriptor"
local CONFIRMATION = "/Script/CommonGame.Default__AsyncAction_ShowConfirmation"
local MODAL = "W_ConfirmationDefault_C"
local CLICK = "/Script/UMG.Widget:ForceLayoutPrepass"
local DECLINE = "/Script/ProjectPBZ.PBZConfirmationScreen:RegisterDeclineAction"
local KILL = "/Script/ProjectPBZ.PBZConfirmationScreen:RegisterKillAction"
local TITLE_LEVEL = "PBZ_StartMenu_CE_WP"
local SUBSYSTEMS = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local ROUTER = "/Script/ProjectPBZ.PBZUIActionRouterBase"
local COMMON_INPUT = "/Script/CommonInput.CommonInputSubsystem"
local GAMEPLAY = "/Script/Engine.Default__GameplayStatics"
local KISMET = "/Script/Engine.Default__KismetSystemLibrary"
local UNBOUND_ACTION_ROW = "NewRow"
local NO_BYPASS = { { DECLINE, "CancelAction" }, { KILL, "KillAction" } }
local RESULTS = { 0, 1, 2 }
local current
local showHome, showPalace, openModFeatures, closeModFeatures
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
    -- Stock CommonUI Back must pass through our current page before closing.
    session.backHooks = {}
    for _, binding in ipairs(NO_BYPASS) do
        local path, field = table.unpack(binding)
        assert(valid(StaticFindObject(path)), "缺少原版确认返回接口")
        local restore = {}
        local pre, post = RegisterHook(path, function(context)
            local modal = unwrap(context)
            if current ~= session or not session.openingModal or not valid(modal)
                or modal:GetClass():GetFName():ToString() ~= MODAL then return end
            local owner = unwrap(modal:GetOwningPlayer())
            local address = modal:GetAddress()
            if not valid(owner) or owner:GetAddress() ~= session.controller:GetAddress()
                or session.before[address] then return end
            local action = modal[field]
            restore[address] = action.RowName:ToString()
            action.RowName = FName(UNBOUND_ACTION_ROW)
        end, function(context)
            local modal = unwrap(context)
            local address = valid(modal) and modal:GetAddress()
            local row = address and restore[address]
            if row then
                modal[field].RowName = FName(row)
                restore[address] = nil
            end
        end)
        session.backHooks[#session.backHooks + 1] = { path, pre, post }
    end
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

local HOME_CARD_MODES = { "test", "practice", "challenge" }
local function updateIllustration(session, index)
    if session.illustrationIndex == index then return end
    session.illustrationIndex = index
    if session.palacePath then
        session.illustration = require("DreamPalaceUI").illustration(session.palaceScreen,
            session.illustrationLayer, session.illustration, index)
    else
        local texture, meta = Art.home(session.modal, HOME_CARD_MODES[index])
        session.illustration = session.palaceScreen:modeBackground(texture, meta, session.illustrationLayer, session.illustration)
    end
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
        if card.image then card.image:SetRenderOpacity(active and 1 or .68) end
        card.caption:OverrideTextColor({ SpecifiedColor = {
            R = active and 1 or .76, G = active and .79 or .73, B = active and .43 or .65, A = 1 }, ColorUseRule = 0 })
        for _, line in ipairs(card.lines) do line:SetRenderOpacity(active and 1 or 0) end
    end
end

local function palaceScreen(session)
    if not session.palaceScreen then
        session.palaceScreen = Screen.open(session.modal, session.controller, { behindDialog = true, plainBackdrop = true })
        if not session.arenaWorld then session.palaceScreen.titleButtonTemplate = unwrap(session.menu.LoadGame) end
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
    local sceneId, sceneChoice = Menus.resolveScene(mode ~= "training" and entry or nil,
        settings.sceneChoice or settings.sceneId, mode)
    local customPlayer = PlayerCustom.copy(settings.customPlayer, cycle)
    return {
        mode = mode, bossId = entry.id, encounterId = entry.id,
        category = entry.category, playerCycle = cycle,
        enemyCycle = number(settings.enemyCycle, 6, 0),
        skillLevel = customPlayer.skill or Profile.normalizeSkillLevel(cycle,
            number(settings.skillLevel, Profile.skillCap(cycle), Profile.skillCap(cycle))),
        difficultyMode = require("GameplayDifficulty").valid(settings.difficultyMode) and settings.difficultyMode or 3,
        customPressure = (mode == "practice" or mode == "challenge")
            and require("GameplayDifficulty").copyPressure(settings.customPressure) or nil,
        sceneId = sceneId, sceneChoice = sceneChoice, musicId = settings.musicId,
        trainingMobId = settings.trainingMobId,
        customPlayer = customPlayer, customProfiles = PlayerCustom.copyProfiles(settings.customProfiles),
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

local function focusDialog(session, count)
    local ui = require("DreamPalaceUI")
    session.dialogInput = { count = count, release = ui.confirmHeld(session.router),
        direction = ui.direction(session.router), selected = 1 }
    session.buttons[1]:SetFocus()
end

local function updateDialogInput(session)
    local input, ui = session.dialogInput, require("DreamPalaceUI")
    if not ui.confirmHeld(session.router) then input.release = false end
    local direction = ui.direction(session.router)
    local changed = direction and direction ~= input.direction
    input.direction = direction
    if input.count == 1 then return end
    local selected
    for index = 1, input.count do
        local button = session.buttons[index]
        if button:HasUserFocus(session.controller) or button:HasUserFocusedDescendants(session.controller) then
            selected = index
            break
        end
    end
    if changed then
        local delta = (direction == 1 or direction == 3) and -1 or 1
        selected = ((selected or input.selected) - 1 + delta) % input.count + 1
        session.buttons[selected]:SetFocus()
    end
    if selected and selected ~= input.selected then
        input.selected = selected
        if session.page.confirmationSound and session.popupHoverSound then
            feedback("navigate", session.controller, session.modal, session.popupHoverSound)
        end
    end
end

local function useManualHoverSound(session)
    if session.popupHoverSound then return end
    local sound = unwrap(session.modal.PopupHoverSound)
    if not valid(sound) then return end
    session.popupHoverSound = sound
    local ok, failure = pcall(function()
        required(KISMET):SetObjectPropertyByName(session.modal, FName("PopupHoverSound"), nil)
        assert(not valid(unwrap(session.modal.PopupHoverSound)), "原版选中音效仍然启用")
    end)
    if not ok then
        session.popupHoverSound = nil
        logUI("manual confirmation hover sound: " .. tostring(failure))
    end
end

local function applyPage(session)
    local page = session.page
    if not page or not valid(session.modal) or not session.modal:IsActivated() or #session.buttons ~= #page.labels then return end
    closeModFeatures(session)
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
    setButtons(session, page.labels, page.actions, palacePage or session.settlement ~= nil or page.firstEntry, page.home)
    if page.confirmationSound and not (session.settlement and session.settlement.floorResult) then useManualHoverSound(session) end
    if session.settlement or page.firstEntry then focusDialog(session, page.actions[2] and 2 or 1)
    else session.buttons[page.focus or 2]:SetFocus() end
    if session.settlement and session.settlement.floorResult then
        local ok, view = pcall(function()
            return require("DreamPalaceResultView").openFloor(session.modal, session.controller,
                session.settlement.floorResult, session.buttons[1], session.confirmFloor)
        end)
        if ok then session.screen = view
        else logUI("final floor layout fallback: " .. tostring(view)) end
    elseif session.settlement and session.settlement.report and not (session.settlement.step or session.settlement.notice) then
        local ok, view = pcall(function()
            return require("DreamPalaceResultView").open(session.modal, session.controller,
                session.settlement.report, page.labels[1], session.onStart, session.settlement.endingTitle)
        end)
        if ok then session.screen = view
        else logUI("settlement layout fallback: " .. tostring(view)) end
    elseif page.mount then
        local skin = palaceScreen(session)
        updateIllustration(session, session.homeIndex)
        session.palaceView = page.mount(skin)
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
            local openFeatures = session.preferences and function() openModFeatures(session) end
            session.modFeaturesHeld = true
            ui.footer(skin, layer, openFeatures and "MOD 与功能", openFeatures, nil, true, Home.close)
            updateHomeSelection(session, true)
            logUI("page=home")
            return
        end
        for index, id in ipairs(HOME_CARD_MODES) do
            local x = 80 + (index - 1) * 590
            local texture, meta = Art.home(session.modal, id)
            local art = skin:backgroundImage(texture, meta, x + 12, 202, 546, 626)
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
            session.homeCards[index] = { button = button, image = art and art.frame, caption = caption, lines = lines }
            local native = session.buttons[index]
            assert(type(native.bCanPlaySound) == "boolean", "首页原生按钮没有声音开关")
            session.homeSound[index] = { button = native, enabled = native.bCanPlaySound }
            feedback("configureArrow", native)
        end
        skin:button("返回", 820, 950, 280, 70, Home.close)
        updateHomeSelection(session)
    end
end

local function page(session, title, body, labels, actions, back, focus, home, confirmationSound)
    session.page = { title = title, body = body, labels = labels, actions = actions, back = back,
        focus = focus, home = home, confirmationSound = confirmationSound }
    applyPage(session)
end

local function restoreHoverSound(session)
    local sound = session.popupHoverSound
    session.popupHoverSound = nil
    if valid(sound) and valid(session.modal) then
        local ok, failure = pcall(function()
            required(KISMET):SetObjectPropertyByName(session.modal, FName("PopupHoverSound"), sound)
        end)
        if not ok then logUI("confirmation hover sound restore: " .. tostring(failure)) end
    end
end

local function stopPalaceInput(session, reason)
    local timer = session.palaceInputTimer
    session.palaceInputTimer = nil
    if timer then timer:stop(reason) end
end

function Home.stopPalaceInput(reason)
    local session = current
    if not session then return end
    -- The old modal may be observed once more while native map loading starts.
    session.palaceInputBlocked = true
    stopPalaceInput(session, reason)
end

local function startPalaceInput(session, modal)
    if not session.palacePath or session.palaceInputBlocked or session.starting
        or not valid(modal) or not modal:IsActivated() or session.palaceInputTimer then return end
    local timer, failure
    timer, failure = require("UiUpdateTimer").start("palace-title", function()
        if current ~= session or session.palaceInputTimer ~= timer or session.palaceInputBlocked
            or session.starting or session.modal ~= modal or not valid(modal)
            or not modal:IsActivated() then return false end
        return Home.updatePalaceInput()
    end, function()
        if session.palaceInputTimer == timer then session.palaceInputTimer = nil end
    end)
    if timer then session.palaceInputTimer = timer
    else logUI("title input timer unavailable: " .. tostring(failure)) end
end

local function detach(session)
    stopPalaceInput(session, "modal detached")
    closeModFeatures(session)
    if session.palaceView then session.palaceView:close(); session.palaceView = nil end
    clearHomeLayer(session)
    closePalaceScreen(session)
    restoreHoverSound(session)
    session.dialog, session.dialogInput, session.router = nil, nil, nil
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
    applyPage(session)
    startPalaceInput(session, modal)
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
    stopPalaceInput(session, "menu closed")
    if session.hook then pcall(UnregisterHook, CLICK, session.hook[1], session.hook[2]) end
    for _, hook in ipairs(session.backHooks or {}) do pcall(UnregisterHook, table.unpack(hook)) end
    local modal = session.modal
    local ok, failure = pcall(detach, session)
    if not ok then logUI("menu cleanup failed: " .. tostring(failure)) end
    if valid(modal) and modal:IsActivated() then modal:CloseWindowByCancel() end
end

function Home.isOpen()
    return current ~= nil
end

function Home.settlementReady(settlement)
    return current ~= nil and current.settlement == settlement and valid(current.modal) and current.modal:IsActivated()
end

local function finish(session, settings)
    stopPalaceInput(session, "opening arena")
    session.starting = settings
    session.pending = nil
    -- The caller must wait for CommonUI to release this modal.
    checked(session.modal, "原版 MOD 弹窗已关闭"):CloseWindowByCancel()
end

local function start(session, settings, mode)
    local chosen = mode == "bloody-palace" and settings
        or settingsCopy(settings, mode)
    if mode == "training" then
        chosen.bossId, chosen.encounterId, chosen.category = nil, nil, nil
    end
    finish(session, chosen)
end

local function closePalaceDialog(session)
    session.dialog, session.dialogInput, session.pending = nil, nil, nil
    session.palaceScreen.pending = {}
    session.palaceScreen:showNativeDialog(false)
    local view = session.palaceView
    local layer = view and view.layer or session.homeLayer
    layer:SetVisibility(4)
    session.title:SetText(FText(session.page.title))
    session.description:SetText(FText(session.page.body))
    setButtons(session, session.page.labels, session.page.actions, true, session.page.home)
    if view then view:restoreFocus()
    else
        session.homeConfirmHeld, session.homeDirectionHeld, session.modFeaturesHeld = true, true, true
        session.buttons[1]:SetFocus()
    end
    session.backHeld = true
end

local function showPalaceDialog(session, body, buttons, onCancel, confirmOnly)
    local function cancel()
        if onCancel then onCancel()
        else closePalaceDialog(session) end
    end
    local layer = session.palaceView and session.palaceView.layer or session.homeLayer
    local count = #buttons + (confirmOnly and 0 or 1)
    assert(layer and count <= #session.buttons, "原版确认按钮不足")
    session.dialog = { cancel = cancel, confirmOnly = confirmOnly }
    session.backHeld = true
    session.palaceScreen.pending = {}
    layer:SetVisibility(3)
    session.palaceScreen:showNativeDialog(true)
    if valid(session.tapZone) then session.tapZone:SetVisibility(3) end
    session.title:SetText(FText(""))
    session.description:SetText(FText(body))
    local labels, actions = {}, {}
    for index, item in ipairs(buttons) do labels[index], actions[index] = item[1], item[2] end
    if not confirmOnly then labels[count], actions[count] = "取消", cancel end
    setButtons(session, labels, actions, true)
    focusDialog(session, count)
end

local function showFirstEntry(session, group, enter, back)
    local messages = FirstEntry.pending(session.preferences, group)
    if not messages then return false end
    local overHome = group == "dream" and session.homeLayer ~= nil

    local function cancel()
        if overHome and session.homeLayer and valid(session.modal) and session.modal:IsActivated() then
            closePalaceDialog(session)
            return
        end
        session.dialogInput, session.pending = nil, nil
        back()
    end
    local function show(index)
        local function confirm()
            if index < #messages then
                show(index + 1)
                return
            end
            if overHome then closePalaceDialog(session)
            else session.dialogInput, session.pending = nil, nil end
            local saved = FirstEntry.acknowledge(session.preferences, group)
            logUI("first entry confirmed group=" .. group .. " saved=" .. tostring(saved))
            enter()
        end
        if overHome then
            showPalaceDialog(session, messages[index], { { "确定", confirm } }, cancel, true)
        else
            session.backHeld = true
            session.page = {
                title = "", body = messages[index], labels = { "确定", "", "" }, actions = { confirm },
                back = cancel, firstEntry = true, confirmationSound = true,
            }
            applyPage(session)
        end
        logUI(("first entry group=%s page=%d/%d"):format(group, index, #messages))
    end
    show(1)
    return true
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
            end, state, function(tier)
                return showFirstEntry(session, "zhuoshi", function()
                    showPalace(session, { page = "prep", tier = tier })
                end, function()
                    showPalace(session, { page = "difficulty", tier = tier })
                end)
            end)
    end
    session.page = selectedPage
    applyPage(session)
end

local function mountArenaSetup(session, flow, enter, leave, targetOnly, confirmLabel)
    session.page = {
        title = "", body = "", labels = { "", "", "" }, focus = 1, arenaSetup = true,
        actions = { function()
            if session.palaceView then session.palaceView:confirmNative() end
        end },
        back = function() if not flow:back() or targetOnly then leave() end end,
        mount = function(screen)
            return require("ArenaSetupMenu").open(session, screen, flow, enter, leave, targetOnly, confirmLabel)
        end,
    }
    applyPage(session)
end

local function showArenaSetup(session, mode)
    session.homeIndex = mode == "training" and 1 or mode == "practice" and 2 or 3
    local flow = require("ArenaSetupFlow").new(settingsCopy(session.settings, mode), session.initial)
    local function leave()
        session.settings = flow:settings()
        showHome(session)
    end
    mountArenaSetup(session, flow, function(chosen) start(session, chosen, mode) end, leave)
end

local LOADER_STATUS = {
    loaded = "已加载", disabled = "已禁用", failed = "加载失败",
    stopped = "已停止", ["reload-blocked"] = "重载受阻", unknown = "未知",
}
local MOD_TABS = {
    { id = "loader", name = "PBZModLoader" },
    { id = "ue4ss", name = "UE4SS" },
    { id = "pak", name = "PAK" },
}
local MODS_PER_PAGE = 8
local TAB_FIRST, TAB_GAP, TAB_WIDTH = 500, 320, 280
local STOCK_ACTIONS = "/Game/PBZContent/DataTable/UI/DT_PBZUniversalActions.DT_PBZUniversalActions"
local ModFeatures = {}
ModFeatures.__index = ModFeatures

local function switchLabel(enabled)
    if enabled == nil then return "未知" end
    return enabled and "开启" or "关闭"
end

local function modLabel(row)
    local title = row.name or row.id or "异常状态条"
    local shortened, count = title:gsub(".[\128-\191]*", "", 42)
    if count == 42 and #shortened > 0 then
        return title:sub(1, #title - #shortened) .. "…", title
    end
    return title
end

local function modValue(row, enabled)
    if row.kind == "feature" then return switchLabel(enabled) end
    if row.kind == "loader" then
        local runtime = LOADER_STATUS[row.status] or "未知"
        if enabled == nil then return runtime end
        return ("%s　·　下次 %s"):format(runtime, switchLabel(enabled))
    end
    return row.label or "未知"
end

local function tabInput(router, stock)
    local function held(key) return router:IsUIKeyHeld({ KeyName = FName(key) }) end
    local previous = held("Z") or held(stock and "Gamepad_LeftTrigger" or "Gamepad_LeftShoulder")
    local following = held("C") or held(stock and "Gamepad_RightTrigger" or "Gamepad_RightShoulder")
    if previous == following then return nil end
    return previous and -1 or 1
end

local function showTabHints(screen, hint, layer)
    local left = hint.create(screen, "LeftShoulderZ", "", TAB_FIRST - 100, 174, 64, 55, layer)
    local right = hint.create(screen, "RightShoulderC", "", TAB_FIRST + (#MOD_TABS - 1) * TAB_GAP + TAB_WIDTH + 36, 174, 64, 55, layer)
    if not valid(left) or not valid(right) then return false end
    local function apply(prompt, tableAsset, row)
        local action = { DataTable = tableAsset, RowName = FName(row) }
        prompt.InputActions = action
        prompt.InputActionWidget:SetInputAction(action)
    end
    local leftDefault, rightDefault = left.InputActions, right.InputActions
    local ok = pcall(function()
        local actions = require("CombatSpawn").class(STOCK_ACTIONS)
        apply(left, actions, "LeftTrigger")
        apply(right, actions, "RightTrigger")
    end)
    if not ok then
        left.InputActions, right.InputActions = leftDefault, rightDefault
        left.InputActionWidget:SetInputAction(leftDefault)
        right.InputActionWidget:SetInputAction(rightDefault)
    end
    return ok
end

local function bindRowArrow(screen, button, layer, callback)
    -- Keep the arrow in its authored HorizontalBox slot while using the
    -- existing NativeScreen pulse and cleanup path.
    local pulse = screen:make("TextBlock")
    pulse:SetVisibility(1)
    screen:place(pulse, 0, 0, 0, 0, layer)
    button.OnButtonBaseClicked:Add(pulse, FName("ForceLayoutPrepass"))
    screen.buttons[#screen.buttons + 1] = { widget = button, pulse = pulse, canvas = layer }
    screen.actions[pulse:GetAddress()] = { callback = callback, button = button }
end

function ModFeatures:enabled(row)
    if row.kind == "feature" then return DisplayPreferences.statusHudEnabled() end
    if row.kind == "loader" and self.config then return ModLoaderSettings.enabled(self.config, row.id) end
end

function ModFeatures:refresh()
    local row = self.rows[self.index]
    local editable = row ~= nil and self.draft ~= nil
    for _, entry in ipairs(self.entries) do
        local selected = entry.index == self.index
        local item = self.rows[entry.index]
        local enabled
        if selected then enabled = self.draft else enabled = self:enabled(item) end
        entry.style:refresh(modValue(item, enabled), selected)
        local arrows = selected and editable
        entry.style.decrease:SetVisibility(arrows and 0 or 2)
        entry.style.increase:SetVisibility(arrows and 0 or 2)
        entry.style.decrease:SetIsEnabled(arrows)
        entry.style.increase:SetIsEnabled(arrows)
    end
    local changed = editable and self.draft ~= self.saved
    self.saveButton:SetIsEnabled(changed)
    if valid(self.savePrompt) then self.savePrompt:SetRenderOpacity(changed and 1 or .55) end
    local hint = self.message
    if not hint and row then
        if row.kind == "loader" then
            hint = self.configReason or (editable and "保存后，下次启动生效。" or "此项无法修改。")
        elseif row.kind == "feature" then
            hint = "保存后立即生效。"
        else
            hint = row.protected and "演武本体 · 仅查看" or "仅查看"
        end
    end
    self.notice:SetText(FText(hint or ""))
end

function ModFeatures:choose(enabled)
    if self.draft == nil or enabled == self.draft then return end
    self.draft, self.message = enabled, nil
    self:refresh()
end

function ModFeatures:save()
    if self.draft == nil or self.draft == self.saved then return end
    local row = self.rows[self.index]
    local saved, reason
    if row.kind == "loader" then
        saved, reason = ModLoaderSettings.setEnabled(row.id, self.draft)
        if saved then self.config, self.configReason = ModLoaderSettings.read() end
    elseif row.kind == "feature" then
        saved = DisplayPreferences.setStatusHudEnabled(self.draft)
    end
    if saved then
        self.saved = self.draft
        self.message = row.kind == "loader" and "已保存，下次启动生效。" or "已保存。"
        if row.kind == "loader" then
            logUI(("mod preference id=%s next_enabled=%s runtime=%s"):format(row.id, tostring(self.draft), row.status))
        end
    else
        self.message = reason or "设置未保存，请重试。"
    end
    self:refresh()
end

function ModFeatures:clearList()
    if not self.listLayer then return end
    for _, entry in ipairs(self.entries) do
        if valid(entry.style.root) then pcall(entry.style.refresh, entry.style, entry.style.lastValue or "", false) end
    end
    self.screen:releaseButtons(self.listLayer)
    if valid(self.listLayer) then self.listLayer:RemoveFromParent() end
    self.listLayer, self.entries, self.first, self.hovered = nil, {}, nil, nil
end

function ModFeatures:drawList(first)
    self:clearList()
    local screen, ui, rowStyle = self.screen, self.ui, require("ParameterStyle")
    local layer = screen:place(screen:make("CanvasPanel"), 0, 0, 1920, 1080, self.layer)
    self.listLayer, self.first = layer, first
    if #self.rows == 0 then
        local id = MOD_TABS[self.tab].id
        local label = self.reasons[id] or (id == "pak" and "没有发现 PAK MOD。"
            or id == "ue4ss" and "没有发现 UE4SS MOD。" or "没有发现 PBZModLoader MOD。")
        local message = screen:text(label, 135, 303, 1650, 80, false, layer, 29)
        message:SetAutoWrapText(true)
        return
    end
    for index = first, math.min(#self.rows, first + MODS_PER_PAGE - 1) do
        local row = self.rows[index]
        local name, fullName = modLabel(row)
        local y = 273 + (index - first) * 71
        local styled = rowStyle.row(screen.modal, screen.controller, screen.tree, name)
        local labelBox = styled.label:GetParent()
        if valid(labelBox) then labelBox:SetWidthOverride(840) end
        if fullName then styled.root:SetToolTipText(FText(fullName)) end
        screen:place(styled.root, 122, y, 1676, 68, layer)
        if row.kind == "feature" or row.kind == "loader" then
            bindRowArrow(screen, styled.decrease, layer, function() self:select(index); self:choose(true) end)
            bindRowArrow(screen, styled.increase, layer, function() self:select(index); self:choose(false) end)
        end
        self.entries[#self.entries + 1] = { index = index, style = styled,
            button = { widget = styled.root, x = 122, y = y, right = 1798, bottom = y + 68 } }
    end
    local pages = math.ceil(#self.rows / MODS_PER_PAGE)
    if pages > 1 then
        local page = 1 + math.floor((first - 1) / MODS_PER_PAGE)
        screen:text(("%d / %d"):format(page, pages), 845, 875, 230, 40, false, layer, 24):SetJustification(1)
        if page > 1 then
            ui.button(screen, "上一页", 650, 859, 160, 58, function() self:select(first - MODS_PER_PAGE) end, layer, true)
        end
        if page < pages then
            ui.button(screen, "下一页", 1110, 859, 160, 58, function() self:select(first + MODS_PER_PAGE) end, layer, true)
        end
    end
end

function ModFeatures:select(index)
    if self.index == index or not self.rows[index] then return end
    self.index, self.message = index, nil
    self.saved = self:enabled(self.rows[index])
    self.draft = self.saved
    local first = 1 + math.floor((index - 1) / MODS_PER_PAGE) * MODS_PER_PAGE
    if self.first ~= first then self:drawList(first) end
    self:refresh()
end

function ModFeatures:readLocalInventory()
    if self.groups.ue4ss then return end
    local inventory, ue4ssReason, pakReason = require("ModFeatureInventory").list()
    inventory = inventory or {}
    self.reasons.ue4ss, self.reasons.pak = ue4ssReason, pakReason
    self.groups.pak = inventory.pak or {}
    local rows = {
        { id = "PBZTestArena", name = "影境演武（PBZTestArena）", kind = "ue4ss",
            label = "配置未知", protected = true },
        { kind = "feature", name = "　　└ 异常状态条" },
    }
    for _, row in ipairs(inventory.ue4ss or {}) do
        if row.id:lower() == "pbztestarena" then
            rows[1].id, rows[1].label = row.id, row.label
        else
            rows[#rows + 1] = row
        end
    end
    self.groups.ue4ss = rows
end

function ModFeatures:filter(index)
    if index == self.tab then return end
    local category = MOD_TABS[index].id
    if category ~= "loader" then self:readLocalInventory() end
    self:clearList()
    self.tab, self.index, self.draft, self.saved, self.message = index, nil, nil, nil, nil
    self.rows = self.groups[category]
    for i, button in ipairs(self.tabs) do button:setSelected(i == index) end
    if #self.rows > 0 then self:select(1)
    else
        self:drawList(1)
        self:refresh()
    end
end

function ModFeatures:update()
    local screen, ui, session = self.screen, self.ui, self.session
    local layer = self.listLayer
    local hovered, mouse = ui.pointer(screen, self.input, self.entries)
    if not screen:update(mouse) or session.modFeatures ~= self or self.listLayer ~= layer then return end
    local focused = session.modal:HasUserFocus(session.controller)
        or session.modal:HasUserFocusedDescendants(session.controller)
    if not (focused or mouse) then return end
    if hovered ~= self.hovered then
        self.hovered = hovered
        if hovered then self:select(self.entries[hovered].index) end
    end
    local router = session.router
    local tab, direction, confirm = tabInput(router, self.stockTabs), ui.direction(router), ui.confirmHeld(router)
    local tabChanged = tab and tab ~= self.tabHeld
    local directionChanged = direction and direction ~= self.direction
    local confirmPressed = confirm and not self.confirm
    self.tabHeld, self.direction, self.confirm = tab, direction, confirm
    if tabChanged then
        self:filter((self.tab + tab - 1) % #MOD_TABS + 1)
    elseif directionChanged and self.index then
        if direction == 1 or direction == 2 then
            local delta = direction == 1 and -1 or 1
            self:select((self.index + delta - 1) % #self.rows + 1)
        else self:choose(direction == 3) end
    elseif confirmPressed then
        self:save()
    end
end

closeModFeatures = function(session, restore)
    local view = session.modFeatures
    if not view then return end
    session.modFeatures, session.pending = nil, nil
    view:clearList()
    for _, button in ipairs(view.tabs or {}) do button:setSelected(false) end
    if view.layer then view.screen:releaseButtons(view.layer) end
    if valid(view.layer) then view.layer:RemoveFromParent() end
    if valid(session.homeLayer) then session.homeLayer:SetVisibility(view.homeVisibility) end
    if valid(session.illustrationLayer) then session.illustrationLayer:SetVisibility(view.illustrationVisibility) end
    if not restore then return end
    session.homeConfirmHeld, session.homeDirectionHeld, session.modFeaturesHeld, session.backHeld = true, true, true, true
    session.buttons[1]:SetFocus()
end

openModFeatures = function(session)
    if current ~= session or session.dialog or session.modFeatures or not session.homeLayer then return end
    local loaderRows, loaderReason = require("ModFeaturesBridge").list(session.controller)
    local config, configReason = ModLoaderSettings.read()
    local groups = { loader = {} }
    for _, row in ipairs(loaderRows or {}) do
        groups.loader[#groups.loader + 1] = { id = row.id, status = row.status, kind = "loader" }
    end

    local screen, ui = session.palaceScreen, require("DreamPalaceUI")
    local view = setmetatable({
        session = session, screen = screen, ui = ui, input = session.homeInput, groups = groups,
        config = config, configReason = configReason, entries = {}, tabs = {},
        reasons = { loader = loaderReason },
        homeVisibility = session.homeLayer:GetVisibility(),
        illustrationVisibility = session.illustrationLayer:GetVisibility(),
        direction = ui.direction(session.router),
        confirm = ui.confirmHeld(session.router),
    }, ModFeatures)
    session.modFeatures, session.pending = view, nil
    screen.pending = {}
    session.homeLayer:SetVisibility(1)
    session.illustrationLayer:SetVisibility(1)

    local layer = screen:panel(0, 0, 1920, 1080)
    view.layer = layer
    ui.heading(screen, "MOD 与功能", layer)
    local hint = require("InputActionHint")
    view.stockTabs = showTabHints(screen, hint, layer)
    view.tabHeld = tabInput(session.router, view.stockTabs)
    for index, tab in ipairs(MOD_TABS) do
        view.tabs[index] = ui.button(screen, tab.name, TAB_FIRST + (index - 1) * TAB_GAP, 158, TAB_WIDTH, 74,
            function() view:filter(index) end, layer, true)
    end
    screen:shade(122, 243, 1676, 2, .55, layer):SetBrushColor({ R = .63, G = .61, B = .57, A = .35 })
    view.notice = screen:text("", 132, 941, 1330, 60, false, layer, 25)
    view.notice:SetAutoWrapText(true)
    view.savePrompt = hint.create(screen, "DefaultConfirm", "保存", 1580, 1012, 118, 30, layer)
    local saveButton, caption = require("ParameterStyle").button(screen.modal, screen.controller, screen.tree, "")
    caption:SetVisibility(1)
    view.saveButton = screen:bindButton(saveButton, 1580, 1006, 118, 42, function() view:save() end, layer)
    ui.footer(screen, layer, nil, nil, nil, false, function() closeModFeatures(session, true) end)
    view:filter(1)
    session.buttons[1]:SetFocus()
    logUI("page=mod-features")
end

showHome = function(session)
    local actions = {
        function() showArenaSetup(session, "training") end,
        function() showArenaSetup(session, "practice") end,
        function() showArenaSetup(session, "challenge") end,
    }
    if not session.palacePath then
        page(session, "影境演武", "", { "测试场", "练习模式", "挑战模式" }, actions, Home.close, 1, true)
        return
    end
    actions[4] = function()
        local function enter() showPalace(session) end
        if not showFirstEntry(session, "dream", enter, function() showHome(session) end) then enter() end
    end
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
            if current ~= session or session.pending or session.starting or session.modFeatures then return end
            local pulse = unwrap(context:get())
            local action = valid(pulse) and session.actions[pulse:GetAddress()]
            if not action then return end
            if session.dialogInput and session.dialogInput.release then return end
            if session.settlement and session.settlement.floorResult and session.screen and not session.screen.ready then return end
            session.pending = action
        end)
        session.hook = { pre, post }
        show(session)
        routeNativeBack(session)
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

function Home.open(menu, controller, defaults, onStart, palacePath, preferences)
    checked(menu, "找不到原版标题菜单")
    checked(controller, "找不到标题菜单的本地控制器")
    assert(type(onStart) == "function", "缺少 MOD 开始回调")
    local restored = defaults or {}
    if restored.customPlayer == nil then
        local remembered, cycle = PlayerCustom.read()
        if remembered then
            local settings = {}; for key, value in pairs(restored) do settings[key] = value end
            settings.customProfiles, settings.playerCycle = remembered, cycle
            settings.customPlayer, settings.skillLevel = remembered[cycle], Profile.skillCap(cycle)
            restored = settings
        end
    end
    if restored.sceneId == "day" then
        local migrated = {}; for key, value in pairs(restored) do migrated[key] = value end
        migrated.sceneId, restored = "night", migrated
    end
    local initial = settingsCopy(restored)
    local session = {
        menu = menu, controller = controller, onStart = onStart, settings = settingsCopy(initial), initial = initial,
        buttons = {}, pulses = {}, actions = {}, bindings = {}, palacePath = palacePath, preferences = preferences,
    }
    local function enter() showHome(session) end
    return openPage(session, function()
        if not showFirstEntry(session, "arena", enter, Home.close) then enter() end
    end)
end

local function openArenaSetupInWorld(pawn, controller, flow, onChange, targetOnly, confirmLabel)
    local world = checked(require("SceneArena").runtimeWorld(pawn), "演武目标界面场景未就绪")
    checked(controller, "找不到演武目标界面的本地控制器")
    local session = { menu = pawn, controller = controller, arenaWorld = world:GetAddress(), onStart = onChange,
        buttons = {}, pulses = {}, actions = {}, bindings = {} }
    return openPage(session, function()
        mountArenaSetup(session, flow, function(chosen)
            finish(session, chosen)
        end, Home.close, targetOnly, confirmLabel)
    end)
end

function Home.openArenaTarget(pawn, controller, state, onChange)
    local flow = require("ArenaSetupFlow").new(state)
    return openArenaSetupInWorld(pawn, controller, flow, onChange, nil, "确认更换")
end

function Home.openTrainingTarget(pawn, controller, mobId, onChange)
    local flow = require("ArenaSetupFlow").new(settingsCopy({ trainingMobId = mobId }, "training"))
    flow:open("target")
    return openArenaSetupInWorld(pawn, controller, flow, function(chosen)
        onChange({ trainingMobId = chosen.trainingMobId })
    end, true)
end

function Home.prompt(controller, settlement, onExit)
    local world = checked(require("SceneArena").runtimeWorld(controller), "血宫界面场景未就绪")
    local session = { menu = controller, controller = controller, arenaWorld = world:GetAddress(),
        onStart = onExit, settlement = settlement,
        buttons = {}, pulses = {}, actions = {}, bindings = {} }
    local function exit(destination)
        session.starting, session.pending = destination or "title", nil
        if session.settlement.floorResult and session.screen then
            session.screen:close()
            session.screen = nil
        end
        if valid(session.modal) and session.modal:IsActivated() then session.modal:CloseWindowByCancel() end
    end
    local function show()
        local title, body, confirm, decline = settlement:labels()
        local returnChoices = settlement:hasReturnChoices()
        local function answer(accepted)
            if settlement:answer(accepted) then exit(settlement.returnAfterOffer)
            else show() end
        end
        session.confirmFloor = settlement.floorResult and function() answer(true) end or nil
        local function accept()
            if session.screen and session.screen.requestExit then session.screen:requestExit(returnChoices and "arena" or "title")
            elseif session.screen and session.screen.accept then session.screen:accept()
            elseif returnChoices then exit("arena")
            else answer(true) end
        end
        local function quit()
            if session.screen and session.screen.requestExit then session.screen:requestExit("title")
            else exit("title") end
        end
        local function alternate()
            if returnChoices or session.screen and session.screen.requestExit then quit()
            else answer(false) end
        end
        local function back()
            if settlement.floorResult or settlement.failurePage and returnChoices then return end
            alternate()
        end
        page(session, title, body, { confirm, decline or "", "" },
            { accept, decline and alternate }, back, 1, nil, decline ~= nil or settlement.floorResult ~= nil)
    end
    return openPage(session, show)
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
            local back = session.dialog and session.dialog.cancel or (session.page and session.page.back)
            local returnState = session.palaceView and not (session.page and session.page.arenaSetup)
                and (session.dialog and session.palaceView:pageState() or session.palaceView:backState())
            if session.palaceView then logUI("native modal deactivated before page back") end
            session.pending = nil
            detach(session)
            session.modal = nil
            session.openingModal = nil
            if returnState then showPalace(session, returnState)
            elseif not session.settlement then
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
            if session.page.confirmationSound or (session.dialog and session.dialog.confirmOnly) then
                feedback("confirmationClick", session.controller, session.modal, action.index ~= 1)
            end
            local inDialog = session.dialogInput ~= nil
            action.run()
            -- One click or Back may advance only one confirmation page.
            if inDialog or session.dialogInput then return end
        elseif not session.modal then
            attachIfReady(session)
        end
        if current ~= session or session.starting or not valid(session.modal) then return end
        local wasBackHeld = session.backHeld
        if session.router then session.backHeld = require("DreamPalaceUI").backHeld(session.router) end
        local backPressed = session.backHeld and not wasBackHeld
        if backPressed then
            if session.modFeatures then closeModFeatures(session, true)
            elseif session.dialog then session.dialog.cancel()
            elseif session.page.firstEntry then session.page.back()
            elseif session.settlement then
                if session.settlement.floorResult then return end
                if session.page.confirmationSound then feedback("confirmationClick", session.controller, session.modal, true) end
                session.page.back()
            elseif session.palaceView then session.palaceView:back()
            elseif session.page.home then Home.close() end
            return
        elseif session.modFeatures then
            session.modFeatures:update()
            return
        elseif session.dialogInput then
            updateDialogInput(session)
            if session.screen and session.screen:update(session.dialogInput) == false then Home.close() end
            return
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
            if current ~= session or session.palaceScreen ~= screen or not session.homeEntries
                or session.dialog or session.modFeatures then return end
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
            local features = held("F") or held("Gamepad_FaceButton_Top")
            local openFeatures = features and not session.modFeaturesHeld
            session.modFeaturesHeld = features
            if session.preferences and openFeatures then openModFeatures(session); return end
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
