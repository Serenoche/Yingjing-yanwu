local Menus = require("ArenaMenuCatalog")
local Target = require("ChallengeTarget")
local Flow, Picker = {}, {}
Flow.__index, Picker.__index = Flow, Picker

local DEFAULT_MUSIC = { id = "default", name = "默认" }
local SECTIONS = { character = true, target = true, scene = true, music = true }
local TRAINING_PAGE_SIZE = 10

function Picker:current()
    return self.index == 0 and self.pinned or self.groups[self.region].entries[self.index]
end

local function indexOf(entries, id)
    for index, entry in ipairs(entries) do
        if entry.id == id then return index end
    end
end

function Picker:select(id)
    if self.pinned and id == self.pinned.id then self.index = 0; return true end
    for region, group in ipairs(self.groups) do
        local index = indexOf(group.entries, id)
        if index then self.region, self.index = region, index; return true end
    end
    return false
end

function Picker.new(groups, selected, pinned)
    local self = setmetatable({
        groups = groups, region = 1, index = 1, pinned = pinned, applied = selected,
    }, Picker)
    self:select(selected)
    return self
end

function Picker:entries() return self.groups[self.region].entries end
function Picker:regionName() return self.groups[self.region].name end

function Picker:changeRegion(delta)
    if #self.groups <= 1 then return false end
    self.region = (self.region - 1 + delta) % #self.groups + 1
    self.index = indexOf(self:entries(), self.applied) or 1
    return true
end

function Picker:move(delta)
    local nextIndex = self.index + delta
    if nextIndex < (self.pinned and 0 or 1) or nextIndex > #self:entries() then return false end
    self.index = nextIndex
    return true
end

function Picker:step(delta)
    self.index = self.index == 0 and (delta > 0 and 1 or #self:entries())
        or (self.index - 1 + delta) % #self:entries() + 1
end

function Flow.new(settings, baseline)
    return setmetatable({ model = Target.form(settings, baseline), baseline = baseline or settings,
        page = "overview", focus = "target" }, Flow)
end

function Flow:settings() return self.model:getSettings() end

function Flow:showTargets(member)
    local count = self.draft:customCount()
    self.member = count > 0 and math.min(member or 1, count) or nil
    self.picker = Picker.new(Menus.targets(self.draft, self.member), self.draft:targetId(self.member))
end

function Flow:targetField() return self.member and "member-" .. self.member or "opponent" end
function Flow:choiceFocus()
    local option = self.picker:current()
    return option and "pick-" .. option.id
end

function Flow:refreshTrainingTargets()
    local training = require("TrainingTarget")
    local choices = self.trainingFilters:choices()
    local count = math.max(1, math.ceil(#choices / TRAINING_PAGE_SIZE))
    local groups = {}
    for page = 1, count do
        local entries = {}
        for index = (page - 1) * TRAINING_PAGE_SIZE + 1, math.min(page * TRAINING_PAGE_SIZE, #choices) do
            entries[#entries + 1] = choices[index]
        end
        groups[page] = { name = ("%d / %d"):format(page, count), entries = entries }
    end
    self.trainingCount = #choices
    self.picker = Picker.new(groups, training.option(self.draft.settings.trainingMobId).id)
end

function Flow:chooseTrainingTarget(id)
    assert(self.trainingFilters and self.picker:select(id), "所选目标不在当前筛选结果中")
    self.draft.settings.trainingMobId = require("TrainingTarget").resolve(id) and id or nil
    self.picker.applied = id
end

function Flow:open(section)
    assert(self.page == "overview" and SECTIONS[section], "无效的演武参数页")
    self.draft, self.page = self.model:fork(), section
    if section == "target" then
        if self.draft.settings.mode == "training" then
            self.trainingFilters = require("TrainingTarget").filters()
            self:refreshTrainingTargets()
            self.focus = "parameter-1"
        else
            self:showTargets()
            self.focus = self:targetField()
        end
    elseif section == "character" then
        self.focus = "parameter-1"
    else
        local settings = self.draft.settings
        local encounter = settings.mode ~= "training" and settings.encounterId or nil
        self.picker = section == "scene" and Picker.new(Menus.scenes(settings.mode, encounter), settings.sceneChoice,
            Menus.defaultSceneOption(settings))
            or Picker.new(Menus.music(), settings.musicId, DEFAULT_MUSIC)
        self.focus = self:choiceFocus()
    end
end

function Flow:openTargets(member, choice)
    assert(self.page == "target", "请先打开目标设置")
    if member ~= self.member then self:showTargets(member) end
    if choice then assert(self.picker:select(choice), "目标不在当前地区列表") end
    self.page, self.focus = "targetChoice", self:choiceFocus()
end

function Flow:openCustom(section)
    assert(self.page == "character" and self.draft.settings.customPlayer, "无效的角色设置页")
    local PlayerCustom = require("PlayerCustom")
    assert(PlayerCustom.section(section), "无效的角色设置页")
    local settings = self.draft.settings
    self.customBefore = PlayerCustom.copy(settings.customPlayer, settings.playerCycle)
    self.customSkillBefore = settings.skillLevel
    self.page, self.focus = "playerCustom", "parameter-1"
    self.customSection = section
end

function Flow:leaveCustom(apply)
    if not apply then
        self.draft.settings.customPlayer = self.customBefore
        self.draft.settings.skillLevel = self.customSkillBefore
    end
    self.page, self.focus = "character", "edit-" .. self.customSection
    self.customBefore, self.customSkillBefore, self.customSection = nil, nil, nil
end

function Flow:back()
    local page = self.page
    if page == "overview" then return false end
    if page == "playerCustom" then
        self:leaveCustom(false)
    elseif page == "targetChoice" then
        self:showTargets(self.member)
        self.page, self.focus = "target", self:targetField()
    else
        self.draft, self.picker, self.member = nil, nil, nil
        self.trainingFilters, self.trainingCount = nil, nil
        self.page, self.focus = "overview", page
    end
    return true
end

function Flow:choose()
    local page = self.page
    assert(page ~= "overview", "请从总览进入场地")
    if page == "playerCustom" then self:leaveCustom(true); return end
    if page == "targetChoice" then
        self.draft:chooseTarget(self.picker:current().id, self.member)
        self:back()
        return
    end
    if page == "scene" then self.draft:chooseScene(self.picker:current().id) end
    if page == "music" then self.draft:chooseMusic(self.picker:current().id) end
    self.model = self.draft
    self:back()
end

function Flow:enter()
    assert(self.page == "overview", "请先返回演武总览")
    local ok, reason = self.model:commit()
    if ok then return self:settings() end
    return nil, reason
end

return Flow
