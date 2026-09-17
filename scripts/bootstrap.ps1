#Requires -Version 5.1
<#
.SYNOPSIS
  一键把本机改造成"声明式工具链"模式：装好 mise、写入机器声明、配好 PATH。

.DESCRIPTION
  设计目标：让任何一台机器都能用同一条命令到达同一个状态。

  这个脚本只做四件事，且每件都是幂等的（重复执行结果相同）：
    1. 安装 mise（按 winget → scoop → choco → npm → 手工下载 的顺序尝试）
    2. 把仓库里的 templates/mise-config.toml 写成全局机器声明（覆盖前会备份）
    3. 把 mise 的 shims 目录加入【用户级】PATH —— 这是唯一应该进 PATH 的工具链目录
    4. 执行 mise install，把声明的运行时拉取到位

  它刻意【不做】的事：
    - 不修改机器级（Machine）环境变量，避免影响其它用户和需要管理员权限的场合
    - 不删除已有的 PATH 条目。那些指向具体版本的旧条目只会被报告出来，由你决定
    - 不动 IDE 自带的运行时（JetBrains 的 JBR 属于 IDE 的一部分）

.PARAMETER DryRun
  只打印将要执行的改动，不实际修改任何东西。

.PARAMETER SkipTools
  只装 mise 和配置，不执行 mise install（适合先看看配置再决定装什么）。

.PARAMETER NoProfile
  不往 PowerShell $PROFILE 写 shell 激活行。写激活行能让 cd 进项目时自动切换版本，
  但会修改你的 shell 启动文件，所以默认通过开关控制而不是强加。

.PARAMETER ConfigSource
  机器声明模板的路径。默认为本仓库的 templates/mise-config.toml。
  模板刻意不放 mise/ 目录下：mise 会把 <任意目录>/mise/config.toml 当作项目配置自动读取，
  放那里会让仓库自己变成一个"未授权的 mise 项目"并报错。

.PARAMETER RefreshConfig
  用模板覆盖已部署的全局声明（覆盖前自动备份）。
  默认【不覆盖】：部署副本里可能有手工加的工具、registry 镜像或代理设置，
  无脑覆盖会把这些悄悄丢掉。所以默认只报告漂移，由你决定是否刷新。

.EXAMPLE
  .\bootstrap.ps1 -DryRun
  先看看会做哪些改动。

.EXAMPLE
  .\bootstrap.ps1 -NoProfile
  实际执行，但不修改 PowerShell 配置文件。
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SkipTools,
    [switch]$NoProfile,
    [switch]$RefreshConfig,
    [string]$ConfigSource = '',
    [string]$ToolsRoot = ''
)

$ErrorActionPreference = 'Stop'

# ============================================================
# 输出小工具
# ============================================================
function Write-Step  { param([string]$Text) Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Text) Write-Host "    [完成] $Text" -ForegroundColor Green }
function Write-Skip  { param([string]$Text) Write-Host "    [跳过] $Text" -ForegroundColor DarkGray }
function Write-Warn2 { param([string]$Text) Write-Host "    [注意] $Text" -ForegroundColor Yellow }
function Write-Plan  { param([string]$Text) Write-Host "    [计划] $Text" -ForegroundColor Magenta }
# 只在真正执行过之后才宣告完成；空运行模式下什么都不说，避免造成"已经改了"的错觉
function Write-Done  { param([string]$Text) if (-not $DryRun) { Write-Ok $Text } }

# 执行一条命令；-DryRun 时只打印不执行
function Invoke-Action {
    param([string]$Description, [scriptblock]$Action)
    if ($DryRun) {
        Write-Plan $Description
        return
    }
    & $Action
}

# 取出声明文件里 [tools] 段的工具名，用于说清"漂移"到底差在哪。
# 极简扫描：只认 section 内的 "键 = 值" 行，跳过注释，不解析数组与嵌套表
# （census.ps1 里有同样的实现，两处都刻意保持"够用就好"）。
function Get-ToolsSectionKeys {
    param([string]$Path)
    $keys = New-Object System.Collections.Generic.List[string]
    $inTools = $false
    foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        $t = "$line".Trim()
        if ($t -match '^\[') { $inTools = ($t -eq '[tools]'); continue }
        if (-not $inTools -or $t -eq '' -or $t.StartsWith('#')) { continue }
        $m = [regex]::Match($t, '^([A-Za-z0-9_\-\.]+)\s*=')
        if ($m.Success) { $keys.Add($m.Groups[1].Value) }
    }
    return $keys
}

# 探测 PowerShell 7 是否真的能用，返回版本号；不可用返回空串。
# 不能只看文件存不存在：WindowsApps 下的 pwsh.exe 是 0 字节的应用执行别名，
# 没装 Store 版 PowerShell 时它照样能被 Get-Command 找到，但执行会以 9009 退出。
# 所以必须真的跑一次——这也是 census 判断可用性的同一套办法。
function Get-PwshVersion {
    if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) { return '' }
    try {
        $v = (& pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null | Select-Object -First 1)
        return "$v".Trim()
    } catch { return '' }
}

# ============================================================
# 常量
# ============================================================

# mise 在 Windows 上的默认目录布局
$MiseDataDir  = Join-Path $env:LOCALAPPDATA 'mise'
$MiseShimsDir = Join-Path $MiseDataDir 'shims'
$MiseConfigDir  = Join-Path $env:USERPROFILE '.config\mise'
$MiseConfigFile = Join-Path $MiseConfigDir 'config.toml'

if (-not $ConfigSource) {
    $ConfigSource = Join-Path (Split-Path $PSScriptRoot -Parent) 'templates\mise-config.toml'
}

# 规范根：非托管的手装运行时的落脚点，按 <工具>/<版本>/ 排列。
# 优先级：命令行参数 > 环境变量 TOOLCHAIN_ROOT > 默认 ~/toolchains。
if (-not $ToolsRoot) { $ToolsRoot = $env:TOOLCHAIN_ROOT }
if (-not $ToolsRoot) { $ToolsRoot = Join-Path $env:USERPROFILE 'toolchains' }

Write-Host ''
Write-Host ' 工具链引导脚本 bootstrap.ps1' -ForegroundColor White
Write-Host ' 目标：把本机改造成声明式工具链模式' -ForegroundColor DarkGray
if ($DryRun) { Write-Host ' 模式：空运行（不会修改任何东西）' -ForegroundColor Magenta }

# ============================================================
# 步骤 0：环境自检
# ============================================================
Write-Step '环境自检'

Write-Ok "PowerShell $($PSVersionTable.PSVersion)"

$pkgManagers = @()
foreach ($pm in 'winget', 'scoop', 'choco', 'npm') {
    $cmd = Get-Command $pm -ErrorAction SilentlyContinue
    if ($cmd) {
        $pkgManagers += $pm
        Write-Ok "找到包管理器: $pm"
    }
}
if ($pkgManagers.Count -eq 0) {
    Write-Warn2 '没有找到任何包管理器，将走手工下载路线（需要网络访问 GitHub）'
}

# ============================================================
# 步骤 1：安装 mise
# ============================================================
Write-Step '安装 mise'

$miseCmd = Get-Command mise -ErrorAction SilentlyContinue
if ($miseCmd) {
    $existing = (& mise --version 2>&1 | Select-Object -First 1)
    Write-Skip "mise 已安装: $existing（位置 $($miseCmd.Source)）"
} else {
    # 按可靠性排序尝试。winget 在 Windows 10/11 上基本都存在，是首选。
    $installed = $false

    if (-not $installed -and $pkgManagers -contains 'winget') {
        Invoke-Action '通过 winget 安装 mise（winget install --id jdx.mise -e）' {
            winget install --id jdx.mise -e --accept-source-agreements --accept-package-agreements
        }
        $installed = $true
    }
    if (-not $installed -and $pkgManagers -contains 'scoop') {
        Invoke-Action '通过 scoop 安装 mise（scoop install mise）' { scoop install mise }
        $installed = $true
    }
    if (-not $installed -and $pkgManagers -contains 'choco') {
        Invoke-Action '通过 chocolatey 安装 mise（choco install mise -y）' { choco install mise -y }
        $installed = $true
    }
    if (-not $installed -and $pkgManagers -contains 'npm') {
        Invoke-Action '通过 npm 安装 mise（npm i -g mise）' { npm install -g mise }
        $installed = $true
    }
    if (-not $installed) {
        Write-Warn2 '没有可用的包管理器。请手工从 https://github.com/jdx/mise/releases 下载并放进 PATH。'
        Write-Warn2 'PowerShell 里不能用 mise.run 安装脚本——那个脚本只支持 macOS 和 Linux。'
        if (-not $DryRun) { exit 1 }
    }
    Write-Warn2 '安装完成后需要重开一个终端，mise 才会进入 PATH'
}

# ============================================================
# 步骤 2：写入全局机器声明
# ============================================================
Write-Step '写入全局机器声明'

if (-not (Test-Path -LiteralPath $ConfigSource)) {
    Write-Warn2 "找不到配置模板: $ConfigSource"
    Write-Warn2 '跳过这一步。请手工把 templates/mise-config.toml 复制到 ' + $MiseConfigFile
} else {
    Write-Ok "模板: $ConfigSource"
    Write-Ok "目标: $MiseConfigFile"

    # 先判断部署副本与模板是否一致。这一步解决的是"声明漂移"：
    # 模板是这台机器想要的状态，部署副本是现在实际声明的状态，两者是两份独立文件，
    # 没有任何机制保证同步——模板里新加的工具会永远装不上，而 census 只能看到部署副本，
    # 于是报告一切正常。
    $same = $false
    if (Test-Path -LiteralPath $MiseConfigFile) {
        try {
            $a = (Get-Content -LiteralPath $MiseConfigFile -Raw) -replace "`r`n", "`n"
            $b = (Get-Content -LiteralPath $ConfigSource  -Raw) -replace "`r`n", "`n"
            $same = ($a.Trim() -eq $b.Trim())
        } catch { $same = $false }
    }

    if ((Test-Path -LiteralPath $MiseConfigFile) -and $same) {
        Write-Skip '部署副本与模板一致，无需改写'
    } elseif (Test-Path -LiteralPath $MiseConfigFile) {
        # 漂移。默认不覆盖：部署副本里可能有手工加的工具、registry 镜像、代理设置。
        Write-Warn2 '检测到漂移：部署的配置与模板不一致'
        $tplKeys = @(Get-ToolsSectionKeys -Path $ConfigSource)
        $depKeys = @(Get-ToolsSectionKeys -Path $MiseConfigFile)
        $onlyTpl = @($tplKeys | Where-Object { $depKeys -notcontains $_ })
        $onlyDep = @($depKeys | Where-Object { $tplKeys -notcontains $_ })
        if ($onlyTpl.Count -gt 0) { Write-Host "      模板有而部署副本没有: $($onlyTpl -join ', ')" -ForegroundColor DarkYellow }
        if ($onlyDep.Count -gt 0) { Write-Host "      部署副本有而模板没有: $($onlyDep -join ', ')" -ForegroundColor DarkYellow }
        if ($onlyTpl.Count -eq 0 -and $onlyDep.Count -eq 0) { Write-Host '      [tools] 的键相同，但内容有差异（版本或注释不同）' -ForegroundColor DarkYellow }

        if ($RefreshConfig) {
            $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backup = "$MiseConfigFile.bak-$stamp"
            Invoke-Action "备份到 $backup 并按模板刷新" {
                Copy-Item -LiteralPath $MiseConfigFile -Destination $backup -Force
                Copy-Item -LiteralPath $ConfigSource  -Destination $MiseConfigFile -Force
            }
            Write-Done '已按模板刷新（备份保留，可对比合并）'
        } else {
            Write-Skip '保持现状（要按模板覆盖请加 -RefreshConfig，覆盖前会自动备份）'
        }
    } else {
        Invoke-Action "创建目录并写入配置" {
            New-Item -ItemType Directory -Force -Path $MiseConfigDir | Out-Null
            Copy-Item -LiteralPath $ConfigSource -Destination $MiseConfigFile -Force
        }
        Write-Done '机器声明已就位'
    }
}

# ============================================================
# 步骤：建立规范根
# ============================================================
Write-Step '建立规范根'

# 规范根是非托管运行时的落脚点。它刻意不进 PATH——PATH 里只应该有 mise 的
# shims 那一个工具链条目，加多了就会回到"多个版本争同一个名字"的老问题。
# 约定本身写在 AGENTS.md 规则 5 与 SKILL.md 里，census 的 [STRAY] 告警负责检查。
Write-Ok "规范根: $ToolsRoot"

if (Test-Path -LiteralPath $ToolsRoot) {
    Write-Skip '目录已存在'
} else {
    Invoke-Action "创建 $ToolsRoot" {
        New-Item -ItemType Directory -Force -Path $ToolsRoot | Out-Null
    }
    Write-Done '已创建'
}
if (-not $DryRun) {
    Write-Warn2 '今后手工安装的运行时请放在 <工具>/<版本>/ 子目录下（如 node/22.23.2）'
    Write-Warn2 '已经装在别处的运行时不要迁移——路径可能被项目配置写死，改成登记到声明文件'
}

# ============================================================
# 步骤 3：配置 PATH —— 全机只留一个工具链目录
# ============================================================
Write-Step '配置 PATH（核心步骤）'

Write-Host '    原则：PATH 里只应该出现 mise 的 shims 目录这一个工具链条目，' -ForegroundColor DarkGray
Write-Host '    而不是每个运行时各自一条（<系统盘>:\nodejs、Python312、jdk\bin ...）。' -ForegroundColor DarkGray

# 3a. 把 shims 目录放到用户级 PATH 的【首位】
#     为什么必须是首位而不是"加进去就行"：Windows 组合 PATH 的规则是
#     机器级在前、用户级在后，而解析命令时按组合后的顺序逐个目录找。
#     历史上手工装的直接目录（<系统盘>:\nodejs、Python312 ...）都排在前面，
#     shims 追加在尾部等于永远轮不到它——声明看起来生效了，实际没有。
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
if ($null -eq $userPath) { $userPath = '' }
$shims = $MiseShimsDir.TrimEnd('\')

# 重建用户级条目：顺手去掉重复项（PATH 有长度上限），并把 shims 摘出来单独放最前
$userEntries = New-Object System.Collections.Generic.List[string]
$seenEntry   = New-Object System.Collections.Generic.HashSet[string]
foreach ($raw in ($userPath -split ';')) {
    $e = "$raw".Trim().Trim('"').TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($e)) { continue }
    if ($e -ieq $shims) { continue }
    if (-not $seenEntry.Add($e.ToLowerInvariant())) { continue }
    $userEntries.Add($e)
}

$userFirst = if ($userEntries.Count -gt 0) { $userEntries[0] } else { '' }
if ($userFirst -ieq $shims) {
    Write-Skip "shims 已位于用户级 PATH 首位: $shims"
} else {
    Invoke-Action "把 $shims 放到用户级 PATH 首位（并去掉重复条目）" {
        $newPath = (@($shims) + $userEntries.ToArray()) -join ';'
        [Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
    }
    Write-Done 'shims 目录已置于用户级 PATH 首位'
    if (-not $DryRun) { Write-Warn2 '需要重开终端才生效' }
}

# 3b. 报告 PATH 里那些"指向具体版本"的旧条目
#     只报告不删除：它们可能还被别的工具依赖，删错代价高。
Write-Host ''
Write-Host '    以下 PATH 条目都指向具体版本，属于"该收敛掉"的候选：' -ForegroundColor DarkGray
$suspicious = @($userEntries | Where-Object {
    $_ -and ($_ -match '\\(nodejs|Python\d*|jdk|jre|Java|node|jbr)\b' -or
              $_ -match 'Java\\javapath' -or
              $_ -match '\\(node|python)\d')
})
if ($suspicious.Count -eq 0) {
    Write-Ok '没有发现需要收敛的条目'
} else {
    foreach ($s in $suspicious) { Write-Host "      - $s" -ForegroundColor Yellow }
    Write-Warn2 '脚本不会自动删除它们。确认 mise 工作正常后，可以手工清理。'
}

# 3c. 报告机器级 PATH 里的"直接工具目录"——这是改用户 PATH 解决不了的一类遮蔽。
#     Windows 组合 PATH 的规则是机器级在前、用户级在后，所以机器级里的
#     C:\ProgramData\Oracle\Java\javapath 这类目录会一直赢过 shims（实测 java 就是这样）。
#     修它需要管理员权限，脚本刻意不提权，只把事实和可选做法摆出来。
Write-Host ''
$machineEntries = @([Environment]::GetEnvironmentVariable('PATH', 'Machine') -split ';' | Where-Object { $_ })
$shadowers = New-Object System.Collections.Generic.List[string]
foreach ($raw in $machineEntries) {
    $d = "$raw".Trim().Trim('"').TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($d) -or -not (Test-Path -LiteralPath $d)) { continue }
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($exe in @('node.exe', 'java.exe', 'javac.exe', 'python.exe', 'npm.cmd', 'go.exe', 'cargo.exe', 'dotnet.exe')) {
        if (Test-Path -LiteralPath (Join-Path $d $exe)) { $hits.Add(($exe -replace '\.(exe|cmd)$', '')) }
    }
    if ($hits.Count -gt 0) { $shadowers.Add("$d（$($hits -join ', ')）") }
}
if ($shadowers.Count -eq 0) {
    Write-Ok '机器级 PATH 里没有会抢在 shims 前面的直接工具目录'
} else {
    Write-Warn2 "机器级 PATH 里有 $($shadowers.Count) 个直接工具目录，它们排在任何用户级条目之前，shims 抢不过："
    foreach ($s in $shadowers) { Write-Host "      - $s" -ForegroundColor Yellow }
    Write-Warn2 '这一类只能靠管理员权限把这些目录移出机器级 PATH，或接受"只有激活 mise 的会话才用对版本"'
    Write-Warn2 '（cmd、图形程序、IDE 任务、-NoProfile 脚本拿不到激活，会用到这里的旧版本）'
}

# ============================================================
# 步骤 4：配置 shell 激活（可选）
# ============================================================
Write-Step '配置 shell 激活'

if ($NoProfile) {
    Write-Skip '按参数要求跳过（-NoProfile）'
} else {
    # 激活行让 cd 进项目时自动按 .tool-versions 切换版本。
    # 不写的话，仍然可以用 mise exec -- <命令> 一次性激活，只是少了自动切换。
    # 激活行必须带存在性判断。
    # 否则在任何 mise 还不可解析的会话里（PATH 尚未刷新的新终端、用户卸载了 mise），
    # 每次启动 shell 都会抛 CommandNotFoundException——实测确实会这样。
    $activation = 'if (Get-Command mise -ErrorAction SilentlyContinue) { (&mise activate pwsh) | Out-String | Invoke-Expression }'

    # PowerShell 的 profile 是【分宿主】的：5.1 读 WindowsPowerShell 目录，7 读 PowerShell
    # 目录，两者互不加载。只写当前宿主的话，用户换到 pwsh 之后还得再跑一次脚本，
    # 所以两边都写。路径问各自的宿主要，这样 OneDrive 重定向过的 Documents 也不会写错地方。
    $pwshVersion = Get-PwshVersion
    $pwshProfile = ''
    if ($pwshVersion) {
        try { $pwshProfile = (& pwsh -NoProfile -Command '$PROFILE' 2>$null | Select-Object -First 1) } catch { }
        if ($pwshProfile) { $pwshProfile = "$pwshProfile".Trim() }
    }

    $targets = New-Object System.Collections.Generic.List[object]
    $targets.Add([pscustomobject]@{ host = "当前宿主 PowerShell $($PSVersionTable.PSVersion)"; path = $PROFILE })
    if ($pwshProfile -and ($pwshProfile -ne $PROFILE)) {
        $targets.Add([pscustomobject]@{ host = "PowerShell $pwshVersion (pwsh)"; path = $pwshProfile })
    }

    foreach ($t in $targets) {
        if (-not (Test-Path -LiteralPath $t.path)) {
            Invoke-Action "创建 $($t.path)" {
                New-Item -ItemType Directory -Force (Split-Path -Parent $t.path) | Out-Null
                New-Item -ItemType File -Path $t.path -Force | Out-Null
            }
        }

        $already = $false
        if (Test-Path -LiteralPath $t.path) {
            $already = [bool](Select-String -Path $t.path -SimpleMatch $activation -Quiet -ErrorAction SilentlyContinue)
        }

        if ($already) {
            Write-Skip "$($t.host): 激活行已存在"
        } else {
            Invoke-Action "向 $($t.path) 追加激活行" {
                Add-Content -Path $t.path -Value ''
                Add-Content -Path $t.path -Value '# 由 runtime-census 的 bootstrap.ps1 添加：让 mise 按项目声明自动切换运行时版本'
                Add-Content -Path $t.path -Value $activation
            }
            Write-Done "$($t.host): 激活行已写入 $($t.path)"
        }
    }
    if (-not $DryRun) { Write-Warn2 '想撤销就删掉 profile 里带 "runtime-census" 注释的那两行' }

    # 宿主结论。实测：5.1 下 mise activate 会打印
    #   "chpwd functionality requires PowerShell version 7 or higher"
    # 也就是说它只把 shims 前置到 PATH（等于把 mise 的版本设成全局默认），
    # 并不能在 cd 进项目时自动切换版本——而后者才是用 activate 的唯一理由。
    # 注意判断"有没有 PowerShell 7"不能看文件存不存在：WindowsApps 里的 pwsh.exe
    # 是 0 字节的应用执行别名，没装 Store 版时它照样存在但不可用，必须真的跑一次。
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        Write-Ok "当前宿主是 PowerShell $($PSVersionTable.PSVersion)，按项目自动切换可用"
    } elseif ($pwshVersion) {
        Write-Warn2 "当前宿主是 Windows PowerShell $($PSVersionTable.PSVersion)：它不支持 mise 的自动切换目录（chpwd 需要 PowerShell 7）"
        Write-Warn2 "本机已装 PowerShell $pwshVersion，两个宿主的 profile 都已写好——直接用 pwsh 打开终端即可"
    } else {
        Write-Warn2 "当前宿主是 Windows PowerShell $($PSVersionTable.PSVersion)：它不支持 mise 的自动切换目录（chpwd 需要 PowerShell 7）"
        Write-Warn2 '在 5.1 下激活只相当于把 mise 的版本设成全局默认；要按项目自动切换，请安装 PowerShell 7'
        Write-Warn2 '安装命令： winget install --id Microsoft.PowerShell -e'
    }
}

# ============================================================
# 步骤 5：拉取声明的运行时
# ============================================================
Write-Step '拉取声明的运行时'

if ($SkipTools) {
    Write-Skip '按参数要求跳过（-SkipTools）'
} elseif (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
    Write-Warn2 'mise 还不在当前会话的 PATH 里，无法执行 mise install。'
    Write-Warn2 '请重开终端后手工执行: mise install'
} else {
    Invoke-Action 'mise install（按机器声明拉取全部运行时）' { mise install }
    Write-Done '运行时已拉取'
}

# ============================================================
# 步骤 6：自检
# ============================================================
Write-Step '自检'

if (Get-Command mise -ErrorAction SilentlyContinue) {
    Write-Host ''
    # mise 会把告警写到 stderr（例如"非全局配置里的 auto_update 被忽略"）。
    # 本脚本全局启用了 $ErrorActionPreference='Stop'，而 2>&1 会把原生命令的 stderr
    # 变成终止性错误——实测会让脚本在最后一步直接退出，连收尾提示都打不出来。
    # 所以展示类调用在这里临时放开错误策略。
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & mise doctor 2>&1 | ForEach-Object { "    $_" }
        Write-Host ''
        Write-Host '    当前 mise 管理的运行时：' -ForegroundColor DarkGray
        & mise ls 2>&1 | ForEach-Object { "      $_" }
    } finally {
        $ErrorActionPreference = $prevEap
    }
} else {
    Write-Warn2 'mise 尚未在当前会话可用，跳过自检。重开终端后执行 mise doctor。'
}

# ============================================================
# 收尾
# ============================================================
Write-Host ''
Write-Host '======================================================================' -ForegroundColor DarkGray
Write-Host ' 完成。接下来的用法：' -ForegroundColor White
Write-Host '' -ForegroundColor DarkGray
Write-Host '   重开一个终端，然后：' -ForegroundColor Gray
Write-Host '' -ForegroundColor DarkGray
Write-Host '   盘点本机所有运行时（包括未被 mise 纳管的）' -ForegroundColor Gray
Write-Host '     .\scripts\census.ps1' -ForegroundColor Green
Write-Host '' -ForegroundColor DarkGray
Write-Host '   在项目里声明所需版本，然后一次性执行命令' -ForegroundColor Gray
Write-Host '     mise use node@22           # 写入项目 .tool-versions' -ForegroundColor Green
Write-Host '     mise exec -- node -v       # 零全局状态地激活一次' -ForegroundColor Green
Write-Host '' -ForegroundColor DarkGray
Write-Host '   查看这台机器上所有可用版本' -ForegroundColor Gray
Write-Host '     mise ls                    # 已安装' -ForegroundColor Green
Write-Host '     mise ls-remote node        # 可安装' -ForegroundColor Green
Write-Host '' -ForegroundColor DarkGray
if ($DryRun) {
    Write-Host ' 这是空运行。去掉 -DryRun 才会真正执行。' -ForegroundColor Magenta
}
Write-Host '======================================================================' -ForegroundColor DarkGray
Write-Host ''
