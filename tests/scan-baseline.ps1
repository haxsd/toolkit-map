#Requires -Version 5.1
# 首扫基线（收敛计划 P1 起）：在真实机器上用临时地图跑 map.ps1 scan，
# 打印墙钟时间与进程启动次数，作为首扫探测优化前后的对比基线。
#
# 去掉预热干扰：同一宿主连续跑 -Runs 次（默认 2），只有最后一次计入基线，
# 前面的都标成 warm-up（不计）。CI 里另外让宿主交替出场（先 PS7 后 PS5.1），
# 磁盘缓存、.NET 首次 JIT、杀毒首扫这些一次性开销落在不计的那一轮。
#
# 每一轮都必须是冷的"首扫"：
#   - 每轮一个全新的临时目录放 -MapFile（地图与 map.md 都写在里面），没有旧地图可合并；
#   - 每轮是一个新的 map.ps1 进程。探测缓存（Invoke-ToolkitProbe）只在进程内存里，
#     不落盘，所以每轮都从空缓存开始，测到的不是上一轮的缓存命中。
#   - 不改 LOCALAPPDATA / USERPROFILE：扫描要看真实机器上的安装位置，换掉它们
#     等于换了一台机器，数字就没法和之前对比了。
#
# 只量不判：数字随 runner 浮动，这里不设阈值。只有 scan 本身失败
# （非 0 退出、没有 JSON、ok 为假、缺 probeStats）才算失败。
# 输出行只用 ASCII：Windows PowerShell 5.1 的输出经 OEM 代码页进日志，中文会变成问号。
param([string]$Label = '', [int]$Runs = 2)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$hostExe = (Get-Process -Id $PID).Path
if (-not $Label) { $Label = "PowerShell $($PSVersionTable.PSVersion)" }
if ($Runs -lt 1) { $Runs = 1 }
$tmpRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }

function Invoke-BaselineScan {
    param([int]$Run)
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
            Write-Host "::error::scan baseline failed ($Label run $Run): exit=$code output=$tail"
            exit 1
        }
        $s = $result.probeStats
        return "wallMs=$($s.wallMs) (outer incl. host start=$outerMs) launches=$($s.launches) (census probes=$($s.census.launches), map probes=$($s.map.launches), +1 census host) probeMs=$($s.probeMs) censusWallMs=$($s.census.wallMs) tools=$($result.tools)"
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

for ($run = 1; $run -le $Runs; $run++) {
    $stats = Invoke-BaselineScan $run
    $counted = ($run -eq $Runs)
    $tag = if ($counted) { 'COUNTED' } else { 'warm-up, not counted' }
    $summary = "$Label first scan run $run/$Runs [$tag]: $stats"
    Write-Host "  [baseline] $summary"
    if ($counted) { Write-Host "::notice title=scan baseline $Label (counted run $run/$Runs)::$summary" }
    if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value "- $summary" }
}
