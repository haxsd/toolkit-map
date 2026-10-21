$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent

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

$statusesPath = Join-Path (Join-Path $repoRoot 'schemas') 'statuses.json'
$resultSchemaPath = Join-Path (Join-Path $repoRoot 'schemas') 'result-v2.schema.json'
$mapSchemaPath = Join-Path (Join-Path $repoRoot 'schemas') 'map-v2.schema.json'
$contractPath = Join-Path (Join-Path $repoRoot 'docs') 'contract.md'

Write-Host ''
Write-Host ' 契约冻结检查（状态枚举、schema 与脚本字面量）' -ForegroundColor White

foreach ($path in @($statusesPath, $resultSchemaPath, $mapSchemaPath, $contractPath)) {
    Check "$([IO.Path]::GetFileName($path)) 存在" ([IO.File]::Exists($path))
}
if (-not [IO.File]::Exists($statusesPath) -or -not [IO.File]::Exists($resultSchemaPath) -or -not [IO.File]::Exists($mapSchemaPath)) {
    Write-Host "  有 $fail 项失败" -ForegroundColor Red
    exit 1
}

$statusDoc = [IO.File]::ReadAllText($statusesPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$resultSchema = [IO.File]::ReadAllText($resultSchemaPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$mapSchema = [IO.File]::ReadAllText($mapSchemaPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$contract = [IO.File]::ReadAllText($contractPath, [Text.Encoding]::UTF8)

$statusNames = @($statusDoc.statuses.PSObject.Properties.Name | Sort-Object)
$schemaEnum = @($resultSchema.'$defs'.status.enum | Sort-Object)
$diff = @(Compare-Object $statusNames $schemaEnum)
Check 'statuses.json 与 result schema 的状态枚举一致' ($diff.Count -eq 0) (($diff | ForEach-Object { "$($_.InputObject)" }) -join ', ')
Check "状态枚举非空（$($statusNames.Count) 项）" ($statusNames.Count -gt 0)

$literals = New-Object System.Collections.Generic.List[string]
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'scripts') -Filter '*.ps1' -File)) {
    $text = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
    foreach ($match in [regex]::Matches($text, '(?:New-MapResult|Throw-MapError)\s+[''"]([a-z_]+)[''"]')) {
        $literals.Add($match.Groups[1].Value)
    }
}
$literalNames = @($literals | Sort-Object -Unique)
$unknown = @($literalNames | Where-Object { $statusNames -notcontains $_ })
Check '脚本中的状态字面量都在 statuses.json 中' ($unknown.Count -eq 0) ($unknown -join ', ')

$notInDoc = @($statusNames | Where-Object { -not $contract.Contains(([string][char]96) + $_ + ([string][char]96)) })
Check '契约文档列出每个状态' ($notInDoc.Count -eq 0) ($notInDoc -join ', ')

Check 'result schema 声明 JSON Schema 2020-12' ($resultSchema.'$schema' -eq 'https://json-schema.org/draft/2020-12/schema')
Check 'result schema 的 schemaVersion 固定为 2' ($resultSchema.properties.schemaVersion.const -eq 2)
Check 'result schema 支持 doctor bundle' ($resultSchema.properties.bundle.type -eq 'object')
Check 'map schema 的 schemaVersion 固定为 2' ($mapSchema.properties.schemaVersion.const -eq 2)
Check 'statuses.json 的 schemaVersion 为 2' ($statusDoc.schemaVersion -eq 2)

$version = ([IO.File]::ReadAllText((Join-Path $repoRoot 'VERSION'), [Text.Encoding]::UTF8)).Trim()
$package = [IO.File]::ReadAllText((Join-Path (Join-Path $repoRoot 'mcp') 'package.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
Check "VERSION 已进入 1.x（当前：$version）" ($version -match '^1\.\d+\.\d+$')
Check 'mcp/package.json 与 VERSION 一致' ($package.version -eq $version) "package：$($package.version)"

$required = @($resultSchema.required)
foreach ($field in @('schemaVersion', 'action', 'ok', 'status')) {
    Check "result schema 要求 $field" ($required -contains $field)
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
