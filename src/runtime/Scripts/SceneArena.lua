-- Original native bell scenes only. No replacement bell, map travel, marker
-- relocation, saved-resource restoration, or speculative high-altitude spawn.
local Arena = {}
local PENDING = 0x08023600
local CLEAR = { R=0, G=0, B=0, A=0 }
local worldId, pawnId, player, selectedBell, sceneRef, snapshot
local ready, stable, nextProbe, nextScan, wasDead, ownTag, lastLog
local lastProbeReason
local groundDiagAt,groundDiagReason=0,nil
local nextBellScan, preparationError, needsRescue
local streaming
local discovery = {}
local restores, handled = {}, {}
local pending = {}
local policySnapshots = {}
local blockedBells = {}
local entrySnapshots = {}
local entryNodes = {}
local interactionState
local hideTag, deadTag
local localBellPolicy
local actorClass, componentClass, primitiveClass, levelClass, queryContext

local function valid(v) return v ~= nil and type(v.IsValid)=="function" and v:IsValid() end
local function required(path) local o=StaticFindObject(path); assert(valid(o),"缺少原生场景接口："..path); return o end
local function ownerActor(v)
    if not valid(v) then return end
    actorClass=valid(actorClass) and actorClass or required("/Script/Engine.Actor")
    componentClass=valid(componentClass) and componentClass or required("/Script/Engine.ActorComponent")
    if v:IsA(actorClass) then return v end
    if v:IsA(componentClass) then
        local actor=v:GetOwner()
        if valid(actor) and actor:IsA(actorClass) then return actor end
    end
end
local function owningWorld(actor)
    -- Pinned UE4SS AActor:GetWorld follows Outer to the package's vestigial
    -- UWorld. ULevel.OwningWorld is the actual live world for streamed actors.
    local ok,result=pcall(function()
        local level=actor:GetLevel()
        if not valid(level) then return end
        local live=level.OwningWorld
        if valid(live) then return live end
        -- GetLevel returns a ULevel wrapped as UObject, so this specific
        -- GetWorld dispatch uses ULevel's native virtual, not LuaAActor's SDK
        -- Outer-world helper. Both native paths return OwningWorld.
        levelClass=valid(levelClass) and levelClass or required("/Script/Engine.Level")
        if level:IsA(levelClass) then return level:GetWorld() end
    end)
    if ok and valid(result) then return result end
end
local function inWorld(v,expected)
    local actor=ownerActor(v)
    local live=actor and owningWorld(actor) or nil
    -- A known foreign OwningWorld is authoritative: a cached/query fallback
    -- may never override it merely because the actor ID or package matches.
    if valid(live) and live:GetAddress()~=expected then return false end
    if valid(v) and v:IsA(componentClass) then
        -- ActorComponent uses the native UObject virtual GetWorld and prefers
        -- its registered WorldPrivate. Ownerless model/level geometry is legal.
        local ok,registered=pcall(function()return v:GetWorld()end)
        if ok and valid(registered) then return registered:GetAddress()==expected end
    end
    if valid(live) then return true end
    if not actor then return false end
    local context=queryContext
    if not context or context.world~=expected or not valid(context.pawn) then return false end
    local contextWorld=owningWorld(context.pawn)
    if not valid(contextWorld) or contextWorld:GetAddress()~=expected then return false end
    local class=actor:GetClass();if not valid(class) or class:HasAnyFlags(PENDING) then return false end
    local id=class:GetAddress();local members=context.classes[id]
    if not members then
        local list={}
        context.gameplay:GetAllActorsOfClass(context.pawn,class,list)
        members={};for _,item in ipairs(list) do if valid(item) then members[item:GetAddress()]=true end end
        context.classes[id]=members
    end
    return members[actor:GetAddress()]==true
end
local function world(v) return inWorld(v,worldId) end
local function name(v) if type(v)=="string" then return v end; return v and v:ToString() or "" end
local function unwrap(v)
    if v~=nil then
        local ok,x=pcall(function() return v:get() end); if ok then return x end
        ok,x=pcall(function() return v:Get() end); if ok then return x end
    end
    return v
end
local function copy(v) local r={}; for k,x in pairs(v) do r[k]=x end; return r end
local function finite(v) return type(v)=="number" and v>-math.huge and v<math.huge end
local function vector(v)
    if not v then return end
    local x,y,z=v.X,v.Y,v.Z
    if finite(x) and finite(y) and finite(z) then return {X=x,Y=y,Z=z} end
end
local function log(text)
    if text~=lastLog then print("[PBZTestArenaNative] Native scene arena: "..text.."\n"); lastLog=text end
end
local function undo(action)
    local ok,err=pcall(action)
    if not ok then pending[#pending+1]=action;log("restore pending: "..tostring(err)) end
end
local function drain()
    local old=pending;pending={}
    for _,action in ipairs(old) do undo(action) end
end
local function inside(actor,scene)
    if not world(actor) then return false end
    local p=actor:K2_GetActorLocation(); local s=scene.scope
    return p.X>=s.minX and p.X<=s.maxX and p.Y>=s.minY and p.Y<=s.maxY and p.Z>=s.minZ and p.Z<=s.maxZ
end
local function protected(actor,keep)
    return not valid(actor) or actor:GetAddress()==pawnId or (valid(selectedBell) and actor:GetAddress()==selectedBell:GetAddress())
        or (streaming and world(streaming.actor) and actor:GetAddress()==streaming.actor:GetAddress())
        or (keep and keep(actor))
end
local function removeTag()
    local old=ownTag;ownTag=false
    if old then
        undo(function()
            if not inWorld(old.pawn,old.world) then return end
            local asc=old.pawn.AbilitySystemComponent
            if not valid(asc) then return end
            local count=asc:GetGameplayTagCount(old.tag)
            -- A native call can have succeeded before its Lua wrapper throws.
            -- Never subtract a second stack when a previous attempt did so.
            if count==0 or (old.before and count<old.before) then return end
            old.before=count
            assert(required("/Script/ProjectPBZ.Default__PBZAbilityBlueprintLibrary")
                :RemoveLooseGameplayTag(old.pawn,old.tag,false),"原场景交互标签恢复待重试")
        end)
    end
end
function Arena.reset()
    if queryContext then queryContext.classes={} end -- fresh proof for rollback
    drain()
    removeTag()
    for i=#restores,1,-1 do undo(restores[i]) end
    if snapshot then
        snapshot.scene.anchor,snapshot.scene.reviveLocation,snapshot.scene.rotation,snapshot.scene.camera=
            snapshot.anchor,snapshot.revive,snapshot.rotation,snapshot.camera
    end
    worldId,pawnId,player,selectedBell,sceneRef,snapshot=nil,nil,nil,nil,nil,nil
    ready,stable,nextProbe,nextScan,wasDead,ownTag,lastLog=false,nil,0,0,false,false,nil
    nextBellScan,preparationError,needsRescue=0,nil,false
    lastProbeReason=nil
    groundDiagAt,groundDiagReason=0,nil
    discovery={}
    restores,handled={},{}
    policySnapshots={}
    blockedBells={}
    entrySnapshots={}
    entryNodes={}
    interactionState=nil
    streaming=nil
    queryContext=nil
end
local function streamOriginalBell(gameplay,pawn,controller,scene,now)
    -- The exact native helper used by SwitchStreamingSource. Keep its default
    -- all-grid/range/state/Shapes; no bell clone, DataLayer change or teleport.
    if scene.id~="cliff" and scene.id~="lake" then return end
    assert((scene.id=="cliff" and scene.map=="PBZ_Duanhun_WP" and scene.bellSaveId=="Bell_DH_004")
        or (scene.id=="lake" and scene.map=="PBZ_Zhengdaodaying_WP" and scene.bellSaveId=="BrokenBell_LJC_02"),"原铃铛流式加载目标不匹配")
    if ready and streaming then
        -- Completion walks WorldPartition cells. It is preparation diagnostics,
        -- not a per-frame combat query. Keep our source enabled: native player
        -- flags alone cannot prove equivalent live streaming coverage.
        if now<(streaming.nextReadyCheck or 0) then return end
        streaming.nextReadyCheck=now+1
        if not streaming.readyReported then
            streaming.readyReported=true
            local ok,details=pcall(function()
                local locationText="unavailable"
                local method=StaticFindObject("/Script/Engine.PlayerController:GetStreamingSourceLocationAndRotation")
                if valid(method) and not method:HasAnyFlags(PENDING) then
                    local read,at=pcall(function()
                        local location,rotation={},{}
                        controller:GetStreamingSourceLocationAndRotation(location,rotation)
                        return vector(location)
                    end)
                    if read and at then locationText=("%.2f,%.2f,%.2f"):format(at.X,at.Y,at.Z) end
                end
                return ("playerEnabled=%s playerActivate=%s playerSource=%s; owned helper retained"):format(
                    tostring(controller.bEnableStreamingSource),tostring(controller.bStreamingSourceShouldActivate),locationText)
            end)
            log("native streaming source settled: "..(ok and details or "readback unavailable; owned helper retained"))
        end
        if world(streaming.actor) and world(streaming.component) then return end
    end
    if streaming and not world(streaming.actor) then streaming=nil end
    if not streaming then
        local class=required("/Script/ProjectPBZ.EventpipelineStreamingSource")
        local cdo=class:GetCDO()
        assert(not class:HasAnyFlags(PENDING) and valid(cdo) and not cdo:HasAnyFlags(PENDING),"等待原生流式助手类型")
        local transform=required("/Script/Engine.Default__KismetMathLibrary"):MakeTransform(scene.bell.location,
            {Pitch=0,Yaw=0,Roll=0},{X=1,Y=1,Z=1})
        local actor=gameplay:BeginDeferredActorSpawnFromClass(pawn,class,transform,0,nil,1)
        assert(world(actor),"无法创建原生流式加载助手")
        local record={actor=actor,world=worldId}
        streaming=record
        -- Own the deferred actor before BeginPlay/Finish can fail.
        restores[#restores+1]=function()
            if inWorld(record.actor,record.world) and not record.actor:IsActorBeingDestroyed() then record.actor:K2_DestroyActor() end
        end
        local finished=gameplay:FinishSpawningActor(actor,transform,1)
        assert(world(finished) and finished:GetAddress()==actor:GetAddress(),"原生流式加载助手初始化失败")
        local actual=actor:K2_GetActorLocation();local target=scene.bell.location
        assert(actual and finite(actual.X) and finite(actual.Y) and finite(actual.Z)
            and math.abs(actual.X-target.X)<=1 and math.abs(actual.Y-target.Y)<=1 and math.abs(actual.Z-target.Z)<=1,
            "原生流式助手位置回读与目标不符")
        record.finished=true
        log("owned native streaming source created for "..scene.bellSaveId.."; original component defaults retained")
    end
    if not world(streaming.component) then
        local component=streaming.actor:GetComponentByClass(required("/Script/Engine.WorldPartitionStreamingSourceComponent"))
        assert(world(component) and not component:HasAnyFlags(PENDING),"等待原生流式助手组件")
        streaming.component=component
        component:EnableStreamingSource()
        local inspected,details=pcall(function()
            return ("enabled=%s grids=%d shapes=%d targetState=%s"):format(
                tostring(component:IsStreamingSourceEnabled()),#component.TargetGrids,#component.Shapes,tostring(component.TargetState))
        end)
        log("owned native streaming source defaults: "..(inspected and details or "readback unavailable: "..tostring(details)))
    end
    -- Completion is diagnostic; original BellID plus physical support still
    -- decides admission, never a streaming boolean alone.
    if ready or now<(streaming.nextCompletion or 0) then return end
    streaming.nextCompletion=now+1
    local complete=streaming.component:IsStreamingCompleted()
    if complete~=streaming.complete then
        streaming.complete=complete
        log("owned native streaming source completion="..tostring(complete).." (bell/physics checks still required)")
    end
end
local function findBell(gameplay,pawn,controller,scene,now)
    local function candidate(actor,source,ownerVerified)
        actor=unwrap(actor)
        if not world(actor) then return end
        local ok,result=pcall(function()
            local actorName=name(actor:GetFName())
            local class=actor:GetClass();local className=valid(class) and name(class:GetFName()) or "?"
            if not ownerVerified and not actorName:find("Bell",1,true) and not className:find("Bell",1,true) then return end
            local idOk,id=pcall(function() return name(unwrap(actor.BellID)) end)
            if not idOk then id="<unreadable BellID>" end
            local p=actor:K2_GetActorLocation()
            local exact=id==scene.bellSaveId
            local playerAt=pawn:K2_GetActorLocation()
            if not discovery[actor:GetAddress()] and (exact or (p.X-scene.bell.location.X)^2+(p.Y-scene.bell.location.Y)^2<1500^2
                or (p.X-playerAt.X)^2+(p.Y-playerAt.Y)^2<1500^2) then
                discovery[actor:GetAddress()]=true
                log(("bell candidate source=%s class=%s name=%s id=%s xyz=%.2f,%.2f,%.2f scope=%s expectedName=%s match=%s")
                    :format(source,className,actorName,id,p.X,p.Y,p.Z,tostring(inside(actor,scene)),
                        tostring(actorName:sub(1,#scene.bell.actorName)==scene.bell.actorName),tostring(exact)))
            end
            -- BellID is the native authored identity. UAID names can change in
            -- a loaded WP instance; region/name are diagnostics, never a reason
            -- to freeze a player who is beside the correct original bell.
            if exact then return actor end
        end)
        if ok then return result end
    end
    -- The native menu supplies its actual weak OwnerBell even if a class-name
    -- query did not enumerate the streamed variant. This route is read-only.
    for _,widget in ipairs(FindAllOf("W_BellMenu_C") or {}) do
        if valid(widget) and widget:IsActivated() then
            local owner=unwrap(widget:GetOwningPlayer())
            if valid(owner) and owner:GetAddress()==controller:GetAddress() then
                local bell=candidate(widget.OwnerBell,"native-menu",true);if bell then return bell end
            end
        end
    end
    if now<nextBellScan then return end;nextBellScan=now+.5
    local counts={}
    for _,class in ipairs({scene.bell.class,"BP_MelodiousBell_C","MelodiousBell"}) do
        local actors=FindAllOf(class) or {};counts[#counts+1]=class.."="..#actors
        for _,actor in ipairs(actors) do local bell=candidate(actor,class);if bell then return bell end end
    end
    -- GetAllActorsOfClass is the reflected world-scoped engine query. The
    -- blueprint is already part of the original map; never LoadAsset here.
    local base=scene.bell.class:gsub("_C$","")
    local class=StaticFindObject("/Game/PBZContent/Blueprint/Item/"..base.."."..scene.bell.class)
    local query=StaticFindObject("/Script/Engine.GameplayStatics:GetAllActorsOfClass")
    if valid(class) and not class:HasAnyFlags(PENDING) and valid(query) and not query:HasAnyFlags(PENDING) then
        local actors={};local ok=pcall(function() gameplay:GetAllActorsOfClass(pawn,class,actors) end)
        counts[#counts+1]="world-query="..(ok and #actors or "unavailable")
        if ok then for _,actor in ipairs(actors) do local bell=candidate(actor,"world-query");if bell then return bell end end end
    end
    local actors=FindAllOf("Actor") or {};counts[#counts+1]="Actor="..#actors
    for _,actor in ipairs(actors) do local bell=candidate(actor,"Actor");if bell then return bell end end
    if not discovery.missing then
        discovery.missing=true;log("bell discovery missing "..scene.bellSaveId.."; "..table.concat(counts,","))
    end
end
local function stopFlow(flow)
    if not valid(flow) then return end
    assert(not flow:HasAnyFlags(PENDING),"等待原生剧情组件载入")
    flow.bAutoStartRootFlow=false
    if valid(flow:GetRootFlowInstance()) then
        assert(valid(flow.RootFlow),"等待原生剧情根流程")
        flow:FinishRootFlow(flow.RootFlow,1)
        assert(not valid(flow:GetRootFlowInstance()),"剧情流程尚未关闭")
    end
    flow:PBZUnregister()
end
local function blockCliffPortal(scene)
    if scene.id~="cliff" then return end
    local expected="BP_MelodiousBell_C_UAID_74563C6BC2BD3C9B02_1461742006"
    for _,bell in ipairs(FindAllOf("BP_MelodiousBell_C") or {}) do
        if inside(bell,scene) and name(bell:GetFName()):sub(1,#expected)==expected
            and name(bell.BellID)=="Bell_DH_007" then
            -- 007 is 大梦倾颓处, not the selected 004 断魂崖. Keep its model,
            -- actor visibility/collision and local tags exactly as authored.
            local flow=bell.BP_PBZFlow
            local template=valid(flow) and flow.RootFlow
            if valid(template) and name(template:GetFName())=="BPF_ZuoShangBell_visible"
                and not bell:HasAnyFlags(PENDING) and not flow:HasAnyFlags(PENDING) then
                -- Its own map/teleport policy is also reversible. In-flight
                -- SetVisibility latent work may still run after unregister,
                -- but cannot recreate this interaction map or sphere mode.
                localBellPolicy(bell)
                local record=blockedBells[bell:GetAddress()]
                if not record then
                    local sphere=bell.InteractionComp
                    assert(world(sphere),"等待大梦倾颓处原交互组件")
                    record={bell=bell,sphere=sphere,collision=sphere:GetCollisionEnabled(),flow=flow,
                        autoStart=flow.bAutoStartRootFlow,live=flow:GetRootFlowInstance(),world=worldId}
                    blockedBells[bell:GetAddress()]=record
                    restores[#restores+1]=function()
                        if inWorld(record.sphere,record.world) then record.sphere:SetCollisionEnabled(record.collision) end
                    end
                    restores[#restores+1]=function()
                        if not inWorld(record.flow,record.world) then return end
                        record.flow.bAutoStartRootFlow=record.autoStart
                        local currentRoot=record.flow:GetRootFlowInstance()
                        if record.unregistered and valid(record.live) and valid(currentRoot)
                            and currentRoot:GetAddress()==record.live:GetAddress() then
                            -- Re-register this component's own delegates only.
                            -- Never restart/replay or claim to restore a node.
                            record.flow:PBZRegister();record.unregistered=false
                        end
                    end
                end
                record.sphere:SetCollisionEnabled(0)
                local currentRoot=not record.unregistered and record.flow:GetRootFlowInstance() or nil
                if valid(currentRoot) and not record.unregistered then
                    -- Native PBZUnregister only removes this component's
                    -- delegate registrations; it does not FinishRootFlow.
                    -- BeginPlay may start a graph after our first scan. Capture
                    -- that actual live instance just before unregistering; the
                    -- original autoStart snapshot is never replaced.
                    record.live=currentRoot
                    record.flow.bAutoStartRootFlow=false
                    record.flow:PBZUnregister()
                    record.unregistered=true
                end
            end
        end
    end
end
local function blockLakeEntries(scene,now)
    if scene.id~="lake" then return end
    local seen={}
    for _,node in ipairs(FindAllOf("SetExcuteType_C") or {}) do
        if valid(node) and not node:HasAnyFlags(PENDING + 0x30) then
            local nodeId=node:GetAddress()
            seen[nodeId]=true
            local known=entryNodes[nodeId]
            local shape=node.ShapeComponent
            local shapeId=valid(shape) and shape:GetAddress() or nil
            local sameShape=known and valid(known.node) and known.node:GetAddress()==nodeId and shapeId==known.shapeId
            if sameShape and known.accepted then
                -- A source actor is intentionally retired below. Keep its
                -- already proven native overlap disabled without repeatedly
                -- invoking every flow node's native owner getters.
                if world(shape) and shape:GetCollisionEnabled()~=0 then shape:SetCollisionEnabled(0) end
            elseif not(sameShape and now<known.nextRefresh) then
            -- RF_ClassDefaultObject|RF_ArchetypeObject are never runtime entry
            -- nodes; their native owner getters need an initialized root flow.
            -- This original node spawns its TriggerBox with Owner=None. Match
            -- the node's native source actor/flow, not that box's Actor.Owner
            -- or its unused authored EntryCenterTransform (UseSelfTransform).
            local owner=node:GetOwnerActor()
            local flow=node:GetOwnerFlowComponent()
            local template=valid(flow) and flow.RootFlow
            local ownerName=valid(owner) and name(owner:GetFName()) or ""
            local authored=false
            if valid(owner) then
                for _,spec in ipairs(scene.storyActors or {}) do
                    if ownerName:sub(1,#spec.name)==spec.name then authored=true;break end
                end
            end
            -- Incomplete nodes remain eligible next scan. Only a definitely
            -- unrelated owner may use a two-second negative cache.
            local nodeRecord={node=node,shapeId=valid(shape) and shape:GetAddress() or nil,
                nextRefresh=valid(owner) and not authored and now+2 or now}
            entryNodes[nodeId]=nodeRecord
            if authored and inside(owner,scene) and world(flow) and valid(template)
                and name(template:GetFName())=="BPF_MuXiaoKuiChuChang" then
                local actor=node.ShapeActor
                if world(actor) and world(shape)
                    and name(shape:GetCollisionProfileName())=="Profile_NpcFlowInteract" then
                    local id=shape:GetAddress();local record=entrySnapshots[id]
                    if not record then
                        record={shape=shape,world=worldId,mode=shape:GetCollisionEnabled()}
                        entrySnapshots[id]=record
                        restores[#restores+1]=function()
                            if inWorld(record.shape,record.world) then record.shape:SetCollisionEnabled(record.mode) end
                        end
                    end
                    if shape:GetCollisionEnabled()~=0 then shape:SetCollisionEnabled(0) end
                    nodeRecord.accepted=true
                    if not record.reported then
                        record.reported=true;log("lake native story entry disabled: "..ownerName)
                    end
                end
            end
            end
        end
    end
    for id in pairs(entryNodes) do if not seen[id] then entryNodes[id]=nil end end
end
local function suppress(scene,keep)
    -- Exact authored UAIDs, not all FlowActors/components. Native preload,
    -- terrain, LengTu marker classes and dynamically summoned enemies survive.
    -- Unregister authored narrative listeners/trigger domains before destroying
    -- their old pawn: its native Despawn/OnDestroyed must not start a death scene.
    local ordered={}
    for _,spec in ipairs(scene.storyActors or {}) do
        if spec.domain or spec.class=="BP_FlowActor_C" then ordered[#ordered+1]=spec end
    end
    for _,spec in ipairs(scene.storyActors or {}) do
        if not spec.domain and spec.class~="BP_FlowActor_C" then ordered[#ordered+1]=spec end
    end
    local byClass,names={},{}
    for _,spec in ipairs(ordered) do
        if not byClass[spec.class] then byClass[spec.class]=FindAllOf(spec.class) or {} end
        for _,actor in ipairs(byClass[spec.class]) do
            if valid(actor) and not handled[actor:GetAddress()] then
                local id=actor:GetAddress()
                local actorName=names[id]
                if not actorName then actorName=name(actor:GetFName());names[id]=actorName end
                -- Most same-class actors are unrelated. Filter the exact
                -- authored name before GetLevel/world/location/native calls.
                if actorName:sub(1,#spec.name)==spec.name and inside(actor,scene) and not protected(actor,keep) then
                assert(not actor:HasAnyFlags(PENDING),"等待原生剧情控制器载入")
                if spec.domain then
                    local old=actor:IsEnabled(); actor:SetEnabled(false)
                    local ownedWorld=worldId
                    restores[#restores+1]=function() if inWorld(actor,ownedWorld) then actor:SetEnabled(old) end end
                    handled[actor:GetAddress()]=true
                else
                    -- BP_AISpawner.GetPawn is the authored SpawnedAI reference;
                    -- its Despawn event calls CancelPendingSpawn and the native
                    -- SGameAISpawnerInterface.Despawn before removing NPC names.
                    -- Never infer ownership from a boss class or nearby marker.
                    local originalPawn=spec.class=="BP_AISpawner_C" and actor:GetPawn() or nil
                    if not valid(originalPawn) or (inside(originalPawn,scene) and not protected(originalPawn,keep)) then
                        actor:SetActorEnableCollision(false); stopFlow(actor.BP_PBZFlowComponent)
                        if spec.npc or spec.class=="BP_AISpawner_C" then actor:Despawn() end
                        if world(originalPawn) and inside(originalPawn,scene) and not protected(originalPawn,keep)
                            and not originalPawn:IsActorBeingDestroyed() then originalPawn:K2_DestroyActor() end
                        actor:K2_DestroyActor()
                        handled[actor:GetAddress()]=true
                    else
                        log("preserved spawner with protected/foreign pawn: "..spec.name)
                    end
                end
                end
            end
        end
    end
end
localBellPolicy=function(bell)
    local id=bell:GetAddress()
    local record=policySnapshots[id]
    if record and not valid(record.bell) then record=nil;policySnapshots[id]=nil;handled[id]=nil end
    if handled[id] and record then return end
    -- These are instance data. Do not touch the bell CDO or global narrative tags.
    if not record then
        local map=bell.FlowTagMap
        assert(type(map)=="userdata" and map:type()=="TMap" and map:IsValid(),"原铃铛剧情映射类型未就绪")
        local entries={}
        map:ForEach(function(k,v)
            entries[#entries+1]={ key=name(unwrap(k).TagName), value=name(unwrap(v).TagName) }
        end)
        record={bell=bell,map=map,entries=entries,teleport=bell.bDisableTeleport,
            brokenLeave=bell.bTeleportOnBrokenBellLeave,world=worldId}
        policySnapshots[id]=record
        -- Snapshot once before the first mutation. Retrying desired setters
        -- must never register a partially modified state as another original.
        restores[#restores+1]=function()
            if inWorld(record.bell,record.world) then
                record.bell.bDisableTeleport=record.teleport;record.bell.bTeleportOnBrokenBellLeave=record.brokenLeave
            end
        end
        restores[#restores+1]=function()
            if inWorld(record.bell,record.world) then
                record.map:Empty()
                for _,entry in ipairs(record.entries) do record.map:Add({TagName=FName(entry.key)},{TagName=FName(entry.value)}) end
            end
        end
    end
    record.map:Empty(); assert(#record.map==0,"原铃铛剧情映射关闭失败")
    bell.bDisableTeleport=true; bell.bTeleportOnBrokenBellLeave=false
    handled[id]=true
end
local function floorAt(pawn,at,radius,halfHeight)
    local system=required("/Script/Engine.Default__KismetSystemLibrary")
    -- UEngineTypes::ConvertToObjectType is C++, not a Kismet UFUNCTION.
    -- Default channel mapping in this build: ObjectTypeQuery1(0)=WorldStatic.
    local objectTypes={0}
    local center,body
    local ignored=valid(selectedBell) and {selectedBell} or {}
    for index,offset in ipairs({{0,0},{radius*.8,0},{-radius*.8,0},{0,radius*.8},{0,-radius*.8}}) do
        local hit={}; local x,y=at.X+offset[1],at.Y+offset[2]
        local found=system:LineTraceSingleForObjects(pawn,{X=x,Y=y,Z=at.Z-halfHeight+100},
            {X=x,Y=y,Z=at.Z-halfHeight-180},objectTypes,false,ignored,0,hit,true,CLEAR,CLEAR,0)
        -- Out-hit vector views may refer to temporary native call storage.
        -- Copy their scalar values before any other native owner/collision call.
        local point,normal=vector(hit.ImpactPoint),vector(hit.ImpactNormal)
        local component=unwrap(hit.Component)
        -- Packed OutHit booleans are not reliable in pinned UE4SS; use the
        -- native query result and actual physical component/Pawn response.
        local prefix="铃铛脚印"..index.."："
        if not found then return nil,prefix.."原生静态查询未命中" end
        if not point or not normal then return nil,prefix.."命中向量无效" end
        if normal.Z<.7 then return nil,prefix.."坡面不足，normalZ="..tostring(normal.Z) end
        if not world(component) then return nil,prefix.."命中组件不属于当前运行世界" end
        if component.Mobility~=0 then return nil,prefix.."支撑组件非静态，mobility="..tostring(component.Mobility) end
        if component:GetCollisionResponseToChannel(2)~=2 then return nil,prefix.."组件不阻挡Pawn" end
        local mode=component:GetCollisionEnabled()
        if mode~=1 and mode~=3 and mode~=5 then return nil,"原铃铛地面缺少物理查询碰撞" end
        if not center then center,body=point,component
        elseif math.abs(center.Z-point.Z)>28 then return nil,prefix.."五点高度差超过28cm" end
    end
    local destination={X=at.X,Y=at.Y,Z=center.Z+halfHeight+6}
    local hit={}
    local blocked=system:CapsuleTraceSingleForObjects(pawn,destination,{X=destination.X,Y=destination.Y,Z=destination.Z+.2},
        radius,halfHeight,objectTypes,false,ignored,0,hit,true,CLEAR,CLEAR,0)
    if blocked then return nil,"原铃铛角色胶囊净空不足" end
    return destination,body
end
local function supportState(component)
    if not valid(component) then return "missing" end
    primitiveClass=valid(primitiveClass) and primitiveClass or required("/Script/Engine.PrimitiveComponent")
    if not component:IsA(primitiveClass) then return "invalid" end
    local owner=ownerActor(component);local live=owner and owningWorld(owner) or nil
    if valid(live) and live:GetAddress()~=worldId then return "foreign" end
    local ok,registered=pcall(function()return component:GetWorld()end)
    if ok and valid(registered) and registered:GetAddress()~=worldId then return "foreign" end
    return world(component) and "live" or "unknown"
end
local function supportDescription(component,state)
    if not valid(component) then return "None("..state..")" end
    local owner=ownerActor(component)
    local ok,w=pcall(function()return component:GetWorld()end)
    return component:GetFullName().."["..state.." owner="..(valid(owner) and owner:GetFullName() or "None")
        .." registeredWorld="..(ok and valid(w) and tostring(w:GetAddress()) or "None").."]"
end
local function playerGround(pawn,scene,radius,halfHeight)
    local at=vector(pawn:K2_GetActorLocation())
    local original=snapshot and snapshot.anchor or scene.anchor
    if not at or (at.X-original.X)^2+(at.Y-original.Y)^2>300^2 or math.abs(at.Z-original.Z)>300 then
        return nil,"请在原铃铛300cm内站稳确认承重"
    end
    local movement=pawn.CharacterMovement
    if not valid(movement) then return nil,"角色移动组件未就绪" end
    local mode=movement.MovementMode
    local ok,data=pcall(function()
        -- These are live reflected properties (Operation::Get), whose pinned
        -- bool reader applies FieldMask. Never use an Out/return table copy of
        -- FindFloorResult: GetNonTrivialLocal has the known packed-bool issue.
        local floor=movement.CurrentFloor;local hit=floor.HitResult
        return {blocking=floor.bBlockingHit,walkable=floor.bWalkableFloor,penetrating=hit.bStartPenetrating,
            distance=floor.FloorDist,lineDistance=floor.LineDist,point=vector(hit.ImpactPoint),normal=vector(hit.ImpactNormal),
            location=vector(hit.Location),component=hit.Component,updated=movement.UpdatedComponent}
    end)
    if not ok then return nil,"原生CurrentFloor读取失败(mode="..tostring(mode)..")",tostring(data) end
    local method=StaticFindObject("/Script/Engine.CharacterMovementComponent:GetMovementBase")
    if not valid(method) or method:HasAnyFlags(PENDING) then return nil,"原生GetMovementBase接口未就绪" end
    local component=unwrap(data.component)
    local base=movement:GetMovementBase()
    local componentState,baseState=supportState(component),supportState(base)
    local weakKind="unavailable";local typed,kind=pcall(function()return data.component:type()end)
    if typed then weakKind=tostring(kind) end
    local detail=("mode=%s blocking=%s walkable=%s penetrating=%s floorDist=%s lineDist=%s hitWeak=%s hitComponent=%s base=%s updated=%s radius=%.2f half=%.2f nearBell=%.2f")
        :format(tostring(mode),tostring(data.blocking),tostring(data.walkable),tostring(data.penetrating),tostring(data.distance),
            tostring(data.lineDistance),weakKind,supportDescription(component,componentState),supportDescription(base,baseState),valid(data.updated) and tostring(data.updated:GetAddress()) or "None",
            radius,halfHeight,math.sqrt((at.X-original.X)^2+(at.Y-original.Y)^2))
    if mode~=1 and mode~=2 then return nil,"玩家未处于原生步行承重，MovementMode="..tostring(mode),detail end
    if data.blocking~=true or data.walkable~=true or data.penetrating~=false then return nil,"原生胶囊地面未就绪",detail end
    if not finite(data.distance) or data.distance< -10 or data.distance>20 or not data.point or not data.normal or data.normal.Z<=0 then
        return nil,"原生承重点/距离无效",detail
    end
    if math.abs(at.Z-halfHeight-data.point.Z)>60 or (at.X-data.point.X)^2+(at.Y-data.point.Y)^2>(radius+10)^2 then
        return nil,"原生承重命中已离开当前胶囊",detail
    end
    -- NavWalking does not continually update CurrentFloor. It may only reuse
    -- this certificate while its saved sweep location still matches the pawn.
    if mode==2 and (not data.location or (at.X-data.location.X)^2+(at.Y-data.location.Y)^2>5^2
        or math.abs(at.Z-data.location.Z)>20) then return nil,"NavWalking地面缓存已离开当前胶囊",detail end
    local capsule=pawn.CapsuleComponent
    if not world(movement) or not world(capsule) or not valid(data.updated)
        or data.updated:GetAddress()~=capsule:GetAddress() then return nil,"原生移动组件未关联当前角色胶囊",detail end
    if componentState=="foreign" or baseState=="foreign" or componentState=="invalid" or baseState=="invalid" then
        return nil,"原生支撑对象属于外部世界或类型不符",detail,true
    end
    if valid(base) and valid(component) and base:GetAddress()~=component:GetAddress() then
        return nil,"原生移动基座与胶囊承重组件不一致",detail
    end
    local support=valid(component) and component or valid(base) and base or nil
    if support then
        local collision=support:GetCollisionEnabled()
        if (collision~=1 and collision~=3 and collision~=5) or support:GetCollisionResponseToChannel(2)~=2 then
            return nil,"原生支撑不提供Pawn查询碰撞",detail
        end
    end
    if mode==2 and componentState~="live" and baseState~="live" then
        return nil,"NavWalking缺少当前可证的支撑对象",detail
    end
    -- UE explicitly permits a walkable floor with no primitive/base. In that
    -- case the live Walking floor belongs to this verified movement/capsule
    -- context; missing optional object identity is not evidence of foreignness.
    return at,support or capsule,detail
end
local function nativePoint(bell,scene)
    if bell:HasAnyFlags(PENDING) or bell:GetClass():HasAnyFlags(PENDING) then return nil,"等待原铃铛蓝图载入" end
    local event=StaticFindObject("/Game/PBZContent/Blueprint/Item/BP_MelodiousBell.BP_MelodiousBell_C:GetSaveTransform")
    if not valid(event) or event:HasAnyFlags(PENDING) then return nil,"等待原铃铛保存位置函数载入" end
    local transform,camera={},{ }
    bell:GetSaveTransform(transform,camera)
    local at,rotation,scale={},{},{}
    required("/Script/Engine.Default__KismetMathLibrary"):BreakTransform(transform,at,rotation,scale)
    for _,key in ipairs({"X","Y","Z"}) do assert(type(at[key])=="number" and at[key]>-math.huge and at[key]<math.huge,"原铃铛保存位置无效") end
    for _,key in ipairs({"Pitch","Yaw","Roll"}) do
        assert(finite(rotation[key]) and finite(camera[key]),"原铃铛保存朝向无效")
    end
    local original=snapshot and snapshot.anchor or scene.anchor
    assert((at.X-original.X)^2+(at.Y-original.Y)^2<800^2 and math.abs(at.Z-original.Z)<500,"原铃铛保存位置超出本地范围")
    return at,rotation,camera
end
local function dead(pawn)
    local asc=pawn.AbilitySystemComponent
    if valid(asc) and asc:GetGameplayTagCount(deadTag)>0 then return true end
    local attrs=pawn.AttributeSetBase
    if valid(attrs) then local hp=attrs.Health.CurrentValue; if finite(hp) then return hp<=0 end end
end
local function interaction(pawn,bell,allowed,now)
    local sphere=bell.InteractionComp
    if interactionState and valid(sphere) and interactionState.key==sphere:GetAddress()
        and interactionState.allowed==allowed and now<interactionState.nextVerify then return end
    assert(world(sphere),"等待原铃铛交互组件")
    local key=sphere:GetAddress()
    if not handled[key] then
        local old=sphere:GetCollisionEnabled(); handled[key]=old
        local ownedWorld=worldId
        restores[#restores+1]=function() if inWorld(sphere,ownedWorld) then sphere:SetCollisionEnabled(old) end end
    end
    local desired=allowed and handled[key] or 0
    if sphere:GetCollisionEnabled()~=desired then sphere:SetCollisionEnabled(desired) end
    if allowed then removeTag() else
        local asc=pawn.AbilitySystemComponent; assert(valid(asc),"等待原生角色能力组件")
        local count=asc:GetGameplayTagCount(hideTag)
        if count==0 then
            -- Register ownership before the native write. A wrapper can throw
            -- after the tag was added, in which case the error path must undo
            -- exactly that one stack instead of leaving interaction blocked.
            ownTag={pawn=pawn,world=worldId,tag=hideTag,before=count}
            assert(required("/Script/ProjectPBZ.Default__PBZAbilityBlueprintLibrary"):AddLooseGameplayTag(pawn,hideTag,false),"关闭原场景交互失败")
        end
    end
    interactionState={key=key,allowed=allowed,nextVerify=now+.5}
end
local function update(gameplay,pawn,controller,now,scene,keep,allowBell)
    if queryContext then queryContext.classes={} end
    drain()
    assert(scene and (scene.id=="drill" or scene.id=="cliff" or scene.id=="lake") and scene.nativeBell and scene.scope,"原生铃铛场景无效")
    if not valid(pawn) or not valid(controller) then return nil,"等待原场景角色" end
    if name(gameplay:GetCurrentLevelName(pawn,true))~=scene.map then
        if worldId then Arena.reset() end; return nil,"等待读入"..scene.name
    end
    local w=owningWorld(pawn); if not valid(w) then return nil,"等待原场景真实运行世界" end
    if worldId~=w:GetAddress() or pawnId~=pawn:GetAddress() or sceneRef~=scene then
        Arena.reset(); worldId,pawnId,player,sceneRef=w:GetAddress(),pawn:GetAddress(),pawn,scene
        hideTag={TagName=FName("Flow.HideInteract")};deadTag={TagName=FName("CharacterState.Dead")}
    end
    -- Only a missing OwningWorld reflection bridge needs the native query.
    -- Cache per class for this service pass, never global FindAllOf membership.
    queryContext={gameplay=gameplay,pawn=pawn,world=worldId,classes={}}
    if not world(controller) then return nil,"等待原场景控制器" end
    -- A player can open the original bell while discovery is pending. Native
    -- menus can pause/dilate game time, so preparation uses real time only.
    -- This does not change any encounter combat timer.
    now=gameplay:GetRealTimeSeconds(pawn);assert(finite(now),"原生场景实时时钟无效")
    local position=assert(vector(pawn:K2_GetActorLocation()),"角色位置无效")
    if not ready and not wasDead and not snapshot and math.abs(position.Z-scene.anchor.Z)>10000 then
        Arena.reset(); return nil,"角色不在所选原铃铛地图层"
    end
    local isDead=dead(pawn)
    if isDead then
        wasDead=true
        -- An encounter that was previously admitted must still record death
        -- while a streamed-out return cell is being reacquired.
        return (ready or snapshot~=nil) and true or nil,"等待原生复活"
    end
    if wasDead then
        if isDead==nil then return nil,"等待复活生命状态" end
        wasDead,ready,stable,needsRescue=false,false,nil,true;nextProbe=0
    end
    if snapshot and position.Z<scene.anchor.Z-500 and (ready or not needsRescue) then
        ready,stable,nextProbe,needsRescue=false,nil,0,true
    end
    if preparationError then return nil,"原生场景校准已停止（玩家移动不受限制）："..preparationError end
    -- Admission is not a recurring bell-floor prerequisite for combat. A jump
    -- or a dynamic native floor must not stop the encounter service. Native
    -- respawn / a genuine large fall above already re-enters safe admission.
    if not ready and #pending>0 then return nil,"等待上一原场景状态恢复" end
    -- Exact authored narrative suppression must not wait for the target bell's
    -- separate spatial cell. Preserve all unrelated/native preload actors.
    if now>=nextScan then
        blockLakeEntries(scene,now);blockCliffPortal(scene);suppress(scene,keep);nextScan=now+(ready and 1 or .5)
    end
    streamOriginalBell(gameplay,pawn,controller,scene,now)
    selectedBell=world(selectedBell) and selectedBell or findBell(gameplay,pawn,controller,scene,now)
    if not valid(selectedBell) then
        if ready then return true end -- A distant native bell may stream out during combat.
        return nil,"等待原铃铛流式载入："..scene.bellSaveId
    end
    localBellPolicy(selectedBell)
    if not ready then
        -- Native maps already load at their original saved point. Waiting for
        -- discovery/physics must not borrow MOVE_None or stop player velocity.
        -- Keep the original bell operable so its OwnerBell can identify it.
        if now<nextProbe then return nil,lastProbeReason or "等待首次地面采样" end;nextProbe=now+.12
        local capsule=pawn.CapsuleComponent;assert(world(capsule),"等待原生角色胶囊")
        local radius,halfHeight=capsule:GetScaledCapsuleRadius(),capsule:GetScaledCapsuleHalfHeight()
        assert(finite(radius) and finite(halfHeight) and radius>0 and halfHeight>=radius,"原生角色胶囊尺寸无效")
        -- The game's current player-floor certificate is authoritative. A
        -- sporadic static Bell query must not keep changing the sample source.
        local target,body,detail,foreign=playerGround(pawn,scene,radius,halfHeight)
        local playerReason=body
        local rotation,camera,source=scene.rotation,scene.camera,"player"
        local strictReason=foreign and "未调用（原生支撑明确不符）" or "未调用（原生玩家证据有效）"
        if not target and not foreign then
            local at,r,c=nativePoint(selectedBell,scene)
            if at then target,body=floorAt(pawn,at,radius,halfHeight) end
            strictReason=at and body or r
            if target then rotation,camera,source=r,c,"bell" end
        end
        if not target then
            stable=nil;lastProbeReason="玩家承重："..tostring(playerReason).."；铃铛扫描："..tostring(strictReason)
            log(scene.id..": "..lastProbeReason)
            if detail and (groundDiagReason~=playerReason or now>=groundDiagAt) then
                print("[PBZTestArenaNative] Native grounded admission: "..detail.."\n")
                groundDiagReason,groundDiagAt=playerReason,now+2
            end
            return nil,lastProbeReason
        end
        local moved=stable and source=="player" and ((stable.x-target.X)^2+(stable.y-target.Y)^2>12^2 or math.abs(stable.z-target.Z)>4)
        if not stable or stable.source~=source or stable.body~=body:GetAddress() or moved
            or (source=="bell" and math.abs(stable.z-target.Z)>1) then
            stable={source=source,body=body:GetAddress(),x=target.X,y=target.Y,z=target.Z,since=now,count=0}
        end
        stable.count=stable.count+1
        if stable.count<3 or now-stable.since<.25 then
            lastProbeReason=("已取得%s承重样本%d/3，等待连续稳定"):format(source=="player" and "玩家原生胶囊" or "铃铛物理",stable.count)
            return nil,lastProbeReason
        end
        -- A bell can be discovered after the player has walked away. Initial
        -- calibration only publishes its safe anchor; never pull that player
        -- back or overwrite their camera. Relocation is reserved for an actual
        -- post-admission fall/native respawn, after support is proven again.
        if needsRescue and source=="bell" then
            assert(required("/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary"):PBZActorTeleportTo(pawn,target,rotation,false,false),"无法定位原铃铛安全保存点")
            controller:SetControlRotation(camera)
        end
        if not snapshot then snapshot={scene=scene,anchor=scene.anchor,revive=scene.reviveLocation,rotation=scene.rotation,camera=scene.camera} end
        scene.anchor,scene.reviveLocation,scene.rotation,scene.camera=copy(target),copy(target),copy(rotation),copy(camera)
        ready,needsRescue=true,false
        lastProbeReason=nil
        log(("%s ready via=%s Bell=%s x=%.2f y=%.2f z=%.2f body=%s %s"):format(scene.id,source,scene.bellSaveId,target.X,target.Y,target.Z,body:GetFullName(),detail or ""))
    end
    interaction(pawn,selectedBell,allowBell==true,now)
    return true
end
function Arena.update(...)
    local ok,a,b=pcall(update,...)
    if not ok then
        -- A bad bridge/setter cannot retry indefinitely while taking input or
        -- movement ownership. Preserve the first concrete failure for this
        -- world/pawn; leaving/reentering the scope explicitly resets it.
        preparationError=tostring(a)
        if streaming and not streaming.finished then
            local failed=streaming;streaming=nil
            undo(function()
                if inWorld(failed.actor,failed.world) and not failed.actor:IsActorBeingDestroyed() then failed.actor:K2_DestroyActor() end
            end)
        end
        removeTag()
        if world(selectedBell) then
            local sphere=selectedBell.InteractionComp
            if world(sphere) and handled[sphere:GetAddress()]~=nil then
                local originalMode,ownedWorld=handled[sphere:GetAddress()],worldId
                undo(function() if inWorld(sphere,ownedWorld) then sphere:SetCollisionEnabled(originalMode) end end)
            end
        end
        log("calibration stopped without movement ownership: "..preparationError)
        return nil,"原生场景准备失败（玩家移动不受限制）："..preparationError
    end
    return a,b
end
function Arena.owns(actor)
    if not worldId then return false end
    return world(actor) and ((valid(selectedBell) and actor:GetAddress()==selectedBell:GetAddress())
        or (streaming and world(streaming.actor) and actor:GetAddress()==streaming.actor:GetAddress())) or false
end
function Arena.getBell() if worldId and world(selectedBell) then return selectedBell end end
function Arena.runtimeWorld(object)
    local actor=ownerActor(object)
    return actor and owningWorld(actor) or nil
end
return Arena
