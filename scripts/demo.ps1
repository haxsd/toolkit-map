[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$mapPath = Join-Path $repoRoot 'scripts\map.ps1'
if (-not (Test-Path -LiteralPath $mapPath)) { throw "找不到地图脚本：$mapPath" }

$demoRoot = Join-Path $env:TEMP ('toolkit-map-demo-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$bin = Join-Path $demoRoot 'bin'
$project = Join-Path $demoRoot 'project'
$mapFile = Join-Path $demoRoot 'map.json'
$node16 = Join-Path $bin 'runtime-a.cmd'
$node22 = Join-Path $bin 'runtime-b.cmd'
$powerShell = (Get-Process -Id $PID).Path

function Invoke-DemoMap {
    param([string[]]$Arguments, [switch]$AllowFailure)
    $output = & $powerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $mapPath @Arguments -MapFile $mapFile -Json
    $parsed = $output | Out-String | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) { throw "地图动作失败：$($Arguments -join ' ')" }
    return $parsed
}

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host "  $Text" -ForegroundColor Cyan
}

try {
    New-Item -ItemType Directory -Force -Path $bin, $project | Out-Null
    [IO.File]::WriteAllText($node16, "@echo off`r`necho v16.20.2`r`n", (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($node22, "@echo off`r`necho v22.23.2`r`n", (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $project '.nvmrc'), "22`n", (New-Object Text.UTF8Encoding($false)))

    Write-Host ''
    Write-Host '  toolkit-map 2 分钟演示' -ForegroundColor White
    Write-Host '  （使用临时地图，不读取也不修改 ~/.toolkit/map.json）' -ForegroundColor DarkGray

    Write-Step '[1/4] 登记两个已存在的 Node 副本'
    $null = Invoke-DemoMap @('add', 'node', '-Path', $node16, '-Version', '16.20.2')
    $null = Invoke-DemoMap @('add', 'node', '-Path', $node22, '-Version', '22.23.2')
    Write-Host "  16 → $node16" -ForegroundColor DarkGray
    Write-Host "  22 → $node22" -ForegroundColor DarkGray

    Write-Step '[2/4] 项目声明：Node 22（.nvmrc）'
    Write-Host "  $project\.nvmrc = 22" -ForegroundColor DarkGray

    Write-Step '[3/4] agent 直接运行旧版本（模拟 PATH 上的 16）'
    $oldOutput = (& $node16 --version | Out-String).Trim()
    Write-Host "  node --version → $oldOutput" -ForegroundColor Yellow
    Write-Host '  这是常见起点：命令能跑，但版本不是项目要求的。' -ForegroundColor DarkGray

    Write-Step '[4/4] 先查地图，再执行返回的绝对路径'
    $result = Invoke-DemoMap @('find', 'node', '-Project', $project, '-SkipScan')
    if (-not $result.ok) { throw "演示失败：$($result.status) $($result.message)" }
    Write-Host "  requirement → $($result.requirement.version)（$($result.requirement.scope)）" -ForegroundColor DarkGray
    Write-Host "  path        → $($result.path)" -ForegroundColor Green
    Write-Host "  version     → $($result.version)；verification → $($result.verification)" -ForegroundColor Green
    $newOutput = (& $result.path --version | Out-String).Trim()
    Write-Host "  执行返回路径 → $newOutput" -ForegroundColor Green

    Write-Step '[对照] 把项目要求改成 Node 24'
    [IO.File]::WriteAllText((Join-Path $project '.nvmrc'), "24`n", (New-Object Text.UTF8Encoding($false)))
    $missing = Invoke-DemoMap @('find', 'node', '-Project', $project, '-SkipScan') -AllowFailure
    Write-Host "  status → $($missing.status)" -ForegroundColor Yellow
    Write-Host "  path   → '$($missing.path)'" -ForegroundColor Yellow
    Write-Host '  没有满足要求的副本时，地图不降级、不返回 16 的路径。' -ForegroundColor DarkGray

    Write-Host ''
    Write-Host '  演示完成。真实接入见 README 的「首次接入」与 docs/mcp.md。' -ForegroundColor White
    Write-Host ''
} finally {
    Remove-Item -LiteralPath $demoRoot -Recurse -Force -ErrorAction SilentlyContinue
}
