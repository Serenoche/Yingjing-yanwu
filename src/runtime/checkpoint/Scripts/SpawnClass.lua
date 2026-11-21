-- An existing UClass can still belong to an asynchronously loading package.
-- Do not hand such a class to SpawnActorDeferred: its event Func may be null.
local SpawnClass = {}
local confirmed = {}
local Probe = {}
Probe.__index = Probe
-- UE 5.7 EObjectFlags, verified against the pinned game/loader sources.
-- NeedInitialization|NeedLoad|NeedPostLoad|NeedPostLoadSubobjects|
-- BeingRegenerated|WillBeLoaded. WasLoaded/LoadCompleted do not imply readiness.
local PENDING = 0x08023600
local EVENTS = { "UserConstructionScript", "ReceiveBeginPlay", "ReceiveTick", "Init Level" }
local FAST_CLASSES = {
    ["/PBZCombatAsset/ActorData/Mobs/048_HookMan/BP_Monster_HookMan.BP_Monster_HookMan_C"] = true,
    ["/PBZCombatAsset/ActorData/Mobs/051_HookMan_P2/BP_Monster_HookMan_P2.BP_Monster_HookMan_P2_C"] = true,
}
local DEPENDENCY_PROVIDERS = { "JingYeMount", "ChiLianArena", "LionArena" }
local eventNamesByIndex

local function valid(object)
    return object ~= nil and type(object.IsValid) == "function" and object:IsValid()
end

local function findLocalEvents(ancestor)
    if not eventNamesByIndex then
        local byIndex = {}
        for _, name in ipairs(EVENTS) do byIndex[FName(name):GetComparisonIndex()] = name end
        eventNamesByIndex = byIndex
    end
    local found = {}
    -- The pinned UE4SS UStruct iterator visits functions declared directly
    -- on the class. The readiness loop still checks each super separately.
    -- UE4SS 1ceefac8 pops a false result twice. Keep the callback's implicit nil.
    ancestor:ForEachFunction(function(event)
        assert(valid(event), "native function iterator returned an invalid object")
        local name = event:GetFName()
        local expected = eventNamesByIndex[name:GetComparisonIndex()]
        if expected and name:ToString():lower() == expected:lower() then
            found[expected] = event
        end
    end)
    return found
end

local function reflectedPath(ancestor)
    local path = ancestor:GetFullName():match("^%S+ (.+)$")
    assert(path, "spawn ancestor has no reflected object path")
    return path
end

local function ready(class, path, proof, enumerate)
    local useLocal = enumerate or FAST_CLASSES[path] == true
    if not valid(class) then return false, "等待角色类型载入" end
    if class:HasAnyFlags(PENDING) then return false, "等待角色类型完成初始化" end
    -- This pinned UE4SS getter reads ClassDefaultObject; it never constructs a
    -- CDO or invokes an event on a partially loaded class.
    local cdo = class:GetCDO()
    if not valid(cdo) then return false, "等待角色默认对象载入" end
    if cdo:HasAnyFlags(PENDING) then return false, "等待角色默认对象完成初始化" end
    if proof then proof.cdo = cdo:GetAddress() end
    local ancestor, ancestorPath, seen = class, path, {}
    for _ = 1, 32 do
        local address = ancestor:GetAddress()
        assert(not seen[address], "spawn class inheritance contains a cycle")
        seen[address] = true
        if proof then proof.ancestors[#proof.ancestors + 1] = address end
        if ancestor:HasAnyFlags(PENDING) then
            return false, "等待角色继承类型完成初始化：" .. (ancestorPath or reflectedPath(ancestor))
        end
        local localEvents
        if useLocal then
            local ok, found = pcall(findLocalEvents, ancestor)
            if ok then localEvents = found
            else
                useLocal = false
                ancestorPath = ancestorPath or reflectedPath(ancestor)
            end
        end
        if not localEvents then ancestorPath = ancestorPath or reflectedPath(ancestor) end
        for _, name in ipairs(EVENTS) do
            local event
            if localEvents then event = localEvents[name]
            else event = StaticFindObject(ancestorPath .. ":" .. name) end
            if valid(event) then
                if event:HasAnyFlags(PENDING) then
                    return false, "等待角色蓝图事件完成初始化：" .. (ancestorPath or reflectedPath(ancestor)) .. ":" .. name
                end
                if proof then proof.events[#proof.events + 1] = event end
            end
        end
        -- GetSuperStruct returns a UStruct wrapper. Read flags/functions only;
        -- do not attempt to create/get a parent CDO through that wrapper.
        ancestor = ancestor:GetSuperStruct()
        if not valid(ancestor) then return true end
        ancestorPath = not useLocal and reflectedPath(ancestor) or nil
    end
    error("spawn class inheritance exceeds the supported depth")
end

local function validPath(path)
    return type(path) == "string" and path:match("^/[A-Za-z0-9_./-]+_C$") ~= nil
end

local function stillReady(class, proof)
    if not valid(class) then return false end
    if class:GetAddress() ~= proof.ancestors[1] then return false end
    if class:HasAnyFlags(PENDING) then return false end
    local cdo = class:GetCDO()
    if not valid(cdo) then return false end
    if cdo:GetAddress() ~= proof.cdo then return false end
    if cdo:HasAnyFlags(PENDING) then return false end
    local ancestor = class
    for _, address in ipairs(proof.ancestors) do
        if not valid(ancestor) or ancestor:GetAddress() ~= address then return false end
        if ancestor:HasAnyFlags(PENDING) then return false end
        ancestor = ancestor:GetSuperStruct()
    end
    if valid(ancestor) then return false end
    for _, event in ipairs(proof.events) do
        if not valid(event) then return false end
        if event:HasAnyFlags(PENDING) then return false end
    end
    return true
end

local function verify(class, path, proof, job)
    local preloaded = job and job.preloadProof
    if preloaded then
        if stillReady(class, preloaded) then return true, nil, proof and preloaded end
        job.preloadProof = nil
        job.proofRechecked = true
    end
    local complete, reason = ready(class, path, proof, job ~= nil)
    return complete, reason, proof
end

local function resolve(path, captureProof, preload)
    assert(validPath(path), "invalid spawn class path")
    local job = preload and preload.byPath[path]
    local class = StaticFindObject(path)
    local proof = captureProof and { ancestors = {}, events = {} }
    if valid(class) and confirmed[path] == class:GetAddress() then
        local complete, _, verified = verify(class, path, proof, job)
        if complete then
            return class, nil, verified
        end
        if proof then proof = { ancestors = {}, events = {} } end
        confirmed[path] = nil
    end

    -- LoadAsset uses AssetRegistry.GetAsset -> FAssetData.GetAsset, which loads
    -- an existing but incomplete package synchronously. Generated classes and
    -- blueprint assets can have different registry paths; keep both forms.
    local started = job and os.clock()
    local loaded = false
    for _, assetPath in ipairs({ path, (path:gsub("_C$", "")) }) do
        local ok, asset, _, didLoad = pcall(LoadAsset, assetPath)
        if ok and didLoad == true and valid(asset) then loaded = true; break end
    end
    if started then preload:noteSync(path, (os.clock() - started) * 1000, loaded) end
    if not loaded then
        return nil, "等待首领资源包完整载入：" .. path
    end
    class = StaticFindObject(path)
    local complete, reason, verified = verify(class, path, proof, job)
    if not complete then return nil, reason .. "：" .. path end
    confirmed[path] = class:GetAddress()
    print("[PBZTestArenaNative] Spawn class package ready: " .. path .. "\n")
    return class, nil, verified
end

function SpawnClass.resolve(path, preload)
    return resolve(path, nil, preload)
end

-- Observing the loaded class does not confirm its package with the asset
-- registry. The spawn resolver still performs that check when needed.
function SpawnClass.observeReady(path)
    assert(validPath(path), "invalid observed spawn class path")
    local class = StaticFindObject(path)
    local proof = { ancestors = {}, events = {} }
    local complete, reason = ready(class, path, proof, true)
    if complete then return class, nil, proof end
    return nil, reason
end

function SpawnClass.preload(members, preload)
    local paths, seen = {}, {}
    for _, member in ipairs(members) do
        local path = member.classPath
        assert(validPath(path), "invalid preload class path")
        if not seen[path] then
            paths[#paths + 1], seen[path] = path, true
        end
    end
    local requiredCount = #paths
    for _, member in ipairs(members) do
        if member.id then
            for _, name in ipairs(DEPENDENCY_PROVIDERS) do
                local provider = require(name)
                local dependencies = provider.preloadPaths and provider.preloadPaths(member)
                if dependencies then
                    for _, path in ipairs(dependencies) do
                        if not seen[path] then
                            paths[#paths + 1], seen[path] = path, true
                        end
                    end
                end
            end
        end
    end
    return setmetatable({ paths = paths, requiredCount = requiredCount, next = 1, proofs = {}, preload = preload }, Probe)
end

function Probe:step()
    local path = self.paths[self.next]
    if not path then return true end
    if self.next <= self.requiredCount then
        local class, reason, proof = resolve(path, true, self.preload)
        if not class then return false, reason end
        self.proofs[path] = proof
    else
        -- Try known secondary classes once. Their spawn code still resolves them
        -- when needed, so an unavailable dependency must not keep the cover open.
        pcall(resolve, path)
    end
    -- UE4SS wrappers do not pin the package. These observations apply only to
    -- this preloader's world and are rechecked at spawn time.
    self.next = self.next + 1
    return self.next > #self.paths
end

function Probe:resolve(path)
    assert(validPath(path), "invalid spawn class path")
    local proof = self.proofs[path]
    if proof then
        local class = StaticFindObject(path)
        if stillReady(class, proof) then return class end
        self.proofs[path] = nil
    end
    local class, reason, restored = resolve(path, true, self.preload)
    if class then self.proofs[path] = restored end
    return class, reason
end

return SpawnClass
