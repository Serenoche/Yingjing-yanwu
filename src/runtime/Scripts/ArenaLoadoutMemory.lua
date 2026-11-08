-- Owned, data-only equipment selection. Never persists levels, resources,
-- attributes or skills. Windows commits are recoverable renames, not an
-- atomic replace: a verified primary or backup survives each transition.
local Native=require("ArenaLoadout")
local Memory,Service={},{}
Service.__index=Service
local OWNER="7d5ad307-d21c-47eb-9584-493443190984"
local HEADER="PBZ_ARENA_LOADOUT\t1\t"..OWNER
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
    assert(path:lower():match("/arenapreferences/pbzloadout%.tsv$"),"配装记忆只能位于指定ArenaPreferences/PBZLoadout.tsv")
    return path
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
local function encode(value)
    value=snapshot(value);local rows={HEADER}
    for _,group in ipairs(GROUPS)do for index=1,group[2]do
        local value=value[group[1]][index]
        rows[#rows+1]=group[1].."\t"..index.."\t"..(value==false and "-" or hex(value))
    end end
    local body=table.concat(rows,"\n").."\n"
    return body.."CHECKSUM\t"..checksum(body).."\n"
end
local function decode(bytes)
    assert(type(bytes)=="string"and #bytes<=16384 and bytes:sub(-1)=="\n","配装记忆不完整")
    local rows={};for row in bytes:gmatch("([^\n]*)\n")do rows[#rows+1]=row end
    assert(#rows==14 and rows[1]==HEADER,"配装记忆所有者、版本或记录数量不匹配")
    local body=table.concat(rows,"\n",1,13).."\n"
    assert(rows[14]=="CHECKSUM\t"..checksum(body),"配装记忆完整性校验失败")
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
    return snapshot(result)
end
local function unique(path,kind)
    for _=1,64 do
        sequence=sequence+1;local candidate=path.."."..kind.."-"..os.time().."-"..sequence
        if not read(candidate)then return candidate end
    end
    error("无法创建独立配装提交文件")
end
local function verified(bytes)if not bytes then return false end;return pcall(decode,bytes)end
local function commit(self,bytes)
    owned(self.path)
    assert(not self.readOnly,"保留未知primary内容，本次配装记忆只读")
    local before=read(self.path)
    assert(before==self.diskBytes,"配装记忆已由其他会话修改，本次不覆盖")
    local backup=read(self.path..".bak")
    assert(not backup or verified(backup),"配装备份不属于本MOD或已损坏，不覆盖")
    local temporary=unique(self.path,"tmp")
    local file=assert(io.open(temporary,"wb"),"无法写入配装临时文件")
    local wrote,why=file:write(bytes);local flushed=file:flush();local closed=file:close()
    assert(wrote and flushed and closed,why or "无法完成配装临时写入")
    assert(read(temporary)==bytes and verified(bytes),"配装提交回读失败")
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
    assert(read(self.path)==bytes and verified(read(self.path)),"新配装primary校验失败；backup仍保留")
    if retired and verified(read(retired))then os.remove(retired)end
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
function Memory.new(path,isPrivate,log)
    local ok,result=pcall(function()
        assert(type(isPrivate)=="function","配装记忆缺少私有会话守卫")
        path=normalize(path);owned(path)
        local primary,backup=read(path),read(path..".bak")
        local choice,dirty,readOnly,warning
        if primary then
            local parsed,value=pcall(decode,primary)
            if parsed then choice=value
            elseif backup and verified(backup)then
                choice=decode(backup);readOnly=true;warning="primary内容未知或损坏，使用已验证backup且不覆盖未知文件"
            else error("primary内容未知或损坏；未找到完整自有backup")end
        elseif backup then choice=decode(backup);dirty=true end
        return setmetatable({path=path,isPrivate=isPrivate,log=log,selection=choice,diskBytes=primary,
            dirty=dirty,readOnly=readOnly,warning=warning,state="pending",nextAttempt=0,nextCapture=0},Service)
    end)
    if not ok then return nil,tostring(result)end
    return result
end
function Service:flush()
    if not self.dirty or not self.selection then return true end
    local ok,why=pcall(commit,self,encode(self.selection))
    if not ok then say(self,why);return false,why end
    return true
end
function Service:beginLoad(pawn)
    -- Only an explicit, still-private pre-load checkpoint may read equipment.
    -- Raw LoadGame/MapPre teardown passes nil and flushes cached data only.
    if self.state=="ready"and active(self,pawn)and pawn:GetAddress()==self.pawnId then
        local ok,value=pcall(Native.capture,pawn)
        if ok and value then
            local good,copy=pcall(snapshot,value)
            if good and encode(copy)~=encode(self.selection)then self.selection=copy;self.dirty=true end
        end
    end
    self.state="suspended";self:flush()
end
function Service:update(pawn,now)
    if not active(self,pawn)then return false,"非私有演武会话，未读取或应用配装"end
    assert(type(now)=="number"and now==now and math.abs(now)<math.huge,"配装记忆时钟无效")
    local address=pawn:GetAddress()
    if self.pawnId and self.pawnId~=address then
        self.state,self.since,self.candidate,self.nextAttempt="pending",nil,nil,0
    end
    self.pawnId=address
    if self.state=="suspended"or self.state=="disabled"then return true end
    self.since=self.since or now
    if self.state=="pending"then
        if now-self.since>=12 then
            self.state="disabled";say(self,"恢复等待超时；保留原记忆，本次不采集，演武继续")
            return true
        end
        if now<self.nextAttempt then return false,"等待原生配装初始化"end
        self.nextAttempt=now+.10
        if self.selection then
            local ok,result,reason=pcall(Native.apply,pawn,snapshot(self.selection))
            if not ok or result~=true then
                say(self,"等待恢复："..tostring(ok and reason or result));return false,ok and reason or result
            end
            self.state,self.nextCapture="ready",now+.5
            say(self,self.warning or "已恢复槽位选择；等级和铸魂沿用本次预设")
            if self.dirty then self:flush()end
            return true
        end
        local ok,value,reason=pcall(Native.capture,pawn)
        local good,copy=false,nil
        if ok and value then good,copy=pcall(snapshot,value)end
        if not good then self.candidate=nil;return false,"等待完整原生配装："..tostring(reason or value)end
        local encoded=encode(copy)
        if not self.candidate or self.candidate.bytes~=encoded then self.candidate={bytes=encoded,since=now,count=0}end
        self.candidate.count=self.candidate.count+1
        if self.candidate.count<3 or now-self.candidate.since<.5 then return false,"等待初始配装连续稳定"end
        self.selection,self.dirty,self.state,self.nextCapture=copy,true,"ready",now+.5
        self:flush();say(self,"已建立本MOD专用槽位记忆")
        return true
    end
    if now<self.nextCapture then return true end;self.nextCapture=now+.5
    local ok,value=pcall(Native.capture,pawn)
    if ok and value then
        local good,copy=pcall(snapshot,value)
        if good and encode(copy)~=encode(self.selection)then self.selection,self.dirty=copy,true end
    end
    if self.dirty and now>=(self.nextWrite or 0)then
        local saved=self:flush();self.nextWrite=now+(saved and .5 or 5)
    end
    return true
end
function Service:close()
    if self.closed then return end
    self.closed=true;self.state="closed";self:flush()
end
return Memory
