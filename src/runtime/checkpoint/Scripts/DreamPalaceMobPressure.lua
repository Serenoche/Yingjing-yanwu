local Rules = require("DreamPalaceMobPressureRules")
local CombatSpawn = require("CombatSpawn")
local Pressure = {}
local Session = {}
Session.__index = Session

local SELECT_BEHAVIOR = "/Script/SGameAI.SGameAIStrategyConfig:SelectBehavior"
local PREVIEW_HOOKS = {
    { "/SGameAI/Core/AICondition/Condition_IsLeaderAI.Condition_IsLeaderAI_C:EvaluateCondition", "goal" },
    { "/SGameAI/MetaAI/Decorators/BTDecorator_IsLeaderAI.BTDecorator_IsLeaderAI_C:PerformConditionCheckAI", "tree" },
    { "/SGameAI/Core/AICondition/Condition_DoesStrategyValid.Condition_DoesStrategyValid_C:EvaluateCondition", "strategy" },
}
local ACTION_PHASES = {
    "CharacterState.Action.Phase.Start", "CharacterState.Action.Phase.Act",
    "CharacterState.Action.Phase.Combo", "CharacterState.Action.Phase.Cancel",
}
local ranged = {}
for _, mob in ipairs(require("TrainingMobCatalog")) do
    ranged[mob.id] = mob.role == "远程" or mob.role == "投掷"
end

local function valid(object) return object and object:IsValid() end
local function tagCount(asc, tag) return asc:GetGameplayTagCount(tag) > 0 end
local function log(floor, message) print(("[PBZDreamMobPressure] floor=%d %s\n"):format(floor, message)) end

local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "杂兵压力接口不可用 " .. path)
    return object
end

local function nativeGroup(controller)
    local ok, group = pcall(function() return controller:GetMetaAI() end)
    if ok and valid(group) then return group end
end

local function ownsGroup(group, owned, deadTag)
    local ok, result = pcall(function()
        local pawns, living = group:GetMemberPawns(), 0
        for index = 1, #pawns do
            local pawn = pawns[index]
            if pawn and type(pawn.IsValid) ~= "function" then pawn = pawn:get() end
            if valid(pawn) and valid(pawn.AbilitySystemComponent) and not tagCount(pawn.AbilitySystemComponent, deadTag) then
                if not owned[pawn:GetAddress()] then return false end
                living = living + 1
            end
        end
        return living >= 2
    end)
    return ok and result == true
end

function Session:treeInfo(tree)
    local address = tree:GetAddress()
    local info = self.trees[address]
    if not info then
        info = { address = address, attacks = Rules.attackTree(tree:GetFName():ToString()) }
        self.trees[address] = info
    end
    return info
end

function Session:sample(now)
    if self.sampledAt == now then return end
    local tags = self.tags
    for _, record in ipairs(self.members) do
        record.alive, record.eligible, record.tail, record.attackTree = false, false, false, nil
        if valid(record.actor) and valid(record.ai) and valid(record.brain) and valid(record.asc)
            and not record.actor:IsActorBeingDestroyed() and not tagCount(record.asc, tags.dead) then
            record.alive = true
            local combat = record.ai.CurrentStateTag.TagName:ToString() == "AI.State.Combat"
            record.eligible = combat and not tagCount(record.asc, tags.hit) and not tagCount(record.asc, tags.broken)
            local slot = self.sequence.slots[record.id]
            if combat or slot then
                local tree = record.brain:GetRunningBehaviorTree()
                if valid(tree) then
                    local info = self:treeInfo(tree)
                    if info.attacks or (slot and info.address == slot.tree) then record.attackTree = info.address end
                end
                if not record.attackTree and slot and slot.running and record.eligible then
                    for _, phase in ipairs(self.phases) do
                        if tagCount(record.asc, phase) then record.tail = true; break end
                    end
                end
            end
        end
    end
    local asc = self.pawn.AbilitySystemComponent
    assert(valid(asc), "浊梦玩家能力组件已离开战场")
    local ready = not (tagCount(asc, tags.hit) or tagCount(asc, tags.broken) or tagCount(asc, tags.dead))
    self.sequence:observe(now, self.members, ready)
    self.sampledAt = now
end

function Session:fail(reason)
    if self.failure then return end
    self.failure = tostring(reason)
    log(self.floor, "已恢复原版选招 " .. self.failure)
end

function Session:step(now)
    if self.closed or self.failure then return false end
    local ok, reason = pcall(self.sample, self, now)
    if not ok then self:fail(reason) end
    return ok
end

function Session:recordFor(parameter)
    if not self.active or self.failure or not parameter or not IsInGameThread() then return end
    local controller = parameter:get()
    if not valid(controller) then return end
    local record = self.byController[controller:GetAddress()]
    if record and valid(record.actor) and not record.actor:IsActorBeingDestroyed() then return record end
end

function Session:preview(kind, context, controller)
    local record = self:recordFor(controller)
    if not record then return end
    if kind == "strategy" then
        if not Rules.attackStrategy(context:get()["Strategy Tag"].TagName:ToString()) then return end
    elseif kind == "goal" and not record.ownedGroup then return end
    self:sample(self.gameplay:GetTimeSeconds(self.pawn))
    if self.sequence.slots[record.id] then
        if kind ~= "strategy" then return true end
        return
    end
    if kind == "tree" then return end
    if not self.sequence:canConsider(record) then return false end
    if kind == "goal" then return true end
end

function Session:select(result, strategy, controller)
    local record = self:recordFor(controller)
    if not record then return end
    local choice = result:get()
    local tree = choice.BehaviorTree
    if not valid(tree) then return end
    local info = self:treeInfo(tree)
    if not info.attacks and not Rules.attackStrategy(strategy:get().TagName:ToString()) then return end
    info.attacks = true
    local now = self.gameplay:GetTimeSeconds(self.pawn)
    self:sample(now)
    if not self.sequence:admit(record, info.address, now) then
        -- The original StateTree treats an empty tree as a failed selection.
        choice.BehaviorTree = nil
        assert(not valid(choice.BehaviorTree), "杂兵选招结果无法清空")
    end
end

function Session:register(path, ...)
    local pre, post = RegisterHook(path, ...)
    assert(type(pre) == "number" and type(post) == "number", "杂兵压力接口注册失败 " .. path)
    self.hooks[#self.hooks + 1] = { path, pre, post }
end

function Session:install()
    required(SELECT_BEHAVIOR)
    for _, hook in ipairs(PREVIEW_HOOKS) do
        local path = hook[1]
        if not valid(StaticFindObject(path)) then LoadAsset(path:match("^(.+)_C:")) end
        required(path)
    end
    self:register(SELECT_BEHAVIOR, function() end, function(_, result, strategy, controller)
        local ok, reason = pcall(self.select, self, result, strategy, controller)
        if not ok then self:fail(reason) end
    end)
    for _, hook in ipairs(PREVIEW_HOOKS) do
        local path, kind = hook[1], hook[2]
        self:register(path, function(context, controller)
            local ok, value = pcall(self.preview, self, kind, context, controller)
            if ok then return value end
            self:fail(value)
        end)
    end
end

function Session:close()
    if self.closed then return end
    self.closed, self.active = true, false
    for _, hook in ipairs(self.hooks) do
        local ok, reason = pcall(UnregisterHook, table.unpack(hook))
        if not ok then log(self.floor, "杂兵压力接口清理 " .. tostring(reason)) end
    end
    local counts = self.sequence.counts
    if counts.admitted > 0 or counts.outside > 0 then
        log(self.floor, ("cap=%d admitted=%d started=%d expired=%d outside=%d peak=%d windows=%d")
            :format(self.sequence.limit, counts.admitted, counts.started, counts.expired,
                counts.outside, counts.peak, counts.windows))
    end
    self.byController, self.members, self.hooks, self.pawn = {}, {}, {}, nil
end

function Pressure.start(pawn, actors, members, floor)
    if floor < Rules.firstFloor then return end
    local self = setmetatable({ pawn = pawn, floor = floor, sequence = Rules.new(floor),
        hooks = {}, members = {}, trees = {}, byController = {}, phases = {}, tags = {} }, Session)
    local ok, reason = pcall(function()
        assert(IsInGameThread() and valid(pawn) and type(UnregisterHook) == "function", "浊梦战斗接口不可用")
        assert(#actors == #members and #actors > 0, "浊梦杂兵名单尚未就绪")
        self.gameplay = required("/Script/Engine.Default__GameplayStatics")
        self.tags = {
            hit = { TagName = FName("CharacterState.Hitreact.State") },
            broken = { TagName = FName("CharacterState.Stand.Break") },
            dead = { TagName = FName("CharacterState.Dead") },
        }
        for _, phase in ipairs(ACTION_PHASES) do self.phases[#self.phases + 1] = { TagName = FName(phase) } end
        local owned, groups = {}, {}
        for index, actor in ipairs(actors) do
            local member = members[index]
            assert(member.regularMob and valid(actor), "杂兵压力仅接收本层已生成的杂兵")
            local controller, ai, asc = actor:GetController(), CombatSpawn.ai(actor), actor.AbilitySystemComponent
            assert(valid(controller) and valid(ai) and valid(asc), "浊梦杂兵战斗组件尚未就绪")
            local brain = controller.BrainComponent
            assert(valid(brain) and brain.GetRunningBehaviorTree, "浊梦杂兵行为树组件尚未就绪")
            local record = { id = index, actor = actor, ai = ai, asc = asc, brain = brain,
                ranged = ranged[member.id], controller = controller }
            self.members[index], self.byController[controller:GetAddress()] = record, record
            owned[actor:GetAddress()] = true
        end
        for _, record in ipairs(self.members) do
            local group = nativeGroup(record.controller)
            if group then
                local address = group:GetAddress()
                if groups[address] == nil then groups[address] = ownsGroup(group, owned, self.tags.dead) end
                record.ownedGroup = groups[address]
            end
        end
        self:install()
    end)
    if not ok then self:fail(reason); self:close(); return end
    self.active = true
    return self
end

return Pressure
