[CmdletBinding()]
param(
    [string]$Project = (Get-Location).Path,
    [switch]$Mcp,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$mapPath = Join-Path $repoRoot 'scripts\map.ps1'
$serverPath = Join-Path $repoRoot 'mcp\server.mjs'
$powerShell = (Get-Process -Id $PID).Path

if (-not (Test-Path -LiteralPath $Project -PathType Container)) {
    throw "项目目录不存在：$Project"
}
if (-not (Test-Path -LiteralPath $mapPath)) {
    throw "找不到地图脚本：$mapPath"
}
$Project = [IO.Path]::GetFullPath($Project)

function Invoke-Map {
    param([string[]]$Arguments)
    $output = & $powerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $mapPath @Arguments -Json
    $parsed = $output | Out-String | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $parsed.ok) {
        $detail = if ($parsed.message) { $parsed.message } else { $parsed.status }
        throw "地图动作失败：$($Arguments -join ' ')（$detail）"
    }
    return $parsed
}

Write-Host ''
Write-Host '  toolkit-map quickstart' -ForegroundColor White
Write-Host "  项目：$Project" -ForegroundColor DarkGray
Write-Host "  源码：$repoRoot" -ForegroundColor DarkGray

Write-Host ''
Write-Host '  [1/2] 项目规则与地图' -ForegroundColor Cyan
if ($WhatIf) {
    $preview = & $powerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $mapPath setup -Project $Project -WhatIf -Json
    $parsedPreview = $preview | Out-String | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $parsedPreview.ok) { throw "预览失败：$($parsedPreview.message)" }
    Write-Host "  将写入：$($parsedPreview.rulesFile)" -ForegroundColor Yellow
    Write-Host '  -WhatIf 不建图、不写文件、不生成 MCP 配置。' -ForegroundColor DarkGray
} else {
    Write-Host '  首次建图可能需要几十秒；不安装运行时、不改 PATH。' -ForegroundColor DarkGray
    $setup = Invoke-Map @('setup', '-Project', $Project)
    Write-Host "  规则文件：$($setup.rulesFile)" -ForegroundColor Green
    if ($setup.backup) { Write-Host "  已备份：$($setup.backup)" -ForegroundColor DarkGray }
    Write-Host "  地图：$($setup.mapFile)" -ForegroundColor Green
}

if ($Mcp) {
    Write-Host ''
    Write-Host '  [2/2] MCP 配置' -ForegroundColor Cyan
    if ($WhatIf) {
        Write-Host '  将用地图查找 Node 18+，并输出 mcpServers 配置（不写客户端文件）。' -ForegroundColor Yellow
    } else {
        $node = $null
        try { $node = Invoke-Map @('find', 'node', '-Version', '>=18', '-Project', $Project) }
        catch {
            Write-Host "  MCP 跳过：$($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host '  规则文件已接入；安装 Node 18+ 后重新执行 -Mcp 即可。' -ForegroundColor DarkGray
        }
        if ($node) {
            Write-Host "  Node 18+：$($node.path)（$($node.version)）" -ForegroundColor Green
            Write-Host ''
            & $node.path $serverPath --print-config --project $Project
            Write-Host ''
            Write-Host '  把上面的 JSON 合并进 Cursor / Claude Code 的 mcpServers；Codex 用：' -ForegroundColor DarkGray
            Write-Host ('    & "{0}" "{1}" --print-config codex --project "{2}"' -f $node.path, $serverPath, $Project) -ForegroundColor DarkGray
            Write-Host '  不要覆盖配置文件里已有的其他服务器。' -ForegroundColor DarkGray
        }
    }
} else {
    Write-Host ''
    Write-Host '  [2/2] MCP 未启用（加 -Mcp 生成配置）' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '  下一步：新开 agent 会话，要求它先查地图再执行工具。' -ForegroundColor White
Write-Host '  验收与故障排查：docs\mcp.md、docs\troubleshooting.md' -ForegroundColor DarkGray
Write-Host ''
