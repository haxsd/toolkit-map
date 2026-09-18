<#
.SYNOPSIS
  编码检查：保证 .ps1 带 UTF-8 BOM、.sh 不带 BOM。

.DESCRIPTION
  为什么必须有这一项：仓库里的 .ps1 含中文注释（UTF-8，无 BOM）。Windows PowerShell 5.1
  在没有 BOM 时按系统 ANSI 代码页读取脚本——英文系统上那是 cp1252，UTF-8 的连续字节会被
  解成 U+201C/U+201D 这类智能引号，而 PowerShell 把智能引号也当作字符串定界符，
  于是括号失配、脚本直接解析失败（实测：同一份文件 cp437 解析 0 错误、cp1252 报
  "Missing closing '}'"）。开发机是中文系统（cp936）时完全看不见这个问题。

  反向的坑是 .sh：带 BOM 会让 `#!/bin/sh` 变成 `#!/bin/sh`，shebang 失效。

  用法:
    .\tests\check-encodings.ps1          # 检查仓库里的脚本
    .\tests\check-encodings.ps1 -Fix     # 给缺失的 .ps1 补 BOM（.sh 的 BOM 只报告不自动删）
#>
[CmdletBinding()]
param([switch]$Fix)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent

$fail = 0
function Check {
    param([string]$What, [bool]$Ok, [string]$Hint = '')
    if ($Ok) { Write-Host "  [通过] $What" -ForegroundColor Green }
    else {
        Write-Host "  [失败] $What" -ForegroundColor Red
        if ($Hint) { Write-Host "         $Hint" -ForegroundColor DarkGray }
        Write-Host "::error::$What $(if ($Hint) { $Hint })"
        $script:fail++
    }
}

function Test-HasBom {
    param([string]$Path)
    $b = [System.IO.File]::ReadAllBytes($Path)
    return ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
}

function Add-Bom {
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path)   # 按 BOM 自动识别；无 BOM 时按 UTF-8 读
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($true)))
}

$ps1Files = @(Get-ChildItem -Path (Join-Path $repoRoot 'scripts'), (Join-Path $repoRoot 'tests') -Filter *.ps1 -File)
$shFiles  = @(Get-ChildItem -Path (Join-Path $repoRoot 'scripts'), (Join-Path $repoRoot 'tests') -Filter *.sh -File)

Write-Host ''
Write-Host ' 编码检查（脚本的文件编码）' -ForegroundColor White

foreach ($f in $ps1Files) {
    $hasBom = Test-HasBom $f.FullName
    if (-not $hasBom -and $Fix) {
        Add-Bom $f.FullName
        $hasBom = $true
        Write-Host "  [已修] 补上 UTF-8 BOM: $($f.Name)" -ForegroundColor Yellow
    }
    Check "$($f.Name) 带 UTF-8 BOM" $hasBom '没有 BOM 时，英文系统的 ANSI 代码页会把中文注释读坏（见脚本头部说明）'

    # 关键回归测试：把文件当成 cp1252 解码后再解析，必须零语法错误。
    # 这正是英文 Windows 上 PowerShell 5.1 的读法，也是唯一能拦住这类问题的方式。
    $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::GetEncoding(1252))
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errs)
    Check "$($f.Name) 在 cp1252 读法下也能解析" (@($errs).Count -eq 0) `
          ("解析错误: " + (@($errs) | Select-Object -First 1 | ForEach-Object { $_.Message }))
}

foreach ($f in $shFiles) {
    Check "$($f.Name) 不带 BOM" (-not (Test-HasBom $f.FullName)) 'BOM 会让 shebang 失效（#!/bin/sh）'
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host ' 全部通过' -ForegroundColor Green
    Write-Host ''
    exit 0
} else {
    Write-Host " 有 $fail 项失败" -ForegroundColor Red
    Write-Host ''
    exit 1
}
