-- Weapon props are render components on the cinematic Hun.
local Props = {}
local SUBSYSTEMS = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local BACKPACK = "/Script/ProjectPBZ.PBZBackPackSubsystem"
local WEAPONS = "/Script/SGameCombatSystem.CharacterWeaponsComponent"
local SKELETAL = "/Script/Engine.SkeletalMeshComponent"
local STATIC = "/Script/Engine.StaticMeshComponent"
local GLAIVE_MESH = "/HuaShira/Characters/Hero/Hero_Hun/Weapon/Hun_YanYueDao.Hun_YanYueDao"
local UI_MONTAGES = "/Game/RenewalContent/Actors/Players/UICharacterAnim/"
local SEAT_SECONDS = .13

-- Take the original stance, first slot, and AN_DetachArmSlot time from each
-- of the three native equipment-screen unarm montages.
local SHEATH = {
    Tang = { slot = "RightArmOverride", attach = 1.198547 },
    Double = { slot = "IdleOverride", attach = .9303274 },
    Long = { slot = "IdleOverride", attach = 1.4642392 },
}

local function valid(x) return x and type(x.IsValid) == "function" and x:IsValid() end
local function unwrap(x)
    if x and type(x.IsValid) ~= "function" then
        local get = x.get or x.Get
        if type(get) == "function" then return get(x) end
    end
    return x
end

local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "missing " .. path)
    return object
end

local function same(a, b)
    return valid(a) and valid(b) and a:GetAddress() == b:GetAddress()
end

local function socket(mesh, value)
    value = unwrap(value)
    local name = type(value) == "string" and value or value and value:ToString() or "None"
    if name == "None" or name == "" then return nil end
    local result = FName(name)
    assert(mesh:DoesSocketExist(result), "Hun cutscene socket unavailable: " .. name)
    return result, name
end

local function slot(component, index, tag)
    local out = {}
    if component:GetSlotWeapon({ TagName = FName(tag or "Weapon.Slot.Main") }, index, out) ~= true then return end
    local function copy(field)
        local result, array = {}, out[field]
        if array then
            for i = 1, #array do result[i] = unwrap(array[i]) end
        end
        return result
    end
    return { config = unwrap(out.WeaponConfig), actors = copy("WeaponActors"), scabbards = copy("Scabbards") }
end

local function displayData(config)
    -- The native GetDisplayData implementation returns this exact property.
    -- Prefer the actual committed config (which may be the forged variant).
    local rows = config["Display Data"]
    if rows and #rows > 0 then return rows end
    local out = {}
    config:GetDisplayData(out)
    return out.DisplayData or out
end

local function animationStyle(config)
    local tags = config["Weapon Equip Tags"]
    tags = tags and (tags.GameplayTags or tags)
    local family, weaponType
    if tags then
        for i = 1, #tags do
            local tag = unwrap(tags[i])
            local name = tag and unwrap(tag.TagName or tag)
            local text = type(name) == "string" and name or name and name:ToString() or ""
            if text == "Weapon.Type.Global.SingleHanded" then family = family or "Tang"
            elseif text == "Weapon.Type.Global.DualHanded" then family = family or "Double"
            elseif text == "Weapon.Type.Global.TwoHanded" then family = family or "Long"
            else weaponType = weaponType or text:match("^Weapon%.Type%.([^%.]+)$") end
        end
    end
    return family, weaponType
end

local function clone(owner, class, asset, source, parent, mount, relative, identity, skeletal, created)
    local component = owner:AddComponentByClass(class, true, identity, false)
    assert(valid(component), "could not make the weapon render component")
    created[#created + 1] = component
    component:SetCollisionEnabled(0)
    if skeletal then component:SetSkeletalMeshAsset(asset) else component:SetStaticMesh(asset) end
    if valid(source) then
        for i = 0, source:GetNumMaterials() - 1 do
            local material = source:GetMaterial(i)
            if valid(material) then component:SetMaterial(i, material) end
        end
    end
    assert(component:K2_AttachToComponent(parent, mount, 2, 2, 2, false), "weapon mount failed")
    if relative then component:K2_SetRelativeTransform(relative, false, {}, true) end
    return component
end

function Props.activeSlot(pawn)
    local bp = required(SUBSYSTEMS):GetWorldSubsystem(pawn, required(BACKPACK))
    assert(valid(bp), "active equipment interface unavailable")
    local index = bp:GetCurrentMainWeaponIndex()
    assert(index == 0 or index == 1, "active main weapon index unavailable")
    return index
end

function Props.prepare(pawn, hun, mathLibrary, identity, created, activeIndex)
    local mesh = hun.Mesh
    local component = pawn:GetComponentByClass(required(WEAPONS))
    assert(valid(component), "active weapon component unavailable")
    local index = activeIndex or Props.activeSlot(pawn)
    local data = slot(component, index)
    assert(data and valid(data.config), "active main weapon configuration unavailable")
    local configName = data.config:GetFName():ToString()
    local gotStyle, selected, kind = pcall(animationStyle, data.config)
    local weaponType = (gotStyle and kind) or configName:match("^Weapon_Hun_(.+)$") or configName

    local rows = displayData(data.config)
    assert(rows and (#rows == 1 or #rows == 2), "unexpected active weapon display count")
    local skel, static = required(SKELETAL), required(STATIC)
    local parts, scabbards = {}, {}
    local family = gotStyle and selected or nil
    for i = 1, #rows do
        local row = unwrap(rows[i])
        local hand = socket(mesh, row.ArmedSocket)
        local back, backName = socket(mesh, row.UnarmedSocket)
        assert(hand and back, "active weapon has no hand or stow socket")
        if i == 1 and not family then
            family = #rows == 2 and "Double" or
                backName:find("LongBlade", 1, true) and "Long" or "Tang"
        end

        local actor = data.actors[i]
        assert(valid(actor), "active main weapon mesh actor unavailable")
        local source = unwrap(actor.WeaponMesh)
        assert(valid(source), "active main weapon render mesh unavailable")
        local skeletal = source:IsA(skel)
        assert(skeletal or source:IsA(static), "unsupported active main weapon mesh")
        local asset
        if skeletal then asset = source:GetSkeletalMeshAsset() else asset = source.StaticMesh end
        assert(valid(asset), "active main weapon render asset unavailable")
        local offset = mathLibrary:MakeRelativeTransform(source:K2_GetComponentToWorld(),
            actor:K2_GetRootComponent():K2_GetComponentToWorld())
        -- LuanYing's auxiliary blade can be hidden or already on the back.
        -- The single-hand animation only moves the active hand weapon.
        if i == 1 or family == "Double" or actor.bHidden ~= true then
            local mount = i == 1 or family == "Double"
            local prop = clone(hun, skeletal and skel or static, asset, source, mesh,
                mount and hand or back, offset, identity, skeletal, created)
            if mount then parts[#parts + 1] = { mesh = prop, hand = hand, back = back, offset = offset } end
        end

        local scabbard = unwrap(row.ScabbardMesh)
        if valid(scabbard) then
            local sheath, sheathName = socket(mesh, row.ScabbardSocket)
            assert(sheath, "active weapon has no scabbard socket")
            if not same(scabbards[sheathName], scabbard) then
                scabbards[sheathName] = scabbard
                local sheathSource
                for _, candidate in ipairs(data.scabbards) do
                    if valid(candidate) and candidate:IsA(skel)
                        and candidate:GetAttachSocketName():ToString() == sheathName
                        and same(candidate:GetSkeletalMeshAsset(), scabbard) then
                        sheathSource = candidate
                        break
                    end
                end
                clone(hun, skel, scabbard, sheathSource, mesh, sheath, nil, identity, true, created)
            end
        end
    end
    print(("[PBZBloodyPalace] ending weapon: slot=%d; config=%s; family=%s; pieces=%d\n")
        :format(index, configName, family, #parts))
    return { parts = parts, family = family, weaponType = weaponType }
end

function Props.prepareGlaive(hun, identity, load, created)
    -- BP_Weapon_Hun_YanYueDao uses this mesh on weapon_r_Socket at its default transform.
    local mesh = hun.Mesh
    local asset = load(GLAIVE_MESH, "/Script/Engine.SkeletalMesh")
    local prop = clone(hun, required(SKELETAL), asset, nil, mesh,
        socket(mesh, "weapon_r_Socket"), nil, identity, true, created)
    return { parts = { { mesh = prop } }, family = "Long", weaponType = "YanYueDao" }
end

function Props.loadUnarm(weapon, loadMontage)
    local name = "UI_AM_Hun_" .. weapon.family .. "_Unarm"
    local montage = loadMontage(UI_MONTAGES .. name .. "." .. name)
    local timing = SHEATH[weapon.family]
    assert(montage:GetPlayLength() > timing.attach + .5, "native unarm montage too short")
    weapon.clip, weapon.slot, weapon.attach, weapon.length = montage, FName(timing.slot), timing.attach,
        montage:GetPlayLength() - .002
end

function Props.setArmed(weapon, parent, armed)
    for _, piece in ipairs(weapon.parts) do
        local mount = armed and piece.hand or piece.back
        assert(mount and piece.mesh:K2_AttachToComponent(parent, mount, 2, 2, 2, false), "weapon mount failed")
        piece.mesh:K2_SetRelativeTransform(piece.offset, false, {}, true)
    end
    weapon.armed = armed
end

function Props.stow(weapon, parent, mathLibrary, motion)
    if weapon.stowed then return end
    local weight = math.min(1, math.max(0, (motion - weapon.attach) / SEAT_SECONDS))
    weight = weight * weight * (3 - 2 * weight)
    for _, piece in ipairs(weapon.parts) do
        if not piece.startOffset then
            -- Preserve the blade's pose at the socket change. In particular,
            -- the stock double unarm notify precedes the final seating by a
            -- few frames, and an immediate snap would jump visibly.
            piece.startOffset = mathLibrary:MakeRelativeTransform(piece.mesh:K2_GetComponentToWorld(),
                parent:GetSocketTransform(piece.back, 0))
            assert(piece.mesh:K2_AttachToComponent(parent, piece.back, 1, 1, 1, false), "weapon stow failed")
        end
        local offset = weight == 1 and piece.offset or mathLibrary:TLerp(piece.startOffset, piece.offset, weight, 0)
        piece.mesh:K2_SetRelativeTransform(offset, false, {}, true)
    end
    weapon.stowed = weight == 1
end

function Props.hideOriginal(pawn, hidden)
    local component = pawn:GetComponentByClass(required(WEAPONS))
    if not valid(component) then return end
    local seen = {}
    for _, tag in ipairs({ "Weapon.Slot.Main", "Weapon.Slot.ShaChi" }) do
        for index = 0, 1 do
            local data = slot(component, index, tag)
            for _, actor in ipairs(data and data.actors or {}) do
                if valid(actor) and not seen[actor:GetAddress()] then
                    seen[actor:GetAddress()] = true
                    hidden[#hidden + 1] = { actor = actor, wasHidden = actor.bHidden == true }
                    actor:SetActorHiddenInGame(true)
                end
            end
        end
    end
end

return Props
