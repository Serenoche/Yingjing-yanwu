-- Original-arena variant: suppress only this LengTu's friendly summons.
-- Enemy requests, transforms, AI, health and phase events are never edited.
-- Enemy observations are retained solely for diagnostics and exit cleanup.
local SpawnClass = require("SpawnClass")
local Module, Session = {}, {}
Session.__index = Session
local BASE = "/PBZCombatAsset/ActorData/Mobs/077_LengTu/Ability/Passive/"
local SUMMON = "/SGameAI/Core/AIScript/GA_SummonPassive.GA_SummonPassive_C:"
local REQUEST = "/Script/SGameAI.SGameAIFunctionLibrary:RequestSummonSpawn"
local LIBRARY = "/Script/SGameAI.Default__SGameAIFunctionLibrary"
local SOURCES = {
    { name = "P1_Scavenger", kind = "enemy" }, { name = "P2_GuiChai", kind = "enemy" },
    { name = "P3_Vessels", kind = "enemy" }, { name = "P4_FemaleDolls", kind = "enemy" },
    { name = "P1_PengMeng", kind = "ally" }, { name = "P2_HuaShan", kind = "ally" },
    { name = "P3_FengXueDaoKe", kind = "ally" }, { name = "P4_LionDancer", kind = "ally" },
    { name = "P5_LeiDang", kind = "ally" },
}
local function valid(x) return x ~= nil and type(x.IsValid) == "function" and x:IsValid() end
local function unwrap(x)
    if x and type(x.get) == "function" then return x:get() end
    return x
end
local function text(x) return type(x) == "string" and x or x:ToString() end
local function same(a,b) return valid(a) and valid(b) and a:GetAddress() == b:GetAddress() end
local function finite(x) return type(x) == "number" and x == x and math.abs(x) < math.huge end
local function fmt(x) return string.format("%.1f,%.1f,%.1f",x.X,x.Y,x.Z) end
local function required(path)
    local result = StaticFindObject(path)
    assert(valid(result), "冷荼召唤接口不可用："..path)
    return result
end

function Session:ownsBoss(actor)
    return valid(actor) and same(actor:GetWorld(),self.world) and same(self.bosses[actor:GetAddress()],actor)
end
function Session:source(ability)
    if self.closed or not valid(ability) then return end
    if ability:HasAnyFlags(0x08023610) or not same(ability:GetWorld(),self.world) then return end
    local boss = ability:GetAvatarActorFromActorInfo()
    if not self:ownsBoss(boss) then return end
    for _,source in ipairs(self.sources) do
        -- Enemy abilities are naturally loaded by the original battle, never
        -- preloaded or configured by this helper.
        local class=source.class or StaticFindObject(source.path)
        if valid(class) and ability:IsA(class) then return source,boss end
    end
end
function Session:disableAlly(ability,source)
    local key = ability:GetAddress()
    if not self.disabled[key] then
        assert(type(ability.MaxSummonCount)=="number", "冷荼友方召唤实例缺少上限")
        self.disabled[key]={ ability=ability,maximum=ability.MaxSummonCount }
        print("[PBZTestArenaNative] LengTu ally summons disabled: "..source.name.."; instance="..key.."\n")
    end
    ability.MaxSummonCount=0
end
function Session:bindBoss(actor)
    assert(not self.closed and valid(actor) and same(actor:GetWorld(),self.world), "冷荼召唤本体不可用")
    self.bosses[actor:GetAddress()]=actor
end
function Session:request(abilityParam,classParam,transformParam,hiddenParam,slicedParam)
    local ability=unwrap(abilityParam)
    local source=self:source(ability)
    if not source then return end
    if source.kind=="ally" then
        self:disableAlly(ability,source)
        if self.nullClass and classParam and type(classParam.set)=="function" then
            local originalClass=unwrap(classParam)
            local replaced=pcall(function()
                classParam:set(self.nullClass)
                local result=unwrap(classParam)
                assert(result and result:GetAddress()==0,"冷荼友方原生空类型拒绝未生效")
            end)
            if replaced then
                print("[PBZTestArenaNative] LengTu ally native request rejected with typed null class: "..source.name.."\n")
                return
            end
            -- An unsupported bridge must leave a legal original argument for
            -- the hidden/cancel/next-tick cleanup fallback, never a half edit.
            classParam:set(originalClass)
            local restored=unwrap(classParam)
            assert(valid(restored) and restored:GetAddress()==originalClass:GetAddress(),"冷荼友方召唤原类型恢复失败")
        end
        -- True native PRE. Request hidden/sliced behavior and cancel pending
        -- work in POST. Native gates can still choose synchronous fallback;
        -- Ready hiding plus next-update cleanup covers that case as well.
        assert(hiddenParam and type(hiddenParam.set)=="function" and slicedParam and type(slicedParam.set)=="function",
            "冷荼友方召唤缺少原生排队参数")
        hiddenParam:set(true)
        slicedParam:set(true)
        return
    end
    -- Diagnostics must not reject or alter an original enemy request, even if
    -- its optional position view is unavailable in this binding.
    local logged=pcall(function()
        local class=unwrap(classParam)
        local transform=unwrap(transformParam)
        local at=transform and transform.Translation
        local position=at and finite(at.X) and finite(at.Y) and finite(at.Z) and fmt(at) or "unavailable"
        print("[PBZTestArenaNative] LengTu original enemy request unchanged: "..source.name
            .."/"..(valid(class) and text(class:GetFName()) or "unavailable").."; original="..position.."\n")
    end)
    if not logged and not self.diagnosticWarning then
        self.diagnosticWarning=true
        print("[PBZTestArenaNative] LengTu enemy diagnostic unavailable; original request left unchanged\n")
    end
end
function Session:afterRequest(abilityParam)
    local ability=unwrap(abilityParam)
    local source=self:source(ability)
    if source and source.kind=="ally" then
        self:disableAlly(ability,source)
        -- Exact original K2_OnEndAbility API, scoped to this one friendly GA.
        -- Pending cancellation cannot decrement another enemy GA's wave count.
        self.library:CancelPendingSummons(ability)
    end
end
function Session:spawned(abilityParam,pawnParam,ready)
    local ability,actor=unwrap(abilityParam),unwrap(pawnParam)
    local source,boss=self:source(ability)
    if not source or not valid(actor) or actor:IsActorBeingDestroyed() then return end
    if not same(actor:GetWorld(),self.world) then return end
    local class=actor:GetClass()
    local key=actor:GetAddress()
    local record=self.actors[key]
    if not record then
        record={ actor=actor,class=class,source=source.name,kind=source.kind,boss=boss }
        self.actors[key]=record
    end
    assert(same(record.actor,actor) and record.kind==source.kind,"冷荼召唤身份冲突")
    if source.kind=="ally" then
        -- Only enqueue here. The original Ready body / native spawn scheduler
        -- can still be using Pawn when a reflected callback is delivered.
        record.ready=record.ready or ready
        if ready then actor:SetActorHiddenInGame(true) end
        return
    end
    record.ready=record.ready or ready
    if ready and not record.logged then
        record.logged=true
        pcall(function()
            print("[PBZTestArenaNative] LengTu original enemy ready unchanged: "..actor:GetFullName()
                .."; source="..record.source.."; original="..fmt(actor:K2_GetActorLocation()).."\n")
        end)
    end
end
function Session:owns(actor)
    if not valid(actor) or not same(actor:GetWorld(),self.world) then return false end
    local record=self.actors[actor:GetAddress()]
    return record~=nil and same(record.actor,actor) and actor:IsA(record.class)
end
function Session:update(pawn)
    assert(not self.closed and same(pawn,self.pawn) and same(pawn:GetWorld(),self.world), "冷荼召唤角色或世界已改变")
    assert(not self.error,self.error)
    for _,record in pairs(self.disabled) do
        local source=self:source(record.ability)
        if source then record.ability.MaxSummonCount=0 end
    end
    for _,record in pairs(self.actors) do
        local actor=record.actor
        if valid(actor) and not actor:IsActorBeingDestroyed() and record.ready and record.kind=="ally" then
            print("[PBZTestArenaNative] LengTu queued ally removed on safe update: "..actor:GetFullName().."\n")
            actor:K2_DestroyActor()
        end
    end
    return true
end
function Session:close()
    if self.closed and not self.closePending then return end
    self.closed=true
    local failures,disabled,actors,hooks={},{},{},{}
    for _,hook in ipairs(self.hooks) do
        local ok,reason=pcall(UnregisterHook,hook.path,hook.pre,hook.post)
        if not ok then hooks[#hooks+1]=hook;failures[#failures+1]=tostring(reason) end
    end
    self.hooks=hooks
    for key,record in pairs(self.disabled) do
        local ability=record.ability
        local ok,reason=pcall(function()
            if valid(ability) and same(ability:GetWorld(),self.world) then ability.MaxSummonCount=record.maximum end
        end)
        if not ok then disabled[key]=record; failures[#failures+1]=tostring(reason) end
    end
    for key,record in pairs(self.actors) do
        local ok,reason=pcall(function()
            if valid(record.actor) and not record.actor:IsActorBeingDestroyed() and same(record.actor:GetWorld(),self.world) then
                assert(record.actor:IsA(record.class),"冷荼召唤清理身份改变")
                record.actor:K2_DestroyActor()
            end
        end)
        if not ok then actors[key]=record;failures[#failures+1]=tostring(reason) end
    end
    self.actors,self.disabled,self.bosses=actors,disabled,{}
    self.closePending=#failures>0
    assert(not self.closePending,table.concat(failures,"; "))
end
function Module.new(pawn)
    assert(valid(pawn) and valid(pawn:GetWorld()),"冷荼召唤上下文不可用")
    local sources={}
    for _,definition in ipairs(SOURCES) do
        local name="GA_LengTu_SummonPassive_"..definition.name
        local class,reason
        if definition.kind=="ally" then
            class,reason=SpawnClass.resolve(BASE..name.."."..name.."_C")
            if not class then return nil,reason end
        end
        sources[#sources+1]={name=definition.name,kind=definition.kind,class=class,path=BASE..name.."."..name.."_C"}
    end
    local self=setmetatable({pawn=pawn,world=pawn:GetWorld(),sources=sources,
        bosses={},actors={},disabled={},hooks={},library=required(LIBRARY)},Session)
    local gotNull,nullClass=pcall(function()
        -- Original native factory returns UClass(nullptr). A Lua nil SET is
        -- a no-op for ClassProperty in pinned UE4SS, hence this typed wrapper.
        local factory=required("/Script/Engine.Default__GameplayStatics")
        local result=factory:GetObjectClass(nil)
        assert(type(result)=="userdata" and result:GetAddress()==0)
        return result
    end)
    if gotNull then self.nullClass=nullClass
    else print("[PBZTestArenaNative] LengTu typed null class unavailable; friendly hidden/cancel cleanup fallback active\n") end
    local function safe(fn,...)
        if self.closed then return end
        local ok,reason=pcall(fn,self,...)
        if not ok then self.error=tostring(reason) end
    end
    local function hook(path,pre,post)
        required(path)
        local first,last
        if post then first,last=RegisterHook(path,pre,post) else first,last=RegisterHook(path,pre) end
        self.hooks[#self.hooks+1]={path=path,pre=first,post=last}
    end
    local ok,reason=pcall(function()
        hook(REQUEST,function(_,ability,class,transform,_,_,hidden,sliced) safe(Session.request,ability,class,transform,hidden,sliced) end,
            function(_,ability) safe(Session.afterRequest,ability) end)
        local function cap(context)
            safe(function(session,abilityParam)
                local ability=unwrap(abilityParam); local source=session:source(ability)
                if source and source.kind=="ally" then session:disableAlly(ability,source) end
            end,context)
        end
        -- In pinned UE4SS, a Blueprint function's FIRST callback is POST;
        -- the optional third callback is ignored for script functions. These
        -- caps prepare later requests; native Request PRE/POST covers the first.
        hook(SUMMON.."OnReceivedSpawnSummonsEvent",cap)
        for _,source in ipairs(sources) do
            if source.kind=="ally" then hook(source.path..":K2_ActivateAbility",cap) end
        end
        hook(SUMMON.."OnSummonSpawnPreFinish",function(context,actor) safe(Session.spawned,context,actor,false) end)
        hook(SUMMON.."OnSummonSpawnReady",function(context,actor) safe(Session.spawned,context,actor,true) end)
    end)
    if not ok then self:close(); error(reason,0) end
    return self
end
return Module
