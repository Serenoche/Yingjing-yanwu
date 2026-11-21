-- Set TEST_ROOT to a fresh, disposable directory with an ArenaPreferences subdirectory.
local path = assert(TEST_ROOT) .. "/ArenaPreferences/PBZLoadout.tsv"
local marker = TEST_ROOT .. "/ArenaPreferences/.PBZTestArenaArenaPrefs-owner"
local existing = io.open(marker, "rb")
if existing then
    existing:close()
    error("TEST_ROOT must be a fresh fixture")
end
local owner = assert(io.open(marker, "wb"))
assert(owner:write("7d5ad307-d21c-47eb-9584-493443190984"))
assert(owner:close())

local function equipment(main)
    return { version = 1, mainWeapons = { main, false }, shadowWeapons = { false, false },
        accessories = { false, false, false, false, false, false }, medicines = { false, false } }
end

local pawn = { equipment = equipment("Default"), IsValid = function() return true end,
    GetAddress = function() return 1 end }
local captures, applies, elapsed = 0, 0, 0
local unavailable, incomplete = false, false
local originalClock = os.clock
os.clock = function() return elapsed end
package.loaded.ArenaLoadout = {
    capture = function(player)
        captures = captures + 1
        if incomplete then return nil, "waiting: native slots unavailable" end
        return player.equipment
    end,
    apply = function(player, selection)
        applies = applies + 1
        if unavailable then return false, "unavailable: missing item" end
        player.equipment = selection
        return true
    end,
}

local Memory = require("ArenaLoadoutMemory")
local Restore = require("ArenaLoadoutRestore")
local private = true
local function open(projected)
    return assert(Memory.new(path, function() return private end, nil, projected))
end
local function savedMain()
    local stored = assert(Memory.checkpointSelection(path))
    return stored.mainWeapons[1]
end
local function advance(memory)
    for _ = 1, 60 do
        elapsed = elapsed + .25
        assert(memory:update(pawn))
    end
end

local memory = open()
assert(memory:remember(pawn) == nil)
advance(memory)
assert(captures == 0 and applies == 0 and Memory.checkpointSelection(path) == nil,
    "the initial preset must not be sampled or saved outside the bell")
pawn.equipment = equipment("BellChoice")
assert(memory:remember(pawn) and captures == 1 and savedMain() == "BellChoice")
pawn.equipment = equipment("ChangedDuringCombat")
advance(memory)
memory:close()
assert(captures == 1 and applies == 0 and savedMain() == "BellChoice",
    "combat and teardown must keep the bell selection")

memory = open()
assert(memory:update(pawn) and pawn.equipment.mainWeapons[1] == "BellChoice" and applies == 1)
advance(memory)
assert(captures == 1 and applies == 1, "a completed slot restore must stay idle")
memory:close()

memory = open(Restore.checkpointWire(pawn.equipment))
assert(memory:update(pawn) and captures == 2 and applies == 1)
advance(memory)
assert(captures == 2 and applies == 1, "native checkpoint readback must only run on admission")
memory:close()

unavailable = true
memory = open()
assert(not memory:update(pawn))
assert(memory:remember(pawn) == nil and captures == 2)
elapsed = elapsed + 12.5
assert(memory:update(pawn))
pawn.equipment = equipment("Replacement")
advance(memory)
assert(captures == 2 and savedMain() == "BellChoice", "timeout must keep the last bell file")
private = false
assert(memory:remember(pawn) == false and captures == 2)
private, incomplete = true, true
assert(memory:remember(pawn) == false and savedMain() == "BellChoice")
incomplete = false
assert(memory:remember(pawn) and savedMain() == "Replacement")
memory:close()

unavailable = false
assert(os.rename(path, path .. ".fixture-primary"))
memory = open()
assert(memory:update(pawn) and pawn.equipment.mainWeapons[1] == "BellChoice")
advance(memory)
memory:close()
assert(io.open(path, "rb") == nil, "recovering a backup can wait for the bell to rewrite the primary")

os.clock = originalClock
print("PASS only the bell saves equipment, and either restore route stays idle afterward")
