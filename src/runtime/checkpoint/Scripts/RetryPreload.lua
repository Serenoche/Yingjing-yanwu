local Async = require("AsyncClassLoad")
local References = require("PreloadReferences")
local SpawnClass = require("SpawnClass")

local Retry = {}
local WAIT = 0.25
local EXPIRY = 60

local function address(object)
    return object and type(object.IsValid) == "function" and object:IsValid() and object:GetAddress() or nil
end

local function world(pawn)
    return address(pawn) and address(pawn:GetWorld())
end

local function log(ticket, message)
    print(("[PBZRetryPreload] %s; mode=%s; target=%s\n"):format(message, ticket.mode, ticket.entry.id))
end

function Retry.close(run, mapTransition)
    local ticket = run.retryPreload
    if not ticket then return end
    if mapTransition and run.reloadRequested and ticket.phase == "departure" then
        ticket.phase = "arriving"
        return
    end
    run.retryPreload = nil
    if ticket.references then
        local _, _, failures = ticket.references:release()
        if failures > 0 then log(ticket, "reference cleanup incomplete") end
    end
end

function Retry.expire(run)
    local ticket = run.retryPreload
    if ticket and os.clock() >= ticket.expires then Retry.close(run) end
end

local function advance(ticket, pawn)
    local ready = true
    for _, job in ipairs(ticket.jobs) do
        if not job.held then
            local class = SpawnClass.observeReady(job.path)
            if class then
                job.held = ticket.references:hold(class)
                job.address = address(class)
            else
                if not job.requested then
                    Async.request(pawn, job.path)
                    job.requested = true
                end
                ready = false
            end
        end
    end
    return ready
end

function Retry.start(run, gameplay, pawn, now)
    Retry.close(run)
    if run.palace or (run.mode ~= "challenge" and run.mode ~= "practice") then return end
    local ticket = { entry = run.entry, mode = run.mode, scene = run.scene, slot = run.slot,
        phase = "departure", deadline = now + WAIT, expires = os.clock() + EXPIRY, jobs = {} }
    run.retryPreload = ticket
    local ok, reason = pcall(function()
        ticket.pawn, ticket.world = address(pawn), world(pawn)
        assert(ticket.pawn and ticket.world, "retry actor is unavailable")
        local seen = {}
        for _, member in ipairs(run.entry.stages[1].members) do
            local path = member.classPath
            if not seen[path] then
                seen[path] = true
                ticket.jobs[#ticket.jobs + 1] = { path = path }
            end
        end
        ticket.references = References.new(gameplay, pawn)
        ticket.references:attach()
        ticket.instance = address(ticket.references.instance)
        advance(ticket, pawn)
        log(ticket, ("started; first-stage classes=%d"):format(#ticket.jobs))
    end)
    if not ok then
        log(ticket, "loading fallback; reason=" .. tostring(reason))
        Retry.close(run)
    end
end

local function step(run, gameplay, pawn, beforeReload, now)
    local ticket = run.retryPreload
    if not ticket then return true end
    if ticket.entry ~= run.entry or ticket.scene ~= run.scene or ticket.slot ~= run.slot or ticket.mode ~= run.mode
        or os.clock() >= ticket.expires then
        Retry.close(run)
        return true
    end

    local ok, ready = pcall(function()
        local pawnId, worldId = address(pawn), world(pawn)
        if not pawnId or not worldId or address(gameplay:GetGameInstance(pawn)) ~= ticket.instance
            or (beforeReload and ticket.phase ~= "departure")
            or (not beforeReload and (run.stageIndex ~= 1 or ticket.phase == "departure")) then
            Retry.close(run)
            return true
        end

        if ticket.phase == "arriving" then
            -- Pending latent requests belong to the departing world. Retained
            -- classes are GameInstance-owned, and unfinished requests can be reapplied here.
            ticket.pawn, ticket.world = pawnId, worldId
            ticket.phase, ticket.deadline = "arrival", gameplay:GetRealTimeSeconds(pawn) + WAIT
            if not ticket.references:ownedIndex(ticket.references.instance.ReferencedObjects) then
                ticket.references:release()
                ticket.references = References.new(gameplay, pawn)
                ticket.references:attach()
            end
            for _, job in ipairs(ticket.jobs) do
                if job.held and not ticket.references:holds(job.held, job.address) then
                    job.held, job.address = nil, nil
                end
                job.requested = nil
            end
        end
        if ticket.pawn ~= pawnId or ticket.world ~= worldId then
            Retry.close(run)
            return true
        end
        if ticket.phase == "ready" then return true end

        local completed = advance(ticket, pawn)
        local time = now or gameplay:GetRealTimeSeconds(pawn)
        if not completed and time < ticket.deadline then return false end
        if not beforeReload then
            ticket.phase = "ready"
            log(ticket, completed and "first-stage preload ready" or "remaining classes use normal loading")
        end
        return true
    end)
    if ok then return ready end

    log(ticket, "loading fallback; reason=" .. tostring(ready))
    Retry.close(run)
    return true
end

function Retry.beforeReload(run, gameplay, pawn, now)
    return step(run, gameplay, pawn, true, now)
end

function Retry.beforeSpawn(run, gameplay, pawn)
    return step(run, gameplay, pawn, false)
end

return Retry
