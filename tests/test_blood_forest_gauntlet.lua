-- Run against the staged 2.1.0 checkpoint scripts with TEST_ROOT set.
local nextAddress, clock = 0, 0
local function object(fields)
    fields = fields or {}
    nextAddress = nextAddress + 1
    fields.address = nextAddress
    function fields:IsValid() return not self.destroyed end
    function fields:GetAddress() return self.address end
    return fields
end

local world = object()
local facing = { Pitch = 0, Yaw = 0, Roll = 0 }
local classes, actors, ready = {}, {}, {}
local rejectedClass
local function class(path)
    if not classes[path] then
        local cdo = object()
        classes[path] = object({ path = path, GetCDO = function() return cdo end })
    end
    return classes[path]
end

local function actor(kind, name, position)
    local value = object({ kind = kind, name = name, position = position })
    function value:GetFName() return { ToString = function() return self.name end } end
    function value:GetClass() return self.kind end
    function value:IsA(kind) return self.kind == kind end
    function value:GetWorld() return world end
    function value:GetOwner() return self.owner end
    function value:HasAnyFlags() return false end
    function value:IsActorBeingDestroyed() return self.destroyed == true end
    function value:K2_GetActorLocation() return self.position end
    function value:K2_GetActorRotation() return facing end
    function value:K2_DestroyActor() self.destroyed = true end
    function value:DeactivateWires() self.wiresReleased = true end
    function value:IsAlive() return not self.defeated end
    value.CapsuleComponent = object({ GetScaledCapsuleHalfHeight = function() return 100 end })
    value.AttributeSetBase = object({ Health = { CurrentValue = 99 }, Health_Max = { CurrentValue = 100 } })
    value.AbilitySystemComponent = object({ GetGameplayTagCount = function(_, tag)
        if tag.TagName == "CharacterState.Dead" then return value.defeated and 1 or 0 end
        if tag.TagName == "CharacterState.InCombat" then return value.engaged and 1 or 0 end
        return 1
    end })
    actors[#actors + 1] = value
    return value
end

local pawn = actor(nil, "Player")
pawn.IsAlive = nil -- Player survival is available through its attributes and death tag.
for _, name in ipairs({ "Shachi", "Shachi_Max", "UltimateCharge", "UltimateChargeCount", "SpiritShadow" }) do
    pawn.AttributeSetBase[name] = { CurrentValue = 17 }
end
local medicine = { CurrentTime = 3, CurrentLevel = 2 }
local backpack = object({ MedicineInfos = { ForEach = function(_, visit) visit("Medicine_Duration", medicine) end } })
local function array()
    return { GetArrayNum = function(self) return #self end,
        Empty = function(self) for index = #self, 1, -1 do self[index] = nil end end }
end
local instance = object({ ReferencedObjects = array() })
local expectedScene, reloaded
function instance:LoadGame(slot, result)
    assert(slot == expectedScene.checkpointSlot)
    result.ResultType, result.LevelName = 0, expectedScene.map
end
local native = object({ GetGameCycle = function() return 0 end, PBZActorTeleportTo = function(_, target, at)
    assert(target == pawn)
    target.position = at
    return true
end })
local engine = {
    ["/Script/Engine.ObjectLibrary"] = object(),
    ["/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary"] = native,
    ["/Script/ProjectPBZ.Default__PBZAbilityBlueprintLibrary"] = object(),
    ["/Script/Engine.Default__SubsystemBlueprintLibrary"] = object({ GetWorldSubsystem = function() return backpack end }),
    ["/Script/ProjectPBZ.PBZBackPackSubsystem"] = object(),
    ["/Script/Engine.Default__KismetMathLibrary"] = object({
        MakeTransform = function(_, position, rotation) return { position = position, rotation = rotation } end,
        FindLookAtRotation = function() return facing end,
    }),
    ["/Script/NavigationSystem.Default__NavigationSystemV1"] = object({
        K2_ProjectPointToNavigation = function(_, _, at, out)
            out.X, out.Y, out.Z = at.X, at.Y, at.Z
            return true
        end,
        FindPathToLocationSynchronously = function(_, _, from, to)
            return object({ IsPartial = function() return false end, PathPoints = { from, to } })
        end,
    }),
    ["/Script/SGameAI.Default__SGameAIFunctionLibrary"] = object({
        SpawnActorDeferred = function(_, _, kind, transform)
            if kind.path == rejectedClass then return end
            return actor(kind, kind.path .. "_" .. nextAddress, transform.position)
        end,
    }),
}
StaticFindObject = function(path) return engine[path] or (ready[path] and classes[path]) end
StaticConstructObject = function() return object({ Objects = array() }) end
FName = function(value) return value end
RegisterHook = function() return 1, 2 end
UnregisterHook = function() end
FindAllOf = function(kind)
    if kind == "Actor" then return actors end
    assert(kind == "W_BossDead_Red_C")
    return { object({ IsActivated = function() return true end }) }
end

local function actorsOfClass(_, _, expectedWorld, kind)
    assert(expectedWorld == world)
    local result = {}
    for _, value in ipairs(actors) do
        if value:IsValid() and value.kind == kind then result[#result + 1] = value end
    end
    return result
end
package.loaded.SceneArena = {
    runtimeWorld = function(value) return value:GetWorld() end,
    actorIsInWorld = function(value, expected) return value and value:IsValid() and value:GetWorld() == expected end,
    actorsOfClass = actorsOfClass,
}
package.loaded.StockBellArena = { floorAt = function(_, _, at) return at.Z end }
local function resolve(path)
    if ready[path] == false then return nil, "class still loading" end
    ready[path] = true
    return class(path)
end
package.loaded.SpawnClass = { resolve = resolve,
    observeReady = function(path)
        if not ready[path] then return end
        local kind = class(path)
        return kind, nil, { cdo = kind:GetCDO():GetAddress() }
    end,
    preload = function(members)
    return {
        resolve = function(_, path) return resolve(path) end,
        step = function()
            for _, member in ipairs(members) do if not resolve(member.classPath) then return false end end
            return true
        end,
    }
end }
package.loaded.AsyncClassLoad = { request = function() end }
package.loaded.CombatSpawn = {
    finish = function(_, _, value, transform) value.position = transform.position; return value, 25 end,
    challengeAI = function() end,
}
package.loaded.EncounterEngage = {
    start = function(value) value.engaged = true; return true end,
    linkGroup = function() end,
}
package.loaded.StageFade = { new = function(_, _, now)
    return { hold = 0.7, blackAt = now, update = function(self) return self.revealing and "done" or "black" end,
        canReveal = function() return true end, reveal = function(self) self.revealing = true end,
        close = function() end }
end }
package.loaded.ChallengeMenu = { update = function() return false end, close = function() end }
package.loaded.PracticeHud = { update = function() end, close = function() end }
package.loaded.PracticeBossInfo = { update = function() end, close = function() end }
local settlement
package.loaded.ChallengeVictory = {
    open = function(_, _, report, action) settlement = { report = report, action = action }; return true end,
    update = function() return settlement ~= nil end,
    close = function() settlement = nil end,
}
package.loaded.StockCheckpoint = { open = function(_, _, scene, result)
    assert(scene == expectedScene and result.LevelName == scene.map)
    reloaded = true
end }
local gameplay = {
    GetRealTimeSeconds = function() return clock end,
    GetGameInstance = function() return instance end,
    IsGamePaused = function() return false end,
    GetPlayerController = function() end,
    GetActorOfClass = function(self, player, kind) return actorsOfClass(self, player, world, kind)[1] end,
}
local system = {
    GetFrameCount = function() return math.floor(clock * 100) end,
    LineTraceSingle = function(_, _, top, _, _, _, _, _, hit)
        hit.ImpactPoint, hit.ImpactNormal = { X = top.X, Y = top.Y, Z = top.Z - 150 }, { Z = 1 }
        return true
    end,
    LineTraceSingleForObjects = function() return false end,
}

local Challenge = require("Challenge")
local Signals = require("ChallengeSignals")
local Arena = require("XiguBossArena")
local Scenes = require("ArenaScenes")
local Catalog = require("EncounterCatalog")
local PlayerState = require("EncounterPlayerState")

local function makeStockMarkers(scene)
    local base = "/PBZCombatAsset/ActorData/Mobs/065_ChiLian_P2/"
    local markers = {}
    for index = 1, 5 do
        local name, part, at
        if index == 1 then
            name, part, at = scene.nativeSnake.center, "BP_ChiLian_P2_Center", scene.chiLianUltimate.center
        else
            local item = scene.nativeSnake.spawners[index - 1]
            name, part, at = item.name, "BP_ChiLian_CA_SnakeSpawner", item.ground
        end
        local marker = actor(class(base .. part .. "." .. part .. "_C"), name, at)
        marker.Arrow = object({ K2_GetComponentLocation = function() return at end })
        function marker:DespawnSnake() self.SnakeActor = nil end
        markers[index] = marker
    end
    return markers
end

local function runGauntlet(sceneId, entryId, mode, phaseTwoCount, losePhaseTwo)
    local scene = Scenes.get(sceneId)
    expectedScene, reloaded = scene, false
    pawn.position, pawn.engaged = scene.entryGround, false
    local markers = sceneId == "forest_silk_tree" and makeStockMarkers(scene) or nil
    local entry = assert(Catalog.resolve(entryId))
    if entryId == "gauntlet_yucong" then
        -- The first fight is now a separate map. Exercise the two authored
        -- forest phases here, including the same-world trio transition.
        entry = setmetatable({ stages = { entry.stages[2], entry.stages[3] } }, { __index = entry })
    end
    local run = Challenge.new(entry, 0, TEST_ROOT, 0, nil, {
        resetSlot = scene.checkpointSlot, sceneId = sceneId, mode = mode,
        cyclePrefix = "PBZArenaIntegratedCycle",
        selectCheckpoint = function(slot, cycle) return slot == scene.checkpointSlot and cycle == 0 end,
    })
    run.difficulty = { update = function() return true end }
    if mode == "practice" then
        run.practice = { state = { ai = false }, update = function() return true end,
            getState = function(self) return self.state end }
    end
    assert(run:spawnStage(gameplay, system, pawn), run.spawnWaitReason)
    local first = run.boss
    assert(#run.bosses == 1)
    run.pawnAddress, run.startedAt, run.awake, run.status = pawn:GetAddress(), 20, true, "combat"
    run.observer = Signals.newEncounter(pawn, run.bosses, nil, false)
    first.engaged = true
    local baseline = PlayerState.capture(pawn)
    local historyBefore = #run.history
    local blockedClass = run.entry.stages[2].members[1].classPath
    ready[blockedClass] = false
    local function tick(at)
        clock = at
        run:tick(gameplay, system, pawn, at)
    end
    tick(21)
    first.defeated = true
    tick(22)
    assert(run.status == "transition" and run.stageIndex == 1 and #run.history == historyBefore and not settlement)
    for frame = 1, 10 do tick(22 + frame * 0.1) end
    assert(run.stageIndex == 2 and first.destroyed and not run.boss and not settlement)
    ready[blockedClass] = true
    if losePhaseTwo then
        local spawnStage = run.spawnStage
        function run:spawnStage(...)
            if not spawnStage(self, ...) then return false end
            self.boss.position = { X = self.boss.position.X, Y = self.boss.position.Y, Z = scene.combatHeight.min - 500 }
            self.boss.defeated = true
            return true
        end
        local fade = run.stageFade
        tick(24)
        assert(run.status == "resetting" and run.reloadAt == 24 and not fade.revealing)
        assert(run.message:find("第 2 阶段", 1, true) and run.message:find("地形异常", 1, true))
        assert(#run.history == historyBefore and not settlement)
        tick(25)
        assert(reloaded and run.stageIndex == 1 and run:menuState(true).recoveryMessage == run.bossRecoveryMessage)
        print("PASS second-stage terrain death before reveal restarts at stage one")
        return
    end
    local nextFrame = 11
    if phaseTwoCount > 1 then
        local before = #actors
        rejectedClass = run.entry.stages[2].members[2].classPath
        tick(24)
        rejectedClass = nil
        assert(not run.boss and #actors == before + 1 and actors[#actors].destroyed,
            "A partially spawned group must be cleaned up before retry")
        nextFrame = 21
    end
    for frame = nextFrame, 50 do
        tick(22 + frame * 0.1)
        if not run.transitionStep then break end
    end
    assert(run.status == "combat" and run.stageIndex == 2 and #run.bosses == phaseTwoCount, run.message)
    assert(run.startedAt == 20 and Arena.inside(pawn, scene) and PlayerState.compare(baseline, PlayerState.capture(pawn)))
    assert(run.observer.stageCount == 2 and run.observer.records[1].actor == nil)
    for index, member in ipairs(run.entry.stages[2].members) do
        local at, preferred = run.bosses[index].position, scene.spawnPoints[scene.bossSpawnIndex[member.id]]
        assert(at.X == preferred.X and at.Y == preferred.Y, member.id)
    end
    local summon
    if markers then
        local session = run.chiLianArena
        assert(session.center == markers[1] and #session.actors == 0 and not session:owns(markers[1]))
        summon = actor(session.snakeClass, "NativeSummonedSnake", markers[2].position)
        markers[2].SnakeActor = summon
    end

    for index = 1, phaseTwoCount - 1 do
        run.bosses[index].defeated = true
        tick(28 + index * 0.1)
        assert(run.status == "combat" and #run.history == historyBefore and not settlement)
        -- Native may retire a defeated group member before its partners fall.
        run.bosses[index]:K2_DestroyActor()
    end
    run.bosses[phaseTwoCount].defeated = true
    tick(29)
    assert(run.status == "won" and run.view == "victory")
    tick(32)
    assert(settlement and settlement.report == run.report)
    if mode == "challenge" then
        assert(#run.history == historyBefore + 1 and run.report.completedStages == 2 and run.report.timeSeconds == 9)
        assert(run.report.reportFile)
    else
        assert(#run.history == historyBefore and run.report.mode == "practice")
    end
    tick(32.5)
    assert(settlement and #run.history == historyBefore + (mode == "challenge" and 1 or 0))
    settlement.action("retry")
    tick(33)
    assert(run.status == "resetting" and run.reloadAt == 33)
    tick(34)
    assert(reloaded and run.reloadRequested and run.stageIndex == 1 and not run.observer and not run.chiLianCleanupError)
    if markers then
        assert(summon.destroyed and not markers[2].SnakeActor)
        for _, marker in ipairs(markers) do
            assert(marker:IsValid())
            marker:K2_DestroyActor()
        end
    end
    require("RetryPreload").close(run)
    assert(#instance.ReferencedObjects == 0)
    print("PASS " .. entryId .. " " .. mode .. ": wait for phase spawn, preserve resources, settle once and retry")
end

runGauntlet("forest_silk_tree", "gauntlet_chilian", "challenge", 1)
runGauntlet("forest_silk_tree_yucong", "gauntlet_yucong", "challenge", 3)
runGauntlet("forest_silk_tree_yucong", "gauntlet_yucong", "practice", 3)
runGauntlet("forest_silk_tree", "gauntlet_chilian", "challenge", 1, true)
