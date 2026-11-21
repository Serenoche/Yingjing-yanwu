local SpawnClass = require("SpawnClass")
local Mechanics = {}
local Session = {}
Session.__index = Session

local LEI_CLEAR = "/PBZCombatAsset/ActorData/Mobs/047_LeiDang/Ability/Abilities/GA_LeiDang_CA"
local PLAYER_HEALTH = "/Game/RenewalContent/Prototypes/Character/BP_RenewalPlayer.BP_RenewalPlayer_C:Health Post Func"
local ZUO = "/PBZCombatAsset/ActorData/Mobs/054_ZuoShang/"
local ZUO_SHANG = "BP_Monster_ZuoShang_Ending"
local MO_YUAN = "BP_Monster_MoTian"
local VANISH_GRACE, DISSOLVE_HOLD = .45, 2.0
local ZERO, FLAT = { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 }
local CLEAR, WORLD_STATIC = { R = 0, G = 0, B = 0, A = 0 }, { 0 }
local BOMB_MESHES = { M087 = "BombMan", M088 = "BombMan_Bing", M089 = "BombMan_Du" }
local LEASH = { [ZUO_SHANG] = true, BP_Monster_ZuoShang_P2 = true, [MO_YUAN] = true,
    BP_Monster_YuCong_FirstTime = true, BP_Monster_MuXiaoKui_P2 = true, BP_Monster_YuBi = true,
    BP_Monster_LeiDang = true, BP_Monster_LeiDang_P2 = true,
    BP_Monster_AHua_GuiTouDao = true, BP_Monster_ChiLian_P2 = true, BP_Monster_WuLengShuang = true,
    BP_Monster_FemaleVessel_YuDing = true, BP_Monster_FengXueDaoKe = true }

local function log(message) print("[PBZBloodyPalace] " .. message .. "\n") end
local function valid(object) return object ~= nil and object:IsValid() end
local function same(a, b) return valid(a) and valid(b) and a:GetAddress() == b:GetAddress() end
local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "首领机制接口未就绪：" .. path)
    return object
end

function Mechanics.prepareAppearance(actor, id)
    local expected = BOMB_MESHES[id]
    if not expected then return end
    local ok, reason = pcall(function()
        local mesh = actor.Mesh
        assert(valid(mesh), "爆弹兵骨骼网格未就绪")
        local asset = mesh:GetSkeletalMeshAsset()
        assert(valid(asset) and asset:GetFName():ToString() == expected, "爆弹兵原版网格不匹配")
        -- Skip the animation budget for this body before it registers in BeginPlay.
        mesh:SetAutoRegisterWithBudgetAllocator(false)
        mesh.bEnableUpdateRateOptimizations = false
        mesh:SetForcedLOD(1)
    end)
    if not ok then log("bombman pose setup; unit=" .. id .. "; " .. tostring(reason)) end
end

function Mechanics.stabilizeAppearance(actor, id)
    if not BOMB_MESHES[id] then return end
    local ok, reason = pcall(function()
        local mesh, tube = actor.Mesh, actor.Tube
        if valid(mesh) then mesh:PrestreamTextures(12, false, 0) end
        if valid(tube) then
            -- The physics-driven Blueprint tube is constructed during FinishSpawning.
            tube.bEnableUpdateRateOptimizations = false
            tube.VisibilityBasedAnimTickOption = 0 -- AlwaysTickPoseAndRefreshBones
            tube:SetForcedLOD(1)
            tube:PrestreamTextures(12, false, 0)
        end
        local cloth = actor:GetComponentByClass(required("/Script/ChaosClothAssetEngine.ChaosClothComponent"))
        if valid(cloth) then
            cloth:SetForcedLOD(1)
            cloth:PrestreamTextures(12, false, 0)
        end
    end)
    log((ok and "bombman visuals prepared; unit=" or "bombman visuals fallback; unit=") .. id
        .. (ok and "" or "; " .. tostring(reason)))
end

function Session:hook(path, callback)
    required(path)
    local pre, post = RegisterHook(path, function(...)
        if self.closed then return end
        local ok, reason = pcall(callback, ...)
        if not ok and reason ~= self.hookError then
            self.hookError = reason
            log("native mechanic hook: " .. tostring(reason))
        end
    end)
    self.hooks[#self.hooks + 1] = { path = path, pre = pre, post = post }
end

function Session:bind(actor, id, ground)
    if self.ordinary and not LEASH[id] then return end
    assert(valid(actor) and same(actor:GetWorld(), self.world), "机制首领不属于当前场景")
    if self.ordinary then
        self.bosses[actor:GetAddress()] = { actor = actor, id = id, ground = ground }
    else
        self.boss = actor
    end
end

local function groundHeight(hit)
    if hit.ImpactPoint and hit.ImpactNormal and hit.ImpactNormal.Z >= 0.7 then
        return hit.ImpactPoint.Z
    end
end

function Session:groundAt(system, scene, x, y, ignored)
    if self.xigu and not ignored then return self.xigu.mechanicGround(self.pawn, system, scene, x, y) end
    local trace = scene.spawnTrace
    local from, to = { X = x, Y = y, Z = trace.top }, { X = x, Y = y, Z = trace.bottom }
    local hit = {}
    if system:LineTraceSingle(self.pawn, from, to, 0, false, ignored or {}, 0, hit, true, CLEAR, CLEAR, 0) then
        local floor = groundHeight(hit)
        if floor then return floor end
    end
    if trace.worldStaticFallback then
        hit = {}
        if system:LineTraceSingleForObjects(self.pawn, from, to, WORLD_STATIC, false, ignored or {},
            0, hit, true, CLEAR, CLEAR, 0) then
            return groundHeight(hit)
        end
    end
end

function Session:prepareArenaBounds(system, scene)
    local preferred = self.xigu and scene.portalPoint or (scene.chiLianUltimate and scene.chiLianUltimate.center)
    local candidates = preferred and { preferred } or {}
    if not self.xigu then
        for _, at in ipairs(scene.spawnPoints) do candidates[#candidates + 1] = at end
    end
    for _, at in ipairs(candidates) do
        local floor = self:groundAt(system, scene, at.X, at.Y)
        if floor then
            self.center = { X = at.X, Y = at.Y, Z = floor }
            return true
        end
    end
    return false, "等待首领机制回位地面"
end

function Session:close()
    if self.closed then return end
    self.closed = true
    for _, hook in ipairs(self.hooks) do
        local ok, reason = pcall(UnregisterHook, hook.path, hook.pre, hook.post)
        if not ok then log("native mechanic hook cleanup: " .. tostring(reason)) end
    end
    for index = #self.actors, 1, -1 do
        local actor = self.actors[index]
        if valid(actor) and same(actor:GetWorld(), self.world) then actor:K2_DestroyActor() end
    end
    for _, saved in ipairs(self.borrowed) do
        if valid(saved.actor) and same(saved.actor:GetWorld(), self.world) then
            local ok, restored = pcall(saved.actor.K2_SetActorLocationAndRotation, saved.actor,
                saved.location, saved.rotation, false, {}, true)
            if not ok or not restored then log("native anchor restore failed; " .. saved.name) end
        end
    end
    self.hooks, self.actors, self.borrowed, self.bosses, self.boss = {}, {}, {}, {}, nil
end

local function layoutAnchors(self, system, scene, yaw, frontX, frontY, span)
    local center = self.center
    local function point(along, above)
        local x, y = center.X + along * frontX * span, center.Y + along * frontY * span
        local floor = self:groundAt(system, scene, x, y)
        if floor and (self.xigu or math.abs(floor - center.Z) <= 150) then
            return { X = x, Y = y, Z = floor + above }
        end
    end
    local anchors = {
        { "BP_ZuoShang_CA_02_SnapPoint", point(-550, 0) },
        { "BP_ZuoShang_CA_03_DomainCenter", point(0, 0) },
        { "BP_ZuoShang_CA_03_SnapPoint", point(-825, 1402) },
        { "BP_ZuoShang_CA_03_LandingPoint", point(825, 0) },
    }
    for _, entry in ipairs(anchors) do if not entry[2] then return end end
    return anchors, { Pitch = 0, Yaw = yaw, Roll = 0 }
end

local function anchorLayout(self, system, scene, mathLibrary)
    if self.xigu then
        local portal = self.xigu.portalDestination(self.pawn, system, scene)
        if portal then
            return layoutAnchors(self, system, scene, (portal.rotation.Yaw + 180) % 360, portal.frontX, portal.frontY, 1)
        end
        return
    end
    local approach = (scene.phaseReturnPoints and scene.phaseReturnPoints[1]) or scene.anchor
    local facing = mathLibrary:FindLookAtRotation(self.center, approach).Yaw
    for _, span in ipairs({ 1, .75, .5 }) do
        for _, offset in ipairs({ 0, 90 }) do
            local yaw = (facing + offset) % 360
            local radians = math.rad(yaw)
            local anchors, rotation = layoutAnchors(self, system, scene, yaw, math.cos(radians), math.sin(radians), span)
            if anchors then return anchors, rotation end
        end
    end
end

local function createAnchors(self, gameplay, system, scene)
    local mathLibrary = required("/Script/Engine.Default__KismetMathLibrary")
    local anchors, rotation = anchorLayout(self, system, scene, mathLibrary)
    if not anchors then return false, "等待左殇大招的安全落点" end
    for _, entry in ipairs(anchors) do
        local name = entry[1]
        local class, reason = SpawnClass.resolve(ZUO .. name .. "." .. name .. "_C")
        if not valid(class) then return false, reason end
        entry.class = class
    end
    local spawner = required("/Script/SGameAI.Default__SGameAIFunctionLibrary")
    local scale = { X = 1, Y = 1, Z = 1 }
    for _, entry in ipairs(anchors) do
        local actor = gameplay:GetActorOfClass(self.pawn, entry.class)
        if valid(actor) then
            assert(self.ordinary and same(actor:GetWorld(), self.world), "左殇定位点在当前场景中重复：" .. entry[1])
            -- The ability resolves the first instance of this class in the world.
            -- In a private arena, relocate that instance for this stage and restore it at teardown.
            local at = actor:K2_GetActorLocation()
            local location = { X = at.X, Y = at.Y, Z = at.Z }
            local angles = actor:K2_GetActorRotation()
            self.borrowed[#self.borrowed + 1] = { actor = actor, name = entry[1], location = location,
                rotation = { Pitch = angles.Pitch, Yaw = angles.Yaw, Roll = angles.Roll } }
            assert(actor:K2_SetActorLocationAndRotation(entry[2], rotation, false, {}, true), "左殇原版定位点移动失败：" .. entry[1])
        else
            local transform = mathLibrary:MakeTransform(entry[2], rotation, scale)
            actor = spawner:SpawnActorDeferred(self.pawn, entry.class, transform, 1)
            assert(valid(actor), "左殇定位点创建失败：" .. entry[1])
            self.actors[#self.actors + 1] = actor
            actor:SetOwner(self.pawn)
            gameplay:FinishSpawningActor(actor, transform, 1)
            actor:SetActorEnableCollision(false)
            actor:SetActorHiddenInGame(true)
        end
        assert(valid(actor.Arrow) and same(gameplay:GetActorOfClass(self.pawn, entry.class), actor),
            "游戏未读到左殇定位点：" .. entry[1])
        local at = actor.Arrow:K2_GetComponentLocation()
        assert((at.X - entry[2].X)^2 + (at.Y - entry[2].Y)^2 + (at.Z - entry[2].Z)^2 < 25,
            "左殇定位点落点偏移：" .. entry[1])
    end
    self.landing = anchors[4][2]
    if not self.ordinary then
        self.safeReturn = self.xigu.phaseDestination(self.pawn, system, scene)
        if not self.safeReturn then return false, "等待左殇互动的玩家回位点" end
    end
    local grabName = "GA_ZuoShang_CA_GEx_01"
    local grab = ZUO .. "Ability/Abilities/" .. grabName .. "." .. grabName .. "_C"
    local class, reason = SpawnClass.resolve(grab)
    if not valid(class) then return false, reason end
    self:hook(grab .. ":K2_ActivateAbility", function(context)
        local ability = context:get()
        local actor = ability:GetAvatarActorFromActorInfo()
        if self.ordinary then
            if not valid(actor) or not same(actor:GetWorld(), self.world) then return end
            local boss = self.bosses[actor:GetAddress()]
            if not boss or boss.id ~= ZUO_SHANG or not same(actor, boss.actor) then return end
        elseif not same(actor, self.boss) then return end
        local warp = actor:GetComponentByClass(required("/Script/MotionWarping.MotionWarpingComponent"))
        if valid(warp) then
            warp:AddOrUpdateWarpTargetFromLocationAndRotation(FName("LandingPoint"), self.landing, rotation)
        end
    end)
    log(("ZuoShang native snap, landing and domain anchors ready; center=%.1f,%.1f"):format(self.center.X, self.center.Y))
    return true
end

local function watchLeiDangRefill(self)
    local class, reason = SpawnClass.resolve(LEI_CLEAR .. ".GA_LeiDang_CA_C")
    if not valid(class) then return false, reason end
    -- The original phase-death ability sends a map-clear event to the player.
    -- Pair its callbacks with the player's already-supported HP notification.
    -- This avoids changing arguments on the Blueprint VM's static native call.
    self:hook(PLAYER_HEALTH, function(context, newValue, oldValue)
        if not same(context:get(), self.pawn) then return end
        local after, before = newValue:get(), oldValue:get()
        local attributes = self.pawn.AttributeSetBase
        if type(before) == "number" and type(after) == "number" and before > 0 and after > before + .01
            and math.abs(after - attributes.Health_Max.CurrentValue) <= .01 then
            self.stockRefill = { before = before, after = after, at = self.gameplay:GetTimeSeconds(self.pawn) }
        end
    end)
    for _, callback in ipairs({ "Added_CC586AF9455AC2B7E2364DB3FB9328BF", "K2_OnEndAbility" }) do
        self:hook(LEI_CLEAR .. ".GA_LeiDang_CA_C:" .. callback, function(context)
            if same(context:get():GetAvatarActorFromActorInfo(), self.boss) then
                self.phaseSignalAt = self.gameplay:GetTimeSeconds(self.pawn)
            end
        end)
    end
    return true
end

function Session:preserveLeiDangHealth()
    local refill, signal = self.stockRefill, self.phaseSignalAt
    if not refill or not signal or math.abs(refill.at - signal) > .35 then return end
    self.stockRefill, self.phaseSignalAt = nil, nil
    local hp = self.pawn.AttributeSetBase.Health.CurrentValue
    if hp <= 0 or hp > refill.after + .01 then return end
    local carry = math.max(1, refill.before - (refill.after - hp))
    require("PracticeMode").setAttributeValue(self.pawn, "Health", carry)
    log(("LeiDang intermediate stock refill reverted; before=%.2f; refilled=%.2f; kept=%.2f")
        :format(refill.before, refill.after, self.pawn.AttributeSetBase.Health.CurrentValue))
end

local function playDeathDissolve(boss)
    local effect = boss.VanishParticle -- BP_RenewalNPC's original NS_DeathDissolve_001.
    assert(valid(effect), "首领原版退场特效未就绪")
    local library = required("/Script/Niagara.Default__NiagaraFunctionLibrary")
    local niagara = required("/Script/Niagara.NiagaraComponent")
    local skeletalMesh = required("/Script/Engine.SkeletalMeshComponent")
    local components = boss:K2_GetComponentsByClass(skeletalMesh)
    local meshes = {}
    -- Copy the returned array before component queries can reuse its storage.
    for index = 1, #components do
        local mesh = components[index]
        if mesh and type(mesh.IsValid) ~= "function" then mesh = mesh:get() end
        if mesh then meshes[#meshes + 1] = mesh end
    end
    local native, started = 0, 0
    for _, mesh in ipairs(meshes) do
        if valid(mesh) and mesh:IsVisible() and valid(mesh:GetSkeletalMeshAsset()) then
            local playing = false
            for index = 0, mesh:GetNumChildrenComponents() - 1 do
                local child = mesh:GetChildComponent(index)
                if valid(child) and child:IsA(niagara) and child:IsActive() and same(child:GetAsset(), effect) then
                    playing = true
                    break
                end
            end
            if playing then
                native = native + 1
            elseif valid(library:SpawnSystemAttached(effect, mesh, FName("None"), ZERO, FLAT, 0, true, true, 0, false)) then
                started = started + 1
            end
        end
    end
    return native, started
end

function Session:deathEffectFinished(now, clearedAt)
    if self.id ~= MO_YUAN then return true end
    local boss = self.boss
    if not valid(boss) or boss:IsActorBeingDestroyed() then return true end
    if self.dissolveUntil then return now >= self.dissolveUntil end
    -- Let the native On Vanish callback start its dissolve after the QTE.
    -- If it did not fire, attach the same Niagara asset to the surviving meshes.
    if now - clearedAt < VANISH_GRACE then return false end
    local ok, native, started = pcall(playDeathDissolve, boss)
    if not ok then
        log("MoYuan death dissolve unavailable: " .. tostring(native))
        return true
    end
    log(("MoYuan death dissolve; native=%d; started=%d"):format(native, started))
    if native + started == 0 then return true end
    self.dissolveUntil = now + DISSOLVE_HOLD
    return false
end

function Mechanics.new(pawn, gameplay, system, scene, stage, hasNextStage, ordinary)
    if stage.regularMobs then return end
    local id = stage.members[1].id
    local needsBounds, zuoShang = LEASH[id], id == ZUO_SHANG
    if ordinary then
        for _, member in ipairs(stage.members) do
            needsBounds = needsBounds or LEASH[member.id]
            zuoShang = zuoShang or member.id == ZUO_SHANG
        end
    end
    if not needsBounds then return end
    local leiDang = not ordinary and hasNextStage and id == "BP_Monster_LeiDang"
    local xigu = (not ordinary or scene.id == "xigu") and require("XiguArena") or nil
    local self = setmetatable({ id = id, pawn = pawn, gameplay = gameplay, world = pawn:GetWorld(),
        actors = {}, borrowed = {}, bosses = {}, hooks = {}, ordinary = ordinary, xigu = xigu,
        scene = scene, system = system }, Session)
    local ok, ready, reason = pcall(function()
        local bounds, why = self:prepareArenaBounds(system, scene)
        if not bounds then return false, why end
        if leiDang then
            return watchLeiDangRefill(self)
        elseif zuoShang then
            return createAnchors(self, gameplay, system, scene)
        end
        return true
    end)
    if not ok or not ready then
        self:close()
        if not ok then error(ready, 0) end
        return nil, reason
    end
    return self
end

local function recover(self, actor, at, destination, label)
    local x, y, z = at.X, at.Y, at.Z
    local library = required("/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary")
    if library:PBZActorTeleportTo(actor, destination, actor:K2_GetActorRotation(), false, false) then
        local movement = actor.CharacterMovement
        if valid(movement) then movement:StopMovementImmediately() end
        log(("boss mechanic returned %s from %.0f,%.0f,%.0f"):format(label, x, y, z))
    end
end

local function outside(center, at)
    return (at.X - center.X)^2 + (at.Y - center.Y)^2 > 4200^2
        or at.Z <= center.Z - 380 or at.Z >= center.Z + 3600
end

local function livingInArena(actor, world)
    return valid(actor) and not actor:IsActorBeingDestroyed() and same(actor:GetWorld(), world) and actor:IsAlive()
end

function Session:recoveryGround(ground, boss)
    local height = self:groundAt(self.system, self.scene, ground.X, ground.Y, { boss })
    if height and math.abs(height - ground.Z) <= 150 then
        return { X = ground.X, Y = ground.Y, Z = height }
    end
end

function Session:recoverBoss(boss, ground, label)
    local at = boss:K2_GetActorLocation()
    if not outside(self.center, at) then return end
    local from = { X = at.X, Y = at.Y, Z = at.Z }
    if self.ordinary then
        -- Prefer the boss's own slot so simultaneous recoveries do not pile up.
        ground = self:recoveryGround(ground, boss) or self:recoveryGround(self.center, boss)
        if not ground then return end
    end
    local capsule = boss.CapsuleComponent
    if valid(capsule) then
        local destination = { X = ground.X, Y = ground.Y, Z = ground.Z + capsule:GetScaledCapsuleHalfHeight() + 6 }
        recover(self, boss, from, destination, label)
    end
end

function Session:update(now)
    self:preserveLeiDangHealth()
    local pawn = self.pawn
    if self.closed or now < (self.nextCheck or 0) or not valid(pawn) or not same(pawn:GetWorld(), self.world) then return end
    self.nextCheck = now + .10
    if self.ordinary then
        for _, record in pairs(self.bosses) do
            if livingInArena(record.actor, self.world) then
                self:recoverBoss(record.actor, record.ground, record.id)
            end
        end
        return
    end
    if not livingInArena(self.boss, self.world) then return end
    self:recoverBoss(self.boss, self.landing or self.center, "boss")
    if self.safeReturn then
        local at = pawn:K2_GetActorLocation()
        if outside(self.center, at) then recover(self, pawn, at, self.safeReturn.position, "player") end
    end
end

return Mechanics
