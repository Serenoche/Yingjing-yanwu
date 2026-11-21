local Daze = {}
Daze.__index = Daze

-- GA_MoTian_GEd_05 uses this post-process system and camera shake on the receiver.
local EFFECT = "/PBZVFXPack/VFX/BattleFX/YanQianSui/NS_YanQianSui_QTE_001_Post.NS_YanQianSui_QTE_001_Post"
local SHAKE = "/PBZCombatAsset/ActorData/Mobs/067_MoTian/Camera/CameraShake_MoYuan_GEx_05.CameraShake_MoYuan_GEx_05_C"
local COLLECTION_DIR = "/PBZVFXPack/VFX/A_Materials/MatMisc/"
local ROTATION = { Pitch = 0, Yaw = 0, Roll = 0 }
local OFFSET = { X = 0, Y = 0, Z = 0 }
local NATIVE_DURATION = 2.6678

-- BP_M_YanQianSui_PostCtrl_001 modifies these two collections while active
-- and writes defaults during EndPlay. Restore the values from before the shot.
local COLLECTIONS = {
    { "MPC_Dizziness_001", { "DizzinessEffectScale" } },
    { "MPC_PP_RadialBlur", { "StartPos", "MaxPos", "CenterX", "CenterY", "Intensity", "ColorSeperation",
        "VignettePower", "VignetteStrength", "UseWP" }, { "MainTex_TilingSpeed", "ColorSeperationTint", "CenterWP" } },
}

local function valid(x) return x and type(x.IsValid) == "function" and x:IsValid() end

function Daze.new(gameplay, pawn, camera, lens, load, duration)
    local niagara = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
    local materials = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
    assert(valid(niagara) and valid(materials), "眩晕特效接口不可用")
    local effect = load(EFFECT, "/Script/Niagara.NiagaraSystem")
    local collections = {}
    for i, row in ipairs(COLLECTIONS) do
        local name = row[1]
        collections[i] = load(COLLECTION_DIR .. name .. "." .. name, "/Script/Engine.MaterialParameterCollection")
    end
    local manager = gameplay:GetPlayerCameraManager(pawn, 0)
    local loaded, shake = pcall(load, SHAKE, "/Script/Engine.BlueprintGeneratedClass")
    if not loaded then print("[PBZBloodyPalace] ending daze shake unavailable: " .. tostring(shake) .. "\n") end
    local component = niagara:SpawnSystemAttached(effect, lens, FName("None"), OFFSET, ROTATION, 0, false, false, 0, false)
    assert(valid(component), "原版眩晕特效组件未就绪")
    local ok, reason = pcall(function()
        component:SetForceSolo(true)
        component:SetAllowScalability(false)
        component:SetCustomTimeDilation(NATIVE_DURATION / duration)
    end)
    if not ok then
        component:K2_DestroyComponent(component)
        error(reason, 0)
    end
    return setmetatable({ camera = camera, pawn = pawn, component = component, materials = materials,
        collections = collections, manager = manager, shakeClass = loaded and shake or nil }, Daze)
end

function Daze:start()
    local previous = {}
    for i, row in ipairs(COLLECTIONS) do
        local collection = self.collections[i]
        for _, parameter in ipairs(row[2]) do
            local name = FName(parameter)
            local value = self.materials:GetScalarParameterValue(self.camera, collection, name)
            assert(type(value) == "number", "眩晕前的画面参数读取失败 " .. parameter)
            previous[#previous + 1] = { collection, name, value }
        end
        for _, parameter in ipairs(row[3] or {}) do
            local name = FName(parameter)
            local color = self.materials:GetVectorParameterValue(self.camera, collection, name)
            previous[#previous + 1] = { collection, name, { R = color.R, G = color.G, B = color.B, A = color.A } }
        end
    end
    self.previous = previous
    self.component:Activate(true)
    self.started = true
    if valid(self.manager) and valid(self.shakeClass) then
        local ok, shake = pcall(self.manager.StartCameraShake, self.manager, self.shakeClass, 1, 0, ROTATION)
        if ok and valid(shake) then self.shake = shake end
    end
end

function Daze:close()
    local failure
    local function attempt(callback)
        local ok, reason = pcall(callback)
        if not ok then failure = failure or reason end
    end
    attempt(function()
        if valid(self.shake) and valid(self.manager) then self.manager:StopCameraShake(self.shake, true) end
        self.shake = nil
    end)
    attempt(function()
        if valid(self.component) then self.component:K2_DestroyComponent(self.component) end
        self.component = nil
    end)
    local context = valid(self.camera) and self.camera or self.pawn
    if self.previous and valid(context) then
        for _, row in ipairs(self.previous) do
            attempt(function()
                if type(row[3]) == "number" then self.materials:SetScalarParameterValue(context, row[1], row[2], row[3])
                else self.materials:SetVectorParameterValue(context, row[1], row[2], row[3]) end
            end)
        end
    end
    if failure then error(failure, 0) end
    self.previous = nil
end

return Daze
