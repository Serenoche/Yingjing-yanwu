-- Use the staged runtime on package.path. Set CHECKPOINT_RUNTIME for the original-map entry cover.
local time, frame, nextAddress = 0, 0, 0
local active = {}
local function noop() end
local function object(fields)
    nextAddress = nextAddress + 1
    local id = nextAddress
    fields.IsValid = function() return true end
    fields.GetAddress = function() return id end
    return fields
end

local function array()
    local size, values = 0, {}
    return setmetatable({
        GetArrayNum = function() return size end,
        Empty = function() size, values = 0, {} end,
    }, { __index = function(_, index) return values[index] end,
        __newindex = function(_, index, value)
            values[index], size = value, math.max(size, index)
        end })
end

local classA, classB, later = "/Test/EnemyA.EnemyA_C", "/Test/EnemyB.EnemyB_C", "/Test/Later.Later_C"
local entry = { id = "retry-target", stages = {
    { members = {{ classPath = classA }, { classPath = classA }, { classPath = classB }} },
    { members = {{ classPath = later }} },
} }
local libraryClass = object({})
local requests, classes, brokenLoader = {}, {}, false
local function markReady(path) classes[path] = object({}) end
local loader = object({
    MakeSoftClassPath = function(_, path) return path end,
    Conv_SoftClassPathToSoftClassRef = function(_, path) return path end,
    Conv_SoftClassReferenceToString = function(_, path) return path end,
    LoadAssetClass = function(_, context, path, callback, latent)
        assert(path == classA or path == classB)
        assert(callback == nil and latent.CallbackTarget == context and latent.ExecutionFunction == "None")
        assert(not requests[latent.UUID])
        requests[latent.UUID] = { path = path, pawn = context }
    end,
})
FName = function(name) return name end
StaticFindObject = function(path)
    if path == "/Script/Engine.ObjectLibrary" then return libraryClass end
    if path == "/Script/Engine.Default__KismetSystemLibrary" and not brokenLoader then return loader end
end
StaticConstructObject = function(class, owner)
    assert(class == libraryClass and owner == active.instance)
    return object({ Objects = array() })
end
local syncPreloads = 0
package.loaded.SpawnClass = {
    observeReady = function(path) return classes[path] end,
    preload = function() return { step = function()
        syncPreloads = syncPreloads + 1
        return true
    end } end,
}
for _, name in ipairs({ "CombatSpawn", "ChallengeSignals", "EncounterPlayerState", "EncounterCatalog", "StageFade",
    "EncounterEngage", "PlayerProfile", "ChallengeMedicine", "ArenaScenes", "LionArena", "JingYeMount",
    "ChiLianArena", "BattleMusic", "GameplayDifficulty", "BloodyPalaceMechanics", "DreamPalaceFormation",
    "BloodyPalaceProgress" }) do package.loaded[name] = {} end
package.loaded.ChallengeVictory = { close = noop }
package.loaded.ChallengeMenu = { close = noop, update = function() return false end }
package.loaded.PracticeHud = { close = noop }
package.loaded.PlayerProfile.id = function() return "test-profile" end
package.loaded.ArenaScenes.preset = function(scene) return scene end
package.loaded.TestArena = { getBell = noop }
package.loaded.BossLoadCover = { new = function() return { isOwned = function() return true end,
    close = function() return true end } end }

local Retry = require("RetryPreload")
local Challenge = require("Challenge")
local gameplay = {
    GetGameInstance = function(_, pawn) return pawn.instance end,
    GetRealTimeSeconds = function() return time end,
}
local system = { GetFrameCount = function() return frame end }
local function pawnIn(instance)
    local sceneWorld = object({})
    return object({ instance = instance, GetWorld = function() return sceneWorld end })
end
local function requestCount(pawn)
    local count = 0
    for _, request in pairs(requests) do if request.pawn == pawn then count = count + 1 end end
    return count
end

local function expectReferences(count)
    local refs = active.instance.ReferencedObjects
    assert(refs[1] == active.nativeReference)
    local owned, held = 0, 0
    for i = 2, refs:GetArrayNum() do
        if refs[i] then held, owned = held + refs[i].Objects:GetArrayNum(), owned + 1 end
    end
    assert(owned == (count and 1 or 0) and held == (count or 0))
end

local function travel(pawn)
    assert(pawn == active.pawn and active.run.reloadRequested and active.run.stageIndex == 1)
    active.reloaded = true
    active.run:close(true)
    active.newPawn = pawnIn(active.instance)
end
gameplay.OpenLevel = function(_, pawn) travel(pawn) end
package.loaded.StockCheckpoint = { open = function(_, pawn) travel(pawn) end }
package.loaded.TestArena.reload = function(_, pawn) travel(pawn) end

local function setUp(mode, source)
    time, frame, classes, requests, brokenLoader = 0, 0, {}, {}, false
    local nativeReference = object({})
    local instance = object({ ReferencedObjects = array(), LoadGame = function(_, slot, out)
        assert(slot == "RetrySlot" and not active.failLoad, "simulated load failure")
        out.ResultType, out.LevelName, out.GameModeOptions = 0, "TestMap", ""
    end })
    instance.ReferencedObjects[1] = nativeReference
    local scene = { id = "test", name = "Test", map = "TestMap", gameModeOptions = "", runtimeModule = "TestArena",
        originalPath = CHECKPOINT_RUNTIME and "/Game/TestMap" or nil }
    local victory = source == "victory"
    local run = setmetatable({ entry = entry, mode = mode, scene = scene, slot = "RetrySlot",
        stageIndex = victory and 2 or 1, status = victory and "won" or "ready",
        view = victory and "victory" or nil, bellOpen = not victory, bosses = {},
        clearStage = noop, checkpointLoadout = noop,
    }, Challenge)
    active = { instance = instance, nativeReference = nativeReference, run = run, pawn = pawnIn(instance) }
    return run, active.pawn
end

local function click(run, pawn)
    run:queueAction("retry")
    assert(run:updateMenuOnly(gameplay, system, pawn, time))
    assert(run.status == "resetting")
end

for _, mode in ipairs({ "challenge", "practice" }) do
    for _, source in ipairs({ "victory", "bell" }) do
        local run, pawn = setUp(mode, source)
        markReady(classA)
        click(run, pawn)
        assert(requestCount(pawn) == 1)
        expectReferences(1)
        time = 0.1
        assert(run:updateMenuOnly(gameplay, system, pawn, time) and not active.reloaded)
        time = 0.3
        assert(run:updateMenuOnly(gameplay, system, pawn, time) and active.reloaded)
        expectReferences(1)

        time, frame = 0, 1
        local cover
        if CHECKPOINT_RUNTIME then
            cover = require("BossEntryPreload").new(run, active.newPawn, active.newPawn:GetWorld())
            assert(not cover:update(gameplay, system, active.newPawn, active.newPawn:GetWorld()))
            local prior = syncPreloads
            frame = frame + 1
            assert(not cover:update(gameplay, system, active.newPawn, active.newPawn:GetWorld()))
            assert(syncPreloads == prior and requestCount(active.newPawn) == 1)
        else
            assert(not Retry.beforeSpawn(run, gameplay, active.newPawn))
        end
        assert(requestCount(active.newPawn) == 1)
        markReady(classB)
        time, frame = 0.05, frame + 1
        if cover then assert(cover:update(gameplay, system, active.newPawn, active.newPawn:GetWorld()))
        else assert(Retry.beforeSpawn(run, gameplay, active.newPawn)) end
        expectReferences(2)
        run:close()
        expectReferences()
    end
end

local run, pawn = setUp("challenge", "victory")
click(run, pawn)
assert(requestCount(pawn) == 2)
time = 0.3
assert(run:updateMenuOnly(gameplay, system, pawn, time) and active.reloaded)
time = 0
assert(not Retry.beforeSpawn(run, gameplay, active.newPawn))
time = 0.3
assert(Retry.beforeSpawn(run, gameplay, active.newPawn))
run:close()
expectReferences()

run, pawn = setUp("practice", "bell")
markReady(classA)
markReady(classB)
click(run, pawn)
assert(requestCount(pawn) == 0)
assert(run:updateMenuOnly(gameplay, system, pawn, time) and active.reloaded)
assert(Retry.beforeSpawn(run, gameplay, active.newPawn))
assert(requestCount(active.newPawn) == 0)
expectReferences(2)
run:close()
expectReferences()

run, pawn = setUp("challenge", "victory")
markReady(classA)
click(run, pawn)
time = 0.3
assert(run:updateMenuOnly(gameplay, system, pawn, time) and active.reloaded)
active.instance.ReferencedObjects[2] = nil
classes[classA] = nil
assert(not Retry.beforeSpawn(run, gameplay, active.newPawn))
assert(requestCount(active.newPawn) == 2)
expectReferences(0)
run:close(true) -- another travel cancels this attempt
expectReferences()

run, pawn = setUp("practice", "victory")
brokenLoader = true
click(run, pawn)
assert(not run.retryPreload and run:updateMenuOnly(gameplay, system, pawn, time) and active.reloaded)
expectReferences()

run, pawn = setUp("challenge", "victory")
markReady(classA)
click(run, pawn)
active.failLoad = true
time = 0.3
assert(not pcall(run.updateMenuOnly, run, gameplay, system, pawn, time))
run:fail("simulated load failure")
expectReferences()

run, pawn = setUp("practice", "bell")
markReady(classA)
click(run, pawn)
run.retryPreload.expires = -1
Retry.expire(run)
expectReferences()

print("PASS challenge and practice retry from victory and bell, first-stage scope, async handoff, fallback and cleanup")
