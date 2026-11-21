local Portal = require("BloodyPalacePortal")
local Xigu = require("XiguArena")
local GateScene = {}
GateScene.__index = GateScene
local BEFORE_SHOT, AFTER_SHOT = .5, .5
local CAMERA_BLEND, EASE_IN_OUT, BLEND_EXPONENT = .6, 4, 2
local OPENING_LEAD, OPENING_DURATION, OPEN_HOLD = .1, 1.1, .2
local ONE = { X = 1, Y = 1, Z = 1 }

local function valid(object) return object and object:IsValid() end
local function same(a, b) return valid(a) and valid(b) and a:GetAddress() == b:GetAddress() end
local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "缺少血宫开门过场接口：" .. path)
    return object
end

function GateScene:playerView()
    local currentPawn = self.controller:K2_GetPawn()
    if (not valid(currentPawn) or same(currentPawn, self.pawn)) and valid(self.previousView) then
        return self.previousView
    end
    return valid(currentPawn) and currentPawn or self.controller
end

function GateScene:restoreView()
    local controller, camera = self.controller, self.camera
    if not valid(controller) or not valid(self.manager) or not valid(camera) then return end
    local view = controller:GetViewTarget()
    local target = self:playerView()
    if not same(view, camera) then
        if not same(self.manager.ViewTarget.Target, camera) then return end
        assert(same(view, self.returnTarget), "血宫开门镜头仍在过渡")
        -- UE ignores a cut to the pending destination. Cancel the outgoing
        -- blend first so the camera can be destroyed safely in this tick.
        if same(view, target) then controller:SetViewTargetWithBlend(camera, 0, 0, 0, false) end
    end
    controller:SetViewTargetWithBlend(target, 0, 0, 0, false)
    assert(not same(controller:GetViewTarget(), camera) and not same(self.manager.ViewTarget.Target, camera),
        "血宫开门镜头尚未恢复")
end

function GateScene:release()
    local failure
    local function attempt(callback)
        local ok, reason = pcall(callback)
        if not ok then failure = failure or reason end
    end
    attempt(function() self:restoreView() end)
    if self.tagged then
        attempt(function()
            if valid(self.camera) then self.input:RemoveInputModeTag(self.camera, self.camera) end
            self.tagged = nil
        end)
    end
    if self.lookHeld then
        attempt(function()
            if valid(self.controller) then self.controller:SetIgnoreLookInput(false) end
            self.lookHeld = nil
        end)
    end
    if self.moveHeld then
        attempt(function()
            if valid(self.controller) then self.controller:SetIgnoreMoveInput(false) end
            self.moveHeld = nil
        end)
    end
    if not failure then
        attempt(function()
            if valid(self.camera) then self.camera:K2_DestroyActor() end
            self.camera = nil
        end)
    end
    return not failure, failure
end

function GateScene:close()
    local released, reason = self:release()
    if self.portal then
        local closed, failure = pcall(self.portal.close, self.portal)
        if not closed then return false, failure end
        self.portal = nil
    end
    return released, reason
end

function GateScene:stopAction()
    local pawn, movement = self.pawn, self.pawn.CharacterMovement
    assert(valid(movement), "血宫角色移动组件已失效")
    local velocity = movement.Velocity
    local moving = velocity.X^2 + velocity.Y^2 > 16
    local pending = pawn:ConsumeMovementInputVector()
    local requested = pending.X^2 + pending.Y^2 > .0001
    local montage = pawn:GetCurrentMontage()
    if not valid(montage) and not moving and not requested then return end
    self.actions:CancelAbilitiesByTag(pawn.AbilitySystemComponent, self.actionTags, self.emptyTags)
    montage = pawn:GetCurrentMontage()
    if valid(montage) then pawn:StopAnimMontage(montage) end
    movement:StopMovementImmediately()
end

function GateScene:pushOutside()
    if Portal.contains(self.pawn, self.destination.position) then
        assert(Xigu.pushOutsidePortal(self.pawn, self.system, self.scene, self.destination, Portal.safeDistance),
            "传送门旁未找到安全落脚点")
        print("[PBZBloodyPalace] moved player at least 100 cm outside the portal trigger\n")
    end
end

function GateScene.new(gameplay, system, pawn, scene, destination)
    local controller = gameplay:GetPlayerController(pawn, 0)
    assert(valid(controller) and same(controller:K2_GetPawn(), pawn), "血宫开门镜头的玩家已切换")
    local manager = gameplay:GetPlayerCameraManager(pawn, 0)
    assert(valid(manager), "血宫玩家相机管理器未就绪")
    local eye, rotation = Xigu.portalCamera(pawn, system, destination, manager:GetCameraLocation().Z)
    if not eye then return nil, "传送门镜头被场景遮挡" end
    local mathLibrary = required("/Script/Engine.Default__KismetMathLibrary")
    local transform = mathLibrary:MakeTransform(eye, rotation, ONE)
    local cameraClass = required("/Script/Engine.CameraActor")
    local self = setmetatable({ gameplay = gameplay, pawn = pawn, system = system, scene = scene,
        destination = destination, controller = controller, manager = manager,
        input = required("/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary"),
        actions = required("/Script/SGameUtils.Default__AbilityUtils"),
        actionTags = { GameplayTags = { { TagName = FName("Ability.Action") } }, ParentTags = {} },
        emptyTags = { GameplayTags = {}, ParentTags = {} } }, GateScene)
    -- The registered component holds the ready asset during camera setup.
    local portal, reason = Portal.new(gameplay, pawn, destination, OPENING_DURATION)
    if not portal then return nil, reason end
    self.portal = portal
    local ok, failure = pcall(function()
        self.camera = gameplay:BeginDeferredActorSpawnFromClass(pawn, cameraClass, transform, 1, pawn, 1)
        assert(valid(self.camera), "血宫开门镜头创建失败")
        local camera = gameplay:FinishSpawningActor(self.camera, transform, 1)
        assert(valid(camera), "血宫开门镜头初始化失败")
        self.camera = camera
        local component = camera.CameraComponent
        assert(valid(component), "血宫开门镜头缺少相机组件")
        component:SetFieldOfView(55)
        component.bConstrainAspectRatio = false
        self.tagged = true
        self.input:AddInputModeTag(camera, { TagName = FName("InputType.DisableAll") }, camera)
        controller:SetIgnoreMoveInput(true)
        self.moveHeld = true
        controller:SetIgnoreLookInput(true)
        self.lookHeld = true
        self:stopAction()
        local now = gameplay:GetTimeSeconds(pawn)
        self.blendAt, self.deadline = now + BEFORE_SHOT, now + 8
    end)
    if not ok then
        -- Return the partial handle if cleanup needs another game-thread tick.
        local closed = self:close()
        return nil, failure, not closed and self or nil
    end
    return self
end

function GateScene:update()
    assert(same(self.controller:K2_GetPawn(), self.pawn), "血宫开门过场已离开当前角色")
    if self.gameplay:IsGamePaused(self.pawn) then return end
    local now = self.gameplay:GetTimeSeconds(self.pawn)
    assert(now < self.deadline, "血宫开门镜头等待超时")
    self:stopAction()
    if not self.blendStarted then
        if now < self.blendAt then return end
        self.previousView = self.controller:GetViewTarget()
        self.controller:SetViewTargetWithBlend(self.camera, CAMERA_BLEND, EASE_IN_OUT, BLEND_EXPONENT, true)
        assert(same(self.controller:GetViewTarget(), self.camera), "游戏未切入血宫开门镜头")
        self.blendStarted = now
        return
    end
    if not self.effectAt then
        if not same(self.manager.ViewTarget.Target, self.camera) then return end
        self.effectAt = now + OPENING_LEAD
        return
    end
    if not self.effectStarted then
        if now < self.effectAt then return end
        self:pushOutside()
        self.portal:activate(self.pawn, now)
        self.effectStarted = true
        return
    end
    if not self.returnTarget then
        if not self.portal:update(now) then return end
        self.holdUntil = self.holdUntil or (now + OPEN_HOLD)
        if now < self.holdUntil then return end
        self.returnTarget = self:playerView()
        self.controller:SetViewTargetWithBlend(self.returnTarget, CAMERA_BLEND, EASE_IN_OUT, BLEND_EXPONENT, true)
        return
    end
    if not self.releaseAt then
        if same(self.manager.ViewTarget.Target, self.camera) then return end
        self.releaseAt = now + AFTER_SHOT
        print(("[PBZBloodyPalace] portal camera sequence finished in %.3fs\n"):format(now - self.blendStarted))
    elseif now >= self.releaseAt then
        self:pushOutside()
        local released, reason = self:release()
        assert(released, reason)
        local portal = self.portal
        self.portal = nil
        return portal
    end
end

return GateScene
