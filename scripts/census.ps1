#Requires -Version 5.1
<#
.SYNOPSIS
  运行时普查（census）—— 回答"这台机器上到底有哪些运行时"，而不是"PATH 解析到哪个"。

.DESCRIPTION
  要解决的根本问题：`node --version` 这类命令是**解析器**（回答"现在用哪个"），
  不是**盘点器**（回答"这台机器有哪些"）。把解析结果当成全量清单，
  就会得出"本机只有 Node 16"这种关于机器的错误结论。

  本脚本从五个来源做真正的盘点：
    1. 声明层   —— 当前目录向上的 mise.toml / .tool-versions，以及全局配置
    2. 纳管层   —— mise 管理的运行时
    3. 约定层   —— PATH 目录里"带版本号的命名 shim"（如 node22.cmd、python312.bat）
    4. 非纳管层 —— 版本管理器目录、系统安装目录、IDE 内置 JBR、conda 环境、
                   PATH 目录的兄弟目录（捕捉自定义约定）
    5. 解析层   —— 常见命令实际解析到哪个文件、什么版本、是否可用

.PARAMETER Deep
  额外对每个盘符做一次有深度上限的宽松扫描。较慢，可能耗时数分钟。

.PARAMETER DeepMaxDepth
  -Deep 模式的深度上限，默认 4。

.PARAMETER Json
  以 JSON 输出，供 agent 或其它程序消费。

.PARAMETER Timing
  附带各阶段耗时。

.PARAMETER Lang
  输出语言：zh（默认）或 en。也可以由环境变量 CENSUS_LANG 指定。
  告警的 kind 代码始终是 ASCII，不随语言变化。

.EXAMPLE
  .\census.ps1

.EXAMPLE
  .\census.ps1 -Json | Out-File census.json -Encoding utf8

.EXAMPLE
  .\census.ps1 -Lang en
  英文输出（章节标题、告警与其处置建议都是英文）。
#>
[CmdletBinding()]
param(
    [switch]$Deep,
    [int]$DeepMaxDepth = 4,
    [switch]$Json,
    [switch]$Timing,
    # 输出语言：zh（默认）或 en。也可以用环境变量 CENSUS_LANG 指定。
    [string]$Lang = ''
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'toolkit-common.ps1')

# ============================================================
# 语言与文案
# ============================================================
# 语言选择：-Lang 参数 > 环境变量 CENSUS_LANG > 默认 zh。
# 所有面向人的散文都集中在这张表里，调用处只传"事实"（facts）——
# 否则每加一条告警就会变成"只写了一种语言"的漂移，而漂移正是这个工具要治的病。
# 占位符写成 {名字}，由 T 用 facts 替换。
$script:Lang = if ($Lang) { $Lang.ToLowerInvariant() }
               elseif ($env:CENSUS_LANG) { $env:CENSUS_LANG.ToLowerInvariant() }
               else { 'zh' }
if ($script:Lang -notin @('zh', 'en')) { $script:Lang = 'zh' }

# 文案表放在同目录的 census-text.tsv（key<TAB>lang<TAB>text），与 census.sh 共用一份。
# 用 ReadAllText + 显式 UTF8 读：Windows PowerShell 5.1 的 Get-Content 默认按 ANSI 代码页读，
# 英文系统上中文会读坏。平台脚本名等差异由 census-data.tsv 提供，不再在文案表里做前缀覆盖。
# 文件缺失直接失败：静默退化成键名会让 -Json 的 message/action 全部变成 warn.XXX.message。
$script:TextPath = Join-Path $PSScriptRoot 'census-text.tsv'
if (-not [IO.File]::Exists($script:TextPath)) {
    [Console]::Error.WriteLine("[census] 找不到文案表 $($script:TextPath)（census-text.tsv 必须与 census.ps1 放在同一目录）")
    exit 2
}
$script:Text = @{}
foreach ($line in ([IO.File]::ReadAllText($script:TextPath, [Text.Encoding]::UTF8) -split "`n")) {
    $line = $line.TrimEnd("`r")
    if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }
    $parts = $line -split "`t", 3
    if ($parts.Count -lt 3) { continue }
    $key = $parts[0]
    if (-not $script:Text.ContainsKey($key)) { $script:Text[$key] = @{} }
    $script:Text[$key][$parts[1]] = $parts[2]
}
Remove-Variable -Name line, parts, key -ErrorAction SilentlyContinue

# 扫描数据（探测相对路径、候选根目录、解析命令表、约定命令名）放在同目录的 census-data.tsv，
# 与 census.sh 共用一份；每行 kind<TAB>os<TAB>value，这里取 os 为 win 或 all 的行。
# 缺表或缺必需的 kind 都直接失败：静默退化成空列表会让扫描"成功"地什么都找不到。
$script:DataPath = Join-Path $PSScriptRoot 'census-data.tsv'
if (-not [IO.File]::Exists($script:DataPath)) {
    [Console]::Error.WriteLine("[census] 找不到扫描数据表 $($script:DataPath)（census-data.tsv 必须与 census.ps1 放在同一目录）")
    exit 2
}
$script:CensusData = Read-ToolkitDataTable -Path $script:DataPath -Os 'win'
foreach ($kind in @('probe-rel', 'conda-dir', 'conda-rel', 'root', 'ide-glob', 'resolve', 'convention', 'convention-skip', 'bootstrap', 'bootstrap-refresh')) {
    if (-not $script:CensusData.ContainsKey($kind) -or $script:CensusData[$kind].Count -eq 0) {
        [Console]::Error.WriteLine("[census] 扫描数据表 $($script:DataPath) 缺少 $kind 行（os 为 win 或 all）")
        exit 2
    }
}
$script:BootstrapCmd = $script:CensusData['bootstrap'][0]
$script:RefreshCmd   = $script:CensusData['bootstrap-refresh'][0]
Remove-Variable -Name kind -ErrorAction SilentlyContinue

# 取一条文案并用 facts 替换 {占位符}。缺失的键返回键名本身，
# 这样漏翻译会立刻在输出里露出来，而不是静默变成空白。
function T {
    param([string]$Key, [hashtable]$Facts)
    $entry = $script:Text[$Key]
    if (-not $entry) { return $Key }
    $tpl = $entry[$script:Lang]
    if (-not $tpl) { $tpl = $entry['zh'] }
    if ($Facts) {
        foreach ($k in @($Facts.Keys)) {
            $tpl = $tpl.Replace("{$k}", [string]$Facts[$k])
        }
    }
    return $tpl
}

# 内部取值（位置、来源）→ 当前语言的显示名。没有对应文案时原样返回，
# 保证"没翻译"表现为可见的原值，而不是空白。
function Get-LabelText {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $entry = $script:Text["lbl.$Value"]
    if (-not $entry) { return $Value }
    if ($entry[$script:Lang]) { return $entry[$script:Lang] }
    return $Value
}

# 内部取值 → JSON 里的稳定 ASCII 键。JSON 的消费者（agent、脚本）不该依赖中文取值，
# 内部仍用中文是为了让脚本里的比较一眼可读；两者在这里做一次显式转换。
$script:StableKeys = @{
    '托管'       = 'managed'
    '宿主'       = 'host'
    '公认'       = 'standard'
    '规范根'     = 'canonical'
    '游离'       = 'stray'
    'mise'       = 'mise'
    'conda'      = 'conda'
    'scoop'      = 'scoop'
    'chocolatey' = 'chocolatey'
    'homebrew'   = 'homebrew'
    '系统安装'   = 'system'
    'IDE 内置'   = 'ide'
    '自定义位置' = 'custom'
    '版本管理器' = 'version-manager'
    '定向探测'   = 'probe'
    '(深度扫描)' = 'deep-scan'
    # 计时阶段名（JSON 的 timings 数组里用得上）
    '0. PATH 索引'          = 'path-index'
    '1. 声明层'             = 'declarations'
    '2. mise 纳管层'        = 'managed'
    '3. 约定层（命名 shim）' = 'conventions'
    '4a. 候选根目录'        = 'roots'
    '4b. 定向探测运行时'    = 'probe'
    '4c. 深度扫描（-Deep）' = 'deep-scan'
    '5. 解析层'             = 'resolution'
    '6. 汇总告警'           = 'warnings'
}
function Get-StableKey {
    param([string]$Value)
    if ($script:StableKeys.ContainsKey($Value)) { return $script:StableKeys[$Value] }
    return $Value
}

# 构造一条告警：kind 是稳定的 ASCII 代码，message/action 跟随语言，detail 是事实（路径、版本）。
function New-Warning {
    param([string]$Kind, [string]$Tool, [hashtable]$Facts, [string]$Detail = '')
    if ($null -eq $Facts) { $Facts = @{} }
    if (-not $Facts.ContainsKey('bootstrap')) { $Facts['bootstrap'] = $script:BootstrapCmd }
    if (-not $Facts.ContainsKey('refresh'))   { $Facts['refresh']   = $script:RefreshCmd }
    return [pscustomobject]@{
        kind    = $Kind
        tool    = $Tool
        message = (T "warn.$Kind.message" $Facts)
        action  = (T "warn.$Kind.action"  $Facts)
        detail  = $Detail
    }
}

# ============================================================
# 通用工具函数
# ============================================================

# 把 PATH 拆成干净的目录列表：去掉引号、尾部反斜杠，并去重。
# PATH 里常见的脏数据（带引号的条目、重复条目）会让后续所有比较失真。
function Get-PathDirs {
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $out  = New-Object System.Collections.Generic.List[string]
    foreach ($raw in ($env:PATH -split ';')) {
        $d = "$raw".Trim().Trim('"').TrimEnd('\')
        if ([string]::IsNullOrWhiteSpace($d)) { continue }
        if ($seen.Add($d)) { $out.Add($d) }
    }
    return $out
}

# ---------- 高速文件系统原语 ----------
# PowerShell 的 Get-ChildItem 会为每个条目构造完整的 FileInfo 对象，在批量探测时
# 是主要瓶颈；带通配符的 -Path 还会触发深度枚举。下面这几个包装直接用 .NET 的
# 枚举 API，只返回字符串，实测快一到两个数量级。

function Get-SubDirectories {
    param([string]$Dir)
    # 手动枚举而不是写 @(EnumerateDirectories(...))：在 Windows PowerShell 5.1 上
    # @() 作用于 .NET 的惰性可枚举对象行为不稳定，而且这里还需要容忍枚举中途的权限错误，
    # 保留已经拿到的部分结果。
    $out = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($d in [System.IO.Directory]::EnumerateDirectories($Dir)) { $out.Add($d) }
    } catch { }
    return $out.ToArray()
}

function Test-FileQuick {
    param([string]$Path)
    try { return [System.IO.File]::Exists($Path) } catch { return $false }
}

function Test-DirQuick {
    param([string]$Path)
    try { return [System.IO.Directory]::Exists($Path) } catch { return $false }
}

# 文件长度，用于识别 0 字节的商店别名存根；读取失败返回 -1。
function Get-FileLength {
    param([string]$Path)
    try { return ([System.IO.FileInfo]$Path).Length } catch { return -1 }
}

# 运行一个可执行文件并只取输出的第一行，失败返回空串。
# 真正的执行在 toolkit-common.ps1 的 Invoke-ToolkitProbe（.NET Process，同时读两个流、20 秒超时、
# 进程内缓存与计数）。不用 PowerShell 的原生调用：java -version 把版本写到 stderr，
# 在 $ErrorActionPreference='SilentlyContinue' 下 2>&1 合并进来的 stderr 会被整体丢弃。
# 口径：不看退出码，stdout 为空时取 stderr 的第一行非空行。
# 注意：scan-guards.ps1 会把本函数单独抽出来运行，名字和位置都不要动；
# 护栏必须先于 Test-FileQuick（scan-guards 用它检测 shim 有没有被交给执行器）。
function Get-FirstLine {
    param([string]$Exe, [string[]]$Arguments)
    # 不只看文件本身：npm.cmd 一类启动器会再去执行 PATH 上的 node（见 Test-ToolkitProbeSafe）
    if (-not (Test-ToolkitProbeSafe $Exe)) { return '' }
    if (-not (Test-FileQuick $Exe)) { return '' }
    $probe = Invoke-ToolkitProbe -Exe $Exe -Arguments $Arguments
    if (-not $probe.ok) { return '' }
    $text = $probe.stdout
    if ([string]::IsNullOrWhiteSpace($text)) { $text = $probe.stderr }
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    $line = $text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1
    return "$line".Trim()
}

# 运行一个命令并在超时后放弃，返回 stdout 文本；超时或失败返回空串。
# 为什么需要它：census 是只读诊断工具，不能跟着别的进程一起卡死。实测踩过——
# mise 会因为陈旧的锁或联网自检无限等待，而 census 里的 `mise ls` 就会一直挂着。
# 执行器会把 MISE_AUTO_UPDATE 等关掉。-NoCache：mise ls 的输出取决于配置而不是 mise 本身，
# 不能按可执行文件的大小和修改时间缓存。
function Invoke-CaptureWithTimeout {
    param([string]$Exe, [string[]]$Arguments, [int]$TimeoutMs = 20000)
    $cmd = Get-Command $Exe -ErrorAction SilentlyContinue
    if (-not $cmd) { return '' }
    if (-not (Test-ToolkitProbeSafe $cmd.Source)) { return '' }
    $probe = Invoke-ToolkitProbe -Exe $cmd.Source -Arguments $Arguments -TimeoutMs $TimeoutMs -NoCache
    if (-not $probe.ok) { return '' }
    return $probe.stdout
}

# 判断文件是不是"真的可执行"。
# 这里只做静态判断（存在、不是目录、长度大于 0），用于筛选"运行时二进制"这类文件。
# 注意它不能用来判断 WindowsApps 下的商店应用别名——见 Test-AliasExecutable。
function Test-RealExecutable {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $false }
    if ($item.PSIsContainer) { return $false }
    if ($item.Length -eq 0) { return $false }
    return $true
}

# 判断 0 字节文件是不是"能用的应用执行别名"。
# 实测（本机 Windows 11，2026-09）：WindowsApps 下的别名统一是 0 字节的 ReparsePoint，
# 能不能用完全取决于目标应用装没装：
#     pwsh.exe    -> 输出 7.6.6，可用
#     winget.exe  -> 输出 v1.29.290，可用
#     python3.exe -> 无输出、退出码 9009（没装商店版 Python），不可用
# 所以"0 字节 ⇒ 不可用"是错的判据，只能真的执行一次版本来确认。
function Test-AliasExecutable {
    param([string]$Path)
    if (-not (Test-FileQuick $Path)) { return $false }
    if (Get-FirstLine $Path @('--version')) { return $true }
    return [bool](Get-FirstLine $Path @('-version'))
}

# 把各种工具输出版本号的形式统一成裸版本号。
function Get-NormalizedVersion {
    param([string]$Tool, [string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return '' }
    switch ($Tool) {
        { $_ -in 'powershell', 'pwsh' } {
            $m = [regex]::Match($Raw, '([0-9]+\.[0-9]+(?:\.[0-9]+)*)')
            if ($m.Success) { return $m.Groups[1].Value }
            return $Raw
        }
        'java' {
            # openjdk version "25.0.3" 2026-04-21  ->  25.0.3
            $m = [regex]::Match($Raw, 'version\s+"([^"]+)"')
            if ($m.Success) { return $m.Groups[1].Value }
            # java version "1.8.0_144" 已经能被上面匹配
            return $Raw
        }
        'node' {
            return ($Raw -replace '^v', '').Trim()
        }
        'python' {
            # "Python 3.12.10" -> "3.12.10"
            $m = [regex]::Match($Raw, 'Python\s+([0-9][^\s]*)')
            if ($m.Success) { return $m.Groups[1].Value }
            return $Raw
        }
        'pip' {
            # "pip 25.0.1 from C:\...\site-packages\pip (python 3.12)" -> "25.0.1"
            $m = [regex]::Match($Raw, 'pip\s+([0-9][^\s]*)')
            if ($m.Success) { return $m.Groups[1].Value }
            return $Raw
        }
        default {
            # 其余工具（uv / mise / go / cargo / deno 等）从输出里抓第一个版本号
            $m = [regex]::Match($Raw, '([0-9]+\.[0-9]+(?:\.[0-9]+)*)')
            if ($m.Success) { return $m.Groups[1].Value }
            return $Raw
        }
    }
}

# 探测某个运行时可执行文件的版本。
# 同一个文件不会被反复启动（java -version 启动开销不小）：缓存在统一执行器 Invoke-ToolkitProbe 里，
# 按 路径|长度|修改时间|参数 记，这里不再另设一层。
function Get-RuntimeVersion {
    param([string]$Tool, [string]$ExePath)
    if (Test-ToolkitShimPath $ExePath) { return '' }

    $raw = ''
    switch ($Tool) {
        'node'   { $raw = Get-FirstLine $ExePath @('--version') }
        'python' { $raw = Get-FirstLine $ExePath @('--version') }
        'pip'    { $raw = Get-FirstLine $ExePath @('--version') }
        'java'   { $raw = Get-FirstLine $ExePath @('-version') }
        { $_ -in 'powershell', 'pwsh' } {
            $raw = Get-FirstLine $ExePath @('-NoProfile', '-NonInteractive', '-Command', '$PSVersionTable.PSVersion.ToString()')
        }
        default  {
            # 绝大多数工具支持 --version；个别只认 -version 或裸 version，逐个兜底
            $raw = Get-FirstLine $ExePath @('--version')
            if (-not $raw) { $raw = Get-FirstLine $ExePath @('-version') }
            if (-not $raw) { $raw = Get-FirstLine $ExePath @('version') }
        }
    }
    $ver = Get-NormalizedVersion -Tool $Tool -Raw $raw
    return $ver
}

# 有深度上限的目录遍历。只在显式要求 -Deep 时使用，因为代价较高。
# MaxDirs 是硬边界，保证在巨大目录树上不会失控。
function Find-RuntimeExecutables {
    param(
        [string]$Root,
        [int]$MaxDepth = 4,
        [int]$MaxDirs = 30000,
        [string[]]$FileNames = @('node.exe', 'python.exe', 'java.exe')
    )
    $results = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Root)) { return $results }

    # 这些目录名在实践中几乎不会包含"需要纳管的运行时"，但体积极大
    $skip = @(
        'node_modules', '.git', '.cache', '.gradle', '.m2', '.nuget', 'Cache', 'cache',
        'Windows', '$Recycle.Bin', 'System Volume Information', 'Temp', 'tmp',
        '.pnpm-store', '.yarn', 'pkgs', 'site-packages', 'dist-packages',
        'conda-meta', 'include', 'share', 'obj', 'dist', 'build', 'target', 'vendor'
    )
    $stack = New-Object System.Collections.Stack
    $stack.Push(@($Root, 0))
    $visited = 0

    while ($stack.Count -gt 0) {
        if ($visited -ge $MaxDirs) { break }
        $cur = $stack.Pop()
        $dir = $cur[0]
        $depth = $cur[1]
        $visited++

        foreach ($name in $FileNames) {
            $candidate = Join-Path $dir $name
            if (Test-FileQuick $candidate) {
                $results.Add($candidate)
            }
        }
        if ($depth -ge $MaxDepth) { continue }

        foreach ($sub in (Get-SubDirectories $dir)) {
            $subName = [System.IO.Path]::GetFileName($sub)
            if ($skip -contains $subName) { continue }
            $stack.Push(@($sub, $depth + 1))
        }
    }
    return $results
}

# 把一个可执行文件路径转成一条运行时记录；无法识别的返回 $null。
# 集中在这里，保证定向探测和深度扫描产出的记录结构完全一致。
function ConvertTo-RuntimeRecord {
    param([string]$ExePath, [string]$Root = '', [string]$Pattern = '')
    $real = $ExePath
    try { $real = (Resolve-Path -LiteralPath $ExePath).Path } catch { }

    $exeName = [System.IO.Path]::GetFileName($real)
    $tool = Get-ToolFromExe $exeName
    if (-not $tool) { return $null }

    return [pscustomobject]@{
        tool      = $tool
        version   = (Get-RuntimeVersion -Tool $tool -ExePath $real)
        path      = $real
        root      = $Root
        source    = (Get-InstallSource $real)
        placement = (Get-Placement $real)   # 托管 / 公认 / 规范根 / 游离
        managed   = (Test-IsMiseManaged $real)
        real      = (Test-RealExecutable $real)
        pattern   = $Pattern
    }
}

# 计时收集器。用普通变量放在脚本作用域，Measure-Phase 直接往里追加。
# 刻意不用 $script: 前缀——在脚本顶层和函数内部对它的解析行为容易产生歧义。
$TimingItems = New-Object System.Collections.Generic.List[object]
function Measure-Phase {
    param([string]$Name, [scriptblock]$Body)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = & $Body
    $sw.Stop()
    $TimingItems.Add([pscustomobject]@{ phase = $Name; ms = [int]$sw.Elapsed.TotalMilliseconds }) | Out-Null
    # 用逗号包一层再返回，避免 PowerShell 展开数组；
    # 空结果统一成空数组，否则调用方会拿到 @($null) 这种长度为 1 的假结果。
    if ($null -eq $result) { return ,@() }
    return ,$result
}

# 从 shim 脚本内容里提取它真正指向的可执行文件路径。
# 例如 node22.cmd 里写死的那条 "C:\...\tools\node22\node.exe"。
function Get-ShimTarget {
    param([string]$ShimPath)
    $text = ''
    try {
        # 只读前 40 行足够发现目标路径；-Raw 与 -TotalCount 互斥，这里手动拼接
        $lines = Get-Content -LiteralPath $ShimPath -TotalCount 40 -ErrorAction SilentlyContinue
        if ($lines) { $text = ($lines -join "`n") }
    } catch { return '' }
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }

    # 抓第一个看起来像绝对路径、且以运行时 exe 结尾的字符串
    $m = [regex]::Matches($text, '[A-Za-z]:\\[^"''\r\n]*?\.(exe|cmd|bat|ps1)')
    foreach ($hit in $m) {
        $p = $hit.Value.Trim()
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    return ''
}

# 按 exe 文件名推断它属于哪个运行时。
function Get-ToolFromExe {
    param([string]$ExeName)
    switch ($ExeName.ToLowerInvariant()) {
        'node.exe'   { return 'node' }
        'python.exe' { return 'python' }
        'java.exe'   { return 'java' }
        'javac.exe'  { return 'java' }
        default      { return '' }
    }
}

# 判断某个路径是否属于 mise 的纳管目录。
function Test-IsMiseManaged {
    param([string]$Path)
    return ($Path -match '\\mise\\(installs|shims)\\' -or $Path -match '/mise/(installs|shims)/')
}

# 判断"解析到的实际版本"是否已经满足声明里的要求。
# 声明里可能是 "3.12"、"22"，也可能是一串（TOML 数组去掉括号后的 "22, 20"）；
# 实际版本可能是 "3.12.10" / "22.23.2" / "1.8.0_144"。
# 规则：逐段比数字前缀——声明 "3.12" 满足 "3.12.10"，声明 "22" 满足 "22.23.2"；
# 带发行版前缀的声明（temurin-21）先剥掉前缀再比。声明是一串时任意一条满足即可。
# 判断不出来的一律当作满足（latest / stable / 空值）：宁可漏报，也不要在用户本来
# 就满足声明时喊"版本不对"——那种告警按它自己的建议改完也不会消失。
function Test-VersionSatisfies {
    param([string]$Version, [string]$Wanted)
    if ([string]::IsNullOrWhiteSpace($Wanted)) { return $true }
    if ([string]::IsNullOrWhiteSpace($Version)) { return $false }
    # 数字段按去掉前导零的字符串比较，日期型构建号等超长数字不会让 [int] 溢出。
    $actual = @([regex]::Matches($Version, '\d+') | ForEach-Object { ConvertTo-ToolkitVersionSegment $_.Value })
    if ($actual.Count -eq 0) { return $true }
    foreach ($one in ($Wanted -split '[,;]')) {
        $w = "$one".Trim() -replace '"', ''
        if ([string]::IsNullOrWhiteSpace($w)) { continue }
        if ($w -match '^(?i)(latest|stable|lts|system|any|\*)$') { return $true }
        $w = $w -replace '^[A-Za-z][A-Za-z0-9]*[-_]', ''      # temurin-21 -> 21
        $want = @([regex]::Matches($w, '\d+') | ForEach-Object { ConvertTo-ToolkitVersionSegment $_.Value })
        if ($want.Count -eq 0) { return $true }
        $n = [Math]::Min($want.Count, $actual.Count)
        $ok = $true
        for ($i = 0; $i -lt $n; $i++) { if ($want[$i] -ne $actual[$i]) { $ok = $false; break } }
        if ($ok) { return $true }
    }
    return $false
}

# ---------- 规范根与位置基准 ----------
# 规范根：非托管的手装运行时应该放在这里，按 <工具>/<版本>/ 排列。
# 它不是一个强制约束，而是给 census 一个判断"位置是否规范"的基准。
# 新机器由 bootstrap 建立；存量机器只检查、不迁移——搬动已有运行时的风险
# （路径被项目配置、IDE 设置、CI 脚本写死）远大于收益。

$script:ToolsRoot = if ($env:TOOLCHAIN_ROOT) { $env:TOOLCHAIN_ROOT }
                    elseif ($env:USERPROFILE)  { Join-Path $env:USERPROFILE 'toolchains' }
                    else                       { Join-Path $HOME 'toolchains' }

# 操作系统与发行版的公认安装位置。落在这些位置下的运行时不算游离。
$script:StandardRoots = @()
if ($env:USERPROFILE) {
    $script:StandardRoots += 'C:\Program Files'
    $script:StandardRoots += 'C:\Program Files (x86)'
    $script:StandardRoots += 'C:\ProgramData'
    $script:StandardRoots += (Join-Path $env:LOCALAPPDATA 'Programs')
}
if ($env:WINDIR) { $script:StandardRoots += $env:WINDIR }
$script:StandardRoots += @('/usr', '/usr/local', '/opt', '/Library', '/Applications', "$HOME/Applications")
$script:StandardRoots = @($script:StandardRoots | Where-Object { $_ })

# 把路径规范化成统一形式再比较，避免斜杠方向和大小写造成误判。
function Get-NormalizedPath {
    param([string]$Path)
    $n = ($Path -replace '/', '\')
    return $n.TrimEnd('\').ToLowerInvariant()
}

# 判断 $Path 是否位于 $Root 之下。加尾部分隔符，避免 /opt 误匹配 /optional。
function Test-UnderRoot {
    param([string]$Path, [string]$Root)
    if (-not $Root) { return $false }
    $p = Get-NormalizedPath $Path
    $r = (Get-NormalizedPath $Root) + '\'
    return $p.StartsWith($r)
}

# 判断一个运行时安装的位置属于哪一类：
#   宿主   —— IDE 捆绑的运行时（jbr 等），由 IDE 自己管理，不是用户手工放的
#   托管   —— mise / nvm / fnm / volta / asdf / pyenv / conda / scoop / chocolatey / homebrew
#   公认   —— 操作系统或发行版的标准安装目录
#   规范根 —— 本套件约定的 <工具>/<版本>/ 根
#   游离   —— 以上都不是：手工放在某处，且没有任何机制记得它
#             位置不规范本身不致命，真正的问题是它只靠 PATH 被找到，
#             PATH 一变就没人知道它在哪里了。
function Get-Placement {
    param([string]$Path)
    $p = Get-NormalizedPath $Path

    # 先判宿主：IDE 捆绑的 JBR 里有完整 JDK，但它属于 IDE 的一部分，
    # 记进"游离"会把真正需要登记的东西淹没在噪音里。
    if ($p -match '\\jbr\\' -or
        $p -match '\\(pycharm|intellij|webstorm|goland|jetbrains|android[\\ ]studio|idea)\\') { return '宿主' }

    if (Test-IsMiseManaged $Path) { return '托管' }
    if ($p -match '\\(nvm|fnm|nvs|volta|asdf|pyenv|scoop|chocolatey|homebrew|cellar)\\' -or
        $p -match '\\envs\\' -or
        $p -match '\\(mini|ana)conda') { return '托管' }

    foreach ($r in $script:StandardRoots) {
        if (Test-UnderRoot $Path $r) { return '公认' }
    }
    if (Test-UnderRoot $Path $script:ToolsRoot) { return '规范根' }

    return '游离'
}

# ============================================================
# 第 1 阶段：声明层
# ============================================================

function Get-Declarations {
    # tools 原本是哈希表，键的顺序每次运行都可能不同（JSON、文本和告警的顺序跟着乱）。
    # 这里换成按工具名（序数比较）排好的有序字典；只用到 .Keys 与下标，行为不变。
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($d in @(Get-ToolkitDeclarations)) {
        $keys = [string[]]@($d.tools.Keys)
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        $sorted = [ordered]@{}
        foreach ($k in $keys) { $sorted[$k] = $d.tools[$k] }
        $d.tools = $sorted
        $out.Add($d)
    }
    return $out.ToArray()
}

# 尽力解析声明文件里的"工具 -> 期望版本"。
# .tool-versions 是 "nodejs 20.11.0" 这种极简格式；mise.toml 读 [tools] 段。
# 这里是尽力而为的轻量解析，不追求覆盖 TOML 全部语法。
function Read-DeclaredTools {
    param([string]$Path)
    return (Read-ToolkitDeclaredTools $Path).tools
}

# 取出某个 [section] 里的键名列表（极简扫描，够用来比较"声明了哪些工具"）。
# 只认 section 内的 "键 = 值" 行，跳过注释；不解析数组/表的嵌套，不追求 TOML 完备。
function Get-TomlSectionKeys {
    param([string]$Path, [string]$Section)
    $keys = New-Object System.Collections.Generic.List[string]
    $inSection = $false
    foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        $t = "$line".Trim()
        if ($t -match '^\[') { $inSection = ($t -eq "[$Section]"); continue }
        if (-not $inSection) { continue }
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $m = [regex]::Match($t, '^([A-Za-z0-9_\-\.]+)\s*=')
        if ($m.Success) { $keys.Add($m.Groups[1].Value) }
    }
    return $keys
}

# ============================================================
# 第 2 阶段：mise 纳管层
# ============================================================

function Get-MiseManaged {
    $records = New-Object System.Collections.Generic.List[object]
    $miseCmd = Get-Command mise -ErrorAction SilentlyContinue
    if (-not $miseCmd) {
        return @{ available = $false; records = $records; raw = '' }
    }

    $raw = ''
    try {
        # 带超时 + 关掉联网自检：mise 卡住时不能把 census 一起挂住
        $raw = (Invoke-CaptureWithTimeout -Exe 'mise' -Arguments @('ls', '--json') -TimeoutMs 20000).Trim()
    } catch { $raw = '' }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{ available = $true; records = $records; raw = '' }
    }

    try {
        $data = $raw | ConvertFrom-Json
    } catch {
        return @{ available = $true; records = $records; raw = $raw }
    }

    foreach ($toolProp in $data.PSObject.Properties) {
        $toolName = $toolProp.Name
        foreach ($entry in $toolProp.Value) {
            $installed = $true
            if ($entry.PSObject.Properties.Name -contains 'installed') { $installed = [bool]$entry.installed }
            if (-not $installed) { continue }

            $ver = ''
            if ($entry.PSObject.Properties.Name -contains 'version') { $ver = "$($entry.version)" }

            $installPath = ''
            if ($entry.PSObject.Properties.Name -contains 'install_path') { $installPath = "$($entry.install_path)" }

            $records.Add([pscustomobject]@{
                tool        = $toolName
                version     = $ver
                installPath = $installPath
                requested   = $(if ($entry.PSObject.Properties.Name -contains 'requested_version') { "$($entry.requested_version)" } else { '' })
                source      = 'mise'
                managed     = $true
            })
        }
    }
    return @{ available = $true; records = $records; raw = $raw }
}

# ============================================================
# 第 3 阶段：约定层（带版本号的命名 shim）
# ============================================================

function Get-ConventionShims {
    param([string[]]$PathDirs)
    $records = New-Object System.Collections.Generic.List[object]

    # 形如 node22 / node-22 / python312 / java8 / go1.22 的可执行文件命名约定；命令名来自 census-data.tsv
    $pattern = '^(' + ($script:CensusData['convention'] -join '|') + ')(?:[-_]?v?)(\d+(?:\.\d+){0,3})$'
    $skipPattern = '^(' + ($script:CensusData['convention-skip'] -join '|') + ')[23](\.\d+){0,2}$'

    $exts = @('.exe', '.cmd', '.bat', '.ps1', '.sh', '')

    foreach ($dir in $PathDirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($file in (Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue)) {
            $base = $file.Name
            foreach ($ext in $exts) {
                if ($ext -and $base.EndsWith($ext, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $base = $base.Substring(0, $base.Length - $ext.Length)
                    break
                }
            }
            $m = [regex]::Match($base, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $m.Success) { continue }

            # python2 / python3 / pip3 / python3.12 这类是跨平台公认的名字，
            # 不属于"只存在于文件名里的本地私有约定"，不该被当作约定上报
            if ($base -match $skipPattern) { continue }

            # 0 字节的商店别名存根不可用，已由 STUB 告警单独覆盖，这里不重复报
            if (-not (Test-RealExecutable $file.FullName)) { continue }

            $tool = $m.Groups[1].Value.ToLowerInvariant()
            $declaredVer = $m.Groups[2].Value

            # shim 可能是脚本，需要找出它真正调用的目标
            $target = $file.FullName
            $actualVer = ''
            if ($file.Extension -match '^\.(cmd|bat|ps1|sh)$' -or $file.Extension -eq '') {
                $resolved = Get-ShimTarget $file.FullName
                if ($resolved) { $target = $resolved }
            }
            $probeTool = $tool
            if ($tool -in @('npm', 'npx', 'pnpm', 'yarn')) { $probeTool = 'node' }
            if ($tool -in @('javac', 'mvn', 'gradle'))       { $probeTool = 'java' }
            if ($tool -in @('pip', 'pip3'))                   { $probeTool = 'python' }
            $actualVer = Get-RuntimeVersion -Tool $probeTool -ExePath $target

            $records.Add([pscustomobject]@{
                shim        = $file.FullName
                shimName    = $file.Name
                tool        = $tool
                nameVersion = $declaredVer     # 从文件名读出的版本
                target      = $target          # shim 真正指向的可执行文件
                targetOk    = (Test-RealExecutable $target)
                actualVersion = $actualVer
                source      = 'convention'
                managed     = $false
            })
        }
    }
    return $records
}

# ============================================================
# 第 4 阶段：非纳管层（定向探测已知安装位置）
# ============================================================

# 相对于某个候选根目录要探测的可执行文件位置。
# 这里编码的是"运行时通常住在磁盘的什么位置"这类经验：
#     <root>\node.exe              直接放在安装根目录
#     <root>\bin\java.exe          放在 bin 子目录
#     <root>\jbr\bin\java.exe      IDE 内置运行时（JetBrains 的 JBR 里有完整 JDK）
#     <root>\Scripts\python.exe    Windows 虚拟环境
# 只做"存在性检查"而不是列目录，因为一次 stat 比一次目录枚举便宜得多。
# 清单在 census-data.tsv（kind = probe-rel）。
$script:ProbeRelatives = $script:CensusData['probe-rel'].ToArray()

# 判断一个运行时安装来自哪个渠道，用于报告里区分来源。
function Get-InstallSource {
    param([string]$Path)
    $p = $Path.ToLowerInvariant()
    if ($p -match '\\mise\\')                                                    { return 'mise' }
    if ($p -match '\\envs\\' -or $p -match '\\(mini|ana)conda')                  { return 'conda' }
    if ($p -match '\\jbr\\' -or $p -match '(pycharm|intellij|jetbrains|android[\\ ]studio)') { return 'IDE 内置' }
    if ($p -match '\\(nvm|fnm|nvs|volta|asdf|pyenv)\b')                          { return '版本管理器' }
    if ($p -match '\\scoop\\')                                                    { return 'scoop' }
    if ($p -match '\\chocolatey\\')                                               { return 'chocolatey' }
    if ($p -match '^c:\\program files')                                           { return '系统安装' }
    return '自定义位置'
}

# census-data.tsv 里根目录的 {占位符} 换成同名环境变量；未设置时展开成空串
# （与原来直接写 "$env:APPDATA\nvm" 的行为一致，展开出的相对路径会被后面的存在性检查过滤掉）。
function Expand-CensusDataPath {
    param([string]$Value)
    return [regex]::Replace($Value, '\{([A-Za-z_][A-Za-z0-9_]*)\}', { param($m) "$([Environment]::GetEnvironmentVariable($m.Groups[1].Value))" })
}

function Get-CandidateRoots {
    $roots = @()

    # --- 静态候选根：版本管理器、conda、系统安装、IDE 安装目录（census-data.tsv，kind = root）---
    foreach ($root in $script:CensusData['root']) { $roots += (Expand-CensusDataPath $root) }

    # --- IDE 内置运行时（JetBrains 的 jbr 里带完整 JDK，最容易被忽略）：每个盘符根下按名称找 ---
    $idePatterns = $script:CensusData['ide-glob'].ToArray()
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Root -match '^[A-Z]:\\$' })) {
        foreach ($pat in $idePatterns) {
            foreach ($hit in (Get-ChildItem -Path (Join-Path $drive.Root $pat) -Directory -ErrorAction SilentlyContinue)) {
                $roots += $hit.FullName
            }
        }
    }

    # --- 自定义目录：PATH 上的目录及其父目录 ---
    # PATH 目录本身可能就是一个运行时安装（如 <系统盘>:\nodejs）；
    # 它的父目录则能捕捉 "tools\bin 在 PATH 上、运行时实际在 tools\node22" 这类自定义约定。
    # 刻意排除盘符根目录，否则会退化成全盘扫描（实测慢上百倍）。
    foreach ($dir in (Get-PathDirs)) {
        if ($dir -notmatch '^[A-Za-z]:$') { $roots += $dir }
        $parent = Split-Path $dir -Parent
        if (-not $parent) { continue }
        if ($parent -match '^[A-Za-z]:\\?$') { continue }
        if (Test-DirQuick $parent) { $roots += $parent }
    }

    return ,@($roots | Where-Object { $_ -and (Test-DirQuick $_) } | Sort-Object -Unique)
}

function Get-UnmanagedRecords {
    param([string[]]$Roots)
    $records = New-Object System.Collections.Generic.List[object]
    $seen    = New-Object System.Collections.Generic.HashSet[string]

    # 内部小工具：探测一个具体路径，命中就登记一条记录。
    # 直接读写外层变量，避免为每条记录走一遍管道。
    $tryAdd = {
        param([string]$Candidate, [string]$Root)
        if (-not (Test-FileQuick $Candidate)) { return }
        $real = $Candidate
        try { $real = (Resolve-Path -LiteralPath $Candidate).Path } catch { }
        if (-not $seen.Add($real.ToLowerInvariant())) { return }
        $rec = ConvertTo-RuntimeRecord -ExePath $real -Root $Root -Pattern '定向探测'
        if ($rec) { $records.Add($rec) }
    }

    foreach ($root in $Roots) {
        # 第 1 层：根目录本身
        foreach ($rel in $script:ProbeRelatives) {
            & $tryAdd (Join-Path $root $rel) $root
        }

        # 第 2 层：直接子目录。覆盖两类布局——
        #     nvm\v20.11.0\node.exe                       版本号目录
        #     <安装位置>\PyCharm 2026.2\jbr\bin\java.exe    IDE 安装目录
        foreach ($sub in (Get-SubDirectories $root)) {
            foreach ($rel in $script:ProbeRelatives) {
                & $tryAdd (Join-Path $sub $rel) $root
            }
        }

        # conda 专门处理：环境位于 envs\<环境名>\ 下，解释器可能在根或 Scripts 里
        foreach ($envDirName in $script:CensusData['conda-dir']) {
            $envRoot = Join-Path $root $envDirName
            if (-not (Test-DirQuick $envRoot)) { continue }
            foreach ($env in (Get-SubDirectories $envRoot)) {
                foreach ($rel in $script:CensusData['conda-rel']) { & $tryAdd (Join-Path $env $rel) $root }
            }
        }
    }
    return $records
}

# ============================================================
# 第 5 阶段：解析层（PATH 实际把命令解析到哪）
# ============================================================

# 建立 PATH 索引：一次性枚举 PATH 上每个目录里的文件名，之后所有命令解析都退化成
# 字典查询。比逐命令调用 Get-Command -All 快很多——后者在 Windows 上会顺带解析
# 应用执行别名，实测 21 个命令要十几秒。
function Get-PathIndex {
    $index = @{}                      # 文件名(小写) -> 命中列表
    $dirs  = Get-PathDirs
    for ($i = 0; $i -lt $dirs.Count; $i++) {
        $dir = $dirs[$i]
        if (-not (Test-DirQuick $dir)) { continue }
        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($dir)) {
                $leaf = [System.IO.Path]::GetFileName($f).ToLowerInvariant()
                if (-not $index.ContainsKey($leaf)) {
                    $index[$leaf] = New-Object System.Collections.Generic.List[object]
                }
                $index[$leaf].Add([pscustomobject]@{ path = $f; dirOrder = $i })
            }
        } catch {
            # 权限不足等情况下保留已索引的部分，不影响其它目录
        }
    }
    return @{ index = $index; dirCount = $dirs.Count }
}

# 按 Windows 的真实解析顺序查找命令：外层走 PATH 目录顺序，内层走 PATHEXT 扩展名顺序。
# 这个顺序很关键——同一目录下先试 .exe 还是 .cmd 会得到不同结果。
function Resolve-CommandInPath {
    param([hashtable]$Index, [string]$Name, [string[]]$Exts, [int]$DirCount)
    $result = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $DirCount; $i++) {
        foreach ($ext in $Exts) {
            $key = ($Name + $ext).ToLowerInvariant()
            if (-not $Index.ContainsKey($key)) { continue }
            foreach ($hit in $Index[$key]) {
                if ($hit.dirOrder -eq $i) { $result.Add($hit.path) }
            }
        }
    }
    return $result
}

function Get-Resolution {
    param([hashtable]$PathIndex, [int]$DirCount, [string[]]$ExtraCommands = @())

    # 默认解析的命令表在 census-data.tsv（kind = resolve）。除了语言运行时，还有环境能力类命令：
    # pwsh 决定 mise 能不能按项目自动切换版本，winget 是 bootstrap 的首选安装来源，
    # docker 决定 .sh 脚本在这台机器上能否被验证。
    # 注意 scan-guards.ps1 会把本函数单独抽出来运行，它自己加载同一份数据表。
    # 用 ToArray()：Windows PowerShell 5.1 上 @() 作用于泛型 List 可能抛 "Argument types do not match"。
    $probeList = $script:CensusData['resolve'].ToArray()

    # 声明里点名的工具也要解析。这个套件面向的是【所有工具】，不是只认语言的运行时：
    # 声明里写了 jadx / nmap / ffmpeg / jq，就应该能看到它们解析到哪、装了没有。
    # 上面那张固定表只是"默认值得看一眼的常见命令"，不是能力边界。
    foreach ($extra in $ExtraCommands) {
        if ($extra -and ($probeList -notcontains $extra)) { $probeList += $extra }
    }

    # PATHEXT 决定同一目录下各扩展名的尝试顺序，末尾补一个空串表示无扩展名的文件
    $exts = @($env:PATHEXT -split ';' | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
    if ($exts.Count -eq 0) { $exts = @('.com', '.exe', '.bat', '.cmd', '.ps1') }
    $exts += ''

    $records = New-Object System.Collections.Generic.List[object]

    foreach ($name in $probeList) {
        $pathList = @(Resolve-CommandInPath -Index $PathIndex -Name $name -Exts $exts -DirCount $DirCount)
        if ($pathList.Count -eq 0) { continue }

        $first = $pathList[0]
        # 0 字节在这里只意味着"可疑"，不能直接判死：pwsh / winget 这类应用执行别名也是
        # 0 字节，但目标应用已安装时能正常执行；真正坏的存根（未安装的商店版 Python）
        # 会在探测时无输出、退出码 9009。所以对 0 字节文件补一次实测。
        $usable = $true
        if ((Get-FileLength $first) -eq 0) {
            $usable = Test-AliasExecutable -Path $first
        }

        # 把命令名映射到它的"宿主运行时"，这样才能问出版本号。
        # 例如 npm 的版本必须问 node，javac 必须问 java。
        if ($name -in @('npm', 'npx', 'pnpm', 'yarn'))    { $probeTool = 'node' }
        elseif ($name -in @('javac', 'mvn', 'gradle'))    { $probeTool = 'java' }
        elseif ($name -eq 'py' -or $name -like 'python*') { $probeTool = 'python' }
        else                                              { $probeTool = $name }

        $ver = ''
        $shim = Test-ToolkitShimPath $first
        if ($probeTool -and $usable -and -not $shim) { $ver = Get-RuntimeVersion -Tool $probeTool -ExePath $first }

        $records.Add([pscustomobject]@{
            command    = $name
            resolvesTo = $first
            version    = $ver
            allHits    = $pathList
            hitCount   = $pathList.Count
            stub       = (-not $usable)   # true 表示解析到不可执行的文件
            usable     = $usable
            isShim     = $shim
        })
    }
    return $records
}

# ============================================================
# 汇总与告警
# ============================================================

function Get-Warnings {
    param($Managed, $Conventions, $Unmanaged, $Resolution, $Declarations)

    $warnings = New-Object System.Collections.Generic.List[object]

    # --- 1) 命令解析到 0 字节存根（存在但不可用）---
    foreach ($r in $Resolution) {
        if ($r.stub -or -not $r.usable) {
            $warnings.Add((New-Warning -Kind 'STUB' -Tool $r.command -Facts @{
                command = $r.command
                path    = $r.resolvesTo
            } -Detail $r.resolvesTo))
        }
    }

    # --- 2) 同一运行时多版本共存，但 PATH 只暴露一个 ---
    $byTool = @{}
    foreach ($r in $Unmanaged) {
        # 只统计真正可执行的运行时；0 字节存根不算"被遮蔽的版本"
        if (-not $r.real) { continue }
        if (-not $byTool.ContainsKey($r.tool)) { $byTool[$r.tool] = New-Object System.Collections.Generic.List[string] }
        $byTool[$r.tool].Add($r.path)
    }
    foreach ($k in $byTool.Keys) {
        $paths = $byTool[$k] | Sort-Object -Unique
        if ($paths.Count -le 1) { continue }

        # 找出哪些版本在 PATH 上（能被直接调用）
        $pathDirs = @(Get-PathDirs) | ForEach-Object { $_.ToLowerInvariant() }
        $reachable = @($paths | Where-Object { $d = Split-Path $_ -Parent; $pathDirs -contains $d.ToLowerInvariant() })
        $hidden    = @($paths | Where-Object { $d = Split-Path $_ -Parent; $pathDirs -notcontains $d.ToLowerInvariant() })

        if ($hidden.Count -gt 0) {
            $warnings.Add((New-Warning -Kind 'SHADOWED' -Tool $k -Facts @{
                tool   = $k
                total  = $paths.Count
                hidden = $hidden.Count
            } -Detail ($hidden -join ' | ')))
        }
    }

    # --- 3) 发现了自定义命名约定（这类约定只存在于文件名里，最容易失传）---
    foreach ($c in $Conventions) {
        $warnings.Add((New-Warning -Kind 'CONVENTION' -Tool $c.tool -Facts @{
            shim     = $c.shimName
            declared = $c.nameVersion
            actual   = $c.actualVersion
        } -Detail $c.shim))
    }

    # --- 4) 声明了但没装 ---
    foreach ($d in $Declarations) {
        foreach ($tool in $d.tools.Keys) {
            $wanted = $d.tools[$tool]
            $short  = ($tool -replace '^(nodejs|node)$', 'node') -replace '^python3$', 'python'
            $installed = @($Managed.records | Where-Object { $_.tool -eq $short }) +
                         @($Unmanaged | Where-Object { $_.tool -eq $short })
            # 判断"装了没"不能只看运行时清单：这个套件面向所有工具，
            # 声明里可能是 jadx / nmap / ffmpeg 这类不在清单里的东西。
            # 只要 PATH 上能解析到、而且真的能执行，就算装了。
            $resolvedOk = @($Resolution | Where-Object { $_.command -eq $short -and $_.usable }).Count -gt 0
            if ($installed.Count -eq 0 -and -not $resolvedOk) {
                $warnings.Add((New-Warning -Kind 'MISSING' -Tool $short -Facts @{
                    tool    = $tool
                    wanted  = $wanted
                    file    = $d.path
                } -Detail $d.path))
            }
        }
    }

    # --- 5) mise 未安装 ---
    if (-not $Managed.available) {
        $warnings.Add((New-Warning -Kind 'NO_MISE' -Tool 'mise' -Facts @{}))
    }

    # --- 6) 游离运行时：没有任何管理器纳管，也不在公认位置或规范根下 ---
    # 只报告不迁移。搬动已有运行时的风险（路径被项目配置、IDE 设置、CI 脚本写死）
    # 远大于收益，而"登记到声明文件"能用接近零的成本解决真正的问题——
    # 它们目前只靠 PATH 被找到，PATH 一变就没人知道它们在哪儿。
    $stray = @($Unmanaged | Where-Object { $_.real -and $_.placement -eq '游离' })
    if ($stray.Count -gt 0) {
        $toolNames = (($stray | ForEach-Object { $_.tool }) | Sort-Object -Unique) -join '/'
        $strayDetail = ($stray | Sort-Object tool, version |
                        ForEach-Object { "$($_.tool) $($_.version) @ $($_.path)" }) -join ' | '
        $warnings.Add((New-Warning -Kind 'STRAY' -Tool $toolNames -Facts @{
            count = $stray.Count
            root  = $script:ToolsRoot
        } -Detail $strayDetail))
    }

    # --- 7) 项目有版本约束，但没有工具读得到的声明文件 ---
    # package.json 的 engines 只在版本不符时给一条警告，它不会切换版本。
    # 于是"这个项目需要 Node 22"这个事实只存在于 engines 里，用上 22 得靠人
    # 记住某个路径——这正是当初需要 node22.cmd 那类私有约定的原因。
    $hasProjectDeclaration = @($Declarations | Where-Object { $_.scope -eq 'project' -and [IO.Path]::GetFileName($_.path) -in @('mise.toml', '.mise.toml', '.tool-versions', '.nvmrc', '.node-version') }).Count -gt 0
    if (-not $hasProjectDeclaration) {
        $pkgPath = Join-Path (Get-Location).Path 'package.json'
        if (Test-Path -LiteralPath $pkgPath) {
            $wantNode = ''
            try {
                $pkg = Get-Content -LiteralPath $pkgPath -Raw | ConvertFrom-Json
                if ($pkg.PSObject.Properties.Name -contains 'engines' -and
                    $pkg.engines.PSObject.Properties.Name -contains 'node') {
                    $wantNode = "$($pkg.engines.node)"
                }
            } catch { }
            if ($wantNode) {
                $warnings.Add((New-Warning -Kind 'UNDECLARED' -Tool 'node' -Facts @{
                    wanted = $wantNode
                }))
            }
        }
    }

    # --- 8) 声明被 PATH 顺序遮蔽：声明要求某个版本，mise 也确实装了，但解析到的副本
    #        连"满足声明"都谈不上（解析到的版本本来就符合声明就不报，见 Test-VersionSatisfies）---
    # 根因不在运行时，而在 Windows 组合 PATH 的规则：机器级 PATH 在前、用户级在后，
    # 于是 legacy 的直接工具目录（D:\nodejs、C:\ProgramData\Oracle\Java\javapath）
    # 永远排在 mise 的 shims 之前。交互式会话靠 `mise activate` 在会话内临时把 shims
    # 前置来救场，但 cmd、图形程序、IDE 任务、带 -NoProfile 的脚本拿不到这个前置，
    # 它们会用错版本——"声明式"的承诺正是在这些场景里失效的。
    $seenInert = New-Object System.Collections.Generic.HashSet[string]
    foreach ($d in $Declarations) {
        foreach ($tool in $d.tools.Keys) {
            $short = ($tool -replace '^(nodejs|node)$', 'node') -replace '^python3$', 'python'
            $managedForTool = @($Managed.records | Where-Object { $_.tool -eq $short })
            if ($managedForTool.Count -eq 0) { continue }

            $resolved = @($Resolution | Where-Object {
                if ($short -eq 'node')        { $_.command -in @('node', 'npm', 'npx', 'pnpm', 'yarn') }
                elseif ($short -eq 'python')  { $_.command -in @('python', 'python3', 'py') }
                else                          { $_.command -eq $short }
            })
            foreach ($r in $resolved) {
                if (-not $r.usable) { continue }
                # 已经解析到 mise 的 shims / installs 就不是问题
                if ($r.resolvesTo -match '\\mise\\(shims|installs)\\') { continue }
                # 解析到的副本本来就满足声明，就算不上"用错版本"：
                # 声明 python "3.12, 3.13"、解析到 Windows 的 py 启动器（3.12.10）就是这种情况——
                # 版本是对的，只是不是 mise 那一份。而且 mise 不会为 py 生成 shim，
                # 按告警建议去调 PATH 顺序也永远不会让它消失，只会白费一轮排查。
                if (Test-VersionSatisfies -Version $r.version -Wanted "$($d.tools[$tool])") { continue }
                if (-not $seenInert.Add("$($r.command)|$($r.resolvesTo)")) { continue }

                $warnings.Add((New-Warning -Kind 'PATH_ORDER' -Tool $r.command -Facts @{
                    tool    = $short
                    wanted  = $d.tools[$tool]
                    file    = $d.path
                    have    = $managedForTool[0].version
                    command = $r.command
                    path    = $r.resolvesTo
                    version = $r.version
                }))
            }
        }
    }

    # --- 9) PATH 里的脏数据：重复条目、带引号的条目 ---
    # Get-PathDirs 会静默去重以免影响其它判断，但脏数据本身值得报告：
    # PATH 有长度上限，重复条目会挤占空间，而且会让"改了却没生效"难以排查。
    # 检查的是【进程生效的 PATH】而不是某一层的注册表值：
    #   1. 这才是所有子进程真正看到的顺序；
    #   2. census.sh 也只能看到进程 PATH，两者口径必须一致，否则同一台机器上
    #      两个实现会给出不同的结论（parity 测试会立刻发现）。
    $userRaw = @($env:PATH -split ';' | Where-Object { $_ })
    $seenEntry = @{}
    $dupes = New-Object System.Collections.Generic.List[string]
    foreach ($e in $userRaw) {
        $k = "$e".Trim().Trim('"').TrimEnd('\').ToLowerInvariant()
        if ($seenEntry.ContainsKey($k)) { $dupes.Add("$e") } else { $seenEntry[$k] = $true }
    }
    $quoted = @($userRaw | Where-Object { "$_" -match '"' })

    $dirt = New-Object System.Collections.Generic.List[string]
    if ($dupes.Count -gt 0)  { $dirt.Add((T 'dirt.dupes'  @{ n = $dupes.Count })) }
    if ($quoted.Count -gt 0) { $dirt.Add((T 'dirt.quoted' @{ n = $quoted.Count })) }
    if ($dirt.Count -gt 0) {
        $dirtDetail = @()
        if ($dupes.Count -gt 0)  { $dirtDetail += ($dupes | Sort-Object -Unique) -join ' | ' }
        if ($quoted.Count -gt 0) { $dirtDetail += ($quoted | Sort-Object -Unique) -join ' | ' }
        $warnings.Add((New-Warning -Kind 'PATH_DIRT' -Tool 'PATH' -Facts @{
            parts = ($dirt -join (T 'dirt.join' @{}))
        } -Detail ($dirtDetail -join ' || ')))
    }

    # --- 10) 部署的全局声明与仓库模板漂移 ---
    # 模板是"这台机器想要的状态"，部署副本是"现在实际声明的状态"。两者是两份独立文件，
    # 没有任何机制保证同步——模板里新加的工具会永远装不上，这正是最容易被忽视的一类失效：
    # census 只说"声明要求什么"，看不出声明本身已经落后于意图。
    $templatePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'templates\mise-config.toml'
    # 部署副本的位置必须和 mise 自己的规则一致：XDG_CONFIG_HOME 一旦被设置，mise 的全局
    # 配置就搬走了，此时 ~/.config/mise/config.toml 只是"从工作目录向上发现"的配置。
    # （两个实现必须用同一套规则，否则同一台机器上 .ps1 和 .sh 会报出不同的漂移结论。）
    $deployedPath = if ($env:XDG_CONFIG_HOME) { Join-Path $env:XDG_CONFIG_HOME 'mise\config.toml' }
                    else { Join-Path $env:USERPROFILE '.config\mise\config.toml' }
    if ((Test-FileQuick $templatePath) -and (Test-FileQuick $deployedPath)) {
        $tplText = ((Get-Content -LiteralPath $templatePath -Raw) -replace "`r`n", "`n")
        $depText = ((Get-Content -LiteralPath $deployedPath -Raw) -replace "`r`n", "`n")
        if ($tplText.Trim() -ne $depText.Trim()) {
            $tplKeys = @(Get-TomlSectionKeys -Path $templatePath -Section 'tools')
            $depKeys = @(Get-TomlSectionKeys -Path $deployedPath -Section 'tools')
            $onlyTpl = @($tplKeys | Where-Object { $depKeys -notcontains $_ })
            $onlyDep = @($depKeys | Where-Object { $tplKeys -notcontains $_ })
            $diff = New-Object System.Collections.Generic.List[string]
            if ($onlyTpl.Count -gt 0) { $diff.Add((T 'drift.onlyTpl' @{ keys = ($onlyTpl -join ', ') })) }
            if ($onlyDep.Count -gt 0) { $diff.Add((T 'drift.onlyDep' @{ keys = ($onlyDep -join ', ') })) }
            if ($diff.Count -eq 0)   { $diff.Add((T 'drift.sameKeys' @{})) }
            $warnings.Add((New-Warning -Kind 'DRIFT' -Tool 'mise' -Facts @{
                deployed = $deployedPath
            } -Detail ($diff -join (T 'drift.join' @{}))))
        }
    }

    # --- 11) XDG_CONFIG_HOME 被设置：mise 的"全局"配置会搬家 ---
    # 这是实测踩到的坑：设置了 XDG_CONFIG_HOME 后，mise 把 $XDG_CONFIG_HOME/mise/config.toml
    # 当作真正的全局配置，而 ~/.config/mise/config.toml 降级为"向上遍历发现"的配置——
    # 于是它在 D:\ 之类的工作目录下完全不生效，同时 auto_update 这类只允许写在全局配置里的
    # 设置会被忽略（mise 会打印 "auto_update in non-global config ... is ignored"）。
    if ($env:XDG_CONFIG_HOME) {
        $xdgConfig = Join-Path $env:XDG_CONFIG_HOME 'mise\config.toml'
        $warnings.Add((New-Warning -Kind 'XDG_SHIFT' -Tool 'mise' -Facts @{
            xdg    = $env:XDG_CONFIG_HOME
            config = $xdgConfig
        }))
    }

    return $warnings
}

# ============================================================
# 主流程
# ============================================================

$pathDirs = @(Get-PathDirs)

# 每个阶段独立计时，便于定位性能问题（-Timing）
$pathIndex    = Measure-Phase '0. PATH 索引'           { Get-PathIndex }
$declarations = Measure-Phase '1. 声明层'              { Get-Declarations }
$managed      = Measure-Phase '2. mise 纳管层'          { Get-MiseManaged }
$conventions  = Measure-Phase '3. 约定层（命名 shim）'   { Get-ConventionShims -PathDirs $pathDirs }
$roots        = Measure-Phase '4a. 候选根目录'          { Get-CandidateRoots }
$unmanaged    = Measure-Phase '4b. 定向探测运行时'       { Get-UnmanagedRecords -Roots $roots }

# 可选：宽松深扫（慢）。默认关闭，这是唯一的非线性开销来源。
if ($Deep) {
    $deepRecords = Measure-Phase '4c. 深度扫描（-Deep）' {
        $drives = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
                    Where-Object { $_.Root -match '^[A-Z]:\\$' } |
                    ForEach-Object { $_.Root })
        $acc = New-Object System.Collections.Generic.List[object]
        foreach ($drive in $drives) {
            foreach ($exe in (Find-RuntimeExecutables -Root $drive -MaxDepth $DeepMaxDepth)) {
                $rec = ConvertTo-RuntimeRecord -ExePath $exe -Root $drive -Pattern '(深度扫描)'
                if ($rec) { $acc.Add($rec) }
            }
        }
        return ,$acc
    }
    $known = New-Object System.Collections.Generic.HashSet[string]
    foreach ($r in $unmanaged) { [void]$known.Add($r.path.ToLowerInvariant()) }
    foreach ($r in $deepRecords) {
        if ($known.Add($r.path.ToLowerInvariant())) { $unmanaged = @($unmanaged) + @($r) }
    }
}

$resolution = Measure-Phase '5. 解析层'                {
    # 把声明里点名的工具并进解析列表：任何工具都能被盘点，不限于语言运行时
    $declaredCommands = @($declarations | ForEach-Object { $_.tools.Keys } | Sort-Object -Unique)
    Get-Resolution -PathIndex $pathIndex.index -DirCount $pathIndex.dirCount -ExtraCommands $declaredCommands
}
$warnings   = Measure-Phase '6. 汇总告警'               {
    Get-Warnings -Managed $managed -Conventions $conventions -Unmanaged $unmanaged `
                 -Resolution $resolution -Declarations $declarations
}

# 逐字段挂载，而不是一次性写出哈希表字面量。
# 一次性构造一旦失败会整体丢弃并留下 $null，报告所有字段变空却不说哪个字段有问题；
# 逐个挂载能把出错的字段名和值类型报出来。
function Add-ReportField {
    param([object]$Target, [string]$Name, [scriptblock]$Factory)
    $value = $null
    try {
        $value = & $Factory
    } catch {
        [Console]::Error.WriteLine("[census] 计算字段 '$Name' 失败: $($_.Exception.Message)")
        throw
    }
    $valueType = if ($null -eq $value) { 'null' } else { $value.GetType().FullName }
    try {
        Add-Member -InputObject $Target -NotePropertyName $Name -NotePropertyValue $value -Force
    } catch {
        [Console]::Error.WriteLine("[census] 挂载字段 '$Name' 失败 (值类型 $valueType): $($_.Exception.Message)")
        throw
    }
}

# 注意每个数组字段都用 ,@(...) 包一层：脚本块的输出会被管道展开，
# 直接写 @() 时空数组会变成 $null，导致字段消失。
$report = New-Object PSObject
Add-ReportField $report 'schemaVersion' { 1 }
Add-ReportField $report 'generatedAt'  { (Get-Date).ToString('s') }
Add-ReportField $report 'host'         {
    [pscustomobject]@{
        os         = [System.Environment]::OSVersion.VersionString
        arch       = $env:PROCESSOR_ARCHITECTURE
        user       = $env:USERNAME
        powershell = $PSVersionTable.PSVersion.ToString()
        cwd        = (Get-Location).Path
    }
}
Add-ReportField $report 'declarations' { ,@($declarations) }
Add-ReportField $report 'toolsRoot'    { $script:ToolsRoot }
Add-ReportField $report 'mise'         { [pscustomobject]@{ available = $managed.available; tools = $managed.records.ToArray() } }
Add-ReportField $report 'conventions'  { ,@($conventions) }
# JSON 里的位置与来源换成稳定 ASCII 键：agent 与脚本不该依赖中文取值。
Add-ReportField $report 'runtimes'     { ,@($unmanaged | ForEach-Object {
    [pscustomobject]@{
        tool      = $_.tool
        version   = $_.version
        path      = $_.path
        source    = (Get-StableKey $_.source)
        placement = (Get-StableKey $_.placement)
        managed   = $_.managed
        real      = $_.real
        root      = $_.root
        # pattern 也必须过 Get-StableKey：它是发现阶段标记（probe / deep-scan），
        # 内部值「定向探测」是中文。漏转会让 JSON 里混进本地化取值，
        # 而 census.sh 侧没有这个字段——按文档写的消费者会在 Windows 上
        # 拿到中文、在 Unix 上拿到 null。
        pattern   = (Get-StableKey $_.pattern)
    }
}) }
Add-ReportField $report 'resolution'   { ,@($resolution) }
Add-ReportField $report 'warnings'     { ,@($warnings) }
# 注意不能写 @($TimingItems)：在 Windows PowerShell 5.1 上，
# @() 作用于 List[object] 会抛 "Argument types do not match"，必须走 ToArray()
Add-ReportField $report 'timings'      {
    # 与 census.sh 对齐：timings 只在 -Timing 时填充。bash 侧每阶段要起一个 date 进程，
    # 默认不测；两边不一致会让同一份 JSON 在一个平台上是 8 条、另一个平台上是 0 条，
    # 而文档承诺的是"配合 --timing 的各阶段毫秒数"。
    if (-not $Timing) { return ,@() }
    return ,@($TimingItems | ForEach-Object {
        [pscustomobject]@{ phase = (Get-StableKey $_.phase); ms = $_.ms }
    })
}
# probeStats 总是输出（不依赖 -Timing）：计数本身零开销，map 扫描要拿它做基线。
Add-ReportField $report 'probeStats'   {
    # 计数来自统一执行器（toolkit-common.ps1 的 $script:ToolkitProbeStats）：每启动一个外部进程记一次，
    # 累计从启动到退出（或超时）的毫秒数；命中探测缓存不算。
    [pscustomobject]@{ launches = [int]$script:ToolkitProbeStats.launches; ms = [int64]$script:ToolkitProbeStats.ms }
}
Add-ReportField $report 'summary'      {
    [pscustomobject]@{
        runtimeCount = @($unmanaged).Count
        warningCount = @($warnings).Count
        byTool       = @{}
    }
}

# 按运行时统计版本数（只统计真正可执行的，排除商店别名存根这类假阳性）
$stats = @{}
foreach ($r in $unmanaged) {
    if (-not $r.real) { continue }
    if (-not $stats.ContainsKey($r.tool)) { $stats[$r.tool] = @() }
    if ($stats[$r.tool] -notcontains $r.version) { $stats[$r.tool] += $r.version }
}
# 同理按工具名排序，免得 summary.byTool 的键序每次运行都不同
$statKeys = [string[]]@($stats.Keys)
[Array]::Sort($statKeys, [StringComparer]::Ordinal)
$byTool = [ordered]@{}
foreach ($k in $statKeys) { $byTool[$k] = $stats[$k] }
$report.summary.byTool = $byTool

if ($Json) {
    $report | ConvertTo-Json -Depth 6
    return
}

# ---------- 人类可读输出 ----------

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ("=" * 72) -ForegroundColor DarkGray
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor DarkGray
}

Write-Host ''
Write-Host (' ' + (T 'title')) -ForegroundColor White
Write-Host (' ' + (T 'meta' @{
    time = $report.generatedAt
    user = $report.host.user
    arch = $report.host.arch
    cwd  = $report.host.cwd
})) -ForegroundColor DarkGray

Write-Section (T 'sec.decl')
if ($declarations.Count -eq 0) {
    Write-Host ('  ' + (T 'no.decl')) -ForegroundColor DarkYellow
} else {
    foreach ($d in $declarations) {
        $tag = if ($d.scope -eq 'global') { T 'scope.global' } else { T 'scope.project' }
        Write-Host "  $tag $($d.path)" -ForegroundColor Green
        foreach ($k in $d.tools.Keys) {
            Write-Host "        $k  ->  $($d.tools[$k])" -ForegroundColor Gray
        }
    }
}

Write-Section (T 'sec.managed')
if (-not $managed.available) {
    Write-Host ('  ' + (T 'no.mise')) -ForegroundColor DarkYellow
} elseif (@($managed.records).Count -eq 0) {
    Write-Host ('  ' + (T 'no.managed')) -ForegroundColor DarkYellow
} else {
    foreach ($r in ($managed.records | Sort-Object tool, version)) {
        Write-Host ("  {0,-10} {1,-14} {2}" -f $r.tool, $r.version, $r.installPath) -ForegroundColor Gray
    }
}

Write-Section (T 'sec.conv')
if ($conventions.Count -eq 0) {
    Write-Host ('  ' + (T 'no.conv')) -ForegroundColor DarkGray
} else {
    foreach ($c in ($conventions | Sort-Object tool, nameVersion)) {
        $state = if ($c.targetOk) { T 'state.ok' } else { T 'state.bad' }
        Write-Host ('  ' + (T 'conv.line' @{
            shim     = $c.shimName
            declared = $c.nameVersion
            actual   = $c.actualVersion
            state    = $state
        })) -ForegroundColor Yellow
        Write-Host "        -> $($c.target)" -ForegroundColor DarkGray
    }
}

Write-Section (T 'sec.inv')
$grouped = $unmanaged | Group-Object tool | Sort-Object Name
foreach ($g in $grouped) {
    Write-Host ('  ' + (T 'inv.count' @{ tool = $g.Name.ToUpperInvariant(); count = $g.Count })) -ForegroundColor White
    foreach ($r in ($g.Group | Sort-Object version)) {
        # 来源与位置在内部是固定的中文取值（JSON 里会换成 ASCII 键），
        # 显示时按当前语言映射一次，避免把"内部取值"当成"界面文案"用。
        $flags = @(Get-LabelText $r.source)
        if ($r.real) {
            # 只有真正可执行的运行时才谈"位置是否规范"；存根不参与这个判断
            if ($r.placement -eq '游离')   { $flags += (T 'lbl.游离位置') }
            if ($r.placement -eq '规范根') { $flags += (T 'lbl.规范根') }
        } else {
            $flags += (T 'lbl.不可用')
        }
        Write-Host ("    {0,-14} {1}" -f $r.version, $r.path) -ForegroundColor Gray
        Write-Host ('                   [' + ($flags -join ' | ') + ']') -ForegroundColor DarkGray
    }
}

Write-Section (T 'sec.res')
foreach ($r in ($resolution | Sort-Object command)) {
    if ($r.hitCount -gt 1) {
        Write-Host ('  ' + (T 'res.hits' @{
            command = $r.command; path = $r.resolvesTo; version = $r.version; hits = $r.hitCount
        })) -ForegroundColor Gray
    } else {
        Write-Host ('  ' + (T 'res.line' @{
            command = $r.command; path = $r.resolvesTo; version = $r.version
        })) -ForegroundColor Gray
    }
    if ($r.stub) {
        Write-Host ('             ' + (T 'res.stub')) -ForegroundColor Red
    }
}

Write-Section (T 'sec.warn')
if ($warnings.Count -eq 0) {
    Write-Host ('  ' + (T 'no.warn')) -ForegroundColor Green
} else {
    $order = @('STUB', 'PATH_ORDER', 'SHADOWED', 'CONVENTION', 'PATH_DIRT', 'DRIFT', 'XDG_SHIFT', 'STRAY', 'UNDECLARED', 'MISSING', 'NO_MISE')
    foreach ($kind in $order) {
        foreach ($w in ($warnings | Where-Object { $_.kind -eq $kind })) {
            $color = switch ($kind) {
                'STUB'       { 'Red' }
                'PATH_ORDER' { 'Red' }
                'SHADOWED'   { 'Yellow' }
                'CONVENTION' { 'Magenta' }
                'PATH_DIRT'  { 'DarkYellow' }
                'DRIFT'      { 'Red' }
                'XDG_SHIFT'  { 'Red' }
                'STRAY'      { 'Cyan' }
                'UNDECLARED' { 'Yellow' }
                'MISSING'    { 'Red' }
                default      { 'DarkYellow' }
            }
            Write-Host ("  [$($w.kind)] " + $w.message) -ForegroundColor $color
            if ($w.action) { Write-Host ('        -> ' + $w.action) -ForegroundColor DarkGray }
            if ($w.detail) { Write-Host "        $($w.detail)" -ForegroundColor DarkGray }
        }
    }
}

Write-Section (T 'sec.summary')
Write-Host ('  ' + (T 'sum.runtimes' @{ count = @($unmanaged).Count })) -ForegroundColor White
foreach ($k in ($stats.Keys | Sort-Object)) {
    Write-Host ('    ' + (T 'sum.byTool' @{
        tool     = $k
        count    = @($stats[$k]).Count
        versions = ($stats[$k] -join ', ')
    })) -ForegroundColor Gray
}

# 位置分布：一眼看出有多少运行时是"只靠 PATH 被记住"的
$placementCounts = @{}
foreach ($r in $unmanaged) {
    if (-not $r.real) { continue }
    $placementCounts[$r.placement] = 1 + $placementCounts[$r.placement]
}
$placementText = @(@('托管', '宿主', '公认', '规范根', '游离') |
    Where-Object { $placementCounts.ContainsKey($_) } |
    ForEach-Object { "$(Get-LabelText $_) $($placementCounts[$_])" })
Write-Host ('  ' + (T 'sum.placement' @{ text = ($placementText -join '  /  ') })) -ForegroundColor Gray
Write-Host ('  ' + (T 'sum.root' @{ root = $script:ToolsRoot })) -ForegroundColor DarkGray

Write-Host ('  ' + (T 'sum.warnings' @{ count = $warnings.Count })) -ForegroundColor $(if ($warnings.Count -gt 0) { 'Yellow' } else { 'Green' })

# 脚本可验证性：.ps1 在本机就能跑；.sh 需要一个真正的 bash（Git Bash / WSL 发行版 / 容器）。
# 常见的坑是 PATH 上的 bash 其实是 C:\WINDOWS\system32\bash.exe——WSL 的转发壳，
# 没装发行版时它报的是 WSL 自己的错（"execvpe(/bin/bash) failed"），
# 看起来像脚本有语法错误，其实和脚本无关。
$bashExe    = (Get-Command bash -ErrorAction SilentlyContinue).Source
$gitBashExe = @('C:\Program Files\Git\bin\bash.exe', 'C:\Program Files (x86)\Git\bin\bash.exe') |
              Where-Object { Test-FileQuick $_ } | Select-Object -First 1
$bashState = (T 'lbl.不可用')
if ($gitBashExe)                                { $bashState = "Git Bash ($gitBashExe)" }
elseif ($bashExe -match 'System32\\bash\.exe$') { $bashState = 'WSL relay only (unusable without a distro)' }
elseif ($bashExe)                               { $bashState = $bashExe }
$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
Write-Host ('  ' + (T 'sum.shell' @{
    bash   = $bashState
    docker = $(if ($dockerCmd) { 'yes' } else { 'no' })
})) -ForegroundColor Gray
if ($bashState -notmatch '^Git Bash' -and $dockerCmd) {
    Write-Host ('       ' + (T 'sum.docker')) -ForegroundColor DarkGray
}

if ($Timing) {
    Write-Section (T 'sec.timing')
    foreach ($t in ($TimingItems | Sort-Object -Property phase)) {
        Write-Host ('  ' + (T 'timing.line' @{ phase = (Get-LabelText $t.phase); ms = $t.ms })) -ForegroundColor DarkGray
    }
    $sum = ($TimingItems | Measure-Object -Property ms -Sum).Sum
    # 合计行与 census.sh 同格式（timing.line）。旧写法把 ms 传给不含 {ms} 的 timing.total，数字被吞掉了。
    Write-Host ('  ' + (T 'timing.line' @{ phase = (T 'timing.total'); ms = $sum })) -ForegroundColor White
    Write-Host ('  ' + (T 'timing.probes' @{ count = $script:ToolkitProbeStats.launches; ms = $script:ToolkitProbeStats.ms })) -ForegroundColor DarkGray
}

Write-Host ''
