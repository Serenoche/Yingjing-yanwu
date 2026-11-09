-- Portable ORIGINAL Lion pole area. All edits belong to this private attempt.
-- The native blueprint supplies pole planning/links, Jump input and the temporary
-- GA_StandingOnPole grant. No global class, player skill, map or save is patched.
local SpawnClass = require("SpawnClass")
local Arena = {}
local Session = {}
Session.__index = Session
local AREA = "/Game/PBZContent/Blueprint/TriggerVolume/BP_LionDance_Area.BP_LionDance_Area_C"
local POLE = "/Game/RenewalContent/Actors/SpecialMove/Volume/BP_LionDancing_Pole_Base.BP_LionDancing_Pole_Base_C"
local EXIT = "/Game/RenewalContent/Actors/SpecialMove/Volume/BP_LionDancing_Pole_Exit.BP_LionDancing_Pole_Exit_C"
local STANDING = "/Game/RenewalContent/Actors/SpecialMove/GA/GA_StandingOnPole.GA_StandingOnPole_C"
local LION = "BP_Monster_LionDancer_P2"
local ZERO, ONE = {Pitch=0,Yaw=0,Roll=0}, {X=1,Y=1,Z=1}
local COLOR = {R=0,G=0,B=0,A=0}
local function valid(x) return x ~= nil and x:IsValid() end
local function same(a,b) return valid(a) and valid(b) and a:GetAddress()==b:GetAddress() end
local function required(path)
    local x=StaticFindObject(path); assert(valid(x),"舞狮场地接口不可用："..path); return x
end
local function unwrap(x)
    local ok,y=pcall(function() return x:get() end); return ok and y or x
end
local function each(array, action)
    -- Never read beyond a native TArray's length (this bridge can grow on GET).
    for i=1,#array do action(unwrap(array[i])) end
end
local function copy(v) return {X=v.X,Y=v.Y,Z=v.Z} end
local function log(s) print("[PBZLionArena] "..s.."\n") end

local function scaledNativeVolume(area,origin,extent)
    -- BaseSplineTriggerVolume.CheckIfPointLiesInsideArea first tests the COOKED
    -- local convex planes, transformed by the root's inverse transform. Editing
    -- Spline/BorderHeight/adding a Box does not rebuild those runtime planes.
    -- Preserve the authored spline+mesh+cache and transform the whole instance.
    -- Probe original native containment once to obtain conservative local spans;
    -- no unreflected memory, CDO mutation, cache fabrication or per-tick rebuild.
    assert(area:CheckIfPointLiesInsideArea(origin),"原版舞狮体积中心不可用")
    local scale={}
    for _,axis in ipairs({"X","Y","Z"}) do
        local span
        for _,direction in ipairs({-1,1}) do
            local function contains(distance)
                local p=copy(origin);p[axis]=p[axis]+direction*distance
                return area:CheckIfPointLiesInsideArea(p)==true
            end
            local low,high=0,64
            while contains(high) do
                low,high=high,high*2
                assert(high<=32768,"原版舞狮体积边界无法测定")
            end
            for _=1,8 do
                local mid=(low+high)/2
                if contains(mid) then low=mid else high=mid end
            end
            assert(low>=8,"原版舞狮体积过薄")
            span=span and math.min(span,low) or low
        end
        scale[axis]=extent[axis]/span*1.2
        assert(scale[axis]>0 and scale[axis]<256,"舞狮体积缩放超出范围")
    end
    area:SetActorScale3D(scale)
    -- Test all corners, not just the center or a custom box. The actual native
    -- checker must cover the whole requested battle volume before a boss spawns.
    for _,x in ipairs({-1,1}) do for _,y in ipairs({-1,1}) do for _,z in ipairs({-1,1}) do
        assert(area:CheckIfPointLiesInsideArea({X=origin.X+x*extent.X,Y=origin.Y+y*extent.Y,Z=origin.Z+z*extent.Z}),
            "舞狮原生体积未覆盖完整战斗范围")
    end end end
    area:UpdateSplinePointsArray()
    log(("native authored volume scaled; xyz=%.3f,%.3f,%.3f"):format(scale.X,scale.Y,scale.Z))
    return scale
end

function Arena.required(stage)
    for _,entry in ipairs(stage.members or {}) do if entry.id==LION then return true end end
    return false
end

function Session:identity()
    return valid(self.area) and same(self.area:GetOwner(),self.pawn)
        and same(self.area:GetWorld(),self.world) and same(self.pawn:GetWorld(),self.world)
end

function Session:collect()
    -- Snapshot only arrays maintained by OUR area, including inactive pooled
    -- actors. Original spawned poles need not have an Actor.Owner, so an owner
    -- chain alone misses them. Recheck Area/linked pole identities before delete.
    for _,field in ipairs({"ActivatedPoles","DeactivatedPoles","PolesPlayerCanJump","CabbagePoles"}) do
        each(self.area[field],function(actor)
            if valid(actor) and actor:IsA(self.poleClass) and same(actor.Area,self.area)
                and same(actor:GetWorld(),self.world) then self.poles[actor:GetAddress()]=actor end
        end)
    end
    for _,field in ipairs({"ActivatedLinks","DeactivatedLinks"}) do
        each(self.area[field],function(actor)
            if valid(actor) and same(actor:GetWorld(),self.world) then
                local a,b=actor.LinkedPoleA,actor.LinkedPoleB
                if valid(a) and valid(b) and same(a.Area,self.area) and same(b.Area,self.area) then
                    self.links[actor:GetAddress()]=actor
                end
            end
        end)
    end
end

function Session:update(pawn,now)
    assert(not self.closed and same(pawn,self.pawn) and self:identity(),"舞狮机制区域已切换或失效")
    if now < (self.nextAt or 0) then return true end
    self.nextAt=now+0.25
    local inside=self.area:CheckIfPointLiesInsideArea(copy(pawn:K2_GetActorLocation()))
    -- Native tracked entry/exit is idempotent. It invokes the ORIGINAL callbacks
    -- once per transition; never call GiveAbility/EnableInput ourselves or fire
    -- the BP event directly on every poll. Physical overlap may reach it first.
    self.area:TryUpdateActorInTriggerState(pawn,inside)
    self:collect()
    local count=0; for _,actor in pairs(self.poles) do if valid(actor) then count=count+1 end end
    if self.lastCount~=count or self.lastInside~=inside then
        self.lastCount,self.lastInside=count,inside
        log("area="..self.area:GetAddress().."; poles="..count.."; playerInside="..tostring(inside))
    end
    return true
end

function Session:close()
    if self.closed then return end
    if self:identity() then
        self:collect()
        -- Releases exactly the original area's own grant and input component.
        -- Does not clear unrelated abilities or replace the player's input mode.
        self.area:TryUpdateActorInTriggerState(self.pawn,false)
        self.area:SetEnabled(false)
        self.box:SetCollisionEnabled(0)
        for _,actor in pairs(self.links) do
            if valid(actor) and same(actor:GetWorld(),self.world) then
                local a,b=actor.LinkedPoleA,actor.LinkedPoleB
                if valid(a) and valid(b) and same(a.Area,self.area) and same(b.Area,self.area) then actor:K2_DestroyActor() end
            end
        end
        for _,actor in pairs(self.poles) do
            if valid(actor) and same(actor:GetWorld(),self.world) and same(actor.Area,self.area) then actor:K2_DestroyActor() end
        end
        self.area:K2_DestroyActor()
        log("owned pole area and temporary player interaction released")
    end
    self.closed=true
end

function Arena.new(pawn,scene,gameplay,system)
    assert(scene and (scene.id=="night" or scene.id=="lake"),"舞狮机制仅用于独立演武场")
    local world=pawn:GetWorld()
    local classes={}
    for _,path in ipairs({AREA,POLE,EXIT,STANDING}) do
        local class,reason=SpawnClass.resolve(path)
        if not valid(class) then return nil,reason end
        classes[path]=class
    end
    -- Never borrow or modify a story area's input/grants/pools.
    for _,actor in ipairs(FindAllOf("BP_LionDance_Area_C") or {}) do
        if valid(actor) and same(actor:GetWorld(),world) and not actor:IsActorBeingDestroyed() then
            return nil,"已有非本场舞狮区域；为避免冲突未接管"
        end
    end
    local math=required("/Script/Engine.Default__KismetMathLibrary")
    local minX,maxX,minY,maxY=scene.anchor.X,scene.anchor.X,scene.anchor.Y,scene.anchor.Y
    for _,point in ipairs(scene.spawnPoints) do
        if point.X<minX then minX=point.X end; if point.X>maxX then maxX=point.X end
        if point.Y<minY then minY=point.Y end; if point.Y>maxY then maxY=point.Y end
    end
    local center={X=(minX+maxX)/2,Y=(minY+maxY)/2,Z=scene.anchor.Z+1500}
    local extent={X=(maxX-minX)/2+1800,Y=(maxY-minY)/2+1800,Z=3000}
    local transform=math:MakeTransform(center,ZERO,ONE)
    local deferred=required("/Script/SGameAI.Default__SGameAIFunctionLibrary"):SpawnActorDeferred(pawn,classes[AREA],transform,3)
    assert(valid(deferred),"无法生成舞狮原版机制区域")
    local session=setmetatable({pawn=pawn,world=world,area=deferred,poleClass=classes[POLE],
        poles={},links={},createdExits={}},Session)
    local ok,reason=pcall(function()
        deferred:SetOwner(pawn)
        session.area=gameplay:FinishSpawningActor(deferred,transform,1)
        assert(session:identity(),"舞狮机制区域归属校验失败")
        local area=session.area
        assert(valid(area.Spline),"舞狮区域缺少原版样条")
        local volumeScale=scaledNativeVolume(area,center,extent)
        -- Add a query-only box to the ORIGINAL area actor. Its local extents
        -- account for root scale, keeping world bounds equal to the tested area.
        -- Boss.GetOverlappingActors therefore finds its expected class; native
        -- pole overlaps still reach ReceiveActorBeginOverlap and register pools.
        area.DynamicMeshComponent:SetCollisionEnabled(0)
        session.box=area:AddComponentByClass(required("/Script/Engine.BoxComponent"),false,
            math:MakeTransform({X=0,Y=0,Z=0},ZERO,ONE),false)
        assert(valid(session.box),"舞狮区域重叠组件创建失败")
        session.box:SetBoxExtent({X=extent.X/volumeScale.X,Y=extent.Y/volumeScale.Y,Z=extent.Z/volumeScale.Z},false)
        session.box:SetCollisionProfileName(FName("Profile_Trigger"),false)
        session.box:SetCollisionResponseToAllChannels(0)
        for _,channel in ipairs({1,2,19}) do session.box:SetCollisionResponseToChannel(channel,1) end
        session.box:SetGenerateOverlapEvents(true)
        session.box:SetCollisionEnabled(1)
        area:SetEnabled(true)
        assert(area:CheckIfPointLiesInsideArea(center)==true,"原版舞狮区域未识别内部点")
        local playerPoint=copy(pawn:K2_GetActorLocation())
        assert(area:CheckIfPointLiesInsideArea(playerPoint)==true,"原版舞狮区域未覆盖玩家位置")
        assert(area:CheckIfPointLiesInsideArea({X=scene.spawnPoints[1].X,Y=scene.spawnPoints[1].Y,Z=playerPoint.Z})==true,
            "原版舞狮区域未覆盖首领位置")
        assert(area:CheckIfPointLiesInsideArea({X=center.X+extent.X*3,Y=center.Y,Z=center.Z})==false,
            "原版舞狮区域边界校验失败")
        -- Original exit targets are invisible ground-height StandPoints, not
        -- elevated posts. Supply four checked landing anchors around the battle
        -- center; the native standing ability chooses/animates the exit itself.
        local battle=scene.spawnPoints[1]
        local exits=0
        for _,offset in ipairs({{X=-1300,Y=0},{X=1300,Y=0},{X=0,Y=-1300},{X=0,Y=1300}}) do
            local x,y=battle.X+offset.X,battle.Y+offset.Y
            local hit={}
            if system:LineTraceSingle(pawn,{X=x,Y=y,Z=scene.spawnTrace.top},
                {X=x,Y=y,Z=scene.spawnTrace.bottom},0,false,{},0,hit,true,COLOR,COLOR,0)
                and hit.ImpactPoint and hit.ImpactNormal and hit.ImpactNormal.Z>=0.75 then
                local floor=copy(hit.ImpactPoint)
                local exit=area:SpawnPole(math:MakeTransform({X=x,Y=y,Z=floor.Z-500},ZERO,ONE),true,classes[EXIT],false)
                assert(valid(exit),"原版舞狮落地点生成失败")
                exit:SetOwner(area)
                session.createdExits[exit:GetAddress()]=exit
                session.poles[exit:GetAddress()]=exit
                assert(same(exit.Area,area),"原版舞狮落地点未注册到本场区域")
                local stand=copy(exit.StandPoint:K2_GetComponentLocation())
                local at=copy(exit:K2_GetActorLocation()); at.Z=at.Z+floor.Z+4-stand.Z
                assert(exit:K2_SetActorTransform(math:MakeTransform(at,ZERO,ONE),false,{},true),"舞狮落地点校准失败")
                exit:SetActorHiddenInGame(true)
                exit.SM_WoodPost_001:SetCollisionEnabled(0)
                exits=exits+1
            end
        end
        assert(exits>=2,"场地缺少可用的舞狮落地点，未生成首领")
        session:update(pawn,0)
        log("original area prepared; scene="..scene.id.."; exits="..exits.."; center="..center.X..","..center.Y..","..center.Z)
    end)
    if not ok then
        -- Construction may have failed before a complete area/box existed.
        if valid(session.area) and same(session.area:GetOwner(),pawn) and same(session.area:GetWorld(),world) then
            pcall(session.collect,session)
            pcall(function() session.area:TryUpdateActorInTriggerState(pawn,false) end)
            pcall(function() session.area:SetEnabled(false) end)
            for _,actor in pairs(session.links) do
                if valid(actor) and same(actor:GetWorld(),world) then
                    local a,b=actor.LinkedPoleA,actor.LinkedPoleB
                    if valid(a) and valid(b) and same(a.Area,session.area) and same(b.Area,session.area) then
                        pcall(function() actor:K2_DestroyActor() end)
                    end
                end
            end
            for _,actor in pairs(session.poles) do
                if valid(actor) and same(actor.Area,session.area) then pcall(function() actor:K2_DestroyActor() end) end
            end
            for _,actor in pairs(session.createdExits) do
                if valid(actor) and same(actor:GetOwner(),session.area) and same(actor:GetWorld(),world) then
                    pcall(function() actor:K2_DestroyActor() end)
                end
            end
            pcall(function() session.area:K2_DestroyActor() end)
        end
        error(reason,0)
    end
    return session
end
return Arena
