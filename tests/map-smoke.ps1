<#
.SYNOPSIS
  地图核心动作冒烟测试：查找要返回活路径，安装不得覆盖已有版本。

.DESCRIPTION
  使用临时地图和临时统一仓库调用真实的 scripts/map.ps1，不读取或修改使用者的本机地图。
  这个测试刻意不触网、不安装工具，只验证高风险边界。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$mapScript = Join-Path $repoRoot 'scripts\map.ps1'
$psExe = (Get-Process -Id $PID).Path
$scratch = Join-Path $env:TEMP ('toolkit-map-smoke-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$mapFile = Join-Path $scratch 'map.json'
$warehouse = Join-Path $scratch 'toolchains'
$oldToolchainRoot = $env:TOOLCHAIN_ROOT
$oldPath = $env:PATH

function Fail {
    param([string]$Message)
    Write-Host "::error::map-smoke.ps1：$Message"
    throw $Message
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { Fail $Message }
}

function Invoke-Map {
    param([string[]]$Arguments)
    $savedPreference = $ErrorActionPreference
    try {
        # 被测脚本故意有一个“应失败”的安装用例；把子进程 stderr 收进结果，
        # 不让测试宿主在断言之前把它当成自己的异常。
        $ErrorActionPreference = 'Continue'
        $output = @(& $psExe -NoProfile -ExecutionPolicy Bypass -File $mapScript @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    [pscustomobject]@{
        Output = $output
        ExitCode = $code
    }
}

function Get-JsonOutput {
    param($Result)
    $line = @($Result.Output | ForEach-Object { "$($_)" } | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1)
    if ($line.Count -eq 0) {
        Fail ("没有找到 JSON 输出：" + (($Result.Output | ForEach-Object { "$($_)" }) -join "`n"))
    }
    return ($line[0] | ConvertFrom-Json)
}

function Write-Fixture {
    param([hashtable]$Tools)
    $fixture = @{
        schemaVersion = 1
        scannedAt = (Get-Date).ToString('o')
        warehouse = $warehouse
        pathSnapshot = $env:PATH
        tools = $Tools
    }
    New-Item -ItemType Directory -Force -Path $scratch | Out-Null
    ($fixture | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $mapFile -Encoding UTF8
}

try {
    New-Item -ItemType Directory -Force -Path $scratch, $warehouse | Out-Null
    $env:TOOLCHAIN_ROOT = $warehouse

    $gitPath = @($env:PATH -split ';' |
        Where-Object { $_ } |
        ForEach-Object { Join-Path $_ 'git.exe' } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1)
    Assert-True ($gitPath.Count -eq 1) '测试环境没有可用于验证的 git.exe'

    $deadPath = Join-Path $scratch 'removed\git.exe'
    $tools = @{
        git = @{
            preferred = 'stale-0.0.0'
            candidates = @(@{
                id = 'stale-0.0.0'; version = '0.0.0'; path = $deadPath
                source = 'system'; reachable = $false; isShim = $false; note = ''
            })
        }
        'map-smoke-empty' = @{
            preferred = 'missing'
            candidates = @()
        }
    }
    Write-Fixture $tools

    # 原子写入器是 map.ps1 的内部实现，但用真实 dot-source 调用验证它，
    # 确保地图与摘要不会继续依赖直接覆盖写入。
    . $mapScript -Action status -MapFile $mapFile
    Assert-True ($null -ne (Get-Command Write-AtomicUtf8 -ErrorAction SilentlyContinue)) 'map.ps1 缺少原子 UTF-8 写入器'
    $atomicProbe = Join-Path $scratch 'atomic-probe.txt'
    Write-AtomicUtf8 -Path $atomicProbe -Content 'atomic-ok'
    Assert-True ((Get-Content -LiteralPath $atomicProbe -Raw).Trim() -eq 'atomic-ok') '原子 UTF-8 写入器没有写出完整内容'

    # 证书吊销服务器不可达时的重试：受控网络里复现不了 schannel 的失败，
    # 所以用"第一次抛证书类错误、第二次成功"的假动作验证边界（不触网）。
    Assert-True ($null -ne (Get-Command Invoke-NetRetry -ErrorAction SilentlyContinue)) 'map.ps1 缺少 Invoke-NetRetry'

    $script:netCalls = 0
    $beforeRevoke = [Net.ServicePointManager]::CheckCertificateRevocationList
    $retried = & Invoke-NetRetry -What '冒烟测试' -Action {
        $script:netCalls++
        if ($script:netCalls -eq 1) { throw 'The underlying connection was closed: Could not establish trust relationship for the SSL/TLS secure channel.' }
        'retried-ok'
    } 3>$null
    Assert-True ($retried -eq 'retried-ok') '证书类错误应被重试，而不是直接抛出'
    Assert-True ($script:netCalls -eq 2) "证书类错误应恰好重试一次；实际请求 $($script:netCalls) 次"
    Assert-True ([Net.ServicePointManager]::CheckCertificateRevocationList -eq $beforeRevoke) '重试后应还原吊销检查设置'

    $script:netCalls = 0
    $threw = $false
    try {
        & Invoke-NetRetry -What '冒烟测试' -Action {
            $script:netCalls++
            throw 'Response status code does not indicate success: 404 (Not Found).'
        } 3>$null | Out-Null
    } catch { $threw = $true }
    Assert-True $threw '非证书类错误应原样抛出'
    Assert-True ($script:netCalls -eq 1) "非证书类错误不该重试；实际请求 $($script:netCalls) 次"

    # 版本写在 stderr 的工具也要探到版本：老实现用 `& $exe --version 2>&1`，而全局
    # $ErrorActionPreference='Stop' 会把原生命令的 stderr 变成终止性错误、再被 catch 吞掉，
    # 于是版本恒为空（实测：统一仓库里的 JDK 8 就被记成空版本）。用一个假 java 钉住边界。
    $stubDir = Join-Path $scratch 'stub'
    New-Item -ItemType Directory -Force -Path $stubDir | Out-Null
    $fakeJava = Join-Path $stubDir 'fake-java.cmd'
    @(
        '@echo off'
        'if "%1"=="-version" goto ver'
        'echo Unrecognized option: %1 1>&2'
        'exit /b 1'
        ':ver'
        'echo openjdk version "1.8.0_504" 1>&2'
        'exit /b 0'
    ) -join "`r`n" | Set-Content -LiteralPath $fakeJava -Encoding ASCII
    $probed = Get-ExeVersion -ExePath $fakeJava
    Assert-True ($probed -eq '1.8.0_504') "版本写在 stderr 的工具应能探到版本；实际='$probed'"

    # 只吐报错文本的"工具"不该把报错当版本记进地图（老实现会把首行原样返回）
    $noisy = Join-Path $stubDir 'no-version.cmd'
    @('@echo off', 'echo Unrecognized option: --version 1>&2', 'exit /b 1') -join "`r`n" |
        Set-Content -LiteralPath $noisy -Encoding ASCII
    $noisyVer = Get-ExeVersion -ExePath $noisy
    Assert-True (-not $noisyVer) "不该把报错文本当成版本；实际='$noisyVer'"

    # 候选 id 必须工具内唯一（docs/reference.md 的契约：preferred 指向 id）：
    # java 8 的 bin\java.exe 与 jre\bin\java.exe 父亲目录同名，只按父目录名区分会撞车。
    $idPair = @(
        @{ id = 'warehouse-1.8.0_504'; path = 'X:\toolchains\java\8u504b01\bin\java.exe' },
        @{ id = 'warehouse-1.8.0_504'; path = 'X:\toolchains\java\8u504b01\jre\bin\java.exe' }
    )
    Set-UniqueCandidateIds -Candidates $idPair
    $ids = @($idPair | ForEach-Object { $_.id })
    Assert-True (($ids | Sort-Object -Unique).Count -eq $ids.Count) "候选 id 必须唯一；实际=$($ids -join ' / ')"
    Assert-True ($ids -notcontains 'warehouse-1.8.0_504') '撞车的 id 应被区分开，而不是原样保留'

    $result = Invoke-Map @('find', 'git', '-Json', '-MapFile', $mapFile)
    $jsonResult = Get-JsonOutput $result
    Assert-True ($result.ExitCode -eq 0) "失效首选路径修复后 find 应成功，退出码为 $($result.ExitCode)"
    Assert-True ([bool]$jsonResult.found) '失效首选路径修复后 found 应为 true'
    Assert-True ($jsonResult.path -ne $deadPath -and (Test-Path -LiteralPath $jsonResult.path -PathType Leaf)) "find 应返回现场找到的活路径；实际=$($jsonResult.path)"

    $result = Invoke-Map @('find', 'git', '-Json', '-SkipScan', '-MapFile', $mapFile)
    $jsonResult = Get-JsonOutput $result
    Assert-True ($result.ExitCode -eq 0 -and [bool]$jsonResult.found) '修复后的 git 条目应能在跳过现场搜索时继续使用'
    Assert-True ($jsonResult.path -ne $deadPath -and (Test-Path -LiteralPath $jsonResult.path -PathType Leaf)) '地图修复结果没有持久化'

    $result = Invoke-Map @('find', 'map-smoke-empty', '-Json', '-SkipScan', '-MapFile', $mapFile)
    $jsonResult = Get-JsonOutput $result
    Assert-True ($result.ExitCode -ne 0) '没有候选时 find 不应返回成功'
    Assert-True (-not [bool]$jsonResult.found) '没有候选时 found 应为 false'

    $target = Join-Path (Join-Path $warehouse 'collision-tool') '1.0.0'
    $sentinel = Join-Path $target 'sentinel.txt'
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    'keep me' | Set-Content -LiteralPath $sentinel -Encoding ASCII
    $result = Invoke-Map @('install', 'collision-tool', '-Version', '1.0.0', '-Url', 'https://example.invalid/toolkit-map-test.zip', '-MapFile', $mapFile)
    $outputText = ($result.Output | ForEach-Object { "$($_)" }) -join "`n"
    Assert-True ($result.ExitCode -ne 0) '目标版本已存在时 install 应失败而不是覆盖'
    Assert-True ($outputText -match '拒绝覆盖') 'install 应明确说明拒绝覆盖已有版本'
    Assert-True ((Get-Content -LiteralPath $sentinel -Raw).Trim() -eq 'keep me') '已有版本目录中的文件被改动'

    $fakeWingetBin = Join-Path $scratch 'fake-winget'
    New-Item -ItemType Directory -Force -Path $fakeWingetBin | Out-Null
    $fakeWinget = Join-Path $fakeWingetBin 'winget.cmd'
    "@echo off`r`necho fake winget failure`r`nexit /b 42" |
        Set-Content -LiteralPath $fakeWinget -Encoding ASCII
    $env:PATH = $fakeWingetBin + ';' + $oldPath
    $result = Invoke-Map @('install', 'winget-smoke-tool', '-Via', 'winget', '-MapFile', $mapFile)
    $outputText = ($result.Output | ForEach-Object { "$($_)" }) -join "`n"
    Assert-True ($result.ExitCode -ne 0) 'winget 失败时 install 应返回非零退出码'
    Assert-True ($outputText -match 'winget 安装失败') 'winget 失败时应明确报告安装失败，而不是继续登记'
    $savedMap = Get-Content -LiteralPath $mapFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (-not $savedMap.tools.PSObject.Properties.Name.Contains('winget-smoke-tool')) 'winget 失败时不应把旧候选登记为新安装'

    $tempMapFiles = @(Get-ChildItem -LiteralPath $scratch -Filter 'map.json.*.tmp' -File -ErrorAction SilentlyContinue)
    Assert-True ($tempMapFiles.Count -eq 0) '地图原子写入留下了临时文件'

    Write-Host '  [通过] map.ps1 查找与安装边界冒烟测试' -ForegroundColor Green
} finally {
    $env:TOOLCHAIN_ROOT = $oldToolchainRoot
    $env:PATH = $oldPath
    if (Test-Path -LiteralPath $scratch) {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 被测子进程最后一个用例预期以非零退出；显式结束，避免 Windows PowerShell
# 把那个“预期失败”的 $LASTEXITCODE 当成整个测试的失败码。
exit 0
