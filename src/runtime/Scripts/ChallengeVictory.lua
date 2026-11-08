-- Full-screen settlement hosted by the stock CommonUI confirmation modal.
-- Challenge owns battle timing, stock Zhan prelude and reload; this module
-- presents a completed report and owns its short information reveal.
local Victory = {}
local Art, Screen, Profile = require("ArtAssets"), require("NativeScreen"), require("PlayerProfile")
local Portraits = require("PortraitLayout")
local Feedback = require("ParameterFeedback")
local DESCRIPTORS = "/Script/CommonGame.Default__CommonGameDialogDescriptor"
local CONFIRMATION = "/Script/CommonGame.Default__AsyncAction_ShowConfirmation"
local SUBSYSTEMS = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local ROUTER = "/Script/ProjectPBZ.PBZUIActionRouterBase"
local MODAL = "W_ConfirmationDefault_C"
local CLICK = "/Script/UMG.Widget:ForceLayoutPrepass"
local LABELS = { "重试", "更换目标", "退出演武" }
local CONFIRM_KEYS = { "Gamepad_FaceButton_Bottom", "Enter", "SpaceBar" }
local SKIP_KEYS = { "Gamepad_FaceButton_Bottom", "Enter", "SpaceBar", "LeftMouseButton" }
local REVEAL_DURATION, STAMP_AT, BUTTONS_AT = .80, 2.80, 3.00
local REVEAL_INTERVAL_MS = 16
local DIRECTIONS = {
    { "Gamepad_DPad_Left", "Left", "Gamepad_DPad_Up", "Up" },
    { "Gamepad_DPad_Right", "Right", "Gamepad_DPad_Down", "Down" },
}
local DIFFICULTIES = { [1] = "入阵者", [2] = "破局者", [3] = "逆天者" }
local current
local function valid(value) return value ~= nil and type(value.IsValid) == "function" and value:IsValid() end
local function unwrap(value)
    if value and type(value.IsValid) ~= "function" then
        local get = value.get or value.Get
        if type(get) == "function" then return get(value) end
    end
    return value
end
local function checked(value, message) value = unwrap(value); assert(valid(value), message); return value end
local function same(a, b) return valid(a) and valid(b) and a:GetAddress() == b:GetAddress() end
local function required(path) return checked(StaticFindObject(path), "缺少原版结算接口：" .. path) end
local function focused(session)
    return valid(session.modal) and session.modal:IsActivated() and
        (session.modal:HasUserFocus(session.controller) or session.modal:HasUserFocusedDescendants(session.controller))
end
local function held(router, keys)
    for _, key in ipairs(keys) do if router:IsUIKeyHeld({ KeyName = FName(key) }) then return true end end
    return false
end
local function rank(cycle, side, profile)
    if side == "player" and profile == "lao" then cycle = -1 end
    local ok, result = pcall(Profile.rank, cycle, side)
    return ok and result or "—"
end
local function duration(seconds)
    if type(seconds) ~= "number" or seconds ~= seconds or seconds < 0 or seconds == math.huge then return "—" end
    local total = math.floor(seconds * 1000 + .5)
    return ("%02d:%02d.%03d"):format(math.floor(total / 60000), math.floor(total / 1000) % 60, total % 1000)
end
local function reportInfo(report,reportOnly)
    local encounter = require("EncounterCatalog").resolve(report.encounterId or report.bossId)
    return {
        id = report.encounterId or report.bossId,
        name = report.encounterName or report.bossName or (not reportOnly and encounter and encounter.name) or (reportOnly and "—" or "挑战对象"),
        category = (report.categoryName or (not reportOnly and encounter and encounter.categoryName) or (reportOnly and "—" or "")):gsub("（.-）", ""):gsub("%b()", ""),
        difficulty = report.difficultyName or DIFFICULTIES[report.difficultyMode] or (reportOnly and "—" or "难度未记录"),
        header=report.attemptResult=="failure" and "挑战失败" or (report.attemptResult=="success" or not reportOnly)and "挑战成功" or "挑战记录",
        player = rank(report.playerCycle, "player", report.playerProfile),
        enemy = rank(report.enemyCycle, "enemy"), time = duration(report.timeSeconds),
        damage = type(report.damageTaken)=="number" and report.damageTaken==report.damageTaken
            and report.damageTaken>=0 and report.damageTaken<math.huge
            and (((report.damageTakenStatus=="sampled-hp" or report.damageTakenStatus=="partial-attribute-events") and "≈" or "")
                ..(("%.2f"):format(report.damageTaken):gsub("0+$", ""):gsub("%.$", ""))) or "—",
    }
end
local function ownModals(controller)
    local found = {}
    for _, value in ipairs(FindAllOf(MODAL) or {}) do
        local modal = unwrap(value)
        if valid(modal) and modal:IsActivated() and same(unwrap(modal:GetOwningPlayer()), controller) then
            found[modal:GetAddress()] = modal
        end
    end
    return found
end
local function requestModal(session)
    session.before, session.deadline = ownModals(session.controller), os.time() + 4
    local descriptor = checked(required(DESCRIPTORS):CreateConfirmationOk(session.pawn,
        FText(session.practice and "练习结束" or session.info.header),
        FText(session.practice and "" or session.info.name .. "\n" .. session.info.time)), "无法创建原生结算描述")
    for index, label in ipairs(LABELS) do
        descriptor.ButtonActions[index] = { Result = index - 1, OptionalDisplayText = FText(session.reportOnly and(index==1 and "返回" or "")or label) }
    end
    session.request = checked(required(CONFIRMATION):ShowConfirmationCustom(session.pawn, descriptor), "无法打开原生结算菜单")
    session.request:Activate()
end
local function caption(screen, content, x, y, width, height, scale, heading, canvas)
    local widget = screen:textScaled(content, x, y, width, height, scale or 1, heading == true, canvas)
    -- Keep the actual layout area. Enlarging glyphs via RenderScale or shrinking
    -- their layout rectangle produces both blurred text and clipped characters.
    widget:SetAutoWrapText(false)
    return widget
end
local function stopRevealTicker(session)
    local ticker = session.revealTicker
    session.revealTicker = nil
    if ticker then
        ticker.active = false -- also reject an already-queued stale callback
        if ticker.handle and type(CancelDelayedAction) == "function" then pcall(CancelDelayedAction, ticker.handle) end
    end
end
local function clearSkin(session)
    stopRevealTicker(session)
    if session.portraits then session.portraits:close(); session.portraits = nil end
    if session.skin then session.skin:close(); session.skin = nil end
    session.reveal, session.revealRows, session.stamp, session.resultButtons,session.skipLayer = nil, nil, nil, nil,nil
    session.skipPending=nil
end
local function nativePage(session, target)
    for _, widget in ipairs(session.navigation or {}) do
        -- One UI-router direction path, including the stock practice buttons.
        -- Leaving their geometric navigation enabled skipped the middle option
        -- on this game's confirmation layout.
        if valid(widget) then for direction = 0, 3 do widget:SetNavigationRuleBase(direction, 3) end end
    end
    for index, button in ipairs(session.buttons) do
        local label = session.reportOnly and(index==1 and "返回" or "")or target and (index == 1 and "确认" or index == 2 and "返回" or "") or LABELS[index]
        button:SetButtonText(FText(label))
        button:SetVisibility((session.reportOnly and index>1 or target and index==3)and 1 or 0)
        button:SetIsEnabled(session.reportOnly and index==1 or not session.reportOnly and(not target or index<=2))
        if session.practice then button:SetIsFocusable(true) end
    end
    session.buttons[session.practice and not target and (session.resultRow or 1) or 1]:SetFocus()
end
local function queue(session, kind, source)
    if current==session and session.view=="result" and not session.practice and type(kind)=="number" then
        if not session.resultControlsReady then
            if session.skipReady then session.skipPending=true end
            return
        end
        if session.consumeGesture then return end
    end
    if current == session and not session.pending then session.pending = { kind = kind, source = source } end
end
local function equipmentGroup(session, heading, groups, counts, y, iconSize, canvas)
    local screen, data = session.skin, session.report.loadout
    local x, gap, slot = canvas and 0 or 120, 22, 0
    caption(screen, heading, x, y, 780, 42, 1.45, true, canvas)
    for groupIndex, groupName in ipairs(groups) do
        local items = type(data) == "table" and data[groupName] or nil
        for index = 1, counts[groupIndex] do
            slot = slot + 1
            local item = type(items) == "table" and items[index] or nil
            local position = x + (slot - 1) * (iconSize + gap)
            screen:shade(position, y + 42, iconSize, iconSize, .22, canvas)
            if type(item) == "table" and item.id and item.id ~= "None" and item.empty ~= true then
                local texture, meta = Art.equipment(session.pawn, item.kind, item.id, item.level, item)
                local widget = screen:image(texture, meta, position + 6, y + 48, iconSize - 12, iconSize - 12, canvas)
                if valid(widget) then widget:SetToolTipText(FText(item.name or item.id)) end
                if not texture then caption(screen, item.name or item.id, position + 6, y + 62, iconSize - 12, 54, 1, false, canvas) end
                local level = type(item.level) == "number" and tostring(item.level) or "—"
                if groupName == "accessories" or groupName == "medicines" then
                    if type(item.level) == "number" then level = "+" .. level end
                end
                caption(screen, level, position + 8, y + 42 + iconSize - 28, iconSize - 16, 40, 1.2, false, canvas)
            else
                caption(screen, "—", position + iconSize / 2 - 10, y + 64, 40, 42, 1.3, false, canvas)
            end
        end
    end
end
local showResult, showTarget
local function resultConfirm(session)
    return session.confirmReady == true and not session.consumeGesture
        and (session.practice or session.resultControlsReady) and focused(session)
end
local function row(session,y,height,delay)
    local panel=session.skin:panel(120,y,900,height)
    session.revealRows[#session.revealRows+1]={widget=panel,x=120,y=y,delay=delay}
    return panel
end
local function presentResult(session,elapsed,final)
    for _,item in ipairs(session.revealRows or {})do
        local progress=final and 1 or math.max(0,math.min(1,(elapsed-item.delay)/REVEAL_DURATION))
        local eased=progress*progress*(3-2*progress)
        if eased ~= item.presented then
            item.presented = eased
            item.widget:SetRenderOpacity(eased)
            -- The original UI also uses this native render-only translation
            -- (DisplayQuest.js / PickupSwitcher.js). Keep the approved Canvas
            -- layout fixed instead of invalidating it on every animation frame.
            item.widget:SetRenderTranslation({X=-48*(1-eased),Y=0})
        end
    end
    local stampOpacity = (final or elapsed>=STAMP_AT)and 1 or 0
    if valid(session.stamp) and session.stampOpacity ~= stampOpacity then
        session.stampOpacity = stampOpacity; session.stamp:SetRenderOpacity(stampOpacity)
    end
    local ready=final or elapsed>=BUTTONS_AT
    if ready~=session.resultControlsReady then
        session.resultControlsReady=ready
        for _,button in ipairs(session.resultButtons or {})do
            button:SetVisibility(ready and 0 or 1);button:SetIsEnabled(ready)
        end
        if valid(session.skipLayer)then
            session.skipLayer:SetVisibility(ready and 1 or 0)
            session.skipLayer:SetIsEnabled(not ready)
        end
    end
end
local function completeReveal(session, skipped)
    if skipped then
        session.skipPending,session.pending=nil,nil
        session.confirmReady,session.consumeGesture=false,true
        if session.skin then session.skin.pending={} end
    end
    presentResult(session,BUTTONS_AT,true)
    session.reveal=nil
    stopRevealTicker(session)
end
local function modalWorld(modal)
    if not valid(modal) then return nil end
    local ok, world = pcall(function() return unwrap(modal:GetWorld()) end)
    return ok and valid(world) and world or nil
end
local function startRevealTicker(session)
    if session.revealTicker or session.revealTickerUnavailable or not session.reveal
        or session.practice or session.reportOnly or not focused(session) then return false end
    if type(LoopInGameThreadWithDelay) ~= "function" or type(CancelDelayedAction) ~= "function" then return false end
    local world = modalWorld(session.modal)
    if not world then return false end
    if session.revealWorld and not same(world,session.revealWorld) then session.revealWorldChanged=true;return false end
    session.revealWorld = world
    local ticker = { active = true, world = world, reveal = session.reveal }
    session.revealTicker = ticker
    -- Pinned UE4SS 1ceefac8: this returns a handle; its callback return value is
    -- ignored. CancelDelayedAction(handle), not `return true`, stops the loop.
    local ok, handle = pcall(LoopInGameThreadWithDelay, REVEAL_INTERVAL_MS, function()
        if not ticker.active then
            if ticker.handle then pcall(CancelDelayedAction, ticker.handle) end
            return
        end
        local tickOk, failure = pcall(function()
            if not same(modalWorld(session.modal),ticker.world) then
                session.revealWorldChanged=true;stopRevealTicker(session);return
            end
            if current ~= session or session.view ~= "result" or session.reveal ~= ticker.reveal
                or not session.skin or not focused(session) then
                session.skipReady,session.confirmReady=false,false
                stopRevealTicker(session); return
            end
            -- UI presentation only: no Screen.update, input dispatch, actor
            -- enumeration, scene service, inventory, report/file IO or reload.
            -- A native click can request skip between owner updates, including
            -- immediately before 3s. Consume its already-recorded gesture before
            -- revealing buttons; the loop never polls or dispatches input.
            if session.skipPending then completeReveal(session,true);return end
            local elapsed = math.max(0,session.gameplay:GetRealTimeSeconds(session.modal)-ticker.reveal.startedAt)
            presentResult(session,elapsed,false)
            if elapsed >= BUTTONS_AT then session.reveal = nil; stopRevealTicker(session) end
        end)
        if not tickOk then
            stopRevealTicker(session); session.revealTickerUnavailable = true
            print("[PBZTestArenaNative] Victory animation ticker: " .. tostring(failure) .. "\n")
        end
    end)
    if not ok or type(handle) ~= "number" then
        stopRevealTicker(session); session.revealTickerUnavailable = true
        return false
    end
    ticker.handle = handle
    if not session.revealTickerLogged then
        session.revealTickerLogged=true
        print("[PBZTestArenaNative] Victory reveal uses a temporary game-thread loop: requested=16ms; duration=3s\n")
    end
    return true
end
showResult = function(session)
    if session.targetModel then session.targetModel:close(); session.targetModel = nil end
    clearSkin(session)
    session.view, session.pending, session.resultRow = "result", nil, session.resultRow or 1
    session.confirmReady, session.directionBlocked, session.activeDirection = false, true, nil
    session.consumeGesture=false
    nativePage(session, false)
    if session.practice then
        -- Keep the existing CommonUI dialog and its normal three-button
        -- navigation. A practice result is a choice, never a report page.
        session.title:SetText(FText("练习结束"))
        session.description:SetText(FText(""))
        return
    end
    local screen = Screen.open(session.modal, session.controller)
    session.skin = screen
    local info = session.info
    session.revealRows,session.resultButtons={},{}
    session.stampOpacity,session.revealTickerUnavailable=nil,nil
    local first=row(session,45,75,0)
    local x,firstScale=0,1.55
    for _,value in ipairs({info.header,info.category,info.difficulty})do
        local _,length=value:gsub("[^\128-\191]", "")
        local width=math.max(120,length*26*firstScale+16)
        caption(screen,value,x,0,width,70,firstScale,true,first);x=x+width+76
    end
    local _, nameLength = info.name:gsub("[^\128-\191]", "")
    local _,enemyLength=info.enemy:gsub("[^\128-\191]", "")
    local nameScale = math.min(1.72,534/(math.max(nameLength,1)*26),304/(math.max(enemyLength,1)*26))
    local second=row(session,130,85,.25)
    caption(screen, info.name, 0, 0, 550, 85, nameScale, true,second)
    caption(screen, info.enemy, 580, 0, 320, 85, nameScale,true,second)
    local third=row(session,230,75,.50)
    caption(screen, info.player, 0, 0, 900, 75, 1.8,true,third)
    local fourth=row(session,335,135,.75)
    caption(screen,"挑战耗时",0,0,420,38,1.25,false,fourth)
    caption(screen,"受到伤害",460,0,420,38,1.25,false,fourth)
    caption(screen,info.time,0,38,440,95,2.8,true,fourth)
    local damage=caption(screen,info.damage,460,38,420,95,2.8,true,fourth)
    if type(session.report.damageTakenNote)=="string" and session.report.damageTakenNote~="" then
        damage:SetToolTipText(FText(session.report.damageTakenNote))
    end
    equipmentGroup(session,"出战装备",{"mainWeapons","shadowWeapons"},{2,2},0,118,row(session,495,165,1.0))
    equipmentGroup(session,"饰品",{"accessories"},{6},0,94,row(session,675,145,1.25))
    local medicine=row(session,835,115,1.50)
    equipmentGroup(session,"药品",{"medicines"},{2},0,72,medicine)
    if type(session.report.loadout) ~= "table" or session.report.loadout.available == false then
        caption(screen, "未读到出战装备",310,20,500,42,1.2,false,medicine)
    end
    session.portraits = Portraits.open(screen, session.pawn, info.id, "bust", { x = 1050, y = 155, w = 810, h = 750 })
    if (not session.reportOnly or session.report.attemptResult=="success")and type(Art.missionComplete)=="function" then
        local texture,meta=Art.missionComplete(session.pawn)
        if texture then
            session.stamp=screen:image(texture,meta,990,50,900,900)
            session.stamp.Slot:SetZOrder(3) -- above background, behind portrait containers (5)
        end
    end
    for index, label in ipairs(session.reportOnly and {"返回"}or LABELS) do
        local button=screen:button(label, 120 + (index - 1) * 290, 972, 260, 65, function()
            if session.reportOnly then queue(session,"report-back","mouse");return end
            if session.resultControlsReady and not session.consumeGesture then session.resultRow=index end
            queue(session, index, "mouse")
        end)
        session.resultButtons[index]=button
    end
    screen.selectedButton = session.resultRow
    -- The game does not promise mouse buttons in the router's held-key set.
    -- An ordinary native UMG button receives a full-screen pointer click even
    -- outside the three action rectangles; opacity does not disable hit tests.
    if not session.reportOnly then session.skipLayer=screen:button("",0,0,1920,1080,function()
        if current==session and session.view=="result" and not session.resultControlsReady then
            session.skipReady,session.skipPending=true,true
        end
    end)
    session.skipLayer:SetRenderOpacity(0)
    session.skipLayer:SetIsFocusable(false)
    session.skipLayer.Slot:SetZOrder(100)
    for direction=0,3 do session.skipLayer:SetNavigationRuleBase(direction,3)end
    end
    session.resultControlsReady=nil
    session.skipReady=not held(session.router,SKIP_KEYS)
    session.reveal={startedAt=session.gameplay:GetRealTimeSeconds(session.modal)}
    presentResult(session,0,session.reportOnly or session.hasShownResult==true)
    if session.reportOnly or session.hasShownResult then session.reveal=nil end
    session.hasShownResult=true
    if session.reveal then startRevealTicker(session) end
end
local function targetBack(session)
    if session.targetModel and session.targetModel:back() then return end
    showResult(session)
end
showTarget = function(session, existing)
    clearSkin(session)
    if session.targetModel and session.targetModel ~= existing then session.targetModel:close() end
    local model = existing or require("ChallengeTarget").form(session.state)
    session.targetModel, session.view, session.pending = model, "target", nil
    nativePage(session, true)
    model:mount(session.modal, session.description, session.controller, session.buttons[1], {
        onConfirm = function() queue(session, "target-confirm", "mouse") end,
        onBack = function() queue(session, "target-back", "mouse") end,
    })
end
local function restoreNavigation(session)
    for _, widget in ipairs(session.navigation or {}) do
        if valid(widget) then for direction = 0, 3 do pcall(function() widget:SetNavigationRuleBase(direction, 0) end) end end
    end
    session.navigation = {}
end
local function detach(session, keepTarget)
    if session.targetModel then
        session.targetModel:close()
        if not keepTarget then session.targetModel = nil end
    end
    clearSkin(session)
    restoreNavigation(session)
    session.pending = nil
    for index, button in ipairs(session.buttons) do
        if valid(button) then
            local delegate, owns = button.OnButtonBaseClicked, false
            for _, binding in ipairs(delegate:GetBindings()) do
                local named, name = pcall(function()
                    local value = unwrap(binding.FunctionName)
                    return type(value) == "string" and value or value:ToString()
                end)
                if named and name == "ForceLayoutPrepass" and same(unwrap(binding.Object), session.pulses[index]) then owns = true end
            end
            -- A deactivated modal may be pooled. Restore our own delegates even
            -- there, but never clear handlers already replaced by another page.
            if owns then
                delegate:Clear()
                for _, binding in ipairs(session.bindings[index] or {}) do
                    if valid(unwrap(binding.Object)) then delegate:Add(unwrap(binding.Object), binding.FunctionName) end
                end
                if session.focusable[index] ~= nil then button:SetIsFocusable(session.focusable[index]) end
                local state=session.reportButtonStates and session.reportButtonStates[index]
                if state then button:SetVisibility(state.visibility);button:SetIsEnabled(state.enabled)end
            end
        end
    end
    for index, pulse in ipairs(session.pulses) do
        if session.pulseOwned[index] and valid(pulse) then pulse:RemoveFromParent() end
    end
    session.buttons, session.pulses, session.actions, session.bindings = {}, {}, {}, {}
    session.pulseOwned = {}
    if valid(session.navigationGroup) and session.groupNavigation ~= nil then
        session.navigationGroup.bBindButtonNavigation = session.groupNavigation
    end
    session.navigationGroup, session.groupNavigation = nil, nil
end
local function readyControls(modal)
    local tree, title, description = unwrap(modal.WidgetTree), unwrap(modal.Text_Title), unwrap(modal.RichText_Description)
    local root = valid(tree) and unwrap(tree.RootWidget) or nil
    if not valid(root) or not valid(title) or not valid(description) then return nil, "标题或正文尚未初始化" end
    local group, entries = unwrap(modal.ButtonGroup), nil
    if valid(group) then
        if group:GetButtonCount() ~= 3 then return nil, "原生按钮组尚未完成三个选项" end
    else
        local box = unwrap(modal.EntryBox_Buttons)
        if not valid(box) then return nil, "原生按钮容器尚未初始化" end
        entries = box:GetAllEntries()
        if #entries ~= 3 then return nil, "原生按钮条目尚未完成三个选项" end
    end
    local buttons = {}
    for index = 1, 3 do
        buttons[index] = unwrap(entries and entries[index] or group:GetButtonBaseAtIndex(index - 1))
        if not valid(buttons[index]) then return nil, "原生按钮未就绪 " .. index end
    end
    return { root = root, title = title, description = description, group = group, buttons = buttons }
end
local function attach(session, modal, controls)
    session.modal = modal
    local root = controls.root
    session.title, session.description = controls.title, controls.description
    if session.practice and valid(controls.group) then
        session.navigationGroup = controls.group
        session.groupNavigation = controls.group.bBindButtonNavigation
        assert(type(session.groupNavigation) == "boolean", "无法读取原生练习菜单导航开关")
        controls.group.bBindButtonNavigation = false
    end
    session.navigation = {}
    if session.reportOnly then
        required("/Script/UMG.Widget:GetIsEnabled")
        session.reportButtonStates={}
    end
    for index = 1, 3 do
        local button = controls.buttons[index]
        if session.reportOnly then
            local enabled=button:GetIsEnabled();assert(type(enabled)=="boolean","无法读取原生报告按钮状态")
            session.reportButtonStates[index]={visibility=button:GetVisibility(),enabled=enabled}
        end
        local pulse = button
        if not session.practice then
            pulse = checked(StaticConstructObject(required("/Script/UMG.TextBlock"), root), "无法构建结算回调")
            pulse:SetVisibility(1); checked(root:AddChildToOverlay(pulse), "无法挂载结算回调")
            session.pulseOwned[index] = true
        end
        session.buttons[index], session.pulses[index] = button, pulse
        if session.practice then session.focusable[index] = button:GetIsFocusable() end
        session.bindings[index] = button.OnButtonBaseClicked:GetBindings()
        button.OnButtonBaseClicked:Clear(); button.OnButtonBaseClicked:Add(pulse, FName("ForceLayoutPrepass"))
        session.actions[pulse:GetAddress()] = index
        session.navigation[#session.navigation + 1] = button
        local tree = unwrap(button.WidgetTree)
        local internal = valid(tree) and unwrap(tree.RootWidget) or nil
        if valid(internal) and not same(internal, button) then session.navigation[#session.navigation + 1] = internal end
    end
    for _, widget in ipairs(session.navigation) do for direction = 0, 3 do widget:SetNavigationRuleBase(direction, 3) end end
    session.router = checked(required(SUBSYSTEMS):GetLocalPlayerSubsystem(modal, required(ROUTER)), "结算没有原生 UI 输入路由")
    if session.restoreTarget and session.targetModel then
        session.restoreTarget = nil; showTarget(session, session.targetModel)
    else showResult(session) end
    print("[PBZTestArenaNative] " .. (session.practice and "Simple native practice choices" or "Full-screen native victory modal") .. " attached\n")
end
local function attachIfReady(session)
    local selected
    for address, modal in pairs(ownModals(session.controller)) do
        if not session.before[address] then assert(not selected, "出现多个结算弹窗"); selected = modal end
    end
    if selected then
        local controls, reason = readyControls(selected)
        if controls then attach(session, selected, controls); return true end
        if session.waitReason ~= reason then
            session.waitReason = reason
            print("[PBZTestArenaNative] Victory awaiting native controls: " .. reason .. "\n")
        end
        -- A modal already owns input. Incomplete async widget setup should be
        -- allowed to finish without closing it and releasing the world/bell.
        return false
    end
    assert(os.time() <= session.deadline, "等待原生结算菜单超时")
    return false
end
function Victory.close()
    local session = current
    if not session then return end
    current = nil
    if session.hook then pcall(UnregisterHook, CLICK, session.hook[1], session.hook[2]) end
    local modal = session.modal
    local ok, failure = pcall(detach, session)
    if not ok then print("[PBZTestArenaNative] Victory cleanup: " .. tostring(failure) .. "\n") end
    if valid(modal) and modal:IsActivated() then modal:CloseWindowByCancel() end
end
local function finishReport(session)
    if current~=session or session.returned then return false end
    session.returned=true
    local callback=session.onBack
    Victory.close()
    callback() -- restore the original caller only after all owned UI is gone
    return false
end
local function openSession(gameplay, pawn, report, onAction, profilePath, state,reportOnly)
    Victory.close()
    assert(type(report) == "table" and type(onAction) == "function", "结算数据不可用")
    local session = { pawn = pawn, controller = checked(gameplay:GetPlayerController(pawn, 0), "结算控制器不可用"),
        gameplay=gameplay,
        report = report, info = reportInfo(report,reportOnly), onAction = onAction, profilePath = profilePath,
        reportOnly=reportOnly,onBack=reportOnly and onAction or nil,
        state = state, practice = not reportOnly and(report.mode == "practice" or (type(state) == "table" and state.mode == "practice")),
        buttons = {}, pulses = {}, pulseOwned = {}, focusable = {}, actions = {}, bindings = {}, resultRow = 1 }
    current = session
    local ok, failure = pcall(function()
        local pre, post = RegisterHook(CLICK, function(context)
            if current ~= session or session.pending then return end
            local pulse = unwrap(context:get())
            local index = valid(pulse) and session.actions[pulse:GetAddress()] or nil
            if not index then return end
            if session.reportOnly then
                if index==1 and resultConfirm(session)then queue(session,"report-back","native")end
            elseif session.view == "target" then
                if index == 1 and session.targetModel:canConfirm() then queue(session, "target-confirm", "native")
                elseif index == 2 then queue(session, "target-back", "native") end
            elseif not session.practice and not session.resultControlsReady then
                if session.skipReady and focused(session)then session.skipPending=true end
            elseif resultConfirm(session) then
                if session.practice and (held(session.router, DIRECTIONS[1]) or held(session.router, DIRECTIONS[2])) then return end
                queue(session, session.practice and index or index == 1 and session.resultRow or index, "native")
            end
        end)
        session.hook = { pre, post }
        requestModal(session); attachIfReady(session)
    end)
    if not ok then pcall(Victory.close); error(failure, 0) end
    return true
end
function Victory.open(gameplay,pawn,report,onAction,profilePath,state)
    return openSession(gameplay,pawn,report,onAction,profilePath,state,false)
end
function Victory.openReport(gameplay,pawn,report,onBack,profilePath,state)
    return openSession(gameplay,pawn,report,onBack,profilePath,state,true)
end
local function resultInput(session, gameplay)
    if not focused(session) then
        session.confirmReady, session.directionBlocked, session.activeDirection = false, true, nil
        return
    end
    local confirming=held(session.router,session.practice and CONFIRM_KEYS or SKIP_KEYS)
    if session.consumeGesture then
        session.confirmReady=false
        if confirming then return end
        session.consumeGesture=false
    end
    if not confirming then session.confirmReady = true end
    if session.reportOnly then return end -- a static report has one Back choice
    local previous, nextKey = held(session.router, DIRECTIONS[1]), held(session.router, DIRECTIONS[2])
    if session.practice and not previous and not nextKey then
        for index, button in ipairs(session.buttons) do
            if button:HasUserFocus(session.controller) or button:HasUserFocusedDescendants(session.controller) then
                session.resultRow = index; break
            end
        end
    end
    local now = gameplay:GetRealTimeSeconds(session.modal)
    if not previous and not nextKey then
        session.directionBlocked, session.activeDirection, session.nextRepeat = false, nil, nil
    elseif previous and nextKey then
        session.directionBlocked, session.activeDirection = true, nil
    elseif not session.directionBlocked then
        local direction = previous and -1 or 1
        if session.activeDirection ~= direction or now >= (session.nextRepeat or now) then
            session.nextRepeat = now + (session.activeDirection == direction and .12 or .35)
            session.activeDirection = direction
            session.resultRow = (session.resultRow - 1 + direction) % 3 + 1
            if session.practice then session.buttons[session.resultRow]:SetFocus()
            else
                session.skin.selectedButton = session.resultRow
                session.buttons[1]:SetFocus()
                pcall(Feedback.navigate, session.controller, session.modal)
            end
        end
    end
    if session.practice and (previous or nextKey) then
        local button = session.buttons[session.resultRow]
        if not button:HasUserFocus(session.controller) and not button:HasUserFocusedDescendants(session.controller) then button:SetFocus() end
    end
end
local function resultAnimation(session,gameplay)
    if session.practice or not session.reveal then return false end
    if session.revealWorldChanged then stopRevealTicker(session);return true end
    if not focused(session) then
        session.skipReady,session.confirmReady=false,false
        stopRevealTicker(session); return true
    end
    local down=held(session.router,SKIP_KEYS)
    if not down then
        session.skipReady=true
        -- Preserve the owner's observed release across the natural 3s boundary.
        -- The ticker can reveal buttons between owner ticks; the first fresh A
        -- must not be discarded merely because resultInput has not run yet.
        if not session.consumeGesture then session.confirmReady=true end
    end
    if focused(session) and session.skipReady and (down or session.skipPending)then
        completeReveal(session,true)
        return true -- the skip gesture cannot also operate a revealed button
    end
    session.skipPending=nil
    local elapsed=math.max(0,gameplay:GetRealTimeSeconds(session.modal)-session.reveal.startedAt)
    if elapsed>=BUTTONS_AT then
        presentResult(session,elapsed,false);stopRevealTicker(session);session.reveal=nil;return false
    end
    -- Main service remains 50ms. It handles gestures/lifecycle, while this short
    -- 16ms game-thread loop owns only moving/fading UI during the intro.
    if not session.revealTicker and not startRevealTicker(session) then presentResult(session,elapsed,false) end
    return true
end
function Victory.update(gameplay)
    local session = current
    if not session then return false end
    if not session.modal then attachIfReady(session); return true end
    if not valid(session.modal) or not session.modal:IsActivated() then
        if session.reportOnly then return finishReport(session)end
        -- Native Back already released this CommonUI page. Preserve the shared
        -- selection model only when Back meant Enemy -> Player, then reopen it.
        local keep = session.targetModel and session.targetModel:back() == true
        detach(session, keep)
        session.restoreTarget, session.modal = keep, nil
        requestModal(session); attachIfReady(session)
        return true
    end
    if session.view == "target" then session.targetModel:update(gameplay)
    else
        if session.skin then session.skin:update() end
        local animating=resultAnimation(session,gameplay)
        if not animating then resultInput(session, gameplay)end
    end
    local action = session.pending; session.pending = nil
    if not action then return true end
    if action.kind=="report-back" and session.reportOnly then
        if action.source=="native" and not resultConfirm(session)then return true end
        return finishReport(session)
    elseif action.kind == "target-back" then targetBack(session)
    elseif action.kind == "target-confirm" then
        local model = session.targetModel
        if not model:canConfirm() then return true end
        if model:confirm() then session.onAction("change", model:getSettings()) end
    elseif type(action.kind) == "number" then
        if action.source == "native" and not resultConfirm(session) then return true end
        print("[PBZTestArenaNative] Victory choice mode=" .. (session.practice and "practice" or "challenge")
            .. "; index=" .. action.kind .. "; label=" .. LABELS[action.kind] .. "; source=" .. tostring(action.source) .. "\n")
        if action.kind == 1 then session.onAction("retry")
        elseif action.kind == 2 then showTarget(session)
        elseif action.kind == 3 then session.onAction("exit") end
    end
    return true
end
return Victory
