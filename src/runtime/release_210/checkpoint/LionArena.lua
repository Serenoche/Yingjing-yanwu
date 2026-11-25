-- Portable ORIGINAL Lion pole area. All edits belong to this private attempt.
-- The native blueprint supplies pole planning/links, Jump input and the temporary
-- GA_StandingOnPole grant. No global class, player skill, map or save is patched.
local SpawnClass = require("SpawnClass")
local SceneArena = require("SceneArena")
local Terrain = require("ArenaTerrain")
local Arena = {}
local Session = {}
Session.__index = Session
local AREA = "/Game/PBZContent/Blueprint/TriggerVolume/BP_LionDance_Area.BP_LionDance_Area_C"
local POLE = "/Game/RenewalContent/Actors/SpecialMove/Volume/BP_LionDancing_Pole_Base.BP_LionDancing_Pole_Base_C"
local EXIT = "/Game/RenewalContent/Actors/SpecialMove/Volume/BP_LionDancing_Pole_Exit.BP_LionDancing_Pole_Exit_C"
local STANDING = "/Game/RenewalContent/Actors/SpecialMove/GA/GA_StandingOnPole.GA_StandingOnPole_C"
local CLASS_PATHS = { AREA, POLE, EXIT, STANDING }
local LION = "BP_Monster_LionDancer_P2"
local ZERO, ONE = {Pitch=0,Yaw=0,Roll=0}, {X=1,Y=1,Z=1}
local COLOR = {R=0,G=0,B=0,A=0}
local function valid(x) return x ~= nil and x:IsValid() end
local function same(a,b) return valid(a) and valid(b) and a:GetAddress()==b:GetAddress() end
local inWorld = SceneArena.actorIsInWorld
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
local function vectorReady(v) return type(v.X)=="number" and type(v.Y)=="number" and type(v.Z)=="number" end
local function log(s) print("[PBZLionArena] "..s.."\n") end

local function overlappingArea(gameplay,pawn,world,class,center,extent,owned)
    -- The stock boss uses GetOverlappingActors to find its pole area. An
    -- unrelated region in another part of the same map cannot intercept it.
    for _,actor in ipairs(SceneArena.actorsOfClass(gameplay,pawn,world,class)) do
        if not same(actor,owned) then
            local origin,bounds={},{}
            actor:GetActorBounds(true,origin,bounds,false)
            if not vectorReady(origin) or not vectorReady(bounds) then return "等待已有舞狮区域的碰撞范围" end
            if bounds.X+bounds.Y+bounds.Z>0
                and math.abs(origin.X-center.X)<=bounds.X+extent.X
                and math.abs(origin.Y-center.Y)<=bounds.Y+extent.Y
                and math.abs(origin.Z-center.Z)<=bounds.Z+extent.Z then
                return "本场战斗范围与已有舞狮区域重叠"
            end
        end
    end
end

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

function Arena.preloadPaths(entry)
    if entry and entry.id == LION then return CLASS_PATHS end
end

function Arena.required(stage)
    for _, entry in ipairs(stage.members or {}) do
        if Arena.preloadPaths(entry) then return true end
    end
    return false
end

function Session:identity()
    return valid(self.area) and same(self.area:GetOwner(),self.pawn)
        and inWorld(self.area,self.world) and inWorld(self.pawn,self.world)
end

function Session:collect()
    -- Snapshot only arrays maintained by OUR area, including inactive pooled
    -- actors. Original spawned poles need not have an Actor.Owner, so an owner
    -- chain alone misses them. Recheck Area/linked pole identities before delete.
    for _,field in ipairs({"ActivatedPoles","DeactivatedPoles","PolesPlayerCanJump","CabbagePoles"}) do
        each(self.area[field],function(actor)
            if valid(actor) and actor:IsA(self.poleClass) and same(actor.Area,self.area)
                and inWorld(actor,self.world) then self.poles[actor:GetAddress()]=actor end
        end)
    end
    for _,field in ipairs({"ActivatedLinks","DeactivatedLinks"}) do
        each(self.area[field],function(actor)
            if inWorld(actor,self.world) then
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
    if now>=self.nextAreaCheck then
        self.nextAreaCheck=now+1
        local reason=overlappingArea(self.gameplay,pawn,self.world,self.areaClass,self.center,self.extent,self.area)
        assert(not reason,reason)
    end
    local inside=self.area:CheckIfPointLiesInsideArea(copy(pawn:K2_GetActorLocation()))
    -- Native tracked entry/exit is idempotent. It invokes the ORIGINAL callbacks
    -- once per transition; never call GiveAbility/EnableInput ourselves or fire
    -- the BP event directly on every poll. Physical overlap may reach it first.
    if self.walkInScene then
        inside=inside and require("XiguBossArena").inside(pawn,self.walkInScene)
    end
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
            if inWorld(actor,self.world) then
                local a,b=actor.LinkedPoleA,actor.LinkedPoleB
                if valid(a) and valid(b) and same(a.Area,self.area) and same(b.Area,self.area) then actor:K2_DestroyActor() end
            end
        end
        for _,actor in pairs(self.poles) do
            if inWorld(actor,self.world) and same(actor.Area,self.area) then actor:K2_DestroyActor() end
        end
        self.area:K2_DestroyActor()
        log("owned pole area and temporary player interaction released")
    end
    self.closed=true
end

local function exitFloor(pawn,system,scene,point)
    local hit={}
    local top={X=point.X,Y=point.Y,Z=scene.spawnTrace.top}
    local bottom={X=point.X,Y=point.Y,Z=scene.spawnTrace.bottom}
    if scene.spawnTrace.localGround and point.Z then
        top.Z,bottom.Z=point.Z+150,point.Z-195
    end
    local found=system:LineTraceSingle(pawn,top,bottom,0,false,{},0,hit,true,COLOR,COLOR,0)
    if not found and scene.spawnTrace.worldStaticFallback then
        hit={}
        found=system:LineTraceSingleForObjects(pawn,top,bottom,{0},false,{},0,hit,true,COLOR,COLOR,0)
    end
    if found and hit.ImpactPoint and hit.ImpactNormal and hit.ImpactNormal.Z>=0.75 then
        return copy(hit.ImpactPoint)
    end
end

local function portablePlacement(pawn, system, scene)
    local exits, _, home = Terrain.place(pawn, system, scene, { {-1300,0}, {1300,0}, {0,-1300}, {0,1300} })
    if not exits then return end
    local center = { X = home.X, Y = home.Y, Z = home.Z+1300 }
    local extent = { X = 1800, Y = 1800, Z = 2850 }
    for _, point in ipairs(scene.combatBoundary) do
        extent.X = math.max(extent.X, math.abs(point.X-center.X)+150)
        extent.Y = math.max(extent.Y, math.abs(point.Y-center.Y)+150)
    end
    return center, extent, exits, home
end

function Arena.new(pawn,scene,gameplay,system)
    assert(scene and (scene.id=="night" or scene.id=="lake" or scene.runtimeModule),"舞狮机制仅用于独立演武场")
    local world=SceneArena.runtimeWorld(pawn)
    if not valid(world) then return nil,"等待舞狮区域所在关卡" end
    local classes={}
    for _,path in ipairs(CLASS_PATHS) do
        local class,reason=SpawnClass.resolve(path)
        if not valid(class) then return nil,reason end
        classes[path]=class
    end
    local math=required("/Script/Engine.Default__KismetMathLibrary")
    local minX,maxX,minY,maxY=scene.anchor.X,scene.anchor.X,scene.anchor.Y,scene.anchor.Y
    for _,point in ipairs(scene.spawnPoints) do
        if point.X<minX then minX=point.X end; if point.X>maxX then maxX=point.X end
        if point.Y<minY then minY=point.Y end; if point.Y>maxY then maxY=point.Y end
    end
    local center={X=(minX+maxX)/2,Y=(minY+maxY)/2,Z=scene.anchor.Z+1500}
    local extent={X=(maxX-minX)/2+1800,Y=(maxY-minY)/2+1800,Z=3000}
    local placement=scene.lionArena
    if placement then center,extent=placement.center,placement.extent end
    local battle=scene.spawnPoints[1]
    local exitPoints=placement and placement.exits or {
        {X=battle.X-1300,Y=battle.Y}, {X=battle.X+1300,Y=battle.Y},
        {X=battle.X,Y=battle.Y-1300}, {X=battle.X,Y=battle.Y+1300},
    }
    local checkedExits, placementHome
    if scene.runtimeModule=="XiguBossArena" and (placement or not scene.portableBossMechanics) then
        local arena=require("XiguBossArena")
        local home=battle.Z and arena.mechanicFloor(pawn,system,{X=center.X,Y=center.Y,Z=battle.Z})
        if home then
            checkedExits={}
            for index,point in ipairs(exitPoints) do
                local floor=exitFloor(pawn,system,scene,point)
                if not floor or not arena.mechanicRoute(pawn,scene,home,floor) then
                    checkedExits=nil
                    break
                end
                checkedExits[index]=floor
            end
        end
        if not checkedExits and not scene.portableBossMechanics then return nil,"等待"..scene.name.."的舞狮桩区和下桩落点" end
    end
    if scene.portableBossMechanics and not checkedExits then
        center,extent,checkedExits,placementHome=portablePlacement(pawn,system,scene)
        if not checkedExits then return nil,"等待"..scene.name.."的舞狮下桩落点" end
        exitPoints=checkedExits
    end
    local conflict=overlappingArea(gameplay,pawn,world,classes[AREA],center,extent)
    if conflict then return nil,conflict end
    local transform=math:MakeTransform(center,ZERO,ONE)
    local deferred=required("/Script/SGameAI.Default__SGameAIFunctionLibrary"):SpawnActorDeferred(pawn,classes[AREA],transform,3)
    assert(valid(deferred),"无法生成舞狮原版机制区域")
    local session=setmetatable({pawn=pawn,world=world,gameplay=gameplay,area=deferred,areaClass=classes[AREA],
        poleClass=classes[POLE],center=center,extent=extent,nextAreaCheck=1,poles={},links={},createdExits={},
        walkInScene=checkedExits and scene.walkIn and scene or nil},Session)
    local ok,reason=pcall(function()
        deferred:SetOwner(pawn)
        assert(same(gameplay:FinishSpawningActor(deferred,transform,1),deferred),"舞狮机制区域初始化失败")
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
        if placementHome then
            playerPoint=copy(placementHome)
            playerPoint.Z=playerPoint.Z+pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()
        elseif placement then
            -- The bell is downstairs; verify the combat entrance above it.
            playerPoint=copy(scene.phaseReturnPoints[1])
            playerPoint.Z=playerPoint.Z+pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()
        end
        assert(area:CheckIfPointLiesInsideArea(playerPoint)==true,"原版舞狮区域未覆盖本场入场点")
        assert(area:CheckIfPointLiesInsideArea({X=scene.spawnPoints[1].X,Y=scene.spawnPoints[1].Y,Z=playerPoint.Z})==true,
            "原版舞狮区域未覆盖首领位置")
        assert(area:CheckIfPointLiesInsideArea({X=center.X+extent.X*3,Y=center.Y,Z=center.Z})==false,
            "原版舞狮区域边界校验失败")
        -- Original exit targets are invisible ground-height StandPoints, not
        -- elevated posts. Supply four checked landing anchors around the battle
        -- center; the native standing ability chooses/animates the exit itself.
        local exits=0
        for index,point in ipairs(exitPoints) do
            local x,y=point.X,point.Y
            local floor=checkedExits and checkedExits[index] or exitFloor(pawn,system,scene,point)
            if floor then
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
        if inWorld(session.area,world) then
            pcall(session.collect,session)
            pcall(function() session.area:TryUpdateActorInTriggerState(pawn,false) end)
            pcall(function() session.area:SetEnabled(false) end)
            for _,actor in pairs(session.links) do
                if inWorld(actor,world) then
                    local a,b=actor.LinkedPoleA,actor.LinkedPoleB
                    if valid(a) and valid(b) and same(a.Area,session.area) and same(b.Area,session.area) then
                        pcall(function() actor:K2_DestroyActor() end)
                    end
                end
            end
            for _,actor in pairs(session.poles) do
                if inWorld(actor,world) and same(actor.Area,session.area) then pcall(function() actor:K2_DestroyActor() end) end
            end
            for _,actor in pairs(session.createdExits) do
                if inWorld(actor,world) and same(actor:GetOwner(),session.area) then
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
