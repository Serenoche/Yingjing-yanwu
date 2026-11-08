-- Native camera interpolation plus a passive UMG screen over the game's HUD.
local StageScreen = require("StageScreen")
local StageFade, Fade = {}, {}
Fade.__index = Fade
local DURATION, BLACK_HOLD = 0.50, 0.70

local function valid(object)
    return object ~= nil and type(object.IsValid) == "function" and object:IsValid()
end
local function finite(value)
    return type(value) == "number" and value > -math.huge and value < math.huge
end
local function time(value)
    assert(finite(value), "阶段转场时钟无效")
    return value
end
local function black() return { R = 0, G = 0, B = 0, A = 1 } end

function Fade:gameTime()
    assert(valid(self.pawn) and valid(self.camera), "阶段转场相机或玩家已失效")
    local world, cameraWorld = self.pawn:GetWorld(), self.camera:GetWorld()
    assert(valid(world) and valid(cameraWorld) and world:GetAddress() == self.worldAddress
        and cameraWorld:GetAddress() == self.worldAddress, "阶段转场不能跨越世界")
    return time(self.gameplay:GetTimeSeconds(self.pawn))
end

function Fade:close()
    if self.closed then return end
    local screenClosed, screenError = true, nil
    if self.screen then screenClosed, screenError = pcall(self.screen.close, self.screen) end
    local reset, resetError, stopped, stopError = true, nil, true, nil
    if valid(self.camera) then
        -- Both calls target the originally captured local camera, never a new
        -- world's camera. Attempt Stop even if the manual reset fails.
        reset, resetError = pcall(self.camera.SetManualCameraFade, self.camera, 0, black(), false)
        stopped, stopError = pcall(self.camera.StopCameraFade, self.camera)
    end
    assert(screenClosed and reset and stopped, tostring(screenError or resetError or stopError))
    self.closed, self.phase = true, "done"
end

function StageFade.new(gameplay, pawn, realNow)
    time(realNow)
    assert(valid(pawn), "阶段转场玩家不可用")
    local world = pawn:GetWorld()
    assert(valid(world), "阶段转场世界不可用")
    -- The shipped BP_GameMode_Build uses this reflected GameplayStatics call.
    local camera = gameplay:GetPlayerCameraManager(pawn, 0)
    assert(valid(camera), "找不到阶段转场的本地相机")
    local cameraWorld = camera:GetWorld()
    assert(valid(cameraWorld) and cameraWorld:GetAddress() == world:GetAddress(), "阶段转场相机属于其他世界")
    local startedGame = time(gameplay:GetTimeSeconds(pawn))
    local self = setmetatable({ gameplay = gameplay, pawn = pawn, camera = camera,
        worldAddress = world:GetAddress(), phase = "out", startedGame = startedGame }, Fade)
    local ok, failure = pcall(function()
        self.screen = StageScreen.new(gameplay, pawn)
        self.screen:setAlpha(0)
        camera:SetManualCameraFade(0, black(), false)
        camera:StartCameraFade(0, 1, DURATION, black(), false, true)
    end)
    if not ok then pcall(self.close, self); error(failure, 0) end
    return self
end

function Fade:update(realNow)
    time(realNow)
    if self.closed then return "done" end
    local gameNow = self:gameTime()
    -- A clock rewind must not reuse an elapsed deadline from a prior epoch.
    if gameNow < self.startedGame then self.startedGame = gameNow end
    local progress = math.max(0, math.min(1, (gameNow - self.startedGame) / DURATION))
    self.screen:setAlpha(self.phase == "out" and progress or self.phase == "in" and 1 - progress or 1)
    if self.phase == "out" and gameNow - self.startedGame >= DURATION then
        -- Force the exact boundary before callers teleport/spawn. A stalled
        -- frame starts a fresh hold now; it cannot skip the black phase.
        self.camera:SetManualCameraFade(1, black(), false)
        self.phase, self.blackAt = "black", realNow
    elseif self.phase == "in" and gameNow - self.startedGame >= DURATION then
        self:close()
    end
    return self.phase
end

function Fade:canReveal(realNow)
    time(realNow)
    return not self.closed and self.phase == "black" and realNow - self.blackAt >= BLACK_HOLD
end

function Fade:reveal(realNow)
    assert(self:canReveal(realNow), "阶段转场尚未完成黑屏停留")
    self.startedGame = self:gameTime()
    self.camera:StartCameraFade(1, 0, DURATION, black(), false, false)
    self.phase = "in"
end

return StageFade
