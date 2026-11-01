$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-Host '  跳过：quickstart 配置写入目前只在 Windows 上验证' -ForegroundColor Yellow
    exit 0
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$mapScript = Join-Path (Join-Path $repoRoot 'scripts') 'map.ps1'
$quickstart = Join-Path (Join-Path $repoRoot 'scripts') 'quickstart.ps1'
$serverPath = Join-Path (Join-Path $repoRoot 'mcp') 'server.mjs'
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

# 测试只能操作 GUID 临时目录下的地图；任何真实用户地图都必须拒绝。
function Assert-IsolatedMap {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    $realMap = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.toolkit\map.json'))
    if (-not $full.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "测试地图不在 TEMP 下，拒绝继续：$full"
    }
    if ($full -eq $realMap) { throw "测试地图指向真实用户地图，拒绝继续：$full" }
}

function Invoke-MapAdd {
    param([string]$MapFile, [string]$Tool, [string]$Path, [switch]$Prefer)
    Assert-IsolatedMap $MapFile
    $nativeArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $mapScript,
        'add', $Tool, '-Path', $Path, '-MapFile', $MapFile, '-Json')
    if ($Prefer) { $nativeArgs += '-Prefer' }
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $powerShell @nativeArgs 2>$null | Out-String
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousEap
    }
    $parsed = $null
    try { $parsed = $output | ConvertFrom-Json } catch { }
    if ($exitCode -ne 0 -or -not $parsed -or -not $parsed.ok) {
        throw "临时地图登记失败：$Tool（退出码 $exitCode）"
    }
}

function Escape-JsonString {
    param([string]$Value)
    return $Value.Replace('\', '\\').Replace('"', '\"')
}

# 比较两个路径是否指向同一位置；空值一律不相等，避免把“没写”当成“写对了”。
function Test-SamePath {
    param([string]$Left, [string]$Right)
    if (-not $Left -or -not $Right) { return $false }
    try {
        return [string]::Equals([IO.Path]::GetFullPath($Left), [IO.Path]::GetFullPath($Right), [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

# 假 Node：只实现 quickstart 需要的 --version / --print-config / --check 三种调用。
# 用文件而不是 PATH 上的 node，避免测试碰到真实运行时。
function New-FakeRuntime {
    param(
        [string]$Path,
        [string]$Project,
        [string]$Server,
        [ValidateSet('ok', 'garbage', 'exit')][string]$PrintMode = 'ok',
        [ValidateSet('ok', 'fail')][string]$CheckMode = 'ok',
        [string]$CommandPath = '',
        # 写入一个固定值，验证 quickstart 不会照抄错误的 TOOLKIT_MAP_FILE。
        [string]$EnvMapFile = '',
        # 记录 --print-config 子进程实际继承的 TOOLKIT_MAP_FILE / TOOLKIT_MAP。
        [string]$PrintLog = '',
        # 记录 --check 子进程实际继承的 TOOLKIT_MAP_FILE / TOOLKIT_MAP。
        [string]$CheckLog = ''
    )
    $configuredCommand = if ($CommandPath) { $CommandPath } else { $Path }
    $envJson = '"TOOLKIT_MAP_PROJECT":"' + (Escape-JsonString $Project) + '"'
    if ($EnvMapFile) {
        $envJson += ',"TOOLKIT_MAP_FILE":"' + (Escape-JsonString $EnvMapFile) + '"'
    }
    $configJson = '{"mcpServers":{"toolkit-map":{"command":"' + (Escape-JsonString $configuredCommand) +
        '","args":["' + (Escape-JsonString $Server) +
        '"],"env":{' + $envJson + '}}}}'
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('@echo off')
    $lines.Add('setlocal')
    $lines.Add('if /I "%~1"=="--version" (')
    $lines.Add('  echo v22.99.2')
    $lines.Add('  exit /b 0')
    $lines.Add(')')
    $lines.Add('if /I "%~2"=="--print-config" (')
    if ($PrintLog) {
        $lines.Add('  > "' + $PrintLog + '" echo %TOOLKIT_MAP_FILE%')
        $lines.Add('  >> "' + $PrintLog + '" echo %TOOLKIT_MAP%')
    }
    if ($PrintMode -eq 'garbage') {
        $lines.Add('  echo not-json')
        $lines.Add('  exit /b 0')
    } elseif ($PrintMode -eq 'exit') {
        $lines.Add('  echo ' + $configJson)
        $lines.Add('  exit /b 3')
    } else {
        $lines.Add('  echo ' + $configJson)
        $lines.Add('  exit /b 0')
    }
    $lines.Add(')')
    $lines.Add('if /I "%~2"=="--check" (')
    if ($CheckLog) {
        $lines.Add('  > "' + $CheckLog + '" echo %TOOLKIT_MAP_FILE%')
        $lines.Add('  >> "' + $CheckLog + '" echo %TOOLKIT_MAP%')
    }
    if ($CheckMode -eq 'fail') {
        $lines.Add('  echo MCP check failed 1>&2')
        $lines.Add('  exit /b 1')
    } else {
        $lines.Add('  echo {"ok":true,"status":"ok"}')
        $lines.Add('  exit /b 0')
    }
    $lines.Add(')')
    $lines.Add('exit /b 0')
    [IO.File]::WriteAllText($Path, ($lines -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding($false)))
}

function New-TestProject {
    param([string]$Path)
    New-Item -ItemType Directory -Force -Path $Path, (Join-Path $Path '.cursor') | Out-Null
}

function Invoke-Quickstart {
    param([string]$Project, [string]$MapFile, [string]$RunnerMapFile = '', [string[]]$ExtraArgs = @())
    Assert-IsolatedMap $MapFile
    # 默认让两个变量一致；需要复现“继承的 TOOLKIT_MAP_FILE 与 setup 地图不同”时传 -RunnerMapFile。
    $runnerMap = if ($RunnerMapFile) { $RunnerMapFile } else { $MapFile }
    Assert-IsolatedMap $runnerMap
    $previousMap = $env:TOOLKIT_MAP
    $previousMapFile = $env:TOOLKIT_MAP_FILE
    $previousEap = $ErrorActionPreference
    $env:TOOLKIT_MAP = $MapFile
    # MCP 服务器读取 TOOLKIT_MAP_FILE；测试里指向临时地图，确保不会碰到真实地图。
    $env:TOOLKIT_MAP_FILE = $runnerMap
    $ErrorActionPreference = 'Continue'
    try {
        $nativeArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $quickstart,
            '-Project', $Project) + @($ExtraArgs)
        $output = & $powerShell @nativeArgs 2>$null 6>&1 | Out-String
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
    } finally {
        $ErrorActionPreference = $previousEap
        if ($null -eq $previousMap) { Remove-Item Env:\TOOLKIT_MAP -ErrorAction SilentlyContinue }
        else { $env:TOOLKIT_MAP = $previousMap }
        if ($null -eq $previousMapFile) { Remove-Item Env:\TOOLKIT_MAP_FILE -ErrorAction SilentlyContinue }
        else { $env:TOOLKIT_MAP_FILE = $previousMapFile }
    }
}

function Read-ConfigObject {
    param([string]$Path)
    return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
}

try {
    if (-not [IO.File]::Exists($quickstart)) { throw "找不到 quickstart：$quickstart" }
    if (-not [IO.File]::Exists($serverPath)) { throw "找不到 MCP 服务器：$serverPath" }
    New-Item -ItemType Directory -Force -Path $temp, (Join-Path $temp 'bin') | Out-Null

    # ---------- 1. 正常路径：写入两个客户端配置，保留其他服务器，修改前备份 ----------
    $goodProject = Join-Path $temp 'good-project'
    $goodMap = Join-Path $temp 'good-map.json'
    $goodNode = Join-Path (Join-Path $temp 'bin') 'runtime-good.cmd'
    New-TestProject $goodProject
    New-FakeRuntime -Path $goodNode -Project $goodProject -Server $serverPath
    Invoke-MapAdd -MapFile $goodMap -Tool node -Path $goodNode -Prefer

    $goodCursor = Join-Path $goodProject '.cursor\mcp.json'
    $goodClaude = Join-Path $goodProject '.mcp.json'
    [IO.File]::WriteAllText($goodCursor, '{"mcpServers":{"other":{"command":"keep-me"}}}', (New-Object Text.UTF8Encoding($false)))

    $good = Invoke-Quickstart -Project $goodProject -MapFile $goodMap -ExtraArgs @('-Mcp', '-WriteMcp', '-McpClient', 'both')
    Check '正常路径退出码为 0' ($good.ExitCode -eq 0) "实际退出码：$($good.ExitCode)"
    Check '正常路径写入项目规则' ([IO.File]::Exists((Join-Path $goodProject 'AGENTS.md')) -and
        ([IO.File]::ReadAllText((Join-Path $goodProject 'AGENTS.md')) -match 'toolkit-map:begin'))
    Check '正常路径写入 Cursor 配置' ([IO.File]::Exists($goodCursor))
    Check '正常路径写入 Claude Code 配置' ([IO.File]::Exists($goodClaude))

    if ([IO.File]::Exists($goodCursor)) {
        $cursor = Read-ConfigObject $goodCursor
        Check '正常路径保留已有服务器' ($cursor.mcpServers.other.command -eq 'keep-me')
        Check '正常路径写入 toolkit-map 条目' ([bool]$cursor.mcpServers.'toolkit-map')
        if ($cursor.mcpServers.'toolkit-map') {
            $entry = $cursor.mcpServers.'toolkit-map'
            Check 'command 指向已登记的 Node' (([IO.Path]::GetFullPath($entry.command)) -eq ([IO.Path]::GetFullPath($goodNode)))
            Check 'args 指向 MCP 服务器' ((@($entry.args).Count -eq 1) -and
                (([IO.Path]::GetFullPath(@($entry.args)[0])) -eq ([IO.Path]::GetFullPath($serverPath))))
            Check 'env 指向当前项目' (([IO.Path]::GetFullPath($entry.env.TOOLKIT_MAP_PROJECT)) -eq ([IO.Path]::GetFullPath($goodProject)))
        }
    }
    Check '正常路径修改前备份' (@(Get-ChildItem (Join-Path $goodProject '.cursor') -Filter '*.bak').Count -ge 1)

    # 合法项目路径带尾部分隔符时，Node 的 path.resolve 会去掉分隔符。
    $slashProject = Join-Path $temp 'trailing-project'
    $slashMap = Join-Path $temp 'trailing-map.json'
    $slashNode = Join-Path (Join-Path $temp 'bin') 'runtime-trailing.cmd'
    New-TestProject $slashProject
    New-FakeRuntime -Path $slashNode -Project $slashProject -Server $serverPath
    Invoke-MapAdd -MapFile $slashMap -Tool node -Path $slashNode -Prefer
    foreach ($separator in @('\', '/')) {
        $slashResult = Invoke-Quickstart -Project ($slashProject + $separator) -MapFile $slashMap -ExtraArgs @('-Mcp', '-WriteMcp')
        Check "项目尾分隔符 $separator 不阻断 MCP 接入" ($slashResult.ExitCode -eq 0 -and [IO.File]::Exists((Join-Path $slashProject '.cursor\mcp.json'))) "退出码：$($slashResult.ExitCode)；$($slashResult.Output)"
    }

    # Claude Code 的项目指令可以明确写入 CLAUDE.md，而不自动覆盖 AGENTS.md。
    $claudeProject = Join-Path $temp 'claude-rules-project'
    $claudeMap = Join-Path $temp 'claude-rules-map.json'
    $claudeNode = Join-Path (Join-Path $temp 'bin') 'runtime-claude-rules.cmd'
    $claudeRules = Join-Path $claudeProject 'CLAUDE.md'
    New-TestProject $claudeProject
    New-FakeRuntime -Path $claudeNode -Project $claudeProject -Server $serverPath
    Invoke-MapAdd -MapFile $claudeMap -Tool node -Path $claudeNode -Prefer
    $claudePreview = Invoke-Quickstart -Project $claudeProject -MapFile $claudeMap -ExtraArgs @('-Mcp', '-WriteMcp', '-McpClient', 'claude', '-RulesFile', $claudeRules, '-WhatIf')
    Check '自定义规则路径预览不写文件' ($claudePreview.ExitCode -eq 0 -and $claudePreview.Output.Contains('CLAUDE.md') -and -not [IO.File]::Exists($claudeRules))
    $claudeResult = Invoke-Quickstart -Project $claudeProject -MapFile $claudeMap -ExtraArgs @('-Mcp', '-WriteMcp', '-McpClient', 'claude', '-RulesFile', $claudeRules)
    Check 'Claude 指令写入指定文件' ($claudeResult.ExitCode -eq 0 -and [IO.File]::Exists($claudeRules) -and ([IO.File]::ReadAllText($claudeRules) -match 'toolkit-map:begin'))
    Check '自定义规则路径不额外写 AGENTS.md' (-not [IO.File]::Exists((Join-Path $claudeProject 'AGENTS.md')))
    Check 'Claude 项目配置按选择写入' ([IO.File]::Exists((Join-Path $claudeProject '.mcp.json')))

    # ---------- 2. 缺 Node 18+：规则接入保留，MCP 明确部分完成，退出码非 0 ----------
    $missingProject = Join-Path $temp 'missing-project'
    $missingMap = Join-Path $temp 'missing-map.json'
    $fakeGit = Join-Path (Join-Path $temp 'bin') 'runtime-git.cmd'
    New-TestProject $missingProject
    New-FakeRuntime -Path $fakeGit -Project $missingProject -Server $serverPath
    Invoke-MapAdd -MapFile $missingMap -Tool git -Path $fakeGit -Prefer

    $missing = Invoke-Quickstart -Project $missingProject -MapFile $missingMap -ExtraArgs @('-Mcp', '-WriteMcp')
    Check '缺 Node 时退出码为 2' ($missing.ExitCode -eq 2) "实际退出码：$($missing.ExitCode)"
    Check '缺 Node 时规则已接入' ([IO.File]::Exists((Join-Path $missingProject 'AGENTS.md')) -and
        ([IO.File]::ReadAllText((Join-Path $missingProject 'AGENTS.md')) -match 'toolkit-map:begin'))
    Check '缺 Node 时不写 Cursor 配置' (-not [IO.File]::Exists((Join-Path $missingProject '.cursor\mcp.json')))
    Check '缺 Node 时不写 Claude Code 配置' (-not [IO.File]::Exists((Join-Path $missingProject '.mcp.json')))
    Check '缺 Node 时报告部分完成' ($missing.Output -match '部分完成')

    # ---------- 3. --print-config 输出不是 JSON：不写配置，已有文件保持原样 ----------
    $badJsonProject = Join-Path $temp 'badjson-project'
    $badJsonMap = Join-Path $temp 'badjson-map.json'
    $badJsonNode = Join-Path (Join-Path $temp 'bin') 'runtime-badjson.cmd'
    New-TestProject $badJsonProject
    New-FakeRuntime -Path $badJsonNode -Project $badJsonProject -Server $serverPath -PrintMode garbage
    Invoke-MapAdd -MapFile $badJsonMap -Tool node -Path $badJsonNode -Prefer

    $badJsonCursor = Join-Path $badJsonProject '.cursor\mcp.json'
    $badJsonOriginal = '{"mcpServers":{"other":{"command":"keep-me"}}}'
    [IO.File]::WriteAllText($badJsonCursor, $badJsonOriginal, (New-Object Text.UTF8Encoding($false)))

    $badJson = Invoke-Quickstart -Project $badJsonProject -MapFile $badJsonMap -ExtraArgs @('-Mcp', '-WriteMcp')
    Check '无效 JSON 退出码为 2' ($badJson.ExitCode -eq 2) "实际退出码：$($badJson.ExitCode)"
    Check '无效 JSON 不覆盖已有配置' ([IO.File]::Exists($badJsonCursor) -and
        ([IO.File]::ReadAllText($badJsonCursor, [Text.Encoding]::UTF8) -eq $badJsonOriginal))
    Check '无效 JSON 时规则已接入' ([IO.File]::Exists((Join-Path $badJsonProject 'AGENTS.md')) -and
        ([IO.File]::ReadAllText((Join-Path $badJsonProject 'AGENTS.md')) -match 'toolkit-map:begin'))
    Check '无效 JSON 时报告部分完成' ($badJson.Output -match '部分完成')

    # ---------- 4. --print-config 退出码非 0：即使输出了 JSON 也不写 ----------
    $printFailProject = Join-Path $temp 'printfail-project'
    $printFailMap = Join-Path $temp 'printfail-map.json'
    $printFailNode = Join-Path (Join-Path $temp 'bin') 'runtime-printfail.cmd'
    New-TestProject $printFailProject
    New-FakeRuntime -Path $printFailNode -Project $printFailProject -Server $serverPath -PrintMode exit
    Invoke-MapAdd -MapFile $printFailMap -Tool node -Path $printFailNode -Prefer

    $printFail = Invoke-Quickstart -Project $printFailProject -MapFile $printFailMap -ExtraArgs @('-Mcp', '-WriteMcp')
    Check '配置生成失败退出码为 2' ($printFail.ExitCode -eq 2) "实际退出码：$($printFail.ExitCode)"
    Check '配置生成失败不写配置' (-not [IO.File]::Exists((Join-Path $printFailProject '.cursor\mcp.json')))
    Check '配置生成失败时规则已接入' ([IO.File]::Exists((Join-Path $printFailProject 'AGENTS.md')) -and
        ([IO.File]::ReadAllText((Join-Path $printFailProject 'AGENTS.md')) -match 'toolkit-map:begin'))

    # ---------- 5. 启动检查失败：不写配置 ----------
    $checkFailProject = Join-Path $temp 'checkfail-project'
    $checkFailMap = Join-Path $temp 'checkfail-map.json'
    $checkFailNode = Join-Path (Join-Path $temp 'bin') 'runtime-checkfail.cmd'
    New-TestProject $checkFailProject
    New-FakeRuntime -Path $checkFailNode -Project $checkFailProject -Server $serverPath -CheckMode fail
    Invoke-MapAdd -MapFile $checkFailMap -Tool node -Path $checkFailNode -Prefer

    $checkFail = Invoke-Quickstart -Project $checkFailProject -MapFile $checkFailMap -ExtraArgs @('-Mcp', '-WriteMcp')
    Check '启动检查失败退出码为 2' ($checkFail.ExitCode -eq 2) "实际退出码：$($checkFail.ExitCode)"
    Check '启动检查失败不写配置' (-not [IO.File]::Exists((Join-Path $checkFailProject '.cursor\mcp.json')))
    Check '启动检查失败时规则已接入' ([IO.File]::Exists((Join-Path $checkFailProject 'AGENTS.md')) -and
        ([IO.File]::ReadAllText((Join-Path $checkFailProject 'AGENTS.md')) -match 'toolkit-map:begin'))

    # ---------- 6. 已有配置不是合法 JSON：拒绝写入且保持原样 ----------
    $invalidProject = Join-Path $temp 'invalid-project'
    $invalidMap = Join-Path $temp 'invalid-map.json'
    $invalidNode = Join-Path (Join-Path $temp 'bin') 'runtime-invalid.cmd'
    New-TestProject $invalidProject
    New-FakeRuntime -Path $invalidNode -Project $invalidProject -Server $serverPath
    Invoke-MapAdd -MapFile $invalidMap -Tool node -Path $invalidNode -Prefer

    $invalidCursor = Join-Path $invalidProject '.cursor\mcp.json'
    $invalidOriginal = '{not-json'
    [IO.File]::WriteAllText($invalidCursor, $invalidOriginal, (New-Object Text.UTF8Encoding($false)))

    $invalid = Invoke-Quickstart -Project $invalidProject -MapFile $invalidMap -ExtraArgs @('-Mcp', '-WriteMcp')
    Check '已有配置损坏时退出码为 2' ($invalid.ExitCode -eq 2) "实际退出码：$($invalid.ExitCode)"
    Check '已有配置损坏时保持原样' ([IO.File]::ReadAllText($invalidCursor, [Text.Encoding]::UTF8) -eq $invalidOriginal)
    Check '已有配置损坏时规则已接入' ([IO.File]::Exists((Join-Path $invalidProject 'AGENTS.md')))

    # ---------- 7. --print-config 指向别的 command：拒绝写入 ----------
    $mismatchProject = Join-Path $temp 'mismatch-project'
    $mismatchMap = Join-Path $temp 'mismatch-map.json'
    $mismatchNode = Join-Path (Join-Path $temp 'bin') 'runtime-mismatch.cmd'
    New-TestProject $mismatchProject
    New-FakeRuntime -Path $mismatchNode -Project $mismatchProject -Server $serverPath -CommandPath $fakeGit
    Invoke-MapAdd -MapFile $mismatchMap -Tool node -Path $mismatchNode -Prefer

    $mismatch = Invoke-Quickstart -Project $mismatchProject -MapFile $mismatchMap -ExtraArgs @('-Mcp', '-WriteMcp')
    Check 'command 不匹配退出码为 2' ($mismatch.ExitCode -eq 2) "实际退出码：$($mismatch.ExitCode)"
    Check 'command 不匹配不写配置' (-not [IO.File]::Exists((Join-Path $mismatchProject '.cursor\mcp.json')))
    Check 'command 不匹配时规则已接入' ([IO.File]::Exists((Join-Path $mismatchProject 'AGENTS.md')))

    # ---------- 8. mcpServers 不是对象：拒绝写入，避免丢掉已有内容 ----------
    $shapeProject = Join-Path $temp 'shape-project'
    New-TestProject $shapeProject
    $shapeCursor = Join-Path $shapeProject '.cursor\mcp.json'
    $shapeOriginal = '{"mcpServers":"keep-this-value","other":true}'
    [IO.File]::WriteAllText($shapeCursor, $shapeOriginal, (New-Object Text.UTF8Encoding($false)))

    $shape = Invoke-Quickstart -Project $shapeProject -MapFile $goodMap -ExtraArgs @('-Mcp', '-WriteMcp')
    Check 'mcpServers 形状错误时退出码为 2' ($shape.ExitCode -eq 2) "实际退出码：$($shape.ExitCode)"
    Check 'mcpServers 形状错误时保持原样' ([IO.File]::ReadAllText($shapeCursor, [Text.Encoding]::UTF8) -eq $shapeOriginal)
    Check 'mcpServers 形状错误时规则已接入' ([IO.File]::Exists((Join-Path $shapeProject 'AGENTS.md')))

    # ---------- 9. -WhatIf：预览不写任何配置 ----------
    $previewProject = Join-Path $temp 'preview-project'
    New-TestProject $previewProject
    $preview = Invoke-Quickstart -Project $previewProject -MapFile $goodMap -ExtraArgs @('-Mcp', '-WriteMcp', '-WhatIf')
    Check '-WhatIf 退出码为 0' ($preview.ExitCode -eq 0) "实际退出码：$($preview.ExitCode)"
    Check '-WhatIf 不写配置' (-not [IO.File]::Exists((Join-Path $previewProject '.cursor\mcp.json')) -and
        -not [IO.File]::Exists((Join-Path $previewProject '.mcp.json')))

    # ---------- 10. 继承的 TOOLKIT_MAP_FILE 是另一张地图：验证与写入都必须用 setup 地图 ----------
    $routeProject = Join-Path $temp 'route-project'
    $routeSetupMap = Join-Path $temp 'route-setup-map.json'
    $routeDecoyMap = Join-Path $temp 'route-decoy-map.json'
    $routeNode = Join-Path (Join-Path $temp 'bin') 'runtime-route.cmd'
    $routeCheckLog = Join-Path $temp 'route-check-env.txt'
    $routePrintLog = Join-Path $temp 'route-print-env.txt'
    New-TestProject $routeProject
    New-FakeRuntime -Path $routeNode -Project $routeProject -Server $serverPath -PrintLog $routePrintLog -CheckLog $routeCheckLog
    Invoke-MapAdd -MapFile $routeSetupMap -Tool node -Path $routeNode -Prefer
    # 诱饵地图结构合法但没有 node；如果验证或写入落到它上面，说明用了错误地图。
    Invoke-MapAdd -MapFile $routeDecoyMap -Tool git -Path $fakeGit -Prefer

    $route = Invoke-Quickstart -Project $routeProject -MapFile $routeSetupMap -RunnerMapFile $routeDecoyMap -ExtraArgs @('-Mcp', '-WriteMcp')
    Check '地图不一致时退出码为 0' ($route.ExitCode -eq 0) "实际退出码：$($route.ExitCode)"
    $routeCursor = Join-Path $routeProject '.cursor\mcp.json'
    Check '地图不一致时写入 Cursor 配置' ([IO.File]::Exists($routeCursor))
    $routeMapValue = ''
    if ([IO.File]::Exists($routeCursor)) {
        $routeConfig = Read-ConfigObject $routeCursor
        if ($routeConfig.mcpServers.'toolkit-map' -and $routeConfig.mcpServers.'toolkit-map'.env) {
            $routeMapValue = "$($routeConfig.mcpServers.'toolkit-map'.env.TOOLKIT_MAP_FILE)"
        }
    }
    Check '写入的 TOOLKIT_MAP_FILE 指向 setup 地图' (Test-SamePath $routeMapValue $routeSetupMap) "实际值：$routeMapValue"
    Check '写入的 TOOLKIT_MAP_FILE 不是继承的诱饵地图' (-not (Test-SamePath $routeMapValue $routeDecoyMap)) "实际值：$routeMapValue"

    $routeLog = if ([IO.File]::Exists($routeCheckLog)) {
        @([IO.File]::ReadAllLines($routeCheckLog) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } else { @() }
    Check '启动检查的 TOOLKIT_MAP_FILE 是 setup 地图' ($routeLog.Count -ge 1 -and (Test-SamePath $routeLog[0] $routeSetupMap)) "实际值：$($routeLog -join ' / ')"
    Check '启动检查的 TOOLKIT_MAP 也被固定为 setup 地图' ($routeLog.Count -ge 2 -and (Test-SamePath $routeLog[1] $routeSetupMap)) "实际值：$($routeLog -join ' / ')"
    $routePrintLogLines = if ([IO.File]::Exists($routePrintLog)) {
        @([IO.File]::ReadAllLines($routePrintLog) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } else { @() }
    Check '生成配置的 TOOLKIT_MAP_FILE 是 setup 地图' ($routePrintLogLines.Count -ge 1 -and (Test-SamePath $routePrintLogLines[0] $routeSetupMap)) "实际值：$($routePrintLogLines -join ' / ')"
    $routeEscaped = [IO.Path]::GetFullPath($routeSetupMap).Replace('\', '\\')
    Check '打印的配置包含 TOOLKIT_MAP_FILE 且指向 setup 地图' (($route.Output -match 'TOOLKIT_MAP_FILE') -and $route.Output.Contains($routeEscaped))

    # ---------- 11. 只打印不写：打印出来的配置同样固定 TOOLKIT_MAP_FILE ----------
    $printProject = Join-Path $temp 'printonly-project'
    $printMap = Join-Path $temp 'printonly-map.json'
    $printNode = Join-Path (Join-Path $temp 'bin') 'runtime-printonly.cmd'
    $printLog = Join-Path $temp 'printonly-env.txt'
    New-TestProject $printProject
    New-FakeRuntime -Path $printNode -Project $printProject -Server $serverPath -PrintLog $printLog
    Invoke-MapAdd -MapFile $printMap -Tool node -Path $printNode -Prefer

    $printOnly = Invoke-Quickstart -Project $printProject -MapFile $printMap -RunnerMapFile $routeDecoyMap -ExtraArgs @('-Mcp')
    Check '只打印配置时退出码为 0' ($printOnly.ExitCode -eq 0) "实际退出码：$($printOnly.ExitCode)"
    Check '只打印配置时不写客户端文件' (-not [IO.File]::Exists((Join-Path $printProject '.cursor\mcp.json')) -and
        -not [IO.File]::Exists((Join-Path $printProject '.mcp.json')))
    $printEscaped = [IO.Path]::GetFullPath($printMap).Replace('\', '\\')
    Check '打印的配置固定 setup 地图' (($printOnly.Output -match 'TOOLKIT_MAP_FILE') -and $printOnly.Output.Contains($printEscaped)) "输出未包含 setup 地图：$printEscaped"
    $printDecoyEscaped = [IO.Path]::GetFullPath($routeDecoyMap).Replace('\', '\\')
    Check '打印的配置不含诱饵地图' (-not $printOnly.Output.Contains($printDecoyEscaped))
    $printLogLines = if ([IO.File]::Exists($printLog)) {
        @([IO.File]::ReadAllLines($printLog) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } else { @() }
    Check '只打印时子进程拿到 setup 地图' ($printLogLines.Count -ge 1 -and (Test-SamePath $printLogLines[0] $printMap)) "实际值：$($printLogLines -join ' / ')"

    # ---------- 12. 生成的 TOOLKIT_MAP_FILE 是非法相对路径：部分失败，不猜也不写 ----------
    $taintProject = Join-Path $temp 'taint-project'
    $taintMap = Join-Path $temp 'taint-map.json'
    $taintNode = Join-Path (Join-Path $temp 'bin') 'runtime-taint.cmd'
    New-TestProject $taintProject
    New-FakeRuntime -Path $taintNode -Project $taintProject -Server $serverPath -EnvMapFile 'relative\map.json'
    Invoke-MapAdd -MapFile $taintMap -Tool node -Path $taintNode -Prefer

    $taint = Invoke-Quickstart -Project $taintProject -MapFile $taintMap -ExtraArgs @('-Mcp', '-WriteMcp')
    Check '生成的 TOOLKIT_MAP_FILE 非法时退出码为 2' ($taint.ExitCode -eq 2) "实际退出码：$($taint.ExitCode)"
    Check '生成的 TOOLKIT_MAP_FILE 非法时不写配置' (-not [IO.File]::Exists((Join-Path $taintProject '.cursor\mcp.json')))
    Check '生成的 TOOLKIT_MAP_FILE 非法时规则已接入' ([IO.File]::Exists((Join-Path $taintProject 'AGENTS.md')))
    Check '生成的 TOOLKIT_MAP_FILE 非法时报告部分完成' ($taint.Output -match '部分完成')

    # ---------- 12b. 生成端已带正确的 TOOLKIT_MAP_FILE：接受并原样写入 ----------
    $envMatchProject = Join-Path $temp 'envmatch-project'
    $envMatchMap = Join-Path $temp 'envmatch-map.json'
    $envMatchNode = Join-Path (Join-Path $temp 'bin') 'runtime-envmatch.cmd'
    New-TestProject $envMatchProject
    New-FakeRuntime -Path $envMatchNode -Project $envMatchProject -Server $serverPath -EnvMapFile $envMatchMap
    Invoke-MapAdd -MapFile $envMatchMap -Tool node -Path $envMatchNode -Prefer

    $envMatch = Invoke-Quickstart -Project $envMatchProject -MapFile $envMatchMap -RunnerMapFile $routeDecoyMap -ExtraArgs @('-Mcp', '-WriteMcp')
    Check '生成端已带地图时退出码为 0' ($envMatch.ExitCode -eq 0) "实际退出码：$($envMatch.ExitCode)"
    $envMatchCursor = Join-Path $envMatchProject '.cursor\mcp.json'
    $envMatchValue = ''
    if ([IO.File]::Exists($envMatchCursor)) {
        $envMatchConfig = Read-ConfigObject $envMatchCursor
        if ($envMatchConfig.mcpServers.'toolkit-map' -and $envMatchConfig.mcpServers.'toolkit-map'.env) {
            $envMatchValue = "$($envMatchConfig.mcpServers.'toolkit-map'.env.TOOLKIT_MAP_FILE)"
        }
    }
    Check '生成端已带地图时写入 setup 地图' (Test-SamePath $envMatchValue $envMatchMap) "实际值：$envMatchValue"

    # ---------- 13. 临时固定进程环境后必须恢复调用方原值 ----------
    $restoreProject = Join-Path $temp 'restore-project'
    $restoreMap = Join-Path $temp 'restore-map.json'
    $restoreDecoy = Join-Path $temp 'restore-decoy-map.json'
    $restoreNode = Join-Path (Join-Path $temp 'bin') 'runtime-restore.cmd'
    New-TestProject $restoreProject
    New-FakeRuntime -Path $restoreNode -Project $restoreProject -Server $serverPath
    Invoke-MapAdd -MapFile $restoreMap -Tool node -Path $restoreNode -Prefer
    Invoke-MapAdd -MapFile $restoreDecoy -Tool git -Path $fakeGit -Prefer

    $previousTestMap = $env:TOOLKIT_MAP
    $previousTestFile = $env:TOOLKIT_MAP_FILE
    $env:TOOLKIT_MAP = $restoreMap
    $env:TOOLKIT_MAP_FILE = $restoreDecoy
    try {
        # 在同一个进程里跑 quickstart（独立 runspace），才能观察到进程环境是否被还原。
        $runspace = [PowerShell]::Create()
        $null = $runspace.AddScript('param($script, $project) & $script -Project $project -Mcp -WriteMcp').AddArgument($quickstart).AddArgument($restoreProject)
        try { $null = $runspace.Invoke() } catch { }
        $runspace.Dispose()

        Check '进程环境恢复：TOOLKIT_MAP_FILE 保持调用方原值' (Test-SamePath $env:TOOLKIT_MAP_FILE $restoreDecoy) "实际值：$($env:TOOLKIT_MAP_FILE)"
        Check '进程环境恢复：TOOLKIT_MAP 保持调用方原值' (Test-SamePath $env:TOOLKIT_MAP $restoreMap) "实际值：$($env:TOOLKIT_MAP)"

        $restoreCursor = Join-Path $restoreProject '.cursor\mcp.json'
        Check '同进程运行后写入配置' ([IO.File]::Exists($restoreCursor))
        $restoreMapValue = ''
        if ([IO.File]::Exists($restoreCursor)) {
            $restoreConfig = Read-ConfigObject $restoreCursor
            if ($restoreConfig.mcpServers.'toolkit-map' -and $restoreConfig.mcpServers.'toolkit-map'.env) {
                $restoreMapValue = "$($restoreConfig.mcpServers.'toolkit-map'.env.TOOLKIT_MAP_FILE)"
            }
        }
        Check '同进程运行写入的 TOOLKIT_MAP_FILE 是 setup 地图' (Test-SamePath $restoreMapValue $restoreMap) "实际值：$restoreMapValue"
    } finally {
        if ($null -eq $previousTestMap) { Remove-Item Env:\TOOLKIT_MAP -ErrorAction SilentlyContinue }
        else { $env:TOOLKIT_MAP = $previousTestMap }
        if ($null -eq $previousTestFile) { Remove-Item Env:\TOOLKIT_MAP_FILE -ErrorAction SilentlyContinue }
        else { $env:TOOLKIT_MAP_FILE = $previousTestFile }
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
