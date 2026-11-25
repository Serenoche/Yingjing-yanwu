-- Isolated combat-rules prototype. No game entry, hooks, UObject access or saves.
-- The host owns actor lifetime, native damage and unit conversion. In batch one
-- the only host is the synthetic replay fixture; native integration is gated.
-- Direct hits must already be identified and attributed, not inferred from HP.
local Catalog=require("RogueCatalog")
local Combat={}; Combat.__index=Combat
local R=Catalog.rules

local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function id(v) return type(v)=="string" and #v>0 and #v<=256 end
local function positive(v) return finite(v) and v>0 end
local function point(v)
    return type(v)=="table" and finite(v.x) and finite(v.y) and finite(v.z)
end
local function copyPoint(v) return {x=v.x,y=v.y,z=v.z} end
local function distance2(a,b) return (a.x-b.x)^2+(a.y-b.y)^2+(a.z-b.z)^2 end
local function bounded(v,maximum) return finite(v) and v%1==0 and v>=0 and v<=maximum end

function Combat.new(config,host)
    assert(type(config)=="table" and type(host)=="table","config and host required")
    for _,key in ipairs({"session","room","player","weapon"}) do assert(id(config[key]),"invalid "..key) end
    assert(config.weapon==Catalog.weaponId,"unbound weapon")
    assert(positive(config.referenceDamage),"invalid damage reference")
    for _,key in ipairs({"actor","damage","nearby"}) do assert(type(host[key])=="function","missing host "..key) end
    local build=Catalog.build(config.effects)
    return setmetatable({session=config.session,room=config.room,player=config.player,weapon=config.weapon,
        referenceDamage=config.referenceDamage,build=build,host=host,now=0,edge=0,edgeExpires=0,
        fire={},events={},echoes={},damageLog={},closed=false,dispatching=false},Combat)
end

function Combat:ownedActor(actorId)
    if not id(actorId) then return end
    local a=self.host:actor(actorId)
    if type(a)~="table" or a.id~=actorId or a.room~=self.room or a.session~=self.session
        or a.alive~=true or a.team~="enemy" or not point(a.position) then return end
    return a
end

function Combat:fireStacks(target)
    local f=self.fire[target]
    if f and f.expires>self.now and self:ownedActor(target) then return f.stacks end
    return 0
end

function Combat:addFire(target,amount)
    if not self.build.ignite_blade or not bounded(amount,R.fireMaximum) or amount==0
        or not self:ownedActor(target) then return end
    local f=self.fire[target]
    if not f or f.expires<=self.now then
        f={stacks=0,nextTick=self.now+R.fireTick}; self.fire[target]=f
    end
    f.stacks=math.min(R.fireMaximum,f.stacks+amount)
    f.expires=self.now+R.fireDuration
end

function Combat:addEdge(amount)
    if not self.build.store_edge or not bounded(amount,R.edgeMaximum) or amount==0 then return end
    self.edge=math.min(R.edgeMaximum,self.edge+amount)
    self.edgeExpires=self.now+R.edgeDuration
end

function Combat:emit(target,ratio,origin,eventId)
    if not self:ownedActor(target) or not positive(ratio) then return end
    local command={target=target,amount=self.referenceDamage*ratio,ratio=ratio,origin=origin,
        eventId=eventId,sourcePlayer=self.player,weapon=self.weapon,session=self.session,room=self.room,
        at=self.now,canTriggerWeaponHit=false}
    self.damageLog[#self.damageLog+1]=command
    local ok,why=pcall(self.host.damage,self.host,command)
    if not ok then self:close();error("damage host failed; combat closed: "..tostring(why)) end
    if not self:ownedActor(target) then self.fire[target]=nil end
end

function Combat:expire()
    if self.edge>0 and self.edgeExpires<=self.now then self.edge=0;self.edgeExpires=0 end
    for target,f in pairs(self.fire) do
        if f.expires<self.now or (f.expires==self.now and f.nextTick>self.now)
            or not self:ownedActor(target) then self.fire[target]=nil end
    end
end

function Combat:advance(at)
    assert(not self.closed,"combat closed")
    assert(not self.dispatching,"reentrant combat dispatch")
    assert(finite(at) and at>=self.now,"combat time must be monotonic")
    -- Resolve due work in timestamp order. A final tick at the deadline is
    -- resolved before expiration, giving a four-second burn four full ticks.
    while true do
        local nextAt,kind,key
        for target,f in pairs(self.fire) do
            if f.nextTick<=f.expires and f.nextTick<=at and (not nextAt or f.nextTick<nextAt
                or (f.nextTick==nextAt and kind=="fire" and target<key)) then
                nextAt,kind,key=f.nextTick,"fire",target
            end
        end
        for index,e in ipairs(self.echoes) do
            if e.at<=at and (not nextAt or e.at<nextAt) then nextAt,kind,key=e.at,"echo",index end
        end
        if not nextAt then break end
        self.now=nextAt; self:expire()
        if kind=="fire" then
            local f=self.fire[key]
            if f then
                f.nextTick=f.nextTick+R.fireTick
                self.dispatching=true
                self:emit(key,f.stacks*R.fireDamage,"burn","tick:"..key..":"..tostring(nextAt))
                self.dispatching=false
            end
        else
            local e=table.remove(self.echoes,key)
            local a=self:ownedActor(e.target)
            if a and distance2(a.position,e.position)<=R.echoRadius^2 then
                self.dispatching=true
                self:emit(e.target,e.heavyRatio*R.echoDamage,"return_cut",e.eventId..":echo")
                if e.burst then self:addFire(e.target,R.echoFire) end
                self.dispatching=false
            end
        end
    end
    self.now=at; self:expire()
end

function Combat:accept(event,kind)
    if self.closed or self.dispatching then return false,"inactive-or-reentrant" end
    if type(event)~="table" or event.kind~=kind or event.session~=self.session or event.room~=self.room
        or event.player~=self.player or event.weapon~=self.weapon or not id(event.id)
        or not finite(event.at) or event.at<self.now then return false,"invalid-event-scope" end
    if kind~="parry" and (event.origin~="weapon" or event.confirmed~=true
        or not self:ownedActor(event.target)) then return false,"unconfirmed-weapon-hit" end
    if kind=="heavy" and (not positive(event.heavyRatio) or event.heavyRatio>100) then return false,"invalid-heavy-reference" end
    -- Light hits deduplicate by action + target; heavy resources spend only
    -- once for the action's chosen main target, even if its swing hits others.
    local eventKey=kind..":"..event.id..(kind=="light" and ":"..event.target or "")
    if self.events[eventKey] then return false,"duplicate-event" end
    self:advance(event.at)
    self.events[eventKey]=true
    return true
end

function Combat:light(event)
    local ok,reason=self:accept(event,"light"); if not ok then return false,reason end
    self:addFire(event.target,1)
    return true,{fire=self:fireStacks(event.target)}
end

function Combat:parry(event)
    if type(event)~="table" or event.confirmed~=true or event.outcome~="perfect_deflect" then
        return false,"unconfirmed-perfect-deflect"
    end
    local ok,reason=self:accept(event,"parry"); if not ok then return false,reason end
    self:addEdge(1)
    return true,{edge=self.edge}
end

function Combat:heavy(event)
    local ok,reason=self:accept(event,"heavy"); if not ok then return false,reason end
    local target=event.target
    local actor=self:ownedActor(target)
    if not actor then return false,"target-expired-before-hit" end
    local origin=copyPoint(actor.position)
    local spent=self.edge;self.edge=0;self.edgeExpires=0
    if self.build.temper_edge and spent>0 then self:addFire(target,spent) end
    local stacks=self:fireStacks(target)
    local burst=self.build.heartfire_slash and stacks>=R.burstMinimum or false
    if burst then self.fire[target]=nil end
    self.dispatching=true
    if spent>0 then self:emit(target,spent*R.edgeDamage,"edge",event.id) end
    if burst then
        -- Snapshot candidates before any damage, and deduplicate host results.
        local targets,seen={target},{[target]=true}
        local found,nearby=pcall(self.host.nearby,self.host,origin,R.burstRadius)
        if not found or type(nearby)~="table" then self:close();error("nearby host failed; combat closed") end
        for _,candidate in ipairs(nearby) do
            local a=self:ownedActor(candidate)
            if a and not seen[candidate] and distance2(a.position,origin)<=R.burstRadius^2 then
                seen[candidate]=true;targets[#targets+1]=candidate
            end
        end
        table.sort(targets)
        for _,candidate in ipairs(targets) do self:emit(candidate,stacks*R.burstDamage,"fire_burst",event.id) end
        if self.build.rekindle then self:addFire(target,1) end
    end
    if self.build.retain_edge and spent>=R.retainMinimum then self:addEdge(R.retainedEdge) end
    if self.build.return_cut and self:ownedActor(target) then
        self.echoes[#self.echoes+1]={at=self.now+R.echoDelay,target=target,position=origin,
            heavyRatio=event.heavyRatio,burst=burst,eventId=event.id}
    end
    self.dispatching=false
    return true,{spentEdge=spent,consumedFire=burst and stacks or 0,burst=burst,
        fire=self:fireStacks(target),edge=self.edge}
end

function Combat:snapshot()
    local fire={}
    for target,f in pairs(self.fire) do
        if self:ownedActor(target) then fire[target]={stacks=f.stacks,expires=f.expires,nextTick=f.nextTick} end
    end
    return {at=self.now,edge=self.edge,edgeExpires=self.edgeExpires,fire=fire,pendingEchoes=#self.echoes,closed=self.closed}
end

function Combat:close()
    self.closed=true;self.edge=0;self.edgeExpires=0;self.fire={};self.echoes={};self.events={}
end

return Combat
