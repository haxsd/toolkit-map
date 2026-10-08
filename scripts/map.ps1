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
    [string]$Project = '',
    [string]$RulesFile = '',
    [switch]$AllowUnverified,
    [switch]$AllowIdeHost,
    [ValidateRange(0, 300)][int]$LockTimeoutSeconds = 60,
    [string]$Note = '',                      # add/find 用：备注
    [switch]$Prefer,                         # add 用：同时标记为首选

    [string]$Url = '',                       # install 用：portable 归档的直链
    [string]$Sha256 = '',                    # install 用：归档的可选 SHA256（可带 sha256: 前缀）
    [string]$Via = '',                       # install 用：'winget' 表示走包管理器兜底
    [string]$WingetId = '',                  # install 用：包管理器里的包 ID（默认用工具名）
    [string]$MapFile = '',                   # 覆盖地图位置（默认 ~/.toolkit/map.json）
    [int]$MaxAgeHours = 24,                  # status 用：超过多少小时算旧

    [switch]$Json,                           # 机器可读输出（agent 用这个）
    [switch]$SkipScan,                       # find 用：地图里没有时不去现场搜
    [switch]$WhatIf                          # install 用：只打印要做什么
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 的 Invoke-WebRequest 逐块刷新进度条，下载大文件会慢一个数量级。
$ProgressPreference = 'SilentlyContinue'

# ---------- 路径与常量 ----------



# 统一仓库：新装的工具落在这里，按 <工具>/<版本>/ 并列。
# 注意它不进 PATH —— PATH 只应该有一个间接层，多版本塞进 PATH 只会互相遮蔽。


# 版本号唯一来源是仓库根目录的 VERSION；文档里的稳定标签由 tests/check-docs.ps1 校验一致。
function Get-ToolkitVersion {
    $file = Join-Path (Split-Path $PSScriptRoot -Parent) 'VERSION'
    if (-not [IO.File]::Exists($file)) { return '' }
    return ([IO.File]::ReadAllText($file)).Trim()
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
    'powershell', 'pwsh', 'bash', 'tar', 'ssh', 'scp', 'vim', 'nvim', 'code', 'unzip', 'ncat',
    # 逆向 / 安全（本机用户的工作范围，值得进地图）
    'jadx', 'apktool', 'adb', 'frida', 'objection', 'r2', 'rabin2', 'radare2',
    'nmap', 'masscan', 'sqlmap', 'hashcat', 'john', 'tshark', 'yara', 'binwalk',
    'exiftool', 'steghide', 'strings', 'objdump', 'readelf', 'gdb', 'lldb', 'dumpbin'
)

# 核心与数据配方都相对本脚本定位，可从任意项目调用。
$script:MapScriptPath = $PSCommandPath
. (Join-Path $PSScriptRoot 'toolkit-common.ps1')
. (Join-Path $PSScriptRoot 'map-core.ps1')
$script:ToolCatalog = (ConvertTo-HashtableDeep ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'tools.json')) | ConvertFrom-Json)).tools

# portable 归档的来源。两种形态：
#   · GitHub 发布：repo + tag + asset 三段模板。tag 与资产文件名的 v 前缀经常不一致
#     （jadx 的 tag 是 v1.5.6，资产却叫 jadx-1.5.6.zip），所以模板分开写、版本号按裸版本处理。
#   · 固定 URL：配方钉死带版本号的官方地址、版本与 SHA256（如 Google 的 platform-tools），
#     不使用"永远指向最新"的地址——那种地址的内容会变，无法预先核对校验值。
$Recipes = (ConvertTo-HashtableDeep ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'tools.json')) | ConvertFrom-Json)).recipes

# ---------- 网络访问：容忍"证书吊销服务器不可达"的机器 ----------
#
# 实测环境：受限网络里连不上 CRL/OCSP 服务器时，Windows PowerShell 5.1（.NET Framework）
# 在开启吊销检查时会让 Invoke-WebRequest / Invoke-RestMethod 直接失败，报"基础连接已经关闭:
# 未能为 SSL/TLS 安全通道建立信任关系"，看起来像网络不通，实际只是本地无法确认证书有
# 没有被吊销（同一台机器的 curl 报的是 CRYPT_E_REVOCATION_OFFLINE，能对上）。
#
# 处理：先按默认设置请求一次；只有同时满足下面三条，才在【本进程内】临时关掉吊销检查重试一次，
# 并明确告知使用者——不静默降级，也不写任何系统设置：
#   · 宿主是 Windows PowerShell 5.1：PowerShell 7 的网络命令基于 HttpClient，
#     ServicePointManager 对它不起作用，重试只会重复同一个错误，所以不重试；
#   · 本进程确实开着吊销检查（.NET Framework 默认是关着的，只有被显式打开时才会因吊销失败）：
#     已经关着时再"关一次"毫无意义，失败说明是别的信任问题；
#   · 错误信息指向信任关系/吊销，而不是笼统的 SSL/TLS/certificate 字样。
# 其他错误（404、超时、证书过期或域名不符、校验失败……）原样抛出。
$RevocationErrorPattern = '(?i)trust relationship|信任关系|revocation|吊销|CRYPT_E_REVOCATION|OfflineRevocation|RevocationStatusUnknown'

function Get-ExceptionMessageChain {
    param($ErrorRecord)
    $messages = New-Object System.Collections.Generic.List[string]
    $exception = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
    while ($exception) { $messages.Add("$($exception.Message)"); $exception = $exception.InnerException }
    return ($messages -join ' | ')
}

function Test-RevocationRetryApplicable {
    param($ErrorRecord)
    if ($PSVersionTable.PSEdition -eq 'Core') { return $false }
    if (-not [Net.ServicePointManager]::CheckCertificateRevocationList) { return $false }
    return ((Get-ExceptionMessageChain $ErrorRecord) -match $RevocationErrorPattern)
}

function Invoke-NetRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$What = '网络请求'
    )
    try {
        return & $Action
    } catch {
        $first = $_
    }
    if (-not (Test-RevocationRetryApplicable $first)) { throw $first }

    $before = [Net.ServicePointManager]::CheckCertificateRevocationList
    try {
        [Net.ServicePointManager]::CheckCertificateRevocationList = $false
        Write-MapWarning "$What 失败：$($first.Exception.Message)"
        Write-MapWarning '本机可能连不上证书吊销服务器，已在本进程内临时关闭吊销检查后重试（不改系统设置）'
        return & $Action
    } finally {
        [Net.ServicePointManager]::CheckCertificateRevocationList = $before
    }
}

# ---------- 下载完整性 ----------
# 配方安装必须有来自官方的 SHA256，按优先级取：
#   1. 配方钉死的值（固定 URL 形态，例如带版本号的 platform-tools 地址）；
#   2. GitHub 为发布资产计算的 digest（API 的 assets[].digest，"sha256:..."）；
#   3. 上游随发布附带的校验文件（配方的 checksums 模板，例如 gh 的 checksums.txt、rg 的 .sha256）。
# 都取不到就拒绝下载，除非用户用 -Sha256 给出自己从官方渠道核实过的值；
# 用户给了值时也要与官方值一致。-Url 自定义直链的 -Sha256 仍是可选的。
function Get-GitHubRelease {
    param([string]$Repo, [string]$Tag = '')
    $api = if ($Tag) { "https://api.github.com/repos/$Repo/releases/tags/$Tag" } else { "https://api.github.com/repos/$Repo/releases/latest" }
    return (Invoke-NetRetry -What "读取 $Repo 的发布信息" -Action {
        Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'toolkit-map'; 'Accept' = 'application/vnd.github+json' } -TimeoutSec 30
    })
}

function Get-ChecksumFromText {
    # 支持 "<hash>  <文件名>"（sha256sum / checksums.txt，文件名可带 * 或路径）、只有一个哈希的 .sha256 文件，
    # 以及 CertUtil -hashfile 的输出（"SHA256 hash of <文件名>:" 下一行是哈希；ripgrep 的 Windows 资产用这种格式）。
    param([string]$Text, [string]$Asset)
    $lines = @("$Text" -split "`r?`n" | Where-Object { $_.Trim() })
    foreach ($line in $lines) {
        if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') {
            if ([IO.Path]::GetFileName(($Matches[2] -replace '\\', '/')) -eq $Asset) { return $Matches[1].ToLowerInvariant() }
        }
    }
    $bare = @($lines | Where-Object { $_ -match '^\s*[0-9a-fA-F]{64}\s*$' })
    if ($bare.Count -eq 1 -and ($lines.Count -eq 1 -or @($lines | Where-Object { $_ -match ('^SHA256 hash of (.*[\\/])?' + [regex]::Escape($Asset) + ':\s*$') }).Count -eq 1)) {
        return $bare[0].Trim().ToLowerInvariant()
    }
    return ''
}

function Resolve-RecipeSha256 {
    param($Recipe, [string]$Version, [string]$Tag, [string]$Asset)
    if ($Recipe.sha256) { return @{ sha256 = "$($Recipe.sha256)".ToLowerInvariant(); source = 'recipe' } }
    if (-not $Recipe.repo) { return $null }
    $release = Get-GitHubRelease -Repo $Recipe.repo -Tag $Tag
    $assetInfo = @($release.assets | Where-Object { $_.name -eq $Asset } | Select-Object -First 1)
    if (-not $assetInfo.Count) { Throw-MapError 'asset_missing' "$($Recipe.repo) 的发布 $Tag 中没有资产 $Asset。" }
    if ("$($assetInfo[0].digest)" -match '^sha256:([0-9a-fA-F]{64})$') { return @{ sha256 = $Matches[1].ToLowerInvariant(); source = 'github-asset-digest' } }
    if ($Recipe.checksums) {
        $sumName = ($Recipe.checksums -replace '\{ver\}', $Version) -replace '\{asset\}', $Asset
        $sumInfo = @($release.assets | Where-Object { $_.name -eq $sumName } | Select-Object -First 1)
        if ($sumInfo.Count) {
            $sumUrl = "$($sumInfo[0].browser_download_url)"
            $text = Invoke-NetRetry -What "下载校验文件 $sumName" -Action {
                Invoke-RestMethod -Uri $sumUrl -Headers @{ 'User-Agent' = 'toolkit-map' } -TimeoutSec 30
            }
            if ($text -is [byte[]]) { $text = [Text.Encoding]::UTF8.GetString($text) }
            $hash = Get-ChecksumFromText -Text "$text" -Asset $Asset
            if ($hash) { return @{ sha256 = $hash; source = 'upstream-checksums' } }
        }
    }
    return $null
}

# 版本号不许猜：@latest 走 GitHub API 拿最新发布的 tag。
# agent 不该凭记忆写版本号，机器也不该让它去猜。
function Resolve-LatestVersion {
    param([string]$Repo)
    try {
        $rel = Get-GitHubRelease -Repo $Repo
        return ("$($rel.tag_name)" -replace '^v', '')
    } catch {
        throw "拿不到 $Repo 的最新版本（$($_.Exception.Message)）。请显式给版本：install <tool>@<版本>"
    }
}

# 带提取规则的版本探测：有些工具的 --version 第一行不是版本号
# （adb 第一行是协议版本 1.0.41，平台工具版本在第二行），所以配方可以自带正则。
function Get-ExeVersionByPattern {
    param([string]$ExePath, [string]$Pattern)
    if (-not $Pattern) { return (Get-ExeVersion $ExePath) }
    foreach ($flag in @('--version', '-version', 'version')) {
        # 与通用探测共用同一个取输出的通道：stderr 也要读（Java 一类把版本写在 stderr）
        $out = Get-ProbeText -Exe $ExePath -Arguments @($flag) -MaxLines 4
        if (-not $out) { continue }
        $m = [regex]::Match($out, $Pattern)
        if ($m.Success) {
            return $(if ($m.Groups.Count -gt 1) { $m.Groups[1].Value } else { $m.Value })
        }
    }
    return ''
}

function Assert-ArchiveSha1 {
    # 只用于核对上游只公布 SHA-1 的官方值（Google SDK 仓库清单）；SHA256 仍是主校验。
    param([string]$ArchivePath, [string]$Expected)
    if (-not $Expected) { return }
    $actual = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA1).Hash
    if (-not [string]::Equals($actual, $Expected.Trim(), [StringComparison]::OrdinalIgnoreCase)) {
        throw "归档 SHA1 与官方清单不匹配：期望 $Expected，实际 $actual"
    }
}

function Assert-ArchiveSha256 {
    param([string]$ArchivePath, [string]$Expected)
    if (-not $Expected) { return }
    $normalized = $Expected.Trim() -replace '^sha256:', ''
    if ($normalized -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'SHA256 必须是 64 位十六进制字符串（可带 sha256: 前缀）'
    }
    $actual = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash
    if (-not [string]::Equals($actual, $normalized, [StringComparison]::OrdinalIgnoreCase)) {
        throw "归档 SHA256 不匹配：期望 $normalized，实际 $actual"
    }
    Write-MapMessage '  SHA256 校验通过。' -ForegroundColor DarkGray
}

# winget 兜底安装的可替换步骤：测试用假实现替换，不触网、不读本机注册表。
function Invoke-WingetCommand {
    param([string]$Exe, [string[]]$Arguments)
    $output = @(& $Exe @Arguments 2>&1)
    return @{ exitCode = $LASTEXITCODE; output = $output }
}
function Get-InstallerRefreshedPath {
    return ([Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH', 'User'))
}
function Test-InstalledSince {
    # 安装器常保留文件的原始修改时间，所以创建时间与修改时间任一晚于安装开始即可（留 5 秒余量）。
    param([string]$P, [datetime]$Since)
    $item = Get-Item -LiteralPath $P -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    $edge = $Since.AddSeconds(-5)
    return ($item.CreationTimeUtc -ge $edge -or $item.LastWriteTimeUtc -ge $edge)
}
function Find-NewInstalledExecutable {
    param([string]$Name, [datetime]$Since)
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Programs' }))
    $seen = @{}
    foreach ($root in $roots) {
        if (-not $root -or -not [IO.Directory]::Exists($root)) { continue }
        Get-ChildItem -LiteralPath $root -Recurse -Depth 3 -File -Filter "$Name.*" -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -eq $Name -and $_.Extension -in @('.exe', '.cmd', '.bat') -and (Test-InstalledSince $_.FullName $Since) } |
            ForEach-Object {
                $key = Get-ToolkitNormalizedPath $_.FullName
                if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $_.FullName }
            }
    }
}

function Invoke-Install {
    if (-not $Tool) { throw "用法：map.ps1 install <tool>@<版本|latest>（或 install <tool> -Url <zip 直链> [-Sha256 <校验值>]，或 install <tool> -Via winget）" }
    $existingMap = Read-Map # 先验证地图，不能装完才发现地图损坏。

    # ---- 兜底路径：只能走安装器的工具（nmap、驱动类、需要注册表/服务集成的） ----
    # 统一仓库的理想是"装完长一样"，但不该为了形式统一而拒绝安装。这里允许装到包管理器
    # 自己的位置，装完在地图里标注真实路径与"不在仓库"的原因——它仍然是可发现的。
    if ($Via) {
        if ($Via -ne 'winget') { throw "目前只支持 -Via winget（其余情况请人工安装后用 map.ps1 add 登记）" }
        # 地图键与其他动作一致：规范化 + 单个名称校验；包 ID 不能以 - 开头，避免被 winget 当成选项。
        $name = Get-ToolkitCanonicalName $Tool
        if ($Tool -match '@' -or $name -notmatch '^[a-z0-9][a-z0-9._+-]*$') {
            Throw-MapError 'invalid_argument' '工具名必须是单个名称，不能包含路径、分隔符或 @版本（winget 版本由包管理器决定）。'
        }
        $id = if ($WingetId) { $WingetId } else { $Tool }
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') { Throw-MapError 'invalid_argument' 'winget 包 ID 只能包含字母、数字与 . _ + -，且不能以 - 开头。' }
        Write-MapMessage "用 winget 安装 $id（装到包管理器自己的位置，不在统一仓库）…" -ForegroundColor Cyan
        if ($WhatIf) { return (New-MapResult 'planned' @{ tool = $name; via = 'winget'; packageId = $id; destination = 'package-manager' }) }

        $wingetPaths = @(Get-PathHits 'winget' | Where-Object { -not (Test-IsShimPath $_) -and [IO.Path]::GetExtension($_) -in @('.exe', '.cmd', '.bat') })
        if (-not $wingetPaths.Count) { Throw-MapError 'installer_missing' '未找到可直接调用的 winget；不会执行 shim 安装器。' }
        $installStart = (Get-Date).ToUniversalTime()
        $winget = Invoke-WingetCommand -Exe $wingetPaths[0] -Arguments @('install', '--id', $id, '--exact', '--silent', '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
        @($winget.output) | Select-Object -Last 3 | ForEach-Object { Write-MapMessage ('  ' + $_) }
        if ($winget.exitCode -ne 0) { throw "winget 安装失败（退出码 $($winget.exitCode)）：$id" }

        # 关键一步：当前进程的 PATH 是安装前的旧环境（子进程继承，不会跟着注册表变），
        # 所以先用注册表现算一份新 PATH 再搜，否则"装好了却找不到"。
        $saved = $env:PATH
        try {
            $env:PATH = Get-InstallerRefreshedPath
            $cands = @(Get-ToolCandidates -Name $name -RuntimeIndex @{})
            $fresh = @($cands | Where-Object { Test-InstalledSince $_.path $installStart })
            # 有些安装器不把目录写进 PATH：再往公认安装位置里找本次新装的文件。
            # 只认安装开始之后出现的文件，多于一个就不猜，避免把同名的旧文件登记成 winget 安装。
            if (-not $fresh.Count) {
                $hits = @(Find-NewInstalledExecutable -Name $name -Since $installStart)
                if ($hits.Count -gt 1) { Throw-MapError 'installed_ambiguous' "winget 装完后找到多个新的 $name 可执行文件，不猜测：$($hits -join '; ')。请确认后用 add 登记。" }
                if ($hits.Count -eq 1) { $c = New-Candidate -P $hits[0]; $fresh = @($c); $cands = @($cands) + @($c) }
            }
            if ($cands.Count -eq 0) {
                Throw-MapError 'installed_not_discovered' "winget 装完了，但没找到 $name 的可执行文件。请确认路径后用 add 登记。"
            }
            $map = Read-Map
            if ($null -eq $map) { $map = @{ schemaVersion = 2; warehouse = Get-WarehouseRoot; tools = @{}; scannedAt = $null; pathSnapshot = $saved } }
            if (-not $map.tools.ContainsKey($name)) { $map.tools[$name] = @{ candidates = @(); preferred = ''; preferredPath = '' } }
            $freshPaths = @($fresh | ForEach-Object { $_.path })
            foreach ($c in $cands) {
                # 只有本次新出现的文件才标注为 winget 安装；PATH 上原有的同名副本照常登记、不改说明。
                if ($freshPaths -contains $c.path) { $c.note = 'winget 安装（不在统一仓库）；升级/卸载交给 winget' }
                if (-not (@($map.tools[$name].candidates) | Where-Object { $_.path -eq $c.path })) {
                    $map.tools[$name].candidates = @($map.tools[$name].candidates) + @($c)
                }
            }
            Save-Map $map
            Write-MapMessage ("  已登记进地图：map.ps1 find {0}" -f $name) -ForegroundColor Green
        } finally { $env:PATH = $saved }
        $fields = @{ tool = $name; via = 'winget'; packageId = $id; installed = $freshPaths; mapFile = Get-MapPath }
        if (-not $freshPaths.Count) { $fields.hint = '未发现本次新出现的可执行文件（可能是原位升级）；已登记 PATH 上现有的副本，请用 find 核对。' }
        return (New-MapResult 'ok' $fields)
    }

    $name = $Tool; $ver = $Version
    if ($Tool -match '@') { $parts = $Tool -split '@', 2; $name = $parts[0]; $ver = $parts[1] }
    $name = Get-ToolkitCanonicalName $name
    if ($name -notmatch '^[a-z0-9][a-z0-9._-]*$' -or ($ver -and $ver -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._+-]*$')) {
        Throw-MapError 'invalid_argument' '工具名与版本必须是单个名称，不能包含路径或分隔符。'
    }

    $root = Get-WarehouseRoot
    $url = $Url
    # 注意 PowerShell 变量不分大小写：$url 与参数 $Url 是同一个变量，配方分支用 $fromRecipe 区分。
    $recipe = $null; $fromRecipe = $false; $tag = ''; $asset = ''
    if ($url -and $ver -eq 'latest') { $ver = '' }
    $ver = "$ver" -replace '^v(?=\d)', ''
    $exeRel = ''
    if (-not $url) {
        if (-not $Recipes.ContainsKey($name)) {
            throw "没有 $name 的 portable 配方。请给直链：map.ps1 install $name -Url <zip 直链> -Version $ver（或用包管理器装，然后 map.ps1 add 登记）"
        }
        $recipe = $Recipes[$name]
        $fromRecipe = $true
        $exeRel = $recipe.exe
        if ($recipe.url) {
            # 固定 URL 形态：配方钉死带版本号的官方地址与校验值，latest 即配方版本。
            # 其他版本没有可核实的校验值，不猜地址，交给 -Url 与 -Sha256。
            $url = $recipe.url
            $requested = "$ver" -replace '^v', ''
            if ($recipe.version) {
                if ($requested -and $requested -ne 'latest' -and $requested -ne "$($recipe.version)") {
                    Throw-MapError 'version_unavailable' "$name 配方固定为 $($recipe.version)（官方带版本号的地址与校验值）；其他版本请用 -Url 与 -Sha256 指定。"
                }
                $ver = "$($recipe.version)"
            } elseif ($requested -and $requested -ne 'latest') { $ver = $requested } else { $ver = '' }
        } else {
            # GitHub 发布形态：版本号一律按裸版本处理（'v1.5.6' 与 '1.5.6' 等价），latest 走 API
            $ver = "$ver" -replace '^v', ''
            if (-not $ver -or $ver -eq 'latest') {
                if ($WhatIf) {
                    return (New-MapResult 'planned' @{ tool = $name; version = 'latest'; warehouse = $root; recipe = $recipe; networkRequired = $true })
                }
                Write-MapMessage "解析 $name 的最新版本（GitHub API）…" -ForegroundColor DarkGray
                $ver = Resolve-LatestVersion -Repo $recipe.repo
            }
            $tag = $recipe.tag -replace '\{ver\}', $ver
            $asset = $recipe.asset -replace '\{ver\}', $ver
            $url = "https://github.com/$($recipe.repo)/releases/download/$tag/$asset"
        }
    }

    Write-MapMessage "将把 $name $(if ($ver) { $ver } else { '(版本装完探测)' }) 装到仓库：$(Join-Path $root $name)" -ForegroundColor Cyan
    Write-MapMessage "  下载：$url" -ForegroundColor DarkGray
    if ($ver -and $WhatIf) {
        $knownTarget = Join-Path (Join-Path $root $name) $ver
        if (Test-Path -LiteralPath $knownTarget) {
            throw "目标版本已存在，拒绝覆盖：$knownTarget"
        }
    }
    $integrityPlan = if ($fromRecipe) { 'required' } elseif ($Sha256) { 'user' } else { 'none' }
    if ($WhatIf) { return (New-MapResult 'planned' @{ tool = $name; version = $ver; url = $url; warehouse = $root; integrity = $integrityPlan }) }
    # 同版本可用副本已在其他位置时，直接复用，不重复安装或迁移。
    if ($ver) {
        $registered = if ($existingMap -and $existingMap.tools[$name]) { @($existingMap.tools[$name].candidates) } else { @() }
        $existingCandidates = @(Merge-Candidates (Get-ToolCandidates $name) $registered)
        foreach ($candidate in $existingCandidates) {
            $candidate = New-Candidate $candidate.path $candidate.version
            if ($candidate.verification -eq 'verified' -and (Test-CandidateRequirement $candidate $ver $name)) {
                return (New-MapResult 'already_available' @{ tool = $name; path = $candidate.path; version = $candidate.version; verification = $candidate.verification })
            }
        }
        $knownTarget = Join-Path (Join-Path $root $name) $ver
        if (Test-Path -LiteralPath $knownTarget) { throw "目标版本已存在且没有可验证副本，拒绝覆盖：$knownTarget" }
    }

    # 配方安装：下载前先拿到官方 SHA256，拿不到就不下载（用户 -Sha256 可替代，但要与官方值一致）。
    $integrity = @{ sha256 = ''; source = 'none' }
    if ($fromRecipe) {
        $official = Resolve-RecipeSha256 -Recipe $recipe -Version $ver -Tag $tag -Asset $asset
        if ($official) {
            if ($Sha256 -and -not [string]::Equals(($Sha256.Trim() -replace '^sha256:', ''), $official.sha256, [StringComparison]::OrdinalIgnoreCase)) {
                Throw-MapError 'checksum_conflict' "-Sha256 与官方值（$($official.source)）不一致，拒绝下载。"
            }
            $integrity = $official
        } elseif ($Sha256) {
            $integrity = @{ sha256 = ($Sha256.Trim() -replace '^sha256:', '').ToLowerInvariant(); source = 'user' }
        } else {
            Throw-MapError 'checksum_unavailable' "无法从官方来源取得 $name $ver 的 SHA256（发布资产没有 digest，也没有上游校验文件）；请在官方发布页核实后用 -Sha256 指定。"
        }
    } elseif ($Sha256) {
        $integrity = @{ sha256 = ($Sha256.Trim() -replace '^sha256:', '').ToLowerInvariant(); source = 'user' }
    }

    # 先在暂存目录里下载+解压+验证，全部通过后再整体搬进仓库——
    # 这样失败不会在仓库里留下半个目录（半成品最难排查：它看起来像装好了）。
    $stage = [IO.Path]::GetFullPath((Join-Path $env:TEMP ("tk-" + [guid]::NewGuid().ToString('N'))))
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $movedTarget = $false
    $finalValidated = $false
    try {
        $zip = Join-Path $stage 'pkg.zip'
        Invoke-NetRetry -What "下载 $url" -Action { Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing }
        Assert-ArchiveSha256 -ArchivePath $zip -Expected $integrity.sha256
        if ($fromRecipe) { Assert-ArchiveSha1 -ArchivePath $zip -Expected "$($recipe.sha1)" }
        $extract = Join-Path $stage 'x'
        Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force

        # 归档里往往多一层同名目录，压平一层，保证 <仓库>/<工具>/<版本>/<文件> 的布局稳定
        $entries = @(Get-ChildItem -LiteralPath $extract -Force)
        if ($entries.Count -eq 1 -and $entries[0].PSIsContainer) {
            $inner = $entries[0].FullName
            foreach ($f in (Get-ChildItem -LiteralPath $inner -Force)) { Move-Item -LiteralPath $f.FullName -Destination $extract -Force }
            Remove-Item -LiteralPath $inner -Recurse -Force -ErrorAction SilentlyContinue
        }

        # 找可执行文件：配方给的是相对路径；没配方就挑一个与工具同名的
        $exe = ''
        if ($exeRel) {
            $cand = Join-Path $extract $exeRel
            if (Test-Path -LiteralPath $cand) { $exe = $cand }
        }
        if (-not $exe) {
            $found = @(Get-ChildItem -LiteralPath $extract -Recurse -File -ErrorAction SilentlyContinue |
                       Where-Object { $_.BaseName -eq $name -and $_.Extension -in @('.exe', '.cmd', '.bat', '') } |
                       Select-Object -First 1)
            if ($found.Count -gt 0) { $exe = $found[0].FullName }
        }
        if (-not $exe) {
            Throw-MapError 'executable_missing' "归档中未找到 $name 的可执行文件，安装未完成。"
        }

        # 版本未知（固定 URL 形态）就从可执行文件里探一个出来，目录名必须带版本。
        # 用配方自带的正则（如果有）：有些工具 --version 第一行不是版本号（adb 第一行是
        # 协议版本 1.0.41，平台工具版本在第二行），通用探测会记错。
        if (-not $ver) {
            $vpat = ''
            if ($recipe -and $recipe.versionPattern) { $vpat = $recipe.versionPattern }
            $probed = Get-ExeVersionByPattern -ExePath $exe -Pattern $vpat
            if (-not $probed) { Throw-MapError 'probe_failed' '无法验证下载工具的版本；安装未完成。' }
            $ver = $probed
            Write-MapMessage "  探测到版本：$ver" -ForegroundColor DarkGray
        }
        $target = Join-Path (Join-Path $root $name) $ver
        $actualVersion = Get-ExeVersion $exe
        if (-not $actualVersion -or -not (Test-CandidateRequirement @{ version = $actualVersion; path = $exe } $ver $name)) {
            Throw-MapError 'version_mismatch' "下载工具版本未通过验证：要求 $ver，实际 $actualVersion。"
        }
        if (-not (Test-ToolkitUnderRoot $target $root)) { Throw-MapError 'invalid_path' '安装目标不在统一仓库内。' }
        if (Test-Path -LiteralPath $target) {
            throw "目标版本已存在，拒绝覆盖：$target"
        }
        New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
        Move-Item -LiteralPath $extract -Destination $target
        $movedTarget = $true
        $finalExe = Join-Path $target ($exe.Substring($extract.Length).TrimStart('\'))
        $c = New-Candidate -P $finalExe -VersionHint $actualVersion
        if ($c.verification -ne 'verified' -or -not (Test-CandidateRequirement $c $ver $name)) {
            Throw-MapError 'probe_failed' '工具移动到最终位置后验证失败，安装未完成。'
        }
        $finalValidated = $true
        $actualVersion = $c.version
        Write-MapMessage "  已安装：$finalExe" -ForegroundColor Green

        # 登记进地图并设为首选（同一工具的多个版本可以并存，目录并列）
        $map = Read-Map
        if ($null -eq $map) { $map = @{ schemaVersion = 1; warehouse = $root; tools = @{} } }
        if (-not $map.tools.ContainsKey($name)) { $map.tools[$name] = @{ preferred = ''; candidates = @() } }
        $map.tools[$name].candidates = @($map.tools[$name].candidates) + @($c)
        $map.tools[$name].preferred = $c.id
        $map.tools[$name].preferredPath = $finalExe
        Save-Map $map
        Write-MapMessage "  已登记进地图并设为首选：map.ps1 find $name" -ForegroundColor Green
        return (New-MapResult 'ok' @{ tool = $name; path = $finalExe; version = $actualVersion; verification = $c.verification; integrity = $integrity; mapFile = Get-MapPath })
    } catch {
        if ($movedTarget -and -not $finalValidated) {
            if (-not (Test-ToolkitUnderRoot $target $root) -or (Get-ToolkitNormalizedPath $target) -eq (Get-ToolkitNormalizedPath $root)) { throw '安装目标越界，拒绝回滚。' }
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
        }
        throw
    } finally {
        if (-not (Test-ToolkitUnderRoot $stage ([IO.Path]::GetFullPath($env:TEMP)))) { throw '暂存目录不在 TEMP 内，拒绝清理。' }
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}


# 入口在整个 read-modify-write 周期持锁；JSON stdout 恰好一个对象。
$mapMutex = $null
try {
    if ($Action.ToLowerInvariant() -in @('scan', 'find', 'add', 'update', 'install', 'setup')) { $mapMutex = Enter-MapLock }
    $result = switch ($Action.ToLowerInvariant()) {
        'scan'    { Invoke-Scan }
        'status'  { Invoke-Status }
        'find'    { Invoke-Find }
        'add'     { Invoke-Add }
        'update'  { Invoke-Update }
        'install' { Invoke-Install }
        'setup'   { Invoke-Setup }
        'doctor'  { Invoke-Doctor }
        'help'    { New-MapResult 'ok' @{ version = (Get-ToolkitVersion); actions = @('setup', 'doctor', 'scan', 'status', 'find', 'add', 'update', 'install'); hint = 'find <工具> [-Project <目录>] [-Version <版本>] -Json；setup [-Project <目录>] [-WhatIf]' } }
        default   { Throw-MapError 'invalid_action' "未知动作：$Action；执行 help 查看用法。" }
    }
    if ($null -eq $result) { $result = New-MapResult 'ok' @{ mapFile = Get-MapPath } }
    if ($Json) { $result | ConvertTo-Json -Depth 20 -Compress }
    elseif ($Action.ToLowerInvariant() -eq 'find' -and $result.found) {
        Write-Host ("{0} → {1}`n版本 {2}；验证 {3}；依据 {4}" -f $result.tool, $result.path, $result.version, $result.verification, $result.reason)
        if ($result.requirement.version) { Write-Host ("要求 {0}（{1}）" -f $result.requirement.version, $result.requirement.source) }
        $result.candidates | Format-Table path, version, source, verification, isShim -AutoSize
    } else { $result | Format-List | Out-String | Write-Host }
    if (-not $result.ok) { $script:MapExitCode = 1 } else { $script:MapExitCode = 0 }
} catch {
    $code = if ($_.Exception.Data['code']) { $_.Exception.Data['code'] } else { 'operation_failed' }
    $result = New-MapResult $code @{ message = $_.Exception.Message; found = $false; path = '' } $false
    if ($Json) { $result | ConvertTo-Json -Depth 20 -Compress } else { [Console]::Error.WriteLine($_.Exception.Message) }
    $script:MapExitCode = 1
} finally {
    if ($mapMutex) { $mapMutex.ReleaseMutex(); $mapMutex.Dispose() }
}
# dot-source 用于隔离测试导入函数时，不能终止调用方。
if ($MyInvocation.InvocationName -ne '.') { exit $script:MapExitCode }
