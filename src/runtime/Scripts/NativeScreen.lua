-- Full-screen artwork inside the already active native CommonUI modal. No
-- AddToViewport, input mode, focus owner, save or gameplay state is changed.
local Style = require("ParameterStyle")
local Feedback = require("ParameterFeedback")
local Screen, Instance = {}, {}
Instance.__index = Instance
local CLICK = "/Script/UMG.Widget:ForceLayoutPrepass"
local function unwrap(value)
    if value and type(value.IsValid) ~= "function" then
        local get = value.get or value.Get
        if type(get) == "function" then return get(value) end
    end
    return value
end
local function valid(value) return value and type(value.IsValid) == "function" and value:IsValid() end
local function checked(value, message) value = unwrap(value); assert(valid(value), message); return value end
local function same(a, b) return valid(a) and valid(b) and a:GetAddress() == b:GetAddress() end
function Instance:make(kind)
    local class = checked(StaticFindObject("/Script/UMG." .. kind), "缺少全屏 UMG 控件：" .. kind)
    local widget = checked(StaticConstructObject(class, self.tree), "无法创建全屏 UMG 控件：" .. kind)
    widget:SetVisibility(4)
    return widget
end
function Instance:place(widget, x, y, width, height, canvas)
    local slot = checked((canvas or self.canvas):AddChildToCanvas(widget), "无法挂载全屏菜单控件")
    slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } })
    slot:SetPosition({ X = x, Y = y }); slot:SetSize({ X = width, Y = height })
    slot:SetZOrder(20)
    return widget
end
function Instance:panel(x, y, width, height)
    return self:place(self:make("CanvasPanel"), x, y, width, height)
end
function Instance:text(value, x, y, width, height, heading, canvas, fontSize)
    local widget = Style.text(self.tree, value, heading, fontSize)
    self:place(widget, x, y, width, height, canvas)
    return widget
end
function Instance:textScaled(value, x, y, width, height, scale, heading, canvas)
    local widget = self:text(value, x, y, width, height, heading, canvas)
    -- Resize glyphs before Slate lays them out. The inherited UMG DPI and
    -- ScaleBox layout transform then rasterize at the actual window scale;
    -- a RenderScale would magnify the small glyph after text layout instead.
    Style.scaleText(widget, scale or 1)
    return widget
end
function Instance:shade(x, y, width, height, alpha, canvas)
    local border = self:make("Border")
    border:SetVisibility(3)
    border:SetBrushColor({ R = .015, G = .017, B = .019, A = alpha or 1 })
    self:place(border, x, y, width, height, canvas)
    border.Slot:SetZOrder(10)
    return border
end
function Instance:image(texture, meta, x, y, width, height, canvas, cover)
    local viewport = self:make("SizeBox")
    viewport:SetWidthOverride(width); viewport:SetHeightOverride(height)
    viewport:SetVisibility(3); viewport:SetClipping(1)
    self:place(viewport, x, y, width, height, canvas)
    viewport.Slot:SetZOrder(5)
    if not valid(texture) then return viewport end
    local image = self:make("Image")
    image:SetVisibility(3)
    image:SetBrushFromTexture(texture, true)
    local inner = self:make("CanvasPanel"); inner:SetVisibility(3)
    viewport:SetContent(inner)
    local tw, th = (meta and meta.width) or width, (meta and meta.height) or height
    local bounds = meta and meta.box or { 0, 0, 1, 1 }
    local bx, by, bw, bh = bounds[1] or bounds.x or 0, bounds[2] or bounds.y or 0,
        bounds[3] or bounds.w or 1, bounds[4] or bounds.h or 1
    bh = bh * ((meta and meta.cropFraction) or 1)
    local scale = (cover and math.max or math.min)(width / (tw * bw), height / (th * bh))
    local px, py = .5, .5
    if cover and meta and type(meta.position) == "string" then
        local sx, sy = meta.position:match("([%d.]+)%% ([%d.]+)%%")
        px, py = (tonumber(sx) or 50) / 100, (tonumber(sy) or 50) / 100
    end
    self:place(image, (width - tw * bw * scale) * px - tw * bx * scale,
        (height - th * bh * scale) * py - th * by * scale, tw * scale, th * scale, inner)
    return viewport
end
-- Full texture positioned by its calibrated subject, without a member viewport.
function Screen.portraitGeometry(meta, subject)
    local function finite(v)return type(v)=="number"and v==v and math.abs(v)<math.huge end
    assert(type(meta)=="table"and type(meta.box)=="table","画像缺少主体校准")
    local tw,th=meta.width or meta.measuredWidth,meta.height or meta.measuredHeight
    local box=meta.compositeBox or meta.box
    local bx,by,bw,bh=box[1]or box.x,box[2]or box.y,box[3]or box.w,box[4]or box.h
    assert(finite(tw)and finite(th)and tw>0 and th>0 and finite(bx)and finite(by)
        and finite(bw)and finite(bh)and bw>0 and bh>0,"画像主体校准尺寸无效")
    bh=bh*(meta.cropFraction or 1)
    assert(bh>0 and finite(subject.x)and finite(subject.y)and finite(subject.w)and finite(subject.h)
        and subject.w>0 and subject.h>0,"画像主体布局无效")
    local scale=math.min(subject.w/(tw*bw),subject.h/(th*bh))
    local width,height=tw*bw*scale,th*bh*scale
    local left,top=subject.x+(subject.w-width)*.5,subject.y+(subject.h-height)*.5
    return {x=left-tw*bx*scale,y=top-th*by*scale,w=tw*scale,h=th*scale,scale=scale,
        subject={x=left,y=top,w=width,h=height,anchorX=left+width*.5,anchorY=top+height*.5}}
end
function Instance:portrait(texture,meta,subject,canvas)
    assert(valid(texture)and valid(canvas),"画像素材或共同容器无效")
    local geometry=Screen.portraitGeometry(meta,subject)
    local image=self:make("Image")
    image:SetVisibility(3);image:SetClipping(0) -- Inherit: only the common panel clips.
    image:SetBrushFromTexture(texture,true)
    self:place(image,geometry.x,geometry.y,geometry.w,geometry.h,canvas)
    image.Slot:SetZOrder(subject.z or 1)
    return image,geometry
end
function Instance:button(label, x, y, width, height, callback, canvas)
    local button, caption = Style.button(self.modal, self.controller, self.tree, label)
    button:SetVisibility(0)
    self:place(button, x, y, width, height, canvas)
    local pulse = self:make("TextBlock")
    pulse:SetVisibility(1)
    self:place(pulse, 0, 0, 0, 0)
    button.OnButtonBaseClicked:Add(pulse, FName("ForceLayoutPrepass"))
    self.buttons[#self.buttons + 1] = { widget = button, caption = caption, pulse = pulse }
    self.actions[pulse:GetAddress()] = { callback = callback, button = button }
    Feedback.configureArrow(button)
    return button, caption
end
function Instance:placeholder()
    local box, label = self:make("SizeBox"), self:make("TextBlock")
    label:SetVisibility(1); box:SetContent(label)
    return label, box
end
function Instance:setFooter(enter, back, enterLabel)
    self.enterButton, self.enterCaption = self:button(enterLabel or "进入", 700, 950, 300, 70, enter)
    self.backButton = self:button("返回", 1030, 950, 210, 70, back)
end
function Instance:update()
    if self.closed then return false end
    if not valid(self.modal) or not self.modal:IsActivated()
        or not same(unwrap(self.modal:GetOwningPlayer()), self.controller) then return false end
    if not self.modal:HasUserFocus(self.controller) and not self.modal:HasUserFocusedDescendants(self.controller) then
        self.pending = {}; return true
    end
    local pending = self.pending; self.pending = {}
    for _, action in ipairs(pending) do
        if not self.closed then
            Feedback.click(self.modal, action.button)
            action.callback()
        end
    end
    if self.closed then return false end
    for index, item in ipairs(self.buttons) do
        local selected = self.selectedButton == index or item.widget:IsHovered()
        item.caption:OverrideTextColor({ SpecifiedColor = { R = 1, G = selected and .77 or .92,
            B = selected and .43 or .84, A = 1 }, ColorUseRule = 0 })
    end
    return true
end
function Instance:close()
    if self.closed then return end
    self.closed, self.pending = true, {}
    if self.hook then pcall(UnregisterHook, CLICK, self.hook[1], self.hook[2]); self.hook = nil end
    for _, button in ipairs(self.buttons or {}) do
        if valid(button.widget) then pcall(function() button.widget.OnButtonBaseClicked:Clear() end) end
    end
    for _, original in ipairs(self.originals or {}) do
        if valid(original.widget) then pcall(function()
            original.widget:SetRenderOpacity(original.opacity)
            original.widget:SetVisibility(original.visibility)
        end) end
    end
    if valid(self.root) then pcall(function() self.root:RemoveFromParent() end) end
end
function Screen.open(modal, controller, options)
    options = options or {}
    local self = setmetatable({ modal = checked(modal, "全屏原生弹窗无效"),
        controller = checked(controller, "全屏原生控制器无效"), originals = {}, buttons = {}, actions = {}, pending = {} }, Instance)
    local ok, failure = pcall(function()
        assert(modal:IsActivated() and same(unwrap(modal:GetOwningPlayer()), controller), "全屏弹窗未激活或属于其他玩家")
        self.tree = checked(modal.WidgetTree, "全屏弹窗没有控件树")
        self.nativeRoot = checked(self.tree.RootWidget, "全屏弹窗没有根 Overlay")
        -- Keep the original tree/pooled button group intact. Hit-test invisible
        -- removes its old mouse rectangles while the focused native Confirm
        -- still receives its CommonUI action and native Back still deactivates.
        for index = 0, self.nativeRoot:GetChildrenCount() - 1 do
            local child = checked(self.nativeRoot:GetChildAt(index), "原生弹窗子控件失效")
            self.originals[#self.originals + 1] = { widget = child,
                visibility = child:GetVisibility(), opacity = child:GetRenderOpacity() }
            child:SetVisibility(3); child:SetRenderOpacity(0)
        end
        self.root = self:make("ScaleBox"); self.root:SetStretch(2)
        local slot = checked(self.nativeRoot:AddChildToOverlay(self.root), "无法挂载全屏画布")
        slot:SetHorizontalAlignment(0); slot:SetVerticalAlignment(0)
        self.design = self:make("SizeBox")
        self.design:SetWidthOverride(1920); self.design:SetHeightOverride(1080)
        self.canvas = self:make("CanvasPanel")
        self.design:SetContent(self.canvas); self.root:SetContent(self.design)
        self:shade(0, 0, 1920, 1080, 1).Slot:SetZOrder(0)
        local Art = require("ArtAssets")
        local texture, meta = Art.background(modal)
        self:image(texture, meta, 0, 0, 1920, 1080, nil, true).Slot:SetZOrder(0)
        self:shade(0, 0, 1920, 1080, .67).Slot:SetZOrder(1)
        if options.title then
            self.title = self:textScaled(options.title, 100, 55, 600, 110, 2.6, true)
        end
        local pre, post = RegisterHook(CLICK, function(context)
            if self.closed or not valid(self.modal) or not self.modal:IsActivated() then return end
            local target = unwrap(context:get())
            local action = valid(target) and self.actions[target:GetAddress()] or nil
            if action then self.pending[#self.pending + 1] = action end
        end)
        self.hook = { pre, post }
    end)
    if not ok then self:close(); error(failure, 0) end
    return self
end
return Screen
