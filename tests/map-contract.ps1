#Requires -Version 5.1
# 使用临时地图、假工具与假 census 验证公开契约；不安装工具，不读取本机地图。
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$hostExe = (Get-Process -Id $PID).Path
$scratch = [IO.Path]::GetFullPath((Join-Path $env:TEMP ('toolkit-map-contract-' + [guid]::NewGuid().ToString('N'))))
$original = @{}
foreach ($name in @('USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'MISE_DATA_DIR', 'MISE_SHIMS_DIR', 'MISE_CONFIG_FILE', 'MISE_CONFIG_DIR', 'XDG_CONFIG_HOME', 'TOOLCHAIN_ROOT', 'PATH')) { $original[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
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
try {
    [void][IO.Directory]::CreateDirectory($scratch)
    $scripts = Join-Path $scratch 'product\scripts'
    [void][IO.Directory]::CreateDirectory($scripts)
    foreach ($name in @('map.ps1', 'map-core.ps1', 'toolkit-common.ps1', 'tools.json')) { Copy-Item -LiteralPath (Join-Path (Join-Path $repo 'scripts') $name) -Destination $scripts }
    Copy-Item -LiteralPath (Join-Path $repo 'VERSION') -Destination (Join-Path $scratch 'product')
    $mapScript = Join-Path $scripts 'map.ps1'
    $mapFile = Join-Path $scratch 'map.json'
    $project = Join-Path $scratch 'project'
    $homeDir = Join-Path $scratch 'home'
    foreach ($dir in @($project, $homeDir, (Join-Path $homeDir '.config\mise'))) { [void][IO.Directory]::CreateDirectory($dir) }
    $env:USERPROFILE = $homeDir; $env:APPDATA = $homeDir; $env:LOCALAPPDATA = $homeDir
    $env:MISE_DATA_DIR = Join-Path $scratch 'custom-manager'
    $env:MISE_SHIMS_DIR = ''; $env:MISE_CONFIG_FILE = ''; $env:MISE_CONFIG_DIR = ''; $env:XDG_CONFIG_HOME = ''
    $env:TOOLCHAIN_ROOT = Join-Path $scratch 'warehouse'
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
    # probeStats 是附加字段：launches 必须是非负整数；假 census 没有 probeStats，census 部分按 0 计。
    $probeStats = $r.value.probeStats
    $probeLaunches = if ($probeStats) { $probeStats.launches } else { $null }
    Assert (($probeLaunches -is [int] -or $probeLaunches -is [long]) -and $probeLaunches -ge 0) "scan 结果必须带非负整数 probeStats.launches：$($r.output -join '`n')"
    Assert ($probeStats.census.launches -eq 0 -and ($probeStats.wallMs -is [int] -or $probeStats.wallMs -is [long]) -and $probeStats.wallMs -ge 0) "census 缺 probeStats 时应按 0 计，wallMs 为非负整数：$($r.output -join '`n')"
    $one = Fake-Tool (Join-Path $scratch 'node16') 'node' '16.20.2'
    $two = Fake-Tool (Join-Path $scratch 'node22') 'node' '22.23.2'
    $r = Run-Map @('add', 'node', '-Path', $one, '-Note', '手工登记保留', '-Prefer'); Assert ($r.code -eq 0) 'add 失败'
    $r = Run-Map @('add', 'node', '-Path', $two); Assert ($r.code -eq 0) '第二份 add 失败'
    [IO.File]::WriteAllText((Join-Path $homeDir '.config\mise\config.toml'), "[tools]`nnode = `"16`"`n")
    [IO.File]::WriteAllText((Join-Path $project 'mise.toml'), "[tools]`nnode = `"22`"`n")
    $r = Run-Map @('find', 'node', '-Project', $project, '-SkipScan')
    Assert ($r.code -eq 0 -and $r.value.path -eq $two -and $r.value.requirement.scope -eq 'project') "项目声明必须覆盖全局声明和用户偏好。退出码=$($r.code)，期望路径=$two，实际结果：$($r.output -join '`n')"
    $r = Run-Map @('find', 'node', '-Project', $project, '-Version', '20', '-SkipScan')
    Assert ($r.code -ne 0 -and $r.value.status -eq 'version_mismatch' -and -not $r.value.path) '缺少要求版本时不许降级'
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
    $r = Run-Map @('setup', '-Project', $project)
    Assert ($r.code -eq 0 -and -not $r.value.rulesChanged) 'setup 必须幂等'
    $r = Run-Map @('doctor', '-Project', $project)
    Assert ($r.code -eq 0 -and -not $r.value.agentVerified) 'doctor 应通过，并明确不能证明模型行为'
    $r = Run-Map @('install', 'rg@latest', '-WhatIf')
    Assert ($r.code -eq 0 -and $r.value.status -eq 'planned') 'latest WhatIf 不应联网'
    $r = Run-Map @('install', '../escape', '-Version', '1', '-Url', 'https://example.invalid/tool.zip', '-WhatIf')
    Assert ($r.code -ne 0 -and $r.value.status -eq 'invalid_argument') '安装参数不得越出仓库'
    $rg = Fake-Tool (Join-Path $env:TOOLCHAIN_ROOT 'ripgrep\15.0.0') 'rg' '15.0.0'
    $r = Run-Map @('find', 'ripgrep', '-Project', $project)
    Assert ($r.code -eq 0 -and $r.value.tool -eq 'rg' -and $r.value.path -eq $rg) '别名与旧仓库目录应可发现'
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
        $processes += @{ process = $process; stdout = $process.StandardOutput.ReadToEndAsync(); stderr = $process.StandardError.ReadToEndAsync() }
    }
    foreach ($job in $processes) {
        Assert ($job.process.WaitForExit(30000) -and $job.process.ExitCode -eq 0) "并发登记失败：$($job.stderr.Result)"
        $job.process.Dispose()
    }
    $saved = [IO.File]::ReadAllText($mapFile) | ConvertFrom-Json
    for ($i = 0; $i -lt 4; $i++) { Assert ($saved.tools.PSObject.Properties.Name -contains "parallel-$i") '并发更新丢失条目' }
    [IO.File]::WriteAllText($mapFile, '{broken')
    $r = Run-Map @('add', 'node', '-Path', $one)
    Assert ($r.code -ne 0 -and $r.value.status -eq 'map_corrupt' -and [IO.File]::ReadAllText($mapFile) -eq '{broken') '损坏地图不能被当成空地图覆盖'
    Write-Host '[通过] 项目选择、探测护栏、持久化、查询缓存、并发与首次接入契约'
} finally {
    foreach ($name in $original.Keys) { [Environment]::SetEnvironmentVariable($name, $original[$name], 'Process') }
    $resolved = [IO.Path]::GetFullPath($scratch)
    $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
exit 0
