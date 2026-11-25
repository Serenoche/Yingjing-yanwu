local StoryActors = require("ArenaItemActors")
local Items = {}

local PENDING = 0x08023600
local PICKUP = "/Script/ProjectPBZ.PBZPickupActor"
local INTERACT = "/Script/ProjectPBZ.PBZInteractComponent"
local ACTOR = "/Script/Engine.Actor"
local DESTROY_RETRY_SECONDS = 1
local itemClasses = {
    BP_Chest_C = "chest",
    BP_FlowInteract_MemoryFlower_C = "collectible",
    BP_HangingGift_C = "collectible",
    BP_MultiChaosSpawner_HangingGift_C = "collectible",
    BP_Rubbish_C = "container",
    BP_Rubbish_A_C = "container",
    BP_Rubbish_b_C = "container",
    BP_Rubbish_C_C = "container",
}
local pickupClass, session, hookInstalled

local function valid(object)
    local kind = type(object)
    return (kind == "table" or kind == "userdata") and type(object.IsValid) == "function" and object:IsValid()
end

local function unwrap(value)
    if valid(value) then return value end
    local ok, object = pcall(function() return value:get() end)
    if ok and valid(object) then return object end
end

local function name(object)
    local value = object:GetFName()
    return type(value) == "string" and value or value:ToString()
end

function Items.classCategory(class, short)
    if itemClasses[short] then return itemClasses[short] end
    if not valid(pickupClass) then
        pickupClass = StaticFindObject(PICKUP)
        assert(valid(pickupClass), "缺少原版拾取物类型")
    end
    if class:IsChildOf(pickupClass) then return "pickup" end
end

function Items.isStoryProp(actor, short, scene)
    local authored = StoryActors[short]
    local corpses = scene and scene.hiddenStoryProps
    local cinematic = short == "SkeletalMeshActor" and scene and scene.cinematicProps
    if not (authored or corpses or cinematic) then return false end
    local id = name(actor)
    local corpse = corpses and corpses[id]
    return (authored and authored[id]) or (corpse and corpse.className == short)
        or (cinematic and cinematic[id]) or false
end

function Items.storyPropClasses(scene)
    local classes = {}
    for class in pairs(StoryActors) do classes[class] = true end
    for _, prop in pairs(scene and scene.hiddenStoryProps or {}) do classes[prop.className] = true end
    if scene and scene.cinematicProps then classes.SkeletalMeshActor = true end
    return classes
end

local function live(actor)
    return valid(actor) and not actor:HasAnyFlags(PENDING) and not actor:IsActorBeingDestroyed()
end

local function suppressed(actor)
    return actor.bHidden == true and not actor:GetActorEnableCollision() and not actor:IsActorTickEnabled()
end

function Items.suppress(actor)
    if not live(actor) then return false end
    if not suppressed(actor) then
        actor:SetActorEnableCollision(false)
        actor:SetActorHiddenInGame(true)
        actor:SetActorTickEnabled(false)
        assert(suppressed(actor), "场景物品未停用：" .. name(actor))
    end
    return true
end

local function belongsTo(tx, actor)
    local level = actor:GetLevel()
    local world = valid(level) and level.OwningWorld
    return valid(world) and world:GetAddress() == tx.world
end

local function queue(tx, actor)
    if not valid(actor) then return end
    local class = actor:GetClass()
    local address = class:GetAddress()
    local entry = tx.classes[address]
    if not entry then
        local short = name(class)
        entry = { short = short, category = Items.classCategory(class, short) }
        tx.classes[address] = entry
    end
    local category = entry.category
    if not category and Items.isStoryProp(actor, entry.short, tx.scene) then category = "story" end
    if not category or not live(actor) or not belongsTo(tx, actor) then return end
    tx.pending[actor:GetAddress()] = { actor = actor, name = name(actor), category = category }
end

local function remove(tx, item, interaction)
    local actor = item.actor
    if not live(actor) or name(actor) ~= item.name or not belongsTo(tx, actor) then return end
    if interaction then interaction:RemovePotentialInteract(actor) end
    actor:K2_DestroyActor()
    if not live(actor) then return "removed" end
    -- World Partition can retain actors after Destroy during entry. Verify that
    -- the item is inert before deferring its next destruction attempt.
    assert(interaction, "等待物品交互缓存可用：" .. item.name)
    return Items.suppress(actor) and "deferred" or "removed"
end

function Items.reset()
    session = nil
end

-- Both entry points call this on the game thread, after private-world admission.
-- BeginPlay can run while a partition is being added. Queue its actors and
-- destroy them from the arena update, outside the engine's BeginPlay callback.
function Items.update(gameplay, pawn, world, scene)
    if not hookInstalled then
        RegisterBeginPlayPostHook(function(parameter)
            local tx = session
            if not tx then return end
            local ok, failure = pcall(function() queue(tx, unwrap(parameter)) end)
            if not ok then
                if tx.hookError ~= failure then
                    print("[PBZArenaItems] BeginPlay error: " .. tostring(failure) .. "\n")
                end
                tx.hookError = failure
                tx.swept = false
            end
        end)
        hookInstalled = true
    end
    if not session or session.world ~= world:GetAddress() or session.scene ~= scene then
        session = { world = world:GetAddress(), scene = scene, pending = {}, classes = {} }
    end
    local tx = session
    if not tx.swept then
        local base = StaticFindObject(ACTOR)
        assert(valid(base), "缺少场景实体类型")
        local actors = {}
        gameplay:GetAllActorsOfClass(pawn, base, actors)
        for _, value in ipairs(actors) do queue(tx, unwrap(value)) end
        tx.swept = true
    end

    if tx.remaining == 0 and next(tx.pending) == nil then return true end
    local now = gameplay:GetRealTimeSeconds(pawn)
    local interactionClass = StaticFindObject(INTERACT)
    local interaction = valid(interactionClass) and unwrap(pawn:GetComponentByClass(interactionClass))
    local removed = { chest = 0, collectible = 0, container = 0, pickup = 0, story = 0 }
    local pending = tx.pending
    tx.pending = {}
    local problem
    for address, item in pairs(pending) do
        if session ~= tx then return nil, "场地已切换" end
        if item.retryAt and now < item.retryAt then
            tx.pending[address] = item
        else
            local ok, result = pcall(remove, tx, item, interaction)
            if not ok then
                item.retryAt = nil
                tx.pending[address] = item
                problem = problem or result
            elseif result == "deferred" then
                item.retryAt = now + DESTROY_RETRY_SECONDS
                tx.pending[address] = item
            elseif result == "removed" then
                removed[item.category] = removed[item.category] + 1
            end
        end
    end
    local remaining, blocked = 0, 0
    for _, item in pairs(tx.pending) do
        remaining = remaining + 1
        if not item.retryAt then blocked = blocked + 1 end
    end
    local total = removed.chest + removed.collectible + removed.container + removed.pickup + removed.story
    if tx.remaining ~= remaining or tx.blocked ~= blocked or total > 0 then
        print(("[PBZArenaItems] scene=%s removed=%d chest=%d collectible=%d container=%d pickup=%d story=%d pending=%d deferred=%d blocked=%d\n")
            :format(scene.id, total, removed.chest, removed.collectible, removed.container, removed.pickup, removed.story,
                remaining, remaining - blocked, blocked))
    end
    tx.remaining, tx.blocked = remaining, blocked
    if blocked > 0 then return nil, problem or "正在清理补载的场景物品" end
    return true
end

return Items
