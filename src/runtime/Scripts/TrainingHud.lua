-- A passive child of the game's existing native layout; no input or menu stack.
local TrainingHud = {}
local LIBRARY = "/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary"
local MAX_TARGETS = 6
local COLLAPSED, HIT_TEST_INVISIBLE = 1, 3
-- SlateEnums.h: Fill=0, Left/Top=1, Center=2, Right/Bottom=3.
local H_ALIGN_RIGHT, V_ALIGN_TOP = 3, 1
local PANEL_WIDTH, CONTENT_WIDTH, PANEL_RIGHT, PANEL_TOP = 296, 272, 20, 88
local current
local warned = {}
local CONTENT_WIDGETS = { SafeZone = true, SizeBox = true, ScaleBox = true, Border = true }
local COLORS = {
    background = { R = 0.025, G = 0.03, B = 0.035, A = 0.82 },
    title = { R = 0.95, G = 0.85, B = 0.57, A = 1 },
    text = { R = 0.9, G = 0.91, B = 0.92, A = 1 },
    muted = { R = 0.65, G = 0.68, B = 0.71, A = 1 },
    selected = { R = 1, G = 0.87, B = 0.5, A = 1 },
    health = { R = 0.45, G = 0.72, B = 0.46, A = 1 },
    dead = { R = 0.78, G = 0.39, B = 0.35, A = 1 },
}
local DEFAULT_CONTROLS = {
    { key = "F5", action = "切换目标" },
    { key = "F6", action = "自动回血" },
    { key = "F7", action = "显示面板" },
    { key = "F8", action = "生成目标" },
    { key = "F9", action = "攻击 AI" },
    { key = "F10", action = "清除目标" },
}

local function valid(object)
    return object ~= nil and type(object.IsValid) == "function" and object:IsValid()
end

local function unwrap(value)
    local kind = type(value)
    if (kind == "table" or kind == "userdata") and type(value.IsValid) ~= "function" then
        local getter = value.get or value.Get
        if type(getter) == "function" then return getter(value) end
    end
    return value
end

local function checked(object, message)
    object = unwrap(object)
    assert(valid(object), message)
    return object
end

local function same(first, second)
    return valid(first) and valid(second) and first:GetAddress() == second:GetAddress()
end

local function warnOnce(kind, failure)
    if warned[kind] then return end
    warned[kind] = true
    print("[PBZTestArenaNative] Training HUD " .. kind .. ": " .. tostring(failure) .. "\n")
end

local function required(path)
    return checked(StaticFindObject(path), "缺少训练面板的原生界面接口：" .. path)
end

local function make(class, outer)
    local widget = checked(StaticConstructObject(required("/Script/UMG." .. class), outer),
        "无法创建原生训练面板控件：" .. class)
    widget:SetVisibility(HIT_TEST_INVISIBLE)
    return widget
end

local function finite(value, minimum, maximum)
    return type(value) == "number" and value == value and value >= minimum and value <= maximum
end

local function integer(value, minimum, maximum, fallback)
    return finite(value, minimum, maximum) and value == math.floor(value) and value or fallback
end

local function clean(value, limit)
    if type(value) ~= "string" and type(value) ~= "number" then return "" end
    local input = tostring(value):gsub("[%z\1-\31\127]", " ")
    local cursor, count = 1, 0
    while cursor <= #input and count < limit do
        local byte = input:byte(cursor)
        local length = byte < 128 and 1 or byte >= 194 and byte <= 223 and 2
            or byte >= 224 and byte <= 239 and 3 or byte >= 240 and byte <= 244 and 4 or 1
        if cursor + length - 1 > #input then break end
        cursor, count = cursor + length, count + 1
    end
    return input:sub(1, cursor - 1) .. (cursor <= #input and "…" or "")
end

local function metric(value)
    if not finite(value, 0, 1e15) then return "—" end
    if value >= 1e8 then return ("%.2f亿"):format(value / 1e8) end
    if value >= 1e6 then return ("%.1f万"):format(value / 1e4) end
    return ("%.0f"):format(value)
end

local function className(widget)
    local class = checked(widget:GetClass(), "训练面板根控件缺少类型")
    local name = class:GetFName()
    return type(name) == "string" and name or name:ToString()
end

local function panelRoot(layout)
    local tree = checked(layout.WidgetTree, "游戏原生布局没有可访问的 WidgetTree")
    local widget = checked(tree.RootWidget, "游戏原生布局没有可访问的根控件")
    local seen, chain = {}, {}
    for _ = 1, 8 do
        local name, address = className(widget), widget:GetAddress()
        chain[#chain + 1] = name
        assert(not seen[address], "游戏原生布局的根控件存在循环")
        seen[address] = true
        if name == "CanvasPanel" or name == "Overlay" then return widget, name end
        assert(CONTENT_WIDGETS[name], "不支持的游戏原生布局根类型：" .. table.concat(chain, " → "))
        widget = checked(widget:GetContent(), "游戏原生布局的单子控件为空：" .. name)
    end
    error("游戏原生布局根控件层数超过限制：" .. table.concat(chain, " → "))
end

local function addRow(box, widget, top, bottom)
    local slot = checked(box:AddChildToVerticalBox(widget), "无法挂载原生训练面板行")
    slot:SetPadding({ Left = 0, Top = top or 0, Right = 0, Bottom = bottom or 0 })
    return slot
end

local function color(widget, value)
    widget:SetColorAndOpacity({ SpecifiedColor = value, ColorUseRule = 0 })
end

local function label(outer, size, value)
    local widget = make("TextBlock", outer)
    -- This is this new widget's own font info. Keep its native Slate fallback.
    local ok, failure = pcall(function()
        local font = widget.Font
        font.Size = size
        widget:SetFont(font)
    end)
    if not ok then warnOnce("font", failure) end
    widget:SetAutoWrapText(true)
    -- WrapTextAt is reflected, but its native setter is not a UFUNCTION.
    -- Set before mounting so normal property synchronization applies it.
    widget.WrapTextAt = CONTENT_WIDTH
    color(widget, value or COLORS.text)
    return widget
end

local function mount(session, root, rootClass)
    local panel = make("SizeBox", root)
    session.panel = panel
    panel:SetVisibility(COLLAPSED)
    panel:SetWidthOverride(PANEL_WIDTH)
    local border = make("Border", panel)
    border:SetBrushColor(COLORS.background)
    border:SetPadding({ Left = 12, Top = 10, Right = 12, Bottom = 10 })
    panel:SetContent(border)
    local body = make("VerticalBox", border)
    border:SetContent(body)
    session.title = label(body, 18, COLORS.title)
    session.title:SetText(FText("训练场"))
    addRow(body, session.title, 0, 3)
    session.count = label(body, 14)
    addRow(body, session.count, 0, 2)
    session.status = label(body, 14, COLORS.muted)
    addRow(body, session.status, 0, 2)
    session.notice = label(body, 14, COLORS.muted)
    addRow(body, session.notice, 0, 2)
    session.empty = label(body, 14, COLORS.muted)
    session.empty:SetText(FText("尚无测试目标，按 F8 生成"))
    addRow(body, session.empty, 4, 2)
    session.units = {}
    for index = 1, MAX_TARGETS do
        local unit = { root = make("VerticalBox", body) }
        addRow(body, unit.root, 5, 1)
        unit.title = label(unit.root, 14)
        addRow(unit.root, unit.title, 0, 1)
        unit.health = label(unit.root, 14, COLORS.muted)
        addRow(unit.root, unit.health, 0, 2)
        local barBox = make("SizeBox", unit.root)
        barBox:SetHeightOverride(4)
        unit.bar = make("ProgressBar", barBox)
        unit.bar:SetIsMarquee(false)
        unit.bar:SetFillColorAndOpacity(COLORS.health)
        barBox:SetContent(unit.bar)
        addRow(unit.root, barBox, 0, 1)
        session.units[index] = unit
    end
    session.controlsTitle = label(body, 14, COLORS.title)
    session.controlsTitle:SetText(FText("按键指引"))
    addRow(body, session.controlsTitle, 6, 2)
    session.controls = {}
    for index = 1, 3 do
        session.controls[index] = label(body, 14, COLORS.muted)
        addRow(body, session.controls[index], 0, 1)
    end
    local slot
    if rootClass == "CanvasPanel" then
        slot = checked(root:AddChildToCanvas(panel), "无法挂载游戏原生 Canvas 训练面板")
        slot:SetAnchors({ Minimum = { X = 1, Y = 0 }, Maximum = { X = 1, Y = 0 } })
        slot:SetAlignment({ X = 1, Y = 0 })
        slot:SetPosition({ X = -PANEL_RIGHT, Y = PANEL_TOP })
        slot:SetAutoSize(true)
    else
        slot = checked(root:AddChildToOverlay(panel), "无法挂载游戏原生 Overlay 训练面板")
        slot:SetHorizontalAlignment(H_ALIGN_RIGHT)
        slot:SetVerticalAlignment(V_ALIGN_TOP)
        slot:SetPadding({ Left = 0, Top = PANEL_TOP, Right = PANEL_RIGHT, Bottom = 20 })
    end
    print("[PBZTestArenaNative] Training HUD attached; native UMG root=" .. rootClass
        .. "; controller=" .. tostring(session.controllerAddress) .. "; world=" .. tostring(session.worldAddress) .. "\n")
end

local function refresh(session, snapshot)
    local rows = {}
    for _, item in ipairs(type(snapshot.targets) == "table" and snapshot.targets or {}) do
        if #rows >= MAX_TARGETS then break end
        if type(item) == "table" then rows[#rows + 1] = item end
    end
    local maximum = integer(snapshot.maxTargets, 1, MAX_TARGETS, MAX_TARGETS)
    local cycle = integer(snapshot.enemyCycle, 0, 6, 0)
    local selected = snapshot.selectedId ~= nil and clean(snapshot.selectedId, 8) or nil
    session.count:SetText(FText(("目标 %d / %d  ·  敌人轮回 %d"):format(#rows, maximum, cycle)))
    session.status:SetText(FText("生命自动恢复 " .. (snapshot.autoheal == true and "开启" or "关闭") .. "  ·  "
        .. (selected and "当前 #" .. selected or "未选择目标")))
    local notice = clean(snapshot.message, 22)
    session.notice:SetText(FText(notice))
    session.notice:SetVisibility(notice ~= "" and HIT_TEST_INVISIBLE or COLLAPSED)
    session.empty:SetVisibility(#rows == 0 and HIT_TEST_INVISIBLE or COLLAPSED)
    for index, unit in ipairs(session.units) do
        local item = rows[index]
        unit.root:SetVisibility(item and HIT_TEST_INVISIBLE or COLLAPSED)
        if item then
            local id = clean(item.id or index, 8)
            local health = finite(item.health, 0, 1e15) and item.health or nil
            local maxHealth = finite(item.maxHealth, 0, 1e15) and item.maxHealth or nil
            local alive = item.alive ~= false and (health == nil or health > 0)
            local status = not alive and "已死亡" or item.ai == true and "AI 开启" or "AI 关闭"
            local level = integer(item.level, 0, 1000000)
            unit.title:SetText(FText((selected == id and "◆ " or "") .. "#" .. id .. "  Lv."
                .. (level and tostring(level) or "—") .. "  " .. status))
            color(unit.title, selected == id and COLORS.selected or alive and COLORS.text or COLORS.dead)
            unit.health:SetText(FText(metric(health) .. " / " .. metric(maxHealth)))
            unit.bar:SetPercent(health and maxHealth and maxHealth > 0 and math.max(0, math.min(1, health / maxHealth)) or 0)
        end
    end
    local controls = type(snapshot.controls) == "table" and #snapshot.controls > 0 and snapshot.controls or DEFAULT_CONTROLS
    local labels = {}
    for _, item in ipairs(controls) do
        if #labels >= 2 * #session.controls then break end
        if type(item) == "table" then
            local key, action = clean(item.key, 5), clean(item.action, 24)
            if key ~= "" and action ~= "" then labels[#labels + 1] = key .. "  " .. action end
        end
    end
    session.controlsTitle:SetVisibility(#labels > 0 and HIT_TEST_INVISIBLE or COLLAPSED)
    for index, widget in ipairs(session.controls) do
        local first, second = labels[2 * index - 1], labels[2 * index]
        widget:SetVisibility(first and HIT_TEST_INVISIBLE or COLLAPSED)
        if first then widget:SetText(FText(first .. (second and "　·　" .. second or ""))) end
    end
end

function TrainingHud.close()
    local session = current
    current = nil
    if session and valid(session.panel) then
        local ok, failure = pcall(function() session.panel:RemoveFromParent() end)
        if not ok then warnOnce("cleanup", failure) end
    end
end

function TrainingHud.update(controller, snapshot)
    if type(snapshot) ~= "table" or snapshot.mode ~= "ready" or snapshot.visible ~= true
        or snapshot.challenge == true or snapshot.training == false then
        TrainingHud.close()
        return false
    end
    local ok, result = pcall(function()
        controller = unwrap(controller)
        if not valid(controller) then TrainingHud.close(); return false end
        local world = unwrap(controller:GetWorld())
        if not valid(world) then TrainingHud.close(); return false end
        local layout = unwrap(required(LIBRARY):GetUILayOut(controller))
        if not valid(layout) then TrainingHud.close(); return false end
        assert(same(unwrap(layout:GetOwningPlayer()), controller), "游戏原生布局属于其他控制器")
        assert(same(unwrap(layout:GetWorld()), world), "游戏原生布局不属于当前场景")
        local root, rootClass = panelRoot(layout)
        local address, worldAddress = controller:GetAddress(), world:GetAddress()
        if current and (current.controllerAddress ~= address or current.worldAddress ~= worldAddress
            or not same(current.layout, layout) or not same(current.root, root)
            or not valid(current.panel) or not same(unwrap(current.panel:GetParent()), root)) then TrainingHud.close() end
        if not current then
            current = { controllerAddress = address, worldAddress = worldAddress, layout = layout, root = root }
            mount(current, root, rootClass)
        end
        local session = current
        refresh(session, snapshot)
        local hidden = layout:HasModal() or layout:HasWidgetAboveLayer({ TagName = FName("UI.Layer.Game") }, true)
        session.panel:SetVisibility(hidden and COLLAPSED or HIT_TEST_INVISIBLE)
        if not hidden and not session.shown then
            session.shown = true
            print("[PBZTestArenaNative] Training HUD first shown; native UMG root=" .. rootClass .. "\n")
        end
        return true
    end)
    if not ok then TrainingHud.close(); warnOnce("update", result); return false end
    return result
end

return TrainingHud
