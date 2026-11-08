local Integration = {}
local OWNER = "7d5ad307-d21c-47eb-9584-493443190984"
local GAME_SHA256 = "4415933ce33476f14c837abb61a1b60af8b78cd81783896501913a7aac69e423"

local function read(path)
    local stream = io.open(path, "rb")
    if not stream then return nil end
    local value = stream:read(8192)
    stream:close()
    return value
end

local function normalized(path)
    assert(type(path) == "string" and #path <= 1024 and not path:find("[%z\1-\31\127]"), "invalid installed MOD path")
    path = path:gsub("\\", "/"):gsub("/+$", "")
    assert(path:match("^[A-Za-z]:/") and not path:find("//", 1, true)
        and not path:sub(3):find(":",1,true), "installed MOD path must be absolute")
    assert(not path:find('[*?<>|"]'), "invalid installed MOD path characters")
    for part in path:gmatch("[^/]+") do
        assert(part ~= "." and part ~= ".." and not part:match("[. ]$"), "relative or aliased installed MOD path")
    end
    return path
end

local function customProvider(command)
    local words, quoted = {}, false
    local function finish()
        local word = table.concat(words)
        words = {}
        if word:match("^%-pbztestarena") then return true end
        local name = word:match("^%-([%a]+)=") or word:match("^%-([%a]+)$")
        return name == "savegamesdir" or name == "userdir"
    end
    for char in command:gmatch(".") do
        if char == '"' then quoted = not quoted
        elseif not quoted and char:match("%s") then
            if #words > 0 and finish() then return true end
        else words[#words + 1] = char end
    end
    return #words > 0 and finish() or false
end

function Integration.load(system)
    local command = system:GetCommandLine()
    command = (type(command) == "string" and command or command:ToString()):lower()
    -- Explicit test/custom profiles retain the existing strict isolation path.
    if customProvider(command) then return nil end
    local source = debug.getinfo(1, "S").source
    assert(source:sub(1, 1) == "@", "installed MOD script path is unavailable")
    local scripts = normalized(assert(source:sub(2):match("^(.*)[/\\][^/\\]+$")))
    local configPath = scripts .. "/IntegratedConfig.lua"
    if not read(configPath) then return nil end
    local platform = assert(scripts:lower():match("^(.*)/ue4ss/mods/pbztestarena/scripts$"), "invalid installed MOD layout")
    local marker = read(platform .. "/ue4ss/.PBZTestArenaIntegrated-owner")
    assert(marker and marker:match("^%s*(.-)%s*$") == OWNER, "installed MOD ownership marker is missing")
    local config = assert(loadfile(configPath))()
    assert(type(config) == "table" and (config.version == 1 or config.version == 2) and config.owner == OWNER,
        "installed MOD configuration is invalid")
    if config.version == 2 or config.gameSha256 ~= nil then
        assert(type(config.gameSha256) == "string" and config.gameSha256:lower() == GAME_SHA256,
            "installed MOD game build is unsupported")
        config.gameSha256 = GAME_SHA256
    end
    assert(config.diagnostics == nil or type(config.diagnostics) == "boolean", "invalid installed MOD diagnostics setting")
    if config.version == 2 and config.diagnostics == nil then config.diagnostics = false end
    assert(config.trainingSlot == "PBZArenaIntegratedTraining" and config.cyclePrefix == "PBZArenaIntegratedCycle",
        "installed MOD private save namespace is invalid")
    config.profile, config.savePath = normalized(config.profile), normalized(config.savePath)
    if config.loadoutMemoryPath~=nil then
        config.loadoutMemoryPath=normalized(config.loadoutMemoryPath)
        assert(config.loadoutMemoryPath:lower():match("/arenapreferences/pbzloadout%.tsv$"),"invalid installed loadout memory path")
    end
    assert(config.version ~= 2 or config.loadoutMemoryPath ~= nil, "installed MOD preference path is required")
    assert(config.profile:lower():match("/integratedmenu/arenadata/profile$"), "installed MOD data directory is invalid")
    assert((read(config.profile .. "/PBZIntegratedProfile.txt") or ""):match("^%s*(.-)%s*$") == OWNER,
        "installed MOD data ownership marker is missing")
    local install = assert(platform:match("^(.*)/platform/steam$"), "installed MOD is outside the pinned game layout")
    local accountPrefix = install .. "/projectpbz/saved/savegames/steam/"
    local path = config.savePath:lower()
    local account = path:sub(#accountPrefix + 1):match("^(%d+)/pbzsavegame%.sav$")
    assert(path:sub(1, #accountPrefix) == accountPrefix and account and #account == 17,
        "installed MOD save provider differs from this game installation")
    config.accountId = account
    if config.version == 2 then
        local dataRoot = install .. "/projectpbz/saved/pbztestarena/" .. account
        assert(config.profile:lower() == dataRoot .. "/integratedmenu/arenadata/profile",
            "installed MOD profile must belong to this game and Steam account")
        assert(config.loadoutMemoryPath:lower() == dataRoot .. "/arenapreferences/pbzloadout.tsv",
            "installed MOD preferences must belong to this game and Steam account")
        config.dataRoot = dataRoot
    end
    assert(type(config.defaultPlayerCycle) == "number" and config.defaultPlayerCycle % 1 == 0
        and config.defaultPlayerCycle >= 0 and config.defaultPlayerCycle <= 6, "invalid installed player cycle")
    assert(type(config.defaultEnemyCycle) == "number" and config.defaultEnemyCycle % 1 == 0
        and config.defaultEnemyCycle >= 0 and config.defaultEnemyCycle <= 6, "invalid installed enemy cycle")
    config.integrated = true
    return config
end

return Integration
