#Requires -Version 5.1
# 真正执行暂存、解压、校验、版本验证与登记；下载器替换为本地 zip，不触网。
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$scratch = [IO.Path]::GetFullPath((Join-Path $env:TEMP ('toolkit-map-install-' + [guid]::NewGuid().ToString('N'))))
$oldRoot = $env:TOOLCHAIN_ROOT; $oldPath = $env:PATH
$oldInstallerEnv = @{}
foreach ($name in @('ProgramFiles', 'ProgramFiles(x86)', 'LOCALAPPDATA')) { $oldInstallerEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
function Assert { param([bool]$Ok, [string]$Message) if (-not $Ok) { throw $Message } }
function Make-Package {
    param([string]$Name, [string]$VersionText)
    $dir = Join-Path $scratch ('pkg-' + $Name)
    [void][IO.Directory]::CreateDirectory($dir)
    [IO.File]::WriteAllText((Join-Path $dir ($Name + '.cmd')), "@echo off`r`necho $Name $VersionText`r`nexit /b 0`r`n", [Text.Encoding]::ASCII)
    $zip = Join-Path $scratch ($Name + '.zip')
    Compress-Archive -LiteralPath $dir -DestinationPath $zip
    return $zip
}
try {
    [void][IO.Directory]::CreateDirectory($scratch)
    $env:TOOLCHAIN_ROOT = Join-Path $scratch 'warehouse'; $env:PATH = ''
    . (Join-Path $repo 'scripts\map.ps1') -Action help -MapFile (Join-Path $scratch 'map.json') -Json | Out-Null
    $Action = 'install'; $Url = 'https://example.invalid/test.zip'
    function Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing) Copy-Item -LiteralPath $script:Archive -Destination $OutFile }
    $script:Archive = Make-Package 'install-ok' '1.2.3'
    $Tool = 'install-ok'; $Version = '1.2.3'; $Sha256 = (Get-FileHash -LiteralPath $script:Archive -Algorithm SHA256).Hash
    $result = Invoke-Install
    Assert ($result.ok -and $result.verification -eq 'verified' -and [IO.File]::Exists($result.path)) 'portable 安装没有完成验证与登记'
    $saved = Read-Map
    Assert ($saved.tools['install-ok'].candidates.Count -eq 1) '安装结果未登记'
    $result = Invoke-Install
    Assert ($result.status -eq 'already_available' -and (Read-Map).tools['install-ok'].candidates.Count -eq 1) '重复安装仓库内已验证版本应复用且不重复登记'
    $Tool = 'bad-version'; $Version = '2.0.0'; $Sha256 = ''
    $script:Archive = Make-Package 'bad-version' '1.0.0'
    $failed = $false
    try { $null = Invoke-Install } catch { $failed = ($_.Exception.Data['code'] -eq 'version_mismatch') }
    Assert ($failed -and -not [IO.Directory]::Exists((Join-Path $env:TOOLCHAIN_ROOT 'bad-version\2.0.0'))) '版本不符时必须失败且不留下安装目录'
    $Tool = 'bad-hash'; $Version = '1.0.0'; $Sha256 = ('a' * 64)
    $script:Archive = Make-Package 'bad-hash' '1.0.0'
    $failed = $false
    try { $null = Invoke-Install } catch { $failed = ($_.Exception.Message -match 'SHA256') }
    Assert ($failed -and -not [IO.Directory]::Exists((Join-Path $env:TOOLCHAIN_ROOT 'bad-hash\1.0.0'))) '校验失败时不能安装'
    $Tool = 'missing-exe'; $Version = '1.0.0'; $Sha256 = ''
    $failed = $false
    try { $null = Invoke-Install } catch { $failed = ($_.Exception.Data['code'] -eq 'executable_missing') }
    Assert $failed '归档缺少可执行文件时不能报告成功'
    # 可执行文件可能依赖安装位置：暂存验证成功不代表移动后仍然可用。
    $Tool = 'relocation'; $Version = '1.0.0'
    $script:Archive = Make-Package 'relocation' '1.0.0'
    $relocationCmd = Join-Path $scratch 'pkg-relocation\relocation.cmd'
    [IO.File]::WriteAllText($relocationCmd, "@echo off`r`nsetlocal EnableDelayedExpansion`r`nset here=%~dp0`r`nif not `"!here:warehouse=!`"==`"!here!`" exit /b 1`r`necho relocation 1.0.0`r`nexit /b 0`r`n", [Text.Encoding]::ASCII)
    Compress-Archive -LiteralPath (Split-Path $relocationCmd -Parent) -DestinationPath $script:Archive -Force
    $failed = $false
    try { $null = Invoke-Install } catch { $failed = ($_.Exception.Data['code'] -eq 'probe_failed') }
    Assert ($failed -and -not [IO.Directory]::Exists((Join-Path $env:TOOLCHAIN_ROOT 'relocation\1.0.0'))) '移动后不可用必须失败并回滚目标目录'
    Assert (-not (Read-Map).tools.ContainsKey('relocation')) '失败副本不能登记到地图'
    $Tool = 'external'; $Version = '1.0.0'
    $script:Archive = Make-Package 'external' '1.0.0'
    $external = Join-Path $scratch 'pkg-external\external.cmd'
    $Path = $external
    $null = Invoke-Add
    $downloadCalls = 0
    function Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing) $script:downloadCalls++; throw '不应该下载' }
    $result = Invoke-Install
    Assert ($result.status -eq 'already_available' -and $result.path -eq $external -and $script:downloadCalls -eq 0) '已有合适副本必须复用，不重复下载'
    # winget 兜底：键名规范化与参数校验；只登记本次新出现的文件，同名旧文件不冒充；多个新文件不猜。
    # winget 调用与注册表 PATH 刷新替换为假实现，不触网、不改机器。
    $Url = ''; $Sha256 = ''; $Version = ''; $Via = 'winget'; $WingetId = ''
    $Tool = '../escape'; $failed = $false
    try { $null = Invoke-Install } catch { $failed = ($_.Exception.Data['code'] -eq 'invalid_argument') }
    Assert $failed 'winget 工具名不得包含路径'
    $Tool = 'wtool'; $WingetId = '--source'; $failed = $false
    try { $null = Invoke-Install } catch { $failed = ($_.Exception.Data['code'] -eq 'invalid_argument') }
    Assert $failed 'winget 包 ID 不得以 - 开头'
    $wingetDir = Join-Path $scratch 'winget-bin'; [void][IO.Directory]::CreateDirectory($wingetDir)
    [IO.File]::WriteAllText((Join-Path $wingetDir 'winget.cmd'), "@echo off`r`nexit /b 1`r`n", [Text.Encoding]::ASCII)
    $env:PATH = $wingetDir
    [Environment]::SetEnvironmentVariable('ProgramFiles', (Join-Path $scratch 'pf'), 'Process')
    [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $null, 'Process')
    [Environment]::SetEnvironmentVariable('LOCALAPPDATA', (Join-Path $scratch 'lad'), 'Process')
    $oldCopy = Join-Path $env:ProgramFiles 'Old\wtool.cmd'
    [void][IO.Directory]::CreateDirectory((Split-Path $oldCopy -Parent))
    [IO.File]::WriteAllText($oldCopy, "@echo off`r`necho wtool 0.9.0`r`nexit /b 0`r`n", [Text.Encoding]::ASCII)
    $longAgo = (Get-Date).ToUniversalTime().AddDays(-30)
    (Get-Item -LiteralPath $oldCopy).CreationTimeUtc = $longAgo; (Get-Item -LiteralPath $oldCopy).LastWriteTimeUtc = $longAgo
    function Get-InstallerRefreshedPath { return '' }
    function Invoke-WingetCommand {
        param([string]$Exe, [string[]]$Arguments)
        $script:WingetArgs = $Arguments
        foreach ($rel in $script:WingetNewFiles) {
            $file = Join-Path $env:ProgramFiles $rel
            [void][IO.Directory]::CreateDirectory((Split-Path $file -Parent))
            [IO.File]::WriteAllText($file, "@echo off`r`necho tool 1.0.0`r`nexit /b 0`r`n", [Text.Encoding]::ASCII)
        }
        return @{ exitCode = 0; output = @('installed') }
    }
    $Tool = 'WTool'; $WingetId = 'Vendor.WTool'; $script:WingetNewFiles = @('Vendor\WTool\wtool.cmd')
    $result = Invoke-Install
    $expected = Join-Path $env:ProgramFiles 'Vendor\WTool\wtool.cmd'
    Assert ($result.ok -and $result.tool -eq 'wtool' -and @($result.installed).Count -eq 1 -and @($result.installed)[0] -eq $expected) "winget 应登记本次新装的文件：$($result | ConvertTo-Json -Depth 5 -Compress)"
    Assert ($script:WingetArgs -contains 'Vendor.WTool' -and $script:WingetArgs -contains '--exact') 'winget 参数应使用给定包 ID 精确匹配'
    $saved = Read-Map
    Assert (@($saved.tools.Keys) -ccontains 'wtool' -and @($saved.tools.Keys) -cnotcontains 'WTool') '地图键必须规范化为小写（地图哈希表不区分大小写，按原始键名区分）'
    Assert (@($saved.tools['wtool'].candidates | Where-Object { $_.path -eq $oldCopy }).Count -eq 0) '安装前就存在的同名文件不能登记成 winget 安装'
    $Tool = 'wtool2'; $WingetId = 'Vendor.WTool2'; $script:WingetNewFiles = @('A\wtool2.cmd', 'B\wtool2.cmd')
    $failed = $false
    try { $null = Invoke-Install } catch { $failed = ($_.Exception.Data['code'] -eq 'installed_ambiguous') }
    Assert ($failed -and -not (Read-Map).tools.ContainsKey('wtool2')) '多个新文件时不能猜测登记'
    Assert ($env:PATH -eq $wingetDir) 'winget 分支结束后必须恢复 PATH'
    $Via = ''
    Write-Host '[通过] portable 安装暂存、校验、版本验证、失败回滚、已有副本复用与 winget 兜底登记'
} finally {
    $env:TOOLCHAIN_ROOT = $oldRoot; $env:PATH = $oldPath
    foreach ($name in $oldInstallerEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $oldInstallerEnv[$name], 'Process') }
    $resolved = [IO.Path]::GetFullPath($scratch)
    $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
exit 0
