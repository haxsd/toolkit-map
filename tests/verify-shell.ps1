<#
.SYNOPSIS
  用本机真正可用的 bash 给仓库里的 .sh 脚本做语法校验。

.DESCRIPTION
  要解决的问题：Windows 上 `bash` 通常解析到 C:\WINDOWS\system32\bash.exe —— WSL 的
  转发壳。没装 WSL 发行版时，它会以
      execvpe(/bin/bash) failed: No such file or directory
  退出，看起来像脚本本身有语法错误，其实和脚本无关。结果是仓库里的 .sh 从来没人验证，
  而它们和 .ps1 是同一套设计的两个实现，长期不验证必然漂移。

  本脚本按 Git Bash → 容器 的顺序找一个真正的 bash，对每个 .sh 执行 `bash -n`：
  -n 只做语法解析、不执行，所以对 bootstrap.sh 这种有副作用的脚本也安全。

.PARAMETER Targets
  要校验的文件或目录，默认为仓库的 scripts 与 tests 两个目录。

.EXAMPLE
  .\tests\verify-shell.ps1
  校验 scripts 与 tests 下所有 .sh。

.EXAMPLE
  .\tests\verify-shell.ps1 -Targets .\scripts\census.sh
  只校验一个文件。
#>
[CmdletBinding()]
param([string[]]$Targets = @())

$ErrorActionPreference = 'Stop'

# 1) 找一个真正能用的 bash。Git Bash 的默认安装路径优先——
#    它不依赖 PATH 里那个可能指向 WSL 转发壳的 bash。
$gitBashCandidates = @(
    'C:\Program Files\Git\bin\bash.exe',
    'C:\Program Files (x86)\Git\bin\bash.exe',
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
)
$bash = $gitBashCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

# 2) 没有 Git Bash 就退回容器。容器里的 bash 一定是真的，
#    但要把仓库挂进去，路径里的反斜杠和空格交给 docker 处理。
$useDocker = $false
if (-not $bash) {
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $useDocker = $true
    } else {
        Write-Host '找不到可用的 bash（既没有 Git Bash，也没有 docker）。' -ForegroundColor Yellow
        Write-Host 'PATH 里的 bash 可能是 WSL 的转发壳，它可以被 Get-Command 找到但执行会失败。' -ForegroundColor DarkGray
        exit 2
    }
}

# 3) 收集目标文件
if ($Targets.Count -eq 0) {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $Targets = @(Join-Path $repoRoot 'scripts'), (Join-Path $repoRoot 'tests')
}

$files = New-Object System.Collections.Generic.List[string]
foreach ($t in $Targets) {
    if (Test-Path -LiteralPath $t -PathType Container) {
        Get-ChildItem -LiteralPath $t -Filter '*.sh' -File | ForEach-Object { $files.Add($_.FullName) }
    } elseif (Test-Path -LiteralPath $t -PathType Leaf) {
        $files.Add((Resolve-Path -LiteralPath $t).Path)
    } else {
        Write-Host "跳过不存在的路径: $t" -ForegroundColor DarkYellow
    }
}

if ($files.Count -eq 0) {
    Write-Host '没有找到需要校验的 .sh 文件。' -ForegroundColor DarkYellow
    exit 0
}

Write-Host ''
Write-Host ' shell 脚本语法校验（bash -n，只解析不执行）' -ForegroundColor White
Write-Host " 校验器: $(if ($useDocker) { 'docker 容器里的 bash' } else { $bash })" -ForegroundColor DarkGray

$failed = 0
foreach ($f in $files) {
    $name = Split-Path $f -Leaf
    if ($useDocker) {
        # 挂载仓库根目录，容器内用相对路径调用，避免 Windows 路径格式问题
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $rel = $f.Substring($repoRoot.Length).TrimStart('\') -replace '\\', '/'
        $out = & docker run --rm -v "${repoRoot}:/w" -w /w bash:latest bash -n "/w/$rel" 2>&1
    } else {
        $out = & $bash -n $f 2>&1
    }
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK]   $name" -ForegroundColor Green
    } else {
        $failed++
        Write-Host "  [失败] $name" -ForegroundColor Red
        foreach ($line in $out) { Write-Host "         $line" -ForegroundColor DarkGray }
    }
}

Write-Host ''
if ($failed -eq 0) {
    Write-Host " 全部通过（$($files.Count) 个文件）" -ForegroundColor Green
    exit 0
} else {
    Write-Host " 有 $failed 个文件未通过" -ForegroundColor Red
    exit 1
}
