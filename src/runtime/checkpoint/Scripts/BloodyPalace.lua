local Progress = require("BloodyPalaceProgress")
local Loadout = require("ArenaLoadout")
local LoadoutRestore = require("ArenaLoadoutRestore")
local Ability = require("AbilityChallenge")
local Medicine = require("ChallengeMedicine")
local PlayerState = require("EncounterPlayerState")
local Xigu = require("XiguArena")
local Menu = require("BloodyPalaceMenu")
local StageFade = require("StageFade")
local Portal = require("BloodyPalacePortal")
local GateScene = require("BloodyPalaceGateScene")
local PlayerProfile = require("PlayerProfile")
local Practice = require("PracticeMode")
local Music = require("BloodyPalaceMusic")
local Dream = require("DreamPalaceProfile")
local Balance = require("DreamPalaceBalance")
local CombatAwards = require("DreamPalaceCombatAwards")
local Timer = require("DreamPalaceTimer")
local Defense = require("DreamPalaceDefense")
local Settlement = require("DreamPalaceSettlement")
local NextFloorPreload = require("DreamPalacePreload")
-- Unreal distances are in centimeters. 120 m covers the Xigu combat enclosure.
local ARENA_RADIUS = 12000
local CORPSE_WAIT_LIMIT = 3
local DEBUG_INVULNERABLE = "CharacterState.Stand.Invulnerable.Debug"
local Palace = {}
Palace.__index = Palace

local function log(message) print("[PBZBloodyPalace] " .. message .. "\n") end
local function valid(object) return object and object:IsValid() end

local function corpseVisible(actor)
    if not valid(actor) or actor:IsActorBeingDestroyed() or actor.bHidden == true then return false end
    local mesh = actor.Mesh
    if valid(mesh) and mesh:IsVisible() and mesh.bHiddenInGame ~= true then return true end
    -- Some original enemies have separate skeletal meshes for the head or body.
    local skeletalClass = StaticFindObject("/Script/Engine.SkeletalMeshComponent")
    if not valid(skeletalClass) then return true end
    local components = actor:K2_GetComponentsByClass(skeletalClass)
    local sawBody = false
    for index = 1, #components do
        local part = components[index]
        if part and type(part.IsValid) ~= "function" then part = part:get() end
        if valid(part) and valid(part:GetSkeletalMeshAsset()) then
            sawBody = true
            if part:IsVisible() and part.bHiddenInGame ~= true then return true end
        end
    end
    return not sawBody
end

local function hasDebugInvulnerability(pawn)
    local asc = pawn.AbilitySystemComponent
    return valid(asc) and asc:GetGameplayTagCount({ TagName = FName(DEBUG_INVULNERABLE) }) > 0
end

local function dead(pawn)
    local asc, attributes = pawn.AbilitySystemComponent, pawn.AttributeSetBase
    return (valid(attributes) and attributes.Health.CurrentValue <= 0)
        or (valid(asc) and asc:GetGameplayTagCount({ TagName = FName("CharacterState.Dead") }) > 0)
end

function Palace.new(path, ownsArena, deferCleanup, loadoutPath, ownsLoadout, admission)
    local tier = admission and assert(Dream.tier(admission.tier), Dream.name .. "难度无效")
    local testRange = Progress.testRange
    return setmetatable({ path = path, ownsArena = ownsArena, deferCleanup = deferCleanup,
        loadoutPath = loadoutPath, ownsLoadout = ownsLoadout,
        profileBase = not testRange and admission and admission.base or nil, tier = tier, testRange = testRange,
        practiceFloor = admission and admission.practice, resumeOnEntry = admission and admission.resume,
        entryCheckpoint = admission and admission.checkpoint, warmupEquipment = admission and admission.warmupEquipment,
        projectedLoadout = admission and admission.projectedLoadout,
        returnToArenaMenu = admission and admission.returnToArenaMenu,
        playerCycle = tier and tier.cycle or Progress.playerCycle, difficulty = tier and 3 or Progress.difficulty,
        floor = testRange and testRange.first or 1, cleared = 0, milliseconds = 0, rewardMilliseconds = 0, combatBonus = 0,
        rewards = {}, state = "preparing" }, Palace)
end

function Palace:canUseBell()
    return not self.closed and self.state == "preparing" and self.prepared == true and not self.resumeOnEntry
end

function Palace:closeLoadoutMemory(pawn)
    if not self.loadout then return end
    if pawn and self.loadout.state == "ready" then
        local ok, skills = pcall(Ability.capture, pawn)
        if ok then self:rememberAbility(pawn, skills) end
    end
    self.loadout:close()
    self.loadout = nil
end

function Palace:rememberAbility(pawn, skills)
    if self.loadout and self.loadout:setAbility(pawn, skills) then self.loadout:flush() end
end

function Palace:observeExternalAid(pawn, realNow, force)
    if self.externalAid or not self.profileBase or self.practiceFloor or self.tier.assist
        or (not force and realNow < (self.nextAidSample or 0))
        or not self.ownsArena() or not valid(pawn) or pawn:GetAddress() ~= self.pawnAddress then return end
    self.nextAidSample = realNow + .25
    local ok, active = pcall(hasDebugInvulnerability, pawn)
    if ok and active then
        self.externalAid = true
        log("external aid observed: " .. DEBUG_INVULNERABLE .. "; floor=" .. self.floor)
    end
end

function Palace:currentFloorTime(challenge, now)
    if self.fade or not challenge.startedAt then return 0 end
    return Progress.elapsed(math.max(challenge.startedAt, self.clockReadyAt or challenge.startedAt), now)
end

function Palace:remaining(challenge, now)
    return Timer.left(self.rewardMilliseconds, self.milliseconds + self:currentFloorTime(challenge, now))
end

function Palace:creditDefense(challenge, kind, gameTime, realTime, color, route, evidence)
    if not challenge.startedAt or self.fade or challenge.transitionStep
        or self.state ~= "combat" or self.closed then return false end
    if not (self.tier and self.tier.assist) and self:remaining(challenge, gameTime) <= 0 then return false end
    local category = (color == "red" or color == "blue") and "precision" or kind
    local reward = Timer.queueReward(self.rewards, category, realTime)
    self.rewardMilliseconds, self.combatBonus = self.rewardMilliseconds + reward, self.combatBonus + reward
    log(("countdown reward=%s attack=%s route=%s via=%s floor=%d amountMs=%d remainingMs=%d")
        :format(kind, color, route, evidence, self.floor, reward, self:remaining(challenge, gameTime)))
    return true
end

function Palace:creditKills(challenge, now, realNow)
    if not challenge.startedAt or self.fade or challenge.transitionStep
        or self.state ~= "combat" or self.closed then return end
    local stage = challenge.entry.stages[challenge.stageIndex]
    if not stage.regularMobs then return end
    local defeated
    for _, record in ipairs(challenge.observer.currentRecords) do
        if record.dead and record.killReward then
            defeated = defeated or {}
            defeated[#defeated + 1] = record
        end
    end
    if not defeated then return end
    if #defeated > 1 then
        table.sort(defeated, function(first, second)
            return (first.endedAt or now) < (second.endedAt or now)
        end)
    end
    local clockStart = math.max(challenge.startedAt, self.clockReadyAt or challenge.startedAt)
    local assist = self.tier and self.tier.assist
    for _, record in ipairs(defeated) do
        local kind, killedAt = record.killReward, record.endedAt or now
        record.killReward = nil
        if killedAt >= clockStart and (assist or self:remaining(challenge, killedAt) > 0) then
            local reward = Timer.queueReward(self.rewards, kind, realNow)
            self.rewardMilliseconds = self.rewardMilliseconds + reward
            self.combatBonus = self.combatBonus + reward
        end
    end
end

function Palace:checkTime(challenge, now, realNow)
    if not challenge.startedAt or self:remaining(challenge, now) > 0 then return false end
    if self.tier and self.tier.assist then
        if not self.overtime then
            self.overtime = true
            log("time expired in zhuoshi; continuing with a negative time balance")
        end
        return false
    end
    self:finish(challenge, now, "failure", realNow, true)
    return true
end

function Palace:startCombatAwards(pawn)
    if not self.profileBase or self.practiceFloor or self.tier.assist then return end
    local ok, awards = pcall(CombatAwards.new, pawn, self)
    if ok then self.combatAwards = awards
    else log("achievement tracking unavailable: " .. tostring(awards)) end
end

function Palace:closeCombatAwards()
    local awards = self.combatAwards
    self.combatAwards = nil
    if not awards then return end
    local ok, reason = pcall(awards.close, awards)
    if not ok then log("achievement hook cleanup: " .. tostring(reason)) end
end

function Palace:noMedicine()
    local awards = self.combatAwards
    return not self.medicineHistoryUnknown and awards ~= nil
        and not (awards.usedMedicine or awards.medicineObservationFailed)
end

function Palace:recordBoss(stage, outcome, flags)
    if self.externalAid then flags = (flags or "") .. Dream.externalAidFlag end
    local ok, failure = pcall(Dream.logBoss, self.profileBase, self.tier.id, self.floor, stage, outcome, flags)
    if not ok then log("boss achievement record: " .. tostring(failure)) end
end

function Palace:onStageDefeated(challenge, sample, realNow)
    local awards = self.combatAwards
    local avoidedGrab = awards and awards:finishBride(challenge)
    if not self.profileBase or self.practiceFloor or self.tier.assist then return end
    self:observeExternalAid(self.pawn, realNow or self.lastRealNow or 0, true)
    local stage = challenge.stageIndex
    if self.floor == 101 and stage == 5 and stage == #challenge.entry.stages then
        self.fiveBattlesUntouched = sample.damageTaken == 0 and sample.damageTakenStatus == "attribute-events"
    end
    local _, _, boss = Progress.floor(self.floor)
    if not boss then return end
    local flags = ""
    local stats = valid(self.pawn) and self.pawn.AttributeSetBase
    if valid(stats) and stats.Health.CurrentValue > 0
        and stats.Health.CurrentValue <= stats.Health_Max.CurrentValue * .1 then flags = flags .. "l" end
    if awards then
        if avoidedGrab then flags = flags .. "g" end
        local ok, spent = pcall(awards.suppliesSpent, awards, self.pawn)
        if ok and spent then flags = flags .. "d"
        elseif not ok then log("boss achievement supplies unavailable: " .. tostring(spent)) end
    end
    local checked, lost = pcall(Dream.hasBossLoss, self.profileBase, self.floor, stage)
    if checked and lost then flags = flags .. "v"
    elseif not checked then log("boss defeat history unavailable: " .. tostring(lost)) end
    if flags ~= "" then self:recordBoss(stage, "win", flags) end
end

function Palace:closeGateScene()
    local opening = self.gateScene
    if not opening then return end
    self.gateScene = nil
    local ok, closed, reason = pcall(opening.close, opening)
    if not ok or not closed then
        log("portal opening cleanup: " .. tostring(ok and reason or closed))
        if self.deferCleanup then self.deferCleanup(opening) end
    end
end

function Palace:closeEnding()
    local ending = self.ending
    if not ending then return end
    self.ending = nil
    local ok, closed, reason = pcall(ending.close, ending)
    if not ok or not closed then
        log("ending cleanup: " .. tostring(ok and reason or closed))
        if self.deferCleanup then self.deferCleanup(ending) end
    end
end

function Palace:cover(gameplay, pawn, now)
    if not self.fade then
        self.fade = StageFade.new(gameplay, pawn, now, true)
        if self.music then self.music:duck(now) end
        return false
    end
    return self.fade:canReveal(now)
end

function Palace:playMusic(challenge, now)
    if self.music then self.music:play(Progress.sourceFloor(self.floor), challenge.stageIndex,
        challenge.entry.stages[challenge.stageIndex], now) end
end

function Palace:reveal(now)
    if self.fade then self.fade:reveal(now) end
    self.menu:releasePlayer()
end

function Palace:closeFade()
    if not self.fade then return end
    local ok, failure = pcall(self.fade.close, self.fade)
    if not ok then log("transition cleanup: " .. tostring(failure)) end
    self.fade = nil
end

function Palace:readCheckpoint()
    local ok, saved = pcall(Progress.load, self.path, self.tier and self.tier.assist)
    self.saved = ok and saved or nil
    self.checkpointError = not ok and tostring(saved) or nil
    if self.checkpointError then log("checkpoint unavailable: " .. self.checkpointError) end
    return self.saved
end

local function setOpponent(self, challenge)
    challenge.entry, challenge.enemyCycle = Progress.floor(self.floor)
    local preload = self.openingPreload
    self.openingPreload = nil
    if preload then
        if preload.floor == self.floor and preload:matches(self.pawn) then
            self.arrivalPreload = preload
        else
            preload:close("arrival-scope-changed")
        end
    end
    challenge.stageIndex, challenge.startedAt, challenge.lastSample = 1, nil, nil
    challenge.nextSpawn, challenge.spawnDeadline, challenge.level = nil, nil, nil
    challenge.status, challenge.message = "waiting", "正在准备第 " .. self.floor .. " 场"
    self.engagement = { requests = {}, confirmed = {} }
    self.clockReadyAt, self.shachiRecovery = nil, nil
    self.combatBonus, self.rewards = 0, {}
end

local function movePlayer(challenge, gameplay, system, pawn)
    local destination, reason = Xigu.phaseDestination(pawn, system, challenge.scene)
    if not destination then return false, reason end
    local controller = gameplay:GetPlayerController(pawn, 0)
    local captured, before = pcall(PlayerState.capture, pawn, controller)
    if not captured then return false, tostring(before) end
    destination.pawnAddress, destination.worldAddress = before.pawnAddress, before.worldAddress
    destination.abilitySystemAddress, destination.controllerAddress = before.abilitySystemAddress, before.controllerAddress
    destination.controlRotation = destination.rotation
    local moved, reason = PlayerState.teleport(pawn, destination, controller)
    if not moved then return false, reason end
    local after = PlayerState.capture(pawn, controller)
    local same, differences = PlayerState.compare(before, after)
    assert(same, "血宫回位改变了玩家状态：" .. tostring(differences[1] and differences[1].field))
    local at, target = after.position, destination.position
    assert((at.X - target.X)^2 + (at.Y - target.Y)^2 + (at.Z - target.Z)^2 <= 75^2, "血宫回位偏离擂台落点")
    return true
end

function Palace:rest(pawn, controller, now)
    if not self.recovery then
        self.recovery = Practice.new(pawn)
        self.medicine = Medicine.new(pawn)
        self.medicine:backpack(pawn):RestoreShaqiWeaponBullet()
        local library = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
        assert(valid(library), "血宫状态恢复接口不可用")
        library:SendGameplayEventToActor(pawn, { TagName = FName("GameplayEvent.Actor.Player.ResetState") }, {})
    end
    local resources = self.recovery:restoreResources(now)
    local medicines, reason = self.medicine:update(pawn, now, controller)
    if not resources or not medicines then return false, reason end
    if self.playerShachiBase then Balance.restorePlayerShachi(pawn, self.playerShachiBase) end
    self.recovery, self.medicine = nil, nil
    local attributes = pawn.AttributeSetBase
    log(("restored health, medicines, ammo and combat resources; floor=%d; hp=%.2f/%.2f; spiritShadow=%.2f/%.2f")
        :format(Progress.sourceFloor(self.floor), attributes.Health.CurrentValue, attributes.Health_Max.CurrentValue,
            attributes.SpiritShadow.CurrentValue, attributes.SpiritShadow_Max.CurrentValue))
    return true
end

function Palace:exitProgress()
    if not self.arenaEntered or self.practiceFloor or self.testRange or self.state == "result" then return end
    return self.checkpointFloor == self.floor, self.checkpointFloor
end

local function hasEnding(palace, challenge)
    if palace.practiceFloor or palace.floor ~= Progress.count or Progress.sourceFloor(palace.floor) ~= 101
        or challenge.stageIndex ~= #challenge.entry.stages then return false end
    local members = challenge.entry.stages[challenge.stageIndex].members
    return #members == 1 and members[1].id == "BP_Monster_FengXueDaoKe"
end

function Palace:coverEnding(challenge, gameplay, system, pawn, realNow)
    if self.endingReady then return true end
    if not self.ending then
        local ok, ending, reason, partial = pcall(function()
            return require("BloodyPalaceEnding").new(gameplay, system, pawn, challenge.scene, self.music,
                self.tier and self.tier.id)
        end)
        if ok and ending then
            self.ending = ending
            if self.music then self.music:finish(realNow) end
        else
            log("ending setup fallback: " .. tostring(ok and reason or ending))
            self.ending = partial
            self:closeEnding()
            self.endingReady = true
            return true
        end
    end
    local ok, covered = pcall(self.ending.cover, self.ending, realNow)
    if ok then return covered end
    log("ending cover fallback: " .. tostring(covered))
    self:closeEnding()
    self.endingReady = true
    return true
end

function Palace:prepareAtBell(challenge, gameplay, pawn, now)
    if not self.menu then
        local controller = gameplay:GetPlayerController(pawn, 0)
        if not valid(controller) then return end
        local controlled = controller:K2_GetPawn()
        if not valid(controlled) or controlled:GetAddress() ~= pawn:GetAddress() then return end
        assert(self.ownsArena(), "血宫需要独立演武会话")
        local native = StaticFindObject("/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary")
        assert(valid(native) and native:GetGameCycle(pawn) == self.playerCycle, "血宫测试档轮回不匹配")
        self.menu = Menu.new(pawn, controller, function() return not self.closed and self.ownsArena() end,
            function() return self:exitProgress() end)
        self.pawn, self.pawnAddress = pawn, pawn:GetAddress()
        if self.tier then self.shachiTalentModel = Balance.readPlayerTalentModel(pawn, self.tier.cycle * 5) end
        self.music = Music.new(gameplay, pawn)
        challenge.ability, challenge.abilityProfilePawn = Ability, pawn
        Ability.setProfile(pawn, PlayerProfile.id(self.playerCycle))
        Ability.setCycleSkills(pawn, challenge.skillLevel)
        challenge.pendingSkillLevel, challenge.loadoutApplied = nil, true
        if self.loadoutPath and self.ownsLoadout(pawn) then
            local memory, why = require("ArenaLoadoutMemory").new(self.loadoutPath, function(player)
                return not self.closed and (self.state == "preparing" or self.state == "launching")
                    and player:GetAddress() == self.pawnAddress and self.ownsLoadout(player)
            end, log, self.projectedLoadout)
            self.loadout = memory
            if not memory then log("preparation loadout unavailable: " .. tostring(why)) end
        end
    end
    if self.warmupEquipment then
        self.warmupRestore = self.warmupRestore or LoadoutRestore.new(self.warmupEquipment, self.projectedLoadout)
        local ready, reason = self.warmupRestore:update(pawn)
        if ready == nil then
            self.menu:restrict(true)
            challenge.message = "正在恢复热身配装"
            return
        end
        if ready then log("warmup equipment restored; route=" .. reason)
        else log("warmup equipment unavailable: " .. tostring(reason)) end
        self.warmupRestore, self.warmupEquipment = nil, nil
    end
    if self.loadout and self.loadout.state == "pending" then
        local ready = self.loadout:update(pawn)
        if not ready then
            self.menu:restrict(true)
            challenge.message = "正在恢复血宫常用配装"
            return
        end
    end
    if not self.prepSkillsRestored then
        if self.loadout and self.loadout.abilities then
            local restored, failure = pcall(Ability.restore, pawn, self.loadout.abilities)
            if not restored then
                self.loadout.readOnly = true
                log("preparation skills unavailable: " .. tostring(failure))
            end
        end
        self.prepSkillsRestored = true
    end
    local ready, reason = self.menu:restrict(self.resumeOnEntry == true)
    if not ready then challenge.message = reason or "等待备战菜单就绪"; return end
    self.prepared = true
    if self.resumeOnEntry then
        self:bellAction(challenge, "palace-resume", now)
        return
    end
    challenge.status, challenge.message = "preparing", "按 ESC／菜单键配装，在铃铛处开始试炼"
    log("ready at the preparation bell")
    if self.testRange then
        self:bellAction(challenge, "palace-start", now)
    elseif self.practiceFloor then
        challenge.message = ("按 ESC／菜单键配装，在铃铛处开始第 %d 层热身"):format(self.practiceFloor)
        log(("warmup awaiting bell; floor=%d"):format(self.practiceFloor))
    elseif self.profileBase then
        log(("menu admission ready; tier=%s; playerCycle=%d; resume=%s"):format(self.tier.id,
            self.playerCycle, tostring(self.resumeOnEntry == true)))
    end
end

function Palace:bellAction(challenge, action, now)
    if self.practiceFloor and (action ~= "palace-start" or not self:canUseBell()) then return end
    local resume = action == "palace-resume"
    local checkpoint = resume and (self.entryCheckpoint or self:readCheckpoint()) or nil
    self.entryCheckpoint = nil
    if resume and not checkpoint then
        challenge.status = "preparing"
        challenge.message = "无法载入浊梦进度，请从系统菜单返回主菜单。"
        return
    end
    self.checkpoint = checkpoint
    if checkpoint then
        self.floor, self.cleared, self.milliseconds = checkpoint.cleared, checkpoint.cleared, checkpoint.milliseconds
        self.rewardMilliseconds = checkpoint.rewardMilliseconds
        self.externalAid = self.profileBase ~= nil and not self.tier.assist and checkpoint.externalAid == true
        self.medicineHistoryUnknown = checkpoint.cleared >= 81 and checkpoint.noMedicine ~= true
        self.resumed = true
        self.checkpointFloor = checkpoint.cleared
    elseif self.practiceFloor then
        self.floor = self.practiceFloor
    end
    self.menu:holdPlayer()
    self.state, self.deadline = "launching", now + 15
    challenge.status, challenge.message = "preparing", resume and "正在载入血宫进度" or "正在准备进入雾门"
    if self.practiceFloor then log(("warmup selected at the bell; floor=%d"):format(self.floor))
    else log(resume and "checkpoint selected from the title menu" or "new trial selected at the bell") end
end

function Palace:launch(challenge, gameplay, system, pawn, realNow)
    assert(realNow < self.deadline, "等待血宫进场超时：" .. tostring(self.waitReason or "未就绪"))
    local restricted, reason = self.menu:restrict(true)
    if not restricted then self.waitReason = reason; return end
    assert(self.menu:update(realNow), "血宫系统菜单已离开当前角色")
    if gameplay:IsGamePaused(pawn) then self.waitReason = "等待原版菜单退出"; return end
    if not self:cover(gameplay, pawn, realNow) then return end
    if not self.equipment then
        if self.checkpoint and not self.checkpointApplied then
            self.checkpointRestore = self.checkpointRestore or LoadoutRestore.new(self.checkpoint.equipment, self.projectedLoadout)
            local ready, why = self.checkpointRestore:update(pawn)
            assert(ready ~= false, "浊梦存点配装恢复失败：" .. tostring(why))
            if not ready then
                self.deadline = realNow + 15
                challenge.message, self.waitReason = "正在恢复血宫配装", why
                return
            end
            self.checkpointRestore = nil
            Ability.restore(pawn, self.checkpoint.ability)
            self.checkpointApplied = true
            log("checkpoint equipment restored; route=" .. why)
        end
        local equipment, reason = Loadout.capture(pawn)
        if not equipment then challenge.message = "等待原版配装生效"; self.waitReason = reason; return end
        self.equipment, self.skills = equipment, Ability.capture(pawn)
        if self.loadout then
            if not self.testRange then
                self.loadout:setAbility(pawn, self.skills)
                self.loadout:remember(pawn, equipment)
            end
            self:closeLoadoutMemory()
        end
        log(("native equipment confirmed and locked; player cycle=%d; difficulty=%d"):format(self.playerCycle, self.difficulty))
    end
    if not self.restored then
        local ready, reason = self:rest(pawn, self.menu.controller, realNow)
        if not ready then
            challenge.message, self.waitReason = "正在补满血宫资源", reason
            return
        end
        self.restored = true
    end
    local moved, why = movePlayer(challenge, gameplay, system, pawn)
    if not moved then self.waitReason = why; return end
    if self.tier then
        local cycle, value, base = Balance.setPlayerShachi(pawn, self.tier.id, self.skills.HeiShi8, self.shachiTalentModel)
        self.playerShachiBase = base
        log(("player ShachiAttack; cycle=%d; value=%.2f"):format(cycle, value))
        self.playerControl = require("DreamPalacePlayerControl").start(pawn)
    end
    self.stopDeathWatch = Progress.watchDeath(self, pawn, log)
    self:startCombatAwards(pawn)
    local ok, defense = pcall(Defense.new, pawn, challenge, gameplay,
        function() return self.state == "combat" and not self.fade and not self.closed and self.ownsArena() end,
        function(...) return self:creditDefense(challenge, ...) end)
    if ok then self.defense = defense else log("countdown signal setup: " .. tostring(defense)) end
    self.arenaEntered = true
    log("player placed inside FogDoor14; floor=" .. self.floor)
    if self.checkpoint then
        self.checkpoint = nil
        challenge.entry, challenge.enemyCycle = Progress.floor(self.floor)
        self.state, self.deadline = "gate", realNow + 12
        self.gateMessage = ("已载入第 %d 波进度，靠近传送门继续"):format(self.floor)
        challenge.status, challenge.message = "gate", self.gateMessage
        self:recordResume(pawn, realNow)
        log(("resumed at floor %d gate; recorded time=%d"):format(self.floor, self.milliseconds))
    else
        self.state, self.deadline = "combat", nil
        setOpponent(self, challenge)
        log("new run starting at floor " .. self.floor)
    end
end

function Palace:recordResume(pawn, realNow)
    if not self.profileBase or self.tier.assist then return end
    self:observeExternalAid(pawn, realNow, true)
    local flags = self.externalAid and "r" .. Dream.externalAidFlag or "r"
    local ok, failure = pcall(Dream.log, self.profileBase, self.tier.id, self.cleared, self.milliseconds, "restore", flags)
    if ok then self.resumeAwarded = true
    else log("checkpoint achievement record: " .. tostring(failure)) end
end

function Palace:recordReached()
    local floor = self.reachedFloor
    if not floor or not self.profileBase or self.practiceFloor or self.testRange
        or floor <= (self.loggedReach or 0) then return end
    local ok, best = pcall(function()
        local recorded = self.loggedReach or Dream.read(self.profileBase, self.tier.id).bestReached
        if floor > recorded then Dream.logReached(self.profileBase, self.tier.id, floor) end
        return math.max(floor, recorded)
    end)
    if ok then self.loggedReach = best
    else log("warmup reach record: " .. tostring(best)) end
end

function Palace:onStageReady(challenge)
    local stage = challenge.entry.stages[challenge.stageIndex]
    local floor = Progress.sourceFloor(self.floor)
    self.shachiRecovery = Balance.recoveryTargets(stage, challenge.bosses, floor, self.tier and self.tier.id)
    if self.tier and floor == 101 and not challenge.fengXuePursuit then
        challenge.fengXuePursuit = require("DreamPalaceFengXuePursuit").start(self.pawn, stage, challenge.bosses)
    end
    if self.tier and stage.regularMobs and not challenge.mobPressure then
        challenge.mobPressure = require("DreamPalaceMobPressure").start(self.pawn, challenge.bosses, stage.members, floor)
    end
    local preload = self.arrivalPreload
    if preload then
        self.arrivalPreload = nil
        local ok, failure = pcall(preload.reportSpawn, preload, stage.members, challenge.bosses)
        if not ok then log("next floor spawn observation failed: " .. tostring(failure)) end
        preload:close("spawned")
    end
    self.reachedFloor = Progress.sourceFloor(self.floor)
    self:recordReached()
    self.arenaTargets = self.tier and { requests = {} } or nil
    if stage.regularMobs then
        local records = challenge.observer.recordsByAddress
        for index, member in ipairs(stage.members) do
            local record = records[challenge.bosses[index]:GetAddress()]
            if record then record.killReward = member.killReward end
        end
    end
    if self.combatAwards then self.combatAwards:watchBride(challenge) end
    if self.music then self.music:prepare(Progress.sourceFloor(self.floor), stage) end
    local units = {}
    for _, member in ipairs(stage.members) do
        units[#units + 1] = ("%s:%d"):format(member.id, member.enemyCycle or stage.enemyCycle or challenge.enemyCycle)
    end
    log(("spawned floor=%d stage=%d/%d count=%d roster=%s"):format(self.floor, challenge.stageIndex,
        #challenge.entry.stages, #challenge.bosses, table.concat(units, ",")))
end

function Palace:keepArenaTargets(challenge, gameplay, pawn, now)
    local state = self.arenaTargets
    if not state or self.state ~= "combat" or not challenge.awake or self.engagement
        or challenge.transitionStep or now < (state.nextAt or 0) then return end
    state.nextAt = now + 1
    if gameplay:IsGamePaused(pawn) then return end

    local engage = require("EncounterEngage")
    local mode = self.practiceFloor and "warmup" or "trial"
    local members = challenge.entry.stages[challenge.stageIndex].members
    for index, actor in ipairs(challenge.bosses) do
        if valid(actor) and not actor:IsActorBeingDestroyed() then
            local address = actor:GetAddress()
            local request = state.requests[address] or {}
            state.requests[address] = request
            if now >= (request.errorRetryAt or 0) then
                local ok, sight, loseSight, recoveredAt, loss = pcall(engage.keepArena, actor, pawn, ARENA_RADIUS, request, now)
                local id = members[index] and members[index].id or tostring(index)
                if not ok then
                    if sight ~= request.error then
                        log(("arena aggro error mode=%s floor=%d unit=%s: %s"):format(mode, self.floor, id, sight))
                    end
                    request.error, request.errorRetryAt = sight, now + 3
                elseif sight or loss then
                    if sight and not request.logged then
                        log(("arena aggro mode=%s floor=%d stage=%d unit=%s original=%.1fm sight=%.1fm retain=%.1fm")
                            :format(mode, self.floor, challenge.stageIndex, id, request.originalRadius / 100, sight / 100, loseSight / 100))
                        request.logged = true
                    end
                    if loss then
                        log(("arena engagement lost mode=%s floor=%d stage=%d unit=%s distance=%.1fm state=%s aiStarted=%s hasTarget=%s threatened=%s")
                            :format(mode, self.floor, challenge.stageIndex, id, loss.distance / 100, loss.state,
                                tostring(loss.started), tostring(loss.hasTarget), tostring(loss.playerThreatened)))
                    end
                    if recoveredAt then
                        log(("arena target recovered mode=%s floor=%d unit=%s distance=%.1fm")
                            :format(mode, self.floor, id, recoveredAt / 100))
                    end
                    request.error, request.errorRetryAt = nil, nil
                end
            end
        end
    end
end

function Palace:engage(challenge, pawn, now, gameNow)
    local state = self.engagement
    if not state or now < (state.nextAt or 0) then return end
    self:observeExternalAid(pawn, now)
    state.nextAt = now + .25
    state.deadline = state.deadline or now + 5
    state.readyDeadline = state.readyDeadline or gameNow + 12
    local engage, complete, reason = require("EncounterEngage"), true, nil
    for _, actor in ipairs(challenge.bosses) do
        if valid(actor) then
            local address = actor:GetAddress()
            if not state.confirmed[address] then
                local request = state.requests[address] or {}
                state.requests[address] = request
                local ready, why = engage.start(actor, pawn, request, now)
                if ready then state.confirmed[address] = true else complete, reason = false, why end
            end
        end
    end
    if complete then
        challenge.awake, self.engagement = true, nil
        if self.floor == 1 and not self.practiceFloor and not self.testRange then Progress.discard(self.path) end
        self:reveal(now)
        self:playMusic(challenge, now)
        log("opening combat engaged; floor=" .. self.floor .. "; count=" .. #challenge.bosses)
    elseif now >= state.deadline and now >= (state.nextLog or 0) then
        log("waiting for opening combat; floor=" .. self.floor .. "; reason=" .. tostring(reason))
        state.nextLog = now + 5
    end
    assert(complete or gameNow < state.readyDeadline, "血宫敌人未完成接战：" .. tostring(reason))
end

function Palace:clearRound(challenge, sample, now, realNow)
    assert(challenge.stageIndex == #challenge.entry.stages, "血宫整场尚未结束")
    self:onStageDefeated(challenge, sample, realNow)
    local _, _, boss = Progress.floor(self.floor)
    local restore = boss or self.tier and self.tier.assist and Progress.isNamedElite(self.floor)
    local spent = self:currentFloorTime(challenge, sample.endedAt or now)
    self.milliseconds = self.milliseconds + spent
    local noDamage = sample.damageTaken == 0
    local clearKind = boss and (Timer.bossClearKinds[#challenge.entry.stages] or "bossClear") or "clear"
    local clearBonus = Timer.queueReward(self.rewards, clearKind, realNow)
    if noDamage then clearBonus = clearBonus + Timer.queueReward(self.rewards, "clean", realNow) end
    self.rewardMilliseconds = self.rewardMilliseconds + clearBonus
    local reward = self.combatBonus + clearBonus
    self.floorResult = { floor = self.floor, spent = spent, reward = reward, noDamage = noDamage, at = realNow }
    self.cleared = self.floor
    if self.profileBase and not self.practiceFloor then
        local flags = self.resumed and not self.resumeAwarded and "r" or ""
        if self.externalAid then flags = flags .. Dream.externalAidFlag end
        local ok, failure = pcall(Dream.log, self.profileBase, self.tier.id, self.cleared, self.milliseconds, "clear", flags)
        if not ok then log("UI progress record: " .. tostring(failure))
        elseif self.resumed then self.resumeAwarded = true end
    end
    self.engagement = nil
    if self.music then self.music:stopRetry() end
    challenge.startedAt, challenge.awake = nil, false
    challenge.observer:close()
    challenge.observer = nil
    challenge.status, challenge.message = "gate", restore and "正在恢复状态" or "本场完成，传送门即将开启"
    self.state, self.clearAt, self.clearedAt = "clearing", realNow + .35, now
    self.nextOpeningAttempt, self.portalWaitReason = nil, nil
    self.restored = not restore
    log(("cleared floor=%d; spentMs=%d; rewardMs=%d; noDamage=%s; damageStatus=%s; remainingMs=%d")
        :format(self.floor, spent, reward, tostring(noDamage), tostring(sample.damageTakenStatus), self:remaining(challenge, now)))
end

function Palace:closePreload(reason)
    if self.openingPreload then self.openingPreload:close(reason); self.openingPreload = nil end
    if self.arrivalPreload then self.arrivalPreload:close(reason); self.arrivalPreload = nil end
    if self.combatFrames then self.combatFrames:finish(reason); self.combatFrames = nil end
end

function Palace:finish(challenge, now, result, realNow, timedOut)
    self:closePreload("settlement")
    if self.state == "result" then return end
    if self.playerControl then self.playerControl:close() end
    if challenge.mobPressure then challenge:closeMobPressure() end
    local mobDefeat
    local stage = challenge.entry and challenge.entry.stages[challenge.stageIndex]
    if result == "failure" and self.state == "combat" and self.profileBase and not self.practiceFloor
        and not (self.tier.assist or challenge.transitionStep) and stage and (challenge.awake or challenge.startedAt) then
        self:observeExternalAid(self.pawn, realNow or self.lastRealNow or 0, true)
        if not (timedOut or challenge.lastSample and challenge.lastSample.bossDead) then
            local _, _, boss = Progress.floor(self.floor)
            if boss then
                self:recordBoss(challenge.stageIndex, "loss")
            elseif stage.regularMobs and valid(self.pawn) then
                mobDefeat = dead(self.pawn)
            end
        end
    end
    self.milliseconds = timedOut and (Timer.initial + self.rewardMilliseconds)
        or self.milliseconds + self:currentFloorTime(challenge, now)
    local remaining = Timer.left(self.rewardMilliseconds, self.milliseconds)
    local cleared = self.cleared > 0 and Progress.sourceFloor(self.cleared) or 0
    local fullClear = result == "success" and not self.practiceFloor and self.cleared == Progress.count and cleared == 101
    local finalLoadout
    if fullClear then
        local ok, snapshot = pcall(function() return require("ChallengeLoadout").capture(self.pawn) end)
        if ok and snapshot and snapshot.available then
            finalLoadout = snapshot
        else
            local reason = ok and snapshot and table.concat(snapshot.errors or {}, "; ") or tostring(snapshot)
            log("settlement loadout unavailable: " .. reason)
        end
    end
    if not self.practiceFloor and not self.testRange then
        local shouldDiscard = result == "success" or (not timedOut and not (self.tier and self.tier.assist))
        local recorded, failure
        if self.profileBase then
            local victory = fullClear and Progress.count == 101 and not self.tier.assist
            local flags = victory and not self.resumed and "n" or ""
            if victory and self.equipment then
                local gear = self.equipment
                local single = (not not gear.mainWeapons[1]) ~= (not not gear.mainWeapons[2])
                local accessories = not (gear.accessories[1] or gear.accessories[2] or gear.accessories[3]
                    or gear.accessories[4] or gear.accessories[5] or gear.accessories[6])
                local shadow = not (gear.shadowWeapons[1] or gear.shadowWeapons[2])
                flags = flags .. (single and "w" or "") .. (accessories and "a" or "") .. (shadow and "s" or "")
                    .. (single and accessories and shadow and "o" or "")
            end
            if mobDefeat and Dream.mobDefeatFlag then flags = flags .. Dream.mobDefeatFlag end
            if self.externalAid then flags = flags .. Dream.externalAidFlag end
            if result == "failure" then
                self:recordReached()
                flags = flags .. Dream.exactReachFlag
            end
            local weapons
            if victory then
                if self.fiveBattlesUntouched then flags = flags .. "u" end
                if self:noMedicine() then flags = flags .. "m" end
                local gear, reason = Loadout.capture(self.pawn)
                if gear then weapons = gear.mainWeapons else log("result weapon slots unavailable: " .. tostring(reason)) end
            end
            recorded, failure = pcall(Dream.log, self.profileBase, self.tier.id, self.cleared, self.milliseconds,
                result == "success" and "win" or "loss", flags, weapons,
                remaining, timedOut)
        else
            recorded, failure = pcall(Progress.record, self.path, self.cleared, self.milliseconds, result)
        end
        if not recorded then
            log("result file: " .. tostring(failure))
        end
        if shouldDiscard and (recorded or result ~= "success") then
            local discarded, why = pcall(Progress.discard, self.path)
            if not discarded then log("checkpoint cleanup: " .. tostring(why)) end
        end
    end
    self.state, self.result, self.shachiRecovery = "result", result, nil
    if self.defense then self.defense:close(); self.defense = nil end
    self:closeCombatAwards()
    if self.music then self.music:finish(realNow or self.lastRealNow or 0) end
    challenge:closeTransition()
    self:closeFade()
    self:closeGateScene()
    self.menu:releasePlayer()
    if self.portal then self.portal:close(); self.portal = nil end
    if challenge.observer then challenge.observer:close(); challenge.observer = nil end
    local cleaned, why = pcall(challenge.clearStage, challenge)
    if not cleaned then log("settlement cleanup: " .. tostring(why)) end
    challenge.startedAt, challenge.status = nil, "won"
    if timedOut then challenge.message = "时间耗尽，挑战失败"
    elseif self.testRange then challenge.message = result == "success" and "短测完成" or "短测战败"
    elseif self.practiceFloor then challenge.message = result == "success" and "练习结束" or "练习战败"
    else challenge.message = result == "success" and (Dream.name .. "通关") or "阵亡，本轮挑战已结束" end
    local failureCause = result == "failure" and self.tier and (timedOut and "timeout" or "death") or nil
    local time, rank = Progress.format(self.milliseconds), Dream.rank(cleared)
    local remainingText = Timer.format(remaining, true)
    local body = ("已完成 %d 层\n战斗用时 %s\n到达评级 %s"):format(cleared, time, rank)
    local report
    if failureCause or not self.testRange and (fullClear or self.tier and not self.practiceFloor) then
        local tierName = self.tier and self.tier.name or "—"
        report = { cleared = cleared, time = time, remaining = remainingText, rank = rank, tierName = tierName,
            failure = result == "failure" and (timedOut and "时间耗尽" or "阵亡") or nil,
            fullClear = fullClear, loadout = finalLoadout, warmupFloor = self.practiceFloor }
        body = ("完成时间 %s\n结算时间 %s\n职阶 %s\n通关层数 %d\n到达评级 %s")
            :format(time, remainingText, tierName, cleared, rank)
    elseif self.tier and self.tier.assist then
        body = body .. "\n时间结算 " .. remainingText
    end
    if self.practiceFloor then body = ("第 %d 层"):format(self.practiceFloor) end
    if self.testRange then
        body = cleared > 0 and ("已测至第 %d 层"):format(cleared) or ("第 %d 层"):format(self.floor)
    end
    local offer = self.profileBase and not self.practiceFloor and result == "failure" and self.tier.id == "deep"
        and Dream.canUnlockZhuoshi(self.profileBase)
    self.settlement = Settlement.new(challenge.message, body, offer and self.profileBase or nil, not timedOut, report,
        fullClear and self.ending and self.floorResult or nil, failureCause)
    if failureCause and realNow and valid(self.menu.controller) then
        local gameplay = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        if valid(gameplay) then
            self.resultGameplay = gameplay
            local ok, failure = pcall(self.settlement.freezeRespawn, self.settlement, gameplay, self.menu.controller)
            if not ok then log("failure world hold: " .. tostring(failure)) end
        end
    end
    log(("settled result=%s cleared=%d totalMs=%d timeout=%s remainingMs=%d")
        :format(result, cleared, self.milliseconds, tostring(timedOut == true), remaining))
end

function Palace:waitForPortal(challenge, realNow, reason)
    reason = reason or "正在等待传送门落点"
    if self.portalWaitReason ~= reason then log("floor=" .. self.floor .. "; " .. reason) end
    self.portalWaitReason, self.nextOpeningAttempt = reason, realNow + .25
    challenge.message = reason
    assert(realNow < self.deadline, "传送门准备超时：" .. reason)
end

function Palace:openGate(challenge, gameplay, system, pawn, realNow)
    if not self.gateScene then
        if gameplay:IsGamePaused(pawn) or realNow < (self.nextOpeningAttempt or 0) then return end
        local destination = Xigu.portalDestination(pawn, system, challenge.scene)
        local opening, reason, partial
        if destination then
            opening, reason, partial = GateScene.new(gameplay, system, pawn, challenge.scene, destination)
        end
        self.gateScene = opening or partial
        assert(not partial, reason)
        if not opening then
            self:waitForPortal(challenge, realNow, reason)
            return
        end
    end
    local opening = self.gateScene
    local portal = opening:update()
    if portal then
        if self.openingPreload then self.openingPreload:endOpening() end
    elseif opening.effectStarted and not gameplay:IsGamePaused(pawn) and self.ownsArena() then
        if self.openingPreload then
            self.openingPreload:stepOpening(pawn, gameplay)
        else
            local nextFloor = self.floor + 1
            local entry = Progress.floor(nextFloor)
            self.openingPreload = NextFloorPreload.new(pawn, self.floor, nextFloor, entry.stages[1].members)
            self.openingPreload:beginOpening()
        end
    end
    if not portal then return end
    self.portal, self.gateScene, self.state = portal, nil, "gate"
    challenge.message = self.gateMessage or "靠近传送门，进入下一场"
    log("portal opened after floor " .. self.floor)
end

function Palace:corpsesCleared(challenge, now)
    -- Scope the visibility checks to the short interval between combat and the gate.
    for _, actor in ipairs(challenge.bosses) do
        local ok, visible = pcall(corpseVisible, actor)
        if not ok or visible then
            if now - self.clearedAt < CORPSE_WAIT_LIMIT then return false end
            -- An actor may retain a visible component flag after its material dissolves.
            -- Use normal owned-actor cleanup so that such a floor still opens its gate.
            log(("corpse cleanup fallback; floor=%d; waitedGameMs=%.0f; limit=%.0fs")
                :format(self.floor, (now - self.clearedAt) * 1000, CORPSE_WAIT_LIMIT))
            break
        end
    end
    return true
end

function Palace:updateResult(challenge, gameplay, controller, now)
    self.resultGameplay = gameplay
    if self.settlement.floorResult and self.ending then
        if not self.ending.waitingForConfirm then self.ending:showFloorResult() end
        self.settlement:update(gameplay, controller, now)
        if self.settlement.floorResult then return end
    end
    if self.ending and not self.endingReady then
        local ok, ready = pcall(function()
            self.ending:confirm(now)
            return self.ending:update(now, self.settlement.report ~= nil)
        end)
        if ok and not ready then return end
        if not ok then
            log("ending playback fallback: " .. tostring(ready))
            self:closeEnding()
        elseif self.ending.titleScreen and not self.ending.titleScreen.closed then
            self.settlement.endingTitle = self.ending.titleScreen
        end
        self.endingReady = true
    end
    if self.settlement:update(gameplay, controller, now) then
        if self.settlement.exit == "arena" and self.returnToArenaMenu then self.returnToArenaMenu() end
        challenge:queueAction("palace-exit")
    end
end

function Palace:beforeTick(challenge, gameplay, system, pawn, now, realNow)
    if self.closed then return true end
    self.lastRealNow = realNow
    if self.music then
        local retry = self.state == "combat" and challenge.status == "combat"
            and not challenge.transitionStep and not gameplay:IsGamePaused(pawn)
        self.music:update(realNow, retry)
    end
    if self.state == "result" then
        if challenge.action then challenge:updateMenuOnly(gameplay, system, pawn, now)
        else self:updateResult(challenge, gameplay, gameplay:GetPlayerController(pawn, 0), realNow) end
        return true
    end
    if self.pawnAddress and (self.playerDied or pawn:GetAddress() ~= self.pawnAddress or dead(pawn)) then
        if self.arenaEntered and (self.playerDied or valid(self.pawn) and dead(self.pawn)) then
            self:finish(challenge, now, "failure", realNow)
        else
            self.arenaEntered = false
            challenge:queueAction("palace-exit")
            challenge:updateMenuOnly(gameplay, system, pawn, now)
        end
        return true
    end
    challenge.difficulty = challenge.difficulty or require("GameplayDifficulty").new(pawn, self.difficulty)
    assert(challenge.difficulty:update(pawn) ~= false, "血宫难度已离开当前角色")
    if self.fade and self.fade:update(realNow) == "done" then
        self.fade = nil
        if self.state == "combat" then
            self.clockReadyAt = now
            log("floor reveal finished; floor=" .. self.floor)
        end
    end
    if not self.practiceFloor and (self.combatFrames or self.combatSampledFloor ~= self.floor) then
        local inCombat = self.state == "combat" and challenge.startedAt ~= nil and challenge.awake
            and not self.fade and not gameplay:IsGamePaused(pawn)
        if self.combatFrames then
            if not inCombat or NextFloorPreload.combatWindowDone(self.combatFrames) then
                self.combatFrames:finish(inCombat and "opening-window" or "combat-state-changed")
                self.combatFrames = nil
            end
        elseif inCombat and self.ownsArena() then
            self.combatSampledFloor = self.floor
            self.combatFrames = NextFloorPreload.captureCombat(self.floor)
        end
    end
    if self.state == "preparing" then
        if not self.prepared then self:prepareAtBell(challenge, gameplay, pawn, realNow) end
        if self.menu and self.menu.policy then assert(self.menu:update(realNow), "血宫备战菜单已离开当前角色") end
        if self.prepared then challenge:updateMenuOnly(gameplay, system, pawn, now) end
        return true
    end
    if self.state == "launching" then
        self:launch(challenge, gameplay, system, pawn, realNow)
        return true
    end
    if self.state == "combat" and not challenge.transitionStep and (challenge.awake or challenge.startedAt) then
        self:observeExternalAid(pawn, realNow)
    end
    if self.shachiRecovery then
        local active = self.state == "combat" and challenge.startedAt and not challenge.transitionStep
            and not self.fade and not gameplay:IsGamePaused(pawn)
        Balance.recoverShachi(self.shachiRecovery, active and now or nil)
    end
    if challenge.mobPressure and self.state == "combat" and not challenge.mobPressure:step(now) then
        challenge:closeMobPressure()
    end
    assert(self.menu:update(realNow), "血宫系统菜单已离开当前角色")
    if self.state == "clearing" then
        if self.clearAt then
            if realNow < self.clearAt then return true end
            local mechanics = challenge.palaceMechanics
            if mechanics and not mechanics:deathEffectFinished(now, self.clearedAt) then return true end
            local nextFloor = not self.practiceFloor and self.floor < (self.testRange and self.testRange.last or Progress.count)
            if nextFloor and not self:corpsesCleared(challenge, now) then return true end
            if hasEnding(self, challenge) and not self:coverEnding(challenge, gameplay, system, pawn, realNow) then
                return true
            end
            challenge:clearStage()
            self.clearAt, self.clearedAt, self.deadline = nil, nil, realNow + 15
        end
        assert(realNow < self.deadline, "等待血宫关底补给超时")
        if not self.restored then
            if not self:rest(pawn, gameplay:GetPlayerController(pawn, 0), realNow) then return true end
            self.restored = true
        end
        if self.practiceFloor then
            self:finish(challenge, now, "success", realNow)
            return true
        end
        if self.floor == (self.testRange and self.testRange.last or Progress.count) then
            if not self.ending and self.floorResult and realNow < self.floorResult.at + 2.8 then return true end
            self:finish(challenge, now, "success", realNow)
            return true
        end
        if not self.testRange and (Progress.isCheckpoint(self.floor) or self.tier and self.tier.assist) then
            local noMedicine
            if self.profileBase and not self.tier.assist and self.floor >= 81 then noMedicine = self:noMedicine() end
            Progress.save(self.path, self.floor, self.milliseconds, self.equipment, self.skills,
                self.tier and self.tier.assist, self.externalAid, noMedicine, self.rewardMilliseconds)
            self.checkpointFloor = self.floor
            self.gateMessage = ("第 %d 波已保存，可退出游戏或靠近传送门"):format(self.floor)
            challenge.message = self.gateMessage
            log(("checkpoint saved after floor %d; next floor=%d"):format(self.floor, self.floor + 1))
        end
        self.state, self.deadline = "opening", realNow + 10
    end
    if self.state == "opening" then
        self:openGate(challenge, gameplay, system, pawn, realNow)
        return true
    end
    if self.state == "gate" then
        if not self.portal then
            if realNow < (self.nextOpeningAttempt or 0) then return true end
            local destination = Xigu.portalDestination(pawn, system, challenge.scene)
            local portal, reason
            if destination then portal, reason = Portal.new(gameplay, pawn, destination) end
            if not portal then self:waitForPortal(challenge, realNow, reason); return true end
            self.portal = portal
            if Portal.contains(pawn, destination.position) then
                assert(Xigu.pushOutsidePortal(pawn, system, challenge.scene, destination, Portal.safeDistance),
                    "传送门旁未找到安全落脚点")
            end
            portal:activate(pawn, now)
            challenge.message = self.gateMessage or "靠近传送门，进入下一场"
            log("portal opened after floor " .. self.floor)
        end
        local opened = self.portal:update(now)
        if not gameplay:IsGamePaused(pawn) then
            if opened and self.fade and self.fade.phase == "black" then self:reveal(realNow) end
            if not self.fade and self.portal:entered(pawn) then
                self.menu:holdPlayer()
                self.state, self.deadline = "moving", now + 8
                log("portal crossed; floor=" .. self.floor)
            end
        end
        return true
    end
    if self.state == "moving" then
        if gameplay:IsGamePaused(pawn) or not self:cover(gameplay, pawn, realNow) then return true end
        self.floorResult = nil
        local moved, reason = movePlayer(challenge, gameplay, system, pawn)
        if not moved then assert(now < self.deadline, reason); return true end
        self.portal:close()
        self.portal, self.gateMessage = nil, nil
        self.floor, self.state, self.deadline = self.floor + 1, "combat", nil
        setOpponent(self, challenge)
        log("portal entered; starting floor " .. self.floor)
        return true
    end
    return self.fade ~= nil and (challenge.transitionStep ~= nil or gameplay:IsGamePaused(pawn))
end

function Palace:hud(challenge, now)
    if not self.arenaEntered or self.state == "result" or self.closed then return nil end
    local stage = challenge.entry.stages[challenge.stageIndex]
    local target = stage and stage.name or challenge.entry.name
    if #challenge.entry.stages > 1 then
        target = ("%d/%d %s"):format(challenge.stageIndex, #challenge.entry.stages, target)
    end
    return { floor = self.floor, count = Progress.count, time = Timer.format(self:remaining(challenge, now), true),
        target = self.practiceFloor and ("练习 · " .. target) or target }
end

function Palace:battleHud(challenge, now)
    if self.closed or not self.arenaEntered or self.state == "result" or self.ending
        or (self.state == "combat" and not challenge.startedAt and not self.fade) then return nil end
    local fade = self.fade or challenge.stageFade
    local remaining = self:remaining(challenge, now)
    if not (self.tier and self.tier.assist) then remaining = math.max(0, remaining) end
    local result = self.floorResult
    if result and hasEnding(self, challenge) then result = nil end
    return { floor = self.floor, remaining = remaining, result = result,
        rewards = self.rewards, fading = fade ~= nil, covered = fade ~= nil and fade.phase ~= "out" }
end

function Palace:onMapPre(challenge)
    self:closePreload("map-change")
    -- Stock respawn can replace the pawn between service ticks.
    if self.state ~= "result" and self.arenaEntered
        and (self.playerDied or valid(self.pawn) and dead(self.pawn)) then
        self:finish(challenge, challenge.lastPalaceTime or 0, "failure")
    end
end

function Palace:close()
    self:closePreload("run-closed")
    self.closed = true
    if self.playerControl then self.playerControl:close(); self.playerControl = nil end
    if self.stopDeathWatch then self.stopDeathWatch(); self.stopDeathWatch = nil end
    if self.defense then self.defense:close(); self.defense = nil end
    self:closeCombatAwards()
    if self.music then self.music:close(); self.music = nil end
    self:closeLoadoutMemory()
    self:closeFade()
    self:closeGateScene()
    if self.settlement then self.settlement:detach(self.resultGameplay); self.settlement = nil end
    self:closeEnding()
    if self.portal then pcall(self.portal.close, self.portal); self.portal = nil end
    if self.menu then
        local ok, done, why = pcall(self.menu.close, self.menu)
        if not ok or not done then
            log("native menu cleanup: " .. tostring(ok and why or done))
            if self.deferCleanup then self.deferCleanup(self.menu) end
        end
        self.menu = nil
    end
    self.recovery, self.medicine, self.pawn = nil, nil, nil
end

return Palace
