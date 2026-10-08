#Requires -Version 5.1
<#
.SYNOPSIS
  文案表检查：scripts/census-text.tsv 是 census.ps1 与 census.sh 共用的唯一文案来源。

.DESCRIPTION
  检查四件事：
    1. 格式：每个数据行恰好是 key<TAB>lang<TAB>text，lang 只能是 zh / en，(key, lang) 不重复；
    2. 双语齐全：每个 key（含 ps1: / sh: 前缀的实现专用 key）zh 与 en 都有且非空，
       前缀 key 成对出现（有 ps1: 就必须有 sh:，反之亦然）；
    3. 引用可解析：两个脚本里写死的 T '<key>' 和各自产生的告警种类（warn.<KIND>.message/action）
       在本实现的视角下都查得到——漏一条，输出里就会露出键名本身；
    4. 实际运行：census.ps1 -Lang en / zh 输出对应语言的章节标题、不残留键名；
       文案表缺失时 census.ps1 以退出码 2 失败，而不是静默输出键名。
  census.sh 的运行时行为（--lang en、文案表缺失）由 tests/smoke.sh 覆盖。

.EXAMPLE
  .\tests\check-text.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot  = Split-Path $PSScriptRoot -Parent
$scripts   = Join-Path $repoRoot 'scripts'
$textPath  = Join-Path $scripts 'census-text.tsv'
$censusPs1 = Join-Path $scripts 'census.ps1'
$censusSh  = Join-Path $scripts 'census.sh'

$fail = 0
function Check {
    param([string]$What, [bool]$Ok, [string]$Hint = '')
    if ($Ok) { Write-Host "  [通过] $What" -ForegroundColor Green }
    else {
        Write-Host "  [失败] $What" -ForegroundColor Red
        if ($Hint) { Write-Host "         $Hint" -ForegroundColor DarkGray }
        Write-Host "::error::$What $(if ($Hint) { $Hint })"
        $script:fail++
    }
}

Write-Host ''
Write-Host ' 文案表检查（scripts/census-text.tsv）' -ForegroundColor White

# ---------- 1. 格式 ----------
$entries = @{}          # "key|lang" -> text
$keys = New-Object System.Collections.Generic.List[string]
$badRows = @()
$dupes = @()
$lineNo = 0
foreach ($raw in ([IO.File]::ReadAllText($textPath, [Text.Encoding]::UTF8) -split "`n")) {
    $lineNo++
    $line = $raw.TrimEnd("`r")
    if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }
    $parts = @($line -split "`t")
    if ($parts.Count -ne 3 -or $parts[1] -notin @('zh', 'en')) { $badRows += "第 $lineNo 行"; continue }
    $id = "$($parts[0])|$($parts[1])"
    # 用区分大小写的比较找重复：键名大小写不同在 bash 侧就是两个键
    if ($entries.Keys | Where-Object { $_ -ceq $id }) { $dupes += $id; continue }
    $entries[$id] = $parts[2]
    if (-not ($keys | Where-Object { $_ -ceq $parts[0] })) { $keys.Add($parts[0]) }
}
Check "每行都是 key<TAB>lang<TAB>text 且 lang 为 zh/en（共 $($entries.Count) 条）" ($badRows.Count -eq 0) ($badRows -join ', ')
Check '(key, lang) 没有重复' ($dupes.Count -eq 0) ($dupes -join ', ')

# ---------- 2. 双语齐全 ----------
$missing = @($keys | Where-Object {
    -not $entries.ContainsKey("$_|zh") -or -not $entries["$_|zh"] -or
    -not $entries.ContainsKey("$_|en") -or -not $entries["$_|en"]
})
Check "每个 key 都有非空的 zh 与 en（共 $($keys.Count) 个 key）" ($missing.Count -eq 0) ("缺: " + ($missing -join ', '))

$unpaired = @()
foreach ($k in $keys) {
    if ($k -like 'ps1:*' -and -not ($keys -ccontains ('sh:' + $k.Substring(4)))) { $unpaired += $k }
    if ($k -like 'sh:*'  -and -not ($keys -ccontains ('ps1:' + $k.Substring(3)))) { $unpaired += $k }
}
Check 'ps1: / sh: 前缀的 key 成对出现' ($unpaired.Count -eq 0) ($unpaired -join ', ')

# ---------- 3. 脚本里的引用都能解析 ----------
function Test-Resolves {
    param([string]$Key, [string]$Prefix)
    return ($keys -ccontains $Key) -or ($keys -ccontains ($Prefix + $Key))
}
foreach ($impl in @(
    @{ Name = 'census.ps1'; Path = $censusPs1; Prefix = 'ps1:'; KindPattern = "New-Warning\s+-Kind\s+'([A-Z_]+)'" },
    @{ Name = 'census.sh';  Path = $censusSh;  Prefix = 'sh:';  KindPattern = 'add_warn\s+"([A-Z_]+)"' }
)) {
    $src = [IO.File]::ReadAllText($impl.Path, [Text.Encoding]::UTF8)
    $used = @([regex]::Matches($src, "\bT\s+'([^'`$]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $kinds = @([regex]::Matches($src, $impl.KindPattern) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    foreach ($kind in $kinds) { $used += "warn.$kind.message"; $used += "warn.$kind.action" }
    $unresolved = @($used | Where-Object { -not (Test-Resolves $_ $impl.Prefix) })
    Check "$($impl.Name) 用到的 $($used.Count) 个文案 key 都查得到（含 $($kinds.Count) 种告警）" ($unresolved.Count -eq 0) ("查不到: " + ($unresolved -join ', '))
}

# ---------- 4. 实际运行 census.ps1 ----------
# 用当前宿主跑子进程（5.1 / 7 各自验证自己的读取路径），在临时目录里跑，避免往仓库写东西。
$psExe = (Get-Process -Id $PID).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ('census-text-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
function Invoke-Census {
    param([string]$Script, [string[]]$Arguments)
    $out = Join-Path $work 'out.txt'; $err = Join-Path $work 'err.txt'
    $p = Start-Process -FilePath $psExe -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $Arguments) `
                       -WorkingDirectory $work -PassThru -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError $err
    # Windows PowerShell 5.1 里 Start-Process 返回的进程对象若不先取一次 Handle，
    # 退出后 ExitCode 会是空值（CI 上实测）；取了句柄才能在退出后读到退出码。
    $null = $p.Handle
    if (-not $p.WaitForExit(180000)) { try { $p.Kill() } catch { }; return @{ code = -1; out = ''; err = 'timeout' } }
    $p.WaitForExit()
    return @{
        code = $p.ExitCode
        out  = [IO.File]::ReadAllText($out, [Text.Encoding]::UTF8)
        err  = [IO.File]::ReadAllText($err, [Text.Encoding]::UTF8)
    }
}
try {
    # 断言用 ASCII：子进程重定向到文件时，英文系统可能按 OEM 代码页写出中文
    $en = Invoke-Census $censusPs1 @('-Lang', 'en')
    Check 'census.ps1 -Lang en 正常退出' ($en.code -eq 0) "退出码 $($en.code) $($en.err)"
    Check 'census.ps1 -Lang en 输出英文章节标题' ($en.out -match '6\. Warnings' -and $en.out -match '1\. Declarations')
    Check 'census.ps1 -Lang en 输出里没有残留的文案 key' ($en.out -notmatch '\b(warn\.[A-Z_]+\.(message|action)|sec\.[a-z]+|sum\.[a-zA-Z]+)\b')

    $zh = Invoke-Census $censusPs1 @('-Lang', 'zh', '-Json')
    $zhJson = $null; try { $zhJson = $zh.out | ConvertFrom-Json } catch { }
    Check 'census.ps1 -Lang zh -Json 输出可解析的 JSON' ($null -ne $zhJson)
    $rawKeys = @(@($zhJson.warnings) | Where-Object { "$($_.message) $($_.action)" -match '\bwarn\.[A-Z_]+\.' })
    Check 'census.ps1 的告警 message/action 都已解析成文案' ($rawKeys.Count -eq 0) (($rawKeys | ForEach-Object { $_.kind }) -join ', ')

    # 文案表缺失：复制一份 census.ps1（和它依赖的 toolkit-common.ps1）到没有 tsv 的目录
    $lonely = Join-Path $work 'no-text'
    New-Item -ItemType Directory -Force -Path $lonely | Out-Null
    Copy-Item -LiteralPath $censusPs1, (Join-Path $scripts 'toolkit-common.ps1') -Destination $lonely
    $gone = Invoke-Census (Join-Path $lonely 'census.ps1') @('-Json')
    Check '文案表缺失时 census.ps1 以退出码 2 失败' ($gone.code -eq 2) "退出码 $($gone.code)"
    Check '文案表缺失时 stderr 指明 census-text.tsv' ($gone.err -match 'census-text\.tsv')
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host ' 全部通过' -ForegroundColor Green
    Write-Host ''
    exit 0
}
Write-Host " 有 $fail 项失败" -ForegroundColor Red
Write-Host ''
exit 1
