-- Player-only no-damage mode. The original infinite GE at level 100 makes
-- Health_Min = Health_Max (0.01 * LinearMin001(100)); this is a native clamp
-- before death, not polling health back after a hit. It does not modify
-- Invulnerable, Poise, Deflect, Shachi or character level.
local Guard={};Guard.__index=Guard
local EFFECT='/PBZCombatAsset/Prototypes/GameplayEffects/GE_LockHealthButCanExecuted.GE_LockHealthButCanExecuted_C'
local LIB='/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary'
local TAG_LIB='/Script/ProjectPBZ.Default__PBZAbilityBlueprintLibrary'
local EXECUTE='CharacterState.CanNotBeExecuted'
local PENDING=0x08023600
local readyAddress,fullHealthReady
local function valid(v)return v~=nil and v:IsValid()end
local function finite(v)return type(v)=='number'and v>-math.huge and v<math.huge end
local function world(v)local w=valid(v)and v:GetWorld();return valid(w)and w:GetAddress()or nil end
local function required(path)local v=StaticFindObject(path);assert(valid(v),'missing no-damage interface: '..path);return v end
local function readPlayer(pawn)
 -- The player does not implement the NPC IsAlive function used by Health.lua.
 -- On this UE4SS build, a missing reflected function is a TrivialObject (not
 -- callable). Use only the player's verified ASC tag and native attributes.
 assert(valid(pawn),'no-damage player is unavailable')
 local asc,attributes=pawn.AbilitySystemComponent,pawn.AttributeSetBase
 assert(valid(asc)and valid(attributes),'no-damage player attributes are unavailable')
 local hp,maximum=attributes.Health.CurrentValue,attributes.Health_Max.CurrentValue
 assert(finite(hp)and finite(maximum)and maximum>0,'no-damage player health is not initialized')
 local dead=hp<=0 or asc:GetGameplayTagCount({TagName=FName('CharacterState.Dead')})>0
 return hp,maximum,dead
end
local function source()
 local e=StaticFindObject(EFFECT)
 if not valid(e)or readyAddress~=e:GetAddress()or e:HasAnyFlags(PENDING)then
  local complete=false
  for _,path in ipairs({EFFECT,(EFFECT:gsub('_C$',''))})do
   local ok,asset,_,didLoad=pcall(LoadAsset,path)
   if ok and didLoad==true and valid(asset)then complete=true;break end
  end
  assert(complete,'original no-damage health-floor package is unavailable')
  e=StaticFindObject(EFFECT)
 end
 assert(valid(e)and not e:HasAnyFlags(PENDING),'original no-damage effect is not ready')
 local cdo=e:GetCDO();assert(valid(cdo)and not cdo:HasAnyFlags(PENDING),'original no-damage defaults are not ready')
 readyAddress=e:GetAddress();return e
end
local function prepareFullHealth()
 local path='/Game/PBZContent/Blueprint/Item/GameplayEffect/GE_RegenFullHealth.GE_RegenFullHealth_C'
 local effect=StaticFindObject(path)
 if not valid(effect)or fullHealthReady~=effect:GetAddress()or effect:HasAnyFlags(PENDING)then
  local complete=false
  for _,name in ipairs({path,(path:gsub('_C$',''))})do
   local ok,asset,_,didLoad=pcall(LoadAsset,name)
   if ok and didLoad==true and valid(asset)then complete=true;break end
  end
  assert(complete,'initial full-health package is unavailable')
  effect=StaticFindObject(path)
 end
 assert(valid(effect)and not effect:HasAnyFlags(PENDING),'initial full-health class is not ready')
 local cdo=effect:GetCDO()
 assert(valid(cdo)and not cdo:HasAnyFlags(PENDING),'initial full-health defaults are not ready')
 fullHealthReady=effect:GetAddress()
 return effect
end
function Guard.new(pawn)
 assert(valid(pawn)and world(pawn),'no-damage player is unavailable')
 local asc=pawn.AbilitySystemComponent;assert(valid(asc),'no-damage ability system is unavailable')
 return setmetatable({pawn=pawn,pawnAddress=pawn:GetAddress(),world=world(pawn),asc=asc,ascAddress=asc:GetAddress()},Guard)
end
function Guard:owns()
 return valid(self.pawn)and self.pawn:GetAddress()==self.pawnAddress and world(self.pawn)==self.world
  and valid(self.asc)and valid(self.pawn.AbilitySystemComponent)
  and self.pawn.AbilitySystemComponent:GetAddress()==self.ascAddress
end
function Guard:active()
 if not self:owns()or not self.handle then return false end
 local owner=required(LIB):GetAbilitySystemComponentFromActiveGameplayEffectHandle(self.handle)
 if not valid(owner)then return false end
 assert(owner:GetAddress()==self.ascAddress,'no-damage handle belongs to another ability system')
 return required(LIB):IsActiveGameplayEffectHandleActive(self.handle)==true
end
function Guard:enable()
 assert(not self.closed and self:owns(),'no-damage player identity changed')
 local hp,maximum,dead=readPlayer(self.pawn)
 assert(not dead and hp and maximum,'no-damage cannot activate on a dead player')
 if not self.executionOwned then
  local tag={TagName=FName(EXECUTE)}
  local before=self.asc:GetGameplayTagCount(tag)
  assert(required(TAG_LIB):AddLooseGameplayTag(self.pawn,tag,false)==true,'no-damage execution guard failed')
  self.executionOwned,self.executionTag=true,tag -- retain before verification
  assert(self.asc:GetGameplayTagCount(tag)==before+1,'no-damage execution guard readback failed')
 end
 if not self:active()then
  self.handle=nil
  local value=self.asc:BP_ApplyGameplayEffectToSelf(source(),100.0,{})
  assert(value and type(value.Handle)=='number'and value.Handle>=0 and value.Handle%1==0,'invalid no-damage effect handle')
  self.handle={Handle=value.Handle,bPassedFiltersAndWasExecuted=value.bPassedFiltersAndWasExecuted==true}
  assert(self:active(),'native no-damage floor was not activated')
 end
 local a=self.pawn.AttributeSetBase
 assert(valid(a)and type(a.Health_Min.CurrentValue)=='number'
   and a.Health_Min.CurrentValue>=a.Health_Max.CurrentValue-.01,'native no-damage floor is below maximum health')
 if not self.initialized then
  -- One explicit full-health initialization only. Afterwards all damage is
  -- handled by the infinite native floor; update never restores player HP.
  hp,maximum,dead=readPlayer(self.pawn)
  assert(not dead and hp,'no-damage player died while activating')
  if maximum-hp>.01 then
   local effect=prepareFullHealth()
   assert(self:owns(),'no-damage player changed during initial full-health setup')
   -- Apply the ready original instant GE directly. Calling Health.restore here
   -- would re-enter its NPC IsAlive path even after a player-specific read.
   self.asc:BP_ApplyGameplayEffectToSelf(effect,1.0,{})
   local restored,currentMax,nowDead=readPlayer(self.pawn)
   assert(not nowDead and currentMax-restored<=.01,'initial no-damage full-health setup failed')
  end
  self.initialized=true
  print('[PBZTestArenaNative] Practice no-damage: one-time full-health initialization; native floor=maximum, normal hit reaction retained\n')
 end
 return true
end
function Guard:close()
 if self.closed then return end
 local errors={}
 if self:active()then
  local ok,why=pcall(function()
   assert(self.asc:RemoveActiveGameplayEffect(self.handle,-1)==true,'owned no-damage floor could not be removed')
   assert(not self:active(),'owned no-damage floor remained active')
  end)
  if ok then self.handle=nil else errors[#errors+1]=tostring(why)end
 else self.handle=nil end
 if self.executionOwned then
  if self:owns()then
   local ok,why=pcall(function()
    assert(required(TAG_LIB):RemoveLooseGameplayTag(self.pawn,self.executionTag,false)==true,'owned no-damage execution count could not be removed')
   end)
   if ok then self.executionOwned,self.executionTag=false,nil else errors[#errors+1]=tostring(why)end
  else self.executionOwned,self.executionTag=false,nil end
 end
 assert(#errors==0,table.concat(errors,'; '))
 self.closed=true
end
return Guard
