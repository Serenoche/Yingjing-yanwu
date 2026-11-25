local Data = require("BattleMusicData")
local Music, Player = {}, {}
Player.__index = Player
local Preview = {}
Preview.__index = Preview
local currentPlayer, currentPreview

local DEFAULT = "default"
local COLLECTION_EVENTS = "/Game/Wwise/Events/Mus/Mus_MusicPlayer/Exclusive_66/"
local SOUND = "/Script/ProjectPBZ.PBZSoundFXSubsystem"
local STOCK = "/Script/ProjectPBZ.MusicSubsystem"
local MIX = "/Game/Wwise/States/Mus/Mus_Volume_State/Mus_Volume_State-"
local VIDEO = "/Game/Wwise/States/System/VideoSoundOnly/VideoSoundOnly-"
local PENDING = 0x08023600
local ZERO, SCALE, FLAT = { X = 0, Y = 0, Z = 0 }, { X = 1, Y = 1, Z = 1 }, { Pitch = 0, Yaw = 0, Roll = 0 }
local choices, tracks = { DEFAULT }, {}
for _, row in ipairs(Data.tracks) do
    local id, title = row[1], row[2]
    choices[#choices + 1] = id
    tracks[id] = { title = title, index = #choices }
end

local function valid(object) return object and type(object.IsValid) == "function" and object:IsValid() end
local function ready(object) return valid(object) and not object:HasAnyFlags(PENDING) end
local function log(message) print("[PBZArenaMusic] " .. message .. "\n") end

local function find(path)
    local object = StaticFindObject(path)
    assert(ready(object), "缺少音乐接口 " .. path)
    return object
end

local function asset(path, class)
    local object = StaticFindObject(path)
    if not ready(object) then LoadAsset(path); object = StaticFindObject(path) end
    assert(ready(object) and object:IsA(find(class)), "音乐资源不可用 " .. path)
    return object
end

local function subsystem(context, path)
    return find("/Script/Engine.Default__SubsystemBlueprintLibrary"):GetWorldSubsystem(context, find(path))
end

local function statePath(region, state)
    local group = region == "VS2" and "Mus_GamePlay" or "Mus_GamePlay_" .. region
    local name = group .. "-" .. state
    return "/Game/Wwise/States/Mus/" .. group .. "/" .. name .. "." .. name
end

local function playing(id)
    return type(id) == "number" and id ~= 0 and id ~= -1 and id ~= 0xffffffff
end

function Music.normalize(id)
    return type(id) == "string" and tracks[id] and id or DEFAULT
end

function Music.label(id)
    local track = tracks[Music.normalize(id)]
    return track and track.title or "默认"
end

function Music.canPreview(id) return Music.normalize(id) ~= DEFAULT end

function Music.step(id, direction)
    local track = tracks[Music.normalize(id)]
    local index = track and track.index or 1
    return choices[(index - 1 + direction) % #choices + 1]
end

local function gameplayCue(binding)
    local region, state = binding[1], binding[2]
    local event = "Mus_GamePlay_" .. region
    return { region = region, state = state,
        event = "/Game/Wwise/Events/Mus/Mus_GamePlay/" .. event .. "." .. event,
        loopState = binding[3], introSeconds = binding[4] }
end

local function collectionEvent(id)
    local event = Data.eventOverrides[id] or id
    return COLLECTION_EVENTS .. event .. "." .. event
end

function Music.resolve(entry, id)
    id = Music.normalize(id)
    if id ~= DEFAULT then
        local battle = Data.combat[id]
        if battle then
            local cue = gameplayCue(battle)
            cue.track = id
            if battle.ostIntro then cue.opening, cue.openingSeconds = collectionEvent(id), battle.ostIntro end
            return cue
        end
        return { track = id, event = collectionEvent(id) }
    end
    local stage = entry and entry.stages and entry.stages[1]
    local member = stage and stage.members[1]
    local binding = member and Data.bosses[member.id]
    if not binding then return nil, member and member.id end
    local cue = gameplayCue(binding)
    cue.target = member.id
    return cue
end

function Player:setState(path)
    self.ak:SetState(asset(path, "/Script/AkAudio.AkStateValue"))
end

function Player:openBus()
    self.mix = true
    self:setState(VIDEO .. "DoNothing.VideoSoundOnly-DoNothing")
    self:setState(MIX .. "Common.Mus_Volume_State-Common")
end

function Player:guard()
    if not ready(self.stock) then return end
    local restarted = self.stock.bDontInitMusic == false
    if restarted then self.stock:SetMusicInitDisabled(true) end
    if playing(self.stock.CurPlayingID_Gameplay) or playing(self.stock.CurPlayingID_Story) then
        self.stock:DisableGameplayMusic(true)
        self.stock:ClearMusic(0.15, true, true)
        restarted = true
        log("清除重新启动的场景音乐")
    end
    if restarted and playing(self.id) then
        self:openBus()
        if self.state then self:setState(statePath(self.cue.region, self.state)) end
    end
end

function Player:prepare(eventPath)
    -- Resolve the event first: a failed load must not leave an empty component
    -- that a later retry mistakes for a player ready to post.
    local event = asset(eventPath, "/Script/AkAudio.AkAudioEvent")
    if not ready(self.component) then
        local mathLibrary = find("/Script/Engine.Default__KismetMathLibrary")
        if ready(self.actor) then pcall(self.actor.K2_DestroyActor, self.actor) end
        local transform = mathLibrary:MakeTransform(self.pawn:K2_GetActorLocation(), FLAT, SCALE)
        self.actor = self.gameplay:BeginDeferredActorSpawnFromClass(self.pawn, find("/Script/Engine.Actor"), transform, 1, self.pawn, 1)
        assert(ready(self.actor), "音乐组件对象无法创建")
        local actor = self.gameplay:FinishSpawningActor(self.actor, transform, 1)
        assert(ready(actor) and actor:GetAddress() == self.actor:GetAddress(), "音乐组件对象无法生成")
        self.component = self.actor:AddComponentByClass(find("/Script/AkAudio.AkComponent"), false,
            mathLibrary:MakeTransform(ZERO, FLAT, SCALE), false)
        assert(ready(self.component), "音乐组件无法注册")
    end
    self.component.AkAudioEvent = event
    assert(ready(self.component.AkAudioEvent), "音乐组件未持有音频事件")
end

function Player:post(now, battle)
    local opening = self.cue.opening and not battle
    self:prepare(opening and self.cue.opening or self.cue.event)
    self:openBus()
    if self.cue.region and not opening then
        self.state = self.cue.state
        self:setState(statePath(self.cue.region, self.state))
    end
    local id = self.sound:PBZPostEventOnAkComponent(self.component.AkAudioEvent, self.component, nil, true, false, 0)
    assert(playing(id), "Wwise 没有返回播放 ID")
    self.id, self.start, self.misses = id, now, 0
    self.opening = opening == true
    self.battle = battle == true
    self.sourceSeen, self.nextTransition = nil, nil
    self.nextSource = now + 1
    currentPlayer = self
    local source = self.state and self.cue.region .. "/" .. self.state or opening and "原声开头" or "原声曲目"
    log(("播放 %s %s id=%d"):format(self.cue.track or self.cue.target, source, id))
end

function Player:stop(fade)
    if playing(self.id) and ready(self.sound) then
        local ok, why = pcall(self.sound.PBZStopPlayingID, self.sound, self.id, fade or 0)
        if not ok then log("停止失败 " .. tostring(why)) end
    end
    self.id, self.nextSource, self.sourceSeen = nil, nil, nil
    if currentPlayer == self then currentPlayer = nil end
end

function Player:close()
    self:stop(0)
    if ready(self.actor) then pcall(self.actor.K2_DestroyActor, self.actor) end
    self.actor, self.component = nil, nil
    if self.state then pcall(self.setState, self, statePath(self.cue.region, "None")); self.state = nil end
    if self.mix then
        pcall(self.setState, self, VIDEO .. "None.VideoSoundOnly-None")
        pcall(self.setState, self, MIX .. "None.Mus_Volume_State-None")
        self.mix = nil
    end
    if self.suppressed and ready(self.stock) then
        pcall(self.stock.SetMusicInitDisabled, self.stock, self.previousInit)
        pcall(self.stock.DisableGameplayMusic, self.stock, false)
    end
    self.suppressed = nil
    self.pausedAt, self.resuming = nil, nil
end

function Music.new(gameplay, pawn, cue)
    local self = setmetatable({ gameplay = gameplay, pawn = pawn, cue = cue, nextTick = 0 }, Player)
    local ok, reason = pcall(function()
        self.stock, self.sound = subsystem(pawn, STOCK), subsystem(pawn, SOUND)
        assert(ready(self.stock) and ready(self.sound), "演武音乐子系统未就绪")
        self.ak = find("/Script/AkAudio.Default__AkGameplayStatics")
        self.previousInit = self.stock.bDontInitMusic == true
        self.suppressed = true
        self.stock:SetMusicInitDisabled(true)
        self.stock:DisableGameplayMusic(true)
        self.stock:ClearMusic(0.2, true, true)
    end)
    if not ok then self:close(); return nil, reason end
    log("已停用本场地原版音乐")
    return self
end

local function position(sound, id)
    local output = {}
    local live = sound:GetPlayingIDPositionMs(id, output)
    local value = live and tonumber(output.OutPositionMs)
    return live, value and value > 0 and value or nil
end

function Player:advanceOpening(now)
    if not playing(self.id) then return false end
    local cue = self.cue
    local native = cue.loopState and self.state ~= cue.loopState
    local limit = self.opening and cue.openingSeconds or native and cue.introSeconds
    local elapsed = now - (self.start or now)
    if not limit or elapsed < limit - .5 or now < (self.nextTransition or 0) then return false end
    self.nextTransition = now + .10
    local live, ms = position(self.sound, self.id)
    local reached = ms and ms >= limit * 1000
    local finished = self.opening and not live and self.sourceSeen
    local fallback = elapsed >= limit + .75
    if not reached and not finished and not fallback then return false end
    if self.opening then
        -- Resolve the loop before retiring the opening, so an asset load failure cannot silence it.
        asset(cue.event, "/Script/AkAudio.AkAudioEvent")
        asset(statePath(cue.region, cue.state), "/Script/AkAudio.AkStateValue")
        self:stop(0.12)
        self.battle = true
        self:post(now, true)
    else
        self:setState(statePath(cue.region, cue.loopState))
        self.state = cue.loopState
        log(("战斗段循环 %s %s/%s id=%d"):format(cue.track or cue.target, cue.region, self.state, self.id))
    end
    return true
end

function Player:update(now, active)
    if self.pausedAt then
        if not self.resuming then return false end
        self.start = self.start + math.max(0, self.resuming - self.pausedAt)
        self.pausedAt, self.resuming = nil, nil
    end
    if active and self:advanceOpening(now) then return true end
    if now < self.nextTick and (not active or self.wasActive) then return false end
    self.wasActive = active
    self.nextTick = now + 0.5
    self:guard()
    if not active then return true end
    if not playing(self.id) then
        self:post(now, self.battle)
        return true
    end
    if self.nextSource and now >= self.nextSource then
        self.nextSource = now + 1
        local live = position(self.sound, self.id)
        if live then
            if not self.sourceSeen then log(("音频源已起播 id=%d"):format(self.id)) end
            self.sourceSeen, self.misses = true, 0
            if self.state then self.nextSource = nil end
        else
            self.misses = self.misses + 1
            -- A finite OST event ends on its own. Repost only after the
            -- engine confirmed that the previous ID had a live source.
            if self.sourceSeen and self.misses >= 2 then
                if self.opening then self.battle = true end
                self:stop(0)
            end
            if not self.sourceSeen and self.misses == 4 then
                log(("播放位置尚未返回 id=%d"):format(self.id))
                -- Some events provide no source position. Leave the playing ID
                -- alone and stop sampling it; a blind repost can stack audio.
                self.nextSource = nil
            end
        end
    end
    return true
end

function Preview:close()
    if currentPreview ~= self then return end
    currentPreview = nil
    if ready(self.sound) and playing(self.id) then
        local ok, why = pcall(self.sound.PBZStopPlayingID, self.sound, self.id, 0)
        if not ok then log("停止试听失败 " .. tostring(why)) end
    end
    local player = self.pausedPlayer
    if player and currentPlayer == player and player.id == self.pausedId and ready(player.sound) then
        local ok, now = pcall(self.gameplay.GetRealTimeSeconds, self.gameplay, self.context)
        local resumed, why = pcall(player.sound.PBZResumePlayingID, player.sound, player.id, 0.1)
        player.resuming = ok and now or self.lastNow
        if not resumed then log("恢复战斗音乐失败 " .. tostring(why)) end
    end
    log("停止试听 " .. self.track)
end

function Preview:update(now)
    if currentPreview ~= self then return false end
    self.lastNow = now
    if not ready(self.sound) then self:close(); return false end
    if self.pausedAt then return true end
    if now >= self.finishAt then self:close(); return false end
    if now >= self.nextSource then
        self.nextSource = now + 1
        local ok, live = pcall(position, self.sound, self.id)
        if ok and live then self.sourceSeen, self.misses = true, 0
        elseif ok and self.sourceSeen then
            self.misses = self.misses + 1
            if self.misses >= 2 then self:close(); return false end
        end
    end
    return true
end

function Preview:togglePause(now)
    assert(currentPreview == self and ready(self.sound) and playing(self.id), "试听已结束")
    if self.pausedAt then
        self.sound:PBZResumePlayingID(self.id, 0.1)
        self.finishAt = self.finishAt + math.max(0, now - self.pausedAt)
        self.pausedAt, self.nextSource, self.misses = nil, now + 1, 0
    else
        self.sound:PBZPausePlayingID(self.id, 0.1)
        self.pausedAt = now
    end
end

function Preview:seconds()
    if currentPreview ~= self or not ready(self.sound) or not playing(self.id) then return end
    local ok, live, value = pcall(position, self.sound, self.id)
    if ok and live then return (value or 0) / 1000 end
end

function Music.preview(gameplay, context, id)
    if not Music.canPreview(id) then return nil end
    if currentPreview then currentPreview:close() end
    local now = gameplay:GetRealTimeSeconds(context)
    local self = setmetatable({ gameplay = gameplay, context = context, track = id, lastNow = now, nextSource = now + 1 }, Preview)
    currentPreview = self
    local ok, reason = pcall(function()
        self.sound = subsystem(context, SOUND)
        assert(ready(self.sound), "试听音频子系统未就绪")
        local event = asset(collectionEvent(id), "/Script/AkAudio.AkAudioEvent")
        local duration = tonumber(event.MaximumDuration)
        self.finishAt = now + (duration and duration > 0 and duration or 300)
        local player = currentPlayer
        if player and playing(player.id) and ready(player.sound) and player.sound:GetAddress() == self.sound:GetAddress() then
            if player.pausedAt and player.resuming then
                player.start = player.start + math.max(0, player.resuming - player.pausedAt)
                player.pausedAt = nil
            end
            if not player.pausedAt then player.sound:PBZPausePlayingID(player.id, 0.1) end
            player.pausedAt, player.resuming = player.pausedAt or now, nil
            self.pausedPlayer, self.pausedId = player, player.id
        end
        self.id = self.sound:PBZPostEventGlobal(event, nil)
        assert(playing(self.id), "Wwise 没有返回试听播放 ID")
        log(("试听 %s id=%d"):format(id, self.id))
    end)
    if not ok then self:close(); return nil, reason end
    return self
end

return Music
