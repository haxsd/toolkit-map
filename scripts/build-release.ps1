[CmdletBinding()]
param(
    [string]$OutputDir = ''
)

$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw '发布包构建目前仅支持 Windows（完整地图与运行时包契约在 Windows 上验证）。'
}
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $OutputDir) { $OutputDir = Join-Path $repoRoot 'dist' }
$version = ([IO.File]::ReadAllText((Join-Path $repoRoot 'VERSION'), [Text.Encoding]::UTF8)).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "VERSION 不是 X.Y.Z：$version" }

$outDir = [IO.Path]::GetFullPath($OutputDir)
$zipName = "toolkit-map-v$version-runtime.zip"
$zipPath = Join-Path $outDir $zipName
$hashPath = "$zipPath.sha256"
$stage = Join-Path $env:TEMP ('toolkit-release-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$sourceZip = Join-Path $stage 'source.zip'
$extract = Join-Path $stage 'tree'

try {
    New-Item -ItemType Directory -Force -Path $stage, $extract, $outDir | Out-Null

    # 从 HEAD 打包，而不是工作区：发布物必须对应一个可追溯的提交/标签。
    & git -C $repoRoot archive --format=zip --output $sourceZip HEAD
    if ($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($sourceZip)) { throw 'git archive 失败' }
    Expand-Archive -LiteralPath $sourceZip -DestinationPath $extract -Force

    foreach ($relative in @('.github', 'tests', '.gitignore', '.gitattributes', 'docs\plans')) {
        $target = Join-Path $extract $relative
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    }

    $stagedVersion = ([IO.File]::ReadAllText((Join-Path $extract 'VERSION'), [Text.Encoding]::UTF8)).Trim()
    if ($stagedVersion -ne $version) { throw "打包内容 VERSION（$stagedVersion）与当前 VERSION（$version）不一致" }

    $required = @(
        'README.md', 'README-EN.md', 'SKILL.md', 'AGENTS.md', 'LICENSE', 'VERSION',
        'scripts\map.ps1', 'scripts\map-core.ps1', 'scripts\toolkit-common.ps1',
        'scripts\census.ps1', 'scripts\census-data.tsv', 'scripts\census-text.tsv', 'scripts\tools.json', 'scripts\quickstart.ps1',
        # server.mjs 直接或间接导入这三个模块；缺一个 MCP 服务器就起不来。
        'mcp\server.mjs', 'mcp\lib\protocol.mjs', 'mcp\lib\runner.mjs', 'mcp\lib\tools.mjs',
        'schemas\result-v2.schema.json', 'schemas\map-v2.schema.json',
        'docs\contract.md', 'docs\mcp.md',
        # setup 从 agent-tool-rules.md 提取规则块；cursor 模板是给用户的同一份接入规则的 Cursor 版。
        'templates\agent-tool-rules.md', 'templates\cursor-toolkit-map.mdc', 'templates\mise-config.toml'
    )
    foreach ($relative in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $extract $relative))) { throw "运行时包缺少：$relative" }
    }

    # 从打包结果本身跑一次 help，确认脚本与 VERSION 等依赖没有漏装。
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $hostPath = (Get-Process -Id $PID).Path
        $helpOutput = & $hostPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $extract 'scripts\map.ps1') help -Json
        $help = $helpOutput | Out-String | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or -not $help.ok) { throw '打包后的 map.ps1 help 失败' }
    }

    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    if (Test-Path -LiteralPath $hashPath) { Remove-Item -LiteralPath $hashPath -Force }
    Compress-Archive -Path (Join-Path $extract '*') -DestinationPath $zipPath -CompressionLevel Optimal
    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $zipName" | Set-Content -LiteralPath $hashPath -Encoding Ascii

    Write-Host "  运行时包：$zipPath" -ForegroundColor Green
    Write-Host "  SHA256：$hash" -ForegroundColor Green
    Write-Host "  校验文件：$hashPath" -ForegroundColor DarkGray
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
