local Fog = {}
local SMOKE = "/Game/PBZContent/VFX/SceneFX/SmokeAndFIre/"
local EFFECTS = { { name = "NS_SmokeWall_202", z = 0 }, { name = "NS_SmokeWall_201", z = 284 } }
local WHITE = { R = 1, G = 1, B = 1, A = 1 }

local function ready(object)
    return object and object:IsValid() and not object:HasAnyFlags(0x08023600)
end

function Fog.load(singleLayer)
    local assets = {}
    for index = 1, singleLayer and 1 or #EFFECTS do
        local effect = EFFECTS[index]
        local path = SMOKE .. effect.name .. "." .. effect.name
        local asset = StaticFindObject(path)
        if not ready(asset) then
            local ok, loaded, _, complete = pcall(LoadAsset, path)
            if ok and complete == true and ready(loaded) then asset = loaded else asset = StaticFindObject(path) end
        end
        if not ready(asset) then return nil, "等待幻术雾特效 " .. effect.name end
        assets[index] = asset
    end
    return assets
end

function Fog.spawn(pawn, points, assets, components, emitter, fillCenter)
    local niagara = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
    assert(ready(niagara), "幻术雾特效接口未就绪")
    -- Use the visual systems of BP_PhantomBarrier_Blocker without starting its quest or lute interaction.
    for index = 1, #points - 1 do
        local first, last = points[index], points[index + 1]
        local dx, dy = last.X - first.X, last.Y - first.Y
        -- Keep local X along the Hitbox. Roll the local XY spread up into the wall plane.
        local rotation = { Pitch = 0, Yaw = math.deg(math.atan(dy, dx)), Roll = emitter and -90 or 0 }
        local endPadding = emitter and 0 or 65
        local halfLength = math.sqrt(dx*dx + dy*dy) * 0.5 + endPadding
        local scale = { X = halfLength / 800, Y = 1, Z = 1 }
        for layer, asset in ipairs(assets) do
            local effect = EFFECTS[layer]
            local at = emitter or { X = (first.X + last.X) * 0.5, Y = (first.Y + last.Y) * 0.5,
                Z = (first.Z + last.Z) * 0.5 + effect.z }
            local effectRotation, effectScale = rotation, scale
            if fillCenter and layer == 2 then
                -- The original wall layer is already upright and has 1000 cm half-width.
                at = { X = emitter.X, Y = emitter.Y, Z = emitter.Z + effect.z }
                effectRotation = { Pitch = 0, Yaw = rotation.Yaw, Roll = 0 }
                effectScale = { X = halfLength / 1000, Y = 1, Z = 1 }
            end
            local component = niagara:SpawnSystemAtLocation(pawn, asset, at, effectRotation, effectScale, false, false, 0, false)
            assert(ready(component), "幻术雾特效组件未创建 " .. effect.name)
            components[#components + 1] = component
            component:SetAllowScalability(false)
            component:SetVariableLinearColor(FName("User.UE_Color01"), WHITE)
            if layer == 2 then
                component:SetVariableLinearColor(FName("User.UE_Color02"), WHITE)
                component:SetVariableBool(FName("User.UE_OpaqueBackground"), fillCenter == true)
                component:SetVariableBool(FName("User.UE_StartPlayingMusic"), false)
            end
            component:Activate(true)
        end
    end
end

return Fog
