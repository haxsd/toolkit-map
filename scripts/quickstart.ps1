# 退出码：0 完成；1 项目接入失败；2 项目接入完成但 MCP 配置未完成（部分成功）。
[CmdletBinding()]
param(
    [string]$Project = (Get-Location).Path,
    [string]$RulesFile = '',
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
# Reuse the map's version and shim checks when a verified launcher resolves to
# a different, independently verified Node executable.
. (Join-Path $PSScriptRoot 'toolkit-common.ps1')

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
$script:McpFailure = ''

function Set-McpFailure {
    param([string]$Message)
    $script:McpFailure = $Message
    Write-Host "  MCP 未完成：$Message" -ForegroundColor Yellow
}

# setup 返回的地图是本次接入的权威目标；缺失或不合法时不能猜，直接算 MCP 部分失败。
function Get-SetupMapFile {
    param([object]$Setup)
    if ($null -eq $Setup) { throw 'setup 没有返回地图信息。' }
    $value = "$($Setup.mapFile)"
    if (-not $value) { throw 'setup 没有返回地图路径。' }
    if (-not [IO.Path]::IsPathRooted($value)) { throw "setup 返回的地图路径不是绝对路径：$value" }
    $full = [IO.Path]::GetFullPath($value)
    if (-not [IO.File]::Exists($full)) { throw "setup 返回的地图文件不存在：$full" }
    return $full
}

function ConvertTo-TomlString {
    param([string]$Value)
    return '"' + ($Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n')) + '"'
}

function Invoke-Map {
    param([string[]]$Arguments)
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # 地图的告警走 stderr；JSON 结果只在 stdout，分开收集避免污染解析。
        $output = & $powerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $mapPath @Arguments -Json 2>$null
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousEap
    }
    $text = $output | Out-String
    try {
        $parsed = $text | ConvertFrom-Json
    } catch {
        throw "地图动作返回的不是合法 JSON：$($Arguments -join ' ')"
    }
    if ($null -eq $parsed -or $parsed -is [array] -or -not ($parsed -is [pscustomobject])) {
        throw "地图动作的 JSON 根节点不是对象：$($Arguments -join ' ')"
    }
    if ($exitCode -ne 0 -or -not $parsed.ok) {
        $detail = if ($parsed.message) { $parsed.message } else { $parsed.status }
        throw "地图动作失败：$($Arguments -join ' ')（$detail）"
    }
    if ($parsed.summaryWarning) { Write-Host "  提醒：$($parsed.summaryWarning)" -ForegroundColor Yellow }
    return $parsed
}

function Invoke-NodeCommand {
    param([string]$NodePath, [string[]]$Arguments, [string]$Label, [string]$MapFile = '')
    $stderrFile = [IO.Path]::GetTempFileName()
    $previousEap = $ErrorActionPreference
    $previousMap = $env:TOOLKIT_MAP
    $previousMapFile = $env:TOOLKIT_MAP_FILE
    $ErrorActionPreference = 'Continue'
    try {
        if ($MapFile) {
            # 只把 setup 实际用的地图交给子进程，覆盖继承来的 TOOLKIT_MAP_FILE / TOOLKIT_MAP。
            # 本进程环境在 finally 里恢复原值，不把固定值泄漏给后续调用或调用方。
            $env:TOOLKIT_MAP = $MapFile
            $env:TOOLKIT_MAP_FILE = $MapFile
        }
        $output = & $NodePath @Arguments 2> $stderrFile | Out-String
        $exitCode = $LASTEXITCODE
        $stderr = ''
        if ([IO.File]::Exists($stderrFile)) {
            $stderr = ([IO.File]::ReadAllText($stderrFile, [Text.Encoding]::UTF8)).Trim()
        }
        return [pscustomobject]@{
            ExitCode = $exitCode
            Output   = $output.Trim()
            Stderr   = $stderr
            Label    = $Label
        }
    } finally {
        $ErrorActionPreference = $previousEap
        if ($null -eq $previousMap) { Remove-Item Env:\TOOLKIT_MAP -ErrorAction SilentlyContinue }
        else { $env:TOOLKIT_MAP = $previousMap }
        if ($null -eq $previousMapFile) { Remove-Item Env:\TOOLKIT_MAP_FILE -ErrorAction SilentlyContinue }
        else { $env:TOOLKIT_MAP_FILE = $previousMapFile }
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
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
    if ($config.PSObject.Properties['mcpServers']) {
        $servers = $config.mcpServers
        if ($null -eq $servers -or -not ($servers -is [pscustomobject])) {
            throw "已有 MCP 配置的 mcpServers 不是对象，未写入：$Path"
        }
        if ($servers.PSObject.Properties['toolkit-map']) {
            $entry = $servers.'toolkit-map'
            if ($null -eq $entry -or -not ($entry -is [pscustomobject])) {
                throw "已有 toolkit-map 条目不是对象，未写入：$Path"
            }
        }
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
    if (-not $config.PSObject.Properties['mcpServers']) {
        $config | Add-Member -MemberType NoteProperty -Name mcpServers -Value ([pscustomobject]@{}) -Force
    } elseif ($null -eq $config.mcpServers -or -not ($config.mcpServers -is [pscustomobject])) {
        throw "已有 MCP 配置的 mcpServers 不是对象，未写入：$Path"
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

function Get-ValidatedMcpEntry {
    param([object]$Config, [string]$NodePath, [string]$MapFile = '', [object[]]$NodeCandidates = @())
    if ($null -eq $Config -or $Config -is [array] -or -not ($Config -is [pscustomobject])) {
        throw 'MCP 配置的根节点不是对象。'
    }
    $servers = $Config.mcpServers
    if ($null -eq $servers -or -not ($servers -is [pscustomobject])) {
        throw 'MCP 配置缺少 mcpServers 对象。'
    }
    $entry = $servers.'toolkit-map'
    if ($null -eq $entry -or -not ($entry -is [pscustomobject])) {
        throw 'MCP 配置缺少 toolkit-map 条目。'
    }

    $command = "$($entry.command)"
    if (-not $command) { throw 'MCP 配置缺少 command。' }
    $commandFull = [IO.Path]::GetFullPath($command)
    if (-not [IO.File]::Exists($commandFull)) { throw "MCP 配置里的 command 不存在：$commandFull" }
    $nodeFull = [IO.Path]::GetFullPath($NodePath)
    if (-not [string]::Equals($commandFull, $nodeFull, [StringComparison]::OrdinalIgnoreCase)) {
        # Node's process.execPath may resolve a launcher to the real executable.
        # Accept that executable only when find independently reports this exact
        # path as verified and suitable; never trust the launcher's output alone.
        $matching = @($NodeCandidates | Where-Object {
            $_.path -and (Get-ToolkitNormalizedPath $_.path) -eq (Get-ToolkitNormalizedPath $commandFull) -and
            $_.verification -eq 'verified' -and -not $_.isShim -and
            $_.source -notin @('ide-host', 'conda-env') -and
            -not (Test-ToolkitShimPath $_.path) -and
            (Test-ToolkitVersionSatisfies "$($_.version)" '>=18')
        })
        if (-not $matching.Count -or [IO.Path]::GetExtension($commandFull) -ine '.exe') {
            throw "MCP 配置里的 command 不是已验证的 Node 18+：$commandFull；请确认并登记实际 Node 可执行文件。"
        }
    }

    $argumentList = @($entry.args)
    if ($argumentList.Count -lt 1) { throw 'MCP 配置缺少 args。' }
    $serverFull = [IO.Path]::GetFullPath([string]$argumentList[0])
    if (-not [IO.File]::Exists($serverFull)) { throw "MCP 配置里的 args[0] 不存在：$serverFull" }
    $expectedServer = [IO.Path]::GetFullPath($serverPath)
    if (-not [string]::Equals($serverFull, $expectedServer, [StringComparison]::OrdinalIgnoreCase)) {
        throw "MCP 配置里的 args[0] 不是当前 MCP 服务器：$serverFull"
    }

    if ($null -eq $entry.env -or -not ($entry.env -is [pscustomobject])) {
        throw 'MCP 配置缺少 env.TOOLKIT_MAP_PROJECT。'
    }
    $configuredProject = "$($entry.env.TOOLKIT_MAP_PROJECT)"
    if (-not $configuredProject) { throw 'MCP 配置缺少 env.TOOLKIT_MAP_PROJECT。' }
    $configuredProjectKey = ([IO.Path]::GetFullPath($configuredProject)).TrimEnd('\', '/')
    $projectKey = ([IO.Path]::GetFullPath($Project)).TrimEnd('\', '/')
    if (-not [string]::Equals($configuredProjectKey, $projectKey, [StringComparison]::OrdinalIgnoreCase)) {
        throw "MCP 配置里的 TOOLKIT_MAP_PROJECT 不是当前项目：$configuredProject"
    }

    if ($MapFile) {
        # 配置里显式带地图路径：客户端启动服务器时不必依赖继承的环境变量。
        # 生成端已经给了不同的值就当作冲突，不静默改写。
        $configuredMap = ''
        if ($entry.env.PSObject.Properties['TOOLKIT_MAP_FILE']) {
            $configuredMap = "$($entry.env.TOOLKIT_MAP_FILE)"
        }
        if ($configuredMap) {
            $configuredMapFull = $null
            try { $configuredMapFull = [IO.Path]::GetFullPath($configuredMap) } catch {
                throw "MCP 配置里的 TOOLKIT_MAP_FILE 不是合法路径：$configuredMap"
            }
            if (-not [string]::Equals($configuredMapFull, $MapFile, [StringComparison]::OrdinalIgnoreCase)) {
                throw "MCP 配置里的 TOOLKIT_MAP_FILE 不是 setup 使用的地图：$configuredMap"
            }
        } else {
            $entry.env | Add-Member -MemberType NoteProperty -Name 'TOOLKIT_MAP_FILE' -Value $MapFile -Force
        }
    }
    return $entry
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

$setup = $null
$setupArgs = @('setup', '-Project', $Project)
if ($RulesFile) { $setupArgs += @('-RulesFile', $RulesFile) }
Write-Host ''
Write-Host '  [1/2] 项目规则与地图' -ForegroundColor Cyan
if ($WhatIf) {
    $preview = Invoke-Map ($setupArgs + @('-WhatIf'))
    Write-Host "  将写入：$($preview.rulesFile)" -ForegroundColor Yellow
    Write-Host '  -WhatIf 不建图、不写文件、不生成 MCP 配置。' -ForegroundColor DarkGray
} else {
    Write-Host '  首次建图可能需要几十秒；不安装运行时、不改 PATH。' -ForegroundColor DarkGray
    $setup = Invoke-Map $setupArgs
    Write-Host "  规则文件：$($setup.rulesFile)" -ForegroundColor Green
    if ($setup.backup) { Write-Host "  已备份：$($setup.backup)" -ForegroundColor DarkGray }
    Write-Host "  地图：$($setup.mapFile)" -ForegroundColor Green
}

if ($Mcp) {
    Write-Host ''
    Write-Host '  [2/2] MCP 配置' -ForegroundColor Cyan
    $targets = @(Get-McpTargets)
    if ($WhatIf) {
        Write-Host '  将用地图查找 Node 18+，验证 --print-config 输出和 --check 启动检查后再写配置。' -ForegroundColor Yellow
        if ($WriteMcp) {
            foreach ($target in $targets) {
                Write-Host "  将写入 $($target.name)：$($target.path)" -ForegroundColor Yellow
            }
        } else {
            Write-Host '  未加 -WriteMcp：只打印配置，不写客户端文件。' -ForegroundColor DarkGray
        }
    } else {
        $mapFile = ''
        try {
            $mapFile = Get-SetupMapFile $setup
        } catch {
            Set-McpFailure $_.Exception.Message
        }

        $node = $null
        if ($mapFile) {
            try {
                # 严格只读：setup 已经建图；不在查询阶段现场探测新候选或改写地图。
                # -MapFile 显式钉住 setup 用的地图，不依赖继承的环境变量。
                $node = Invoke-Map @('find', 'node', '-Version', '>=18', '-Project', $Project, '-SkipScan', '-MapFile', $mapFile)
            } catch {
                Set-McpFailure "找不到可用的 Node 18+：$($_.Exception.Message)"
            }
        }

        if ($node) {
            Write-Host "  Node 18+：$($node.path)（$($node.version)）" -ForegroundColor Green
            Write-Host "  MCP 地图：$mapFile" -ForegroundColor Green
            try {
                $configRun = Invoke-NodeCommand -NodePath $node.path -MapFile $mapFile -Arguments @($serverPath, '--print-config', '--project', $Project) -Label '生成 MCP 配置'
                if ($configRun.ExitCode -ne 0) {
                    throw "生成 MCP 配置失败（退出码 $($configRun.ExitCode)）：$($configRun.Stderr)"
                }
                try {
                    $generated = $configRun.Output | ConvertFrom-Json
                } catch {
                    throw "生成 MCP 配置返回的不是合法 JSON：$($_.Exception.Message)"
                }
                $entry = Get-ValidatedMcpEntry -Config $generated -NodePath $node.path -MapFile $mapFile -NodeCandidates @($node.candidates)

                # Check the actual command that will be written, not merely a
                # launcher that happened to generate the configuration.
                $checkRun = Invoke-NodeCommand -NodePath $entry.command -MapFile $mapFile -Arguments @($serverPath, '--check') -Label '启动检查'
                if ($checkRun.ExitCode -ne 0) {
                    throw "MCP 启动检查失败（退出码 $($checkRun.ExitCode)）：$($checkRun.Stderr)"
                }
                try {
                    $check = $checkRun.Output | ConvertFrom-Json
                } catch {
                    throw "MCP 启动检查未返回合法 JSON：$($_.Exception.Message)"
                }
                if ($null -eq $check -or -not ($check -is [pscustomobject]) -or -not $check.ok) {
                    $checkStatus = if ($check -and $check.status) { $check.status } else { 'unknown' }
                    throw "MCP 启动检查未通过：$checkStatus"
                }
                Write-Host '  启动检查通过。' -ForegroundColor Green

                # 打印的就是最终写入的配置：显式带 TOOLKIT_MAP_FILE，和 --check 用同一张地图。
                $finalJson = ([pscustomobject]@{ mcpServers = [pscustomobject]@{ 'toolkit-map' = $entry } } | ConvertTo-Json -Depth 20)
                Write-Host ''
                Write-Host $finalJson
                Write-Host ''

                if ($WriteMcp) {
                    $configs = @()
                    foreach ($target in $targets) {
                        # 先读并校验所有目标，任何一个已有文件损坏都不写任何客户端配置。
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
                    Write-Host '  把上面的 JSON 合并进 Cursor / Claude Code 的 mcpServers。' -ForegroundColor DarkGray
                    Write-Host '  Codex 替换已有的 [mcp_servers.toolkit-map] 段，不要重复追加 TOML 表：' -ForegroundColor DarkGray
                    Write-Host '    [mcp_servers.toolkit-map]' -ForegroundColor DarkGray
                    Write-Host ('    command = {0}' -f (ConvertTo-TomlString $entry.command)) -ForegroundColor DarkGray
                    Write-Host ('    args = [{0}]' -f (ConvertTo-TomlString $serverPath)) -ForegroundColor DarkGray
                    Write-Host ('    env = {{ "TOOLKIT_MAP_PROJECT" = {0}, "TOOLKIT_MAP_FILE" = {1} }}' -f
                        (ConvertTo-TomlString $Project), (ConvertTo-TomlString $mapFile)) -ForegroundColor DarkGray
                    Write-Host '  加 -WriteMcp 可写入项目级配置（修改前备份）。' -ForegroundColor DarkGray
                }
            } catch {
                Set-McpFailure $_.Exception.Message
            }
        }
    }
} else {
    Write-Host ''
    Write-Host '  [2/2] MCP 未启用（加 -Mcp 生成配置）' -ForegroundColor DarkGray
}

if ($script:McpFailure) {
    Write-Host ''
    Write-Host '  部分完成：项目规则已接入；MCP 配置未完成。' -ForegroundColor Yellow
    if ($setup) {
        Write-Host "  规则文件：$($setup.rulesFile)" -ForegroundColor Yellow
        Write-Host "  地图：$($setup.mapFile)" -ForegroundColor Yellow
    }
    Write-Host "  原因：$script:McpFailure" -ForegroundColor DarkGray
    Write-Host '  修复后重新执行本命令；已经写入的 MCP 配置不会被自动回滚。' -ForegroundColor DarkGray
    Write-Host ''
    exit 2
}

Write-Host ''
if ($WhatIf) {
    Write-Host '  预览完成：未建图、未写文件、未生成 MCP 配置。去掉 -WhatIf 后执行。' -ForegroundColor White
} else {
    Write-Host '  下一步：新开 agent 会话，要求它先查地图再执行工具。' -ForegroundColor White
    Write-Host '  验收与故障排查：docs\mcp.md、docs\troubleshooting.md' -ForegroundColor DarkGray
}
Write-Host ''
exit 0
