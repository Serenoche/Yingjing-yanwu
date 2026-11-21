local Tabs = require("ArenaMapPolicy")
local Menu = {}
Menu.__index = Menu

local CONFIRMATION = "/Script/CommonGame.AsyncAction_ShowConfirmation:ShowConfirmationYesNo"
local SETTINGS = "/Game/PBZContent/UI/GameSystem/Settings/W_PBZSettingPanel.W_PBZSettingPanel_C"
local LIBRARY = "/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary"
local EXIT_ACTIONS = { { "UI_Setting_17", "退出游戏" }, { "UI_GameMenu_01", "离开浊梦" } }

local function valid(object)
    return object and type(object.IsValid) == "function" and object:IsValid()
end

function Menu:newExitMessage(context, body)
    if not self.exitProgress or not self.policy or not self.policy:active() then return end
    local panel = context:get()
    local class = StaticFindObject(SETTINGS)
    if not valid(panel) or not valid(class) or not panel:IsA(class) then return end
    local owner, world = panel:GetOwningPlayer(), panel:GetWorld()
    if not valid(owner) or owner:GetAddress() ~= self.controller:GetAddress()
        or not valid(world) or world:GetAddress() ~= self.policy.world then return end

    local library = StaticFindObject(LIBRARY)
    if not valid(library) then return end
    local original = body:get():ToString()
    if original == "" then return end
    for _, action in ipairs(EXIT_ACTIONS) do
        if original == library:MakeTextByKey(action[1]):ToString() then
            local saved, previousFloor = self.exitProgress()
            if saved == nil then return end
            local notice
            if saved then
                notice = "当前进度已保存。"
            elseif previousFloor then
                notice = ("现在%s，下次可从第 %d 层存档点继续，进入第 %d 层。")
                    :format(action[2], previousFloor, previousFloor + 1)
            else
                notice = "尚未到达存档点，下次将从第 1 层开始。"
            end
            body:set(FText(notice .. "\n\n" .. original))
            return
        end
    end
end

function Menu.new(pawn, controller, gate, exitProgress)
    local self = setmetatable({ pawn = pawn, controller = controller, gate = gate, exitProgress = exitProgress }, Menu)
    if exitProgress then
        -- Keep the original two buttons and their native result callbacks.
        local ok, pre, post = pcall(RegisterHook, CONFIRMATION, function(_, context, _, body)
            local updated, reason = pcall(self.newExitMessage, self, context, body)
            if not updated and not self.exitPromptError then
                self.exitPromptError = true
                print("[PBZBloodyPalace] exit confirmation: " .. tostring(reason) .. "\n")
            end
        end)
        if ok and pre and post then self.exitHook = { pre, post }
        else print("[PBZBloodyPalace] exit confirmation hook unavailable: " .. tostring(pre) .. "\n") end
    end
    return self
end

function Menu:holdPlayer()
    if self.holding then return end
    self.controller:SetIgnoreMoveInput(true)
    self.holding = true
end

function Menu:releasePlayer()
    if not self.holding then return end
    if self.controller:IsValid() then self.controller:SetIgnoreMoveInput(false) end
    self.holding = nil
end

function Menu:restrict(systemOnly)
    if self.policy and self.systemOnly ~= systemOnly then
        local closed, reason = self.policy:close()
        if not closed then return false, reason end
        self.policy = nil
    end
    if not self.policy then
        self.policy = systemOnly and Tabs.only(self.pawn, self.controller, self.gate, "System")
            or Tabs.only(self.pawn, self.controller, self.gate, "Character", "System")
        self.systemOnly = systemOnly
    end
    assert(not self.policy.closed, self.policy.lastError or "血宫原版菜单初始化失败")
    return true
end

function Menu:update(now)
    return self.policy:update(self.pawn, now)
end

function Menu:close()
    local reason
    self.exitProgress = nil
    if self.exitHook then
        local ok, why = pcall(UnregisterHook, CONFIRMATION, self.exitHook[1], self.exitHook[2])
        if ok then self.exitHook = nil else reason = why end
    end
    if self.policy then
        local ok, done, why = pcall(self.policy.close, self.policy)
        if ok and done then self.policy = nil else reason = ok and why or done end
    end
    local ok, why = pcall(self.releasePlayer, self)
    if not ok then reason = why end
    return not self.policy and not self.holding and not self.exitHook, reason
end

return Menu
