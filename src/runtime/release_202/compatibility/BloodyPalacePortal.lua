local Portal = {}
Portal.__index = Portal
local ASSET = "/Game/PBZContent/VFX/SceneFX/Sequence/S_FX_Seqs029/NS_Seqs029_Portal_601.NS_Seqs029_Portal_601"
local RADIUS, HEIGHT, HYSTERESIS = 240, 270, 65
local DESIRED_AGE = 1 -- ENiagaraAgeUpdateMode::DesiredAge
local OPEN_AGE = .85 -- The stock closing curves begin at about one second.
local REALTIME_AGE = 0 -- ENiagaraAgeUpdateMode::TickDeltaTime
local RIM_PERIOD = 1.35 -- The original rim's timed emission curves reach zero by 1.3s.
local aperture = { "NE_Portal01", "NE_PortalRef01", "NE_Ref", "NE_Light", "Audio" }
local particles = { "NE_PortalEng01", "NE_PortalSmoke01", "NE_PortalSmoke02", "NE_PortalSmoke03",
    "NE_Debris01", "NE_Debris02", "NE_Debris03", "NE_Ref02" }
local PENDING = 0x08023600
Portal.safeDistance = RADIUS + 100

local function valid(object) return object and object:IsValid() end
local function ready(asset) return valid(asset) and not asset:HasAnyFlags(PENDING) end

local function near(at, point, radius)
    return math.abs(at.Z - point.Z) <= HEIGHT and (at.X - point.X)^2 + (at.Y - point.Y)^2 <= radius^2
end

function Portal.contains(pawn, point)
    return near(pawn:K2_GetActorLocation(), point, RADIUS)
end

local function loadAsset()
    local asset = StaticFindObject(ASSET)
    if ready(asset) then return asset end
    local ok, loaded, _, complete = pcall(LoadAsset, ASSET)
    -- The registry can return a ready asset before a fresh object lookup does.
    if ok and complete == true and ready(loaded) then return loaded end
    asset = StaticFindObject(ASSET)
    if ready(asset) then return asset end
    return nil, "正在等待传送门特效载入"
end

function Portal.new(gameplay, pawn, destination, openingDuration)
    local asset, reason = loadAsset()
    if not asset then return nil, reason end
    local world = pawn:GetWorld():GetAddress()
    local library = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
    assert(valid(library), "游戏传送门特效接口未就绪")
    local function spawn()
        return library:SpawnSystemAtLocation(pawn, asset, destination.visualPosition, destination.rotation,
            { X = 1, Y = 1, Z = 1 }, false, false, 0, false)
    end
    local component = spawn()
    if not valid(component) then return nil, "正在等待传送门特效组件" end
    local rim = spawn()
    if not valid(rim) then
        component:K2_DestroyComponent(component)
        return nil, "正在等待传送门粒子组件"
    end
    local ok, failure = pcall(function()
        for _, part in ipairs({ component, rim }) do
            part:SetAllowScalability(false)
            part:SetForceSolo(true)
            part:SetAgeUpdateMode(DESIRED_AGE)
            part:SetLockDesiredAgeDeltaTimeToSeekDelta(false)
            part:SetDesiredAge(0)
        end
        -- Apply emitter overrides before the first simulation tick. They are
        -- kept on the component when the Niagara instance restarts.
        for _, name in ipairs(particles) do component:SetEmitterEnable(FName(name), false) end
        for _, name in ipairs(aperture) do rim:SetEmitterEnable(FName(name), false) end
    end)
    if not ok then
        pcall(component.K2_DestroyComponent, component, component)
        pcall(rim.K2_DestroyComponent, rim, rim)
        error(failure, 0)
    end
    return setmetatable({ gameplay = gameplay, component = component, rim = rim, point = destination.position,
        world = world, age = 0, updates = 0, longestGap = 0,
        playbackRate = OPEN_AGE / (openingDuration or OPEN_AGE) }, Portal)
end

function Portal:stopFrameUpdates()
    if not self.frameAction then return end
    CancelDelayedAction(self.frameAction)
    self.frameAction = nil
end

function Portal:advance(now)
    if self.age >= OPEN_AGE then
        -- The Niagara component has had a tick to consume the final age.
        if valid(self.rim) then self.rim:SetAgeUpdateMode(REALTIME_AGE) end
        self.open, self.rimRefreshAt = true, now + RIM_PERIOD - OPEN_AGE
        self:stopFrameUpdates()
        print(("[PBZBloodyPalace] portal VFX open; updateMode=%s; updates=%d; maxGameGapMs=%.1f\n")
            :format(self.updateMode, self.updates, self.longestGap * 1000))
        return
    end
    local age = math.min((now - self.openedAt) * self.playbackRate, OPEN_AGE)
    if age <= self.age then return end
    self.component:SetDesiredAge(age)
    if valid(self.rim) then self.rim:SetDesiredAge(age) end
    self.age = age
    self.updates = self.updates + 1
    self.longestGap = math.max(self.longestGap, now - self.lastUpdateAt)
    self.lastUpdateAt = now
end

function Portal:advanceFrame()
    if not valid(self.component) then self:stopFrameUpdates(); return end
    self:advance(self.gameplay:GetTimeSeconds(self.component))
end

function Portal:activate(pawn, now)
    assert(valid(self.component) and valid(self.rim) and not self.openedAt and pawn:GetWorld():GetAddress() == self.world,
        "血宫传送门特效未就绪或场景已切换")
    self.component:Activate(true)
    self.rim:Activate(true)
    self.openedAt, self.needsExit = now, Portal.contains(pawn, self.point)
    self.lastUpdateAt, self.updateMode = now, "service"
    if EngineTickAvailable and type(LoopInGameThreadAfterFrames) == "function"
        and type(CancelDelayedAction) == "function" then
        local ok, handle = pcall(LoopInGameThreadAfterFrames, 1, function()
            if not self.frameAction then return end
            local advanced, reason = pcall(self.advanceFrame, self)
            if not advanced then
                self:stopFrameUpdates()
                self.updateMode = "service"
                print("[PBZBloodyPalace] portal VFX frame update fallback: " .. tostring(reason) .. "\n")
            end
        end)
        if ok and type(handle) == "number" and handle > 0 then
            self.frameAction, self.updateMode = handle, "frame"
        end
    end
end

function Portal:update(now)
    assert(valid(self.component), "血宫传送门特效已意外离场")
    -- The rim is authored as a one-shot. Replay only the perimeter emitters,
    -- so its particles continue to move without replaying the opening sound or aperture.
    if self.open and valid(self.rim) and now >= self.rimRefreshAt then
        self.rim:Activate(true)
        self.rimRefreshAt = now + RIM_PERIOD
    end
    if self.openedAt and not self.open and not self.frameAction then self:advance(now) end
    return self.open == true
end

function Portal:entered(pawn)
    if self.consumed or pawn:GetWorld():GetAddress() ~= self.world then return false end
    local at = pawn:K2_GetActorLocation()
    if self.needsExit then
        if not near(at, self.point, RADIUS + HYSTERESIS) then self.needsExit = false end
        return false
    end
    if not self.open or not near(at, self.point, RADIUS) then return false end
    self.consumed = true
    return true
end

function Portal:close()
    self.consumed = true
    self:stopFrameUpdates()
    if valid(self.component) then self.component:K2_DestroyComponent(self.component) end
    if valid(self.rim) then self.rim:K2_DestroyComponent(self.rim) end
    self.component, self.rim = nil, nil
end

return Portal
