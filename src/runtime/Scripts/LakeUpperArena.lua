local SceneArena = require("SceneArena")
local Layout = require("LakeUpperLayout")
local Arena = {}
local run, nextMenu = nil, 0
local MAP, PATH = "PBZ_LakeUpperArena", "/Game/Mods/PBZLakeUpperArena/PBZ_LakeUpperArena"
local GAME_MODE = "/Game/PBZContent/Blueprint/BP_GameMode_Build.BP_GameMode_Build_C"
local MATH = "/Script/Engine.Default__KismetMathLibrary"
local NAV = "/Script/NavigationSystem.Default__NavigationSystemV1"
local SKY_CLASS = "/Weather/OurWeather/Blueprints/Ultra_Dynamic_Sky_Child.Ultra_Dynamic_Sky_Child_C"
local FOG_CARD_CLASS = "/AkashaEffects/EasyFog/Blueprints/BP_EasyFog.BP_EasyFog_C"
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
local function emit(msg) print("[PBZLakeUpper] " .. msg .. "\n") end
local function objectName(o) return valid(o) and name(o:GetFName()) or "none" end

local function start(gameplay, context, scene)
    assert(scene.id=="lake" and scene.map==MAP and scene.standaloneLake, "湖畔裁剪图场景不符")
    run, nextMenu = {nextProbe=0, nextNav=0}, 0
    emit("MARK entry")
    emit(("LAYOUT total=%d detail=%d"):format(Layout.total,Layout.detail))
    local p, r = scene.anchor, scene.rotation
    local options = ("game=%s?Location=%.4f,%.4f,%.4f?Rotation=%.6f,%.6f,%.6f")
        :format(GAME_MODE,p.X,p.Y,p.Z,r.Pitch,r.Yaw,r.Roll)
    gameplay:OpenLevel(context,FName(PATH),true,options)
end

function Arena.travelFromTitle(gameplay, context, scene)
    assert(name(gameplay:GetCurrentLevelName(context,true))=="PBZ_StartMenu_CE_WP","须从演武标题入口进入湖畔")
    start(gameplay,context,scene)
end

function Arena.reload(gameplay, pawn, scene) start(gameplay,pawn,scene) end

local function snapshot(tx, mark)
    local seen, loaded, visible, detailLoaded, detailVisible, foreign = {}, 0, 0, 0, 0, 0
    for i=1,#tx.world.StreamingLevels do
        local level=tx.world.StreamingLevels[i]
        if valid(level) then
            local path=name(level:GetWorldAssetPackageFName())
            local kind=Layout.levels[path]
            if kind and not seen[path] then
                seen[path]=true
                if level:IsLevelLoaded() then
                    loaded=loaded+1
                    if kind=="arena" then detailLoaded=detailLoaded+1 end
                end
                if level:IsLevelVisible() then
                    visible=visible+1
                    if kind=="arena" then detailVisible=detailVisible+1 end
                end
            elseif not kind and level:IsLevelLoaded() and path:find("PBZ_Zhengdaodaying_WP",1,true) then
                foreign=foreign+1
            end
        end
    end
    if mark then
        emit(("CELLS mark=%s mode=standalone loaded=%d visible=%d detail_loaded=%d detail_visible=%d")
            :format(mark,loaded,visible,detailLoaded,detailVisible))
        emit(("PARENT_CELLS mark=%s loaded=%d"):format(mark,foreign))
    end
    return loaded,visible,foreign
end

local function reportEnvironment(gameplay,pawn,tx)
    local function count(class)
        local obj=StaticFindObject(class)
        if not valid(obj) then return 0 end
        local actors,n={},0
        gameplay:GetAllActorsOfClass(pawn,obj,actors)
        for _, ref in ipairs(actors) do if inWorld(unwrap(ref),tx.world) then n=n+1 end end
        return n
    end
    emit(("ENVIRONMENT terrain=%d water=%d post=%d fog_cards=%d niagara=%d")
        :format(count("/Script/Landscape.LandscapeStreamingProxy"),count("/Script/Water.WaterBodyLake"),
            count("/Script/Engine.PostProcessVolume"),count(FOG_CARD_CLASS),count("/Script/Niagara.NiagaraActor")))
end

local function findActor(gameplay,pawn,tx,path,expected)
    local out={}
    gameplay:GetAllActorsOfClass(pawn,required(path),out)
    for _, value in ipairs(out) do
        local actor=unwrap(value)
        if inWorld(actor,tx.world) and name(actor:GetFName())==expected then return actor end
    end
end

local function reportWater(gameplay,pawn,tx,mark)
    local lake=tx.lake or findActor(gameplay,pawn,tx,"/Script/Water.WaterBodyLake",Layout.water)
    local zone=tx.waterZone or findActor(gameplay,pawn,tx,"/Script/Water.WaterZone",Layout.waterZone)
    assert(inWorld(lake,tx.world) and inWorld(zone,tx.world),"湖畔原版水体或水区缺失")
    tx.lake,tx.waterZone=lake,zone
    local body=unwrap(lake.WaterBodyComponent)
    assert(valid(body),"湖畔水体组件缺失")
    local surface,zoneMesh=unwrap(body.LakeMeshComp),unwrap(zone.WaterMesh)
    assert(valid(surface) and valid(zoneMesh),"湖畔湖面组件缺失")
    local mesh,authored=unwrap(surface.StaticMesh),unwrap(body.WaterMaterial)
    assert(objectName(mesh)=="WaterInfoMesh_12" and valid(authored),"湖畔湖形或材质缺失")
    if mark=="arena_ready" then
        local ok,material=pcall(function() return unwrap(body:GetWaterMaterialInstance()) end)
        surface:SetMaterial(0,ok and valid(material) and material or authored)
    end
    if not surface:IsVisible() then surface:SetVisibility(true,false) end
    if surface.bHiddenInGame then surface:SetHiddenInGame(false,false) end
    -- Keep the original water info and material parameters, with one visible surface.
    if zoneMesh:IsVisible() then zoneMesh:SetVisibility(false,false) end
    if not zoneMesh.bHiddenInGame then zoneMesh:SetHiddenInGame(true,false) end
    emit(("WATER_SURFACE mark=%s mesh=%s visible=%s hidden=%s z=%.1f material=%s bound=%s zone_visible=%s")
        :format(mark,objectName(mesh),tostring(surface:IsVisible()),tostring(surface.bHiddenInGame),
            surface:K2_GetComponentLocation().Z,objectName(authored),objectName(unwrap(surface:GetMaterial(0))),
            tostring(zoneMesh:IsVisible())))
end

local function reportLighting(gameplay,pawn,tx,mark)
    local sky=tx.sky or findActor(gameplay,pawn,tx,SKY_CLASS,Layout.sky)
    assert(inWorld(sky,tx.world),"湖畔原版天空缺失")
    tx.sky=sky
    local sun,captured=unwrap(sky.Sun),unwrap(sky["Captured Scene Sky Light"])
    local ambient,cloud,fog=unwrap(sky.SkyLightComponent),unwrap(sky.VolumetricCloud),unwrap(sky.HeightFog)
    if not valid(ambient) then ambient=captured end
    assert(valid(sun) and valid(ambient),"湖畔日光或天空光组件缺失")
    emit(("LIGHT mark=%s sun=%.3f sun_visible=%s sky=%.3f sky_visible=%s source=%s realtime=%s sun_mask=%s")
        :format(mark,sun.Intensity,tostring(sun:IsVisible()),ambient.Intensity,tostring(ambient:IsVisible()),
            objectName(unwrap(ambient.Cubemap)),tostring(ambient.bRealTimeCapture),objectName(unwrap(sun.LightFunctionMaterial))))
    emit(("WEATHER mark=%s cloud_visible=%s cloud_material=%s cloud_shadows=%s height_fog=%s fog_density=%s")
        :format(mark,tostring(valid(cloud) and cloud:IsVisible() or false),
            objectName(valid(cloud) and unwrap(cloud.MaterialLifetimePtr)),tostring(sun.bCastCloudShadows),
            tostring(valid(fog) and fog.bEnableVolumetricFog or false),tostring(valid(fog) and fog.FogDensity)))
end

local function reportVisuals(gameplay,pawn,tx,mark)
    local waterOk,waterError=pcall(reportWater,gameplay,pawn,tx,mark)
    if not waterOk then emit("WATER_UNAVAILABLE mark="..mark.." reason="..tostring(waterError)) end
    local lightOk,lightError=pcall(reportLighting,gameplay,pawn,tx,mark)
    if not lightOk then emit("LIGHT_UNAVAILABLE mark="..mark.." reason="..tostring(lightError)) end
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

function Arena.update(gameplay,system,pawn,controller,world,scene,keep,allowBell)
    if not run or not valid(world) then return nil,"等待湖畔裁剪图" end
    local tx=run
    if tx.world and not same(tx.world,world) then return nil,"等待湖畔新世界" end
    tx.world=world
    local now=gameplay:GetRealTimeSeconds(pawn)
    tx.deadline=tx.deadline or now+25
    if tx.failed then return nil,tx.failed end
    if tx.ready then return SceneArena.update(gameplay,pawn,controller,now,scene,keep,allowBell) end
    if now<tx.nextProbe then return nil,tx.wait or "等待湖畔局部资源" end
    tx.nextProbe=now+.3
    local ok,result=pcall(function()
        local loaded,visible,foreign=snapshot(tx)
        assert(foreign==0,"不应载入陆家村原版区块")
        if loaded~=Layout.total or visible~=Layout.total then return "等待湖畔局部区块就绪" end
        local ready,reason=SceneArena.update(gameplay,pawn,controller,now,scene,keep,allowBell)
        if not ready then return reason or "等待原版铃铛复活点" end
        local p=scene.spawnPoints[1]
        local arenaZ=floorAt(pawn,system,p,scene.spawnTrace.top,scene.spawnTrace.bottom)
        if not arenaZ then return "等待湖畔擂台承重" end
        local liftZ=floorAt(pawn,system,{X=-65188,Y=84239},1250,960)
        if not liftZ or liftZ<1040 then return "等待湖畔电梯井口盖板" end
        if now<tx.nextNav then return "等待湖畔原版寻路" end
        tx.nextNav=now+1
        local navigable,navReason=probeNav(pawn,system,scene)
        if not navigable then return "等待湖畔寻路："..tostring(navReason) end
        tx.fog=findActor(gameplay,pawn,tx,"/Game/PBZContent/Blueprint/Item/BP_FogDoor.BP_FogDoor_C",Layout.fog)
        if not tx.fog then return "等待湖畔原版雾门" end
        tx.fog.bInitiallyPassthrough=true
        tx.fog:UpdateAfterOpen()
        makeBarriers(pawn,tx)
        tx.ready,tx.closed=true,false
        emit(("GROUND arena_z=%.2f lift_z=%.2f"):format(arenaZ,liftZ))
        emit("NAV result=full points=6")
        local checked,diagnosticError=pcall(reportEnvironment,gameplay,pawn,tx)
        if not checked then emit("ENVIRONMENT_UNAVAILABLE reason="..tostring(diagnosticError)) end
        reportVisuals(gameplay,pawn,tx,"arena_ready")
        emit("MARK arena_ready")
        snapshot(tx,"arena_ready")
    end)
    if not ok or (not tx.ready and now>=tx.deadline) then
        tx.failed=tostring(result or "湖畔场地就绪超时")
        for _,box in ipairs(tx.barriers or {}) do pcall(function() box:SetCollisionEnabled(0) end) end
        emit("ERROR readiness "..tx.failed)
    end
    tx.wait=ok and result or nil
    return tx.ready or nil,tx.failed or result
end

function Arena.getBell() return SceneArena.getBell() end

function Arena.findBellWidgets(class,now)
    if not run or now<nextMenu then return end
    nextMenu=now+.25
    return FindAllOf(class)
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

function Arena.refreshWater(gameplay,pawn)
    local tx=run
    if not tx or not tx.ready or tx.bossWaterChecked then return end
    tx.bossWaterChecked=true
    local ok,reason=pcall(reportWater,gameplay,pawn,tx,"boss_spawned")
    if not ok then emit("WATER_UNAVAILABLE mark=boss_spawned reason="..tostring(reason)) end
end

function Arena.reset()
    -- On normal travel the engine disposes this world and all its components.
    -- Keep an entry marker that was created before LoadMapPre fires.
    if run and run.world then run,nextMenu=nil,0 end
end

function Arena.abort() run,nextMenu=nil,0 end

emit("READY")
return Arena
