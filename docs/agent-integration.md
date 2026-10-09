# toolkit-map agent 接入指南

让 AI agent 在调用工具前先查 `map.ps1`：查绝对路径、项目要求、验证状态；只有明确需要才安装。
首次试用建议先按 [README](../README.md#首次接入一个项目) 完成一个 Cursor/Codex 项目接入。下面用于选择其他前端、跨项目全局规则或可选技能安装。

| 前端 | 跨项目使用 | 只在当前项目使用 |
|---|---|---|
| Cursor | Customize → Rules → User Rules，手工粘贴 | 项目 AGENTS.md，或带 alwaysApply 的 MDC |
| Codex | CODEX_HOME/AGENTS.md，默认 ~/.codex/AGENTS.md | 项目 AGENTS.md |
| Claude Code | ~/.claude/CLAUDE.md | 项目 CLAUDE.md |

参考规则：

- 通用模板（复制进任意规则文件）：[`templates/agent-tool-rules.md`](../templates/agent-tool-rules.md)
- Cursor 项目规则（含 frontmatter）：[`templates/cursor-toolkit-map.mdc`](../templates/cursor-toolkit-map.mdc)

## 先替换占位路径（必须）

模板里的 `C:/Users/YOUR_USER/Projects/toolkit-map/scripts/map.ps1` 是占位符，**必须换成你本机真实
绝对路径**。从你的 toolkit-map 安装目录定位 `scripts/map.ps1`；安装为技能时按 `SKILL.md` 的实际位置定位，不要假设它在当前项目下。

```powershell
$map="$env:USERPROFILE\Projects\toolkit-map\scripts\map.ps1"   # 按实际情况改
$project = 'D:\your-project'  # 替换成真实存在的当前项目目录
```

Windows 默认策略可能禁止直接执行 `.ps1`。检查源码后，可在当前终端运行 `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`，或单次使用 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File $map <动作与参数>`；无需修改全局策略。agent 新建终端或子进程时应重新采用单次宿主调用；组织组策略的限制需遵循组织要求。

## 核心契约（Windows 完整地图）

1. `& $map status -Json`；无地图、过旧或 PATH 变化时执行 `& $map scan -Json`。
2. `& $map find <工具> -Project <当前项目> -Json`，**find 每次显式传当前项目**，不硬编码项目路径。
3. 检查退出码为 0、`ok:true`、`status:ok`、`requirement` 和 `verification:verified`，再使用返回的绝对 `path`。
4. 未满足要求时不自行加 `-AllowUnverified` / `-AllowIdeHost`，不执行 shim；先报告项目要求、发现的副本、当前解析到谁。
5. `find` 失败只说明本次范围没有合适副本，不授权安装；明确需要时先 `install <工具>@<版本> -WhatIf -Json` 看计划，再单独安装。已有副本用 `add` 登记，不搬路径、不改全局 PATH。
6. 全局规则可选（跨项目复用），但**必须有一个 agent 能读到的持久入口**；仅安装或写好技能文件不能证明 agent 真会调用。
7. 仅预计安装占用 ≥1 GB 时询问安装位置，下载包大小不触发询问；所有新安装都检查目标盘与暂存/缓存盘空间。估算与选盘方法见 [存储与大工具安装](storage.md)。

## Cursor

官方：<https://cursor.com/docs/rules>。全局走 Customize → Rules 的 **User Rules（UI 粘贴）**，仅作用于
Agent Chat，不影响 Tab/Inline Edit。项目规则用 `.cursor/rules/*.mdc`，**必须有 frontmatter `alwaysApply: true`**，
或改用项目 `AGENTS.md`。

**全局（UI 粘贴，最稳）**：先用 `-WhatIf` 生成/预览正文，再粘贴**通用模板正文**（不要把 `.mdc` 的
frontmatter 头一起粘进 UI，UI 不需要 YAML 头）。也可以直接粘贴下面命令的 `preview` 内容，它已经包含真实脚本路径：

```powershell
(& $map setup -Project $project -WhatIf -Json | ConvertFrom-Json).preview
```

**项目（Always Apply）**：先复制完整模板文件（含 frontmatter）到 `.cursor/rules/toolkit-map.mdc`，再在
Cursor 里确认规则显示为 Always Apply。

保留 YAML 头并替换模板中的所有占位路径。已有规则文件不要直接覆盖；先合并模板并保留其他内容。之后可用 `setup -RulesFile '<项目目录>\.cursor\rules\toolkit-map.mdc'` 更新标记块，它会保留头部。采用项目 `AGENTS.md` 时，直接执行 `& $map setup -Project $project` 即可。

> 注意：`setup` **不会生成 MDC frontmatter**，靠 setup 新建 `.mdc` 不等于生效——必须先复制完整模板。
> 不要把 `~/.cursor/AGENTS.md` 当作全局规则，用 UI 最稳。

## Codex

官方：<https://developers.openai.com/codex/guides/agents-md>。全局默认 `~/.codex/AGENTS.md`（尊重
`CODEX_HOME`），`AGENTS.override.md` 可覆盖，项目 `AGENTS.md` 更具体。

```powershell
$codexDir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
& $map setup -RulesFile (Join-Path $codexDir 'AGENTS.md') -WhatIf -Json
& $map setup -RulesFile (Join-Path $codexDir 'AGENTS.md') -Json
& $map doctor -RulesFile (Join-Path $codexDir 'AGENTS.md') -Json
```

- 全局：把通用模板正文写入 `$codexDir\AGENTS.md`，或直接把 `-RulesFile` 指向它。
- 项目：在项目 `AGENTS.md` 里追加同一段规则（模板自带 `toolkit-map:begin/end` 标记，便于更新与 doctor 识别）。

## Claude Code

官方：<https://code.claude.com/docs/en/memory>。全局 `~/.claude/CLAUDE.md`，项目 `CLAUDE.md`。AGENTS.md 支持
有版本/配置条件，推荐用 `CLAUDE.md` 明确接入（内容同样是通用模板正文）。

```powershell
$claudeRules = Join-Path $env:USERPROFILE '.claude\CLAUDE.md'
& $map setup -RulesFile $claudeRules -WhatIf -Json
& $map setup -RulesFile $claudeRules -Json
& $map doctor -RulesFile $claudeRules -Json
# 只在当前项目使用时，把目标换成项目根目录的 CLAUDE.md。
& $map setup -Project $project -RulesFile (Join-Path $project 'CLAUDE.md') -WhatIf -Json
& $map setup -Project $project -RulesFile (Join-Path $project 'CLAUDE.md') -Json
```

## 用 setup / doctor 维护本地规则文件

`setup` 在已有内容变化前会备份；对目标文件追加或替换 `toolkit-map:begin/end` 标记块，保留原有规则、可预览、幂等；
`-RulesFile` 覆盖默认的项目 `AGENTS.md`；`-WhatIf` 纯只读。`doctor` 同时检查宿主、地图和新鲜度，接入检查只针对**指定文件**的标记区与
当前 script 绝对路径，且 `agentVerified` 始终 `false`——它不访问账号/UI 规则，也无法证明模型行为。

```powershell
& $map setup -Project $project -WhatIf -Json
& $map setup -Project $project -Json
& $map doctor -Project $project -Json
```

## 升级与刷新规则

Git 克隆安装：先检查本地修改，工作区干净时更新到稳定标签（在同一 PowerShell 会话中）。有本地修改时先保留并整合，或在新目录克隆；不要 reset/覆盖本机修改。

```powershell
$installDir = "$env:USERPROFILE\Projects\toolkit-map" # 按真实安装目录改
git -C $installDir status --short
# 确认上一步没有本地修改后执行；任一步失败就先处理，别继续。
git -C $installDir fetch --depth 1 origin tag v0.3.0
if ($LASTEXITCODE -ne 0) { throw '获取版本失败' }
git -C $installDir switch --detach v0.3.0
if ($LASTEXITCODE -ne 0) { throw '切换版本失败' }
$map = Join-Path $installDir 'scripts\map.ps1'
```

ZIP 安装：校验 Release 附件，解压到新目录，重新设置 `$map` 指向新位置。移动源码路径后也需刷新规则中的绝对路径。

升级 toolkit-map 不会自动刷新已经粘贴的规则。每次升级后，文件接入重新执行 `setup` 更新标记块；Cursor 全局 UI 接入重新生成 `preview` 并替换旧区块。随后新开会话验收。

## 在 agent 中验收

让 agent 按本项目声明去查 `node`，要求它报告：**项目要求什么、发现哪些候选、所选 `path` 及 `verification`**，
并且**先不安装**。新开一个 agent 会话，观察它实际执行了哪些命令与输出，不要只问“你遵守了吗”。若它直接调用裸 `node`，排查规则是否加载、脚本路径与权限是否正确，以及更具体的规则是否冲突。全局规则含本机路径，账号同步到另一台机器后应重新生成或替换路径。

Windows PS5.1/7 才有完整 map 动作，Unix 目前只有 `census.sh` 扫描内核。

## 可选：安装为技能

完成规则接入后，可将技能联接到前端支持的目录，提供按需加载的详细使用说明。技能目录不替代持久规则。

```powershell
# 先确保父目录存在；目标为直接包含 SKILL.md 的源码目录。
$skillParent = Join-Path $env:USERPROFILE '.agents\skills'
New-Item -ItemType Directory -Force -Path $skillParent | Out-Null
New-Item -ItemType Junction -Path (Join-Path $skillParent 'toolkit-map') -Target $installDir
```

已有同名目录/联接不要覆盖；先查看其来源。Cursor 可用 `~/.cursor/skills`，不同前端的发现方式以其支持为准。撤销见[卸载指南](uninstall.md)。

## 没有 Git 时从 ZIP 接入

从 [Release](https://github.com/haxsd/toolkit-map/releases/latest) 下载源码 ZIP 和 SHA256SUMS.txt。按[故障排查](troubleshooting.md)比对校验值、解除 ZIP 下载标记后解压。源码根目录应直接包含 `SKILL.md` 和 `scripts`，不要指向它的上一级。

在要接入的真实项目中打开 PowerShell，设置一次真实源码目录，然后运行：

```powershell
$project = (Get-Location).Path
$installDir = 'C:\your-install\toolkit-map-v0.3.0' # 替换为你解压后的源码根目录
$map = Join-Path $installDir 'scripts\map.ps1'
$ps = (Get-Process -Id $PID).Path
& $ps -NoProfile -ExecutionPolicy Bypass -File $map setup -Project $project -WhatIf -Json
& $ps -NoProfile -ExecutionPolicy Bypass -File $map setup -Project $project
& $ps -NoProfile -ExecutionPolicy Bypass -File $map doctor -Project $project -Json
& $ps -NoProfile -ExecutionPolicy Bypass -File $map find powershell -Project $project
```

完整地图仍需受支持的 Windows 宿主；组织策略仍以组织要求为准。回到 README 的 agent 验收步骤，把查询 Git 改为查询 PowerShell，无需为了试用而额外安装 Git。
