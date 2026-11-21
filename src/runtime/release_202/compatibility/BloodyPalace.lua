local Progress = require("BloodyPalaceProgress")
local Loadout = require("ArenaLoadout")
local LoadoutRestore = require("ArenaLoadoutRestore")
local Ability = require("AbilityChallenge")
local Medicine = require("ChallengeMedicine")
local PlayerState = require("EncounterPlayerState")
local Xigu = require("XiguArena")
local Menu = require("BloodyPalaceMenu")
local Home = require("TitleHome")
local StageFade = require("StageFade")
local Portal = require("BloodyPalacePortal")
local GateScene = require("BloodyPalaceGateScene")
local PlayerProfile = require("PlayerProfile")
local Dream = require("DreamPalaceProfile")
local Balance = require("DreamPalaceBalance")
local Practice = require("PracticeMode")
local Music = require("BloodyPalaceMusic")
local Palace = {}
Palace.__index = Palace

local function log(message) print("[PBZBloodyPalace] " .. message .. "\n") end
local function valid(object) return object and object:IsValid() end

local function dead(pawn)
    local asc, attributes = pawn.AbilitySystemComponent, pawn.AttributeSetBase
    return (valid(attributes) and attributes.Health.CurrentValue <= 0)
        or (valid(asc) and asc:GetGameplayTagCount({ TagName = FName("CharacterState.Dead") }) > 0)
end

function Palace.new(path, ownsArena, deferCleanup, loadoutPath, ownsLoadout, admission)
    local tier = admission and assert(Dream.tier(admission.tier), Dream.name .. "难度无效")
    return setmetatable({ path = path, ownsArena = ownsArena, deferCleanup = deferCleanup,
        loadoutPath = loadoutPath, ownsLoadout = ownsLoadout,
        profileBase = admission and admission.base, tier = tier,
        practiceFloor = admission and admission.practice, resumeOnEntry = admission and admission.resume,
        warmupEquipment = admission and admission.warmupEquipment,
        playerCycle = tier and tier.cycle or Progress.playerCycle,
        performance = Progress.performanceTrace and require("BloodyPalacePerformance").new() or nil,
        floor = 1, cleared = 0, milliseconds = 0, state = "preparing" }, Palace)
end

function Palace:canUseBell()
    return not self.closed and self.state == "preparing" and self.prepared == true
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
    if not ok then log("white fade cleanup: " .. tostring(failure)) end
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
    challenge.stageIndex, challenge.startedAt, challenge.lastSample = 1, nil, nil
    challenge.nextSpawn, challenge.spawnDeadline, challenge.level = nil, nil, nil
    challenge.status, challenge.message = "waiting", "正在准备第 " .. self.floor .. " 场"
    self.engagement = { requests = {}, confirmed = {} }
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
    if not self.arenaEntered or self.practiceFloor or self.state == "result" then return end
    return self.checkpointFloor == self.floor, self.checkpointFloor
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
        if not self.practiceFloor and (not self.tier or self.resumeOnEntry) then self:readCheckpoint() end
        if self.loadoutPath and self.ownsLoadout(pawn) then
            local memory, why = require("ArenaLoadoutMemory").new(self.loadoutPath, function(player)
                return not self.closed and (self.state == "preparing" or self.state == "launching")
                    and player:GetAddress() == self.pawnAddress and self.ownsLoadout(player)
            end, log)
            self.loadout = memory
            if not memory then log("preparation loadout unavailable: " .. tostring(why)) end
        end
    end
    if self.warmupEquipment then
        self.warmupRestore = self.warmupRestore or LoadoutRestore.new(self.warmupEquipment)
        local ready, reason = self.warmupRestore:update(pawn)
        if ready == nil then
            self.menu:restrict(true)
            challenge.message = "正在恢复热身配装"
            return
        end
        if not ready then log("warmup equipment unavailable: " .. tostring(reason)) end
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
    local ready, reason = self.menu:restrict(false)
    if not ready then challenge.message = reason or "等待备战菜单就绪"; return end
    self.prepared = true
    challenge.status, challenge.message = "preparing", "按 ESC／菜单键配装，在铃铛处开始试炼或载入进度"
    log("ready at the preparation bell")
    if self.practiceFloor then
        self:bellAction(challenge, "palace-start", now)
    elseif self.tier then
        challenge.message = self.resumeOnEntry and "在铃铛处载入进度" or "按 ESC／菜单键配装，在铃铛处开始试炼"
        log(("menu admission ready; tier=%s; playerCycle=%d; resume=%s"):format(self.tier.id, self.playerCycle,
            tostring(self.resumeOnEntry == true)))
    end
end

function Palace:bellAction(challenge, action, now)
    local resume = action == "palace-resume"
    if self.tier and self.resumeOnEntry and not resume then return end
    local checkpoint = resume and self:readCheckpoint() or nil
    if resume and not checkpoint then
        challenge.message = self.checkpointError and "续打存档读取失败" or "没有可载入的血宫进度"
        return
    end
    self.checkpoint = checkpoint
    if checkpoint then
        self.floor, self.cleared, self.milliseconds = checkpoint.cleared, checkpoint.cleared, checkpoint.milliseconds
        self.checkpointFloor = checkpoint.cleared
    elseif self.practiceFloor then
        self.floor = self.practiceFloor
    end
    self.menu:holdPlayer()
    self.state, self.deadline = "launching", now + 15
    challenge.status, challenge.message = "preparing", resume and "正在载入血宫进度" or "正在准备进入雾门"
    log(resume and "checkpoint selected at the bell" or "new trial selected at the bell")
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
            self.checkpointRestore = self.checkpointRestore or LoadoutRestore.new(self.checkpoint.equipment)
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
        log(("native equipment confirmed and locked; player cycle=%d; difficulty=%d"):format(self.playerCycle, Progress.difficulty))
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
    self.arenaEntered = true
    log("player placed inside FogDoor14; floor=" .. self.floor)
    if self.checkpoint then
        self.checkpoint = nil
        challenge.entry, challenge.enemyCycle = Progress.floor(self.floor)
        self.state, self.deadline = "gate", realNow + 12
        self.gateMessage = ("已载入第 %d 波进度，靠近传送门继续"):format(self.floor)
        challenge.status, challenge.message = "gate", self.gateMessage
        log(("resumed at floor %d gate; recorded time=%d"):format(self.floor, self.milliseconds))
    else
        self.state, self.deadline = "combat", nil
        setOpponent(self, challenge)
        log("new run starting at floor 1")
    end
end

local function hasEnding(palace, challenge)
    if palace.floor ~= Progress.count or Progress.sourceFloor(palace.floor) ~= 101
        or challenge.stageIndex ~= #challenge.entry.stages then return false end
    local members = challenge.entry.stages[challenge.stageIndex].members
    return #members == 1 and members[1].id == "BP_Monster_FengXueDaoKe"
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
    if self.music then self.music:prepare(Progress.sourceFloor(self.floor), stage) end
    local units = {}
    for _, member in ipairs(stage.members) do
        units[#units + 1] = ("%s:%d"):format(member.id, member.enemyCycle or stage.enemyCycle or challenge.enemyCycle)
    end
    log(("spawned floor=%d stage=%d/%d count=%d roster=%s"):format(self.floor, challenge.stageIndex,
        #challenge.entry.stages, #challenge.bosses, table.concat(units, ",")))
end

function Palace:engage(challenge, pawn, now, gameNow)
    local state = self.engagement
    if not state or now < (state.nextAt or 0) then return end
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
        if self.floor == 1 and not self.practiceFloor then Progress.discard(self.path) end
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
    local _, _, boss = Progress.floor(self.floor)
    local restore = boss or self.tier and self.tier.assist and Progress.isNamedElite(self.floor)
    self.milliseconds = self.milliseconds + Progress.elapsed(challenge.startedAt, sample.endedAt or now)
    self.cleared = self.floor
    if self.tier and not self.practiceFloor then
        local recorded, failure = pcall(Dream.log, self.profileBase, self.tier.id, self.cleared, self.milliseconds, "clear")
        if not recorded then log("UI progress record: " .. tostring(failure)) end
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
    log(("cleared floor=%d; totalMs=%d; boss=%s"):format(self.floor, self.milliseconds, tostring(boss)))
end

function Palace:finish(challenge, now, result, realNow)
    if self.playerControl then self.playerControl:close() end
    if challenge.mobPressure then challenge:closeMobPressure() end
    if self.state == "result" then return end
    if result ~= "success" then self:closeEnding() end
    self.milliseconds = self.milliseconds + Progress.elapsed(challenge.startedAt, now)
    if not self.practiceFloor then
        if result == "success" or not (self.tier and self.tier.assist) then Progress.discard(self.path) end
        local recorded, failure
        if self.tier then
            recorded, failure = pcall(Dream.log, self.profileBase, self.tier.id, self.cleared,
                self.milliseconds, result == "success" and "win" or "loss")
            if recorded and result == "failure" and self.tier.id == "deep" then
                local unlocked, value = pcall(function()
                    if not Dream.civilian(self.profileBase) and Dream.read(self.profileBase, "deep").failures >= 6 then
                        Dream.unlockCivilian(self.profileBase)
                        return true
                    end
                end)
                if unlocked then self.civilianUnlocked = value
                else log("civilian unlock: " .. tostring(value)) end
            end
        else
            recorded, failure = pcall(Progress.record, self.path, self.cleared, self.milliseconds, result)
        end
        if not recorded then log("result file: " .. tostring(failure)) end
    end
    self.state, self.result = "result", result
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
    if self.practiceFloor then
        challenge.message = result == "success" and "热身结束" or "热身战败"
    else
        challenge.message = result == "success" and "血宫通关" or "阵亡，本轮浊梦已结束"
    end
    log(("settled result=%s cleared=%d totalMs=%d"):format(result, self.cleared, self.milliseconds))
end

function Palace:coverEnding(challenge, gameplay, system, pawn, realNow)
    if self.endingReady then return true end
    if not self.ending then
        local ok, ending, reason, partial = pcall(function()
            return require("BloodyPalaceEnding").new(gameplay, system, pawn, challenge.scene)
        end)
        if ok and ending then
            self.ending = ending
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
    local portal = self.gateScene:update()
    if not portal then return end
    self.portal, self.gateScene, self.state = portal, nil, "gate"
    challenge.message = self.gateMessage or "靠近传送门，进入下一场"
    log("portal opened after floor " .. self.floor)
end

function Palace:updateResult(challenge, gameplay, pawn, now)
    if self.ending and not self.endingReady then
        local ok, ready = pcall(self.ending.update, self.ending, now)
        if ok and not ready then return end
        if not ok then
            log("ending playback fallback: " .. tostring(ready))
            self:closeEnding()
        end
        self.endingReady = true
    end
    if self.resultOpen then
        local ok, opened = pcall(Home.update, gameplay)
        if ok and opened then return end
        self.resultOpen = nil
        self.nextResult = now + .4
    elseif now >= (self.nextResult or 0) then
        local body = ("已完成 %d / %d 场\n战斗用时 %s"):format(self.cleared, Progress.count, Progress.format(self.milliseconds))
        if self.practiceFloor then
            body = ("第 %d 层\n战斗用时 %s"):format(self.practiceFloor, Progress.format(self.milliseconds))
        elseif self.tier then
            body = body .. "\n到达评级 " .. Dream.rank(self.cleared)
            if self.civilianUnlocked then body = body .. "\n已开放平民难度。每层战后保存，具名精英战后恢复。" end
        end
        local ok, failure = pcall(Home.prompt, pawn, gameplay:GetPlayerController(pawn, 0), challenge.message, body,
            function() challenge:queueAction("palace-exit") end)
        if ok then self.resultOpen = true
        else
            self.nextResult = now + 1
            if failure ~= self.menuError then log("settlement UI: " .. tostring(failure)); self.menuError = failure end
        end
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
        else self:updateResult(challenge, gameplay, pawn, realNow) end
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
    if self.shachiRecovery then
        local active = self.state == "combat" and challenge.startedAt and not challenge.transitionStep
            and not self.fade and not gameplay:IsGamePaused(pawn)
        Balance.recoverShachi(self.shachiRecovery, active and now or nil)
    end
    if challenge.mobPressure and self.state == "combat" and not challenge.mobPressure:step(now) then
        challenge:closeMobPressure()
    end
    challenge.difficulty = challenge.difficulty or require("GameplayDifficulty").new(pawn, Progress.difficulty)
    assert(challenge.difficulty:update(pawn) ~= false, "血宫难度已离开当前角色")
    if self.fade and self.fade:update(realNow) == "done" then self.fade = nil end
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
    assert(self.menu:update(realNow), "血宫系统菜单已离开当前角色")
    if self.state == "clearing" then
        if self.clearAt then
            if realNow < self.clearAt then return true end
            local mechanics = challenge.palaceMechanics
            if mechanics and not mechanics:deathEffectFinished(now, self.clearedAt) then return true end
            if not self.practiceFloor and hasEnding(self, challenge) and not self:coverEnding(challenge, gameplay, system, pawn, realNow) then
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
        if self.practiceFloor or self.floor == Progress.count then
            self:finish(challenge, now, "success", realNow)
            return true
        end
        if Progress.isCheckpoint(self.floor) or self.tier and self.tier.assist then
            Progress.save(self.path, self.floor, self.milliseconds, self.equipment, self.skills, self.tier and self.tier.assist)
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
            end
        end
        return true
    end
    if self.state == "moving" then
        if gameplay:IsGamePaused(pawn) or not self:cover(gameplay, pawn, realNow) then return true end
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
    if self.state == "result" or (self.closed and challenge.status ~= "error") then return nil end
    local stage = challenge.entry.stages[challenge.stageIndex]
    local target = stage and stage.name or challenge.entry.name
    if #challenge.entry.stages > 1 then
        target = ("%d/%d %s"):format(challenge.stageIndex, #challenge.entry.stages, target)
    end
    return { floor = self.floor, count = Progress.count, time = Progress.format(self.milliseconds
        + Progress.elapsed(challenge.startedAt, now)),
        target = self.practiceFloor and ("热身 · " .. target)
            or self.state == "preparing" and ("备战 · 玩家 %d 轮回"):format(self.playerCycle) or target }
end

function Palace:onMapPre(challenge)
    -- Stock respawn can replace the pawn between service ticks.
    if self.state ~= "result" and self.arenaEntered
        and (self.playerDied or valid(self.pawn) and dead(self.pawn)) then
        self:finish(challenge, challenge.lastPalaceTime or 0, "failure")
    end
end

function Palace:close()
    self.closed = true
    if self.playerControl then self.playerControl:close(); self.playerControl = nil end
    if self.stopDeathWatch then self.stopDeathWatch(); self.stopDeathWatch = nil end
    if self.music then self.music:close(); self.music = nil end
    self:closeLoadoutMemory()
    self:closeFade()
    self:closeGateScene()
    if self.resultOpen then pcall(Home.close); self.resultOpen = nil end
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
