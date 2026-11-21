local ZiMing = {}
ZiMing.__index = ZiMing

local NIAGARA = "/Script/Niagara.Default__NiagaraFunctionLibrary"
local SYSTEM = "/Script/Niagara.NiagaraSystem"
local STATIC_MESH = "/Script/Engine.StaticMesh"
local STATIC_COMPONENT = "/Script/Engine.StaticMeshComponent"
local VFX = "/PBZVFXPack/VFX/BattleFX/"
local SOUND = "/Game/Wwise/Events/SFX/Combat/Special/"
local FLAT = { Pitch = 0, Yaw = 0, Roll = 0 }
local SUMMON, MOUNT = .228, 1.842
local FIRST_ROUND, ROUND_INTERVAL = 2.656, 2.23571 / 25
local CANNON_MATERIAL = VFX .. "Weapon/ZiMing/Assets/MI_FX_C2_ZuoShang_Weapon_401.MI_FX_C2_ZuoShang_Weapon_401"
local CANNON_MESHES = { "SM_FX_ZuoShang_LeiHuang_404", "SM_FX_ZuoShang_LeiHuang_403" }
-- Centers of the three muzzle rims in the cooked 403 mesh, in its local XY plane.
local MUZZLES = { { -5.16, 2.96 }, { 5.20, 2.96 }, { .27, -5.94 } }
local MUZZLE_HEIGHT = 123

-- Time the two alternating flashes and the native gunshot from the same F01 cue.
local view = require("BloodyPalaceEndingExecutionView").ZiMingJian
ZiMing.lastPose = (#view.frames - 1) / view.rate
local ROUND_COUNT = math.floor((ZiMing.lastPose - FIRST_ROUND) / ROUND_INTERVAL) + 1
ZiMing.swings = {
    { peak = .306, lead = 0, name = "SFX_Combat_Hun_ZiMingJian_Sword_Fly_VFX",
        folder = SOUND .. "Hero_Special/Hun/Common/Wave_Stab_BaDao/ZiMingJian/ZiMingJian/" },
    { peak = .405, lead = 0, name = "SFX_Combat_Special_Execute_HuoLiuXing_Gex_03",
        folder = SOUND .. "Hero_Special/Hun/Execute/Boss/" },
    { peak = .424, lead = 0, name = "SFX_Combat_VO_Hun_ChuZhao_02",
        folder = "/Game/Wwise/Events/VO/Int/Hun/Battle/" },
    { peak = MOUNT, lead = 0, name = "SFX_Combat_Special_GuiChai_Black_Gun_Reload_Pre",
        folder = SOUND .. "Monster_Special/GuiChai/" },
}
for i = 0, ROUND_COUNT - 1 do
    ZiMing.swings[#ZiMing.swings + 1] = { peak = FIRST_ROUND + i * ROUND_INTERVAL, lead = 0,
        name = "SFX_Combat_Special_ZuoShang_Gun_Shoot", folder = SOUND .. "Monster_Special/ZuoShang/" }
end

local function valid(object) return object and type(object.IsValid) == "function" and object:IsValid() end

local function asset(load, folder, name)
    return load(VFX .. folder .. name .. "." .. name, SYSTEM)
end

local function scale(value)
    return { X = value, Y = value, Z = value }
end

local function offset(at, direction, distance)
    return { X = at.X + direction.X * distance, Y = at.Y + direction.Y * distance, Z = at.Z + direction.Z * distance }
end

function ZiMing.new(ending, load)
    local self = setmetatable({ ending = ending, components = {}, guns = {}, gunMeshes = {}, flashes = {}, round = 0 }, ZiMing)
    local function keep(component)
        assert(valid(component), "紫冥剑演出特效无法创建")
        self.components[#self.components + 1] = component
        return component
    end
    local ok, reason = pcall(function()
        local library = StaticFindObject(NIAGARA)
        assert(valid(library), "紫冥剑演出缺少特效接口")
        local summon = asset(load, "ZuoShang/", "NS_ZuoShang_WeaponEmitter_001C")
        local flash = asset(load, "GuiChai/", "NS_GuiChaiBlack_Rifle_004_MuzzleStrong")
        local meshClass = StaticFindObject(STATIC_COMPONENT)
        assert(valid(meshClass), "紫冥剑演出缺少炮身组件")
        local material = load(CANNON_MATERIAL, "/Script/Engine.MaterialInterface")
        local meshes = {}
        for i, name in ipairs(CANNON_MESHES) do
            meshes[i] = load(VFX .. "ZuoShang/Assets/" .. name .. "." .. name, STATIC_MESH)
        end
        local rotation = ending.math:Quat_Rotator({ X = -.5, Y = -.5, Z = -.5, W = .5 })
        self.summon = keep(library:SpawnSystemAttached(summon, ending.hunMesh, FName("root"),
            { X = 0, Y = 0, Z = 20 }, rotation, 0, false, false, 0, false))
        self.summon:SetAllowScalability(false)
        self.summon:SetRelativeScale3D(scale(1.4))
        for i = 1, 2 do
            local gun = {}
            for _, mesh in ipairs(meshes) do
                local part = keep(ending.camera:AddComponentByClass(meshClass, true, ending.identity, false))
                part:SetVisibility(false, false)
                part:SetCollisionEnabled(0)
                part:SetCastShadow(false)
                part:SetAffectDynamicIndirectLighting(false)
                part:SetVisibleInRayTracing(false)
                part:SetLightingChannels(true, false, true)
                assert(part:SetStaticMesh(mesh), "紫冥剑演出炮身未就绪")
                part:SetMaterial(0, material)
                part:PrestreamTextures(14, false, 0)
                gun[#gun + 1] = part
                self.gunMeshes[#self.gunMeshes + 1] = part
            end
            self.guns[i] = gun
            self.flashes[i] = keep(library:SpawnSystemAtLocation(ending.pawn, flash, ending.hun:K2_GetActorLocation(),
                FLAT, scale(.8), false, false, 0, false))
            self.flashes[i]:SetAllowScalability(false)
        end
    end)
    if not ok then self:close(); error(reason, 0) end
    return self
end

function ZiMing:update(source, eye, frame, skipped)
    if skipped then
        self.summon:SetVisibility(false, false)
    elseif source >= SUMMON and not self.summoned then
        self.summon:Activate(true)
        self.summoned = true
    end
    if source < MOUNT then return end

    local round = math.min(ROUND_COUNT, math.floor((source - FIRST_ROUND + 1e-6) / ROUND_INTERVAL) + 1)
    local firing = not skipped and round > self.round and source - (FIRST_ROUND + (round - 1) * ROUND_INTERVAL) < .16
    local ending, mathLibrary = self.ending, self.ending.math
    for i, gun in ipairs(self.guns) do
        local column = i == 1 and 10 or 13
        local mount = ending:weaponPoint(frame[column], frame[column + 1], frame[column + 2])
        mount.Z = math.max(ending.hunGround + 22, mount.Z - 60)
        local facing = mathLibrary:FindLookAtRotation(mount, eye)
        local forward = mathLibrary:GetForwardVector(facing)
        local right = mathLibrary:GetRightVector(facing)
        local body = mathLibrary:MakeRotFromZX(forward, right)
        for _, part in ipairs(gun) do
            part:K2_SetWorldLocationAndRotation(mount, body, false, {}, true)
            if not self.mounted then part:SetVisibility(true, false) end
        end
        if skipped then
            self.flashes[i]:SetVisibility(false, false)
        elseif firing and i == (round - 1) % 2 + 1 then
            local aperture = MUZZLES[math.floor((round - 1) / 2) % #MUZZLES + 1]
            local muzzle = offset(offset(mount, forward, MUZZLE_HEIGHT), right, aperture[1])
            muzzle = offset(muzzle, mathLibrary:GetUpVector(facing), aperture[2])
            self.flashes[i]:K2_SetWorldLocationAndRotation(muzzle, mathLibrary:FindLookAtRotation(muzzle, eye),
                false, {}, true)
            self.flashes[i]:Activate(true)
        end
    end
    if not self.mounted then
        self.mounted = true
        print("[PBZBloodyPalace] ending ZiMing cannons staged\n")
    end
    self.round = math.max(self.round, round)
end

function ZiMing:close()
    if self.closed then return end
    self.closed = true
    for _, component in ipairs(self.components) do
        if valid(component) then pcall(component.K2_DestroyComponent, component, component) end
    end
end

return ZiMing
