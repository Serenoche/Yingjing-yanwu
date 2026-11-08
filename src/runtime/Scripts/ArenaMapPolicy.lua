-- Use the game's instance-local tab lock before it can activate the Map page.
-- No key binding, input action, shared descriptor, CDO or map widget is changed.
local Scene = require("SceneArena")
local Policy, Session = {}, {}
Session.__index = Session
local ROOT = "/Script/ProjectPBZ.PBZSystemScreenWidget"
local TABS = "/Script/ProjectPBZ.PBZTabListWidgetBase"
local GAMEPLAY = "/Script/Engine.Default__GameplayStatics"
local FORBIDDEN = 0x08023630
local MAP = "Map"
local HOOKS = { ROOT .. ":InitWidget", ROOT .. ":OpenByTabID", ROOT .. ":SelectTab", TABS .. ":RegisterTabs" }
local owners = {} -- only owned current-instance locks, never shared descriptors.
local function valid(v) return v ~= nil and type(v.IsValid) == "function" and v:IsValid() end
local function name(v) return type(v) == "string" and v or (v and v:ToString() or "") end
local function unwrap(v)
    if v then local ok, result = pcall(function() return v:get() end); if ok then return result end end
    return v
end
local function clean(v) return valid(v) and not v:HasAnyFlags(FORBIDDEN) end
local function same(a,b) return valid(a) and valid(b) and a:GetAddress() == b:GetAddress() end
local function world(v)
    if not valid(v) then return end
    local actual = Scene.runtimeWorld(v)
    return valid(actual) and actual:GetAddress() or nil
end
local function uiWorld(v)
    if not valid(v) then return end
    local actual = v:GetWorld() -- UWidget UObject native virtual, not LuaAActor outer-world helper.
    return valid(actual) and actual:GetAddress() or nil
end
local function locked(tabs)
    local ids = tabs.LockedIDs
    assert(ids ~= nil, "original tab lock array is unavailable")
    for index = 1, #ids do if name(ids[index]):lower() == "map" then return true end end
    return false
end
local function buttonsReady(tabs)
    local ids=tabs.TabButtonIDs
    if ids==nil then return false end
    for index=1,#ids do
        if not clean(tabs:GetTabButtonBaseByID(FName(name(ids[index])))) then return false end
    end
    return true
end
local function removeEarlyLock(tabs)
    local ids,remaining=tabs.LockedIDs,{}
    -- Convert each name into an independent Lua string before Empty reallocates
    -- the native array. Keep order, duplicates, case and FName number suffixes.
    for index=1,#ids do
        local value=name(ids[index]);if value:lower()~="map"then remaining[#remaining+1]=value end
    end
    ids:Empty()
    for index,value in ipairs(remaining)do ids[index]=FName(value)end
end
function Session:active()
    if self.closed then return false end
    local ok, active = pcall(self.gate)
    if not ok or active ~= true then return false end
    return clean(self.pawn) and self.pawn:GetAddress() == self.pawnId and world(self.pawn) == self.world
        and clean(self.controller) and world(self.controller) == self.world
        and same(self.gameplay:GetPlayerPawn(self.controller,0), self.pawn)
end
function Session:rootMatches(root)
    return clean(root) and clean(self.rootClass) and root:IsA(self.rootClass)
        and uiWorld(root) == self.world and same(root:GetOwningPlayer(),self.controller)
end
function Session:recordMatches(record)
    return self:rootMatches(record.root) and record.root:GetAddress() == record.rootId
        and record.root:GetFullName() == record.rootName and same(record.root.TabList,record.tabs)
        and clean(record.tabs) and record.tabs:GetAddress() == record.tabId
        and record.tabs:GetFullName() == record.tabName and uiWorld(record.tabs) == self.world
        and record.tabs:IsA(self.tabClass)
end
function Session:ensure(root)
    if not self:active() or not self:rootMatches(root) then return false end
    local tabs = root.TabList
    if not clean(tabs) or not tabs:IsA(self.tabClass) or uiWorld(tabs) ~= self.world then return false end
    local key = tostring(tabs:GetAddress())
    local prior=owners[key]
    if prior and prior.session~=self and prior.record.tabName==tabs:GetFullName()
        and prior.session.world==self.world then
        -- Never mistake another session's failed-cleanup lock for original
        -- game state. A closed owner must finish undo before this owner begins.
        if prior.session.closed then prior.session:close()end
        if owners[key]==prior then self.status="waiting-for-owned-map-cleanup";return false end
    end
    local record = self.records[key]
    if record and not self:recordMatches(record) then return false end
    if not record then
        record = { root=root, rootId=root:GetAddress(), rootName=root:GetFullName(), tabs=tabs,
            tabId=tabs:GetAddress(), tabName=tabs:GetFullName(), originalLocked=locked(tabs), owned=false }
        self.records[key] = record
    end
    if not locked(tabs) then
        -- Register ownership before a native setter can mutate then fail.
        record.owned = not record.originalLocked
        if record.owned then owners[key]={session=self,record=record}end
        if buttonsReady(tabs) then
            record.nativeApplied=true
            tabs:SetTabRuntimeHidden(FName(MAP),true)
        else
            -- Pinned LuaTArray NewIndex extends its real FName array. The
            -- original setter's AddLockedId loop dereferences every button;
            -- only this early native-array guard is safe before all exist.
            local ids=tabs.LockedIDs;ids[#ids+1]=FName(MAP);record.early=true
        end
        assert(locked(tabs), "original Map tab lock was rejected")
    end
    if record.early and buttonsReady(tabs) then
        record.nativeApplied=true;tabs:SetTabRuntimeHidden(FName(MAP),true);record.early=nil
    end
    self.status = "native-map-tab-locked"
    return true
end
function Session:discover(onlyTabs)
    if not self:active() then return end
    for _,root in ipairs(FindAllOf("PBZSystemScreenWidget") or {}) do
        if self:rootMatches(root) and (not onlyTabs or same(root.TabList,onlyTabs)) then self:ensure(root) end
    end
end
function Session:callback(path,context)
    if not self:active() then return end
    local object = unwrap(context)
    if path == TABS .. ":RegisterTabs" then
        if clean(object) and object:IsA(self.tabClass) and uiWorld(object) == self.world then self:discover(object) end
    else self:ensure(object) end
end
function Policy.new(pawn,gate)
    assert(type(gate) == "function", "private map policy requires a live scope gate")
    local gameplay,rootClass,tabClass = StaticFindObject(GAMEPLAY),StaticFindObject(ROOT),StaticFindObject(TABS)
    assert(valid(gameplay) and not gameplay:HasAnyFlags(0x08023600) and clean(rootClass) and clean(tabClass), "native map-tab policy metadata is not ready")
    local controller = gameplay:GetPlayerController(pawn,0)
    local self = setmetatable({pawn=pawn,pawnId=valid(pawn) and pawn:GetAddress(),world=world(pawn),controller=controller,
        gameplay=gameplay,rootClass=rootClass,tabClass=tabClass,gate=gate,records={},hooks={},status="waiting-for-native-system-menu"},Session)
    assert(self.world and self:active(), "map policy cannot own this private player")
    local ok, why = pcall(function()
        assert(type(RegisterHook) == "function", "native map policy hooks are unavailable")
        for _,path in ipairs({TABS..":SetTabRuntimeHidden",TABS..":RemoveLockedID",
            "/Script/CommonUI.CommonTabListWidgetBase:GetTabButtonBaseByID"})do
            assert(clean(StaticFindObject(path)),"missing original map-tab lock interface: "..path)
        end
        for _,path in ipairs(HOOKS) do
            assert(clean(StaticFindObject(path)), "missing original map-tab entry: " .. path)
            local function dispatch(context)
                if self.closed then return end
                local good, failure = pcall(self.callback,self,path,context)
                if not good and not self.lastError then
                    self.lastError=tostring(failure)
                    print("[PBZTestArenaNative] Arena map-tab policy: " .. self.lastError .. "\n")
                end
            end
            -- All four are pinned native UFUNCTIONs. PRE locks the two real
            -- activation entries. RegisterTabs POST re-applies after rebuild.
            local pre,post = RegisterHook(path,dispatch,path == TABS .. ":RegisterTabs" and dispatch or nil)
            assert(pre and post, "native map-tab hook installation returned no handles")
            self.hooks[#self.hooks+1] = {path=path,pre=pre,post=post}
        end
        self:discover()
    end)
    if not ok then
        self.lastError=tostring(why)
        local cleaned=self:close()
        -- Return the closed handle when cleanup itself failed, so the caller's
        -- existing retry queue can retain it instead of losing an owned lock.
        if not cleaned then self.status="cleanup-pending";return self end
        error(why,0)
    end
    return self
end
function Session:update(pawn,now)
    if not same(pawn,self.pawn) or not self:active() then return false,"private-map-policy-scope-ended" end
    assert(type(now) == "number" and now > -math.huge and now < math.huge, "map policy clock is unavailable")
    if not self.nextAt or now >= self.nextAt then
        self.nextAt=now+1
        -- No idle GUObject scan. New roots are captured by exact native entry
        -- hooks; RegisterTabs discovery runs only on that finite rebuild event.
        for _,record in pairs(self.records)do self:ensure(record.root)end
    end
    return true
end
function Session:close()
    self.closed=true -- late native callbacks are inert even if unregistration fails.
    self.closeError=nil
    local remaining={}
    for key,record in pairs(self.records) do
        local ok, why = pcall(function()
            if not valid(record.root) or not valid(record.tabs) then return end
            if not self:recordMatches(record) then error("map tab identity/world changed before cleanup") end
            if record.owned and (locked(record.tabs)or record.refreshPending) then
                -- Do NOT call SetTabRuntimeHidden(false): its final force-unlock
                -- would override native descriptor/story locks. This original
                -- remover recomputes those conditions after removing our ID.
                if buttonsReady(record.tabs)then record.tabs:RemoveLockedID(FName(MAP))
                else
                    record.refreshPending=record.nativeApplied
                        or clean(record.tabs:GetTabButtonBaseByID(FName(MAP)))
                    removeEarlyLock(record.tabs)
                    if record.refreshPending then error("waiting for native Map-button cleanup readiness")end
                end
                assert(not locked(record.tabs), "owned Map tab lock cleanup was rejected")
            end
        end)
        if not ok then remaining[key]=record;self.closeError=tostring(why)
        elseif owners[key]and owners[key].session==self then owners[key]=nil end
    end
    self.records=remaining
    local hooks={}
    for _,hook in ipairs(self.hooks) do
        local ok, why = pcall(UnregisterHook,hook.path,hook.pre,hook.post)
        if not ok then hooks[#hooks+1]=hook;self.closeError=tostring(why) end
    end
    self.hooks=hooks
    return next(self.records) == nil and #hooks == 0,self.closeError
end
return Policy
