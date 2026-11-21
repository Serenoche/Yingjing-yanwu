-- A private instance for practice when the native boss extension is pending.
local BossBar = {}
local WIDGETS = "/Script/UMG.Default__WidgetBlueprintLibrary"
local BAR_CLASS = "/Game/PBZContent/UI/Hud/WB_BossHPBar.WB_BossHPBar_C"

local function valid(object)
    local kind = type(object)
    return (kind == "table" or kind == "userdata") and type(object.IsValid) == "function" and object:IsValid()
end

local function same(first, second)
    return valid(first) and valid(second) and first:GetAddress() == second:GetAddress()
end

function BossBar.remove(widget)
    if valid(widget) then widget:RemoveFromParent() end
end

function BossBar.create(layout, controller, actor)
    assert(valid(layout) and valid(controller) and valid(actor), "practice phase bar scope unavailable")
    assert(same(layout:GetOwningPlayer(), controller) and same(layout:GetWorld(), actor:GetWorld())
        and not actor:IsActorBeingDestroyed(), "practice phase bar scope changed")
    local point = layout.BossPoint
    assert(valid(point), "practice boss point unavailable")
    local parent, original = point:GetParent(), point.Slot
    local overlay = StaticFindObject("/Script/UMG.Overlay")
    assert(valid(parent) and valid(original) and valid(overlay) and parent:IsA(overlay),
        "practice boss point overlay unavailable")
    local padding = original.Padding
    local margins = {Left=padding.Left, Top=padding.Top, Right=padding.Right, Bottom=padding.Bottom}
    local horizontal, vertical = original.HorizontalAlignment, original.VerticalAlignment
    local library, class = StaticFindObject(WIDGETS), StaticFindObject(BAR_CLASS)
    assert(valid(library) and valid(class), "practice native phase bar class unavailable")
    local widget = library:Create(layout, class, controller)
    assert(valid(widget), "practice native phase bar creation failed")
    local attached, failure = pcall(function()
        local slot = parent:AddChildToOverlay(widget)
        assert(valid(slot), "practice native phase bar attachment failed")
        slot:SetPadding(margins)
        slot:SetHorizontalAlignment(horizontal)
        slot:SetVerticalAlignment(vertical)
        widget:Init(actor)
        assert(same(widget.Character, actor), "practice native phase bar initialization failed")
    end)
    if not attached then
        pcall(BossBar.remove, widget)
        error(failure, 0)
    end
    return widget
end

return BossBar
