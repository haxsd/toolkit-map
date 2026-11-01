param([switch]$WorktreePreflight)

$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-Host '  跳过：发布包构建目前仅支持 Windows' -ForegroundColor Yellow
    exit 0
}

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'scripts\toolkit-common.ps1')
$build = Join-Path (Join-Path $repoRoot 'scripts') 'build-release.ps1'
$temp = Join-Path $env:TEMP ('toolkit-release-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$version = ([IO.File]::ReadAllText((Join-Path $repoRoot 'VERSION'), [Text.Encoding]::UTF8)).Trim()
$zipName = "toolkit-map-v$version-runtime.zip"

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

# 开发区尚未提交时，正式构建器有意只打包 HEAD。此模式仅检查当前文件放入
# 隔离目录后的运行时布局，不冒充正式 ZIP，也不改 HEAD、创建提交或发布。
if ($WorktreePreflight) {
    try {
        $stage = Join-Path $temp 'worktree'
        $project = Join-Path $temp 'project'
        $mapFile = Join-Path $temp 'map.json'
        New-Item -ItemType Directory -Force -Path $stage, $project | Out-Null
        foreach ($dir in @('scripts', 'mcp', 'schemas', 'templates', 'docs')) {
            Copy-Item -LiteralPath (Join-Path $repoRoot $dir) -Destination (Join-Path $stage $dir) -Recurse
        }
        foreach ($file in @('VERSION', 'README.md', 'README-EN.md', 'SKILL.md', 'AGENTS.md', 'LICENSE')) {
            Copy-Item -LiteralPath (Join-Path $repoRoot $file) -Destination (Join-Path $stage $file)
        }
        $hostExe = (Get-Process -Id $PID).Path
        $stagedMap = Join-Path $stage 'scripts\map.ps1'
        $helpOutput = & $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $stagedMap help -Json
        $helpCode = $LASTEXITCODE
        $help = $helpOutput | Out-String | ConvertFrom-Json
        Check '当前工作树的临时布局可运行 help' ($helpCode -eq 0 -and $help.ok -and $help.version -eq $version)
        $previewOutput = & $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $stagedMap setup -Project $project -MapFile $mapFile -WhatIf -Json
        $previewCode = $LASTEXITCODE
        $preview = $previewOutput | Out-String | ConvertFrom-Json
        Check '临时布局包含可用的接入模板，预览不写地图' ($previewCode -eq 0 -and $preview.status -eq 'planned' -and -not [IO.File]::Exists($mapFile) -and -not [IO.File]::Exists((Join-Path $project 'AGENTS.md')))
        $nodePath = $env:TOOLKIT_MAP_NODE
        if (-not $nodePath -or -not [IO.Path]::IsPathRooted($nodePath) -or -not [IO.File]::Exists($nodePath)) {
            Check '显式提供可用的 TOOLKIT_MAP_NODE' $false '请提供已验证的 Node 18+ 绝对路径'
        } else {
            $mcpVersion = (& $nodePath (Join-Path $stage 'mcp\server.mjs') --version 2>&1 | Out-String).Trim()
            Check '当前工作树的 MCP 模块可从临时布局加载' ($LASTEXITCODE -eq 0 -and $mcpVersion -eq $version)
        }
        # 显式路径不可用时，门禁不能静默改用 PATH 中的另一份 Node。
        $gateAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'tests\release-gate.ps1'), [ref]$null, [ref]$null)
        $resolver = $gateAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-NodePath' }, $true)
        Check '发布门禁包含 Node 路径解析器' ($null -ne $resolver)
        if ($resolver) {
            $fallbackFixture = Join-Path $temp 'fallback-node.exe'; [IO.File]::WriteAllText($fallbackFixture, 'fake node, not executed')
            $selected = & {
                . ([scriptblock]::Create($resolver.Extent.Text))
                function Get-Command { param($Name, $CommandType) [pscustomobject]@{ Source = $fallbackFixture; Path = $fallbackFixture } }
                $savedNode = $env:TOOLKIT_MAP_NODE
                try { $env:TOOLKIT_MAP_NODE = Join-Path $temp 'missing-node.exe'; Resolve-NodePath }
                finally { $env:TOOLKIT_MAP_NODE = $savedNode }
            }
            Check '显式 Node 路径无效时拒绝回退到 PATH' (-not $selected)
            $shimDir = Join-Path $temp 'shims'; [void][IO.Directory]::CreateDirectory($shimDir)
            $shim = Join-Path $shimDir 'node.cmd'; [IO.File]::WriteAllText($shim, '@echo off')
            $shimSelected = & {
                . ([scriptblock]::Create($resolver.Extent.Text))
                $savedNode = $env:TOOLKIT_MAP_NODE
                try { $env:TOOLKIT_MAP_NODE = $shim; Resolve-NodePath }
                finally { $env:TOOLKIT_MAP_NODE = $savedNode }
            }
            Check '发布门禁不选显式 shim' (-not $shimSelected)
        }
    } finally {
        if ([IO.Directory]::Exists($temp)) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if ($fail -gt 0) { exit 1 }
    Write-Host '  [通过] 当前工作树布局预检；正式发布包仍需从提交后的 HEAD 验证'
    exit 0
}

try {
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    Write-Host ''
    Write-Host ' 发布包构建检查' -ForegroundColor White
    & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $build -OutputDir $temp
    Check '构建命令成功' ($LASTEXITCODE -eq 0)

    # 包内容断言只能证明“这一次刚好有”；构建器自己的必装清单才是缺文件时的护栏。
    # 这里静态核对清单，避免删掉 MCP 模块或规则模板后 zip 仍然构建成功。
    $buildText = [IO.File]::ReadAllText($build, [Text.Encoding]::UTF8)
    foreach ($relative in @(
        'scripts\map-core.ps1',
        'scripts\toolkit-common.ps1',
        'scripts\census-data.tsv',
        'scripts\census-text.tsv',
        'scripts\quickstart.ps1',
        'mcp\server.mjs',
        'mcp\lib\protocol.mjs',
        'mcp\lib\runner.mjs',
        'mcp\lib\tools.mjs',
        'templates\agent-tool-rules.md',
        'templates\cursor-toolkit-map.mdc',
        'templates\mise-config.toml'
    )) {
        Check "构建器必装清单包含 $relative" ($buildText.Contains("'$relative'"))
    }

    $zipPath = Join-Path $temp $zipName
    $hashPath = "$zipPath.sha256"
    Check '生成运行时 ZIP' ([IO.File]::Exists($zipPath))
    Check '生成 SHA256 文件' ([IO.File]::Exists($hashPath))
    if ([IO.File]::Exists($zipPath) -and [IO.File]::Exists($hashPath)) {
        $expected = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $recorded = (([IO.File]::ReadAllText($hashPath, [Text.Encoding]::UTF8)).Trim() -split '\s+')[0]
        Check 'SHA256 与 ZIP 一致' ($expected -eq $recorded)

        $extract = Join-Path $temp 'extract'
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extract -Force
        Check '包含 map.ps1' ([IO.File]::Exists((Join-Path (Join-Path $extract 'scripts') 'map.ps1')))
        Check '包含 MCP 服务器' ([IO.File]::Exists((Join-Path (Join-Path $extract 'mcp') 'server.mjs')))
        Check '包含 MCP 协议模块' ([IO.File]::Exists((Join-Path (Join-Path (Join-Path $extract 'mcp') 'lib') 'protocol.mjs')))
        Check '包含 MCP 运行器模块' ([IO.File]::Exists((Join-Path (Join-Path (Join-Path $extract 'mcp') 'lib') 'runner.mjs')))
        Check '包含 MCP 工具定义模块' ([IO.File]::Exists((Join-Path (Join-Path (Join-Path $extract 'mcp') 'lib') 'tools.mjs')))
        Check '包含 JSON schema' ([IO.File]::Exists((Join-Path (Join-Path $extract 'schemas') 'result-v2.schema.json')))
        Check '包含契约文档' ([IO.File]::Exists((Join-Path (Join-Path $extract 'docs') 'contract.md')))
        $templates = Join-Path $extract 'templates'
        $rulesTemplate = Join-Path $templates 'agent-tool-rules.md'
        $cursorTemplate = Join-Path $templates 'cursor-toolkit-map.mdc'
        Check '包含接入规则模板' ([IO.File]::Exists($rulesTemplate))
        Check '包含 Cursor 规则模板' ([IO.File]::Exists($cursorTemplate))
        # setup 运行时会解析这个标记区；模板被截断时包能构建成功，却会在用户机器上失败。
        $markerPattern = '(?s)<!-- toolkit-map:begin -->.*?<!-- toolkit-map:end -->'
        if ([IO.File]::Exists($rulesTemplate)) {
            Check '接入规则模板标记完整' (([IO.File]::ReadAllText($rulesTemplate, [Text.Encoding]::UTF8)) -match $markerPattern)
        }
        if ([IO.File]::Exists($cursorTemplate)) {
            Check 'Cursor 规则模板标记完整' (([IO.File]::ReadAllText($cursorTemplate, [Text.Encoding]::UTF8)) -match $markerPattern)
        }
        Check 'VERSION 一致' ((([IO.File]::ReadAllText((Join-Path $extract 'VERSION'), [Text.Encoding]::UTF8)).Trim()) -eq $version)

        # 入口能加载才说明四个运行时模块彼此可解析；--version 只读取 VERSION，不接触地图。
        $nodePath = $env:TOOLKIT_MAP_NODE
        if ($nodePath) {
            if (-not [IO.Path]::IsPathRooted($nodePath) -or -not [IO.File]::Exists($nodePath) -or -not (Test-ToolkitProbeSafe $nodePath)) { $nodePath = '' }
        } else {
            $nodeCommand = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Where-Object { $_.Source -and (Test-ToolkitProbeSafe $_.Source) } | Select-Object -First 1
            if ($nodeCommand) { $nodePath = $nodeCommand.Source }
        }
        if ($nodePath) {
            $entry = Join-Path (Join-Path $extract 'mcp') 'server.mjs'
            $mcpVersion = (& $nodePath $entry --version 2>&1 | Out-String).Trim()
            Check 'MCP 运行时模块可加载' ($LASTEXITCODE -eq 0 -and $mcpVersion -eq $version)
        } else {
            Check 'MCP 运行时模块可加载' $false '请提供已验证的 TOOLKIT_MAP_NODE，不能执行 shim 或回退错误路径'
        }
        Check '不包含 CI 配置' (-not (Test-Path -LiteralPath (Join-Path $extract '.github')))
        Check '不包含顶层测试' (-not (Test-Path -LiteralPath (Join-Path $extract 'tests')))
        Check '不包含内部计划' (-not (Test-Path -LiteralPath (Join-Path (Join-Path $extract 'docs') 'plans')))
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
