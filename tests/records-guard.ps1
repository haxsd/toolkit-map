$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent

# 公开树只放源码、文档、模板、示例与测试。内部计划、交接、账户/真实环境信息
# 一律放私有记录仓库；这里检查当前树，历史例外由私有 sync-records 维护。
$forbidden = 'HANDOFF\.md$|BRANCH_ISOLATION\.md$|docs/plans/|docs/superpowers/|docs/quality-review-|devin-router-vendor-evidence|support/cursor-capture/|support/cursor-protocol-extractor/|docs/history/|docs/reviews/|docs/validation/|archive/legacy/'

$tracked = & git -C $repoRoot ls-files 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host '  [失败] 无法读取 Git 跟踪文件' -ForegroundColor Red
    exit 1
}

$hits = @($tracked | Select-String -Pattern $forbidden | ForEach-Object { $_.Line })
if ($hits.Count -gt 0) {
    Write-Host ''
    Write-Host ' 公开树出现内部资料：' -ForegroundColor Red
    $hits | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host ' 请移到私有记录仓库，不要留在公开仓库。' -ForegroundColor DarkGray
    exit 1
}

Write-Host ' 公开树边界检查通过' -ForegroundColor Green
exit 0
