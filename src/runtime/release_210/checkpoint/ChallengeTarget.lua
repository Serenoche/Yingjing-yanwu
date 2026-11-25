-- Target settings shared by arena setup and the victory screen.
local Catalog = require("EncounterCatalog")
local Profile = require("PlayerProfile")
local PlayerCustom = require("PlayerCustom")
local Scenes = require("ArenaScenes")
local Menus = require("ArenaMenuCatalog")
local Music = require("BattleMusic")
local Difficulty = require("GameplayDifficulty")
local Pressure = require("DreamPalacePressure")
local Target, Model = {}, {}
Model.__index = Model
local Custom = require("CustomChallenges")
local function firstEntry(category)
    local entries = Catalog.list(category or "duel")
    return entries and entries[1]
end
local function selectedEntry(state)
    local selectedId=state.encounterId or state.bossId
    local entry = Catalog.resolve(selectedId)
    return (entry and not entry.legacy and entry) or firstEntry(Catalog.retiredCategory(selectedId) or state.category) or firstEntry("duel")
end

local function integer(value, maximum)
    return type(value) == "number" and value % 1 == 0 and value >= 0 and value <= maximum
end
local function clamp(value, maximum) return math.max(0, math.min(maximum, value)) end

function Target.form(state, baseline, previous)
    baseline = baseline or state
    local skill = Profile.valid(state.playerCycle) and Profile.normalizeSkillLevel(state.playerCycle, state.skillLevel)
    assert(Profile.valid(state.playerCycle) and integer(state.enemyCycle, 6)
        and integer(skill, Profile.skillCap(state.playerCycle)), "当前挑战参数无效")
    local mode = state.mode == "training" and "training" or state.mode == "practice" and "practice" or "challenge"
    local entry = mode ~= "training" and assert(selectedEntry(state), "当前没有可用挑战") or nil
    local sceneId, sceneChoice = Menus.resolveScene(entry, state.sceneChoice or state.sceneId, mode)
    local customPlayer = PlayerCustom.copy(state.customPlayer, state.playerCycle)
    local settings = { bossId = entry and entry.id or state.bossId, encounterId = entry and entry.id or state.encounterId,
        category = entry and entry.category or state.category, trainingMobId = state.trainingMobId,
        playerCycle = state.playerCycle, enemyCycle = state.enemyCycle, skillLevel = customPlayer.skill or skill,
        difficultyMode = Difficulty.valid(state.difficultyMode) and state.difficultyMode or Difficulty.customBase,
        mode = mode, sceneId = sceneId, sceneChoice = sceneChoice,
        musicId = Music.normalize(state.musicId), customPlayer = customPlayer,
        customProfiles = PlayerCustom.copyProfiles(state.customProfiles) }
    local model = setmetatable({ settings = settings }, Model)
    local playerRow = { label = "档位", value = function() return PlayerCustom.label(settings) end,
        change = function(delta) PlayerCustom.stepProfile(settings, delta, baseline) end }
    local enemyRow = { label = "轮回", value = function() return Profile.rank(settings.enemyCycle, "enemy") end,
        change = function(delta) settings.enemyCycle = clamp(settings.enemyCycle + delta, 6) end }
    local difficulties = Difficulty.choices
    local difficultyRow = { label = "难度", value = function() return difficulties[settings.difficultyMode].name end,
        change = function(delta)
            settings.difficultyMode = math.max(1, math.min(#difficulties, settings.difficultyMode + delta))
        end }
    if mode == "training" then
        if not require("TrainingTarget").resolve(settings.trainingMobId) then settings.trainingMobId = nil end
        model.screenRows = { [1] = playerRow, [5] = enemyRow, [6] = difficultyRow }
        function model:fork() return Target.form(self:getSettings(), baseline) end
        return model
    end

    local remembered, customDrafts = {}, {}
    if previous then
        for category, id in pairs(previous.remembered) do remembered[category] = id end
        for category, draft in pairs(previous.custom) do
            customDrafts[category] = { count = draft.count, members = { table.unpack(draft.members) } }
        end
    end
    remembered[entry.category] = entry.id
    local function select(chosen)
        assert(chosen and #chosen.stages > 0, "挑战尚未开放")
        settings.bossId, settings.encounterId, settings.category = chosen.id, chosen.id, chosen.category
        settings.sceneId, settings.sceneChoice = Menus.resolveScene(chosen, settings.sceneChoice, mode)
        remembered[chosen.category] = chosen.id
    end
    local function customDraft()
        local category = settings.category
        if not Custom.isCategory(category) then return nil end
        if not customDrafts[category] then
            local definition = assert(Custom.parse(settings.bossId))
            customDrafts[category] = { count = #definition.members, members = definition.members }
        end
        return customDrafts[category]
    end
    local function rebuildCustom()
        local draft, members = assert(customDraft()), {}
        for index = 1, draft.count do members[index] = draft.members[index] end
        select(assert(Catalog.resolve(assert(Custom.encode(settings.category, members)))))
    end
    function model:customCount() local draft = customDraft(); return draft and draft.count or 0 end
    function model:fork()
        return Target.form(self:getSettings(), baseline, { remembered = remembered, custom = customDrafts })
    end
    function model:targetId(member)
        if not member then return settings.encounterId end
        local draft = assert(customDraft(), "不是自订阵容")
        assert(member >= 1 and member <= draft.count, "无效的阵容位置")
        return draft.members[member]
    end
    function model:targetChoices(member)
        return member and Custom.choices() or Catalog.list(settings.category)
    end
    function model:chooseTarget(id, member)
        for _, candidate in ipairs(self:targetChoices(member)) do
            if candidate.id == id then
                if member then
                    self:targetId(member)
                    customDraft().members[member] = id
                    rebuildCustom()
                else
                    select(candidate)
                end
                return
            end
        end
        error("所选目标不在当前挑战名单")
    end
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
        { label = "玩家档位", value = playerRow.value, change = playerRow.change },
        { label = "首领轮回", value = function() return tostring(settings.enemyCycle) end,
            change = enemyRow.change },
        { label = "技能增幅", value = function()
                return ("+%d%% / +%d%%"):format(settings.skillLevel * 2, Profile.skillCap(settings.playerCycle) * 2)
            end,
            enabled = function() return Profile.skillCap(settings.playerCycle) > 0 end,
            change = function(delta)
                PlayerCustom.setSkill(settings, clamp(settings.skillLevel + delta, Profile.skillCap(settings.playerCycle)))
            end },
    }
    model.screenRows = {
        playerRow,
        model.rows[5],
        { label = "类型", value = model.rows[1].value, change = model.rows[1].change },
        { label = "目标", value = model.rows[2].value, change = model.rows[2].change },
        enemyRow,
        difficultyRow,
        { label = "场景", value = function() return Menus.sceneLabel(settings) end,
            change = function(delta)
                local scenes = Menus.sceneChoices(mode, settings.encounterId)
                local selected = 0
                for index, scene in ipairs(scenes) do if scene.id == settings.sceneChoice then selected = index end end
                local nextScene = scenes[(selected + delta) % (#scenes + 1)]
                model:chooseScene(nextScene and nextScene.id or "default")
            end },
        { label = "战斗音乐", value = function() return Music.label(settings.musicId) end,
            change = function(delta)
                settings.musicId = Music.step(settings.musicId, delta)
            end },
    }
    model.screenRows[9] = {
        label = "数量", value = function() return model:isCustom() and tostring(model:customCount()) .. " / 5" or "-" end,
        enabled = function() return model:isCustom() end,
        change = function(delta)
            local draft = customDraft(); if not draft then return end
            draft.count = math.max(1, math.min(Custom.maximum, draft.count + delta))
            for index = 1, draft.count do draft.members[index] = draft.members[index] or Custom.choices()[1].id end
            rebuildCustom()
        end,
    }
    for slot = 1, Custom.maximum do
        local index = slot
        model.screenRows[9 + index] = {
            label = "位置 " .. index,
            value = function()
                local draft = customDraft()
                if not draft or index > draft.count then return "-" end
                return assert(Catalog.resolve(draft.members[index])).name
            end,
            enabled = function() return model:isCustom() and index <= model:customCount() end,
            change = function(delta)
                local draft = customDraft(); if not draft or index > draft.count then return end
                local choices, selected = Custom.choices(), 1
                for candidate, entry in ipairs(choices) do if entry.id == draft.members[index] then selected = candidate; break end end
                draft.members[index] = choices[(selected - 1 + delta) % #choices + 1].id
                rebuildCustom()
            end,
        }
    end
    if Pressure.available() then require("PressureControls").add(model, state.customPressure) end
    return model
end
function Model:isCustom()
    return self.settings.mode ~= "training" and Custom.isCategory(self.settings.category)
end
function Model:chooseScene(id)
    local settings = self.settings
    assert(id == "default" or Scenes.available(id, settings.mode), "此场景暂不可用")
    local encounter = settings.mode ~= "training" and Catalog.resolve(settings.encounterId) or nil
    local scene, choice = Menus.resolveScene(encounter, id, settings.mode)
    assert(id == "default" or choice ~= "default", "当前挑战无法手动选择此场景")
    settings.sceneId, settings.sceneChoice = scene, choice
end
function Model:chooseMusic(id)
    assert(Music.normalize(id) == id, "此曲目暂不可用")
    self.settings.musicId = id
end
function Model:getSettings()
    local settings = self.settings
    return { bossId = settings.bossId, encounterId = settings.encounterId, category = settings.category,
        trainingMobId = settings.trainingMobId,
        playerCycle = settings.playerCycle, enemyCycle = settings.enemyCycle, skillLevel = settings.skillLevel,
        difficultyMode = settings.difficultyMode, customPressure = Difficulty.copyPressure(settings.customPressure),
        mode = settings.mode, sceneId = settings.sceneId, sceneChoice = settings.sceneChoice, musicId = settings.musicId,
        customPlayer = PlayerCustom.copy(settings.customPlayer, settings.playerCycle),
        customProfiles = PlayerCustom.copyProfiles(settings.customProfiles) }
end
function Model:mount(modal, description, controller, confirm, options)
    self:close()
    self.form = require("NativeSelection").open(self, modal, description, controller, confirm, options)
    return self
end
function Model:update(gameplay) return self.form and self.form:update(gameplay) or false end
function Model:canConfirm() return self.form and self.form:canConfirm() or false end
function Model:confirm()
    if not self.form or not self.form:confirm() then return false end
    return self:commit()
end
function Model:commit()
    if self:isCustom() then
        local ok, reason = Custom.remember(self.settings.bossId)
        if not ok then
            print("[PBZCustomChallenges] " .. tostring(reason) .. "\n")
            -- Keep the editor open so a failed save is visible and retryable.
            if self.form and self.form.form then self.form.form:refresh() end
            return false, reason
        end
        print("[PBZCustomChallenges] selected " .. self.settings.bossId .. "\n")
    end
    return true
end
function Model:back()
    local handled = self.form and self.form:back() or false
    if handled then self.region = self.form.form.region end
    return handled
end
function Model:takeAction() local action = self.pendingAction; self.pendingAction = nil; return action end
function Model:close() if self.form then self.form:close(); self.form = nil end end

return Target
