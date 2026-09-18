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

$repoRoot  = Split-Path $PSScriptRoot -Parent
$censusPs1 = Join-Path $repoRoot 'scripts\census.ps1'
$censusSh  = Join-Path $repoRoot 'scripts\census.sh'

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
& $bash -c "printf '#!/bin/sh\necho v22.23.2\n' > '$fxMsys/bin/node22' && chmod +x '$fxMsys/bin/node22' '$fxMsys/rt1/bin/node.exe' '$fxMsys/rt2/bin/node.exe'"

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
    $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -NoNewWindow -PassThru `
                       -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        Write-Host "  [注意] 子进程超过 $TimeoutSec 秒仍未返回，已终止：$Exe" -ForegroundColor Yellow
        return ''
    }
    return (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
}

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
function Has-KindContaining {
    param($Report, [string]$Kind, [string]$Needle)
    return [bool](@($Report.warnings) | Where-Object {
        $_.kind -eq $Kind -and (("$($_.detail) $($_.message)") -like "*$Needle*")
    })
}

foreach ($impl in @(@{ Name = 'census.ps1'; Data = $ps1 }, @{ Name = 'census.sh'; Data = $sh })) {
    $name = $impl.Name
    $d = $impl.Data
    Write-Host ("  --- $name 告警: " + ((@($d.warnings) | ForEach-Object { $_.kind } | Sort-Object -Unique) -join ', ')) -ForegroundColor DarkGray

    Check "$name 发现约定 node22（CONVENTION）"      (Has-KindContaining $d 'CONVENTION' 'node22')
    Check "$name 发现声明漂移（DRIFT）"             (Has-KindContaining $d 'DRIFT'      'config.toml')
    Check "$name 发现声明了却没装（MISSING）"        (Has-KindContaining $d 'MISSING'    'census-absent-tool')
    Check "$name 发现 PATH 重复条目（PATH_DIRT）"    (Has-KindContaining $d 'PATH_DIRT'  $leaf)
    Check "$name 发现被遮蔽的副本（SHADOWED）"       (Has-KindContaining $d 'SHADOWED'   'rt1')
    Check "$name 发现游离运行时（STRAY）"            (Has-KindContaining $d 'STRAY'      'rt2')
}

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
} finally {
    # 先回到原目录再删沙箱：Windows 上不能删除"当前所在"的目录
    Pop-Location
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
