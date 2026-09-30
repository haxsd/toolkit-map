#Requires -Version 5.1
# 真正执行暂存、解压、校验、版本验证与登记；下载器替换为本地 zip，不触网。
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$scratch = Join-Path $env:TEMP ('toolkit-map-install-' + [guid]::NewGuid().ToString('N'))
$oldRoot = $env:TOOLCHAIN_ROOT; $oldPath = $env:PATH
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
    $Tool = 'external'; $Version = '1.0.0'
    $script:Archive = Make-Package 'external' '1.0.0'
    $external = Join-Path $scratch 'pkg-external\external.cmd'
    $Path = $external
    $null = Invoke-Add
    $downloadCalls = 0
    function Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing) $script:downloadCalls++; throw '不应该下载' }
    $result = Invoke-Install
    Assert ($result.status -eq 'already_available' -and $result.path -eq $external -and $script:downloadCalls -eq 0) '已有合适副本必须复用，不重复下载'
    Write-Host '[通过] portable 安装暂存、校验、版本验证、失败回滚与已有副本复用'
} finally {
    $env:TOOLCHAIN_ROOT = $oldRoot; $env:PATH = $oldPath
    $resolved = [IO.Path]::GetFullPath($scratch)
    $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
exit 0
