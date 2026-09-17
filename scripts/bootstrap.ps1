#Requires -Version 5.1
<#
.SYNOPSIS
  一键把本机改造成"声明式工具链"模式：装好 mise、写入机器声明、配好 PATH。

.DESCRIPTION
  设计目标：让任何一台机器都能用同一条命令到达同一个状态。

  这个脚本只做四件事，且每件都是幂等的（重复执行结果相同）：
    1. 安装 mise（按 winget → scoop → choco → npm → 手工下载 的顺序尝试）
    2. 把仓库里的 mise/config.toml 写成全局机器声明（覆盖前会备份）
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
  机器声明模板的路径。默认为本仓库的 mise/config.toml。

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

# ============================================================
# 常量
# ============================================================

# mise 在 Windows 上的默认目录布局
$MiseDataDir  = Join-Path $env:LOCALAPPDATA 'mise'
$MiseShimsDir = Join-Path $MiseDataDir 'shims'
$MiseConfigDir  = Join-Path $env:USERPROFILE '.config\mise'
$MiseConfigFile = Join-Path $MiseConfigDir 'config.toml'

if (-not $ConfigSource) {
    $ConfigSource = Join-Path (Split-Path $PSScriptRoot -Parent) 'mise\config.toml'
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
    Write-Warn2 '跳过这一步。请手工把 mise/config.toml 复制到 ' + $MiseConfigFile
} else {
    Write-Ok "模板: $ConfigSource"
    Write-Ok "目标: $MiseConfigFile"

    if (Test-Path -LiteralPath $MiseConfigFile) {
        # 已有配置不直接覆盖：先备份，再由用户决定是否采用新模板
        $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup = "$MiseConfigFile.bak-$stamp"
        Invoke-Action "备份已有配置到 $backup" {
            Copy-Item -LiteralPath $MiseConfigFile -Destination $backup -Force
        }
        if (-not $DryRun) { Write-Warn2 "检测到已有配置，已备份。脚本会写入新模板，你之后可以对比合并。" }
    }

    Invoke-Action "创建目录并写入配置" {
        New-Item -ItemType Directory -Force -Path $MiseConfigDir | Out-Null
        Copy-Item -LiteralPath $ConfigSource -Destination $MiseConfigFile -Force
    }
    Write-Done '机器声明已就位'
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

# 3a. 把 shims 目录加入用户级 PATH
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
if ($null -eq $userPath) { $userPath = '' }
$userEntries = @($userPath -split ';' | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') })

if ($userEntries -contains $MiseShimsDir.TrimEnd('\')) {
    Write-Skip "shims 目录已在用户级 PATH 中: $MiseShimsDir"
} else {
    Invoke-Action "把 $MiseShimsDir 加入用户级 PATH" {
        $newPath = (@($userEntries) + $MiseShimsDir) -join ';'
        [Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
    }
    Write-Done 'shims 目录已加入用户级 PATH'
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

    if (-not (Test-Path -LiteralPath $PROFILE)) {
        Invoke-Action "创建 PowerShell 配置文件 $PROFILE" {
            New-Item -ItemType Directory -Force (Split-Path -Parent $PROFILE) | Out-Null
            New-Item -ItemType File -Path $PROFILE -Force | Out-Null
        }
    }

    $already = $false
    if (Test-Path -LiteralPath $PROFILE) {
        $already = [bool](Select-String -Path $PROFILE -SimpleMatch $activation -Quiet -ErrorAction SilentlyContinue)
    }

    if ($already) {
        Write-Skip "激活行已存在于 $PROFILE"
    } else {
        Invoke-Action "向 $PROFILE 追加激活行" {
            Add-Content -Path $PROFILE -Value ''
            Add-Content -Path $PROFILE -Value '# 由 runtime-census 的 bootstrap.ps1 添加：让 mise 按项目声明自动切换运行时版本'
            Add-Content -Path $PROFILE -Value $activation
        }
        Write-Done "激活行已写入 $PROFILE"
        if (-not $DryRun) { Write-Warn2 '想撤销就删掉该文件里带 "runtime-census" 注释的那两行' }
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
    & mise doctor 2>&1 | ForEach-Object { "    $_" }
    Write-Host ''
    Write-Host '    当前 mise 管理的运行时：' -ForegroundColor DarkGray
    & mise ls 2>&1 | ForEach-Object { "      $_" }
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
