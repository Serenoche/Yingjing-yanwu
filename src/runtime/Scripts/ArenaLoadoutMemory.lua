-- Account-owned equipment and skill choices for private arena sessions.
-- Windows commits are recoverable renames, not an
-- atomic replace: a verified primary or backup survives each transition.
local Native=require("ArenaLoadout")
local Restore=require("ArenaLoadoutRestore")
local Memory,Service={},{}
Service.__index=Service
local OWNER="7d5ad307-d21c-47eb-9584-493443190984"
local HEADER="PBZ_ARENA_LOADOUT\t1\t"..OWNER
local PALACE_HEADER="PBZ_ARENA_LOADOUT\t2\t"..OWNER
local SKILL_HEADER="PBZ_ARENA_SKILLS\t1\t"..OWNER
local GROUPS={{"mainWeapons",2},{"shadowWeapons",2},{"accessories",6},{"medicines",2}}
local sequence=0
local function valid(p)return p~=nil and type(p.IsValid)=="function" and p:IsValid()end
local function normalize(path)
    assert(type(path)=="string" and #path<=1024 and not path:find("[%z\1-\31\127]"),"配装记忆路径无效")
    path=path:gsub("\\","/")
    assert(path:match("^[A-Za-z]:/") and not path:find("//",1,true) and not path:sub(3):find(":",1,true),"配装记忆必须是本地绝对路径")
    assert(not path:find('[*?<>|"]'),"配装记忆路径含保留字符")
    for part in path:gmatch("[^/]+")do
        assert(part~="."and part~=".."and not part:match("[. ]$"),"配装记忆路径含相对或别名目录")
    end
    local file = path:lower():match("/arenapreferences/([^/]+)$")
    local palace = file == "pbzbloodypalaceloadout.tsv" or file == "pbzbloodypalace101internalloadout.tsv"
        or file == "pbzbloodypalacemechanicsinternalloadout.tsv" or file == "pbzbloodypalaceendinginternalloadout.tsv"
    local tier = file and file:match("^pbzdreampalaceloadout%-([a-z]+)%.tsv$")
    -- The Palace caller has already loaded its tier definitions. Ordinary
    -- arena and compatibility-only builds do not have to load that runtime.
    local profile = tier and package.loaded.DreamPalaceProfile
    palace = palace or file == "pbzdreampalaceloadout.tsv"
        or type(profile) == "table" and type(profile.tier) == "function" and profile.tier(tier) ~= nil
    assert(file == "pbzloadout.tsv" or palace, "配装记忆必须使用演武的 ArenaPreferences 文件")
    return path, palace
end
local function read(path)
    local file=io.open(path,"rb");if not file then return nil end
    local bytes=file:read(16385);file:close()
    return bytes or "" -- an existing empty/oversize file is invalid, not absent
end
local function owned(path)
    local marker=path:match("^(.*)/[^/]+$").."/.PBZTestArenaArenaPrefs-owner"
    assert((read(marker)or""):match("^%s*(.-)%s*$")==OWNER,"配装记忆目录缺少本MOD所有权标识")
end
local function id(value)
    return type(value)=="string"and #value>0 and #value<=256 and value~="None"and not value:find("[%z\1-\31\127]")
end
local function snapshot(value)
    assert(type(value)=="table"and value.version==1,"配装快照版本无效")
    local result,allowed={version=1},{version=true}
    for _,group in ipairs(GROUPS)do
        local name,count=group[1],group[2];allowed[name]=true
        local items=value[name];assert(type(items)=="table","配装快照缺少"..name)
        result[name]={}
        for index=1,count do
            local item=items[index];assert(item==false or id(item),"配装快照槽位不完整："..name..index)
            result[name][index]=item
        end
        for key in pairs(items)do assert(type(key)=="number"and key%1==0 and key>=1 and key<=count,"配装快照含额外槽位")end
    end
    for key in pairs(value)do assert(allowed[key],"配装快照含非选择字段："..tostring(key))end
    assert(result.mainWeapons[1]or result.mainWeapons[2],"配装快照尚无已初始化主武器")
    return result
end
local function checksum(bytes)
    local a,b=1,0
    for index=1,#bytes do a=(a+bytes:byte(index))%65521;b=(b+a)%65521 end
    return ("%04X%04X"):format(b,a)
end
local function hex(value)return(value:gsub(".",function(c)return("%02X"):format(c:byte())end))end
local function abilityRows(abilities)
    local rows = {}
    for key, level in pairs(abilities) do
        assert(type(key) == "string" and #key <= 64 and key:match("^[A-Za-z0-9_]+$"), "能力配置节点无效")
        assert(type(level) == "number" and level % 1 == 0 and level >= 0 and level <= 30, "能力配置等级无效")
        rows[#rows + 1] = key .. "\t" .. level
    end
    assert(#rows > 0 and #rows <= 64, "能力配置数量无效")
    table.sort(rows)
    return rows
end
local function encode(value, abilities)
    value=snapshot(value);local rows={abilities and PALACE_HEADER or HEADER}
    for _,group in ipairs(GROUPS)do for index=1,group[2]do
        local value=value[group[1]][index]
        rows[#rows+1]=group[1].."\t"..index.."\t"..(value==false and "-" or hex(value))
    end end
    if abilities then
        for _, row in ipairs(abilityRows(abilities)) do rows[#rows + 1] = row end
    end
    local body=table.concat(rows,"\n").."\n"
    return body.."CHECKSUM\t"..checksum(body).."\n"
end
local function verifiedRows(bytes)
    assert(type(bytes)=="string"and #bytes<=16384 and bytes:sub(-1)=="\n","配装记忆不完整")
    local rows={};for row in bytes:gmatch("([^\n]*)\n")do rows[#rows+1]=row end
    assert(#rows >= 2 and #rows <= 78, "演武配置的记录数量无效")
    local body=table.concat(rows,"\n",1,#rows-1).."\n"
    assert(rows[#rows]=="CHECKSUM\t"..checksum(body),"演武配置完整性校验失败")
    return rows
end

local function readAbilities(rows, start)
    local abilities = {}
    for index = start, #rows - 1 do
        local key, level = rows[index]:match("^([A-Za-z0-9_]+)\t(%d%d?)$")
        assert(key and #key <= 64 and abilities[key] == nil and tonumber(level) <= 30, "能力配置记录无效")
        abilities[key] = tonumber(level)
    end
    return abilities
end

local function encodeSkills(abilities)
    local body = SKILL_HEADER .. "\n" .. table.concat(abilityRows(abilities), "\n") .. "\n"
    return body .. "CHECKSUM\t" .. checksum(body) .. "\n"
end

local function decode(bytes, palace)
    local rows = verifiedRows(bytes)
    local withSkills = palace and rows[1] == PALACE_HEADER
    assert((#rows==14 and rows[1]==HEADER) or (withSkills and #rows>14),
        "配装记忆所有者、版本或记录数量不匹配")
    local result,cursor={version=1},2
    for _,group in ipairs(GROUPS)do
        result[group[1]]={}
        for index=1,group[2]do
            local prefix=group[1].."\t"..index.."\t"
            assert(rows[cursor]:sub(1,#prefix)==prefix,"配装记忆槽位顺序不匹配")
            local value=rows[cursor]:sub(#prefix+1);cursor=cursor+1
            if value=="-"then result[group[1]][index]=false else
                assert(#value>0 and #value%2==0 and not value:find("[^0-9A-F]"),"配装记忆ID编码无效")
                result[group[1]][index]=(value:gsub("..",function(pair)return string.char(tonumber(pair,16))end))
            end
        end
    end
    local abilities = withSkills and readAbilities(rows, cursor) or nil
    return snapshot(result), abilities
end
local function unique(path,kind)
    for _=1,64 do
        sequence=sequence+1;local candidate=path.."."..kind.."-"..os.time().."-"..sequence
        if not read(candidate)then return candidate end
    end
    error("无法创建独立配装提交文件")
end
local function verified(bytes,parse)if not bytes then return false end;return pcall(parse,bytes)end
local function commit(self,bytes)
    owned(self.path)
    assert(not self.readOnly,"保留未知primary内容，本次配装记忆只读")
    local before=read(self.path)
    assert(before==self.diskBytes,"配装记忆已由其他会话修改，本次不覆盖")
    local backup=read(self.path..".bak")
    assert(not backup or verified(backup,self.parse),"配装备份不属于本MOD或已损坏，不覆盖")
    local temporary=unique(self.path,"tmp")
    local file=assert(io.open(temporary,"wb"),"无法写入配装临时文件")
    local wrote,why=file:write(bytes);local flushed=file:flush();local closed=file:close()
    assert(wrote and flushed and closed,why or "无法完成配装临时写入")
    assert(read(temporary)==bytes and verified(bytes,self.parse),"配装提交回读失败")
    local retired
    if before then
        if backup then
            retired=unique(self.path,"previous")
            assert(os.rename(self.path..".bak",retired),"无法保留前次配装备份")
        end
        if not os.rename(self.path,self.path..".bak")then
            if retired then os.rename(retired,self.path..".bak")end
            error("无法将当前配装转存为备份；primary保持不变")
        end
    end
    if not os.rename(temporary,self.path)then
        if before then
            if os.rename(self.path..".bak",self.path)and retired then os.rename(retired,self.path..".bak")end
        elseif not backup then os.rename(temporary,self.path..".bak")end
        error("配装提交未完成；保留已验证primary或backup")
    end
    assert(read(self.path)==bytes and verified(read(self.path),self.parse),"新配装primary校验失败；backup仍保留")
    if retired and verified(read(retired),self.parse)then os.remove(retired)end
    self.diskBytes=bytes;self.dirty=false
end
local function active(self,pawn)
    local ok,value=pcall(self.isPrivate,pawn)
    return not self.closed and valid(pawn)and ok and value==true
end
local function say(self,reason)
    if reason and self.lastMessage~=reason then
        self.lastMessage=reason
        if self.log then self.log("配装记忆："..tostring(reason))end
    end
end
local function openStore(path, parse, isPrivate, log)
    assert(type(isPrivate)=="function","演武配置缺少私有会话守卫")
    owned(path)
    local primary,backup=read(path),read(path..".bak")
    local choice,abilities,readOnly,warning
    if primary then
        local parsed,value,secondary=pcall(parse,primary)
        if parsed then choice,abilities=value,secondary
        elseif backup and verified(backup,parse)then
            choice,abilities=parse(backup);readOnly=true;warning="primary内容未知或损坏，使用已验证backup且不覆盖未知文件"
        else error("primary内容未知或损坏；未找到完整自有backup")end
    elseif backup then choice,abilities=parse(backup) end
    return {path=path,isPrivate=isPrivate,log=log,parse=parse,diskBytes=primary,
        readOnly=readOnly,warning=warning},choice,abilities
end

function Memory.new(path,isPrivate,log,projected)
    local ok,result=pcall(function()
        local palace
        path,palace=normalize(path)
        local store,choice,abilities=openStore(path,function(bytes)return decode(bytes,palace)end,isPrivate,log)
        store.selection,store.abilities,store.palace=choice,abilities,palace
        store.projected=projected
        store.state="pending"
        return setmetatable(store,Service)
    end)
    if not ok then return nil,tostring(result)end
    return result
end

function Memory.checkpointSelection(path)
    if not path then return nil end
    local store, reason = Memory.new(path, function() return false end)
    if not store then return nil, reason end
    return store.selection
end

local Skills = {}
Skills.__index = Skills

function Memory.skills(loadoutPath,isPrivate,log)
    local path,palace = normalize(loadoutPath)
    assert(not palace, "账号技能使用普通演武目录")
    path = path:sub(1, -#"PBZLoadout.tsv" - 1) .. "PBZSkills.tsv"
    local ability = require("AbilityChallenge")
    local store,choice = openStore(path, function(bytes)
        local rows = verifiedRows(bytes)
        assert(rows[1] == SKILL_HEADER, "账号技能文件所有者或版本不匹配")
        local snapshot = readAbilities(rows, 2)
        ability.validateShared(snapshot)
        return snapshot
    end, isPrivate, log)
    store.abilities = choice
    if store.warning and log then log("账号技能：" .. store.warning) end
    return setmetatable(store, Skills)
end

function Skills:apply(pawn, ability, level)
    if not self.abilities or not active(self,pawn) then return end
    local effective, clamped = ability.projectShared(pawn, self.abilities, level)
    ability.restore(pawn, effective)
    if self.log then
        self.log(("ACCOUNT_SKILLS restored clamped=%d terminals=%d/%d/%d")
            :format(clamped, effective.HeiShi8, effective.ShaChiHuPo8, effective.MemoryFlower8))
    end
    return effective
end

function Skills:remember(pawn, before, after)
    if not before or not active(self,pawn) then return false end
    local full,changed = {},0
    for id,level in pairs(after) do
        -- Persist edits made in the skill screen, never the projected cap itself.
        local edited = before[id] ~= level
        full[id] = edited and level or (self.abilities and self.abilities[id]) or level
        if edited then changed = changed + 1 end
    end
    if changed == 0 then return true end
    local ok,failure = pcall(function() commit(self,encodeSkills(full)) end)
    if not ok then
        if self.log then self.log("账号技能保存失败：" .. tostring(failure)) end
        return false
    end
    self.abilities = full
    if self.log then self.log(("ACCOUNT_SKILLS saved edited=%d"):format(changed)) end
    return true
end

function Service:flush()
    if not self.dirty or not self.selection then return true end
    local ok,why=pcall(function() commit(self,encode(self.selection,self.abilities)) end)
    if not ok then say(self,why);return false,why end
    return true
end
function Service:setAbility(pawn, abilities)
    if not self.palace or self.state ~= "ready" or not active(self,pawn) or self.pawnId ~= pawn:GetAddress() then return false end
    local rows = abilityRows(abilities)
    if self.abilities and table.concat(rows,"\n") == table.concat(abilityRows(self.abilities),"\n") then return true end
    local copy = {}
    for key, level in pairs(abilities) do copy[key] = level end
    self.abilities, self.dirty = copy, true
    return true
end
-- A bell opened during restore can wait for readiness without reading live slots.
function Service:remember(pawn, equipment)
    if self.state == "pending" then return nil end
    if self.state ~= "ready" or not active(self, pawn) or pawn:GetAddress() ~= self.pawnId then return false end
    local ok, reason = pcall(function()
        local choice = snapshot(equipment or assert(Native.capture(pawn)))
        local bytes = encode(choice, self.abilities)
        if bytes ~= self.diskBytes then commit(self, bytes) end
        self.selection, self.dirty = choice, false
    end)
    if not ok then say(self, "铃铛保存失败：" .. tostring(reason)) end
    return ok
end

function Service:update(pawn)
    if not active(self, pawn) then return false, "非私有演武会话，未读取或应用配装" end
    local address = pawn:GetAddress()
    if self.pawnId and self.pawnId ~= address then
        self.state, self.restore = "pending", nil
    end
    self.pawnId = address
    if self.state ~= "pending" then return true end
    if not self.selection then
        self.state = "ready"
        return true
    end

    self.restore = self.restore or Restore.new(snapshot(self.selection), self.projected)
    local ready, reason = self.restore:update(pawn)
    if ready == nil then
        say(self, "等待恢复：" .. tostring(reason))
        return false, reason
    end
    self.state, self.restore = "ready", nil
    if ready then
        say(self, self.warning or (reason == "native" and "已随原生存点恢复槽位选择" or "已恢复槽位选择"))
    else
        say(self, "恢复等待超时，保留原记忆：" .. tostring(reason))
    end
    return true
end

function Service:close()
    if self.closed then return end
    self.closed, self.state, self.restore = true, "closed", nil
end
return Memory
