# 地图存储、探测、项目选择与接入。map.ps1 是命令入口。
function Get-MapPath {
    $value = if ($MapFile) { $MapFile } elseif ($env:TOOLKIT_MAP) { $env:TOOLKIT_MAP } else { Join-Path $env:USERPROFILE '.toolkit\map.json' }
    return [IO.Path]::GetFullPath($value)
}
function Get-WarehouseRoot {
    $value = if ($env:TOOLCHAIN_ROOT) { $env:TOOLCHAIN_ROOT } else { Join-Path $env:USERPROFILE 'toolchains' }
    return [IO.Path]::GetFullPath($value)
}
function Test-IsShimPath { param([string]$P) return (Test-ToolkitShimPath $P) }
function Test-IsStoreAlias { param([string]$P) return ($P -match '(?i)[\\/]WindowsApps[\\/]') }
function Test-IsEnvInternal {
    param([string]$P)
    return ($P -match '(?i)[\\/](site-packages|node_modules|\.venv|venv)[\\/]' -or
            ($P -match '(?i)[\\/]envs[\\/][^\\/]+[\\/]' -and [IO.Path]::GetFileNameWithoutExtension($P) -notin @('python', 'python3', 'java', 'node')))
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
    try { $map = ConvertTo-HashtableDeep ([IO.File]::ReadAllText($p) | ConvertFrom-Json) }
    catch { Throw-MapError 'map_corrupt' "地图无法解析，请备份后修复：$p" }
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
    param([string]$Exe, [string[]]$Arguments, [int]$MaxLines = 4)
    $script:LastProbe = @{ ok = $false; reason = 'probe_failed'; exitCode = $null }
    # 最底层护栏，所有调用方（含配方专用探测）都不能绕过。
    if (-not $Exe -or (Test-IsShimPath $Exe) -or (Test-IsStoreAlias $Exe)) { $script:LastProbe.reason = 'skipped'; return '' }
    $p = $null
    try {
        $fileName = $Exe
        $argLine = ($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
        $ext = [IO.Path]::GetExtension($Exe).ToLowerInvariant()
        if ($ext -in @('.cmd', '.bat')) {
            $fileName = $env:ComSpec
            $argLine = '/d /s /c ""' + $Exe + '" ' + $argLine + '"'
        } elseif ($ext -eq '.ps1') { $script:LastProbe.reason = 'unsupported_probe'; return '' }
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $fileName
        $psi.Arguments = $argLine
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.EnvironmentVariables['MISE_AUTO_INSTALL'] = '0'
        $psi.EnvironmentVariables['MISE_NOT_FOUND_AUTO_INSTALL'] = '0'
        $psi.EnvironmentVariables['MISE_AUTO_UPDATE'] = '0'
        $p = [Diagnostics.Process]::Start($psi)
        $stdout = $p.StandardOutput.ReadToEndAsync()
        $stderr = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(20000)) {
            try { if ($PSVersionTable.PSVersion.Major -ge 7) { $p.Kill($true) } else { $p.Kill() } } catch { }
            $script:LastProbe.reason = 'timeout'; return ''
        }
        $script:LastProbe.exitCode = $p.ExitCode
        if ($p.ExitCode -ne 0) { return '' }
        if (-not $stdout.Wait(2000) -or -not $stderr.Wait(2000)) { $script:LastProbe.reason = 'timeout'; return '' }
        $script:LastProbe.ok = $true
        $script:LastProbe.reason = 'ok'
        return (@(("$($stdout.Result)`n$($stderr.Result)" -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First $MaxLines) -join "`n").Trim()
    } catch { return '' } finally { if ($p) { $p.Dispose() } }
}
$script:ProbeCache = @{}
function Get-ExeVersion {
    param([string]$ExePath)
    if (-not $ExePath) { return '' }
    $item = Get-Item -LiteralPath $ExePath -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item.PSIsContainer -or $item.Length -eq 0 -or (Test-IsShimPath $ExePath) -or (Test-IsStoreAlias $ExePath)) { return '' }
    $key = "$ExePath|$($item.Length)|$($item.LastWriteTimeUtc.Ticks)"
    if ($script:ProbeCache.ContainsKey($key)) { return $script:ProbeCache[$key] }
    $name = Get-ToolkitCanonicalName $item.BaseName
    $adapter = $script:ToolCatalog[$name]
    $probes = if ($adapter -and $adapter.probe) { $adapter.probe } else { ,@('--version') }
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
    $script:ProbeCache[$key] = $version
    return $version
}
function Test-VersionSatisfies { param([string]$Version, [string]$Wanted) return (Test-ToolkitVersionSatisfies $Version $Wanted) }
function Get-CandidateSource {
    param([string]$P)
    if (Test-ToolkitUnderRoot $P (Get-WarehouseRoot)) { return 'warehouse' }
    $miseRoot = if ($env:MISE_DATA_DIR) { $env:MISE_DATA_DIR } else { Join-Path $env:LOCALAPPDATA 'mise' }
    if ((Test-IsShimPath $P) -or (Test-ToolkitUnderRoot $P $miseRoot) -or $P -match '(?i)[\\/](nvm|fnm|volta|asdf|pyenv)[\\/]') { return 'manager' }
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
}
function New-Candidate {
    param([string]$P, [string]$VersionHint = '', [string]$IdPrefix = '')
    $P = [IO.Path]::GetFullPath($P)
    $source = Get-CandidateSource $P
    $item = Get-Item -LiteralPath $P -ErrorAction SilentlyContinue
    $shim = Test-IsShimPath $P
    $state = 'unverified'
    $actual = ''
    if ($shim -or (Test-IsStoreAlias $P)) { $state = 'skipped' }
    elseif (-not $item -or $item.PSIsContainer -or $item.Length -eq 0) { $state = 'unavailable' }
    else { $actual = Get-ExeVersion $P; if ($actual) { $state = 'verified' } }
    $dir = Get-ToolkitNormalizedPath (Split-Path $P -Parent)
    $pathDirs = @($env:PATH -split ';' | Where-Object { $_.Trim() } | ForEach-Object { Get-ToolkitNormalizedPath $_ })
    return @{
        id = ''; path = $P; version = if ($actual) { $actual } else { $VersionHint }
        source = $source; reachable = [bool]($pathDirs -contains $dir); isShim = [bool]$shim
        verification = $state; usable = if ($state -eq 'verified') { $true } elseif ($state -eq 'unavailable') { $false } else { $null }
        checkedAt = (Get-Date).ToString('o'); size = if ($item -and -not $item.PSIsContainer) { $item.Length } else { -1 }
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
function Get-ToolCandidates {
    param([string]$Name, [hashtable]$RuntimeIndex = @{})
    if ($Name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._+-]*$') { return @() }
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($runtime in $RuntimeIndex.Values) { if ($runtime.tool -eq $Name) { $paths.Add($runtime.path) } }
    foreach ($file in @(Get-PathHits $Name) + @(Get-WarehouseHits $Name) + @(Get-ManagerHits $Name)) { $paths.Add($file) }
    foreach ($location in @($script:ToolCatalog[$Name].locations)) {
        if (-not $location) { continue }
        $file = [Environment]::ExpandEnvironmentVariables($location)
        if ([IO.File]::Exists($file)) { $paths.Add($file) }
    }
    $seen = @{}
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($file in $paths) {
        $key = Get-ToolkitNormalizedPath $file
        if (-not $seen.ContainsKey($key) -and -not (Test-IsEnvInternal $file)) { $seen[$key] = $true; $out.Add((New-Candidate $file)) }
    }
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
        -not $_.isShim -and -not (Test-IsShimPath $_.path) -and $_.source -ne 'conda-env' -and
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
        @{Expression = { try { [version](($_.version -replace '[^0-9.]', '').Trim('.')) } catch { [version]'0.0' } }; Descending = $true},
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
    Write-AtomicUtf8 -Path (Get-MapPath) -Content ($Map | ConvertTo-Json -Depth 20)
    Write-MapMarkdown $Map
}
function Write-MapMarkdown {
    param($Map)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# 本机工具地图'); $lines.Add('')
    $lines.Add("完整扫描：$($Map.scannedAt)　最近更新：$($Map.updatedAt)"); $lines.Add('')
    $lines.Add('| 工具 | 默认候选 | 版本 | 验证 | 候选数 |'); $lines.Add('|---|---|---|---|---|')
    foreach ($name in ($Map.tools.Keys | Sort-Object)) {
        $entry = $Map.tools[$name]
        $chosen = @($entry.candidates | Where-Object { $_.id -eq $entry.preferred } | Select-Object -First 1)
        if ($chosen.Count) { $lines.Add("| $name | ``$($chosen[0].path -replace '\|', '\|')`` | $($chosen[0].version) | $($chosen[0].verification) | $(@($entry.candidates).Count) |") }
        else { $lines.Add("| $name | （无已验证的默认候选） | | | $(@($entry.candidates).Count) |") }
    }
    $lines.Add(''); $lines.Add('> 这是机器清单；项目内的最终选择由 find 按当前项目声明计算。')
    Write-AtomicUtf8 -Path ([IO.Path]::ChangeExtension((Get-MapPath), '.md')) -Content ($lines -join "`n")
}
function Merge-Candidates {
    param($Fresh, $Existing)
    $out = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($candidate in @($Fresh) + @($Existing)) {
        if (-not $candidate.path -or -not [IO.File]::Exists($candidate.path)) { continue }
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
function Invoke-Scan {
    Write-MapMessage '扫描本机（只读探测，不执行 shim）…'
    $old = Read-Map
    # 当前宿主路径同时支持 Windows PowerShell 5.1 与 PowerShell 7。
    $hostExe = (Get-Process -Id $PID).Path
    $output = & $hostExe -NoProfile -ExecutionPolicy Bypass -File $CensusScript -Json
    if ($LASTEXITCODE -ne 0) { Throw-MapError 'scan_failed' "census 退出码：$LASTEXITCODE" }
    try { $census = ($output | Out-String) | ConvertFrom-Json } catch { Throw-MapError 'scan_failed' 'census 未返回有效 JSON。' }
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
    foreach ($name in ($names | Sort-Object)) {
        $previous = if ($old) { $old.tools[$name] } else { $null }
        if ($name -eq 'rg' -and $old -and -not $previous) { $previous = $old.tools.ripgrep }
        $existing = if ($previous) { @($previous.candidates | Where-Object { [IO.File]::Exists($_.path) } | ForEach-Object {
            $new = New-Candidate $_.path $_.version; $new.registered = $_.registered; $new.userNote = $_.userNote; $new
        }) } else { @() }
        $candidates = @(Merge-Candidates (Get-ToolCandidates $name $index) $existing)
        if (-not $candidates.Count) { continue }
        $map.tools[$name] = @{ candidates = $candidates; preferred = ''; preferredPath = if ($previous) { "$($previous.preferredPath)" } else { '' } }
    }
    Save-Map $map
    return (New-MapResult 'ok' @{ mapFile = Get-MapPath; tools = $map.tools.Count; scannedAt = $map.scannedAt; warnings = $map.censusSummary.warnings })
}
function Invoke-Status {
    $map = Read-Map
    if (-not $map) { return (New-MapResult 'map_missing' @{ exists = $false; mapFile = Get-MapPath; hint = '先执行 setup 或 scan。' } $false) }
    $age = if ($map.scannedAt) { ((Get-Date) - [datetime]$map.scannedAt).TotalHours } else { $null }
    $dead = @($map.tools.Values | ForEach-Object { $_.candidates } | Where-Object { -not [IO.File]::Exists($_.path) }).Count
    $changed = ($map.pathSnapshot -ne $env:PATH)
    $stale = ($null -eq $age -or $age -gt $MaxAgeHours)
    return (New-MapResult 'ok' @{ exists = $true; mapFile = Get-MapPath; scannedAt = $map.scannedAt; updatedAt = $map.updatedAt;
        ageHours = if ($null -ne $age) { [math]::Round($age, 1) } else { $null }; stale = $stale; tools = $map.tools.Count;
        deadCandidates = $dead; pathChanged = $changed; hint = if ($stale -or $changed -or $dead) { '建议 scan；update 只刷新条目，不替代完整扫描。' } else { '地图可用。' } })
}
function Get-Requirement {
    param([string]$Name)
    if ($Version) { return @{ version = $Version; source = 'argument'; scope = 'argument' } }
    foreach ($declaration in @(Get-ToolkitDeclarations $Project)) {
        $key = if ($Name -eq 'python3') { 'python' } else { $Name }
        if ($declaration.unsupported -contains $key) { Throw-MapError 'requirement_unsupported' "声明语法尚不支持：$($declaration.path) 的 $key；请用 -Version 明确指定。" }
        if ($declaration.tools.ContainsKey($key)) { return @{ version = "$($declaration.tools[$key])"; source = $declaration.path; scope = $declaration.scope } }
    }
    return @{ version = ''; source = ''; scope = '' }
}
function Invoke-Find {
    if (-not $Tool) { Throw-MapError 'invalid_argument' 'find 需要工具名。' }
    $name = Get-ToolkitCanonicalName $Tool
    if ($name -notmatch '^[a-z0-9][a-z0-9._+-]*$') { Throw-MapError 'invalid_argument' '工具名不能是路径或包含分隔符。' }
    $map = Read-Map
    if (-not $map) { Throw-MapError 'map_missing' '还没有地图，先执行 setup 或 scan。' }
    $entry = $map.tools[$name]
    if (-not $entry -and $name -eq 'rg') { $entry = $map.tools.ripgrep }
    $existing = if ($entry) { @($entry.candidates) } else { @() }
    $currentPathDirs = @($env:PATH -split ';' | Where-Object { $_.Trim() } | ForEach-Object { Get-ToolkitNormalizedPath $_ })
    $live = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in $existing) {
        if (-not [IO.File]::Exists($candidate.path)) { continue }
        $item = Get-Item -LiteralPath $candidate.path
        if (-not $candidate.verification -or $candidate.size -ne $item.Length -or $candidate.modifiedAt -ne $item.LastWriteTimeUtc.ToString('o')) {
            $fresh = New-Candidate $candidate.path $candidate.version
            $fresh.registered = $candidate.registered; $fresh.userNote = $candidate.userNote
            if ($candidate.userNote) { $fresh.note = $candidate.userNote }
            $live.Add($fresh)
        } else {
            $candidate.reachable = [bool]($currentPathDirs -contains (Get-ToolkitNormalizedPath (Split-Path $candidate.path -Parent)))
            $live.Add($candidate)
        }
    }
    $requirement = Get-Requirement $name
    if (-not (Test-ToolkitRequirementSupported $requirement.version)) {
        Throw-MapError 'requirement_unsupported' "无法判定版本要求：$($requirement.version)（$($requirement.source)）；请用支持的 -Version 或通过管理器执行。"
    }
    $declared = @{}; if ($requirement.version) { $declared[$name] = $requirement.version }
    $preferredPath = if ($entry) { "$($entry.preferredPath)" } else { '' }
    $candidates = $live.ToArray()
    Set-UniqueCandidateIds $candidates
    $selected = Select-Preferred $name $candidates $declared $preferredPath
    $searched = $false
    if (-not $selected -and -not $SkipScan) {
        $candidates = @(Merge-Candidates (Get-ToolCandidates $name) $candidates)
        $searched = $true
        $selected = Select-Preferred $name $candidates $declared $preferredPath
    }
    $map.tools[$name] = @{ candidates = $candidates; preferred = ''; preferredPath = $preferredPath }
    # 只在清理/迁移/发现发生时保存；不把查询结果作为机器全局的项目选择。
    $before = $existing | ConvertTo-Json -Depth 20 -Compress
    $after = $candidates | ConvertTo-Json -Depth 20 -Compress
    if ($before -ne $after -or -not $entry) { Save-Map $map }
    $chosen = @($candidates | Where-Object { $_.id -eq $selected } | Select-Object -First 1)
    $fields = @{ tool = $name; requestedTool = $Tool; found = [bool]$chosen.Count; path = ''; version = ''; source = ''; note = '';
        requirement = $requirement; candidates = $candidates; search = @{ performed = $searched; complete = $false; scope = @('map', 'PATH', 'warehouse', 'mise-installs', 'adapter-locations') };
        reason = ''; verification = ''; invocation = $null }
    if ($chosen.Count) {
        $c = $chosen[0]
        foreach ($key in @('path', 'version', 'source', 'note', 'verification')) { $fields[$key] = $c[$key] }
        $fields.reason = if ($preferredPath -eq $c.path) { 'user_preference' } elseif ($requirement.version) { 'requirement_match' } else { 'machine_default' }
        $fields.invocation = @{ executable = $c.path; arguments = @(); cwd = if ($Project) { [IO.Path]::GetFullPath($Project) } else { (Get-Location).Path } }
        if ($requirement.scope -eq 'project') { $fields.environmentHint = '需要项目环境变量或配套工具时，通过已登记的 mise 执行 mise exec -- <命令>。' }
        return (New-MapResult $(if ($c.verification -eq 'verified') { 'ok' } else { 'unverified' }) $fields)
    }
    $verified = @($candidates | Where-Object { $_.verification -eq 'verified' -and -not $_.isShim })
    $status = if ($requirement.version -and $verified.Count) { 'version_mismatch' } elseif ($candidates.Count) { 'no_usable_candidate' } else { 'not_found' }
    $fields.hint = if ($status -eq 'version_mismatch') { '没有满足要求的候选；不会降级。确认需要后再安装所需版本。' } else { '本次搜索范围内没有已验证的合适副本；不代表全盘不存在，也不会自动安装。' }
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
    $c = New-Candidate $absolute $Version
    $c.registered = $true
    if ($Note) { $c.userNote = $Note; $c.note = $Note }
    $entry.candidates = @($entry.candidates | Where-Object { $_.path -ne $absolute }) + @($c)
    if ($Prefer) { $entry.preferredPath = $absolute }
    Save-Map $map
    return (New-MapResult 'ok' @{ tool = $name; path = $absolute; verification = $c.verification; preferredPath = $entry.preferredPath; mapFile = Get-MapPath })
}
function Invoke-Update {
    $map = Read-Map
    if (-not $map) { Throw-MapError 'map_missing' '先执行 setup 或 scan。' }
    $targets = if ($Tool) { @(Get-ToolkitCanonicalName $Tool) } else { @($map.tools.Keys) }
    foreach ($name in $targets) {
        $entry = $map.tools[$name]
        $existing = if ($entry) { @($entry.candidates | Where-Object { [IO.File]::Exists($_.path) } | ForEach-Object {
            $c = New-Candidate $_.path $_.version; $c.registered = $_.registered; $c.userNote = $_.userNote; if ($_.userNote) { $c.note = $_.userNote }; $c
        }) } else { @() }
        $candidates = @(Merge-Candidates (Get-ToolCandidates $name) $existing)
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
    $command = $script:MapScriptPath.Replace("'", "''")
    return @"
<!-- toolkit-map:begin -->
## 本机工具发现

调用工具前，先用下面的绝对路径查询工具地图；使用 JSON 返回的路径与 requirement、verification。
工具地图脚本：$script:MapScriptPath
在 PowerShell 中执行：
``````powershell
& '$command' status -Json
& '$command' find <工具> -Json -Project <当前项目目录>
``````
版本不匹配或未验证时先诊断，不降级、不据此断言整台机器没有该工具。
find 不安装工具。只有明确需要时才单独执行 install；已有副本用 add 登记，不迁移、不改全局 PATH。
项目需要完整工具链环境时，通过已登记的 mise 执行 mise exec -- <命令>。
<!-- toolkit-map:end -->
"@
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
    if ($map) {
        $state = Invoke-Status
        $checks.Add(@{ name = 'freshness'; ok = (-not $state.stale -and -not $state.pathChanged -and $state.deadCandidates -eq 0); detail = $state.hint })
        $blocked = @($map.tools.Values | ForEach-Object { $_.candidates } | Where-Object { $_.verification -ne 'verified' }).Count
    } else { $blocked = 0 }
    $ok = @($checks | Where-Object { -not $_.ok }).Count -eq 0
    return (New-MapResult $(if ($ok) { 'ok' } else { 'attention_required' }) @{ checks = $checks.ToArray(); unverifiedCandidates = $blocked; agentVerified = $false;
        hint = 'doctor 只检查本机配置；用一次真实的工具查询验证 agent 行为。' } $ok)
}
