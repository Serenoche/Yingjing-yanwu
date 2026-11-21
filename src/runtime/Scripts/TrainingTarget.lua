local Target = {}
local catalog = require("TrainingMobCatalog")

local byId, families, seenFamilies = {}, {}, {}
for _, mob in ipairs(catalog) do
    byId[mob.id] = mob
    if not seenFamilies[mob.family] then
        families[#families + 1] = mob.family
        seenFamilies[mob.family] = true
    end
end
table.sort(families)
table.insert(families, 1, "全部")

local rankLabels = { "全部", "普通怪", "精英怪" }
local ranks = { "all", "ordinary", "elite" }
local roles = { "全部", "近战", "远程", "前排", "长柄", "重型", "兽类",
    "投掷", "飞行", "召唤", "控场", "机制型", "异常" }
local melee = { ["近战"] = true, ["前排"] = true, ["长柄"] = true, ["重型"] = true, ["兽类"] = true }
local ranged = { ["远程"] = true, ["投掷"] = true }
local legacy = { name = "金面人" }

function Target.resolve(id)
    return byId[id]
end

local function step(index, delta, count)
    return (index - 1 + delta) % count + 1
end

function Target.form(settings)
    local choices, selected = {}, 1
    local rank, role, family = 1, 1, 1

    local function select(index)
        selected = index
        local mob = choices[selected]
        settings.trainingMobId = mob and mob.id
    end

    local function filter()
        local previous = settings.trainingMobId
        choices = {}
        if rank == 1 and role == 1 and family == 1 then choices[1] = legacy end
        local wantedRole, wantedFamily = roles[role], families[family]
        local group = wantedRole == "近战" and melee or wantedRole == "远程" and ranged
        local preferred = 1
        for _, mob in ipairs(catalog) do
            if (rank == 1 or mob.rank == ranks[rank])
                and (role == 1 or mob.role == wantedRole or (group and group[mob.role]))
                and (family == 1 or mob.family == wantedFamily) then
                choices[#choices + 1] = mob
                if mob.id == previous then preferred = #choices end
            end
        end
        select(preferred)
    end

    filter()
    return {
        rows = {
            { label = "强度", value = function() return rankLabels[rank] end,
                change = function(delta) rank = step(rank, delta, #ranks); filter() end },
            { label = "战斗定位", value = function() return roles[role] end,
                change = function(delta) role = step(role, delta, #roles); filter() end },
            { label = "家族", value = function() return families[family] end,
                change = function(delta) family = step(family, delta, #families); filter() end },
            { label = "目标", value = function() return choices[selected] and choices[selected].name or "无匹配对象" end,
                enabled = function() return #choices > 1 end,
                change = function(delta)
                    if #choices > 1 then select(step(selected, delta, #choices)) end
                end },
        },
        available = function() return #choices > 0 end,
        position = function()
            local mob = choices[selected]
            if not mob or mob == legacy then return "" end
            local offset = choices[1] == legacy and 1 or 0
            return ("%d / %d　·　%s"):format(selected - offset, #choices - offset, mob.role)
        end,
    }
end

return Target
