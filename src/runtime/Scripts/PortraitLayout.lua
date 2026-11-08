-- Ordered encounter portraits share one clipped native panel. Each complete
-- texture is positioned from its reviewed head/upper-chest subject box.
local Art = require("ArtAssets")
local Layout, View = {}, {}
View.__index = View
local function valid(v)return v and type(v.IsValid)=="function"and v:IsValid()end
local function finite(v)return type(v)=="number"and v==v and math.abs(v)<math.huge end
local function aspect(meta)
    if type(meta)~="table"or type(meta.box)~="table"then return 1 end
    local box=meta.compositeBox or meta.box
    local width,height=meta.width or meta.measuredWidth,meta.height or meta.measuredHeight
    local bw,bh=box[3]or box.w,box[4]or box.h
    if not(finite(width)and finite(height)and finite(bw)and finite(bh)and width>0 and height>0 and bw>0 and bh>0)then return 1 end
    return width*bw/(height*bh*(meta.cropFraction or 1))
end
-- Compatibility name: these are overlapping subject placements, never tiles.
function Layout.cells(count,rect,metadata)
    assert(type(count)=="number"and count%1==0 and count>=1 and count<=64,"画像对象数量无效")
    assert(type(rect)=="table"and finite(rect.x)and finite(rect.y)and finite(rect.w)and finite(rect.h)
        and rect.w>0 and rect.h>0,"画像布局范围无效")
    if count==1 then return {{x=rect.x,y=rect.y,w=rect.w,h=rect.h,z=1,scale=1}}end
    local result,totalWidth,largestWidth={},0,0
    local maximumWidth=rect.w*math.min(.72,.96/math.sqrt(count))
    local widestAspect=0
    for index=1,count do widestAspect=math.max(widestAspect,aspect(metadata and metadata[index]))end
    local baseHeight=math.min(rect.h*.92,maximumWidth/widestAspect)
    for index=1,count do
        local depth=(index-1)/(count-1)
        local height=baseHeight*(1-.12*depth)
        local ratio=aspect(metadata and metadata[index])
        local width=math.min(maximumWidth,height*ratio)
        height=width/ratio
        result[index]={w=width,h=height,y=rect.y+rect.h*(.08-.065*depth),z=count-index+1,
            scale=1-.12*depth,depth=depth}
        totalWidth=totalWidth+width
        largestWidth=math.max(largestWidth,width)
    end
    local margin=rect.w*.02
    local available=math.max(0,rect.w-margin*2-largestWidth)
    local ratio=math.max(.20,.78-.055*(count-2))
    local step=math.min(available/(count-1),totalWidth/count*ratio)
    local minimum,maximum=math.huge,-math.huge
    for index,item in ipairs(result)do
        local anchor=(index-1)*step
        minimum=math.min(minimum,anchor-item.w*.5)
        maximum=math.max(maximum,anchor+item.w*.5)
    end
    local firstAnchor=rect.x+(rect.w-(maximum-minimum))*.5-minimum
    for index,item in ipairs(result)do
        item.anchorX=firstAnchor+(index-1)*step
        item.anchorY=item.y+item.h*.5
        item.x=item.anchorX-item.w*.5
        item.overlapRatio=1-ratio
    end
    return result
end
function View:updateOpacity(alpha)
    if self.closed then return end
    assert(finite(alpha),"画像透明度无效")
    alpha=math.max(0,math.min(1,alpha))
    if valid(self.container)then self.container:SetRenderOpacity(alpha)
    else for _,widget in ipairs(self.widgets)do if valid(widget)then widget:SetRenderOpacity(alpha)end end end
end
function View:close()
    if self.closed then return end
    self.closed=true
    for _,widget in ipairs(self.widgets or {})do if valid(widget)then pcall(function()widget:RemoveFromParent()end)end end
    if valid(self.container)then pcall(function()self.container:RemoveFromParent()end)end
    self.widgets,self.members,self.container={},{},nil
end
function Layout.open(screen,context,encounterId,kind,rect)
    local self=setmetatable({widgets={},members={},geometry={}},View)
    local ok,failure=pcall(function()
        self.members=Art.encounter(context,encounterId,kind or "chest")
        if #self.members==0 then
            self.widgets[1]=screen:text("暂无立绘",rect.x,rect.y+rect.h*.5-20,rect.w,50,false)
            return
        end
        local metadata={};for index,item in ipairs(self.members)do metadata[index]=item.meta end
        if #self.members==1 then
            self.cells=Layout.cells(1,rect,metadata)
            local item=self.members[1]
            self.widgets[1]=valid(item.texture)and screen:image(item.texture,item.meta,rect.x,rect.y,rect.w,rect.h)
                or screen:text("暂无立绘",rect.x,rect.y+rect.h*.5-20,rect.w,50,false)
            return
        end
        self.container=screen:panel(rect.x,rect.y,rect.w,rect.h)
        self.container:SetVisibility(3);self.container:SetClipping(1)
        self.container.Slot:SetZOrder(5)
        self.cells=Layout.cells(#self.members,{x=0,y=0,w=rect.w,h=rect.h},metadata)
        for index,item in ipairs(self.members)do
            local place=self.cells[index]
            local widget,geometry
            if valid(item.texture)then widget,geometry=screen:portrait(item.texture,item.meta,place,self.container)
            else
                widget=screen:text("暂无立绘",place.x,place.y+place.h*.5-20,place.w,50,false,self.container)
                widget.Slot:SetZOrder(place.z)
            end
            self.widgets[#self.widgets+1],self.geometry[index]=widget,geometry
        end
    end)
    if not ok then self:close();error(failure,0)end
    return self
end
return Layout
