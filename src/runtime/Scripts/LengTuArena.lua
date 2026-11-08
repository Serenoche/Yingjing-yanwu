-- Candidate adapter for the original LengTu encounter. Its original abilities
-- locate these actor classes with GetActorOfClass. Supply arena-local, owned
-- markers instead of editing the game's classes. In Duanhun, only the exact
-- audited original markers may be borrowed and then restored; never delete them.
-- The caller chooses ground-checked locations; this module cannot prove navmesh
-- coverage or the authored encounter's behavior in a different level.
local SpawnClass = require("SpawnClass")
local LengTuArena = {}
local BASE = "/PBZCombatAsset/ActorData/Mobs/077_LengTu/"
local MAP = "/Game/Maps/B08_09_12_13/PBZ_Duanhun_WP"
local CELL = MAP .. "/_Generated_/2UDHA78THAAQTQAEHZG5XTBPY"
local DEFINITIONS = {
    { key = "toBattle", name = "BP_LengTu_ToBattle_SnapPoint", original = {
        name = "BP_LengTu_ToBattle_SnapPoint_C_UAID_E89C25A7512037EE02_2098980573",
        location = { X = -193170.61, Y = -112984.33, Z = 62132.34 }, yaw = 95 } },
    { key = "offBattle", name = "BP_LengTu_SwitchPhase_SnapPoint", original = {
        name = "BP_LengTu_SwitchPhase_SnapPoint_C_UAID_E89C25A751201FEE02_1328329292",
        location = { X = -192615.9, Y = -114859.39, Z = 62370.934 }, yaw = 102.71759 } },
    { key = "summon1", name = "BP_LengTu_SummonSlot_01", original = {
        name = "BP_LengTu_SummonSlot_01_C_UAID_E89C25A7512037EE02_1994640570",
        location = { X = -193235.16, Y = -112809.07, Z = 62038.65 }, yaw = 100 } },
    { key = "summon2", name = "BP_LengTu_SummonSlot_02", original = {
        name = "BP_LengTu_SummonSlot_02_C_UAID_E89C25A7512037EE02_2051815571", spatial = true,
        location = { X = -193897.48, Y = -112497.58, Z = 62018.957 }, yaw = 80 } },
    { key = "summon3", name = "BP_LengTu_SummonSlot_03", original = {
        name = "BP_LengTu_SummonSlot_03_C_UAID_E89C25A7512037EE02_2062619572", spatial = true,
        location = { X = -192521.47, Y = -112356.83, Z = 62008.383 }, yaw = 115 } },
}

local function valid(object)
    return object ~= nil and type(object.IsValid) == "function" and object:IsValid()
end

local function same(a, b)
    return valid(a) and valid(b) and a:GetAddress() == b:GetAddress()
end

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function address(object) return valid(object) and object:GetAddress() or 0 end
local function text(value) return type(value) == "string" and value or value:ToString() end
local function numbers(value, names)
    local copied = {}
    for _, name in ipairs(names) do
        assert(value and finite(value[name]), "冷荼定位点原变换无效")
        copied[name] = value[name]
    end
    return copied
end
local function transformSnapshot(actor)
    return { location = numbers(actor:K2_GetActorLocation(), { "X", "Y", "Z" }),
        rotation = numbers(actor:K2_GetActorRotation(), { "Pitch", "Yaw", "Roll" }),
        scale = numbers(actor:GetActorScale3D(), { "X", "Y", "Z" }) }
end
local function angleDistance(a, b) return math.abs((a - b + 180) % 360 - 180) end
local function matches(actual, expected)
    for _, axis in ipairs({ "X", "Y", "Z" }) do
        if math.abs(actual.location[axis] - expected.location[axis]) > 1 then return false end
        if math.abs(actual.scale[axis] - (expected.scale and expected.scale[axis] or 1)) > 0.0001 then return false end
    end
    for _, axis in ipairs({ "Pitch", "Yaw", "Roll" }) do
        if angleDistance(actual.rotation[axis], expected.rotation[axis]) > 0.2 then return false end
    end
    return true
end

local function originalIdentity(actor, definition)
    local expected = definition.original
    if text(actor:GetFName()) ~= expected.name then return false end
    local full = actor:GetFullName()
    local suffix = ":PersistentLevel." .. expected.name
    local original = definition.name .. "_C " .. MAP .. ".PBZ_Duanhun_WP" .. suffix
    if full == original then return true end
    -- The two spatial actors can retain their generated level package path,
    -- or be presented under the world PersistentLevel after cell registration.
    return expected.spatial and (full == definition.name .. "_C " .. CELL .. ".PBZ_Duanhun_WP" .. suffix
        or full == definition.name .. "_C " .. CELL .. ".2UDHA78THAAQTQAEHZG5XTBPY" .. suffix) or false
end

local function identity(self, entry)
    local actor = entry.actor
    if not valid(actor) or actor:IsActorBeingDestroyed() or not same(actor:GetWorld(), self.world) or not actor:IsA(entry.class) then return false end
    if entry.borrowed then
        return originalIdentity(actor, entry.definition) and actor:GetFullName() == entry.originalFullName
            and address(actor:GetOwner()) == entry.ownerAddress
    end
    return same(actor:GetOwner(), self.pawn)
end

local function verifyArrow(entry)
    local arrow = entry.actor.Arrow
    assert(valid(arrow), "冷荼定位点缺少原生 Arrow：" .. entry.key)
    local location = arrow:K2_GetComponentLocation()
    for _, axis in ipairs({ "X", "Y", "Z" }) do
        assert(finite(location[axis]) and math.abs(location[axis] - entry.point.location[axis]) <= 1,
            "冷荼定位点位置回读失败：" .. entry.key)
    end
end

local function move(self, actor, target)
    if matches(transformSnapshot(actor), target) then return end
    local transform = self.mathLibrary:MakeTransform(target.location, target.rotation, target.scale or { X = 1, Y = 1, Z = 1 })
    -- Generic Engine.Actor UFUNCTION; no pawn-only teleport helper or owner edit.
    -- bSweep=false, bTeleport=true, copied empty OUT FHitResult container.
    assert(actor:K2_SetActorTransform(transform, false, {}, true) == true, "冷荼原定位点移动失败")
    assert(matches(transformSnapshot(actor), target), "冷荼原定位点变换回读失败")
end

local function point(value, key)
    assert(type(value) == "table" and type(value.location) == "table" and type(value.rotation) == "table",
        "冷荼定位点缺失：" .. key)
    local location, rotation = value.location, value.rotation
    for _, name in ipairs({ "X", "Y", "Z" }) do assert(finite(location[name]), "冷荼定位点坐标无效：" .. key) end
    for _, name in ipairs({ "Pitch", "Yaw", "Roll" }) do assert(finite(rotation[name]), "冷荼定位点朝向无效：" .. key) end
    -- Copy plain numbers. Do not retain a caller's mutable transform or userdata.
    return { location = { X = location.X, Y = location.Y, Z = location.Z },
        rotation = { Pitch = rotation.Pitch, Yaw = rotation.Yaw, Roll = rotation.Roll } }
end

local function foreignMarker(self)
    for _, definition in ipairs(DEFINITIONS) do
        for _, actor in ipairs(FindAllOf(definition.name .. "_C") or {}) do
            if valid(actor) and same(actor:GetWorld(), self.world) and not actor:IsActorBeingDestroyed() then
                if not self.owned[actor:GetAddress()] then
                    return "场地已有非本场冷荼定位点：" .. definition.key
                end
            end
        end
    end
end

local Session = {}
Session.__index = Session

function Session:ownsMarker(actor)
    if not valid(actor) or actor:IsActorBeingDestroyed() or not same(actor:GetWorld(), self.world) then return false end
    if not self.owned[actor:GetAddress()] then return false end
    for _, entry in ipairs(self.entries) do
        if same(actor, entry.actor) then return identity(self, entry) end
    end
    return false
end

function Session:owns(actor)
    return self:ownsMarker(actor) or (self.summons and self.summons:owns(actor)) or false
end

function Session:bindBoss(actor)
    assert(self.summons, "冷荼召唤控制尚未准备完成")
    return self.summons:bindBoss(actor)
end

function Session:update(pawn, running)
    assert(not self.closed, "冷荼场地适配已关闭")
    assert(same(pawn, self.pawn) and same(pawn:GetWorld(), self.world), "冷荼场地角色或世界已切换")
    for _, entry in ipairs(self.entries) do
        assert(identity(self, entry), "冷荼本场定位点已失效：" .. entry.key)
        if entry.borrowed then
            assert(matches(transformSnapshot(entry.actor), entry.point), "冷荼借用定位点已被外部移动：" .. entry.key)
        end
        verifyArrow(entry)
    end
    local conflict = foreignMarker(self)
    assert(not conflict, conflict)
    if self.summons then self.summons:update(pawn, running) end
    return true
end

function Session:close()
    if self.closed and #self.entries == 0 then return end
    self.closed = true
    if self.summons then self.summons:close(); self.summons = nil end
    -- Captured original actors are restored, never destroyed. Retain failed
    -- restorations so a caller can retry cleanup; never lose the only snapshot.
    local failure, remaining, remainingOwned = nil, {}, {}
    for index = #self.entries, 1, -1 do
        local entry = self.entries[index]
        local actor = entry.actor
        if valid(actor) and not actor:IsActorBeingDestroyed() then
            local ok, reason = pcall(function()
                if entry.borrowed then
                    assert(identity(self, entry), "冷荼原定位点恢复身份不匹配")
                    move(self, actor, entry.originalTransform)
                else
                    assert(same(actor:GetWorld(), self.world) and actor:IsA(entry.class), "冷荼定位点清理身份不匹配")
                    actor:K2_DestroyActor()
                end
            end)
            if not ok then
                failure = failure or tostring(reason)
                remaining[#remaining + 1], remainingOwned[actor:GetAddress()] = entry, true
            end
        end
    end
    self.entries, self.owned = remaining, remainingOwned
    if failure then error(failure, 0) end
end

function LengTuArena.new(gameplay, pawn, points, options)
    assert(valid(gameplay) and valid(pawn) and not pawn:IsActorBeingDestroyed(), "冷荼场地上下文不可用")
    local world = pawn:GetWorld()
    assert(valid(world) and type(points) == "table", "冷荼场地或定位点不可用")
    local prepared = {}
    -- Prepare everything before creating any actors. A package still loading
    -- returns a retryable reason and leaves the world completely unchanged.
    for _, definition in ipairs(DEFINITIONS) do
        prepared[#prepared + 1] = { key = definition.key, name = definition.name, definition = definition,
            point = point(points[definition.key], definition.key) }
    end
    for _, entry in ipairs(prepared) do
        local path = BASE .. entry.name .. "." .. entry.name .. "_C"
        local class, reason = SpawnClass.resolve(path)
        if not class then return nil, reason end
        entry.class = class
    end
    local mathLibrary = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    assert(valid(mathLibrary), "冷荼定位点变换接口不可用")
    local self = setmetatable({ pawn = pawn, world = world, mathLibrary = mathLibrary,
        entries = {}, owned = {}, closed = false }, Session)
    -- Complete every identity/transform check before moving an original or
    -- creating a replacement. GetActorOfClass must have exactly one candidate.
    for _, entry in ipairs(prepared) do
        local found = {}
        for _, actor in ipairs(FindAllOf(entry.name .. "_C") or {}) do
            if valid(actor) and same(actor:GetWorld(), world) and not actor:IsActorBeingDestroyed() then found[#found + 1] = actor end
        end
        assert(#found <= 1, "场地存在重复冷荼定位点：" .. entry.key)
        if #found == 1 then
            local actor = found[1]
            assert(actor:IsA(entry.class) and originalIdentity(actor, entry.definition), "场地已有非本场冷荼定位点：" .. entry.key)
            local captured, original = transformSnapshot(actor), entry.definition.original
            local expected = { location = original.location, rotation = { Pitch = 0, Yaw = original.yaw, Roll = 0 } }
            assert(matches(captured, expected), "冷荼原定位点已被修改，拒绝借用：" .. entry.key)
            entry.actor, entry.borrowed, entry.originalTransform = actor, true, captured
            entry.originalFullName, entry.ownerAddress = actor:GetFullName(), address(actor:GetOwner())
        end
    end
    local ok, reason = pcall(function()
        for _, entry in ipairs(prepared) do
            if entry.borrowed then
                self.entries[#self.entries + 1] = entry
                self.owned[entry.actor:GetAddress()] = true
                move(self, entry.actor, entry.point)
            else
            local transform = mathLibrary:MakeTransform(entry.point.location, entry.point.rotation, { X = 1, Y = 1, Z = 1 })
            -- Engine's reflected generic actor spawn. AlwaysSpawn=1;
            -- MultiplyWithRoot=1. These are marker actors, not combat characters.
            local actor = gameplay:BeginDeferredActorSpawnFromClass(pawn, entry.class, transform, 1, pawn, 1)
            assert(valid(actor), "冷荼定位点生成失败：" .. entry.key)
            entry.actor = actor
            self.entries[#self.entries + 1] = entry
            self.owned[actor:GetAddress()] = true
            local finished = gameplay:FinishSpawningActor(actor, transform, 1)
            assert(same(finished, actor), "冷荼定位点初始化失败：" .. entry.key)
            assert(same(actor:GetOwner(), pawn) and same(actor:GetWorld(), world) and actor:IsA(entry.class),
                "冷荼定位点归属回读失败：" .. entry.key)
            end
            verifyArrow(entry)
        end
        self:update(pawn)
    end)
    if not ok then
        local cleaned, cleanupReason = pcall(function() self:close() end)
        if not cleaned then error(tostring(reason) .. "; cleanup: " .. tostring(cleanupReason), 0) end
        error(reason, 0)
    end
    if options and options.summons == true then
        local loaded, summons, waiting = pcall(function() return require("LengTuSummons").new(pawn, points) end)
        if not loaded or not summons then
            self:close()
            if not loaded then error(summons, 0) end
            return nil, waiting
        end
        self.summons = summons
    end
    return self
end

return LengTuArena
