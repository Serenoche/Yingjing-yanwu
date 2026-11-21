local StageScreen = require("StageScreen")
local Timer = require("DreamPalaceTimer")
local Progress = require("BloodyPalaceProgress")
local Art = require("ArtAssets")
local Assets = require("CombatSpawn")
local Hud = {}

local directory = assert(debug.getinfo(1, "S").source:match("^@(.+)[/\\][^/\\]+$"))
local width, height = 1920, 1080
local visible, collapsed = 3, 1
local paper = { R = 1, G = .92, B = .79, A = 1 }
local ink = { R = .023, G = .017, B = .011, A = 1 }
local gold = { R = 1, G = .79, B = .45, A = 1 }
local red = { R = 1, G = .34, B = .29, A = 1 }
local shadow = { R = 0, G = 0, B = 0, A = 1 }
local fonts = {
    number = "PB3",
    heading = "ZH_ZiKuTangKuangShanKaiShuJF_Font",
    body = "ZH_FZKaiTi_Font",
}

local ART = {
    floor = { "/Game/PBZContent/VFX/SceneFX/UI/Common/Assets/T_PromptBar_Simple_Total", 1024, 128, 80, 5, 862, 116 },
    amount = { "/Game/PBZContent/UI/UINew/System/Character/Texture/T_Shop_Number_InkBar", 128, 64, 6, 5, 121, 46 },
    cleanAmount = { "/Game/PBZContent/UI/UINew/System/Character/Texture/T_Shop_Number_InkBarYellow", 128, 64, 5, 3, 123, 48 },
    caption = { "/Game/PBZContent/UI/InGame/SaveLoad/T_Save_InkBar_Selected", 2840, 284, 1, 0, 2807, 284 },
    cleanCaption = { "/Game/PBZContent/UI/Texture/PauseMenu/T_Mission_Inkbar_Default", 1105, 141, 0, 0, 1102, 141 },
    title = { "/Game/PBZContent/UI/InGame/Quest/T_Mission_Selected_InkBar", 2048, 512, 16, 20, 2016, 477 },
}
local current, gradient, nextMount, lastError

local function valid(value) return value and type(value.IsValid) == "function" and value:IsValid() end
local function checked(value, message) assert(valid(value), message); return value end
local function same(a, b) return valid(a) and valid(b) and a:GetAddress() == b:GetAddress() end

local function make(kind, outer)
    local class = checked(StaticFindObject("/Script/UMG." .. kind), "HUD 控件类型不可用 " .. kind)
    local widget = checked(StaticConstructObject(class, outer), "HUD 控件创建失败 " .. kind)
    widget:SetVisibility(visible)
    return widget
end

local function place(parent, widget, x, y, w, h, horizontal, vertical)
    local slot = checked(parent:AddChildToCanvas(widget), "无法挂载浊梦 HUD 控件")
    slot:SetPosition({ X = x, Y = y })
    slot:SetAlignment({ X = horizontal or 0, Y = vertical or 0 })
    if w then slot:SetSize({ X = w, Y = h }) else slot:SetAutoSize(true) end
end

local function text(parent, x, y, anchor, fontName, size, color, value)
    local widget = make("TextBlock", parent)
    local face = fonts[fontName]
    local font = widget.Font
    font.FontObject = Assets.class("/Game/PBZContent/UI/Fonts/" .. face .. "." .. face)
    font.Size = size
    font.TypefaceFontName = FName(fontName == "number" and "Font" or "Default")
    widget:SetFont(font)
    widget:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 })
    widget:SetShadowOffset({ X = 1, Y = 2 })
    widget:SetShadowColorAndOpacity(color == ink and { R = 1, G = .95, B = .82, A = .32 } or shadow)
    if value then widget:SetText(FText(value)) end
    place(parent, widget, x, y, nil, nil, anchor, .5)
    return widget
end

local function picture(parent, texture, x, y, w, h)
    local image = make("Image", parent)
    image:SetBrushFromTexture(texture, false)
    place(parent, image, x, y, w, h)
    return image
end

local function nativeArt(parent, brush, x, y, w, h)
    local path, tw, th, bx, by, bw, bh = table.unpack(ART[brush])
    local texture = Art.texture(parent, path .. "." .. path:match("([^/]+)$"))
    local sx, sy = w / bw, h / bh
    return picture(parent, checked(texture, "浊梦 HUD 原版底图未加载 " .. brush),
        x - bx * sx, y - by * sy, tw * sx, th * sy)
end

local function line(parent, x, y, w)
    local border = make("Border", parent)
    border:SetBrushColor({ R = .66, G = .5, B = .3, A = .32 })
    place(parent, border, x, y, w, 1)
end

local function rewardGroup(canvas, clean)
    local group = make("CanvasPanel", canvas)
    place(canvas, group, 109, 230, 235, 89)
    nativeArt(group, clean and "cleanAmount" or "amount", 0, 0, 235, 49)
    local captionBackground = nativeArt(group, clean and "cleanCaption" or "caption", 2, 54, 206, 35)
    group:SetVisibility(collapsed)
    return { widget = group, amount = text(group, 23, 26, 0, "number", 36, clean and ink or paper),
        caption = text(group, 23, 71, 0, "body", 24, clean and paper or ink),
        captionBackground = captionBackground }
end

function Hud.mountFloorResult(canvas, withConfirm)
    if not valid(gradient) then
        local render = checked(StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary"), "HUD 图像接口不可用")
        gradient = checked(render:ImportFileAsTexture2D(canvas, directory .. "/DreamPalaceResultFade.png"),
            "HUD 渐变图读取失败")
    end
    local result = make("CanvasPanel", canvas)
    local height = withConfirm and 416 or 376
    place(canvas, result, 1024, 295, 896, height)
    picture(result, gradient, 0, 0, 896, height)
    nativeArt(result, "title", 196, 18, 700, 73)
    local title = text(result, 264, 56, 0, "heading", 53, ink)
    line(result, 264, 100, 565)
    text(result, 264, 143, 0, "body", 34, paper, "本层奖励时间")
    text(result, 264, 196, 0, "body", 34, paper, "本层耗时")
    local reward = text(result, 829, 143, 1, "number", 42, paper)
    local spent = text(result, 829, 196, 1, "number", 42, paper)
    line(result, 196, 235, 633)
    text(result, 196, 276, 0, "body", 40, paper, "本层时间")
    local total = text(result, 829, 276, 1, "number", 68, gold)
    return { widget = result, title = title, reward = reward, spent = spent, total = total }
end

function Hud.setFloorResult(view, result)
    view.title:SetText(FText("通关" .. Timer.floorLabel(Progress.sourceFloor(result.floor))))
    view.reward:SetText(FText(Timer.format(result.reward, false)))
    view.spent:SetText(FText(Timer.format(result.spent, false)))
    view.total:SetText(FText(Timer.format(result.reward - result.spent, false, true)))
end

local function mount(view, root, kind)
    local scale = make("ScaleBox", root)
    view.rootWidget = scale
    local box = make("SizeBox", scale)
    box:SetWidthOverride(width)
    box:SetHeightOverride(height)
    scale:SetStretch(2) -- ScaleToFit, using a 1920 × 1080 design area.
    scale:SetContent(box)
    local canvas = make("CanvasPanel", box)
    box:SetContent(canvas)
    canvas:SetClipping(1)

    local floor = make("CanvasPanel", canvas)
    place(canvas, floor, 99, 683, 303, 62)
    nativeArt(floor, "floor", 0, 0, 303, 62)
    view.floor = text(floor, 33, 31, 0, "heading", 40, paper)
    view.clock = text(canvas, 132, 202, 0, "number", 60, paper)
    view.rewards = { rewardGroup(canvas, false), rewardGroup(canvas, true) }

    view.result = Hud.mountFloorResult(canvas)
    view.result.widget:SetVisibility(collapsed)

    if kind == "CanvasPanel" then
        local slot = checked(root:AddChildToCanvas(scale), "无法挂载战斗 HUD")
        slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 1, Y = 1 } })
        slot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        slot:SetZOrder(1000) -- StageScreen attaches above this canvas.
    else
        local slot = checked(root:AddChildToOverlay(scale), "无法挂载战斗 HUD")
        slot:SetHorizontalAlignment(0)
        slot:SetVerticalAlignment(0)
    end
end

local function ease(value)
    local t = math.min(1, math.max(0, value))
    return 1 - (1 - t)^3
end

local function pose(widget, alpha, x)
    widget:SetRenderOpacity(alpha)
    widget:SetRenderTranslation({ X = x, Y = 0 })
end

function Hud.advanceFloorResult(view, elapsed, fromRight)
    local arrival = ease(elapsed / .32)
    pose(view.widget, arrival, (fromRight and 138 or -138) * (1 - arrival))
    return arrival == 1
end

local function refresh(view, snapshot, now)
    if view.lastFloor ~= snapshot.floor then
        view.floor:SetText(FText(Timer.floorLabel(Progress.sourceFloor(snapshot.floor))))
        view.lastFloor = snapshot.floor
    end
    local remaining = Timer.format(snapshot.remaining, true)
    if view.clockText ~= remaining then
        view.clock:SetText(FText(remaining))
        view.clockText = remaining
    end
    local overtime = snapshot.remaining < 0
    if view.overtime ~= overtime then
        view.clock:SetColorAndOpacity({ SpecifiedColor = overtime and red or paper, ColorUseRule = 0 })
        view.overtime = overtime
    end
    local result = snapshot.result
    if view.lastResult ~= result then
        view.lastResult, view.resultArrived = result, nil
        view.result.widget:SetVisibility(result and visible or collapsed)
        if result then Hud.setFloorResult(view.result, result) end
    end
    if result then
        if not view.resultArrived then view.resultArrived = Hud.advanceFloorResult(view.result, now - result.at) end
    end
    local reward, alpha, x = Timer.visibleReward(snapshot.rewards, now)
    local group = reward and view.rewards[reward.kind == "clean" and 2 or 1]
    if view.rewardGroup ~= group then
        if view.rewardGroup then view.rewardGroup.widget:SetVisibility(collapsed) end
        if group then group.widget:SetVisibility(visible) end
        view.rewardGroup = group
    end
    if group then
        if view.lastReward ~= reward then
            group.amount:SetText(FText((Timer.format(reward.amount, true, true):gsub("^%+00:", "+"))))
            local label = Timer.rewardLabels[reward.kind]
            if label then group.caption:SetText(FText(label)) end
            group.caption:SetVisibility(label and visible or collapsed)
            group.captionBackground:SetVisibility(label and visible or collapsed)
        end
        pose(group.widget, alpha, x)
    end
    view.lastReward = reward
end

function Hud.close()
    if current and valid(current.rootWidget) then current.rootWidget:RemoveFromParent() end
    current, nextMount, lastError = nil, nil, nil
end

function Hud.update(controller, snapshot, now)
    if not snapshot then
        if current and not current.hidden then
            current.rootWidget:SetVisibility(collapsed)
            current.hidden = true
        end
        return false
    end
    if now < (nextMount or 0) then return false end
    local ok, shown = pcall(function()
        local view = current
        if view and (not same(view.controller, controller) or not valid(view.rootWidget)) then Hud.close(); view = nil end
        if view and now >= (view.nextValidate or 0) then
            local layout, root = StageScreen.gameLayout(controller)
            if not same(view.layout, layout) or not same(view.root, root)
                or not same(view.rootWidget:GetParent(), root) then Hud.close(); view = nil end
        end
        if not view then
            -- An Overlay appends children. Wait for any already-mounted transition
            -- mask to leave so subsequent fades will always sit above the HUD.
            if snapshot.fading then return false end
            local layout, root, kind = StageScreen.gameLayout(controller)
            view = { controller = controller, layout = layout, root = root }
            current = view
            mount(view, root, kind)
        end
        if now >= (view.nextValidate or 0) then
            view.nextValidate = now + .25
            view.modal = view.layout:HasModal()
                or view.layout:HasWidgetAboveLayer({ TagName = FName("UI.Layer.Game") }, true)
        end
        local hidden = snapshot.covered or view.modal
        if view.hidden ~= hidden then
            view.rootWidget:SetVisibility(hidden and collapsed or visible)
            view.hidden = hidden
        end
        if not hidden then refresh(view, snapshot, now) end
        return not hidden
    end)
    if not ok then
        local previous = lastError
        pcall(Hud.close)
        lastError, nextMount = tostring(shown), now + 1
        if lastError ~= previous then print("[PBZDreamPalaceUI] Combat HUD waiting: " .. lastError .. "\n") end
        return false
    end
    return shown
end

return Hud
