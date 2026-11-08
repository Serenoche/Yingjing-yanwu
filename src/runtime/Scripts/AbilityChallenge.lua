-- Only the original ability screen instance opened by challenge preparation is modified.
local CombatSpawn = require("CombatSpawn")
local AbilityChallenge = {}

local WIDGET = "/Game/PBZContent/UI/AbilityWidget/W_AbilityWidget.W_AbilityWidget_C"
local COMMON_UI = "/Script/CommonGame.Default__CommonUIExtensions"
local LIBRARY = "/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary"
local ASC_LIBRARY = "/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary"
local SUBSYSTEM_LIBRARY = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local UI_RUNTIME = "/Script/ProjectPBZ.PBZUIRuntimeDataManager"
local ENHANCED_INPUT = "/Script/EnhancedInput.EnhancedInputLocalPlayerSubsystem"
local HEAVY_ATTACK = "/PBZInput/InputActions/IA_AttackH_Press.IA_AttackH_Press"
local HEAVY_ATTACK_ROW = "IA_HeavyAttack"
local DEFAULT_CONTEXT = "/PBZInput/IMC_Default.IMC_Default"
local INPUT_ROUTER = "/Script/ProjectPBZ.PBZUIActionRouterBase"
local COMMON_INPUT = "/Script/CommonInput.CommonInputSubsystem"
local KEY_LIBRARY = "/Script/Engine.Default__KismetInputLibrary"
local FOOTER_STYLE = "/Game/PBZContent/UI/Foundation/Text/TextStyle_Regular.TextStyle_Regular_C"
local INPUT_DECORATOR = "/Game/PBZContent/UI/Foundation/Text/Decorator/BP_InputActionDecorator.BP_InputActionDecorator_C"
local SEAL_PROMPT = '<InputAction id="HeavyAttack" height="26" RightPadding="5" LeftPadding="0"/>封印'
local ROLLBACK_SECONDS = 0.65
local PULSE_FUNCTION = "ForceLayoutPrepass"
local PULSE_HOOK = "/Script/UMG.Widget:" .. PULSE_FUNCTION
local FINAL = { HeiShi8 = true, ShaChiHuPo8 = true, MemoryFlower8 = true }
local KEYS = {}
for _, prefix in ipairs({ "HeiShi", "ShaChiHuPo", "MemoryFlower", "TopRongShuZhiXin", "BottomRongShuZhiXin" }) do
    for index = 1, (prefix:find("RongShu", 1, true) and 4 or 8) do
        KEYS[#KEYS + 1] = prefix .. index
    end
end

local current, inputSnapshot, lastInputProbe
local profileOverride

local function valid(object)
    return object ~= nil and object:IsValid()
end

local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "缺少能力修行接口：" .. path)
    return object
end

local function same(a, b)
    return valid(a) and valid(b) and a:GetAddress() == b:GetAddress()
end

local function nameText(name)
    if type(name) == "string" then return name end
    return name and name:ToString() or ""
end

local function componentOf(pawn)
    local component = required(LIBRARY):GetPBZAbilityNodesComponent(pawn)
    assert(valid(component), "角色能力树尚未载入")
    return component
end

local function abilitySystem(pawn)
    local asc = required(ASC_LIBRARY):GetAbilitySystemComponent(pawn)
    assert(valid(asc), "角色能力系统尚未载入")
    return asc
end

local function findNode(component, id)
    local map, key = component.AbilityNodeMap, FName(id)
    if not map:Contains(key) then return end
    local node = map:Find(key):get()
    if valid(node) then return node end
end

local function isLao(pawn)
    return profileOverride and same(pawn, profileOverride.pawn)
        and pawn:GetWorld():GetAddress() == profileOverride.world and profileOverride.id == "lao"
        and required(LIBRARY):GetGameCycle(pawn) == 0
end

local function cap(pawn, id)
    if not FINAL[id] then return 1 end
    local cycle = required(LIBRARY):GetGameCycle(pawn)
    assert(type(cycle) == "number" and cycle >= 0 and cycle <= 6, "无法读取角色轮回")
    if isLao(pawn) then return 0 end
    return math.min(30, cycle * 5)
end

function AbilityChallenge.setProfile(pawn, id)
    if id ~= "lao" then profileOverride = nil; return end
    assert(valid(pawn) and required(LIBRARY):GetGameCycle(pawn) == 0, "牢预设必须使用原生零轮回")
    profileOverride = { pawn = pawn, world = pawn:GetWorld():GetAddress(), id = id }
end

function AbilityChallenge.clearProfile(pawn)
    if not pawn or (profileOverride and same(pawn, profileOverride.pawn)) then profileOverride = nil end
end

local function setLevel(component, asc, id, node, target)
    local level, key = node:GetLevel(), FName(id)
    while level > target do
        component:DeactivateNode(key, asc)
        local nextLevel = node:GetLevel()
        assert(nextLevel >= 0 and nextLevel < level, "能力回退没有生效：" .. id)
        level = nextLevel
    end
    while level < target do
        component:ActivateNode(key, asc, false, false)
        local nextLevel = node:GetLevel()
        assert(nextLevel == level + 1, "能力激活没有生效：" .. id)
        level = nextLevel
    end
end

function AbilityChallenge.capture(pawn)
    local component, snapshot = componentOf(pawn), {}
    for _, id in ipairs(KEYS) do
        local node = assert(findNode(component, id), "角色能力树缺少节点：" .. id)
        local level = node:GetLevel()
        assert(type(level) == "number" and level >= 0 and level <= cap(pawn, id), "角色能力等级异常：" .. id)
        snapshot[id] = level
    end
    return snapshot
end

function AbilityChallenge.restore(pawn, snapshot)
    assert(type(snapshot) == "table", "缺少挑战能力配置")
    local component, asc = componentOf(pawn), abilitySystem(pawn)
    local nodes, targets, lao = {}, {}, isLao(pawn)
    for _, id in ipairs(KEYS) do
        local level = snapshot[id]
        -- Migrate only the three old Lao terminal values, preserving every
        -- base-node seal/activation selection in the same cached snapshot.
        local legacyTerminal = lao and FINAL[id]
        assert(type(level) == "number" and level % 1 == 0 and level >= 0
            and level <= (legacyTerminal and 30 or cap(pawn, id)),
            "挑战能力等级超出当前轮回上限：" .. id)
        targets[id] = legacyTerminal and 0 or level
        nodes[id] = assert(findNode(component, id), "角色能力树缺少节点：" .. id)
    end
    for _, id in ipairs(KEYS) do setLevel(component, asc, id, nodes[id], targets[id]) end
    local verified = AbilityChallenge.capture(pawn)
    for _, id in ipairs(KEYS) do
        assert(verified[id] == targets[id], "挑战能力回读不符：" .. id)
    end
    return true
end

function AbilityChallenge.setCycleSkills(pawn, level)
    local component, asc = componentOf(pawn), abilitySystem(pawn)
    for id in pairs(FINAL) do
        assert(level >= 0 and level <= cap(pawn, id), "技能等级超出当前轮回上限")
        local node = assert(findNode(component, id), "角色能力树缺少节点：" .. id)
        setLevel(component, asc, id, node, level)
    end
end

local function findMenu(session)
    for _, widget in ipairs(FindAllOf("W_AbilityWidget_C") or {}) do
        if valid(widget) and widget:IsActivated() and same(widget:GetOwningPlayer(), session.controller) then
            return widget
        end
    end
end

local function findRefreshBinding(session, pawn)
    for _, binding in ipairs(componentOf(pawn).OnActivateNode:GetBindings() or {}) do
        local object = binding.Object
        if valid(object) then
            local identity = tostring(object:GetAddress()) .. ":" .. nameText(binding.FunctionName)
            if not session.beforeOpen[identity] then
                if session.refresh then
                    -- A simultaneous listener registration makes identity ambiguous.
                    session.refresh = nil
                    return
                end
                session.refresh = binding
            end
        end
    end
end

local function selection(session, pawn)
    local group = session.widget["Button Group"]
    if not valid(group) then return end
    local button = group:GetSelectedButtonBase()
    if not valid(button) or nameText(button:GetClass():GetFName()) ~= "W_AbilityNode_C" then return end
    local id = nameText(button["Node ID"])
    if id == "" or id == "None" then return end
    local component = componentOf(pawn)
    local node = findNode(component, id)
    if valid(node) then return id, node, component, button end
end

local function refreshAfterRollback(session, id)
    local binding = session.refresh
    if not binding or not valid(binding.Object) then return end
    -- Invoke only the screen's own JS display listener, never broadcast a fake unlock to the game.
    pcall(function()
        local callback = binding.Object[nameText(binding.FunctionName)]
        if callback then callback(binding.Object, FName(id)) end
    end)
end

local function editable(pawn)
    if not current or not current.hold or not same(pawn, current.pawn)
        or not valid(current.widget) or not current.widget:IsActivated()
        or not same(current.widget:GetOwningPlayer(), current.controller) then return end
    return current
end

local function abilityLayoutAvailable(session)
    local layout = required(LIBRARY):GetUILayOut(session.widget)
    return valid(layout) and not layout:HasModal()
end

local function hasAbilityFocus(session, button)
    if not abilityLayoutAvailable(session) then return false end
    return (valid(button) and required(LIBRARY):WidgetIsInFocusPath(button))
        or session.widget:HasUserFocus(session.controller)
        or session.widget:HasUserFocusedDescendants(session.controller)
end

local function rollback(pawn)
    local session = editable(pawn)
    if not session then return false end
    local id, node, component = selection(session, pawn)
    if not node or node:GetLevel() == 0 then return false end
    setLevel(component, abilitySystem(pawn), id, node, 0)
    refreshAfterRollback(session, id)
    print("[PBZTestArenaNative] Challenge ability rollback: " .. id .. "\n")
    return true
end

local function activate(pawn)
    local session = editable(pawn)
    if not session then return false end
    local id, node, component = selection(session, pawn)
    -- This callback is bound only to the stock hold widget of this active session.
    if not node or not abilityLayoutAvailable(session) or node:GetLevel() >= cap(pawn, id) then return false end
    setLevel(component, abilitySystem(pawn), id, node, node:GetLevel() + 1)
    print("[PBZTestArenaNative] Challenge ability free activation: " .. id .. "\n")
    return true
end

local function construct(classPath, outer)
    local object = StaticConstructObject(required(classPath), outer)
    assert(valid(object), "无法构建能力菜单控件：" .. classPath)
    return object
end

local function enhancedInput(controller)
    local input = required(SUBSYSTEM_LIBRARY):GetLocalPlayerSubsystem(controller, required(ENHANCED_INPUT))
    assert(valid(input), "无法读取杀气连招的游戏按键")
    return input
end

local function loaded(path)
    local object = StaticFindObject(path)
    if not valid(object) then
        LoadAsset(path)
        object = required(path)
    end
    return object
end

local function chooseKeys(keys)
    local keyboard, gamepad
    for index = 1, #keys do
        local key = nameText(keys[index].KeyName)
        if key:match("^Gamepad_") then
            if not gamepad or (gamepad:match("Axis$") and not key:match("Axis$")) then gamepad = key end
        elseif key ~= "None" and key ~= "" then
            keyboard = keyboard or key
        end
    end
    return keyboard, gamepad
end

local function activeAttackKeys(input)
    return chooseKeys(input:QueryKeysMappedToAction(loaded(HEAVY_ATTACK)))
end

local function profileAttackKeys(input)
    local settings = input:GetUserSettings()
    if not valid(settings) then return end
    local mapping = FName(HEAVY_ATTACK_ROW)
    local ok, profile = pcall(function() return settings:GetActiveKeyProfile() end)
    local keyboard, gamepad
    if ok and valid(profile) then
        local keys = {}
        local read = pcall(function() profile:GetMappedKeysInRow(mapping, keys) end)
        if read then keyboard, gamepad = chooseKeys(keys) end
        if keyboard and gamepad then return keyboard, gamepad end
    end
    local found, entries = pcall(function() return settings:FindMappingsInRow(mapping) end)
    if found and entries then
        local keys = {}
        for index = 1, #entries do
            local readable, key = pcall(function() return entries[index].CurrentKey end)
            if readable and key then keys[#keys + 1] = key end
        end
        local extraKeyboard, extraGamepad = chooseKeys(keys)
        return keyboard or extraKeyboard, gamepad or extraGamepad
    end
    return keyboard, gamepad
end

local function defaultAttackKeys()
    local context, action = loaded(DEFAULT_CONTEXT), loaded(HEAVY_ATTACK)
    local keys = {}
    local function readMappings(mappings)
        for index = 1, #mappings do
            local mapping = mappings[index]
            if same(mapping.Action, action) then keys[#keys + 1] = mapping.Key end
        end
    end
    pcall(function() readMappings(context.DefaultKeyMappings.Mappings) end)
    if #keys == 0 then pcall(function() readMappings(context.Mappings) end) end
    return chooseKeys(keys)
end

function AbilityChallenge.captureInput(gameplay, pawn)
    local now = os.time()
    if now == lastInputProbe then return end
    lastInputProbe = now
    local controller = gameplay:GetPlayerController(pawn, 0)
    if not valid(controller) then return end
    local ok, keyboard, gamepad = pcall(function() return activeAttackKeys(enhancedInput(controller)) end)
    if ok and (keyboard or gamepad) then
        inputSnapshot = { controller = controller:GetAddress(), keyboard = keyboard, gamepad = gamepad }
    end
end

local function attackKeys(controller)
    local keyboard, gamepad
    local ok, input = pcall(enhancedInput, controller)
    if ok then
        local active, activeKeyboard, activeGamepad = pcall(activeAttackKeys, input)
        if active then keyboard, gamepad = activeKeyboard, activeGamepad end
        if not keyboard or not gamepad then
            local read, profileKeyboard, profileGamepad = pcall(profileAttackKeys, input)
            if read then keyboard, gamepad = keyboard or profileKeyboard, gamepad or profileGamepad end
        end
    end
    if inputSnapshot and inputSnapshot.controller == controller:GetAddress() then
        keyboard, gamepad = keyboard or inputSnapshot.keyboard, gamepad or inputSnapshot.gamepad
    end
    if not keyboard or not gamepad then
        local read, defaultKeyboard, defaultGamepad = pcall(defaultAttackKeys)
        if read then keyboard, gamepad = keyboard or defaultKeyboard, gamepad or defaultGamepad end
    end
    -- Exact keyboard and controller defaults verified in the pinned game's IMC_Default.
    return keyboard or "F", gamepad or "Gamepad_FaceButton_Top"
end

local function installRollbackInput(session)
    local router = required(SUBSYSTEM_LIBRARY):GetLocalPlayerSubsystem(session.widget, required(INPUT_ROUTER))
    assert(valid(router), "找不到原版能力界面的输入路由")
    session.rollbackKeys = {
        { KeyName = FName(session.attackKeyboard) },
        { KeyName = FName(session.attackGamepad) },
    }
    session.router, session.rollbackBlocked = router, true
    print("[PBZTestArenaNative] Challenge ability rollback input: " ..
        session.attackKeyboard .. " / " .. session.attackGamepad .. "\n")
end

local function updateRollback(session, pawn, id, button)
    if not valid(session.router) then return end
    if not id or not editable(pawn) or not hasAbilityFocus(session, button) then
        session.rollbackBlocked, session.heldKey = true, nil
        return
    end
    local read, held = pcall(function()
        for index, key in ipairs(session.rollbackKeys) do
            if session.router:IsUIKeyHeld(key) then return index end
        end
    end)
    if not read then
        print("[PBZTestArenaNative] Challenge ability rollback input: " .. tostring(held) .. "\n")
        session.router = nil
        return
    end
    if not held then
        session.rollbackBlocked, session.heldKey = false, nil
        return
    end
    if session.rollbackBlocked then return end
    if session.heldKey and (session.heldKey ~= held or session.heldNode ~= id) then
        session.rollbackBlocked, session.heldKey = true, nil
        return
    end
    local now = session.gameplay:GetRealTimeSeconds(pawn)
    if not session.heldKey then
        session.heldKey, session.heldNode, session.heldSince = held, id, now
        print("[PBZTestArenaNative] Challenge ability rollback hold: " .. id .. "\n")
    elseif now - session.heldSince >= ROLLBACK_SECONDS then
        session.rollbackBlocked, session.heldKey = true, nil
        rollback(pawn)
    end
end

local function updateSealPrompt(session)
    if not valid(session.rollbackHint) or session.hintUpdateFailed then return end
    local width = session.nativeBar:GetDesiredSize().X
    if session.hintWidth ~= width then
        session.hintWidth = width
        -- The stock OverlaySlot has Right=100, Bottom=38.
        session.hintSlot:SetPadding({ Left = 0, Top = 0, Right = 116 + width, Bottom = 38 })
    end
    local gamepad, family = false, ""
    if valid(session.commonInput) then
        gamepad = session.commonInput:GetCurrentInputType() == 1
        if gamepad then family = nameText(session.commonInput:GetCurrentGamepadName()) end
    end
    if session.hintGamepad == gamepad and session.hintFamily == family then return end
    session.hintGamepad, session.hintFamily = gamepad, family
    if session.richHint then
        session.rollbackHint:RefreshTextLayout()
    else
        local key = gamepad and session.attackGamepad or session.attackKeyboard
        local label = key
        if gamepad and key == "Gamepad_FaceButton_Top" then
            if family == "PS5" or family == "PS4" then label = "△"
            elseif family == "NS" then label = "X"
            else label = "Y" end
        else
            local ok, display = pcall(function()
                return required(KEY_LIBRARY):Key_GetDisplayName({ KeyName = FName(key) }, false):ToString()
            end)
            if ok and display ~= "" then label = display end
        end
        session.rollbackHint:SetText(FText(label .. "  封印"))
    end
end

local function installRollbackHint(session, parent, nativeBar)
    local rich, hint = pcall(function()
        local block = construct("/Script/ProjectPBZ.PBZCommonLocRichText", parent)
        local style = CombatSpawn.class(FOOTER_STYLE):GetCDO()
        block:SetDefaultFont(style.Font)
        block:SetDefaultShadowOffset(style.ShadowOffset)
        block:SetDefaultShadowColorAndOpacity(style.ShadowColor)
        block:SetDecorators({ CombatSpawn.class(INPUT_DECORATOR) })
        block:SetPBZFormatText(FText(SEAL_PROMPT))
        return block
    end)
    if not rich then
        print("[PBZTestArenaNative] Challenge ability seal prompt: " .. tostring(hint) .. "\n")
        hint = construct("/Script/UMG.TextBlock", parent)
        pcall(function() hint:SetFont(CombatSpawn.class(FOOTER_STYLE):GetCDO().Font) end)
        hint:SetText(FText(session.attackKeyboard .. "  封印"))
    end
    session.rollbackHint = hint
    hint:SetVisibility(3) -- HitTestInvisible
    local slot = parent:AddChildToOverlay(hint)
    assert(valid(slot), "无法添加封印提示")
    slot:SetHorizontalAlignment(3)
    slot:SetVerticalAlignment(3)
    session.hintSlot, session.nativeBar, session.richHint = slot, nativeBar, rich
    local ok, input = pcall(function()
        return required(SUBSYSTEM_LIBRARY):GetLocalPlayerSubsystem(session.widget, required(COMMON_INPUT))
    end)
    if ok and valid(input) then session.commonInput = input end
    updateSealPrompt(session)
end

local function detach(session)
    if session.pulseHook then UnregisterHook(PULSE_HOOK, table.unpack(session.pulseHook)) end
    if valid(session.activatePulse) then session.activatePulse:RemoveFromParent() end
    if valid(session.rollbackHint) then session.rollbackHint:RemoveFromParent() end
    if valid(session.hold) then
        local complete = session.hold.CompleteHold
        complete:Clear()
        for _, binding in ipairs(session.holdBindings or {}) do
            if valid(binding.Object) then complete:Add(binding.Object, binding.FunctionName) end
        end
    end
    if valid(session.costPanel) then session.costPanel:SetVisibility(session.costVisibility) end
end

function AbilityChallenge.close()
    local session = current
    if not session then return end
    current = nil
    if valid(session.widget) and session.widget:IsActivated() then session.widget:DeactivateWidget() end
    detach(session)
end

local function attach(session, pawn)
    local widget = session.widget
    local hold = widget.W_LongPressButton
    assert(valid(hold), "原版能力菜单缺少长按控件")
    local complete = hold.CompleteHold
    local bindings = complete:GetBindings()
    assert(type(bindings) == "table" and #bindings > 0, "原版能力菜单长按未初始化")
    session.hold, session.holdBindings = hold, bindings
    local nativeBar = widget.WB_PBZTriggerBoundAction_C_0
    assert(valid(nativeBar), "原版能力菜单缺少底栏")
    local parent = nativeBar:GetParent()
    assert(valid(parent), "原版能力菜单底栏未挂载")
    session.activatePulse = construct("/Script/UMG.TextBlock", parent)
    -- Keep the per-session delegate target alive without intercepting navigation.
    session.activatePulse:SetVisibility(1)
    assert(valid(parent:AddChildToOverlay(session.activatePulse)), "无法连接能力菜单的原生回调")
    local pre, post = RegisterHook(PULSE_HOOK, function(context)
        if current ~= session or not same(context:get(), session.activatePulse) then return end
        local ok, message = pcall(activate, session.pawn)
        if not ok then print("[PBZTestArenaNative] Challenge ability: " .. tostring(message) .. "\n") end
    end)
    session.pulseHook = { pre, post }
    complete:Clear()
    complete:Add(session.activatePulse, FName(PULSE_FUNCTION))
    hold:HoldReset()
    local costs = widget.W_Upgrade_NeedItemPanel
    if valid(costs) then session.costPanel, session.costVisibility = costs, costs:GetVisibility() end
    findRefreshBinding(session, pawn)
    local ready, reason = pcall(installRollbackInput, session)
    if ready then
        local shown, hintError = pcall(installRollbackHint, session, parent, nativeBar)
        if not shown and valid(session.rollbackHint) then session.rollbackHint:RemoveFromParent() end
        if not shown then print("[PBZTestArenaNative] Challenge ability rollback hint: " .. tostring(hintError) .. "\n") end
    else
        print("[PBZTestArenaNative] Challenge ability rollback input: " .. tostring(reason) .. "\n")
    end
end

function AbilityChallenge.open(gameplay, pawn)
    if current then return same(pawn, current.pawn) end
    if isLao(pawn) then AbilityChallenge.setCycleSkills(pawn, 0) end
    local controller = gameplay:GetPlayerController(pawn, 0)
    assert(valid(controller), "找不到挑战角色控制器")
    local session = { pawn = pawn, controller = controller, gameplay = gameplay, beforeOpen = {}, requestedAt = os.time() }
    assert(not findMenu(session), "请先退出已有的能力修行界面")
    local mapped, keyboard, gamepad = pcall(attackKeys, controller)
    if mapped then session.attackKeyboard, session.attackGamepad = keyboard, gamepad
    else print("[PBZTestArenaNative] Challenge ability attack mapping: " .. tostring(keyboard) .. "\n") end
    for _, binding in ipairs(componentOf(pawn).OnActivateNode:GetBindings() or {}) do
        if valid(binding.Object) then
            session.beforeOpen[tostring(binding.Object:GetAddress()) .. ":" .. nameText(binding.FunctionName)] = true
        end
    end
    -- The stock bell uses the streamed counterpart on this same CommonGame layer.
    local class = CombatSpawn.class(WIDGET)
    local commonUI = required(COMMON_UI)
    local player = commonUI:GetLocalPlayerFromController(controller)
    assert(valid(player), "找不到挑战本地玩家")
    if required(LIBRARY):GetGameCycle(pawn) == 0 then
        -- A wholly inactive tree would otherwise arm the original forced tutorial.
        -- This runs only in the isolated challenge save, without an extra save request.
        local runtime = required(SUBSYSTEM_LIBRARY):GetWorldSubsystem(pawn, required(UI_RUNTIME))
        if valid(runtime) then
            local tutorial = { TagName = FName("UI.Tutorial.AbilityWidget") }
            runtime:AddTutorialTag(tutorial)
            if runtime:HasTutorialTag(tutorial) then runtime:CompleteTutorialTag(tutorial) end
        end
    end
    session.widget = commonUI:PushContentToLayer_ForPlayer(player, { TagName = FName("UI.Layer.Menu") }, class)
    assert(valid(session.widget) and same(session.widget:GetOwningPlayer(), controller), "无法打开原版能力修行")
    current = session
    AbilityChallenge.update(pawn)
    return true
end

function AbilityChallenge.update(pawn)
    local session = current
    if not session then return false end
    if not same(pawn, session.pawn) then AbilityChallenge.close(); return false end
    if not valid(session.widget) or (session.hold and not session.widget:IsActivated()) then
        AbilityChallenge.close()
        return false
    end
    if not session.hold then
        local hold = session.widget.W_LongPressButton
        local bindings = valid(hold) and hold.CompleteHold:GetBindings()
        if not session.widget:IsActivated() or not bindings or #bindings == 0 then
            if os.time() - session.requestedAt < 4 then return true end
            AbilityChallenge.close()
            error("原版能力修行界面未完成初始化")
        end
        local ok, message = pcall(attach, session, pawn)
        if not ok then AbilityChallenge.close(); error(message, 0) end
    end
    local id, node, _, button = selection(session, pawn)
    updateRollback(session, pawn, id, button)
    local hintOk, hintError = pcall(updateSealPrompt, session)
    if not hintOk then
        session.hintUpdateFailed = true
        print("[PBZTestArenaNative] Challenge ability seal prompt: " .. tostring(hintError) .. "\n")
    end
    if valid(session.costPanel) and session.costPanel:GetVisibility() ~= 1 then session.costPanel:SetVisibility(1) end
    if node then
        local level, maximum = node:GetLevel(), cap(pawn, id)
        -- E_Widget_AbilityNodeState is Activated=0, CanActivated=1, NotActivated=2.
        -- Keep the selected node's highlight consistent with the challenge rules.
        local state = level > 0 and 0 or (maximum > 0 and 1 or 2)
        if button["Node State"] ~= state then button:UpdateWidgetState(state) end
        local canUpgrade = level < maximum
        if id ~= session.shownNode or level ~= session.shownLevel or session.hold.CanUpgrade ~= canUpgrade then
            local details = session.widget.BottomSwitcher
            if valid(details) then details:SetActiveWidgetIndex(canUpgrade and 2 or 3) end
            local caption = canUpgrade and "免费修行" or (level > 0 and "已修行" or "轮回不足")
            session.hold:Init(canUpgrade, FText(caption), 0)
            session.shownNode, session.shownLevel = id, level
        end
    else
        session.shownNode = nil
    end
    return true
end

return AbilityChallenge
