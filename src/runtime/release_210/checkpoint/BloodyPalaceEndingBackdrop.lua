local Backdrop = {}
Backdrop.__index = Backdrop

local FILE = "BloodyPalaceEndingRedInk.png"
local PLANE = "/Engine/BasicShapes/Plane.Plane"
local MATERIAL = "/Engine/EngineMaterials/Widget3DPassThrough_Opaque.Widget3DPassThrough_Opaque"
local PLANE_SIZE, DISTANCE = 100, 425 -- cm
local PENDING = 0x08023600

local function valid(object)
    return object and type(object.IsValid) == "function" and object:IsValid()
end

local function checked(object, label)
    assert(valid(object), "血宫定格背景资源不可用 " .. label)
    return object
end

local function load(path, class)
    local asset = StaticFindObject(path)
    if not valid(asset) or asset:HasAnyFlags(PENDING) then
        local loaded = LoadAsset(path)
        asset = valid(loaded) and loaded or StaticFindObject(path)
    end
    assert(valid(asset) and not asset:HasAnyFlags(PENDING)
        and asset:IsA(checked(StaticFindObject(class), class)), "血宫定格背景资源不可用 " .. path)
    return asset
end

function Backdrop.new(pawn, camera, identity)
    local directory = assert(debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]+$"), "找不到血宫定格背景目录")
    local renderer = checked(StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary"), "Texture2D")
    local materials = checked(StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary"), "MaterialInstanceDynamic")
    local viewport = checked(StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary"), "WidgetLayoutLibrary")
    local plane = load(PLANE, "/Script/Engine.StaticMesh")
    local parent = load(MATERIAL, "/Script/Engine.MaterialInterface")
    local texture = checked(renderer:ImportFileAsTexture2D(pawn, directory .. "/" .. FILE), FILE)
    local width, height = texture:Blueprint_GetSizeX(), texture:Blueprint_GetSizeY()
    assert(width > 0 and height > 0, "血宫定格背景贴图为空")

    local component
    local ok, reason = pcall(function()
        local class = checked(StaticFindObject("/Script/Engine.StaticMeshComponent"), "StaticMeshComponent")
        component = checked(camera:AddComponentByClass(class, true, identity, false), "背景平面")
        component:SetVisibility(false, false)
        component:SetCollisionEnabled(0)
        component:SetCastShadow(false)
        component:SetAffectDynamicIndirectLighting(false)
        component:SetVisibleInRayTracing(false)
        assert(component:SetStaticMesh(plane), "血宫定格背景平面无法设置")
        local material = checked(materials:CreateDynamicMaterialInstance(camera, parent, FName("None"), 0), "背景材质实例")
        material:SetTextureParameterValue(FName("SlateUI"), texture)
        component:SetMaterial(0, material)
    end)
    if not ok then
        if valid(component) then pcall(function() component:K2_DestroyComponent(camera) end) end
        error(reason, 0)
    end
    return setmetatable({ component = component, ratio = width / height, viewport = viewport,
        plane = plane, parentMaterial = parent, materialLibrary = materials }, Backdrop)
end

function Backdrop:show(pawn, camera, mathLibrary, filmback, focalLength, minimumDepth)
    local eye, rotation = camera:K2_GetActorLocation(), camera:K2_GetActorRotation()
    local forward = mathLibrary:GetForwardVector(rotation)
    local right, up = mathLibrary:GetRightVector(rotation), mathLibrary:GetUpVector(rotation)
    local distance = math.max(DISTANCE, minimumDepth or DISTANCE)
    local center = { X = eye.X + forward.X * distance, Y = eye.Y + forward.Y * distance,
        Z = eye.Z + forward.Z * distance }
    -- The cooked plane's U and V grow with local X and Y. Face it toward the lens with V down.
    local facing = mathLibrary:MakeRotFromXY(right, { X = -up.X, Y = -up.Y, Z = -up.Z })

    local size = self.viewport:GetViewportSize(pawn)
    local filmAspect = filmback.SensorWidth / filmback.SensorHeight
    local aspect = (size.X > 0 and size.Y > 0) and size.X / size.Y or filmAspect
    local nominalWidth = distance * filmback.SensorWidth / focalLength
    -- Cover both horizontal- and vertical-FOV projection, including widescreen viewports.
    local viewWidth = nominalWidth * math.max(1, aspect / filmAspect)
    local viewHeight = nominalWidth * math.max(1 / aspect, 1 / filmAspect)
    local width = math.max(viewWidth, viewHeight * self.ratio) * 1.035
    local scale = { X = width / PLANE_SIZE, Y = width / (self.ratio * PLANE_SIZE), Z = 1 }
    local transform = mathLibrary:MakeTransform(center, facing, scale)
    self.component:K2_SetWorldTransform(transform, false, {}, true)
    self.component:SetVisibility(true, false)
    return distance
end

return Backdrop
