local Inventory = {}
local source = debug.getinfo(1, "S").source
local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local sequence = 0

local function base64(bytes)
    local result = {}
    local function digit(value)
        return alphabet:sub(value + 1, value + 1)
    end
    for index = 1, #bytes, 3 do
        local a, b, c = bytes:byte(index, index + 2)
        result[#result + 1] = digit(math.floor(a / 4))
        result[#result + 1] = digit(a % 4 * 16 + math.floor((b or 0) / 16))
        result[#result + 1] = b and digit(b % 16 * 4 + math.floor((c or 0) / 64)) or "="
        result[#result + 1] = c and digit(c % 64) or "="
    end
    return table.concat(result)
end

-- Scan only the installed MOD directories. The temporary result is outside
-- the game and is passed through a file because Windows GUI _popen is unsafe.
local scan = [=[
param($encodedRoot, $encodedResult)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$utf8 = [Text.UTF8Encoding]::new($false)
$root = $utf8.GetString([Convert]::FromBase64String($encodedRoot))
$result = $utf8.GetString([Convert]::FromBase64String($encodedResult))
$lines = [Collections.Generic.List[string]]::new()
function Link($item) { $item.Attributes -band [IO.FileAttributes]::ReparsePoint }
function Item($path) { Get-Item -LiteralPath $path -Force -EA SilentlyContinue }
function Directory($path) {
    $item = Item $path
    if (!$item) { return }
    if (!$item.PSIsContainer) { throw 'Not a directory' }
    for ($parent = $item; $parent; $parent = $parent.Parent) {
        if (Link $parent) { throw 'Linked directory' }
    }
    $item
}
function File($path) {
    $item = Item $path
    $item -is [IO.FileInfo] -and !(Link $item)
}
try {
    $ue = Directory "$root/platform/steam/ue4ss/Mods"
    if (!$ue) { throw 'UE4SS not found' }
    $settings = Join-Path $ue.Parent.FullName 'UE4SS-settings.ini'
    $unknown = $env:UE4SS_MODS_PATHS -or ((File $settings) -and
        ([IO.File]::ReadAllText($settings) -match '(?im)^[ \t]*([+-]?ModsFolderPaths|ControllingModsTxt)[ \t]*=[ \t]*[^;\r\n\s]'))
    $active = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $file = Join-Path $ue.FullName 'mods.txt'
    if (File $file) {
        foreach ($line in [IO.File]::ReadLines($file)) {
            if ($line.Contains(';')) { continue }
            $parts = $line.Replace(' ', '').Split(':')
            if ($parts.Length -gt 1 -and $parts[-1].StartsWith('1')) { [void]$active.Add($parts[0]) }
        }
    }
    foreach ($mod in $ue.GetDirectories()) {
        if (Link $mod) { continue }
        $path = $mod.FullName
        $lua = Item "$path/Scripts"
        $dll = Item "$path/dlls"
        if (!(($lua -is [IO.DirectoryInfo] -and !(Link $lua) -and (File "$path/Scripts/main.lua")) -or
            ($dll -is [IO.DirectoryInfo] -and !(Link $dll) -and ((File "$path/dlls/main.dll") -or (File "$path/dlls/$($mod.Name).dll"))))) { continue }
        $state = if ($unknown) {'?'} elseif ($active.Contains($mod.Name) -or (File "$path/enabled.txt")) {'1'} else {'0'}
        $lines.Add("U|${state}|$($mod.Name)")
    }
    $lines.Add('UE4SS|ok')
} catch { $lines.Add('UE4SS|unavailable') }
try {
    $paks = Directory "$root/ProjectPBZ/Content/Paks/~mods"
    if ($paks) {
        $queue = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
        $queue.Push($paks)
        while ($queue.Count) {
            foreach ($item in $queue.Pop().GetFileSystemInfos()) {
                if (Link $item) { continue }
                if ($item -is [IO.DirectoryInfo]) { $queue.Push($item); continue }
                if ($item.Extension -in '.pak', '.utoc', '.ucas') {
                    $lines.Add('P|' + $item.FullName.Substring($paks.FullName.Length + 1).Replace('\','/'))
                }
            }
        }
    }
    $lines.Add('PAK|ok')
} catch { $lines.Add('PAK|unavailable') }
$bytes = $utf8.GetBytes([string]::Join([char]10, $lines))
$file = [IO.File]::Open($result, [IO.FileMode]::CreateNew)
try { $file.Write($bytes, 0, $bytes.Length) } finally { $file.Dispose() }
]=]

local unavailable = "当前无法读取本地 MOD 目录。"
local statuses = {
    ["1"] = {status = "configured-enabled", label = "配置已启用"},
    ["0"] = {status = "configured-disabled", label = "配置已禁用"},
    ["?"] = {status = "configuration-unknown", label = "配置未知"},
}

local function collection(text)
    local result, pakGroups, found = {ue4ss = {}, pak = {}}, {}, {}
    for line in text:gmatch("[^\r\n]+") do
        local flag, id = line:match("^U|([01?])|([^|]+)$")
        if id then
            local state = statuses[flag]
            result.ue4ss[#result.ue4ss + 1] = {id = id, kind = "ue4ss", status = state.status, label = state.label,
                protected = id:lower() == "pbztestarena"}
        else
            local path = line:match("^P|([^|]+)$")
            local stem, ext
            if path then stem, ext = path:match("^(.+)%.([^.]+)$") end
            if stem then
                local key = stem:lower()
                local group = pakGroups[key]
                if not group then
                    group = {id = stem, name = stem:match("[^/]+$"), kind = "pak"}
                    pakGroups[key] = group
                    result.pak[#result.pak + 1] = group
                end
                group[ext:lower()] = true
            else
                local name = line:match("^([A-Z0-9]+)|ok$")
                if name then found[name] = true end
            end
        end
    end
    for _, group in ipairs(result.pak) do
        local pairedContainers = (group.utoc == group.ucas)
        local complete = group.pak and pairedContainers
        group.status = complete and "available" or "incomplete"
        group.label = complete and "已安装" or "缺少配套文件"
    end
    local function byName(left, right)
        return left.id:lower() < right.id:lower()
    end
    if found.UE4SS then table.sort(result.ue4ss, byName) else result.ue4ss = {} end
    if found.PAK then table.sort(result.pak, byName) else result.pak = {} end
    local ue4ssReason = not found.UE4SS and "当前无法读取 UE4SS MOD 目录。" or nil
    local pakReason = not found.PAK and "当前无法读取 PAK 目录。" or nil
    return result, ue4ssReason, pakReason
end

local function read()
    local filename = source:match("^@(.+)$")
    if not filename then return end
    filename = filename:gsub("\\", "/")
    local root = filename:lower():match("^(.*)/platform/steam/ue4ss/mods/pbztestarena/scripts/modfeatureinventory%.lua$")
    local system, temp = os.getenv("SystemRoot"), os.getenv("TEMP")
    if not root or not root:match("^[a-z]:/") or not temp or not temp:match("^[A-Za-z]:[/\\]")
        or not system or not system:match("^[A-Za-z]:\\[A-Za-z0-9_ .\\-]+$") or type(os.execute) ~= "function" then return end
    sequence = sequence + 1
    local nonce = (tostring({}):match("0x([0-9a-fA-F]+)") or "0"):lower()
    local filenameOut = ("%s/PBZModFeatureInventory-%s-%d-%d.txt"):format(temp, nonce, os.time(), sequence)
    local args = ("} '%s' '%s'"):format(base64(filename:sub(1, #root)), base64(filenameOut))
    local code = "& {\n" .. scan .. "\n" .. args
    -- Only Base64 enters the shell argument. UTF-8 keeps it below cmd's size
    -- limit without changing the contents of the collector or the path.
    local command = '""' .. system .. '\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"'
        .. " -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -Command "
        .. "\"& ([ScriptBlock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"
        .. base64(code) .. "'))))\"\""
    if #command > 8000 then return end
    local success = os.execute(command)
    if success ~= true and success ~= 0 then return end
    local stream = io.open(filenameOut, "rb")
    if not stream then return end
    local bytes = stream:read("*a")
    stream:close()
    os.remove(filenameOut)
    return bytes
end

function Inventory.list()
    local ok, bytes = pcall(read)
    if not ok or not bytes then
        return {ue4ss = {}, pak = {}}, unavailable, unavailable
    end
    return collection(bytes)
end

return Inventory
