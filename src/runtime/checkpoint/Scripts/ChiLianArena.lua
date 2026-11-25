-- The stock CA_03 reads BP_ChiLian_P2_Center.Arrow without an IsValid branch,
-- then uses its world position as SnapCenter at t=2.20045. Supply the ORIGINAL
-- targeting actors before this boss's BeginPlay; keep its ability/warp intact.
local SpawnClass=require('SpawnClass')
local SceneArena=require('SceneArena')
local Arena={}
local Session={};Session.__index=Session
local ROOT='/PBZCombatAsset/ActorData/Mobs/065_ChiLian_P2/'
local CENTER=ROOT..'BP_ChiLian_P2_Center.BP_ChiLian_P2_Center_C'
local SPAWNER=ROOT..'BP_ChiLian_CA_SnakeSpawner.BP_ChiLian_CA_SnakeSpawner_C'
local SNAKE=ROOT..'BP_Destructible_Snake.BP_Destructible_Snake_C'
local CLASS_PATHS={CENTER,SPAWNER,SNAKE}
local NO_COLOR={R=0,G=0,B=0,A=0}
-- Authored Fujizhilin layout relative to its native center (18374.66,153126.94).
-- Preserve the inward-facing rotations and proportions; raycast local ground.
local OFFSETS={
 {X=1831.137,Y=-1615.61,Yaw=140},
 {X=1579.465,Y=2099.62,Yaw=-125},
 {X=-2310.34,Y=1659.22,Yaw=-35},
 {X=-2567.745,Y=-1577.06,Yaw=30},
}
local function valid(v)return v~=nil and v:IsValid()end
local function same(a,b)return valid(a)and valid(b)and a:GetAddress()==b:GetAddress()end
local inWorld=SceneArena.actorIsInWorld
local function copy(v)return{X=v.X,Y=v.Y,Z=v.Z}end
local function distance(a,b)return(a.X-b.X)^2+(a.Y-b.Y)^2+(a.Z-b.Z)^2 end
local function required(path)local v=StaticFindObject(path);assert(valid(v),'白赤练场地接口未就绪：'..path);return v end
local function log(s)print('[PBZChiLianArena] '..s..'\n')end

function Arena.required(entry)return entry and entry.id=='BP_Monster_ChiLian_P2'end
function Arena.preloadPaths(entry)
 if Arena.required(entry) then return CLASS_PATHS end
end

local function authoredLayout(pawn,system,ground,yaw)
 local radians=yaw*math.pi/180;local c,s=math.cos(radians),math.sin(radians)
 for _,scale in ipairs({1,.8,.6})do
  local points={};local ready=true
  for _,o in ipairs(OFFSETS)do
   local x=ground.X+(o.X*c-o.Y*s)*scale
   local y=ground.Y+(o.X*s+o.Y*c)*scale
   local hit={}
   local found=system:LineTraceSingle(pawn,{X=x,Y=y,Z=ground.Z+500},{X=x,Y=y,Z=ground.Z-500},
     0,false,{},0,hit,true,NO_COLOR,NO_COLOR,0)
   if not found or not hit.ImpactPoint or not hit.ImpactNormal or hit.ImpactNormal.Z<.7 then ready=false;break end
   local p=copy(hit.ImpactPoint) -- copy native OutHit before another native call
   if math.abs(p.Z-ground.Z)>150 then ready=false;break end
   points[#points+1]={location={X=p.X,Y=p.Y,Z=p.Z+2},yaw=yaw+o.Yaw}
  end
  if ready then return points,scale end
 end
 return nil,'白赤练召蛇定位点尚未找到完整地面'
end

local function tracedFloor(pawn,system,x,y,height)
 local hit={}
 local found=system:LineTraceSingle(pawn,{X=x,Y=y,Z=height+500},{X=x,Y=y,Z=height-500},
  0,false,{},0,hit,true,NO_COLOR,NO_COLOR,0)
 if not found or not hit.ImpactPoint or not hit.ImpactNormal or hit.ImpactNormal.Z<.7 then return end
 local p=copy(hit.ImpactPoint)
 if math.abs(p.Z-height)>150 then return end
 return p
end

local function blocked(pawn,system,a,b)
 return system:LineTraceSingle(pawn,a,b,0,false,{},0,{},true,NO_COLOR,NO_COLOR,0)==true
end

local function walkableApproach(pawn,system,home,target)
 local dx,dy=target.X-home.X,target.Y-home.Y
 local length=math.sqrt(dx*dx+dy*dy)
 if length<250 then return false end
 local steps=math.ceil(length/200)
 local sideX,sideY=-dy/length*80,dx/length*80
 -- A floor beneath a marker does not prove that the player can reach it.
 -- Sample a player-width corridor and test body-height obstruction across it.
 for _,side in ipairs({0,-1,1})do
  local previous
  for i=0,steps do
   local t=i/steps
   local floor=tracedFloor(pawn,system,home.X+dx*t+sideX*side,home.Y+dy*t+sideY*side,home.Z)
   if not floor or(previous and math.abs(floor.Z-previous.Z)>60)then return false end
   if previous and blocked(pawn,system,{X=previous.X,Y=previous.Y,Z=previous.Z+95},
      {X=floor.X,Y=floor.Y,Z=floor.Z+95})then return false end
   previous=floor
  end
 end
 -- Keep the attackable snake capsule out of roofs/low props at the endpoint.
 if blocked(pawn,system,{X=target.X,Y=target.Y,Z=target.Z+20},
    {X=target.X,Y=target.Y,Z=target.Z+450})then return false end
 return true
end

-- Native TargetPoint17, located in the courtyard BETWEEN house and bell.
-- The old six-spawn bounding box includes the house and is not a play-area map.
local COURTYARD_CENTER={X=-193003.6,Y=-115937.52}
local COURTYARD_OUTLINE={
 {X=-190687.946,Y=-118757.902},
 {X=-190421.867,Y=-117982.633},
 {X=-190379.935,Y=-117646.575},
 {X=-190442.381,Y=-116641.444},
 {X=-190718.679,Y=-115679.771},
 {X=-190981.256,Y=-114894.256},
 {X=-191966.884,Y=-114160.660},
 {X=-192368.735,Y=-113460.515},
 {X=-193100.913,Y=-113422.814},
 {X=-193540.054,Y=-114232.220},
 {X=-194411.155,Y=-114837.428},
 {X=-195191.154,Y=-115648.645},
 {X=-195421.054,Y=-116737.275},
 {X=-195550.799,Y=-117582.219},
 {X=-195479.398,Y=-118218.211},
 {X=-195079.354,Y=-118800.514},
 {X=-194230.686,Y=-119010.490},
 {X=-192269.439,Y=-118920.207},
}

local function courtyardContains(p,margin)
 -- A conservative house-side guard, NOT a claimed mesh hull. The real Pawn
 -- capsule sweeps below additionally test structures that block player movement.
 if p.Y<=-117300 then return false end
 local inside=false;local minimum=math.huge
 local previous=COURTYARD_OUTLINE[#COURTYARD_OUTLINE]
 for _,point in ipairs(COURTYARD_OUTLINE)do
  if(point.Y>p.Y)~=(previous.Y>p.Y)and p.X<(previous.X-point.X)*(p.Y-point.Y)/(previous.Y-point.Y)+point.X then inside=not inside end
  local dx,dy=point.X-previous.X,point.Y-previous.Y
  local t=math.max(0,math.min(1,((p.X-previous.X)*dx+(p.Y-previous.Y)*dy)/(dx*dx+dy*dy)))
  local x,y=previous.X+dx*t,previous.Y+dy*t
  minimum=math.min(minimum,(p.X-x)^2+(p.Y-y)^2)
  previous=point
 end
 return inside and minimum>=(margin or 200)^2
end


local function nightLayout(pawn,system,ground,scene,mathLibrary)
 -- These exact courtyard coordinates passed the R4 gameplay layout test.
 -- Do not gate the fight on a straight line from the bell-side player spawn:
 -- that line crosses the bell itself and was repeatedly rejecting a good arena.
 local home=tracedFloor(pawn,system,COURTYARD_CENTER.X,COURTYARD_CENTER.Y,ground.Z)
 if not home or not courtyardContains(home,200)then return nil,'屋前空地中心的地面尚未就绪' end
 local points={}
 for _,quadrant in ipairs({{1,-1},{1,1},{-1,1},{-1,-1}})do
  local floor=tracedFloor(pawn,system,home.X+quadrant[1]*1100,home.Y+quadrant[2]*1000,home.Z)
  if not floor or not courtyardContains(floor,200)then return nil,'屋前固定召蛇点的地面尚未就绪' end
  -- Bounded, one-time preparation: 5 down-rays + 4 endpoint headroom rays
  -- + 8 body-height rays. No capsule sweeps, player-entry path or full-map scan.
  for _,height in ipairs({90,180})do
   if blocked(pawn,system,{X=home.X,Y=home.Y,Z=home.Z+height},
      {X=floor.X,Y=floor.Y,Z=floor.Z+height})then return nil,'屋前固定召蛇通路存在阻挡' end
  end
  if blocked(pawn,system,{X=floor.X,Y=floor.Y,Z=floor.Z+20},
    {X=floor.X,Y=floor.Y,Z=floor.Z+450})then return nil,'屋前固定召蛇点上方存在阻挡' end
  points[#points+1]={location={X=floor.X,Y=floor.Y,Z=floor.Z+2},yaw=mathLibrary:FindLookAtRotation(floor,home).Yaw}
 end
 return points,1,home,{minX=home.X-1100,maxX=home.X+1100,minY=home.Y-1000,maxY=home.Y+1000},1
end

local function sceneLayout(pawn,system,ground,scene,mathLibrary)
 local placement=scene.chiLianUltimate
 local home=tracedFloor(pawn,system,placement.center.X,placement.center.Y,ground.Z)
 if not home then return nil,scene.name..'的召蛇中心地面尚未就绪' end
 -- Keep alternate points within the four authored corners for this scene.
 for _,scale in ipairs({1,.8,.6})do
  local points={}
  for _,point in ipairs(placement.snakes)do
   local x=home.X+(point.X-home.X)*scale
   local y=home.Y+(point.Y-home.Y)*scale
   local floor=tracedFloor(pawn,system,x,y,home.Z)
   if not floor then break end
   points[#points+1]={location={X=floor.X,Y=floor.Y,Z=floor.Z+2},yaw=mathLibrary:FindLookAtRotation(floor,home).Yaw}
  end
  if #points==#placement.snakes then return points,scale,home end
 end
 return nil,scene.name..'尚未找到完整的召蛇地面'
end

local function layout(pawn,system,ground,yaw,scene,mathLibrary)
 if scene.id=='night'then return nightLayout(pawn,system,ground,scene,mathLibrary)end
 if scene.chiLianUltimate then return sceneLayout(pawn,system,ground,scene,mathLibrary)end
 local points,scale=authoredLayout(pawn,system,ground,yaw)
 return points,scale,ground
end

local function markerConflict(self)
 -- The stock skill looks up the center in the entire running world.
 for _,class in ipairs(self.markerClasses)do
  for _,actor in ipairs(SceneArena.actorsOfClass(self.gameplay,self.pawn,self.world,class))do
   if not same(self.owned[actor:GetAddress()],actor)then
    return '本场已有其他白赤练中心点或召蛇点'
   end
  end
 end
end

function Arena.new(pawn,gameplay,system,ground,rotation,scene)
 assert(scene and(scene.id=='night'or scene.id=='lake'or scene.chiLianUltimate),'白赤练场地不受支持')
 local classes={}
 for _,path in ipairs(CLASS_PATHS)do
  local cls,reason=SpawnClass.resolve(path)
  if not valid(cls)then return nil,reason end
  classes[path]=cls
 end
 local world=SceneArena.runtimeWorld(pawn)
 if not valid(world)then return nil,'等待白赤练场地所属关卡' end
 local self=setmetatable({pawn=pawn,gameplay=gameplay,world=world,actors={},owned={},spawners={},snakes={},
   markerClasses={classes[CENTER],classes[SPAWNER]},snakeClass=classes[SNAKE],closed=false,nextAt=0},Session)
 local conflict=markerConflict(self)
 if conflict then return nil,conflict end
 local mathLibrary=required('/Script/Engine.Default__KismetMathLibrary')
 local points,scale,home,bounds,scaleY=layout(pawn,system,ground,rotation.Yaw,scene,mathLibrary)
 -- The lake's default snake positions depend on this boss candidate's location and yaw.
 if not points then return nil,scale,scene.id=='lake' and not scene.chiLianUltimate end
 self.centerPosition,self.bounds={X=home.X,Y=home.Y,Z=home.Z+2},bounds
 local spawnLibrary=required('/Script/SGameAI.Default__SGameAIFunctionLibrary')
 local function spawn(cls,position,yaw)
  local transform=mathLibrary:MakeTransform(position,{Pitch=0,Yaw=yaw,Roll=0},{X=1,Y=1,Z=1})
  local actor=spawnLibrary:SpawnActorDeferred(pawn,cls,transform,1)
  assert(valid(actor),'白赤练定位对象创建失败')
  self.actors[#self.actors+1]=actor -- record before construction/BeginPlay
  self.owned[actor:GetAddress()]=actor
  actor:SetOwner(pawn)
  gameplay:FinishSpawningActor(actor,transform,1) -- original BP registers targeting interface itself
  assert(inWorld(actor,world)and same(actor:GetOwner(),pawn),'白赤练定位点归属校验失败')
  actor:SetActorEnableCollision(false);actor:SetActorHiddenInGame(true)
  local placed=copy(actor.Arrow:K2_GetComponentLocation())
  assert(distance(placed,position)<4,'白赤练原版定位组件位置不一致')
  return actor
 end
 local ok,failure=pcall(function()
  -- Four limb/snake points first, neck/center last, matching the original BP's
  -- native targeting enumeration and wire initialization before boss BeginPlay.
  for _,point in ipairs(points)do self.spawners[#self.spawners+1]=spawn(classes[SPAWNER],point.location,point.yaw)end
  self.center=spawn(classes[CENTER],self.centerPosition,rotation.Yaw)
  local resolved=gameplay:GetActorOfClass(pawn,classes[CENTER])
  assert(same(resolved,self.center),'原版查找中心点未指向本场白赤练')
  local conflict=markerConflict(self)
  assert(not conflict,conflict)
 end)
 if not ok then self:close();error(failure,0)end
 log(('original center+4 snake markers ready at %.1f %.1f %.1f; layout scale=%.2f')
  :format(self.centerPosition.X,self.centerPosition.Y,self.centerPosition.Z,scale))
 if bounds then
  log(('night authored courtyard; X=%.1f..%.1f; Y=%.1f..%.1f; scaleXY=%.2f,%.2f')
   :format(bounds.minX,bounds.maxX,bounds.minY,bounds.maxY,scale,scaleY))
  for i,point in ipairs(points)do log(('night snake %d at %.1f %.1f %.1f; yaw=%.1f')
   :format(i,point.location.X,point.location.Y,point.location.Z,point.yaw))end
 elseif scene.chiLianUltimate then
  for i,point in ipairs(points)do log(('%s snake %d at %.1f %.1f %.1f; yaw=%.1f')
   :format(scene.id,i,point.location.X,point.location.Y,point.location.Z,point.yaw))end
 end
 return self
end

function Session:bind(actor)
 assert(not self.closed and inWorld(actor,self.world),'白赤练本场角色身份不匹配')
 self.boss=actor
end

function Session:update(pawn,now)
 assert(not self.closed and same(pawn,self.pawn)and inWorld(pawn,self.world),'白赤练场景已切换')
 if now<self.nextAt then return end
 self.nextAt=now+.5
 assert(inWorld(self.center,self.world)and same(self.center:GetOwner(),self.pawn),'白赤练原版中心点已失效')
 for _,actor in ipairs(self.spawners)do
  assert(inWorld(actor,self.world)and same(actor:GetOwner(),self.pawn),'白赤练原版召蛇定位点已失效')
 end
 local conflict=markerConflict(self)
 assert(not conflict,conflict)
 if valid(self.boss)and valid(self.boss.Mesh)then
  local anim=self.boss.Mesh:GetAnimInstance()
  local montage=valid(anim)and anim:GetCurrentActiveMontage()or nil
  local name=valid(montage)and montage:GetFName():ToString()or''
  if name~=self.lastMontage and name:find('ChiLian_P2_CA_03',1,true)then
   local p=copy(self.boss:K2_GetActorLocation())
   log(('CA03 active; boss=%.1f %.1f %.1f; SnapCenter=%.1f %.1f %.1f')
    :format(p.X,p.Y,p.Z,self.centerPosition.X,self.centerPosition.Y,self.centerPosition.Z))
  end
  self.lastMontage=name
 end
end

function Session:owns(actor)
 if not inWorld(actor,self.world)then return false end
 local address=actor:GetAddress()
 return same(self.owned[address],actor)or same(self.snakes[address],actor)
end

function Session:close()
 if self.closed then return end
 -- Native SnakeActor has no owner link. Collect from ONLY our original helper
 -- properties before despawn/destruction; no class-wide or proximity deletion.
 for _,spawner in ipairs(self.spawners)do
  if inWorld(spawner,self.world)then
   local snake=spawner.SnakeActor
   if valid(snake)and snake:IsA(self.snakeClass)and inWorld(snake,self.world)then self.snakes[snake:GetAddress()]=snake end
  end
 end
 local failures={}
 local function attempt(action)
  local ok,why=pcall(action)
  if not ok then failures[#failures+1]=tostring(why)end
 end
 -- Collect ALL children first, then attempt every cleanup even if one native
 -- callback fails. A first-helper error must not orphan the other three snakes.
 for _,spawner in ipairs(self.spawners)do
  if inWorld(spawner,self.world)then attempt(function()spawner:DespawnSnake()end)end
 end
 if inWorld(self.boss,self.world)then attempt(function()self.boss:DeactivateWires()end)end
 for _,snake in pairs(self.snakes)do if inWorld(snake,self.world)then attempt(function()snake:K2_DestroyActor()end)end end
 -- Reverse creation order so the native center unregisters first.
 for i=#self.actors,1,-1 do local actor=self.actors[i]
  if inWorld(actor,self.world)then attempt(function()actor:K2_DestroyActor()end)end
 end
 assert(#failures==0,table.concat(failures,'; ')) -- caller retains this session for retry
 self.closed=true
 log('owned original center, snake markers and current summoned snakes released')
end
return Arena
