local Arena = require("XiguArena")
local Scene = require("SceneArena")
local Spawn = require("SpawnClass")
local StageFade = require("StageFade")
local Opening = require("BloodyPalaceOpeningShot")
local ExecutionView = require("BloodyPalaceEndingExecutionView")
local ZiMing = require("BloodyPalaceEndingZiMing")
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
local TITLE_IMPACT = "/Game/Wwise/Events/UI/UI_Plot/SFX_UI_Plot_Impact_Po_Small.SFX_UI_Plot_Impact_Po_Small"
local SNOW_BREATH = "/Game/Wwise/Events/Video/Plot/Video_Seq/"
    .. "SFX_Video_Seq008_Breath_OneShot.SFX_Video_Seq008_Breath_OneShot"
local GLAIVE_EXECUTION_AUDIO = "/Game/Wwise/Events/SFX_Impact/Execute/Group/"
local GLAIVE_WAVE_1 = "SFX_Combat_Special_YanYueDao_Execute_Hun_Wave_01"
local GLAIVE_WAVE_2 = "SFX_Combat_Special_YanYueDao_Execute_Wave_02"
local GLAIVE_DOWNSTROKE = 274 / 60
local HUN_SOUND = "/Game/Wwise/Events/SFX/Combat/Special/Hero_Special/Hun/Common/"
local DUAL_HOOK_SOUND = HUN_SOUND .. "Wave_Stab_BaDao/ShuangGou/"
local SUBSYSTEMS = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local SOUND = "/Script/ProjectPBZ.PBZSoundFXSubsystem"
local ROUTER = "/Script/ProjectPBZ.PBZUIActionRouterBase"
local CONFIRM_KEYS = { "LeftMouseButton", "Gamepad_FaceButton_Bottom", "Enter", "SpaceBar" }
local MESH = "/Script/Engine.MeshComponent"
local CLOTH = "/Script/ChaosClothAssetEngine.ChaosClothComponent"
local LIBRARY = "/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary"
local ONE = { X = 1, Y = 1, Z = 1 }
local ORBIT_START = Opening.landingAt + .20
local ORBIT_DURATION, ORBIT_RAMP = 2.40, .28
local SHOULDER_HOLD, FULL_BODY_PUSH = 1, .95
local SHEATH_BEGIN, SALUTE_START, SALUTE_END = SHOULDER_HOLD + .78, .26, 2.10
local MUSIC_START = ORBIT_START + ORBIT_DURATION + SHEATH_BEGIN - 4
local POSE_BLEND, TITLE_SETTLED_TIME, FINAL_VOICE_DELAY = .26, 2, .54
local ENDING_FADE = { out = .72, reveal = .68, nativeReveal = true }
-- The original stem has its blade impact at 1.7s. Fade its tail only after the strike.
local OPENING_SOUND_END, OPENING_SOUND_FADE = 2.09, .40
local FIRST_BREATH = OPENING_SOUND_END + .22
local BREATH_SPAN, BREATH_PERIOD, BREATH_TAIL = .68, 2.5, .85
local TEXTURE_HOLD = 14
local WARMUP_SECONDS, WARMUP_FRAMES = .35, 6
local HUN_DISTANCE = 600 -- cm from Snow, including a two-step retreat
local SHOULDER_X, SHOULDER_Y, SHOULDER_Z = -185, 97, 165
local FULL_BODY_DISTANCE, SALUTE_DISTANCE = 555, 199
local SALUTE_FOCAL, SALUTE_APERTURE = 30, 8
local SERVICE_FALLBACK_AFTER = .25
local PENDING = 0x08023600
local ANIM_SEQUENCE = "/Script/Engine.AnimSequence"

local WEAPON_SHOTS = {
    YanYueDao = {
        -- The QTE attaches the glaive at 1.530s. Take the subsequent
        -- flourish and stop in the settled stance before the final windup.
        clip = "/HuaShira/Characters/Boss/YuDing/Anim/"
            .. "Hun_Perfect_Dodge_Attack_YuDing_Hun.Hun_Perfect_Dodge_Attack_YuDing_Hun",
        first = 93 / 60, last = 369 / 60, hold = .12,
        startRate = .5, normalFrom = 260 / 60, downstroke = GLAIVE_DOWNSTROKE,
        startRadius = 680, startHeight = 200,
        endRadius = 175, endHeight = 112, focal = 23.5,
        finishPush = { duration = .38, distance = 84, drop = 27 },
        startAimOffset = -31, endAimOffset = 3.5,
        backdropClearance = 150,
        swingFolder = GLAIVE_EXECUTION_AUDIO,
        -- Offset each native sound by its measured attack time.
        swings = {
            { peak = 129 / 60, lead = .285, name = GLAIVE_WAVE_1 },
            { peak = 234 / 60, lead = .295, name = GLAIVE_WAVE_2 },
            { peak = GLAIVE_DOWNSTROKE, lead = .285, name = GLAIVE_WAVE_1 },
        },
    },
    HeiMoShang = {
        clip = "/HuaShira/Characters/Hero/Hero_Hun/Animation/ExE/HeiMoShang/"
            .. "Hun_HeiMoShang_EXE_F_05.Hun_HeiMoShang_EXE_F_05",
        victimTrack = ExecutionView.HeiMoShang,
        first = 0, last = 118 / 60, hold = .18,
        startRate = .72, normalFrom = .45, downstroke = 1.817,
        finishDuration = .95, endRate = .05,
        drawAt = 1.37848, focal = 12.7, backdropClearance = 220,
        daze = { hit = .767, resumePose = 69 / 60, duration = 1, ramp = .10 },
        -- Match the attack and receiver timelines, including the impact at .767s.
        swings = {
            { peak = .767, lead = 0, name = "SFX_Combat_Hit_FistTieGui_Meat_Heavy",
                folder = "/Game/Wwise/Events/SFX_Impact/ShouJi/PHM/" },
            { peak = 1.16989, lead = 0, name = "SFX_Combat_Hun_Common_BaDao_New",
                folder = HUN_SOUND .. "Wave_Stab_BaDao/" },
            { peak = 1.62828, lead = 0, name = "SFX_Combat_Hun_GuiTouBlade_Wave_Heavy",
                folder = HUN_SOUND .. "Wave_Stab_BaDao/GuiTouBlade/" },
            { peak = 1.81644, lead = 0, name = "SFX_Combat_Hit_SlashTangBlade_Meat_Heavy",
                folder = HUN_SOUND .. "ShouJi/" },
        },
    },
    ZiMingJian = {
        clip = "/HuaShira/Characters/Hero/Hero_Hun/Animation/ExE/ZiMingJian/"
            .. "Hun_ZiMing_EXE_F_01.Hun_ZiMing_EXE_F_01",
        victimTrack = ExecutionView.ZiMingJian,
        first = 0, last = ZiMing.lastPose, hold = .16,
        startRate = .86, normalFrom = .42, slowFrom = 153 / 60, endRate = .30,
        hideWeaponAt = .357, focal = 17.5, backdropClearance = 220, lightX = -220,
        swings = ZiMing.swings,
    },
    BieLiCanGou = {
        clip = "/HuaShira/Characters/Hero/Hero_Hun/Animation/ExE/BieLiCanGou/"
            .. "Hun_BieLiCanGou_ExE_F_03.Hun_BieLiCanGou_ExE_F_03",
        victimTrack = ExecutionView.BieLiCanGou,
        first = 0, last = 201 / 60, hold = .16,
        focal = 12, backdropClearance = 220, lightX = -290,
        swings = {
            { peak = .2737, lead = 0, name = "SFX_Combat_Hun_ShuangGou_Wave_Middle", folder = DUAL_HOOK_SOUND },
            { peak = .7503, lead = 0, name = "SFX_Combat_Hun_ShuangGou_Wave_Heavy", folder = DUAL_HOOK_SOUND },
            { peak = 1.020, lead = 0, name = "SFX_Combat_Hit_SlashDoubleBlade_Meat_Middle", folder = HUN_SOUND .. "ShouJi/" },
            { peak = 1.4711, lead = 0, name = "SFX_Combat_Hun_ShuangGou_Stab_Heavy", folder = DUAL_HOOK_SOUND },
            { peak = 1.780, lead = 0, name = "SFX_Combat_Hit_SlashDoubleBlade_Meat_Heavy", folder = HUN_SOUND .. "ShouJi/" },
            { peak = 3.3241, lead = 0, name = "SFX_Combat_Hun_ShuangGou_Wave_Heavy", folder = DUAL_HOOK_SOUND },
        },
    },
}
local SINGLE_HAND_SHOTS = { "HeiMoShang", "ZiMingJian" }
local FAMILY_SHOTS = { Long = "YanYueDao", Double = "BieLiCanGou" }
local WEAPON_DIALOGUE = {
    { folder = "JHSY", event = "Vo_Plot_JHSY_HXMM_Inanis_Hun_24", text = "我会彻底结束剩下的一切" },
}
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

local function clamp(t) return math.max(0, math.min(1, t)) end
local function lerp(a, b, t) return a + (b - a) * t end
local function yaw(value) return { Pitch = 0, Yaw = value, Roll = 0 } end
local function smooth(t) return t * t * (3 - 2 * t) end
local function angleDelta(a, b) return (b - a + 180) % 360 - 180 end

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

-- Invert the integrated playback rate for a cue on the source animation.
local function weaponTimeAtSource(shot, timing, source)
    local slowdown = timing.slowdown
    if slowdown and source > slowdown.source then
        local distance = source - slowdown.source
        local rate = math.sqrt(slowdown.startRate^2 + 2 * slowdown.acceleration * distance)
        return timing.front + 2 * distance / (slowdown.startRate + rate)
    end
    if source >= timing.normalFrom then return timing.rampDuration + source - timing.normalFrom end
    local distance = source - shot.first
    local rate = math.sqrt(timing.startRate^2 + 2 * timing.acceleration * distance)
    return 2 * distance / (timing.startRate + rate)
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

local function executionTrack(view, t)
    local keys, frame = view.frames, t * view.rate
    local i = math.min(#keys - 1, math.floor(frame) + 1)
    local before, a = keys[math.max(1, i - 1)], keys[i]
    local b, after = keys[i + 1], keys[math.min(#keys, i + 2)]
    local u = clamp(frame - i + 1)
    local sample = {}
    for axis = 1, #a do
        sample[axis] = hermite(a[axis], b[axis], (b[axis] - before[axis]) * .5, (after[axis] - a[axis]) * .5, u)
    end
    return sample
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

function Ending:lookAt(eye, aim, focalLength, focus)
    local rotation = self.math:FindLookAtRotation(eye, aim)
    local dx, dy, dz = aim.X - eye.X, aim.Y - eye.Y, aim.Z - eye.Z
    local depth = ((focus.X - eye.X) * dx + (focus.Y - eye.Y) * dy + (focus.Z - eye.Z) * dz)
        / math.sqrt(dx * dx + dy * dy + dz * dz)
    self:cameraPose(eye, { Pitch = rotation.Pitch, Yaw = rotation.Yaw, Roll = 0 }, focalLength,
        SALUTE_APERTURE, math.max(30, depth))
end

function Ending:prepareOrbit()
    local eye, rotation, focus = self:openingPose(Opening.landingAt)
    local endEye = self:point(SHOULDER_X, SHOULDER_Y, self.snowGround + SHOULDER_Z)
    local endAim = self:point(HUN_DISTANCE - 2, -7, self.hunGround + 135)
    local endRotation = self.math:FindLookAtRotation(endEye, endAim)
    local center = self:point(0, 0, eye.Z)
    local heading = self.math:FindLookAtRotation(center, eye).Yaw
    local endHeading = self.math:FindLookAtRotation(center, endEye).Yaw
    local turn = (endHeading - heading) % 360
    local startRadius = math.sqrt((eye.X - center.X)^2 + (eye.Y - center.Y)^2)
    self.orbit = {
        startRadius = startRadius,
        endRadius = math.sqrt(SHOULDER_X^2 + SHOULDER_Y^2),
        startHeight = eye.Z,
        endHeight = endEye.Z,
        startAngle = heading,
        turn = turn,
        aimHeight = eye.Z + startRadius * math.tan(math.rad(rotation.Pitch)),
        endAimHeight = endAim.Z,
        endAimDistance = math.sqrt((endAim.X - endEye.X)^2 + (endAim.Y - endEye.Y)^2),
        openingRotation = rotation,
        openingFocusOffset = focus - startRadius,
        yawTravel = turn + angleDelta(rotation.Yaw + turn, endRotation.Yaw),
        hunFocus = self:point(HUN_DISTANCE - 8, 0, self.hunGround + 148),
    }
end

function Ending:orbitFrame(t)
    local orbit = self.orbit
    -- Short ramps at each end, with one constant-speed pan and lift through the middle.
    local p = dolly(t, ORBIT_DURATION, ORBIT_RAMP, ORBIT_RAMP)
    local heading = math.rad(orbit.startAngle - self.direction + orbit.turn * p)
    local radius = lerp(orbit.startRadius, orbit.endRadius, p)
    local eye = self:point(radius * math.cos(heading), radius * math.sin(heading),
        lerp(orbit.startHeight, orbit.endHeight, p))
    -- Keep Snow's head in frame during the lift, then reveal Hun as the lens
    -- clears the shoulder. Ease the pitch as the point of interest moves away.
    local rack = smooth(clamp((p - .62) / .38))
    local snowPitch = math.deg(math.atan((orbit.aimHeight - eye.Z) / radius))
    local hunPitch = math.deg(math.atan((orbit.endAimHeight - eye.Z) / orbit.endAimDistance))
    local rotation = { Pitch = lerp(snowPitch, hunPitch, rack),
        Yaw = orbit.openingRotation.Yaw + orbit.yawTravel * p,
        Roll = orbit.openingRotation.Roll * (1 - p) }
    local forward = self.math:GetForwardVector(rotation)
    local hun = orbit.hunFocus
    local hunFocus = (hun.X - eye.X) * forward.X + (hun.Y - eye.Y) * forward.Y + (hun.Z - eye.Z) * forward.Z
    local focus = lerp(radius + orbit.openingFocusOffset, math.max(30, hunFocus), rack)
    self:cameraPose(eye, rotation, lerp(Opening.openingFocal, SALUTE_FOCAL, p), SALUTE_APERTURE, focus)
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
        if self.snow then self:addLight(SNOW_LIGHT, 0, self.snowGround, 0) end
        -- The original Hun capsule is at yaw 68; here it faces back down the
        -- new scene's axis. Rotate its three character lights with it.
        local hunX = self.weaponShot and 0 or HUN_DISTANCE
        if self.weaponShot and self.weaponShot.victimTrack then hunX = self.weaponShot.lightX or -150 end
        for _, light in ipairs(HUN_LIGHTS) do self:addLight(light, hunX, self.hunGround, 180 - 68) end
    end)
    if not ok then
        for i = #self.actors, baseline + 1, -1 do
            local lamp = self.actors[i]
            local removed = pcall(function() if valid(lamp) then lamp:K2_DestroyActor() end end)
            if removed then table.remove(self.actors, i) end
        end
        print("[PBZBloodyPalace] ending lights fallback: " .. tostring(reason) .. "\n")
    else
        print("[PBZBloodyPalace] ending character lights ready\n")
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
    local function prepareEvent(path, owner)
        local event = load(path, AK_EVENT)
        local emitter = (owner or self.hun):AddComponentByClass(componentClass, false, self.identity, false)
        assert(valid(emitter), "过场声音组件未就绪")
        emitter.AkAudioEvent = event
        return { emitter = emitter }
    end
    local function prepareEffect(path, label, owner)
        local ok, effect = pcall(prepareEvent, path, owner)
        if ok then return effect end
        print("[PBZBloodyPalace] ending " .. label .. " fallback: " .. tostring(effect) .. "\n")
    end

    self.titleImpact = prepareEffect(TITLE_IMPACT, "title impact", self.camera)
    if self.snow then
        -- Seq127-1_Sound starts this effects stem at zero. Its impact is
        -- already aligned with the blade, so play it from the first frame.
        self.openingAudio = prepareEffect(OPENING_AUDIO, "opening effects")
        self.breathAudio = prepareEffect(SNOW_BREATH, "Snow breath", self.snow)
    end
    local shot = self.weaponShot
    if shot and shot.swings then
        local effects = {}
        self.weaponSwings = {}
        for _, cue in ipairs(shot.swings) do
            local effect = effects[cue.name]
            if effect == nil then
                local path = (cue.folder or shot.swingFolder) .. cue.name .. "." .. cue.name
                effect = prepareEffect(path, "weapon swing " .. cue.name) or false
                effects[cue.name] = effect
            end
            if effect then
                local beat = weaponTimeAtSource(shot, self.weaponTiming, cue.peak)
                self.weaponSwings[#self.weaponSwings + 1] = { at = beat - cue.lead, name = cue.name, emitter = effect.emitter }
            end
        end
    end

    local cues = self.weaponShot and WEAPON_DIALOGUE or DIALOGUE
    if cues == DIALOGUE then
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
    end
    for i, cue in ipairs(cues) do
        local path = "/Game/Wwise/Events/VO/Plot/" .. cue.folder .. "/" .. cue.event .. "." .. cue.event
        self.dialogue[i] = prepareEvent(path)
        self.dialogue[i].cue = cue
    end
end

function Ending:postSound(line, atEmitter)
    assert(valid(self.sound) and valid(line.emitter) and valid(line.emitter.AkAudioEvent), "过场声音已卸载")
    local event = line.emitter.AkAudioEvent
    local id
    if atEmitter then
        id = self.sound:PBZPostEventOnAkComponent(event, line.emitter, nil, true, false, 0)
    else
        id = self.sound:PBZPostEventGlobal(event, nil)
    end
    assert(type(id) == "number" and id > 0 and id ~= 0xffffffff, "未取得过场声音播放 ID")
    line.id = id
    return event, id
end

function Ending:stopSound(line, fade)
    if line and line.id then
        if valid(self.sound) then self.sound:PBZStopPlayingID(line.id, fade or 0) end
        line.id = nil
    end
end

function Ending:updateWeaponSound(before, now, source)
    if self.skipped or not self.weaponSwings then return end
    local swing
    for _, cue in ipairs(self.weaponSwings) do
        if before < cue.at and cue.at <= now then swing = cue end
    end
    -- A long frame can skip a beat. Never stack missed swings on that frame.
    if not swing or now - swing.at > .18 then return end
    local ok, reason = pcall(self.postSound, self, swing, true)
    local description = self.weaponShot == WEAPON_SHOTS.ZiMingJian and "ZiMing sound" or "blade sweep"
    if ok then
        print(("[PBZBloodyPalace] ending %s %s; source=%.3f; motion=%.3f; PlayingID=%d\n")
            :format(description, swing.name, source, now, swing.id))
    else
        print("[PBZBloodyPalace] ending " .. description .. " fallback: " .. tostring(reason) .. "\n")
    end
end

function Ending:openingEffects(play)
    if not self.openingAudio then return end
    local ok, reason = pcall(function()
        if play then
            self:postSound(self.openingAudio)
            print("[PBZBloodyPalace] ending opening effects: native Seq127-1 S01\n")
        else
            self:stopSound(self.openingAudio, OPENING_SOUND_FADE)
        end
    end)
    if not ok then print("[PBZBloodyPalace] ending opening effects fallback: " .. tostring(reason) .. "\n") end
end

function Ending:updateBreath(elapsed)
    local sound = self.breathAudio
    if not sound or not self.orbitAt then return end
    local approach = self.joinedAt and elapsed - self.joinedAt - SHEATH_BEGIN or -1
    if approach >= 0 and not self.breathFading then
        self.breathFading = true
        local stopped, why = pcall(self.stopSound, self, sound, BREATH_TAIL)
        if stopped then
            print("[PBZBloodyPalace] ending Snow breath fading with full-body approach\n")
        else
            print("[PBZBloodyPalace] ending Snow breath fade fallback: " .. tostring(why) .. "\n")
        end
    elseif not self.breathFading and elapsed >= (self.nextBreathAt or FIRST_BREATH) then
        self.nextBreathAt = elapsed + BREATH_PERIOD
        local started, why = pcall(function()
            self:stopSound(sound, .10)
            -- The authored breathing event contains breath takes only. The
            -- combat death event can pick cries as well as breath at random.
            self:postSound(sound, true)
        end)
        if not started then
            print("[PBZBloodyPalace] ending Snow breath fallback: " .. tostring(why) .. "\n")
        elseif not self.breathPlayed then
            self.breathPlayed = true
            print("[PBZBloodyPalace] ending Snow breath repeats with the kneel\n")
        end
    end
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
    if self.skipped then return end
    local line = self.dialogue[index]
    if not line or line.sent then return end
    line.sent = true
    local ok, reason = pcall(function()
        -- Use the same global post/seek pair as the native music gallery.
        -- The owned component only keeps this event and its bank resident.
        local event, id = self:postSound(line)
        local cue = line.cue
        local route = cue.at and self:seekVoice(event, id, cue) or "full clip"
        if index == 1 and self.face then self.face:play(self.gameplay:GetRealTimeSeconds(self.pawn)) end
        print(("[PBZBloodyPalace] ending voice: %s; offset=%.3fs; seek=%s\n"):format(cue.text, cue.at or 0, route))
    end)
    if not ok then
        pcall(self.stopSound, self, line)
        print("[PBZBloodyPalace] ending voice fallback: " .. tostring(reason) .. "\n")
        return
    end
end

function Ending:prepareWeaponShot(shot, weapon)
    local clip = load(shot.clip, ANIM_SEQUENCE)
    local root = FName("root")
    local focus = FName("spine_05")
    assert(clip:GetPlayLength() >= shot.last and self.hunMesh:DoesSocketExist(root)
        and self.hunMesh:DoesSocketExist(focus), "武器结算动作或对焦骨骼不可用")
    self.hunMesh:OverrideAnimationData(clip, false, false, shot.first, 1)
    assert(same(self.hunMesh.AnimationData.AnimToPlay, clip), "武器结算动作未绑定到演出角色")
    pose(self.hunMesh, clip, shot.first)
    local animator = self.hunMesh:GetAnimInstance()
    assert(valid(animator), "武器结算动画实例不可用")
    -- Drive root travel from the execution's sampled track on the clone.
    -- The single-node pose stays locked to the reference root in both shots.
    animator:SetRootMotionMode(1) -- IgnoreRootMotion
    if shot.drawAt then Props.setArmed(weapon, self.hunMesh, false) end
    self.weaponRootSocket, self.weaponFocusSocket = root, focus
    self.weaponFacing = yaw(self.hun:K2_GetActorRotation().Yaw)
    self.weaponCapsuleHeight = self.hun:K2_GetActorLocation().Z - self.hunGround
    local facing = self.math:GetForwardVector(self.weaponFacing)
    self.weaponForwardX, self.weaponForwardY = facing.X, facing.Y
    local startRate, normalFrom = shot.startRate or 1, shot.normalFrom or shot.first
    local rampDuration = 2 * (normalFrom - shot.first) / (1 + startRate)
    local timing = { startRate = startRate, normalFrom = normalFrom, rampDuration = rampDuration,
        acceleration = rampDuration > 0 and (1 - startRate) / rampDuration or 0 }
    local finishAt = shot.slowFrom or shot.downstroke or shot.last
    timing.front = weaponTimeAtSource(shot, timing, finishAt)
    if shot.endRate then
        local distance = shot.last - finishAt
        local duration = shot.finishDuration or 2 * distance / (1 + shot.endRate)
        -- With a fixed duration, fit the initial slow-motion rate to the same final pose.
        local startRate = shot.finishDuration and (2 * distance / duration - shot.endRate) or 1
        assert(startRate > shot.endRate, "武器收尾的慢动作时长无效")
        timing.slowdown = { source = finishAt, startRate = startRate,
            acceleration = (shot.endRate - startRate) / duration, duration = duration }
    end
    timing.duration = timing.slowdown and timing.front + timing.slowdown.duration
        or weaponTimeAtSource(shot, timing, shot.last)
    if shot.daze then
        local hit = weaponTimeAtSource(shot, timing, shot.daze.hit)
        local segment = weaponTimeAtSource(shot, timing, shot.daze.resumePose) - hit
        local duration, ramp = shot.daze.duration, shot.daze.ramp
        assert(ramp < segment and segment < duration and 2 * ramp < duration, "处决慢动作的时长无效")
        timing.daze = { hit = hit, resume = hit + duration, duration = duration, ramp = ramp, delay = duration - segment }
        timing.duration = timing.duration + timing.daze.delay
    end
    self.weaponTiming = timing
end

local function discardProps(owner, components)
    for i = #components, 1, -1 do
        local component = components[i]
        if valid(component) then pcall(component.K2_DestroyComponent, component, owner) end
        components[i] = nil
    end
end

function Ending:prepareHun()
    local created = {}
    if not self.saluteEnding then
        local ok, weapon = pcall(Props.prepare, self.pawn, self.hun, self.math, self.identity, created, self.weaponSlot)
        if not ok then
            discardProps(self.hun, created)
            print("[PBZBloodyPalace] ending equipped prop unavailable: " .. tostring(weapon) .. "\n")
            weapon = nil
        end
        local equipped = weapon ~= nil
        weapon = weapon or Props.prepareGlaive(self.hun, self.identity, load, created)
        local route = FAMILY_SHOTS[weapon.family] or SINGLE_HAND_SHOTS[math.random(#SINGLE_HAND_SHOTS)]
        local shot = WEAPON_SHOTS[route]
        self:prepareWeaponShot(shot, weapon)
        self.weapon, self.weaponShot, self.weaponRoute = weapon, shot, route
        self.shotEnd = shot.hold + self.weaponTiming.duration
        self.timelineEnd = self.shotEnd
        print(("[PBZBloodyPalace] ending weapon shot selected; route=%s; type=%s; prop=%s; source=%.3f-%.3f\n")
            :format(route, weapon.weaponType, equipped and "equipped" or "stock", shot.first, shot.last))
        if self.weaponTiming.slowdown then
            local slowdown = self.weaponTiming.slowdown
            print(("[PBZBloodyPalace] ending slowdown; from=%.3fs; duration=%.3fs; startRate=%.2f; endRate=%.2f\n")
                :format(slowdown.source, slowdown.duration, slowdown.startRate, shot.endRate))
        end
        return
    end

    self.saluteAt = SHOULDER_HOLD + FULL_BODY_PUSH
    local salute
    local ok, reason = pcall(function()
        local weapon = Props.prepare(self.pawn, self.hun, self.math, self.identity, created)
        salute = loadSalute()
        holdSalute(self.hunMesh, salute)
        Props.loadUnarm(weapon, function(path) return load(path, "/Script/Engine.AnimMontage") end)
        pose(self.hunMesh, weapon.clip, 0)
        local animator = self.hunMesh:GetAnimInstance()
        assert(valid(animator) and animator:Montage_IsActive(weapon.clip), "原版收刀动作未就绪")
        self.weapon = weapon
        self.saluteAt = SHEATH_BEGIN + weapon.length
    end)
    if not ok then
        discardProps(self.hun, created)
        self.weapon = nil
        salute = salute or loadSalute()
        holdSalute(self.hunMesh, salute)
        pose(self.hunMesh, salute, SALUTE_START)
        print("[PBZBloodyPalace] ending weapon fallback: " .. tostring(reason) .. "\n")
    end
    self.shotEnd = self.saluteAt + SALUTE_END - SALUTE_START
    self.timelineEnd = ORBIT_START + ORBIT_DURATION + self.shotEnd
end

function Ending:weaponPoint(forward, right, height)
    return { X = self.center.X + forward * self.weaponForwardX - right * self.weaponForwardY,
        Y = self.center.Y + forward * self.weaponForwardY + right * self.weaponForwardX,
        Z = self.hunGround + height }
end

function Ending:closeDaze()
    if self.daze then self.daze:close(); self.daze = nil end
end

function Ending:updateDaze(elapsed)
    if not self.daze then return end
    local cue = self.weaponTiming.daze
    if elapsed >= cue.resume then
        self:closeDaze()
        print(("[PBZBloodyPalace] ending execution resumed after %.1fs slow motion\n"):format(cue.duration))
    elseif elapsed >= cue.hit and not self.daze.started then
        local ok, reason = pcall(self.daze.start, self.daze)
        if ok then
            print("[PBZBloodyPalace] ending MoYuan daze started on impact\n")
        else
            self:closeDaze()
            print("[PBZBloodyPalace] ending daze fallback: " .. tostring(reason) .. "\n")
        end
    end
end

function Ending:weaponFrame(t)
    local shot, timing = self.weaponShot, self.weaponTiming
    local elapsed = math.max(0, t - shot.hold)
    local cue = timing.daze
    -- Remove time smoothly from the playback clock to slow the recoil and return to full speed.
    local motion = cue and elapsed - cue.delay * dolly(elapsed - cue.hit, cue.duration, cue.ramp, cue.ramp) or elapsed
    local previousMotion = self.lastWeaponMotion or 0
    local sourceTime = motion < timing.rampDuration
        and shot.first + motion * (timing.startRate + .5 * timing.acceleration * motion)
        or math.min(shot.last, timing.normalFrom + motion - timing.rampDuration)
    if timing.slowdown and motion >= timing.front then
        local slowdown = timing.slowdown
        local tail = math.min(motion - timing.front, slowdown.duration)
        sourceTime = slowdown.source + tail * (slowdown.startRate + .5 * slowdown.acceleration * tail)
        if t >= self.shotEnd then sourceTime = shot.last end
    end
    local landed = shot.downstroke and previousMotion < timing.front and motion >= timing.front
    -- Present the exact drop pose once when a rendered tick straddles the beat.
    if landed and motion - timing.front <= .065 then sourceTime = shot.downstroke end
    if sourceTime > shot.first and not self.weaponActionStarted then
        self.weaponActionStarted = true
        self:say(1)
    end
    if sourceTime ~= self.lastWeaponSource then
        self.hunMesh:SetPosition(sourceTime, false)
        self.lastWeaponSource = sourceTime
    end
    if motion ~= previousMotion then
        self.lastWeaponMotion = motion
        self:updateWeaponSound(previousMotion, motion, sourceTime)
    end

    if shot.victimTrack then
        if shot.drawAt then
            local armed = sourceTime >= shot.drawAt
            if self.weapon.armed ~= armed then Props.setArmed(self.weapon, self.hunMesh, armed) end
        end
        if shot.hideWeaponAt and not self.weaponHidden and sourceTime >= shot.hideWeaponAt then
            for _, part in ipairs(self.weapon.parts) do part.mesh:SetVisibility(false, false) end
            self.weaponHidden = true
        end
        local key = executionTrack(shot.victimTrack, sourceTime)
        local travel, right, turn = key[7], key[8] or 0, key[9] or 0
        if self.executionTravel ~= travel or self.executionRight ~= right or self.executionYaw ~= turn then
            self:place(self.hun, self:weaponPoint(travel, right, self.weaponCapsuleHeight),
                yaw(self.weaponFacing.Yaw + turn))
            self.executionTravel, self.executionRight, self.executionYaw = travel, right, turn
        end
        local eye = self:weaponPoint(key[1], key[2], key[3])
        local gaze = self:weaponPoint(key[4], key[5], key[6])
        self:lookAt(eye, gaze, shot.focal, gaze)
        if self.ziMing and not self.ziMing.closed then
            local ready, reason = pcall(self.ziMing.update, self.ziMing, sourceTime, eye, key, self.skipped)
            if not ready then
                self.ziMing:close()
                print("[PBZBloodyPalace] ending ZiMing effects fallback: " .. tostring(reason) .. "\n")
            end
        end
        self:updateDaze(elapsed)
        return
    end

    local p = dolly(motion, timing.front, .27, .20)
    if p == 0 and self.weaponCameraProgress == 0 then return end
    self.weaponCameraProgress = p
    -- Start and end on Hun's standing axis. Positive yaw turns toward his
    -- right, clockwise when viewed from above.
    local heading = 2 * math.pi * p
    local forward, right = math.cos(heading), math.sin(heading)
    local x = self.weaponForwardX * forward - self.weaponForwardY * right
    local y = self.weaponForwardY * forward + self.weaponForwardX * right
    local finish = shot.finishPush
    local push = dolly(motion - (timing.front - finish.duration), finish.duration, .08, .10)
    local radius = lerp(shot.startRadius, shot.endRadius + finish.distance, p) - finish.distance * push
    local height = lerp(shot.startHeight, shot.endHeight + finish.drop, p) - finish.drop * push
    local eye = { X = self.center.X + radius * x, Y = self.center.Y + radius * y, Z = self.hunGround + height }
    local focus = self.hunMesh:GetSocketLocation(self.weaponFocusSocket)
    local track = { X = focus.X, Y = focus.Y, Z = focus.Z }
    if self.weaponAim then
        local blend = 1 - math.exp(-12 * math.max(0, t - self.weaponAimAt))
        track.X = lerp(self.weaponAim.X, track.X, blend)
        track.Y = lerp(self.weaponAim.Y, track.Y, blend)
        track.Z = lerp(self.weaponAim.Z, track.Z, blend)
    end
    self.weaponAim, self.weaponAimAt = track, t
    -- Follow the torso through the turn, then settle on the standing axis.
    local follow = smooth(clamp(math.min(p, 1 - p) / .10))
    local aim = { X = lerp(self.center.X, track.X, follow), Y = lerp(self.center.Y, track.Y, follow),
        Z = track.Z + lerp(shot.startAimOffset, shot.endAimOffset, p) }
    self:lookAt(eye, aim, shot.focal, focus)
    if landed then
        print(("[PBZBloodyPalace] ending downstroke camera; source=%.3f; planned=%.3f; clockwiseDegrees=%.1f\n")
            :format(sourceTime, shot.downstroke, math.deg(heading)))
    end
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
        print("[PBZBloodyPalace] ending full-body sheath started\n")
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

function Ending:playResultMusic(realNow)
    if not self.music or self.resultMusicStarted then return end
    self.resultMusicStarted = true
    local started, reason = pcall(self.music.playResult, self.music, realNow, self.weaponShot ~= nil)
    if not started then print("[PBZBloodyPalace] ending music fallback: " .. tostring(reason) .. "\n") end
end

function Ending:frame(elapsed, realNow)
    if self.weaponShot then self:weaponFrame(elapsed); return end
    local snowTime = math.min(elapsed, Opening.duration)
    if elapsed > Opening.duration then
        -- Resample the planted tail of the kneel. The turnarounds have zero velocity.
        local phase = (elapsed - Opening.duration) * (2 * math.pi / BREATH_PERIOD)
        snowTime = Opening.duration - BREATH_SPAN * (1 - math.cos(phase)) / 2
    end
    if snowTime ~= self.snowTime then
        self:placeSnow(snowTime)
        self.snowTime = snowTime
    end
    if elapsed >= OPENING_SOUND_END and not self.openingFading then
        self.openingFading = true
        self:openingEffects(false)
    end
    if elapsed < ORBIT_START then
        -- Hold the planted framing while the authored animation and sound continue.
        local eye, rotation, focus = self:openingPose(math.min(elapsed, Opening.landingAt))
        self:cameraPose(eye, rotation, Opening.openingFocal, Opening.openingAperture, focus)
        return
    end
    if not self.orbitAt then
        self.hun:SetActorHiddenInGame(false)
        self.orbitAt = ORBIT_START
        print(("[PBZBloodyPalace] ending orbit started after blade plant; start=%.3fs; duration=%.2fs\n")
            :format(self.orbitAt, ORBIT_DURATION))
    end
    if elapsed >= MUSIC_START then self:playResultMusic(realNow) end
    local orbitTime = elapsed - self.orbitAt
    if orbitTime < ORBIT_DURATION then
        self:updateBreath(elapsed)
        self:orbitFrame(orbitTime)
        return
    end
    if not self.joinedAt then
        -- The shoulder hold starts on arrival, even after a long frame.
        self.joinedAt = elapsed
        self.timelineEnd = elapsed + self.shotEnd
        print("[PBZBloodyPalace] ending orbit reached shoulder; armed hold\n")
    end
    local t = math.min(self.shotEnd, elapsed - self.joinedAt)
    self:updateBreath(elapsed)
    self:poseHun(t)
    -- Rest on the full figure through the sheath, then push and rise as the
    -- salute begins. Both moves leave and arrive at zero velocity.
    local full = dolly(t - SHOULDER_HOLD, FULL_BODY_PUSH, .29, .36)
    local close = dolly(t - self.saluteAt, self.shotEnd - self.saluteAt, .42, .58)
    if full == self.fullFrame and close == self.closeFrame then return end
    local eye = self:point(lerp(SHOULDER_X, HUN_DISTANCE - FULL_BODY_DISTANCE, full)
        + (FULL_BODY_DISTANCE - SALUTE_DISTANCE) * close,
        lerp(SHOULDER_Y, 84, full) + 15 * math.sin(math.pi * full) - 36 * close,
        lerp(self.snowGround + SHOULDER_Z, self.hunGround + 135, full) + 43 * close)
    local aim = self:point(HUN_DISTANCE - 2, lerp(-7, -4, full) + 4 * close,
        self.hunGround + lerp(135, 106, full) + 55 * close)
    local focus = self:point(HUN_DISTANCE - 8, 0, self.hunGround + lerp(148, 166, full) + 5 * close)
    self:lookAt(eye, aim, SALUTE_FOCAL, focus)
    self.fullFrame, self.closeFrame = full, close
end

function Ending:freeze(realNow)
    local backdropShown = self:finishBackdrop(realNow)
    if backdropShown == nil then return false end
    self.frozenAt = realNow
    for _, cloth in ipairs(self.clothes) do
        if valid(cloth) then cloth:SuspendSimulation() end
    end
    if self.face then self.face:close(); self.face = nil end
    local titleShown = self:showTitle()
    self.titleAnimating = titleShown
    local poseName = self.weaponRoute or "salute"
    if self.weaponShot then
        local root = self.hunMesh:GetSocketLocation(self.weaponRootSocket)
        local distance = self.weaponShot.victimTrack and "executionTravelCm" or "centerErrorCm"
        print(("[PBZBloodyPalace] ending weapon framing; %s=%.1f; focusCm=%.1f\n")
            :format(distance, math.sqrt((root.X - self.center.X)^2 + (root.Y - self.center.Y)^2), self.focus))
    end
    print(("[PBZBloodyPalace] ending %s frozen; title=%s; backdrop=%s; frameCallbacks=%d; maxFrameGapMs=%.1f; serviceFallbacks=%d\n")
        :format(poseName, tostring(titleShown), tostring(backdropShown), self.frameSamples, self.maxFrameGap * 1000,
            self.serviceFallbacks))
    return true
end

function Ending:confirmPressed()
    local down = false
    for _, key in ipairs(self.confirmKeys) do
        if self.controller:IsInputKeyDown(key)
            or (valid(self.confirmRouter) and self.confirmRouter:IsUIKeyHeld(key))
            or self.controller:WasInputKeyJustPressed(key) then
            down = true
            break
        end
    end
    local pressed = self.confirmArmed and down
    self.confirmArmed = not down
    return pressed
end

function Ending:seekToFreeze(realNow)
    self.skipped, self.skipAt = true, realNow
    self:closeDaze()
    if self.fade then
        self.fade:close()
        self.fade = nil
    end
    for _, sound in ipairs(self.weaponSwings or {}) do pcall(self.stopSound, self, sound, .12) end
    for _, line in ipairs(self.dialogue) do pcall(self.stopSound, self, line, .12) end
    if self.saluteEnding then
        self.openingFading, self.breathFading = true, true
        pcall(self.stopSound, self, self.openingAudio, .12)
        pcall(self.stopSound, self, self.breathAudio, .12)
        self.joinedAt = self.joinedAt or (self.orbitAt or ORBIT_START) + ORBIT_DURATION
        self.timelineEnd = self.joinedAt + self.shotEnd
    end
    self:frame(self.timelineEnd, realNow)
    self.frameEnded = true
    print("[PBZBloodyPalace] ending confirmed during action; jumped to final pose\n")
end

function Ending:advance(realNow, engineFrame)
    assert(same(self.controller:K2_GetPawn(), self.pawn) and valid(self.hun) and valid(self.camera)
        and (self.weaponShot or valid(self.snow) and valid(self.sword)), "血宫通关过场角色或镜头已离场")
    if engineFrame then
        self.frameSamples = self.frameSamples + 1
        self.maxFrameGap = math.max(self.maxFrameGap, realNow - self.lastFrameAt)
        self.lastFrameAt = realNow
    end
    if not self.started or self.gameplay:IsGamePaused(self.pawn) then return end
    if not self.summaryConfirmed and self:confirmPressed() then
        self.summaryConfirmed = true
        if not self.frozenAt and not self.frameEnded then self:seekToFreeze(realNow); return end
        print("[PBZBloodyPalace] ending freeze confirmed\n")
    end
    if self.frozenAt then self:presentFreeze(realNow); return end
    if not self.frameEnded then
        local elapsed = self.gameplay:GetTimeSeconds(self.pawn) - self.started
        self:frame(math.max(0, elapsed), realNow)
        self.frameEnded = elapsed >= self.timelineEnd
        return
    end
    -- Give the final pose one rendered frame to update its bones and cloth.
    if self.skipped then
        if realNow <= self.skipAt then return end
        if self.weaponShot then
            self.weaponAim = nil
            self:weaponFrame(self.timelineEnd)
        end
    end
    if self:freeze(realNow) and self.summaryConfirmed then self:presentFreeze(realNow) end
end

function Ending:cameraActive()
    return same(self.controller:K2_GetPawn(), self.pawn) and same(self.controller:GetViewTarget(), self.camera)
end

function Ending:anchorWeaponShot()
    local sampled = self.hunMesh:GetSocketLocation(self.weaponRootSocket)
    local anchor = self:point(0, 0, self.hunGround + 3)
    local at = self.hun:K2_GetActorLocation()
    self:place(self.hun, { X = at.X + anchor.X - sampled.X, Y = at.Y + anchor.Y - sampled.Y,
        Z = at.Z + anchor.Z - sampled.Z }, self.hun:K2_GetActorRotation())
    self.weaponCapsuleHeight = self.hun:K2_GetActorLocation().Z - self.hunGround
    -- Sample the posed and centered chest before the transition is revealed.
    self.weaponCameraProgress, self.weaponAim, self.executionTravel = nil, nil, nil
    self:weaponFrame(0)
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
    if self.weaponShot then self:anchorWeaponShot() end
    return true
end

function Ending:cover(realNow)
    assert(self.fade and realNow < self.introDeadline, "血宫结算转场等待超时")
    return self.fade:update(realNow) == "black" and self.fade:canReveal(realNow)
end

function Ending:showFloorResult()
    self:hideHUD()
    self.fade:setCoveredUI(true)
    self:releaseInputTag()
    self.waitingForConfirm = true
    print("[PBZBloodyPalace] ending transition held for final floor confirmation\n")
end

function Ending:confirm(realNow)
    if not self.waitingForConfirm then return end
    self:lockInput()
    self.introDeadline = realNow + 15
    self.fade:setCoveredUI(false)
    self.waitingForConfirm = nil
end

function Ending:lockInput()
    self.tagged = true
    self.input:AddInputModeTag(self.camera, { TagName = FName("InputType.DisableAll") }, self.camera)
end

function Ending:releaseInputTag()
    if not self.tagged then return end
    if valid(self.camera) then self.input:RemoveInputModeTag(self.camera, self.camera) end
    self.tagged = nil
end

function Ending:play(realNow)
    assert(not self.started and self:cameraActive(), "血宫通关镜头尚未就绪")
    self.confirmKeys = {}
    for i, name in ipairs(CONFIRM_KEYS) do self.confirmKeys[i] = { KeyName = FName(name) } end
    local found, router = pcall(function()
        return required(SUBSYSTEMS):GetLocalPlayerSubsystem(self.controller, required(ROUTER))
    end)
    if found and valid(router) then self.confirmRouter = router end
    self.started = self.gameplay:GetTimeSeconds(self.pawn)
    self.lastFrameAt = realNow
    self.deadline = realNow + self.timelineEnd + 7
    if self.weaponShot then self:playResultMusic(realNow) else self:openingEffects(true) end
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
    local sequence = self.weaponShot and (self.weaponRoute .. (self.weaponShot.victimTrack
        and " receiver POV" or " fixed center orbit after disarm"))
        or "stock cam01 + orbit + sheath + salute"
    print("[PBZBloodyPalace] final sequence started; " .. sequence .. "\n")
end

function Ending:stopFrames()
    if self.frameAction then
        CancelDelayedAction(self.frameAction)
        self.frameAction = nil
    end
end

function Ending:releasePresentation(keepTitle)
    self:releaseInputTag()
    self:stopFrames()
    if not keepTitle then self:closeTitle() end
    if self.face then self.face:close(); self.face = nil end
end

function Ending:update(realNow, keepTitle)
    assert(not self.frameError, self.frameError)
    if self.waitingForConfirm then return false end
    if self.fade then
        assert(realNow < self.introDeadline, "血宫结算转场等待超时")
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
    if needsFrameFallback and not self.presentationDone then
        -- A long rendered frame does not invalidate the engine callback. Keep
        -- it registered so the next frame can take over from the service.
        self.serviceFallbacks = self.serviceFallbacks + 1
        self:advance(realNow, false)
    end
    if not self.frozenAt then
        assert(realNow < self.deadline, "血宫通关过场等待超时")
        return false
    end
    if not self.presentationDone then return false end
    if keepTitle and self.weaponShot and self.resultMusicStarted then
        local mixed, reason = pcall(self.music.softenResult, self.music, realNow)
        if not mixed then print("[PBZBloodyPalace] ending score mix fallback: " .. tostring(reason) .. "\n") end
    end
    self:releasePresentation(keepTitle)
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
    attempt(function() self:closeStill() end)
    attempt(function() self:releasePresentation() end)
    attempt(function() self:closeDaze() end)
    if self.ziMing then self.ziMing:close() end
    if self.resultMusicPrepared then
        attempt(function()
            self.music:stopResult()
            self.resultMusicPrepared, self.resultMusicStarted = nil, nil
        end)
    end
    attempt(function() self:stopSound(self.openingAudio) end)
    attempt(function() self:stopSound(self.titleImpact) end)
    attempt(function() self:stopSound(self.breathAudio) end)
    for _, swing in ipairs(self.weaponSwings or {}) do
        attempt(function() self:stopSound(swing) end)
    end
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
    -- Re-resolve from the engine at use time. The warm-up does not keep Lua
    -- wrappers to GC-managed objects across the last fight.
    local resolveStart = clock and clock()
    local centerGround = ground(0, 0)
    local hunYaw = yaw(self.direction + 180)
    self.hunGround = centerGround
    self.hun = self:spawn(cast("BP_Seq_Hun"), self:point(0, 0, centerGround + 99), hunYaw, true)
    self.hunMesh = self.hun.Mesh
    self.identity = self.math:MakeTransform({ X = 0, Y = 0, Z = 0 }, yaw(0), ONE)
    self:prepareHun()
    if not self.weaponShot then
        self.hunGround = ground(HUN_DISTANCE, 0)
        self:place(self.hun, self:point(HUN_DISTANCE, 0, self.hunGround + 99), hunYaw)
        -- Anchor the authored kneel by its visible boot, which is below its root.
        local boot = Opening.bootContact
        local contact = self:point(boot[1], boot[2], 0)
        local contactGround = Arena.mechanicGround(self.pawn, system, scene, contact.X, contact.Y) or centerGround
        self.snowGround = contactGround - boot[3]
        print(("[PBZBloodyPalace] ending kneel anchored at boot; correctionCm=%.2f\n"):format(-boot[3]))
        local snowAnim = animation("Seq127-1", "cam01", "FengXueDaoKe", Opening.duration)
        local snowPoint = self:point(0, 0, self.snowGround + 102)
        self.snow = self:spawn(cast("BP_Seq_FengXueDaoKe"), snowPoint, yaw(self.direction), true)
        self.sword = self:spawn(cast("BP_Seq_FengXueDaoKe_Weapon"), snowPoint, yaw(self.direction), false)
        self.snowMesh = self.snow.Mesh
        self.snowLength = snowAnim:GetPlayLength()
        local socket = FName("weapon_r")
        assert(self.snowMesh:DoesSocketExist(socket) and self.sword:K2_AttachToComponent(self.snowMesh, socket, 2, 2, 2, false),
            "血宫通关过场原版刀挂点不可用")
        pose(self.snowMesh, snowAnim, 0)
    end
    self.hun:SetActorHiddenInGame(not self.weaponShot)
    local resolveMs = resolveStart and ("%.1f"):format((clock() - resolveStart) * 1000) or "unavailable"
    print("[PBZBloodyPalace] ending resources verified at settlement; resolveMs=" .. resolveMs .. "\n")
    local dialogue, voiceReason = pcall(self.prepareDialogue, self)
    if not dialogue then print("[PBZBloodyPalace] ending voice prepare fallback: " .. tostring(voiceReason) .. "\n") end
    if not self.weaponShot and self.dialogue[1] then
        local mouth, result = pcall(Face.new, self.hun.meshhead, function()
            return self.gameplay:GetRealTimeSeconds(self.pawn)
        end)
        if mouth then self.face = result
        else print("[PBZBloodyPalace] ending face setup fallback: " .. tostring(result) .. "\n") end
    end
    local detail, reason = pcall(self.prepareDetail, self)
    if not detail then print("[PBZBloodyPalace] ending detail fallback: " .. tostring(reason) .. "\n") end
    self:prepareLights()

    self.lens = self.camera:GetCineCameraComponent()
    assert(valid(self.lens), "血宫通关过场缺少电影镜头")
    self.lens:SetFilmback(Opening.filmback)
    self.lens.bConstrainAspectRatio = false
    -- Use one aspect policy for the whole move so lens framing cannot jump on arrival.
    pcall(function()
        self.lens:SetAspectRatioAxisConstraint(0) -- MaintainYFOV
        self.lens.bOverrideAspectRatioAxisConstraint = true
    end)
    if self.snow then self:prepareOrbit() end
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

function Ending:animateTitle(realNow)
    local landed, finished = self.titleModule.advance(self.titleScreen, realNow - self.frozenAt)
    if landed and not self.titleLanded then
        self.titleLanded = true
        if self.titleImpact and not self.skipped then
            local ok, reason = pcall(self.postSound, self, self.titleImpact, true)
            if ok then
                print(("[PBZBloodyPalace] ending title impact posted on camera emitter; PlayingID=%d\n"):format(self.titleImpact.id))
            else
                print("[PBZBloodyPalace] ending title impact fallback: " .. tostring(reason) .. "\n")
            end
        end
    end
    if finished then self.titleAnimating = false end
end

function Ending:presentFreeze(realNow)
    local held = realNow - self.frozenAt
    if held >= FINAL_VOICE_DELAY or self.summaryConfirmed then self:say(2) end
    if self.titleAnimating then self:animateTitle(self.summaryConfirmed and self.frozenAt + TITLE_SETTLED_TIME or realNow) end
    if self.summaryConfirmed then
        self.presentationDone = true
        self:stopFrames()
    end
end

function Ending:closeTitle()
    if self.titleScreen and self.titleModule.close(self.titleScreen) then self.titleScreen = nil end
end

function Ending:prepareBackdrop()
    local ok, result = pcall(function()
        local backdrop = require("BloodyPalaceEndingBackdrop")
        return backdrop.new(self.pawn, self.camera, self.identity)
    end)
    if not ok then
        print("[PBZBloodyPalace] ending backdrop setup fallback: " .. tostring(result) .. "\n")
        return
    end
    self.backdrop = result
    if self.weaponShot and self.weaponShot.victimTrack then
        local ready, still = pcall(function()
            return require("BloodyPalaceEndingStill").new(self.pawn, self.camera, self.hun, self.backdrop,
                self.identity, self.ziMing and self.ziMing.gunMeshes)
        end)
        if ready then self.still = still
        else print("[PBZBloodyPalace] ending isolated frame setup fallback: " .. tostring(still) .. "\n") end
    end
end

function Ending:showBackdrop()
    if not self.backdrop then return false end
    local depth = self.weaponShot and self.focus + self.weaponShot.backdropClearance or nil
    local ok, reason = pcall(self.backdrop.show, self.backdrop, self.pawn, self.camera, self.math,
        Opening.filmback, self.focalLength or SALUTE_FOCAL, depth)
    if not ok then
        print("[PBZBloodyPalace] ending backdrop display fallback: " .. tostring(reason) .. "\n")
    elseif depth then
        print(("[PBZBloodyPalace] ending backdrop placed; depthCm=%.1f; focusCm=%.1f\n"):format(reason, self.focus))
    end
    return ok
end

function Ending:closeStill()
    if self.still then self.still:close(); self.still = nil end
end

function Ending:finishBackdrop(realNow)
    if not self.still then return self:showBackdrop() end
    local ok, ready = pcall(function()
        if not self.stillRequestedAt then
            assert(self:showBackdrop(), "血宫定格红墨未就绪")
            self.still:request(self.pawn, self.lens)
            self.stillRequestedAt = realNow
        elseif realNow > self.stillRequestedAt then
            self.still:show(self.lens, self.math)
            if self.ziMing then self.ziMing:close() end
            return true
        end
    end)
    if ok then return ready end
    print("[PBZBloodyPalace] ending isolated frame fallback: " .. tostring(ready) .. "\n")
    self:closeStill()
    return self:showBackdrop()
end

function Ending:activate()
    local gameplay, pawn, controller = self.gameplay, self.pawn, self.controller
    assert(same(controller:K2_GetPawn(), pawn) and same(controller:GetViewTarget(), self.previousView),
        "结算转场期间游戏视角已切换")
    local setupStart = clock and clock()
    self:stage(self.system, self.scene)
    self:prepareTitle()
    if self.weaponShot == WEAPON_SHOTS.ZiMingJian then
        local ok, effect = pcall(ZiMing.new, self, load)
        if ok then self.ziMing = effect
        else print("[PBZBloodyPalace] ending ZiMing effects setup fallback: " .. tostring(effect) .. "\n") end
    end
    self:prepareBackdrop()
    if self.weaponShot and self.weaponShot.daze then
        local ok, effect = pcall(function()
            return require("BloodyPalaceEndingDaze").new(gameplay, pawn, self.camera, self.lens, load,
                self.weaponShot.daze.duration)
        end)
        if ok then self.daze = effect
        else print("[PBZBloodyPalace] ending daze setup fallback: " .. tostring(effect) .. "\n") end
    end
    if self.music then
        self.resultMusicPrepared = true
        self.music:prepareResult(self.weaponShot ~= nil, self.camera, self.identity)
    end

    self:hideHUD()
    self.pawnHidden = pawn.bHidden == true
    local hidden, hideReason = pcall(Props.hideOriginal, pawn, self.hiddenWeapons)
    if not hidden then print("[PBZBloodyPalace] ending original weapon visibility fallback: " .. tostring(hideReason) .. "\n") end
    pawn:SetActorHiddenInGame(true)
    controller:SetViewTargetWithBlend(self.camera, 0, 0, 0, false)
    assert(self:cameraActive(), "血宫通关镜头未切换")
    self.staged = true
    local setupMs = setupStart and ("%.1f"):format((clock() - setupStart) * 1000) or "unavailable"
    print("[PBZBloodyPalace] ending camera ready behind the transition; setupMs=" .. setupMs .. "\n")
end

function Ending:hideHUD()
    if self.hudHidden then return end
    local world = Scene.runtimeWorld(self.pawn)
    for _, hud in ipairs(FindAllOf("W_FrontEndHUDLayout_C") or {}) do
        if valid(hud) and same(hud:GetOwningPlayer(), self.controller) and same(hud:GetWorld(), world) then
            self.hud[#self.hud + 1] = { widget = hud, visibility = hud:GetVisibility() }
            hud:SetVisibility(1)
        end
    end
    self.hudHidden = true
end

function Ending.new(gameplay, system, pawn, scene, music, tierId)
    local controller = gameplay:GetPlayerController(pawn, 0)
    assert(same(valid(controller) and controller:K2_GetPawn(), pawn), "血宫通关过场玩家已切换")
    local self = setmetatable({ gameplay = gameplay, system = system, pawn = pawn, controller = controller,
        scene = scene, music = music, saluteEnding = tierId == "entry",
        math = required("/Script/Engine.Default__KismetMathLibrary"), input = required(LIBRARY),
        actors = {}, hud = {}, hiddenWeapons = {}, clothes = {}, dialogue = {},
        frameSamples = 0, serviceFallbacks = 0, maxFrameGap = 0 }, Ending)
    local ok, failure = pcall(function()
        self.previousView = controller:GetViewTarget()
        if not self.saluteEnding then
            local captured, slot = pcall(Props.activeSlot, pawn)
            if captured then self.weaponSlot = slot end
        end
        self.camera = self:spawn(required(CAMERA), pawn:K2_GetActorLocation(), yaw(0), false)
        self:lockInput()
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
    print(("[PBZBloodyPalace] ending transition started; tier=%s; route=%s\n")
        :format(tierId or "default", self.saluteEnding and "salute" or "weapon"))
    return self
end

return Ending
