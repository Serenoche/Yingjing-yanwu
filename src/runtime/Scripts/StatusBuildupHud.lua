-- Passive children of each target's native HP widget. No viewport/input owner,
-- event delegates, gameplay writes, hooks, or independent update loop.
local Status=require("StatusBuildup")
local Hud,current={},nil
local BAR_HEIGHT,ROW_GAP,MAX_ROWS=16,3,8
local BARS={
    {name="WB_BossHPBar_C",path="/Game/PBZContent/UI/Hud/WB_BossHPBar.WB_BossHPBar_C",actor="Character",kind="boss"},
    {name="WB_EnemyHPBar_C",path="/Game/PBZContent/UI/Hud/WB_EnemyHPBar.WB_EnemyHPBar_C",actor="SelfActor",kind="enemy"},
}
local ABILITIES={
    {name="GA_CommonUtilitiesPassiveBase",key="common",path="/Script/PBZCombatAsset.GA_CommonUtilitiesPassiveBase"},
    {name="GA_CommonUtilitiesPassive_C",key="common",path="/PBZCombatAsset/Prototypes/Abilities/GA_CommonUtilitiesPassive.GA_CommonUtilitiesPassive_C"},
    {name="GA_YaoJu_MonsterErosion_BP_C",key="erosion",path="/PBZCombatAsset/ActorData/Players/Hun/Weapon/YuuBlade/UpgradeData/GA_YaoJu_MonsterErosion_BP.GA_YaoJu_MonsterErosion_BP_C"},
}
local function valid(o) return o~=nil and type(o.IsValid)=="function" and o:IsValid() end
local function unwrap(o)
    if o and type(o.IsValid)~="function" then
        local get=o.get or o.Get
        if type(get)=="function" then return get(o) end
    end
    return o
end
local function checked(o,message) o=unwrap(o);assert(valid(o),message);return o end
local function same(a,b) return valid(a) and valid(b) and a:GetAddress()==b:GetAddress() end
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function className(o)
    local n=o:GetClass():GetFName()
    return type(n)=="string" and n or n:ToString()
end
local function make(kind,outer)
    local class=checked(StaticFindObject("/Script/UMG."..kind),"missing status HUD widget: "..kind)
    local o=checked(StaticConstructObject(class,outer),"cannot create status HUD "..kind)
    o:SetVisibility(3) -- HitTestInvisible: labels and bars never consume input.
    return o
end
local MATERIALS="/Script/Engine.Default__KismetMaterialLibrary"
local Gauge={};Gauge.__index=Gauge
local function dimensions(widget)
    local s=widget:GetDesiredSize();local w,h=s.X,s.Y
    if not finite(w)or w<=0 or not finite(h)or h<=0 then
        local b=widget.Brush.ImageSize;w,h=b.X,b.Y
    end
    assert(finite(w)and w>0 and finite(h)and h>0,"native layout size not ready")
    return w,h
end
local function margin(slot)
    local p=slot.Padding
    return {Left=p.Left,Top=p.Top,Right=p.Right,Bottom=p.Bottom}
end
local function aligned(desired,parent,first,last,alignment)
    if alignment==0 then return math.max(0,parent-first-last),(first-last)*.5 end
    if alignment==1 then return desired,first+(desired-parent)*.5 end
    if alignment==3 then return desired,(parent-desired)*.5-last end
    return desired,(first-last)*.5
end
local function localBounds(widget,parent)
    local w,h=dimensions(widget);local pw,ph=dimensions(parent)
    local slot=checked(widget.Slot,"native widget slot missing");local p=margin(slot)
    local dx,dy
    w,dx=aligned(w,pw,p.Left,p.Right,slot.HorizontalAlignment)
    h,dy=aligned(h,ph,p.Top,p.Bottom,slot.VerticalAlignment)
    local t=widget.RenderTransform
    local sx,sy,tx,ty=t.Scale.X,t.Scale.Y,t.Translation.X,t.Translation.Y
    local pivot=widget.RenderTransformPivot;local px,py=pivot.X,pivot.Y
    return {width=w*math.abs(sx),height=h*math.abs(sy),baseWidth=w,baseHeight=h,scaleX=sx,scaleY=sy,
        x=pw*.5+dx+tx+(sx-1)*w*(.5-px),y=ph*.5+dy+ty+(sy-1)*h*(.5-py)}
end
local function centerOffset(widget,parent)
    local x,y,seen=0,0,{}
    for _=1,6 do
        if not valid(widget)or seen[widget:GetAddress()]then return end
        seen[widget:GetAddress()]=true
        local p=checked(widget:GetParent(),"native Shachi ancestor missing")
        local r=localBounds(widget,p);local pw,ph=dimensions(p)
        x,y=x+r.x-pw*.5,y+r.y-ph*.5
        if same(p,parent)then return x,y end
        widget=p
    end
end
local function nativeSkin(bar,kind)
    local ok,skin=pcall(function()
        local source=bar.BreakmeterBar
        if not valid(source)or not valid(source.ImageBar)or not valid(source.MID_Bar)then return end
        local image,material=source.ImageBar,source.MID_Bar
        local parent=material.Parent
        if not valid(parent)then return end
        local frame
        if kind=="boss"then frame=bar.Image_187 else frame=bar.Image end
        if not valid(frame)or not valid(frame.Brush.ResourceObject)then return end
        local host=frame:GetParent()
        if not valid(host)or className(host)~="Overlay"then return end
        local bounds=localBounds(frame,host)
        local size=image:GetDesiredSize()
        local width,height=size.X,size.Y -- Copy before the next native call.
        if not finite(width)or width<=0 or not finite(height)or height<=0 then
            local brushSize=image.Brush.ImageSize;width,height=brushSize.X,brushSize.Y
        end
        local scale=image.RenderTransform.Scale
        local sx,sy=scale.X,scale.Y
        if not finite(width)or not finite(height)or not finite(sx)or not finite(sy)then return end
        width,height=width*math.abs(sx),height*math.abs(sy)
        if width<16 or width>4096 or height<1 or height>256 then return end
        local ox,oy=centerOffset(source,host)
        if not finite(ox)or not finite(oy)then return end
        local pw,ph=dimensions(host);local trans=image.RenderTransform.Translation
        local ix,iy=trans.X,trans.Y
        local fx,fy=bounds.x-(pw*.5+ox+ix),bounds.y-(ph*.5+oy+iy)
        return {source=material,parent=parent,image=image,width=width,height=height,
            frame=frame,host=host,frameWidth=bounds.width,frameHeight=bounds.height,frameX=fx,frameY=fy,
            frameBaseWidth=bounds.baseWidth,frameBaseHeight=bounds.baseHeight,frameScaleX=bounds.scaleX,frameScaleY=bounds.scaleY,
            outerWidth=math.max(width,bounds.width+2*math.abs(fx)),
            outerHeight=math.max(height,bounds.height+2*math.abs(fy))}
    end)
    if ok then return skin end -- Native Shachi widget may not be initialized yet.
end
function Gauge:paint(ratio)
    if self.painted~=ratio then
        self.painted=ratio
        self.material:SetScalarParameterValue(FName("BarRatio_FG"),ratio)
        self.material:SetScalarParameterValue(FName("BarRatio_BG"),ratio)
    end
end
function Gauge:SetPercent(ratio)
    self.percent=ratio
    if not self.marquee then self:paint(ratio)end
end
function Gauge:SetIsMarquee(enabled)
    self.marquee=enabled
    if not enabled then self:paint(self.percent or 0)end
end
function Gauge:SetFillColorAndOpacity(color)
    -- Foreground only: leave the original frame, background and tip mask alone.
    self.material:SetVectorParameterValue(FName("Color_FG"),color)
    self.material:SetVectorParameterValue(FName("TaintColor_FG"),
        {R=color.R*.23,G=color.G*.23,B=color.B*.23,A=color.A})
end
function Gauge:tick(now)
    if self.marquee then
        -- Indeterminate presentation only; never feeds back into status data.
        self:paint(.35+.2*math.sin(now*4))
    end
end
local function nativeGauge(skin,tree,context)
    local image=make("Image",tree)
    local material=checked(checked(StaticFindObject(MATERIALS),"missing UI material factory")
        :CreateDynamicMaterialInstance(context,skin.parent,FName("None"),0),"cannot create private status material")
    assert(not same(material,skin.source),"status material must not share the native Shachi instance")
    -- Same parent (including static switches/textures), then the source's live
    -- parameter overrides. All subsequent writes target this new instance.
    material:CopyParameterOverrides(skin.source)
    image:SetBrush(skin.image.Brush)
    image:SetBrushFromMaterial(material)
    local viewport=make("SizeBox",tree)
    viewport:SetWidthOverride(skin.outerWidth);viewport:SetHeightOverride(skin.outerHeight)
    local layers=make("Overlay",tree);viewport:SetContent(layers)
    local outline=make("Image",tree);outline:SetBrush(skin.frame.Brush)
    local c=skin.frame.ColorAndOpacity
    outline:SetColorAndOpacity({R=c.R,G=c.G,B=c.B,A=c.A})
    -- Preserve the original pre-scale size as well as its render scale: a
    -- nine-slice Box brush must not be stretched to the final width directly.
    outline:SetRenderScale({X=skin.frameScaleX,Y=skin.frameScaleY})
    local frameBox=make("SizeBox",tree)
    frameBox:SetWidthOverride(skin.frameWidth);frameBox:SetHeightOverride(skin.frameHeight)
    local frameLayer=make("Overlay",tree);frameBox:SetContent(frameLayer)
    local base=make("SizeBox",tree)
    base:SetWidthOverride(skin.frameBaseWidth);base:SetHeightOverride(skin.frameBaseHeight);base:SetContent(outline)
    local baseSlot=frameLayer:AddChildToOverlay(base);baseSlot:SetHorizontalAlignment(2);baseSlot:SetVerticalAlignment(2)
    frameBox:SetRenderTranslation({X=skin.frameX,Y=skin.frameY})
    local border=layers:AddChildToOverlay(frameBox);border:SetHorizontalAlignment(2);border:SetVerticalAlignment(2)
    local fillBox=make("SizeBox",tree)
    fillBox:SetWidthOverride(skin.width);fillBox:SetHeightOverride(skin.height);fillBox:SetContent(image)
    local fill=layers:AddChildToOverlay(fillBox);fill:SetHorizontalAlignment(2);fill:SetVerticalAlignment(2)
    local gauge=setmetatable({widget=viewport,image=image,material=material,percent=0,marquee=false},Gauge)
    gauge:paint(0)
    return gauge
end
local function parentOf(bar,kind)
    if kind=="boss"then
        local frame=bar.Image_187
        if valid(frame)then
            local parent=frame:GetParent()
            if valid(parent)and className(parent)=="Overlay"then return parent,"shachi"end
        end
        return
    end
    local child=bar.HPBar
    local seen={}
    for _=1,8 do
        if not valid(child) or seen[child:GetAddress()] then return end
        seen[child:GetAddress()]=true
        local parent=child:GetParent()
        if not valid(parent) then return end
        local name=className(parent)
        if kind=="boss" and name=="VerticalBox" then return parent,"vertical" end
        if kind=="enemy" and name=="Overlay" then return parent,"overlay" end
        child=parent
    end
end
local function reserveName(view,height)
    local name=view.nameLayout
    if not name or name.lost or not valid(name.widget)or not same(name.widget.Slot,name.slot)then return end
    local now=margin(name.slot)
    local p=name.original
    if math.abs(now.Top-(p.Top+name.applied))>.001 or now.Left~=p.Left or now.Right~=p.Right or now.Bottom~=p.Bottom then
        name.lost=true;return -- Another UI owner changed it; never overwrite that edit.
    end
    if height~=name.applied then
        name.slot:SetPadding({Left=p.Left,Top=p.Top+height,Right=p.Right,Bottom=p.Bottom})
        name.applied=height
    end
end
local function remove(view)
    pcall(reserveName,view,0)
    local root=view.attachment or view.panel
    if valid(root) then pcall(root.RemoveFromParent,root) end
end
function Hud.close()
    if current then for _,view in pairs(current.views) do remove(view) end end
    current=nil
end
local function mount(bar,actor,kind,actorField)
    local parent,layout=parentOf(bar,kind)
    if not valid(parent) then return end
    local skin=nativeSkin(bar,kind)
    if not skin then return end
    local view={bar=bar,actor=actor,actorField=actorField,parent=parent,cells={},sources={},skin=skin,
        rowHeight=math.max(BAR_HEIGHT,skin.outerHeight)}
    -- Build off-tree, attaching only a complete passive panel.
    local tree=valid(bar.WidgetTree) and bar.WidgetTree or parent
    local panel=make("SizeBox",tree); view.panel=panel
    panel:SetHeightOverride(0);panel:SetVisibility(1)
    local body=make("VerticalBox",tree);panel:SetContent(body)
    for index=1,MAX_ROWS do
        local cell={root=make("SizeBox",tree)}
        cell.root:SetHeightOverride(view.rowHeight)
        local overlay=make("Overlay",tree);cell.root:SetContent(overlay)
        cell.bar=nativeGauge(skin,tree,bar:GetOwningPlayer())
        local fill=overlay:AddChildToOverlay(cell.bar.widget)
        fill:SetHorizontalAlignment(2);fill:SetVerticalAlignment(2)
        cell.label=make("TextBlock",tree)
        local font=cell.label.Font;font.Size=11;cell.label:SetFont(font)
        cell.label:SetJustification(1)
        cell.label:SetColorAndOpacity({SpecifiedColor={R=1,G=1,B=1,A=1},ColorUseRule=0})
        cell.label:SetShadowColorAndOpacity({R=0,G=0,B=0,A=1})
        cell.label:SetShadowOffset({X=1,Y=1})
        local caption=overlay:AddChildToOverlay(cell.label)
        caption:SetHorizontalAlignment(2);caption:SetVerticalAlignment(2)
        body:AddChildToVerticalBox(cell.root):SetPadding({Left=0,Top=index==1 and 0 or ROW_GAP,Right=0,Bottom=0})
        cell.root:SetVisibility(1);view.cells[index]=cell
    end
    local ok,failure=pcall(function()
        local slot
        if layout=="shachi"then
            -- Zero desired size keeps this overlay from stretching the original
            -- Shachi image. Our canvas paints the stack beneath its outline.
            local root=make("SizeBox",tree);root:SetWidthOverride(0);root:SetHeightOverride(0)
            local canvas=make("CanvasPanel",tree);root:SetContent(canvas)
            view.attachment,view.panelParent=root,canvas
            local placement=checked(canvas:AddChildToCanvas(panel),"cannot place boss status stack")
            placement:SetAnchors({Minimum={X=0,Y=0},Maximum={X=0,Y=0}})
            view.placement=placement
            slot=checked(parent:AddChildToOverlay(root),"cannot attach status stack below Shachi")
            slot:SetHorizontalAlignment(0);slot:SetVerticalAlignment(0)
            local name=checked(bar.BossNameHorBox,"native boss name row missing")
            local nameSlot=checked(name.Slot,"native boss name slot missing")
            view.nameLayout={widget=name,slot=nameSlot,original=margin(nameSlot),applied=0}
        else
            view.attachment,view.panelParent=panel,parent
            slot=checked(parent:AddChildToOverlay(panel),"cannot attach enemy status bar")
            slot:SetHorizontalAlignment(2);slot:SetVerticalAlignment(2)
            -- Stock enemy HP/posture uses one centered Overlay. Translate only
            -- our panel below it; do not move/replace the native children.
            view.overlay=true
        end
    end)
    if not ok then remove(view);error(failure) end
    print("[PBZStatusBuildup] mounted "..kind.." target bar\n")
    return view
end
local function chargeOwner(object,allowed,byASC)
    local owner=object
    local seen={}
    for _=1,4 do
        if not valid(owner)or seen[owner:GetAddress()]then return end
        seen[owner:GetAddress()]=true
        owner=owner:GetOuter()
        if valid(owner)then
            local address=owner:GetAddress()
            if allowed[address]then return address end
            if byASC[address]then return byASC[address]end
        end
    end
end
local function discover(session,allowed,now)
    if now<session.scanAt then return end
    session.scanAt=now+.5
    local byASC={}
    session.abilities={}
    for address,actor in pairs(allowed) do
        local asc=actor.AbilitySystemComponent
        if valid(asc) then byASC[asc:GetAddress()]=address end
    end
    for _,definition in ipairs(ABILITIES) do
        if valid(StaticFindObject(definition.path)) then
            for _,ability in ipairs(FindAllOf(definition.name) or {}) do
                if valid(ability) then
                    -- GAS CreateNewInstanceOfAbility uses the owner actor as
                    -- Outer, not the ASC. Accept component-owned custom variants.
                    -- Never call avatar/actor-info getters on CDOs/templates.
                    local outer=ability:GetOuter()
                    local ownerAddress=valid(outer) and outer:GetAddress()
                    local address=ownerAddress and (allowed[ownerAddress] and ownerAddress or byASC[ownerAddress])
                    if address then
                        local owned=session.abilities[address] or {}
                        owned[definition.key]=ability;session.abilities[address]=owned
                    end
                end
            end
        end
    end
    -- Poll subobjects read-only. Never bind their single-cast UI delegates.
    local found,objects=pcall(FindAllOf,"UIChargeObject")
    if found then
        for _,object in ipairs(objects or {})do
            if valid(object)then
                local ok,address=pcall(chargeOwner,object,allowed,byASC)
                if ok and address then
                    local read,row=pcall(function()
                        local n=object:GetTableRow();return type(n)=="string"and n or n:ToString()
                    end)
                    if read and(row=="FrostAccumulation"or row=="BleedAccumulation"or row:match("^PoisonPhase[0-3]$"))then
                        local owned=session.abilities[address]or{}
                        owned.charges=owned.charges or{};owned.charges[row]=object;session.abilities[address]=owned
                    end
                end
            end
        end
    end
    for _,definition in ipairs(BARS) do
        if valid(StaticFindObject(definition.path)) then
            for _,bar in ipairs(FindAllOf(definition.name) or {}) do
                if valid(bar) and same(bar:GetOwningPlayer(),session.controller) and same(bar:GetWorld(),session.world) then
                    local actor=bar[definition.actor]
                    if valid(actor) and allowed[actor:GetAddress()] then
                        local address=bar:GetAddress()
                        local old=session.views[address]
                        if old and not same(old.actor,actor) then remove(old);session.views[address]=nil end
                        if not session.views[address] then session.views[address]=mount(bar,actor,definition.kind,definition.actor) end
                    end
                end
            end
        end
    end
end
local function display(view,rows,now)
    local cellWidth=view.skin.outerWidth
    if view.count~=#rows then
        view.count=#rows;view.panel:SetVisibility(#rows>0 and 3 or 1)
        local height=math.max(0,#rows*(view.rowHeight+ROW_GAP)-ROW_GAP)
        view.stackHeight=height
        view.panel:SetHeightOverride(height)
        if view.placement then
            view.placement:SetSize({X=cellWidth,Y=height})
            reserveName(view,height)
        end
        -- Keep the stack's top below the HP bar as more rows are added.
        if view.overlay then view.panel:SetRenderTranslation({X=0,Y=16+height*.5}) end
    end
    if view.width~=cellWidth then
        view.width=cellWidth
        view.panel:SetWidthOverride(cellWidth)
        for _,cell in ipairs(view.cells) do cell.root:SetWidthOverride(cellWidth) end
    end
    if view.placement then
        local bounds=localBounds(view.skin.frame,view.parent)
        local topInset=(view.rowHeight-view.skin.frameHeight)*.5+view.skin.frameY
        local x,y=bounds.x-view.skin.frameX-cellWidth*.5,bounds.y+bounds.height*.5-topInset
        if x~=view.anchorX or y~=view.anchorY then
            view.anchorX,view.anchorY=x,y;view.placement:SetPosition({X=x,Y=y})
        end
    end
    for index,cell in ipairs(view.cells) do
        local row=rows[index]
        if row then
            if view.sources[row.id]~=row.source then
                view.sources[row.id]=row.source
                print("[PBZStatusBuildup] "..row.id.." source="..row.source.."\n")
            end
            local signature=row.id.."|"..row.name.."|"..row.mode
            if signature~=cell.signature then
                cell.signature=signature;cell.root:SetVisibility(3)
                cell.label:SetText(FText(row.name))
                cell.bar:SetFillColorAndOpacity(row.color)
                cell.bar:SetIsMarquee(row.ratio==nil)
            end
            if cell.ratio~=row.ratio then cell.ratio=row.ratio;cell.bar:SetPercent(row.ratio or 0) end
            cell.bar:tick(now)
        elseif cell.signature then
            cell.signature,cell.ratio=nil,nil;cell.root:SetVisibility(1)
        end
    end
end
function Hud.update(controller,actors,now)
    if not valid(controller) or not finite(now) then Hud.close();return false end
    local world=controller:GetWorld()
    if not valid(world) then Hud.close();return false end
    local allowed={}
    for _,actor in ipairs(actors or {}) do
        if valid(actor) and same(actor:GetWorld(),world) then allowed[actor:GetAddress()]=actor end
    end
    if next(allowed)==nil then Hud.close();return true end
    if current and (not same(current.controller,controller) or not same(current.world,world) or now<current.lastTime) then Hud.close() end
    if not current then current={controller=controller,world=world,views={},abilities={},scanAt=now,updateAt=now,lastTime=now} end
    local session=current
    session.lastTime=now
    -- Drop an old stage immediately, even between scheduled samples/scans.
    for address,view in pairs(session.views) do
        if not valid(view.bar) or not valid(view.panel) or not valid(view.attachment)or not valid(view.panelParent)
            or not valid(view.actor) or not allowed[view.actor:GetAddress()]
            or not same(view.bar:GetOwningPlayer(),controller) or not same(view.bar:GetWorld(),world)
            or not same(view.bar[view.actorField],view.actor)
            or not same((view.attachment or view.panel):GetParent(),view.parent)
            or not same(view.panel:GetParent(),view.panelParent) then
            remove(view);session.views[address]=nil
        end
    end
    if now<session.updateAt then return true end
    session.updateAt=now+.1
    discover(session,allowed,now)
    -- One snapshot per actor, even if the game has two HP widgets for it.
    local samples={}
    for _,view in pairs(session.views) do
        local address=view.actor:GetAddress()
        if not samples[address] then
            local rows,failure=Status.read(view.actor,session.abilities[address])
            samples[address]=rows
            session.clockWarnings=session.clockWarnings or{}
            if failure and session.clockWarnings[address]~=failure then
                session.clockWarnings[address]=failure
                print("[PBZStatusBuildup] native timing unavailable: "..tostring(failure).."\n")
            elseif not failure then session.clockWarnings[address]=nil end
        end
        display(view,samples[address],now)
    end
    return true
end
return Hud
