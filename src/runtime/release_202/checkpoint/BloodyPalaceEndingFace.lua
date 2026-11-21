local Face = {}
Face.__index = Face

local UPDATE = "/HuaShira/MetaHumans/Template/Metahuman_Head_PostProcess_AnimBP"
    .. ".Metahuman_Head_PostProcess_AnimBP_C:BlueprintUpdateAnimation"

-- Paired controls share one weight. The first row column is time from the audio seek.
local CONTROLS = {
    { "jawOpen" },
    { "jawBack" },
    { "jawChinRaiseDL", "jawChinRaiseDR" },
    { "mouthStretchL", "mouthStretchR" },
    { "mouthDimpleL", "mouthDimpleR" },
    { "mouthFunnelUL", "mouthFunnelUR", "mouthFunnelDL", "mouthFunnelDR" },
    { "mouthLipsPurseUL", "mouthLipsPurseUR", "mouthLipsPurseDL", "mouthLipsPurseDR" },
    { "mouthLipsTogetherUL", "mouthLipsTogetherUR" },
    { "mouthLipsTogetherDL", "mouthLipsTogetherDR" },
    { "mouthLipsPullUL", "mouthLipsPullUR" },
    { "mouthLipsPullDL", "mouthLipsPullDR" },
    { "mouthLowerLipDepressL", "mouthLowerLipDepressR" },
    { "mouthUpperLipRaiseL", "mouthUpperLipRaiseR" },
    { "tongueDown" },
    { "tongueIn" },
    { "tongueTipUp" },
}

-- Sampled from the Chinese Dlg_JMKD_RenOuZhangMen3_Hun_5 face take at 4.920 s.
local ADMIRATION = {
    { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    { .033, .141, .073, .001, .09, .083, .079, .003, 0, 0, .392, .448, .125, .076, 0, .139, .064 },
    { .067, .289, .191, .001, .19, .145, .123, .002, 0, 0, .714, .863, .324, .123, 0, .272, .072 },
    { .1, .326, .227, 0, .229, .147, .121, 0, 0, 0, .763, .948, .424, .13, 0, .426, .019 },
    { .133, .302, .18, .001, .229, .148, .115, 0, 0, 0, .738, .912, .446, .138, 0, .551, 0 },
    { .167, .258, .097, .001, .209, .15, .106, .001, 0, 0, .678, .82, .445, .15, 0, .622, 0 },
    { .2, .234, .031, .001, .19, .14, .097, .001, 0, 0, .623, .736, .457, .166, 0, .576, 0 },
    { .233, .248, .004, 0, .172, .111, .091, .002, 0, 0, .599, .697, .459, .178, 0, .414, 0 },
    { .267, .295, .011, .001, .139, .072, .082, .008, .001, 0, .594, .67, .354, .154, 0, .388, 0 },
    { .3, .3, .028, .067, .085, .084, .041, .053, .13, .022, .552, .624, .139, .063, 0, .581, 0 },
    { .333, .258, .041, .15, .059, .126, .009, .126, .472, .059, .449, .542, .022, .007, 0, .689, 0 },
    { .367, .242, .073, .117, .086, .125, .01, .141, .754, .043, .448, .557, .013, .001, 0, .638, 0 },
    { .4, .292, .148, .035, .115, .089, .035, .062, .511, .01, .574, .694, .035, .002, .228, .585, 0 },
    { .433, .336, .212, .003, .129, .067, .059, .009, .137, .001, .648, .76, .083, .019, .294, .59, 0 },
    { .467, .317, .255, .005, .11, .057, .071, .006, .013, .001, .619, .689, .064, .026, .094, .675, 0 },
    { .5, .257, .288, .066, .055, .053, .068, .023, .002, .091, .503, .528, .017, .028, 0, .76, 0 },
    { .533, .207, .302, .137, .012, .055, .063, .053, .002, .215, .356, .358, .002, .04, 0, .8, 0 },
    { .567, .178, .307, .156, 0, .053, .067, .091, .002, .25, .244, .248, .001, .047, 0, .808, 0 },
    { .6, .162, .305, .137, 0, .046, .073, .127, .002, .221, .187, .2, 0, .041, 0, .797, 0 },
    { .633, .156, .294, .103, .004, .039, .077, .139, .002, .195, .186, .196, 0, .028, 0, .783, 0 },
    { .667, .156, .282, .07, .009, .034, .078, .132, .002, .192, .221, .226, 0, .019, 0, .778, 0 },
    { .7, .151, .256, .046, .012, .03, .06, .124, .002, .176, .25, .255, 0, .015, .311, .67, 0 },
    { .733, .113, .172, .029, .012, .021, .025, .102, .002, .092, .21, .222, 0, .011, .405, .459, 0 },
    { .767, .073, .096, .02, .009, .015, .005, .075, .006, .02, .152, .17, 0, .006, .234, .311, 0 },
    { .8, .034, .039, .012, .005, .008, 0, .039, .008, .001, .08, .092, 0, .003, .081, .161, 0 },
    { .833, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
}

local JAW_BONE, PARENT_BONE_SPACE = "FACIAL_C_Jaw", 3

local function valid(value)
    return value and type(value.IsValid) == "function" and value:IsValid()
end

local function report(message)
    print("[PBZBloodyPalace] ending face " .. message .. "\n")
end

function Face.new(head, now)
    assert(valid(head), "魂的面部网格不可用")
    -- The head keeps its copy-from-body graph. RigLogic must evaluate on the
    -- visible head itself instead of borrowing the body's final bones.
    head:SetLeaderPoseComponent(nil, true, false)
    head:SetDisablePostProcessBlueprint(false)
    head:SetAllowAnimCurveEvaluation(true)
    head:SetForcedLOD(1)
    head.VisibilityBasedAnimTickOption = 0
    head.bEnableUpdateRateOptimizations = false
    head:SetComponentTickEnabled(true)

    local post = head:GetPostProcessInstance()
    assert(valid(post) and valid(StaticFindObject(UPDATE)), "魂的原版面部后处理未加载")
    assert(head:DoesSocketExist(FName(JAW_BONE)), "魂的下颌骨骼不可用")
    local self = setmetatable({ head = head, post = post, address = post:GetAddress(),
        now = now, jaw = FName(JAW_BONE), names = {} }, Face)
    for i, group in ipairs(CONTROLS) do
        local names = {}
        for j, name in ipairs(group) do names[j] = FName("CTRL_expressions_" .. name) end
        self.names[i] = names
    end
    local first, last = RegisterHook(UPDATE, function(context)
        if not self.line then return end
        local instance = context:get()
        if not valid(instance) or instance:GetAddress() ~= self.address then return end
        -- BlueprintUpdateAnimation and the property copies run before this
        -- instance dispatches its animation graph. Write only on this path.
        local ok, reason = pcall(self.evaluate, self)
        if not ok then
            self.line = nil
            report("fallback: " .. tostring(reason))
        end
    end)
    self.preHook, self.postHook = first, last
    return self
end

function Face:play(started)
    self.line = { track = ADMIRATION, started = started, key = 1, frames = 0, jawDegrees = 0 }
end

function Face:evaluate()
    local line, post = self.line, self.post
    local t = math.max(0, self.now() - line.started)
    -- Compare local joint rotations on successive evaluated frames. Actor
    -- tilt and the camera move cannot contribute to this measurement.
    local q = self.head:GetSocketTransform(self.jaw, PARENT_BONE_SPACE).Rotation
    if line.neutral then
        local a = line.neutral
        local dot = math.min(1, math.abs(a[1] * q.X + a[2] * q.Y + a[3] * q.Z + a[4] * q.W))
        line.jawDegrees = math.max(line.jawDegrees, math.deg(2 * math.acos(dot)))
    else
        line.neutral = { q.X, q.Y, q.Z, q.W }
    end
    line.frames = line.frames + 1

    local node = post.AnimGraphNode_ModifyCurve_6
    local map = node.CurveMap
    if t >= line.track[#line.track][1] then
        map:Empty()
        post["Expression Scaling"] = false
        self.line = nil
        report(("cue=1; evaluations=%d; maxJawDegrees=%.2f"):format(line.frames, line.jawDegrees))
        return
    end
    if not self.curveNodeReady then
        -- This node sits before RigLogic on the Expression Scaling branch.
        -- The map takes priority over the node's original value pins.
        node.ApplyMode = 2 -- EModifyCurveApplyMode::Blend
        post["Jaw Scaling"] = 1
        self.curveNodeReady = true
    end
    while t >= line.track[line.key + 1][1] do line.key = line.key + 1 end
    local a, b = line.track[line.key], line.track[line.key + 1]
    local u = (t - a[1]) / (b[1] - a[1])
    for i, names in ipairs(self.names) do
        local value = a[i + 1] + (b[i + 1] - a[i + 1]) * u
        for _, name in ipairs(names) do map:Add(name, value) end
    end
    post["Expression Scaling"] = true
end

function Face:check(now)
    local line = self.line
    if line and not line.reported and now > line.started + line.track[#line.track][1] + .2 then
        report(("cue=1; interrupted evaluations=%d"):format(line.frames))
        -- The next face tick still clears the weights if rendering resumes.
        line.reported = true
    end
end

function Face:close()
    if self.line and valid(self.post) then
        self.post.AnimGraphNode_ModifyCurve_6.CurveMap:Empty()
        self.post["Expression Scaling"] = false
    end
    self.line = nil
    UnregisterHook(UPDATE, self.preHook, self.postHook)
end

return Face

