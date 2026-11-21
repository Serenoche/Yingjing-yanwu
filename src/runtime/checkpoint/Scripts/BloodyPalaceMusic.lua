local Music = {}
Music.__index = Music

local FADE_SECONDS = 0.5
local TRANSITION_VOLUME = 0.22
local PENDING = 0x08023600
local VOLUME_STATE = "/Game/Wwise/States/Mus/Mus_Volume_State/Mus_Volume_State-"
local VIDEO_STATE = "/Game/Wwise/States/System/VideoSoundOnly/VideoSoundOnly-"
local ONE, ZERO, FLAT = { X = 1, Y = 1, Z = 1 }, { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 }
-- The original MoYuan outro plays the final flute phrase once.
local RESULT_CUE = {
    title = "赤黑诀别", region = "XiGu", state = "MoYuan_P2Outro", volume = .62,
}
local SCORE_GAIN, BACKGROUND_GAIN = .62, .46
local SCORE_MENU_FADE = .90
-- The full score is posted from the game's local Wwise bank.
local RESULT_SCORE = {
    title = "赤黑诀别", region = "Deluxe64",
    event = "/Game/Wwise/Events/Mus/Mus_MusicPlayer/Exclusive_66/Deluxe64.Deluxe64",
    volume = SCORE_GAIN, repeatAfter = 217.38463,
}

-- These states contain the game's authored combat playlists. The combat
-- segment loops inside Wwise after the entrance segment plays once.
local bands = {
    { floor = 1,  title = "古琴千岁", region = "PangZhen", state = "YanQianSui_Engage" },
    { floor = 11, title = "婉约歌声", region = "PangZhen", state = "GuWanYue_Engage" },
    { floor = 21, title = "铁玉合璧", region = "LuJiaCun", state = "MuXiaoKui_P3" },
    { floor = 31, title = "冥火流星", region = "PangZhen", state = "HuoLiuXing_P2" },
    { floor = 41, title = "独眼利弓", region = "PangZhen", state = "DuYan_Engage" },
    { floor = 51, title = "嗔恨修罗", region = "FuJiZhiLin", state = "BanyanTreeBoss" },
    { floor = 61, title = "狮尊归位", region = "PangZhen", state = "WuShi_P2" },
    { floor = 71, title = "绝望剑意", region = "ZhengDaoDaYing", state = "JianOu_P2" },
    { floor = 91, title = "跋扈万里2026", region = "Prologue", state = "Duel_Engage_01" },
}

local bosses = {
    BP_Monster_YuCong_FirstTime = { region = "XiGu", state = "EliteMonster_Engage" },
    BP_Monster_MuXiaoKui_P2 = { region = "LuJiaCun", state = "MuXiaoKui_P2" },
    BP_Monster_YuBi = { region = "ZhengDaoDaYing", state = "YuBi" },
    BP_Monster_LeiDang = { region = "XiMengShanZhuang", state = "LeiDang_P1" },
    BP_Monster_LeiDang_P2 = { region = "XiMengShanZhuang", state = "LeiDang_P2" },
    -- The opening segment exits at 49385ms. The original switch to P2 fades
    -- into the dizi loop, so request it during the last beat of the opening.
    BP_Monster_MoTian = { region = "XiGu", state = "MoYuan_P1", loopState = "MoYuan_P2", introExitMs = 49385 },
    BP_Monster_ZuoShang_Ending = { region = "DuanHun", state = "ZuoShang_P1" },
    BP_Monster_ZuoShang_P2 = { region = "DuanHun", state = "ZuoShang_P2" },
    BP_Monster_AHua_GuiTouDao = { region = "XiGu", state = "GhostBride_Engage" },
    BP_Monster_Yuu = { region = "FuJiZhiLin", state = "YuYaoTieGui_Engage" },
    BP_Monster_TieGui = { region = "FuJiZhiLin", state = "YuYaoTieGui_Engage" },
    BP_Monster_WuLengShuang = { region = "ZhengDaoDaYing", state = "WuLengShuang" },
    BP_Monster_FemaleVessel_YuDing = { region = "XiMengShanZhuang", state = "YuDing_Engage" },
    BP_Monster_FengXueDaoKe = { region = "PangZhen", state = "FengXueDaoKe_Engage" },
}

function Music.cue(floor, stage)
    if not stage.regularMobs then return bosses[stage.members[1].id] end
    for index = #bands, 1, -1 do
        if floor >= bands[index].floor then return bands[index] end
    end
end

local function log(message) print("[PBZBloodyPalace] music " .. message .. "\n") end
local function valid(object) return object and type(object.IsValid) == "function" and object:IsValid() end
local function usable(object) return valid(object) and not object:HasAnyFlags(PENDING) end

local function playing(id)
    return type(id) == "number" and id ~= 0 and id ~= -1 and id ~= 0xffffffff
end

local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "missing " .. path)
    return object
end

local function asset(path, class)
    local object = StaticFindObject(path)
    if not usable(object) then
        LoadAsset(path)
        object = StaticFindObject(path)
    end
    assert(usable(object) and object:IsA(required("/Script/AkAudio." .. class)), "invalid audio asset " .. path)
    return object
end

local function eventPath(region)
    local name = "Mus_GamePlay_" .. region
    return "/Game/Wwise/Events/Mus/Mus_GamePlay/" .. name .. "." .. name
end

local function statePath(region, state)
    local group = "Mus_GamePlay_" .. region
    local name = group .. "-" .. state
    return "/Game/Wwise/States/Mus/" .. group .. "/" .. name .. "." .. name
end

function Music:openMusicBus()
    -- Opening a map or a cinematic can leave either of these global music
    -- gates closed. Both defaults route gameplay music through its own slider.
    self.ak:SetState(asset(VIDEO_STATE .. "DoNothing.VideoSoundOnly-DoNothing", "AkStateValue"))
    self.mixChanged = true
    self.ak:SetState(asset(VOLUME_STATE .. "Common.Mus_Volume_State-Common", "AkStateValue"))
    self.mixReady = true
end

function Music.new(gameplay, pawn)
    local self = setmetatable({ gameplay = gameplay, pawn = pawn, groups = {}, retiring = {} }, Music)
    local ok, why = pcall(function()
        local library = required("/Script/Engine.Default__SubsystemBlueprintLibrary")
        self.stock = library:GetWorldSubsystem(pawn, required("/Script/ProjectPBZ.MusicSubsystem"))
        self.sound = library:GetWorldSubsystem(pawn, required("/Script/ProjectPBZ.PBZSoundFXSubsystem"))
        assert(usable(self.stock) and usable(self.sound), "world audio subsystems unavailable")
        self.ak = required("/Script/AkAudio.Default__AkGameplayStatics")
        self.math = required("/Script/Engine.Default__KismetMathLibrary")
        self.actorClass = required("/Script/Engine.Actor")
        self.componentClass = required("/Script/AkAudio.AkComponent")
        self.previousInitDisabled = self.stock.bDontInitMusic == true
        self.stock:SetMusicInitDisabled(true)
        self.initSuppressed = true
        self.stock:DisableGameplayMusic(true)
        self.stockSuppressed = true
        self.stock:ClearMusic(0.25, true, true)
    end)
    if not ok then
        log("unavailable: " .. tostring(why))
        self:close()
        return nil
    end
    log("scene music suppressed; waiting for combat")
    return self
end

function Music:dispose(voice)
    if not voice then return end
    if playing(voice.id) and usable(self.sound) then
        local ok, why = pcall(self.sound.PBZStopPlayingID, self.sound, voice.id, 0)
        if not ok then log("stop unavailable: " .. tostring(why)) end
    end
    if usable(voice.actor) then
        local ok, why = pcall(voice.actor.K2_DestroyActor, voice.actor)
        if not ok then log("component owner cleanup: " .. tostring(why)) end
    end
end

function Music:makeVoice(cue)
    local voice = { region = cue.region, volume = 1 }
    local ok, why = pcall(function()
        assert(usable(self.pawn), "audio owner no longer in the arena")
        local location = self.pawn:K2_GetActorLocation()
        local world = self.math:MakeTransform({ X = location.X, Y = location.Y, Z = location.Z }, FLAT, ONE)
        local relative = self.math:MakeTransform(ZERO, FLAT, ONE)
        voice.actor = self.gameplay:BeginDeferredActorSpawnFromClass(self.pawn, self.actorClass, world, 1, self.pawn, 1)
        assert(usable(voice.actor), "could not create the music component owner")
        local actor = self.gameplay:FinishSpawningActor(voice.actor, world, 1)
        assert(usable(actor), "could not finish the music component owner")
        voice.actor = actor
        voice.component = actor:AddComponentByClass(self.componentClass, false, relative, false)
        assert(usable(voice.component) and voice.component:IsA(self.componentClass), "could not register the music component")
        -- The registered component owns the event through its UPROPERTY. A Lua
        -- UObject wrapper alone does not keep a streamed event alive across GC.
        local event = asset(cue.event or eventPath(cue.region), "AkAudioEvent")
        voice.component.AkAudioEvent = event
        assert(usable(voice.component.AkAudioEvent) and voice.component.AkAudioEvent:GetAddress() == event:GetAddress(),
            "music component did not retain its event")
    end)
    if ok then return voice end
    self:dispose(voice)
    return nil, why
end

local function setVolume(voice, volume)
    if voice.volumeUnavailable or not usable(voice.component) then return end
    local ok, why = pcall(voice.component.SetOutputBusVolume, voice.component, volume)
    if ok then
        voice.volume = volume
    else
        voice.volumeUnavailable = true
        log("component gain unavailable: " .. tostring(why))
    end
end

local function fade(voice, to, now, duration)
    voice.fade = { from = voice.volume, to = to, start = now, duration = duration or FADE_SECONDS }
end

local function updateFade(voice, now)
    local curve = voice.fade
    if not curve then return end
    local t = math.max(0, math.min(1, (now - curve.start) / curve.duration))
    setVolume(voice, curve.from + (curve.to - curve.from) * t)
    if t == 1 then voice.fade = nil end
end

function Music:duck(now)
    if self.voice then fade(self.voice, TRANSITION_VOLUME, now) end
end

function Music:prepareCue(cue, label)
    if self.voice and self.voice.region == cue.region and usable(self.voice.component) then return end
    if self.prepared and self.prepared.region == cue.region and usable(self.prepared.component) then return end
    self:dispose(self.prepared)
    local voice, why = self:makeVoice(cue)
    self.prepared = voice
    if not voice then log(label .. " preload: " .. tostring(why)) end
end

function Music:prepare(floor, stage)
    local cue = Music.cue(floor, stage)
    if cue then self:prepareCue(cue, "floor=" .. floor) end
end

function Music:retire(voice, now)
    if voice then
        fade(voice, 0, now)
        self.retiring[#self.retiring + 1] = voice
    end
end

function Music:apply(pending, now)
    local cue = pending.cue
    local voice = self.voice
    local volume = cue.volume
    if cue == RESULT_SCORE and self.resultBehindMenu then volume = volume * BACKGROUND_GAIN end
    if not self.mixReady then self:openMusicBus() end
    if voice and voice.region == cue.region and usable(voice.component) then
        if voice.state ~= cue.state then
            self.ak:SetState(asset(statePath(cue.region, cue.state), "AkStateValue"))
            voice.state = cue.state
        end
        fade(voice, volume or 1, now)
        return
    end
    local nextVoice = self.prepared
    if not nextVoice or nextVoice.region ~= cue.region or not usable(nextVoice.component) then
        self:dispose(nextVoice)
        self.prepared = nil
        local why
        nextVoice, why = self:makeVoice(cue)
        assert(nextVoice, why)
        self.prepared = nextVoice
    end
    if cue.state then
        self.groups[cue.region] = true
        self.ak:SetState(asset(statePath(cue.region, cue.state), "AkStateValue"))
    end
    local component = nextVoice.component
    assert(usable(component) and usable(component.AkAudioEvent) and usable(self.sound), "music event was unloaded before posting")
    setVolume(nextVoice, volume or TRANSITION_VOLUME)
    local id = self.sound:PBZPostEventOnAkComponent(component.AkAudioEvent, component, nil, true, false, 0.0)
    assert(playing(id), "no PlayingID returned")
    nextVoice.id, nextVoice.state, nextVoice.result = id, cue.state, pending.duringResult
    nextVoice.probeAt, nextVoice.probeCount = now + 0.75, 0
    nextVoice.repeatAt = cue.repeatAfter and now + cue.repeatAfter
    self.voice, self.prepared = nextVoice, nil
    if not volume then fade(nextVoice, 1, now) end
    self:retire(voice, now)
end

function Music:guardStock(now)
    if now < (self.nextStockCheck or 0) or not usable(self.stock) then return end
    self.nextStockCheck = now + 0.5
    local restarted = self.stock.bDontInitMusic == false
    if restarted then self.stock:SetMusicInitDisabled(true) end
    local gameplayId, storyId = self.stock.CurPlayingID_Gameplay, self.stock.CurPlayingID_Story
    if playing(gameplayId) or playing(storyId) then
        self.stock:DisableGameplayMusic(true)
        self.stock:ClearMusic(0.2, true, true)
        log(("cleared resumed scene music gameplay=%s story=%s"):format(tostring(gameplayId), tostring(storyId)))
        restarted = true
    end
    local voice = self.voice
    if restarted then
        self.mixReady = nil
        if voice then
            self:openMusicBus()
            -- Keep the active branch if the scene posts to the same state group.
            if voice.state then self.ak:SetState(asset(statePath(voice.region, voice.state), "AkStateValue")) end
        end
    end
end

function Music:attempt(now)
    local pending = self.pending
    if not pending or now < pending.nextAt then return end
    local ok, why = pcall(self.apply, self, pending, now)
    if ok then
        local voice, cue = self.voice, pending.cue
        if cue.loopState then
            voice.intro = { loopState = cue.loopState, exitMs = cue.introExitMs,
                startGameTime = self.gameplay:GetTimeSeconds(self.pawn) }
        end
        log(("%s %s/%s id=%d"):format(pending.label, cue.region, cue.state or "full track", voice.id))
        self.pending = nil
    elseif pending.attempts < 2 then
        pending.attempts, pending.nextAt = pending.attempts + 1, now + 0.5
    else
        log(pending.label .. " unavailable: " .. tostring(why))
        self.pending = nil
        self:dispose(self.prepared)
        self.prepared = nil
        if self.voice then fade(self.voice, 1, now) end
    end
end

function Music:advanceIntro(voice, now)
    local intro = voice.intro
    if not intro or now < (intro.nextCheck or 0) then return end
    local elapsedMs = (self.gameplay:GetTimeSeconds(self.pawn) - intro.startGameTime) * 1000
    if elapsedMs < intro.exitMs - 4000 then return end
    intro.nextCheck = now + .10
    local position = {}
    local read, running = pcall(self.sound.GetPlayingIDPositionMs, self.sound, voice.id, position)
    local nearExit = read and running and type(position.OutPositionMs) == "number"
        and position.OutPositionMs >= intro.exitMs - 400
    if not nearExit and elapsedMs < intro.exitMs + 1200 then return end
    local switched, reason = pcall(function()
        self.ak:SetState(asset(statePath(voice.region, intro.loopState), "AkStateValue"))
    end)
    if switched then
        voice.state, voice.intro = intro.loopState, nil
        log(("intro finished; state=%s id=%d positionMs=%s"):format(voice.state, voice.id,
            nearExit and tostring(position.OutPositionMs) or "unavailable"))
    elseif not intro.warning then
        intro.warning = true
        log("intro transition pending: " .. tostring(reason))
    end
end

function Music:update(now, allowPlayback)
    local ok, why = pcall(self.guardStock, self, now)
    if not ok and not self.stockWarning then log("scene music guard: " .. tostring(why)); self.stockWarning = true end
    if allowPlayback or self.pending and self.pending.duringResult then self:attempt(now) end
    for index = #self.retiring, 1, -1 do
        local old = self.retiring[index]
        updateFade(old, now)
        if not old.fade then self:dispose(old); table.remove(self.retiring, index) end
    end
    local voice = self.voice
    if not voice then return end
    if voice.repeatAt and now >= voice.repeatAt then
        self:dispose(voice)
        self.voice = nil
        self:beginCue(RESULT_SCORE, now, "local result score=" .. RESULT_SCORE.title, true)
        return
    end
    updateFade(voice, now)
    if allowPlayback and usable(self.sound) then self:advanceIntro(voice, now) end
    if not voice.probeAt or now < voice.probeAt or not usable(self.sound) then return end
    local position = {}
    local queried, running = pcall(self.sound.GetPlayingIDPositionMs, self.sound, voice.id, position)
    if queried and running and type(position.OutPositionMs) == "number" and position.OutPositionMs > 0 then
        log(("source active id=%d positionMs=%d"):format(voice.id, position.OutPositionMs))
        voice.probeAt = nil
    elseif voice.probeCount >= 2 then
        log(("source position unavailable id=%d state=%s"):format(voice.id, voice.state or "full track"))
        voice.probeAt = nil
    else
        voice.probeCount, voice.probeAt = voice.probeCount + 1, now + 1
    end
end

function Music:prepareResult(weaponShot)
    local cue = weaponShot and RESULT_SCORE or RESULT_CUE
    self:prepareCue(cue, "local result score")
end

function Music:playResult(now, weaponShot)
    local cue = weaponShot and RESULT_SCORE or RESULT_CUE
    self:beginCue(cue, now, "local result score=" .. cue.title, true)
end

function Music:softenResult(now)
    if self.resultBehindMenu then return end
    self.resultBehindMenu = true
    local voice = self.voice
    if voice and voice.result and voice.region == RESULT_SCORE.region then
        fade(voice, SCORE_GAIN * BACKGROUND_GAIN, now, SCORE_MENU_FADE)
    end
end

function Music:beginCue(cue, now, label, duringResult)
    self:stopRetry()
    self.pending = { cue = cue, label = label, nextAt = now, attempts = 0, duringResult = duringResult }
    self:attempt(now)
end

function Music:play(floor, stageIndex, stage, now)
    local cue = Music.cue(floor, stage)
    if not cue then
        log(("no combat cue for floor=%d stage=%d"):format(floor, stageIndex))
        return
    end
    local title = cue.title or stage.name or stage.members[1].id
    self:beginCue(cue, now, ("floor=%d stage=%d cue=%s"):format(floor, stageIndex, title))
end

function Music:stopRetry()
    self.pending = nil
    if self.voice then self.voice.intro = nil end
end

function Music:finish(now)
    self:stopRetry()
    self:dispose(self.prepared)
    self.prepared = nil
    self:retire(self.voice, now)
    self.voice = nil
end

function Music:stopResult()
    self.resultBehindMenu = nil
    if self.pending and self.pending.duringResult then
        self.pending = nil
        self:dispose(self.prepared)
        self.prepared = nil
    end
    if self.voice and self.voice.result then
        self:dispose(self.voice)
        self.voice = nil
    end
end

function Music:close()
    self:stopResult()
    self:stopRetry()
    self:dispose(self.voice)
    self:dispose(self.prepared)
    for _, voice in ipairs(self.retiring) do self:dispose(voice) end
    self.voice, self.prepared, self.retiring = nil, nil, {}
    for region in pairs(self.groups) do
        local ok, why = pcall(function()
            self.ak:SetState(asset(statePath(region, "None"), "AkStateValue"))
        end)
        if not ok then log("state cleanup: " .. tostring(why)) end
    end
    self.groups = {}
    if self.mixChanged then
        local ok, why = pcall(function()
            self.ak:SetState(asset(VIDEO_STATE .. "None.VideoSoundOnly-None", "AkStateValue"))
            self.ak:SetState(asset(VOLUME_STATE .. "None.Mus_Volume_State-None", "AkStateValue"))
        end)
        if not ok then log("music mix cleanup: " .. tostring(why)) end
        self.mixChanged, self.mixReady = nil, nil
    end
    if usable(self.stock) then
        if self.initSuppressed then
            local ok, why = pcall(self.stock.SetMusicInitDisabled, self.stock, self.previousInitDisabled)
            if not ok then log("scene music initialization cleanup: " .. tostring(why)) end
        end
        if self.stockSuppressed then
            local ok, why = pcall(self.stock.DisableGameplayMusic, self.stock, false)
            if not ok then log("stock audio cleanup: " .. tostring(why)) end
        end
    end
    self.stockSuppressed, self.initSuppressed = nil, nil
end

return Music
