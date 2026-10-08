#Requires -Version 5.1
# census-data.tsv（census.ps1 与 census.sh 共用的扫描数据）的结构检查（收敛计划 C3）：
#   1. 每个非注释行恰好 3 列 kind<TAB>os<TAB>value，kind 是已知的，os 只能是 win / unix / all，value 非空
#   2. 没有重复行；同一 kind 下同一个值不能既写 all 又写 win/unix（那样会在一边出现两次）
#   3. 每个必需的 kind 对 census.ps1（win）和 census.sh（unix）都至少有一个值
#   4. 值的形状：约定命令名只能是小写字母数字（要拼进正则）；按空白切分使用的 unix 值不能含空格；
#      根目录里的 {占位符} 只能是该实现会展开的那几个
#   5. 两个脚本都引用了每个 kind；缺表时 census.ps1 以退出码 2 明确失败
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$scripts = Join-Path $repo 'scripts'
$dataPath = Join-Path $scripts 'census-data.tsv'
. (Join-Path $scripts 'toolkit-common.ps1')
$fail = 0
function Check {
    param([string]$What, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host "  [通过] $What" }
    else { Write-Host "  [失败] $What $Detail"; Write-Host "::error::$What $Detail"; $script:fail++ }
}

Write-Host ''
Write-Host ' census-data.tsv 检查'
if (-not [IO.File]::Exists($dataPath)) { Write-Host "::error::找不到 $dataPath"; exit 1 }

$kinds = @('probe-rel', 'conda-dir', 'conda-rel', 'root', 'ide-glob', 'resolve', 'convention', 'convention-skip')
# ide-glob 只有 census.ps1 用（按盘符根匹配 IDE 目录），census.sh 没有对应概念
$unixOptional = @('ide-glob')
$placeholders = @{ win = @('APPDATA', 'LOCALAPPDATA', 'USERPROFILE'); unix = @('HOME', 'MISE_DATA') }

$rows = New-Object System.Collections.Generic.List[object]
$bad = @()
$lineNo = 0
foreach ($line in ([IO.File]::ReadAllText($dataPath, [Text.Encoding]::UTF8) -split "`n")) {
    $lineNo++
    if ($line.EndsWith("`r")) { $bad += "第 $lineNo 行有 CR"; $line = $line.TrimEnd("`r") }
    if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }
    $parts = $line -split "`t"
    if ($parts.Count -ne 3) { $bad += "第 $lineNo 行有 $($parts.Count) 列"; continue }
    if ($kinds -cnotcontains $parts[0]) { $bad += "第 $lineNo 行 kind 未知：$($parts[0])" }
    if (@('win', 'unix', 'all') -cnotcontains $parts[1]) { $bad += "第 $lineNo 行 os 无效：$($parts[1])" }
    if ($parts[2].Trim().Length -eq 0 -or $parts[2] -ne $parts[2].Trim()) { $bad += "第 $lineNo 行 value 为空或首尾有空白" }
    $rows.Add([pscustomobject]@{ line = $lineNo; kind = $parts[0]; os = $parts[1]; value = $parts[2] })
}
Check "每行都是 kind<TAB>os<TAB>value，kind 已知、os 为 win/unix/all（共 $($rows.Count) 行）" ($bad.Count -eq 0) ($bad -join '; ')

$seen = @{}
$dupes = @()
foreach ($r in $rows) {
    $key = "$($r.kind)|$($r.os)|$($r.value)"
    if ($seen.ContainsKey($key)) { $dupes += "$key（第 $($seen[$key]) / $($r.line) 行）" } else { $seen[$key] = $r.line }
}
Check '没有重复行' ($dupes.Count -eq 0) ($dupes -join '; ')
$overlap = @($rows | Where-Object { $_.os -ne 'all' -and $seen.ContainsKey("$($_.kind)|all|$($_.value)") } | ForEach-Object { "$($_.kind)|$($_.value)" })
Check '同一个值不会既写 all 又写 win/unix' ($overlap.Count -eq 0) ($overlap -join '; ')

foreach ($os in @('win', 'unix')) {
    $table = Read-ToolkitDataTable -Path $dataPath -Os $os
    $required = if ($os -eq 'unix') { @($kinds | Where-Object { $unixOptional -notcontains $_ }) } else { $kinds }
    $missing = @($required | Where-Object { -not $table.ContainsKey($_) -or $table[$_].Count -eq 0 })
    Check "$os 一侧每个必需的 kind 都有值" ($missing.Count -eq 0) ("缺: " + ($missing -join ', '))
}

$badShape = @()
foreach ($r in $rows) {
    if ($r.kind -in @('convention', 'convention-skip', 'resolve') -and $r.value -cnotmatch '^[a-z0-9]+$') { $badShape += "第 $($r.line) 行 $($r.kind) 只能是小写字母数字：$($r.value)" }
    if ($r.os -ne 'win' -and $r.kind -in @('probe-rel', 'conda-dir', 'conda-rel', 'resolve') -and $r.value -match '\s') { $badShape += "第 $($r.line) 行 census.sh 按空白切分，不能含空格：$($r.value)" }
    foreach ($m in [regex]::Matches($r.value, '\{([^}]*)\}')) {
        $allowed = if ($r.kind -ne 'root' -or $r.os -eq 'all') { @() } else { $placeholders[$r.os] }
        if ($allowed -cnotcontains $m.Groups[1].Value) { $badShape += "第 $($r.line) 行占位符 {$($m.Groups[1].Value)} 在 $($r.os) / $($r.kind) 里不会被展开" }
    }
}
Check '值的形状合法（命令名、空白、占位符）' ($badShape.Count -eq 0) ($badShape -join '; ')

foreach ($impl in @(@{ name = 'census.ps1'; file = 'census.ps1' }, @{ name = 'census.sh'; file = 'census.sh' })) {
    $src = [IO.File]::ReadAllText((Join-Path $scripts $impl.file), [Text.Encoding]::UTF8)
    $expect = if ($impl.name -eq 'census.sh') { @($kinds | Where-Object { $unixOptional -notcontains $_ }) } else { $kinds }
    $needle = if ($impl.name -eq 'census.sh') { 'data_list {0}' } else { "['{0}']" }
    $unused = @($expect | Where-Object { -not $src.Contains(($needle -f $_)) })
    Check "$($impl.name) 引用了每个 kind" ($unused.Count -eq 0) ("没引用: " + ($unused -join ', '))
}

# 缺表时 census.ps1 以退出码 2 失败，stderr 指明 census-data.tsv（复制 census.ps1 + 依赖到没有数据表的目录）
$psExe = (Get-Process -Id $PID).Path
$lonely = Join-Path ([IO.Path]::GetTempPath()) ('census-data-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($lonely)
try {
    foreach ($f in @('census.ps1', 'toolkit-common.ps1', 'census-text.tsv')) { Copy-Item -LiteralPath (Join-Path $scripts $f) -Destination $lonely }
    $out = Join-Path $lonely 'out.txt'; $err = Join-Path $lonely 'err.txt'
    $p = Start-Process -FilePath $psExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $lonely 'census.ps1'), '-Json') -WorkingDirectory $lonely -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    # PS5.1：先取一次句柄，否则 ExitCode 可能是 $null
    $null = $p.Handle
    $finished = $p.WaitForExit(60000)
    if ($finished) { $p.WaitForExit() } else { try { $p.Kill() } catch { } }
    $errText = if ([IO.File]::Exists($err)) { [IO.File]::ReadAllText($err, [Text.Encoding]::UTF8) } else { '' }
    Check '数据表缺失时 census.ps1 以退出码 2 失败' ($finished -and $p.ExitCode -eq 2) "退出码 $($p.ExitCode)"
    Check '数据表缺失时 stderr 指明 census-data.tsv' ($errText -match 'census-data\.tsv') $errText
} finally {
    Remove-Item -LiteralPath $lonely -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host ' 全部通过'; Write-Host ''; exit 0 }
Write-Host " 有 $fail 项失败"
exit 1
