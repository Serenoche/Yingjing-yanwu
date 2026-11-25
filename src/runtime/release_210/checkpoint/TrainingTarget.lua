local Target = {}
local dummy = require("TrainingDummy").target
local mobs = require("TrainingMobCatalog")
local catalog = { dummy, table.unpack(mobs) }

local byId, families = {}, {}
local seenFamilies = {}
for _, mob in ipairs(catalog) do
    byId[mob.id] = mob
    if not seenFamilies[mob.family] then
        families[#families + 1] = mob.family
        seenFamilies[mob.family] = true
    end
end
table.sort(families)
table.insert(families, 1, "全部")

local rankLabels = { "全部", "普通怪", "精英怪", "木桩" }
local ranks = { "all", "ordinary", "elite", "dummy" }
local roles = { "全部", "近战", "远程", "前排", "长柄", "重型", "兽类",
    "投掷", "飞行", "召唤", "控场", "机制型", "异常", dummy.role }
local groupedRoles = {
    ["近战"] = { ["前排"] = true, ["长柄"] = true, ["重型"] = true, ["兽类"] = true },
    ["远程"] = { ["投掷"] = true },
}
local legacy = { id = "gold-mask", name = "金面人" }

function Target.resolve(id)
    return byId[id]
end

function Target.option(id)
    return byId[id] or legacy
end

function Target.summary(mob)
    if mob == legacy then return end
    if mob == dummy then return "固定靶 · 锁血 · 伤害统计" end
    return table.concat({ mob.rank == "elite" and rankLabels[3] or rankLabels[2], mob.role, mob.family }, " · ")
end

function Target.filters()
    local index = { rank = 1, role = 1, family = 1 }
    local function row(key, label, labels)
        return { label = label, value = function() return labels[index[key]] end,
            change = function(delta) index[key] = (index[key] - 1 + delta) % #labels + 1 end }
    end

    local filters = { rows = { row("rank", "强度", rankLabels), row("role", "战斗定位", roles),
        row("family", "家族", families) } }
    function filters:choices()
        local choices = {}
        if index.rank == 1 and index.role == 1 and index.family == 1 then choices[1] = legacy end
        local rank, role, family = ranks[index.rank], roles[index.role], families[index.family]
        local group = groupedRoles[role]
        for _, mob in ipairs(catalog) do
            if (index.rank == 1 or mob.rank == rank)
                and (index.role == 1 or mob.role == role or (group and group[mob.role]))
                and (index.family == 1 or mob.family == family) then
                choices[#choices + 1] = mob
            end
        end
        return choices
    end
    return filters
end

return Target
