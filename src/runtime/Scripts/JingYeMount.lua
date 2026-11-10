-- A private birth context for the original JingYe rider/horse blueprints.
-- AIScript_Rider.OnInitialize reads Pawn.GetAISpawner().GetTransform() before
-- creating its original horse spawner. A directly spawned rider has no source
-- spawner, causing the blueprint's access-none path to use the identity origin.
local SpawnClass=require('SpawnClass')
local CombatSpawn=require('CombatSpawn')
local Mount={}
local Session={};Session.__index=Session
local SPAWNER='/SGameAI/Tools/Spawner/BP_AISpawner.BP_AISpawner_C'
local HORSE='/PBZCombatAsset/ActorData/Mobs/045_JingYe/BP_Monster_Horse_JingYe.BP_Monster_Horse_JingYe_C'
local RIDER_SCRIPT='AIScript_Rider_C'
local function valid(v)return v~=nil and v:IsValid()end
local function same(a,b)return valid(a)and valid(b)and a:GetAddress()==b:GetAddress()end
local function required(path)local v=StaticFindObject(path);assert(valid(v),'荆野骑乘接口未就绪：'..path);return v end
local function vector(v)return{X=v.X,Y=v.Y,Z=v.Z}end
local function distance(a,b)return(a.X-b.X)^2+(a.Y-b.Y)^2+(a.Z-b.Z)^2 end
local function unwrap(v)local ok,r=pcall(function()return v:get()end);return ok and r or v end
local function log(s)print('[PBZJingYeMount] '..s..'\n')end
local function name(v)return type(v)=='string'and v or v:ToString()end
local function finite(v)return type(v)=='number'and v==v and v>-math.huge and v<math.huge end
local function copiedVector(v)
 local result={X=v.X,Y=v.Y,Z=v.Z}
 assert(finite(result.X)and finite(result.Y)and finite(result.Z),'registration vector is not finite')
 return result
end
local function className(v)return valid(v)and name(v:GetClass():GetFName())or'None'end
local function address(v)return valid(v)and v:GetAddress()or'None'end
local function registrationLog(self,kind,fields)
 if(self.registrationLogCount or 0)>=8 then return end
 self.registrationLogCount=(self.registrationLogCount or 0)+1
 local list={'target-registration '..kind}
 for _,field in ipairs(fields)do list[#list+1]=tostring(field):gsub('[\r\n\t]',' '):sub(1,256)end
 pcall(log,table.concat(list,'; '))
end
local function registrationContext(self)
 assert(valid(self.player)and valid(self.rider)and valid(self.horse),'owned registration actors unavailable')
 local world=self.player:GetWorld()
 assert(valid(world)and same(world,self.rider:GetWorld())and same(world,self.horse:GetWorld()),
  'registration actors belong to different worlds')
 assert(self.rider:IsAlive()and self.horse:IsAlive(),'registration rider or horse is dead')
 assert(self:owns(self.rider)and self:owns(self.horse),'registration actors are not owned')
 assert(valid(self.origin)and same(self.origin:GetOwner(),self.rider)
  and same(self.origin.SpawnedAI,self.rider)and same(self.rider:GetAISpawner(),self.origin),
  'registration rider origin ownership changed')
 assert(valid(self.vehicleSpawner)and same(self.horse:GetAISpawner(),self.vehicleSpawner)
  and(same(self.vehicleSpawner.SpawnedAI,self.horse)or(valid(self.script)and same(self.script.VehiclePawn,self.horse))),
  'registration horse spawner ownership changed')
 assert(valid(self.script)and same(self.script.Pawn,self.rider),'registration rider script ownership changed')
 return world:GetAddress()
end
function Session:readCombatPool(worldId)
 local output={self.player,self.player} -- valid AActor sentinels, not a guessed empty output
 local subsystem=required('/Script/Engine.Default__SubsystemBlueprintLibrary')
  :GetWorldSubsystem(self.player,required('/Script/SGameCombatSystem.TargetingWorldSubsystem'))
 assert(valid(subsystem),'targeting world subsystem unavailable')
 subsystem:GetTargetsByTag({TagName=FName('Targeting.Target.Combat')},true,output)
 local count=#output;assert(count<=1024,'combat target pool is unexpectedly large')
 local actors={};for index=1,count do actors[index]=unwrap(output[index])end
 local result={count=count,rider=false,horse=false,ready=false}
 local sentinel=count==2
 for index,actor in ipairs(actors)do
  assert(valid(actor),'combat pool contains an unreadable actor')
  local world=actor:GetWorld()
  assert(valid(world)and world:GetAddress()==worldId,'combat pool contains a foreign world actor')
  result.rider=result.rider or same(actor,self.rider)
  result.horse=result.horse or same(actor,self.horse)
  if not same(actor,self.player)then result.ready=true end
  sentinel=sentinel and same(actor,self.player)
 end
 if sentinel then result.ready=false;result.reason='output sentinels unchanged'
 elseif not result.ready then result.reason='no native pool positive-control'end
 return result
end
local function poolValue(pool,key)return pool and pool.ready and tostring(pool[key])or'unknown'end
local function readPrimary(rider)
 local output={}
 local found=required('/Script/SGameCombatSystem.Default__TargetingUtils')
  :GetPrimaryTargetingData(rider,{TagName=FName('Targeting.Target.Combat')},output)
 local component=output.Component
 local socket=output.SocketName and name(output.SocketName)or nil
 if found~=true or not valid(component)or not socket then return nil end
 return{Component=component,SocketName=FName(socket)},socket
end
local function poseFields(self)
 local fields={}
 local ok,failure=pcall(function()
  registrationContext(self)
  local driver=self.rider:GetDriverComponent()
  fields[#fields+1]='attached='..tostring(same(self.rider:GetAttachParentActor(),self.horse))
  fields[#fields+1]='waitingForAI='..tostring(self.script.WaitingForAIStart)
  fields[#fields+1]='drivingVehicle='..tostring(valid(driver)and address(driver.DrivingVehicle)or'None')
  fields[#fields+1]='seat='..(valid(driver)and name(driver.CurrentSeat)or'None')
  for _,item in ipairs({{'onHorse',self.rider,'CharacterState.AbilityState.JingYe.OnHorse'},
   {'unselectable',self.rider,'CharacterState.Unselectable'},
   {'keepLock',self.rider,'CharacterState.Unselectable.KeepLock'},
   {'dead',self.rider,'CharacterState.Dead'},
   {'findingLock',self.player,'CharacterState.Native.FindingLockTarget'},
   {'playerCombat',self.player,'CharacterState.InCombat'}})do
   local asc=item[2].AbilitySystemComponent;assert(valid(asc),'registration tag reader unavailable')
   fields[#fields+1]=item[1]..'='..asc:GetGameplayTagCount({TagName=FName(item[3])})
  end
  local targeting=self.player:GetTargetingComponent()
  assert(valid(targeting)and same(targeting:GetOwner(),self.player),'player targeting owner changed')
  fields[#fields+1]='defaultHandler='..className(targeting.DefaultTargetHandler)
  fields[#fields+1]='currentHandler='..className(targeting.CurrentHandler)
  -- There is no reflected disabled-handler collection; never invent or raw-read one.
  fields[#fields+1]='disabledHandlers=not-reflected'
  local locked={};targeting:GetLockTarget(locked)
  local lockedComponent=locked.Component
  local lockedSocket=locked.SocketName and name(locked.SocketName)or'None'
  fields[#fields+1]='lockOwner='..tostring(valid(lockedComponent)and address(lockedComponent:GetOwner())or'None')
  fields[#fields+1]='lockSocket='..lockedSocket
  local primary,socket=readPrimary(self.rider)
  fields[#fields+1]='primary='..tostring(primary~=nil)
  if not primary then return end
  assert(same(primary.Component:GetOwner(),self.rider),'primary target is not the owned rider')
  fields[#fields+1]='nativeValid='..tostring(targeting:IsTargetValid(
   {TagName=FName('Targeting.Validator.Combat.Default')},primary))
  fields[#fields+1]='faction='..tostring(required('/Script/SGameCombatSystem.Default__FactionUtils')
   :GetFactionRelation(self.player,self.rider))
  local camera=self.player.NBCamera
  assert(valid(camera)and same(camera:GetOwner(),self.player),'player camera owner changed')
  local cameraPosition=copiedVector(camera:GetCameraLocationWithCollisionTest())
  local rotation=camera:GetCameraRotation()
  local cameraYaw,cameraPitch=rotation.Yaw,rotation.Pitch -- copy before the next native call
  local point=copiedVector(primary.Component:GetSocketLocation(FName(socket)))
  local playerPosition=copiedVector(self.player:K2_GetActorLocation())
  local desired=required('/Script/Engine.Default__KismetMathLibrary'):FindLookAtRotation(cameraPosition,point)
  local yaw,pitch=desired.Yaw,desired.Pitch
  fields[#fields+1]=('distance=%.1f'):format(math.sqrt(distance(playerPosition,point)))
  fields[#fields+1]=('cameraYawDelta=%.1f'):format((yaw-cameraYaw+180)%360-180)
  fields[#fields+1]=('cameraPitchDelta=%.1f'):format((pitch-cameraPitch+180)%360-180)
 end)
 if not ok then fields[#fields+1]='poseRead='..tostring(failure)end
 return fields
end
function Session:ensureTargetRegistration()
 if self.closed or not self.ready or self.targetRegistrationObserved then return end
 if(self.registrationChecks or 0)>=8 then return end
 local now=self.gameplay:GetRealTimeSeconds(self.player)
 assert(finite(now),'target registration clock unavailable')
 if now<(self.nextRegistrationCheck or 0)then return end
 self.nextRegistrationCheck=now+1
 self.registrationChecks=(self.registrationChecks or 0)+1
 local worldId=registrationContext(self)
 local beforeOK,before=pcall(self.readCombatPool,self,worldId)
 if not beforeOK then before={ready=false,reason=tostring(before)}end
 local callback=false
 if not(before.ready and before.rider)and not self.targetCompletionAttempted then
  -- Native AddUnique semantics were audited. Complete the exact stock birth
  -- callback that context-only BP_AISpawner made BeginPlay wait for. It only
  -- registers THIS rider; do not invoke the full spawner or activate its AI.
  self.targetCompletionAttempted=true;callback=true
  local invoked,reason=pcall(function()self.rider:CompleteSpawnAI_Event(self.rider)end)
  if not invoked then self.targetCompletionError=tostring(reason)end
 end
 local after=before
 if callback then
  local afterOK,value=pcall(self.readCombatPool,self,worldId)
  after=afterOK and value or{ready=false,reason=tostring(value)}
 end
 if after.ready and after.rider then self.targetRegistrationObserved=true end
 local state=poolValue(before,'rider')..'/'..poolValue(before,'horse')..'/'..poolValue(after,'rider')..'/'..poolValue(after,'horse')
 if callback or self.registrationLastState~=state or self.registrationChecks==8 then
  self.registrationLastState=state
  local fields={'beforeRider='..poolValue(before,'rider'),'beforeHorse='..poolValue(before,'horse'),
   'afterRider='..poolValue(after,'rider'),'afterHorse='..poolValue(after,'horse'),
   'callbackInvoked='..tostring(callback),'outputCount='..tostring(after.count or'unknown')}
  if before.reason then fields[#fields+1]='beforeRead='..before.reason end
  if after.reason then fields[#fields+1]='afterRead='..after.reason end
  if self.targetCompletionError then fields[#fields+1]='callbackError='..self.targetCompletionError end
  for _,field in ipairs(poseFields(self))do fields[#fields+1]=field end
  registrationLog(self,self.targetRegistrationObserved and'verified'or'waiting',fields)
 end
end
local function maintainRegistration(self)
 local ok,reason=pcall(self.ensureTargetRegistration,self)
 if not ok and not self.registrationFailureLogged then
  self.registrationFailureLogged=true;registrationLog(self,'unavailable',{tostring(reason)})
 end
end
local function queueDrivePose(self)
 if(self.registrationLogCount or 0)>=8 then return end
 pcall(function()
  local now=self.gameplay:GetRealTimeSeconds(self.player)
  if finite(now)then self.registrationPoseAt=now+.25 end
 end)
end
local function maintainDrivePose(self)
 if not self.registrationPoseAt then return end
 -- Only the cheap real-time clock is polled during this bounded 0.25-second
 -- wait. The native pose/target queries run once, after native Drive settles.
 local ok,reason=pcall(function()
  local now=self.gameplay:GetRealTimeSeconds(self.player)
  if not finite(now)or now<self.registrationPoseAt then return end
  self.registrationPoseAt=nil
  registrationLog(self,'drive-state settled',poseFields(self))
 end)
 if not ok then self.registrationPoseAt=nil end
end

function Mount.required(entry)return entry and entry.id=='BP_Monster_JingYe'end

function Mount.new(pawn,gameplay,ground,rotation)
 local cls,reason=SpawnClass.resolve(SPAWNER)
 if not valid(cls)then return nil,reason end
 local horse,horseReason=SpawnClass.resolve(HORSE)
 if not valid(horse)then return nil,horseReason end -- warm the ORIGINAL horse before rider initialization
 local math=required('/Script/Engine.Default__KismetMathLibrary')
 local spawns=required('/Script/SGameAI.Default__SGameAIFunctionLibrary')
 local location={X=ground.X,Y=ground.Y,Z=ground.Z+6}
 local transform=math:MakeTransform(location,rotation,{X=1,Y=1,Z=1})
 local origin=spawns:SpawnActorDeferred(pawn,cls,transform,1)
 assert(valid(origin),'荆野出生生成器创建失败')
 local self=setmetatable({player=pawn,gameplay=gameplay,origin=origin,horseClass=horse,
  birth=location,owned={},ready=false,nextScan=0,closed=false},Session)
 local ok,failure=pcall(function()
  origin.InitialSpawn=false -- context only; never let this helper spawn an extra rider
  origin.SpawnInfo.bAutoStartAI=false
  gameplay:FinishSpawningActor(origin,transform,1)
  origin:SetActorEnableCollision(false);origin:SetActorHiddenInGame(true)
  local placed=vector(origin:K2_GetActorLocation())
  assert(distance(placed,location)<4,'荆野出生生成器位置回读不一致')
  self.owned[origin:GetAddress()]=origin
 end)
 if not ok then pcall(function()origin:K2_DestroyActor()end);error(failure,0)end
 return self
end

function Session:bind(rider)
 assert(not self.closed and valid(self.origin)and valid(rider),'荆野出生上下文已失效')
 self.rider=rider;self.owned[rider:GetAddress()]=rider
 -- Match BP_SGameAIFunctionLibrary.SpawnAIDefered BEFORE FinishActorSpawning.
 -- That original deferred path sets SpawnedAI + OnSpawnFromSpawner only;
 -- avoid passing a raw UObject through a TScriptInterface Lua setter.
 self.origin.SpawnedAI=rider
 rider:OnSpawnFromSpawner(self.origin)
 assert(same(rider:GetAISpawner(),self.origin),'荆野出生上下文绑定失败')
 self.origin:SetOwner(rider)
 log(('bound original spawner at %.1f %.1f %.1f'):format(self.birth.X,self.birth.Y,self.birth.Z))
end

function Session:findScript(now)
 if valid(self.script)and same(self.script.Pawn,self.rider)then return self.script end
 if not valid(self.rider)then return end
 local function candidate(v)
  return valid(v)and v:GetClass():GetFName():ToString()==RIDER_SCRIPT and same(v.Pawn,self.rider)
 end
 local list=self.rider.ExtraAIScripts.InstancedAIScripts
 for i=1,#list do local v=unwrap(list[i]);if candidate(v)then self.script=v;return v end end
 -- Some native AI initializers duplicate the instanced template. Scan this
 -- SMALL exact script class only while initial binding is pending, never Actor.
 if now>=self.nextScan then
  self.nextScan=now+.25
  for _,v in ipairs(FindAllOf(RIDER_SCRIPT)or{})do if candidate(v)then self.script=v;return v end end
 end
end

function Session:discover(now)
 local script=self:findScript(now)
 if not valid(script)then return false,'等待荆野原版骑乘脚本' end
 local spawner=script.VehicleSpawner
 if valid(spawner)then self.vehicleSpawner=spawner;self.owned[spawner:GetAddress()]=spawner end
 local horse=valid(spawner)and spawner.SpawnedAI or nil
 if not valid(horse)then horse=script.VehiclePawn end
 if not valid(horse)then return false,'等待荆野原版战马' end
 assert(horse:IsA(self.horseClass),'荆野骑乘脚本返回了其他单位')
 assert(valid(self.vehicleSpawner)and same(horse:GetAISpawner(),self.vehicleSpawner),'荆野战马生成器关系不匹配')
 self.horse=horse;self.owned[horse:GetAddress()]=horse
 if not self.ready then
  local p=vector(horse:K2_GetActorLocation())
  assert(distance(p,self.birth)<1500^2,'荆野战马未生成在当前场地，已停止接战')
  if not valid(horse:GetController())then return false,'等待荆野战马控制器' end
  CombatSpawn.challengeAI(horse,false)
  self.running=false;self.ready=true
  log(('original horse ready at %.1f %.1f %.1f; origin relation verified'):format(p.X,p.Y,p.Z))
 end
 return true
end

function Session:prepare(now)
 assert(not self.closed and valid(self.rider),'荆野出生过程中角色已离场')
 local ok,reason=self:discover(now)
 if ok then maintainRegistration(self)end -- never gate original horse spawning or AI on a Lua out-array bridge
 return ok,reason
end

function Session:update(running)
 if self.closed or not self.ready then return end
 -- The original rider controls attachment, damage redirection, hatred sharing
 -- and dismount/death. Only mirror the arena AI toggle onto our own mount.
 if valid(self.horse)and self.horse:IsAlive()and self.running~=running then
  CombatSpawn.challengeAI(self.horse,running)
  self.running=running
  queueDrivePose(self)
 end
 maintainRegistration(self)
 maintainDrivePose(self)
end

function Session:owns(actor)
 if not valid(actor)then return false end
 local v=self.owned[actor:GetAddress()]
 return same(v,actor)
end

function Session:close()
 if self.closed then return end
 self.registrationPoseAt=nil
 -- Retain native child handles before destroying the rider and its script.
 if valid(self.rider)then pcall(self.discover,self,math.huge)end
 if valid(self.vehicleSpawner)then self.vehicleSpawner:Despawn()end -- also cancels delayed native spawns
 if valid(self.rider)then self.rider:K2_DestroyActor()end
 if valid(self.horse)then self.horse:K2_DestroyActor()end
 if valid(self.vehicleSpawner)then self.vehicleSpawner:K2_DestroyActor()end
 if valid(self.origin)then self.origin:K2_DestroyActor()end
 self.closed=true;self.owned={}
end

return Mount
