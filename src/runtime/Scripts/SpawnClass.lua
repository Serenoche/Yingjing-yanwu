-- An existing UClass can still belong to an asynchronously loading package.
-- Do not hand such a class to SpawnActorDeferred: its event Func may be null.
local SpawnClass = {}
local confirmed = {}
-- UE 5.7 EObjectFlags, verified against the pinned game/loader sources.
-- NeedInitialization|NeedLoad|NeedPostLoad|NeedPostLoadSubobjects|
-- BeingRegenerated|WillBeLoaded. WasLoaded/LoadCompleted do not imply readiness.
local PENDING = 0x08023600
local EVENTS = { "UserConstructionScript", "ReceiveBeginPlay", "ReceiveTick", "Init Level" }

local function valid(object)
    return object ~= nil and type(object.IsValid) == "function" and object:IsValid()
end

local function ready(class, path)
    if not valid(class) then return false, "等待角色类型载入" end
    if class:HasAnyFlags(PENDING) then return false, "等待角色类型完成初始化" end
    -- This pinned UE4SS getter reads ClassDefaultObject; it never constructs a
    -- CDO or invokes an event on a partially loaded class.
    local cdo = class:GetCDO()
    if not valid(cdo) then return false, "等待角色默认对象载入" end
    if cdo:HasAnyFlags(PENDING) then return false, "等待角色默认对象完成初始化" end
    local ancestor, ancestorPath, seen = class, path, {}
    for _ = 1, 32 do
        local address = ancestor:GetAddress()
        assert(not seen[address], "spawn class inheritance contains a cycle")
        seen[address] = true
        if ancestor:HasAnyFlags(PENDING) then return false, "等待角色继承类型完成初始化：" .. ancestorPath end
        for _, name in ipairs(EVENTS) do
            local event = StaticFindObject(ancestorPath .. ":" .. name)
            if valid(event) and event:HasAnyFlags(PENDING) then
                return false, "等待角色蓝图事件完成初始化：" .. ancestorPath .. ":" .. name
            end
        end
        -- GetSuperStruct returns a UStruct wrapper. Read flags/functions only;
        -- do not attempt to create/get a parent CDO through that wrapper.
        ancestor = ancestor:GetSuperStruct()
        if not valid(ancestor) then return true end
        ancestorPath = ancestor:GetFullName():match("^%S+ (.+)$")
        assert(ancestorPath, "spawn ancestor has no reflected object path")
    end
    error("spawn class inheritance exceeds the supported depth")
end

function SpawnClass.resolve(path)
    assert(type(path) == "string" and path:match("^/[A-Za-z0-9_./-]+_C$"), "invalid spawn class path")
    local class = StaticFindObject(path)
    if valid(class) and confirmed[path] == class:GetAddress() then
        local complete = ready(class, path)
        if complete then return class end
        confirmed[path] = nil
    end

    -- LoadAsset uses AssetRegistry.GetAsset -> FAssetData.GetAsset, which loads
    -- an existing but incomplete package synchronously. Generated classes and
    -- blueprint assets can have different registry paths; keep both forms.
    local loaded = false
    for _, assetPath in ipairs({ path, (path:gsub("_C$", "")) }) do
        local ok, asset, _, didLoad = pcall(LoadAsset, assetPath)
        if ok and didLoad == true and valid(asset) then loaded = true; break end
    end
    if not loaded then return nil, "等待首领资源包完整载入：" .. path end
    class = StaticFindObject(path)
    local complete, reason = ready(class, path)
    if not complete then return nil, reason .. "：" .. path end
    confirmed[path] = class:GetAddress()
    print("[PBZTestArenaNative] Spawn class package ready: " .. path .. "\n")
    return class
end

return SpawnClass
