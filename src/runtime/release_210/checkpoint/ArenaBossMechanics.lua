local SceneArena = require("SceneArena")
local SpawnClass = require("SpawnClass")
local Terrain = require("ArenaTerrain")

local Mechanics, Session = {}, {}
Session.__index = Session

local DUYAN = "BP_Monster_DuYanBoss"
local SCAVENGER = "BP_Monster_Scavenger"
local LEIDANG = "BP_Monster_LeiDang_P2"
local DUYAN_ROOT = "/PBZCombatAsset/ActorData/Mobs/059_DuYan/"
local SPAWNER = "/SGameAI/Tools/Spawner/BP_AISpawner.BP_AISpawner_C"
local MATH = "/Script/Engine.Default__KismetMathLibrary"
local ACTORS = "/Script/SGameAI.Default__SGameAIFunctionLibrary"
local POST = "/Script/Engine.PostProcessVolume"
local ONE = { X = 1, Y = 1, Z = 1 }
local FLAT = { Pitch = 0, Yaw = 0, Roll = 0 }

local duyanMarkers = {
    "BP_DuYan_CA_Snap_Center", "BP_GroundEye_01", "BP_GroundEye_02", "BP_GroundEye_03", "BP_GroundEye_04",
}
local duyanPattern = { {0,0}, {-1350,-1050}, {1350,-1050}, {1350,1050}, {-1350,1050} }
local postTags = { [SCAVENGER] = "Scavenger_P2_Post", [DUYAN] = "DuYanP2" }

local function valid(object)
    return object and type(object.IsValid) == "function" and object:IsValid()
end

local function same(left, right)
    return valid(left) and valid(right) and left:GetAddress() == right:GetAddress()
end

local function location(actor)
    local point = actor:K2_GetActorLocation()
    return { X = point.X, Y = point.Y, Z = point.Z }
end

local function rotation(actor)
    local value = actor:K2_GetActorRotation()
    return { Pitch = value.Pitch, Yaw = value.Yaw, Roll = value.Roll }
end

local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "场景机制接口未就绪：" .. path)
    return object
end

local function log(message) print("[PBZArenaBossMechanics] " .. message .. "\n") end

function Session:spawn(class, at, facing, beforeFinish)
    local transform = self.math:MakeTransform(at, facing, ONE)
    local actor = self.actors:SpawnActorDeferred(self.pawn, class, transform, 3)
    assert(valid(actor), "场景机制对象创建失败")
    self.created[#self.created+1] = actor
    actor:SetOwner(self.pawn)
    if beforeFinish then beforeFinish(actor) end
    assert(same(actor, self.gameplay:FinishSpawningActor(actor, transform, 1)), "场景机制对象初始化失败")
    assert(SceneArena.actorIsInWorld(actor, self.world), "场景机制对象不在当前战斗世界")
    return actor
end

function Session:marker(class, point, facing, snap)
    local actor = self.gameplay:GetActorOfClass(self.pawn, class)
    if valid(actor) then
        assert(SceneArena.actorIsInWorld(actor, self.world) and not actor:IsActorBeingDestroyed()
            and not valid(actor:GetOwner()), "场景定位点被其他战斗占用")
        local at = location(actor)
        -- The native lookups take the first instance, including streamed map actors.
        local height = self.scene.combatHeight
        if self.scene.id ~= "meiguhu_duyan" or not Terrain.contains(at, self.scene.combatBoundary)
            or at.Z < height.min or at.Z > height.max then
            self.borrowed[#self.borrowed+1] = { actor = actor, location = at, rotation = rotation(actor) }
            assert(actor:K2_SetActorLocationAndRotation(point, facing, false, {}, true), "场景定位点未能回到战区")
        end
    else
        actor = self:spawn(class, point, facing)
        actor:SetActorEnableCollision(false)
        actor:SetActorHiddenInGame(true)
    end
    assert(same(self.gameplay:GetActorOfClass(self.pawn, class), actor), "原版技能无法取得场景定位点")
    if snap then assert(valid(actor.Arrow), "独眼弓客定位点缺少原版箭头组件") end
end

function Session:postProcess(id, center)
    local tag, postClass = FName(postTags[id]), required(POST)
    local actors = {}
    self.gameplay:GetAllActorsOfClass(self.pawn, postClass, actors)
    local existing
    for _, reference in ipairs(actors) do
        local actor = valid(reference) and reference or reference:get()
        if SceneArena.actorIsInWorld(actor, self.world) and actor:ActorHasTag(tag) then
            if existing then return end -- the original NPC also requires a unique tag
            existing = actor
        end
    end
    if existing then
        self.posts[#self.posts+1] = { actor = existing, weight = existing.BlendWeight, unbound = existing.bUnbound }
        existing.bUnbound = true
        return
    end
    local actor = self:spawn(postClass, center, FLAT, function(volume)
        volume.Tags = { tag }
        volume.bUnbound, volume.BlendWeight, volume.Priority = true, 0, 205
    end)
    assert(actor:ActorHasTag(tag), "首领二阶段滤镜未完成注册")
    if id == DUYAN then
        actor.Settings.bOverride_ColorGain = true
        actor.Settings.ColorGain = { X = 1, Y = .9, Z = .9, W = 1 }
    else
        actor.Settings.bOverride_ColorGainShadows = true
        actor.Settings.ColorGainShadows = { X = .75, Y = .9, Z = 1, W = 1 }
    end
end

function Session:bind(actor, member, ground, facing)
    if member.id ~= LEIDANG or not self.spawnerClass then return end
    local point = Terrain.recoveryGround(self.pawn, self.system, self.scene, ground)
        or self.leiDangGround
    -- Both the native CA warp and its falling-rock projectiles read the spawner.
    local origin = self:spawn(self.spawnerClass, point, facing, function(spawner)
        spawner.SpawnerID = spawner:GetFName()
        spawner.InitialSpawn, spawner.ShouldSpawn = false, false
        spawner:SetActorEnableCollision(false)
        spawner:SetActorHiddenInGame(true)
    end)
    origin.SpawnedAI = actor
    actor:OnSpawnFromSpawner(origin)
    assert(same(actor:GetAISpawner(), origin), "雷当二阶段落点未完成原版绑定")
    origin:SetOwner(actor)
end

function Session:close()
    local failure
    for index = #self.created, 1, -1 do
        local actor = self.created[index]
        if SceneArena.actorIsInWorld(actor, self.world) then
            local ok, reason = pcall(actor.K2_DestroyActor, actor)
            if not ok then failure = reason else table.remove(self.created, index) end
        else
            table.remove(self.created, index)
        end
    end
    for index = #self.borrowed, 1, -1 do
        local saved = self.borrowed[index]
        if SceneArena.actorIsInWorld(saved.actor, self.world) then
            local ok, restored = pcall(saved.actor.K2_SetActorLocationAndRotation, saved.actor,
                saved.location, saved.rotation, false, {}, true)
            if not ok or not restored then failure = "原版首领定位点未能归还" else table.remove(self.borrowed, index) end
        else
            table.remove(self.borrowed, index)
        end
    end
    for index = #self.posts, 1, -1 do
        local saved = self.posts[index]
        if SceneArena.actorIsInWorld(saved.actor, self.world) then
            local ok, reason = pcall(function()
                saved.actor.BlendWeight, saved.actor.bUnbound = saved.weight, saved.unbound
            end)
            if not ok then failure = reason else table.remove(self.posts, index) end
        else
            table.remove(self.posts, index)
        end
    end
    if failure then error(failure, 0) end
end

function Mechanics.closeFor(run)
    if not run.bossMechanics then return true end
    local ok, reason = pcall(run.bossMechanics.close, run.bossMechanics)
    if ok then
        run.bossMechanics, run.bossMechanicsCleanup = nil, nil
        return true
    end
    if reason ~= run.bossMechanicsCleanup then log("清理待重试 " .. tostring(reason)) end
    run.bossMechanicsCleanup = reason
    return false, tostring(reason)
end

function Mechanics.new(pawn, gameplay, system, scene, stage)
    if not scene.portableBossMechanics then return end
    local members = {}
    for _, member in ipairs(stage.members) do members[member.id] = true end
    if not (members[DUYAN] or members[SCAVENGER] or members[LEIDANG]) then return end
    local world = SceneArena.runtimeWorld(pawn)
    if not valid(world) then return nil, "等待首领场景机制所在世界" end

    local classes, points, facing, center, spawnerClass, leiDangGround = {}
    if members[DUYAN] then
        for index, name in ipairs(duyanMarkers) do
            local folder = index == 1 and DUYAN_ROOT or DUYAN_ROOT .. "WeaponData/Burst/Ground/"
            local class, why = SpawnClass.resolve(folder .. name .. "." .. name .. "_C")
            if not valid(class) then return nil, why end
            classes[index] = class
        end
        points, facing, center = Terrain.place(pawn, system, scene, duyanPattern, nil, 450)
        if not points then return nil, "等待独眼弓客的中心点和四个地眼落点" end
        points[1].Z = points[1].Z+105
    end
    if members[LEIDANG] then
        local why
        spawnerClass, why = SpawnClass.resolve(SPAWNER)
        if not valid(spawnerClass) then return nil, why end
        local landing = Terrain.place(pawn, system, scene, { {0,0} }, scene.spawnPoints[1], 450)
        if not landing then return nil, "等待雷当二阶段的回落地面" end
        leiDangGround = landing[1]
    end
    local session = setmetatable({ pawn = pawn, world = world, gameplay = gameplay, scene = scene, system = system,
        math = required(MATH), actors = required(ACTORS), created = {}, borrowed = {}, posts = {},
        spawnerClass = spawnerClass, leiDangGround = leiDangGround }, Session)
    local ok, why = pcall(function()
        for index, class in ipairs(classes) do session:marker(class, points[index], facing, index == 1) end
    end)
    if not ok then
        session:close()
        error(why, 0)
    end
    for _, id in ipairs({ DUYAN, SCAVENGER }) do
        if members[id] then
            local count = #session.created
            local ready, reason = pcall(session.postProcess, session, id, center or location(pawn))
            if not ready then
                if #session.created > count then
                    local volume = table.remove(session.created)
                    if SceneArena.actorIsInWorld(volume, world) then volume:K2_DestroyActor() end
                end
                log("可选阶段滤镜载入失败 " .. id .. " " .. tostring(reason))
            end
        end
    end
    log("prepared scene=" .. scene.id)
    return session
end

return Mechanics
