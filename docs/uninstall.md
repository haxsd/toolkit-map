# 撤销接入与卸载

本页说明如何安全撤销 toolkit-map 的**接入入口**，以及默认保留哪些实际资源。命令契约见 [参考手册](reference.md)。

先定位你本机的脚本绝对路径，并在每个命令里显式带入当前项目：

```powershell
$map = "$env:USERPROFILE\Projects\toolkit-map\scripts\map.ps1"   # 换成你本机真实绝对路径
$project = (Get-Location).Path  # 先在对应项目打开 PowerShell
$ps = (Get-Process -Id $PID).Path
```

**本工具没有 CLI `uninstall` 动作**。撤销靠编辑已接入的规则文件与管理目录，不要臆造或调用不存在的卸载子命令。

## 1. 移除各接入入口中的标记块

`setup` 会追加或替换 `toolkit-map:begin/end` 标记块，并保留文件里的其他内容。撤销时**只移除该标记块，保留其他规则**。

先在规则文件中找到已有标记块再手工删除。下面可查看当前版本将生成的区块，但它不是已部署文件的原文（`-WhatIf` 不写文件）：

```powershell
& $ps -NoProfile -ExecutionPolicy Bypass -File $map setup -Project $project -WhatIf -Json
& $ps -NoProfile -ExecutionPolicy Bypass -File $map doctor -Project $project -Json
```

逐个入口处理，块外的规则一律保留：

- 项目 `AGENTS.md`（或 `-RulesFile` 指定的文件，如项目 `CLAUDE.md`）。
- Codex 全局：`CODEX_HOME/AGENTS.md`，默认 `~/.codex/AGENTS.md`；若使用 override 文件也需检查。
- Claude Code 全局：`~/.claude/CLAUDE.md`。
- Cursor 项目规则：`.cursor/rules/*.mdc`（保留 frontmatter 与其他规则）。
- Cursor 全局：**UI 粘贴的 User Rules 需在 Cursor 设置里手工删除对应区块**，脚本无法访问账号/UI 规则。

## 2. 备份恢复仅限“无后续编辑”

`setup` 在改动前会备份原文件。只有当该文件**在备份之后没有其他编辑**时，才可用备份整体覆盖回去。

若备份之后又改过（手动加了别的规则、其他工具写入过），**不要**用备份覆盖，否则会丢掉后续编辑——此时应按第 1 步只删标记块。

## 3. 技能 Junction：只移除链接本身

若技能目录是 Junction/符号链接指向源码仓库，撤销时只移除**链接本身**，不递归删除源码目标：

```powershell
# 按真实技能入口改，Cursor 等前端可能使用其他目录。
$skillPath = Join-Path $env:USERPROFILE '.agents\skills\toolkit-map'
$link = Get-Item -LiteralPath $skillPath -Force
$link | Select-Object FullName, LinkType, Target
# 核对显示的路径与目标后，只删除已确认的目录链接。
if ($link.LinkType -notin @('Junction', 'SymbolicLink')) { throw '这不是目录链接，请勿自动删除' }
[IO.Directory]::Delete($link.FullName) # 非递归，只移除链接本身
```

不要递归清理链接路径或其源码目标；不同宿主的删除行为可能不同。上面的目录删除没有递归参数，删前务必核对 `LinkType`/`Target`。若安装的是普通复制目录，先确认其中没有本地修改，再单独处理，不使用链接删除流程。

## 4. 默认保留的内容

默认**保留**以下资源，它们不影响前端规则加载，删除会造成不必要的破坏：

- 已安装的实际工具 (`~/toolchains/*`)。
- 地图文件与其 Markdown 摘要。

## 5. 只删源码时可能遗留的规则

如果你只删除了源码目录（例如 `toolkit-map` 仓库）而没有按第 1 步清理规则文件，则**接入标记块仍留在各规则文件里**，agent 会继续读到引用已失效脚本绝对路径的规则。请务必先完成第 1 步，再删源码。

## 6. 验收

撤销后**新开一个会话**，确认 agent 不再尝试调用 toolkit-map（例如不再运行 `map.ps1`、不再引用标记块），并确认其余规则仍生效。
