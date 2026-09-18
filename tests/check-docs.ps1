<#
.SYNOPSIS
  文档检查：文档保持单语（中文），所有相对链接都能解析到真实的文件与标题。

.DESCRIPTION
  为什么必须有这一项：文档出错的成本很低——搬动、改名之后留下一堆指向不存在文件的链接，
  或者不知不觉又冒出中英两份互相漂移。这两种问题在本地都没有任何症状，只有别人打开仓库时
  才会暴露。

  检查两类问题：
    · 单语：不允许出现 *.zh-CN.md（改名、新增文档时容易顺手复制出第二份）
    · 链接：所有相对链接（含 #锚点）必须指向仓库内真实存在的文件与标题

  锚点比对刻意宽松（只比较字母与数字，忽略连字符、下划线、标点的差异）：
  GitHub 的 slug 规则会随标点和内联代码变化，这里只判断"那个标题是否存在"，
  宁可漏报也不要制造假警报。

.EXAMPLE
  .\tests\check-docs.ps1
#>
[CmdletBinding()]
param()

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

# 需要检查的 Markdown：仓库根目录 + docs/ + .github/（后者将来放 ISSUE 模板之类也一并覆盖）
function Get-MarkdownFiles {
    $dirs = @($repoRoot, (Join-Path $repoRoot 'docs'), (Join-Path $repoRoot '.github'))
    $out = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { continue }
        Get-ChildItem -LiteralPath $d -Filter '*.md' -File | ForEach-Object { $out.Add($_) }
    }
    return $out
}

# 宽松归一化：只保留字母与数字，用于比对锚点与标题（避免因标点规则不同产生假警报）
function Get-LooseKey {
    param([string]$Text)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToLowerInvariant().ToCharArray()) {
        if ([char]::IsLetterOrDigit($ch)) { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

# 标题是否存在（把每个 ATX 标题按宽松规则归一化后比对）
function Test-Anchor {
    param([string]$Path, [string]$Anchor)
    $want = Get-LooseKey $Anchor
    if (-not $want) { return $true }
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ($line -match '^#{1,6}\s+(.+?)\s*#*\s*$') {
            if ((Get-LooseKey $matches[1]) -eq $want) { return $true }
        }
    }
    return $false
}

# 文档单语（中文）：消费方是 agent 与使用者自己，同时维护中英两份只会互相漂移。
# 这里反向检查"没有 .zh-CN.md 回潮"——新增或改名文档时最容易顺手复制出第二份。
$docs = @(Get-MarkdownFiles)
$zhSuffix = '.zh-CN.md'

Write-Host ''
Write-Host ' 文档检查（单语与链接）' -ForegroundColor White

# ---------- 1. 单语 ----------
foreach ($f in $docs) {
    if ($f.Name -like "*$zhSuffix") {
        Check "$($f.Name) 不该存在" $false '文档已改为单语：请把内容合并进主文件后删除它'
    }
}

# ---------- 2. 相对链接与锚点 ----------
# 行内链接与图片：![alt](target)、[text](target "title")
$linkRe = [regex]'!?\[[^\]]*\]\(\s*([^)\s]+)'
$links = 0
foreach ($f in $docs) {
    $text = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
    foreach ($m in $linkRe.Matches($text)) {
        $target = $m.Groups[1].Value.Trim()
        # 外链、mailto、纯锚点不检查
        if ($target -match '^(https?:|mailto:|tel:|#)') { continue }

        $path = $target
        $anchor = ''
        $hash = $target.IndexOf('#')
        if ($hash -ge 0) {
            $path = $target.Substring(0, $hash)
            $anchor = $target.Substring($hash + 1)
        }
        if (-not $path) { continue }
        $links++

        $full = Join-Path $f.DirectoryName $path
        if (-not (Test-Path -LiteralPath $full)) {
            Check "$($f.Name) 链接 $target" $false '目标文件不存在（改名或移动后忘了同步）'
            continue
        }
        if ($anchor -and -not (Test-Anchor -Path $full -Anchor $anchor)) {
            Check "$($f.Name) 锚点 $target" $false '目标文件里没有这个标题'
        }
    }
}

Write-Host "  已检查 $($docs.Count) 个文档、$links 条相对链接" -ForegroundColor DarkGray
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
