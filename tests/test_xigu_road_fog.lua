-- Run against the checkpoint runtime. The native stair collision and fog
-- component can get out of sync independently of the combat entrance gate.
local nextAddress = 0
local function object(fields)
    nextAddress = nextAddress + 1
    local address = nextAddress
    function fields:IsValid() return true end
    function fields:GetAddress() return address end
    function fields:HasAnyFlags() return false end
    return fields
end

local world = object({})
local function actor(blocking)
    local result = object({ world = world, blocking = blocking })
    function result:IsActorBeingDestroyed() return false end
    function result:GetActorEnableCollision() return self.blocking end
    function result:SetActorEnableCollision(value) self.blocking = value end
    function result:OpenByMobScript() self.openCalls = (self.openCalls or 0) + 1 end
    result["Close By Mob Script"] = function(self) self.closeCalls = (self.closeCalls or 0) + 1 end
    return result
end

local entrance = actor(true)
package.loaded.SceneArena = { runtimeWorld = function(value) return value.world end }
package.loaded.MeiGuHuOriginalEvents = { actor = function(name)
    assert(name == "combat entrance")
    return entrance
end }
package.loaded.SpawnClass = { resolve = function() error("the intact stairs must not be respawned") end }
local Fog = require("XiguRoadFog")

local function niagara(active)
    local effect = object({
        active = active, visible = active, bHiddenInGame = not active, asset = object({}),
        activationCalls = 0, scalabilityCalls = 0,
    })
    function effect:GetAsset() return self.asset end
    function effect:IsVisible() return self.visible end
    function effect:IsActive() return self.active end
    function effect:SetVisibility(value) self.visible = value end
    function effect:SetHiddenInGame(value) self.bHiddenInGame = value end
    function effect:SetAllowScalability(value)
        assert(value == false)
        self.scalabilityCalls = self.scalabilityCalls + 1
    end
    function effect:Activate(reset)
        assert(reset == true)
        self.active = true
        self.activationCalls = self.activationCalls + 1
    end
    return effect
end

local side = actor(true)
local box = object({
    GetCollisionEnabled = function() return 1 end,
    GetCollisionResponseToChannel = function(_, channel) assert(channel == 2); return 2 end,
})
local pawn = { CapsuleComponent = object({ GetCollisionObjectType = function() return 2 end }) }
local scene = { id = "cangang", combatFog = "combat entrance", roadFogs = { { name = "right stair" } } }
local record = { actor = side, boxes = { box } }
local tx = { world = world, scene = scene, roadGates = { record } }
local function update(now) assert(Fog.update(tx, {}, pawn, scene, now)) end

local broken = niagara(false)
side.NS_Common_BossFog_002 = broken
update(0)
assert(broken.active and broken.visible and not broken.bHiddenInGame)
assert(broken.scalabilityCalls == 1 and broken.activationCalls == 1)
assert(side.blocking and not entrance.blocking and entrance.closeCalls == nil)

broken.active = false
update(1)
assert(broken.activationCalls == 1 and not broken.active)
update(2)
assert(broken.active and broken.activationCalls == 2 and broken.scalabilityCalls == 1)

local healthy = niagara(true)
side.NS_Common_BossFog_002 = healthy
update(4)
assert(healthy.scalabilityCalls == 1 and healthy.activationCalls == 0)
update(6)
assert(healthy.scalabilityCalls == 1 and healthy.activationCalls == 0)

Fog.setCombat(tx, true)
assert(entrance.blocking and entrance.closeCalls == 1)
Fog.setCombat(tx, false)
assert(not entrance.blocking and entrance.openCalls == 2 and side.blocking)

print("PASS stair fog recovers without rebuilding collision or closing the combat entrance before engagement")
