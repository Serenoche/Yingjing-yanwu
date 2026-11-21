local Mask = {}
Mask.__index = Mask

local function valid(object)
    return object and type(object.IsValid) == "function" and object:IsValid()
end

local function unwrap(value)
    if valid(value) then return value end
    if value == nil then return end
    local ok, object = pcall(function() return value:get() end)
    if ok and valid(object) then return object end
end

local function baseClass(path)
    local class = StaticFindObject(path)
    return valid(class) and class or nil
end

function Mask.new()
    local script = "/Script/ProjectPBZ."
    local mask = setmetatable({
        system = baseClass("/Script/Engine.Default__KismetSystemLibrary"),
        primitive = baseClass("/Script/Engine.PrimitiveComponent"),
        shape = baseClass("/Script/Engine.ShapeComponent"),
        scene = baseClass("/Script/Engine.SceneComponent"),
        interface = baseClass(script .. "InteractableInterface"),
        pickup = baseClass(script .. "PBZPickupActor"),
        saveTrigger = baseClass(script .. "PBZSaveTriggerBox"),
        pawn = baseClass("/Script/Engine.Pawn"),
        region = baseClass(script .. "PBZInteractRegionComponent"),
        widget = baseClass(script .. "PBZInteractWidgetComp"),
        lazyWidget = baseClass(script .. "PBZLazyWidgetComponent"),
        niagara = baseClass("/Script/Niagara.NiagaraComponent"),
    }, Mask)
    assert(mask.system and mask.primitive and mask.shape and mask.scene and mask.interface
        and mask.pickup and mask.saveTrigger and mask.pawn and mask.region and mask.widget and mask.lazyWidget and mask.niagara,
        "native interaction classes unavailable")
    return mask
end

local function inherits(class, prefix)
    local parent = class:GetSuperStruct()
    while valid(parent) do
        local name = parent:GetFName()
        if (type(name) == "string" and name or name:ToString()):match(prefix) then return true end
        parent = parent:GetSuperStruct()
    end
    return false
end

function Mask:describe(actor, class, short, kind, blockWharf)
    if blockWharf and short == "BP_Wharf_C" then return { wharf = true } end
    if class:IsChildOf(self.pawn) then return end
    local resource = class:IsChildOf(self.pickup) or short:match("^BP_Rubbish") or short == "BP_FlowInteract_MemoryFlower_C"
        or inherits(class, "^BP_Rubbish")
    local checkpoint = class:IsChildOf(self.saveTrigger)
    local interface = self.system:DoesImplementInterface(actor, self.interface)
    local bell = kind == "bell" or short == "MelodiousBell" or short == "BrokenBell"
    local device = short:match("^BP_SwitchDevice") or short:match("^BP_Lift")
        or short:match("^BP_Teleport") or short:match("^BP_SingleDoor") or short:match("^BP_DoubleDoor")
        or short:match("^BP_Block_Door") or short:match("^BP_Block_Gate") or short == "BP_Block_ZongciDoor_C"
        or short == "BP_PhantomBarrier_Blocker_C" or short:lower() == "bp_ladder_c"
    local use = bell or kind == "chest" or kind == "portal" or short:match("^BP_FlowInteract")
        or kind == "spawner" and short == "BP_NPCSpawner_C" or device or interface
    if not (resource or checkpoint or use) then return end
    return {
        resource = not not resource,
        checkpoint = checkpoint, interface = interface, bell = bell, chest = kind == "chest",
    }
end

local triggerFields = {
    "InteractionComp", "InteractSphere", "InteractBox", "StringTrigger", "TriggerBox", "OverlapTriggerbox",
}
local widgetFields = { "Widget", "WidgetComp", "InteractWidget", "InteractWidgetComp" }

function Mask:disableTrigger(value, dedicated)
    local component = unwrap(value)
    if not component or not component:IsA(self.primitive) then return false end
    component:SetGenerateOverlapEvents(false)
    -- Keep physical and Pawn-blocking responses on shared door and ladder components.
    if dedicated or component:IsA(self.shape) and component:GetCollisionEnabled() == 1
        and component:GetCollisionResponseToChannel(2) ~= 2 then
        component:SetCollisionEnabled(0)
    end
    return true
end

local function mute(component, sceneClass)
    component:Deactivate()
    component:SetComponentTickEnabled(false)
    if component:IsA(sceneClass) then component:SetVisibility(false, true) end
end

function Mask:apply(actor, point, after)
    if point.wharf then
        -- The stock wharf binds its boarding overlap to Sphere and owns the
        -- prompt Widget. Collision can also serve as a physical dock barrier.
        local boardingDisabled = self:disableTrigger(actor.Sphere, true)
        self:disableTrigger(actor.Collision)
        if not after then return end
        local prompt = unwrap(actor.Widget)
        if prompt and prompt:IsA(self.scene) then mute(prompt, self.scene) end
        return boardingDisabled, 0
    end
    local disabled = point.resource or point.checkpoint
    if point.resource then
        actor:SetActorHiddenInGame(true)
        actor:SetActorEnableCollision(false)
        actor:SetActorTickEnabled(false)
    elseif point.checkpoint then
        actor:SetActorEnableCollision(false)
        actor:SetActorTickEnabled(false)
    end
    for _, field in ipairs(triggerFields) do
        if self:disableTrigger(actor[field], point.bell and field == "InteractionComp") then disabled = true end
    end
    if not after then return end
    if point.interface then
        local ok, component = pcall(function() return actor:GetCollisionComponent() end)
        if ok and self:disableTrigger(component) then disabled = true end
    end
    for _, field in ipairs(widgetFields) do
        local widget = unwrap(actor[field])
        if widget and (widget:IsA(self.widget) or widget:IsA(self.lazyWidget)) then
            mute(widget, self.scene)
            disabled = true
        end
    end
    if point.resource then
        for _, value in ipairs(actor:K2_GetComponentsByClass(self.niagara) or {}) do
            local component = unwrap(value)
            if component then mute(component, self.scene) end
        end
    end
    local regions = 0
    for _, value in ipairs(actor:K2_GetComponentsByClass(self.region) or {}) do
        local region = unwrap(value)
        if region then
            self:disableTrigger(region)
            mute(region, self.scene)
            regions = regions + 1
        end
    end
    if point.bell or point.chest then actor:SetActorTickEnabled(false) end
    return disabled or regions > 0, regions
end

return Mask
