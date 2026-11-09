-- Project a tipped plane in horizontal bands, then land on the original flat
-- mark. This produces changing perspective across the mark, rather than just
-- moving/scaling one rectangle. All animation writes are render transforms;
-- native Canvas layout/UVs stay fixed and no material or game asset is edited.
local Press, Instance = {}, {}
Instance.__index = Instance
local COUNT, APPROACH, SETTLE = 12, .44, .20
local function clamp(v) return math.max(0,math.min(1,v)) end
local function identity() return {Translation={X=0,Y=0},Scale={X=1,Y=1},Shear={X=0,Y=0},Angle=0} end
local function valid(v) return v~=nil and v:IsValid() end
local function smooth(v) return v*v*(3-2*v) end

function Press.geometry(index,count,width,height,progress)
    local p=clamp(progress)
    local eased=1-(1-p)^3
    local angle=math.rad(-57*(1-eased))
    local lift=height*.50*(1-eased)
    local focal=height*1.8
    local y0=(index-1)/count*height-height*.5
    local y1=index/count*height-height*.5
    local offset=-height*.17*(1-eased)
    local function project(y)
        local q=focal/(focal-lift+y*math.sin(angle))
        return (y*math.cos(angle)+offset)*q,q
    end
    local a,qa=project(y0)
    local b,qb=project(y1)
    local spin=-10*(1-eased)
    local center=(a+b)*.5
    return {Translation={X=-center*math.sin(math.rad(spin)),Y=center*math.cos(math.rad(spin))-(y0+y1)*.5},
        Scale={X=(qa+qb)*.5,Y=(b-a)/(height/count)},Shear={X=0,Y=0},Angle=spin}
end

local function makeBand(screen,texture,meta,plane,width,height,index)
    local h=height/COUNT
    local view=screen:make("SizeBox")
    view:SetWidthOverride(width);view:SetHeightOverride(h)
    view:SetVisibility(3);view:SetClipping(1)
    screen:place(view,0,(index-1)*h,width,h,plane)
    view:SetRenderTransformPivot({X=.5,Y=.5})
    local inner=screen:make("CanvasPanel");inner:SetVisibility(3);view:SetContent(inner)
    local image=screen:make("Image");image:SetVisibility(3);image:SetBrushFromTexture(texture,true)
    local tw,th=(meta and meta.width)or width,(meta and meta.height)or height
    local box=meta and meta.box or{0,0,1,1}
    local bx,by,bw,bh=box[1]or box.x or 0,box[2]or box.y or 0,box[3]or box.w or 1,box[4]or box.h or 1
    bh=bh*((meta and meta.cropFraction)or 1)
    local scale=math.min(width/(tw*bw),height/(th*bh))
    screen:place(image,(width-tw*bw*scale)*.5-tw*bx*scale,
        (height-th*bh*scale)*.5-th*by*scale-(index-1)*h,tw*scale,th*scale,inner)
    return view
end

function Press.new(screen,texture,meta,rect,animated)
    local self=setmetatable({width=rect.w,height=rect.h,bands={},animated=animated},Instance)
    self.flat=screen:image(texture,meta,rect.x,rect.y,rect.w,rect.h)
    self.flat.Slot:SetZOrder(3);self.flat:SetRenderTransformPivot({X=.5,Y=.5})
    if animated then
        self.plane=screen:panel(rect.x,rect.y,rect.w,rect.h);self.plane.Slot:SetZOrder(3)
        self.plane:SetVisibility(3);self.plane:SetRenderOpacity(0)
        for index=1,COUNT do self.bands[index]=makeBand(screen,texture,meta,self.plane,rect.w,rect.h,index)end
        self.echo=screen:image(texture,meta,rect.x,rect.y,rect.w,rect.h)
        self.echo.Slot:SetZOrder(3);self.echo:SetRenderTransformPivot({X=.5,Y=.5})
        self.echo:SetRenderOpacity(0)
    end
    self.flat:SetRenderOpacity(0)
    return self
end

function Instance:present(elapsed,final)
    if self.closed then return end
    if final or not self.animated or elapsed>=APPROACH+SETTLE then
        if self.finished then return end
        self.finished=true
        if valid(self.plane)then self.plane:SetRenderOpacity(0)end
        if valid(self.echo)then self.echo:SetRenderOpacity(0)end
        self.flat:SetRenderTransform(identity());self.flat:SetRenderOpacity(1)
        return
    end
    if elapsed<0 then return end
    if elapsed<APPROACH then
        local p=elapsed/APPROACH
        self.plane:SetRenderOpacity(smooth(clamp(p/.30)))
        for index,band in ipairs(self.bands)do
            band:SetRenderTransform(Press.geometry(index,COUNT,self.width,self.height,p))
        end
        return
    end
    if not self.landed then
        self.landed=true;self.plane:SetRenderOpacity(0);self.flat:SetRenderOpacity(1)
    end
    local p=clamp((elapsed-APPROACH)/SETTLE)
    local rebound=math.sin(p*math.pi*2)*(1-p)^2
    self.flat:SetRenderTransform({Translation={X=0,Y=0},Scale={X=1+.06*rebound,Y=1-.06*rebound},Shear={X=0,Y=0},Angle=-1.2*rebound})
    self.echo:SetRenderOpacity(.42*(1-p)^2)
    self.echo:SetRenderTransform({Translation={X=0,Y=0},Scale={X=1+.23*p,Y=1+.23*p},Shear={X=0,Y=0},Angle=0})
end

function Instance:close()
    self.closed=true;self.bands={}
end
return Press
