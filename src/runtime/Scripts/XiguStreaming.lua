-- Preserve the stock streaming ranges for the arena and scenery. Only
-- exclude the four audited detail grids below the encounter's elevation.
local SceneArena = require("SceneArena")
local Streaming = {}
local rule = {
    count = 35,
    min = { X=-4200, Y=279500, Z=1996300 },
    max = { X=9500, Y=297500, Z=2003500 },
    -- The nonempty grids end below Z=146136 cm on the audited build.
    cells = { Fix512=14, Fix1024=90, Fix2048=0, Fix3072=12 },
}
local GRID_NAMES = {"Fix512", "Fix1024", "Fix2048", "Fix3072"}
local GRID_RANGES = { Fix512=51200, Fix1024=102400, Fix2048=204800, Fix3072=307200 }
local KEEP_WORLD, ACTIVATED, EXCLUDE = 1, 1, 1
local state

local function log(message) print("[PBZXiguStreaming] " .. message .. "\n") end
local function valid(v) return v and v:IsValid() end
local function same(a,b) return valid(a) and valid(b) and a:GetAddress() == b:GetAddress() end
local function required(path)
    local value = StaticFindObject(path)
    assert(valid(value), "missing " .. path)
    return value
end

local function inArena(p)
    return p and p.X >= rule.min.X and p.X <= rule.max.X
        and p.Y >= rule.min.Y and p.Y <= rule.max.Y
        and p.Z >= rule.min.Z and p.Z <= rule.max.Z
end

local function xyDistanceSquared(a,b) return (a.X-b.X)^2+(a.Y-b.Y)^2 end
local function playerSource(controller)
    local position, rotation = {}, {}
    controller:GetStreamingSourceLocationAndRotation(position,rotation)
    assert(type(position.X)=="number" and type(position.Y)=="number" and type(position.Z)=="number",
        "native player streaming location unavailable")
    return position, rotation
end

local function checkedGrids(world)
    local settings=world:K2_GetWorldSettings()
    assert(valid(settings),"private world settings unavailable")
    local partition=settings.WorldPartition
    assert(valid(partition) and same(partition:GetOuter(),settings),"unexpected world partition owner")
    local hash=partition.RuntimeHash
    assert(valid(hash) and same(hash:GetOuter(),partition)
        and hash:GetClass():GetFName():ToString()=="WorldPartitionRuntimeHashSet","unexpected runtime hash")
    local grids=hash.RuntimeStreamingData
    assert(#grids==rule.count,"unexpected runtime grid count")
    local indices={}
    for i=1,#grids do
        local grid=grids[i]
        local name=grid.Name:ToString()
        if rule.cells[name] then
            local cells=grid.SpatiallyLoadedCells
            assert(not indices[name] and grid.LoadingRange==GRID_RANGES[name] and #cells==rule.cells[name],
                "unexpected runtime grid " .. name)
            for k=1,#cells do
                local cell=cells[k]
                assert(valid(cell) and cell.bIsSpatiallyLoaded==true and cell.bIsHLOD==false
                    and cell.bIsCustomHLODPlaceholderCell==false,"unexpected spatial cell in " .. name)
            end
            indices[name]=i
        end
    end
    for _,name in ipairs(GRID_NAMES) do assert(indices[name],"missing grid " .. name) end
    return hash,indices
end

local function sample(tx,label,position)
    local ok,loaded,visible=pcall(function()
        local loaded,visible=0,0
        local grids=tx.hash.RuntimeStreamingData
        for _,name in ipairs(GRID_NAMES) do
            local cells=grids[tx.indices[name]].SpatiallyLoadedCells
            for i=1,#cells do
                local level=cells[i].LevelStreaming
                if valid(level) then
                    if level:IsLevelLoaded() then loaded=loaded+1 end
                    if level:IsLevelVisible() then visible=visible+1 end
                end
            end
        end
        return loaded,visible
    end)
    if not ok then log("residency read unavailable: " .. tostring(loaded)); return end
    local line=("%s selected-grid residency loaded=%d visible=%d"):format(label,loaded,visible)
    if label=="before" then tx.baseline={loaded=loaded,visible=visible,position=position} end
    if label=="after" and tx.baseline then
        local movement=math.sqrt(xyDistanceSquared(tx.baseline.position,position))/100
        line=line..(" fewerLoaded=%d fewerVisible=%d playerSourceDriftM=%.1f comparison=%s"):format(
            tx.baseline.loaded-loaded,tx.baseline.visible-visible,movement,movement<=4 and "nearby" or "moved")
    end
    log(line)
end

local function spawn(tx,gameplay,pawn,position,rotation,priority)
    local mathLibrary=required("/Script/Engine.Default__KismetMathLibrary")
    local class=required("/Script/ProjectPBZ.EventpipelineStreamingSource")
    local componentClass=required("/Script/Engine.WorldPartitionStreamingSourceComponent")
    local transform=mathLibrary:MakeTransform(position,rotation,{X=1,Y=1,Z=1})
    local actor=gameplay:BeginDeferredActorSpawnFromClass(pawn,class,transform,1,nil,1)
    assert(valid(actor),"could not create private streaming source")
    local owned={actor=actor}
    tx.source=owned
    assert(same(SceneArena.runtimeWorld(actor),tx.world),"streaming source belongs to another world")
    assert(same(gameplay:FinishSpawningActor(actor,transform,1),actor),"could not finish streaming source")
    local component=actor:GetComponentByClass(componentClass)
    assert(valid(component),"native streaming component missing")
    owned.component=component
    component:DisableStreamingSource()
    assert(#component.TargetGrids==0 and #component.Shapes==0 and component.TargetState==ACTIVATED,
        "unexpected native streaming component defaults")
    assert(actor:K2_AttachToActor(pawn,FName("None"),KEEP_WORLD,KEEP_WORLD,KEEP_WORLD,false)
        and same(actor:GetAttachParentActor(),pawn),"could not attach player streaming source")
    local actual=actor:K2_GetActorLocation()
    assert(xyDistanceSquared(actual,position)<=4 and math.abs(actual.Z-position.Z)<=2,"native source location mismatch")
    local targetGrids=component.TargetGrids
    for index,name in ipairs(GRID_NAMES) do targetGrids[index]=FName(name) end
    component.TargetBehavior=EXCLUDE
    component.Priority=priority
    assert(component.TargetBehavior==EXCLUDE and component.Priority==priority
        and #component.TargetGrids==#GRID_NAMES and #component.Shapes==0,"native source settings mismatch")
    for index,name in ipairs(GRID_NAMES) do
        assert(component.TargetGrids[index]:ToString()==name,"native target grid mismatch")
    end
    return component
end

local function restore(tx,reason)
    local active=tx.active
    tx.measureAt=nil
    if tx.playerDisabled and valid(tx.controller) then
        local ok,err=pcall(function()
            tx.controller.bEnableStreamingSource=true
            assert(tx.controller.bEnableStreamingSource==true,"native player source did not restore")
        end)
        if not ok then tx.restoreReason=reason; log("player restore: "..tostring(err)); return false end
    end
    tx.playerDisabled=nil
    local owned=tx.source
    if owned then
        local ok,err=pcall(function()
            if valid(owned.component) then owned.component:DisableStreamingSource() end
            if valid(owned.actor) and not owned.actor:IsActorBeingDestroyed() then owned.actor:K2_DestroyActor() end
        end)
        if not ok then tx.restoreReason=reason; log("source cleanup: "..tostring(err)); return false end
    end
    tx.source=nil
    tx.active,tx.restoreReason=false,nil
    if active then log("original player source restored (" .. reason .. ")") end
    return true
end

local function apply(tx,gameplay,pawn,now)
    local controller=tx.controller
    assert(controller.bEnableStreamingSource==true and controller:IsStreamingSourceEnabled()
        and controller:StreamingSourceShouldActivate() and #controller.StreamingSourceShapes==0,
        "original player source unavailable or uses custom shapes")
    local position,rotation=playerSource(controller)
    assert(inArena(position) and xyDistanceSquared(position,pawn:K2_GetActorLocation())<=40000,
        "native player source outside the arena pawn")
    local priority=controller.StreamingSourcePriority
    assert(type(priority)=="number" and priority>=0 and priority<=255,"native source priority unavailable")
    tx.hash,tx.indices=checkedGrids(tx.world)
    tx.baseline=nil
    sample(tx,"before",position)
    local component=spawn(tx,gameplay,pawn,position,rotation,priority)
    component:EnableStreamingSource()
    assert(component:IsStreamingSourceEnabled(),"replacement source did not enable")
    tx.playerDisabled=true
    controller.bEnableStreamingSource=false
    assert(not controller:IsStreamingSourceEnabled(),"original player source did not switch off")
    tx.active,tx.measureAt=true,now+12
    log("excluded the below-arena detail grids")
end

function Streaming.reset(reason)
    if state and not restore(state,reason) then return false end
    state=nil
    return true
end

function Streaming.toggle()
    if not state then return end
    state.wanted=not state.wanted
    state.failed=false
    state.applyAt=nil
    state.checkAt=0
    if not state.wanted then restore(state,"comparison baseline") end
    log(state.wanted and "detail grid exclusion requested" or "original streaming requested")
end

function Streaming.update(gameplay,world,pawn,controller,now,ready)
    if state and (not same(state.world,world) or not same(state.pawn,pawn)
        or not same(state.controller,controller)) then
        if not Streaming.reset("world or pawn changed") then return end
    end
    if state and now<state.checkAt then return end
    if not state and not ready then return end
    if not state then
        state={world=world,pawn=pawn,controller=controller,wanted=true,checkAt=0}
    end
    local tx=state
    tx.checkAt=now+0.75
    if tx.restoreReason then restore(tx,tx.restoreReason); return end
    if tx.active then
        local ok,reason=pcall(function()
            local position=playerSource(controller)
            assert(inArena(position) and same(controller:GetViewTarget(),pawn)
                and valid(tx.source.actor) and xyDistanceSquared(tx.source.actor:K2_GetActorLocation(),position)<=40000,
                "player source or view target left the audited arena")
            assert(not controller:IsStreamingSourceEnabled(),"original player provider was re-enabled")
            assert(valid(tx.source.component) and tx.source.component:IsStreamingSourceEnabled(),"replacement source stopped")
            if tx.measureAt and now>=tx.measureAt then tx.measureAt=nil; sample(tx,"after",position) end
        end)
        if not ok then
            restore(tx,"provider guard")
            tx.failed=true
            log("fallback: " .. tostring(reason))
        end
        return
    end
    if not ready or not tx.wanted or tx.failed then return end
    if not tx.applyAt then tx.applyAt=now+1; return end
    if now<tx.applyAt or not same(controller:GetViewTarget(),pawn) then return end
    local ok,reason=pcall(apply,tx,gameplay,pawn,now)
    if not ok then
        restore(tx,"apply failed")
        tx.failed=true
        log("original streaming retained: " .. tostring(reason))
    end
end

return Streaming
