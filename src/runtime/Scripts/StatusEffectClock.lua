-- Read-only GAS timing. No returned native arrays/structs are retained.
local Clock={}
local LIB="/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary"
local EFFECTS={GE_Ignite="ignite",GE_Frost="frost",GE_Frost_Mob="frost",GE_Chaos="chaos",
    GE_Poison_Phase1="poison",GE_Poison_Phase2="poison",GE_Poison_Phase3="poison",GE_LuanYing_YingHen="yinghen"}
local function valid(o)return o~=nil and type(o.IsValid)=="function"and o:IsValid()end
local function finite(n)return type(n)=="number"and n==n and math.abs(n)<math.huge end
local function unwrap(o)
    if o and type(o.IsValid)~="function"then
        local get=o.get or o.Get;if type(get)=="function"then return get(o)end
    end
    return o
end
function Clock.read(actor,asc)
    if not valid(actor)or not valid(asc)then return {},"missing target/ASC"end
    local ok,result=pcall(function()
        local lib=StaticFindObject(LIB);assert(valid(lib),"native effect timing library unavailable")
        -- Fresh EMPTY input: no borrowed tag containers or FieldPath values.
        local native=asc:GetActiveEffectsWithAllTags({GameplayTags={},ParentTags={}})
        local count=#native;assert(count>=0 and count<=256,"unexpected active effect count")
        local handles={}
        for index=1,count do
            local item=unwrap(native[index]);local id=item.Handle
            if finite(id)and id>=0 and id<2147483647 and id==math.floor(id)then
                handles[#handles+1]={Handle=id,bPassedFiltersAndWasExecuted=item.bPassedFiltersAndWasExecuted==true}
            end
        end
        native=nil -- Only scalar handle copies survive subsequent native calls.
        local effects={}
        for _,handle in ipairs(handles)do
            local ge=lib:GetGameplayEffectFromActiveEffectHandle(handle)
            if valid(ge)then
                local name=ge:GetClass():GetFName();name=type(name)=="string"and name or name:ToString()
                local id=EFFECTS[name:gsub("_C$","")]
                if id then
                    local duration=lib:GetActiveGameplayEffectTotalDuration(handle)
                    if finite(duration)and duration>0 then
                        -- Native helper uses the target world's GAME time,
                        -- including pauses, dilation, refresh and early removal.
                        local remaining=lib:GetActiveGameplayEffectRemainingDuration(actor,handle)
                        if finite(remaining)and remaining>=0 then
                            local old=effects[id]
                            if not old or remaining>old.remaining then
                                effects[id]={remaining=remaining,duration=duration,
                                    ratio=math.max(0,math.min(1,remaining/duration)),source="native-duration"}
                            end
                        end
                    end
                    -- Infinite poison phases use their native charge decay.
                end
            end
        end
        return effects
    end)
    if ok then return result end
    return {},tostring(result)
end
return Clock
