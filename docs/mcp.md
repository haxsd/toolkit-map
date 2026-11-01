# MCP 接入

MCP 适配器把 toolkit-map 暴露成查询工具，客户端直接调用，不再只依赖模型“记得先读规则文件”。查询工具严格只读；维护动作由显式维护工具执行，见[维护工具](#维护工具)。

- `toolkit_find`：按项目声明查工具的绝对路径、版本、验证状态；不执行新候选、不写地图，只读发现的新候选保持未验证；
- `toolkit_status`：地图是否存在、多旧、PATH 是否变化；
- `toolkit_doctor`：宿主、地图、新鲜度与项目规则接入检查。

服务器是 `mcp/server.mjs`，零 npm 依赖，只通过 stdio 与客户端通信。它调用现有的 `scripts/map.ps1 -Json`，不改扫描、安装或地图格式。

## 前提

- Windows + Windows PowerShell 5.1 或 PowerShell 7；
- Node.js 18 或更新版本（只用于 MCP 适配器，不影响地图本身）；
- 已经拿到 toolkit-map 源码目录。首次下载见 [README 的首次接入](../README.md#首次接入一个项目)。

**不要直接用 PATH 上的 `node` 启动服务器。** PATH 上的 Node 可能正好是项目要避开的旧版本。先让地图给出一个已验证的 Node 18+ 绝对路径：

```powershell
$map = 'C:\your-install\toolkit-map\scripts\map.ps1'   # 换成真实绝对路径
$node = (& $map find node -Version '>=18' -Json | ConvertFrom-Json).path
$node
```

`find` 返回 `ok:false` 时不要猜路径，按 [故障排查](troubleshooting.md) 处理。MCP 服务器本身不负责安装 Node。

`find` 是只读查询：它不会执行新候选、不会写地图，也不会把查询结果当作机器事实保存。它可能只读发现候选元数据，但新候选保持 `unverified`，不会被默认选中；要用它们，先显式 `scan` / `update` 验证，已有副本用 `add` 登记，然后再 `find`。

## 生成配置

在 toolkit-map 源码目录执行（用上一步的 `$node`）：

```powershell
& $node mcp\server.mjs --print-config
```

想连同项目 `AGENTS.md` 一起接入时，可以用 `scripts/quickstart.ps1 -Project <目录> -Mcp -WriteMcp`：它先执行 `setup`，再用地图找到 Node 18+，**核对 `--print-config` 的退出码和 JSON，并执行 `--check` 做启动检查**，全部通过后才把配置写入项目级文件（默认 Cursor 的 `.cursor/mcp.json`；`-McpClient claude` 写 `.mcp.json`，`both` 两个都写）。已有文件会先备份，其他 `mcpServers` 条目保留；已有文件不是合法 JSON 或结构不符合预期时拒绝覆盖。

`-McpClient claude` 只选择 MCP 配置文件，不会自动改变规则文件；默认仍是 `AGENTS.md`。如果要让 Claude Code 读取项目 `CLAUDE.md`，同时显式传入 `-RulesFile (Join-Path $project 'CLAUDE.md')`。可以先加 `-WhatIf` 查看规则目标。

如果地图选中的 Node 是启动器，而生成配置中的实际 `node.exe` 路径不同，quickstart 只接受地图中另有记录、指纹未变且满足 Node 18+ 的已验证可执行文件，并用它执行启动检查。否则会停止写入配置；请先核实实际路径，再经授权用 `add` 登记。

quickstart 的退出码：`0` 全部完成；`2` 部分完成——项目规则已接入，但 MCP 未写成（缺 Node 18+、配置生成失败、JSON 不合法或启动检查失败），修好后重跑；`1` 项目接入本身失败。不要把 `2` 当成功。`-WhatIf` 只预览，不建图、不写文件。Codex 的 TOML 仍按下面手动粘贴。

quickstart 打印或写入的配置会把 `TOOLKIT_MAP_FILE` 固定为本次 `setup` 使用的地图，启动检查也使用该地图；`setup` 生成的规则块则为 CLI 回退显式固定相同的 `-MapFile`。因此调用方环境中不同的 `TOOLKIT_MAP_FILE` 不会让检查和实际使用指向另一张地图。将来要切换地图时，需重新生成配置和规则，或明确修改两处路径。单独运行 `--print-config` 不会自动固定地图。

输出是一段可直接粘贴的 `mcpServers` JSON，`command` 和 `args` 都是绝对路径。需要 Codex 的 TOML 时：

```powershell
& $node mcp\server.mjs --print-config codex
```

需要给某个项目设置默认目录时加 `--project`：

```powershell
& $node mcp\server.mjs --print-config --project 'D:\work\my-app'
```

它只影响写入配置的 `TOOLKIT_MAP_PROJECT`；调用工具时仍建议显式传 `project`，尤其是 monorepo。

## 接入客户端

### Cursor

把生成的 JSON 合并进下面任一位置，保留文件里已有的其他服务器：

- 全局：`~/.cursor/mcp.json`
- 项目：`<项目>/.cursor/mcp.json`

配置里的 `command` 和 `args` 是本机绝对路径，**不要提交到团队仓库**。团队成员各自生成；共享项目里只提交通用说明，不提交带本机路径的 `.cursor/mcp.json`。

```json
{
  "mcpServers": {
    "toolkit-map": {
      "command": "D:\\tools\\node22\\node.exe",
      "args": ["D:\\toolkit-map\\mcp\\server.mjs"]
    }
  }
}
```

重启 Cursor，在 MCP 设置里确认 `toolkit-map` 已连接，并能看到 `toolkit_find`、`toolkit_status`、`toolkit_doctor` 三个查询工具。

### Claude Code

项目级 `.mcp.json` 与上面的 JSON 结构相同；也可以直接用命令登记：

```powershell
claude mcp add --transport stdio toolkit-map -- "D:\tools\node22\node.exe" "D:\toolkit-map\mcp\server.mjs"
```

需要时用 `claude mcp list` 确认连接。

### Codex

用 `--print-config codex` 的输出**替换** `~/.codex/config.toml` 里已有的 `[mcp_servers.toolkit-map]` 整段（连同它的 `env` 行），不要再次追加。重复的 TOML 表会让客户端报错，或被后一段静默覆盖：

```toml
[mcp_servers.toolkit-map]
command = "D:\\tools\\node22\\node.exe"
args = ["D:\\toolkit-map\\mcp\\server.mjs"]
```

如果使用了 `--project`，输出里还会带 `env = { "TOOLKIT_MAP_PROJECT" = "..." }`。更新配置时保留新输出的这一行；旧块里多余的行要一起删掉。Codex 配置同样包含本机绝对路径，不要提交到共享仓库。

撤销接入时不要只删规则文件：还要从各客户端配置里移除 `toolkit-map` 条目，保留其他服务器。步骤见[撤销与卸载](uninstall.md#2-移除-mcp-配置)。

## 验证

先脱离 MCP 客户端验证服务器和地图本身：

```powershell
& $node mcp\server.mjs --check
```

它执行一次 `status` 并打印地图 JSON；退出码 0 表示地图存在且可读取，不表示地图一定新鲜、所有候选可用或项目接入已通过诊断。还要检查 `stale`、`deadCandidates` 和 `pathChanged`；PATH 不同也可能只是会话环境不同。`quickstart -WriteMcp` 在写配置前会自动执行这一步。

然后在客户端新开会话，发送：

> 用 toolkit_find 查询本项目需要的 Node，报告项目要求、候选、选中的绝对路径和验证状态；不要安装、不要改 PATH。确认成功后再用该路径执行 `--version`。

成功时工具结果是 `isError:false`，`structuredContent` 至少包含：

```json
{
  "ok": true,
  "status": "ok",
  "path": "D:\\dev\\toolchain\\node22\\node.exe",
  "version": "22.23.2",
  "verification": "verified",
  "requirement": { "version": "22", "scope": "project", "source": "D:\\work\\app\\.nvmrc" }
}
```

`ok:false` 时 `isError` 为 `true`，`status` 保留地图状态（如 `version_mismatch`），不会返回错误版本的路径。

## 工具契约

当前 MCP 的查询工具：

| 工具 | 参数 | 行为 |
|---|---|---|
| `toolkit_find` | `tool`（必填）、`project`、`version` | 调 `map.ps1 find <tool> -Project <project> -Json`；`version` 覆盖项目声明；只读，不执行新候选、不写地图；新候选需显式维护验证 |
| `toolkit_status` | 无 | 调 `map.ps1 status -Json`；不修改地图 |
| `toolkit_doctor` | `project`、`rulesFile` | 调 `map.ps1 doctor -Json`；只读检查接入文件 |

`project` 缺省时依次使用 `TOOLKIT_MAP_PROJECT`、`CLAUDE_PROJECT_DIR`（Claude Code 会注入）和服务器进程工作目录。工具描述要求模型在知道项目目录时显式传入绝对路径。

查询工具只有这三个；`install`、`add`、`scan`、`update` 不通过查询工具暴露，避免模型在查询过程中改动机器状态。工具名、参数与结果字段属于 [v1.0 契约冻结](contract.md) 的一部分。

## 维护工具

MCP 还提供三个显式维护工具，让客户端在用户授权下维护地图。它们默认只预览，`confirm:true` 才请求执行。

| 工具 | 参数 | 行为 |
|---|---|---|
| `toolkit_scan` | `confirm`（默认 `false`） | 预览扫描动作；`confirm:true` 才执行 `map.ps1 scan -Json` |
| `toolkit_update` | `tool`（可选）、`confirm`（默认 `false`） | 预览重探范围；`confirm:true` 才执行 `map.ps1 update [工具] -Json` |
| `toolkit_add` | `tool`、`path`（必填）、`version`、`note`、`prefer`、`confirm`（默认 `false`） | 预览登记；`confirm:true` 才执行 `map.ps1 add ... -Json` |

共同契约：

- **默认只预览**：未传 `confirm:true` 时不得写地图、不得探测新候选；返回 `status:planned` 和将要执行的参数，包括登记备注、版本提示及首选标记。预览会标出这次动作使用的地图来源（`-MapFile`、`TOOLKIT_MAP` 或用户目录默认地图），未解析的值明确注明由 map.ps1 解析；`.md` 地图目标由 map.ps1 拒绝；
- **执行可能运行候选程序**：`scan` / `update` / `add` 为取版本会探测本机候选程序，因此执行前必须取得用户明确授权；查询工具不会这样做；
- **`confirm:true` 不是授权证明**：它只表示请求执行。参数本身无法证明操作者是人、是账号持有人或已获用户同意；客户端必须展示变更并向用户取得明确授权；服务端不提供绕过确认的后门；
- **不自动安装、不改 PATH**：维护工具只做 `scan` / `update` / `add`，不调用 `install`，不写 shell 配置或系统环境变量；
- **参数校验**：`toolkit_add` 的 `path` 原样交给 map.ps1，实际登记时必须是已存在的文件；工具名不能是路径。预览不探测文件，失败时不写地图；
- **结果可审计**：返回结果包含动作、目标、是否执行、地图路径与状态；未执行时明确 `planned`。已有 Markdown 摘要不符合安全覆盖条件时，JSON 地图仍可更新，结果返回 `summaryWarning`。

这三个维护工具的新增属于 minor 级别的接口扩展；本次严格只读 `find` 与旧参数行为的变化另有兼容性影响。客户端需要重新加载服务器配置才能看到新工具；旧版适配器可能只提供三个查询工具。

## 协议支持

- **旧会话**：`initialize` 握手，支持 `2024-11-05`、`2025-03-26`、`2025-06-18`、`2025-11-25`；客户端请求哪个受支持版本就回哪个。
- **新会话**：`2026-07-28` 的 `server/discover` 与每请求 `_meta` 模型；不支持的现代版本返回 `-32022` 并列出 `2026-07-28`。
- 传输：stdio，单行一个 JSON-RPC 消息；stdout 只输出协议消息，诊断走 stderr。
- 服务器不主动向客户端发请求，也不声明 resources / prompts。

## 安全边界

- 当前查询工具标注 `readOnlyHint: true`、`destructiveHint: false`；维护工具标注会写地图、需要确认，不能伪装成只读；
- 子进程使用参数数组启动，不经过 shell，不接受 `.ps1` 片段或任意命令；
- 单次调用默认 120 秒超时，可用 `TOOLKIT_MAP_TIMEOUT_MS` 调整；
- 不读取凭据、不写项目文件、不改 PATH、不安装工具；
- 地图目标按服务端配置 `TOOLKIT_MAP_FILE`、继承的 `TOOLKIT_MAP`、用户目录下默认地图的顺序确定；
- `confirm:true` 只是执行请求，不是真人授权证明；维护工具必须在客户端确认后才执行。

MCP 只降低“模型忘记查地图”的概率，不能强制模型遵守。项目里仍建议保留一条简短规则：**运行版本敏感命令前先调用 `toolkit_find`**。规则与 MCP 可以同时存在。

## 故障排查

| 现象 | 处理 |
|---|---|
| 客户端看不到查询工具 | 确认配置在正确的文件；重启客户端；用 `--print-config` 重新生成绝对路径 |
| `quickstart -Mcp -WriteMcp` 退出 2 | 项目规则已接入，MCP 未写成。读输出里的原因；补 Node 18+、修配置或地图后重跑。不要当成功 |
| 启动时报 Node 版本错误 | MCP 需要 Node 18+；用 `map.ps1 find node -Version '>=18' -Json` 的 `path` 作为 `command`。`find` 只读，先确保地图已建 |
| `errorCode: unsupported_platform` | 完整地图目前只支持 Windows；Unix 只有 `census.sh` 扫描内核 |
| `errorCode: map_script_missing` | `args` 里的 `mcp/server.mjs` 路径不对，或源码目录被移动 |
| `status: map_missing` | 先执行 `map.ps1 setup -Project <目录>` 或 `scan` |
| `status: not_found`，但机器上确实有 | `find` 不执行新候选、不写地图；只用 `scan` / `update` 验证候选，已有副本用 `add` 登记后再查 |
| `status: version_mismatch` | 这是预期结果：没有满足项目要求的副本。补声明、安装或显式传 `version`，不要加绕过参数 |
| Codex 报 TOML 重复表或配置不生效 | `[mcp_servers.toolkit-map]` 被追加了多次；删除旧段，只保留一段 |
| `errorCode: timeout` | 地图动作较慢；先手动执行一次 `scan`，或调大 `TOOLKIT_MAP_TIMEOUT_MS` |
| 返回 `invalid_output` | 自定义的 `TOOLKIT_MAP_SCRIPT` 包装脚本必须只在 stdout 输出一个 JSON 对象 |

完整地图状态含义见 [参考手册](reference.md)；规则文件接入问题见 [故障排查](troubleshooting.md)。

## 与规则文件的关系

- MCP 可用时，优先用 MCP：参数和结果都有 schema，客户端能直接展示工具调用。
- 不支持 MCP 的客户端继续用 `setup` 写入规则文件，见 [agent 接入指南](agent-integration.md)。
- 规则文件里的 `find` 也按严格只读契约使用；需要刷新地图时显式 `scan` / `update` / `add`。
- 两者可以同时启用；MCP 不会自动改写 `AGENTS.md`，`setup` 也不会替你写 MCP 配置。
- 团队共享仓库不要提交写有本机绝对路径的规则块或 MCP 配置；每台机器各自生成。

## 限制

- 完整地图动作仍仅限 Windows；Unix 没有等价实现。
- MCP 服务器不缓存结果；每次调用都读当前地图与项目声明，慢一点但不会返回过期选择。
- `toolkit_find` 只读：不执行新候选、不写地图；新候选保持未验证，必须通过显式 `scan` / `update` / `add` 验证后才可能被选中。搜索范围不是全盘扫描。
- 维护工具默认预览；执行 `scan` / `update` / `add` 可能探测本机候选程序，必须取得用户授权，且不安装工具、不改 PATH。
- 不提供 `resources`、`prompts` 或采样；维护工具的授权由客户端确认流程负责。
