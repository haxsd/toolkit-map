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

.EXAMPLE
  .\census.ps1

.EXAMPLE
  .\census.ps1 -Json | Out-File census.json -Encoding utf8
#>
[CmdletBinding()]
param(
    [switch]$Deep,
    [int]$DeepMaxDepth = 4,
    [switch]$Json,
    [switch]$Timing
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

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
# 用 .NET Process 而不是 PowerShell 的原生调用，原因有两个：
#   1. java -version 把版本写到 stderr。在 $ErrorActionPreference='SilentlyContinue'
#      下，2>&1 合并进来的 stderr 会被整体丢弃，导致 java 版本永远探测为空白。
#   2. 避免每次调用都走一遍 PowerShell 管道，探测上百个文件时差距明显。
# 同时读取两个流是必须的：只读一个的话，另一个管道缓冲区写满就会死锁。
function Get-FirstLine {
    param([string]$Exe, [string[]]$Arguments)
    if (-not (Test-FileQuick $Exe)) { return '' }

    $fileName = $Exe
    $argLine = ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '

    $ext = [System.IO.Path]::GetExtension($Exe).ToLowerInvariant()
    if ($ext -eq '.cmd' -or $ext -eq '.bat') {
        # .cmd/.bat 必须经由 cmd.exe 解释，不能直接作为进程启动
        $argLine  = '/c "' + $Exe + '" ' + $argLine
        $fileName = $env:ComSpec
        if (-not $fileName) { $fileName = 'cmd.exe' }
    } elseif ($ext -eq '.ps1') {
        # 不探测 PowerShell 脚本的版本，避免拖慢且结果无意义
        return ''
    }

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $fileName
        $psi.Arguments              = $argLine
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true

        $p  = [System.Diagnostics.Process]::Start($psi)
        $so = $p.StandardOutput.ReadToEndAsync()
        $se = $p.StandardError.ReadToEndAsync()

        # 加超时保护：某些损坏的运行时安装会让 -version 永久挂住
        if (-not $p.WaitForExit(20000)) {
            try { $p.Kill() } catch { }
            return ''
        }

        $text = $so.Result
        if ([string]::IsNullOrWhiteSpace($text)) { $text = $se.Result }
        if ([string]::IsNullOrWhiteSpace($text)) { return '' }

        $line = $text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1
        return "$line".Trim()
    } catch {
        return ''
    }
}

# 判断文件是不是"真的可执行"。
# Windows 的商店应用别名（WindowsApps\python3.exe）是 0 字节存根：
# 存在、能被 Get-Command 找到、但执行时静默失败（退出码 9009）。
function Test-RealExecutable {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $false }
    if ($item.PSIsContainer) { return $false }
    if ($item.Length -eq 0) { return $false }
    return $true
}

# 把各种工具输出版本号的形式统一成裸版本号。
function Get-NormalizedVersion {
    param([string]$Tool, [string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return '' }
    switch ($Tool) {
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
# 结果做缓存，避免同一个文件被反复调用（java -version 启动开销不小）。
$script:VersionCache = @{}
function Get-RuntimeVersion {
    param([string]$Tool, [string]$ExePath)
    $key = "$Tool|$ExePath"
    if ($script:VersionCache.ContainsKey($key)) { return $script:VersionCache[$key] }

    $raw = ''
    switch ($Tool) {
        'node'   { $raw = Get-FirstLine $ExePath @('--version') }
        'python' { $raw = Get-FirstLine $ExePath @('--version') }
        'pip'    { $raw = Get-FirstLine $ExePath @('--version') }
        'java'   { $raw = Get-FirstLine $ExePath @('-version') }
        default  {
            # 绝大多数工具支持 --version；个别只认 -version 或裸 version，逐个兜底
            $raw = Get-FirstLine $ExePath @('--version')
            if (-not $raw) { $raw = Get-FirstLine $ExePath @('-version') }
            if (-not $raw) { $raw = Get-FirstLine $ExePath @('version') }
        }
    }
    $ver = Get-NormalizedVersion -Tool $Tool -Raw $raw
    $script:VersionCache[$key] = $ver
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
        tool    = $tool
        version = (Get-RuntimeVersion -Tool $tool -ExePath $real)
        path    = $real
        root    = $Root
        source  = (Get-InstallSource $real)
        managed = (Test-IsMiseManaged $real)
        real    = (Test-RealExecutable $real)
        pattern = $Pattern
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

# ============================================================
# 第 1 阶段：声明层
# ============================================================

function Get-Declarations {
    $decls = New-Object System.Collections.Generic.List[object]

    # 全局声明
    $globalCandidates = @(
        (Join-Path $env:USERPROFILE '.config\mise\config.toml'),
        (Join-Path $env:APPDATA     'mise\config.toml'),
        (Join-Path $env:USERPROFILE '.tool-versions')
    )
    foreach ($p in $globalCandidates) {
        if (Test-Path -LiteralPath $p) {
            $decls.Add([pscustomobject]@{ scope = 'global'; path = $p; tools = (Read-DeclaredTools $p) })
        }
    }

    # 当前目录向上逐级找项目声明（最近的最优先，但全部列出便于排查）
    $dir = (Get-Location).Path
    $guard = 0
    while ($dir -and $guard -lt 20) {
        $guard++
        foreach ($name in @('mise.toml', '.mise.toml', '.tool-versions')) {
            $f = Join-Path $dir $name
            if (Test-Path -LiteralPath $f) {
                $decls.Add([pscustomobject]@{ scope = 'project'; path = $f; tools = (Read-DeclaredTools $f) })
            }
        }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $decls
}

# 尽力解析声明文件里的"工具 -> 期望版本"。
# .tool-versions 是 "nodejs 20.11.0" 这种极简格式；mise.toml 读 [tools] 段。
# 这里是尽力而为的轻量解析，不追求覆盖 TOML 全部语法。
function Read-DeclaredTools {
    param([string]$Path)
    $result = @{}
    try {
        $lines = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue
    } catch { return $result }

    $base = [System.IO.Path]::GetFileName($Path)
    $inToolsSection = $false

    foreach ($line in $lines) {
        $t = "$line".Trim()
        if ([string]::IsNullOrWhiteSpace($t) -or $t.StartsWith('#')) { continue }

        if ($base -like '*.toml') {
            if ($t -match '^\[(.+)\]$') {
                $inToolsSection = ($Matches[1] -eq 'tools')
                continue
            }
            if (-not $inToolsSection) { continue }
            # node = "22"    /    node = ["16", "22"]
            $m = [regex]::Match($t, '^([A-Za-z0-9_\-]+)\s*=\s*(.+)$')
            if ($m.Success) {
                $key = $m.Groups[1].Value
                $val = $m.Groups[2].Value -replace '[\[\]"]', ''
                $result[$key] = $val.Trim()
            }
        } else {
            # .tool-versions: "nodejs 20.11.0"
            $parts = $t -split '\s+'
            if ($parts.Count -ge 2) { $result[$parts[0]] = $parts[1] }
        }
    }
    return $result
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
        $raw = (& mise ls --json 2>$null | Out-String).Trim()
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

    # 形如 node22 / node-22 / python312 / java8 / go1.22 的可执行文件命名约定
    $pattern = '^(node|nodejs|npm|npx|pnpm|yarn|python|python3|py|pip|uv|java|javac|mvn|gradle|go|cargo|rustc|deno|bun|dotnet|php|ruby)(?:[-_]?v?)(\d+(?:\.\d+){0,3})$'

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
            if ($base -match '^(python|pip)[23](\.\d+){0,2}$') { continue }

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
$script:ProbeRelatives = @(
    'node.exe',
    'bin\node.exe',
    'python.exe',
    'Scripts\python.exe',
    'java.exe',
    'bin\java.exe',
    'jbr\bin\java.exe',
    'jre\bin\java.exe'
)

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
    if ($p -match '\\nodejs\\')                                                   { return '系统安装' }
    return '自定义位置'
}

function Get-CandidateRoots {
    $h = $env:USERPROFILE
    $roots = @()

    # --- 版本管理器 ---
    $roots += "$env:APPDATA\nvm"
    $roots += "$env:APPDATA\fnm"
    $roots += "$env:LOCALAPPDATA\fnm"
    $roots += "$env:LOCALAPPDATA\fnm_multishells"
    $roots += "$env:APPDATA\nvs"
    $roots += "$h\.volta\tools\image"
    $roots += "$h\.asdf"
    $roots += "$env:LOCALAPPDATA\mise"
    $roots += "$h\.local\share\mise"
    $roots += "$h\.pyenv"
    $roots += "$h\scoop\apps"
    $roots += 'C:\ProgramData\chocolatey\lib'

    # --- conda ---
    $roots += "$h\miniconda3"
    $roots += "$h\anaconda3"
    $roots += 'C:\ProgramData\miniconda3'
    $roots += 'C:\ProgramData\Anaconda3'

    # --- 系统安装 ---
    $roots += 'C:\Program Files\nodejs'
    $roots += 'C:\Program Files\Java'
    $roots += 'C:\Program Files (x86)\Java'
    $roots += 'C:\Program Files\Eclipse Adoptium'
    $roots += 'C:\Program Files\Microsoft'
    $roots += 'C:\Program Files\Zulu'
    $roots += 'C:\Program Files\Amazon Corretto'
    $roots += 'C:\Program Files\BellSoft'
    $roots += 'C:\Program Files\Semeru'
    $roots += 'C:\Program Files\RedHat'

    # --- IDE 内置运行时（JetBrains 的 jbr 里带完整 JDK，最容易被忽略）---
    $idePatterns = @('*pycharm*', '*IntelliJ*', '*JetBrains*', '*webstorm*', '*goland*', '*Android*Studio*')
    foreach ($c in @('C:\Program Files\JetBrains', 'D:\Program Files\JetBrains', "$h\AppData\Local\Programs")) {
        if (Test-DirQuick $c) { $roots += $c }
    }
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Root -match '^[A-Z]:\\$' })) {
        foreach ($pat in $idePatterns) {
            foreach ($hit in (Get-ChildItem -Path (Join-Path $drive.Root $pat) -Directory -ErrorAction SilentlyContinue)) {
                $roots += $hit.FullName
            }
        }
    }

    # --- 自定义目录：PATH 上的目录及其父目录 ---
    # PATH 目录本身可能就是一个运行时安装（如 D:\nodejs）；
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
        #     nvm\v20.11.0\node.exe        版本号目录
        #     D:\pycharm\PyCharm 2026.2\jbr\bin\java.exe    IDE 安装目录
        foreach ($sub in (Get-SubDirectories $root)) {
            foreach ($rel in $script:ProbeRelatives) {
                & $tryAdd (Join-Path $sub $rel) $root
            }
        }

        # conda 专门处理：环境位于 envs\<环境名>\ 下，解释器可能在根或 Scripts 里
        foreach ($envDirName in @('envs', 'env')) {
            $envRoot = Join-Path $root $envDirName
            if (-not (Test-DirQuick $envRoot)) { continue }
            foreach ($env in (Get-SubDirectories $envRoot)) {
                & $tryAdd (Join-Path $env 'python.exe') $root
                & $tryAdd (Join-Path $env 'Scripts\python.exe') $root
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
    param([hashtable]$PathIndex, [int]$DirCount)

    $probeList = @(
        'node', 'npm', 'npx', 'pnpm', 'yarn',
        'python', 'python3', 'py', 'pip', 'uv',
        'java', 'javac', 'mvn', 'gradle',
        'go', 'cargo', 'rustc', 'deno', 'bun', 'dotnet', 'mise'
    )

    # PATHEXT 决定同一目录下各扩展名的尝试顺序，末尾补一个空串表示无扩展名的文件
    $exts = @($env:PATHEXT -split ';' | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
    if ($exts.Count -eq 0) { $exts = @('.com', '.exe', '.bat', '.cmd', '.ps1') }
    $exts += ''

    $records = New-Object System.Collections.Generic.List[object]

    foreach ($name in $probeList) {
        $pathList = @(Resolve-CommandInPath -Index $PathIndex -Name $name -Exts $exts -DirCount $DirCount)
        if ($pathList.Count -eq 0) { continue }

        $first = $pathList[0]
        # 0 字节的文件是 Windows 商店的应用执行别名存根：能被找到，但执行时静默失败
        $usable = ((Get-FileLength $first) -gt 0)

        # 把命令名映射到它的"宿主运行时"，这样才能问出版本号。
        # 例如 npm 的版本必须问 node，javac 必须问 java。
        if ($name -in @('npm', 'npx', 'pnpm', 'yarn'))    { $probeTool = 'node' }
        elseif ($name -in @('javac', 'mvn', 'gradle'))    { $probeTool = 'java' }
        elseif ($name -eq 'py' -or $name -like 'python*') { $probeTool = 'python' }
        else                                              { $probeTool = $name }

        $ver = ''
        if ($probeTool -and $usable) { $ver = Get-RuntimeVersion -Tool $probeTool -ExePath $first }

        $records.Add([pscustomobject]@{
            command    = $name
            resolvesTo = $first
            version    = $ver
            allHits    = $pathList
            hitCount   = $pathList.Count
            stub       = (-not $usable)   # true 表示解析到不可执行的文件
            usable     = $usable
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
            $warnings.Add([pscustomobject]@{
                kind    = 'STUB'
                tool    = $r.command
                message = "命令 '$($r.command)' 解析到 '$($r.resolvesTo)'，但该文件不可执行（0 字节的商店别名存根，常见于 WindowsApps\python3.exe）。执行会静默失败。"
                detail  = $r.resolvesTo
            })
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
            $warnings.Add([pscustomobject]@{
                kind    = 'SHADOWED'
                tool    = $k
                message = "'$k' 在磁盘上有 $($paths.Count) 个副本，其中 $($hidden.Count) 个不在 PATH 上，无法被直接调用。被遮蔽的位置见 detail。"
                detail  = ($hidden -join ' | ')
            })
        }
    }

    # --- 3) 发现了自定义命名约定（这类约定只存在于文件名里，最容易失传）---
    foreach ($c in $Conventions) {
        $warnings.Add([pscustomobject]@{
            kind    = 'CONVENTION'
            tool    = $c.tool
            message = "发现自定义命名约定 '$($c.shimName)'（文件名里声明版本 $($c.nameVersion)，实际 $($c.actualVersion)）。这类约定不在任何标准里，必须写进声明文件否则会失传。"
            detail  = $c.shim
        })
    }

    # --- 4) 声明了但没装 ---
    foreach ($d in $Declarations) {
        foreach ($tool in $d.tools.Keys) {
            $wanted = $d.tools[$tool]
            $short  = ($tool -replace '^(nodejs|node)$', 'node') -replace '^python3$', 'python'
            $installed = @($Managed.records | Where-Object { $_.tool -eq $short }) +
                         @($Unmanaged | Where-Object { $_.tool -eq $short })
            if ($installed.Count -eq 0) {
                $warnings.Add([pscustomobject]@{
                    kind    = 'MISSING'
                    tool    = $short
                    message = "声明文件 '$($d.path)' 要求 $tool $wanted，但本机未发现该运行时的任何安装。"
                    detail  = $d.path
                })
            }
        }
    }

    # --- 5) mise 未安装 ---
    if (-not $Managed.available) {
        $warnings.Add([pscustomobject]@{
            kind    = 'NO_MISE'
            tool    = 'mise'
            message = "本机未安装 mise。运行时只能靠 PATH 解析，无法按项目自动切换版本。执行 scripts/bootstrap.ps1 可一键建立。"
            detail  = ''
        })
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
    Get-Resolution -PathIndex $pathIndex.index -DirCount $pathIndex.dirCount
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
Add-ReportField $report 'mise'         { [pscustomobject]@{ available = $managed.available; tools = $managed.records.ToArray() } }
Add-ReportField $report 'conventions'  { ,@($conventions) }
Add-ReportField $report 'runtimes'     { ,@($unmanaged) }
Add-ReportField $report 'resolution'   { ,@($resolution) }
Add-ReportField $report 'warnings'     { ,@($warnings) }
# 注意不能写 @($TimingItems)：在 Windows PowerShell 5.1 上，
# @() 作用于 List[object] 会抛 "Argument types do not match"，必须走 ToArray()
Add-ReportField $report 'timings'      { ,$TimingItems.ToArray() }
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
$report.summary.byTool = $stats

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
Write-Host ' 运行时普查报告 (census)' -ForegroundColor White
Write-Host " 生成时间: $($report.generatedAt)   主机: $($report.host.user)@$($report.host.arch)   当前目录: $($report.host.cwd)" -ForegroundColor DarkGray

Write-Section '1. 声明层 —— 谁在要求什么版本'
if ($declarations.Count -eq 0) {
    Write-Host '  （未发现任何 mise.toml / .tool-versions 声明）' -ForegroundColor DarkYellow
} else {
    foreach ($d in $declarations) {
        $tag = if ($d.scope -eq 'global') { '[全局]' } else { '[项目]' }
        Write-Host "  $tag $($d.path)" -ForegroundColor Green
        foreach ($k in $d.tools.Keys) {
            Write-Host "        $k  ->  $($d.tools[$k])" -ForegroundColor Gray
        }
    }
}

Write-Section '2. 纳管层 —— mise 管理的运行时'
if (-not $managed.available) {
    Write-Host '  mise 未安装（PATH 上找不到）。' -ForegroundColor DarkYellow
} elseif (@($managed.records).Count -eq 0) {
    Write-Host '  mise 已安装，但尚未纳管任何运行时。' -ForegroundColor DarkYellow
} else {
    foreach ($r in ($managed.records | Sort-Object tool, version)) {
        Write-Host ("  {0,-10} {1,-14} {2}" -f $r.tool, $r.version, $r.installPath) -ForegroundColor Gray
    }
}

Write-Section '3. 约定层 —— 带版本号的命名 shim（最容易失传的约定）'
if ($conventions.Count -eq 0) {
    Write-Host '  （未发现）' -ForegroundColor DarkGray
} else {
    foreach ($c in ($conventions | Sort-Object tool, nameVersion)) {
        $ok = if ($c.targetOk) { 'OK' } else { '不可用' }
        Write-Host ("  {0,-14} 名称声明 {1,-10} 实际 {2,-12} [{3}]" -f $c.shimName, $c.nameVersion, $c.actualVersion, $ok) -ForegroundColor Yellow
        Write-Host "        -> $($c.target)" -ForegroundColor DarkGray
    }
}

Write-Section '4. 运行时清单 —— 磁盘上实际存在的运行时（含纳管与未纳管）'
$grouped = $unmanaged | Group-Object tool | Sort-Object Name
foreach ($g in $grouped) {
    Write-Host "  $($g.Name.ToUpperInvariant())  共 $($g.Count) 个" -ForegroundColor White
    foreach ($r in ($g.Group | Sort-Object version)) {
        $flags = @($r.source)
        if ($r.managed) { $flags += 'mise 纳管' }
        if (-not $r.real) { $flags += '不可用' }
        Write-Host ("    {0,-14} {1}" -f $r.version, $r.path) -ForegroundColor Gray
        Write-Host ("                   [{0}]" -f ($flags -join ' | ')) -ForegroundColor DarkGray
    }
}

Write-Section '5. 解析层 —— 命令实际解析到哪'
foreach ($r in ($resolution | Sort-Object command)) {
    if ($r.hitCount -gt 1) {
        Write-Host ("  {0,-9} -> {1}  ({2})  [{3} 个 PATH 命中]" -f $r.command, $r.resolvesTo, $r.version, $r.hitCount) -ForegroundColor Gray
    } else {
        Write-Host ("  {0,-9} -> {1}  ({2})" -f $r.command, $r.resolvesTo, $r.version) -ForegroundColor Gray
    }
    if ($r.stub) {
        Write-Host "             ^ 警告：该文件不可执行（0 字节存根）" -ForegroundColor Red
    }
}

Write-Section '6. 告警 —— 需要人工确认的问题'
if ($warnings.Count -eq 0) {
    Write-Host '  未发现问题。' -ForegroundColor Green
} else {
    $order = @('STUB', 'SHADOWED', 'CONVENTION', 'MISSING', 'NO_MISE')
    foreach ($kind in $order) {
        foreach ($w in ($warnings | Where-Object { $_.kind -eq $kind })) {
            $color = switch ($kind) {
                'STUB'       { 'Red' }
                'SHADOWED'   { 'Yellow' }
                'CONVENTION' { 'Magenta' }
                'MISSING'    { 'Red' }
                default      { 'DarkYellow' }
            }
            Write-Host ("  [$($w.kind)] " + $w.message) -ForegroundColor $color
            if ($w.detail) { Write-Host "        $($w.detail)" -ForegroundColor DarkGray }
        }
    }
}

Write-Section '汇总'
Write-Host "  发现的运行时文件总数: $(@($unmanaged).Count)" -ForegroundColor White
foreach ($k in ($stats.Keys | Sort-Object)) {
    Write-Host ("    {0,-10} {1} 个版本: {2}" -f $k, $stats[$k].Count, ($stats[$k] -join ', ')) -ForegroundColor Gray
}
Write-Host "  告警数量: $($warnings.Count)" -ForegroundColor $(if ($warnings.Count -gt 0) { 'Yellow' } else { 'Green' })

if ($Timing) {
    Write-Section '性能分解 —— 各阶段耗时'
    foreach ($t in ($TimingItems | Sort-Object -Property phase)) {
        Write-Host ("  {0,-30} {1,8} ms" -f $t.phase, $t.ms) -ForegroundColor DarkGray
    }
    $sum = ($TimingItems | Measure-Object -Property ms -Sum).Sum
    Write-Host ("  {0,-30} {1,8} ms" -f '合计', $sum) -ForegroundColor White
}

Write-Host ''
