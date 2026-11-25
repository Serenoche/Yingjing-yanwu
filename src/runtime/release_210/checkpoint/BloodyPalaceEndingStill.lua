local Still = {}
Still.__index = Still

local CAPTURE_CLASS = "/Script/Engine.SceneCaptureComponent2D"
local RENDERER = "/Script/Engine.Default__KismetRenderingLibrary"
local VIEWPORT = "/Script/UMG.Default__WidgetLayoutLibrary"
local CLEAR = { R = 0, G = 0, B = 0, A = 1 }
local SHOW_ONLY, SCENE_COLOR_NO_ALPHA, RGBA16F = 2, 1, 6
local SCREEN_DEPTH, PLANE_SIZE = 32, 100 -- cm
local FLAGS = {
    { ShowFlagName = "Fog", Enabled = false },
    { ShowFlagName = "VolumetricFog", Enabled = false },
    { ShowFlagName = "Atmosphere", Enabled = false },
    { ShowFlagName = "VolumetricCloud", Enabled = false },
    { ShowFlagName = "MotionBlur", Enabled = false },
}

local function valid(object) return object and type(object.IsValid) == "function" and object:IsValid() end

local function checked(object, message)
    assert(valid(object), message)
    return object
end

local function required(path)
    return checked(StaticFindObject(path), "血宫定格截图缺少接口 " .. path)
end

function Still:fitTarget(pawn)
    local size = self.viewport:GetViewportSize(pawn)
    local width, height = math.floor(size.X), math.floor(size.Y)
    assert(width > 0 and height > 0, "血宫定格画幅不可用")
    if self.width == width and self.height == height then return end
    local target = checked(self.renderer:CreateRenderTarget2D(pawn, width, height, RGBA16F, CLEAR, false, false),
        "血宫定格画布无法创建")
    self.capture.TextureTarget = target
    self.material:SetTextureParameterValue(FName("SlateUI"), target)
    self.width, self.height = width, height
end

function Still.new(pawn, camera, hun, backdrop, identity, props)
    local self = setmetatable({ camera = camera, board = backdrop.component,
        viewport = required(VIEWPORT), renderer = required(RENDERER) }, Still)
    local ok, reason = pcall(function()
        local capture = checked(camera:AddComponentByClass(required(CAPTURE_CLASS), true, identity, true),
            "血宫定格镜头无法创建")
        self.capture = capture
        capture.bCaptureEveryFrame = false
        capture.bCaptureOnMovement = false
        capture.PrimitiveRenderMode = SHOW_ONLY
        -- Keep scene color linear. The main camera applies the tone mapper to the display once.
        capture.CaptureSource = SCENE_COLOR_NO_ALPHA
        capture.PostProcessBlendWeight = 0
        capture.DetailMode = 0
        capture:ShowOnlyActorComponents(hun, true)
        capture:ShowOnlyComponent(self.board)
        for _, prop in ipairs(props or {}) do capture:ShowOnlyComponent(prop) end
        local flags, flagError = pcall(capture.SetShowFlagSettings, capture, FLAGS)
        if not flags then print("[PBZBloodyPalace] ending capture show flags fallback: " .. tostring(flagError) .. "\n") end
        camera:FinishAddComponent(capture, true, identity)

        local display = checked(camera:AddComponentByClass(required("/Script/Engine.StaticMeshComponent"), true, identity, false),
            "血宫定格显示平面无法创建")
        self.display = display
        display:SetVisibility(false, false)
        display:SetHiddenInSceneCapture(true)
        display:SetCollisionEnabled(0)
        display:SetCastShadow(false)
        display:SetAffectDynamicIndirectLighting(false)
        display:SetVisibleInRayTracing(false)
        assert(display:SetStaticMesh(backdrop.plane), "血宫定格显示平面无法设置")
        self.material = checked(backdrop.materialLibrary:CreateDynamicMaterialInstance(camera, backdrop.parentMaterial,
            FName("None"), 0), "血宫定格显示材质无法创建")
        display:SetMaterial(0, self.material)
        self:fitTarget(pawn)
        self.board:SetVisibleInSceneCaptureOnly(true)
    end)
    if not ok then pcall(self.close, self); error(reason, 0) end
    return self
end

function Still:request(pawn, lens)
    self:fitTarget(pawn)
    local verticalFov = math.rad(lens:GetVerticalFieldOfView())
    self.capture.FOVAngle = math.deg(2 * math.atan(math.tan(verticalFov / 2) * self.width / self.height))
    self.capture:K2_SetWorldLocationAndRotation(self.camera:K2_GetActorLocation(), self.camera:K2_GetActorRotation(),
        false, {}, true)
    self.capture:CaptureScene()
    print(("[PBZBloodyPalace] ending isolated frame captured; %dx%d\n"):format(self.width, self.height))
end

function Still:show(lens, mathLibrary)
    local eye, rotation = self.camera:K2_GetActorLocation(), self.camera:K2_GetActorRotation()
    local forward = mathLibrary:GetForwardVector(rotation)
    local right, up = mathLibrary:GetRightVector(rotation), mathLibrary:GetUpVector(rotation)
    local facing = mathLibrary:MakeRotFromXY(right, { X = -up.X, Y = -up.Y, Z = -up.Z })
    local center = { X = eye.X + forward.X * SCREEN_DEPTH, Y = eye.Y + forward.Y * SCREEN_DEPTH,
        Z = eye.Z + forward.Z * SCREEN_DEPTH }
    local height = 2 * SCREEN_DEPTH * math.tan(math.rad(lens:GetVerticalFieldOfView()) / 2) * 1.015
    local scale = { X = height * self.width / self.height / PLANE_SIZE, Y = height / PLANE_SIZE, Z = 1 }
    self.display:K2_SetWorldTransform(mathLibrary:MakeTransform(center, facing, scale), false, {}, true)
    lens:SetCustomNearClippingPlane(5)
    lens.bOverride_CustomNearClippingPlane = true
    lens:SetFocusSettings({ FocusMethod = 3 }) -- The complete frame is already on the screen.
    self.display:SetVisibility(true, false)
end

function Still:close()
    if valid(self.display) then self.display:K2_DestroyComponent(self.camera) end
    if valid(self.capture) then self.capture:K2_DestroyComponent(self.camera) end
    if valid(self.board) then self.board:SetVisibleInSceneCaptureOnly(false) end
    self.display, self.capture = nil, nil
end

return Still
