[CmdletBinding()]
param(
    # 本地诊断用：只跑 MCP 测试，不改变发布工作流调用完整门禁的方式。
    [switch]$McpOnly
)

$ErrorActionPreference = 'Stop'
$checks = @(
    'check-docs.ps1',
    'check-encodings.ps1',
    'check-text.ps1',
    'check-data.ps1',
    'check-contract.ps1',
    'records-guard.ps1',
    'doctor-bundle.ps1',
    'quickstart-write.ps1',
    'release-package.ps1',
    'map-smoke.ps1',
    'map-contract.ps1',
    'version-contract.ps1',
    'install-contract.ps1',
    'download-contract.ps1',
    'scan-guards.ps1',
    'probe-cache.ps1',
    'parity.ps1'
)

$failed = New-Object System.Collections.Generic.List[string]
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'scripts\toolkit-common.ps1')
if ($McpOnly) { $checks = @() }

$version = ([IO.File]::ReadAllText((Join-Path $repoRoot 'VERSION'), [Text.Encoding]::UTF8)).Trim()
$notesPath = Join-Path (Join-Path (Join-Path $repoRoot 'docs') 'releases') "v$version.md"
if (-not $McpOnly -and -not [IO.File]::Exists($notesPath)) {
    Write-Host "  [门禁失败] 缺少发布说明：$notesPath" -ForegroundColor Red
    Write-Host "::error::缺少发布说明：$notesPath"
    exit 1
}
Write-Host ''
$gateTitle = if ($McpOnly) { '发布门禁：MCP 测试' } else { '发布门禁：完整回归' }
Write-Host " $gateTitle" -ForegroundColor White

# 先跑 MCP：下面的 PowerShell 检查会在同一进程里改 PATH / USERPROFILE 等变量，
# 失败路径不保证恢复；MCP 集成测试依赖 powershell.exe 的 PATH 解析，必须在干净环境里跑。
# MCP 测试也不能只靠发布工作流里的单独一步：release-gate 是本地与 CI 共同的完整回归入口。
# 运行时依赖 Node；找不到 Node 视为门禁失败，不能静默跳过 MCP 覆盖。
function Resolve-NodePath {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:TOOLKIT_MAP_NODE) {
        # 显式选择无效时不能换用 PATH 上的另一份运行时。
        if ([IO.Path]::IsPathRooted($env:TOOLKIT_MAP_NODE) -and [IO.File]::Exists($env:TOOLKIT_MAP_NODE) -and (Test-ToolkitProbeSafe $env:TOOLKIT_MAP_NODE)) { return $env:TOOLKIT_MAP_NODE }
        return ''
    }
    foreach ($command in @(Get-Command node -CommandType Application -ErrorAction SilentlyContinue)) {
        if ($command.Source) { $candidates.Add($command.Source) }
        elseif ($command.Path) { $candidates.Add($command.Path) }
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and [IO.File]::Exists($candidate) -and (Test-ToolkitProbeSafe $candidate)) { return $candidate }
    }
    return ''
}

$mcpTests = @(
    'mcp/test/protocol.test.mjs',
    'mcp/test/runner.test.mjs',
    'mcp/test/server.test.mjs',
    'mcp/test/maintenance.test.mjs',
    'mcp/test/integration.test.mjs',
    'mcp/test/contract.test.mjs',
    'mcp/test/maintenance-integration.test.mjs'
)

Write-Host ''
Write-Host ' === MCP 测试（node --test） ===' -ForegroundColor Cyan
$nodePath = Resolve-NodePath
if (-not $nodePath) {
    Write-Host '  [门禁失败] 未找到 Node.js；MCP 测试无法运行' -ForegroundColor Red
    Write-Host '::error::未找到 Node.js，MCP 测试未运行'
    $failed.Add('mcp-tests')
} else {
    Write-Host "  node：$nodePath" -ForegroundColor DarkGray
    $global:LASTEXITCODE = 0
    try {
        Push-Location $repoRoot
        try {
            & $nodePath --test @mcpTests
        } finally {
            Pop-Location
        }
    } catch {
        Write-Host "  [门禁异常] MCP 测试：$($_.Exception.Message)" -ForegroundColor Red
        Write-Host "::error::MCP 测试抛出异常：$($_.Exception.Message)"
        $failed.Add('mcp-tests')
    }
    if ($LASTEXITCODE -ne 0 -and -not $failed.Contains('mcp-tests')) {
        Write-Host "  [门禁失败] MCP 测试退出码 $LASTEXITCODE" -ForegroundColor Red
        Write-Host "::error::MCP 测试退出码 $LASTEXITCODE"
        $failed.Add('mcp-tests')
    }
}

foreach ($name in $checks) {
    Write-Host ''
    Write-Host " === $name ===" -ForegroundColor Cyan
    $global:LASTEXITCODE = 0
    try {
        & (Join-Path $PSScriptRoot $name)
    } catch {
        Write-Host "  [门禁异常] $name：$($_.Exception.Message)" -ForegroundColor Red
        Write-Host "::error::$name 抛出异常：$($_.Exception.Message)"
        $failed.Add($name)
        continue
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [门禁失败] $name 退出码 $LASTEXITCODE" -ForegroundColor Red
        Write-Host "::error::$name 退出码 $LASTEXITCODE"
        $failed.Add($name)
    }
}

Write-Host ''
if ($failed.Count -eq 0) {
    Write-Host ' 发布门禁通过' -ForegroundColor Green
    Write-Host ''
    exit 0
} else {
    Write-Host " 发布门禁失败：$($failed -join ', ')" -ForegroundColor Red
    Write-Host ''
    exit 1
}
