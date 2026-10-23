[CmdletBinding()]
param(
    [string]$Project = (Get-Location).Path,
    [switch]$Mcp,
    [ValidateSet('cursor', 'claude', 'both')]
    [string]$McpClient = 'cursor',
    [switch]$WriteMcp,
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
if ($WriteMcp -and -not $Mcp) {
    throw '-WriteMcp 必须与 -Mcp 一起使用。'
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

function New-McpEntry {
    param([string]$NodePath)
    return [pscustomobject]@{
        command = $NodePath
        args     = @($serverPath)
        env      = [pscustomobject]@{ TOOLKIT_MAP_PROJECT = $Project }
    }
}

function Read-McpConfig {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $null }
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{} }
    try {
        $config = $text | ConvertFrom-Json
    } catch {
        throw "已有 MCP 配置不是合法 JSON，未写入：$Path"
    }
    if ($null -eq $config -or $config -is [array] -or -not ($config -is [pscustomobject])) {
        throw "已有 MCP 配置的根节点不是对象，未写入：$Path"
    }
    return $config
}

function Write-McpConfig {
    param([string]$Path, [object]$Existing, [object]$Entry)
    $directory = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $backup = ''
    if ([IO.File]::Exists($Path)) {
        $backup = "$Path.toolkit-map-" + (Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '.bak'
        Copy-Item -LiteralPath $Path -Destination $backup -Force
    }

    $config = if ($Existing) { $Existing } else { [pscustomobject]@{} }
    if (-not $config.PSObject.Properties['mcpServers'] -or $null -eq $config.mcpServers -or -not ($config.mcpServers -is [pscustomobject])) {
        $config | Add-Member -MemberType NoteProperty -Name mcpServers -Value ([pscustomobject]@{}) -Force
    }
    $config.mcpServers | Add-Member -MemberType NoteProperty -Name 'toolkit-map' -Value $Entry -Force

    $json = $config | ConvertTo-Json -Depth 20
    $temp = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temp, $json + "`n", (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temp -Destination $Path -Force
    } finally {
        if ([IO.File]::Exists($temp)) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
    return [pscustomobject]@{ path = $Path; backup = $backup }
}

function Get-McpTargets {
    $targets = @()
    if ($McpClient -in @('cursor', 'both')) {
        $targets += [pscustomobject]@{
            name = 'Cursor'
            path = Join-Path (Join-Path $Project '.cursor') 'mcp.json'
        }
    }
    if ($McpClient -in @('claude', 'both')) {
        $targets += [pscustomobject]@{
            name = 'Claude Code'
            path = Join-Path $Project '.mcp.json'
        }
    }
    return $targets
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
    $targets = @(Get-McpTargets)
    if ($WhatIf) {
        Write-Host '  将用地图查找 Node 18+，并输出 mcpServers 配置。' -ForegroundColor Yellow
        if ($WriteMcp) {
            foreach ($target in $targets) {
                Write-Host "  将写入 $($target.name)：$($target.path)" -ForegroundColor Yellow
            }
        } else {
            Write-Host '  未加 -WriteMcp：只打印配置，不写客户端文件。' -ForegroundColor DarkGray
        }
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

            if ($WriteMcp) {
                $entry = New-McpEntry $node.path
                $configs = @()
                foreach ($target in $targets) {
                    $configs += [pscustomobject]@{
                        target   = $target
                        existing = Read-McpConfig $target.path
                    }
                }
                foreach ($item in $configs) {
                    $written = Write-McpConfig -Path $item.target.path -Existing $item.existing -Entry $entry
                    Write-Host "  已写入 $($item.target.name)：$($written.path)" -ForegroundColor Green
                    if ($written.backup) { Write-Host "  已备份：$($written.backup)" -ForegroundColor DarkGray }
                }
                Write-Host '  已有 mcpServers 保留；只替换 toolkit-map 条目。' -ForegroundColor DarkGray
            } else {
                Write-Host '  把上面的 JSON 合并进 Cursor / Claude Code 的 mcpServers；Codex 用：' -ForegroundColor DarkGray
                Write-Host ('    & "{0}" "{1}" --print-config codex --project "{2}"' -f $node.path, $serverPath, $Project) -ForegroundColor DarkGray
                Write-Host '  加 -WriteMcp 可写入项目级配置（修改前备份）。' -ForegroundColor DarkGray
            }
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
