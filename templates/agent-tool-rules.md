# toolkit-map 调用规则（可复制到任意 agent 规则文件）

把下面的正文复制进 Cursor 用户规则、Codex 的 AGENTS.md、Claude Code 的 CLAUDE.md 等持久入口。
将 `C:/Users/YOUR_USER/Projects/toolkit-map/scripts/map.ps1` 和 `C:/Users/YOUR_USER/.toolkit/map.json` 替换成本机的脚本与地图绝对路径，复制下面的标记区。文件接入可用 `doctor -RulesFile` 检查；Cursor UI 规则需要观察 agent 的实际调用。

**这份规则含本机绝对路径，不要提交到团队共享仓库。** 每位成员在自己机器上生成或替换路径；共享项目只提交不含本机路径的通用说明。MCP 配置同样含本机 Node 路径，不要提交。

<!-- toolkit-map:begin -->
## 本机工具发现

**优先使用 MCP**：如果当前客户端已经提供 `toolkit_find` / `toolkit_status` / `toolkit_doctor` 工具，直接调用这些工具，不要为同样的查询再启动 PowerShell 执行 `map.ps1`。下面的脚本命令只在 MCP 不可用时作为回退；这样也能避免每次查询都经过宿主终端。

调用本机工具前，先查询工具地图。MCP 不可用时，地图脚本绝对路径：C:/Users/YOUR_USER/Projects/toolkit-map/scripts/map.ps1。

在 PowerShell 中执行（每次将项目参数替换成当前项目目录）：

```powershell
& 'C:/Users/YOUR_USER/Projects/toolkit-map/scripts/map.ps1' status -MapFile 'C:/Users/YOUR_USER/.toolkit/map.json' -Json
& 'C:/Users/YOUR_USER/Projects/toolkit-map/scripts/map.ps1' find <工具> -Project '<当前项目目录>' -MapFile 'C:/Users/YOUR_USER/.toolkit/map.json' -Json
```

- 没有地图时，经用户确认后执行 `setup` 或 `scan` 建图。`setup` 默认写入维护策略：允许 agent 在 `find` 需要时自动执行定向 `update <tool>`；`-NoAutoUpdate` 可关闭。
- **维护循环**：`find` 返回 `maintenance` 时，先看 `required` / `recommended` 和 `actions`。若 action 的 `autoAllowed:true`（默认只对定向 `update` 预授权），直接执行对应 `update <tool>` 并重试一次 `find`，不要反复询问；`scan` / `add` / `install` 或 `autoAllowed:false` 时，说明原因并只确认一次。地图旧不等于每次都要全量 `scan`。
- `find` 只读：不执行新候选、不写地图；只读发现的新候选保持未验证，需要 `update` / `scan` / `add` 验证。CLI 回退的维护动作必须显式传上面相同的 `-MapFile`，以免修改另一张地图。PATH 因会话不同而变化时先确认实际影响，不必反复重扫。
- Windows 策略禁止直接执行脚本时，用当前 PowerShell 宿主以 `-NoProfile -ExecutionPolicy Bypass -File` 单次调用；不修改全局执行策略，遵循组织组策略。组策略拒绝 Bypass 时按组织流程处理，不要绕过。
- 检查退出码为 0、`ok:true`、`status:ok`、`verification:verified` 和 `requirement`，再使用返回的绝对 `path`。已在本次会话查证且配置未变的路径可以复用。
- 版本不匹配或未验证时先诊断，不降级、不执行 shim；`find` 不支持 `-AllowUnverified`，`-AllowIdeHost` 只能在明确需要时使用。`find` 失败只表示当前地图没有合适副本，不表示整台机器没有。
- `find` 不安装工具；明确需要时才另行 `install`，先用 `-WhatIf -Json` 预览。已有副本用 `add` 登记，不迁移、不改全局 PATH。
- 如果客户端提供 `toolkit_update`，在 `find.maintenance.autoAllowed` 为 true 时可传 `confirm:true` 直接调用（策略已授权），然后重试 `find`；`toolkit_scan` / `toolkit_add` 仍需用户明确确认。`confirm:true` 只是执行护栏，不是真人授权证明。不要调用 `install`，不要改 PATH。
- 团队共享仓库不要提交本机绝对路径的规则块或 MCP 配置；每台机器各自生成。
- 下载前说明预计下载量、安装占用及实际目标目录，检查目标盘与暂存/缓存盘空间。仅预计安装占用 ≥1 GB 时询问位置，下载包大小不触发询问；等用户回答再下载。体积未知时先核实估算，Rust、Android SDK 等预计达到门槛的工具即使精确体积未知也先确认。已有明确位置偏好且空间足够时复用；用户指定门槛优先。
- portable 仓库由 `TOOLCHAIN_ROOT` 指定（默认 `~/toolchains`），暂存使用 `TEMP`；管理器的数据/缓存目录分别配置。仅临时改变量不会成为永久偏好，持久化需用户明确选择，已有工具不自动迁移。
- 项目需要完整工具链环境时，通过已登记的 mise 执行 `mise exec -- <命令>`。报告区分项目声明、发现的可用副本与当前 PATH 解析。
<!-- toolkit-map:end -->

Windows PowerShell 5.1/7 才有完整 map 动作；Unix 目前只有 `census.sh` 扫描内核。
