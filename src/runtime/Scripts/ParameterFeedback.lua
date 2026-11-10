-- One stock UI event per parameter action. The original hover/click events
-- already embed Haptic_UI and the hover event also includes traditional Rumble.
-- Game settings and the native Wwise device path own both sound and vibration.
-- Never layer a second force-feedback source over them.
local Feedback = {}
local configured = setmetatable({}, { __mode = "v" })
local warned = {}
local posted = {}

local function unwrap(value)
    if value and type(value.IsValid) ~= "function" then
        local getter = value.get or value.Get
        if type(getter) == "function" then return getter(value) end
    end
    return value
end
local function valid(value) return value and type(value.IsValid) == "function" and value:IsValid() end
local function checked(value, message) value = unwrap(value); assert(valid(value), message); return value end
local function same(first, second)
    return valid(first) and valid(second) and first:GetAddress() == second:GetAddress()
end
local function required(path) return checked(StaticFindObject(path), "缺少反馈接口：" .. path) end
local function warn(kind, reason)
    local identifier = kind .. ":" .. tostring(reason)
    if not warned[identifier] then
        warned[identifier] = true
        print("[PBZTestArenaNative] Parameter " .. kind .. " feedback unavailable: " .. tostring(reason) .. "\n")
    end
end
function Feedback.configureArrow(button)
    button = unwrap(button)
    local ok, reason = pcall(function()
        assert(valid(button), "参数箭头无效")
        -- UPBZButtonBase's own sound gate is used by the stock DisplayQuest.js.
        assert(type(button.bCanPlaySound) == "boolean", "箭头缺少原版声音开关")
        button.bCanPlaySound = false
        assert(button.bCanPlaySound == false, "无法关闭箭头的自动声音")
        configured[button:GetAddress()] = button
    end)
    if not ok then warn("click", reason) end
    return ok
end

local function playSound(modal, expectedController, route)
        assert(valid(modal), "音效缺少有效的原生菜单")
        assert(modal:IsActivated(), "音效菜单已经关闭")
        local owner = checked(modal:GetOwningPlayer(), "声音菜单没有本地控制器")
        assert(owner:IsLocalPlayerController(), "音效控制器不是本地玩家")
        assert(not expectedController or same(owner, expectedController), "音效菜单与输入控制器不一致")
        local property = route == "navigation" and "PopupHoverSound" or "PopupClickSound"
        local sound = checked(modal[property], "原生菜单没有配置 " .. property)
        -- The game's BellMenu/UIHelper use this world subsystem and event API.
        -- A nil FScriptDelegate explicitly clears the callback in the pinned
        -- UE4SS delegate-property marshaller; no world-dependent sound
        -- blueprint is called after the modal has closed or lost its owner.
        local subsystem = checked(required("/Script/Engine.Default__SubsystemBlueprintLibrary"):
            GetWorldSubsystem(modal, required("/Script/ProjectPBZ.PBZSoundFXSubsystem")), "声音子系统不可用")
        local playingId = subsystem:PBZPostEventGlobal(sound, nil)
        assert(type(playingId) == "number" and playingId > 0,
            "原生 UI 音效没有返回有效 PlayingID：" .. tostring(playingId))
        if not posted[route] then
            posted[route] = true
            print("[PBZTestArenaNative] Parameter " .. route .. " feedback source: " .. sound:GetFullName()
                .. "; PlayingID=" .. tostring(playingId) .. "; native Wwise SFX+Haptic_UI"
                .. "; PCForceFeedbackEnabled=" .. tostring(owner.bForceFeedbackEnabled)
                .. "; PCForceFeedbackScale=" .. tostring(owner.ForceFeedbackScale) .. "\n")
        end
        return true
end

function Feedback.click(modal, button)
    modal, button = unwrap(modal), unwrap(button)
    local ok, played = pcall(function()
        assert(valid(button), "鼠标参数箭头无效")
        assert(same(configured[button:GetAddress()], button), "鼠标参数箭头尚未登记单音源")
        assert(button.bCanPlaySound == false, "鼠标参数箭头的自动声音未关闭")
        assert(button:GetIsEnabled(), "鼠标参数箭头当前不可操作")
        local owner = checked(button:GetOwningPlayer(), "鼠标参数箭头没有控制器")
        return playSound(modal, owner, "mouse")
    end)
    if not ok then warn("click", played); return false end
    return played
end

function Feedback.navigate(controller, modal)
    controller, modal = unwrap(controller), unwrap(modal)
    local ok, played = pcall(function()
        assert(valid(controller), "导航控制器无效")
        assert(controller:IsLocalPlayerController(), "导航控制器不是本地玩家")
        return playSound(modal, controller, "navigation")
    end)
    if not ok then warn("navigation", played); return false end
    return played
end

return Feedback
