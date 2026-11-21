"""Enable equipment projection in the generated stock checkpoint reader."""

import shutil
from pathlib import Path


def _edit(path, replacements):
    source = path.read_text(encoding="utf-8")
    for original, updated, count in replacements:
        if source.count(original) != count:
            raise ValueError(f"Unexpected checkpoint generator output in {path.name}: {original!r}")
        source = source.replace(original, updated)
    path.write_text(source, encoding="utf-8", newline="\n")


def stage(directory: Path):
    _edit(directory / "stock_profiles.hpp", (
        ('#include "vendor/json.hpp"', '#include "vendor/json.hpp"\n#include "checkpoint_loadout.hpp"', 1),
        ('    std::wstring slot, text;', '    std::wstring slot, text;\n    bool loadout_projected = false;', 1),
        ('    SelectedPreset& output, std::string& reason) {',
         '    SelectedPreset& output, std::string& reason, std::string_view loadout = {}) {', 1),
        ('        data[pbz_save::utf8(slot)] = compose(presets, slot, cycle);',
         '''        auto record = compose(presets, slot, cycle);
        const auto projected = !loadout.empty() && project_equipment(record, loadout);
        data[pbz_save::utf8(slot)] = std::move(record);''', 1),
        ('        output = {slot, std::move(text)};', '        output = {slot, std::move(text), projected};', 1),
    ))
    _edit(directory / "barrier.cpp", (
        ('int active_cycle = -2;', 'int active_cycle = -2;\nstd::string active_loadout;\nbool active_loadout_projected = false;', 1),
        ('    int cycle = -2;', '    int cycle = -2;\n    std::string loadout;', 1),
        ('    bool ok = GetFileSizeEx(file, &size) && size.QuadPart > 0 && size.QuadPart <= 160',
         '''    constexpr int max_request_bytes = 2176;
    bool ok = GetFileSizeEx(file, &size) && size.QuadPart > 0 && size.QuadPart <= max_request_bytes''', 1),
        ('    char bytes[160]{};', '    char bytes[max_request_bytes]{};', 1),
        ('        const auto cycle = request.substr(slot_end + 1);',
         r'''        const auto cycle_end = request.find('\t', slot_end + 1);
        const auto cycle = request.substr(slot_end + 1, cycle_end - slot_end - 1);
        if (cycle_end != std::string::npos) selection->loadout = request.substr(cycle_end + 1);''', 1),
        ('&& selection.slot == active_slot && selection.cycle == active_cycle',
         '&& selection.slot == active_slot && selection.cycle == active_cycle && selection.loadout == active_loadout', 1),
        ('(selection.slot != active_slot || selection.cycle != active_cycle)',
         '(selection.slot != active_slot || selection.cycle != active_cycle || selection.loadout != active_loadout)', 1),
        ('selection.slot, selection.cycle, preset, reason)', 'selection.slot, selection.cycle, preset, reason, selection.loadout)', 2),
        ('''\n                    active_slot = std::move(selection.slot); active_cycle = selection.cycle;
''', '''\n                    active_slot = std::move(selection.slot); active_cycle = selection.cycle;
                    active_loadout = std::move(selection.loadout); active_loadout_projected = preset.loadout_projected;
''', 1),
        ('''\n                active_slot = std::move(selection.slot); active_cycle = selection.cycle;
''', '''\n                active_slot = std::move(selection.slot); active_cycle = selection.cycle;
                active_loadout = std::move(selection.loadout); active_loadout_projected = preset.loadout_projected;
''', 1),
        ('active_presets = {}; active_slot.clear(); active_cycle = -2;',
         'active_presets = {}; active_slot.clear(); active_cycle = -2;\n                    active_loadout.clear(); active_loadout_projected = false;', 1),
        (r'''    if (ok && action == Operation::select) write_status(path + L".status", nonce + "\tselected\n");''',
         r'''    if (ok && action == Operation::select) {
        write_status(path + L".status", nonce + (active_loadout_projected ? "\tselected\tprojected\n" : "\tselected\n"));
    } else if (ok && action == Operation::arm && active_loadout_projected) {
        write_status(path + L".status", nonce + "\tarmed\tprojected\n");
    }''', 1),
        ('extern "C" __declspec(dllexport) int __cdecl PBZBarrierSelectCheckpoint(void*) { return operation(Operation::select); }',
         '''extern "C" __declspec(dllexport) int __cdecl PBZBarrierSelectCheckpoint(void*) { return operation(Operation::select); }
extern "C" __declspec(dllexport) int __cdecl PBZBarrierCheckpointLoadoutV1(void*) { return 0; }''', 1),
    ))


def stage_compatibility(scripts: Path):
    """Apply the shared loadout, combat and checkpoint rules to the three-map runtime."""
    sources = Path(__file__).resolve().parents[1] / "src"
    shared = {
        "runtime/Scripts": ("ArenaLoadout.lua", "ArenaLoadoutMemory.lua", "ArenaLoadoutRestore.lua", "CombatSpawn.lua",
                            "InstalledPathIdentity.lua", "SpawnClass.lua", "TrainingMobCatalog.lua"),
        "runtime/checkpoint/Scripts": ("BloodyPalaceMenu.lua", "BloodyPalaceProgress.lua",
                                       "DreamPalaceMobPressure.lua", "DreamPalaceMobPressureRules.lua",
                                       "DreamPalaceFengXuePursuit.lua", "DreamPalacePlayerControl.lua",
                                       "AsyncClassLoad.lua", "PreloadReferences.lua", "RetryPreload.lua"),
        "dream_palace": ("DreamPalaceBalance.lua", "DreamPalacePressurePolicy.lua"),
    }
    for folder, names in shared.items():
        for name in names:
            shutil.copyfile(sources / folder / name, scripts / name)

    _edit(scripts / "Integration.lua", (
        ('''    local accountPrefix = install .. "/projectpbz/saved/savegames/" .. (epic and "eos/" or "steam/")
    local path = config.savePath:lower()''',
         '''    local accountPrefix = "/projectpbz/saved/savegames/" .. (epic and "eos/" or "steam/")
    local path = config.savePath:lower()
    install = require("InstalledPathIdentity").installRoot(install, path, accountPrefix)
    accountPrefix = install .. accountPrefix''', 1),
    ))
    _edit(scripts / "TitleSession.lua", (
        ('local function failureMessage(failure, barrier)\n    failure = tostring(failure)',
         '''local function failureMessage(failure, barrier)
    failure = tostring(failure)
    if failure:find("wait for the title save index", 1, true) or failure:find("test save manager is unavailable", 1, true) then
        return "游戏正在读取存档，请稍等几秒再进入影境演武。"
    end
    if failure:find("title probe Continue", 1, true) then
        return "当前没有可继续的普通存档。请先进入本篇保存一次，再回到主界面进入影境演武。"
    end''', 1),
        ('        if not self:initialize(controller) then return end',
         '        if (not self.options.integrated or self.options.disposable) and not self:initialize(controller) then return end', 1),
        ('    if actual~=self.expectedProvider then return false,"installed MOD save provider differs from current game account"end',
         '''    if actual ~= self.expectedProvider and not require("InstalledPathIdentity").sameSave(self.expectedProvider, actual) then
        return false, "installed MOD save provider differs from current game account"
    end''', 1),
    ))

    _edit(scripts / "main.lua", (
        ('    if challenge and not palace then challenge:close() end',
         '    if challenge and not palace then challenge:close(true) end', 1),
        ('''local function service()
    drainServiceCleanup()''', '''local function service()
    drainServiceCleanup()
    if challenge and challenge.retryPreload then require("RetryPreload").expire(challenge) end''', 1),
        ('''            if challenge then challenge:closeMusic() end
            closeArenaServices()''', '''            if challenge then
                if challenge.retryPreload and (not titleSession or titleSession.phase ~= "loading") then
                    require("RetryPreload").close(challenge)
                end
                challenge:closeMusic()
            end
            closeArenaServices()''', 1),
        ('''local function checkpointArenaServices(pawn,slot)
    -- This explicit MOD command runs before native LoadGame can change arrays.
    if arenaServices and arenaServices.memory then pcall(arenaServices.memory.beginLoad,arenaServices.memory,pawn)end
    closeArenaServices()
    servicesAllowed=false
    expectedServiceSlot=slot
end''', '''local function checkpointArenaServices(_,slot)
    closeArenaServices()
    servicesAllowed=false
    expectedServiceSlot=slot
end
local function rememberBellLoadout(pawn)
    if not arenaServices or not arenaServices.initialized then return false end
    local palace = challenge and challenge.palace
    local memory = palace and palace.loadout or arenaServices.memory
    return not memory or memory:remember(pawn) ~= nil
end''', 1),
        ('''    if arenaServices.memory then
        local ok,accepted,reason=pcall(arenaServices.memory.update,arenaServices.memory,pawn,realNow)''',
         '''    if arenaServices.memory and arenaServices.memory.state == "pending" then
        local ok,accepted,reason=pcall(arenaServices.memory.update,arenaServices.memory,pawn)''', 1),
        ('{loadoutMemoryPath=loadoutMemoryPath,onBeforeLoad=checkpointArenaServices})',
         '{loadoutMemoryPath=loadoutMemoryPath,onBeforeLoad=checkpointArenaServices,onBellSave=rememberBellLoadout})', 1),
        ('                            skillMemory = skillMemory,',
         '                            skillMemory = skillMemory, onBellSave = rememberBellLoadout,', 1),
        ('''                        local privateLoadout
                        if not settings.palacePractice then privateLoadout = dream.loadout(palaceLoadoutPath, settings.palaceTier) end''',
         '''                        local privateLoadout = palaceLoadoutPath and dream.loadout(palaceLoadoutPath, settings.palaceTier)
                        local warmupEquipment
                        if settings.palacePractice then
                            warmupEquipment = require("ArenaLoadoutMemory").checkpointSelection(privateLoadout)
                        end
                        if settings.palacePractice or settings.palaceResume then privateLoadout = nil end''', 1),
        ('                                resume = settings.palaceResume })',
         '                                resume = settings.palaceResume, warmupEquipment = warmupEquipment })', 1),
    ))
    _edit(scripts / "BloodyPalace.lua", (
        ('local Loadout = require("ArenaLoadout")',
         'local Loadout = require("ArenaLoadout")\nlocal LoadoutRestore = require("ArenaLoadoutRestore")', 1),
        ('local Dream = require("DreamPalaceProfile")',
         'local Dream = require("DreamPalaceProfile")\nlocal Balance = require("DreamPalaceBalance")', 1),
        ('        practiceFloor = admission and admission.practice, resumeOnEntry = admission and admission.resume,',
         '        practiceFloor = admission and admission.practice, resumeOnEntry = admission and admission.resume,\n'
         '        warmupEquipment = admission and admission.warmupEquipment,', 1),
        ('''    if pawn then
        if self.loadout.state == "ready" then
            local ok, skills = pcall(Ability.capture, pawn)
            if ok then self.loadout:setAbility(pawn, skills) end
        end
        self.loadout:beginLoad(pawn)
    end''', '''    if pawn and self.loadout.state == "ready" then
        local ok, skills = pcall(Ability.capture, pawn)
        if ok then self:rememberAbility(pawn, skills) end
    end''', 1),
        ('''    if self.loadout then
        local ready = self.loadout:update(pawn, now)''',
         '''    if self.warmupEquipment then
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
        local ready = self.loadout:update(pawn)''', 1),
        ('''    if self.loadout then
        -- Check native equip delivery before flushing, while the private
        -- backpack still contains the player's preparation choices.
        local selected, why = Loadout.capture(pawn)
        if not selected then self.waitReason = why; return end
        self:closeLoadoutMemory(pawn)
    end
    if not self.equipment then''', '    if not self.equipment then', 1),
        ('''        self.equipment, self.skills = equipment, Ability.capture(pawn)''',
         '''        self.equipment, self.skills = equipment, Ability.capture(pawn)
        if self.loadout then
            if not self.testRange then
                self.loadout:setAbility(pawn, self.skills)
                self.loadout:remember(pawn, equipment)
            end
            self:closeLoadoutMemory()
        end''', 1),
        ('''        if not self.prepared then self:prepareAtBell(challenge, gameplay, pawn, realNow)
        elseif self.loadout then self.loadout:update(pawn, realNow) end''',
         '        if not self.prepared then self:prepareAtBell(challenge, gameplay, pawn, realNow) end', 1),
        ('''            local ready, why = Loadout.apply(pawn, self.checkpoint.equipment)
            if not ready then
                assert(not tostring(why):find("unavailable:", 1, true), why)
                challenge.message, self.waitReason = "正在恢复血宫配装", why
                return
            end''',
         '''            self.checkpointRestore = self.checkpointRestore or LoadoutRestore.new(self.checkpoint.equipment)
            local ready, why = self.checkpointRestore:update(pawn)
            assert(ready ~= false, "浊梦存点配装恢复失败：" .. tostring(why))
            if not ready then
                self.deadline = realNow + 15
                challenge.message, self.waitReason = "正在恢复血宫配装", why
                return
            end
            self.checkpointRestore = nil''', 1),
        ('''function Palace:prepareAtBell(challenge, gameplay, pawn, now)''',
         '''function Palace:exitProgress()
    if not self.arenaEntered or self.practiceFloor or self.state == "result" then return end
    return self.checkpointFloor == self.floor, self.checkpointFloor
end

function Palace:prepareAtBell(challenge, gameplay, pawn, now)''', 1),
        ('''        self.menu = Menu.new(pawn, controller, function() return not self.closed and self.ownsArena() end)''',
         '''        self.menu = Menu.new(pawn, controller, function() return not self.closed and self.ownsArena() end,
            function() return self:exitProgress() end)''', 1),
        ('''        self.pawn, self.pawnAddress = pawn, pawn:GetAddress()''',
         '''        self.pawn, self.pawnAddress = pawn, pawn:GetAddress()
        if self.tier then self.shachiTalentModel = Balance.readPlayerTalentModel(pawn, self.tier.cycle * 5) end''', 1),
        ('''        self.floor, self.cleared, self.milliseconds = checkpoint.cleared, checkpoint.cleared, checkpoint.milliseconds''',
         '''        self.floor, self.cleared, self.milliseconds = checkpoint.cleared, checkpoint.cleared, checkpoint.milliseconds
        self.checkpointFloor = checkpoint.cleared''', 1),
        ('''    if not resources or not medicines then return false, reason end
    self.recovery, self.medicine = nil, nil''',
         '''    if not resources or not medicines then return false, reason end
    if self.playerShachiBase then Balance.restorePlayerShachi(pawn, self.playerShachiBase) end
    self.recovery, self.medicine = nil, nil''', 1),
        ('''    self.arenaEntered = true
    log("player placed inside FogDoor14; floor=" .. self.floor)''',
         '''    if self.tier then
        local cycle, value, base = Balance.setPlayerShachi(pawn, self.tier.id, self.skills.HeiShi8, self.shachiTalentModel)
        self.playerShachiBase = base
        log(("player ShachiAttack; cycle=%d; value=%.2f"):format(cycle, value))
        self.playerControl = require("DreamPalacePlayerControl").start(pawn)
    end
    self.stopDeathWatch = Progress.watchDeath(self, pawn, log)
    self.arenaEntered = true
    log("player placed inside FogDoor14; floor=" .. self.floor)''', 1),
        ('''function Palace:onStageReady(challenge)
    local stage = challenge.entry.stages[challenge.stageIndex]''',
         '''function Palace:onStageReady(challenge)
    local stage = challenge.entry.stages[challenge.stageIndex]
    local floor = Progress.sourceFloor(self.floor)
    self.shachiRecovery = Balance.recoveryTargets(stage, challenge.bosses, floor, self.tier and self.tier.id)
    if self.tier and floor == 101 and not challenge.fengXuePursuit then
        challenge.fengXuePursuit = require("DreamPalaceFengXuePursuit").start(self.pawn, stage, challenge.bosses)
    end
    if self.tier and stage.regularMobs and not challenge.mobPressure then
        challenge.mobPressure = require("DreamPalaceMobPressure").start(self.pawn, challenge.bosses, stage.members, floor)
    end''', 1),
        ('''function Palace:finish(challenge, now, result, realNow)''',
         '''function Palace:finish(challenge, now, result, realNow)
    if self.playerControl then self.playerControl:close() end
    if challenge.mobPressure then challenge:closeMobPressure() end''', 1),
        ('''    if self.pawnAddress and (pawn:GetAddress() ~= self.pawnAddress or dead(pawn)) then
        if not self.arenaEntered then
            challenge:queueAction("palace-exit")
            challenge:updateMenuOnly(gameplay, system, pawn, now)
        else
            self:finish(challenge, now, "failure", realNow)
        end
        return true
    end''',
         '''    if self.pawnAddress and (self.playerDied or pawn:GetAddress() ~= self.pawnAddress or dead(pawn)) then
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
    end''', 1),
        ('''            Progress.save(self.path, self.floor, self.milliseconds, self.equipment, self.skills, self.tier and self.tier.assist)''',
         '''            Progress.save(self.path, self.floor, self.milliseconds, self.equipment, self.skills, self.tier and self.tier.assist)
            self.checkpointFloor = self.floor''', 1),
        ('''    if self.state ~= "result" and self.arenaEntered and valid(self.pawn) and dead(self.pawn) then''',
         '''    if self.state ~= "result" and self.arenaEntered
        and (self.playerDied or valid(self.pawn) and dead(self.pawn)) then''', 1),
        ('''function Palace:close()
    self.closed = true''',
         '''function Palace:close()
    self.closed = true
    if self.playerControl then self.playerControl:close(); self.playerControl = nil end
    if self.stopDeathWatch then self.stopDeathWatch(); self.stopDeathWatch = nil end''', 1),
    ))
    _edit(scripts / "Challenge.lua", (
        ('local SpawnClass = require("SpawnClass")',
         'local SpawnClass = require("SpawnClass")\nlocal RetryPreload = require("RetryPreload")', 1),
        ('    self.status, self.message, self.reloadAt = "resetting", "正在重读挑战存档", realNow',
         '''    self.status, self.message, self.reloadAt = "resetting", "正在重读挑战存档", realNow
    if action == "retry" then RetryPreload.start(self, gameplay, pawn, realNow)
    else RetryPreload.close(self) end''', 1),
        ('        if self.nextSpawn and now < self.nextSpawn then return end',
         '''        if not RetryPreload.beforeSpawn(self, gameplay, pawn) then return end
        if self.nextSpawn and now < self.nextSpawn then return end''', 1),
        ('    self.bosses = actors', '    self.bosses = actors\n    RetryPreload.close(self)', 1),
        ('function Challenge:close()', 'function Challenge:close(mapTransition)\n    RetryPreload.close(self, mapTransition)', 1),
        ('function Challenge:fail(message)', 'function Challenge:fail(message)\n    RetryPreload.close(self)', 1),
        ('''    if self.reloadAt then
        if realNow < self.reloadAt then return true end''', '''    if self.reloadAt then
        if realNow < self.reloadAt then return true end
        if not RetryPreload.beforeReload(self, gameplay, pawn, realNow) then return true end''', 1),
        ('''function Challenge:clearStage()''',
         '''function Challenge:closeMobPressure()
    local session = self.mobPressure
    if not session then return end
    self.mobPressure = nil
    session:close()
end

function Challenge:clearStage()
    self:closeMobPressure()
    if self.fengXuePursuit then
        self.fengXuePursuit:close()
        self.fengXuePursuit = nil
    end''', 1),
        ('        skillMemory = slots.skillMemory, selectCheckpoint = slots.selectCheckpoint,',
         '        skillMemory = slots.skillMemory, selectCheckpoint = slots.selectCheckpoint, onBellSave = slots.onBellSave,', 1),
        ('        self.bellOpen = ok and active == true', '''        local opened = ok and active == true
        if not opened or not self.bellOpen then self.bellLoadoutHandled = nil end
        if opened and self.onBellSave and not self.bellLoadoutHandled then
            self.bellLoadoutHandled = self.onBellSave(pawn)
        end
        self.bellOpen = opened''', 1),
        ('''return CombatSpawn.finish(gameplay, pawn, deferred, transform, enemyCycle, true)''',
         '''return CombatSpawn.finish(gameplay, pawn, deferred, transform, enemyCycle, true, entry.statCycles)''', 1),
    ))
    return (*(name for names in shared.values() for name in names), "main.lua", "BloodyPalace.lua", "Challenge.lua",
            "Integration.lua", "TitleSession.lua")
