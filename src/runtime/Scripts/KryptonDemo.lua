-- A title-modal comedy sketch. All balances, items and combat are fictional
-- Lua values. No actor, backpack, save, settings, network or payment API is used.
local Screen = require("NativeScreen")
local Art = require("ArtAssets")
local Demo, Model, View = {}, {}, {}
Model.__index, View.__index = Model, View
local GOLD = { 1, .73, .30 }
local PURPLE = { .74, .51, 1 }
local BLUE = { .45, .69, 1 }
local WHITE = { .94, .92, .87 }
local MUTED = { .64, .65, .68 }
local RED = { 1, .36, .34 }
local TEAL = { .37, .85, .75 }
local ROLLS = { 23, 23, 23, 23, 23 }
local STEPS = { "01  限时祈愿", "02  圣遗物强化", "03  逐利深渊", "04  回归单机" }

local function valid(object)
    return object and type(object.IsValid) == "function" and object:IsValid()
end
local function required(path)
    local object = StaticFindObject(path)
    assert(valid(object), "恶搞演示的原生 UI 接口不可用：" .. path)
    return object
end
local function tint(widget, color)
    widget:OverrideTextColor({ SpecifiedColor = { R = color[1], G = color[2], B = color[3], A = 1 }, ColorUseRule = 0 })
    return widget
end
local function label(screen, value, x, y, width, size, color, center)
    local widget = screen:text(value, x, y, width, math.ceil(size * 1.6), true, nil, size)
    tint(widget, color or WHITE)
    if center then widget:SetJustification(1) end
    return widget
end
local function block(screen, x, y, width, height, color, alpha)
    local widget = screen:shade(x, y, width, height, alpha or 1)
    widget:SetBrushColor({ R = color[1], G = color[2], B = color[3], A = alpha or 1 })
    return widget
end
local function panel(screen, x, y, width, height, accent)
    block(screen, x, y, width, height, { .055, .062, .08 }, .94)
    block(screen, x, y, 4, height, accent or GOLD)
end
local function art(screen, context, name, x, y, width, height)
    -- Missing optional artwork must not turn the joke into a menu failure.
    local ok, texture, meta = pcall(function()
        if name == "soul" then return Art.soul(context, 6) end
        return Art.home(context, "challenge")
    end)
    if ok and valid(texture) then
        local image = screen:image(texture, meta, x, y, width, height)
        image.Slot:SetZOrder(12)
        return image
    end
    label(screen, name == "soul" and "魂" or "氪", x, y + height * .25, width, 130, GOLD, true)
end

function Demo.new()
    return setmetatable({ phase = "lobby", revision = 0, elapsed = 0,
        tickets = 10, pulls = 0, fragments = 0, rolls = 0, defense = 19, cooldown = 0 }, Model)
end
function Model:go(phase)
    self.phase, self.elapsed, self.revision = phase, 0, self.revision + 1
end
function Model:step()
    local phase = self.phase == "notice" and self.returnPhase or self.phase
    if phase == "lobby" or phase == "wish" or phase == "pulls" then return 1 end
    if phase == "relic" then return 2 end
    if phase == "abyss" or phase == "battle" or phase == "result" then return 3 end
    return 4
end
function Model:primaryLabel()
    local phase = self.phase
    if phase == "lobby" then return "领取福利 · 十连祈愿" end
    if phase == "wish" then return "跳过祈愿动画" end
    if phase == "pulls" then return "领取极品胚子 · 去强化" end
    if phase == "relic" then
        if self.cooldown > 0 then return "强化中……" end
        return self.rolls < #ROLLS and ("强化至 +" .. (self.rolls + 1) * 4) or "带着双暴梦想 · 去深渊"
    end
    if phase == "abyss" then return "开始挑战" end
    if phase == "battle" then return "快进至结算" end
    if phase == "result" then return "查看官方推荐解决方案" end
    if phase == "shop" then return "立即充值 · 首充双倍" end
    if phase == "receipt" then return "我想起来了 · 回去打游戏" end
    return "继续刚才的演示"
end
function Model:primary()
    local phase = self.phase
    if phase == "lobby" then
        self.tickets, self.pulls = 0, 10
        self:go("wish")
    elseif phase == "wish" then
        self.fragments = 1
        self:go("pulls")
    elseif phase == "pulls" then self:go("relic")
    elseif phase == "relic" then
        if self.cooldown > 0 then return end
        if self.rolls < #ROLLS then
            self.rolls = self.rolls + 1
            self.defense = self.defense + ROLLS[self.rolls]
            self.cooldown = .55
            self.revision = self.revision + 1
        else self:go("abyss") end
    elseif phase == "abyss" then self:go("battle")
    elseif phase == "battle" then self:go("result")
    elseif phase == "result" then self:go("shop")
    elseif phase == "shop" then self:go("receipt")
    elseif phase == "receipt" then return "exit"
    elseif phase == "notice" then
        local previous, elapsed = self.returnPhase, self.returnElapsed
        self.returnPhase, self.returnElapsed = nil, nil
        self:go(previous)
        self.elapsed = elapsed
    end
end
function Model:notice()
    if self.phase == "notice" then return self:primary() end
    self.returnPhase, self.returnElapsed = self.phase, self.elapsed
    self:go("notice")
end
function Model:tick(delta)
    self.elapsed = self.elapsed + delta
    if self.phase ~= "notice" and self.cooldown > 0 then
        self.cooldown = math.max(0, self.cooldown - delta)
        if self.cooldown == 0 then self.revision = self.revision + 1 end
    end
    if self.phase == "wish" and self.elapsed >= 3.2 then self:primary()
    elseif self.phase == "battle" and self.elapsed >= 9 then self:primary() end
end

function View:focused()
    if self.closed or not valid(self.modal) or not self.modal:IsActivated() or not valid(self.controller) then return false end
    local owner = self.modal:GetOwningPlayer()
    return valid(owner) and owner:GetAddress() == self.controller:GetAddress()
        and (self.modal:HasUserFocus(self.controller) or self.modal:HasUserFocusedDescendants(self.controller))
end
function View:confirm()
    if not self:focused() then return false end
    if self.model:primary() == "exit" then self.options.onBack(); return true end
    self:refresh()
    return true
end
function View:secondary()
    if not self:focused() then return false end
    self.model:notice()
    self:refresh()
    return true
end
function View:back() return false end -- Native Back exits through TitleHome.
function View:close()
    if self.closed then return end
    self.closed = true
    if self.screen then self.screen:close(); self.screen = nil end
    self.refs, self.model = nil, nil
end
function View:header(screen)
    label(screen, "影之氪零", 90, 48, 780, 66, GOLD)
    label(screen, "你的复仇之路，现已加入每日上限。", 94, 135, 1060, 28, MUTED)
    label(screen, "恶搞 DEMO 0.1", 1380, 65, 440, 28, GOLD)
    label(screen, "演示资源 · 不计入游戏进度", 1380, 112, 440, 23, MUTED)
    block(screen, 95, 180, 1730, 2, { .35, .28, .18 })
    for index, title in ipairs(STEPS) do
        local x, active = 95 + (index - 1) * 438, index == self.model:step()
        block(screen, x, 205, 415, 57, active and { .22, .16, .085 } or { .065, .066, .075 }, .95)
        label(screen, title, x + 22, 216, 380, 25, active and GOLD or MUTED)
    end
end
function View:lobby(screen)
    panel(screen, 95, 300, 1100, 560, GOLD)
    art(screen, self.modal, "soul", 650, 320, 510, 510)
    label(screen, "当期限定 · 绝版返场", 130, 334, 700, 28, GOLD)
    label(screen, "魂，也要抽。", 130, 400, 720, 62, WHITE)
    label(screen, "五星角色「魂」获取概率大幅提升", 135, 510, 730, 28, WHITE)
    label(screen, "活动剩余：直到你抽出来", 135, 566, 700, 25, MUTED)
    label(screen, "新手福利：赠送十连，先体验一下。", 135, 690, 730, 28, GOLD)
    label(screen, "本期保底：已为演示少侠安排妥当", 135, 744, 730, 24, MUTED)
    panel(screen, 1230, 300, 595, 230, RED)
    label(screen, "每日委托    ●  ●  ●", 1265, 330, 530, 31, RED)
    label(screen, "登录 / 签到 / 领取登录签到奖励", 1265, 399, 530, 25, WHITE)
    label(screen, "尚未领取：领取奖励的奖励", 1265, 447, 530, 24, MUTED)
    panel(screen, 1230, 560, 595, 300, PURPLE)
    label(screen, "运营公告    ●", 1265, 595, 530, 32, PURPLE)
    label(screen, "少侠，江湖凶险。", 1265, 660, 530, 28, WHITE)
    label(screen, "建议先把右上角红点点完。", 1265, 711, 530, 26, WHITE)
    label(screen, "可用祈愿券：" .. self.model.tickets, 1265, 790, 530, 25, GOLD)
end
function View:wish(screen)
    label(screen, "正在连接命运……", 410, 306, 1100, 36, PURPLE, true)
    self.refs.glow = block(screen, 948, 405, 24, 240, PURPLE, .8)
    self.refs.star = label(screen, "★", 710, 385, 500, 170, PURPLE, true)
    self.refs.wish = label(screen, "紫光，是命运的颜色。", 410, 698, 1100, 38, PURPLE, true)
    label(screen, "祈愿券 -10    ·    所有结果已在出光前安排妥当", 330, 795, 1260, 25, MUTED, true)
end
function View:pulls(screen)
    label(screen, "祈愿结果", 100, 292, 900, 36, GOLD)
    label(screen, "金光是真的，自己也是已经有的。", 980, 304, 845, 25, MUTED)
    for index = 1, 10 do
        local x, y = 100 + ((index - 1) % 5) * 349, 360 + math.floor((index - 1) / 5) * 228
        local rarity = index == 10 and 5 or index == 9 and 4 or 3
        local color = rarity == 5 and GOLD or rarity == 4 and PURPLE or BLUE
        panel(screen, x, y, 325, 204, color)
        label(screen, string.rep("★", rarity), x + 22, y + 24, 280, 27, color)
        label(screen, index == 10 and "魂" or index == 9 and "精致的破刀" or "生锈的破刀", x + 22, y + 77, 280, 32, WHITE)
        label(screen, index == 10 and "已拥有 → 魂的碎片 ×1" or "武器 · 未来可期", x + 22, y + 143, 285, 21, color)
    end
    label(screen, "附赠极品圣遗物胚子：双暴开局，前途无量。", 100, 847, 1720, 27, GOLD)
end
function View:relic(screen)
    local model = self.model
    panel(screen, 95, 310, 740, 555, GOLD)
    label(screen, "圣遗物 · 永不毕业之冠", 130, 345, 670, 34, GOLD)
    label(screen, "★★★★★", 135, 415, 660, 39, GOLD)
    label(screen, "+" .. model.rolls * 4, 130, 480, 670, 94, WHITE)
    label(screen, "主属性    攻击力 46.6%", 135, 630, 660, 32, WHITE)
    label(screen, "两件套：延长你的在线时长", 135, 725, 660, 27, MUTED)
    label(screen, "四件套：增加你对下一件的期待", 135, 777, 660, 25, MUTED)
    panel(screen, 875, 310, 950, 555, PURPLE)
    label(screen, "双暴极品胚子 · 自动锁定", 910, 345, 865, 34, PURPLE)
    label(screen, "暴击率                 3.9%", 920, 426, 840, 33, WHITE)
    label(screen, "暴击伤害               7.8%", 920, 489, 840, 33, WHITE)
    label(screen, "攻击力                 19", 920, 552, 840, 33, WHITE)
    self.refs.defense = label(screen, "防御力                 " .. model.defense, 920, 615, 840, 36, GOLD)
    local last = model.rolls == 0 and "策划推荐：这胚子不强化就亏了。"
        or ("+" .. model.rolls * 4 .. "  强化成功！防御力 +23")
    label(screen, last, 920, 717, 850, 29, GOLD)
    label(screen, model.rolls == #ROLLS and "五次强化，双暴纹丝不动。每一次成长都值得期待。"
        or "每一次成长，都值得期待。", 920, 782, 855, 23, MUTED)
end
function View:abyss(screen)
    panel(screen, 95, 310, 1070, 555, RED)
    art(screen, self.modal, "abyss", 695, 380, 430, 410)
    label(screen, "逐利深渊", 135, 350, 950, 58, WHITE)
    label(screen, "第 12 层 · 第 3 间", 140, 454, 850, 35, GOLD)
    label(screen, "本期首领：充值判官", 140, 530, 850, 30, WHITE)
    label(screen, "满星目标：180 秒内完成挑战", 140, 605, 900, 28, MUTED)
    label(screen, "准备状态：防御力令人安心", 140, 760, 900, 27, TEAL)
    panel(screen, 1205, 310, 620, 555, GOLD)
    label(screen, "本期渊月祝福", 1240, 350, 550, 35, GOLD)
    label(screen, "装备当期限定武器", 1240, 445, 550, 29, WHITE)
    label(screen, "伤害提升 500%", 1240, 506, 550, 42, GOLD)
    label(screen, "你的武器：生锈的破刀", 1240, 626, 550, 25, MUTED)
    label(screen, "祝福状态：未激活", 1240, 683, 550, 29, RED)
    label(screen, "深渊将以战斗演出形式展示", 1240, 793, 550, 23, MUTED)
end
function View:battle(screen)
    label(screen, "逐利深渊 · 战斗演出", 100, 300, 1300, 34, GOLD)
    label(screen, "充值判官", 450, 380, 1020, 43, WHITE, true)
    block(screen, 290, 468, 1340, 30, { .17, .12, .12 })
    self.refs.health = block(screen, 290, 468, 1340, 30, RED)
    art(screen, self.modal, "abyss", 660, 530, 600, 270)
    self.refs.timer = label(screen, "用时 00:00", 1390, 315, 440, 31, GOLD)
    self.refs.combat = label(screen, "少侠正在努力操作……", 250, 820, 1420, 31, WHITE, true)
end
function View:result(screen)
    label(screen, "挑战成功", 330, 320, 1260, 68, GOLD, true)
    label(screen, "★  ★  ☆", 330, 440, 1260, 82, GOLD, true)
    label(screen, "通关用时 03:01    /    满星要求 03:00", 330, 582, 1260, 34, WHITE, true)
    label(screen, "距离满星只差一秒。", 330, 668, 1260, 36, WHITE, true)
    label(screen, "距离解决方案，只差一次十连。", 330, 737, 1260, 32, RED, true)
    label(screen, "贴心推荐：当期限定武器池", 330, 826, 1260, 25, MUTED, true)
end
function View:shop(screen)
    panel(screen, 295, 315, 1330, 550, GOLD)
    label(screen, "首充双倍", 370, 350, 1180, 62, GOLD, true)
    label(screen, "让江湖，看见你的支付能力。", 370, 459, 1180, 35, WHITE, true)
    label(screen, "¥ 6", 370, 546, 1180, 88, WHITE, true)
    label(screen, "赠送：距离下一抽还差一点的氪晶", 370, 711, 1180, 30, PURPLE, true)
    label(screen, "恶搞演示 · 点击后只会收到运营部回复", 370, 799, 1180, 24, MUTED, true)
end
function View:receipt(screen)
    label(screen, "支付请求被常识拦截", 230, 330, 1460, 53, GOLD, true)
    label(screen, "检测到您已经购买本游戏。", 230, 464, 1460, 43, WHITE, true)
    label(screen, "那您怎么还想付钱？", 230, 553, 1460, 54, GOLD, true)
    label(screen, "运营部已下班。江湖不打烊。", 230, 705, 1460, 32, MUTED, true)
    label(screen, "卸下运营重担，回去好好打游戏。", 230, 790, 1460, 34, TEAL, true)
end
function View:notice(screen)
    panel(screen, 235, 310, 1450, 560, PURPLE)
    label(screen, "关于近期少侠反馈的战斗体验问题", 285, 354, 1340, 43, GOLD)
    label(screen, "各位少侠：", 290, 456, 1320, 30, WHITE)
    label(screen, "我们高度重视，并决定优化商城入口的显示效果。", 290, 526, 1320, 33, WHITE)
    label(screen, "感谢各位少侠一直以来的理解与支持。", 290, 603, 1320, 30, MUTED)
    label(screen, "补偿附件：祈愿券 × 0.3", 290, 725, 1320, 34, PURPLE)
    label(screen, "领取条件：集齐一张后方可领取。", 290, 797, 1320, 25, MUTED)
end
function View:refresh()
    if self.closed or self.revision == self.model.revision then return end
    if self.screen then self.screen:close(); self.screen = nil end
    self.refs, self.revision = {}, self.model.revision
    local screen = Screen.open(self.modal, self.controller)
    self.screen = screen -- assign before drawing so partial failures can clean up
    self:header(screen)
    self[self.model.phase](self, screen)
    block(screen, 95, 904, 1730, 2, { .35, .28, .18 })
    screen:button("返回演武", 95, 938, 260, 72, self.options.onBack)
    screen:button(self.model:primaryLabel(), 440, 938, 1030, 72, function() self:confirm() end)
    screen:button(self.model.phase == "notice" and "关闭公告" or "运营公告", 1555, 938, 270, 72,
        function() self:secondary() end)
    screen.selectedButton = 2
    label(screen, "Enter / A 继续    ·    Esc / B 返回演武    ·    Tab / X 公告", 95, 1030, 1730, 22, MUTED, true)
    self.confirmButton:SetButtonText(FText(self.model:primaryLabel()))
end
function View:animate()
    local phase, elapsed = self.model.phase, self.model.elapsed
    if phase == "wish" then
        local color = elapsed >= 1.65 and GOLD or PURPLE
        tint(self.refs.star, color); tint(self.refs.wish, color)
        self.refs.glow:SetBrushColor({ R = color[1], G = color[2], B = color[3], A = .8 })
        self.refs.glow:SetRenderOpacity(.35 + math.abs(math.sin(elapsed * 4)) * .65)
        self.refs.star:SetRenderOpacity(.65 + math.abs(math.sin(elapsed * 3)) * .35)
        self.refs.wish:SetText(FText(elapsed >= 1.65 and "金光！恭喜少侠，再次获得自己。" or "紫光，是命运的颜色。"))
    elseif phase == "relic" and self.model.cooldown > 0 then
        self.refs.defense:SetRenderOpacity(.4 + .6 * math.abs(math.sin(self.model.cooldown * 16)))
    elseif phase == "battle" then
        local progress = math.min(1, elapsed / 9)
        self.refs.health.Slot:SetSize({ X = math.max(1, 1340 * (1 - progress)), Y = 30 })
        local seconds = math.floor(progress * 181)
        self.refs.timer:SetText(FText(string.format("用时 %02d:%02d", math.floor(seconds / 60), seconds % 60)))
        local line = elapsed < 2.8 and "少侠正在努力操作……"
            or elapsed < 5.6 and "暴击！双暴胚子暂未作出贡献。"
            or elapsed < 7.6 and "极限闪避！当前防御力非常有安全感。"
            or "最后一刀！运营部正在确认满星门槛……"
        self.refs.combat:SetText(FText(line))
    end
end
function View:update(gameplay)
    if self.closed then return false end
    local now = gameplay and gameplay:GetRealTimeSeconds(self.modal)
    local delta = now and self.lastNow and math.max(0, math.min(.25, now - self.lastNow)) or 0
    self.lastNow = now
    if not self:focused() then
        if self.screen then self.screen:update() end -- discard clicks after focus loss
        self.shortcutDown = true
        return true
    end
    -- Keep native Confirm on its original CommonUI button; custom visual
    -- buttons never take over the game's input mode or action registration.
    if not self.confirmButton:HasUserFocus(self.controller) then self.confirmButton:SetFocus() end
    local shortcut = self.router:IsUIKeyHeld({ KeyName = FName("Tab") })
        or self.router:IsUIKeyHeld({ KeyName = FName("Gamepad_FaceButton_Left") })
    if shortcut and not self.shortcutDown then self:secondary() end
    self.shortcutDown = shortcut
    local screen = self.screen
    if screen then screen:update() end
    if self.closed then return false end
    self.model:tick(delta)
    self:refresh()
    self:animate()
    return true
end
function Model:mount(modal, description, controller, confirm, options)
    local selfView = setmetatable({ model = self, modal = modal, controller = controller,
        confirmButton = confirm, options = options, shortcutDown = true }, View)
    local ok, failure = pcall(function()
        assert(type(options.onBack) == "function", "演示缺少返回入口")
        selfView.router = required("/Script/Engine.Default__SubsystemBlueprintLibrary"):
            GetLocalPlayerSubsystem(modal, required("/Script/ProjectPBZ.PBZUIActionRouterBase"))
        assert(valid(selfView.router), "演示的原生输入路由尚未就绪")
        selfView:refresh()
    end)
    if not ok then selfView:close(); error(failure, 0) end
    return selfView
end
return Demo
