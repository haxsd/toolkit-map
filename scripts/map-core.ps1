# 地图存储、探测、项目选择与接入。map.ps1 是命令入口。
function Get-MapPath {
    $value = if ($MapFile) { $MapFile } elseif ($env:TOOLKIT_MAP) { $env:TOOLKIT_MAP } else { Join-Path $env:USERPROFILE '.toolkit\map.json' }
    return [IO.Path]::GetFullPath($value)
}
function Assert-MapWritePath {
    # The companion Markdown path uses ChangeExtension(..., '.md'). A map
    # ending in .md would otherwise be replaced by its own summary.
    if ([IO.Path]::GetExtension((Get-MapPath)) -ieq '.md') {
        Throw-MapError 'invalid_argument' '地图文件不能使用 .md 扩展名；该扩展名用于 Markdown 摘要。'
    }
}
function Get-WarehouseRoot {
    $value = if ($env:TOOLCHAIN_ROOT) { $env:TOOLCHAIN_ROOT } else { Join-Path $env:USERPROFILE 'toolchains' }
    return [IO.Path]::GetFullPath($value)
}
function Test-IsShimPath { param([string]$P) return (Test-ToolkitShimPath $P) }
function Test-IsStoreAlias { param([string]$P) return ($P -match '(?i)[\\/]WindowsApps[\\/]') }
function Test-IsEnvInternal {
    param([string]$P)
    if ($P -match '(?i)[\\/](site-packages|node_modules|\.venv|venv)[\\/]' -or
        ($P -match '(?i)[\\/]envs[\\/][^\\/]+[\\/]' -and [IO.Path]::GetFileNameWithoutExtension($P) -notin @('python', 'python3', 'java', 'node'))) { return $true }
    # Python venvs may be named anything: check pyvenv.cfg next to the exe or one level up (Scripts/bin).
    try { $parent = Split-Path ([IO.Path]::GetFullPath($P)) -Parent } catch { return $false }
    if ($parent -and [IO.File]::Exists((Join-Path $parent 'pyvenv.cfg'))) { return $true }
    $envRoot = if ($parent -and (Split-Path $parent -Leaf) -in @('Scripts', 'bin')) { Split-Path $parent -Parent } else { '' }
    return [bool]($envRoot -and [IO.File]::Exists((Join-Path $envRoot 'pyvenv.cfg')))
}
function Write-MapMessage {
    param([string]$Message, [string]$ForegroundColor = '')
    if (-not $Json) { Write-Host $Message }
}
function Write-MapWarning {
    param([string]$Message)
    if ($Json) { [Console]::Error.WriteLine($Message) } else { Write-Warning $Message }
}
function Throw-MapError {
    param([string]$Code, [string]$Message)
    $errorObject = New-Object System.InvalidOperationException $Message
    $errorObject.Data['code'] = $Code
    throw $errorObject
}
function New-MapResult {
    param([string]$Status = 'ok', [hashtable]$Fields = @{}, [bool]$Ok = $true)
    $result = @{ schemaVersion = 2; action = $Action.ToLowerInvariant(); status = $Status; ok = $Ok }
    foreach ($key in $Fields.Keys) { $result[$key] = $Fields[$key] }
    return $result
}
function ConvertTo-HashtableDeep {
    param($Obj)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Management.Automation.PSCustomObject] -or $Obj -is [System.Collections.IDictionary]) {
        $out = @{}
        if ($Obj -is [System.Collections.IDictionary]) { foreach ($key in $Obj.Keys) { $out[$key] = ConvertTo-HashtableDeep $Obj[$key] } }
        else { foreach ($prop in $Obj.PSObject.Properties) { $out[$prop.Name] = ConvertTo-HashtableDeep $prop.Value } }
        return $out
    }
    if ($Obj -is [System.Collections.IEnumerable] -and $Obj -isnot [string]) {
        return ,@($Obj | ForEach-Object { ConvertTo-HashtableDeep $_ })
    }
    return $Obj
}
function Read-Map {
    $p = Get-MapPath
    if (-not [IO.File]::Exists($p)) { return $null }
    try {
        # Permit atomic replacement while a read-only find/status/doctor is
        # reading the old snapshot. The replacement is still all-or-nothing.
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.File]::Open($p, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        try {
            $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true)
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally { $stream.Dispose() }
        $map = ConvertTo-HashtableDeep ($text | ConvertFrom-Json)
    } catch { Throw-MapError 'map_corrupt' "地图无法解析，请备份后修复：$p" }
    if ($map.schemaVersion -notin @(1, 2) -or $map.tools -isnot [hashtable]) { Throw-MapError 'schema_unsupported' '不支持的地图格式；不会覆盖原文件。' }
    if ($map.schemaVersion -eq 1) {
        foreach ($entry in $map.tools.Values) {
            $selected = @($entry.candidates | Where-Object { $_.id -eq $entry.preferred } | Select-Object -First 1)
            if ($selected.Count -and -not $entry.preferredPath) { $entry.preferredPath = $selected[0].path }
            foreach ($candidate in @($entry.candidates)) {
                if ($candidate.note -and -not $candidate.userNote) { $candidate.userNote = $candidate.note }
            }
        }
    }
    return $map
}
function Write-AtomicUtf8 {
    param([string]$Path, [string]$Content)
    $dir = Split-Path ([IO.Path]::GetFullPath($Path)) -Parent
    [void][IO.Directory]::CreateDirectory($dir)
    $temp = Join-Path $dir ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temp, $Content, (New-Object Text.UTF8Encoding $true))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Enter-MapLock {
    # OS mutex 在 read-modify-write 全程持有；崩溃后由系统释放，没有陈旧 lock 文件。
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((Get-ToolkitNormalizedPath (Get-MapPath))))) -replace '-', '' }
    finally { $sha.Dispose() }
    $mutex = New-Object Threading.Mutex($false, ('Local\toolkit-map-' + $digest))
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($LockTimeoutSeconds)) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { Throw-MapError 'map_busy' '地图正在由其他进程更新；稍后重试或增大 -LockTimeoutSeconds。' }
        return $mutex
    } catch { $mutex.Dispose(); throw }
}
function Get-ProbeText {
    # 薄封装：执行、超时、缓存与计数都在 toolkit-common.ps1 的 Invoke-ToolkitProbe。
    # 口径：退出码非 0 视为失败；成功时取 stdout + stderr 的前 MaxLines 行非空行。
    param([string]$Exe, [string[]]$Arguments, [int]$MaxLines = 4)
    $script:LastProbe = @{ ok = $false; reason = 'probe_failed'; exitCode = $null }
    # 护栏先于执行器：商店执行别名只在明确的 winget 动作里调用，探测一律跳过。
    if (-not $Exe -or -not (Test-ToolkitProbeSafe $Exe) -or (Test-IsStoreAlias $Exe)) { $script:LastProbe.reason = 'skipped'; return '' }
    $probe = Invoke-ToolkitProbe -Exe $Exe -Arguments $Arguments
    $script:LastProbe.exitCode = $probe.exitCode
    if ($null -eq $probe.exitCode) {
        if ($probe.reason -ne 'ok') { $script:LastProbe.reason = $probe.reason }
        return ''
    }
    if ($probe.exitCode -ne 0) { return '' }
    if (-not $probe.ok) { $script:LastProbe.reason = $probe.reason; return '' }
    $script:LastProbe.ok = $true
    $script:LastProbe.reason = 'ok'
    return (@(("$($probe.stdout)`n$($probe.stderr)" -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First $MaxLines) -join "`n").Trim()
}
# New-Candidate → Get-ExeVersion 会对这个路径做的第一次探测（同样的过滤条件）；不会探测时返回 $null。
# 只预热第一组参数：后备参数只在第一组失败时才串行补跑，进程数与串行时一致。
function Get-ExeVersionProbeJob {
    param([string]$ExePath)
    try { $ExePath = [IO.Path]::GetFullPath($ExePath) } catch { return $null }
    $item = Get-Item -LiteralPath $ExePath -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item.PSIsContainer -or $item.Length -eq 0 -or (Test-IsShimPath $ExePath) -or (Test-IsStoreAlias $ExePath) -or (Test-IsEnvInternal $ExePath)) { return $null }
    $adapter = $script:ToolCatalog[(Get-ToolkitCanonicalName $item.BaseName)]
    # Assign the nested array directly: emitting it from an if expression
    # unwraps a one-element outer array and splits a multi-argument probe.
    $probes = ,@('--version')
    if ($adapter -and $adapter.probe) { $probes = $adapter.probe }
    return @{ exe = $ExePath; args = @(@($probes)[0]) }
}
function Get-ExeVersion {
    param([string]$ExePath)
    if (-not $ExePath) { return '' }
    $item = Get-Item -LiteralPath $ExePath -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item.PSIsContainer -or $item.Length -eq 0 -or (Test-IsShimPath $ExePath) -or (Test-IsStoreAlias $ExePath) -or (Test-IsEnvInternal $ExePath)) { return '' }
    # 同一文件不重复启动：缓存在 Invoke-ToolkitProbe（路径|长度|修改时间|参数），这里不另设一层。
    $name = Get-ToolkitCanonicalName $item.BaseName
    $adapter = $script:ToolCatalog[$name]
    # Keep each adapter's argument group intact (see Get-ExeVersionProbeJob).
    $probes = ,@('--version')
    if ($adapter -and $adapter.probe) { $probes = $adapter.probe }
    $version = ''
    foreach ($arguments in $probes) {
        $text = Get-ProbeText -Exe $ExePath -Arguments @($arguments)
        if (-not $text) { continue }
        $pattern = if ($adapter -and $adapter.versionPattern) { $adapter.versionPattern } else { '\d+(?:\.\d+)+[A-Za-z0-9._+-]*' }
        foreach ($line in ($text -split "`n")) {
            if ($line -match '(?i)unrecognized|unknown option|invalid|not found|no such|usage|error|cannot be loaded') { continue }
            $match = [regex]::Match($line, $pattern)
            if ($match.Success) { $version = if ($match.Groups.Count -gt 1) { $match.Groups[1].Value } else { $match.Value }; break }
        }
        if ($version) { break }
    }
    return $version
}
function ConvertTo-MapTimestampTicks {
    # PS7 的 ConvertFrom-Json 把 ISO 时间串自动转成 DateTime（5.1 保持字符串），
    # 而 "DateTime -ne 字符串" 会按本地时区解析右侧，非 UTC 时区下永远不相等。
    # 统一成 UTC ticks 再比较：5.1、7 以及两个宿主互相写过的地图结果一致。
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().Ticks }
    try {
        return [DateTime]::Parse("$Value", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime().Ticks
    } catch { return $null }
}
function Test-VersionSatisfies { param([string]$Version, [string]$Wanted) return (Test-ToolkitVersionSatisfies $Version $Wanted) }
function Get-CandidateSource {
    param([string]$P)
    if (Test-ToolkitUnderRoot $P (Get-WarehouseRoot)) { return 'warehouse' }
    $miseRoot = if ($env:MISE_DATA_DIR) { $env:MISE_DATA_DIR } else { Join-Path $env:LOCALAPPDATA 'mise' }
    if ((Test-IsShimPath $P) -or (Test-ToolkitUnderRoot $P $miseRoot) -or $P -match '(?i)[\\/](nvm|fnm|volta|asdf|pyenv|scoop)[\\/]') { return 'manager' }
    if ($P -match '(?i)[\\/]envs[\\/][^\\/]+[\\/]') { return 'conda-env' }
    if ($P -match '(?i)miniconda|anaconda|miniforge') { return 'conda-base' }
    if ($P -match '(?i)[\\/]jbr[\\/]|JetBrains|IntelliJ|PyCharm|IDEA') { return 'ide-host' }
    if ($P -match '(?i)[\\/](Program Files(?: \(x86\))?|WindowsApps|Windows)[\\/]') { return 'system' }
    return 'manual'
}
function Get-CandidateNote {
    param([string]$Source, [string]$P)
    if (Test-IsShimPath $P) { return 'shim：只登记，不执行探测，不作首选' }
    if (Test-IsStoreAlias $P) { return '商店应用执行别名：未执行，是否可用未知' }
    if ($Source -eq 'ide-host') { return 'IDE 自带运行时：默认不作首选；明确需要时使用 -AllowIdeHost' }
    if ($Source -eq 'conda-env') { return 'conda 环境内的解释器：默认不作首选' }
    return ''
}
function Get-PathHits {
    param([string]$Name)
    $seen = @{}
    foreach ($raw in ($env:PATH -split ';')) {
        $dir = $raw.Trim().Trim('"').TrimEnd('\')
        if (-not $dir) { continue }
        foreach ($ext in @('.exe', '.cmd', '.bat', '.ps1', '')) {
            $file = Join-Path $dir ($Name + $ext)
            if ([IO.File]::Exists($file) -and -not $seen.ContainsKey($file.ToLowerInvariant())) { $seen[$file.ToLowerInvariant()] = $true; $file }
        }
    }
}
function Get-WarehouseHits {
    param([string]$Name)
    $folderNames = @($Name)
    if ($script:ToolCatalog[$Name].warehouseNames) { $folderNames = @($script:ToolCatalog[$Name].warehouseNames) }
    foreach ($folder in $folderNames) {
        $dir = Join-Path (Get-WarehouseRoot) $folder
        if (-not [IO.Directory]::Exists($dir)) { continue }
        Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -eq $Name -and $_.Extension -in @('.exe', '.cmd', '.bat', '') } | ForEach-Object { $_.FullName }
    }
}
function Get-ManagerHits {
    param([string]$Name)
    $root = if ($env:MISE_DATA_DIR) { $env:MISE_DATA_DIR } else { Join-Path $env:LOCALAPPDATA 'mise' }
    $folders = @($Name)
    if ($Name -eq 'rg') { $folders += 'ripgrep' }
    foreach ($folder in $folders) {
        $dir = Join-Path (Join-Path $root 'installs') $folder
        if ([IO.Directory]::Exists($dir)) {
            Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.BaseName -eq $Name -and $_.Extension -in @('.exe', '.cmd', '.bat', '') } | ForEach-Object { $_.FullName }
        }
    }
    # Known manager layouts are bounded by tool/version directories. Never
    # execute shims and do not recursively walk their package installations.
    $patterns = New-Object System.Collections.Generic.List[string]
    $voltaRoots = @($env:VOLTA_HOME)
    if ($env:LOCALAPPDATA) { $voltaRoots += Join-Path $env:LOCALAPPDATA 'Volta' }
    if ($env:USERPROFILE) { $voltaRoots += Join-Path $env:USERPROFILE '.volta' }
    $fnmRoots = @($env:FNM_DIR)
    if ($env:APPDATA) { $fnmRoots += Join-Path $env:APPDATA 'fnm' }
    if ($env:LOCALAPPDATA) { $fnmRoots += Join-Path $env:LOCALAPPDATA 'fnm' }
    $scoopRoots = @($env:SCOOP)
    if ($env:USERPROFILE) { $scoopRoots += Join-Path $env:USERPROFILE 'scoop' }
    $asdfRoots = @($env:ASDF_DATA_DIR)
    if ($env:USERPROFILE) { $asdfRoots += Join-Path $env:USERPROFILE '.asdf' }
    $plugin = if ($Name -eq 'node') { 'nodejs' } elseif ($Name -eq 'go') { 'golang' } else { $Name }
    # Avoid issuing dozens of wildcard directory enumerations for every
    # common tool when the corresponding manager is absent.
    $voltaRoots = @($voltaRoots | Where-Object { $_ -and [IO.Directory]::Exists((Join-Path $_ "tools\image\$Name")) } | Select-Object -Unique)
    $fnmRoots = @($fnmRoots | Where-Object { $_ -and [IO.Directory]::Exists((Join-Path $_ 'node-versions')) } | Select-Object -Unique)
    $scoopRoots = @($scoopRoots | Where-Object { $_ -and [IO.Directory]::Exists((Join-Path $_ 'apps')) } | Select-Object -Unique)
    $asdfRoots = @($asdfRoots | Where-Object { $_ -and [IO.Directory]::Exists((Join-Path $_ "installs\$plugin")) } | Select-Object -Unique)
    $scoopNames = @($Name)
    if ($Name -eq 'node') { $scoopNames += @('nodejs', 'nodejs-lts') }
    foreach ($ext in @('.exe', '.cmd', '.bat', '')) {
        foreach ($base in @($voltaRoots | Where-Object { $_ } | Select-Object -Unique)) {
            $patterns.Add((Join-Path $base "tools\image\$Name\*\$Name$ext"))
            $patterns.Add((Join-Path $base "tools\image\$Name\*\bin\$Name$ext"))
        }
        if ($Name -eq 'node') {
            foreach ($base in @($fnmRoots | Where-Object { $_ } | Select-Object -Unique)) {
                $patterns.Add((Join-Path $base "node-versions\*\installation\$Name$ext"))
            }
        }
        foreach ($base in @($scoopRoots | Where-Object { $_ } | Select-Object -Unique)) {
            foreach ($folder in $scoopNames) {
                $patterns.Add((Join-Path $base "apps\$folder\*\$Name$ext"))
                $patterns.Add((Join-Path $base "apps\$folder\*\bin\$Name$ext"))
            }
        }
        foreach ($base in @($asdfRoots | Where-Object { $_ } | Select-Object -Unique)) {
            $patterns.Add((Join-Path $base "installs\$plugin\*\bin\$Name$ext"))
            $patterns.Add((Join-Path $base "installs\$plugin\*\$Name$ext"))
        }
    }
    foreach ($pattern in $patterns) {
        Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-IsShimPath $_.FullName) } | ForEach-Object { $_.FullName }
    }
}
function New-Candidate {
    param([string]$P, [string]$VersionHint = '', [string]$IdPrefix = '', [switch]$NoProbe)
    $P = [IO.Path]::GetFullPath($P)
    $source = Get-CandidateSource $P
    $item = Get-Item -LiteralPath $P -ErrorAction SilentlyContinue
    $shim = Test-IsShimPath $P
    $state = 'unverified'
    $actual = ''
    if ($shim -or (Test-IsStoreAlias $P) -or (Test-IsEnvInternal $P)) { $state = 'skipped' }
    elseif (-not $item -or $item.PSIsContainer -or $item.Length -eq 0) { $state = 'unavailable' }
    elseif (-not $NoProbe) { $actual = Get-ExeVersion $P; if ($actual) { $state = 'verified' } }
    $dir = Get-ToolkitNormalizedPath (Split-Path $P -Parent)
    $pathDirs = @($env:PATH -split ';' | Where-Object { $_.Trim() } | ForEach-Object { Get-ToolkitNormalizedPath $_ })
    return @{
        id = ''; path = $P; version = if ($actual) { $actual } else { $VersionHint }
        source = $source; reachable = [bool]($pathDirs -contains $dir); isShim = [bool]$shim
        verification = $state; usable = if ($state -eq 'verified') { $true } elseif ($state -eq 'unavailable') { $false } else { $null }
        checkedAt = if ($NoProbe) { '' } else { (Get-Date).ToString('o') }; size = if ($item -and -not $item.PSIsContainer) { $item.Length } else { -1 }
        modifiedAt = if ($item) { $item.LastWriteTimeUtc.ToString('o') } else { '' }
        note = Get-CandidateNote $source $P
    }
}
function Set-UniqueCandidateIds {
    param([object[]]$Candidates)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($candidate in $Candidates) {
            $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((Get-ToolkitNormalizedPath $candidate.path)))) -replace '-', ''
            $candidate.id = 'path-' + $hash.ToLowerInvariant()
        }
    } finally { $sha.Dispose() }
}
# 某个工具在本机的候选路径（去重、排除环境内部文件），不探测。
function Get-ToolCandidatePaths {
    param([string]$Name, [hashtable]$RuntimeIndex = @{})
    if ($Name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._+-]*$') { return ,@() }
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($runtime in $RuntimeIndex.Values) { if ((Get-ToolkitCanonicalName $runtime.tool) -eq $Name) { $paths.Add($runtime.path) } }
    $searchNames = @($Name)
    if ($Name -eq 'python') { $searchNames += 'python3' }
    foreach ($searchName in $searchNames) {
        foreach ($file in @(Get-PathHits $searchName) + @(Get-WarehouseHits $searchName) + @(Get-ManagerHits $searchName)) { $paths.Add($file) }
    }
    foreach ($location in @($script:ToolCatalog[$Name].locations)) {
        if (-not $location) { continue }
        $file = [Environment]::ExpandEnvironmentVariables($location)
        if ([IO.File]::Exists($file)) { $paths.Add($file) }
    }
    $seen = @{}
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($file in $paths) {
        $key = Get-ToolkitNormalizedPath $file
        if (-not $seen.ContainsKey($key) -and -not (Test-IsEnvInternal $file)) { $seen[$key] = $true; $out.Add($file) }
    }
    return ,$out.ToArray()
}
function Get-ToolCandidates {
    param([string]$Name, [hashtable]$RuntimeIndex = @{}, [string[]]$Paths = $null, [switch]$NoProbe)
    if ($Name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._+-]*$') { return @() }
    if ($null -eq $Paths) { $Paths = Get-ToolCandidatePaths $Name $RuntimeIndex }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($file in $Paths) { $out.Add((New-Candidate $file -NoProbe:$NoProbe)) }
    $candidates = $out.ToArray()
    Set-UniqueCandidateIds $candidates
    return $candidates
}
function Test-CandidateRequirement {
    param($Candidate, [string]$Wanted, [string]$Name)
    if ($Wanted -match '\|\||[,;]') {
        foreach ($alternative in ($Wanted -split '\|\||[,;]')) {
            if (Test-CandidateRequirement $Candidate $alternative.Trim() $Name) { return $true }
        }
        return $false
    }
    $versionText = "$($Candidate.version)"
    if ($Name -eq 'java' -and $Wanted -notmatch '^1\.' -and $versionText -match '^1\.(\d+)\.(.*)') { $versionText = $Matches[1] + '.' + $Matches[2] }
    if ($Wanted -match '^([A-Za-z][A-Za-z0-9]*)-(\d+(?:\.\d+)*)$') {
        $vendor = $Matches[1]; $Wanted = $Matches[2]
        if ("$($Candidate.path) $($Candidate.version)" -notmatch [regex]::Escape($vendor)) { return $false }
    }
    return (Test-VersionSatisfies $versionText $Wanted)
}
function Select-Preferred {
    param([string]$Name, $Candidates, [hashtable]$DeclaredVersions = @{}, [string]$PreferredPath = '')
    $wanted = if ($DeclaredVersions.ContainsKey($Name)) { "$($DeclaredVersions[$Name])" } else { '' }
    $list = @($Candidates | Where-Object {
        -not $_.isShim -and -not (Test-IsShimPath $_.path) -and -not (Test-IsEnvInternal $_.path) -and $_.source -ne 'conda-env' -and
        ($_.source -ne 'ide-host' -or $AllowIdeHost) -and $_.verification -ne 'unavailable' -and
        ($_.verification -eq 'verified' -or ($AllowUnverified -and $_.verification -eq 'unverified')) -and
        (Test-CandidateRequirement $_ $wanted $Name)
    })
    if ($list.Count -eq 0) { return '' }
    $order = @{warehouse = 0; manager = 1; manual = 2; system = 3; 'ide-host' = 4; 'conda-base' = 5}
    $best = $list | Sort-Object @{Expression = { if ($PreferredPath -and $_.path -eq $PreferredPath) { 0 } else { 1 } }},
        @{Expression = { if ($_.verification -eq 'verified') { 0 } else { 1 } }},
        @{Expression = { if ($_.source -eq 'warehouse') { 0 } else { 1 } }},
        @{Expression = { if ($_.reachable) { 0 } else { 1 } }}, @{Expression = { $order[$_.source] }},
        # 版本排序键支持单段版本（22）、超长数字段与预发布（正式版优先），不再经由 [version] 转换。
        @{Expression = { Get-ToolkitVersionSortKey "$($_.version)" }; Descending = $true},
        @{Expression = { $_.path.ToLowerInvariant() }} | Select-Object -First 1
    return $best.id
}
function Get-DeclaredVersions {
    param($Declarations)
    $out = @{}
    foreach ($declaration in @($Declarations | Where-Object { $_.scope -eq 'project' }) + @($Declarations | Where-Object { $_.scope -ne 'project' })) {
        $tools = $declaration.tools
        $keys = if ($tools -is [System.Collections.IDictionary]) { @($tools.Keys) } else { @($tools.PSObject.Properties.Name) }
        foreach ($key in $keys) {
            $name = Get-ToolkitCanonicalName $key
            if (-not $out.ContainsKey($name)) { $out[$name] = if ($tools -is [System.Collections.IDictionary]) { "$($tools[$key])" } else { "$($tools.$key)" } }
        }
    }
    return $out
}
function Save-Map {
    param($Map)
    Assert-MapWritePath
    $mapPath = Get-MapPath
    $summaryPath = [IO.Path]::ChangeExtension($mapPath, '.md')
    # 保留旧地图，用来识别未被手工修改的生成摘要。
    $previous = Read-Map
    # 摘要的默认候选不能受某次查询的放宽策略影响。
    $AllowUnverified = $false
    $AllowIdeHost = $false
    $Map.schemaVersion = 2
    $Map.updatedAt = (Get-Date).ToString('o')
    foreach ($name in @($Map.tools.Keys)) {
        $entry = $Map.tools[$name]
        Set-UniqueCandidateIds @($entry.candidates)
        $entry.preferred = Select-Preferred -Name $name -Candidates @($entry.candidates) -PreferredPath "$($entry.preferredPath)"
    }
    Write-AtomicUtf8 -Path $mapPath -Content ($Map | ConvertTo-Json -Depth 20)
    if (-not (Write-MapSummarySafe $summaryPath $Map $previous)) {
        $script:MapSummaryWarning = "Markdown 摘要未能安全更新；检测到手工修改或占用时不会覆盖，请检查：$summaryPath"
        Write-MapWarning $script:MapSummaryWarning
    }
}
function Write-MapSummarySafe {
    # 只在摘要不存在或仍是上一次生成的内容时覆盖；用户改过的 .md 保留并告警。
    param([string]$Path, $Map, $Previous)
    try {
        if ([IO.File]::Exists($Path)) {
            if (-not $Previous) { return $false }
            $existing = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
            if (-not [string]::Equals($existing, (Get-MapMarkdownContent $Previous), [StringComparison]::Ordinal)) { return $false }
        }
        Write-AtomicUtf8 -Path $Path -Content (Get-MapMarkdownContent $Map)
        return $true
    } catch { return $false }
}
function Format-MapSummaryTimestamp {
    param($Value)
    if ($Value -is [datetime] -or $Value -is [datetimeoffset]) { return $Value.ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
    return "$Value"
}
function Get-MapMarkdownContent {
    param($Map)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# 本机工具地图'); $lines.Add('')
    $lines.Add("完整扫描：$(Format-MapSummaryTimestamp $Map.scannedAt)　最近更新：$(Format-MapSummaryTimestamp $Map.updatedAt)"); $lines.Add('')
    $lines.Add('| 工具 | 默认候选 | 版本 | 验证 | 候选数 |'); $lines.Add('|---|---|---|---|---|')
    foreach ($name in ($Map.tools.Keys | Sort-Object)) {
        $entry = $Map.tools[$name]
        $chosen = @($entry.candidates | Where-Object { $_.id -eq $entry.preferred } | Select-Object -First 1)
        if ($chosen.Count) { $lines.Add("| $name | ``$($chosen[0].path -replace '\|', '\|')`` | $($chosen[0].version) | $($chosen[0].verification) | $(@($entry.candidates).Count) |") }
        else { $lines.Add("| $name | （无已验证的默认候选） | | | $(@($entry.candidates).Count) |") }
    }
    $lines.Add(''); $lines.Add('> 这是机器清单；项目内的最终选择由 find 按当前项目声明计算。')
    return ($lines -join "`n")
}
# Preserve explicit registrations and preferences even when their storage is
# temporarily offline; never treat absence as permission to erase user data.
function Refresh-RecordedCandidate {
    param($Candidate, [string]$PreferredPath = '')
    if (-not $Candidate.path) { return $null }
    if ([IO.File]::Exists($Candidate.path)) {
        $fresh = New-Candidate $Candidate.path $Candidate.version
        if ($Candidate.registered) { $fresh.registered = $true }
        if ($Candidate.userNote) { $fresh.userNote = $Candidate.userNote; $fresh.note = $Candidate.userNote }
        return $fresh
    }
    if (-not $Candidate.registered -and -not $Candidate.userNote -and (-not $PreferredPath -or $Candidate.path -ne $PreferredPath)) { return $null }
    $fresh = $Candidate.Clone()
    $fresh.verification = 'unavailable'; $fresh.usable = $false; $fresh.reachable = $false
    $fresh.checkedAt = (Get-Date).ToString('o')
    if ($null -eq $fresh.source) { $fresh.source = 'manual' }
    if ($null -eq $fresh.version) { $fresh.version = '' }
    if ($null -eq $fresh.note) { $fresh.note = '' }
    if ($null -eq $fresh.isShim) { $fresh.isShim = Test-IsShimPath $fresh.path }
    if ($null -eq $fresh.size) { $fresh.size = -1 }
    if ($null -eq $fresh.modifiedAt) { $fresh.modifiedAt = '' }
    return $fresh
}
function Merge-Candidates {
    param($Fresh, $Existing, [switch]$PreserveMissing)
    $out = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($candidate in @($Fresh) + @($Existing)) {
        if (-not $candidate.path -or (-not $PreserveMissing -and -not [IO.File]::Exists($candidate.path))) { continue }
        $key = Get-ToolkitNormalizedPath $candidate.path
        if (-not $seen.ContainsKey($key)) {
            $old = @($Existing | Where-Object { $_.path -eq $candidate.path } | Select-Object -First 1)
            if ($old.Count -gt 0) {
                if ($old[0].registered) { $candidate.registered = $true }
                if ($old[0].userNote) { $candidate.userNote = $old[0].userNote; $candidate.note = $old[0].userNote }
            }
            $out.Add($candidate); $seen[$key] = $true
        }
    }
    $result = $out.ToArray(); Set-UniqueCandidateIds $result; return $result
}
# 首扫探测的并行度：-Throttle 显式给出时用它（1 = 原来的串行），否则 min(8, CPU 数)。
function Get-ScanThrottle {
    if ($Throttle -ge 1) { return $Throttle }
    return [Math]::Max(1, [Math]::Min(8, [Environment]::ProcessorCount))
}
# Old maps can contain separate keys such as python3/ripgrep. Merge them for
# selection and refresh without discarding their persisted preference or notes.
function Get-CanonicalMapEntry {
    param($Map, [string]$Name, [string]$RequestedName = '')
    if (-not $Map -or -not $Map.tools) { return $null }
    $keys = @($Map.tools.Keys | Where-Object { (Get-ToolkitCanonicalName $_) -eq $Name } | Sort-Object)
    if (-not $keys.Count) { return $null }
    $ordered = New-Object System.Collections.Generic.List[string]
    if ($Map.tools.ContainsKey($Name)) { $ordered.Add($Name) }
    foreach ($key in $keys) { if ($key -ne $Name) { $ordered.Add($key) } }
    $preference = ''
    # Once a canonical entry has a preference it governs every alias. Keep
    # legacy alias preferences on disk; use one only if canonical has none.
    if ($Map.tools.ContainsKey($Name)) { $preference = "$($Map.tools[$Name].preferredPath)" }
    if (-not $preference -and $RequestedName -and $Map.tools.ContainsKey($RequestedName)) { $preference = "$($Map.tools[$RequestedName].preferredPath)" }
    if (-not $preference) {
        foreach ($key in $ordered) { if ($Map.tools[$key].preferredPath) { $preference = "$($Map.tools[$key].preferredPath)"; break } }
    }
    $seen = @{}; $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($key in $ordered) {
        foreach ($candidate in @($Map.tools[$key].candidates)) {
            if (-not $candidate.path) { continue }
            $pathKey = Get-ToolkitNormalizedPath $candidate.path
            if ($seen.ContainsKey($pathKey)) {
                $known = $seen[$pathKey]
                if ($candidate.registered) { $known.registered = $true }
                if (-not $known.userNote -and $candidate.userNote) { $known.userNote = $candidate.userNote; $known.note = $candidate.userNote }
            } else {
                $copy = $candidate.Clone(); $seen[$pathKey] = $copy; $candidates.Add($copy)
            }
        }
    }
    return @{ candidates = $candidates.ToArray(); preferredPath = $preference }
}
function Invoke-Scan {
    Write-MapMessage '扫描本机（只读探测，不执行 shim）…'
    # 计量（probeStats）：只量不改行为，给"首扫并行化"留一份前后对比的基线。
    $scanSw = [Diagnostics.Stopwatch]::StartNew()
    $launchesBefore = [int]$script:ToolkitProbeStats.launches
    $msBefore = [int64]$script:ToolkitProbeStats.ms
    $old = Read-Map
    # 当前宿主路径同时支持 Windows PowerShell 5.1 与 PowerShell 7。
    $hostExe = (Get-Process -Id $PID).Path
    $censusSw = [Diagnostics.Stopwatch]::StartNew()
    $output = & $hostExe -NoProfile -ExecutionPolicy Bypass -File $CensusScript -Json
    $censusWallMs = [int64]$censusSw.Elapsed.TotalMilliseconds
    if ($LASTEXITCODE -ne 0) { Throw-MapError 'scan_failed' "census 退出码：$LASTEXITCODE" }
    try { $census = ($output | Out-String) | ConvertFrom-Json } catch { Throw-MapError 'scan_failed' 'census 未返回有效 JSON。' }
    # A syntactically valid but partial report must not become a fresh map.
    # probeStats is optional for older census versions; the inventory arrays
    # and each runtime's identity are required for a complete scan.
    if ($null -eq $census -or $census -is [array] -or $census -isnot [pscustomobject] -or $census.schemaVersion -ne 1 -or
        $census.runtimes -isnot [array] -or $census.declarations -isnot [array] -or $census.warnings -isnot [array]) {
        Throw-MapError 'scan_failed' 'census 报告缺少完整扫描所需字段；未写入地图。'
    }
    foreach ($runtime in $census.runtimes) {
        if ($runtime -isnot [pscustomobject] -or $runtime.tool -isnot [string] -or -not $runtime.tool -or
            $runtime.path -isnot [string] -or -not $runtime.path) {
            Throw-MapError 'scan_failed' 'census 运行时记录缺少工具名或路径；未写入地图。'
        }
    }
    foreach ($declaration in $census.declarations) {
        if ($null -eq $declaration -or $declaration -is [array] -or $declaration -isnot [pscustomobject] -or
            $null -eq $declaration.tools -or $declaration.tools -is [array] -or $declaration.tools -isnot [pscustomobject]) {
            Throw-MapError 'scan_failed' 'census 声明记录不完整；未写入地图。'
        }
    }
    $index = @{}
    foreach ($runtime in @($census.runtimes)) { $index[$runtime.path] = $runtime }
    $names = New-Object System.Collections.Generic.HashSet[string]
    foreach ($runtime in @($census.runtimes)) { [void]$names.Add((Get-ToolkitCanonicalName $runtime.tool)) }
    foreach ($name in $CommonToolNames) { [void]$names.Add((Get-ToolkitCanonicalName $name)) }
    foreach ($name in (Get-DeclaredVersions $census.declarations).Keys) { [void]$names.Add($name) }
    foreach ($dir in (Get-ChildItem -LiteralPath (Get-WarehouseRoot) -Directory -ErrorAction SilentlyContinue)) { [void]$names.Add((Get-ToolkitCanonicalName $dir.Name)) }
    $miseRoot = if ($env:MISE_DATA_DIR) { $env:MISE_DATA_DIR } else { Join-Path $env:LOCALAPPDATA 'mise' }
    foreach ($dir in (Get-ChildItem -LiteralPath (Join-Path $miseRoot 'installs') -Directory -ErrorAction SilentlyContinue)) { [void]$names.Add((Get-ToolkitCanonicalName $dir.Name)) }
    if ($old) { foreach ($name in $old.tools.Keys) { [void]$names.Add((Get-ToolkitCanonicalName $name)) } }
    $map = @{ schemaVersion = 2; scannedAt = (Get-Date).ToString('o'); warehouse = Get-WarehouseRoot; pathSnapshot = $env:PATH; tools = @{};
        censusSummary = @{ warnings = @($census.warnings); counts = @{ runtimes = @($census.runtimes).Count; declarations = @($census.declarations).Count } } }
    # 两阶段（收敛计划 P3）：先收集所有候选路径，把它们的版本探测一起并行跑完、写进探测缓存；
    # 下面再按原来的顺序逐个建候选，探测全部命中缓存。所以输出与串行完全一致（-Throttle 1 就是原来的串行）。
    $sortedNames = @($names | Sort-Object)
    $pathsByName = @{}
    $jobs = New-Object System.Collections.Generic.List[object]
    foreach ($name in $sortedNames) {
        $pathsByName[$name] = Get-ToolCandidatePaths $name $index
        $previous = Get-CanonicalMapEntry $old $name $name
        $known = @($pathsByName[$name]) + @(if ($previous) { @($previous.candidates | Where-Object { $_.path -and [IO.File]::Exists($_.path) } | ForEach-Object { $_.path }) })
        foreach ($path in $known) { $job = Get-ExeVersionProbeJob $path; if ($job) { $jobs.Add($job) } }
    }
    $throttleUsed = Get-ScanThrottle
    $null = Invoke-ToolkitProbeBatch -Jobs $jobs.ToArray() -Throttle $throttleUsed
    foreach ($name in $sortedNames) {
        $previous = Get-CanonicalMapEntry $old $name $name
        $existing = if ($previous) { @($previous.candidates | ForEach-Object {
            Refresh-RecordedCandidate $_ "$($previous.preferredPath)"
        } | Where-Object { $null -ne $_ }) } else { @() }
        $candidates = @(Merge-Candidates (Get-ToolCandidates $name $index $pathsByName[$name]) $existing -PreserveMissing)
        if (-not $candidates.Count) { continue }
        $map.tools[$name] = @{ candidates = $candidates; preferred = ''; preferredPath = if ($previous) { "$($previous.preferredPath)" } else { '' } }
    }
    # Preserve historical alias keys as well as the merged canonical entry:
    # separate keys can carry different explicit preferences or user notes.
    if ($old) {
        foreach ($legacyName in @($old.tools.Keys)) {
            if ((Get-ToolkitCanonicalName $legacyName) -eq $legacyName -or $map.tools.ContainsKey($legacyName)) { continue }
            $legacy = $old.tools[$legacyName]
            $legacyCandidates = @($legacy.candidates | ForEach-Object {
                Refresh-RecordedCandidate $_ "$($legacy.preferredPath)"
            } | Where-Object { $null -ne $_ })
            $map.tools[$legacyName] = @{ candidates = $legacyCandidates; preferred = ''; preferredPath = "$($legacy.preferredPath)" }
        }
    }
    Save-Map $map
    # census 的 probeStats 是附加字段：旧版或替身 census 没有它时按 0 计。
    $censusLaunches = 0; $censusProbeMs = [int64]0
    if ($census.PSObject.Properties['probeStats'] -and $census.probeStats) {
        if ($null -ne $census.probeStats.launches) { $censusLaunches = [int]$census.probeStats.launches }
        if ($null -ne $census.probeStats.ms) { $censusProbeMs = [int64]$census.probeStats.ms }
    }
    $mapLaunches = [int]$script:ToolkitProbeStats.launches - $launchesBefore
    $mapProbeMs = [int64]$script:ToolkitProbeStats.ms - $msBefore
    # launches = census 子进程本身 1 个 + census 内的版本探测 + 本进程的版本探测（命中探测缓存的不算）。
    $probeStats = @{
        launches = 1 + $censusLaunches + $mapLaunches
        probeMs  = $censusProbeMs + $mapProbeMs
        wallMs   = [int64]$scanSw.Elapsed.TotalMilliseconds
        census   = @{ launches = $censusLaunches; probeMs = $censusProbeMs; wallMs = $censusWallMs }
        map      = @{ launches = $mapLaunches; probeMs = $mapProbeMs; throttle = $throttleUsed }
    }
    $toolCount = @($map.tools.Keys | ForEach-Object { Get-ToolkitCanonicalName $_ } | Sort-Object -Unique).Count
    return (New-MapResult 'ok' @{ mapFile = Get-MapPath; tools = $toolCount; scannedAt = $map.scannedAt; warnings = $map.censusSummary.warnings; probeStats = $probeStats })
}
function Invoke-Status {
    $map = Read-Map
    if (-not $map) { return (New-MapResult 'map_missing' @{ exists = $false; mapFile = Get-MapPath; hint = '先执行 setup 或 scan。' } $false) }
    $age = if ($map.scannedAt) { ((Get-Date) - [datetime]$map.scannedAt).TotalHours } else { $null }
    # 旧地图可能同时保留 canonical 与历史别名键以保存不同偏好/备注。
    # 状态按工具和文件去重，避免同一离线路径重复抬高告警数量。
    $deadPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in @($map.tools.Values | ForEach-Object { $_.candidates })) {
        if (-not [IO.File]::Exists($candidate.path)) {
            $key = try { Get-ToolkitNormalizedPath "$($candidate.path)" } catch { "$($candidate.path)" }
            [void]$deadPaths.Add($key)
        }
    }
    $dead = $deadPaths.Count
    $toolCount = @($map.tools.Keys | ForEach-Object { Get-ToolkitCanonicalName $_ } | Sort-Object -Unique).Count
    $changed = ($map.pathSnapshot -ne $env:PATH)
    $stale = ($null -eq $age -or $age -gt $MaxAgeHours)
    $hints = New-Object System.Collections.Generic.List[string]
    if ($stale) { $hints.Add('完整扫描已过期；经用户确认后可执行 scan。') }
    if ($dead) { $hints.Add('存在暂时不可访问的登记；确认路径或设备恢复后可执行 update。') }
    if ($changed) { $hints.Add('当前进程 PATH 与最近扫描时不同，可能是会话激活造成；find 按当前进程 PATH 判断。') }
    if (-not $hints.Count) { $hints.Add('地图可用。') }
    return (New-MapResult 'ok' @{ exists = $true; mapFile = Get-MapPath; scannedAt = $map.scannedAt; updatedAt = $map.updatedAt;
        ageHours = if ($null -ne $age) { [math]::Round($age, 1) } else { $null }; stale = $stale; tools = $toolCount;
        deadCandidates = $dead; pathChanged = $changed; hint = ($hints -join ' ') })
}
function Get-Requirement {
    param([string]$Name)
    if ($Project) {
        try { $projectPath = [IO.Path]::GetFullPath($Project) } catch { Throw-MapError 'invalid_project' '项目目录路径无效。' }
        if (-not [IO.Directory]::Exists($projectPath)) { Throw-MapError 'invalid_project' "项目目录不存在：$projectPath" }
    }
    if ($Version) { return @{ version = $Version; source = 'argument'; scope = 'argument' } }
    foreach ($declaration in @(Get-ToolkitDeclarations $Project)) {
        $key = if ($Name -eq 'py') { 'python' } else { Get-ToolkitCanonicalName $Name }
        if ($declaration.unsupported -contains $key -or $declaration.unsupported -contains '*') { Throw-MapError 'requirement_unsupported' "声明语法尚不支持：$($declaration.path) 的 $key；请用 -Version 明确指定。" }
        if ($declaration.tools.ContainsKey($key)) { return @{ version = "$($declaration.tools[$key])"; source = $declaration.path; scope = $declaration.scope } }
    }
    return @{ version = ''; source = ''; scope = '' }
}
# When no requirement or usable explicit preference exists, the actual PATH
# winner is the only candidate that can truthfully be called machine_default.
function Select-FindCandidate {
    param([string]$Name, $Candidates, [hashtable]$Declared, [string]$PreferredPath, [string]$PathDefault)
    $selected = Select-Preferred $Name $Candidates $Declared $PreferredPath
    if ($Declared.ContainsKey($Name) -or -not $PathDefault) { return $selected }
    $chosen = @($Candidates | Where-Object { $_.id -eq $selected } | Select-Object -First 1)
    if ($chosen.Count -and $PreferredPath -and (Get-ToolkitNormalizedPath $chosen[0].path) -eq (Get-ToolkitNormalizedPath $PreferredPath)) { return $selected }
    $defaultKey = Get-ToolkitNormalizedPath $PathDefault
    $defaults = @($Candidates | Where-Object { (Get-ToolkitNormalizedPath $_.path) -eq $defaultKey })
    if ($defaults.Count) {
        $defaultSelection = Select-Preferred $Name $defaults $Declared ''
        if ($defaultSelection) { return $defaultSelection }
    }
    # PATH may point at an excluded environment, shim, or unverified file.
    # An independently verified candidate remains useful, but must not be
    # described as the PATH default (Invoke-Find assigns available_candidate).
    return $selected
}
function Invoke-Find {
    if (-not $Tool) { Throw-MapError 'invalid_argument' 'find 需要工具名。' }
    $name = Get-ToolkitCanonicalName $Tool
    if ($name -notmatch '^[a-z0-9][a-z0-9._+-]*$') { Throw-MapError 'invalid_argument' '工具名不能是路径或包含分隔符。' }
    if ($AllowUnverified) { Throw-MapError 'invalid_argument' 'find 只返回已验证候选，不再支持 -AllowUnverified；请先明确授权 update、scan 或 add。' }
    $map = Read-Map
    if (-not $map) { Throw-MapError 'map_missing' '还没有地图，请明确授权后执行 scan。' }
    $entry = Get-CanonicalMapEntry $map $name ($Tool.ToLowerInvariant())
    $existing = if ($entry) { @($entry.candidates) } else { @() }
    $currentPathDirs = @($env:PATH -split ';' | Where-Object { $_.Trim() } | ForEach-Object { Get-ToolkitNormalizedPath $_ })
    $live = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in $existing) {
        if (-not $candidate.path) { continue }
        $view = $candidate.Clone()
        if (-not [IO.File]::Exists($candidate.path)) {
            $view.verification = 'unavailable'; $view.usable = $false; $view.reachable = $false
        } else {
            $item = Get-Item -LiteralPath $candidate.path -ErrorAction SilentlyContinue
            $recorded = ConvertTo-MapTimestampTicks $candidate.modifiedAt
            if (-not $item -or $item.PSIsContainer -or $item.Length -eq 0) {
                $view.verification = 'unavailable'; $view.usable = $false
            } elseif ((Test-IsShimPath $candidate.path) -or (Test-IsStoreAlias $candidate.path) -or (Test-IsEnvInternal $candidate.path) -or -not (Test-ToolkitProbeSafe $candidate.path)) {
                $view.verification = 'skipped'; $view.usable = $null
            } elseif (-not $candidate.verification -or $candidate.size -ne $item.Length -or $null -eq $recorded -or $recorded -ne $item.LastWriteTimeUtc.Ticks) {
                $view.verification = 'unverified'; $view.usable = $null
            }
            $view.reachable = [bool]($currentPathDirs -contains (Get-ToolkitNormalizedPath (Split-Path $candidate.path -Parent)))
        }
        $live.Add($view)
    }
    $requirement = Get-Requirement $name
    if (-not (Test-ToolkitRequirementSupported $requirement.version)) {
        Throw-MapError 'requirement_unsupported' "无法判定版本要求：$($requirement.version)（$($requirement.source)）；请用支持的 -Version 或通过管理器执行。"
    }
    $declared = @{}; if ($requirement.version) { $declared[$name] = $requirement.version }
    $preferredPath = if ($entry) { "$($entry.preferredPath)" } else { '' }
    $pathDefault = Find-ToolkitPathCommand $Tool
    $candidates = $live.ToArray()
    Set-UniqueCandidateIds $candidates
    $selected = Select-FindCandidate $name $candidates $declared $preferredPath $pathDefault
    $searched = $false
    if (-not $selected -and -not $SkipScan) {
        # Discovery only reads file metadata. New candidates are not verified
        # until the user explicitly invokes scan, update or add.
        $found = @(Get-ToolCandidates -Name $name -NoProbe)
        if ($pathDefault -and -not @($found | Where-Object { $_.path -eq $pathDefault }).Count) { $found += New-Candidate $pathDefault -NoProbe }
        $seen = @{}; $combined = New-Object System.Collections.Generic.List[object]
        foreach ($candidate in @($candidates) + @($found)) {
            $key = Get-ToolkitNormalizedPath $candidate.path
            if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $combined.Add($candidate) }
        }
        $candidates = $combined.ToArray()
        Set-UniqueCandidateIds $candidates
        $searched = $true
        $selected = Select-FindCandidate $name $candidates $declared $preferredPath $pathDefault
    }
    $chosen = @($candidates | Where-Object { $_.id -eq $selected } | Select-Object -First 1)
    $fields = @{ tool = $name; requestedTool = $Tool; found = [bool]$chosen.Count; path = ''; version = ''; source = ''; note = '';
        requirement = $requirement; candidates = $candidates; search = @{ performed = $searched; complete = $false; scope = @('map', 'PATH', 'warehouse', 'mise-installs', 'adapter-locations') };
        reason = ''; verification = ''; invocation = $null }
    if ($chosen.Count) {
        $c = $chosen[0]
        foreach ($key in @('path', 'version', 'source', 'note', 'verification')) { $fields[$key] = $c[$key] }
        $fields.reason = if ($preferredPath -and $preferredPath -eq $c.path) { 'user_preference' } elseif ($requirement.version) { 'requirement_match' } elseif ($pathDefault -and (Get-ToolkitNormalizedPath $pathDefault) -eq (Get-ToolkitNormalizedPath $c.path)) { 'machine_default' } else { 'available_candidate' }
        $fields.invocation = @{ executable = $c.path; arguments = @(); cwd = if ($Project) { [IO.Path]::GetFullPath($Project) } else { (Get-Location).Path } }
        if ($requirement.scope -eq 'project') { $fields.environmentHint = '需要项目环境变量或配套工具时，通过已登记的 mise 执行 mise exec -- <命令>。' }
        return (New-MapResult 'ok' $fields)
    }
    $verified = @($candidates | Where-Object { $_.verification -eq 'verified' -and -not $_.isShim })
    $status = if ($requirement.version -and $verified.Count) { 'version_mismatch' } elseif ($candidates.Count -or $pathDefault) { 'no_usable_candidate' } else { 'not_found' }
    $fields.hint = if ($status -eq 'version_mismatch') { '没有满足要求的已验证候选；不会降级。确认后可使用 update、scan 或 add 验证已有副本。' } else { '没有符合条件的已验证候选；find 不执行候选或修改地图。确认后可使用 update、scan 或 add 验证已有副本。' }
    return (New-MapResult $status $fields $false)
}
function Invoke-Add {
    if (-not $Tool -or -not $Path) { Throw-MapError 'invalid_argument' 'add 需要工具名和 -Path。' }
    $absolute = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($absolute)) { Throw-MapError 'invalid_path' "文件不存在：$absolute" }
    if (Test-IsEnvInternal $absolute) { Throw-MapError 'environment_internal' '依赖特定环境的路径不进地图。' }
    $name = Get-ToolkitCanonicalName $Tool
    if ($name -notmatch '^[a-z0-9][a-z0-9._+-]*$') { Throw-MapError 'invalid_argument' '工具名不能是路径或包含分隔符。' }
    $map = Read-Map
    if (-not $map) { $map = @{ schemaVersion = 2; warehouse = Get-WarehouseRoot; tools = @{}; scannedAt = $null; pathSnapshot = $env:PATH } }
    $entry = $map.tools[$name]
    if (-not $entry) { $entry = @{ candidates = @(); preferred = ''; preferredPath = '' }; $map.tools[$name] = $entry }
    $previous = @($entry.candidates | Where-Object { $_.path -eq $absolute } | Select-Object -First 1)
    $c = New-Candidate $absolute $Version
    $c.registered = $true
    if ($Note) { $c.userNote = $Note; $c.note = $Note }
    elseif ($previous.Count -and $previous[0].userNote) { $c.userNote = $previous[0].userNote; $c.note = $previous[0].userNote }
    $entry.candidates = @($entry.candidates | Where-Object { $_.path -ne $absolute }) + @($c)
    if ($Prefer) { $entry.preferredPath = $absolute }
    Save-Map $map
    return (New-MapResult 'ok' @{ tool = $name; path = $absolute; verification = $c.verification; preferredPath = $entry.preferredPath; mapFile = Get-MapPath })
}
function Invoke-Update {
    if ($Tool) {
        $requested = Get-ToolkitCanonicalName $Tool
        if ($requested -notmatch '^[a-z0-9][a-z0-9._+-]*$') { Throw-MapError 'invalid_argument' '工具名不能是路径或包含分隔符。' }
    }
    $map = Read-Map
    if (-not $map) { Throw-MapError 'map_missing' '先执行 setup 或 scan。' }
    $targets = if ($Tool) { @(Get-ToolkitCanonicalName $Tool) } else { @($map.tools.Keys | ForEach-Object { Get-ToolkitCanonicalName $_ } | Sort-Object -Unique) }
    foreach ($name in $targets) {
        $entry = Get-CanonicalMapEntry $map $name $name
        $existing = if ($entry) { @($entry.candidates | ForEach-Object {
            Refresh-RecordedCandidate $_ "$($entry.preferredPath)"
        } | Where-Object { $null -ne $_ }) } else { @() }
        $candidates = @(Merge-Candidates (Get-ToolCandidates $name) $existing -PreserveMissing)
        $map.tools[$name] = @{ candidates = $candidates; preferred = ''; preferredPath = if ($entry) { "$($entry.preferredPath)" } else { '' } }
    }
    Save-Map $map
    return (New-MapResult 'ok' @{ tools = $targets; updatedAt = $map.updatedAt; scannedAt = $map.scannedAt; mapFile = Get-MapPath })
}
function Get-RulesPath {
    if ($RulesFile) { return [IO.Path]::GetFullPath($RulesFile) }
    $dir = if ($Project) { [IO.Path]::GetFullPath($Project) } else { (Get-Location).Path }
    if (-not [IO.Directory]::Exists($dir)) { Throw-MapError 'invalid_project' "项目目录不存在：$dir" }
    return (Join-Path $dir 'AGENTS.md')
}
function Get-RulesBlock {
    # The user-facing template is the single source of truth for setup rules.
    $templatePath = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'templates') 'agent-tool-rules.md'
    if (-not [IO.File]::Exists($templatePath)) { Throw-MapError 'operation_failed' "找不到接入规则模板：$templatePath" }
    $template = [IO.File]::ReadAllText($templatePath, [Text.Encoding]::UTF8)
    $match = [regex]::Match($template, '(?s)<!-- toolkit-map:begin -->.*?<!-- toolkit-map:end -->')
    if (-not $match.Success) { Throw-MapError 'rules_invalid' '接入规则模板缺少完整标记。' }
    $placeholder = 'C:/Users/YOUR_USER/Projects/toolkit-map/scripts/map.ps1'
    $mapPlaceholder = 'C:/Users/YOUR_USER/.toolkit/map.json'
    $command = $script:MapScriptPath.Replace("'", "''")
    $mapPath = Get-MapPath
    $quotedMapPath = $mapPath.Replace("'", "''")
    return $match.Value.Replace("'$placeholder'", "'$command'").Replace($placeholder, $script:MapScriptPath).Replace("'$mapPlaceholder'", "'$quotedMapPath'").Replace($mapPlaceholder, $mapPath)
}
function Invoke-Setup {
    $rulesPath = Get-RulesPath
    $block = Get-RulesBlock
    $previous = if ([IO.File]::Exists($rulesPath)) { [IO.File]::ReadAllText($rulesPath) } else { '' }
    $pattern = '(?s)<!-- toolkit-map:begin -->.*?<!-- toolkit-map:end -->'
    if (($previous.Contains('<!-- toolkit-map:begin -->') -or $previous.Contains('<!-- toolkit-map:end -->')) -and $previous -notmatch $pattern) {
        Throw-MapError 'rules_invalid' '接入规则标记不完整；请先修复，setup 不会覆盖。'
    }
    $next = if ($previous -match $pattern) { [regex]::Replace($previous, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($m) $block.Trim() }) }
            elseif ($previous) { $previous.TrimEnd() + "`n`n" + $block.Trim() + "`n" } else { $block.Trim() + "`n" }
    $fields = @{ rulesFile = $rulesPath; mapFile = Get-MapPath; rulesChanged = ($previous -ne $next); preview = $block; agentVerified = $false }
    if ($WhatIf) { return (New-MapResult 'planned' $fields) }
    if (-not (Read-Map)) { $null = Invoke-Scan }
    if ($previous -ne $next) {
        if ($previous) {
            $backup = $rulesPath + '.toolkit-map-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.bak'
            Write-AtomicUtf8 $backup $previous; $fields.backup = $backup
        }
        Write-AtomicUtf8 $rulesPath $next
    }
    $fields.hint = '配置已写入。新开 agent 会话，验证它实际先查询地图；文件存在不代表模型已遵守。'
    return (New-MapResult 'ok' $fields)
}
function Invoke-Doctor {
    $map = Read-Map
    $checks = New-Object System.Collections.Generic.List[object]
    $checks.Add(@{ name = 'host'; ok = ($PSVersionTable.PSVersion -ge [version]'5.1'); detail = $PSVersionTable.PSVersion.ToString() })
    $checks.Add(@{ name = 'map'; ok = [bool]$map; detail = Get-MapPath })
    $rulesPath = Get-RulesPath
    $rules = if ([IO.File]::Exists($rulesPath)) { [IO.File]::ReadAllText($rulesPath) } else { '' }
    $checks.Add(@{ name = 'integration'; ok = ($rules -match '(?s)<!-- toolkit-map:begin -->.*?<!-- toolkit-map:end -->' -and $rules.Contains($script:MapScriptPath)); detail = $rulesPath })
    $state = $null
    if ($map) {
        $state = Invoke-Status
        $checks.Add(@{ name = 'freshness'; ok = (-not $state.stale -and $state.deadCandidates -eq 0); detail = $state.hint })
        $checks.Add(@{ name = 'path_context'; ok = $true; detail = if ($state.pathChanged) { '当前进程 PATH 与扫描时不同；可能只是不同会话的激活状态。' } else { '当前进程 PATH 与扫描时一致。' } })
        $blockedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($candidate in @($map.tools.Values | ForEach-Object { $_.candidates } | Where-Object { $_.verification -ne 'verified' })) {
            $key = try { Get-ToolkitNormalizedPath "$($candidate.path)" } catch { "$($candidate.path)" }
            [void]$blockedPaths.Add($key)
        }
        $blocked = $blockedPaths.Count
    } else { $blocked = 0 }
    $ok = @($checks | Where-Object { -not $_.ok }).Count -eq 0
    $fields = @{ checks = $checks.ToArray(); unverifiedCandidates = $blocked; agentVerified = $false; hint = 'doctor 只检查本机配置；用一次真实的工具查询验证 agent 行为。' }
    if ($Bundle) {
        $warnings = @()
        if ($map -and $map.censusSummary) { $warnings = @($map.censusSummary.warnings) }
        $fields.bundle = @{
            formatVersion = 1
            generatedAt = (Get-Date).ToString('o')
            version = Get-ToolkitVersion
            checks = $checks.ToArray()
            host = @{
                psVersion = $PSVersionTable.PSVersion.ToString()
                psEdition = "$($PSVersionTable.PSEdition)"
                os = [Environment]::OSVersion.VersionString
                is64BitProcess = [Environment]::Is64BitProcess
            }
            rulesFile = $rulesPath
            map = @{
                exists = [bool]$map
                file = Get-MapPath
                tools = if ($state) { $state.tools } else { 0 }
                scannedAt = if ($map) { $map.scannedAt } else { $null }
                updatedAt = if ($map) { $map.updatedAt } else { $null }
                ageHours = if ($state) { $state.ageHours } else { $null }
                stale = if ($state) { $state.stale } else { $null }
                pathChanged = if ($state) { $state.pathChanged } else { $null }
                deadCandidates = if ($state) { $state.deadCandidates } else { $null }
                warnings = $warnings
            }
            unverifiedCandidates = $blocked
            agentVerified = $false
        }
    }
    return (New-MapResult $(if ($ok) { 'ok' } else { 'attention_required' }) $fields $ok)
}
