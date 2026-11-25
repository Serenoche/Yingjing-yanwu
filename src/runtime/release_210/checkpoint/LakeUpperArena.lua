local SceneArena = require("SceneArena")
local Layout = require("StockLakeLayout")
local Arena = {}
local run
local MATH = "/Script/Engine.Default__KismetMathLibrary"
local NAV = "/Script/NavigationSystem.Default__NavigationSystemV1"
local WORLD_STATIC, CLEAR = {0}, {R=0,G=0,B=0,A=0}
local PENDING = 0x08023600

local function valid(o) return o and type(o.IsValid) == "function" and o:IsValid() end
local function unwrap(o)
    if o and type(o.IsValid) ~= "function" and type(o.Get) == "function" then return o:Get() end
    return o
end
local function same(a,b) return valid(a) and valid(b) and a:GetAddress()==b:GetAddress() end
local function name(v) return type(v)=="string" and v or v and v:ToString() or "" end
local function required(path)
    local obj = StaticFindObject(path)
    assert(valid(obj), "缺少湖畔接口：" .. path)
    return obj
end
local function inWorld(o,w)
    return valid(o) and not o:HasAnyFlags(PENDING) and same(SceneArena.runtimeWorld(o),w)
end
local function emit(msg) print("[PBZStockLake] " .. msg .. "\n") end

local function findActor(gameplay,pawn,tx,path,expected)
    local out={}
    gameplay:GetAllActorsOfClass(pawn,required(path),out)
    for _, value in ipairs(out) do
        local actor=unwrap(value)
        if inWorld(actor,tx.world) and name(actor:GetFName())==expected then return actor end
    end
end

local function floorAt(pawn,system,p,z1,z2)
    local top,bottom={X=p.X,Y=p.Y,Z=z1},{X=p.X,Y=p.Y,Z=z2}
    local hit={}
    if system:LineTraceSingleForObjects(pawn,top,bottom,WORLD_STATIC,false,{},0,hit,true,CLEAR,CLEAR,0)
        and hit.ImpactNormal and hit.ImpactNormal.Z>=.65 then return hit.ImpactPoint.Z end
end

local function probeNav(pawn,system,scene,boss)
    local nav=required(NAV)
    local points={}
    for i, pt in ipairs(scene.spawnPoints) do
        local z=floorAt(pawn,system,pt,scene.spawnTrace.top,scene.spawnTrace.bottom)
        if not z then return false,"ground_"..i end
        local query={X=pt.X,Y=pt.Y,Z=z}
        local pos={}
        if not nav:K2_ProjectPointToNavigation(pawn,query,pos,nil,nil,{X=100,Y=100,Z=150}) or not pos.Z
            or math.abs(pos.Z-z)>100 then return false,"projection_"..i end
        points[i]=pos
    end
    for i=2,#points do
        local path=nav:FindPathToLocationSynchronously(pawn,points[1],points[i],boss or pawn,nil)
        if not valid(path) or path:IsPartial() or #path.PathPoints<2 then return false,"path_"..i end
    end
    return true
end

local function closeEnough(p,scene)
    local c=scene.spawnPoints[1]
    -- Avoid closing the ring if a player wandered out of the play area.
    return (p.X-c.X)^2+(p.Y-c.Y)^2 <= 4100^2
end

local function makeBarriers(pawn,tx)
    local spline=tx.fog.Spline
    assert(inWorld(spline,tx.world), "湖畔缺少原版雾门样条")
    local mathLib=required(MATH)
    local unit={X=1,Y=1,Z=1}
    local boxClass=required("/Script/Engine.BoxComponent")
    if tx.fog.bIsClosedSpline then
        spline:SetClosedLoop(true,true)
    end
    local length=spline:GetSplineLength()
    assert(length>16000 and length<70000,"湖畔雾门样条长度异常")
    local count=math.ceil(length/520)
    tx.barriers={}
    local first=spline:GetLocationAtDistanceAlongSpline(0,1)
    local last=first
    local channel=pawn.CapsuleComponent:GetCollisionObjectType()
    local function segment(a,b)
        local dx,dy=b.X-a.X,b.Y-a.Y
        local width=math.sqrt(dx*dx+dy*dy)
        if width<1 then return end
        local center={X=(a.X+b.X)*.5,Y=(a.Y+b.Y)*.5,Z=(a.Z+b.Z)*.5+160}
        local transform=mathLib:MakeTransform(center,{Pitch=0,Yaw=math.deg(math.atan(dy,dx)),Roll=0},unit)
        local box=tx.fog:AddComponentByClass(boxClass,true,transform,true)
        assert(valid(box),"创建湖畔雾门碰撞失败")
        tx.barriers[#tx.barriers+1]=box
        box.bCanEverAffectNavigation=false
        box:SetCollisionEnabled(0)
        box:SetGenerateOverlapEvents(false)
        box:SetBoxExtent({X=width*.5+25,Y=22,Z=580},false)
        box:SetCollisionObjectType(0)
        box:SetCollisionResponseToAllChannels(0)
        box:SetCollisionResponseToChannel(2,2)
        box:SetCollisionResponseToChannel(19,2)
        box:SetCollisionResponseToChannel(23,2)
        box:SetCollisionResponseToChannel(channel,2)
        box:SetHiddenInGame(true,false)
        tx.fog:FinishAddComponent(box,true,transform)
        local readback=box:K2_GetComponentLocation()
        assert(math.abs(readback.X-center.X)<2 and math.abs(readback.Y-center.Y)<2,"湖畔雾门碰撞位置不符")
    end
    for i=1,count do
        local p=spline:GetLocationAtDistanceAlongSpline(i*length/count,1)
        segment(last,p)
        last=p
    end
    if (last.X-first.X)^2+(last.Y-first.Y)^2>50^2 then
        assert((last.X-first.X)^2+(last.Y-first.Y)^2<850^2,"湖畔雾门样条未闭合")
        segment(last,first)
    end
    emit("FOG_BARRIERS count="..#tx.barriers)
end

function Arena.prepareStock(gameplay, system, pawn, world, scene)
    run = run or { world = world, nextNav = 0 }
    local tx = run
    assert(same(tx.world, world) and scene.map == "PBZ_Zhengdaodaying_WP", "湖畔原版世界不匹配")
    if tx.ready then return true end
    if tx.failure then return nil, tx.failure end
    local now = gameplay:GetRealTimeSeconds(pawn)
    if now < tx.nextNav then return nil, tx.reason end
    tx.nextNav = now + 1
    tx.fog = tx.fog or findActor(gameplay, pawn, tx,
        "/Game/PBZContent/Blueprint/Item/BP_FogDoor.BP_FogDoor_C", Layout.fog)
    if not tx.fog then
        tx.reason = "等待湖畔原版雾门"
        return nil, tx.reason
    end
    local navigable, reason = probeNav(pawn, system, scene)
    if not navigable then
        tx.reason = "等待湖畔原版寻路 " .. tostring(reason)
        return nil, tx.reason
    end
    local ok, failure = pcall(function()
        tx.passthrough = tx.fog.bInitiallyPassthrough
        tx.fog.bInitiallyPassthrough = true
        tx.fog:UpdateAfterOpen()
        makeBarriers(pawn, tx)
    end)
    if not ok then
        tx.failure = tostring(failure)
        for _, box in ipairs(tx.barriers or {}) do pcall(function() box:SetCollisionEnabled(0) end) end
        return nil, tx.failure
    end
    tx.ready, tx.closed = true, false
    emit("NAV result=full points=6")
    return true
end

function Arena.phaseDestination(pawn,system,scene)
    if not run or not run.ready or not inWorld(pawn,run.world) then return nil,"等待湖畔就绪" end
    for _, p in ipairs(Layout.phasePoints) do
        local z=floorAt(pawn,system,p,scene.spawnTrace.top,scene.spawnTrace.bottom)
        if z then
            local dest={X=p.X,Y=p.Y,Z=z+pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()+6}
            local rotation=required(MATH):FindLookAtRotation(dest,scene.spawnPoints[1])
            return {position=dest,rotation={Pitch=0,Yaw=rotation.Yaw,Roll=0}}
        end
    end
    return nil,"等待湖畔连战回位点承重"
end

function Arena.updateCombat(pawn,scene,active)
    local tx=run
    if not tx or not tx.ready or tx.closed==active or tx.fogFailed==active or not inWorld(pawn,tx.world) then return end
    if active and not closeEnough(pawn:K2_GetActorLocation(),scene) then return end
    local ok,reason=pcall(function()
        tx.fog.bInitiallyPassthrough=not active
        if active then tx.fog:UpdateAfterClose() else tx.fog:UpdateAfterOpen() end
        for _,box in ipairs(tx.barriers) do
            local mode=active and 1 or 0
            box:SetCollisionEnabled(mode)
            assert(box:GetCollisionEnabled()==mode,"湖畔雾门碰撞读回不符")
        end
    end)
    if ok then
        tx.closed,tx.fogFailed=active,nil
        emit("FOG_STATE closed="..tostring(active).." boxes="..#tx.barriers)
    else
        for _,box in ipairs(tx.barriers) do pcall(function() box:SetCollisionEnabled(0) end) end
        pcall(function() tx.fog.bInitiallyPassthrough=true;tx.fog:UpdateAfterOpen() end)
        tx.closed,tx.fogFailed=false,active
        emit("ERROR fog_state "..tostring(reason))
    end
end

function Arena.resetStock()
    local tx = run
    run = nil
    if not tx or not inWorld(tx.fog, tx.world) then return end
    for _, box in ipairs(tx.barriers or {}) do pcall(function() box:K2_DestroyComponent() end) end
    if tx.passthrough ~= nil then
        pcall(function()
            tx.fog.bInitiallyPassthrough = tx.passthrough
            tx.fog:UpdateAfterOpen()
        end)
    end
end

return Arena
