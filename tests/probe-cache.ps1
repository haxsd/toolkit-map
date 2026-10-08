#Requires -Version 5.1
# 统一探测执行器 Invoke-ToolkitProbe 的进程内缓存（收敛计划 P2）：
#   - 同一个未变的文件 + 同样的参数，第二次不再启动进程（launches 不变，cached 为真）；
#   - 修改时间变了、大小变了、换了参数，都要重新启动；
#   - -NoCache 每次都启动；shim 永远不启动、不计数；
#   - 地图侧的 Get-ExeVersion 走同一个缓存，连续两次探测同一文件只启动一次；
#   - 并行批次（P3）：去重、shim 不启动、挂住的工具按超时结束，之后串行再探全部命中缓存。
# 只跑临时目录里的假工具（Windows 上是 .cmd，其他平台是 #!/bin/sh 脚本），不执行真实工具。
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$scripts = Join-Path $repo 'scripts'
. (Join-Path $scripts 'toolkit-common.ps1')
. (Join-Path $scripts 'map-core.ps1')
$script:ToolCatalog = @{}
$onWindows = [IO.Path]::DirectorySeparatorChar -eq '\'
$fail = 0
function Check {
    param([string]$What, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host "  [通过] $What" }
    else { Write-Host "  [失败] $What $Detail"; Write-Host "::error::$What $Detail"; $script:fail++ }
}
function Write-FakeTool {
    param([string]$Path, [string]$Version)
    if ($onWindows) {
        [IO.File]::WriteAllText($Path, "@echo off`r`necho faketool $Version`r`nexit /b 0`r`n", [Text.Encoding]::ASCII)
    } else {
        [IO.File]::WriteAllText($Path, "#!/bin/sh`necho faketool $Version`n", [Text.Encoding]::ASCII)
        & chmod +x $Path
    }
}
function Get-Launches { return [int]$script:ToolkitProbeStats.launches }

$work = Join-Path ([IO.Path]::GetTempPath()) ('probe-cache-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($work)
try {
    $name = if ($onWindows) { 'faketool.cmd' } else { 'faketool' }
    $tool = Join-Path $work $name
    Write-FakeTool $tool '1.0.0'

    $n0 = Get-Launches
    $r1 = Invoke-ToolkitProbe $tool @('--version')
    Check '首次探测启动一次进程并拿到输出' ($r1.ok -and $r1.exitCode -eq 0 -and $r1.stdout -match 'faketool 1\.0\.0' -and -not $r1.cached -and (Get-Launches) -eq $n0 + 1) "ok=$($r1.ok) exit=$($r1.exitCode) out=$($r1.stdout) reason=$($r1.reason) launches=$((Get-Launches) - $n0)"

    $n1 = Get-Launches
    $r2 = Invoke-ToolkitProbe $tool @('--version')
    Check '同一未变文件、同样参数：不再启动（launches 不变）' ((Get-Launches) -eq $n1 -and $r2.cached -and $r2.stdout -eq $r1.stdout -and $r2.exitCode -eq 0) "launches=$((Get-Launches) - $n1) cached=$($r2.cached)"

    $n2 = Get-Launches
    $null = Invoke-ToolkitProbe $tool @('-version')
    Check '换参数：重新启动' ((Get-Launches) -eq $n2 + 1)

    $n3 = Get-Launches
    [IO.File]::SetLastWriteTimeUtc($tool, [IO.File]::GetLastWriteTimeUtc($tool).AddMinutes(-5))
    $r3 = Invoke-ToolkitProbe $tool @('--version')
    Check '只改修改时间：缓存失效、重新启动' ((Get-Launches) -eq $n3 + 1 -and -not $r3.cached)

    $n4 = Get-Launches
    $stamp = [IO.File]::GetLastWriteTimeUtc($tool)
    Write-FakeTool $tool '22.10.100'
    [IO.File]::SetLastWriteTimeUtc($tool, $stamp)
    $r4 = Invoke-ToolkitProbe $tool @('--version')
    Check '只改大小（修改时间还原）：缓存失效、拿到新输出' ((Get-Launches) -eq $n4 + 1 -and $r4.stdout -match 'faketool 22\.10\.100') "out=$($r4.stdout)"

    $n5 = Get-Launches
    $null = Invoke-ToolkitProbe $tool @('--version') -NoCache
    $null = Invoke-ToolkitProbe $tool @('--version') -NoCache
    Check '-NoCache 每次都启动' ((Get-Launches) -eq $n5 + 2)

    $shimDir = Join-Path $work 'shims'
    [void][IO.Directory]::CreateDirectory($shimDir)
    $shim = Join-Path $shimDir $name
    Write-FakeTool $shim '9.9.9'
    $n6 = Get-Launches
    $r6 = Invoke-ToolkitProbe $shim @('--version')
    Check 'shim 不启动、不计数' ($r6.reason -eq 'skipped' -and -not $r6.ok -and (Get-Launches) -eq $n6) "reason=$($r6.reason)"

    # 地图侧：Get-ExeVersion → Get-ProbeText → Invoke-ToolkitProbe，同一文件第二次不启动
    $other = Join-Path $work ('othertool' + $(if ($onWindows) { '.cmd' } else { '' }))
    Write-FakeTool $other '3.4.5'
    $n7 = Get-Launches
    $v1 = Get-ExeVersion $other
    $mid = Get-Launches
    $v2 = Get-ExeVersion $other
    Check 'Get-ExeVersion 连续两次只启动一次' ($v1 -eq '3.4.5' -and $v2 -eq '3.4.5' -and $mid -eq $n7 + 1 -and (Get-Launches) -eq $mid) "v1=$v1 v2=$v2 first=$($mid - $n7) second=$((Get-Launches) - $mid)"
    Check 'Get-ProbeText 命中缓存时 LastProbe 仍为成功' ($script:LastProbe.ok -and $script:LastProbe.reason -eq 'ok' -and $script:LastProbe.exitCode -eq 0)

    # 并行预热（收敛计划 P3）：Invoke-ToolkitProbeBatch 在 RunspacePool 里探测、结果进同一个缓存
    $ext = if ($onWindows) { '.cmd' } else { '' }
    $fast = @(1..3 | ForEach-Object { $f = Join-Path $work ("par$_" + $ext); Write-FakeTool $f "5.0.$_"; $f })
    $hang = Join-Path $work ('hangtool' + $ext)
    if ($onWindows) {
        [IO.File]::WriteAllText($hang, "@echo off`r`nping -n 30 127.0.0.1 >nul`r`necho never`r`n", [Text.Encoding]::ASCII)
    } else {
        [IO.File]::WriteAllText($hang, "#!/bin/sh`nsleep 30`necho never`n", [Text.Encoding]::ASCII)
        & chmod +x $hang
    }
    $jobs = @($fast | ForEach-Object { @{ exe = $_; args = @('--version') } }) + @(@{ exe = $hang; args = @('--version') }, @{ exe = $shim; args = @('--version') }, @{ exe = $fast[0]; args = @('--version') })
    $n8 = Get-Launches
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $planned = Invoke-ToolkitProbeBatch -Jobs $jobs -Throttle 4 -TimeoutMs 3000
    $sw.Stop()
    Check '并行批次：去重、跳过 shim，只启动 4 个进程' ($planned -eq 4 -and (Get-Launches) -eq $n8 + 4) "planned=$planned launches=$((Get-Launches) - $n8)"
    Check '并行批次：挂住的假工具按超时结束，整批远小于 30 秒' ($sw.ElapsedMilliseconds -lt 20000) "ms=$($sw.ElapsedMilliseconds)"
    $n9 = Get-Launches
    $h = Invoke-ToolkitProbe $hang @('--version')
    $okAll = $true
    foreach ($i in 0..2) { $r = Invoke-ToolkitProbe $fast[$i] @('--version'); if (-not ($r.cached -and $r.ok -and $r.stdout -match "faketool 5\.0\.$($i + 1)")) { $okAll = $false } }
    Check '并行批次之后串行再探：全部命中缓存、不再启动' ((Get-Launches) -eq $n9 -and $okAll) "launches=$((Get-Launches) - $n9)"
    Check '挂住的那个结果是 timeout' ($h.reason -eq 'timeout' -and -not $h.ok -and $h.cached) "reason=$($h.reason)"
    $n10 = Get-Launches
    Check '-Throttle 1 不预热（等于原来的串行）' ((Invoke-ToolkitProbeBatch -Jobs @(@{ exe = $other; args = @('-x') }) -Throttle 1) -eq 0 -and (Get-Launches) -eq $n10)
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host ' 全部通过'; exit 0 }
Write-Host " 有 $fail 项失败"
exit 1
