$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$mapPath = Join-Path $repoRoot 'scripts\map.ps1'
$powerShell = (Get-Process -Id $PID).Path
$version = ([IO.File]::ReadAllText((Join-Path $repoRoot 'VERSION'), [Text.Encoding]::UTF8)).Trim()

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

$temp = Join-Path $env:TEMP ('toolkit-doctor-bundle-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$bin = Join-Path $temp 'bin'
$project = Join-Path $temp 'project'
$mapFile = Join-Path $temp 'map.json'
$runtime = Join-Path $bin 'runtime-a.cmd'

try {
    New-Item -ItemType Directory -Force -Path $bin, $project | Out-Null
    [IO.File]::WriteAllText($runtime, "@echo off`r`necho v22.23.2`r`n", (New-Object Text.UTF8Encoding($false)))

    Write-Host ''
    Write-Host ' doctor -Bundle 检查' -ForegroundColor White

    $missingOutput = & $powerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $mapPath doctor -Project $project -MapFile $mapFile -Bundle -Json
    $missing = $missingOutput | Out-String | ConvertFrom-Json
    Check '没有地图时仍返回结构化 doctor 结果' ($missing.status -eq 'attention_required')
    Check 'bundle.formatVersion 为 1' ($missing.bundle.formatVersion -eq 1)
    Check 'bundle.map.exists 为 false' ($missing.bundle.map.exists -eq $false)
    Check 'bundle 明确 agentVerified=false' ($missing.bundle.agentVerified -eq $false)
    Check 'bundle 不包含候选列表' (-not ($missing.bundle.map.PSObject.Properties.Name -contains 'candidates'))
    Check 'bundle 不包含 PATH 快照' (-not ($missing.bundle.map.PSObject.Properties.Name -contains 'pathSnapshot'))

    $null = & $powerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $mapPath add node -Path $runtime -Version '22.23.2' -MapFile $mapFile -Json
    $withMapOutput = & $powerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $mapPath doctor -Project $project -MapFile $mapFile -Bundle -Json
    $withMap = $withMapOutput | Out-String | ConvertFrom-Json
    Check '有地图时 bundle.map.exists 为 true' ($withMap.bundle.map.exists -eq $true)
    Check 'bundle.map.tools 是数字' ($withMap.bundle.map.tools -eq 1)
    Check 'bundle.map.warnings 是数组' ($withMap.bundle.map.warnings -is [array])
    Check 'bundle.version 与 VERSION 一致' ($withMap.bundle.version -eq $version)
    Check 'bundle.checks 包含检查项' (@($withMap.bundle.checks).Count -ge 4)
    Check 'bundle.generatedAt 非空' (-not [string]::IsNullOrWhiteSpace($withMap.bundle.generatedAt))
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
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
