#Requires -Version 5.1
# 用调用记录验证扫描内核不把 shim 交给执行器；不执行真实 shim。
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts\toolkit-common.ps1')
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts\census.ps1'), [ref]$tokens, [ref]$errors)
foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($definition.Name -in @('Get-Resolution', 'Get-FirstLine', 'Get-RuntimeVersion', 'Get-WarehouseToolVersion', 'Get-InstallSource')) { Invoke-Expression $definition.Extent.Text }
}
# Get-Resolution 的默认命令表来自 census-data.tsv（census.ps1 在顶层加载，这里单独抽函数运行，要自己加载）。
$script:CensusData = Read-ToolkitDataTable -Path (Join-Path $repo 'scripts\census-data.tsv') -Os 'win'
function Resolve-CommandInPath { param($Index, $Name, $Exts, $DirCount) if ($Name -eq 'node') { 'C:\fixture\custom-data\shims\node.exe' } }
function Get-FileLength { param($Path) return 512 }
function Test-FileQuick { param($Path) throw 'shim 被交给了文件/执行探测器' }
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
$oldVolta = $env:VOLTA_HOME
try {
    $env:VOLTA_HOME = 'C:\fixture\Volta'
    if (Test-ToolkitShimPath 'C:\fixture\Volta\tools\image\node\22.1.0\node.exe') { throw 'Volta 真实运行时不应被当作 shim' }
    if (-not (Test-ToolkitShimPath 'C:\fixture\Volta\bin\node.exe')) { throw 'Volta bin 中的 shim 必须识别' }
} finally { $env:VOLTA_HOME = $oldVolta }
# 统一执行器自己也必须先过护栏：shim 不启动、不计数、不进缓存。
$before = $script:ToolkitProbeStats.launches
$probe = Invoke-ToolkitProbe 'C:\fixture\custom-data\shims\node.exe' @('--version')
if ($probe.reason -ne 'skipped' -or $script:ToolkitProbeStats.launches -ne $before) { throw 'Invoke-ToolkitProbe 不应执行 shim' }
# 统一仓库工具的探测同样先拒绝 shim：路径检查必须在文件探测与执行器之前。
function Test-RealExecutable { param($Path) throw "shim 被交给了文件探测器：$Path" }
function Invoke-ToolkitProbe { param($Exe, $Arguments) throw "shim 被交给了执行器：$Exe" }
$warehouseShim = Get-WarehouseToolVersion -Tool 'rg' -ExePath 'C:\fixture\custom-data\shims\rg.exe'
if ($warehouseShim) { throw 'Get-WarehouseToolVersion 不应探测 shim' }
# 编辑器 / IDE 宿主自带的 helper 运行时不能被当成普通项目工具。
if (-not (Test-ToolkitHostRuntimePath 'C:\fixture\editor\resources\app\resources\helpers\node.exe')) { throw '未识别编辑器自带运行时' }
if (Test-ToolkitHostRuntimePath 'C:\fixture\tools\node.exe') { throw '普通工具目录被误识别为宿主运行时' }
if ((Get-InstallSource 'C:\fixture\editor\resources\app\resources\helpers\node.exe') -ne 'IDE 内置') { throw '扫描器未把编辑器 helper 归为 IDE 内置' }
Write-Host '[通过] 扫描内核各层 shim 护栏'
exit 0
