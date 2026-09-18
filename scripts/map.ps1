# toolkit-map —— 本机工具地图（给 agent 用）
#
# 定位：agent 要用工具之前先查这张地图拿到**绝对路径**，而不是靠 PATH 解析或自己猜。
#   scan    扫描本机，生成/刷新地图
#   status  地图在不在、多旧、是否需要重扫
#   find    查一个工具：返回该用哪个（绝对路径 + 版本 + 依据 + 其他候选）
#   add     把一个手工装的工具登记进地图（不搬家）
#   update  重探某个工具（路径没了/版本变了/多出新副本时用它）
#   install 把新工具装进统一仓库，并登记进地图
#
# 与 census.ps1 的分工：census 负责"磁盘上有什么"（扫描内核，已跑在 CI 里），
# 本脚本负责"该用哪个、装哪里、怎么记住"。扫描时直接复用 census 的 JSON 输出，
# 不重复实现盘点逻辑。
#
# 只读承诺（今天的教训）：探测版本时会**执行**目标文件，而 mise 的 shim 被执行时
# 会触发自动安装。所以这里对所有 shim 类路径一律不执行、只登记路径。

param(
    [Parameter(Position = 0)][string]$Action = 'status',
    [Parameter(Position = 1)][string]$Tool = '',

    [string]$Path = '',                      # add 用：候选的绝对路径
    [string]$Version = '',                   # add 用：版本（留空则尝试自动探测）
    [string]$Note = '',                      # add/find 用：备注
    [switch]$Prefer,                         # add 用：同时标记为首选

    [string]$Url = '',                       # install 用：portable 归档的直链
    [string]$MapFile = '',                   # 覆盖地图位置（默认 ~/.toolkit/map.json）
    [int]$MaxAgeHours = 24,                  # status 用：超过多少小时算旧

    [switch]$Json,                           # 机器可读输出（agent 用这个）
    [switch]$SkipScan,                       # find 用：地图里没有时不去现场搜
    [switch]$WhatIf                          # install 用：只打印要做什么
)

$ErrorActionPreference = 'Stop'

# ---------- 路径与常量 ----------

function Get-MapPath {
    if ($MapFile) { return $MapFile }
    if ($env:TOOLKIT_MAP) { return $env:TOOLKIT_MAP }
    return (Join-Path $env:USERPROFILE '.toolkit\map.json')
}

# 统一仓库：新装的工具落在这里，按 <工具>/<版本>/ 并列。
# 注意它不进 PATH —— PATH 只应该有一个间接层，多版本塞进 PATH 只会互相遮蔽。
function Get-WarehouseRoot {
    if ($env:TOOLCHAIN_ROOT) { return $env:TOOLCHAIN_ROOT }
    return (Join-Path $env:USERPROFILE 'toolchains')
}

$CensusScript = Join-Path $PSScriptRoot 'census.ps1'

# 扫描时按这些名字去 PATH / 管理器目录里找候选。不是白名单——找不到就是没有；
# 没在这张表里、但装在管理器目录或仓库里的工具，也会通过"目录枚举"被发现。
$CommonToolNames = @(
    # 语言运行时与包管理器
    'node', 'npm', 'npx', 'pnpm', 'yarn', 'corepack', 'bun', 'deno',
    'python', 'python3', 'pip', 'pipx', 'uv', 'py', 'poetry', 'conda',
    'java', 'javac', 'mvn', 'gradle', 'kotlin', 'scala',
    'go', 'cargo', 'rustc', 'gcc', 'clang', 'dotnet', 'php', 'ruby', 'perl', 'lua',
    # 开发与运维 CLI
    'git', 'gh', 'git-lfs', 'docker', 'kubectl', 'helm', 'terraform', 'aws', 'az',
    'jq', 'yq', 'rg', 'fd', 'fzf', 'bat', 'curl', 'wget', 'openssl', 'make', 'cmake', 'ninja',
    'ffmpeg', 'magick', '7z', 'sqlite3', 'mysql', 'psql', 'redis-cli',
    # 工具管理器本身也是工具（"我用的那套管理器在哪儿、什么版本"同样要能查）
    'mise', 'winget', 'scoop', 'choco', 'nvm', 'fnm', 'volta', 'asdf', 'conda', 'pipx', 'poetry',
    # 日常会用到的通用命令
    'tar', 'ssh', 'scp', 'vim', 'nvim', 'code', 'unzip', 'ncat',
    # 逆向 / 安全（本机用户的工作范围，值得进地图）
    'jadx', 'apktool', 'adb', 'frida', 'objection', 'r2', 'rabin2', 'radare2',
    'nmap', 'masscan', 'sqlmap', 'hashcat', 'john', 'tshark', 'yara', 'binwalk',
    'exiftool', 'steghide', 'strings', 'objdump', 'readelf', 'gdb', 'lldb', 'dumpbin'
)

# ---------- 只读护栏 ----------

# shim 类路径：可以被"发现"，但绝不执行它去问版本。
# 理由：mise 的 shim 在目标工具缺失时会**自动安装**（今天实测触发过一次），
# 一个只读的盘点工具不该改机器状态。
function Test-IsShimPath {
    param([string]$P)
    return ($P -match '\\mise\\shims\\' -or $P -match '/mise/shims/')
}

# 商店应用执行别名：可能是 0 字节占位，执行会静默失败（退出码 9009）。
function Test-IsStoreAlias {
    param([string]$P)
    return ($P -match '\\WindowsApps\\')
}

# 依赖特定环境的路径：这些**不进地图**。
# 判据来自需求：miniconda 某个 env 里的小包、venv、node_modules 离开那个环境就没有意义，
# 而地图要记的是"能独立执行的工具"。
function Test-IsEnvInternal {
    param([string]$P)
    if ($P -match '\\envs\\[^\\]+\\' -and $P -notmatch '\\envs\\[^\\]+\\bin\\') { return $true }
    if ($P -match '\\site-packages\\' -or $P -match '/site-packages/') { return $true }
    if ($P -match '\\node_modules\\' -or $P -match '/node_modules/') { return $true }
    if ($P -match '\\\.venv\\' -or $P -match '/\.venv/') { return $true }
    # conda env 里的解释器：不排除，但下面会标成 conda-env（默认不作首选）
    return $false
}

# ---------- 版本探测（唯一会执行外部程序的地方）----------

function Get-ExeVersion {
    param([string]$ExePath)
    if (-not $ExePath) { return '' }
    if (Test-IsShimPath $ExePath) { return '' }        # 护栏：不执行 shim
    if (Test-IsStoreAlias $ExePath) { return '' }       # 护栏：不执行商店别名
    $item = Get-Item -LiteralPath $ExePath -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item.PSIsContainer -or $item.Length -eq 0) { return '' }
    foreach ($flag in @('--version', '-version')) {
        try {
            $out = & $ExePath $flag 2>&1 | Select-Object -First 1
            if ($out) {
                # 统一成裸版本号：'v22.23.2' -> '22.23.2'、'Python 3.12.14' -> '3.12.14'
                $t = "$out".Trim()
                $m = [regex]::Match($t, '\d+(\.\d+)+[A-Za-z0-9._+-]*')
                if ($m.Success) { return $m.Value }
                return $t
            }
        } catch { }
    }
    return ''
}

# 声明里的 "3.12" 满足 "3.12.10"、"22" 满足 "22.23.2"；判断不出来一律当作满足。
# 与 census.ps1 的 Test-VersionSatisfies 规则一致（那边是告警判定，这里是首选判定）。
function Test-VersionSatisfies {
    param([string]$Version, [string]$Wanted)
    if ([string]::IsNullOrWhiteSpace($Wanted)) { return $true }
    if ([string]::IsNullOrWhiteSpace($Version)) { return $false }
    $actual = @([regex]::Matches($Version, '\d+') | ForEach-Object { [int]$_.Value })
    if ($actual.Count -eq 0) { return $true }
    foreach ($one in ($Wanted -split '[,;]')) {
        $w = "$one".Trim() -replace '"', ''
        if ([string]::IsNullOrWhiteSpace($w)) { continue }
        if ($w -match '^(?i)(latest|stable|lts|system|any|\*)$') { return $true }
        $w = $w -replace '^[A-Za-z][A-Za-z0-9]*[-_]', ''
        $want = @([regex]::Matches($w, '\d+') | ForEach-Object { [int]$_.Value })
        if ($want.Count -eq 0) { return $true }
        $n = [Math]::Min($want.Count, $actual.Count)
        $ok = $true
        for ($i = 0; $i -lt $n; $i++) { if ($want[$i] -ne $actual[$i]) { $ok = $false; break } }
        if ($ok) { return $true }
    }
    return $false
}

# ---------- 候选分类 ----------

function Get-CandidateSource {
    param([string]$P)
    $n = $P -replace '/', '\'
    if ($n -match '\\toolchains\\') { return 'warehouse' }
    if ($n -match '\\mise\\(installs|shims)\\') { return 'manager' }
    if ($n -match '\\envs\\[^\\]+\\') { return 'conda-env' }
    if ($n -match 'miniconda|anaconda|miniforge') { return 'conda-base' }
    if ($n -match '\\jbr\\|JetBrains|IntelliJ|PyCharm|IDEA') { return 'ide-host' }
    if ($n -match '\\Program Files( \(x86\))?\\|\\WindowsApps\\|^/usr/|^/opt/|^/Library/') { return 'system' }
    if ($n -match '\\nvm\\|\\fnm\\|\\volta\\|\\asdf\\|\\pyenv\\|\.local\\share\\uv') { return 'manager' }
    return 'manual'
}

# 需要用户/agent 留意的备注：这些是"能发现但别直接当首选"的情况
function Get-CandidateNote {
    param([string]$Source, [string]$P)
    switch ($Source) {
        'conda-env' { return 'conda 环境内的解释器：离开该环境无意义，默认不作首选' }
        'conda-base' { return 'conda base：可独立调用，但它自带一套包管理，注意别和系统 python 混用' }
        'ide-host' { return 'IDE 自带运行时：属于宿主，只在明确需要时使用' }
        'manager' { if (Test-IsShimPath $P) { return 'shim（未执行探测，避免触发自动安装）' } }
        'system' { if (Test-IsStoreAlias $P) { return '商店应用执行别名：可能是 0 字节占位' } }
    }
    return ''
}

# ---------- 地图读写 ----------

# ConvertFrom-Json 给出的是 PSCustomObject，改起来麻烦；统一转成哈希表处理。
function ConvertTo-HashtableDeep {
    param($Obj)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-HashtableDeep $p.Value }
        return $h
    }
    if ($Obj -is [System.Collections.IEnumerable] -and $Obj -isnot [string]) {
        return @($Obj | ForEach-Object { ConvertTo-HashtableDeep $_ })
    }
    return $Obj
}

function Read-Map {
    $p = Get-MapPath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (ConvertTo-HashtableDeep (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)) }
    catch { Write-Warning "地图文件解析失败（当作没有地图处理）：$p"; return $null }
}

function Save-Map {
    param($Map)
    $p = Get-MapPath
    $dir = Split-Path $p -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $Map.scannedAt = (Get-Date).ToString('o')
    ($Map | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $p -Encoding UTF8
    Write-MapMarkdown $Map
}

# 人类可读摘要。agent 用 JSON，人看这个。
function Write-MapMarkdown {
    param($Map)
    $p = [IO.Path]::ChangeExtension((Get-MapPath), '.md')
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# 本机工具地图")
    $lines.Add('')
    $lines.Add("扫描时间：$($Map.scannedAt)　仓库：$($Map.warehouse)")
    $lines.Add('')
    $lines.Add('| 工具 | 首选 | 版本 | 来源 | 其他候选 |')
    $lines.Add('|---|---|---|---|---|')
    foreach ($name in ($Map.tools.Keys | Sort-Object)) {
        $t = $Map.tools[$name]
        $pref = @($t.candidates | Where-Object { $_.id -eq $t.preferred } | Select-Object -First 1)
        $others = @($t.candidates).Count - 1
        if ($pref.Count -eq 0) {
            $lines.Add("| $name | （未定） | | | $others |")
        } else {
            $lines.Add("| $name | ``$($pref[0].path)`` | $($pref[0].version) | $($pref[0].source) | $others |")
        }
    }
    $lines.Add('')
    $lines.Add('> 首选规则：声明优先 → 统一仓库 → 管理器 → 手装 → 系统/宿主。')
    ($lines -join "`n") | Set-Content -LiteralPath $p -Encoding UTF8
}

# ---------- 候选收集 ----------

# 在 PATH 上找出这个命令名的**全部**命中（不是一个——PATH 是单值命名空间，
# "还有哪几份"才是地图要回答的）。
function Get-PathHits {
    param([string]$Name)
    $hits = New-Object System.Collections.Generic.List[string]
    $dirs = @(($env:PATH -split ';') | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') } | Sort-Object -Unique)
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        foreach ($ext in @('', '.exe', '.cmd', '.bat', '.ps1')) {
            $f = Join-Path $d ($Name + $ext)
            if (Test-Path -LiteralPath $f -PathType Leaf) {
                if (-not $hits.Contains($f)) { $hits.Add($f) }
            }
        }
    }
    return @($hits)
}

# 仓库里已经装好的版本：<仓库>/<工具>/<版本>/**（含 bin 子目录）
function Get-WarehouseHits {
    param([string]$Name)
    $root = Get-WarehouseRoot
    $toolDir = Join-Path $root $Name
    if (-not (Test-Path -LiteralPath $toolDir)) { return @() }
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($verDir in (Get-ChildItem -LiteralPath $toolDir -Directory -ErrorAction SilentlyContinue)) {
        foreach ($cand in (Get-ChildItem -LiteralPath $verDir.FullName -Recurse -File -ErrorAction SilentlyContinue |
                           Where-Object { $_.BaseName -eq $Name -and $_.Extension -in @('', '.exe', '.cmd', '.bat') } |
                           Select-Object -First 3)) {
            $found.Add($cand.FullName)
        }
    }
    return @($found)
}

# 管理器目录里的版本（mise 的 installs）：也是"多版本并列"的一种真实存在
function Get-ManagerHits {
    param([string]$Name)
    $miseData = if ($env:MISE_DATA_DIR) { $env:MISE_DATA_DIR } else { Join-Path $env:LOCALAPPDATA 'mise' }
    $installs = Join-Path $miseData 'installs'
    $toolDir = Join-Path $installs $Name
    if (-not (Test-Path -LiteralPath $toolDir)) { return @() }
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($verDir in (Get-ChildItem -LiteralPath $toolDir -Directory -ErrorAction SilentlyContinue)) {
        foreach ($cand in (Get-ChildItem -LiteralPath $verDir.FullName -Recurse -File -ErrorAction SilentlyContinue |
                           Where-Object { $_.BaseName -eq $Name -and $_.Extension -in @('.exe', '.cmd', '') } |
                           Select-Object -First 3)) {
            $found.Add($cand.FullName)
        }
    }
    return @($found)
}

function New-Candidate {
    param([string]$P, [string]$VersionHint = '', [string]$IdPrefix = '')
    $source = Get-CandidateSource $P
    $ver = $VersionHint
    if (-not $ver) { $ver = Get-ExeVersion $P }      # 内部已带"不执行 shim"护栏
    $dir = Split-Path $P -Parent
    $pathDirs = @(($env:PATH -split ';') | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLowerInvariant() })
    $reachable = $pathDirs -contains $dir.TrimEnd('\').ToLowerInvariant()
    $id = if ($IdPrefix) { "$IdPrefix" } else { ($source + '-' + ($ver -replace '[^\w\.]', '_')) }
    return @{
        id        = $id
        version   = $ver
        path      = $P
        source    = $source
        reachable = [bool]$reachable
        isShim    = (Test-IsShimPath $P)
        note      = (Get-CandidateNote -Source $source -P $P)
    }
}

# 收集某个工具的全部候选
function Get-ToolCandidates {
    param([string]$Name, [hashtable]$RuntimeIndex)
    $cands = New-Object System.Collections.Generic.List[object]
    $seen = New-Object System.Collections.Generic.HashSet[string]

    # 1) census 的运行时清单（含系统安装、IDE 内置、conda、手装副本）
    foreach ($r in @($RuntimeIndex.Values | Where-Object { $_.tool -eq $Name })) {
        if ($seen.Add($r.path.ToLowerInvariant())) {
            $cands.Add((New-Candidate -P $r.path -VersionHint $r.version))
        }
    }
    # 2) PATH 上的全部命中（census 只探固定清单，这里覆盖任意命令名）
    foreach ($p in (Get-PathHits $Name)) {
        if ($seen.Add($p.ToLowerInvariant())) { $cands.Add((New-Candidate -P $p)) }
    }
    # 3) 统一仓库
    foreach ($p in (Get-WarehouseHits $Name)) {
        if ($seen.Add($p.ToLowerInvariant())) { $cands.Add((New-Candidate -P $p)) }
    }
    # 4) 管理器目录（mise installs）
    foreach ($p in (Get-ManagerHits $Name)) {
        if ($seen.Add($p.ToLowerInvariant())) { $cands.Add((New-Candidate -P $p)) }
    }

    # 过滤：依赖特定环境的副本不进地图
    $cands = @($cands | Where-Object { -not (Test-IsEnvInternal $_.path) })

    # 归并同一路径的重复项，并给同工具的多个同来源条目补上区分的 id
    $dupes = @{}
    foreach ($c in $cands) { $dupes[$c.id] = ($dupes[$c.id] + 1) }
    foreach ($c in $cands) {
        if ($dupes[$c.id] -gt 1) {
            $c.id = $c.id + '-' + ([IO.Path]::GetFileName((Split-Path $c.path -Parent)) -replace '[^\w\.]', '_')
        }
    }
    return @($cands)
}

# 首选规则（按你的拍板细化）：
#   1) 有声明 → 只从满足声明的候选里选
#   2) 仓库里装的那份最优先（那是"我们的"，位置可控、不会被 PATH 变化弄丢）
#   3) 其余先看**能不能被 PATH 解析到**：同一个版本下，"本来就能跑"的那份比"只能在旧会话里跑"的强
#   4) 再比来源：管理器 > 手装 > 系统/宿主 > conda
#   5) 最后比版本（高者优先）
# 环境内的副本（conda env）默认不参选，除非没有别的。
function Select-Preferred {
    param([string]$Name, $Candidates, [hashtable]$DeclaredVersions)
    $order = @{ 'warehouse' = 0; 'manager' = 1; 'manual' = 2; 'system' = 3; 'ide-host' = 4; 'conda-base' = 5; 'conda-env' = 6 }
    $list = @($Candidates)
    if ($list.Count -eq 0) { return '' }

    $wanted = ''
    if ($DeclaredVersions -and $DeclaredVersions.ContainsKey($Name)) { $wanted = "$($DeclaredVersions[$Name])" }

    # 1) 声明优先：只从**满足声明的具体二进制**里选。
    #    shim 不参与这一步——它是间接层，底下指向哪个版本会随所在项目的声明变化，
    #    所以它不是"那个确定的二进制"。项目级声明比机器级更具体，协议里要求 agent
    #    在项目内用 mise exec，这一点写在 SKILL.md。
    if ($wanted) {
        $ok = @($list | Where-Object { -not $_.isShim -and (Test-VersionSatisfies -Version $_.version -Wanted $wanted) })
        if ($ok.Count -gt 0) { $list = $ok }
    }
    # 2) 环境内的副本默认不当首选（除非没有别的）
    $nonEnv = @($list | Where-Object { $_.source -ne 'conda-env' })
    if ($nonEnv.Count -gt 0) { $list = $nonEnv }

    # 3) 仓库里那份最优先；其余按"确定程度"排：
    #    可直接解析的具体二进制 > 可直接解析的 shim > 解析不到的副本 > 来源优先级 > 版本
    $best = $list |
        Sort-Object @{ Expression = { if ($_.source -eq 'warehouse') { 0 } else { 1 } } },
                    @{ Expression = { if ($_.isShim) { 2 } elseif ($_.reachable) { 1 } else { 3 } } },
                    @{ Expression = { $order[$_.source] } },
                    @{ Expression = {
                           $v = ($_.version -replace '[^0-9.]', '')
                           try { [version]$v } catch { [version]'0.0' }
                       }; Descending = $true } |
        Select-Object -First 1
    return $best.id
}

# 从声明文件里取"这个工具要求什么版本"
function Get-DeclaredVersions {
    param($Declarations)
    $out = @{}
    foreach ($d in @($Declarations)) {
        foreach ($prop in $d.tools.PSObject.Properties) {
            $k = $prop.Name -replace '^(nodejs)$', 'node' -replace '^python3$', 'python'
            if (-not $out.ContainsKey($k)) { $out[$k] = "$($prop.Value)" }
        }
    }
    return $out
}

# ---------- 动作：scan ----------

function Invoke-Scan {
    Write-Host '扫描本机（复用 census 的扫描内核）…' -ForegroundColor Cyan
    $censusJson = & "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $CensusScript -Json 2>$null | Out-String
    $census = $null
    try { $census = $censusJson | ConvertFrom-Json } catch { throw "census 输出不是可解析的 JSON：$($_.Exception.Message)" }

    $declared = Get-DeclaredVersions $census.declarations
    $runtimeIndex = @{}
    foreach ($r in @($census.runtimes)) { $runtimeIndex[$r.path] = $r }

    # 要扫的工具名 = census 清单里的 ∪ 声明里的 ∪ 常见工具表 ∪ 仓库里已有的 ∪ 管理器里已装的
    $names = New-Object System.Collections.Generic.HashSet[string]
    foreach ($r in @($census.runtimes)) { [void]$names.Add($r.tool) }
    foreach ($k in $declared.Keys) { [void]$names.Add($k) }
    foreach ($n in $CommonToolNames) { [void]$names.Add($n) }
    foreach ($d in (Get-ChildItem -LiteralPath (Get-WarehouseRoot) -Directory -ErrorAction SilentlyContinue)) { [void]$names.Add($d.Name) }
    $miseInstalls = Join-Path $env:LOCALAPPDATA 'mise\installs'
    foreach ($d in (Get-ChildItem -LiteralPath $miseInstalls -Directory -ErrorAction SilentlyContinue)) { [void]$names.Add($d.Name) }

    $map = @{
        schemaVersion = 1
        scannedAt     = (Get-Date).ToString('o')
        warehouse     = (Get-WarehouseRoot)
        pathSnapshot  = (($env:PATH -split ';') -join ';')
        censusSummary = @{
            warnings = @(@($census.warnings) | ForEach-Object { "$($_.kind)" })
            counts   = @{ runtimes = @($census.runtimes).Count; declarations = @($census.declarations).Count }
        }
        tools         = @{}
    }

    $found = 0
    foreach ($name in ($names | Sort-Object)) {
        $cands = @(Get-ToolCandidates -Name $name -RuntimeIndex $runtimeIndex)
        if ($cands.Count -eq 0) { continue }      # 没找到就不进地图（find 会发现它缺失）
        $found++
        $map.tools[$name] = @{
            preferred  = (Select-Preferred -Name $name -Candidates $cands -DeclaredVersions $declared)
            candidates = $cands
        }
    }

    Save-Map $map
    if ($Json) {
        @{ mapFile = (Get-MapPath); tools = $found; scannedAt = $map.scannedAt } | ConvertTo-Json -Compress
    } else {
        Write-Host ("  地图已写入：{0}" -f (Get-MapPath)) -ForegroundColor Green
        Write-Host ("  收录 {0} 个工具、{1} 条候选；人类可读摘要见同名 .md 文件" -f $found, (@($map.tools.Values | ForEach-Object { $_.candidates.Count } | Measure-Object -Sum).Sum))
    }
}

# ---------- 动作：status ----------

function Invoke-Status {
    $map = Read-Map
    $mapPath = Get-MapPath
    if ($null -eq $map) {
        $o = @{ mapFile = $mapPath; exists = $false; hint = '还没有地图，先跑：map.ps1 scan' }
        if ($Json) { $o | ConvertTo-Json -Compress } else { Write-Host "还没有地图。先跑：map.ps1 scan" -ForegroundColor Yellow }
        return
    }
    $age = ((Get-Date) - [datetime]$map.scannedAt).TotalHours
    $pathChanged = ($map.pathSnapshot -ne (($env:PATH -split ';') -join ';'))
    $dead = 0
    foreach ($t in $map.tools.Values) {
        foreach ($c in @($t.candidates)) { if (-not (Test-Path -LiteralPath $c.path)) { $dead++ } }
    }
    $o = @{
        mapFile = $mapPath; exists = $true; scannedAt = $map.scannedAt
        ageHours = [math]::Round($age, 1); stale = ($age -gt $MaxAgeHours)
        tools = $map.tools.Count; deadCandidates = $dead; pathChanged = $pathChanged
        hint = if ($age -gt $MaxAgeHours -or $dead -gt 0 -or $pathChanged) { '建议重扫：map.ps1 scan（或 map.ps1 update 只重探某几个）' } else { '地图可用' }
    }
    if ($Json) { $o | ConvertTo-Json -Compress } else { $o | Format-List | Out-String | Write-Host }
}

# ---------- 动作：find ----------

function Invoke-Find {
    if (-not $Tool) { throw "find 需要一个工具名：map.ps1 find <tool>" }
    $map = Read-Map
    if ($null -eq $map) { throw "还没有地图。先跑：map.ps1 scan" }

    if (-not $map.tools.ContainsKey($Tool)) {
        if (-not $SkipScan) {
            # 地图里没有 → 现场在 PATH / 仓库 / 管理器目录里找一次，找到就补进地图
            Write-Host "地图里没有 '$Tool'，现场搜索…" -ForegroundColor DarkGray
            $cands = @(Get-ToolCandidates -Name $Tool -RuntimeIndex @{})
            if ($cands.Count -gt 0) {
                $map.tools[$Tool] = @{ preferred = (Select-Preferred -Name $Tool -Candidates $cands); candidates = $cands }
                Save-Map $map
                Write-Host "  找到并已登记进地图。" -ForegroundColor Green
            } else {
                # 真的没有 → 按协议应当装进仓库
                $o = @{ tool = $Tool; found = $false; hint = "本机没有这个工具。按协议装进统一仓库：map.ps1 install $Tool@<版本>" }
                if ($Json) { $o | ConvertTo-Json -Compress } else { Write-Host "本机没有 '$Tool'。用 map.ps1 install $Tool@<版本> 装进仓库。" -ForegroundColor Yellow }
                exit 1
            }
        } else {
            $o = @{ tool = $Tool; found = $false; hint = '地图里没有（本次跳过现场搜索）' }
            if ($Json) { $o | ConvertTo-Json -Compress } else { Write-Host "地图里没有 '$Tool'（-SkipScan）" -ForegroundColor Yellow }
            exit 1
        }
    }

    $t = $map.tools[$Tool]
    $pref = @($t.candidates | Where-Object { $_.id -eq $t.preferred } | Select-Object -First 1)
    $others = @($t.candidates | Where-Object { $_.id -ne $t.preferred })

    if ($Json) {
        @{
            tool      = $Tool
            found     = $true
            path      = if ($pref.Count -gt 0) { $pref[0].path } else { '' }
            version   = if ($pref.Count -gt 0) { $pref[0].version } else { '' }
            source    = if ($pref.Count -gt 0) { $pref[0].source } else { '' }
            note      = if ($pref.Count -gt 0) { $pref[0].note } else { '' }
            candidates = @($t.candidates)
        } | ConvertTo-Json -Depth 6 -Compress
        return
    }

    if ($pref.Count -eq 0) {
        Write-Host "  $Tool ：地图里没有任何候选（需要登记或安装）" -ForegroundColor Yellow
    } else {
        Write-Host ("  {0} → {1}" -f $Tool, $pref[0].path) -ForegroundColor Green
        Write-Host ("      版本 {0}　来源 {1}　可被 PATH 解析 {2}" -f $pref[0].version, $pref[0].source, $pref[0].reachable)
        if ($pref[0].note) { Write-Host ("      " + $pref[0].note) -ForegroundColor DarkGray }
    }
    if ($others.Count -gt 0) {
        Write-Host ("  另有 {0} 份副本（不要用错）：" -f $others.Count) -ForegroundColor DarkGray
        foreach ($o in $others) {
            Write-Host ("      {0}  [{1}] {2} {3}" -f $o.path, $o.source, $o.version, $(if ($o.note) { '— ' + $o.note } else { '' })) -ForegroundColor DarkGray
        }
    }
}

# ---------- 动作：add / update ----------

function Invoke-Add {
    if (-not $Tool -or -not $Path) { throw "用法：map.ps1 add <tool> -Path <绝对路径> [-Version v] [-Note 说明] [-Prefer]" }
    if (-not (Test-Path -LiteralPath $Path)) { throw "路径不存在：$Path" }
    $map = Read-Map
    if ($null -eq $map) { $map = @{ schemaVersion = 1; toolstore = $null; warehouse = (Get-WarehouseRoot); tools = @{} } }
    if (-not $map.tools.ContainsKey($Tool)) { $map.tools[$Tool] = @{ preferred = ''; candidates = @() } }
    $c = New-Candidate -P $Path -VersionHint $Version
    if ($Note) { $c.note = $Note }
    if (Test-IsEnvInternal $c.path) { throw "这是依赖特定环境的路径（env/venv/node_modules），按设计不进地图：$Path" }
    $existing = @($map.tools[$Tool].candidates | Where-Object { $_.path -eq $c.path })
    if ($existing.Count -gt 0) {
        Write-Host "这个路径已经在地图里了，跳过。" -ForegroundColor Yellow
    } else {
        $map.tools[$Tool].candidates = @($map.tools[$Tool].candidates) + @($c)
        Write-Host ("已登记：{0} → {1} [{2}] {3}" -f $Tool, $c.path, $c.source, $c.version) -ForegroundColor Green
    }
    if ($Prefer -or -not $map.tools[$Tool].preferred) { $map.tools[$Tool].preferred = $c.id }
    Save-Map $map
}

function Invoke-Update {
    $map = Read-Map
    if ($null -eq $map) { throw "还没有地图。先跑：map.ps1 scan" }
    $targets = if ($Tool) { @($Tool) } else { @($map.tools.Keys) }
    $changed = 0
    foreach ($name in $targets) {
        if (-not $map.tools.ContainsKey($name)) { continue }
        $keep = New-Object System.Collections.Generic.List[object]
        foreach ($c in @($map.tools[$name].candidates)) {
            if (-not (Test-Path -LiteralPath $c.path)) {
                Write-Host ("  路径已消失，移除：{0}" -f $c.path) -ForegroundColor Yellow
                $changed++
                continue
            }
            $fresh = Get-ExeVersion $c.path
            if ($fresh -and $fresh -ne $c.version) {
                Write-Host ("  版本变化：{0} {1} → {2}" -f $c.path, $c.version, $fresh) -ForegroundColor Yellow
                $c.version = $fresh
                $changed++
            }
            $keep.Add($c)
        }
        # 现场再找一遍，捕捉新出现的副本（例如刚装的第二份）
        # 注意：这里不要写 @($keep) —— PowerShell 5.1 对 List[object] 用 @() 会抛
        # "Argument types do not match"（见 AGENTS.md 坑 5）。管道直接接即可。
        $extra = @(Get-ToolCandidates -Name $name -RuntimeIndex @{})
        foreach ($e in $extra) {
            if (-not ($keep | Where-Object { $_.path -eq $e.path })) {
                Write-Host ("  发现新副本，登记：{0}" -f $e.path) -ForegroundColor Yellow
                $keep.Add($e)
                $changed++
            }
        }
        $map.tools[$name].candidates = $keep.ToArray()
        $map.tools[$name].preferred = (Select-Preferred -Name $name -Candidates $keep.ToArray() -DeclaredVersions @{})
    }
    Save-Map $map
    Write-Host ("更新完成，{0} 处变化。" -f $changed) -ForegroundColor Green
}

# ---------- 动作：install ----------

# portable 归档的来源。只收录"官方发布 zip/tar.gz"的常见工具；其它工具用 -Url 指定。
$Recipes = @{
    'gh'       = @{ url = 'https://github.com/cli/cli/releases/download/v{ver}/gh_{ver}_windows_amd64.zip'; exe = 'bin\gh.exe' }
    'jadx'     = @{ url = 'https://github.com/skylot/jadx/releases/download/v{ver}/jadx-{ver}.zip'; exe = 'bin\jadx.bat' }
    'ripgrep'  = @{ url = 'https://github.com/BurntSushi/ripgrep/releases/download/{ver}/ripgrep-{ver}-x86_64-pc-windows-msvc.zip'; exe = 'rg.exe' }
    'fd'       = @{ url = 'https://github.com/sharkdp/fd/releases/download/v{ver}/fd-v{ver}-x86_64-pc-windows-msvc.zip'; exe = 'fd.exe' }
}

function Invoke-Install {
    if (-not $Tool) { throw "用法：map.ps1 install <tool>@<版本>（或 install <tool> -Url <zip 直链>）" }
    $name = $Tool; $ver = $Version
    if ($Tool -match '@') { $parts = $Tool -split '@', 2; $name = $parts[0]; $ver = $parts[1] }

    $root = Get-WarehouseRoot
    $target = Join-Path (Join-Path $root $name) $ver
    $url = $Url
    $exeRel = ''
    if (-not $url) {
        if (-not $Recipes.ContainsKey($name)) {
            throw "没有 $name 的 portable 配方。请给直链：map.ps1 install $name -Url <zip 直链> -Version $ver（或用包管理器装，然后 map.ps1 add 登记）"
        }
        if (-not $ver) { throw "install $name 需要版本号：map.ps1 install $name@<版本>" }
        $url = $Recipes[$name].url -replace '\{ver\}', $ver
        $exeRel = $Recipes[$name].exe
    }
    if (-not $ver) { $ver = 'unversioned' }

    Write-Host "将把 $name $ver 装到：$target" -ForegroundColor Cyan
    Write-Host "  下载：$url" -ForegroundColor DarkGray
    if ($WhatIf) { Write-Host '（-WhatIf：到此为止）' -ForegroundColor Yellow; return }

    $tmp = Join-Path $env:TEMP ("tk-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $zip = Join-Path $tmp 'pkg.zip'
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        Expand-Archive -LiteralPath $zip -DestinationPath $target -Force

        # 归档里往往多一层同名目录，压平一层，保证 <仓库>/<工具>/<版本>/<文件> 的布局稳定
        $entries = @(Get-ChildItem -LiteralPath $target -Force)
        if ($entries.Count -eq 1 -and $entries[0].PSIsContainer) {
            $inner = $entries[0].FullName
            foreach ($f in (Get-ChildItem -LiteralPath $inner -Force)) { Move-Item -LiteralPath $f.FullName -Destination $target -Force }
            Remove-Item -LiteralPath $inner -Recurse -Force -ErrorAction SilentlyContinue
        }
        $exe = $exeRel
        if (-not $exe) {
            # 没有配方时：挑一个与工具同名的可执行文件
            $found = @(Get-ChildItem -LiteralPath $target -Recurse -File -ErrorAction SilentlyContinue |
                       Where-Object { $_.BaseName -eq $name -and $_.Extension -in @('.exe', '.cmd', '.bat', '') } |
                       Select-Object -First 1)
            if ($found.Count -gt 0) { $exe = $found[0].FullName }
        } else {
            $exe = Join-Path $target $exe
        }
        if (-not $exe -or -not (Test-Path -LiteralPath $exe)) {
            Write-Warning "装好了，但没找到 $name 的可执行文件。位置：$target（请用 map.ps1 add 手动登记）"
            return
        }
        Write-Host "  已安装：$exe" -ForegroundColor Green

        # 登记进地图，并在该工具还没有首选时设为仓库优先
        $map = Read-Map
        if ($null -eq $map) { $map = @{ schemaVersion = 1; warehouse = $root; tools = @{} } }
        if (-not $map.tools.ContainsKey($name)) { $map.tools[$name] = @{ preferred = ''; candidates = @() } }
        $c = New-Candidate -P $exe -VersionHint $ver
        $map.tools[$name].candidates = @($map.tools[$name].candidates) + @($c)
        $map.tools[$name].preferred = $c.id
        Save-Map $map
        Write-Host ("  已登记进地图并设为首选：map.ps1 find $name" ) -ForegroundColor Green
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------- 入口 ----------

switch ($Action.ToLowerInvariant()) {
    'scan'    { Invoke-Scan }
    'status'  { Invoke-Status }
    'find'    { Invoke-Find }
    'add'     { Invoke-Add }
    'update'  { Invoke-Update }
    'install' { Invoke-Install }
    default {
        Write-Host @'
toolkit-map —— 本机工具地图（给 agent 用）

  map.ps1 scan                 扫描本机，生成/刷新地图
  map.ps1 status               地图在不在、多旧、是否需要重扫
  map.ps1 find <tool>          查这个工具该用哪个（绝对路径 + 版本 + 其他候选）
  map.ps1 add <tool> -Path <p> 登记一个已有副本（不搬家）
  map.ps1 update [<tool>]      重探（路径没了 / 版本变了 / 多出新副本）
  map.ps1 install <tool>@<ver> 装进统一仓库并登记

  公共开关：-Json（机器可读）  -MapFile <路径>  -SkipScan  -WhatIf
'@
    }
}
