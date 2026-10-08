# 共享的发现护栏与声明读取。只读，不执行管理器或 shim。
function Get-ToolkitNormalizedPath {
    param([string]$Value)
    if (-not $Value) { return '' }
    return ([IO.Path]::GetFullPath($Value.Trim().Trim('"')) -replace '/', '\').TrimEnd('\').ToLowerInvariant()
}

function Test-ToolkitUnderRoot {
    param([string]$Value, [string]$Root)
    if (-not $Value -or -not $Root) { return $false }
    try {
        $p = Get-ToolkitNormalizedPath $Value
        $r = Get-ToolkitNormalizedPath $Root
        return ($p -eq $r -or $p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase))
    } catch { return $false }
}

function Test-ToolkitShimPath {
    param([string]$Value)
    $p = $Value -replace '\\', '/'
    # shims 是间接层；目录名判断也覆盖非默认的 mise/asdf/pyenv 数据目录。
    if ($p -match '(?i)/shims/') { return $true }
    if ([IO.Path]::GetFileName($Value) -match '(?i)^(node|python|java)[-_]?v?\d.*\.(cmd|bat|ps1|sh)$') { return $true }
    foreach ($root in @($env:MISE_SHIMS_DIR, $env:VOLTA_HOME)) {
        if ($root -and (Test-ToolkitUnderRoot $Value $root)) { return $true }
    }
    if ($env:USERPROFILE -and (Test-ToolkitUnderRoot $Value (Join-Path $env:USERPROFILE '.volta\bin'))) { return $true }
    return $false
}

# 脚本型启动器（npm/npx/pnpm/yarn/corepack，含 npm22 这类约定名）本身不是 shim，
# 但执行它时会再去调用 node：npm.cmd 与 Unix 的 sh 启动器优先用同目录的 node，没有才走 PATH；
# `#!/usr/bin/env node` 直接走 PATH。PATH 上的 node 恰好是 shim 时，探测启动器版本
# 就等于执行了 shim。与 census.sh 的 probe_safe 保持同一套规则。
$script:ToolkitNodeLauncherPattern = '^(npm|npx|pnpm|pnpx|yarn|yarnpkg|corepack)([-_]?v?\d+(\.\d+){0,3})?$'

function Find-ToolkitPathCommand {
    param([string]$Name)
    if (-not $Name) { return '' }
    $exts = @('')
    if ([IO.Path]::DirectorySeparatorChar -eq '\') {
        $exts = @("$env:PATHEXT" -split ';' | Where-Object { $_ })
        if (-not $exts.Count) { $exts = @('.com', '.exe', '.bat', '.cmd') }
        if ([IO.Path]::GetExtension($Name)) { $exts = @('') + $exts }
    }
    foreach ($raw in ("$env:PATH" -split [regex]::Escape([string][IO.Path]::PathSeparator))) {
        $dir = $raw.Trim().Trim('"')
        if (-not $dir) { continue }
        foreach ($ext in $exts) {
            try { $file = Join-Path $dir ($Name + $ext) } catch { continue }
            if ([IO.File]::Exists($file)) { return $file }
        }
    }
    return ''
}

function Get-ToolkitShebang {
    # 只读前 256 字节；不是 #! 脚本时返回空串。
    param([string]$Path)
    $count = 0
    $buffer = New-Object byte[] 256
    try {
        $stream = [IO.File]::OpenRead($Path)
        try { $count = $stream.Read($buffer, 0, $buffer.Length) } finally { $stream.Dispose() }
    } catch { return '' }
    if ($count -lt 3 -or $buffer[0] -ne 0x23 -or $buffer[1] -ne 0x21) { return '' }
    return (([Text.Encoding]::UTF8.GetString($buffer, 2, $count - 2) -split "`r?`n")[0]).Trim()
}

function Test-ToolkitProbeSafe {
    # 执行该文件做版本探测是否安全：自身不是 shim，#! 解释器（env 按 PATH 解析）不是 shim，
    # node 启动器实际会用的 node 也必须安全。解析不出解释器时宁可不执行。
    param([string]$Path, [int]$Depth = 0)
    if (-not $Path -or $Depth -gt 3 -or (Test-ToolkitShimPath $Path)) { return $false }
    $shebang = Get-ToolkitShebang $Path
    $isScript = [bool]$shebang -or ([IO.Path]::GetExtension($Path).ToLowerInvariant() -in @('.cmd', '.bat', '.ps1', '.sh'))
    if ($shebang) {
        $words = @($shebang -split '\s+' | Where-Object { $_ })
        if (-not $words.Count) { return $false }
        $interpreter = $words[0]
        if ([IO.Path]::GetFileName($interpreter) -eq 'env') {
            $rest = @($words | Select-Object -Skip 1 | Where-Object { $_ -notmatch '^-' -and $_ -notmatch '=' })
            $interpreter = if ($rest.Count) { Find-ToolkitPathCommand $rest[0] } else { '' }
        }
        if (-not (Test-ToolkitProbeSafe $interpreter ($Depth + 1))) { return $false }
    }
    if ($isScript -and [IO.Path]::GetFileNameWithoutExtension($Path) -match $script:ToolkitNodeLauncherPattern) {
        $node = ''
        $dir = Split-Path $Path -Parent
        foreach ($leaf in @('node.exe', 'node')) {
            $sibling = Join-Path $dir $leaf
            if ([IO.File]::Exists($sibling)) { $node = $sibling; break }
        }
        if (-not $node) { $node = Find-ToolkitPathCommand 'node' }
        if (-not (Test-ToolkitProbeSafe $node ($Depth + 1))) { return $false }
    }
    return $true
}

function Get-ToolkitCanonicalName {
    param([string]$Name)
    if ($script:ToolCatalog) {
        foreach ($key in $script:ToolCatalog.Keys) {
            if ($script:ToolCatalog[$key].aliases -contains $Name.ToLowerInvariant()) { return $key }
        }
    }
    switch ($Name.ToLowerInvariant()) {
        'nodejs' { return 'node' }
        'ripgrep' { return 'rg' }
        default { return $Name.ToLowerInvariant() }
    }
}

function Read-ToolkitDeclaredTools {
    param([string]$File)
    $tools = @{}
    $unsupported = New-Object System.Collections.Generic.List[string]
    $base = [IO.Path]::GetFileName($File)
    $text = [IO.File]::ReadAllText($File)
    if ($base -eq 'package.json') {
        $package = $text | ConvertFrom-Json
        if ($package.engines.node) { $tools.node = "$($package.engines.node)" }
    } elseif ($base -in @('.nvmrc', '.node-version', '.python-version')) {
        $name = if ($base -eq '.python-version') { 'python' } else { 'node' }
        $tools[$name] = $text.Trim()
    } else {
        $inTools = $false
        foreach ($line in ($text -split "`r?`n")) {
            $t = $line.Trim()
            if (-not $t -or $t.StartsWith('#')) { continue }
            if ($base -eq '.tool-versions') {
                if ($t -match '^(\S+)\s+(.+?)(?:\s+#.*)?$') {
                    $name = Get-ToolkitCanonicalName $Matches[1]
                    if ($name -eq 'python3') { $name = 'python' }
                    $tools[$name] = ($Matches[2] -replace '\s+', ',')
                }
                continue
            }
            if ($t -match '^\[\[?\s*(.+?)\s*\]\]?') {
                $section = $Matches[1]
                $inTools = ($section -match '^(tools|"tools"|''tools'')$')
                if ($section -match '^(?:tools|"tools"|''tools'')\s*\.\s*([A-Za-z0-9_-]+|"[^"]+"|''[^'']+'')') {
                    $key = Get-ToolkitCanonicalName ($Matches[1].Trim('"').Trim("'"))
                    if ($key -eq 'python3') { $key = 'python' }
                    $unsupported.Add($key)
                }
                continue
            }
            if (-not $inTools) { continue }
            if ($t -match '^([A-Za-z0-9_-]+|"[^"]+"|''[^'']+'')\s*\.') {
                $unsupported.Add((Get-ToolkitCanonicalName ($Matches[1].Trim('"').Trim("'"))))
                continue
            }
            if ($t -match '^([A-Za-z0-9_-]+|"[^"]+"|''[^'']+'')\s*=\s*(.+)$') {
                $key = Get-ToolkitCanonicalName ($Matches[1].Trim('"').Trim("'"))
                if ($key -eq 'python3') { $key = 'python' }
                $value = ($Matches[2] -replace '\s+#.*$', '').Trim()
                if ($value -match '^(["'']).*\1$' -or $value -match '^\[\s*(?:["''][^"'']+["'']\s*,?\s*)*\]$') {
                    $tools[$key] = ($value -replace '[\[\]"'']', '').Trim()
                } else { $unsupported.Add($key) }
            } else { $unsupported.Add('*') }
        }
    }
    return @{ tools = $tools; unsupported = $unsupported.ToArray() }
}

function Get-ToolkitDeclarations {
    param([string]$ProjectPath = '')
    $out = New-Object System.Collections.Generic.List[object]
    $dir = if ($ProjectPath) { [IO.Path]::GetFullPath($ProjectPath) } else { (Get-Location).Path }
    if (-not [IO.Directory]::Exists($dir)) { throw "项目目录不存在：$dir" }
    $seen = @{}
    # 最近项目优先；标准声明先于传统声明和 engines；全局配置最后。
    while ($dir) {
        foreach ($name in @('mise.toml', '.mise.toml', '.tool-versions', '.nvmrc', '.node-version', '.python-version', 'package.json')) {
            $file = Join-Path $dir $name
            if ([IO.File]::Exists($file)) {
                $data = Read-ToolkitDeclaredTools $file
                $out.Add([pscustomobject]@{ scope = 'project'; path = $file; tools = $data.tools; unsupported = $data.unsupported })
                $seen[(Get-ToolkitNormalizedPath $file)] = $true
            }
        }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    $globalFiles = New-Object System.Collections.Generic.List[string]
    if ($env:MISE_CONFIG_FILE) { $globalFiles.Add($env:MISE_CONFIG_FILE) }
    if ($env:MISE_CONFIG_DIR) { $globalFiles.Add((Join-Path $env:MISE_CONFIG_DIR 'config.toml')) }
    elseif ($env:XDG_CONFIG_HOME) { $globalFiles.Add((Join-Path $env:XDG_CONFIG_HOME 'mise\config.toml')) }
    elseif ($env:USERPROFILE) { $globalFiles.Add((Join-Path $env:USERPROFILE '.config\mise\config.toml')) }
    if ($env:APPDATA) { $globalFiles.Add((Join-Path $env:APPDATA 'mise\config.toml')) }
    if ($env:USERPROFILE) { $globalFiles.Add((Join-Path $env:USERPROFILE '.tool-versions')) }
    foreach ($file in $globalFiles) {
        if ([IO.File]::Exists($file) -and -not $seen.ContainsKey((Get-ToolkitNormalizedPath $file))) {
            $data = Read-ToolkitDeclaredTools $file
            $out.Add([pscustomobject]@{ scope = 'global'; path = $file; tools = $data.tools; unsupported = $data.unsupported })
        }
    }
    return $out.ToArray()
}

function Test-ToolkitVersionSatisfies {
    param([string]$Version, [string]$Wanted)
    if (-not $Wanted) { return $true }
    if ($Version -match '^v?\d+(?:\.\d+)+[A-Za-z0-9._+-]*$' -and $Version.TrimStart('v') -eq $Wanted.TrimStart('v')) { return $true }
    if ($Version -notmatch '^v?(\d+(?:\.\d+)*)(.*)$') { return $false }
    $actualText = $Matches[1]
    $suffix = $Matches[2]
    $parts = @($actualText.Split('.') | ForEach-Object { [int]$_ })
    $padded = @($parts) + @(0, 0, 0)
    $actual = [version](($padded[0..2]) -join '.')
    foreach ($alternative in ($Wanted -split '\|\||[,;]')) {
        $w = $alternative.Trim()
        if ($w -in @('latest', 'stable', 'system', 'any', '*')) { return $true }
        if ($w -match '^v?(\d+(?:\.\d+)*)(?:\.([xX*]))?$') {
            $want = @($Matches[1].Split('.') | ForEach-Object { [int]$_ })
            if ($parts.Count -lt $want.Count -or $suffix -match '^-') { continue }
            $ok = $true
            for ($i = 0; $i -lt $want.Count; $i++) { if ($parts[$i] -ne $want[$i]) { $ok = $false } }
            if ($ok) { return $true }
        } elseif ($w -match '^[~^]v?(\d+(?:\.\d+){0,2})$') {
            $operator = $w[0]
            $want = @($Matches[1].Split('.') | ForEach-Object { [int]$_ })
            $pad = @($want) + @(0, 0, 0)
            $lower = [version](($pad[0..2]) -join '.')
            $upper = if ($operator -eq '~' -and $want.Count -gt 1) { [version]"$($pad[0]).$($pad[1]+1).0" }
                     elseif ($operator -eq '^' -and $pad[0] -eq 0 -and $want.Count -gt 1) {
                         if ($pad[1] -gt 0 -or $want.Count -eq 2) { [version]"0.$($pad[1]+1).0" } else { [version]"0.0.$($pad[2]+1)" }
                     } else { [version]"$($pad[0]+1).0.0" }
            if ($actual -ge $lower -and $actual -lt $upper -and $suffix -notmatch '^-') { return $true }
        } elseif ($w -match '^(?:\s*(?:>=|<=|>|<|=)\s*\d+(?:\.\d+){0,2}\s*)+$') {
            $ok = ($suffix -notmatch '^-')
            foreach ($term in [regex]::Matches($w, '(>=|<=|>|<|=)\s*(\d+(?:\.\d+){0,2})')) {
                $digits = @($term.Groups[2].Value.Split('.'))
                $pad = $digits + @('0', '0', '0')
                $bound = [version](($pad[0..2]) -join '.')
                $partial = ($digits.Count -lt 3)
                $upper = if ($digits.Count -eq 1) { [version]"$([int]$pad[0]+1).0.0" }
                         else { [version]"$($pad[0]).$([int]$pad[1]+1).0" }
                switch ($term.Groups[1].Value) {
                    '>=' { $ok = $ok -and ($actual -ge $bound) }
                    '<=' { $ok = $ok -and $(if ($partial) { $actual -lt $upper } else { $actual -le $bound }) }
                    '>'  { $ok = $ok -and $(if ($partial) { $actual -ge $upper } else { $actual -gt $bound }) }
                    '<'  { $ok = $ok -and ($actual -lt $bound) }
                    '='  { $ok = $ok -and $(if ($partial) { $actual -ge $bound -and $actual -lt $upper } else { $actual -eq $bound }) }
                }
            }
            if ($ok) { return $true }
        }
    }
    return $false
}

function Test-ToolkitRequirementSupported {
    param([string]$Wanted)
    if (-not $Wanted) { return $true }
    foreach ($alternative in ($Wanted -split '\|\||[,;]')) {
        $w = $alternative.Trim()
        if ($w -in @('latest', 'stable', 'system', 'any', '*')) { continue }
        if ($w -match '^v?\d+(?:\.\d+)*(?:\.[xX*])?$' -or
            $w -match '^v?\d+(?:\.\d+)+[A-Za-z0-9._+-]+$' -or
            $w -match '^[~^]v?\d+(?:\.\d+){0,2}$' -or
            $w -match '^(?:\s*(?:>=|<=|>|<|=)\s*\d+(?:\.\d+){0,2}\s*)+$' -or
            $w -match '^[A-Za-z][A-Za-z0-9]*-\d+(?:\.\d+)*$') { continue }
        return $false
    }
    return $true
}
