# toolkit-map agent 接入指南

让 AI agent 在调用工具前先查 `map.ps1`：查绝对路径、项目要求、验证状态；只有明确需要才安装。
客户端支持 MCP 时，优先用 [MCP 接入](mcp.md)：配置一次即可直接调用 `toolkit_find`，不依赖模型记住规则文件。下面的规则文件接入是通用回退方案，两者可以同时启用。
首次试用建议先按 [README](../README.md#快速开始) 完成一个 Cursor/Codex 项目接入。下面用于选择其他前端、跨项目全局规则或可选技能安装。

`find` 是只读查询：不执行新候选、不写地图；只读发现的新候选保持未验证。结果里的 `maintenance` 会说明地图是否过期、有没有待验证候选、建议执行什么动作。`setup` 默认写入 `autoUpdate=true`；未执行 `setup` 时不预授权。`scan` / `add` / `install` 仍只向用户确认一次。

| 前端 | 跨项目使用 | 只在当前项目使用 |
|---|---|---|
| MCP 客户端（Cursor / Claude Code / Codex） | 配置一次 `mcpServers`，见 [MCP 接入](mcp.md) | 项目级 `.cursor/mcp.json` / `.mcp.json` |
| Cursor | Customize → Rules → User Rules，手工粘贴 | 项目 AGENTS.md，或带 alwaysApply 的 MDC |
| Codex | CODEX_HOME/AGENTS.md，默认 ~/.codex/AGENTS.md | 项目 AGENTS.md |
| Claude Code | ~/.claude/CLAUDE.md | 项目 CLAUDE.md |

参考规则：

- 通用模板（复制进任意规则文件）：[`templates/agent-tool-rules.md`](../templates/agent-tool-rules.md)
- Cursor 项目规则（含 frontmatter）：[`templates/cursor-toolkit-map.mdc`](../templates/cursor-toolkit-map.mdc)

**团队共享仓库**：`setup` 生成的规则块和 MCP 配置都包含本机绝对路径（`map.ps1`、Node 可执行文件）。这些路径只对生成它们的机器有效。不要提交到共享仓库；团队成员各自执行 `setup` / `quickstart`，或把 MCP 配置放在用户级、项目内未跟踪的本地文件。项目里只提交不带本机路径的通用模板。

## 先替换占位路径（必须）

模板里的 `C:/Users/YOUR_USER/Projects/toolkit-map/scripts/map.ps1` 与 `C:/Users/YOUR_USER/.toolkit/map.json` 是占位符，**必须分别换成本机真实的脚本和地图绝对路径**。`setup` 生成规则时会固定本次接入所用地图；MCP 不可用而回退 CLI 时，查询和经授权的维护动作都使用同一个 `-MapFile`。从你的 toolkit-map 安装目录定位 `scripts/map.ps1`；安装为技能时按 `SKILL.md` 的实际位置定位，不要假设它在当前项目下。

```powershell
$map="$env:USERPROFILE\Projects\toolkit-map\scripts\map.ps1"   # 按实际情况改
$project = 'D:\your-project'  # 替换成真实存在的当前项目目录
```

Windows 默认策略可能禁止直接执行 `.ps1`。不要修改全局执行策略，也不要为了绕过组策略去改注册表；用当前 PowerShell 宿主单次调用（只影响该子进程）：

```powershell
$ps = (Get-Process -Id $PID).Path
& $ps -NoProfile -ExecutionPolicy Bypass -File $map status -Json
```

组织策略若仍拒绝 `Bypass`，按组织流程申请允许的执行策略。agent 新建终端或子进程时应重新采用单次宿主调用。

## 核心契约（Windows 完整地图）

1. `& $map status -Json`；无地图时先取得用户同意，再用 `setup` / `scan` 建图。PATH 可能仅因会话不同而变化，先确认实际影响。
2. `& $map find <工具> -Project <当前项目> -Json`，**find 每次显式传当前项目**，不硬编码项目路径。`find` 只读：不执行新候选、不写地图；只读发现的新候选保持未验证。
3. 检查退出码为 0、`ok:true`、`status:ok`、`requirement` 和 `verification:verified`，再使用返回的绝对 `path`。同时检查 `maintenance`：`required` 必须先处理，`recommended` 可先维护再执行。
4. 未满足要求时先诊断；`find` 不支持 `-AllowUnverified`，不自行加 `-AllowIdeHost`，不执行 shim；先报告项目要求、发现的副本、当前解析到谁。
5. `maintenance.actions` 里 `autoAllowed:true` 的定向 `update <tool>` 可直接执行（`setup` 已授权），然后重试一次 `find`；`scan` / `add` / `install` 或 `autoAllowed:false` 时只确认一次。不要因为地图旧就每次全量重扫。
6. 全局规则可选（跨项目复用），但**必须有一个 agent 能读到的持久入口**；仅安装或写好技能文件不能证明 agent 真会调用。
7. 仅预计安装占用 ≥1 GB 时询问安装位置，下载包大小不触发询问；所有新安装都检查目标盘与暂存/缓存盘空间。估算与选盘方法见 [存储与大工具安装](storage.md)。

## find 严格只读与 agent 自动维护

`find` / `toolkit_find` 只负责“按现有地图和项目声明选择”，不执行候选、不写地图：

- 不执行新候选：即使只读发现新路径，也不会运行它取版本；新候选保持 `unverified`，不会被默认选中；
- 不写地图：查询不会更新 `scannedAt` / `updatedAt`、候选列表或首选路径；
- 返回 `maintenance`：地图年龄、待验证候选、建议动作和 `autoAllowed`；`required` 表示当前没有可执行路径，`recommended` 表示路径可用但地图有可维护项。
- 验证靠维护动作：`scan` / `update` / `add` 才会实际探测并把候选变成可用的已验证副本。`setup` 预授权后允许 agent 对具体工具自动执行定向 `update`；未执行 `setup` 时不预授权。`scan` / `add` / `install` 仍确认。

需要改变地图时，优先由 agent 按策略执行；关闭自动更新或没有预授权时，由人显式执行：

```powershell
& $ps -NoProfile -ExecutionPolicy Bypass -File $map scan -Json              # 完整重扫
& $ps -NoProfile -ExecutionPolicy Bypass -File $map update node -Json       # 只重探已有条目
& $ps -NoProfile -ExecutionPolicy Bypass -File $map add node -Path 'D:\existing\node.exe' -Json  # 登记已有副本
& $ps -NoProfile -ExecutionPolicy Bypass -File $map setup -Project $project -NoAutoUpdate -Json  # 关闭定向自动更新
```

MCP 的维护工具遵循同一原则：`toolkit_update` 在 `find.maintenance.autoAllowed` 为 true 时可传 `confirm:true` 直接执行（策略已授权），然后重试 `find`；`toolkit_scan` / `toolkit_add` 默认只返回预览，`confirm:true` 才请求执行。**`confirm:true` 不能证明操作者是人或已获用户授权**；客户端必须展示将要发生的变更并取得用户明确同意。执行 `scan` / `update` / `add` 会为取版本探测本机候选程序，因此更要先确认。维护工具不安装工具、不改 PATH。见 [MCP 维护工具](mcp.md#维护工具)。

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

`setup` 写入的标记块包含本机 `map.ps1` 绝对路径。共享项目里不要把这个块提交上去；每人本地执行 `setup`，或改用本地未跟踪的规则文件。升级源码目录后路径会变化，需要重新生成。

`setup` 同时写入维护策略：无参数默认 `autoUpdate=true`，允许 agent 在 `find` 需要时自动执行定向 `update <tool>`；`-NoAutoUpdate` 关闭。未执行 `setup` 时不预授权。`scan` / `add` / `install` 仍由用户确认。

`setup` 生成的规则块应先说明 MCP 优先、再给脚本回退，并说明 `find` 只读、`maintenance` 的自动维护规则。用 `-WhatIf -Json` 的 `preview` 核对当前文案；如果仍是旧顺序，先更新源码再重新 `setup`，不要手工改已部署块。

```powershell
& $map setup -Project $project -WhatIf -Json
& $map setup -Project $project -Json
& $map setup -Project $project -NoAutoUpdate -Json
& $map doctor -Project $project -Json
```

## 升级与刷新规则

Git 克隆安装：先检查本地修改，工作区干净时更新到稳定标签（在同一 PowerShell 会话中）。有本地修改时先保留并整合，或在新目录克隆；不要 reset/覆盖本机修改。

```powershell
$installDir = "$env:USERPROFILE\Projects\toolkit-map" # 按真实安装目录改
git -C $installDir status --short
# 确认上一步没有本地修改后执行；任一步失败就先处理，别继续。
git -C $installDir fetch --depth 1 origin tag v2.1.0
if ($LASTEXITCODE -ne 0) { throw '获取版本失败' }
git -C $installDir switch --detach v2.1.0
if ($LASTEXITCODE -ne 0) { throw '切换版本失败' }
$map = Join-Path $installDir 'scripts\map.ps1'
```

ZIP 安装：从 Release 下载 `toolkit-map-v<版本>-runtime.zip`，用同名 `.sha256` 校验后解压到新目录，重新设置 `$map` 指向新位置。运行时包不含顶层 `tests/` 与 CI；完整源码仍可从 Release 的 `Source code (zip)` 浏览。移动源码路径后也需刷新规则中的绝对路径。

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

从 [Release](https://github.com/haxsd/toolkit-map/releases/latest) 下载 `toolkit-map-v<版本>-runtime.zip`（含运行所需脚本、MCP、schema 与文档；不含顶层 tests/ 与 CI），用同名 `.sha256` 校验后解压。按[故障排查](troubleshooting.md)解除 ZIP 下载标记。源码根目录应直接包含 `SKILL.md` 和 `scripts`，不要指向它的上一级。

在要接入的真实项目中打开 PowerShell，设置一次真实源码目录，然后运行：

```powershell
$project = (Get-Location).Path
$installDir = 'C:\your-install\toolkit-map-v2.1.0' # 替换为你解压后的源码根目录
$map = Join-Path $installDir 'scripts\map.ps1'
$ps = (Get-Process -Id $PID).Path
& $ps -NoProfile -ExecutionPolicy Bypass -File $map setup -Project $project -WhatIf -Json
& $ps -NoProfile -ExecutionPolicy Bypass -File $map setup -Project $project
& $ps -NoProfile -ExecutionPolicy Bypass -File $map doctor -Project $project -Json
& $ps -NoProfile -ExecutionPolicy Bypass -File $map find powershell -Project $project
```

完整地图仍需受支持的 Windows 宿主；组织策略仍以组织要求为准。回到 README 的 agent 验收步骤，把查询 Git 改为查询 PowerShell，无需为了试用而额外安装 Git。
