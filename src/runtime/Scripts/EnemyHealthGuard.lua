-- Own exactly one original infinite health-floor effect per practice enemy.
-- Native Health_Min clamps lethal damage before death; polling HP afterwards
-- cannot provide this guarantee. Remove only our returned active effect handle.
local Guard = {}
Guard.__index = Guard
local EFFECT = "/PBZCombatAsset/ActorData/Mobs/077_LengTu/GameplayEffect/GE_LengTu_LockHealth.GE_LengTu_LockHealth_C"
local LIB = "/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary"
local PENDING = 0x08023600
local readyAddress
local function valid(v) return v ~= nil and v:IsValid() end
local function required(path)
    local v=StaticFindObject(path);assert(valid(v),"missing native health lock interface: "..path);return v
end
local function world(v)
    local w=valid(v)and v:GetWorld();return valid(w)and w:GetAddress()or nil
end
local function source()
    local effect=StaticFindObject(EFFECT)
    if not valid(effect)or readyAddress~=effect:GetAddress()or effect:HasAnyFlags(PENDING)then
        local complete=false
        for _,path in ipairs({EFFECT,(EFFECT:gsub("_C$",""))})do
            local loaded,asset,_,didLoad=pcall(LoadAsset,path)
            if loaded and didLoad==true and valid(asset)then complete=true;break end
        end
        assert(complete,"original health lock package is unavailable")
        effect=StaticFindObject(EFFECT)
    end
    assert(valid(effect)and not effect:HasAnyFlags(PENDING),"original health lock class is not ready")
    local cdo=effect:GetCDO()
    assert(valid(cdo)and not cdo:HasAnyFlags(PENDING),"original health lock defaults are not ready")
    readyAddress=effect:GetAddress();return effect
end
local function handleCopy(value)
    assert(value~=nil,"native health lock returned no effect handle")
    local id=value.Handle
    assert(type(id)=="number"and id>=0 and id%1==0,"native health lock returned an invalid effect handle")
    return {Handle=id,bPassedFiltersAndWasExecuted=value.bPassedFiltersAndWasExecuted==true}
end
function Guard.new(actor)
    assert(valid(actor)and world(actor),"practice health lock enemy is unavailable")
    local asc=actor.AbilitySystemComponent
    assert(valid(asc),"practice health lock ability system is unavailable")
    return setmetatable({actor=actor,actorAddress=actor:GetAddress(),world=world(actor),asc=asc,ascAddress=asc:GetAddress()},Guard)
end
function Guard:owns()
    return valid(self.actor)and self.actor:GetAddress()==self.actorAddress and world(self.actor)==self.world
        and valid(self.asc)and valid(self.actor.AbilitySystemComponent)
        and self.actor.AbilitySystemComponent:GetAddress()==self.ascAddress
end
function Guard:active()
    if not self:owns()or not self.handle then return false end
    local owner=required(LIB):GetAbilitySystemComponentFromActiveGameplayEffectHandle(self.handle)
    if not valid(owner)then return false end
    assert(owner:GetAddress()==self.ascAddress,"owned health lock handle belongs to another ability system")
    return required(LIB):IsActiveGameplayEffectHandleActive(self.handle)==true
end
function Guard:enable()
    assert(not self.closed and self:owns(),"practice health lock identity changed")
    if not self:active()then
        self.handle=nil
        self.handle=handleCopy(self.asc:BP_ApplyGameplayEffectToSelf(source(),1.0,{}))
        assert(self:active(),"native health lock was not activated")
    end
    local attributes=self.actor.AttributeSetBase
    assert(valid(attributes)and type(attributes.Health_Min.CurrentValue)=="number"
        and attributes.Health_Min.CurrentValue>0,"native health lock floor was not applied")
    assert(self.asc:GetGameplayTagCount({TagName=FName("CharacterState.CanNotBeExecuted")})>0,
        "native health lock execution guard was not applied")
    return true
end
function Guard:close()
    if self.closed then return end
    if self:active()then
        assert(self.asc:RemoveActiveGameplayEffect(self.handle,-1)==true,"owned health lock could not be removed")
        assert(not self:active(),"owned health lock remained active after removal")
    end
    self.handle,self.closed=nil,true
end
return Guard
