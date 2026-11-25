-- Display an authored CommonUI action without binding a second input handler.
local Hint = {}
local WIDGET_LIBRARY = "/Script/UMG.Default__WidgetBlueprintLibrary"
local PROMPT = "/Game/PBZContent/UI/Foundation/Widgets/BottomBar/WB_InputWidget.WB_InputWidget_C"
local ACTIONS = "/Game/PBZContent/DataTable/UI/DT_UniversalActions.DT_UniversalActions"
local reportedFailure

local function valid(object)
    return object and type(object.IsValid) == "function" and object:IsValid()
end

local function asset(path)
    local object = StaticFindObject(path)
    if not valid(object) then
        LoadAsset(path)
        object = StaticFindObject(path)
    end
    assert(valid(object), "原版按键提示缺少资源：" .. path)
    return object
end

function Hint.setText(prompt, text)
    local label = FText(text)
    prompt.DisplayText = label
    prompt.RichText:SetPBZFormatText(label)
end

function Hint.setAction(prompt, row, actionTable)
    local action = { DataTable = asset(actionTable or ACTIONS), RowName = FName(row) }
    prompt.InputActions = action
    prompt.InputActionWidget:SetInputAction(action)
end

function Hint.create(screen, row, text, x, y, width, height, canvas, actionTable)
    local prompt
    local ok, failure = pcall(function()
        local library = StaticFindObject(WIDGET_LIBRARY)
        assert(valid(library), "原版按键提示无法获取控件库")
        prompt = library:Create(screen.modal, asset(PROMPT), screen.controller)
        assert(valid(prompt), "无法创建原版按键提示")
        Hint.setAction(prompt, row, actionTable)
        Hint.setText(prompt, text)
        prompt:SetVisibility(3)
        screen:place(prompt, x, y, width, height, canvas).Slot:SetZOrder(22)
    end)
    if ok then return prompt end
    if valid(prompt) then pcall(prompt.RemoveFromParent, prompt) end
    if not reportedFailure then
        reportedFailure = true
        print("[PBZTestArenaNative] Action prompt: " .. tostring(failure) .. "\n")
    end
end

return Hint
