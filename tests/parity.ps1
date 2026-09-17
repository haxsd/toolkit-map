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
    · 声明要求了但没装            go（→ MISSING）
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

# 假机器声明：与仓库模板不一致（少 python/java），且要求一个没装的 go
@'
[tools]
node = ["22"]
go = ["1.22"]
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
# PATH 只留沙箱需要的东西：两个实现必须看同一个世界，否则本机装了什么会污染结论。
$miseBin = (Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Filter 'bin' -Recurse -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'mise' } | Select-Object -First 1).FullName
$miseShims = Join-Path $env:LOCALAPPDATA 'mise\shims'
$fixturePath = @("$fx\bin", "$fx\bin", $gitUsrBin, $miseShims, $miseBin) |
               Where-Object { $_ -and (Test-Path -LiteralPath $_) }
$env:PATH             = ($fixturePath -join ';')   # 重复的 $fx\bin 触发 PATH_DIRT
$env:USERPROFILE      = "$fx\home"                 # census.ps1 认这个
$env:HOME             = ConvertTo-MsysPath "$fx\home"   # census.sh 认这个
$env:XDG_CONFIG_HOME  = ''                         # 两边都不用 XDG，避免路径形式差异

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
        $script:fail++
    }
}

# ---------- 跑两个实现 ----------
$ps1Json = & $psExe -NoProfile -ExecutionPolicy Bypass -File $censusPs1 -Json 2>$null | Out-String
$shJson  = & $bash $censusSh --json 2>$null | Out-String

try { $ps1 = $ps1Json | ConvertFrom-Json } catch { $ps1 = $null }
try { $sh  = $shJson  | ConvertFrom-Json } catch { $sh  = $null }
Check 'census.ps1 输出了可解析的 JSON' ($null -ne $ps1)
Check 'census.sh 输出了可解析的 JSON'  ($null -ne $sh)
if ($null -eq $ps1 -or $null -eq $sh) {
    Write-Host "`n census.ps1 原始输出片段: $($ps1Json.Substring(0, [Math]::Min(200, $ps1Json.Length)))" -ForegroundColor DarkGray
    Write-Host " census.sh  原始输出片段: $($shJson.Substring(0, [Math]::Min(200, $shJson.Length)))" -ForegroundColor DarkGray
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
    Check "$name 发现声明了却没装（MISSING / go）"   (Has-KindContaining $d 'MISSING'    'go')
    Check "$name 发现 PATH 重复条目（PATH_DIRT）"    (Has-KindContaining $d 'PATH_DIRT'  $leaf)
    Check "$name 发现被遮蔽的副本（SHADOWED）"       (Has-KindContaining $d 'SHADOWED'   'rt1')
    Check "$name 发现游离运行时（STRAY）"            (Has-KindContaining $d 'STRAY'      'rt2')
}

# ---------- 双语与 JSON 契约 ----------
$enOut = & $psExe -NoProfile -ExecutionPolicy Bypass -File $censusPs1 -Lang en 2>$null | Out-String
Check 'census.ps1 -Lang en 输出英文标题' ($enOut -match '6\. Warnings — things that need a human decision')
Check 'census.ps1 -Lang en 输出英文告警' ($enOut -match '\[(DRIFT|MISSING|CONVENTION|PATH_DIRT)\] \S')
$enOutSh = & $bash $censusSh --lang en 2>$null | Out-String
Check 'census.sh --lang en 输出英文标题' ($enOutSh -match '6\. Warnings — things that need a human decision')

# JSON 契约：两边都要有 schemaVersion 与同一组顶层字段（跨平台消费的前提）
$sharedFields = @('schemaVersion', 'generatedAt', 'host', 'declarations', 'toolsRoot', 'mise', 'conventions', 'runtimes', 'resolution', 'warnings', 'timings', 'summary')
$ps1Missing = @($sharedFields | Where-Object { $ps1.PSObject.Properties.Name -notcontains $_ })
$shMissing  = @($sharedFields | Where-Object { $sh.PSObject.Properties.Name -notcontains $_ })
Check 'census.ps1 的 JSON 字段齐全' ($ps1Missing.Count -eq 0) ("缺: " + ($ps1Missing -join ', '))
Check 'census.sh 的 JSON 字段齐全'  ($shMissing.Count -eq 0)  ("缺: " + ($shMissing -join ', '))
Check '两边 schemaVersion 相同' ($ps1.schemaVersion -and ($ps1.schemaVersion -eq $sh.schemaVersion)) ("ps1=$($ps1.schemaVersion) sh=$($sh.schemaVersion)")

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
