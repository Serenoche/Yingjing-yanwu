local Writer = {}
local Settings = require("ModLoaderSettings")
local sequence = 0
local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64(bytes)
    local encoded = {}
    local function digit(value)
        return alphabet:sub(value + 1, value + 1)
    end
    for i = 1, #bytes, 3 do
        local a, b, c = bytes:byte(i, i + 2)
        encoded[#encoded + 1] = digit(math.floor(a / 4))
        encoded[#encoded + 1] = digit(a % 4 * 16 + math.floor((b or 0) / 16))
        encoded[#encoded + 1] = b and digit(b % 16 * 4 + math.floor((c or 0) / 64)) or "="
        encoded[#encoded + 1] = c and digit(c % 64) or "="
    end
    return table.concat(encoded)
end

-- Invoked only by Save. The argument values are encoded separately from code.
local replaceScript = [=[
param($encodedTarget,$token)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$target = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedTarget))
if ($token -cnotmatch '^[0-9a-f]+-[0-9]+-[0-9]+$' -or [IO.Path]::GetFileName($target) -cne 'mods.ini') { exit 1 }
$prefix = "$target.pbz-features-$token"
$expected = "$prefix.current"
$next = "$prefix.next"
$backup = "$prefix.backup"
$lock = [Threading.Mutex]::new($false, 'Local\PBZModFeaturesIniWrite')
$held = $false
try {
    try { $held = $lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (!$held) { exit 2 }
    foreach ($path in @($target,$expected,$next)) {
        $item = Get-Item -LiteralPath $path -Force
        if ($item.PSIsContainer) { exit 1 }
        while ($item) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { exit 1 }
            $item = if ($item.PSIsContainer) { $item.Parent } else { $item.Directory }
        }
    }
    if ([IO.File]::Exists($backup)) { exit 1 }
    $stream = [IO.File]::Open($target,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
    try {
        if ($stream.Length -ne [IO.FileInfo]::new($expected).Length) { exit 2 }
        $bytes = [IO.MemoryStream]::new()
        try { $stream.CopyTo($bytes); $current = [Convert]::ToBase64String($bytes.ToArray()) }
        finally { $bytes.Dispose() }
        if ($current -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($expected))) { exit 2 }
        [IO.File]::Replace($next,$target,$backup)
    } finally { $stream.Dispose() }
    try { [IO.File]::Delete($backup) } catch {}
    exit 0
} catch {
    if (![IO.File]::Exists($target) -and [IO.File]::Exists($backup)) {
        [IO.File]::Move($backup,$target)
    }
    exit 1
} finally {
    if ($held) { $lock.ReleaseMutex() }
    $lock.Dispose()
}
]=]

local function stage(path, value)
    local previous = io.open(path, "rb")
    if previous then previous:close(); return false end
    local file = io.open(path, "wb")
    if not file then return false end
    local written = file:write(value)
    local closed = file:close()
    if written and closed then return true end
    os.remove(path)
    return false
end

local function replace(path, before, after)
    local system = os.getenv("SystemRoot")
    if not system or not system:match("^[A-Za-z]:\\[A-Za-z0-9_ .\\-]+$") or type(os.execute) ~= "function" then
        return false, "系统文件保存接口不可用。"
    end
    sequence = sequence + 1
    local nonce = (tostring({}):match("0x([0-9a-fA-F]+)") or "0"):lower()
    local token = ("%s-%d-%d"):format(nonce, os.time(), sequence)
    local prefix = path .. ".pbz-features-" .. token
    local current, nextFile = prefix .. ".current", prefix .. ".next"
    local code = "& {\n" .. replaceScript .. "\n} '" .. base64(path) .. "' '" .. token .. "'"
    local encoded = base64(code:gsub(".", "%0\0"))
    local command = '"' .. system .. '\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"'
        .. " -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand " .. encoded
    if #command > 8000 then return false, "PBZModLoader 设置文件路径过长。" end

    if not stage(current, before) then return false, "无法写入 PBZModLoader 设置目录。" end
    if not stage(nextFile, after) then
        os.remove(current)
        return false, "无法写入 PBZModLoader 设置目录。"
    end
    local called, result, _, exitCode = pcall(os.execute, command)
    os.remove(current)
    os.remove(nextFile)
    if called and (result == true or result == 0) then return true end
    if exitCode == 2 or result == 2 then return false, "配置刚被改动，请返回后重新打开菜单。" end
    return false, "未能保存 PBZModLoader 设置。"
end

function Writer.configure(source)
    local filename = type(source) == "string" and source:match("^@(.+)$")
    if not filename then return false end
    filename = filename:gsub("\\", "/")
    local root, platform = filename:lower():match("^(.*)/platform/([^/]+)/ue4ss/mods/pbztestarena/scripts/main%.lua$")
    if not root or not root:match("^[a-z]:/") or (platform ~= "steam" and platform ~= "epicgamestore") then return false end
    local path = filename:sub(1, #root) .. "/ProjectPBZ/PBZModLoader/mods.ini"
    Settings.configure(path, platform == "steam" and replace or nil)
    return true
end

return Writer
