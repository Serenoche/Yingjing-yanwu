-- Shared encounter target form. Bell uses a native child modal; victory mounts
-- the same model into its existing modal so CommonUI keeps input ownership.
local Catalog = require("EncounterCatalog")
local Profile = require("PlayerProfile")
local Scenes = require("ArenaScenes")
local Target, Model = {}, {}
Model.__index = Model
local DESCRIPTORS = "/Script/CommonGame.Default__CommonGameDialogDescriptor"
local CONFIRMATION = "/Script/CommonGame.Default__AsyncAction_ShowConfirmation"
local CLICK = "/Script/UMG.Widget:ForceLayoutPrepass"
local MODAL = "W_ConfirmationDefault_C"
local current
local function firstEntry(category)
    local entries = Catalog.list(category or "duel")
    return entries and entries[1]
end
local function selectedEntry(state)
    local selectedId=state.encounterId or state.bossId
    local entry = Catalog.resolve(selectedId)
    return (entry and not entry.legacy and entry) or firstEntry(Catalog.retiredCategory(selectedId) or state.category) or firstEntry("duel")
end

local function unwrap(object)
    if object and type(object.IsValid) ~= "function" then
        local getter = object.get or object.Get
        if type(getter) == "function" then return getter(object) end
    end
    return object
end
local function valid(object) return object ~= nil and type(object.IsValid) == "function" and object:IsValid() end
local function checked(object, message) object = unwrap(object); assert(valid(object), message); return object end
local function same(first, second) return valid(first) and valid(second) and first:GetAddress() == second:GetAddress() end
local function required(path) return checked(StaticFindObject(path), "缺少原版目标菜单接口：" .. path) end
local function integer(value, maximum)
    return type(value) == "number" and value % 1 == 0 and value >= 0 and value <= maximum
end
local function clamp(value, maximum) return math.max(0, math.min(maximum, value)) end

function Target.form(state, baseline)
    baseline = baseline or state
    local skill = Profile.valid(state.playerCycle) and Profile.normalizeSkillLevel(state.playerCycle, state.skillLevel)
    assert(Profile.valid(state.playerCycle) and integer(state.enemyCycle, 6)
        and integer(skill, Profile.skillCap(state.playerCycle)), "当前挑战参数无效")
    local entry = assert(selectedEntry(state), "当前没有可用挑战")
    local settings = { bossId = entry.id, encounterId = entry.id, category = entry.category,
        playerCycle = state.playerCycle, enemyCycle = state.enemyCycle, skillLevel = skill,
        difficultyMode = integer(state.difficultyMode, 3) and state.difficultyMode >= 1 and state.difficultyMode or 3,
        mode = state.mode == "practice" and "practice" or "challenge", sceneId = Scenes.forEncounter(entry.id, Scenes.normalize(state.sceneId)).id }
    local remembered = { [entry.category] = entry.id }
    local function select(chosen)
        assert(chosen and #chosen.stages > 0, "挑战尚未开放")
        settings.bossId, settings.encounterId, settings.category = chosen.id, chosen.id, chosen.category
        settings.sceneId = Scenes.forEncounter(chosen.id, settings.sceneId).id
        remembered[chosen.category] = chosen.id
    end
    local model = setmetatable({ settings = settings }, Model)
    model.rows = {
        { label = "挑战类型", value = function() return assert(Catalog.resolve(settings.bossId)).categoryName end,
            change = function(delta)
                local index = 1
                for current, category in ipairs(Catalog.categories) do
                    if category.id == settings.category then index = current; break end
                end
                local category = Catalog.categories[(index - 1 + delta) % #Catalog.categories + 1].id
                select(Catalog.resolve(remembered[category]) or firstEntry(category))
            end },
        { label = "挑战目标", value = function() return assert(Catalog.resolve(settings.bossId)).name end,
            change = function(delta)
                local entries, selected = Catalog.list(settings.category), 1
                for index, candidate in ipairs(entries) do
                    if candidate.id == settings.bossId then selected = index; break end
                end
                select(entries[(selected - 1 + delta) % #entries + 1])
            end },
        { label = "玩家轮回", value = function() return Profile.rank(settings.playerCycle) end, change = function(delta)
            local cycle = math.max(-1, math.min(6, settings.playerCycle + delta))
            if cycle ~= settings.playerCycle then
                settings.playerCycle = cycle
                settings.skillLevel = Profile.normalizeSkillLevel(cycle,
                    cycle == baseline.playerCycle and baseline.skillLevel or Profile.skillCap(cycle))
            end
        end },
        { label = "首领轮回", value = function() return tostring(settings.enemyCycle) end,
            change = function(delta) settings.enemyCycle = clamp(settings.enemyCycle + delta, 6) end },
        { label = "技能等级", value = function() return settings.playerCycle == -1 and "-" or ("%d / %d"):format(settings.skillLevel, Profile.skillCap(settings.playerCycle)) end,
            enabled = function() return settings.playerCycle ~= -1 end,
            change = function(delta)
                if settings.playerCycle ~= -1 then settings.skillLevel = clamp(settings.skillLevel + delta, Profile.skillCap(settings.playerCycle)) end
            end },
    }
    local difficulties = { "入阵者", "破局者", "逆天者" }
    model.screenRows = {
        { label = "轮回", value = model.rows[3].value, change = model.rows[3].change },
        model.rows[5],
        { label = "类型", value = model.rows[1].value, change = model.rows[1].change },
        { label = "目标", value = model.rows[2].value, change = model.rows[2].change },
        { label = "轮回", value = function() return Profile.rank(settings.enemyCycle, "enemy") end,
            change = model.rows[4].change },
        { label = "难度", value = function() return difficulties[settings.difficultyMode] end,
            change = function(delta) settings.difficultyMode = math.max(1, math.min(3, settings.difficultyMode + delta)) end },
        { label = "场景", value = function() return Scenes.get(settings.sceneId).name end,
            enabled = function() return #Scenes.list() > 1 end,
            change = function(delta)
                local choices, selected = Scenes.list(), 1
                for index, scene in ipairs(choices) do if scene.id == settings.sceneId then selected = index end end
                settings.sceneId = choices[(selected - 1 + delta) % #choices + 1].id
            end } }
    return model
end
function Model:getSettings()
    local settings = self.settings
    return { bossId = settings.bossId, encounterId = settings.encounterId, category = settings.category,
        playerCycle = settings.playerCycle, enemyCycle = settings.enemyCycle, skillLevel = settings.skillLevel,
        difficultyMode = settings.difficultyMode, mode = settings.mode, sceneId = settings.sceneId }
end
function Model:mount(modal, description, controller, confirm, options)
    self:close()
    self.form = require("NativeSelection").open(self, modal, description, controller, confirm, options)
    return self
end
function Model:update(gameplay) return self.form and self.form:update(gameplay) or false end
function Model:canConfirm() return self.form and self.form:canConfirm() or false end
function Model:confirm() return self.form and self.form:confirm() or false end
function Model:back()
    local handled = self.form and self.form:back() or false
    if handled then self.region = self.form.form.region end
    return handled
end
function Model:takeAction() local action = self.pendingAction; self.pendingAction = nil; return action end
function Model:close() if self.form then self.form:close(); self.form = nil end end

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
local function detach(session)
    session.model:close()
    for index, button in ipairs(session.buttons) do
        if valid(session.modal) and session.modal:IsActivated() and valid(button) then
            button.OnButtonBaseClicked:Clear()
            for _, binding in ipairs(session.bindings[index] or {}) do
                local object = unwrap(binding.Object)
                if valid(object) then button.OnButtonBaseClicked:Add(object, binding.FunctionName) end
            end
        end
    end
    for _, pulse in ipairs(session.pulses) do if valid(pulse) then pulse:RemoveFromParent() end end
end
function Target.close()
    local session = current
    if not session then return end
    current = nil
    if session.hook then pcall(UnregisterHook, CLICK, session.hook[1], session.hook[2]) end
    local ok, failure = pcall(detach, session)
    if not ok then print("[PBZTestArenaNative] Target menu cleanup: " .. tostring(failure) .. "\n") end
    if valid(session.modal) and session.modal:IsActivated() then session.modal:CloseWindowByCancel() end
end
local function attach(session, modal)
    session.modal = modal
    local root = checked(checked(modal.WidgetTree, "目标弹窗没有控件树").RootWidget, "目标弹窗没有根控件")
    checked(modal.Text_Title, "目标弹窗没有标题"):SetText(FText("更换目标"))
    local description = checked(modal.RichText_Description, "目标弹窗没有正文")
    description:SetText(FText(""))
    local group = checked(modal.ButtonGroup, "目标弹窗没有导航组")
    assert(group:GetButtonCount() == 3, "目标弹窗按钮数量不符")
    for index = 1, 3 do
        local button = checked(group:GetButtonBaseAtIndex(index - 1), "目标弹窗按钮未就绪")
        session.buttons[index] = button
        local pulse = checked(StaticConstructObject(required("/Script/UMG.TextBlock"), root), "无法创建目标菜单回调")
        pulse:SetVisibility(1); checked(root:AddChildToOverlay(pulse), "无法挂载目标菜单回调")
        session.pulses[index] = pulse
        session.bindings[index] = button.OnButtonBaseClicked:GetBindings()
        button.OnButtonBaseClicked:Clear(); button.OnButtonBaseClicked:Add(pulse, FName("ForceLayoutPrepass"))
        button:SetVisibility(index <= 2 and 0 or 1); button:SetIsEnabled(index <= 2)
        button:SetButtonText(FText(index == 1 and "应用并重新挑战" or index == 2 and "返回" or ""))
    end
    session.model:mount(modal, description, session.controller, session.buttons[1], {
        onConfirm = function() session.pending = 1 end,
        onBack = function() session.pending = 2 end,
    })
end
local function attachIfReady(session)
    local selected
    for address, modal in pairs(ownModals(session.controller)) do
        if not session.before[address] then assert(not selected, "存在多个目标弹窗"); selected = modal end
    end
    if selected then attach(session, selected); return true end
    assert(os.time() <= session.deadline, "等待原版目标弹窗超时")
    return false
end
function Target.open(gameplay, pawn, state, onChange, onBack, region)
    Target.close()
    local controller = checked(gameplay:GetPlayerController(pawn, 0), "找不到目标菜单控制器")
    assert(type(onChange) == "function" and type(onBack) == "function", "缺少目标菜单回调")
    local session = { pawn = pawn, controller = controller, model = Target.form(state), onChange = onChange, onBack = onBack,
        buttons = {}, pulses = {}, bindings = {}, before = ownModals(controller), deadline = os.time() + 4 }
    session.model.region = region or 1
    assert(next(session.before) == nil, "请先关闭其他原版确认弹窗")
    current = session
    local ok, failure = pcall(function()
        local pre, post = RegisterHook(CLICK, function(context)
            if current ~= session or session.pending or session.closing then return end
            local pulse = unwrap(context:get())
            for index = 1, 2 do
                if same(pulse, session.pulses[index]) then
                    if index == 1 and not session.model:canConfirm() then return end
                    session.pending = index
                    return
                end
            end
        end)
        session.hook = { pre, post }
        local descriptor = checked(required(DESCRIPTORS):CreateConfirmationOk(pawn, FText("更换目标"), FText("")), "无法创建目标弹窗")
        for index, label in ipairs({"应用并重新挑战", "返回", ""}) do
            descriptor.ButtonActions[index] = { Result = index - 1, OptionalDisplayText = FText(label) }
        end
        session.request = checked(required(CONFIRMATION):ShowConfirmationCustom(pawn, descriptor), "无法请求原版目标弹窗")
        session.request:Activate()
        attachIfReady(session)
    end)
    if not ok then Target.close(); error(failure, 0) end
    return true
end
function Target.update(gameplay)
    local session = current
    if not session then return false end
    if not session.modal then attachIfReady(session); return true end
    if not valid(session.modal) or not session.modal:IsActivated() then
        -- Native Back owns deactivation. Reopen the same native page one region
        -- back only after it has fully released input; outer Back resumes bell.
        if not session.chosen and session.model:back() then
            local state, region = session.model:getSettings(), session.model.region
            local onChange, onBack = session.onChange, session.onBack
            Target.close(); Target.open(gameplay, session.pawn, state, onChange, onBack, region)
            return true
        end
        local settings, onChange, onBack = session.chosen, session.onChange, session.onBack
        Target.close()
        if settings then onChange(settings) else onBack() end
        return false
    end
    if session.closing then return true end
    session.model:update(gameplay)
    local pending = session.pending; session.pending = nil
    if pending then
        if pending == 1 then
            if not session.model:confirm() then return true end
            session.chosen = session.model:getSettings()
        elseif session.model:back() then return true end
        session.closing = true
        -- Keep the artwork through the stock exit animation. Final detach and
        -- exact native-tree restoration occur only after deactivation above.
        session.modal:CloseWindowByCancel()
    end
    return true
end

return Target
