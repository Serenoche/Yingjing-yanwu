-- Passive black child of the already-owned game layout. No activatable widget,
-- viewport replacement, input binding, focus change or player-state mutation.
local StageScreen, Screen = {}, {}
Screen.__index = Screen
local LIBRARY = "/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary"
local CONTENT = { SafeZone = true, SizeBox = true, ScaleBox = true, Border = true }
local INVISIBLE_TO_INPUT, COLLAPSED = 3, 1

local function valid(object)
    return object ~= nil and type(object.IsValid) == "function" and object:IsValid()
end
local function unwrap(value)
    if value and type(value.IsValid) ~= "function" then
        local getter = value.get or value.Get
        if type(getter) == "function" then return getter(value) end
    end
    return value
end
local function checked(value, message)
    local result = unwrap(value)
    assert(valid(result), message)
    return result
end
local function same(first, second)
    return valid(first) and valid(second) and first:GetAddress() == second:GetAddress()
end
local function required(path)
    return checked(StaticFindObject(path), "缺少转场遮罩原生接口：" .. path)
end
local function rootOf(layout)
    local tree = checked(layout.WidgetTree, "转场布局没有控件树")
    local root = checked(tree.RootWidget, "转场布局没有根控件")
    local seen = {}
    for _ = 1, 8 do
        local class = checked(root:GetClass(), "转场根控件没有类型")
        local name = class:GetFName()
        name = type(name) == "string" and name or name:ToString()
        local address = root:GetAddress()
        assert(not seen[address], "转场布局根控件存在循环")
        seen[address] = true
        if name == "CanvasPanel" or name == "Overlay" then return root, name end
        assert(CONTENT[name], "不支持的转场布局根类型：" .. name)
        root = checked(root:GetContent(), "转场布局的单子控件为空")
    end
    error("转场布局根控件层数超过限制")
end

function Screen:close()
    if self.closed then return end
    if valid(self.border) then
        local reset, resetError = pcall(self.border.SetRenderOpacity, self.border, 0)
        local removed, removeError = pcall(self.border.RemoveFromParent, self.border)
        assert(reset and removed, tostring(resetError or removeError))
    end
    self.closed = true
end

function Screen:setAlpha(amount)
    assert(not self.closed, "转场遮罩已经关闭")
    local ok, failure = pcall(function()
        assert(type(amount) == "number" and amount >= 0 and amount <= 1, "转场遮罩透明度无效")
        assert(valid(self.pawn) and valid(self.world) and valid(self.controller) and valid(self.layout)
            and valid(self.root) and valid(self.border), "转场遮罩对象已经失效")
        assert(same(unwrap(self.pawn:GetWorld()), self.world)
            and same(unwrap(self.controller:GetWorld()), self.world)
            and same(unwrap(self.layout:GetWorld()), self.world), "转场遮罩不能跨越世界")
        assert(same(unwrap(self.controller:K2_GetPawn()), self.pawn)
            and same(unwrap(self.layout:GetOwningPlayer()), self.controller), "转场遮罩所属玩家已经改变")
        assert(same(unwrap(required(LIBRARY):GetUILayOut(self.controller)), self.layout)
            and same(rootOf(self.layout), self.root), "转场原生布局已经重建")
        assert(same(unwrap(self.border:GetParent()), self.root), "转场遮罩已经离开原生布局")
        -- Pause/settings remain visible and operable if opened during the fade.
        local menu = self.layout:HasModal()
            or self.layout:HasWidgetAboveLayer({ TagName = FName("UI.Layer.Game") }, true)
        self.border:SetRenderOpacity(amount)
        self.border:SetVisibility(menu and COLLAPSED or INVISIBLE_TO_INPUT)
    end)
    if not ok then pcall(self.close, self); error(failure, 0) end
end

function StageScreen.new(gameplay, pawn)
    pawn = checked(pawn, "转场遮罩玩家不可用")
    local world = checked(pawn:GetWorld(), "转场遮罩世界不可用")
    local controller = checked(gameplay:GetPlayerController(pawn, 0), "转场遮罩本地控制器不可用")
    assert(same(unwrap(controller:GetWorld()), world) and same(unwrap(controller:K2_GetPawn()), pawn),
        "转场遮罩控制器不属于当前玩家")
    local layout = checked(required(LIBRARY):GetUILayOut(controller), "转场原生布局尚未就绪")
    assert(same(unwrap(layout:GetOwningPlayer()), controller) and same(unwrap(layout:GetWorld()), world),
        "转场原生布局不属于当前玩家或世界")
    local root, kind = rootOf(layout)
    local self = setmetatable({ pawn = pawn, world = world, controller = controller,
        layout = layout, root = root, rootKind = kind }, Screen)
    local ok, failure = pcall(function()
        self.border = checked(StaticConstructObject(required("/Script/UMG.Border"), root), "无法创建原生转场遮罩")
        self.border:SetVisibility(INVISIBLE_TO_INPUT)
        self.border:SetBrushColor({ R = 0, G = 0, B = 0, A = 1 })
        self.border:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        self.border:SetRenderOpacity(0)
        if kind == "CanvasPanel" then
            local slot = checked(root:AddChildToCanvas(self.border), "无法挂载原生Canvas转场遮罩")
            slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 1, Y = 1 } })
            slot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
            slot:SetAlignment({ X = 0, Y = 0 })
            slot:SetAutoSize(false)
            slot:SetZOrder(100000)
        else
            local slot = checked(root:AddChildToOverlay(self.border), "无法挂载原生Overlay转场遮罩")
            slot:SetHorizontalAlignment(0)
            slot:SetVerticalAlignment(0)
            slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        end
        self:setAlpha(0)
    end)
    if not ok then pcall(self.close, self); error(failure, 0) end
    return self
end

return StageScreen
