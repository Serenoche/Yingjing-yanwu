local Medicine = require("ChallengeMedicine")
local Awards = {}
Awards.__index = Awards

local USE_MEDICINE = "/Script/ProjectPBZ.PBZBackPackSubsystem:UseMedicine"
local BRIDE = "BP_Monster_AHua_GuiTouDao"
local GRAB_VICTIM = "/PBZCombatAsset/ActorData/Mobs/042_AHua/Ability/GuiTouDao/Abilities/Grab/GA_AHua_CA_01_GEd.GA_AHua_CA_01_GEd_C"
local GRAB_ACTIVATION = GRAB_VICTIM .. ":K2_ActivateAbility"

local function valid(object) return object and object:IsValid() end

local function unwrap(value)
    if value and (type(value) == "table" or type(value) == "userdata") and type(value.get) == "function" then
        return value:get()
    end
    return value
end

local function medicineAmount(backpack, id)
    local info = unwrap(backpack.MedicineInfos:Find(id))
    return info and info.CurrentTime
end

function Awards:watchMedicine()
    local palace = self.palace
    local native = StaticFindObject(USE_MEDICINE)
    assert(native and native:IsValid(), "浊梦主动用药接口未就绪")
    local before
    local function capture(context, medicineId, count)
        local backpack = unwrap(context)
        if not backpack or not backpack:IsValid() or backpack:GetAddress() ~= self.inventory.backpackAddress then return end
        local amount = unwrap(count)
        assert(type(amount) == "number", "浊梦用药数量不可读")
        if amount <= 0 then return end
        local remaining = medicineAmount(backpack, unwrap(medicineId))
        assert(type(remaining) == "number", "浊梦药品余量不可读")
        return remaining
    end
    local function reportFailure(reason)
        if not self.medicineObservationFailed then
            print("[PBZBloodyPalace] medicine achievement observation: " .. tostring(reason) .. "\n")
        end
        self.medicineObservationFailed = true
    end
    local pre, post = RegisterHook(USE_MEDICINE, function(context, medicineId, count)
        before = nil
        if self.closed or not palace.arenaEntered or palace.floor < 81 or palace.cleared >= 101 then return end
        local ok, remaining = pcall(capture, context, medicineId, count)
        if ok then before = remaining else reportFailure(remaining) end
    end, function(context, medicineId)
        local remaining = before
        before = nil
        if remaining == nil or self.closed then return end
        local ok, reason = pcall(self.observeMedicine, self, context, medicineId, remaining)
        if not ok then reportFailure(reason) end
    end)
    assert(pre and post, "浊梦主动用药监听未注册")
    self.medicineHook = { pre, post }
end

function Awards.new(pawn, palace)
    local self = setmetatable({ palace = palace, inventory = Medicine.new(pawn) }, Awards)
    assert(self:backpack(pawn), "浊梦成就背包未就绪")
    local ok, reason = pcall(self.watchMedicine, self)
    if not ok then
        self.medicineObservationFailed = true
        print("[PBZBloodyPalace] medicine achievement hook unavailable: " .. tostring(reason) .. "\n")
    end
    return self
end

function Awards:backpack(pawn)
    return self.inventory:backpack(pawn)
end

function Awards:observeMedicine(context, medicineId, before)
    local backpack, id = unwrap(context), unwrap(medicineId)
    local after = medicineAmount(backpack, id)
    assert(type(after) == "number", "浊梦用药后余量不可读")
    if after < before then self.usedMedicine = true end
end

function Awards:suppliesSpent(pawn)
    local attributes = pawn.AttributeSetBase
    if not valid(attributes) or attributes.SpiritShadow.CurrentValue ~= 0 then return false end
    local backpack, equipped = self:backpack(pawn), false
    for index = 0, 1 do
        local value = unwrap(backpack:GetMedicineByIndex(index))
        local id = type(value) == "string" and value or value and value:ToString() or ""
        if id ~= "" and id:lower() ~= "none" then
            equipped = true
            if medicineAmount(backpack, FName(id)) ~= 0 then return false end
        end
    end
    return equipped
end

function Awards:watchBride(challenge)
    if self.bride then return end
    local stage = challenge.entry.stages[challenge.stageIndex]
    for index, member in ipairs(stage.members) do
        if member.id == BRIDE and valid(challenge.bosses[index]) then
            local ok, reason = pcall(self.registerGrab, self, challenge)
            if not ok then
                print("[PBZBloodyPalace] AHua grab observation unavailable: " .. tostring(reason) .. "\n")
            end
            return
        end
    end
end

function Awards:registerGrab(challenge)
    if not valid(StaticFindObject(GRAB_ACTIVATION)) then
        local asset, reason = require("SpawnClass").resolve(GRAB_VICTIM)
        assert(valid(asset), reason)
    end
    local watch = { challenge = challenge, stage = challenge.stageIndex }
    -- These red grabs all activate the same victim ability on the player
    -- after a successful grab. Ordinary damage uses other hit reactions.
    local pre, post = RegisterHook(GRAB_ACTIVATION, function(context)
        if self.closed or self.bride ~= watch or watch.hit or watch.failed then return end
        local ok, reason = pcall(function()
            local actor = unwrap(context):GetAvatarActorFromActorInfo()
            assert(valid(actor), "阿花抓技受击角色不可读")
            watch.hit = actor:GetAddress() == self.inventory.pawnAddress
        end)
        if not ok then
            watch.failed = true
            print("[PBZBloodyPalace] AHua grab observation failed: " .. tostring(reason) .. "\n")
        elseif watch.hit then
            print("[PBZBloodyPalace] AHua red grab hit the player\n")
        end
    end)
    assert(pre and post, "浊梦阿花抓技监听未注册")
    watch.hook = { pre, post }
    self.bride = watch
end

function Awards:finishBride(challenge)
    local watch = self.bride
    if not watch then return false end
    self.bride = nil
    local ok, reason = pcall(UnregisterHook, GRAB_ACTIVATION, watch.hook[1], watch.hook[2])
    if not ok then print("[PBZBloodyPalace] AHua grab hook cleanup: " .. tostring(reason) .. "\n") end
    return challenge == watch.challenge and challenge.stageIndex == watch.stage and not (watch.hit or watch.failed)
end

function Awards:close()
    self.closed = true
    self:finishBride()
    if self.medicineHook then
        UnregisterHook(USE_MEDICINE, self.medicineHook[1], self.medicineHook[2])
        self.medicineHook = nil
    end
end

return Awards
