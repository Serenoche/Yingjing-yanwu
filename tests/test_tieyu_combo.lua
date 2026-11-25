-- Run with the staged 2.1.0 Scripts directory on package.path.
local sequence = 0
local function object()
    sequence = sequence + 1
    local id = sequence
    return {
        GetAddress = function() return id end,
        GetFName = function() return "Object" .. id end,
        IsValid = function(self) return not self.destroyed end,
        HasAnyFlags = function() return false end,
        IsActorBeingDestroyed = function(self) return self.destroyed end,
        K2_DestroyActor = function(self) self.destroyed = true end,
        K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end,
        K2_GetActorRotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end,
        IsAlive = function(self) return not self.dead end,
        GetAISpawner = function(self) return self.Spawner end,
        GetMobGroup = function(self) return self.MobGroup end,
    }
end

local world, player = object(), object()
package.loaded.SceneArena = { runtimeWorld = function() return world end }
package.loaded.CombatSpawn = { class = object }

local spawners, failAt = {}, nil
local ai = object()
function ai:SpawnActorDeferred(context)
    assert(context == player)
    if #spawners + 1 == failAt then return nil end
    local spawner = object()
    spawner.GetPawn = function(self) return self.SpawnedAI end
    spawner.GetOtherAliveMembersInGroup = function(self)
        local peers = {}
        for _, actor in ipairs(self.MobGroup:GetAliveMemberPawns()) do
            if actor ~= self.SpawnedAI then peers[#peers + 1] = actor end
        end
        return peers
    end
    spawners[#spawners + 1] = spawner
    return spawner
end
function ai:SetValueAsObjectByTag(board, key, actor)
    assert(key.TagName == "AI.BlackboardKey.Object.Vehicle")
    board.partner = actor
end
function ai:GetValueAsObjectByTag(board) return board.partner end

local boards, mathLibrary = object(), object()
function boards:GetBlackboard(actor) return actor.board end
function mathLibrary:MakeTransform() return {} end
function FName(name) return name end
function StaticFindObject(path)
    if path:find("Default__SGameAIFunctionLibrary", 1, true) then return ai end
    if path:find("Default__AIBlueprintHelperLibrary", 1, true) then return boards end
    if path:find("Default__KismetMathLibrary", 1, true) then return mathLibrary end
    assert(path == "/Script/SGameAI.MobGroup")
    return object()
end
function StaticConstructObject()
    local group, members = object(), {}
    function group:AddRuntimeMember(actor) members[actor] = true end
    function group:RemoveRuntimeMember(actor) members[actor] = nil end
    function group:GetAliveMemberPawns()
        local pawns = {}
        for actor in pairs(members) do
            if actor:IsAlive() then pawns[#pawns + 1] = actor end
        end
        return pawns
    end
    return group
end

local gameplay = { FinishSpawningActor = function(_, spawner)
    assert(not spawner.InitialSpawn and not spawner.ShouldSpawn and spawner.SpawnedAI == nil)
    return spawner
end }
local tie, yuu = { id = "BP_Monster_TieGui" }, { id = "BP_Monster_Yuu" }
local stage = { cooperation = "tieyu", members = { tie, yuu } }
local iron, jade = object(), object()
local combo = require("TieYuCombo")
iron.board = object()
assert(not combo.open({ members = { tie } }, { iron }, gameplay, player, 0, "duel", "lake"))
assert(#spawners == 0)

local session = assert(combo.open(stage, { iron, jade }, gameplay, player, 0, "group_forest_guardians", "night"))
assert(#spawners == 2 and iron:GetMobGroup() == jade:GetMobGroup() and not session.ready)
assert(iron:GetAISpawner():GetOtherAliveMembersInGroup()[1] == jade)
jade.board = object()
session:update(player, 0.1)
assert(not session.ready)
session:update(player, 0.25)
assert(session.ready and iron.board.partner == jade and jade.board.partner == iron)
session:close()
session:close()
assert(not iron.board.partner and not jade.board.partner and not iron.Spawner and not jade.MobGroup)
assert(not spawners[1]:IsValid() and not spawners[2]:IsValid() and iron:IsValid() and jade:IsValid())

stage.members = { yuu, tie }
session = assert(combo.open(stage, { jade, iron }, gameplay, player, 1, "gauntlet_muxiaokui", "lake"))
assert(session.ready and jade.board.partner == iron)
session:close()
failAt = #spawners + 2
assert(not combo.open(stage, { jade, iron }, gameplay, player, 2, "gauntlet_muxiaokui", "lake"))
assert(not jade.Spawner and not jade.MobGroup and not spawners[#spawners]:IsValid())
failAt, jade.board = nil, nil
session = assert(combo.open(stage, { jade, iron }, gameplay, player, 3, "gauntlet_muxiaokui", "lake"))
session:update(player, 11)
assert(session.closed and not iron.Spawner and not jade.MobGroup and not iron.board.partner)

print("TieYu preset combination lifecycle passed")
