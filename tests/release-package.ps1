$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-Host '  跳过：发布包构建目前仅支持 Windows' -ForegroundColor Yellow
    exit 0
}

$repoRoot = Split-Path $PSScriptRoot -Parent
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

try {
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    Write-Host ''
    Write-Host ' 发布包构建检查' -ForegroundColor White
    & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $build -OutputDir $temp
    Check '构建命令成功' ($LASTEXITCODE -eq 0)

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
        Check '包含 JSON schema' ([IO.File]::Exists((Join-Path (Join-Path $extract 'schemas') 'result-v2.schema.json')))
        Check '包含契约文档' ([IO.File]::Exists((Join-Path (Join-Path $extract 'docs') 'contract.md')))
        Check 'VERSION 一致' ((([IO.File]::ReadAllText((Join-Path $extract 'VERSION'), [Text.Encoding]::UTF8)).Trim()) -eq $version)
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
