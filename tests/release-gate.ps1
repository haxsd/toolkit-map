$ErrorActionPreference = 'Stop'
$checks = @(
    'check-text.ps1',
    'check-data.ps1',
    'check-contract.ps1',
    'doctor-bundle.ps1',
    'quickstart-write.ps1',
    'release-package.ps1',
    'map-smoke.ps1',
    'map-contract.ps1',
    'version-contract.ps1',
    'install-contract.ps1',
    'download-contract.ps1',
    'scan-guards.ps1',
    'probe-cache.ps1',
    'parity.ps1'
)

$failed = New-Object System.Collections.Generic.List[string]
Write-Host ''
Write-Host ' 发布门禁：完整回归' -ForegroundColor White
foreach ($name in $checks) {
    Write-Host ''
    Write-Host " === $name ===" -ForegroundColor Cyan
    $global:LASTEXITCODE = 0
    try {
        & (Join-Path $PSScriptRoot $name)
    } catch {
        Write-Host "  [门禁异常] $name：$($_.Exception.Message)" -ForegroundColor Red
        Write-Host "::error::$name 抛出异常：$($_.Exception.Message)"
        $failed.Add($name)
        continue
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [门禁失败] $name 退出码 $LASTEXITCODE" -ForegroundColor Red
        Write-Host "::error::$name 退出码 $LASTEXITCODE"
        $failed.Add($name)
    }
}

Write-Host ''
if ($failed.Count -eq 0) {
    Write-Host ' 发布门禁通过' -ForegroundColor Green
    Write-Host ''
    exit 0
} else {
    Write-Host " 发布门禁失败：$($failed -join ', ')" -ForegroundColor Red
    Write-Host ''
    exit 1
}
