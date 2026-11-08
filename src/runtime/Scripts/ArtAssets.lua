-- Native textures for the confirmed full-screen design. No save or gameplay writes.
local Data = require("NativeUiAssetsData")
local Art = {}
local source = debug.getinfo(1, "S").source
local directory = source:sub(1, 1) == "@" and source:sub(2):match("^(.*)[/\\][^/\\]+$")
local root = directory and (directory .. "/" .. Data.assetDirectory)
local cache, failures, recent, sequence = {}, {}, {}, 0
local CACHE_LIMIT = 16 -- A complete result needs at most 15 visible textures.
local RENDERING = "/Script/Engine.Default__KismetRenderingLibrary"
local KISMET = "/Script/Engine.Default__KismetSystemLibrary"
local SUBSYSTEMS = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local BACKPACK = "/Script/ProjectPBZ.PBZBackPackSubsystem"
local BACKPACK_CDO = "/Script/ProjectPBZ.Default__PBZBackPackSubsystem"

local function valid(object)
    return object ~= nil and type(object.IsValid) == "function" and object:IsValid()
end
local function unwrap(value)
    local kind = type(value)
    if value and (kind == "table" or kind == "userdata") and type(value.IsValid) ~= "function" then
        local getter = value.get or value.Get
        if type(getter) == "function" then return getter(value) end
    end
    return value
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
local function object(path)
    return unwrap(StaticFindObject(path))
end
local function text(value)
    value = unwrap(value)
    if type(value) == "string" then return value end
    if value and type(value.ToString) == "function" then return value:ToString() end
    return ""
end
local function softPath(value)
    value = unwrap(value)
    local path = type(value) == "string" and value or nil
    if not path and value then
        local system = object(KISMET)
        if valid(system) then
            local ok, result = pcall(function() return system:Conv_SoftObjectReferenceToString(value) end)
            if ok then path = text(result) end
        end
    end
    if not path then return nil end
    path = path:match("^[^']*'([^']+)'$") or path
    -- Asset identifiers only: external files have a separate fixed-manifest route.
    if path == "" or path == "None" or not path:match("^/[A-Za-z0-9_][A-Za-z0-9_./%-]+$")
        or path:find("..", 1, true) then return nil end
    return path
end
local function unavailable(meta, reason)
    meta.placeholder, meta.reason = true, tostring(reason or "图像资源不可用")
    return nil, meta
end
local function remember(path, texture)
    sequence = sequence + 1
    cache[path], recent[path] = texture, sequence
    local count, oldest, oldestTime = 0, nil, math.huge
    for key in pairs(cache) do
        count = count + 1
        if key ~= path and (recent[key] or 0) < oldestTime then oldest, oldestTime = key, recent[key] or 0 end
    end
    if count > CACHE_LIMIT and oldest then cache[oldest], recent[oldest] = nil, nil end
    return texture
end
local function dimensions(texture, meta)
    local ok, width, height = pcall(function()
        return texture:Blueprint_GetSizeX(), texture:Blueprint_GetSizeY()
    end)
    if ok and type(width) == "number" and type(height) == "number" and width > 0 and height > 0 then
        meta.width, meta.height = width, height
    end
    meta.box = meta.box or { 0, 0, 1, 1 }
    meta.flip = false
    meta.placeholder = false
    return texture, meta
end

function Art.texture(context, path, metadata)
    local meta = copy(metadata or {})
    path = softPath(path)
    if not path then return unavailable(meta, "没有有效的原生贴图路径") end
    meta.texturePath = path
    if valid(cache[path]) then return dimensions(remember(path, cache[path]), meta) end
    if failures[path] then return unavailable(meta, failures[path]) end
    local ok, result = pcall(function()
        local texture = object(path)
        if not valid(texture) then
            LoadAsset(path)
            texture = object(path)
        end
        assert(valid(texture), "原生贴图尚未加载：" .. path)
        -- Texture2D's reflected getters also reject an accidental non-texture asset.
        assert(texture:Blueprint_GetSizeX() > 0 and texture:Blueprint_GetSizeY() > 0,
            "图像不是有效的 Texture2D")
        return texture
    end)
    if not ok then failures[path] = tostring(result); return unavailable(meta, result) end
    remember(path, result)
    return dimensions(result, meta)
end

local function external(context, record)
    local meta = copy(record or {})
    if not record or not root then return unavailable(meta, "原生 UI 图像目录不可用") end
    local filename = record.file
    if type(filename) ~= "string" or not filename:match("^[A-Za-z0-9_%-]+%.png$")
        and not filename:match("^[A-Za-z0-9_%-]+%.jpg$") then
        return unavailable(meta, "图像文件名不在固定资源目录中")
    end
    local path = root .. "/" .. filename
    meta.filePath = path
    if valid(cache[path]) then return dimensions(remember(path, cache[path]), meta) end
    if failures[path] then return unavailable(meta, failures[path]) end
    local ok, result = pcall(function()
        local library = object(RENDERING)
        assert(valid(library), "没有原生图像导入接口")
        local texture = library:ImportFileAsTexture2D(context, path)
        assert(valid(texture), "无法载入 UI 图像：" .. filename)
        return texture
    end)
    if not ok then failures[path] = tostring(result); return unavailable(meta, result) end
    remember(path, result)
    return dimensions(result, meta)
end

function Art.home(context, id)
    local record = Data.home[id]
    if not record then return unavailable({ name = tostring(id) }, "没有此模式场景图") end
    return external(context, record)
end
function Art.soul(context, uiCycle)
    if type(uiCycle) ~= "number" or uiCycle % 1 ~= 0 or uiCycle < -1 or uiCycle > 6 then
        return unavailable({ name = "魂" }, "玩家形象档位无效")
    end
    return external(context, Data.soul[tostring(uiCycle)])
end
function Art.background(context) return external(context, Data.background) end
function Art.zhan(context) return external(context, Data.zhan) end
function Art.missionComplete(context)
    -- Original green completion seal: W_CompleteBranchEntry.Image_87 and
    -- W_QuestListView_Entry.Image_159 use this full-color Texture2D directly.
    return Art.texture(context, "/Game/PBZContent/UI/InGame/Quest/T_QuestSuccess.T_QuestSuccess", {
        name = "任务完成", source = "native-quest-completion", width = 128, height = 128,
        box = { 0, 0, 1, 1 }, alphaBox = { 15 / 128, 12 / 128, 101 / 128, 104 / 128 },
        preserveColor = true,
    })
end

function Art.members(encounterId)
    local ok, encounter = pcall(function() return require("EncounterCatalog").resolve(encounterId) end)
    if not ok or not encounter then return {}, nil end
    local members, seen = {}, {}
    local function add(member, stageIndex)
        local id = type(member) == "table" and member.id or member
        if type(id) == "string" and not seen[id] then
            local entry = { bossId = id, name = type(member) == "table" and member.name or id, stages = { stageIndex } }
            members[#members + 1], seen[id] = entry, entry
        elseif type(id) == "string" then
            local stages = seen[id].stages
            if stages[#stages] ~= stageIndex then stages[#stages + 1] = stageIndex end
        end
    end
    for stageIndex, stage in ipairs(encounter.stages or {}) do
        for _, member in ipairs(stage.members or {}) do add(member, stageIndex) end
    end
    -- Actor-internal summons may not be stage-spawned by this MOD. The catalog
    -- may explicitly declare their verified portrait identities as well.
    for _, member in ipairs(encounter.portraitMembers or {}) do add(member, 0) end
    return members, encounter
end

function Art.bossMember(context, bossId, kind)
    local meta = { name = tostring(bossId), sourceBossId = bossId, crop = kind or "full", cropFraction = 1,
        box = { 0, 0, 1, 1 }, flip = false }
    local record = Data.bosses[bossId] or (Data.displayPortraits or {})[bossId]
    if not record then return unavailable(meta, "此对象没有匹配的真实图鉴图像") end
    meta.name, meta.sourceBossName = record.name, record.name
    local path = record.texturePath
    if kind == "chest" or kind == "bust" then
        local portrait = record.portrait
        if not portrait or not portrait.verified then return unavailable(meta, "此对象的上胸构图尚未校准") end
        path, meta.box = portrait.texturePath, copy(portrait.box)
        meta.variant = portrait.variant == "half" and "native-half" or "full"
        meta.boxVerified, meta.framing = true, portrait.framing
        meta.measuredWidth, meta.measuredHeight = portrait.width, portrait.height
        if bossId == "BP_Monster_ChiLian_P2" then
            -- This authored pose is inverted. Its older wide chest box includes
            -- both arms but misses the full head/crown. A composite-only subject
            -- keeps the actual face/neck readable; single-target framing is kept.
            -- Reviewed against the original 3800x2048 H texture, no image edits.
            meta.compositeBox = {1650/3800,1070/2048,520/3800,440/2048}
            meta.faceBox = {1720/3800,1180/2048,400/3800,320/2048}
        end
    else
        meta.variant, meta.box, meta.boxVerified = "full", copy(record.box), record.boxVerified
    end
    -- A failed native texture stays missing. Falling back to an uncalibrated
    -- full image would silently reintroduce cut-off faces and weapon centering.
    return Art.texture(context, path, meta)
end

function Art.encounter(context, encounterId, kind)
    local members, encounter = Art.members(encounterId)
    local result = {}
    for _, member in ipairs(members) do
        local texture, meta = Art.bossMember(context, member.bossId, kind or "chest")
        meta.encounterId, meta.encounterName, meta.memberName, meta.stages = encounter.id, encounter.name, member.name, member.stages
        result[#result + 1] = { bossId = member.bossId, name = member.name, texture = texture, meta = meta }
    end
    return result
end

-- Compatibility for single-art callers. Shared selection/result pages use
-- Art.encounter/PortraitLayout so every phase and group member is represented.
function Art.boss(context, encounterId, kind)
    local members, encounter = Art.members(encounterId)
    if not encounter or #members == 0 then return unavailable({ name = tostring(encounterId) }, "找不到当前挑战对象") end
    local texture, meta = Art.bossMember(context, members[1].bossId, kind)
    meta.encounterId, meta.name, meta.members, meta.representative = encounter.id, encounter.name, {}, #members > 1
    for _, member in ipairs(members) do meta.members[#meta.members + 1] = member.bossId end
    return texture, meta
end

local function backpack(context)
    local subsystems, class = object(SUBSYSTEMS), object(BACKPACK)
    assert(valid(subsystems) and valid(class), "背包接口不可用")
    local result = subsystems:GetWorldSubsystem(context, class)
    assert(valid(result), "当前世界背包不可用")
    return result
end
local function firstPath(...)
    for index = 1, select("#", ...) do
        local path = softPath(select(index, ...))
        if path then return path end
    end
end
local function forgedInfo(map, id)
    local forged = false
    if map and type(map.ForEach) == "function" then
        map:ForEach(function(key, value)
            if text(key) == id then
                value = unwrap(value)
                forged = value.bAlreadySnapSoul == true
            end
        end)
    end
    return forged
end

-- The path-only API allows reports to persist a plain snapshot before map reload.
function Art.equipmentPath(context, kind, id, level, info)
    local meta = { kind = kind, id = text(id), level = level, box = { 0, 0, 1, 1 } }
    if info and softPath(info.iconPath) then return softPath(info.iconPath), meta end
    if meta.id == "" or meta.id == "None" then meta.empty = true; return nil, meta end
    local ok, path = pcall(function()
        local bp = backpack(context)
        local name = FName(meta.id)
        if kind == "main" or kind == "weapon" or kind == "shadow" or kind == "shadowWeapon" then
            local main = kind == "main" or kind == "weapon"
            local row = main and bp:GetMainWeaponTableData(name) or bp:GetShaqiWeaponTableData(name)
            local forged = info and (info.forged == true or info.bAlreadySnapSoul == true)
            if info == nil then forged = forgedInfo(main and bp.MainWeaponInfos or bp.ShaqiWeaponInfos, meta.id) end
            meta.forged = forged == true
            local snap = main and row.WeaponSnapSoulData or row.ShaChiWeaponSnapSoulData
            local normal = main and row.White or row.WhiteIcon
            if forged and snap and softPath(snap.RenderIcon) then
                return firstPath(snap.WhiteIcon, normal, snap.RenderIcon, row.RenderIcon)
            end
            return firstPath(normal, row.RenderIcon)
        end
        local defaults = object(BACKPACK_CDO)
        assert(valid(defaults), "背包数据表默认对象不可用")
        if kind == "accessory" then
            local row = defaults:GetAccessoryData(name)
            -- Icon may be a shared legacy placeholder: never prefer it.
            return firstPath(row.WhiteIcon, row.HighPrecisionTexture)
        elseif kind == "medicine" then
            local row = defaults:GetMedicineData(name)
            return firstPath(row.SmallRenderIcon, row.SoftTexture, row.HighPrecisionTexture)
        end
        error("未知装备类型")
    end)
    if not ok then meta.placeholder, meta.reason = true, tostring(path); return nil, meta end
    if not path then meta.placeholder, meta.reason = true, "该物品没有有效的专属图像" end
    return path, meta
end
function Art.equipment(context, kind, id, level, info)
    local path, meta = Art.equipmentPath(context, kind, id, level, info)
    if not path then return nil, meta end
    return Art.texture(context, path, meta)
end
function Art.clear()
    -- Existing image brushes retain their own texture references until removed.
    cache, failures, recent, sequence = {}, {}, {}, 0
end

return Art
