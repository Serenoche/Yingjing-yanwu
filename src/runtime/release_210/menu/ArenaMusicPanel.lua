local Art = require("ArtAssets")
local Assets = require("CombatSpawn")
local Panel = {}
Panel.__index = Panel

local UI = "/Game/PBZContent/UI/Menu/BonusCollection/"
local ITEM_CLASS = UI .. "BP_BonusMuiscItem.BP_BonusMuiscItem_C"
local ROW_CLASS = UI .. "W_Bonus_MusicEntry.W_Bonus_MusicEntry_C"
local COLLECTION_CLASS = UI .. "WB_BonusCollection.WB_BonusCollection_C"
local WIDGETS = "/Script/UMG.Default__WidgetBlueprintLibrary"
-- The shorter arena viewport fits eight native rows, including the expanded selection.
local VISIBLE_ROWS, TOP_ROW, BOTTOM_ROW = 8, 2, 5

local function unwrap(value)
    if value and type(value.IsValid) ~= "function" then
        local get = value.get or value.Get
        if type(get) == "function" then return get(value) end
    end
    return value
end

local function valid(value)
    return value and type(value.IsValid) == "function" and value:IsValid()
end

local function checked(value, name)
    value = unwrap(value)
    assert(valid(value), "原版音乐页缺少 " .. name)
    return value
end

local function timeLabel(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    return ("%02d:%02d"):format(seconds // 60, seconds % 60)
end

local function setVisibility(widget, visibility)
    if valid(widget) then widget:SetVisibility(visibility) end
end

local function formatName(row, track)
    local name = FText(track.name)
    for _, field in ipairs({ "MusicName", "MusicName_1", "MusicName_Copy" }) do
        local label = row[field]
        if valid(label) then
            if field == "MusicName_1" then label.bUseCustomColor = false end
            label:SetPBZFormatText(name)
        end
    end
end

local function animation(row, field, start)
    local effect = row[field]
    if not valid(effect) then return end
    if start then row:QueuePlayAnimation(effect, 0, 1, 0, 1, false)
    else row:QueueStopAnimation(effect) end
end

local function refreshRow(row, state, selected, hovered, playing)
    hovered = hovered and not selected
    local layoutChanged = state.selected ~= selected
    if layoutChanged then
        state.selected = selected
        row.Selected:SetVisibility(selected and 4 or 1)
        row.Default:SetVisibility(selected and 1 or 4)
        row:DoSelectedAppearance(selected)
        if valid(row.Bar_W) then
            row.Bar_W:SetRenderOpacity(selected and 1 or 0)
            local fill = row.Bar_W:GetDynamicMaterial()
            if valid(fill) then fill:SetScalarParameterValue(FName("DebugDissolveVal"), selected and 1 or 0) end
        end
    end
    if (state.hovered == true) ~= hovered then
        state.hovered = hovered
        animation(row, "AI_BonusMusicTextHoverIn", false)
        animation(row, "AI_BonusMusicTextHoverOut", false)
        if selected and valid(row.QuestNameRetainer_1) then
            row.QuestNameRetainer_1:SetRenderScale({ X = 1, Y = 1 })
        else
            animation(row, hovered and "AI_BonusMusicTextHoverIn" or "AI_BonusMusicTextHoverOut", true)
        end
    end
    if state.playing ~= playing then
        state.playing = playing
        setVisibility(row.NS_MusicPlay, playing and 3 or 1)
    end
    return layoutChanged
end

function Panel:populate(picker)
    local class = Assets.class(ITEM_CLASS)
    local count = 0
    local function add(track)
        local item = checked(StaticConstructObject(class, self.list), "曲目数据项")
        item.MusicRowName = FName(track and track.id ~= "default" and track.id or "None")
        if track then
            self.items[track.id], self.tracks[item:GetAddress()] = item, track
            self.indices[track.id] = count
            count = count + 1
        end
        self.list:AddItem(item)
    end
    self.list:ClearListItems()
    if picker.pinned then add(picker.pinned) end
    for _, track in ipairs(picker:entries()) do add(track) end
    self.maxScrollOffset = 0
    if count >= VISIBLE_ROWS then
        -- The original list uses blank tail rows to bring the last track above its fade.
        self.maxScrollOffset = count - 1 - BOTTOM_ROW
        for _ = 1, VISIBLE_ROWS - BOTTOM_ROW do add() end
    end
    self:select(picker:current().id)
end

function Panel:select(id)
    local item = self.items[id]
    if not valid(item) then return end
    local list = self.list
    self.selectedId = id
    list:BP_SetSelectedItem(item)
    list:BP_CancelScrollIntoView()
    local offset = list:GetScrollOffset()
    local index = self.indices[id]
    local position = index - offset
    local top = offset
    if position < TOP_ROW then top = index - TOP_ROW
    elseif position > BOTTOM_ROW then top = index - BOTTOM_ROW end
    top = math.max(0, math.min(top, self.maxScrollOffset))
    if top ~= offset then list:SetScrollOffset(top) end
end

function Panel:sampleRows(pointer, cursor)
    local displayed = self.list:GetDisplayedEntryWidgets()
    local rows, states, hovered, ambiguous = {}, {}, nil, false
    local count = type(displayed.GetArrayNum) == "function" and displayed:GetArrayNum() or #displayed
    for index = 1, count do
        local row = unwrap(displayed[index])
        if valid(row) and valid(row.Selected) and valid(row.Default) then
            local item = unwrap(row.ListItem)
            if valid(item) then
                local itemAddress = item:GetAddress()
                local track = self.tracks[itemAddress]
                local address = row:GetAddress()
                local state = self.rowStates[address]
                if not state or state.itemAddress ~= itemAddress then
                    row:StopAnimationsAndLatentActions()
                    if valid(row.QuestNameRetainer_1) then row.QuestNameRetainer_1:SetRenderScale({ X = 1, Y = 1 }) end
                    row:SetVisibility(track and 0 or 3)
                    row:SetRenderOpacity(track and 1 or 0)
                    row:SetIsEnabled(track ~= nil)
                    row:SetIsInteractionEnabled(track ~= nil)
                    if track then formatName(row, track) end
                    state = { itemAddress = itemAddress, id = track and track.id or false }
                end
                states[address] = state
                rows[#rows + 1] = { widget = row, state = state }
                if track and pointer and row:IsHovered() then
                    ambiguous = ambiguous or (hovered ~= nil and hovered ~= track.id)
                    hovered = track.id
                end
            end
        end
    end
    self.rows, self.rowStates = rows, states
    if ambiguous then return self.hovered end
    -- Keep a stationary pointer on the same track until the list actually scrolls.
    if not pointer or not cursor then
        self.hoverOrigin = nil
    elseif hovered ~= self.hovered then
        local offset = self.list:GetScrollOffset()
        local origin = self.hoverOrigin
        if origin and cursor.X == origin.x and cursor.Y == origin.y and offset == origin.offset then
            return self.hovered
        end
        self.hoverOrigin = hovered and { x = cursor.X, y = cursor.Y, offset = offset } or nil
    end
    self.hovered = hovered
    return hovered
end

function Panel:refreshRows(hovered, playing)
    local layoutChanged = false
    for _, entry in ipairs(self.rows) do
        local id = entry.state.id
        -- The expanded native row follows explicit navigation. Hover only animates its text.
        if refreshRow(entry.widget, entry.state, self.selectedId == id, hovered == id, playing == id) then
            entry.widget:ForceLayoutPrepass()
            layoutChanged = true
        end
    end
    if layoutChanged then self.list:ForceLayoutPrepass() end
    if not self.listReady and #self.rows > 0 then
        self.listReady = true
        self.list:SetRenderOpacity(1)
    end
end

function Panel:clickedTrack()
    local selected = unwrap(self.list:BP_GetSelectedItem())
    if valid(selected) then return self.tracks[selected:GetAddress()] end
end

function Panel.new(screen, layer, picker, actions)
    local library = checked(StaticFindObject(WIDGETS), "控件库")
    local template = checked(library:Create(screen.modal, Assets.class(COLLECTION_CLASS), screen.controller), "设定集界面")
    local listBox = checked(template.ListViewSizeBox, "曲目栏")
    local detail = checked(template.RightPaneBox, "详情栏")
    local root = checked(listBox:GetParent(), "音乐页容器")
    assert(checked(detail:GetParent(), "详情栏容器"):GetAddress() == root:GetAddress(), "原版音乐页结构不匹配")
    local wrapper = checked(template.W_PBZ_ListView, "列表外框")
    local list = checked(wrapper.CommonListView_26, "曲目列表")
    local player = checked(template.W_BonusMusicPlayerBar, "播放器")
    local self = setmetatable({
        screen = screen, root = root, list = list, player = player, template = template,
        title = checked(template.MusicName, "曲名"), cover = checked(template.MusicImg, "封面"),
        items = {}, tracks = {}, indices = {}, rows = {}, rowStates = {},
    }, Panel)

    -- Mount the authored music tab without activating the collection's account-level screen.
    list.EntryWidgetClass = Assets.class(ROW_CLASS)
    list:SetSelectionMode(1)
    list:SetRenderOpacity(0)
    listBox.Slot:SetPadding({ Left = 150, Top = 212, Right = 0, Bottom = 0 })
    listBox:SetHeightOverride(612)
    listBox:SetClipping(1)
    template.WidgetSwitcher_MusicLock:SetActiveWidgetIndex(0)
    root:RemoveFromParent()
    root:SetVisibility(4)
    screen:place(root, 0, 0, 1920, 1080, layer)

    local nativeButtons = { { "PrevButton", actions.previous }, { "PlayPauseButton", actions.play },
        { "NextButton", actions.next } }
    for _, binding in ipairs(nativeButtons) do
        screen:listenButton(checked(player[binding[1]], binding[1]), binding[2], layer, layer, "OnClicked")
    end
    screen:listenButton(list, function()
        local track = self:clickedTrack()
        if track then actions.choose(track.id) end
    end, layer, layer, "BP_OnItemClicked")

    setVisibility(player.ModeButton, 1)
    setVisibility(player.VolumeSlider, 1)
    setVisibility(player.VolumeFill, 1)
    if valid(player.ProgressSlider) then player.ProgressSlider:SetLocked(true) end
    self:populate(picker)
    return self
end

function Panel:refresh(track, preview, elapsed)
    local player = self.player
    if self.track ~= track.id then
        self.track = track.id
        self.title:SetPBZFormatText(FText(track.name))
        local cover = track.image and Art.texture(self.screen.modal, track.image)
        if valid(cover) then self.cover:SetBrushFromTexture(cover, false) end
        setVisibility(self.cover, valid(cover) and 3 or 2)
        player.PlayPauseButton:SetIsEnabled(track.id ~= "default")
    end

    local playing = preview and not preview.pausedAt or false
    if self.playing ~= playing then
        self.playing = playing
        local name = playing and "T_Pause" or "T_Play"
        local texture = Art.texture(self.screen.modal, UI .. name .. "." .. name)
        if valid(player.Image_191) and valid(texture) then player.Image_191:SetBrushFromTexture(texture, false) end
    end
    local seconds, total = math.max(0, elapsed or 0), track.seconds or 0
    if self.seconds ~= seconds or self.total ~= total then
        self.seconds, self.total = seconds, total
        local fraction = total > 0 and math.min(1, seconds / total) or 0
        if valid(player.ProgressSlider) then player.ProgressSlider:SetValue(fraction) end
        if valid(player.ProgressFill) then
            local fill = player.ProgressFill:GetDynamicMaterial()
            if valid(fill) then fill:SetScalarParameterValue(FName("BarRatio"), fraction) end
        end
        if valid(player.TimeCurrent) then player.TimeCurrent:SetText(FText(timeLabel(seconds))) end
        if valid(player.TimeTotal) then player.TimeTotal:SetText(FText(timeLabel(total))) end
    end
end

function Panel:updateTransport()
    local player = self.player
    local previous, nextTrack = player.PrevButton:IsHovered(), player.NextButton:IsHovered()
    if self.previousHovered ~= previous and valid(player.Image_119) then
        self.previousHovered = previous
        player.Image_119:SetRenderOpacity(previous and 1 or .4)
    end
    if self.nextHovered ~= nextTrack and valid(player.Image) then
        self.nextHovered = nextTrack
        player.Image:SetRenderOpacity(nextTrack and 1 or .4)
    end
end

return Panel
