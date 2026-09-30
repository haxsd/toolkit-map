#Requires -Version 5.1
# 用调用记录验证扫描内核不把 shim 交给执行器；不执行真实 shim。
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts\toolkit-common.ps1')
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts\census.ps1'), [ref]$tokens, [ref]$errors)
foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($definition.Name -in @('Get-Resolution', 'Get-FirstLine', 'Get-RuntimeVersion')) { Invoke-Expression $definition.Extent.Text }
}
function Resolve-CommandInPath { param($Index, $Name, $Exts, $DirCount) if ($Name -eq 'node') { 'C:\fixture\custom-data\shims\node.exe' } }
function Get-FileLength { param($Path) return 512 }
function Test-FileQuick { param($Path) throw 'shim 被交给了文件/执行探测器' }
$script:VersionCache = @{}
$guarded = Get-FirstLine 'C:\fixture\custom-data\shims\node.exe' @('--version')
if ($guarded) { throw 'Get-FirstLine 不应探测 shim' }
$guarded = Get-RuntimeVersion 'node' 'C:\fixture\custom-data\shims\node.exe'
if ($guarded) { throw 'Get-RuntimeVersion 不应探测 shim' }
function Get-RuntimeVersion { param($Tool, $ExePath) throw "解析层把 shim 交给了版本执行器：$ExePath" }
$records = @(Get-Resolution @{} 1)
if ($records.Count -ne 1 -or -not $records[0].isShim -or $records[0].version) { throw '解析层必须保留 shim 路径，但不探测版本' }
$old = $env:MISE_SHIMS_DIR
try {
    $env:MISE_SHIMS_DIR = 'C:\fixture\custom-bin'
    if (-not (Test-ToolkitShimPath 'C:\fixture\custom-bin\node.exe')) { throw '未识别 MISE_SHIMS_DIR' }
    if (Test-ToolkitShimPath 'C:\fixture\custom-binary\node.exe') { throw '前缀相同的其他目录被误识别为 shim' }
} finally { $env:MISE_SHIMS_DIR = $old }
Write-Host '[通过] 扫描内核各层 shim 护栏'
exit 0
