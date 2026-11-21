local Arena = require("XiguArena")
local Scene = require("SceneArena")
local Spawn = require("SpawnClass")
local StageFade = require("StageFade")
local Opening = require("BloodyPalaceOpeningShot")
local Props = require("BloodyPalaceEndingProps")
local Face = require("BloodyPalaceEndingFace")

local Ending = {}
Ending.__index = Ending
local clock = os and os.clock
local unpack = table.unpack or unpack

local SEQUENCER = "/Game/PBZContent/Sequencer/GenerateSequencer/"
local CAST = "/HuaShira/Animation/Seqs/ActorForSeqs/"
local SALUTE_PATH = SEQUENCER .. "Seq126/cam06/Anim/Seq126_cam06_Hun.Seq126_cam06_Hun"
local CAMERA = "/Script/CinematicCamera.CineCameraActor"
local SPOT = "/Script/Engine.SpotLight"
local AK_COMPONENT = "/Script/AkAudio.AkComponent"
local AK_EVENT = "/Script/AkAudio.AkAudioEvent"
local AK_STATICS = "/Script/AkAudio.Default__AkGameplayStatics"
local AK_CULTURE = "/Script/AkAudio.AkGameplayStatics:GetCurrentAudioCulture"
local OPENING_AUDIO = "/Game/Wwise/Events/Video/Plot/Video_Seq/Seqslice_Video_Seq/"
    .. "SFX_Video_Seq127_1__Slices/SFX_Video_Seq127_1_S01.SFX_Video_Seq127_1_S01"
local SUBSYSTEMS = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local SOUND = "/Script/ProjectPBZ.PBZSoundFXSubsystem"
local MESH = "/Script/Engine.MeshComponent"
local CLOTH = "/Script/ChaosClothAssetEngine.ChaosClothComponent"
local LIBRARY = "/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary"
local ONE = { X = 1, Y = 1, Z = 1 }
local SHEATH_BEGIN, SALUTE_START, SALUTE_END = 1, .26, 2.10
local POSE_BLEND, CAPTION_HOLD = .26, 2.4
local ENDING_FADE = { out = .72, reveal = .90, nativeReveal = true }
local BREATH_SPAN, BREATH_PERIOD = .68, 2.5
local TEXTURE_HOLD = 14
local WARMUP_SECONDS, WARMUP_FRAMES = .35, 6
local HUN_DISTANCE = 455
local SALUTE_FOCAL, SALUTE_APERTURE = 30, 8
local SERVICE_FALLBACK_AFTER = .25
local PENDING = 0x08023600
local ANIM_SEQUENCE = "/Script/Engine.AnimSequence"
-- The two spoken tails are single-source original Hun VO. Seek them in the
-- same frame as Post so the preceding dialogue is never queued for playback.
local DIALOGUE = {
    { folder = "JMKD", event = "Vo_Plot_JMKD_RenOuZhangMen3_Hun_5", at = 4.92, duration = 5.8125, text = "在下佩服" },
    { folder = "XSSL", event = "Vo_Plot_XSSL_ChangHong2_Hun_2", at = 2.135, duration = 2.928, text = "领教了！" },
}

-- Source fixtures: Seq127-1_light3 SpotLight103 and Seq126_light3
-- SpotLight84/87/85. Aim these character-only fills at the rebased cast.
local SNOW_LIGHT = { -184.05, -313.99, 710.25, -60.75, 49.19, { 225, 235, 255, 40, 16.376, 46.08, 0, 1000 } }
local HUN_LIGHTS = {
    { -303.28, 144.63, 273.96, -16.95, 334.58, { 211, 227, 255, 20, 5.632, 23.328, 10, 1000 } },
    { 136.85, -241.91, 228.16, -39.95, 473.98, { 211, 227, 255, 3, 5.632, 23.328, 30, 800 } },
    { 469.07, 55.95, 358.21, -23.55, 546.38, { 227, 237, 255, 2, 5.632, 23.328, 30, 800 } },
}

local function valid(object) return object and type(object.IsValid) == "function" and object:IsValid() end
local function same(a, b) return valid(a) and valid(b) and a:GetAddress() == b:GetAddress() end
local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "血宫通关过场缺少接口 " .. path)
    return object
end

local function load(path, class)
    local asset = StaticFindObject(path)
    if not valid(asset) or asset:HasAnyFlags(PENDING) then
        local loaded = LoadAsset(path)
        asset = valid(loaded) and loaded or StaticFindObject(path)
    end
    assert(valid(asset) and not asset:HasAnyFlags(PENDING) and asset:IsA(required(class)), "过场资源不可用 " .. path)
    return asset
end

local function animation(sequence, camera, actor, minimum)
    local name = ("%s_%s_%s"):format(sequence, camera, actor)
    local path = SEQUENCER .. sequence .. "/" .. camera .. "/Anim/" .. name .. "." .. name
    local asset = load(path, ANIM_SEQUENCE)
    assert(asset:GetPlayLength() >= minimum - .001, "血宫通关动作不可用 " .. name)
    return asset
end

local function loadSalute()
    local asset = load(SALUTE_PATH, ANIM_SEQUENCE)
    assert(asset:GetPlayLength() >= SALUTE_END, "血宫抱拳动作时长不足")
    return asset
end

local function cast(name)
    local class, reason = Spawn.resolve(CAST .. name .. "." .. name .. "_C")
    assert(valid(class), reason)
    return class
end

local function loadCast()
    return {
        hunAnim = loadSalute(),
        snowAnim = animation("Seq127-1", "cam01", "FengXueDaoKe", Opening.duration),
        hunClass = cast("BP_Seq_Hun"),
        snowClass = cast("BP_Seq_FengXueDaoKe"),
        swordClass = cast("BP_Seq_FengXueDaoKe_Weapon"),
    }
end

local function clamp(t) return math.max(0, math.min(1, t)) end
local function lerp(a, b, t) return a + (b - a) * t end
local function yaw(value) return { Pitch = 0, Yaw = value, Roll = 0 } end

-- Integrate smoothstep velocity ramps to join the cruise with continuous
-- speed and acceleration, including at the stationary start and finish.
local function dolly(t, duration, accelerate, brake)
    if t <= 0 then return 0 end
    if t >= duration then return 1 end
    local distance = duration - (accelerate + brake) / 2
    if t < accelerate then
        local u = t / accelerate
        return accelerate * u * u * u * (1 - .5 * u) / distance
    end
    if t > duration - brake then
        local u = (duration - t) / brake
        return 1 - brake * u * u * u * (1 - .5 * u) / distance
    end
    return (t - accelerate / 2) / distance
end

local function bezier(a, b, c, d, t)
    local u = 1 - t
    return u * u * u * a + 3 * u * u * t * b + 3 * u * t * t * c + t * t * t * d
end

local function hermite(a, b, leave, arrive, u)
    local v = u * (1 - u)
    return lerp(a, b, u * u * (3 - 2 * u)) + v * ((1 - u) * leave - u * arrive)
end

local function channel(a, b, i, u)
    return hermite(a[i], b[i], a[12 + i], b[6 + i], u)
end

local function track(keys, t)
    local index = math.max(1, math.min(#keys - 1, math.floor(t * Opening.rate) + 1))
    local a, b = keys[index], keys[index + 1]
    local u = clamp(t * Opening.rate - index + 1)
    return channel(a, b, 1, u), channel(a, b, 2, u), channel(a, b, 3, u),
        channel(a, b, 4, u), channel(a, b, 5, u), channel(a, b, 6, u)
end

local function curve(keys, t)
    for i = 2, #keys do
        local a, b = keys[i - 1], keys[i]
        if t < b[1] then
            local dt = b[1] - a[1]
            return hermite(a[2], b[2], (a[4] or 0) * dt, (b[3] or 0) * dt, clamp((t - a[1]) / dt))
        end
    end
    return keys[#keys][2]
end

function Ending:point(x, y, z)
    return { X = self.center.X + x * self.forwardX - y * self.forwardY,
        Y = self.center.Y + x * self.forwardY + y * self.forwardX, Z = z }
end

function Ending:place(actor, at, rotation)
    actor:K2_SetActorLocationAndRotation(at, rotation, false, {}, true)
end

function Ending:placeSnow(t)
    local x, y, z, pitch, heading, roll = track(Opening.snow, t)
    self:place(self.snow, self:point(x, y, self.snowGround + 102 + z),
        { Pitch = pitch, Yaw = self.direction + heading, Roll = roll })
    local height = curve(Opening.meshZ, t)
    if self.snowMeshZ ~= height then
        self.snowMesh:K2_SetRelativeLocation({ X = 0, Y = 0, Z = height }, false, {}, true)
        self.snowMeshZ = height
    end
    self.snowMesh:SetPosition(math.min(t, self.snowLength), false)
end

function Ending:openingPose(t)
    local x, y, z, pitch, heading, roll = track(Opening.camera, t)
    return self:point(x, y, self.snowGround + 102 + z),
        { Pitch = pitch, Yaw = self.direction + heading, Roll = roll }, curve(Opening.focus, t)
end

function Ending:cameraPose(eye, rotation, focalLength, aperture, focus)
    self:place(self.camera, eye, rotation)
    if self.focalLength ~= focalLength then
        self.lens:SetCurrentFocalLength(focalLength)
        self.focalLength = focalLength
    end
    if self.aperture ~= aperture then
        self.lens:SetCurrentAperture(aperture)
        self.aperture = aperture
    end
    if self.focus ~= focus then
        self.lens:SetFocusSettings({ FocusMethod = 1, bSmoothFocusChanges = false, FocusOffset = 0,
            ManualFocusDistance = focus })
        self.focus = focus
    end
end

function Ending:spawn(class, at, rotation, character)
    local transform = self.math:MakeTransform(at, rotation, ONE)
    local actor = self.gameplay:BeginDeferredActorSpawnFromClass(self.pawn, class, transform, 1, self.pawn, 1)
    assert(valid(actor), "血宫通关过场角色或镜头创建失败")
    self.actors[#self.actors + 1] = actor
    if character then
        actor.AutoPossessAI = 0
        actor.AutoPossessPlayer = 0
        local mesh = actor.Mesh
        assert(valid(mesh), "血宫通关过场缺少角色网格")
        mesh:SetAutoRegisterWithBudgetAllocator(false)
        mesh.bEnableUpdateRateOptimizations = false
        mesh.VisibilityBasedAnimTickOption = 0
    elseif same(class, StaticFindObject(SPOT)) and valid(actor.SpotLightComponent) then
        -- Give the native movable light a safe, dark starting state before
        -- registration. No frame sees the engine's default spot intensity.
        actor.SpotLightComponent.Mobility = 2
        actor.SpotLightComponent.Intensity = 0
    end
    local spawned = self.gameplay:FinishSpawningActor(actor, transform, 1)
    assert(same(spawned, actor), "血宫通关过场角色或镜头初始化失败")
    actor:SetActorEnableCollision(false)
    if character then actor.CharacterMovement:DisableMovement() end
    return actor
end

function Ending:prepareDetail()
    local meshClass, clothClass = required(MESH), required(CLOTH)
    local skinnedClass = required("/Script/Engine.SkinnedMeshComponent")
    local staticClass = required("/Script/Engine.StaticMeshComponent")
    local count, failed = 0, nil
    for _, actor in ipairs({ self.hun, self.snow, self.sword }) do
        local meshes = actor:K2_GetComponentsByClass(meshClass)
        for i = 1, #meshes do
            local mesh = meshes[i]
            if not valid(mesh) then mesh = mesh:get() end
            if valid(mesh) then
                local ok, reason = pcall(function()
                    mesh:SetLightingChannels(true, false, true)
                    if mesh:IsA(skinnedClass) then mesh:SetForcedLOD(1)
                    elseif mesh:IsA(staticClass) then mesh:SetForcedLodModel(1) end
                    mesh:PrestreamTextures(TEXTURE_HOLD, false, 0)
                end)
                if ok then count = count + 1 else failed = failed or reason end
                if mesh:IsA(clothClass) then self.clothes[#self.clothes + 1] = mesh end
            end
        end
    end
    print(("[PBZBloodyPalace] ending detail warm-up; meshes=%d%s\n")
        :format(count, failed and "; first fallback=" .. tostring(failed) or ""))
end

local function linear(value)
    local c = value / 255
    if c <= .04045 then return c / 12.92 end
    return ((c + .055) / 1.055) ^ 2.4
end

function Ending:addLight(row, x, ground, rotation)
    local radians = math.rad(rotation)
    local cx, sx = math.cos(radians), math.sin(radians)
    local at = self:point(x + row[1] * cx - row[2] * sx, row[1] * sx + row[2] * cx, ground + row[3])
    local lamp = self:spawn(required(SPOT), at, { Pitch = row[4], Yaw = self.direction + rotation + row[5], Roll = 0 }, false)
    local light = lamp.SpotLightComponent
    assert(valid(light), "血宫过场补光组件未就绪")
    local red, green, blue, intensity, inner, outer, radius, range = unpack(row[6])
    light:SetLightingChannels(false, false, true)
    light:SetCastShadows(false)
    light:SetAffectTranslucentLighting(false)
    light:SetIndirectLightingIntensity(0)
    light:SetVolumetricScatteringIntensity(0)
    light:SetUseInverseSquaredFalloff(false)
    light:SetLightFalloffExponent(2)
    light:SetAttenuationRadius(range)
    light:SetInnerConeAngle(inner)
    light:SetOuterConeAngle(outer)
    light:SetSourceRadius(radius)
    light:SetLightColor({ R = linear(red), G = linear(green), B = linear(blue), A = 1 }, true)
    light:SetIntensity(intensity)
end

function Ending:prepareLights()
    local baseline = #self.actors
    local ok, reason = pcall(function()
        self:addLight(SNOW_LIGHT, 0, self.snowGround, 0)
        -- The original Hun capsule is at yaw 68; here it faces back down the
        -- new scene's axis. Rotate its three character lights with it.
        for _, light in ipairs(HUN_LIGHTS) do self:addLight(light, HUN_DISTANCE, self.hunGround, 180 - 68) end
    end)
    if not ok then
        for i = #self.actors, baseline + 1, -1 do
            local lamp = self.actors[i]
            local removed = pcall(function() if valid(lamp) then lamp:K2_DestroyActor() end end)
            if removed then table.remove(self.actors, i) end
        end
        print("[PBZBloodyPalace] ending lights fallback: " .. tostring(reason) .. "\n")
    else
        print("[PBZBloodyPalace] ending character lights ready; Seq127-1 + Seq126\n")
    end
end

local function pose(mesh, asset, position)
    mesh:PlayAnimation(asset, false)
    mesh:Stop()
    mesh:SetPosition(position, false)
    assert(math.abs(mesh:GetPosition() - position) < .01, "血宫通关动作未绑定到演出角色")
end

local function holdSalute(mesh, asset)
    -- AnimationData retains the asset on the mesh while the single-node
    -- instance plays the separate sheath animation.
    mesh:OverrideAnimationData(asset, false, false, SALUTE_START, 1)
    assert(same(mesh.AnimationData.AnimToPlay, asset), "血宫抱拳动作没有绑定到演出角色")
end

function Ending:prepareDialogue()
    self.sound = required(SUBSYSTEMS):GetWorldSubsystem(self.pawn, required(SOUND))
    assert(valid(self.sound), "原版声音系统不可用")
    local componentClass = required(AK_COMPONENT)
    local function prepareEvent(path)
        local event = load(path, AK_EVENT)
        local emitter = self.hun:AddComponentByClass(componentClass, false, self.identity, false)
        assert(valid(emitter), "过场声音组件未就绪")
        emitter.AkAudioEvent = event
        return { emitter = emitter }
    end

    -- Seq127-1_Sound starts this effects stem at zero. Its impact is
    -- already aligned with the blade, so play it from the first frame.
    local effectsReady, effects = pcall(prepareEvent, OPENING_AUDIO)
    if effectsReady then self.openingAudio = effects
    else print("[PBZBloodyPalace] ending opening effects fallback: " .. tostring(effects) .. "\n") end

    local ak = StaticFindObject(AK_STATICS)
    local culture = StaticFindObject(AK_CULTURE)
    if valid(ak) and valid(culture) then
        local language = culture(ak)
        local name = type(language) == "string" and language or language and language:ToString() or ""
        name = name:lower()
        assert(name == "" or name == "chinese" or name:match("^zh"), "原声短句仅对齐了中文配音")
    end
    self.seekSeconds = StaticFindObject(SOUND .. ":PBZSeekMsOnPlayingID")
    self.seekPercent = StaticFindObject(SOUND .. ":PBZSeekOnPlayingID")
    assert(valid(self.seekSeconds) or valid(self.seekPercent), "原声定位接口不可用")
    for i, cue in ipairs(DIALOGUE) do
        local path = "/Game/Wwise/Events/VO/Plot/" .. cue.folder .. "/" .. cue.event .. "." .. cue.event
        self.dialogue[i] = prepareEvent(path)
    end
end

function Ending:postSound(line)
    assert(valid(self.sound) and valid(line.emitter) and valid(line.emitter.AkAudioEvent), "过场声音已卸载")
    local event = line.emitter.AkAudioEvent
    local id = self.sound:PBZPostEventGlobal(event, nil)
    assert(type(id) == "number" and id > 0, "未取得过场声音播放 ID")
    line.id = id
    return event, id
end

function Ending:stopSound(line, fade)
    if line and line.id then
        if valid(self.sound) then self.sound:PBZStopPlayingID(line.id, fade or 0) end
        line.id = nil
    end
end

function Ending:openingEffects(play)
    if not self.openingAudio then return end
    local ok, reason = pcall(function()
        if play then
            self:postSound(self.openingAudio)
            print("[PBZBloodyPalace] ending opening effects: native Seq127-1 S01\n")
        else
            self:stopSound(self.openingAudio, .06)
        end
    end)
    if not ok then print("[PBZBloodyPalace] ending opening effects fallback: " .. tostring(reason) .. "\n") end
end

function Ending:seekVoice(event, id, cue)
    if valid(self.seekSeconds) then
        local called, result = pcall(self.seekSeconds, self.sound, event, id, cue.at)
        if called and result ~= false then return "seconds" end
    end
    if valid(self.seekPercent) then
        local called, result = pcall(self.seekPercent, self.sound, event, id, cue.at / cue.duration)
        if called and result ~= false then return "percent" end
    end
    error("原声短句定位失败")
end

function Ending:say(index)
    local cue, line = DIALOGUE[index], self.dialogue[index]
    if not line or line.sent then return end
    line.sent = true
    local ok, reason = pcall(function()
        -- Use the same global post/seek pair as the native music gallery.
        -- The owned component only keeps this event and its bank resident.
        local event, id = self:postSound(line)
        local route = self:seekVoice(event, id, cue)
        if self.face then self.face:play(index, self.gameplay:GetRealTimeSeconds(self.pawn)) end
        print(("[PBZBloodyPalace] ending voice: %s; offset=%.3fs; seek=%s\n"):format(cue.text, cue.at, route))
    end)
    if not ok then
        pcall(self.stopSound, self, line)
        print("[PBZBloodyPalace] ending voice fallback: " .. tostring(reason) .. "\n")
        return
    end
end

function Ending:prepareHun(asset)
    holdSalute(self.hunMesh, asset)
    self.saluteAt = SHEATH_BEGIN
    local created = {}
    local ok, reason = pcall(function()
        local weapon = Props.prepare(self.pawn, self.hun, self.math, self.identity,
            function(path) return load(path, "/Script/Engine.AnimMontage") end, created)
        pose(self.hunMesh, weapon.clip, 0)
        local animator = self.hunMesh:GetAnimInstance()
        assert(valid(animator) and animator:Montage_IsActive(weapon.clip), "原版收刀动作未就绪")
        self.weapon = weapon
        self.saluteAt = SHEATH_BEGIN + weapon.length
    end)
    if not ok then
        for i = #created, 1, -1 do
            local component = created[i]
            pcall(function()
                if valid(component) then component:K2_DestroyComponent(self.hun) end
            end)
        end
        self.weapon = nil
        pose(self.hunMesh, asset, SALUTE_START)
        print("[PBZBloodyPalace] ending weapon fallback: " .. tostring(reason) .. "\n")
    end
    self.shotEnd = self.saluteAt + SALUTE_END - SALUTE_START
    self.timelineEnd = Opening.duration + self.shotEnd
end

function Ending:poseHun(t)
    -- The first sheath pose was evaluated while covered. Hold that armed
    -- pose for the whole over-the-shoulder beat, with cloth still running.
    if t < SHEATH_BEGIN then return end
    local weapon = self.weapon
    local motion = t - SHEATH_BEGIN
    if not self.sheathStarted then
        self.sheathStarted = true
        self:say(1)
        print("[PBZBloodyPalace] ending sheath and push started\n")
    end
    if weapon and not self.saluting then
        self.hunMesh:SetPosition(math.min(motion, weapon.length), false)
        if motion >= weapon.attach then Props.stow(weapon, self.hunMesh, self.math, motion) end
        if t >= self.saluteAt then
            -- The original montage is held at its last frame. Blend its
            -- settled pose into the salute on the same native montage slot;
            -- do not swap the mesh animation mode or reset its cloth.
            local asset = loadSalute()
            if not same(self.hunMesh.AnimationData.AnimToPlay, asset) then
                holdSalute(self.hunMesh, asset)
            end
            local animator = self.hunMesh:GetAnimInstance()
            assert(valid(animator), "魂的演出动画实例不可用")
            local ok, montage = pcall(function()
                local value = animator:PlaySlotAnimationAsDynamicMontage(asset,
                    weapon.slot, POSE_BLEND, POSE_BLEND, 1, 1, -1, SALUTE_START)
                assert(valid(value), "抱拳混合动作未就绪")
                animator:Montage_Pause(value)
                assert(animator:Montage_IsActive(value), "抱拳混合动作未绑定")
                return value
            end)
            self.saluting = true
            if ok then
                self.hunAnimator, self.saluteMontage = animator, montage
                print("[PBZBloodyPalace] ending salute blend started\n")
            else
                print("[PBZBloodyPalace] ending pose blend fallback: " .. tostring(montage) .. "\n")
                pose(self.hunMesh, asset, SALUTE_START)
            end
        end
    end
    if t >= self.saluteAt then
        local position = math.min(SALUTE_END, SALUTE_START + t - self.saluteAt)
        if self.saluteMontage then
            self.hunAnimator:Montage_SetPosition(self.saluteMontage, position)
        else
            self.hunMesh:SetPosition(position, false)
        end
    end
end

function Ending:frame(elapsed)
    local snowTime = math.min(elapsed, Opening.duration)
    if self.joinedAt then
        -- Resample the planted tail of the kneel. The turnarounds have zero velocity.
        local phase = (elapsed - self.joinedAt) * (2 * math.pi / BREATH_PERIOD)
        snowTime = Opening.duration - BREATH_SPAN * (1 - math.cos(phase)) / 2
    end
    if snowTime ~= self.snowTime then
        self:placeSnow(snowTime)
        self.snowTime = snowTime
    end
    if elapsed < Opening.duration then
        local eye, rotation, focus = self:openingPose(elapsed)
        self:cameraPose(eye, rotation, Opening.openingFocal, Opening.openingAperture, focus)
        return
    end
    if not self.joinedAt then
        self:openingEffects(false)
        self.hun:SetActorHiddenInGame(false)
        -- Count the pause from the actual cut, even if a rendered frame ran
        -- long just before it. A camera cut also clears temporal history.
        self.joinedAt = elapsed
        self.timelineEnd = elapsed + self.shotEnd
        pcall(function() self.gameplay:GetPlayerCameraManager(self.pawn):SetGameCameraCutThisFrame() end)
        print("[PBZBloodyPalace] ending hard cut: over the shoulder; 1s armed hold\n")
    end
    local t = math.min(self.shotEnd, elapsed - self.joinedAt)
    self:poseHun(t)
    if t < SHEATH_BEGIN and self.shoulderFramed then return end

    local travel = t - SHEATH_BEGIN
    -- Peel away from Snow's shoulder in one arc. Give the hand movement a
    -- soft lead-in, then let the fixed lens close on Hun as he bows.
    local push = .15 * dolly(travel, 1.45, .38, .65)
        + .85 * dolly(travel, self.shotEnd - SHEATH_BEGIN, .48, .82)
    local eye = self:point(lerp(-185, 256, push), bezier(97, 123, 85, 48, push),
        bezier(self.snowGround + 165, self.snowGround + 167, self.hunGround + 162, self.hunGround + 162, push))
    local aim = self:point(HUN_DISTANCE - 2, lerp(-7, 0, push),
        self.hunGround + bezier(135, 144, 151, 151, push))
    local rotation = self.math:FindLookAtRotation(eye, aim)
    local focus = self:point(HUN_DISTANCE - 8, 0, self.hunGround + lerp(148, 171, push))
    local dx, dy, dz = aim.X - eye.X, aim.Y - eye.Y, aim.Z - eye.Z
    local distance = math.max(30, (dx * (focus.X - eye.X) + dy * (focus.Y - eye.Y)
        + dz * (focus.Z - eye.Z)) / math.sqrt(dx * dx + dy * dy + dz * dz))
    self:cameraPose(eye, { Pitch = rotation.Pitch, Yaw = rotation.Yaw, Roll = 0 }, SALUTE_FOCAL, SALUTE_APERTURE, distance)
    self.shoulderFramed = true
end

function Ending:advance(realNow, engineFrame)
    assert(same(self.controller:K2_GetPawn(), self.pawn) and valid(self.snow)
        and valid(self.hun) and valid(self.camera) and valid(self.sword), "血宫通关过场角色或镜头已离场")
    if self.frozenAt then return end
    if engineFrame then
        self.frameSamples = self.frameSamples + 1
        self.maxFrameGap = math.max(self.maxFrameGap, realNow - self.lastFrameAt)
        self.lastFrameAt = realNow
    end
    if not self.started or self.gameplay:IsGamePaused(self.pawn) then return end
    local now = self.gameplay:GetTimeSeconds(self.pawn)
    local elapsed = now - self.started
    if not self.frameEnded then
        self:frame(math.max(0, elapsed))
        self.frameEnded = elapsed >= self.timelineEnd
        return
    end
    -- Wait one engine frame for the final pose, socket attachment and cloth.
    self.frozenAt = realNow
    for _, cloth in ipairs(self.clothes) do
        if valid(cloth) then cloth:SuspendSimulation() end
    end
    self:say(2)
    self:stopFrames()
    local titleShown = self:showTitle()
    local backdropShown = self:showBackdrop()
    print(("[PBZBloodyPalace] ending salute frozen; title=%s; backdrop=%s; frameCallbacks=%d; maxFrameGapMs=%.1f; serviceFallbacks=%d\n")
        :format(tostring(titleShown), tostring(backdropShown), self.frameSamples, self.maxFrameGap * 1000,
            self.serviceFallbacks))
end

function Ending:cameraActive()
    return same(self.controller:K2_GetPawn(), self.pawn) and same(self.controller:GetViewTarget(), self.camera)
end

function Ending:warmed(realNow)
    assert(self:cameraActive(), "血宫通关过场镜头已切换")
    if not self.warmAt then
        self.warmAt = realNow
        local read, frame = pcall(function() return self.system:GetFrameCount() end)
        if read and type(frame) == "number" then self.warmFrame = frame end
        return false
    end
    if realNow - self.warmAt < WARMUP_SECONDS then return false end
    if self.warmFrame then
        local frame = self.system:GetFrameCount()
        if frame - self.warmFrame < WARMUP_FRAMES and realNow - self.warmAt < 1.2 then return false end
    end
    return true
end

function Ending:cover(realNow)
    assert(self.fade and realNow < self.introDeadline, "血宫白屏转场等待超时")
    return self.fade:update(realNow) == "black" and self.fade:canReveal(realNow)
end

function Ending:play(realNow)
    assert(not self.started and self:cameraActive(), "血宫通关镜头尚未就绪")
    self.started = self.gameplay:GetTimeSeconds(self.pawn)
    self.lastFrameAt = realNow
    self.deadline = realNow + self.timelineEnd + 7
    self:openingEffects(true)
    if EngineTickAvailable and type(LoopInGameThreadAfterFrames) == "function"
        and type(CancelDelayedAction) == "function" then
        local scheduled, handle = pcall(LoopInGameThreadAfterFrames, 1, function()
            if self.closing or not self.frameAction or self.frameError then return end
            local advanced, reason = pcall(function()
                self:advance(self.gameplay:GetRealTimeSeconds(self.pawn), true)
            end)
            if not advanced then self.frameError = tostring(reason) end
        end)
        if scheduled and type(handle) == "number" and handle > 0 then self.frameAction = handle end
    end
    print("[PBZBloodyPalace] final sequence started; stock cam01 + sheath + salute\n")
end

function Ending:stopFrames()
    if self.frameAction then
        CancelDelayedAction(self.frameAction)
        self.frameAction = nil
    end
end

function Ending:releasePresentation()
    if self.tagged then
        if valid(self.camera) then self.input:RemoveInputModeTag(self.camera, self.camera) end
        self.tagged = nil
    end
    self:stopFrames()
    self:closeTitle()
    if self.face then self.face:close(); self.face = nil end
end

function Ending:update(realNow)
    assert(not self.frameError, self.frameError)
    if self.fade then
        assert(realNow < self.introDeadline, "血宫白屏转场等待超时")
        assert(not self.staged or self:cameraActive(), "血宫通关过场镜头已切换")
        local phase = self.fade:update(realNow)
        if phase == "done" then
            self.fade = nil
        elseif phase == "black" and self.fade:canReveal(realNow) then
            if not self.staged then self:activate()
            elseif self:warmed(realNow) then
                self.fade:reveal(realNow)
                self:play(realNow)
            end
        end
        if not self.started then return false end
    end
    assert(self.started and self:cameraActive(), "血宫通关过场镜头已切换")
    if self.released then return true end
    if self.face then self.face:check(realNow) end
    local needsFrameFallback = not self.frameAction or realNow - self.lastFrameAt > SERVICE_FALLBACK_AFTER
    if not self.frozenAt and needsFrameFallback then
        -- A long rendered frame does not invalidate the engine callback. Keep
        -- it registered so the next frame can take over from the service.
        self.serviceFallbacks = self.serviceFallbacks + 1
        self:advance(realNow, false)
    end
    if not self.frozenAt then
        assert(realNow < self.deadline, "血宫通关过场等待超时")
        return false
    end
    local held = realNow - self.frozenAt
    if held < CAPTION_HOLD then return false end
    self:releasePresentation()
    self.released = true
    return true
end

function Ending:close()
    self.closing = true
    local failure
    local canDestroyCamera = true
    local function attempt(callback)
        local ok, reason = pcall(callback)
        if not ok then failure = failure or reason end
    end
    attempt(function() self:releasePresentation() end)
    attempt(function() self:stopSound(self.openingAudio) end)
    for _, line in pairs(self.dialogue) do
        attempt(function() self:stopSound(line) end)
    end
    attempt(function()
        canDestroyCamera = false
        if valid(self.controller) and same(self.controller:GetViewTarget(), self.camera) then
            local target = valid(self.previousView) and self.previousView or self.controller:K2_GetPawn()
            self.controller:SetViewTargetWithBlend(valid(target) and target or self.controller, 0, 0, 0, false)
            assert(not same(self.controller:GetViewTarget(), self.camera), "血宫通关镜头尚未还原")
        end
        canDestroyCamera = true
    end)
    if self.fade then
        attempt(function()
            self.fade:close()
            self.fade = nil
        end)
    end
    for i = #self.hud, 1, -1 do
        attempt(function()
            local item = self.hud[i]
            if valid(item.widget) then item.widget:SetVisibility(item.visibility) end
            table.remove(self.hud, i)
        end)
    end
    for i = #self.hiddenWeapons, 1, -1 do
        attempt(function()
            local item = self.hiddenWeapons[i]
            if valid(item.actor) then item.actor:SetActorHiddenInGame(item.wasHidden) end
            table.remove(self.hiddenWeapons, i)
        end)
    end
    if self.pawnHidden ~= nil then
        attempt(function()
            if valid(self.pawn) then self.pawn:SetActorHiddenInGame(self.pawnHidden) end
            self.pawnHidden = nil
        end)
    end
    if self.moveHeld then
        attempt(function()
            if valid(self.controller) then self.controller:SetIgnoreMoveInput(false) end
            self.moveHeld = nil
        end)
    end
    if self.lookHeld then
        attempt(function()
            if valid(self.controller) then self.controller:SetIgnoreLookInput(false) end
            self.lookHeld = nil
        end)
    end
    for i = #self.actors, 1, -1 do
        local actor = self.actors[i]
        if not same(actor, self.camera) or canDestroyCamera then
            attempt(function()
                if valid(actor) then actor:K2_DestroyActor() end
                table.remove(self.actors, i)
            end)
        end
    end
    return not failure, failure
end

function Ending:stage(system, scene)
    local at = assert(Arena.portalDestination(self.pawn, system, scene), "血宫通关过场缺少场地中心")
    self.center, self.forwardX, self.forwardY = at.position, at.frontX, at.frontY
    self.direction = (at.rotation.Yaw + 180) % 360
    local function ground(x, y)
        local point = self:point(x, y, 0)
        return assert(Arena.mechanicGround(self.pawn, system, scene, point.X, point.Y), "血宫通关过场缺少安全地面")
    end
    -- The authored root reaches the kneeling pose about 15 cm above the
    -- visible sole. Anchor the shot at that sole on the arena floor.
    local boot = Opening.bootContact
    local contact = self:point(boot[1], boot[2], 0)
    local contactGround = Arena.mechanicGround(self.pawn, system, scene, contact.X, contact.Y) or ground(0, 0)
    self.snowGround, self.hunGround = contactGround - boot[3], ground(HUN_DISTANCE, 0)
    print(("[PBZBloodyPalace] ending kneel anchored at boot; correctionCm=%.2f\n"):format(-boot[3]))
    local hunPoint = self:point(HUN_DISTANCE, 0, self.hunGround + 99)
    local snowPoint = self:point(0, 0, self.snowGround + 102)
    -- Re-resolve from the engine at use time. The warm-up does not keep Lua
    -- wrappers to GC-managed objects across the last fight.
    local resolveStart = clock and clock()
    local assets = loadCast()
    local resolveMs = resolveStart and ("%.1f"):format((clock() - resolveStart) * 1000) or "unavailable"
    print("[PBZBloodyPalace] ending resources verified at settlement; resolveMs=" .. resolveMs .. "\n")
    self.hun = self:spawn(assets.hunClass, hunPoint, yaw(self.direction + 180), true)
    self.snow = self:spawn(assets.snowClass, snowPoint, yaw(self.direction), true)
    self.sword = self:spawn(assets.swordClass, snowPoint, yaw(self.direction), false)
    self.hunMesh, self.snowMesh = self.hun.Mesh, self.snow.Mesh
    self.snowLength = assets.snowAnim:GetPlayLength()
    local socket = FName("weapon_r")
    assert(self.snowMesh:DoesSocketExist(socket) and self.sword:K2_AttachToComponent(self.snowMesh, socket, 2, 2, 2, false),
        "血宫通关过场原版刀挂点不可用")
    self.identity = self.math:MakeTransform({ X = 0, Y = 0, Z = 0 }, yaw(0), ONE)
    self:prepareHun(assets.hunAnim)
    local dialogue, voiceReason = pcall(self.prepareDialogue, self)
    if not dialogue then print("[PBZBloodyPalace] ending voice prepare fallback: " .. tostring(voiceReason) .. "\n") end
    if next(self.dialogue) then
        local mouth, result = pcall(Face.new, self.hun.meshhead, function()
            return self.gameplay:GetRealTimeSeconds(self.pawn)
        end)
        if mouth then self.face = result
        else print("[PBZBloodyPalace] ending face setup fallback: " .. tostring(result) .. "\n") end
    end
    pose(self.snowMesh, assets.snowAnim, 0)
    self.hun:SetActorHiddenInGame(true)
    local detail, reason = pcall(self.prepareDetail, self)
    if not detail then print("[PBZBloodyPalace] ending detail fallback: " .. tostring(reason) .. "\n") end
    self:prepareLights()

    self.lens = self.camera:GetCineCameraComponent()
    assert(valid(self.lens), "血宫通关过场缺少电影镜头")
    self.lens:SetFilmback(Opening.filmback)
    self.lens.bConstrainAspectRatio = false
    self:frame(0)
end

function Ending:prepareTitle()
    -- The title is optional presentation. The pose and voice clocks need
    -- only the freeze cue, even if the title cannot be imported or mounted.
    local ok, module = pcall(require, "BloodyPalaceEndingTitle")
    if not ok then
        print("[PBZBloodyPalace] ending title module fallback: " .. tostring(module) .. "\n")
        return
    end
    local screen = module.new(self.gameplay, self.pawn, Scene.runtimeWorld)
    if screen then
        self.titleModule, self.titleScreen = module, screen
    end
end

function Ending:showTitle()
    return self.titleScreen ~= nil and self.titleModule.show(self.titleScreen)
end

function Ending:closeTitle()
    if self.titleScreen and self.titleModule.close(self.titleScreen) then self.titleScreen = nil end
end

function Ending:prepareBackdrop()
    local ok, result = pcall(function()
        local backdrop = require("BloodyPalaceEndingBackdrop")
        return backdrop.new(self.pawn, self.camera, self.identity)
    end)
    if ok then self.backdrop = result
    else print("[PBZBloodyPalace] ending backdrop setup fallback: " .. tostring(result) .. "\n") end
end

function Ending:showBackdrop()
    if not self.backdrop then return false end
    local ok, reason = pcall(self.backdrop.show, self.backdrop, self.pawn, self.camera, self.math,
        Opening.filmback, SALUTE_FOCAL)
    if not ok then print("[PBZBloodyPalace] ending backdrop display fallback: " .. tostring(reason) .. "\n") end
    return ok
end

function Ending:activate()
    local gameplay, pawn, controller = self.gameplay, self.pawn, self.controller
    assert(same(controller:K2_GetPawn(), pawn) and same(controller:GetViewTarget(), self.previousView),
        "白屏期间游戏视角已切换")
    local setupStart = clock and clock()
    self:stage(self.system, self.scene)
    self:prepareTitle()
    self:prepareBackdrop()

    local world = Scene.runtimeWorld(pawn)
    for _, hud in ipairs(FindAllOf("W_FrontEndHUDLayout_C") or {}) do
        if valid(hud) and same(hud:GetOwningPlayer(), controller) and same(hud:GetWorld(), world) then
            self.hud[#self.hud + 1] = { widget = hud, visibility = hud:GetVisibility() }
            hud:SetVisibility(1)
        end
    end
    self.pawnHidden = pawn.bHidden == true
    local hidden, hideReason = pcall(Props.hideOriginal, pawn, self.hiddenWeapons)
    if not hidden then print("[PBZBloodyPalace] ending original weapon visibility fallback: " .. tostring(hideReason) .. "\n") end
    pawn:SetActorHiddenInGame(true)
    controller:SetViewTargetWithBlend(self.camera, 0, 0, 0, false)
    assert(self:cameraActive(), "血宫通关镜头未切换")
    self.staged = true
    local setupMs = setupStart and ("%.1f"):format((clock() - setupStart) * 1000) or "unavailable"
    print("[PBZBloodyPalace] ending camera ready behind white; setupMs=" .. setupMs .. "\n")
end

function Ending.new(gameplay, system, pawn, scene)
    local controller = gameplay:GetPlayerController(pawn, 0)
    assert(same(valid(controller) and controller:K2_GetPawn(), pawn), "血宫通关过场玩家已切换")
    local self = setmetatable({ gameplay = gameplay, system = system, pawn = pawn, controller = controller, scene = scene,
        math = required("/Script/Engine.Default__KismetMathLibrary"), input = required(LIBRARY),
        actors = {}, hud = {}, hiddenWeapons = {}, clothes = {}, dialogue = {},
        frameSamples = 0, serviceFallbacks = 0, maxFrameGap = 0 }, Ending)
    local ok, failure = pcall(function()
        self.previousView = controller:GetViewTarget()
        self.camera = self:spawn(required(CAMERA), pawn:K2_GetActorLocation(), yaw(0), false)
        self.tagged = true
        self.input:AddInputModeTag(self.camera, { TagName = FName("InputType.DisableAll") }, self.camera)
        controller:SetIgnoreMoveInput(true)
        self.moveHeld = true
        controller:SetIgnoreLookInput(true)
        self.lookHeld = true
        local realNow = gameplay:GetRealTimeSeconds(pawn)
        self.fade = StageFade.new(gameplay, pawn, realNow, true, ENDING_FADE)
        self.introDeadline = realNow + 15
    end)
    if not ok then
        local closed = self:close()
        return nil, failure, not closed and self or nil
    end
    print("[PBZBloodyPalace] ending white transition started\n")
    return self
end

return Ending
