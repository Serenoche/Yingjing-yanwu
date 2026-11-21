local Progress = require("BloodyPalaceProgress")
local Art = require("ArtAssets")
local Portraits = require("DreamPalaceWarmupPortraits")
local Warmup = {}

function Warmup.members(floor)
    local entry = Progress.floor(floor)
    local full, portraits = {}, {}
    for _, stage in ipairs(entry.stages) do
        for _, unit in ipairs(stage.members) do
            local art = Portraits[unit.id]
            local group = (not unit.regularMob or art and art.full) and full or portraits
            group[#group + 1] = { id = unit.id, name = unit.name, art = art }
        end
    end
    return full, portraits
end

local function drawGroup(screen, layer, items, top, width, height, full)
    if #items == 0 then return end
    local columns = math.min(#items, full and 3 or 5)
    local rows = math.ceil(#items / columns)
    local cellWidth = math.min(width / columns, full and 676 or 225)
    local cellHeight = height / rows
    local nameHeight = full and 74 or 58
    for index, member in ipairs(items) do
        local row = math.floor((index - 1) / columns)
        local inRow = math.min(columns, #items - row * columns)
        local x = (width - inRow * cellWidth) / 2 + ((index - 1) % columns) * cellWidth
        local y = top + row * cellHeight
        local title = screen:text(member.name, x + 7, y, cellWidth - 14, nameHeight, full, layer, full and 34 or 24)
        title:SetJustification(1)
        title:SetAutoWrapText(true)

        local texture, meta
        if member.art then
            texture, meta = Art.texture(screen.modal, member.art.path, { box = member.art.box })
        elseif full then
            texture, meta = Art.bossMember(screen.modal, member.id, "full")
        end
        if texture then
            local artWidth, artHeight = cellWidth - 20, cellHeight - nameHeight - 8
            if full then
                screen:image(texture, meta, x + 10, y + nameHeight, artWidth, artHeight, layer)
            else
                local side = math.min(artWidth, artHeight)
                screen:image(texture, meta, x + (cellWidth - side) / 2, y + nameHeight, side, side, layer, true)
            end
        end
    end
end

function Warmup.draw(screen, page, floor)
    local full, portraits = Warmup.members(floor)
    local layer = screen:make("CanvasPanel")
    layer:SetVisibility(3)
    local width, height = 1140, 762
    screen:place(layer, 660, 166, width, height, page)
    if #full > 0 then
        local fullHeight = #portraits > 0 and 508 or height
        drawGroup(screen, layer, full, 0, width, fullHeight, true)
        drawGroup(screen, layer, portraits, fullHeight + 18, width, height - fullHeight - 18, false)
    else
        drawGroup(screen, layer, portraits, 232, width, 270, false)
    end
    return layer
end

return Warmup
