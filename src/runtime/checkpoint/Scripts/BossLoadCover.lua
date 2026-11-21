local StageScreen = require("StageScreen")
local SceneArena = require("SceneArena")

local Cover = {}
Cover.__index = Cover
local DARK = { R = .007, G = .005, B = .008, A = 1 }

local function valid(object)
    return object ~= nil and type(object.IsValid) == "function" and object:IsValid()
end

local function address(object)
    if type(object) == "number" then return object end
    if valid(object) then return object:GetAddress() end
end

function Cover:isOwned(pawn, world)
    if self.closed or not self.screen then return false end
    local ok, owned = pcall(function()
        if address(pawn) ~= self.pawnAddress or address(world) ~= self.worldAddress
            or address(SceneArena.runtimeWorld(pawn)) ~= self.worldAddress then return false end
        local controller = self.controller
        if not valid(controller) or address(controller:GetWorld()) ~= self.worldAddress
            or address(controller:K2_GetPawn()) ~= self.pawnAddress then return false end
        local _, root = StageScreen.gameLayout(controller)
        return address(root) == self.rootAddress and valid(self.screen.border)
            and address(self.screen.border:GetParent()) == self.rootAddress
    end)
    return ok and owned == true
end

function Cover:close()
    if self.closed then return true end
    local failure
    local function release(field, action)
        if not self[field] then return end
        local ok, reason = pcall(action)
        if ok then self[field] = nil else failure = failure or reason end
    end
    release("lookHeld", function()
        if valid(self.controller) then self.controller:SetIgnoreLookInput(false) end
    end)
    release("moveHeld", function()
        if valid(self.controller) then self.controller:SetIgnoreMoveInput(false) end
    end)
    release("screen", function() self.screen:close() end)
    if failure then return false, failure end
    self.closed, self.controller = true, nil
    return true
end

function Cover.new(gameplay, pawn, world)
    local self = setmetatable({}, Cover)
    local ok, failure = pcall(function()
        self.pawnAddress = assert(address(pawn), "首领载入遮罩的角色尚未就绪")
        self.worldAddress = assert(address(world), "首领载入遮罩的场景尚未就绪")
        assert(address(SceneArena.runtimeWorld(pawn)) == self.worldAddress, "首领载入遮罩的角色不属于该场景")
        local controller = gameplay:GetPlayerController(pawn, 0)
        assert(valid(controller) and address(controller:GetWorld()) == self.worldAddress
            and address(controller:K2_GetPawn()) == self.pawnAddress, "首领载入遮罩的控制器不属于该场景")
        self.controller = controller
        self.screen = StageScreen.fullscreenCover(controller, DARK)
        self.rootAddress = assert(address(self.screen.root), "首领载入遮罩的界面尚未就绪")
        controller:SetIgnoreMoveInput(true)
        self.moveHeld = true
        controller:SetIgnoreLookInput(true)
        self.lookHeld = true
    end)
    if ok then return self end
    local closed = self:close()
    return nil, failure, not closed and self or nil
end

return Cover
