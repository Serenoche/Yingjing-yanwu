-- The final-house set occupies a separate high-altitude layer of Duanhun.
-- All mutations are scoped to the sealed training profile and that set.
local ClosedArena = {}

local ANCHOR = { X = -192742.284, Y = -113848.174, Z = 4500046.15 }
local FACING = { Pitch = 0, Yaw = -77.1263388, Roll = 0 }
local CAMERA = { Pitch = 0, Yaw = 267.873657, Roll = 0 }
local BELL = { "BP_BrokenBell_C", "BP_BrokenBell_C_UAID_E89C25A751207AE802_1375855971" }
local BELL_ID = "BrokenBell_TheEnd01"
local STORY_VOLUMES = {
    { "BP_AISpawnerTriggerVolume_C", "BP_AISpawnerTriggerVolume_C_UAID_E89C25A75120D0DD02_1115775492", -192974.77, -117840.16, 4499903.5 },
    { "BP_MobDomain_C", "BP_MobDomain_C_UAID_E89C25A75120D0DD02_1115747491", -192860.73, -117902.836, 4499902.5 },
}
local STORY_CONTROLLERS = {
    { "BP_FlowActor_C", "BP_FlowActor_C_UAID_E89C25A75120D0DD02_1115780495", -193055.05, -118846.414, 4499998 },
    { "BP_NPCSpawner_C", "BP_NPCSpawner_C_UAID_BCFCE707898301DD02_1353401098", -193034.14, -117493.93, 4500004 },
    { "BP_NPCSpawner_C", "BP_NPCSpawner_C_UAID_E89C25A75120D1DD02_1710250698", -193381.48, -120175.234, 4501173 },
    { "BP_AISpawner_C", "BP_AISpawner_C_UAID_E89C25A75120D0DD02_1115777493", -193036.5, -117948.414, 4499905 },
    { "BP_AISpawner_C", "BP_AISpawner_C_UAID_E89C25A75120D0DD02_1115779494", -193036.5, -118716.62, 4499905 },
}
local STORY_CHARACTERS = { "BP_NPC_ZuoShang_C", "BP_Monster_ZuoShang_Ending_C", "BP_Monster_ZuoShang_P2_C" }
local NPC_STORY_FLOWS = { BPF_ZuoShang_TheEnd_Chuchang = true, BPF_BigBoss_ZuoShang_Roof = true }
local NO_COLOR = { R = 0, G = 0, B = 0, A = 0 }

local activeWorld, activePawn, ready, nextScan
local restore, handled = {}, {}

local function valid(object)
    return object ~= nil and object:IsValid()
end

local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "缺少原生接口：" .. path)
    return object
end

local function inHouse(position)
    return math.abs(position.X - ANCHOR.X) <= 12000 and math.abs(position.Y - ANCHOR.Y) <= 12000
        and math.abs(position.Z - ANCHOR.Z) <= 3500
end

function ClosedArena.reset()
    for index = #restore, 1, -1 do pcall(restore[index]) end
    restore, handled = {}, {}
    activeWorld, activePawn, ready, nextScan = nil, nil, false, 0
end

local function findExact(spec)
    local atLocation
    for _, actor in ipairs(FindAllOf(spec[1]) or {}) do
        if valid(actor) and actor:GetWorld():GetAddress() == activeWorld then
            if actor:GetFName():ToString():sub(1, #spec[2]) == spec[2] then return actor end
            if spec[3] then
                local p = actor:K2_GetActorLocation()
                if math.abs(p.X - spec[3]) <= 20 and math.abs(p.Y - spec[4]) <= 20
                    and math.abs(p.Z - spec[5]) <= 20 then atLocation = actor end
            end
        end
    end
    return atLocation
end

local function findBell()
    local exact = findExact(BELL)
    if valid(exact) then return exact end
    for _, class in ipairs({ BELL[1], "MelodiousBell" }) do
        for _, actor in ipairs(FindAllOf(class) or {}) do
            if valid(actor) and actor:GetWorld():GetAddress() == activeWorld and inHouse(actor:K2_GetActorLocation()) then
                local id = actor.BellID
                if id and (type(id) == "string" and id or id:ToString()) == BELL_ID then return actor end
            end
        end
    end
end

local function disableBell()
    local bell = findBell()
    local sphere = bell and bell.InteractionComp
    if not valid(sphere) then return false end
    local mode = sphere:GetCollisionEnabled()
    if mode ~= 0 then
        restore[#restore + 1] = function()
            if valid(sphere) then sphere:SetCollisionEnabled(mode) end
        end
        sphere:SetCollisionEnabled(0)
        print("[PBZTestArenaNative] Old-house bell interaction disabled: " .. bell:GetFName():ToString() .. "\n")
    end
    return sphere:GetCollisionEnabled() == 0
end

local function hideInteractions(pawn)
    local tag = { TagName = FName("Flow.HideInteract") }
    local abilities = required("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
    local asc = abilities:GetAbilitySystemComponent(pawn)
    assert(valid(asc), "等待测试角色能力组件")
    if asc:GetGameplayTagCount(tag) > 0 then return end
    local library = required("/Script/ProjectPBZ.Default__PBZAbilityBlueprintLibrary")
    assert(library:AddLooseGameplayTag(pawn, tag, false), "无法关闭场景交互")
    restore[#restore + 1] = function()
        if valid(pawn) then library:RemoveLooseGameplayTag(pawn, tag, false) end
    end
    assert(asc:GetGameplayTagCount(tag) > 0, "场景交互限制回读失败")
    print("[PBZTestArenaNative] Old-house native interaction tag enabled\n")
end

local function removeStoryActor(actor, npcSpawner)
    local id = actor:GetAddress()
    if handled[id] then return end
    actor:SetActorEnableCollision(false)
    local flow = actor.BP_PBZFlowComponent
    if valid(flow) then
        flow.bAutoStartRootFlow = false
        if valid(flow:GetRootFlowInstance()) then
            flow:FinishRootFlow(flow.RootFlow, 1) -- Abort the authored flow.
            assert(not valid(flow:GetRootFlowInstance()), "剧情流程关闭失败")
        end
        flow:PBZUnregister()
    end
    if npcSpawner then
        for _, sphere in ipairs({ actor.SpawnSphere, actor.InteractSphere }) do
            if valid(sphere) then sphere:SetCollisionEnabled(0) end
        end
        actor:Despawn()
    end
    local name = actor:GetFName():ToString()
    actor:K2_DestroyActor()
    handled[id] = true
    print("[PBZTestArenaNative] Removed old-house story actor: " .. name .. "\n")
end

local function isNpcStoryFlow(flow)
    if not valid(flow) then return false end
    local root = flow.RootFlow
    return valid(root) and NPC_STORY_FLOWS[root:GetFName():ToString()] == true
end

local function removeNpcStorySpawner(spawner)
    if valid(spawner) and isNpcStoryFlow(spawner.BP_PBZFlowComponent) then
        removeStoryActor(spawner, true)
    end
end

local function disableStoryEntry(actor, shape)
    if not valid(actor) or not valid(shape) or actor:GetWorld():GetAddress() ~= activeWorld then return end
    local p = actor:K2_GetActorLocation()
    if math.abs(p.X + 193003.6) > 8 or math.abs(p.Y + 115937.52) > 8 or math.abs(p.Z - 4499909) > 8 then return end
    if shape:GetCollisionProfileName():ToString() ~= "Profile_NpcFlowInteract" then return end
    local mode = shape:GetCollisionEnabled()
    if mode == 0 then return end
    shape:SetCollisionEnabled(0)
    assert(shape:GetCollisionEnabled() == 0, "左殇登场区域关闭失败")
    restore[#restore + 1] = function()
        if valid(shape) then shape:SetCollisionEnabled(mode) end
    end
    print("[PBZTestArenaNative] Disabled left-hand story entry overlap: " .. actor:GetFName():ToString() .. "\n")
end

local function suppressStory(keep)
    -- The two NPC flows register a native overlap box at this same authored
    -- point. Stop the box even when its streamed controller is not enumerable.
    for _, node in ipairs(FindAllOf("SetExcuteType_C") or {}) do
        if valid(node) then disableStoryEntry(node.ShapeActor, node.ShapeComponent) end
    end
    for _, actor in ipairs(FindAllOf("TriggerBox") or {}) do
        if valid(actor) then disableStoryEntry(actor, actor.CollisionComponent) end
    end
    for _, spec in ipairs(STORY_VOLUMES) do
        local trigger = findExact(spec)
        if valid(trigger) and trigger:IsEnabled() then
            restore[#restore + 1] = function()
                if valid(trigger) then trigger:SetEnabled(true) end
            end
            trigger:SetEnabled(false)
            assert(not trigger:IsEnabled(), "左殇剧情触发区关闭失败")
            print("[PBZTestArenaNative] Disabled old-house story volume: " .. trigger:GetFName():ToString() .. "\n")
        end
    end

    -- These are authored story controllers/spawners, not the house or its floor.
    for _, spec in ipairs(STORY_CONTROLLERS) do
        local actor = findExact(spec)
        if valid(actor) then removeStoryActor(actor, spec[1] == "BP_NPCSpawner_C") end
    end
    -- These NPC sources live in a streamed cell. Match their exact root flow
    -- even when the streamed object's generated name or outer world differs.
    for _, flow in ipairs(FindAllOf("BP_PBZFlowComponent_C") or {}) do
        if isNpcStoryFlow(flow) then
            local owner = flow:GetOwner()
            if valid(owner) and inHouse(owner:K2_GetActorLocation()) and not (keep and keep(owner)) then
                removeStoryActor(owner, true)
            end
        end
    end
    for _, spawner in ipairs(FindAllOf("NPCSpawner") or {}) do
        if valid(spawner) and inHouse(spawner:K2_GetActorLocation()) and not (keep and keep(spawner)) then
            removeNpcStorySpawner(spawner)
        end
    end
    for _, class in ipairs(STORY_CHARACTERS) do
        for _, actor in ipairs(FindAllOf(class) or {}) do
            if valid(actor) and actor:GetWorld():GetAddress() == activeWorld and inHouse(actor:K2_GetActorLocation())
                and not (keep and keep(actor)) then
                if class == "BP_NPC_ZuoShang_C" then
                    local spawner = actor.NPCSpawner
                    if not valid(spawner) then spawner = actor:GetAttachParentActor() end
                    if valid(spawner) and inHouse(spawner:K2_GetActorLocation()) then
                        removeNpcStorySpawner(spawner)
                    end
                end
                if valid(actor) then removeStoryActor(actor) end
            end
        end
    end
end

local function anchorReady(pawn)
    local system = required("/Script/Engine.Default__KismetSystemLibrary")
    local top = { X = ANCHOR.X, Y = ANCHOR.Y, Z = ANCHOR.Z - 35 }
    local bottom = { X = ANCHOR.X, Y = ANCHOR.Y, Z = ANCHOR.Z - 220 }
    local hit = {}
    local found = system:LineTraceSingle(pawn, top, bottom, 0, false, {}, 0, hit, true, NO_COLOR, NO_COLOR, 0)
    return found and hit.ImpactPoint and hit.ImpactNormal and hit.ImpactNormal.Z >= 0.65
        and ANCHOR.Z - hit.ImpactPoint.Z >= 55 and ANCHOR.Z - hit.ImpactPoint.Z <= 185
end

function ClosedArena.update(pawn, controller, worldAddress, now, keep, allowBell)
    local position = pawn:K2_GetActorLocation()
    if not inHouse(position) then
        if activeWorld then ClosedArena.reset() end
        return nil, "等待读入故屋幻景场景"
    end
    local pawnAddress = pawn:GetAddress()
    if activeWorld ~= worldAddress or activePawn ~= pawnAddress then
        ClosedArena.reset()
        activeWorld, activePawn = worldAddress, pawnAddress
    end

    if not ready then
        if not anchorReady(pawn) then return nil, "等待故屋幻景地面加载" end
        suppressStory(keep)
        if not allowBell then
            hideInteractions(pawn)
            disableBell()
        end
        local dx, dy, dz = position.X - ANCHOR.X, position.Y - ANCHOR.Y, position.Z - ANCHOR.Z
        if dx * dx + dy * dy > 25^2 or math.abs(dz) > 80 then
            local library = required("/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary")
            if not library:PBZActorTeleportTo(pawn, ANCHOR, FACING, false, false) then
                return nil, "读档后无法返回故屋幻景"
            end
            controller:SetControlRotation(CAMERA)
        end
        nextScan, ready = now + 1, true
    elseif now >= nextScan then
        suppressStory(keep)
        if not allowBell then
            hideInteractions(pawn)
            disableBell()
        end
        nextScan = now + 1
    end
    return true
end

return ClosedArena
