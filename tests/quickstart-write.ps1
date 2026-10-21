$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-Host '  跳过：quickstart 配置写入目前只在 Windows 上验证' -ForegroundColor Yellow
    exit 0
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$mapScript = Join-Path (Join-Path $repoRoot 'scripts') 'map.ps1'
$quickstart = Join-Path (Join-Path $repoRoot 'scripts') 'quickstart.ps1'
$powerShell = (Get-Process -Id $PID).Path
$temp = Join-Path $env:TEMP ('toolkit-quickstart-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

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

try {
    $project = Join-Path $temp 'project'
    $bin = Join-Path $temp 'bin'
    $mapFile = Join-Path $temp 'map.json'
    $fakeNode = Join-Path $bin 'runtime-a.cmd'
    New-Item -ItemType Directory -Force -Path $project, $bin, (Join-Path $project '.cursor') | Out-Null
    [IO.File]::WriteAllText($fakeNode, "@echo off`r`necho v22.99.2`r`n", (New-Object Text.UTF8Encoding($false)))

    $addOutput = & $powerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $mapScript add node -Path $fakeNode -MapFile $mapFile -Prefer -Json
    $added = $addOutput | Out-String | ConvertFrom-Json
    Check '临时地图登记成功' ($LASTEXITCODE -eq 0 -and $added.ok)

    $existing = '{"mcpServers":{"other":{"command":"keep-me"}}}'
    [IO.File]::WriteAllText((Join-Path $project '.cursor\mcp.json'), $existing, (New-Object Text.UTF8Encoding($false)))

    $previousMap = $env:TOOLKIT_MAP
    $env:TOOLKIT_MAP = $mapFile
    try {
        & $powerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $quickstart -Project $project -Mcp -WriteMcp -McpClient both
        Check 'quickstart 写入成功' ($LASTEXITCODE -eq 0)
    } finally {
        if ($null -eq $previousMap) { Remove-Item Env:\TOOLKIT_MAP -ErrorAction SilentlyContinue } else { $env:TOOLKIT_MAP = $previousMap }
    }

    $cursorPath = Join-Path $project '.cursor\mcp.json'
    $claudePath = Join-Path $project '.mcp.json'
    Check '写入 Cursor 配置' ([IO.File]::Exists($cursorPath))
    Check '写入 Claude Code 配置' ([IO.File]::Exists($claudePath))

    if ([IO.File]::Exists($cursorPath)) {
        $cursor = [IO.File]::ReadAllText($cursorPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        Check '保留已有服务器' ($cursor.mcpServers.other.command -eq 'keep-me')
        Check '写入 toolkit-map 条目' ([bool]$cursor.mcpServers.'toolkit-map')
        $configuredCommand = $cursor.mcpServers.'toolkit-map'.command
        Check 'command 指向已登记的 Node' ([IO.File]::Exists($configuredCommand) -and (Split-Path $configuredCommand -Leaf) -eq 'runtime-a.cmd')
        Check 'env 指向项目目录' (Test-Path -LiteralPath $cursor.mcpServers.'toolkit-map'.env.TOOLKIT_MAP_PROJECT -PathType Container)
    }
    Check '修改前备份' (@(Get-ChildItem (Join-Path $project '.cursor') -Filter '*.bak').Count -ge 1)

    $previewProject = Join-Path $temp 'preview'
    New-Item -ItemType Directory -Force -Path $previewProject | Out-Null
    $previousMap = $env:TOOLKIT_MAP
    $env:TOOLKIT_MAP = $mapFile
    try {
        & $powerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $quickstart -Project $previewProject -Mcp -WriteMcp -WhatIf
        Check '-WhatIf 不写配置' (-not (Test-Path -LiteralPath (Join-Path $previewProject '.cursor\mcp.json')) -and -not (Test-Path -LiteralPath (Join-Path $previewProject '.mcp.json')))
    } finally {
        if ($null -eq $previousMap) { Remove-Item Env:\TOOLKIT_MAP -ErrorAction SilentlyContinue } else { $env:TOOLKIT_MAP = $previousMap }
    }
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
