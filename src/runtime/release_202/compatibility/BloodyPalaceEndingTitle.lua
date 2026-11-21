local StageScreen = require("StageScreen")

local Title = {}
local CLEAR = { R = 0, G = 0, B = 0, A = 0 }
local FILE = "BloodyPalaceEndingTitle.png"
local ANGLE = -12
local INK_EDGE = {
    { -15, -2, .91 }, { -11, -10, .90 }, { -1, -13, .87 }, { 10, -10, .92 },
    { 14, -3, .88 }, { 16, 5, .94 }, { 10, 13, .95 }, { 1, 15, .95 }, { -10, 10, .93 },
}

local function checked(object, message)
    assert(object and type(object.IsValid) == "function" and object:IsValid(), message)
    return object
end

local function report(message)
    print("[PBZBloodyPalace] ending title " .. message .. "\n")
end

local function loadTexture(pawn)
    local source = debug.getinfo(1, "S").source
    local directory = assert(source:match("^@(.*)[/\\][^/\\]+$"), "血宫结算贴图目录不可用")
    local renderer = checked(StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary"), "缺少贴图导入接口")
    local texture = checked(renderer:ImportFileAsTexture2D(pawn, directory .. "/" .. FILE), "血宫结算贴图不可用")
    local width, height = texture:Blueprint_GetSizeX(), texture:Blueprint_GetSizeY()
    assert(width == 2172 and height == 724, "血宫结算贴图尺寸有误")
    return texture, width, height
end

local function widget(kind, outer)
    local class = checked(StaticFindObject("/Script/UMG." .. kind), "缺少血宫结算标题控件类型 " .. kind)
    local value = checked(StaticConstructObject(class, outer), "无法创建血宫结算标题控件 " .. kind)
    value:SetVisibility(3)
    return value
end

local function compose(border, texture, width, height)
    local canvas = widget("CanvasPanel", border)
    border:SetContent(canvas)
    local fit = widget("ScaleBox", canvas)
    local slot = canvas:AddChildToCanvas(fit)
    slot:SetAnchors({ Minimum = { X = .22, Y = .554 }, Maximum = { X = .78, Y = .986 } })
    slot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
    fit:SetStretch(2) -- ScaleToFit, including on ultrawide viewports.
    local frame = widget("SizeBox", fit)
    fit:SetContent(frame)
    local radians = math.rad(math.abs(ANGLE))
    local frameWidth = width * math.cos(radians) + height * math.sin(radians) + 36
    local frameHeight = height * math.cos(radians) + width * math.sin(radians) + 36
    frame:SetWidthOverride(frameWidth)
    frame:SetHeightOverride(frameHeight)

    local brush = widget("CanvasPanel", frame)
    frame:SetContent(brush)
    brush:SetRenderTransformPivot({ X = .5, Y = .5 })
    brush:SetRenderTransformAngle(ANGLE)
    brush:SetRenderTranslation({ X = -33, Y = -49 }) -- center the visible strokes within the transparent PNG
    local function layer(x, y, z, opacity)
        local image = widget("Image", brush)
        image:SetBrushFromTexture(texture, true)
        if opacity then image:SetColorAndOpacity({ R = 0, G = 0, B = 0, A = opacity }) end
        local placement = brush:AddChildToCanvas(image)
        placement:SetPosition({ X = (frameWidth - width) / 2 + x, Y = (frameHeight - height) / 2 + y })
        placement:SetSize({ X = width, Y = height })
        placement:SetZOrder(z)
    end
    -- Offset copies of the dry-brush silhouette form the black ink edge.
    for _, edge in ipairs(INK_EDGE) do layer(edge[1], edge[2], 0, edge[3]) end
    layer(0, 0, 1)
end

function Title.close(screen)
    if not screen then return true end
    local ok, reason = pcall(screen.close, screen)
    if not ok then report("cleanup fallback: " .. tostring(reason)) end
    return ok
end

function Title.new(gameplay, pawn, worldOf)
    local screen
    local ok, reason = pcall(function()
        local texture, width, height = loadTexture(pawn)
        screen = StageScreen.new(gameplay, pawn, CLEAR, worldOf)
        compose(screen.border, texture, width, height)
        report(("loaded; width=%d; height=%d; angle=%d"):format(width, height, ANGLE))
    end)
    if ok then return screen end
    report("setup fallback: " .. tostring(reason))
    Title.close(screen)
    return nil
end

function Title.show(screen)
    if not screen then return false end
    local ok, reason = pcall(screen.setAlpha, screen, 1)
    if not ok then report("display fallback: " .. tostring(reason)) end
    return ok
end

return Title
