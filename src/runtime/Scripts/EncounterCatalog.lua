-- Encounter definitions own ordering; BossCatalog remains the cooked actor source.
local Bosses = require("BossCatalog")
local Data = require("GeneratedEncounterCatalog")
local Catalog = { categories = {} }
local byId, ordered, categoryNames, exclusions = {}, {}, {}, {}
local RETIRED = { gauntlet_lengtu = "gauntlet", BP_Monster_LengTu = "duel", group_mob_rioters = "group" }

assert(Data.schemaVersion == 1, "不支持的挑战目录版本")
for _, category in ipairs(Data.categories) do
    assert(type(category.id) == "string" and type(category.name) == "string" and not categoryNames[category.id],
        "挑战分类数据无效")
    Catalog.categories[#Catalog.categories + 1] = { id = category.id, name = category.name }
    categoryNames[category.id] = category.name
end
for _, exclusion in ipairs(Data.duelExclusions or {}) do exclusions[exclusion.bossId] = exclusion.reason end

local function stagesOf(source)
    local stages = {}
    for _, stage in ipairs(source or {}) do
        local members = {}
        for _, id in ipairs(stage.members) do
            members[#members + 1] = assert(Bosses[id], "挑战成员不在原生首领目录：" .. tostring(id))
        end
        assert(#members > 0, "挑战阶段没有成员")
        stages[#stages + 1] = { members = members }
    end
    return stages
end

for _, source in ipairs(Data.entries) do
    assert(type(source.id) == "string" and not byId[source.id] and categoryNames[source.category], "挑战目录条目无效")
    -- Explicitly withdrawn entries retain their definition for restoration,
    -- while every stored selection can recover within its original category.
    -- A pending adapter is unavailable, but is not a retired selection.
    if source.enabled == false and source.status == "disabled" then RETIRED[source.id] = source.category end
    local entry = {
        id = source.id, name = source.name, category = source.category, categoryName = categoryNames[source.category],
        enabled = source.enabled, selectable = source.enabled and source.status == "ready" and not RETIRED[source.id],
        status = source.status, notes = source.notes, order = source.order, stages = stagesOf(source.stages),
        adapter = source.adapter, authoredPhaseCount = source.authoredPhaseCount,
        summonWaveCount = source.summonWaveCount, portraitMembers = {},
    }
    for _, id in ipairs(source.portraitMembers or {}) do
        entry.portraitMembers[#entry.portraitMembers + 1] = Bosses[id] or { id = id, name = id }
    end
    if entry.selectable then assert(#entry.stages > 0, "已开放挑战缺少阶段：" .. entry.id) end
    if source.category == "duel" and #entry.stages == 1 and #entry.stages[1].members == 1 then
        local boss = entry.stages[1].members[1]
        entry.classPath, entry.capsuleHalfHeight, entry.capsuleRadius = boss.classPath, boss.capsuleHalfHeight, boss.capsuleRadius
    end
    byId[entry.id], ordered[#ordered + 1] = entry, entry
end

function Catalog.resolve(id)
    if type(id) ~= "string" then return nil, "挑战对象 ID 无效" end
    if RETIRED[id] then return nil, (byId[id] and byId[id].notes) or "此挑战已撤下" end
    local entry = byId[id]
    if entry then
        if not entry.selectable then return nil, entry.notes or ("此挑战暂未开放：" .. entry.name) end
        return entry
    end
    local boss = Bosses[id]
    if not boss then return nil, "找不到挑战对象：" .. id end
    -- Keep older stored boss IDs readable/playable; removed duel choices are
    -- never silently reintroduced into the current selection list.
    return {
        id = boss.id, name = boss.name, category = "duel", categoryName = categoryNames.duel,
        enabled = false, selectable = false, status = "legacy", legacy = true,
        notes = exclusions[id] or "仅兼容旧挑战配置，不再作为新挑战选项",
        order = boss.order, classPath = boss.classPath,
        capsuleHalfHeight = boss.capsuleHalfHeight, capsuleRadius = boss.capsuleRadius,
        stages = { { members = { boss } } },
    }
end

function Catalog.isRetired(id) return RETIRED[id] ~= nil end
-- Old stored settings can omit/misstate their category. Keep a withdrawn
-- combination in its own selectable category without reviving that entry.
function Catalog.retiredCategory(id) return RETIRED[id] end

function Catalog.list(category)
    if category ~= nil and not categoryNames[category] then return {}, "未知挑战分类：" .. tostring(category) end
    local result = {}
    for _, entry in ipairs(ordered) do
        if entry.selectable and (category == nil or entry.category == category) then result[#result + 1] = entry end
    end
    return result
end

return Catalog
