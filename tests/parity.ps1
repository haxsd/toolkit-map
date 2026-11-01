<#
.SYNOPSIS
  一致性测试：在同一个沙箱里跑 census.ps1 与 census.sh，断言两边都发现了同一批人造问题。

.DESCRIPTION
  为什么需要它：这个仓库有两份实现（PowerShell 与 shell），靠人肉保持同步，而漂移真实发生过——
  census.sh 曾因为 add_runtime 少收一个字段导致运行时清单静默变空，[STRAY] 永远不触发，
  报告却显示一切正常。与其相信"我改了另一份"，不如每次让机器对一遍。

  断言方式刻意不用"告警种类集合完全相等"：真实机器上还有别的运行时（IDE 自带的 JDK、
  历史遗留的 Node），两个实现看到的候选目录不同，集合必然有噪音。所以改成
  针对沙箱自己造出来的事实逐条断言（"两边都必须发现我埋的那颗雷"），既严格又不受环境干扰。

  沙箱里埋的雷：
    · 只写在文件名里的约定        node22（→ CONVENTION）
    · 声明与仓库模板不一致        （→ DRIFT）
    · 声明要求了但没装            census-absent-tool（→ MISSING）
    · PATH 里有重复条目           （→ PATH_DIRT）
    · 同一个运行时被遮蔽          两份不在 PATH 上的 node 副本（→ SHADOWED / STRAY）

.PARAMETER KeepSandbox
  保留沙箱目录，便于事后翻看两个实现的原始输出。

.EXAMPLE
  .\tests\parity.ps1
#>
[CmdletBinding()]
param([switch]$KeepSandbox)

$ErrorActionPreference = 'Stop'

# 任何未捕获的异常都要带上位置与原因，并转成 GitHub 注解后再退出：
# 抛异常会直接中断调用方的步骤脚本，那样连一条线索都留不下（CI 上踩过）。
trap {
    $where = $_.InvocationInfo.PositionMessage
    Write-Host "  [失败] parity.ps1 抛出异常" -ForegroundColor Red
    Write-Host "         $($_.Exception.Message)" -ForegroundColor DarkGray
    Write-Host "::error::parity.ps1 异常: $($_.Exception.Message)"
    if ($where) { Write-Host "::error::位置: $($where -replace "`r?`n", ' ')" }
    exit 1
}

$repoRoot  = Split-Path $PSScriptRoot -Parent
$censusPs1 = Join-Path $repoRoot 'scripts\census.ps1'
$censusSh  = Join-Path $repoRoot 'scripts\census.sh'
$originalEnvironment = @{}
foreach ($name in @('PATH', 'USERPROFILE', 'HOME', 'APPDATA', 'LOCALAPPDATA', 'TOOLCHAIN_ROOT', 'MISE_DATA_DIR', 'MISE_SHIMS_DIR', 'MISE_CONFIG_FILE', 'MISE_CONFIG_DIR', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'VOLTA_HOME', 'FNM_DIR', 'SCOOP', 'ASDF_DATA_DIR', 'TOOLKIT_PARITY_ROOT', 'TOOLKIT_PARITY_ROOT_ALT', 'TOOLKIT_PARITY_ROOT_WIN')) {
    $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

# Git Bash：PATH 上的 bash 可能是 WSL 的转发壳，所以显式找 Git 自带的那一个
$bash = @(
    'C:\Program Files\Git\bin\bash.exe',
    'C:\Program Files (x86)\Git\bin\bash.exe',
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $bash) {
    Write-Host '  [跳过] 找不到 Git Bash，无法在 Windows 上运行 census.sh 做对比。' -ForegroundColor Yellow
    exit 0
}
$gitRoot   = Split-Path (Split-Path $bash -Parent) -Parent
$gitUsrBin = Join-Path $gitRoot 'usr\bin'

# ---------- 搭沙箱 ----------
# 用长路径（LOCALAPPDATA 而不是 TEMP）：TEMP 可能是 8.3 短名（ADMINI~1），
# MSYS 解析不了短名，chmod 会报 "No such file or directory"。
$leaf = 'census-parity-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$fx = Join-Path $env:LOCALAPPDATA "Temp\$leaf"
New-Item -ItemType Directory -Force -Path "$fx\home\.config\mise", "$fx\bin", "$fx\rt1\bin", "$fx\rt2\bin" | Out-Null

# 假机器声明：与仓库模板不一致（少 python/java），且要求一个"永远不可能存在"的工具。
# 刻意不用 go / jadx 这类真实工具名：CI runner 上可能刚好装了它（实测 GitHub 的
# ubuntu 镜像里有 /usr/bin/go），那样"声明了但没装"这条断言就会失效。
@'
[tools]
node = ["22"]
census-absent-tool = ["1.0"]
'@ | Set-Content -LiteralPath "$fx\home\.config\mise\config.toml" -Encoding ASCII

# 项目只有 Python 的版本声明时，不能抑制 package.json 的 Node 接入提醒。
'{"engines":{"node":">=22"}}' | Set-Content -LiteralPath "$fx\package.json" -Encoding ASCII
"[tools]`npython = `"3.12`"`nrg = `"14`"" | Set-Content -LiteralPath "$fx\mise.toml" -Encoding ASCII
# 声明的 rg 只在统一仓库，不放到 PATH。两个脚本各使用自己的假执行文件。
$rgBin = Join-Path $fx 'toolchains\ripgrep\14.1.0\bin'
[void][IO.Directory]::CreateDirectory($rgBin)
[IO.File]::WriteAllText((Join-Path $rgBin 'rg.cmd'), "@echo off`r`necho ripgrep 14.1.0`r`n", [Text.Encoding]::ASCII)

# 会遮蔽 mise 的 node（给 census.ps1 走 Windows 解析），以及一个只存在于文件名里的约定。
# 约定 shim 特意用 bash 创建并 chmod +x：MSYS 的"可执行"是按 Unix 语义判断的，
# 而 census.sh 的约定层要求 [ -x ]——PowerShell 写出来的文件默认没有执行位。
'@echo v16.0.0' | Set-Content -LiteralPath "$fx\bin\node.cmd" -Encoding ASCII

# 两份"游离副本"：都在 PATH 之外，用来触发 SHADOWED / STRAY。
# 用 node.exe 这个名字（而不是裸 node）：census.ps1 只按 Windows 的命名习惯探测
# （node.exe / bin\node.exe），而 census.sh 两种都认——测试必须让两边都能看见它们。
'#!/bin/sh' | Set-Content -LiteralPath "$fx\rt1\bin\node.exe" -Encoding ASCII
'#!/bin/sh' | Set-Content -LiteralPath "$fx\rt2\bin\node.exe" -Encoding ASCII

function ConvertTo-MsysPath {
    param([string]$Path)
    $p = $Path -replace '\\', '/'
    if ($p -match '^([A-Za-z]):(.*)$') { return '/' + $Matches[1].ToLowerInvariant() + $Matches[2] }
    return $p
}

# 关键一步：MSYS 按 Unix 语义判断"可执行"，PowerShell 写出来的文件默认没有执行位，
# 而 census.sh 的约定层要求 [ -x ]。所以让两个实现看到同一份权限，并由 bash 造出约定 shim。
$fxMsys = ConvertTo-MsysPath $fx

# 在临时副本中限制候选探测范围；保留真实产品的其他逻辑。
# Windows 的静态系统目录和 IDE 枚举、Git Bash 的系统工具目录都不能成为测试候选。
$isolatedScripts = Join-Path $fx 'product\scripts'
$isolatedTemplates = Join-Path $fx 'product\templates'
New-Item -ItemType Directory -Force -Path $isolatedScripts, $isolatedTemplates | Out-Null
foreach ($name in @('toolkit-common.ps1', 'census-data.tsv', 'census-text.tsv')) {
    Copy-Item -LiteralPath (Join-Path (Join-Path $repoRoot 'scripts') $name) -Destination $isolatedScripts
}
$commonPath = Join-Path $isolatedScripts 'toolkit-common.ps1'
$commonSource = [IO.File]::ReadAllText($commonPath, [Text.Encoding]::UTF8)
$probeGuardMarker = '    # 最底层护栏：所有调用方都不能绕过。同时拦住经由 #! 或 npm.cmd 再去执行 PATH 上 node shim 的启动器。'
if ($commonSource.IndexOf($probeGuardMarker, [StringComparison]::Ordinal) -lt 0 -or
    $commonSource.IndexOf($probeGuardMarker, [StringComparison]::Ordinal) -ne $commonSource.LastIndexOf($probeGuardMarker, [StringComparison]::Ordinal)) {
    throw '无法设置 PowerShell 探测护栏；拒绝在真实机器上运行一致性测试。'
}
$probeGuard = '    if ($Exe -and -not (Test-ToolkitUnderRoot $Exe $env:TOOLKIT_PARITY_ROOT_WIN)) { throw "测试拒绝执行沙箱外候选：$Exe" }' + "`r`n"
[IO.File]::WriteAllText($commonPath, $commonSource.Replace($probeGuardMarker, ($probeGuard + $probeGuardMarker)), (New-Object Text.UTF8Encoding $true))
Copy-Item -LiteralPath (Join-Path $repoRoot 'templates\mise-config.toml') -Destination $isolatedTemplates
$psSource = [IO.File]::ReadAllText($censusPs1, [Text.Encoding]::UTF8)
$rootsLine = '$roots        = Measure-Phase ''4a. 候选根目录''          { Get-CandidateRoots }'
$rootsFixture = '$roots        = Measure-Phase ''4a. 候选根目录''          { @((Join-Path $env:TOOLKIT_PARITY_ROOT_WIN ''rt1''), (Join-Path $env:TOOLKIT_PARITY_ROOT_WIN ''rt2'')) }'
if ($psSource.IndexOf($rootsLine, [StringComparison]::Ordinal) -lt 0 -or
    $psSource.IndexOf($rootsLine, [StringComparison]::Ordinal) -ne $psSource.LastIndexOf($rootsLine, [StringComparison]::Ordinal)) {
    throw '无法限制 PowerShell 扫描根；拒绝在真实机器上运行一致性测试。'
}
$censusPs1 = Join-Path $isolatedScripts 'census.ps1'
[IO.File]::WriteAllText($censusPs1, $psSource.Replace($rootsLine, $rootsFixture), (New-Object Text.UTF8Encoding $true))
$shSource = [IO.File]::ReadAllText($censusSh, [Text.Encoding]::UTF8)
$shGuards = @(
    @{ old = 'set -uo pipefail'; new = "set -uo pipefail`nPATH=`"`$TOOLKIT_PARITY_ROOT_ALT/bin:`$PATH`"" },
    @{ old = 'probe_safe() {'; new = "probe_safe() {`n  if [ `"`${2:-0}`" -eq 0 ]; then case `"`$1`" in `"`$TOOLKIT_PARITY_ROOT`"/*|`"`$TOOLKIT_PARITY_ROOT_ALT`"/*) ;; *) return 1 ;; esac; fi" },
    @{ old = '  local p="$1" tool ver src'; new = "  local p=`"`$1`" tool ver src`n  case `"`$p`" in `"`$TOOLKIT_PARITY_ROOT`"/*|`"`$TOOLKIT_PARITY_ROOT_ALT`"/*) ;; *) return 0 ;; esac" },
    @{ old = '  local root="$1" rel'; new = "  local root=`"`$1`" rel`n  case `"`$root`" in `"`$TOOLKIT_PARITY_ROOT`"|`"`$TOOLKIT_PARITY_ROOT`"/*|`"`$TOOLKIT_PARITY_ROOT_ALT`"|`"`$TOOLKIT_PARITY_ROOT_ALT`"/*) ;; *) return 0 ;; esac" }
)
foreach ($guard in $shGuards) {
    if ($shSource.IndexOf($guard.old, [StringComparison]::Ordinal) -lt 0 -or
        $shSource.IndexOf($guard.old, [StringComparison]::Ordinal) -ne $shSource.LastIndexOf($guard.old, [StringComparison]::Ordinal)) {
        throw '无法限制 shell 扫描根；拒绝在真实机器上运行一致性测试。'
    }
    $shSource = $shSource.Replace($guard.old, $guard.new)
}
$censusSh = Join-Path $isolatedScripts 'census.sh'
[IO.File]::WriteAllText($censusSh, $shSource, (New-Object Text.UTF8Encoding $false))
$env:TOOLKIT_PARITY_ROOT = $fxMsys; $env:TOOLKIT_PARITY_ROOT_WIN = $fx
# Git Bash 可能把同一 Windows 临时目录映射到 /tmp；仅在两者确为同一目录时允许别名。
$env:TOOLKIT_PARITY_ROOT_ALT = "/tmp/$leaf"
& $bash -c '[ "$TOOLKIT_PARITY_ROOT" -ef "$TOOLKIT_PARITY_ROOT_ALT" ]'
if ($LASTEXITCODE -ne 0) { $env:TOOLKIT_PARITY_ROOT_ALT = $fxMsys }
& $bash -c "printf '#!/bin/sh\necho v22.23.2\n' > '$fxMsys/bin/node22' && printf '#!/bin/sh\necho ripgrep 14.1.0\n' > '$fxMsys/toolchains/ripgrep/14.1.0/bin/rg' && chmod +x '$fxMsys/bin/node22' '$fxMsys/rt1/bin/node.exe' '$fxMsys/rt2/bin/node.exe' '$fxMsys/toolchains/ripgrep/14.1.0/bin/rg'"
if ($LASTEXITCODE -ne 0) { throw '无法创建隔离的假运行时与 rg' }

# ---------- 受控环境 ----------
# PATH 只留沙箱需要的东西，而且【刻意不含 mise】：两个实现必须看同一个世界，
# 测试也不该依赖开发机上的 mise 状态——实测踩过：本机 mise 一旦卡住（陈旧锁），
# 会调用 mise 的 census 就会一起挂住，测试白等十几分钟。要覆盖 mise 相关告警时
# 再显式把它加进来（见 tests/smoke.sh 的 MISE_BIN 说明）。
$gitUsrBin = Join-Path $gitRoot 'usr\bin'
$fixturePath = @("$fx\bin", "$fx\bin", $gitUsrBin) |
               Where-Object { $_ -and (Test-Path -LiteralPath $_) }
$env:PATH             = ($fixturePath -join ';')   # 重复的 $fx\bin 触发 PATH_DIRT
$env:USERPROFILE      = "$fx\home"                 # census.ps1 认这个
$env:HOME             = ConvertTo-MsysPath "$fx\home"   # census.sh 认这个
$env:XDG_CONFIG_HOME  = ''                         # 两边都不用 XDG，避免路径形式差异

# LOCALAPPDATA / APPDATA 也指进沙箱：PowerShell 5.1 会往这里写模块分析缓存，
# 而 USERPROFILE 被改写之后它可能退化成相对路径、把产物丢进当前目录——
# 实测就这样在仓库里凭空多出过 Microsoft/Windows/PowerShell/ModuleAnalysisCache。
New-Item -ItemType Directory -Force -Path "$fx\AppData\Local", "$fx\AppData\Roaming" | Out-Null
$env:LOCALAPPDATA = "$fx\AppData\Local"
$env:APPDATA      = "$fx\AppData\Roaming"
$env:TOOLCHAIN_ROOT = "$fx\toolchains"
$env:MISE_DATA_DIR = "$fx\mise"
$env:MISE_SHIMS_DIR = ''; $env:MISE_CONFIG_FILE = ''; $env:MISE_CONFIG_DIR = ''; $env:XDG_DATA_HOME = ''
$env:VOLTA_HOME = ''; $env:FNM_DIR = ''; $env:SCOOP = ''; $env:ASDF_DATA_DIR = ''

# 用当前宿主的可执行文件跑子进程：沙箱 PATH 里刻意不含 System32
$psExe = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }

Write-Host ''
Write-Host ' 一致性测试：census.ps1 与 census.sh 在同一沙箱里找同一批雷' -ForegroundColor White
Write-Host " 沙箱: $fx" -ForegroundColor DarkGray

$fail = 0
function Check {
    param([string]$What, [bool]$Ok, [string]$Hint = '')
    if ($Ok) { Write-Host "  [通过] $What" -ForegroundColor Green }
    else {
        Write-Host "  [失败] $What" -ForegroundColor Red
        if ($Hint) { Write-Host "         $Hint" -ForegroundColor DarkGray }
        # 同时打一条 GitHub 注解：注解可以匿名从 API 读到，而 job 日志需要鉴权。
        # 放在这里而不是交给工作流收尾，是因为脚本一旦 exit，宿主可能直接结束，
        # 收尾代码就没有机会运行了（上一轮就是这么丢掉了全部线索）。
        Write-Host "::error::$What $(if ($Hint) { $Hint })"
        $script:fail++
    }
}

# 带超时地跑子进程：一旦哪个工具卡住（实测 mise 会因为陈旧的锁无限等待），
# 测试要快速失败并说清原因，而不是把 CI 挂到超时上限。
# 刻意不用 Start-Job：这个测试会把 LOCALAPPDATA 指进沙箱，而 PowerShell 的作业
# 基础设施要往那里写状态，Receive-Job 会报 "The Persistence Path does not exist"。
# Start-Process + WaitForExit(毫秒) 不依赖任何外部状态，正好。
function Invoke-Bounded {
    param([string]$Exe, [string[]]$Arguments, [int]$TimeoutSec = 300, [string]$Tag = 'cmd')
    $outFile = Join-Path $fx "$Tag.out.txt"
    $errFile = Join-Path $fx "$Tag.err.txt"
    $savedPath = $env:PATH; $savedWarehouse = $env:TOOLCHAIN_ROOT
    try {
        # PowerShell 不需要 Git 自带的 Unix 工具；避免解析并探测沙箱外命令。
        if ($Exe -eq $psExe) { $env:PATH = "$fx\bin;$fx\bin" }
        else { $env:TOOLCHAIN_ROOT = "$fxMsys/toolchains" }
        $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -WindowStyle Hidden -PassThru `
                           -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    } finally { $env:PATH = $savedPath; $env:TOOLCHAIN_ROOT = $savedWarehouse }
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        Write-Host "  [注意] 子进程超过 $TimeoutSec 秒仍未返回，已终止：$Exe" -ForegroundColor Yellow
        return ''
    }
    return (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
}

# Volta 的 image 是真实运行时目录，不应因 VOLTA_HOME 整棵树被当成 shim。
$shimMatch = [regex]::Match($shSource, '(?ms)^is_shim_path\(\) \{.*?^\}')
if (-not $shimMatch.Success) { throw '无法提取 shell shim 护栏进行隔离测试' }
$voltaCheckScript = Join-Path $fx 'volta-check.sh'
$voltaBody = @'
is_shim_path "$VOLTA_HOME/tools/image/node/22.1.0/node" && exit 1
is_shim_path "$VOLTA_HOME/bin/node" || exit 2
exit 0
'@
[IO.File]::WriteAllText($voltaCheckScript, $shimMatch.Value + "`n" + $voltaBody, (New-Object Text.UTF8Encoding $false))
$env:VOLTA_HOME = "$fxMsys/volta"
& $bash $voltaCheckScript
Check 'shell 区分 Volta 真实运行时和 bin shim' ($LASTEXITCODE -eq 0)
$env:VOLTA_HOME = ''

# 符号链接不能让 shim 变成可探测文件；普通工具的链接仍允许。
& $bash -c "mkdir -p '$fxMsys/mise/shims' '$fxMsys/ordinary' && printf 'fake shim\n' > '$fxMsys/mise/shims/faketool' && printf 'fake runtime\n' > '$fxMsys/ordinary/faketool'"
if ($LASTEXITCODE -ne 0) { throw '无法创建隔离的 shell 链接夹具' }
New-Item -ItemType Junction -Path (Join-Path $fx 'shim-alias') -Target (Join-Path $fx 'mise\shims') | Out-Null
New-Item -ItemType Junction -Path (Join-Path $fx 'runtime-alias') -Target (Join-Path $fx 'ordinary') | Out-Null
$guardFunctions = New-Object System.Collections.Generic.List[string]
foreach ($functionName in @('is_shim_path', 'is_node_launcher_name', 'read_shebang', 'resolve_probe_path', 'probe_safe')) {
    $functionMatch = [regex]::Match($shSource, ('(?ms)^' + [regex]::Escape($functionName) + '\(\) \{.*?^\}'))
    if (-not $functionMatch.Success) { throw "无法提取 shell 探测护栏：$functionName" }
    $guardFunctions.Add($functionMatch.Value)
}
$linkGuardScript = Join-Path $fx 'link-guard-check.sh'
$linkBody = @'
probe_safe "$TOOLKIT_PARITY_ROOT/shim-alias/faketool" && { echo "linked shim was accepted: $(resolve_probe_path "$TOOLKIT_PARITY_ROOT/shim-alias/faketool") link=$([ -L "$TOOLKIT_PARITY_ROOT/shim-alias" ] && echo yes || echo no) target=$(readlink "$TOOLKIT_PARITY_ROOT/shim-alias" 2>/dev/null || echo none)"; exit 1; }
probe_safe "$TOOLKIT_PARITY_ROOT/runtime-alias/faketool" || { echo 'ordinary link was rejected'; exit 2; }
exit 0
'@
[IO.File]::WriteAllText($linkGuardScript, ($guardFunctions -join "`n") + "`n" + $linkBody, (New-Object Text.UTF8Encoding $false))
$env:MISE_SHIMS_DIR = "$fxMsys/mise/shims"
$linkOutput = @(& $bash $linkGuardScript 2>&1); $linkCode = $LASTEXITCODE
Check 'shell 不执行经符号链接隐藏的 shim，普通链接仍可用' ($linkCode -eq 0) "退出码 $linkCode：$($linkOutput -join ' ')"
if ($linkCode -ne 0) { throw 'shell 链接护栏失败，停止后续扫描。' }
# Mutation control: deleting the physical-path check must make this same
# junction fixture fail, proving it exercises the intended defect.
$oldProbe = $guardFunctions[$guardFunctions.Count - 1]
$unsafeProbe = $oldProbe.Replace('  physical="$(resolve_probe_path "$p")" || return 1', '').Replace('  is_shim_path "$physical" && return 1', '')
if ($unsafeProbe -eq $oldProbe) { throw '无法构造链接护栏对照，拒绝声称覆盖已验证。' }
$unsafeFunctions = @($guardFunctions.ToArray()); $unsafeFunctions[$unsafeFunctions.Count - 1] = $unsafeProbe
$unsafeGuardScript = Join-Path $fx 'link-guard-unsafe-control.sh'
[IO.File]::WriteAllText($unsafeGuardScript, ($unsafeFunctions -join "`n") + "`n" + $linkBody, (New-Object Text.UTF8Encoding $false))
$unsafeOutput = @(& $bash $unsafeGuardScript 2>&1); $unsafeCode = $LASTEXITCODE
Check 'shell 链接夹具能识别移除物理路径护栏的缺陷' ($unsafeCode -eq 1 -and ($unsafeOutput -join ' ') -match 'linked shim was accepted')
$env:MISE_SHIMS_DIR = ''

# 子进程一律在沙箱目录里跑：即使有工具想往"当前目录"写缓存，也只会写进沙箱。
Push-Location $fx
try {
    # ---------- 跑两个实现 ----------
    $ps1Json = Invoke-Bounded -Exe $psExe -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $censusPs1, '-Json') -Tag 'ps1'
    $shJson  = Invoke-Bounded -Exe $bash  -Arguments @($censusSh, '--json') -Tag 'sh'

    try { $ps1 = $ps1Json | ConvertFrom-Json } catch { $ps1 = $null }
    try { $sh  = $shJson  | ConvertFrom-Json } catch { $sh  = $null }
    Check 'census.ps1 输出了可解析的 JSON' ($null -ne $ps1)
    Check 'census.sh 输出了可解析的 JSON'  ($null -ne $sh)
    if ($null -ne $ps1 -and $null -ne $sh) {
        $outsidePs = @($ps1.runtimes | Where-Object { $_.path -and -not "$($_.path)".StartsWith($fx + '\', [StringComparison]::OrdinalIgnoreCase) })
        $outsideSh = @($sh.runtimes | Where-Object { $_.path -and -not "$($_.path)".StartsWith($fxMsys + '/', [StringComparison]::OrdinalIgnoreCase) -and -not "$($_.path)".StartsWith($env:TOOLKIT_PARITY_ROOT_ALT + '/', [StringComparison]::OrdinalIgnoreCase) })
        Check '两个扫描器的候选运行时均在临时目录内' ($outsidePs.Count -eq 0 -and $outsideSh.Count -eq 0)
        Check 'shell 扫描器可发现两个受控运行时' (@($sh.runtimes).Count -ge 2) "实际：$((@($sh.runtimes) | ForEach-Object { $_.path }) -join ' | ')"
    }
    if ($null -eq $ps1 -or $null -eq $sh) {
        Write-Host "`n census.ps1 原始输出片段: $($ps1Json.Substring(0, [Math]::Min(200, $ps1Json.Length)))" -ForegroundColor DarkGray
        Write-Host " census.sh  原始输出片段: $($shJson.Substring(0, [Math]::Min(200, $shJson.Length)))" -ForegroundColor DarkGray
        # 这一步是"脚本跑了但输出不是 JSON"，原因常常是子进程被超时终止或环境不对，
        # 原始输出里才有线索——同样转成注解带出去。
        Write-Host "::error::census.ps1 输出前 200 字符: $($ps1Json.Substring(0, [Math]::Min(200, $ps1Json.Length)))"
        Write-Host "::error::census.sh  输出前 200 字符: $($shJson.Substring(0, [Math]::Min(200, $shJson.Length)))"
        exit 1
    }

# 两个实现看到的世界不同，候选目录不同，所以按"沙箱里埋的雷"逐条断言，
# 而不是比较告警种类集合是否完全相等。
# 期望事实放在 tests/fixtures/census-expected.tsv，与 smoke.sh 共用同一份：
# 每行 scope / kind / tool / needle，这里只取 scope 为 both 或 parity 的行。
# needle 用 .Contains 做字面匹配（-like 会把 [ ] * ? 当通配符）。
$expectedPath = Join-Path $repoRoot 'tests\fixtures\census-expected.tsv'
$expected = @()
foreach ($line in [IO.File]::ReadAllLines($expectedPath, [Text.Encoding]::UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
    $cols = $line.TrimEnd("`r") -split "`t"
    if ($cols.Count -lt 4) { continue }
    if ($cols[0] -ne 'both' -and $cols[0] -ne 'parity') { continue }
    $expected += [pscustomobject]@{
        kind   = $cols[1]
        tool   = $cols[2]
        needle = $cols[3].Replace('{sandbox}', $leaf)
    }
}
Check 'census-expected.tsv 有可用的期望行' ($expected.Count -gt 0) "读取 $expectedPath"

foreach ($impl in @(@{ Name = 'census.ps1'; Data = $ps1 }, @{ Name = 'census.sh'; Data = $sh })) {
    $name = $impl.Name
    $d = $impl.Data
    Write-Host ("  --- $name 告警: " + ((@($d.warnings) | ForEach-Object { $_.kind } | Sort-Object -Unique) -join ', ')) -ForegroundColor DarkGray
    Check "$name 不因无关 Python 声明忽略 Node 声明提醒" (@($d.warnings | Where-Object { $_.kind -eq 'UNDECLARED' -and $_.tool -eq 'node' }).Count -eq 1)
    Check "$name 读取了 rg 项目声明" (@($d.declarations | Where-Object { $_.scope -eq 'project' -and $_.tools.rg -eq '14' }).Count -eq 1)
    Check "$name 的 PATH 不含 rg" (@($d.resolution | Where-Object { $_.command -eq 'rg' }).Count -eq 0)
    Check "$name 不误报仓库中的已验证 rg 缺失" (@($d.warnings | Where-Object { $_.kind -eq 'MISSING' -and $_.tool -eq 'rg' }).Count -eq 0)

    foreach ($row in $expected) {
        $hit = @(@($d.warnings) | Where-Object {
            $_.kind -eq $row.kind -and
            ($row.tool -eq '*' -or $_.tool -eq $row.tool -or ("$($_.tool)" -split '/') -contains $row.tool) -and
            ("$($_.detail) $($_.message)".Contains($row.needle))
        })
        Check "$name 报出 $($row.kind)（tool=$($row.tool)，含 $($row.needle)）" ($hit.Count -gt 0) '期望来自 tests/fixtures/census-expected.tsv'
    }
}

    # 新的仓库工具探测必须走超时保护；假 timeout 立即返回 124，不等待真实时间。
    & $bash -c "printf '#!/bin/sh\necho invoked > `"%s`"\nexit 124\n' '$fxMsys/timeout-invoked' > '$fxMsys/bin/timeout' && chmod +x '$fxMsys/bin/timeout'"
    if ($LASTEXITCODE -ne 0) { throw '无法创建超时夹具' }
    $timedSh = (Invoke-Bounded -Exe $bash -Arguments @($censusSh, '--json') -Tag 'sh-rg-timeout') | ConvertFrom-Json
    $timeoutInvoked = [IO.File]::Exists((Join-Path $fx 'timeout-invoked'))
    $timedMissing = @($timedSh.warnings | Where-Object { $_.kind -eq 'MISSING' -and $_.tool -eq 'rg' }).Count
    Check 'shell 仓库版本探测受超时保护且超时不能冒充成功' ($timeoutInvoked -and $timedMissing -eq 1) "timeout=$timeoutInvoked missing=$timedMissing resolution=$(@($timedSh.resolution | Where-Object { $_.command -eq 'rg' } | ForEach-Object { $_.resolvesTo }) -join ',')"
    # 临时移除保护做对照，确认该测试能抓到直接运行候选的回归。
    [IO.File]::Delete((Join-Path $fx 'timeout-invoked'))
    $boundedProbe = 'output="$(run_with_timeout 20 "$candidate" --version | head -n 4)"; rc=$?'
    $unboundedProbe = 'output="$("$candidate" --version 2>&1)"; rc=$?'
    if (-not $shSource.Contains($boundedProbe)) { throw '无法构造超时护栏对照测试' }
    $unboundedSh = Join-Path $isolatedScripts 'census-unbounded.sh'
    [IO.File]::WriteAllText($unboundedSh, $shSource.Replace($boundedProbe, $unboundedProbe), (New-Object Text.UTF8Encoding $false))
    $unboundedResult = (Invoke-Bounded -Exe $bash -Arguments @($unboundedSh, '--json') -Tag 'sh-rg-unbounded') | ConvertFrom-Json
    Check '超时测试能识别直接执行候选的缺陷' (-not [IO.File]::Exists((Join-Path $fx 'timeout-invoked')) -and @($unboundedResult.warnings | Where-Object { $_.kind -eq 'MISSING' -and $_.tool -eq 'rg' }).Count -eq 0)
    [IO.File]::Delete((Join-Path $fx 'bin\timeout'))

    # timeout 自身若是 shim，不能执行；回退路径使用受限超时和同一假 rg。
    [void][IO.Directory]::CreateDirectory((Join-Path $fx 'shims'))
    & $bash -c "printf '#!/bin/sh\necho invoked > `"%s`"\nexit 124\n' '$fxMsys/shim-timeout-invoked' > '$fxMsys/shims/timeout' && chmod +x '$fxMsys/shims/timeout'"
    if ($LASTEXITCODE -ne 0) { throw '无法创建 timeout shim 夹具' }
    $normalPathLine = 'PATH="$TOOLKIT_PARITY_ROOT_ALT/bin:$PATH"'
    $shimPathLine = 'PATH="$TOOLKIT_PARITY_ROOT_ALT/shims:$TOOLKIT_PARITY_ROOT_ALT/bin:$PATH"'
    if (-not $shSource.Contains($normalPathLine) -or -not $shSource.Contains('run_with_timeout 20 "$candidate" --version')) { throw '无法构造 shim 超时护栏测试' }
    $shimTimeoutSource = $shSource.Replace($normalPathLine, $shimPathLine).Replace('run_with_timeout 20 "$candidate" --version', 'run_with_timeout 1 "$candidate" --version')
    $shimTimeoutSh = Join-Path $isolatedScripts 'census-shim-timeout.sh'
    [IO.File]::WriteAllText($shimTimeoutSh, $shimTimeoutSource, (New-Object Text.UTF8Encoding $false))
    $shimTimeoutResult = (Invoke-Bounded -Exe $bash -Arguments @($shimTimeoutSh, '--json') -Tag 'sh-shim-timeout') | ConvertFrom-Json
    Check '超时工具是 shim 时不执行 shim，仍能探测假候选' (-not [IO.File]::Exists((Join-Path $fx 'shim-timeout-invoked')) -and @($shimTimeoutResult.warnings | Where-Object { $_.kind -eq 'MISSING' -and $_.tool -eq 'rg' }).Count -eq 0)

    # 错误输出含数字也不能冒充已验证版本；替换的均是临时假文件。
    [IO.File]::WriteAllText((Join-Path $rgBin 'rg.cmd'), "@echo off`r`necho error: unsupported 14.1.0`r`n", [Text.Encoding]::ASCII)
    & $bash -c "printf '#!/bin/sh\necho error: unsupported 14.1.0\n' > '$fxMsys/toolchains/ripgrep/14.1.0/bin/rg' && chmod +x '$fxMsys/toolchains/ripgrep/14.1.0/bin/rg'"
    if ($LASTEXITCODE -ne 0) { throw '无法创建不可用的 rg 夹具' }
    $brokenPs = (Invoke-Bounded -Exe $psExe -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $censusPs1, '-Json') -Tag 'ps1-rg-broken') | ConvertFrom-Json
    $brokenSh = (Invoke-Bounded -Exe $bash -Arguments @($censusSh, '--json') -Tag 'sh-rg-broken') | ConvertFrom-Json
    Check '两端不会把仓库中的错误版本输出当成可用 rg' (@($brokenPs.warnings | Where-Object { $_.kind -eq 'MISSING' -and $_.tool -eq 'rg' }).Count -eq 1 -and @($brokenSh.warnings | Where-Object { $_.kind -eq 'MISSING' -and $_.tool -eq 'rg' }).Count -eq 1)

    # 节点本身已声明时不能反过来误报；两边仍只读取相同的临时夹具。
    [IO.File]::WriteAllText((Join-Path $fx 'mise.toml'), "[tools]`nnode = `"22`"`npython = `"3.12`"`njava = `"8`"`n", [Text.Encoding]::ASCII)
    $declaredPs = Invoke-Bounded -Exe $psExe -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $censusPs1, '-Json') -Tag 'ps1-declared'
    $declaredSh = Invoke-Bounded -Exe $bash -Arguments @($censusSh, '--json') -Tag 'sh-declared'
    $declaredPsJson = $declaredPs | ConvertFrom-Json; $declaredShJson = $declaredSh | ConvertFrom-Json
    Check '两端识别项目 Node 声明后不再提示未声明' (@($declaredPsJson.warnings | Where-Object { $_.kind -eq 'UNDECLARED' -and $_.tool -eq 'node' }).Count -eq 0 -and @($declaredShJson.warnings | Where-Object { $_.kind -eq 'UNDECLARED' -and $_.tool -eq 'node' }).Count -eq 0)

    # Node 与 npm 的版本体系不同；在沙箱中构造 shell 假管理器和假工具。
    # PowerShell 侧同一行为由 version-contract.ps1 使用替身记录覆盖。
    $javaFixture = @'
#!/bin/sh
echo 'java version "1.8.0_504"' >&2
'@
    [IO.File]::WriteAllText((Join-Path $fx 'bin\java'), $javaFixture, (New-Object Text.UTF8Encoding $false))
    & $bash -c "printf '#!/bin/sh\necho v22.0.0\n' > '$fxMsys/bin/node' && printf '#!/bin/sh\necho 10.9.0\n' > '$fxMsys/bin/npm' && printf '#!/bin/sh\necho node 22.0.0 fixture 22\necho java 8.0.0 fixture 8\necho java 1.8.0_504 fixture 1.8\necho java 11.0.0 fixture 11\n' > '$fxMsys/bin/mise' && chmod +x '$fxMsys/bin/node' '$fxMsys/bin/npm' '$fxMsys/bin/mise' '$fxMsys/bin/java'"
    if ($LASTEXITCODE -ne 0) { throw '无法创建隔离的 shell 测试工具' }
    $packageSh = (Invoke-Bounded -Exe $bash -Arguments @($censusSh, '--json') -Tag 'sh-package') | ConvertFrom-Json
    $npm = @($packageSh.resolution | Where-Object { $_.command -eq 'npm' })
    Check 'census.sh 隔离夹具确实发现管理器中的 Node 22' ($packageSh.mise.available -and @($packageSh.mise.tools | Where-Object { $_.tool -eq 'node' -and $_.version -eq '22.0.0' }).Count -eq 1)
    Check 'census.sh 隔离夹具确实解析到 npm 10' ($npm.Count -eq 1 -and $npm[0].version -match '^10\.')
    Check 'census.sh 不把 npm 版本当成 Node 的 PATH_ORDER' (@($packageSh.warnings | Where-Object { $_.kind -eq 'PATH_ORDER' -and $_.tool -eq 'npm' }).Count -eq 0)
    $java = @($packageSh.resolution | Where-Object { $_.command -eq 'java' })
    Check 'census.sh 读取 Java 8 的旧版版本号' ($java.Count -eq 1 -and $java[0].version -eq '1.8.0_504')
    Check 'Java 1.8 应满足 Java 8 声明' (@($packageSh.warnings | Where-Object { $_.kind -eq 'PATH_ORDER' -and $_.tool -eq 'java' }).Count -eq 0)
    [IO.File]::WriteAllText((Join-Path $fx 'mise.toml'), "[tools]`njava = `"1.8`"`n", [Text.Encoding]::ASCII)
    $javaLegacy = (Invoke-Bounded -Exe $bash -Arguments @($censusSh, '--json') -Tag 'sh-java-legacy') | ConvertFrom-Json
    Check 'Java 1.8 也满足显式 1.8 声明' (@($javaLegacy.mise.tools | Where-Object { $_.tool -eq 'java' -and $_.version -eq '1.8.0_504' }).Count -eq 1 -and @($javaLegacy.warnings | Where-Object { $_.kind -eq 'PATH_ORDER' -and $_.tool -eq 'java' }).Count -eq 0)
    [IO.File]::WriteAllText((Join-Path $fx 'mise.toml'), "[tools]`njava = `"11`"`n", [Text.Encoding]::ASCII)
    $javaMismatch = (Invoke-Bounded -Exe $bash -Arguments @($censusSh, '--json') -Tag 'sh-java-mismatch') | ConvertFrom-Json
    Check 'Java 8 不满足 Java 11 声明时提示 PATH 顺序' (@($javaMismatch.mise.tools | Where-Object { $_.tool -eq 'java' -and $_.version -eq '11.0.0' }).Count -eq 1 -and @($javaMismatch.warnings | Where-Object { $_.kind -eq 'PATH_ORDER' -and $_.tool -eq 'java' }).Count -eq 1)

    # ---------- 双语与 JSON 契约 ----------
    # 断言只用 ASCII 匹配：CI runner 多是英文系统，子进程重定向到文件时按 OEM
    # 代码页写出，非 ASCII 字符（例如破折号）会被替换掉，拿它做断言会假失败。
    $enOut = Invoke-Bounded -Exe $psExe -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $censusPs1, '-Lang', 'en') -TimeoutSec 120 -Tag 'ps1-en'
    Check 'census.ps1 -Lang en 输出英文标题' ($enOut -match '6\. Warnings')
    Check 'census.ps1 -Lang en 输出英文告警' ($enOut -match '\[CONVENTION\] Found a naming convention')
    $enOutSh = Invoke-Bounded -Exe $bash -Arguments @($censusSh, '--lang', 'en') -TimeoutSec 120 -Tag 'sh-en'
    Check 'census.sh --lang en 输出英文标题' ($enOutSh -match '6\. Warnings')
    Check 'census.sh --lang en 输出英文告警' ($enOutSh -match '\[CONVENTION\] Found a naming convention')

    # JSON 契约：两边都要有 schemaVersion 与同一组顶层字段（跨平台消费的前提）
    $sharedFields = @('schemaVersion', 'generatedAt', 'host', 'declarations', 'toolsRoot', 'mise', 'conventions', 'runtimes', 'resolution', 'warnings', 'timings', 'summary')
    $ps1Missing = @($sharedFields | Where-Object { $ps1.PSObject.Properties.Name -notcontains $_ })
    $shMissing  = @($sharedFields | Where-Object { $sh.PSObject.Properties.Name -notcontains $_ })
    Check 'census.ps1 的 JSON 字段齐全' ($ps1Missing.Count -eq 0) ("缺: " + ($ps1Missing -join ', '))
    Check 'census.sh 的 JSON 字段齐全'  ($shMissing.Count -eq 0)  ("缺: " + ($shMissing -join ', '))
    Check '两边 schemaVersion 相同' ($ps1.schemaVersion -and ($ps1.schemaVersion -eq $sh.schemaVersion)) ("ps1=$($ps1.schemaVersion) sh=$($sh.schemaVersion)")

    # 这里刻意【不】逐字段强制两份实现结构一致。曾经加过这样的断言，代价是每次改动
    # 都要在两个实现之间做完全对齐（连附加信息都要互相补齐或写例外名单），而收益只是
    # "少一个字段"，不值这个钱。契约以 docs/reference 里列出的字段为准：消费者按文档
    # 读，实现可以带上自己的附加字段。
    #
    # 但有一条必须守：机器可读的标识符必须是稳定 ASCII（见下）。它与"两边是否一致"
    # 无关——kind / source / placement / pattern 是给脚本和 agent 匹配用的，一旦混进
    # 本地化取值（内部的中文标记直接落进 JSON），非 UTF-8 locale 下就匹配不上。
    # message / action 是散文，按文档跟随 --lang，不在这条断言的范围里。
    # probeStats（附加字段，schemaVersion 仍为 1）：探测进程计数必须是非负整数。
    foreach ($impl in @(@{ name = 'census.ps1'; data = $ps1 }, @{ name = 'census.sh'; data = $sh })) {
        $probeLaunches = $null
        if ($impl.data.PSObject.Properties.Name -contains 'probeStats' -and $impl.data.probeStats) { $probeLaunches = $impl.data.probeStats.launches }
        Check "$($impl.name) 的 probeStats.launches 是非负整数" (($probeLaunches -is [int] -or $probeLaunches -is [long]) -and $probeLaunches -ge 0) "launches=$probeLaunches"
    }

    $asciiFields = 'kind', 'source', 'placement', 'pattern'
    foreach ($impl in @(@{ name = 'census.ps1'; data = $ps1 }, @{ name = 'census.sh'; data = $sh })) {
        $bad = @()
        foreach ($stage in 'runtimes', 'warnings') {
            foreach ($r in @($impl.data.$stage)) {
                if ($null -eq $r) { continue }
                foreach ($f in $asciiFields) {
                    if ($r.PSObject.Properties.Name -notcontains $f) { continue }
                    $v = $r.$f
                    if ($v -and ("$v" -notmatch '^[\x20-\x7E]*$')) { $bad += "$stage.$f=$v" }
                }
            }
        }
        Check "$($impl.name) 的机器可读字段是纯 ASCII" ($bad.Count -eq 0) ((@($bad | Select-Object -Unique) | Select-Object -First 5) -join '; ')
    }
} finally {
    # 先回到原目录再删沙箱：Windows 上不能删除"当前所在"的目录。
    Pop-Location
    foreach ($name in $originalEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], 'Process') }
}

# ---------- 收尾 ----------
if ($KeepSandbox) {
    Write-Host " 沙箱已保留: $fx" -ForegroundColor DarkGray
} else {
    Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host ' 全部通过' -ForegroundColor Green
    Write-Host ''
    exit 0
} else {
    Write-Host " 有 $fail 项失败" -ForegroundColor Red
    Write-Host ''
    exit 1
}
