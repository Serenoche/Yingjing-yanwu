-- Passive native HUD: five practice switches use only F5..F9.
local Hud, current = {}, nil
local LIB = "/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary"
local WRAPPERS = { SafeZone = true, SizeBox = true, ScaleBox = true, Border = true }
local function valid(o) return o ~= nil and type(o.IsValid) == "function" and o:IsValid() end
local function unwrap(o)
    if o and type(o.IsValid) ~= "function" then
        local get = o.get or o.Get
        if type(get) == "function" then return get(o) end
    end
    return o
end
local function check(o, message) o = unwrap(o); assert(valid(o), message); return o end
local function required(path) return check(StaticFindObject(path), "missing practice HUD interface: " .. path) end
local function same(a,b) return valid(a) and valid(b) and a:GetAddress()==b:GetAddress() end
local function make(kind, outer)
    local o=check(StaticConstructObject(required("/Script/UMG."..kind),outer),"cannot create practice HUD "..kind)
    o:SetVisibility(3); return o
end
local function rootOf(layout)
    local root=check(check(layout.WidgetTree,"practice HUD has no tree").RootWidget,"practice HUD has no root")
    local seen={}
    for _=1,8 do
        local kind=root:GetClass():GetFName():ToString()
        assert(not seen[root:GetAddress()],"practice HUD root cycle"); seen[root:GetAddress()]=true
        if kind=="Overlay" or kind=="CanvasPanel" then return root,kind end
        assert(WRAPPERS[kind],"unsupported practice HUD root: "..kind)
        root=check(root:GetContent(),"practice HUD root content missing")
    end
    error("practice HUD root exceeds depth")
end
function Hud.close()
    if current and valid(current.panel) then pcall(current.panel.RemoveFromParent,current.panel) end
    current=nil
end
function Hud.update(controller,state,target)
    controller=check(controller,"practice HUD controller missing")
    local world=check(controller:GetWorld(),"practice HUD world missing")
    local layout=check(required(LIB):GetUILayOut(controller),"practice HUD layout missing")
    assert(same(layout:GetOwningPlayer(),controller) and same(layout:GetWorld(),world),"practice HUD owner mismatch")
    local root,kind=rootOf(layout)
    if current and (not same(current.root,root) or not same(current.controller,controller)
        or not same(current.world,world) or not valid(current.panel)) then Hud.close() end
    if not current then
        local panel=make("SizeBox",root); panel:SetWidthOverride(286)
        current={panel=panel,controller=controller,world=world,root=root,labels={}}
        local border=make("Border",panel)
        border:SetBrushColor({R=.025,G=.03,B=.035,A=.82})
        border:SetPadding({Left=12,Top=10,Right=12,Bottom=10});panel:SetContent(border)
        local body=make("VerticalBox",border);border:SetContent(body)
        for index=1,7 do
            local text=make("TextBlock",body)
            local font=text.Font; font.Size=index==1 and 18 or 14; text:SetFont(font)
            text:SetColorAndOpacity({SpecifiedColor={R=.95,G=.85,B=.57,A=1},ColorUseRule=0})
            text:SetAutoWrapText(true);text.WrapTextAt=262
            body:AddChildToVerticalBox(text):SetPadding({Left=0,Top=2,Right=0,Bottom=3})
            current.labels[index]=text
        end
        local slot
        if kind=="CanvasPanel" then
            slot=root:AddChildToCanvas(panel)
            slot:SetAnchors({Minimum={X=1,Y=0},Maximum={X=1,Y=0}})
            slot:SetAlignment({X=1,Y=0});slot:SetPosition({X=-20,Y=88});slot:SetAutoSize(true)
        else
            slot=root:AddChildToOverlay(panel);slot:SetHorizontalAlignment(3);slot:SetVerticalAlignment(1)
            slot:SetPadding({Left=0,Top=88,Right=20,Bottom=20})
        end
    end
    local function value(name) return state[name] and "开启" or "关闭" end
    local lines={"练习模式", "F5  敌人 AI　"..value("ai"),"F6  敌人回血　"..value("enemyRegen"),
        "F7  玩家无敌　"..value("invulnerable"),"F8  无限大招　"..value("infiniteUltimate"),
        "F9  无限暗源　"..value("infiniteSpiritShadow")}
    for index,text in ipairs(lines) do current.labels[index]:SetText(FText(text)) end
    current.labels[7]:SetText(FText(state.lastError or ""))
    current.labels[7]:SetVisibility(state.lastError and state.lastError~="" and 3 or 1)
    current.panel:SetVisibility((layout:HasModal() or layout:HasWidgetAboveLayer({TagName=FName("UI.Layer.Game")},true)) and 1 or 3)
    return true
end
return Hud
