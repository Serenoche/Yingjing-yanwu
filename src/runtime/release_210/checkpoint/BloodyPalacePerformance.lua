-- Read-only telemetry for the ending test. Sample engine frames over wall
-- time so a slow Lua timer cannot be mistaken for the rendered frame rate.
local Performance = {}
Performance.__index = Performance

local INTERVAL = 3
local RENDERING_LIBRARY = "/Script/Engine.Default__KismetRenderingLibrary"
local CVARS = {
    { "rtQuality", "gq.Ind.RayTracingQualityLevel" },
    { "rayTracing", "r.RayTracing.Enable" },
    { "lumenHW", "r.Lumen.HardwareRayTracing" },
}

local function phase(palace, challenge)
    if palace.ending and not palace.endingReady then
        return palace.ending.fade and "ending-white" or "ending"
    end
    if challenge.transitionStep then return "relay-" .. challenge.transitionStep end
    if palace.state == "preparing" and not palace.prepared then return "entry" end
    return palace.state
end

local function numeric(read)
    local ok, value = pcall(read)
    if ok and type(value) == "number" and value == value and math.abs(value) < math.huge then return value end
end

function Performance.new()
    return setmetatable({}, Performance)
end

function Performance:update(system, world, now, palace, challenge, trim)
    local label = phase(palace, challenge)
    local key = ("%s:%d:%d"):format(label, palace.floor, challenge.stageIndex)
    local prev = self.sample
    if prev and prev.world == world and prev.key == key and now >= prev.time and now - prev.time < INTERVAL then return end

    local frame = numeric(function() return system:GetFrameCount() end)
    local pso = numeric(function()
        if not self.rendering or not self.rendering:IsValid() then
            self.rendering = StaticFindObject(RENDERING_LIBRARY)
        end
        return self.rendering:NumPrecompilingPSOsRemaining()
    end)
    if prev and prev.world == world and now - prev.time >= .25 then
        local seconds = now - prev.time
        local fps = frame and prev.frame and frame >= prev.frame and ("%.1f"):format((frame - prev.frame) / seconds)
        local fields = {}
        for _, cvar in ipairs(CVARS) do
            local value = numeric(function() return system:GetConsoleVariableIntValue(cvar[2]) end)
            fields[#fields + 1] = cvar[1] .. "=" .. tostring(value or "unavailable")
        end
        print(("[PBZBloodyPalace] frame pacing phase=%s next=%s seconds=%.2f engineFPS=%s trim=%s->%s pso=%s->%s %s\n")
            :format(prev.key, key, seconds, fps or "unavailable", tostring(prev.trim), tostring(trim),
                tostring(prev.pso or "unavailable"), tostring(pso or "unavailable"), table.concat(fields, " ")))
    end
    self.sample = { world = world, key = key, time = now, frame = frame, pso = pso, trim = trim }
end

return Performance
