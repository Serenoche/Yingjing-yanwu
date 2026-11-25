local StageScreen = require("StageScreen")
local FailureScreen, View = {}, {}
View.__index = View

local TITLE_FILE = "DreamPalaceFailureTitle.png"
local DARK = { R = .007, G = .005, B = .008, A = 1 }
local DURATION, APPEAR, DISAPPEAR = 3, .24, .20
local DESIGN_WIDTH, DESIGN_HEIGHT, TITLE_HEIGHT = 1920, 1080, 820
local VISIBLE_WITHOUT_INPUT, COLLAPSED = 3, 1

-- Brush sizes, tint and scale keyframes from W_PlayerDead.
local SPLASH_FOLDER = "/Game/PBZContent/UI/InGame/Dead/"
local SPLASH_TINT = { R = .168627, G = .168627, B = .168627, A = 1 }
local SPLASH_FADE = .25
local SPLASHES = {
    { name = "Blood1", width = 700, height = 560, start = .7, peak = 1.1, scaleX = 1, scaleY = 1 },
    { name = "T_UI_blood_Combine", width = 1024, height = 1024, start = .8, peak = 4 / 3, scaleX = .57, scaleY = .60 },
}

local function valid(object)
    return object ~= nil and type(object.IsValid) == "function" and object:IsValid()
end

local function checked(object, message)
    assert(valid(object), message)
    return object
end

local function log(message)
    print("[PBZBloodyPalace] failure page " .. message .. "\n")
end

local function widget(kind, outer)
    local class = checked(StaticFindObject("/Script/UMG." .. kind), "找不到沉梦界面控件 " .. kind)
    local item = checked(StaticConstructObject(class, outer), "无法创建沉梦界面控件 " .. kind)
    item:SetVisibility(VISIBLE_WITHOUT_INPUT)
    return item
end

local function loadTitle(controller)
    local source = debug.getinfo(1, "S").source
    local directory = assert(source:match("^@(.*)[/\\\\][^/\\\\]+$"), "沉梦贴图目录不可用")
    local renderer = checked(StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary"), "贴图导入接口不可用")
    return checked(renderer:ImportFileAsTexture2D(controller, directory .. "/" .. TITLE_FILE), "沉梦贴图不可用")
end

local function mountSplash(controller, canvas, spec)
    local texture = require("ArtAssets").texture(controller, SPLASH_FOLDER .. spec.name .. "." .. spec.name)
    checked(texture, "沉梦溅血贴图不可用 " .. spec.name)
    local image = widget("Image", canvas)
    image:SetBrushFromTexture(texture, false)
    image:SetColorAndOpacity(SPLASH_TINT)
    image:SetRenderTransformPivot({ X = .5, Y = .5 })
    image:SetRenderOpacity(0)
    local slot = checked(canvas:AddChildToCanvas(image), "无法挂载沉梦溅血层 " .. spec.name)
    slot:SetPosition({ X = (DESIGN_WIDTH - spec.width) / 2, Y = (DESIGN_HEIGHT - spec.height) / 2 })
    slot:SetSize({ X = spec.width, Y = spec.height })
    return { image = image, spec = spec }
end

-- The native cubic keys have zero tangents at both ends.
local function smooth(progress)
    local t = math.max(0, math.min(1, progress))
    return t * t * (3 - 2 * t)
end

local function animateSplash(layers, elapsed)
    local opacity = smooth((DURATION - elapsed) / SPLASH_FADE)
    for _, layer in ipairs(layers) do
        local image, spec = layer.image, layer.spec
        if valid(image) then
            local scale = smooth((elapsed - spec.start) / (spec.peak - spec.start))
            image:SetRenderScale({ X = spec.scaleX * scale, Y = spec.scaleY * scale })
            image:SetRenderOpacity(scale > 0 and opacity or 0)
        end
    end
end

function View:updateSplash(elapsed)
    if not self.splash or #self.splash == 0 then return end
    local ok, problem = pcall(animateSplash, self.splash, elapsed)
    if ok then return end
    for _, layer in ipairs(self.splash) do
        if valid(layer.image) then pcall(layer.image.SetRenderOpacity, layer.image, 0) end
    end
    self.splash = nil
    log("splash animation unavailable: " .. tostring(problem))
end

function FailureScreen.new(cause)
    return setmetatable({ cause = cause }, View)
end

function View:open(controller, now)
    local texture = loadTitle(controller)
    local width, height = texture:Blueprint_GetSizeX(), texture:Blueprint_GetSizeY()
    assert(width > 0 and height > 0, "沉梦贴图尺寸无效")
    local titleWidth = TITLE_HEIGHT * width / height
    self.layer = StageScreen.fullscreenCover(controller, DARK)
    local fit = widget("ScaleBox", self.layer.border)
    fit:SetStretch(2)
    local frame = widget("SizeBox", fit)
    frame:SetWidthOverride(DESIGN_WIDTH)
    frame:SetHeightOverride(DESIGN_HEIGHT)
    local canvas = widget("CanvasPanel", frame)
    fit:SetContent(frame)
    frame:SetContent(canvas)
    self.layer.border:SetContent(fit)

    self.splash = {}
    for _, spec in ipairs(SPLASHES) do
        local ok, layer = pcall(mountSplash, controller, canvas, spec)
        if ok then self.splash[#self.splash + 1] = layer
        else log("splash layer unavailable: " .. tostring(layer)) end
    end

    local title = widget("Image", canvas)
    title:SetBrushFromTexture(texture, false)
    -- Optical center of the ink on the original transparent canvas.
    local slot = checked(canvas:AddChildToCanvas(title), "无法挂载沉梦字图")
    slot:SetPosition({ X = DESIGN_WIDTH / 2 - titleWidth * .548, Y = DESIGN_HEIGHT / 2 - TITLE_HEIGHT * .515 })
    slot:SetSize({ X = titleWidth, Y = TITLE_HEIGHT })
    title:SetRenderOpacity(0)
    self.title, self.shownAt = title, now
    log(("shown; cause=%s; duration=%.2fs; splash layers=%d"):format(self.cause, DURATION, #self.splash))
end

function View:closePage()
    if self.layer then
        local ok, failure = pcall(self.layer.close, self.layer)
        if not ok then log("cleanup: " .. tostring(failure)) end
    end
    self.layer, self.title, self.shownAt, self.splash = nil, nil, nil, nil
end

function FailureScreen.backdrop(root)
    local layer = StageScreen.coverRoot(root, "Overlay", DARK)
    return function() layer:close() end
end

function View:replaceNativeDeath(controller, now)
    if self.cause ~= "death" or now < (self.nextStockCheck or 0) then return end
    self.nextStockCheck = now + .20
    local stock = self.stock
    if stock and valid(stock.widget) and valid(stock.root) then
        if not stock.widget.NotTick then stock.widget.NotTick = true end
        if stock.root:GetVisibility() ~= COLLAPSED then stock.root:SetVisibility(COLLAPSED) end
        return
    end
    local controllerWorld = controller:GetWorld()
    if not valid(controllerWorld) then return end
    for _, death in ipairs(FindAllOf("W_PlayerDead_C") or {}) do
        if valid(death) and death:IsActivated() then
            local owner, world = death:GetOwningPlayer(), death:GetWorld()
            if valid(owner) and owner:GetAddress() == controller:GetAddress()
                and valid(world) and world:GetAddress() == controllerWorld:GetAddress() then
                local tree = death.WidgetTree
                local root = valid(tree) and tree.RootWidget
                if valid(root) then
                    assert(type(death.NotTick) == "boolean", "原版死亡控件复活开关不可用")
                    self.stock = { widget = death, root = root, notTick = death.NotTick, visibility = root:GetVisibility() }
                    -- DeadMenu.Tick honors NotTick. Keep the widget alive: its
                    -- native Destruct performs a fallback respawn.
                    death.NotTick = true
                    root:SetVisibility(COLLAPSED)
                    log("replaced native death view; revive gate held")
                    return
                end
            end
        end
    end
end

function View:uncover(now, menuReady)
    if self.layer and self.finished and (menuReady or now >= self.handoffDeadline) then
        self:closePage()
    end
end

function View:detach()
    self:closePage()
    local stock = self.stock
    if stock then
        if valid(stock.widget) then pcall(function() stock.widget.NotTick = stock.notTick end) end
        if valid(stock.root) then pcall(stock.root.SetVisibility, stock.root, stock.visibility) end
    end
    self.stock, self.nextStockCheck, self.nextOpen, self.openDeadline = nil, nil, nil, nil
end

function View:update(controller, now)
    local hidden, problem = pcall(self.replaceNativeDeath, self, controller, now)
    if not hidden and problem ~= self.lastNativeError then log("native death takeover: " .. tostring(problem)) end
    self.lastNativeError = not hidden and problem or nil
    if self.finished then return true end

    if not self.layer then
        if now < (self.nextOpen or 0) then return false end
        self.openDeadline = self.openDeadline or now + 1.25
        local ok, failure = pcall(self.open, self, controller, now)
        if not ok then
            self:closePage()
            self.nextOpen = now + .20
            if now < self.openDeadline then return false end
            log("fallback to settlement; cause=" .. self.cause .. "; reason=" .. tostring(failure))
            self.finished = true
            return true
        end
    end
    local elapsed = math.max(0, now - self.shownAt)
    if elapsed < DURATION and valid(self.title) then
        local alpha = math.min(1, elapsed / APPEAR, (DURATION - elapsed) / DISAPPEAR)
        local ok, failure = pcall(self.title.SetRenderOpacity, self.title, alpha)
        if ok then
            self:updateSplash(elapsed)
            return false
        end
        log("display fallback: " .. tostring(failure))
    end
    self:updateSplash(DURATION)
    if valid(self.title) then pcall(self.title.SetRenderOpacity, self.title, 0) end
    self.finished, self.handoffDeadline = true, now + 1.25
    log(("settlement handoff; cause=%s; shown=%.3fs"):format(self.cause, elapsed))
    return true
end

return FailureScreen
