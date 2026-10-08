#Requires -Version 5.1
# 首扫基线（收敛计划 P1，只量不改行为）：在真实机器上用一份临时地图跑一次 map.ps1 scan，
# 打印墙钟时间与进程启动次数，作为"首扫探测并行化"之前的对比基线。
# 只量不判：数字随 runner 浮动，这里不设阈值。只有 scan 本身失败
# （非 0 退出、没有 JSON、ok 为假、缺 probeStats）才算失败。
# 输出行只用 ASCII：Windows PowerShell 5.1 的输出经 OEM 代码页进日志，中文会变成问号。
param([string]$Label = '')
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$hostExe = (Get-Process -Id $PID).Path
if (-not $Label) { $Label = "PowerShell $($PSVersionTable.PSVersion)" }
$tmpRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
# 地图旁边还会写一份 markdown 摘要，所以给它一个独立目录，收尾时整个删掉。
$work = Join-Path $tmpRoot ('scan-baseline-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($work)
$mapFile = Join-Path $work 'map.json'
try {
    $old = $ErrorActionPreference
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        # 5.1 上 EAP=Stop 时，子进程写 stderr 会被当成终止错误；与 map-contract 一样临时放宽。
        $ErrorActionPreference = 'Continue'
        $output = @(& $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\map.ps1') scan -MapFile $mapFile -Json 2>$null)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    $outerMs = [int64]$sw.Elapsed.TotalMilliseconds
    $line = @($output | ForEach-Object { "$_" } | Where-Object { $_ -match '^\{' }) | Select-Object -Last 1
    $result = $null
    if ($line) { try { $result = $line | ConvertFrom-Json } catch { } }
    if ($code -ne 0 -or -not $result -or -not $result.ok -or -not $result.probeStats) {
        $tail = (@($output) | Select-Object -Last 5) -join ' | '
        Write-Host "::error::scan baseline failed ($Label): exit=$code output=$tail"
        exit 1
    }
    $s = $result.probeStats
    $summary = "$Label first scan: wallMs=$($s.wallMs) (outer incl. host start=$outerMs) launches=$($s.launches) (census probes=$($s.census.launches), map probes=$($s.map.launches), +1 census host) probeMs=$($s.probeMs) censusWallMs=$($s.census.wallMs) tools=$($result.tools)"
    Write-Host "  [baseline] $summary"
    Write-Host "::notice title=scan baseline $Label::$summary"
    if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value "- $summary" }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
