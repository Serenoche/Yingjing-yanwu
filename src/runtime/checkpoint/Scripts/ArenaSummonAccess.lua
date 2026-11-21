-- Private arena permission and level scaling for the player's native summons.
local SceneArena = require("SceneArena")
local Access, Session = {}, {}
Session.__index = Session

local SUMMON_AVAILABLE = "CharacterState.Summon.SummonAvailable"
local TAG_LIBRARY = "/Script/ProjectPBZ.Default__PBZAbilityBlueprintLibrary"
local GAME_LIBRARY = "/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary"
local SUMMON_ASSET = "/SGameAI/Core/AIScript/GA_SummonPassive"
local PRE_FINISH = SUMMON_ASSET .. ".GA_SummonPassive_C:OnSummonSpawnPreFinish"
local NPC_CLASS = "/Game/RenewalContent/Prototypes/Character/BP_RenewalNPC.BP_RenewalNPC_C"
local UNLOADED_FLAGS = 0x08023600
local NON_INSTANCE_FLAGS = 0x00018030
local LEVELS_PER_CYCLE = 25 -- BP_RenewalNPC:Init Level
local PLAYER_SUMMONS = {
    GA_KuYeSiZhuChuan_Summon_Passive_C = true,
    GA_CaoOuSiXian_Summon_Passive_C = true,
    GA_JianKeZhaoJiLing_Summon_Passive_C = true,
    GA_XueSeLingDang_Summon_Passive_C = true,
}
local levelHookInstalled, activeSession

local function address(object)
    return object and object:IsValid() and object:GetAddress() or nil
end

local function tagLibrary()
    local library = StaticFindObject(TAG_LIBRARY)
    assert(address(library), "原生召唤许可接口不可用")
    return library
end

function Session:applySummonLevel(context, spawnParam)
    local ability = context:get()
    if not address(ability) or ability:HasAnyFlags(NON_INSTANCE_FLAGS) then return end
    local className = ability:GetClass():GetFName():ToString()
    if not PLAYER_SUMMONS[className] then return end
    local pawn = ability:GetAvatarActorFromActorInfo()
    if address(pawn) ~= self.pawnAddress or self.privateGate(pawn) ~= true then return end

    local summon = spawnParam:get()
    if not address(summon) or summon:HasAnyFlags(NON_INSTANCE_FLAGS) or summon:IsActorBeingDestroyed()
        or address(SceneArena.runtimeWorld(summon)) ~= self.world then return end
    local npcClass = StaticFindObject(NPC_CLASS)
    assert(address(npcClass) and summon:IsA(npcClass), "原版召唤单位类型无法确认")
    local library = StaticFindObject(GAME_LIBRARY)
    assert(address(library), "原生轮回接口不可用")
    local cycle = library:GetGameCycle(pawn)
    assert(type(cycle) == "number" and cycle % 1 == 0 and cycle >= 0 and cycle <= 6, "玩家原生轮回无效")

    -- OnDeferedSpawn has just written weapon level plus the native global
    -- offset. FinishSpawning will initialize the attributes from this Level.
    local nativeLevel = summon.Level
    assert(type(nativeLevel) == "number" and nativeLevel >= 1 and nativeLevel < math.huge, "原版召唤等级无效")
    local level = nativeLevel + cycle * LEVELS_PER_CYCLE
    if level ~= nativeLevel then
        summon.Level = level
        assert(summon.Level == level, "演武召唤等级回读失败")
    end
    print(("[PBZTestArenaNative] Private arena summon level: playerCycle=%d; nativeLevel=%g; level=%g\n")
        :format(cycle, nativeLevel, level))
end

local function installLevelHook()
    local entry = StaticFindObject(PRE_FINISH)
    if not address(entry) then
        LoadAsset(SUMMON_ASSET .. ".GA_SummonPassive_C")
        entry = StaticFindObject(PRE_FINISH)
        if not address(entry) then
            LoadAsset(SUMMON_ASSET)
            entry = StaticFindObject(PRE_FINISH)
        end
    end
    assert(address(entry) and not entry:HasAnyFlags(UNLOADED_FLAGS), "原版召唤生成入口未就绪")
    -- UE4SS matches script hooks by name. One POST survives map changes and
    -- remains inert whenever the private arena has no active session.
    local first, last = RegisterHook(PRE_FINISH, function(context, spawnParam)
        local session = activeSession
        if not session or session.closed then return end
        local ok, failure = pcall(session.applySummonLevel, session, context, spawnParam)
        if not ok and not session.levelError then
            session.levelError = tostring(failure)
            print("[PBZTestArenaNative] 演武召唤等级：" .. session.levelError .. "\n")
        end
    end)
    assert(first and last, "演武召唤等级回调未安装")
    levelHookInstalled = true
end

function Access.new(pawn, world, privateGate)
    return setmetatable({ pawn = pawn, pawnAddress = pawn:GetAddress(), world = world,
        privateGate = privateGate, tag = { TagName = FName(SUMMON_AVAILABLE) } }, Session)
end

function Session:update(pawn)
    if self.closed or address(pawn) ~= self.pawnAddress then return end
    local entering = not levelHookInstalled or activeSession ~= self
    if entering and self.privateGate(pawn) ~= true then return end
    if not levelHookInstalled then
        local ok, failure = pcall(installLevelHook)
        if not ok and not self.hookError then
            self.hookError = tostring(failure)
            print("[PBZTestArenaNative] 演武召唤等级：" .. self.hookError .. "\n")
        end
    end
    if entering and levelHookInstalled then activeSession = self end
    local asc = pawn.AbilitySystemComponent
    local ascAddress = address(asc)
    if not ascAddress then return end
    if self.ownedAsc ~= ascAddress then self.ownedAsc = nil end
    if asc:GetGameplayTagCount(self.tag) > 0 then return end
    -- Auditing the count is read-only. Confirm the current private scope
    -- before every grant, including when a native ability component resets.
    if self.privateGate(pawn) ~= true then return end

    -- Native grants already in effect do not acquire a MOD-owned count.
    -- A rebuilt or reset ASC can acquire a fresh count on its next update.
    self.ownedAsc = nil
    assert(tagLibrary():AddLooseGameplayTag(pawn, self.tag, false) == true, "无法补齐召唤区域许可")
    self.ownedAsc = ascAddress
    assert(asc:GetGameplayTagCount(self.tag) > 0, "召唤区域许可回读失败")
    print("[PBZTestArenaNative] Private arena summon permission granted\n")
end

function Session:close()
    self.closed = true
    if activeSession == self then activeSession = nil end
    local pawn = self.pawn
    if self.ownedAsc and address(pawn) == self.pawnAddress
        and address(SceneArena.runtimeWorld(pawn)) == self.world then
        local asc = pawn.AbilitySystemComponent
        if address(asc) == self.ownedAsc and asc:GetGameplayTagCount(self.tag) > 0 then
            assert(tagLibrary():RemoveLooseGameplayTag(pawn, self.tag, false) == true, "无法撤回演武召唤区域许可")
        end
    end
    self.ownedAsc = nil
    return true
end

return Access
