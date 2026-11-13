#Requires -Version 5.1
# 使用临时地图、假工具与假 census 验证公开契约；不安装工具，不读取本机地图。
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$hostExe = (Get-Process -Id $PID).Path
$scratch = [IO.Path]::GetFullPath((Join-Path $env:TEMP ('toolkit-map-contract-' + [guid]::NewGuid().ToString('N'))))
$original = @{}
foreach ($name in @('USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'MISE_DATA_DIR', 'MISE_SHIMS_DIR', 'MISE_CONFIG_FILE', 'MISE_CONFIG_DIR', 'XDG_CONFIG_HOME', 'TOOLCHAIN_ROOT', 'VOLTA_HOME', 'FNM_DIR', 'SCOOP', 'ASDF_DATA_DIR', 'ProgramFiles', 'ProgramFiles(x86)', 'PATH')) { $original[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
function Assert {
    param([bool]$Ok, [string]$Message)
    if (-not $Ok) { throw $Message }
}
function Run-Map {
    param([string[]]$Arguments)
    $old = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $hostExe -NoProfile -ExecutionPolicy Bypass -File $mapScript @Arguments -MapFile $mapFile -Json 2>&1)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    $jsonLines = @($output | ForEach-Object { "$_" } | Where-Object { $_ -match '^\{' })
    Assert ($jsonLines.Count -eq 1) "stdout 必须恰好一个 JSON 对象：$($output -join '`n')"
    $value = $jsonLines[0] | ConvertFrom-Json
    Assert ($value.schemaVersion -eq 2 -and $null -ne $value.ok -and $value.action) '缺少结果契约字段'
    return @{ value = $value; code = $code; output = $output }
}
function Fake-Tool {
    param([string]$Directory, [string]$Name, [string]$Version)
    [void][IO.Directory]::CreateDirectory($Directory)
    $file = Join-Path $Directory ($Name + '.cmd')
    [IO.File]::WriteAllText($file, "@echo off`r`necho $Name $Version`r`nexit /b 0`r`n", [Text.Encoding]::ASCII)
    return [IO.Path]::GetFullPath($file)
}
# 地图去掉随时间变化的字段（键名以 At 结尾：scannedAt、updatedAt、checkedAt 等）、键按名字排序后的稳定文本
# （地图里的对象来自哈希表，PS7 每个进程的键序都可能不同，所以比较前统一排序）
function ConvertTo-StableNode {
    param($Node)
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        $out = [ordered]@{}
        foreach ($name in @($Node.PSObject.Properties | ForEach-Object { $_.Name } | Where-Object { $_ -cnotmatch 'At$' } | Sort-Object -CaseSensitive)) { $out[$name] = ConvertTo-StableNode $Node.$name }
        return $out
    }
    if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) { return ,@(foreach ($item in $Node) { ConvertTo-StableNode $item }) }
    return $Node
}
function Get-StableMapText {
    param([string]$Path)
    $value = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    return (ConvertTo-StableNode $value | ConvertTo-Json -Depth 30 -Compress)
}
try {
    [void][IO.Directory]::CreateDirectory($scratch)
    $scripts = Join-Path $scratch 'product\scripts'
    [void][IO.Directory]::CreateDirectory($scripts)
    foreach ($name in @('map.ps1', 'map-core.ps1', 'toolkit-common.ps1', 'tools.json')) { Copy-Item -LiteralPath (Join-Path (Join-Path $repo 'scripts') $name) -Destination $scripts }
    Copy-Item -LiteralPath (Join-Path $repo 'VERSION') -Destination (Join-Path $scratch 'product')
    [void][IO.Directory]::CreateDirectory((Join-Path $scratch 'product\templates'))
    Copy-Item -LiteralPath (Join-Path $repo 'templates\agent-tool-rules.md') -Destination (Join-Path $scratch 'product\templates')
    $mapScript = Join-Path $scripts 'map.ps1'
    $mapFile = Join-Path $scratch 'map.json'
    $project = Join-Path $scratch 'project'
    $homeDir = Join-Path $scratch 'home'
    foreach ($dir in @($project, $homeDir, (Join-Path $homeDir '.config\mise'))) { [void][IO.Directory]::CreateDirectory($dir) }
    $env:USERPROFILE = $homeDir; $env:APPDATA = $homeDir; $env:LOCALAPPDATA = $homeDir
    $env:MISE_DATA_DIR = Join-Path $scratch 'custom-manager'
    $env:MISE_SHIMS_DIR = ''; $env:MISE_CONFIG_FILE = ''; $env:MISE_CONFIG_DIR = ''; $env:XDG_CONFIG_HOME = ''
    $env:VOLTA_HOME = ''; $env:FNM_DIR = ''; $env:SCOOP = ''; $env:ASDF_DATA_DIR = ''
    $env:TOOLCHAIN_ROOT = Join-Path $scratch 'warehouse'
    [Environment]::SetEnvironmentVariable('ProgramFiles', (Join-Path $scratch 'program-files'), 'Process')
    [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', (Join-Path $scratch 'program-files-x86'), 'Process')
    $env:PATH = ''
    # scan 必须启动当前宿主；假内核隔离机器盘点，但调用的是原样的产品入口。
    $fakeCensus = @'
param([switch]$Json)
'{"schemaVersion":1,"runtimes":[],"declarations":[],"warnings":[]}'
'@
    [IO.File]::WriteAllText((Join-Path $scripts 'census.ps1'), $fakeCensus, (New-Object Text.UTF8Encoding $true))
    $r = Run-Map @('help')
    Assert ($r.code -eq 0 -and $r.value.version -eq ([IO.File]::ReadAllText((Join-Path $repo 'VERSION'))).Trim()) 'help 的版本必须来自 VERSION'
    $r = Run-Map @('scan'); Assert ($r.code -eq 0) '当前 PowerShell 宿主下 scan 应成功'
    $scanTime = $r.value.scannedAt
    # 正常退出但数据缺字段的内核不能把旧地图覆盖为“完整扫描”。
    $savedMapBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($mapFile))
    foreach ($badJson in @('{}', '{"schemaVersion":1,"runtimes":"wrong","declarations":[],"warnings":[]}', '{"schemaVersion":1,"runtimes":[],"declarations":[]}', '{"schemaVersion":1,"runtimes":[{"tool":"node"}],"declarations":[],"warnings":[]}')) {
        $badCensus = "param([switch]`$Json)`r`n'$badJson'`r`n"
        [IO.File]::WriteAllText((Join-Path $scripts 'census.ps1'), $badCensus, (New-Object Text.UTF8Encoding $true))
        $badResult = Run-Map @('scan')
        Assert ($badResult.code -ne 0 -and $badResult.value.status -eq 'scan_failed' -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($mapFile)) -eq $savedMapBytes) "不完整 census 结果必须拒绝保存：$badJson"
    }
    [IO.File]::WriteAllText((Join-Path $scripts 'census.ps1'), $fakeCensus, (New-Object Text.UTF8Encoding $true))
    # probeStats 是附加字段：launches 必须是非负整数；假 census 没有 probeStats，census 部分按 0 计。
    $probeStats = $r.value.probeStats
    $probeLaunches = if ($probeStats) { $probeStats.launches } else { $null }
    Assert (($probeLaunches -is [int] -or $probeLaunches -is [long]) -and $probeLaunches -ge 0) "scan 结果必须带非负整数 probeStats.launches：$($r.output -join '`n')"
    Assert ($probeStats.census.launches -eq 0 -and ($probeStats.wallMs -is [int] -or $probeStats.wallMs -is [long]) -and $probeStats.wallMs -ge 0) "census 缺 probeStats 时应按 0 计，wallMs 为非负整数：$($r.output -join '`n')"
    $one = Fake-Tool (Join-Path $scratch 'node16') 'node' '16.20.2'
    $two = Fake-Tool (Join-Path $scratch 'node22') 'node' '22.23.2'
    $beforeInvalidUpdate = [Convert]::ToBase64String([IO.File]::ReadAllBytes($mapFile))
    foreach ($invalidTool in @('C:\fixture\node.exe', '../node', 'node;other')) {
        $badUpdate = Run-Map @('update', $invalidTool)
        Assert ($badUpdate.code -ne 0 -and $badUpdate.value.status -eq 'invalid_argument' -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($mapFile)) -eq $beforeInvalidUpdate) "update 必须拒绝路径或非法名称并保持地图不变：$invalidTool"
    }
    $r = Run-Map @('add', 'node', '-Path', $one, '-Note', '手工登记保留', '-Prefer'); Assert ($r.code -eq 0) 'add 失败'
    $r = Run-Map @('add', 'node', '-Path', $two); Assert ($r.code -eq 0) '第二份 add 失败'
    $r = Run-Map @('add', 'node', '-Path', $one)
    $r = Run-Map @('find', 'node', '-Project', $project, '-SkipScan')
    Assert ($r.value.ok -and $r.value.path -eq $one -and $r.value.note -eq '手工登记保留') '重新登记同一路径且未提供新备注时应保留已有备注与偏好'
    # 编辑器/IDE 宿主自带的 helper 运行时不能作为项目候选；只有 -AllowIdeHost 才能显式启用。
    $editorNode = Fake-Tool (Join-Path $scratch 'editor\resources\app\resources\helpers') 'node' '24.22.1'
    $r = Run-Map @('add', 'node', '-Path', $editorNode); Assert ($r.code -eq 0) '登记编辑器自带 Node 失败'
    $editorFind = Run-Map @('find', 'node', '-Project', $project, '-Version', '24', '-SkipScan')
    Assert (-not $editorFind.value.ok -and $editorFind.value.status -eq 'version_mismatch' -and -not $editorFind.value.path) '编辑器自带 Node 不应被 -Version 24 默认选中'
    $editorCandidate = @($editorFind.value.candidates | Where-Object { $_.path -eq $editorNode } | Select-Object -First 1)
    Assert ($editorCandidate.Count -eq 1 -and $editorCandidate[0].source -eq 'ide-host' -and $editorCandidate[0].verification -eq 'verified') '编辑器自带 Node 必须归为 ide-host 且保留验证状态'
    $editorAllowed = Run-Map @('find', 'node', '-Project', $project, '-Version', '24', '-SkipScan', '-AllowIdeHost')
    Assert ($editorAllowed.value.ok -and $editorAllowed.value.path -eq $editorNode) '-AllowIdeHost 应允许显式选择编辑器自带 Node'
    # 损坏的 package.json 是无法判断的 Node 声明，而不是可忽略的空声明。
    $badProject = Join-Path $scratch 'bad-package-project'; [void][IO.Directory]::CreateDirectory($badProject)
    foreach ($badJson in @('{invalid', '[]', '{"engines":"22"}', '{"engines":{"node":22}}')) {
        [IO.File]::WriteAllText((Join-Path $badProject 'package.json'), $badJson, [Text.Encoding]::UTF8)
        $badNode = Run-Map @('find', 'node', '-Project', $badProject, '-SkipScan')
        Assert (-not $badNode.value.ok -and $badNode.value.status -eq 'requirement_unsupported' -and -not $badNode.value.path) "损坏的 package.json 应明确阻止猜测 Node 要求：$badJson，实际：$($badNode.output -join ' ')"
    }
    $badGitPath = Fake-Tool (Join-Path $scratch 'bad-package-git') 'git' '2.45.1'
    $r = Run-Map @('add', 'git', '-Path', $badGitPath)
    $badGit = Run-Map @('find', 'git', '-Project', $badProject, '-SkipScan')
    Assert ($badGit.value.ok -and $badGit.value.path -eq $badGitPath) '损坏的 Node package.json 不应阻止无关 Git 查询'
    [IO.File]::WriteAllText((Join-Path $homeDir '.config\mise\config.toml'), "[tools]`nnode = `"16`"`n")
    [IO.File]::WriteAllText((Join-Path $project 'mise.toml'), "[tools]`nnode = `"22`"`n")
    $r = Run-Map @('find', 'node', '-Project', $project, '-SkipScan')
    Assert ($r.code -eq 0 -and $r.value.path -eq $two -and $r.value.requirement.scope -eq 'project') "项目声明必须覆盖全局声明和用户偏好。退出码=$($r.code)，期望路径=$two，实际结果：$($r.output -join '`n')"
    $r = Run-Map @('find', 'node', '-Project', $project, '-Version', '20', '-SkipScan')
    Assert ($r.code -ne 0 -and $r.value.status -eq 'version_mismatch' -and -not $r.value.path) '缺少要求版本时不许降级'
    $invalidProject = Join-Path $scratch 'project-does-not-exist'
    $r = Run-Map @('find', 'node', '-Project', $invalidProject, '-Version', '22', '-SkipScan')
    Assert ($r.code -ne 0 -and $r.value.status -eq 'invalid_project' -and -not $r.value.path) '显式版本只覆盖声明，不能返回不存在的 invocation.cwd'
    $r = Run-Map @('find', 'node', '-Project', $project, '-Version', '>=22 <23', '-SkipScan')
    Assert ($r.code -eq 0 -and $r.value.path -eq $two) 'engines 范围比较失败'
    $r = Run-Map @('find', 'node', '-Project', $project, '-Version', '^22.0.0', '-SkipScan')
    Assert ($r.code -eq 0 -and $r.value.path -eq $two) 'caret 比较失败'
    $r = Run-Map @('find', 'node', '-Project', $project, '-Version', '22.23.3', '-SkipScan')
    Assert ($r.code -ne 0) '补丁版本必须精确匹配'
    $r = Run-Map @('find', 'node', '-Project', $project, '-Version', 'lts/unknown', '-SkipScan')
    Assert ($r.code -ne 0 -and $r.value.status -eq 'requirement_unsupported') '未知版本表达式不能当成满足'
    foreach ($range in @('>=22 <=22', '=22.23')) {
        $r = Run-Map @('find', 'node', '-Project', $project, '-Version', $range, '-SkipScan')
        Assert ($r.code -eq 0 -and $r.value.path -eq $two) "部分版本比较应接受 22.23.2：$range"
    }
    $r = Run-Map @('find', 'node', '-Project', $project, '-Version', '>22', '-SkipScan')
    Assert ($r.code -ne 0) '>22 不应接受 22.x'
    foreach ($header in @('[tools.node]', '[tools."node"]', '[[tools.node]]', '["tools".node]')) {
        [IO.File]::WriteAllText((Join-Path $project 'mise.toml'), "$header`nversion = '22'`n")
        $r = Run-Map @('find', 'node', '-Project', $project, '-SkipScan')
        Assert ($r.code -ne 0 -and $r.value.status -eq 'requirement_unsupported' -and -not $r.value.path) "复杂声明不得被忽略并降级到全局 Node 16：$header"
    }
    [IO.File]::WriteAllText((Join-Path $project 'mise.toml'), "[tools]`nnode.version = '22'`n")
    $r = Run-Map @('find', 'node', '-Project', $project, '-SkipScan')
    Assert ($r.code -ne 0 -and $r.value.status -eq 'requirement_unsupported') '点号工具表不得被忽略'
    [IO.File]::WriteAllText((Join-Path $project 'mise.toml'), "[tools]`nnode = `"22`"`n")
    $r = Run-Map @('update', 'node'); Assert ($r.code -eq 0 -and $r.value.scannedAt -eq $scanTime) '条目更新不得刷新完整扫描时间'
    $r = Run-Map @('scan'); Assert ($r.code -eq 0) '重扫失败'
    $r = Run-Map @('find', 'node', '-Project', $project, '-Version', '16', '-SkipScan')
    Assert ($r.value.path -eq $one -and $r.value.note -eq '手工登记保留') '重扫必须保留手工副本、备注与偏好'
    $three = Fake-Tool (Join-Path $scratch 'same-version') 'node' '22.23.2'
    $r = Run-Map @('add', 'node', '-Path', $three, '-Prefer')
    $r = Run-Map @('find', 'node', '-Project', $project, '-SkipScan')
    Assert ($r.value.path -eq $three) '同版本第二份 Prefer 必须生效'
    $ids = @($r.value.candidates.id)
    Assert (@($ids | Sort-Object -Unique).Count -eq $ids.Count) '候选 ID 撞车'
    $empty = Join-Path $scratch 'empty.exe'; [IO.File]::WriteAllBytes($empty, [byte[]]@())
    $r = Run-Map @('add', 'empty', '-Path', $empty, '-Version', '1.0.0')
    $r = Run-Map @('find', 'empty', '-Project', $project, '-SkipScan', '-AllowUnverified')
    Assert ($r.code -ne 0 -and -not $r.value.found) '普通零字节文件永远不能当可用副本'
    $shimDir = Join-Path $env:MISE_DATA_DIR 'shims'; [void][IO.Directory]::CreateDirectory($shimDir)
    $marker = Join-Path $scratch 'shim-executed.txt'
    $shim = Join-Path $shimDir 'node.cmd'
    [IO.File]::WriteAllText($shim, "@echo off`r`necho wrong > `"$marker`"`r`necho node 99.0.0`r`n", [Text.Encoding]::ASCII)
    $r = Run-Map @('add', 'node', '-Path', $shim, '-Version', '99.0.0', '-Prefer')
    $r = Run-Map @('find', 'node', '-Project', $project, '-Version', '99', '-AllowUnverified')
    Assert ($r.code -ne 0 -and -not [IO.File]::Exists($marker)) '自定义目录的 shim 不得执行或选为首选'
    $r = Run-Map @('setup', '-Project', $project, '-WhatIf')
    Assert ($r.code -eq 0 -and $r.value.status -eq 'planned' -and -not [IO.File]::Exists((Join-Path $project 'AGENTS.md'))) 'setup WhatIf 必须只读'
    [IO.File]::WriteAllText((Join-Path $project 'AGENTS.md'), "# 原有规则`n保留这句话`n")
    $r = Run-Map @('setup', '-Project', $project)
    Assert ($r.code -eq 0 -and [IO.File]::Exists($r.value.backup)) '已有规则必须备份'
    $rules = [IO.File]::ReadAllText((Join-Path $project 'AGENTS.md'))
    Assert ($rules.Contains('保留这句话') -and $rules.Contains($mapScript)) 'setup 必须保留用户规则并写入绝对路径'
    Assert ($rules.Contains('toolkit_find') -and $rules.Contains('toolkit_scan') -and $rules.Contains('confirm:true') -and $rules.Contains('不执行新候选')) 'setup 规则必须优先 MCP，说明严格只读与维护授权'
    $escapedRuleMap = $mapFile.Replace("'", "''")
    Assert ($rules.Contains("-MapFile '$escapedRuleMap'")) 'setup 的命令行回退必须固定到本次接入的地图'
    $r = Run-Map @('setup', '-Project', $project)
    Assert ($r.code -eq 0 -and -not $r.value.rulesChanged) 'setup 必须幂等'
    # The generated fallback must keep a custom map even if the later CLI
    # session has a different TOOLKIT_MAP. Exercise single-quote escaping too.
    $savedMapFile = $mapFile; $savedToolkitMap = $env:TOOLKIT_MAP
    try {
        $mapFile = Join-Path $scratch "custom-owner's-map.json"
        Copy-Item -LiteralPath $savedMapFile -Destination $mapFile
        $fallbackProject = Join-Path $scratch 'fallback-project'; [void][IO.Directory]::CreateDirectory($fallbackProject)
        $fallbackSetup = Run-Map @('setup', '-Project', $fallbackProject)
        Assert ($fallbackSetup.code -eq 0) '自定义地图 setup 失败'
        $fallbackRules = [IO.File]::ReadAllText((Join-Path $fallbackProject 'AGENTS.md'))
        Assert ($fallbackRules -match "status -MapFile '((?:''|[^'])*)' -Json") '规则缺少安全引用的状态查询地图参数'
        $fallbackMap = $Matches[1].Replace("''", "'")
        Assert ($fallbackMap -eq $mapFile) '规则中的地图路径或单引号转义不正确'
        $decoy = Join-Path $scratch 'fallback-decoy.json'; $env:TOOLKIT_MAP = $decoy
        $fallbackOutput = & $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $mapScript status -MapFile $fallbackMap -Json
        $fallbackCode = $LASTEXITCODE
        $fallbackStatus = ($fallbackOutput | Out-String) | ConvertFrom-Json
        Assert ($fallbackCode -eq 0 -and $fallbackStatus.mapFile -eq $mapFile -and -not [IO.File]::Exists($decoy)) '回退命令必须使用 setup 地图而非不同的环境地图'
    } finally {
        $mapFile = $savedMapFile
        $env:TOOLKIT_MAP = $savedToolkitMap
    }
    $r = Run-Map @('doctor', '-Project', $project)
    Assert ($r.code -eq 0 -and -not $r.value.agentVerified) 'doctor 应通过，并明确不能证明模型行为'
    $r = Run-Map @('install', 'rg@latest', '-WhatIf')
    Assert ($r.code -eq 0 -and $r.value.status -eq 'planned') 'latest WhatIf 不应联网'
    $r = Run-Map @('install', '../escape', '-Version', '1', '-Url', 'https://example.invalid/tool.zip', '-WhatIf')
    Assert ($r.code -ne 0 -and $r.value.status -eq 'invalid_argument') '安装参数不得越出仓库'
    $rg = Fake-Tool (Join-Path $env:TOOLCHAIN_ROOT 'ripgrep\15.0.0') 'rg' '15.0.0'
    $r = Run-Map @('find', 'ripgrep', '-Project', $project)
    Assert ($r.code -ne 0 -and $r.value.tool -eq 'rg' -and @($r.value.candidates | Where-Object { $_.path -eq $rg -and $_.verification -eq 'unverified' }).Count -eq 1) '只读查询应发现别名与旧仓库目录，但不得自动验证'
    $r = Run-Map @('update', 'rg'); Assert ($r.code -eq 0) '明确更新后应验证仓库中的已有副本'
    $r = Run-Map @('find', 'ripgrep', '-Project', $project)
    Assert ($r.code -eq 0 -and $r.value.tool -eq 'rg' -and $r.value.path -eq $rg) '验证后的别名与旧仓库目录应可选择'
    $java = Fake-Tool (Join-Path $scratch 'temurin\jdk8') 'java' '1.8.0_504'
    $r = Run-Map @('add', 'java', '-Path', $java)
    $r = Run-Map @('find', 'java', '-Version', 'temurin-8,temurin-21', '-Project', $project, '-SkipScan')
    Assert ($r.code -eq 0 -and $r.value.path -eq $java) 'Java 旧版本号和发行版候选要求应可匹配'
    $r = Run-Map @('find', 'java', '-Version', '1.8.0_504', '-Project', $project, '-SkipScan')
    Assert ($r.code -eq 0) 'Java 完整旧版本号应精确匹配'
    $r = Run-Map @('find', 'java', '-Version', 'zulu-8', '-Project', $project, '-SkipScan')
    Assert ($r.code -ne 0) '不能把其他发行版当成满足'
    # 连续查询命中缓存：PS7 的 ConvertFrom-Json 会把 modifiedAt 转成 DateTime，比较必须与 5.1 一致，
    # 否则非 UTC 时区下每次 find 都会重新执行候选并重写地图文件。
    $probeLog = Join-Path $scratch 'cache-probes.log'
    $cacheDir = Join-Path $scratch 'cache-tool'; [void][IO.Directory]::CreateDirectory($cacheDir)
    $cacheTool = Join-Path $cacheDir 'cachetool.cmd'
    [IO.File]::WriteAllText($cacheTool, "@echo off`r`necho probe>>`"$probeLog`"`r`necho cachetool 1.2.3`r`nexit /b 0`r`n", [Text.Encoding]::ASCII)
    $r = Run-Map @('add', 'cachetool', '-Path', $cacheTool)
    Assert ($r.code -eq 0 -and $r.value.verification -eq 'verified') "缓存测试工具登记失败：$($r.output -join '`n')"
    $mdFile = [IO.Path]::ChangeExtension($mapFile, '.md')
    $snapshot = { @(@($mapFile, $mdFile) | ForEach-Object { (Get-Item -LiteralPath $_).LastWriteTimeUtc.Ticks; (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }) -join '|' }
    $probesBefore = @(Get-Content -LiteralPath $probeLog).Count
    $filesBefore = & $snapshot
    for ($i = 0; $i -lt 2; $i++) {
        $r = Run-Map @('find', 'cachetool', '-Project', $project, '-SkipScan')
        Assert ($r.code -eq 0 -and $r.value.path -eq $cacheTool) "缓存测试 find 失败：$($r.output -join '`n')"
    }
    Assert (@(Get-Content -LiteralPath $probeLog).Count -eq $probesBefore) "文件未变时连续 find 不得重新探测（PowerShell $($PSVersionTable.PSVersion)）"
    Assert ((& $snapshot) -eq $filesBefore) "文件未变时连续 find 不得重写 map.json / map.md（PowerShell $($PSVersionTable.PSVersion)）"
    # 严格只读查询：所有路径、地图和被探测文件都位于本测试的隔离目录。
    $oldMap = $mapFile; $oldMd = $mdFile; $oldPath = $env:PATH
    try {
        $mapFile = Join-Path $scratch 'readonly-map.json'; $mdFile = [IO.Path]::ChangeExtension($mapFile, '.md')
        $roProject = Join-Path $scratch 'readonly-project'; [void][IO.Directory]::CreateDirectory($roProject)
        $roPath = Join-Path $scratch 'readonly-bin'; [void][IO.Directory]::CreateDirectory($roPath)
        $env:PATH = $roPath
        $marker = Join-Path $scratch 'readonly-probes.txt'
        $oldNode = Fake-Tool $roPath 'node' '16.20.2'
        [IO.File]::WriteAllText($oldNode, "@echo off`r`necho probe>>`"$marker`"`r`necho node 16.20.2`r`nexit /b 0`r`n", [Text.Encoding]::ASCII)
        $newNode = Fake-Tool (Join-Path $env:TOOLCHAIN_ROOT 'node\22') 'node' '22.23.2'
        $r = Run-Map @('add', 'node', '-Path', $oldNode, '-Note', 'keep this registration'); Assert ($r.code -eq 0) '只读测试旧版本登记失败'
        $r = Run-Map @('add', 'node', '-Path', $newNode); Assert ($r.code -eq 0) '只读测试仓库版本登记失败'
        # A PATH winner excluded from the map is not a reason to discard an
        # independently verified candidate; never execute or label it default.
        $safePick = Fake-Tool (Join-Path $scratch 'verified-pick') 'picktest' '1.2.3'
        $r = Run-Map @('add', 'picktest', '-Path', $safePick); Assert ($r.code -eq 0) '查询回退候选登记失败'
        foreach ($suffix in @('.venv\Scripts', 'custom-manager\shims', 'unregistered-path')) {
            $excludedDir = Join-Path $scratch $suffix
            $excluded = Fake-Tool $excludedDir 'picktest' '9.0.0'
            [IO.File]::WriteAllText($excluded, "@echo off`r`necho probe>>`"$marker`"`r`necho picktest 9.0.0`r`n", [Text.Encoding]::ASCII)
            $env:PATH = $excludedDir
            $probeCount = @([IO.File]::ReadAllLines($marker)).Count
            $before = & $snapshot
            $pick = Run-Map @('find', 'picktest', '-Project', $roProject, '-SkipScan')
            Assert ($pick.value.ok -and $pick.value.path -eq $safePick -and $pick.value.reason -eq 'available_candidate') "不可选 PATH 默认不应阻止已验证候选：$suffix"
            Assert ((& $snapshot) -eq $before -and @([IO.File]::ReadAllLines($marker)).Count -eq $probeCount) "只读回退不得执行 PATH 候选或写地图：$suffix"
        }
        $env:PATH = $roPath
        $before = & $snapshot; $probeCount = @([IO.File]::ReadAllLines($marker)).Count
        $r = Run-Map @('find', 'node', '-Project', $roProject)
        Assert ($r.value.ok -and $r.value.path -eq $oldNode) '无声明时应选择 PATH 实际默认版本，而非仓库版本'
        Assert ((& $snapshot) -eq $before -and @([IO.File]::ReadAllLines($marker)).Count -eq $probeCount) '已验证候选的 find 不得写地图或运行候选'
        $unknownMarker = Join-Path $scratch 'unknown-probes.txt'
        $unknown = Fake-Tool $roPath 'unregistered' '1.2.3'
        [IO.File]::WriteAllText($unknown, "@echo off`r`necho probe>>`"$unknownMarker`"`r`necho unregistered 1.2.3`r`n", [Text.Encoding]::ASCII)
        $before = & $snapshot
        $r = Run-Map @('find', 'unregistered', '-Project', $roProject)
        Assert (-not $r.value.ok -and -not $r.value.path -and @($r.value.candidates | Where-Object { $_.path -eq $unknown -and $_.verification -eq 'unverified' }).Count -eq 1) '新发现候选应标记未验证，不能选择'
        Assert (-not [IO.File]::Exists($unknownMarker) -and (& $snapshot) -eq $before) 'find 新候选不得执行程序或写地图'
        [IO.File]::AppendAllText($oldNode, "rem changed`r`n", [Text.Encoding]::ASCII)
        $before = & $snapshot; $probeCount = @([IO.File]::ReadAllLines($marker)).Count
        $r = Run-Map @('find', 'node', '-Project', $roProject, '-Version', '16', '-SkipScan', '-AllowUnverified')
        Assert (-not $r.value.ok -and $r.value.status -eq 'invalid_argument' -and -not $r.value.path -and (& $snapshot) -eq $before -and @([IO.File]::ReadAllLines($marker)).Count -eq $probeCount) '旧放宽参数必须明确拒绝；不得探测、选择或写地图'
        $r = Run-Map @('add', 'node', '-Path', $oldNode, '-Note', 'keep this registration', '-Prefer'); Assert ($r.code -eq 0) '重新验证只读测试候选失败'
        $offline = "$oldNode.offline"; [IO.File]::Move($oldNode, $offline)
        $before = & $snapshot
        $r = Run-Map @('find', 'node', '-Project', $roProject, '-Version', '16')
        Assert (-not $r.value.ok -and (& $snapshot) -eq $before) 'find 不得删除暂时离线的手工登记'
        foreach ($action in @('update', 'scan')) {
            $argsForAction = if ($action -eq 'update') { @('update', 'node') } else { @('scan') }
            $r = Run-Map $argsForAction
            $savedOffline = [IO.File]::ReadAllText($mapFile) | ConvertFrom-Json
            $kept = @($savedOffline.tools.node.candidates | Where-Object { $_.path -eq $oldNode -and $_.registered -and $_.userNote -eq 'keep this registration' })
            Assert ($r.value.ok -and $kept.Count -eq 1 -and $savedOffline.tools.node.preferredPath -eq $oldNode) "$action 必须保留离线登记、备注与偏好"
        }
        [IO.File]::Move($offline, $oldNode)
        $r = Run-Map @('update', 'node'); $r = Run-Map @('find', 'node', '-Project', $roProject, '-Version', '16', '-SkipScan')
        Assert ($r.value.ok -and $r.value.path -eq $oldNode) '离线路径恢复后可通过显式 update 重新验证'
        $roMise = Join-Path $roProject 'mise.toml'
        foreach ($declaration in @('tools = { node = "22" }', 'tools.node = "22"')) {
            [IO.File]::WriteAllText($roMise, $declaration, [Text.Encoding]::UTF8)
            $r = Run-Map @('find', 'node', '-Project', $roProject, '-SkipScan')
            Assert ($r.value.ok -and $r.value.requirement.version -eq '22' -and $r.value.path -eq $newNode) "顶层声明必须正确选择要求的版本：$declaration"
        }
        $roPython = Fake-Tool (Join-Path $scratch 'readonly-python') 'python' '3.12.1'
        $r = Run-Map @('add', 'python', '-Path', $roPython)
        [IO.File]::WriteAllText($roMise, "[tools]`nnode = [`n  `"22`",`n]`npython = `"3.12`"`n", [Text.Encoding]::UTF8)
        $r = Run-Map @('find', 'python', '-Project', $roProject, '-SkipScan')
        Assert ($r.value.ok -and $r.value.path -eq $roPython -and $r.value.requirement.version -eq '3.12') 'Node 多行声明不得阻止查询已声明的 Python'
        [IO.File]::Delete($roMise)
        $roGo = Fake-Tool (Join-Path $scratch 'readonly-go') 'go' '1.20.2'
        $r = Run-Map @('add', 'go', '-Path', $roGo)
        [IO.File]::WriteAllText((Join-Path $roProject '.tool-versions'), "golang 1.22`n", [Text.Encoding]::UTF8)
        $r = Run-Map @('find', 'go', '-Project', $roProject, '-SkipScan')
        Assert ($r.value.status -eq 'version_mismatch' -and $r.value.requirement.version -eq '1.22' -and -not $r.value.path) 'golang 声明必须约束 go，不能降级'
        # v2 旧地图可能把 python3 单独存为键；新的别名策略不能丢掉旧登记。
        $mapFile = Join-Path $scratch 'legacy-alias-map.json'
        $legacyPython = Fake-Tool (Join-Path $scratch 'legacy-python') 'runtime' '3.12.5'
        $r = Run-Map @('add', 'python', '-Path', $legacyPython, '-Note', 'legacy registration', '-Prefer'); Assert ($r.code -eq 0) '旧别名地图准备失败'
        $legacyMap = [IO.File]::ReadAllText($mapFile) | ConvertFrom-Json
        $legacyEntry = $legacyMap.tools.python
        $legacyMap.tools.PSObject.Properties.Remove('python')
        $legacyMap.tools | Add-Member -MemberType NoteProperty -Name 'python3' -Value $legacyEntry
        [IO.File]::WriteAllText($mapFile, ($legacyMap | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding $true))
        $r = Run-Map @('find', 'python3', '-Project', $roProject, '-SkipScan')
        Assert ($r.value.ok -and $r.value.path -eq $legacyPython) "旧 python3 键的已验证登记仍应可查询：$($r.output -join ' ')"
        $r = Run-Map @('scan')
        $legacyAfter = [IO.File]::ReadAllText($mapFile) | ConvertFrom-Json
        $legacyCandidates = @($legacyAfter.tools.python.candidates | Where-Object { $_.path -eq $legacyPython -and $_.userNote -eq 'legacy registration' })
        Assert ($r.value.ok -and $legacyCandidates.Count -eq 1 -and $legacyAfter.tools.python.preferredPath -eq $legacyPython) '重扫必须迁移旧别名登记及偏好'
        # 历史别名键保留以保护用户备注，状态计数仍须按工具与物理路径去重。
        $legacyOffline = "$legacyPython.offline"; [IO.File]::Move($legacyPython, $legacyOffline)
        $r = Run-Map @('scan')
        $status = Run-Map @('status')
        $expectedTools = @($legacyAfter.tools.PSObject.Properties.Name | ForEach-Object { if ($_ -eq 'python3') { 'python' } else { $_ } } | Sort-Object -Unique).Count
        Assert ($r.value.tools -eq $expectedTools) '扫描结果不得按历史别名重复统计工具'
        Assert ($status.value.deadCandidates -eq 1 -and $status.value.tools -eq $expectedTools) '别名重复键不得使失效候选或工具数量重复计数'
        $aliasDoctor = Run-Map @('doctor', '-Project', $roProject, '-Bundle')
        Assert ($aliasDoctor.value.bundle.map.tools -eq $expectedTools -and $aliasDoctor.value.unverifiedCandidates -eq 1 -and $aliasDoctor.value.bundle.unverifiedCandidates -eq 1) '诊断摘要中的工具与未验证候选也必须按路径去重'
        [IO.File]::Move($legacyOffline, $legacyPython)
        $r = Run-Map @('update', 'python')
        $r = Run-Map @('find', 'python3', '-Project', $roProject, '-SkipScan')
        Assert ($r.value.ok -and $r.value.path -eq $legacyPython) '旧别名离线恢复后应重新验证并保留偏好'
        $newPreferredPython = Fake-Tool (Join-Path $scratch 'legacy-python-new') 'runtime' '3.12.8'
        $r = Run-Map @('add', 'python', '-Path', $newPreferredPython, '-Prefer')
        $canonicalFind = Run-Map @('find', 'python', '-Project', $roProject, '-SkipScan')
        $aliasFind = Run-Map @('find', 'python3', '-Project', $roProject, '-SkipScan')
        $aliasSnapshot = [IO.File]::ReadAllText($mapFile) | ConvertFrom-Json
        Assert ($canonicalFind.value.path -eq $newPreferredPython -and $aliasFind.value.path -eq $newPreferredPython) '更新规范名称的偏好后，别名查询必须一致'
        Assert ($aliasSnapshot.tools.python3.preferredPath -eq $legacyPython) '解决别名偏好冲突不能删除历史记录'
        # Legacy maps may already contain environment-internal paths even
        # though new registrations and scans refuse to add them.
        foreach ($internalDir in @('.venv\Scripts', 'venv\Scripts', 'node_modules\bin', 'site-packages\bin')) {
            $mapFile = Join-Path $scratch ('legacy-internal-' + [guid]::NewGuid().ToString('N') + '.json')
            $originalTool = Fake-Tool (Join-Path $scratch ([guid]::NewGuid().ToString('N'))) 'internaltest' '1.2.3'
            $internalMarker = Join-Path $scratch ('internal-probes-' + [guid]::NewGuid().ToString('N') + '.txt')
            [IO.File]::WriteAllText($originalTool, "@echo off`r`necho probe>>`"$internalMarker`"`r`necho internaltest 1.2.3`r`n", [Text.Encoding]::ASCII)
            $r = Run-Map @('add', 'internaltest', '-Path', $originalTool)
            Assert ($r.value.ok -and $r.value.verification -eq 'verified') '环境内部旧地图夹具登记失败'
            $targetDir = Join-Path $scratch $internalDir; [void][IO.Directory]::CreateDirectory($targetDir)
            $internalTool = Join-Path $targetDir ('internaltest-' + [guid]::NewGuid().ToString('N') + '.cmd')
            [IO.File]::Move($originalTool, $internalTool)
            $internalMap = [IO.File]::ReadAllText($mapFile) | ConvertFrom-Json
            $internalMap.tools.internaltest.candidates[0].path = $internalTool
            [IO.File]::WriteAllText($mapFile, ($internalMap | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding $true))
            $internalProbeCount = @([IO.File]::ReadAllLines($internalMarker)).Count
            $r = Run-Map @('find', 'internaltest', '-Project', $roProject, '-SkipScan')
            Assert (-not $r.value.ok -and -not $r.value.path -and $r.value.candidates[0].verification -eq 'skipped') "旧地图里的环境内部文件不得作为工具返回：$internalDir"
            $r = Run-Map @('update', 'internaltest')
            $savedInternal = [IO.File]::ReadAllText($mapFile) | ConvertFrom-Json
            Assert ($r.value.ok -and $savedInternal.tools.internaltest.candidates[0].registered -and $savedInternal.tools.internaltest.candidates[0].verification -eq 'skipped' -and @([IO.File]::ReadAllLines($internalMarker)).Count -eq $internalProbeCount) "显式更新必须保留旧登记，但不能执行环境内部文件：$internalDir"
            $r = Run-Map @('scan')
            $savedInternal = [IO.File]::ReadAllText($mapFile) | ConvertFrom-Json
            Assert ($r.value.ok -and $savedInternal.tools.internaltest.candidates[0].registered -and $savedInternal.tools.internaltest.candidates[0].verification -eq 'skipped' -and @([IO.File]::ReadAllLines($internalMarker)).Count -eq $internalProbeCount) "并行扫描不能在预热时执行环境内部旧登记：$internalDir"
        }
        # 常见管理器的真实运行时在标准嵌套目录，不应因 shim 安全护栏被漏掉。
        $mapFile = Join-Path $scratch 'manager-layout-map.json'
        $env:VOLTA_HOME = Join-Path $scratch 'volta-home'; $env:FNM_DIR = Join-Path $scratch 'fnm-home'
        $env:SCOOP = Join-Path $scratch 'scoop-home'; $env:ASDF_DATA_DIR = Join-Path $scratch 'asdf-home'
        $managerPaths = @(
            (Fake-Tool (Join-Path $env:VOLTA_HOME 'tools\image\node\21.1.0') 'node' '21.1.0'),
            (Fake-Tool (Join-Path $env:FNM_DIR 'node-versions\v20.1.0\installation') 'node' '20.1.0'),
            (Fake-Tool (Join-Path $env:SCOOP 'apps\nodejs\current') 'node' '19.1.0'),
            (Fake-Tool (Join-Path $env:ASDF_DATA_DIR 'installs\nodejs\18.1.0\bin') 'node' '18.1.0')
        )
        $r = Run-Map @('add', 'node', '-Path', $oldNode)
        $r = Run-Map @('update', 'node')
        $managerMap = [IO.File]::ReadAllText($mapFile) | ConvertFrom-Json
        foreach ($managerPath in $managerPaths) {
            Assert (@($managerMap.tools.node.candidates | Where-Object { $_.path -eq $managerPath -and $_.verification -eq 'verified' -and -not $_.isShim }).Count -eq 1) "应发现并验证管理器标准目录中的真实运行时：$managerPath"
        }
        $env:VOLTA_HOME = ''; $env:FNM_DIR = ''; $env:SCOOP = ''; $env:ASDF_DATA_DIR = ''
    } finally { $mapFile = $oldMap; $mdFile = $oldMd; $env:PATH = $oldPath }
    # 并发登记：必须同时保留所有进程的结果。
    $processes = @()
    for ($i = 0; $i -lt 4; $i++) {
        $file = Fake-Tool (Join-Path $scratch "parallel-$i") "parallel-$i" '1.0.0'
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $hostExe
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$mapScript`" add parallel-$i -Path `"$file`" -MapFile `"$mapFile`" -Json"
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($psi)
        $processes += @{ process = $process; stdout = $process.StandardOutput.ReadToEndAsync(); stderr = $process.StandardError.ReadToEndAsync(); kind = 'add' }
    }
    # 受控并发回归：读取和原子替换同时进行，读取只能看到完整 JSON 快照。
    # 这是压力覆盖而非确定性证明旧实现必然失败。
    for ($i = 0; $i -lt 4; $i++) {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $hostExe
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$mapScript`" find node -Project `"$project`" -Version 22 -SkipScan -MapFile `"$mapFile`" -Json"
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($psi)
        $processes += @{ process = $process; stdout = $process.StandardOutput.ReadToEndAsync(); stderr = $process.StandardError.ReadToEndAsync(); kind = 'find' }
    }
    foreach ($job in $processes) {
        Assert ($job.process.WaitForExit(30000) -and $job.process.ExitCode -eq 0) "并发 $($job.kind) 失败：$($job.stderr.Result)"
        if ($job.kind -eq 'find') {
            $readResult = $job.stdout.Result | ConvertFrom-Json
            Assert ($readResult.ok -and $readResult.path -eq $two) '并发读取必须返回完整、已验证的快照'
        }
        $job.process.Dispose()
    }
    $saved = [IO.File]::ReadAllText($mapFile) | ConvertFrom-Json
    for ($i = 0; $i -lt 4; $i++) { Assert ($saved.tools.PSObject.Properties.Name -contains "parallel-$i") '并发更新丢失条目' }
    # P3：并行探测（-Throttle 4）与串行（-Throttle 1）扫同一个沙箱，去掉时间字段后地图必须逐字相同，启动次数也相同。
    $pathA = Join-Path $scratch 'path-a'; $pathB = Join-Path $scratch 'path-b'
    foreach ($tool in @('node', 'python', 'git', 'go', 'rg', 'cargo', 'java', 'uv')) { $null = Fake-Tool $pathA $tool '1.2.3' }
    foreach ($tool in @('node', 'python', 'git')) { $null = Fake-Tool $pathB $tool '4.5.6' }
    $savedPath = $env:PATH; $savedMap = $mapFile
    $env:PATH = "$pathA;$pathB"
    $runs = @{}
    foreach ($throttle in @(1, 4)) {
        $mapFile = Join-Path $scratch "throttle-$throttle.json"
        $r = Run-Map @('scan', '-Throttle', "$throttle"); Assert ($r.code -eq 0) "-Throttle $throttle 的 scan 失败"
        $runs[$throttle] = @{ text = Get-StableMapText $mapFile; launches = $r.value.probeStats.map.launches; candidates = @(([IO.File]::ReadAllText($mapFile) | ConvertFrom-Json).tools.PSObject.Properties | ForEach-Object { @($_.Value.candidates) } | Where-Object { $_.path }).Count }
    }
    $env:PATH = $savedPath; $mapFile = $savedMap
    Assert ($runs[1].candidates -ge 11) "沙箱里的 11 个假工具没有全部扫到：$($runs[1].candidates)"
    Assert ($runs[1].text -eq $runs[4].text) "并行与串行扫描的地图（去掉时间字段后）必须相同：`n$($runs[1].text)`n$($runs[4].text)"
    Assert ($runs[1].launches -eq $runs[4].launches) "并行与串行的探测启动次数必须相同：$($runs[1].launches) / $($runs[4].launches)"

    # 维护策略：独立临时地图，从未 setup 的状态开始。
    $policyMap = Join-Path $scratch 'maintenance-policy.json'
    $savedMapForPolicy = $mapFile
    $mapFile = $policyMap
    $r = Run-Map @('add', 'node', '-Path', $two)
    Assert ($r.value.ok) '维护策略测试的临时地图初始化失败'
    $r = Run-Map @('find', 'node', '-Project', $project, '-Version', '22', '-SkipScan')
    Assert ($r.value.ok -and $r.value.maintenance -and $r.value.maintenance.policy.autoUpdate -eq $false) '未 setup 时 find 必须返回 maintenance.policy，且不得预授权 autoUpdate'
    $r = Run-Map @('setup', '-Project', $project)
    Assert ($r.value.ok -and $r.value.maintenance.autoUpdate -and $r.value.maintenance.configured) 'setup 无参数时应默认预授权 autoUpdate'
    $r = Run-Map @('setup', '-Project', $project, '-NoAutoUpdate')
    Assert ($r.value.ok -and -not $r.value.maintenance.autoUpdate) 'setup -NoAutoUpdate 必须关闭自动 update'
    $savedPolicy = [IO.File]::ReadAllText($mapFile) | ConvertFrom-Json
    Assert ($savedPolicy.settings.maintenance.autoUpdate -eq $false) 'setup 必须把维护策略写入地图'
    $r = Run-Map @('find', 'node', '-Project', $project, '-Version', '999', '-SkipScan')
    Assert (-not $r.value.ok -and $r.value.maintenance.required -and $r.value.maintenance.actions[0].autoAllowed -eq $false) '关闭策略后维护动作不得自动执行'
    $r = Run-Map @('setup', '-Project', $project, '-AutoUpdate')
    Assert ($r.value.ok -and $r.value.maintenance.autoUpdate) 'setup -AutoUpdate 必须恢复自动 update'
    $r = Run-Map @('find', 'node', '-Project', $project, '-Version', '999', '-SkipScan')
    Assert ($r.value.maintenance.autoAllowed -and $r.value.maintenance.actions[0].autoAllowed) '开启策略后定向 update 应标记 autoAllowed'
    $r = Run-Map @('scan', '-Throttle', '1')
    $savedPolicy = [IO.File]::ReadAllText($mapFile) | ConvertFrom-Json
    Assert ($r.value.ok -and $savedPolicy.settings.maintenance.autoUpdate -eq $true -and $savedPolicy.settings.maintenance.configured -eq $true) 'scan 必须保留维护策略'
    $mapFile = $savedMapForPolicy

    [IO.File]::WriteAllText($mapFile, '{broken')
    $r = Run-Map @('add', 'node', '-Path', $one)
    Assert ($r.code -ne 0 -and $r.value.status -eq 'map_corrupt' -and [IO.File]::ReadAllText($mapFile) -eq '{broken') '损坏地图不能被当成空地图覆盖'
    Write-Host '[通过] 项目选择、探测护栏、持久化、查询缓存、并发、并行扫描与首次接入契约'
} finally {
    foreach ($name in $original.Keys) { [Environment]::SetEnvironmentVariable($name, $original[$name], 'Process') }
    $resolved = [IO.Path]::GetFullPath($scratch)
    $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
exit 0
