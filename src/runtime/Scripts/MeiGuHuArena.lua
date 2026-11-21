local SceneArena = require("SceneArena")
local Layout = require("MeiGuHuStandaloneLayout")
local Arena = {}
local MAP = "PBZ_MeiGuHuArena"
local TITLE = "PBZ_StartMenu_CE_WP"
local BELL_CLASS = "/Game/PBZContent/Blueprint/Item/BP_MelodiousBell.BP_MelodiousBell_C"
local FOG_CLASS = "/Game/PBZContent/Blueprint/Item/BP_FogDoor.BP_FogDoor_C"
local MATH = "/Script/Engine.Default__KismetMathLibrary"
local NATIVE = "/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary"
local SUBSYSTEM = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local NAVIGATION = "/Script/NavigationSystem.Default__NavigationSystemV1"
local CLEAR = { R = 0, G = 0, B = 0, A = 0 }
local SCALE = { X = 1, Y = 1, Z = 1 }
local IDENTITY_ROTATION = { Pitch = 0, Yaw = 0, Roll = 0 }
local PENDING = 0x08023600
local WORLD_STATIC = { 0 }
local FOG_SAMPLE_STEP = 200
local FOG_BOX_HALF_WIDTH = 22
local FOG_BOX_HEIGHT = 650
local LOCAL_FOG_START = "r.LocalFogVolume.GlobalStartDistance"
local LOCAL_FOG_NEAR_CLIP = 10
local session
local expected, detailCount = {}, 0
for _, cell in ipairs(Layout.cells) do
    expected[cell.package] = cell.kind
    if cell.kind ~= "background" then detailCount = detailCount + 1 end
end

local function log(message) print("[PBZMeiGuHuArena] " .. message .. "\n") end
local function event(message) print("[PBZMeiGuHuStandalone] " .. message .. "\n") end
local function valid(object) return object and type(object.IsValid) == "function" and object:IsValid() end
local function same(a, b) return valid(a) and valid(b) and a:GetAddress() == b:GetAddress() end
local function name(value) return type(value) == "string" and value or (value and value:ToString() or "") end
local function distanceSquared(a, b) return (a.X - b.X)^2 + (a.Y - b.Y)^2 + (a.Z - b.Z)^2 end
local function unwrap(value)
    if valid(value) then return value end
    local ok, object = pcall(function() return value:get() end)
    return ok and object or nil
end

local function inWorld(actor, world)
    return valid(actor) and not actor:HasAnyFlags(PENDING) and same(SceneArena.runtimeWorld(actor), world)
end

local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object) and not object:HasAnyFlags(PENDING), "缺少关卡接口 " .. path)
    return object
end

local function mapOptions(position, rotation)
    return ("game=%s?Location=%.4f,%.4f,%.4f?Rotation=%.6f,%.6f,%.6f"):format(
        Layout.gameMode, position.X, position.Y, position.Z, rotation.Pitch, rotation.Yaw, rotation.Roll)
end

function Arena.travelFromTitle(gameplay, menu, scene)
    assert(scene.map == MAP and name(gameplay:GetCurrentLevelName(menu, true)) == TITLE, "独立梅谷乐坊须从演武标题入口进入")
    log("opening standalone map " .. Layout.map)
    gameplay:OpenLevel(menu, FName(Layout.map), true, mapOptions(scene.anchor, scene.rotation))
end

function Arena.reload(gameplay, pawn, scene)
    assert(scene.map == MAP, "独立梅谷乐坊重载场景不匹配")
    local sameMap = name(gameplay:GetCurrentLevelName(pawn, true)) == MAP
    local at = sameMap and session and inWorld(pawn, session.world) and session.respawn or scene.anchor
    log("reloading standalone arena beside " .. scene.bellSaveId)
    gameplay:OpenLevel(pawn, FName(Layout.map), true, mapOptions(at, scene.rotation))
end

local function residency(world)
    local levels = world.StreamingLevels
    local seen, loaded, visible, arenaLoaded, arenaVisible = {}, 0, 0, 0, 0
    for i = 1, #levels do
        local level = levels[i]
        if valid(level) then
            local package = name(level:GetWorldAssetPackageFName())
            local kind = expected[package]
            if kind and not seen[package] then
                seen[package] = true
                if level:IsLevelLoaded() then
                    loaded = loaded + 1
                    if kind ~= "background" then arenaLoaded = arenaLoaded + 1 end
                end
                if level:IsLevelVisible() then
                    visible = visible + 1
                    if kind ~= "background" then arenaVisible = arenaVisible + 1 end
                end
            end
        end
    end
    return loaded, visible, arenaLoaded, arenaVisible
end

function Arena.snapshot()
    assert(session and valid(session.world), "standalone map is unavailable")
    return "standalone", residency(session.world)
end

local function inspectLighting(gameplay, pawn, tx)
    local actors = {}
    gameplay:GetAllActorsOfClass(pawn, required("/Script/Engine.SkyLight"), actors)
    for _, entry in ipairs(actors) do
        local actor = unwrap(entry)
        if inWorld(actor, tx.world) and valid(actor.LightComponent) then
            local cubemap = actor.LightComponent.Cubemap
            if valid(cubemap) and name(cubemap:GetFName()) == "PBZ_Skylight_V3" then
                event("LIGHT source=PBZ_Skylight_V3")
                return
            end
        end
    end
    event("LIGHT source=unavailable")
end

local function inspectEnvironment(gameplay, pawn, tx)
    local spec = Layout.nativeEnvironment
    if not spec then return inspectLighting(gameplay, pawn, tx) end
    local function byClass(path, names)
        local class = StaticFindObject(path)
        if not valid(class) then return {}, 0 end
        local actors, result, count = {}, {}, 0
        gameplay:GetAllActorsOfClass(pawn, class, actors)
        for _, entry in ipairs(actors) do
            local actor = unwrap(entry)
            if inWorld(actor, tx.world) then
                local key = name(actor:GetFName())
                for _, expected in ipairs(names) do
                    if key == expected then result[key], count = actor, count + 1; break end
                end
            end
        end
        return result, count
    end
    local skies = byClass("/Weather/OurWeather/Blueprints/Ultra_Dynamic_Sky_Child.Ultra_Dynamic_Sky_Child_C", { spec.sky })
    local weather = byClass("/Weather/OurWeather/Blueprints/Ultra_Dynamic_Weather_Child.Ultra_Dynamic_Weather_Child_C", { spec.weather })
    local _, post = byClass("/Script/Engine.PostProcessVolume", spec.postProcess)
    local water = byClass("/Script/Water.WaterBodyLake", { spec.water })
    local sky, weatherActor, lake = skies[spec.sky], weather[spec.weather], water[spec.water]
    local sun = valid(sky) and unwrap(sky.Sun)
    local light = valid(sky) and unwrap(sky["Captured Scene Sky Light"])
    local fog = valid(sky) and unwrap(sky.HeightFog)
    local cloud = valid(sky) and unwrap(sky.VolumetricCloud)
    local cubemap = valid(light) and unwrap(light.Cubemap)
    local body = valid(lake) and unwrap(lake.WaterBodyComponent)
    local material = valid(body) and unwrap(body.WaterMaterial)
    event(("RENDER sky=%d sun=%d weather=%d cloud=%d volumetric=%d post=%d/%d water=%s")
        :format(valid(sky) and 1 or 0, valid(sun) and 1 or 0, valid(weatherActor) and 1 or 0,
            valid(cloud) and 1 or 0, not tx.weatherFog and valid(fog) and fog.bEnableVolumetricFog and 1 or 0,
            post, #spec.postProcess, valid(material) and name(material:GetFName()) or "missing"))
    event("LIGHT source=" .. (valid(cubemap) and name(cubemap:GetFName()) or "unavailable"))
    local _, vt = byClass("/Script/Engine.RuntimeVirtualTextureVolume", spec.virtualTextures)
    local _, height = byClass("/Script/VirtualHeightfieldMesh.VirtualHeightfieldMesh", { spec.heightfield })
    local _, planar = byClass("/Script/Engine.PlanarReflection", { spec.planar })
    local _, capture = byClass("/Script/Engine.SphereReflectionCapture", { spec.reflection })
    event(("RENDER_SURFACES virtual_textures=%d heightfield=%d planar=%d capture=%d"):format(vt, height, planar, capture))
    if spec.waterSurface then
        local zones = byClass("/Script/Water.WaterZone", { spec.waterZone })
        local zone = zones[spec.waterZone]
        local zoneMesh = valid(zone) and unwrap(zone.WaterMesh)
        local surface = valid(body) and unwrap(body.LakeMeshComp)
        assert(valid(zoneMesh) and valid(surface) and name(surface:GetFName()) == spec.waterSurface,
            "梅谷乐坊湖面组件缺失")
        local mesh = unwrap(surface.StaticMesh)
        assert(valid(mesh) and name(mesh:GetFName()) == "WaterInfoMesh_2", "梅谷乐坊湖形网格缺失")
        local surfaceMaterial = body:GetWaterMaterialInstance()
        if not valid(surfaceMaterial) then surfaceMaterial = material end
        assert(valid(material) and valid(surfaceMaterial), "梅谷乐坊湖面材质缺失")
        surface:SetCollisionEnabled(0)
        surface:SetMaterial(0, surfaceMaterial)
        surface:SetVisibility(true, false)
        surface:SetHiddenInGame(false, false)
        zoneMesh:SetVisibility(false, false)
        zoneMesh:SetHiddenInGame(true, false)
        event(("WATER_SURFACE mesh=%s visible=%d hidden=%d z=%.1f material=%s zone_mesh_visible=%d")
            :format(name(mesh:GetFName()), surface:IsVisible() and 1 or 0, surface.bHiddenInGame and 1 or 0,
                surface:K2_GetComponentLocation().Z, name(material:GetFName()), zoneMesh:IsVisible() and 1 or 0))
    end
end

local function findBell(gameplay, pawn, tx, scene)
    local actors = {}
    gameplay:GetAllActorsOfClass(pawn, required(BELL_CLASS), actors)
    for _, item in ipairs(actors) do
        local actor = unwrap(item)
        if inWorld(actor, tx.world) and name(actor:GetFName()) == Layout.bell and name(actor.BellID) == scene.bellSaveId
            and distanceSquared(actor:K2_GetActorLocation(), scene.bellLocation) <= 25 then
            return actor
        end
    end
end

local function floorAt(pawn, system, point, above, below)
    local top = { X = point.X, Y = point.Y, Z = point.Z + (above or 180) }
    local bottom = { X = point.X, Y = point.Y, Z = point.Z - (below or 220) }
    local hit = {}
    if system:LineTraceSingle(pawn, top, bottom, 0, false, {}, 0, hit, true, CLEAR, CLEAR, 0)
        and hit.ImpactNormal and hit.ImpactNormal.Z >= 0.7 and hit.ImpactPoint then
        return hit.ImpactPoint.Z
    end
    hit = {}
    if system:LineTraceSingleForObjects(pawn, top, bottom, WORLD_STATIC, false, {}, 0, hit, true, CLEAR, CLEAR, 0)
        and hit.ImpactNormal and hit.ImpactNormal.Z >= 0.7 and hit.ImpactPoint then
        return hit.ImpactPoint.Z
    end
end

local function inspectTerrain(gameplay, system, pawn, tx)
    local actors, supported = {}, 0
    local landscape = required("/Script/Landscape.LandscapeStreamingProxy")
    gameplay:GetAllActorsOfClass(pawn, landscape, actors)
    for _, point in ipairs(Layout.groundSamples) do
        local z = point.expectedZ and floorAt(pawn, system, { X = point.X, Y = point.Y, Z = point.expectedZ }, 90, 100)
        if not point.expectedZ then
            local hit = {}
            local top = { X = point.X, Y = point.Y, Z = 2600 }
            local bottom = { X = point.X, Y = point.Y, Z = -1100 }
            local found = system:LineTraceSingleForObjects(pawn, top, bottom, WORLD_STATIC, false, {}, 0, hit, true, CLEAR, CLEAR, 0)
            z = found and hit.ImpactNormal and hit.ImpactNormal.Z >= 0.35 and hit.ImpactPoint and hit.ImpactPoint.Z
        else
            event(("GROUND_POINT id=%s x=%.0f y=%.0f expected_z=%.0f hit_z=%s walkable=%d"):format(
                point.id, point.X, point.Y, point.expectedZ, z and ("%.1f"):format(z) or "miss", point.walkable))
        end
        if z then
            supported = supported + 1
        elseif point.walkable ~= 0 then
            event(("GROUND_MISS x=%.0f y=%.0f"):format(point.X, point.Y))
        end
    end
    local proxies, material = 0, nil
    for _, entry in ipairs(actors) do
        local actor = unwrap(entry)
        if inWorld(actor, tx.world) then
            proxies = proxies + 1
            if not material and Layout.nativeEnvironment then
                local value = unwrap(actor.LandscapeMaterial)
                if valid(value) then material = name(value:GetFName()) end
            end
        end
    end
    event(("GROUND terrain=%d samples=%d supported=%d"):format(proxies, #Layout.groundSamples, supported))
    if Layout.nativeEnvironment then event("GROUND_MATERIAL name=" .. (material or "missing")) end
end

local function prepareRespawn(tx, pawn, system, scene)
    local capsule = pawn.CapsuleComponent
    if not valid(capsule) then return nil, "等待玩家胶囊初始化" end
    local height = capsule:GetScaledCapsuleHalfHeight()
    local entry = scene.anchor
    local ground = floorAt(pawn, system, { X = entry.X, Y = entry.Y, Z = entry.Z - height })
    if not ground then return nil, "等待梅谷乐坊铃铛旁的原版地面" end
    if not floorAt(pawn, system, scene.spawnPoints[1]) then return nil, "等待梅谷乐坊擂台原版碰撞" end
    tx.respawn = { X = entry.X, Y = entry.Y, Z = ground + height + 6 }
    return true
end

local function checkNavigation(pawn, context)
    local navigation = required(NAVIGATION)
    local points = {}
    for i, point in ipairs(Layout.navPoints) do
        if i == 1 and valid(context) then
            local position = context:K2_GetActorLocation()
            local capsule = context.CapsuleComponent
            local halfHeight = valid(capsule) and capsule:GetScaledCapsuleHalfHeight() or 0
            point = { X = position.X, Y = position.Y, Z = position.Z - halfHeight }
        end
        local at = {}
        if not navigation:K2_ProjectPointToNavigation(pawn, point, at, nil, nil, { X = 120, Y = 120, Z = 180 })
            or not at.X or distanceSquared(at, point) > 180^2 then
            return false, "nav_projection_" .. i
        end
        points[i] = at
    end
    for i = 2, #points do
        local path = navigation:FindPathToLocationSynchronously(pawn, points[1], points[i], context or pawn, nil)
        if not valid(path) or path:IsPartial() or #path.PathPoints < 2 then
            return false, "nav_path_" .. i
        end
        local finish = path.PathPoints[#path.PathPoints]
        -- UE4SS maps its UObject validity check to IsValid. A complete
        -- NavigationPath still needs non-partial points ending on the target.
        if distanceSquared(finish, points[i]) > 120^2 then return false, "nav_endpoint_" .. i end
    end
    return true
end

local function spawn(gameplay, pawn, tx, class, transform)
    local actor = gameplay:BeginDeferredActorSpawnFromClass(pawn, class, transform, 1, nil, 1)
    assert(inWorld(actor, tx.world), "无法创建梅谷乐坊场地对象")
    tx.owned[#tx.owned + 1] = actor
    assert(same(gameplay:FinishSpawningActor(actor, transform, 1), actor), "无法完成梅谷乐坊场地对象生成")
    return actor
end

local function hideWeatherFog(gameplay, pawn, tx)
    local skyClass = required("/Weather/OurWeather/Blueprints/Ultra_Dynamic_Sky_Child.Ultra_Dynamic_Sky_Child_C")
    local skies, sky = {}, nil
    gameplay:GetAllActorsOfClass(pawn, skyClass, skies)
    for _, entry in ipairs(skies) do
        local candidate = unwrap(entry)
        if inWorld(candidate, tx.world) and name(candidate:GetFName()) == Layout.nativeEnvironment.sky then
            sky = candidate
            break
        end
    end
    local weatherFog = valid(sky) and unwrap(sky.HeightFog)
    assert(valid(weatherFog), "梅谷乐坊原版天气雾组件缺失")
    -- The sky Blueprint also writes this component during weather updates.
    tx.weatherFog = { sky = sky, component = weatherFog, enabled = sky["Render Exponential Height Fog"],
        visible = weatherFog:IsVisible(), hidden = weatherFog.bHiddenInGame }
    sky["Render Exponential Height Fog"] = false
    weatherFog:SetVisibility(false, false)
    weatherFog:SetHiddenInGame(true, false)
    assert(not sky["Render Exponential Height Fog"] and not weatherFog:IsVisible(), "梅谷乐坊天气雾未交接")
end

local function prepareMist(gameplay, pawn, tx)
    local mist = Layout.arenaMist
    local transform = required(MATH):MakeTransform(Layout.floor.position, IDENTITY_ROTATION, SCALE)
    local actor = spawn(gameplay, pawn, tx, required("/Script/Engine.ExponentialHeightFog"), transform)
    local fog = unwrap(actor.RootComponent)
    assert(valid(fog), "梅谷乐坊距离雾组件缺失")
    fog:SetVolumetricFog(false)
    fog:SetFogHeightFalloff(mist.heightFalloff)
    fog:SetSecondFogDensity(0)
    fog:SetFogDensity(mist.density)
    fog:SetStartDistance(mist.startDistance)
    fog:SetFogMaxOpacity(1)
    fog:SetEndDistance(0)
    fog:SetFogCutoffDistance(0)
    fog:SetSkyAtmosphereAmbientContributionColorScale(mist.skyTint)
    fog:SetDirectionalInscatteringColor(CLEAR)
    fog:SetFogInscatteringColor(mist.color)
    fog:SetVolumetricFogEmissive(mist.color)
    fog:SetHiddenInGame(false, false)
    fog:SetVisibility(true, false)
    assert(fog:IsVisible() and not fog.bEnableVolumetricFog and math.abs(fog.FogDensity - mist.density) < 0.001
        and math.abs(fog.StartDistance - mist.startDistance) < 1, "梅谷乐坊距离雾设置回读不符")
    hideWeatherFog(gameplay, pawn, tx)
    event(("ARENA_MIST start_cm=%.0f density=%.2f height_falloff=%.3f target_m=%.0f visible=1 weather_fog_visible=0")
        :format(fog.StartDistance, fog.FogDensity, fog.FogHeightFalloff, mist.targetDistance / 100))
end

local function preparePerimeterFog(gameplay, system, pawn, tx)
    local mist = Layout.perimeterFog
    assert(system:GetConsoleVariableIntValue("r.SupportLocalFogVolumes") > 0
        and system:GetConsoleVariableIntValue("r.LocalFogVolume") > 0, "本次渲染设置未启用局部雾体积")
    local mathLibrary = required(MATH)
    local fogClass = required("/Script/Engine.LocalFogVolumeComponent")
    local actor = spawn(gameplay, pawn, tx, required("/Script/Engine.Actor"),
        mathLibrary:MakeTransform(Layout.floor.position, IDENTITY_ROTATION, SCALE))
    local scale = mist.radius / 500 -- Native local fog volumes have a 500 cm unit radius.
    local volumeScale = { X = scale, Y = scale, Z = scale }
    for _, position in ipairs(mist.positions) do
        local transform = mathLibrary:MakeTransform(position, IDENTITY_ROTATION, volumeScale)
        local volume = actor:AddComponentByClass(fogClass, true, transform, true)
        assert(valid(volume), "梅谷乐坊外围雾体积无法创建")
        volume:SetRadialFogExtinction(mist.radialExtinction)
        -- The renderer combines both fog distributions. A low falloff keeps
        -- the vertical density gradual while the radial edge fades to zero.
        volume:SetHeightFogExtinction(mist.heightExtinction)
        volume:SetHeightFogFalloff(1)
        volume:SetFogAlbedo(mist.albedo)
        volume:SetFogEmissive(mist.emissive)
        volume:SetFogPhaseG(0)
        actor:FinishAddComponent(volume, true, transform)
        assert(volume:IsVisible() and distanceSquared(volume:K2_GetComponentLocation(), position) < 1
            and distanceSquared(volume:K2_GetComponentScale(), volumeScale) < 0.0001
            and math.abs(volume.RadialFogExtinction - mist.radialExtinction) < 0.001
            and math.abs(volume.HeightFogExtinction - mist.heightExtinction) < 0.001,
            "梅谷乐坊外围雾体积设置回读不符")
    end
    -- The default 20 m near clip cuts a hole in the fog when approaching the perimeter.
    local nearClip = system:GetConsoleVariableFloatValue(LOCAL_FOG_START)
    if nearClip > LOCAL_FOG_NEAR_CLIP then
        tx.localFogStart = { system = system, previous = nearClip }
        system:ExecuteConsoleCommand(tx.world, LOCAL_FOG_START .. " " .. LOCAL_FOG_NEAR_CLIP, nil)
        nearClip = system:GetConsoleVariableFloatValue(LOCAL_FOG_START)
        assert(nearClip == LOCAL_FOG_NEAR_CLIP, "梅谷乐坊局部雾近裁面设置回读不符")
    end
    hideWeatherFog(gameplay, pawn, tx)
    event(("PERIMETER_FOG volumes=%d band_m=%.1f radial_extinction=%.2f near_clip_cm=%.0f")
        :format(#mist.positions, mist.radius * 2 / 100, mist.radialExtinction, math.max(nearClip, LOCAL_FOG_NEAR_CLIP)))
end

local function restoreLocalFogStart(tx)
    local state = tx.localFogStart
    tx.localFogStart = nil
    if not state or not valid(state.system) then return end
    if state.system:GetConsoleVariableFloatValue(LOCAL_FOG_START) == LOCAL_FOG_NEAR_CLIP then
        local context = valid(tx.world) and tx.world or nil
        state.system:ExecuteConsoleCommand(context, ("%s %.9g"):format(LOCAL_FOG_START, state.previous), nil)
    end
end

local function restoreWeatherFog(tx)
    local state = tx.weatherFog
    tx.weatherFog = nil
    if not state or not inWorld(state.sky, tx.world) or not valid(state.component) then return end
    state.sky["Render Exponential Height Fog"] = state.enabled
    state.component:SetHiddenInGame(state.hidden, false)
    state.component:SetVisibility(state.visible, false)
end

local function createCollisionBox(gameplay, pawn, tx, mathLibrary, position, rotation, extent, profile)
    local transform = mathLibrary:MakeTransform(position, rotation, SCALE)
    local actor = spawn(gameplay, pawn, tx, required("/Script/Engine.Actor"), transform)
    local box = actor:AddComponentByClass(required("/Script/Engine.BoxComponent"), false,
        transform, false)
    assert(valid(box), "梅谷乐坊碰撞体无法创建")
    box:K2_SetWorldLocationAndRotation(position, rotation, false, {}, true)
    box:SetBoxExtent(extent, true)
    box:SetCollisionProfileName(FName(profile), true)
    box:SetCollisionEnabled(3)
    box:SetHiddenInGame(true, false)
    assert(box:GetCollisionResponseToChannel(2) == 2, "梅谷乐坊碰撞体未阻挡玩家")
    assert(distanceSquared(box:K2_GetComponentLocation(), position) < 1, "梅谷乐坊碰撞体坐标不符")
    return box
end

local function createCharacterBarrier(actor, boxClass, transform, extent, pawnChannel, walkable)
    local box = actor:AddComponentByClass(boxClass, true, transform, true)
    assert(valid(box), "梅谷乐坊阻挡组件创建失败")
    box.bCanEverAffectNavigation = false
    box:SetBoxExtent(extent, false)
    box:SetCollisionProfileName(FName("Profile_LA_InvisibleWall"), false)
    box:SetCollisionObjectType(0)
    box:SetCollisionResponseToChannel(2, 2)
    box:SetCollisionResponseToChannel(23, 2) -- Original fog-door AIPawn response.
    if pawnChannel ~= 2 and pawnChannel ~= 23 then box:SetCollisionResponseToChannel(pawnChannel, 2) end
    -- A floor participates in ground and foot IK queries. Walls leave sight clear.
    if not walkable then box:SetCollisionResponseToChannel(3, 0) end
    box:SetCollisionResponseToChannel(4, 0)
    box:SetGenerateOverlapEvents(false)
    box:SetCollisionEnabled(0)
    box:SetHiddenInGame(true, false)
    actor:FinishAddComponent(box, true, transform)
    assert(box:GetCollisionResponseToChannel(pawnChannel) == 2 and box:GetCollisionResponseToChannel(23) == 2,
        "梅谷乐坊碰撞组件未阻挡角色")
    return box
end

local function createBridgeDeck(actor, boxClass, system, pawn, mathLibrary, pawnChannel, deck)
    local transform = mathLibrary:MakeTransform(deck.position, deck.rotation, SCALE)
    local floor = createCharacterBarrier(actor, boxClass, transform, deck.extent, pawnChannel, true)
    floor.CanCharacterStepUpOn = 1 -- ECB_Yes
    floor:SetCollisionEnabled(3)
    assert(floor:GetCollisionEnabled() == 3 and floor.CanCharacterStepUpOn == 1
        and distanceSquared(floor:K2_GetComponentLocation(), deck.position) < 1, "梅谷乐坊桥尾承重面设置回读不符")

    local yaw = math.rad(deck.rotation.Yaw)
    local cos, sin = math.cos(yaw), math.sin(yaw)
    local hits, lowest, highest = 0, math.huge, -math.huge
    for _, along in ipairs({ -370, -185, 0, 185, 360 }) do
        for _, across in ipairs({ -90, 0, 90 }) do
            local x = deck.position.X + cos * along - sin * across
            local y = deck.position.Y + sin * along + cos * across
            local hit = {}
            if system:LineTraceSingleForObjects(pawn, { X = x, Y = y, Z = 950 }, { X = x, Y = y, Z = 700 },
                    WORLD_STATIC, false, {}, 0, hit, true, CLEAR, CLEAR, 0) then
                local z = hit.ImpactPoint and hit.ImpactPoint.Z
                local normal = hit.ImpactNormal and hit.ImpactNormal.Z
                local component = unwrap(hit.Component)
                if z and z >= 735 and z <= 815 and normal and normal >= 0.7 and valid(component)
                    and component:GetCollisionResponseToChannel(pawnChannel) == 2 then
                    hits, lowest, highest = hits + 1, math.min(lowest, z), math.max(highest, z)
                end
            end
        end
    end
    local heights = hits > 0 and ("%.1f..%.1f"):format(lowest, highest) or "none"
    event(("BRIDGE_DECK player_support=%d/15 z=%s"):format(hits, heights))
end

local function createBridgeWall(gameplay, system, pawn, tx, mathLibrary)
    local wall = Layout.bridgeWall
    if not wall then return end
    local capsule = unwrap(pawn.CapsuleComponent)
    assert(valid(capsule), "梅谷乐坊桥口缺少角色胶囊体")
    local position, extent = wall.position, wall.extent
    local transform = mathLibrary:MakeTransform(position, wall.rotation, SCALE)
    local actor = spawn(gameplay, pawn, tx, required("/Script/Engine.Actor"), transform)
    local box = createCharacterBarrier(actor, required("/Script/Engine.BoxComponent"), transform, extent,
        capsule:GetCollisionObjectType())
    box:SetCollisionEnabled(1)
    assert(box:GetCollisionEnabled() == 1 and distanceSquared(box:K2_GetComponentLocation(), position) < 1,
        "梅谷乐坊桥口空气墙设置回读不符")
    local radians = math.rad(wall.rotation.Yaw)
    local x, y = math.cos(radians), math.sin(radians)
    local hits = 0
    for _, lateral in ipairs({ -0.33 * extent.Y, 0, 0.33 * extent.Y }) do
        local sampleX, sampleY = position.X - y * lateral, position.Y + x * lateral
        local from = { X = sampleX + x * 75, Y = sampleY + y * 75, Z = wall.probeHeight }
        local to = { X = sampleX - x * 75, Y = sampleY - y * 75, Z = wall.probeHeight }
        local hit = {}
        if system:LineTraceSingleForObjects(pawn, from, to, WORLD_STATIC, false, {}, 0, hit, true, CLEAR, CLEAR, 0)
            and same(unwrap(hit.Component), box) then
            hits = hits + 1
        end
    end
    event(("BRIDGE_WALL x=%.0f y=%.0f yaw=%.0f width_m=%.1f traces=%d/3")
        :format(position.X, position.Y, wall.rotation.Yaw, extent.Y * 2 / 100, hits))
end

local function createBridgeGuard(gameplay, system, pawn, tx, mathLibrary)
    local guard = Layout.bridgeGuard
    if not guard then return end
    local capsule = unwrap(pawn.CapsuleComponent)
    assert(valid(capsule), "梅谷乐坊木桥缺少角色胶囊体")
    local pawnChannel = capsule:GetCollisionObjectType()
    local boxClass = required("/Script/Engine.BoxComponent")
    local actorClass = required("/Script/Engine.Actor")
    local actor = spawn(gameplay, pawn, tx, actorClass,
        mathLibrary:MakeTransform(guard.route[1], IDENTITY_ROTATION, SCALE))
    if guard.deck then createBridgeDeck(actor, boxClass, system, pawn, mathLibrary, pawnChannel, guard.deck) end
    local function trace(from, to)
        local hit = {}
        if system:LineTraceSingleForObjects(pawn, from, to, WORLD_STATIC, false, {}, 0, hit, true, CLEAR, CLEAR, 0) then
            return unwrap(hit.Component)
        end
    end
    for _, edge in ipairs(guard.edges) do
        local hits = 0
        for i = 2, #edge.points do
            local a, b = edge.points[i - 1], edge.points[i]
            local dx, dy = b.X - a.X, b.Y - a.Y
            local length = math.sqrt(dx * dx + dy * dy)
            local center = { X = (a.X + b.X) * 0.5, Y = (a.Y + b.Y) * 0.5, Z = guard.centerZ }
            local rotation = { Pitch = 0, Yaw = math.deg(math.atan(dy, dx)), Roll = 0 }
            local transform = mathLibrary:MakeTransform(center, rotation, SCALE)
            -- Extend each box into the next one so there is no gap at a bend.
            local extent = { X = length * 0.5 + 30, Y = edge.halfThickness or 16, Z = guard.halfHeight }
            local box = createCharacterBarrier(actor, boxClass, transform, extent, pawnChannel)
            box:SetCollisionEnabled(1)
            assert(box:GetCollisionEnabled() == 1 and distanceSquared(box:K2_GetComponentLocation(), center) < 1,
                "梅谷乐坊木桥空气墙设置回读不符")
            local nx, ny = -dy * 65 / length, dx * 65 / length
            local from = { X = center.X + nx, Y = center.Y + ny, Z = guard.probeHeight }
            local to = { X = center.X - nx, Y = center.Y - ny, Z = guard.probeHeight }
            if same(trace(from, to), box) or same(trace(to, from), box) then hits = hits + 1 end
        end
        local count = #edge.points - 1
        event(("BRIDGE_GUARD side=%s boxes=%d traces=%d/%d"):format(edge.name, count, hits, count))
    end
    local clear, deck = 0, 0
    for i, point in ipairs(guard.route) do
        if i > 1 and not valid(trace(guard.route[i - 1], point)) then clear = clear + 1 end
        local z = floorAt(pawn, system, point, 0, 330)
        if z and z >= 680 and z <= 875 then deck = deck + 1 end
    end
    event(("BRIDGE_ROUTE clear=%d/%d deck=%d/%d"):format(clear, #guard.route - 1, deck, #guard.route))
end

local function createFogCollision(gameplay, system, pawn, tx, mathLibrary, spline)
    local transform = mathLibrary:MakeTransform({ X = 0, Y = 0, Z = 0 }, IDENTITY_ROTATION, SCALE)
    local actor = spawn(gameplay, pawn, tx, required("/Script/Engine.Actor"), transform)
    local boxClass = required("/Script/Engine.BoxComponent")
    local length = spline:GetSplineLength()
    local count = math.ceil(length / FOG_SAMPLE_STEP)
    assert(count > 0, "梅谷乐坊雾门样条长度无效")
    tx.fogSegments, tx.fogSystem = {}, system
    local first = spline:GetLocationAtDistanceAlongSpline(0, 1)
    local previous = first
    local capsule = unwrap(pawn.CapsuleComponent)
    assert(valid(capsule), "梅谷乐坊雾门缺少角色胶囊体")
    local pawnChannel = capsule:GetCollisionObjectType()
    local function addSegment(a, b, probe)
        local dx, dy = b.X - a.X, b.Y - a.Y
        local width = math.sqrt(dx * dx + dy * dy)
        if width < 1 then return end
        local center = { X = (a.X + b.X) * 0.5, Y = (a.Y + b.Y) * 0.5, Z = (a.Z + b.Z) * 0.5 + 160 }
        local rotation = { Pitch = 0, Yaw = math.deg(math.atan(dy, dx)), Roll = 0 }
        local worldTransform = mathLibrary:MakeTransform(center, rotation, SCALE)
        local extent = { X = width * 0.5 + 12, Y = FOG_BOX_HALF_WIDTH, Z = FOG_BOX_HEIGHT }
        local box = createCharacterBarrier(actor, boxClass, worldTransform, extent, pawnChannel)
        assert(distanceSquared(box:K2_GetComponentLocation(), center) < 1, "梅谷乐坊雾门碰撞位置不符")
        local offsetX, offsetY = dy * 45 / width, -dx * 45 / width
        tx.fogSegments[#tx.fogSegments + 1] = { box = box, probe = probe,
            from = { X = center.X + offsetX, Y = center.Y + offsetY, Z = center.Z },
            to = { X = center.X - offsetX, Y = center.Y - offsetY, Z = center.Z } }
    end
    for i = 1, count do
        local point = spline:GetLocationAtDistanceAlongSpline(i * length / count, 1)
        addSegment(previous, point, i > 3 and i <= count - 3)
        previous = point
    end
    -- The original open spline's two ends overlap near the bell-side entry.
    assert(#tx.fogSegments == count, "梅谷乐坊雾门碰撞段数不符")
end

local function supportNorthwest(gameplay, system, pawn, tx, mathLibrary)
    local point = Layout.northwestSupport
    if not point then return end
    local position = point.position
    local sample = point.sample
    local z = floorAt(pawn, system, sample, 55, 55)
    if z and math.abs(z - point.top) <= 55 then
        event(("GROUND_SUPPORT id=northwest result=original z=%.1f"):format(z))
        return
    end
    createCollisionBox(gameplay, pawn, tx, mathLibrary, position, point.rotation, point.extent, "Profile_LA_InvisibleWall")
    local patched = floorAt(pawn, system, sample, 55, 55)
    event(("GROUND_SUPPORT id=northwest result=%s z=%s"):format(
        patched and math.abs(patched - point.top) <= 55 and "restored" or "unverified",
        patched and ("%.1f"):format(patched) or "miss"))
end

local function createFog(gameplay, system, pawn, tx, mathLibrary)
    local fog = Layout.fog
    local class, reason = require("SpawnClass").resolve(FOG_CLASS)
    assert(valid(class), reason or "缺少原版雾门")
    local actor = spawn(gameplay, pawn, tx, class, mathLibrary:MakeTransform(fog.position, fog.rotation, fog.scale))
    actor:SetActorEnableCollision(false)
    local spline = actor.Spline
    assert(valid(spline), "原版雾门样条组件无效")
    local walls = actor["Spline Mesh Component"]
    local initialWalls = {}
    for i = 1, #walls do
        local wall = unwrap(walls[i])
        if valid(wall) then initialWalls[#initialWalls + 1] = wall end
    end
    for _, wall in ipairs(initialWalls) do wall:K2_DestroyComponent(wall) end
    if #walls > 0 then walls:Empty() end
    local points = actor["Spline Points Locations"]
    if points and #points > 0 then points:Empty() end
    actor["Scale Z"] = fog.heightScale
    actor.bInitiallyPassthrough = true
    spline:ClearSplinePoints(false)
    for index, point in ipairs(fog.points) do
        spline:AddSplinePoint(point.position, 0, false)
        spline:SetTangentsAtSplinePoint(index - 1, point.arrive, point.leave, 0, false)
    end
    spline:SetClosedLoop(false, true)
    assert(spline:GetNumberOfSplinePoints() == #fog.points, "原版雾门样条回读不符")
    actor:ConstructFogDoor()
    local segments = #actor["Spline Mesh Component"]
    assert(segments == #fog.points - 1, "原版雾门特效段数不符")
    actor:TSBeginPlay()
    actor:UpdateAfterOpen()
    actor:SetActorEnableCollision(false)
    tx.fog = actor
    createFogCollision(gameplay, system, pawn, tx, mathLibrary, spline)
    event(("FOG points=%d spline_segments=%d collision_components=%d")
        :format(#fog.points, segments, #tx.fogSegments))
end

local function prepareObjects(gameplay, system, pawn, tx)
    local mathLibrary = required(MATH)
    local floor = Layout.floor
    local floorExtent = { X = floor.scale.X * 100, Y = floor.scale.Y * 100, Z = floor.scale.Z * 100 }
    createCollisionBox(gameplay, pawn, tx, mathLibrary, floor.position, floor.rotation, floorExtent, "Profile_LA_InvisibleWall")
    local heights = Layout.boundary[1]
    local testZ = heights.position.Z + heights.extent.Z - 100
    local verified = 0
    for _, rim in ipairs(Layout.boundary) do
        local wall = createCollisionBox(gameplay, pawn, tx, mathLibrary, rim.position, IDENTITY_ROTATION, rim.extent, "InvisibleWall")
        wall:SetCollisionResponseToChannel(3, 0)
        wall:SetCollisionResponseToChannel(4, 0)
        assert(wall:GetCollisionResponseToChannel(3) == 0 and wall:GetCollisionResponseToChannel(4) == 0,
            "梅谷乐坊边缘碰撞挡住了视线或镜头")
        local hit = {}
        local top = { X = rim.position.X, Y = rim.position.Y, Z = testZ + 400 }
        local bottom = { X = top.X, Y = top.Y, Z = testZ }
        if system:LineTraceSingleForObjects(pawn, top, bottom, WORLD_STATIC, false, {}, 0, hit, true, CLEAR, CLEAR, 0)
            and same(unwrap(hit.Component), wall) then
            verified = verified + 1
        end
    end
    event(("BOUNDARY boxes=%d traces=%d"):format(#Layout.boundary, verified))
    supportNorthwest(gameplay, system, pawn, tx, mathLibrary)
    createBridgeWall(gameplay, system, pawn, tx, mathLibrary)
    createBridgeGuard(gameplay, system, pawn, tx, mathLibrary)
    createFog(gameplay, system, pawn, tx, mathLibrary)
end

local function armRevive(tx, pawn, controller, scene)
    local gameSystem = required(SUBSYSTEM):GetWorldSubsystem(pawn, required("/Script/ProjectPBZ.PBZGameSystem"))
    assert(valid(gameSystem), "缺少梅谷乐坊复活接口")
    local at, mathLibrary = tx.respawn, required(MATH)
    if distanceSquared(pawn:K2_GetActorLocation(), at) > 60^2 then
        assert(required(NATIVE):PBZActorTeleportTo(pawn, at, scene.rotation, false, false), "无法回到梅谷乐坊铃铛旁")
        controller:SetControlRotation(scene.rotation)
    end
    gameSystem:SetReviveTransform(mathLibrary:MakeTransform(at, scene.rotation, SCALE))
    local transform, camera, position, rotation = {}, {}, {}, {}
    gameSystem:GetReviveTransform(transform, camera)
    mathLibrary:BreakTransform(transform, position, rotation, {})
    assert(distanceSquared(position, at) <= 4, "梅谷乐坊复活点回读不匹配")
    tx.pawn = pawn:GetAddress()
end

local function updateBell(tx, enabled)
    local sphere = tx.bell.InteractionComp
    if not valid(sphere) then return end
    local mode = sphere:GetCollisionEnabled()
    if not same(tx.interaction, sphere) then
        if mode == 0 then return end
        tx.interaction, tx.bellMode = sphere, mode
    end
    local desired = enabled and tx.bellMode or 0
    if mode ~= desired then sphere:SetCollisionEnabled(desired) end
end

function Arena.getBell()
    if session and inWorld(session.bell, session.world) then return session.bell end
end

function Arena.findBellWidgets(class, now)
    if not session or now < session.nextMenuLookup then return end
    session.nextMenuLookup = now + 0.25
    return FindAllOf(class)
end

function Arena.phaseDestination(pawn, system, scene)
    if not session or not session.ready or not inWorld(pawn, session.world) then return nil, "等待梅谷乐坊场地就绪" end
    local height = pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()
    for _, at in ipairs(scene.phaseReturnPoints) do
        local ground = floorAt(pawn, system, at)
        if ground then
            local position = { X = at.X, Y = at.Y, Z = ground + height + 6 }
            local aim = required(MATH):FindLookAtRotation(position, scene.spawnPoints[1])
            return { position = position, rotation = { Pitch = 0, Yaw = aim.Yaw, Roll = 0 } }
        end
    end
    return nil, "等待梅谷乐坊场内回位点的地面"
end

function Arena.updateCombat(pawn, active)
    local tx = session
    if not tx or not tx.ready or tx.fogClosed == active or not inWorld(tx.fog, tx.world) then return end
    -- Closing only inside the ring keeps the bell-side approach accessible
    -- if the enemy engages a player who is still outside.
    local at, center = pawn:K2_GetActorLocation(), Layout.floor.position
    if active and (at.X - center.X)^2 + (at.Y - center.Y)^2 > 850^2 then return end
    if tx.fogFailed == active then return end
    local ok, failure = pcall(function()
        local mode = active and 1 or 0 -- QueryOnly is sufficient for the character movement sweep.
        for _, segment in ipairs(tx.fogSegments) do segment.box:SetCollisionEnabled(mode) end
        tx.fog.bInitiallyPassthrough = not active
        if active then tx.fog:UpdateAfterClose() else tx.fog:UpdateAfterOpen() end
        local hits, probes = 0, 0
        for _, segment in ipairs(tx.fogSegments) do
            assert(segment.box:GetCollisionEnabled() == mode, "梅谷乐坊雾门碰撞状态不符")
            if segment.probe then
                probes = probes + 1
                local hit = {}
                if tx.fogSystem:LineTraceSingleForObjects(pawn, segment.from, segment.to, WORLD_STATIC, false, {}, 0,
                        hit, true, CLEAR, CLEAR, 0) and same(unwrap(hit.Component), segment.box) then
                    hits = hits + 1
                end
            end
        end
        event(("FOG_COLLISION closed=%s boxes=%d hits=%d/%d"):format(tostring(active), #tx.fogSegments, hits, probes))
    end)
    if ok then
        tx.fogClosed, tx.fogFailed = active, nil
        event("FOG_STATE closed=" .. tostring(active))
    else
        for _, segment in ipairs(tx.fogSegments) do
            pcall(function() segment.box:SetCollisionEnabled(0) end)
        end
        pcall(function()
            tx.fog.bInitiallyPassthrough = true
            tx.fog:UpdateAfterOpen()
        end)
        tx.fogClosed = false
        tx.fogFailed = active
        event("ERROR fog_state " .. tostring(failure))
    end
end

function Arena.reset()
    local old = session
    session = nil
    if not old then return end
    if inWorld(old.bell, old.world) and valid(old.interaction) then
        pcall(function() old.interaction:SetCollisionEnabled(old.bellMode) end)
    end
    pcall(restoreWeatherFog, old)
    pcall(restoreLocalFogStart, old)
    for _, actor in ipairs(old.owned) do
        if inWorld(actor, old.world) and not actor:IsActorBeingDestroyed() then
            pcall(function() actor:K2_DestroyActor() end)
        end
    end
end

function Arena.update(gameplay, system, pawn, controller, world, now, scene, allowBell)
    assert(scene.map == MAP and name(gameplay:GetCurrentLevelName(pawn, true)) == MAP and inWorld(pawn, world),
        "梅谷乐坊独立地图或角色归属不匹配")
    if not session or not same(session.world, world) then
        Arena.reset()
        session = { world = world, owned = {}, nextProbe = 0, nextMenuLookup = 0, nextBellCheck = 0,
            deadline = now + 24, fogClosed = false }
        event("MAP_LOADED name=" .. MAP)
        event(("LAYOUT total=%d detail=%d"):format(#Layout.cells, detailCount))
    end
    local tx = session
    if tx.failure then return nil, tx.failure end
    if not tx.ready then
        if now < tx.nextProbe then return nil, tx.waiting end
        tx.nextProbe = now + 0.5
        if now >= tx.deadline and not tx.waitLogged then
            tx.waitLogged = true
            event("ERROR readiness " .. tostring(tx.waiting or "unknown"))
        end
        local loaded, visible, detailLoaded, detailVisible = residency(world)
        if visible ~= #Layout.cells then
            tx.waiting = ("等待独立关卡区块 %d/%d"):format(visible, #Layout.cells)
            if tx.lastVisible ~= visible then
                event(("LEVELS loaded=%d visible=%d expected=%d"):format(loaded, visible, #Layout.cells))
                tx.lastVisible = visible
            end
            return nil, tx.waiting
        end
        local bell = tx.bell or findBell(gameplay, pawn, tx, scene)
        if not bell then tx.waiting = "等待梅谷乐坊原版铃铛"; return nil, tx.waiting end
        tx.bell = bell
        if not tx.objectsReady then
            local ok, failure = pcall(prepareObjects, gameplay, system, pawn, tx)
            if not ok then tx.failure = tostring(failure); event("ERROR objects " .. tx.failure); return nil, tx.failure end
            tx.objectsReady = true
        end
        if (Layout.perimeterFog or Layout.arenaMist) and not tx.mistReady then
            local lastOwned = #tx.owned
            local ok, failure
            if Layout.perimeterFog then
                ok, failure = pcall(preparePerimeterFog, gameplay, system, pawn, tx)
            else
                ok, failure = pcall(prepareMist, gameplay, pawn, tx)
            end
            if not ok then
                local partial = tx.owned[lastOwned + 1]
                if inWorld(partial, tx.world) then pcall(function() partial:K2_DestroyActor() end) end
                pcall(restoreWeatherFog, tx)
                pcall(restoreLocalFogStart, tx)
                event("SCENE_CHECK_ERROR mist " .. tostring(failure))
            end
            tx.mistReady = true
        end
        local ready, reason = prepareRespawn(tx, pawn, system, scene)
        if not ready then tx.waiting = reason; return nil, reason end
        local navigation, navReason = checkNavigation(pawn)
        if not navigation then
            if tx.lastNavReason ~= navReason then event("NAV_WAIT reason=" .. navReason); tx.lastNavReason = navReason end
            tx.waiting = "等待原版寻路区块注册 " .. navReason
            return nil, tx.waiting
        end
        local armed, reviveError = pcall(armRevive, tx, pawn, controller, scene)
        if not armed then tx.waiting = tostring(reviveError); return nil, tx.waiting end
        tx.ready = true
        local environmentOk, environmentError = pcall(inspectEnvironment, gameplay, pawn, tx)
        if not environmentOk then event("SCENE_CHECK_ERROR render " .. tostring(environmentError)) end
        if Layout.nativeEnvironment and Layout.nativeEnvironment.waterSurface then
            event(("BACKGROUND_LEVELS loaded=%d visible=%d"):format(loaded - detailLoaded, visible - detailVisible))
        end
        local terrainOk, terrainError = pcall(inspectTerrain, gameplay, system, pawn, tx)
        if not terrainOk then event("SCENE_CHECK_ERROR ground " .. tostring(terrainError)) end
        event(("ARENA_READY cells=%d nav=full bell=%s"):format(visible, name(bell.BellID)))
    elseif tx.pawn ~= pawn:GetAddress() and now >= (tx.nextReviveCheck or 0) then
        tx.nextReviveCheck = now + 1
        local armed, reason = pcall(armRevive, tx, pawn, controller, scene)
        if not armed and tx.reviveError ~= reason then event("REVIVE_WAIT " .. tostring(reason)) end
        tx.reviveError = not armed and reason or nil
    end
    if allowBell ~= tx.allowBell or now >= tx.nextBellCheck then
        updateBell(tx, allowBell)
        tx.allowBell, tx.nextBellCheck = allowBell, now + 0.75
    end
    return true
end

return Arena
