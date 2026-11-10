-- Separate buildup, native duration and consume-on-burst states. Read only.
local Clock=require("StatusEffectClock")
local Status={}
local DEFINITIONS={
    -- Positive frost accumulation drives chill/slow independently of the
    -- finite freeze effect. Never infer chill from the Frost parent tag.
    {id="chill",name="冰缓",field="Frost_Accumulation",maximum=true,tags={},color={R=.35,G=.90,B=.95,A=1}},
    {id="frost",name="冰冻",
        tags={"CharacterState.StatusInfliction.Frost.Effect"},color={R=.35,G=.77,B=1,A=1}},
    {id="ignite",name="火",field="Ignite_Accumulation",
        tags={"CharacterState.StatusInfliction.Ignite"},color={R=1,G=.38,B=.12,A=1}},
    {id="poison",name="毒",field="Poison_Accumulation",poison=true,
        tags={"CharacterState.StatusInfliction.Poison.Phase3","CharacterState.StatusInfliction.Poison.Phase2",
            "CharacterState.StatusInfliction.Poison.Phase1"},color={R=.49,G=.85,B=.30,A=1}},
    -- Small bleeding must not fill or hold the independent burst buildup.
    {id="bleed",name="流血",field="BloodBurst_Accumulation",maximum=true,tags={},color={R=.91,G=.16,B=.22,A=1}},
    {id="chaos",name="混沌火焰",tags={"CharacterState.StatusInfliction.Chaos"},color={R=.38,G=.30,B=.87,A=1}},
    {id="yinghen",name="莺痕",tags={"CharacterState.AbilityState.LuanYing.YingHen"},color={R=1,G=.67,B=.76,A=1}},
}
local YAO_COLOR={R=.78,G=.47,B=1,A=1}
local function finite(n)return type(n)=="number"and n==n and math.abs(n)<math.huge end
local function valid(o)return o~=nil and type(o.IsValid)=="function"and o:IsValid()end
local function unwrap(o)
    if o and type(o.IsValid)~="function"then local get=o.get or o.Get;if type(get)=="function"then return get(o)end end
    return o
end
local function text(n)return type(n)=="string"and n or n:ToString()end
local function attribute(set,name)
    if not name then return 0 end
    local ok,n=pcall(function()return set[name].CurrentValue end)
    return ok and finite(n)and math.max(0,n)or 0
end
local function charge(o)
    o=unwrap(o);if not valid(o)then return end
    local ok,value,ratio=pcall(function()return o:GetValue(),o:GetPercentage()end)
    if ok and finite(value)and finite(ratio)then
        return {value=math.max(0,value),ratio=math.max(0,math.min(1,ratio)),source="native-charge"}
    end
end
local function nativeCharges(abilities)
    local result,phases={},{}
    local ability=abilities.common
    if valid(ability)then
        pcall(function()
            ability.Inflictions:ForEach(function(key,value)
                key,value=unwrap(key),unwrap(value);local name=text(key.AttributeName)
                if name=="Frost_Accumulation"or name=="Ignite_Accumulation"or name=="BloodBurst_Accumulation"then
                    result[name]=charge(value.ChargeObject)
                end
            end)
        end)
        pcall(function()
            local array=ability.PoisonInflictionPhases;local count=#array
            if count<1 or count>8 then return end
            for index=1,count do phases[index-1]=charge(unwrap(array[index]).ChargeObject)end
        end)
    end
    -- Directly discovered charge subobjects avoid one Blueprint subclass dependency.
    for row,o in pairs(abilities.charges or {})do
        local sample=charge(o)
        if row=="FrostAccumulation"then result.Frost_Accumulation=sample
        elseif row=="BleedAccumulation"then result.BloodBurst_Accumulation=sample
        else local phase=tonumber(row:match("^PoisonPhase([0-3])$"));if phase then phases[phase]=sample end end
    end
    return result,phases
end
local function hasTag(asc,names)
    if not valid(asc)then return false end
    for _,name in ipairs(names)do
        local ok,count=pcall(asc.GetGameplayTagCount,asc,{TagName=FName(name)})
        if ok and finite(count)and count>0 then return true end
    end
    return false
end
local function yaoQi(ability,asc)
    if valid(ability)then
        local ok,value,ratio=pcall(function()return ability:GetCurrentYaoQi(),ability:GetYaoQiRatio()end)
        if ok and finite(value)and finite(ratio)then
            if value<=.001 then return end -- Burst clears it even if Tainted remains.
            return {id="yaoqi",name="妖气侵蚀",ratio=math.max(0,math.min(1,ratio)),value=value,
                source="native-erosion",mode="buildup",color=YAO_COLOR}
        end
    end
    if hasTag(asc,{"CharacterState.AbilityState.YaoJu.Tainted"})then
        return {id="yaoqi",name="妖气侵蚀",mode="unknown",source="native-tag",color=YAO_COLOR}
    end
end
function Status.read(actor,abilities)
    if not valid(actor)then return {}end
    local ok,alive=pcall(function()return not actor:IsActorBeingDestroyed()and actor:IsAlive()end)
    if not ok or not alive then return {}end
    local set,asc=actor.AttributeSetBase,actor.AbilitySystemComponent
    if not valid(set)then return {}end
    abilities=abilities or {}
    local samples,phases=nativeCharges(abilities)
    local states,needsClock={},false
    for _,definition in ipairs(DEFINITIONS)do
        states[definition.id]=hasTag(asc,definition.tags)
        if states[definition.id]then needsClock=true end
    end
    local effects,clockError={}
    if needsClock then effects,clockError=Clock.read(actor,asc)end
    local rows={}
    for _,definition in ipairs(DEFINITIONS)do
        local raw=attribute(set,definition.field)
        local sample=definition.field and samples[definition.field]
        local active=states[definition.id]
        local phase
        if definition.poison then
            for index=3,1,-1 do
                if hasTag(asc,{"CharacterState.StatusInfliction.Poison.Phase"..index})then phase=index;break end
            end
            if phase then sample=phases[phase]else
                for index=3,0,-1 do if phases[index]and phases[index].value>.001 then phase=index;sample=phases[index];break end end
            end
        end
        -- Some NPC charge subobjects exist without being driven by the player
        -- UI subsystem. A zero-only object must not hide a positive attribute.
        if sample and sample.value<=.001 and raw>.001 then sample=nil end
        -- GE_Frost overrides the current accumulation to zero while frozen.
        -- A UI charge cache must not resurrect chill after that native reset.
        if definition.id=="chill"and raw<=.001 then sample=nil end
        local value=sample and sample.value or raw
        if value>.001 or active then
            local ratio=sample and sample.ratio
            local source=sample and sample.source or(value>.001 and "native-attribute"or"native-tag")
            local mode="buildup"
            if active then
                mode="active"
                if effects[definition.id]then ratio,source=effects[definition.id].ratio,"native-duration"
                elseif definition.poison and sample then ratio,source=sample.ratio,"native-phase-decay"
                else ratio,source=nil,"native-tag"end
            elseif ratio==nil and definition.maximum then
                local maximum=attribute(set,"Infliction_Max");if maximum>0 then ratio=math.min(1,value/maximum)end
            end
            local effect=active and effects[definition.id]
            rows[#rows+1]={id=definition.id,name=definition.name,ratio=ratio,phase=phase,
                mode=ratio and mode or"unknown",value=value,source=source,color=definition.color,
                remaining=effect and effect.remaining,duration=effect and effect.duration}
        end
    end
    local yao=yaoQi(abilities.erosion,asc);if yao then rows[#rows+1]=yao end
    return rows,clockError
end
return Status
