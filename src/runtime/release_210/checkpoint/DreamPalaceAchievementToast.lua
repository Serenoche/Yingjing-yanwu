local Catalog = require("DreamPalaceAchievements")
local Toast = {}

local ENABLE_PREVIEW_KEY = false
local FADE_IN, HOLD, FADE_OUT = .3, 5, .35
local DURATION = FADE_IN + HOLD + FADE_OUT
local UPDATE_MS = 33
local INSET_RIGHT, INSET_TOP = 72, 64
local INK_BAR = "/Game/PBZContent/UI/Texture/PauseMenu/T_Mission_Inkbar_Default.T_Mission_Inkbar_Default"
local NOTE_GAP = .20
local UNLOCK_SOUNDS = {
    ding = "/Game/Wwise/Events/UI/UI_Int/UI_PickUp/SFX_UI_Tips_PickUp_Prompt_Metal_B.SFX_UI_Tips_PickUp_Prompt_Metal_B",
    dong = "/Game/Wwise/Events/UI/UI_General/SFX_UI_General_Confirm_Dong.SFX_UI_General_Confirm_Dong",
}
local SUBSYSTEM_LIBRARY = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local SOUND_SUBSYSTEM = "/Script/ProjectPBZ.PBZSoundFXSubsystem"
local milestoneFloors = {}
for _, item in ipairs(Catalog) do
    if item.floor then milestoneFloors[item.floor] = true end
end

local entries = {}
local watchedBase, readEarned, earned, assisted
local view, retryAt, lastError
local soundEvents, soundErrors = {}, {}
local ticker
local previewGameplay, previewController
local canSchedule = type(LoopInGameThreadWithDelay) == "function" and type(CancelDelayedAction) == "function"

local function valid(object) return object and type(object.IsValid) == "function" and object:IsValid() end
local function same(first, second)
    return valid(first) and valid(second) and first:GetAddress() == second:GetAddress()
end
local function checked(object, message) assert(valid(object), message); return object end
local function log(message) print("[PBZDreamPalaceUI] " .. message .. "\n") end

local function detach()
    if view and valid(view.panel) then pcall(view.panel.RemoveFromParent, view.panel) end
    view, retryAt = nil, nil
    for _, entry in ipairs(entries) do entry.widget, entry.alpha = nil, nil end
end

local function stopTicker()
    local stopped = ticker
    ticker = nil
    if stopped then pcall(CancelDelayedAction, stopped.handle) end
end

local function readProgress()
    local ok, result, assistedResult = pcall(readEarned, watchedBase, true)
    if ok then return result, assistedResult or {} end
    log("achievement notification progress: " .. tostring(result))
end

function Toast.watch(base, reader)
    if watchedBase ~= base then
        stopTicker()
        detach()
        entries = {}
    end
    watchedBase, readEarned = base, reader
    earned, assisted = readProgress()
end

function Toast.refresh(base)
    if base ~= watchedBase then return end
    local updated, updatedAssisted = readProgress()
    if not updated then return end
    if earned then
        for _, item in ipairs(Catalog) do
            local id = item[1]
            local restored = assisted[id] and not updatedAssisted[id]
            if updated[id] and (not earned[id] or restored) then
                entries[#entries + 1] = { name = item[2], age = 0, updated = restored }
                log((restored and "achievement updated: " or "achievement unlocked: ") .. item[2])
            end
        end
    end
    earned, assisted = updated, updatedAssisted
end

function Toast.resultWritten(base, cleared, outcome, flags)
    -- Only victory, restore and milestone writes can change the earned set.
    -- The r flag also covers the fallback when a restore record could not be written.
    if outcome == "win" or outcome == "restore"
        or outcome == "clear" and (milestoneFloors[cleared] or flags:find("[rl]")) then
        Toast.refresh(base)
    end
end

local function mount(controller, layout, root, kind)
    view = { controller = controller, layout = layout, root = root }
    local boxClass = checked(StaticFindObject("/Script/UMG.VerticalBox"), "成就提示缺少原生竖向容器")
    local panel = checked(StaticConstructObject(boxClass, layout.WidgetTree), "无法创建成就提示")
    view.panel = panel
    panel:SetVisibility(3)
    if kind == "CanvasPanel" then
        local slot = checked(root:AddChildToCanvas(panel), "无法挂载成就提示")
        slot:SetAnchors({ Minimum = { X = 1, Y = 0 }, Maximum = { X = 1, Y = 0 } })
        slot:SetPosition({ X = -INSET_RIGHT, Y = INSET_TOP })
        slot:SetAlignment({ X = 1, Y = 0 })
        slot:SetAutoSize(true)
        slot:SetZOrder(100001)
    else
        local slot = checked(root:AddChildToOverlay(panel), "无法挂载成就提示")
        slot:SetHorizontalAlignment(3)
        slot:SetVerticalAlignment(1)
        slot:SetPadding({ Left = 0, Top = INSET_TOP, Right = INSET_RIGHT, Bottom = 0 })
    end
end

local function addName(entry)
    local tree = view.layout.WidgetTree
    local prefix = entry.updated and "成就更新 · " or "成就解锁 · "
    local text = require("ParameterStyle").text(tree, prefix .. entry.name, false, 32)
    text:SetJustification(2)
    text:SetShadowOffset({ X = 1, Y = 2 })
    text:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = .88 })
    local row = text
    if view.ink == nil then
        local ink, metadata = require("ArtAssets").texture(view.controller, INK_BAR)
        view.ink = ink or false
        if not ink then log("achievement ink unavailable: " .. tostring(metadata and metadata.reason)) end
    end
    if valid(view.ink) then
        local class = checked(StaticFindObject("/Script/UMG.Border"), "成就提示缺少原生底条容器")
        row = checked(StaticConstructObject(class, tree), "无法创建成就提示底条")
        row:SetVisibility(3)
        row:SetBrushFromTexture(view.ink)
        row:SetContent(text)
        -- Border's desired size comes from the child and padding. The
        -- native brush then fills that size, including both feathered ends.
        row:SetPadding({ Left = 30, Top = 10, Right = 30, Bottom = 10 })
    end
    row:SetRenderOpacity(0)
    local slot = checked(view.panel:AddChildToVerticalBox(row), "无法显示成就名称")
    slot:SetHorizontalAlignment(3)
    slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 6 })
    entry.widget, entry.alpha = row, 0
end

local function playUnlockSound(controller, note)
    local ok, result = pcall(function()
        local event = soundEvents[note]
        if not valid(event) then
            event = require("CombatSpawn").class(UNLOCK_SOUNDS[note])
            soundEvents[note] = event
        end
        local library = checked(StaticFindObject(SUBSYSTEM_LIBRARY), "游戏子系统接口未加载")
        local class = checked(StaticFindObject(SOUND_SUBSYSTEM), "游戏声音子系统未加载")
        local subsystem = checked(library:GetWorldSubsystem(controller, class), "当前场景的声音不可用")
        local id = subsystem:PBZPostEventGlobal(event, nil)
        assert(type(id) == "number" and id > 0, "游戏未返回解锁音效的 PlayingID")
        return id
    end)
    if ok then
        soundErrors[note] = nil
        log("achievement sound " .. note .. " PlayingID=" .. result)
    elseif tostring(result) ~= soundErrors[note] then
        soundErrors[note] = tostring(result)
        log("achievement sound " .. note .. " unavailable: " .. soundErrors[note])
    end
end

local function animate(gameplay, controller, now)
    if view and not same(view.controller, controller) then detach() end
    if not view or now >= view.validateAt then
        local layout, root, kind = require("StageScreen").gameLayout(controller)
        if view and (not same(view.layout, layout) or not same(view.root, root)
            or not valid(view.panel) or not same(view.panel:GetParent(), root)) then detach() end
        if not view then mount(controller, layout, root, kind) end
        view.validateAt = now + .25
    end
    local elapsed = view.lastTime and math.max(0, now - view.lastTime) or 0
    view.lastTime = now
    local playSound = false
    local index = 1
    while index <= #entries do
        local entry = entries[index]
        if entry.widget then
            entry.age = entry.age + elapsed
        else
            addName(entry)
            if not entry.announced then
                entry.announced, playSound = true, true
                log("achievement notification mounted: " .. entry.name)
            end
        end
        if entry.age >= DURATION then
            entry.widget:RemoveFromParent()
            table.remove(entries, index)
        else
            local t = math.min(1, entry.age / FADE_IN, (DURATION - entry.age) / FADE_OUT)
            local alpha = t * t * (3 - 2 * t)
            if entry.alpha ~= alpha then entry.widget:SetRenderOpacity(alpha); entry.alpha = alpha end
            index = index + 1
        end
    end
    -- Multiple unlocks from one settlement share a chime. Reattaching
    -- surviving notices after a map change keeps their original cue.
    if view.dongAt and now >= view.dongAt then
        view.dongAt = nil
        playUnlockSound(controller, "dong")
    end
    -- Notices arriving before the second note share the current pair.
    if playSound and not view.dongAt then
        playUnlockSound(controller, "ding")
        view.dongAt = gameplay:GetRealTimeSeconds(controller) + NOTE_GAP
    end
end

local function update(gameplay, controller)
    if #entries == 0 then stopTicker(); return end
    if not valid(controller) then
        stopTicker()
        if view then detach() end
        return
    end
    local now
    local ok, reason = pcall(function()
        now = gameplay:GetRealTimeSeconds(controller)
        if not retryAt or now >= retryAt then animate(gameplay, controller, now) end
    end)
    if ok and #entries == 0 then
        stopTicker()
        detach()
    elseif not ok then
        detach()
        retryAt = now and now + .5
        local message = tostring(reason)
        if message ~= lastError then log("achievement notification awaiting native layout: " .. message) end
        lastError = message
    end
end

function Toast.update(gameplay, controller)
    if ENABLE_PREVIEW_KEY then previewGameplay, previewController = gameplay, controller end
    if #entries == 0 then return end
    if not valid(controller) then
        stopTicker()
        if view then detach() end
        return
    end
    if ticker and not same(ticker.controller, controller) then
        stopTicker()
        detach()
    end
    if ticker then return end
    update(gameplay, controller)
    if #entries > 0 and canSchedule then
        local action = { controller = controller }
        local ok, handle = pcall(LoopInGameThreadWithDelay, UPDATE_MS, function()
            if ticker == action then update(gameplay, controller) end
        end)
        if ok and type(handle) == "number" and handle > 0 then action.handle, ticker = handle, action
        else canSchedule = false end
    end
end

function Toast.onMapPre()
    previewGameplay, previewController = nil, nil
    stopTicker()
    detach()
end

if ENABLE_PREVIEW_KEY then
    RegisterKeyBind(Key.F2, function()
        ExecuteInGameThread(function()
            if not valid(previewGameplay) or not valid(previewController) then return end
            -- Replay only the HUD. Leave the profile and earned cache untouched.
            for index, entry in ipairs(entries) do
                if entry.preview then
                    if valid(entry.widget) then pcall(entry.widget.RemoveFromParent, entry.widget) end
                    table.remove(entries, index)
                    break
                end
            end
            local name = "小试牛刀"
            entries[#entries + 1] = { name = name, age = 0, preview = true }
            log("F2 achievement preview: " .. name)
            Toast.update(previewGameplay, previewController)
        end)
    end)
end

return Toast
