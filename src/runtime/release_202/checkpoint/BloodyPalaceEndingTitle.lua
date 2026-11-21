local StageScreen = require("StageScreen")

local Title = {}
local CLEAR = { R = 0, G = 0, B = 0, A = 0 }
local FILE = "BloodyPalaceEndingTitle.png"
local ANGLE, DROP, SETTLE = -12, .27, .24
-- Visible ink bounds at the resting angle, measured from the texture center.
local INK_WIDTH, INK_HEIGHT, INK_CENTER_X, INK_CENTER_Y = 2036, 919, 33, 49
local EDGE_PADDING = 28

local function valid(object) return object and type(object.IsValid) == "function" and object:IsValid() end

local function checked(object, message)
    assert(valid(object), message)
    return object
end

local function report(message)
    print("[PBZBloodyPalace] ending title " .. message .. "\n")
end

local function loadTexture(context)
    local source = debug.getinfo(1, "S").source
    local directory = assert(source:match("^@(.*)[/\\][^/\\]+$"), "血宫结算贴图目录不可用")
    local renderer = checked(StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary"), "缺少贴图导入接口")
    local texture = checked(renderer:ImportFileAsTexture2D(context, directory .. "/" .. FILE), "血宫结算贴图不可用")
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

local function compose(canvas, texture, width, height)
    local fit = widget("ScaleBox", canvas)
    fit:SetStretch(2) -- ScaleToFit, including on ultrawide viewports.
    local frame = widget("SizeBox", fit)
    fit:SetContent(frame)
    local frameWidth, frameHeight = INK_WIDTH + 2 * EDGE_PADDING, INK_HEIGHT + 2 * EDGE_PADDING
    frame:SetWidthOverride(frameWidth)
    frame:SetHeightOverride(frameHeight)

    local brush = widget("CanvasPanel", frame)
    frame:SetContent(brush)
    brush:SetRenderTransformPivot({ X = .5, Y = .5 })
    local image = widget("Image", brush)
    image:SetBrushFromTexture(texture, true)
    local placement = brush:AddChildToCanvas(image)
    placement:SetPosition({ X = (frameWidth - width) / 2, Y = (frameHeight - height) / 2 })
    placement:SetSize({ X = width, Y = height })
    return fit, brush
end

local function place(canvas, fit)
    local slot = checked(canvas:AddChildToCanvas(fit), "无法挂载血宫结算题字")
    slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 1, Y = 1 } })
    slot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
    return slot
end

local function render(brush, xScale, yScale, lift, tilt, opacity)
    brush:SetRenderTransform({ Translation = { X = -INK_CENTER_X, Y = -INK_CENTER_Y - lift },
        Scale = { X = xScale, Y = yScale }, Shear = { X = 0, Y = 0 }, Angle = ANGLE + tilt })
    brush:SetRenderOpacity(opacity)
end

local function present(brush, elapsed)
    if elapsed < DROP then
        local remaining = 1 - (math.max(0, elapsed) / DROP) ^ 2.6
        render(brush, 1 + 1.25 * remaining, 1 + 1.45 * remaining, 370 * remaining, -9 * remaining,
            math.min(1, .20 + elapsed / .055))
    else
        local t = math.min(1, (elapsed - DROP) / SETTLE)
        local compression = math.cos(t * math.pi * 1.5) * (1 - t)^2
        render(brush, 1 + .12 * compression, 1 - .20 * compression, -36 * compression, 0, 1)
    end
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
        local canvas = widget("CanvasPanel", screen.border)
        screen.border:SetContent(canvas)
        local fit, brush = compose(canvas, texture, width, height)
        place(canvas, fit)
        screen.brush = brush
        report(("loaded; width=%d; height=%d; angle=%d"):format(width, height, ANGLE))
    end)
    if ok then return screen end
    report("setup fallback: " .. tostring(reason))
    Title.close(screen)
    return nil
end

function Title.show(screen)
    local ok, reason = pcall(function()
        present(screen.brush, 0)
        screen:setAlpha(1)
    end)
    if not ok then
        report("display fallback: " .. tostring(reason))
        Title.close(screen)
    end
    return ok
end

function Title.placeBehindBlur(screen, root)
    if screen.closed or not valid(screen.border) then return end
    local function restore()
        if screen.closed or not valid(screen.border) then return end
        screen.border:RemoveFromParent()
        if valid(screen.root) then screen:mount(screen.root, screen.rootKind) end
    end
    local ok, reason = pcall(function()
        screen.border:RemoveFromParent()
        screen:mount(root, "Overlay")
    end)
    if not ok then
        pcall(restore)
        report("background blur fallback: " .. tostring(reason))
        return nil
    end
    return restore
end

function Title.advance(screen, elapsed)
    if screen.closed then return false, true end
    local ok, reason = pcall(present, screen.brush, elapsed)
    if not ok then
        report("motion fallback: " .. tostring(reason))
        Title.close(screen)
        return false, true
    end
    return elapsed >= DROP, elapsed >= DROP + SETTLE
end

return Title
