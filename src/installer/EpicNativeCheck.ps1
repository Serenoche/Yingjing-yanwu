function Check-NativeFile([string] $Game, $Requirements) {
    # Use the exact verified reference windows of the shipped native DLL, not
    # only the shorter samples in the remote locator report.
    $file = [IO.File]::OpenRead($Game)
    $pe = [IO.BinaryReader]::new($file)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $null = $file.Seek(60,[IO.SeekOrigin]::Begin)
        $header = $pe.ReadUInt32()
        if ($header -lt 64 -or $header -gt 1MB -or $file.Length -lt ($header+264)) { throw 'Bad PE header' }
        $null = $file.Seek($header,[IO.SeekOrigin]::Begin)
        if ($pe.ReadUInt32() -ne 17744 -or $pe.ReadUInt16() -ne 34404) { throw 'Expected AMD64 PE' }
        $count = $pe.ReadUInt16()
        $null = $file.Seek($header+20,[IO.SeekOrigin]::Begin)
        $optSize = $pe.ReadUInt16()
        $table = $header+24+$optSize
        if ($count -lt 1 -or $count -gt 96 -or $optSize -ne 240 -or $table+40*$count -gt $file.Length) { throw 'Bad PE section table' }
        $sections = @()
        for ($i=0; $i -lt $count; $i++) {
            $null = $file.Seek($table+40*$i+8,[IO.SeekOrigin]::Begin)
            $virtual,$rva,$size,$offset = $pe.ReadUInt32(),$pe.ReadUInt32(),$pe.ReadUInt32(),$pe.ReadUInt32()
            $null = $file.Seek($table+40*$i+36,[IO.SeekOrigin]::Begin)
            $sections += @{ rva=$rva; offset=$offset; size=$size; flags=$pe.ReadUInt32() }
        }
        foreach ($item in $Requirements) {
            $section = @($sections | Where-Object { $item.rva -ge $_.rva -and
                [long]$item.rva - $_.rva + $item.bytes -le $_.size })
            if ($section.Count -ne 1 -or $item.bytes -lt 1 -or $item.bytes -gt 512) { $item.name; continue }
            $section = $section[0]
            $start = [long]$section.offset + $item.rva - $section.rva
            if ($start + $item.bytes -gt $file.Length -or
                ($item.kind -eq 'code' -and !($section.flags -band 0x20000000)) -or
                ($item.kind -eq 'constant_data' -and (($section.flags -band 0x20000000) -or ([long]$section.flags -band 2147483648)))) {
                $item.name; continue
            }
            $null = $file.Seek($start,[IO.SeekOrigin]::Begin)
            $digest = [BitConverter]::ToString($sha.ComputeHash($pe.ReadBytes($item.bytes))).Replace('-','').ToLowerInvariant()
            if ($digest -cne $item.sha256) { $item.name }
        }
    } finally { $sha.Dispose(); $pe.Dispose(); $file.Dispose() }
}
