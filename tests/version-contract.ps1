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
    $censusCases = @(
        @('20.0.0', '>=18', $true),
        @('22.1.0', '20 || 22', $true),
        @('22.0.0-rc.1', '22', $false),
        @('19.0.0', '>=20 <23', $false)
    )
    foreach ($case in $censusCases) {
        $actual = & {
            . ([scriptblock]::Create($definition.Extent.Text))
            Test-VersionSatisfies $case[0] $case[1]
        }
        Check "扫描诊断 '$($case[0])' 对 '$($case[1])' 应为 $($case[2])，实际 $actual" ($actual -is [bool] -and $actual -eq $case[2])
    }
}

# 诊断告警的条件应基于运行时本身，不把包管理器版本当作运行时版本。
$warningDefinition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-Warnings' }, $true)
Check 'census.ps1 中应有 Get-Warnings' ($null -ne $warningDefinition)
if ($warningDefinition) {
    $warningResults = & {
        . ([scriptblock]::Create($definition.Extent.Text))
        $script:TestCensusRoot = $scripts
        $warningText = $warningDefinition.Extent.Text.Replace('$PSScriptRoot', '$script:TestCensusRoot')
        . ([scriptblock]::Create($warningText))
        function New-Warning { param($Kind, $Tool, $Facts, $Detail) [pscustomobject]@{ kind = $Kind; tool = $Tool; facts = $Facts } }
        function Test-FileQuick { param($Path) return $false }
        function Get-WarehouseToolRecords { param($ToolNames, $Root) return @() }
        function T { param($Key, $Values) return '' }
        $savedProfile = $env:USERPROFILE; $savedXdg = $env:XDG_CONFIG_HOME; $savedPath = $env:PATH
        try {
            $env:USERPROFILE = [IO.Path]::GetTempPath(); $env:XDG_CONFIG_HOME = ''; $env:PATH = ''
            $managedNode = @{ available = $true; records = @(@{ tool = 'node'; version = '22.0.0' }) }
            $nodeDeclaration = @(@{ scope = 'project'; path = 'fixture.toml'; tools = @{ node = '22' } })
            $resolution = @(
                @{ command = 'node'; resolvesTo = 'C:\fake\node.exe'; version = '22.1.0'; usable = $true; stub = $false; isShim = $false },
                @{ command = 'npm'; resolvesTo = 'C:\fake\npm.cmd'; version = '10.9.0'; usable = $true; stub = $false; isShim = $false }
            )
            $correctNode = @(Get-Warnings $managedNode @() @() $resolution $nodeDeclaration | Where-Object { $_.kind -eq 'PATH_ORDER' })
            $resolution[0].version = '16.20.2'
            $wrongNode = @(Get-Warnings $managedNode @() @() $resolution $nodeDeclaration | Where-Object { $_.kind -eq 'PATH_ORDER' })
            $managedJava = @{ available = $true; records = @(@{ tool = 'java'; version = '8' }) }
            $javaDeclaration = @(@{ scope = 'project'; path = 'fixture.toml'; tools = @{ java = '8' } })
            $javaResolution = @(@{ command = 'java'; resolvesTo = 'C:\fake\java.exe'; version = '1.8.0_504'; usable = $true; stub = $false; isShim = $false })
            $correctJava = @(Get-Warnings $managedJava @() @() $javaResolution $javaDeclaration | Where-Object { $_.kind -eq 'PATH_ORDER' })
            $noPython = @{ available = $true; records = @() }
            $pythonDeclaration = @(@{ scope = 'project'; path = 'fixture.toml'; tools = @{ python = '3.12' } })
            $pythonStub = @(@{ tool = 'python'; path = 'C:\fake\python.exe'; real = $false; placement = 'standard' })
            $stubResolution = @(@{ command = 'python'; resolvesTo = 'C:\fake\python.exe'; version = ''; usable = $false; stub = $true; isShim = $false })
            $missingPython = @(Get-Warnings $noPython @() $pythonStub $stubResolution $pythonDeclaration | Where-Object { $_.kind -eq 'MISSING' })
            return @{ correctNode = $correctNode; wrongNode = $wrongNode; correctJava = $correctJava; missingPython = $missingPython }
        } finally { $env:USERPROFILE = $savedProfile; $env:XDG_CONFIG_HOME = $savedXdg; $env:PATH = $savedPath }
    }
    Check 'Node 版本正确时，不得把 npm 自身版本当作 Node 的 PATH_ORDER' (@($warningResults.correctNode).Count -eq 0)
    Check 'Node 版本不符时，应只对 Node 自身发出 PATH_ORDER' (@($warningResults.wrongNode).Count -eq 1 -and $warningResults.wrongNode[0].tool -eq 'node')
    Check 'Java 8 的 1.8 版本应满足 Java 8 声明' (@($warningResults.correctJava).Count -eq 0)
    Check '只有不可用 Python 存根时，应报告声明版本尚未发现' (@($warningResults.missingPython).Count -eq 1)
}

# 仓库 <tool>/<version>/ 布局必须纳入扫描；只创建临时假文件，不执行它。
$rootsDefinition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-CandidateRoots' }, $true)
$unmanagedDefinition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-UnmanagedRecords' }, $true)
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('toolkit-census-roots-' + [guid]::NewGuid().ToString('N'))
try {
    $warehouse = Join-Path $fixtureRoot 'warehouse'
    $versionDir = Join-Path (Join-Path $warehouse 'node') '22.0.0'
    [void][IO.Directory]::CreateDirectory($versionDir)
    $fixtureExe = Join-Path $versionDir 'node.exe'; [IO.File]::WriteAllText($fixtureExe, 'fixture')
    $foundWarehouse = & {
        . ([scriptblock]::Create($rootsDefinition.Extent.Text))
        . ([scriptblock]::Create($unmanagedDefinition.Extent.Text))
        $script:ToolsRoot = $warehouse
        $script:ProbeRelatives = @('node.exe')
        $script:CensusData = @{ root = @(); 'ide-glob' = (New-Object 'System.Collections.Generic.List[string]'); 'conda-dir' = @(); 'conda-rel' = @() }
        function Get-PathDirs { return @() }
        function Get-SubDirectories { param($Dir) if ([IO.Directory]::Exists($Dir)) { return [IO.Directory]::GetDirectories($Dir) } return @() }
        function Test-DirQuick { param($Path) return [IO.Directory]::Exists($Path) }
        function Test-FileQuick { param($Path) return [IO.File]::Exists($Path) }
        function ConvertTo-RuntimeRecord { param($ExePath, $Root, $Pattern) [pscustomobject]@{ tool = 'node'; path = $ExePath; real = $true } }
        $roots = Get-CandidateRoots
        return @((Get-UnmanagedRecords $roots) | Where-Object { $_.path -eq $fixtureExe }).Count -eq 1
    }
    Check '扫描应发现统一仓库中的版本化运行时' $foundWarehouse
} finally {
    if ([IO.Directory]::Exists($fixtureRoot)) { [IO.Directory]::Delete($fixtureRoot, $true) }
}

# ---------- 5. 统一仓库中的普通工具（非运行时） ----------
# 声明里可以有 rg / jadx 这类不在运行时清单里的工具。它们可能只存在于统一仓库
# （<root>/<工具>/<版本>/...）且不在 PATH 上；这种"已安装"不能被误报成 MISSING。
# 同时，路径存在、0 字节文件或错误输出都不能算已验证；shim 不得被交给执行器。
$warehouseVersionDefinition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-WarehouseToolVersion' }, $true)
$warehouseRecordsDefinition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-WarehouseToolRecords' }, $true)
Check 'census.ps1 中应有 Get-WarehouseToolVersion' ($null -ne $warehouseVersionDefinition)
Check 'census.ps1 中应有 Get-WarehouseToolRecords' ($null -ne $warehouseRecordsDefinition)

$warehouseFixture = Join-Path ([IO.Path]::GetTempPath()) ('toolkit-census-warehouse-' + [guid]::NewGuid().ToString('N'))
try {
    $goodRoot   = Join-Path $warehouseFixture 'good'
    $goodExe    = Join-Path (Join-Path (Join-Path $goodRoot 'rg') '14.1.0') 'rg.exe'
    $aliasRoot  = Join-Path $warehouseFixture 'alias'
    $aliasExe   = Join-Path (Join-Path (Join-Path $aliasRoot 'ripgrep') '13.0.0') 'rg.exe'
    $binRoot    = Join-Path $warehouseFixture 'bin'
    $binExe     = Join-Path (Join-Path (Join-Path (Join-Path $binRoot 'jadx') '1.5.1') 'bin') 'jadx.bat'
    $brokenRoot = Join-Path $warehouseFixture 'broken'
    $brokenExe  = Join-Path (Join-Path (Join-Path $brokenRoot 'rg') '12.0.0') 'rg.exe'
    $errorRoot  = Join-Path $warehouseFixture 'error'
    $errorExe   = Join-Path (Join-Path (Join-Path $errorRoot 'rg') '11.0.0') 'rg.exe'
    $deepRoot   = Join-Path $warehouseFixture 'deep'
    $deepExe    = Join-Path $deepRoot 'rg\10.0.0\nested\rg.exe'
    $shimRoot   = Join-Path $warehouseFixture 'shims'
    $shimExe    = Join-Path (Join-Path (Join-Path $shimRoot 'rg') '9.0.0') 'rg.exe'
    foreach ($file in @($goodExe, $aliasExe, $binExe, $errorExe, $deepExe, $shimExe)) {
        [void][IO.Directory]::CreateDirectory((Split-Path $file -Parent))
        [IO.File]::WriteAllText($file, 'fixture, not a real executable')
    }
    [void][IO.Directory]::CreateDirectory((Split-Path $brokenExe -Parent))
    [IO.File]::WriteAllBytes($brokenExe, [byte[]]@())
    $goodExe   = (Resolve-Path -LiteralPath $goodExe).Path
    $aliasExe  = (Resolve-Path -LiteralPath $aliasExe).Path
    $binExe    = (Resolve-Path -LiteralPath $binExe).Path
    $brokenExe = (Resolve-Path -LiteralPath $brokenExe).Path
    $errorExe  = (Resolve-Path -LiteralPath $errorExe).Path
    $deepExe   = (Resolve-Path -LiteralPath $deepExe).Path
    $shimExe   = (Resolve-Path -LiteralPath $shimExe).Path

    $script:WarehouseProbeCalls = New-Object System.Collections.Generic.List[string]
    $script:WarehouseProbeArguments = New-Object System.Collections.Generic.List[string]
    $warehouseResults = & {
        if ($warehouseVersionDefinition) { . ([scriptblock]::Create($warehouseVersionDefinition.Extent.Text)) }
        if ($warehouseRecordsDefinition) { . ([scriptblock]::Create($warehouseRecordsDefinition.Extent.Text)) }
        # 未修复时函数不存在：用空实现让测试继续执行并报告失败，而不是抛异常中断。
        if (-not (Get-Command Get-WarehouseToolVersion -ErrorAction SilentlyContinue)) {
            function Get-WarehouseToolVersion { param($Tool, $ExePath) return '' }
        }
        if (-not (Get-Command Get-WarehouseToolRecords -ErrorAction SilentlyContinue)) {
            function Get-WarehouseToolRecords { param($ToolNames, $Root) return @() }
        }
        function Test-DirQuick { param($Path) return [IO.Directory]::Exists($Path) }
        function Test-FileQuick { param($Path) return [IO.File]::Exists($Path) }
        function Get-SubDirectories { param($Dir) if ([IO.Directory]::Exists($Dir)) { return [IO.Directory]::GetDirectories($Dir) } return @() }
        function Test-RealExecutable {
            param($Path)
            if (-not [IO.File]::Exists($Path)) { return $false }
            $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
            return ($null -ne $item -and -not $item.PSIsContainer -and $item.Length -gt 0)
        }
        # 替身执行器：只记录调用。测试绝不启动真实程序；shim 被传进来就直接失败。
        function Invoke-ToolkitProbe {
            param([string]$Exe, [string[]]$Arguments)
            $script:WarehouseProbeCalls.Add($Exe)
            $script:WarehouseProbeArguments.Add(($Arguments -join ' '))
            if ($Exe -match '[\\/]shims[\\/]') { throw "shim 被交给了执行器：$Exe" }
            if ($Exe -match '[\\/]error[\\/]') { return @{ ok = $true; exitCode = 0; stdout = 'error: failed to initialize runtime'; stderr = '' } }
            return @{ ok = $true; exitCode = 0; stdout = 'ripgrep 14.1.0 (rev fixture)'; stderr = '' }
        }

        $good   = @(Get-WarehouseToolRecords -ToolNames @('rg') -Root $goodRoot)
        $alias  = @(Get-WarehouseToolRecords -ToolNames @('rg') -Root $aliasRoot)
        $bin    = @(Get-WarehouseToolRecords -ToolNames @('jadx') -Root $binRoot)
        $broken = @(Get-WarehouseToolRecords -ToolNames @('rg') -Root $brokenRoot)
        $error  = @(Get-WarehouseToolRecords -ToolNames @('rg') -Root $errorRoot)
        $deep   = @(Get-WarehouseToolRecords -ToolNames @('rg') -Root $deepRoot)
        $shim   = @(Get-WarehouseToolRecords -ToolNames @('rg') -Root $shimRoot)
        $directShim = Get-WarehouseToolVersion -Tool 'rg' -ExePath $shimExe

        return @{ good = $good; alias = $alias; bin = $bin; broken = $broken; error = $error; deep = $deep; shim = $shim; directShim = $directShim }
    }
    Check '统一仓库中可运行的 rg 应被识别为已安装' (@($warehouseResults.good).Count -eq 1 -and $warehouseResults.good[0].tool -eq 'rg' -and $warehouseResults.good[0].version -eq '14.1.0')
    Check 'ripgrep 目录应通过别名识别为 rg' (@($warehouseResults.alias).Count -eq 1 -and $warehouseResults.alias[0].tool -eq 'rg')
    Check '版本目录的 bin 子目录应被识别' (@($warehouseResults.bin).Count -eq 1 -and $warehouseResults.bin[0].tool -eq 'jadx')
    Check '0 字节文件不能冒充已安装' (@($warehouseResults.broken).Count -eq 0)
    Check '错误输出不能冒充已验证版本' (@($warehouseResults.error).Count -eq 0)
    Check '未知仓库工具只执行 --version，不猜测其他子命令' (@($script:WarehouseProbeArguments | Where-Object { $_ -ne '--version' }).Count -eq 0)
    Check '不得递归到版本目录深处' (@($warehouseResults.deep).Count -eq 0)
    Check 'shim 不能冒充已安装' (@($warehouseResults.shim).Count -eq 0 -and -not $warehouseResults.directShim)
    Check '探测只应发生在候选文件上（未执行 shim / 0 字节 / 深层文件）' (
        -not @($script:WarehouseProbeCalls | Where-Object { $_ -match '[\\/]shims[\\/]' -or $_ -eq $brokenExe -or $_ -eq $deepExe }).Count -and
        @($script:WarehouseProbeCalls | Where-Object { $_ -eq $goodExe }).Count -eq 1 -and
        @($script:WarehouseProbeCalls | Where-Object { $_ -eq $aliasExe }).Count -eq 1 -and
        @($script:WarehouseProbeCalls | Where-Object { $_ -eq $binExe }).Count -eq 1 -and
        @($script:WarehouseProbeCalls | Where-Object { $_ -notlike "$warehouseFixture*" }).Count -eq 0
    )

    # Get-Warnings 的 MISSING 判断必须接受"只在统一仓库里"的已验证工具；
    # 不可用副本（错误输出 / shim）仍然必须报 MISSING。
    $warningResults = & {
        $script:TestCensusRoot = $scripts
        if ($warningDefinition) {
            $warningText = $warningDefinition.Extent.Text.Replace('$PSScriptRoot', '$script:TestCensusRoot')
            . ([scriptblock]::Create($warningText))
        }
        if ($warehouseVersionDefinition) { . ([scriptblock]::Create($warehouseVersionDefinition.Extent.Text)) }
        if ($warehouseRecordsDefinition) { . ([scriptblock]::Create($warehouseRecordsDefinition.Extent.Text)) }
        if (-not (Get-Command Get-WarehouseToolVersion -ErrorAction SilentlyContinue)) {
            function Get-WarehouseToolVersion { param($Tool, $ExePath) return '' }
        }
        if (-not (Get-Command Get-WarehouseToolRecords -ErrorAction SilentlyContinue)) {
            function Get-WarehouseToolRecords { param($ToolNames, $Root) return @() }
        }
        function Test-DirQuick { param($Path) return [IO.Directory]::Exists($Path) }
        function Test-FileQuick { param($Path) return [IO.File]::Exists($Path) }
        function Get-SubDirectories { param($Dir) if ([IO.Directory]::Exists($Dir)) { return [IO.Directory]::GetDirectories($Dir) } return @() }
        function Test-RealExecutable {
            param($Path)
            if (-not [IO.File]::Exists($Path)) { return $false }
            $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
            return ($null -ne $item -and -not $item.PSIsContainer -and $item.Length -gt 0)
        }
        function Invoke-ToolkitProbe {
            param([string]$Exe, [string[]]$Arguments)
            if ($Exe -match '[\\/]shims[\\/]') { throw "shim 被交给了执行器：$Exe" }
            if ($Exe -match '[\\/]error[\\/]') { return @{ ok = $true; exitCode = 0; stdout = 'error: failed to initialize runtime'; stderr = '' } }
            return @{ ok = $true; exitCode = 0; stdout = 'ripgrep 14.1.0 (rev fixture)'; stderr = '' }
        }
        function T { param($Key, $Facts) return '' }
        function New-Warning { param($Kind, $Tool, $Facts, $Detail) [pscustomobject]@{ kind = $Kind; tool = $Tool; facts = $Facts; message = ''; action = ''; detail = $Detail } }
        function Get-PathDirs { return @() }
        function Test-VersionSatisfies { param($Version, $Wanted) return $true }

        $managed = @{ available = $true; records = @() }
        $declaration = @(@{ scope = 'project'; path = 'fixture.toml'; tools = @{ rg = '14' } })

        $script:ToolsRoot = $goodRoot
        $goodMissing = @(Get-Warnings $managed @() @() @() $declaration | Where-Object { $_.kind -eq 'MISSING' })
        $script:ToolsRoot = $errorRoot
        $errorMissing = @(Get-Warnings $managed @() @() @() $declaration | Where-Object { $_.kind -eq 'MISSING' })
        $script:ToolsRoot = $shimRoot
        $shimMissing = @(Get-Warnings $managed @() @() @() $declaration | Where-Object { $_.kind -eq 'MISSING' })

        return @{ good = $goodMissing; error = $errorMissing; shim = $shimMissing }
    }
    Check '统一仓库里可运行的 rg 不应再报 MISSING' (@($warningResults.good).Count -eq 0)
    Check '只有错误输出的仓库副本仍应报 MISSING' (@($warningResults.error).Count -eq 1)
    Check '仓库里的 shim 仍应报 MISSING' (@($warningResults.shim).Count -eq 1)
} finally {
    if ([IO.Directory]::Exists($warehouseFixture)) { [IO.Directory]::Delete($warehouseFixture, $true) }
}

if ($fail -eq 0) { Write-Host "[通过] 版本比较与排序（$($cases.Count) 条要求用例，PowerShell $($PSVersionTable.PSVersion)）"; exit 0 }
Write-Host " 有 $fail 项失败"
exit 1
