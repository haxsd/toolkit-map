#Requires -Version 5.1
# 版本比较与排序的表驱动契约：纯函数，不启动进程、不读写文件。
# 新增版本语法或修复比较边界时，先在下面的表里加一行。
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$scripts = Join-Path $repo 'scripts'
. (Join-Path $scripts 'toolkit-common.ps1')
. (Join-Path $scripts 'map-core.ps1')
$fail = 0
function Check {
    param([string]$What, [bool]$Ok)
    if (-not $Ok) { Write-Host "  [失败] $What"; Write-Host "::error::$What"; $script:fail++ }
}

# ---------- 1. 版本要求 ----------
# 实际版本 | 要求 | 期望
$cases = @(
    # 前缀与精确
    @('22.23.2', '22', $true), @('22.23.2', '22.23', $true), @('22.23.2', '22.23.2', $true), @('22.23.2', '22.23.3', $false),
    @('22.23.2', '22.x', $true), @('22.23.2', '22.*', $true), @('v22.23.2', '22', $true), @('22', '22', $true), @('22', '22.1', $false),
    # 比较符与部分版本
    @('22.23.2', '>=22 <23', $true), @('23.0.0', '>=22 <23', $false), @('22.23.2', '>22', $false), @('23.0.0', '>22', $true),
    @('22.23.2', '<=22', $true), @('22.23.2', '=22.23', $true), @('22.24.0', '=22.23', $false), @('22.23.2', '<=22.23.2', $true),
    @('16.20.2', '>=18', $false), @('21.0.0', '>20 <=21', $true),
    # ^ 与 ~
    @('22.23.2', '^22', $true), @('23.0.0', '^22', $false), @('0.2.9', '^0.2', $true), @('0.3.0', '^0.2', $false),
    @('0.0.3', '^0.0.3', $true), @('0.0.4', '^0.0.3', $false), @('22.23.9', '~22.23', $true), @('22.24.0', '~22.23', $false),
    @('9.9.9', '^9', $true), @('10.0.0', '^9', $false), @('99.0.0', '~99.9', $false), @('99.9.1', '~99.9', $true),
    # 多个候选
    @('20.1.0', '^18 || ^20 || ^22', $true), @('19.0.0', '^18 || ^20', $false), @('22.0.0', '20,22', $true),
    # 超长数字段：不能抛异常，按数值比较
    @('1.2.20240101123456', '1.2', $true), @('1.2.20240101123456', '1.2.20240101123456', $true),
    @('1.2.20240101123456', '>=1.2.3', $true), @('1.2.99999999999999999999', '<1.3', $true), @('100000000000.0.0', '^99999999999', $false),
    @('100000000000.0.0', '^100000000000', $true), @('1.0.0', '>=99999999999999999999', $false), @('007.1', '7', $true),
    # 预发布：只在完整精确匹配时满足，semver 与 Python 写法一致
    @('22.0.0-nightly', '22', $false), @('22.0.0-rc.1', '^22', $false), @('22.0.0-rc.1', '22.0.0-rc.1', $true),
    @('3.12.0rc1', '3.12', $false), @('3.12.0rc1', '>=3.11', $false), @('3.12.0rc1', '3.12.0rc1', $true), @('3.13.0a2', '3.13', $false),
    @('1.0.dev0', '1', $false), @('21.0.1-ea', '21', $false),
    # 不是预发布的后缀
    @('1.8.0_392', '1.8', $true), @('17.0.2+8', '17', $true), @('2.45.1.windows.1', '2.45', $true), @('2.45.1.windows.1', '>=2.40', $true),
    # 通配
    @('1.0.0', '*', $true), @('1.0.0', 'latest', $true), @('', '22', $false), @('abc', '22', $false)
)
foreach ($case in $cases) {
    $actual = try { Test-ToolkitVersionSatisfies $case[0] $case[1] } catch { "抛出异常：$($_.Exception.Message)" }
    Check "版本 '$($case[0])' 对要求 '$($case[1])' 应为 $($case[2])，实际 $actual" ($actual -is [bool] -and $actual -eq $case[2])
}

# ---------- 2. 排序键 ----------
# 期望的降序：高版本在前，同号正式版在预发布前，单段与超长数字段按数值，解析不了的排最后。
# 22 与 22.0.0 的键相同，用第二排序键（原始字符串升序）固定先后。
$expected = @('100000000000.0', '22.23.10', '22.23.2', '22', '22.0.0', '22.0.0-rc.1', '9', '3.12.0', '3.12.0rc1', '1.8.0_392', '1.2.20240101123456', '1.2.3', 'unknown')
$shuffled = @('9', '22.0.0-rc.1', 'unknown', '1.2.3', '22.23.2', '3.12.0rc1', '22', '1.2.20240101123456', '22.23.10', '1.8.0_392', '100000000000.0', '3.12.0', '22.0.0')
$sorted = @($shuffled | Sort-Object @{ Expression = { Get-ToolkitVersionSortKey $_ }; Descending = $true }, @{ Expression = { $_ } })
Check "排序键降序应为 $($expected -join ', ')，实际 $($sorted -join ', ')" (($sorted -join ',') -eq ($expected -join ','))
Check '单段版本 22 与 22.0.0 排序键相同' ((Get-ToolkitVersionSortKey '22') -eq (Get-ToolkitVersionSortKey '22.0.0'))

# ---------- 3. 默认候选选择 ----------
function New-TestCandidate { param([string]$Version, [string]$Name) return @{ id = "id-$Name"; path = "C:\t\$Name\tool.exe"; version = $Version; source = 'manual'; verification = 'verified'; isShim = $false; reachable = $false } }
$pick = Select-Preferred 'tool' @((New-TestCandidate '9' 'nine'), (New-TestCandidate '22' 'single'), (New-TestCandidate '1.2.20240101123456' 'long'))
Check "单段 22 应优先于 9 与 1.2.x，实际 $pick" ($pick -eq 'id-single')
$pick = Select-Preferred 'python' @((New-TestCandidate '3.12.0rc1' 'rc'), (New-TestCandidate '3.12.0' 'final'))
Check "同号正式版应优先于预发布，实际 $pick" ($pick -eq 'id-final')
$pick = Select-Preferred 'python' @((New-TestCandidate '3.12.0rc1' 'rc'), (New-TestCandidate '3.11.9' 'old')) @{ python = '3.12' }
Check "预发布不满足 3.12 前缀要求，实际 $pick" (-not $pick)

# ---------- 4. 扫描内核的声明比较（census.ps1 内的同名函数，从源码 AST 取出单独执行） ----------
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts 'census.ps1'), [ref]$null, [ref]$null)
$definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-VersionSatisfies' }, $true)
Check 'census.ps1 中应有 Test-VersionSatisfies' ($null -ne $definition)
if ($definition) {
    $censusResult = & {
        . ([scriptblock]::Create($definition.Extent.Text))
        try { @((Test-VersionSatisfies '1.2.20240101123456' '1.2'), (Test-VersionSatisfies '1.2.20240101123456' '1.3'), (Test-VersionSatisfies '22.23.2' '22')) } catch { "抛出异常：$($_.Exception.Message)" }
    }
    Check "census.ps1 的声明比较不能因超长数字段溢出：$($censusResult -join ',')" (($censusResult -join ',') -eq 'True,False,True')
}

if ($fail -eq 0) { Write-Host "[通过] 版本比较与排序（$($cases.Count) 条要求用例，PowerShell $($PSVersionTable.PSVersion)）"; exit 0 }
Write-Host " 有 $fail 项失败"
exit 1
