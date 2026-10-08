#Requires -Version 5.1
# 下载完整性与证书重试的契约：网络调用全部替换为假实现，不触网、不写机器设置。
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$scratch = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('toolkit-map-download-' + [guid]::NewGuid().ToString('N'))))
$fail = 0
function Check {
    param([string]$What, [bool]$Ok)
    if (-not $Ok) { Write-Host "  [失败] $What"; Write-Host "::error::$What"; $script:fail++ }
}
function Get-ErrorCode { param([scriptblock]$Block) try { $null = & $Block; return 'no_error' } catch { if ($_.Exception.Data['code']) { return $_.Exception.Data['code'] } return $_.Exception.Message } }
$oldRevocation = [Net.ServicePointManager]::CheckCertificateRevocationList
$oldRoot = $env:TOOLCHAIN_ROOT; $oldPath = $env:PATH
try {
    [void][IO.Directory]::CreateDirectory($scratch)
    . (Join-Path (Join-Path $repo 'scripts') 'map.ps1') -Action help -MapFile (Join-Path $scratch 'map.json') -Json | Out-Null
    $Json = $true

    # ---------- 1. 证书重试的触发条件 ----------
    $trust = New-Object System.Net.WebException 'The underlying connection was closed: Could not establish trust relationship for the SSL/TLS secure channel.'
    $generic = New-Object System.Net.WebException 'The SSL connection could not be established, see inner exception. certificate name mismatch'
    $script:calls = 0
    $failingTrust = { $script:calls++; throw $trust }
    $isDesktop = ($PSVersionTable.PSEdition -ne 'Core')
    [Net.ServicePointManager]::CheckCertificateRevocationList = $true
    Check "信任关系错误且开启吊销检查时，仅 5.1 重试（当前 $($PSVersionTable.PSEdition)）" ((Test-RevocationRetryApplicable (New-Object System.Management.Automation.ErrorRecord $trust, 'x', 'NotSpecified', $null)) -eq $isDesktop)
    Check '笼统的 SSL/certificate 错误不触发重试' (-not (Test-RevocationRetryApplicable (New-Object System.Management.Automation.ErrorRecord $generic, 'x', 'NotSpecified', $null)))
    $script:calls = 0
    $null = Get-ErrorCode { Invoke-NetRetry -What '测试' -Action $failingTrust 2>$null }
    Check "开启吊销检查时重试次数符合宿主（调用 $script:calls 次）" ($script:calls -eq $(if ($isDesktop) { 2 } else { 1 }))
    Check '重试结束后恢复吊销检查设置' ([Net.ServicePointManager]::CheckCertificateRevocationList -eq $true)
    [Net.ServicePointManager]::CheckCertificateRevocationList = $false
    $script:calls = 0
    $null = Get-ErrorCode { Invoke-NetRetry -What '测试' -Action $failingTrust }
    Check "吊销检查本来就关着时不重试（调用 $script:calls 次）" ($script:calls -eq 1)
    $script:calls = 0
    $null = Get-ErrorCode { Invoke-NetRetry -What '测试' -Action { $script:calls++; throw (New-Object System.Net.WebException '(404) Not Found') } }
    Check '非证书错误不重试' ($script:calls -eq 1)

    # ---------- 2. 校验文件解析 ----------
    $hashA = 'a' * 64; $hashB = 'B' * 64
    Check 'checksums.txt 按文件名取值' ((Get-ChecksumFromText "$hashA  other.zip`n$hashB  tool_1.0_windows_amd64.zip`n" 'tool_1.0_windows_amd64.zip') -eq $hashB.ToLowerInvariant())
    Check '带 * 与路径的 sha256sum 行' ((Get-ChecksumFromText "$hashA *dist/tool.zip" 'tool.zip') -eq $hashA)
    Check '只有一个哈希的 .sha256 文件' ((Get-ChecksumFromText "$hashA`r`n" 'tool.zip') -eq $hashA)
    Check 'CertUtil -hashfile 输出' ((Get-ChecksumFromText "SHA256 hash of tool.zip:`r`n$hashB`r`nCertUtil: -hashfile command completed successfully.`r`n" 'tool.zip') -eq $hashB.ToLowerInvariant())
    Check 'CertUtil 输出的文件名不符时不取' ((Get-ChecksumFromText "SHA256 hash of other.zip:`r`n$hashB`r`nCertUtil: -hashfile command completed successfully.`r`n" 'tool.zip') -eq '')
    Check '找不到文件名时不猜' ((Get-ChecksumFromText "$hashA  a.zip`n$hashB  b.zip" 'c.zip') -eq '')

    # ---------- 3. 官方 SHA256 的来源 ----------
    $script:restCalls = New-Object System.Collections.Generic.List[string]
    $script:release = $null
    $script:sumText = ''
    function Invoke-RestMethod {
        param($Uri, $Headers, $TimeoutSec)
        $script:restCalls.Add("$Uri")
        if ("$Uri" -like 'https://api.github.com/*') { return $script:release }
        return $script:sumText
    }
    $recipe = @{ repo = 'owner/tool'; tag = 'v{ver}'; asset = 'tool-{ver}.zip'; checksums = '{asset}.sha256' }
    $script:release = [pscustomobject]@{ assets = @([pscustomobject]@{ name = 'tool-1.0.0.zip'; digest = "sha256:$hashB"; browser_download_url = 'https://example.invalid/tool-1.0.0.zip' }) }
    $r = Resolve-RecipeSha256 -Recipe $recipe -Version '1.0.0' -Tag 'v1.0.0' -Asset 'tool-1.0.0.zip'
    Check 'GitHub 资产 digest 优先' ($r.source -eq 'github-asset-digest' -and $r.sha256 -eq $hashB.ToLowerInvariant() -and $script:restCalls[0] -eq 'https://api.github.com/repos/owner/tool/releases/tags/v1.0.0')
    $script:release = [pscustomobject]@{ assets = @(
        [pscustomobject]@{ name = 'tool-1.0.0.zip'; digest = $null; browser_download_url = 'https://example.invalid/tool-1.0.0.zip' },
        [pscustomobject]@{ name = 'tool-1.0.0.zip.sha256'; digest = $null; browser_download_url = 'https://example.invalid/tool-1.0.0.zip.sha256' }) }
    $script:sumText = "$hashA  tool-1.0.0.zip"
    $r = Resolve-RecipeSha256 -Recipe $recipe -Version '1.0.0' -Tag 'v1.0.0' -Asset 'tool-1.0.0.zip'
    Check '没有 digest 时用上游校验文件' ($r.source -eq 'upstream-checksums' -and $r.sha256 -eq $hashA)
    $noSums = @{ repo = 'owner/tool'; tag = 'v{ver}'; asset = 'tool-{ver}.zip' }
    Check '都没有时返回空，由调用方拒绝' ($null -eq (Resolve-RecipeSha256 -Recipe $noSums -Version '1.0.0' -Tag 'v1.0.0' -Asset 'tool-1.0.0.zip'))
    Check '发布里没有该资产时失败' ((Get-ErrorCode { Resolve-RecipeSha256 -Recipe $recipe -Version '1.0.0' -Tag 'v1.0.0' -Asset 'missing.zip' }) -eq 'asset_missing')
    $script:restCalls.Clear()
    $r = Resolve-RecipeSha256 -Recipe @{ url = 'https://example.invalid/x.zip'; sha256 = $hashB } -Version '' -Tag '' -Asset ''
    Check '配方钉死的值不联网' ($r.source -eq 'recipe' -and $script:restCalls.Count -eq 0)

    # ---------- 4. 内置配方 ----------
    $adb = $Recipes['adb']
    Check 'adb 使用带版本号的官方地址并钉死 SHA256' ("$($adb.url)" -match 'platform-tools_r\d+(\.\d+)+-win\.zip$' -and "$($adb.url)" -match [regex]::Escape("r$($adb.version)-") -and "$($adb.sha256)" -match '^[0-9a-f]{64}$' -and "$($adb.sha1)" -match '^[0-9a-f]{40}$')
    foreach ($name in @($Recipes.Keys)) {
        $item = $Recipes[$name]
        Check "配方 $name 要么钉死 SHA256，要么来自 GitHub 发布" ([bool]$item.sha256 -or [bool]$item.repo)
    }
    # 安装入口：拒绝绕过固定版本；WhatIf 不联网并声明需要完整性校验
    $Action = 'install'; $Url = ''; $Sha256 = ''; $Via = ''; $WhatIf = $true
    $Tool = 'adb@36.0.0'; $Version = ''
    Check 'adb 配方之外的版本返回 version_unavailable' ((Get-ErrorCode { Invoke-Install }) -eq 'version_unavailable')
    $script:restCalls.Clear()
    $Tool = 'adb'
    $plan = Invoke-Install
    Check 'adb WhatIf 给出钉死版本与地址且不联网' ($plan.status -eq 'planned' -and $plan.version -eq $adb.version -and $plan.url -eq $adb.url -and $plan.integrity -eq 'required' -and $script:restCalls.Count -eq 0)
    $Tool = 'fd@10.5.0'
    $plan = Invoke-Install
    Check 'GitHub 配方 WhatIf 不联网' ($plan.status -eq 'planned' -and $plan.integrity -eq 'required' -and $script:restCalls.Count -eq 0)
    # 取不到官方值时拒绝下载（不调用下载器）
    $WhatIf = $false
    $script:downloads = 0
    function Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing) $script:downloads++; throw '不应该下载' }
    $env:TOOLCHAIN_ROOT = Join-Path $scratch 'warehouse'
    $env:PATH = ''
    $Recipes['fake'] = $noSums
    $script:release = [pscustomobject]@{ assets = @([pscustomobject]@{ name = 'tool-9.9.9.zip'; digest = $null; browser_download_url = 'https://example.invalid/tool-9.9.9.zip' }) }
    $Tool = 'fake@9.9.9'
    Check '取不到官方 SHA256 时返回 checksum_unavailable 且不下载' ((Get-ErrorCode { Invoke-Install }) -eq 'checksum_unavailable' -and $script:downloads -eq 0)
    $script:release = [pscustomobject]@{ assets = @([pscustomobject]@{ name = 'tool-9.9.9.zip'; digest = "sha256:$hashB"; browser_download_url = 'https://example.invalid/tool-9.9.9.zip' }) }
    $Sha256 = $hashA
    Check '-Sha256 与官方值冲突时返回 checksum_conflict 且不下载' ((Get-ErrorCode { Invoke-Install }) -eq 'checksum_conflict' -and $script:downloads -eq 0)
} finally {
    $env:TOOLCHAIN_ROOT = $oldRoot; $env:PATH = $oldPath
    [Net.ServicePointManager]::CheckCertificateRevocationList = $oldRevocation
    if ([IO.Directory]::Exists($scratch)) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}
if ($fail -eq 0) { Write-Host "[通过] 下载完整性与证书重试（PowerShell $($PSVersionTable.PSVersion)）"; exit 0 }
Write-Host " 有 $fail 项失败"
exit 1
