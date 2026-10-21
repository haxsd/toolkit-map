# MCP 接入（推荐）

MCP 适配器把 toolkit-map 暴露成三个只读工具，客户端直接调用，不再只依赖模型“记得先读规则文件”。

- `toolkit_find`：按项目声明查工具的绝对路径、版本、验证状态；
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

## 生成配置

在 toolkit-map 源码目录执行（用上一步的 `$node`）：

```powershell
& $node mcp\server.mjs --print-config
```

想连同项目 `AGENTS.md` 一起接入时，可以用 `scripts/quickstart.ps1 -Project <目录> -Mcp -WriteMcp`：它先执行 `setup`，再用地图找到 Node 18+，把配置写入项目级文件（默认 Cursor 的 `.cursor/mcp.json`；`-McpClient claude` 写 `.mcp.json`，`both` 两个都写）。已有文件会先备份，其他 `mcpServers` 条目保留；已有文件不是合法 JSON 时拒绝覆盖。`-WhatIf` 只预览，不写文件。Codex 的 TOML 仍按下面手动粘贴。

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

重启 Cursor，在 MCP 设置里确认 `toolkit-map` 已连接，并能看到三个 `toolkit_*` 工具。

### Claude Code

项目级 `.mcp.json` 与上面的 JSON 结构相同；也可以直接用命令登记：

```powershell
claude mcp add --transport stdio toolkit-map -- "D:\tools\node22\node.exe" "D:\toolkit-map\mcp\server.mjs"
```

需要时用 `claude mcp list` 确认连接。

### Codex

把 `--print-config codex` 的输出追加到 `~/.codex/config.toml`：

```toml
[mcp_servers.toolkit-map]
command = "D:\\tools\\node22\\node.exe"
args = ["D:\\toolkit-map\\mcp\\server.mjs"]
```

如果使用了 `--project`，输出里还会带 `env = { "TOOLKIT_MAP_PROJECT" = "..." }`。

## 验证

先脱离 MCP 客户端验证服务器和地图本身：

```powershell
& $node mcp\server.mjs --check
```

它执行一次 `status` 并打印地图 JSON；退出码 0 表示地图存在且可用。

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

| 工具 | 参数 | 行为 |
|---|---|---|
| `toolkit_find` | `tool`（必填）、`project`、`version` | 调 `map.ps1 find <tool> -Project <project> -Json`；`version` 覆盖项目声明 |
| `toolkit_status` | 无 | 调 `map.ps1 status -Json`；不修改地图 |
| `toolkit_doctor` | `project`、`rulesFile` | 调 `map.ps1 doctor -Json`；只读检查接入文件 |

`project` 缺省时依次使用 `TOOLKIT_MAP_PROJECT`、`CLAUDE_PROJECT_DIR`（Claude Code 会注入）和服务器进程工作目录。工具描述要求模型在知道项目目录时显式传入绝对路径。

服务器只暴露这三个只读动作。`install`、`add`、`scan`、`update` 不通过 MCP 暴露，避免模型在查询过程中改动机器状态。工具名、参数与结果字段属于 [v1.0 契约冻结](contract.md) 的一部分。

## 协议支持

- **旧会话**：`initialize` 握手，支持 `2024-11-05`、`2025-03-26`、`2025-06-18`、`2025-11-25`；客户端请求哪个受支持版本就回哪个。
- **新会话**：`2026-07-28` 的 `server/discover` 与每请求 `_meta` 模型；不支持的现代版本返回 `-32022` 并列出 `2026-07-28`。
- 传输：stdio，单行一个 JSON-RPC 消息；stdout 只输出协议消息，诊断走 stderr。
- 服务器不主动向客户端发请求，也不声明 resources / prompts。

## 安全边界

- 工具全部标注 `readOnlyHint: true`、`destructiveHint: false`；
- 子进程使用参数数组启动，不经过 shell，不接受 `.ps1` 片段或任意命令；
- 单次调用默认 120 秒超时，可用 `TOOLKIT_MAP_TIMEOUT_MS` 调整；
- 不读取凭据、不写项目文件、不改 PATH、不安装工具；
- 地图路径固定为 `~/.toolkit/map.json`，可用 `TOOLKIT_MAP_FILE` 指向测试副本。

MCP 只降低“模型忘记查地图”的概率，不能强制模型遵守。项目里仍建议保留一条简短规则：**运行版本敏感命令前先调用 `toolkit_find`**。规则与 MCP 可以同时存在。

## 故障排查

| 现象 | 处理 |
|---|---|
| 客户端看不到三个工具 | 确认配置在正确的文件；重启客户端；用 `--print-config` 重新生成绝对路径 |
| 启动时报 Node 版本错误 | MCP 需要 Node 18+；用 `map.ps1 find node -Version '>=18' -Json` 的 `path` 作为 `command` |
| `errorCode: unsupported_platform` | 完整地图目前只支持 Windows；Unix 只有 `census.sh` 扫描内核 |
| `errorCode: map_script_missing` | `args` 里的 `mcp/server.mjs` 路径不对，或源码目录被移动 |
| `status: map_missing` | 先执行 `map.ps1 setup -Project <目录>` 或 `scan` |
| `status: version_mismatch` | 这是预期结果：没有满足项目要求的副本。补声明、安装或显式传 `version`，不要加绕过参数 |
| `errorCode: timeout` | 机器首次扫描或现场搜索较慢；先手动执行一次 `scan`，或调大 `TOOLKIT_MAP_TIMEOUT_MS` |
| 返回 `invalid_output` | 自定义的 `TOOLKIT_MAP_SCRIPT` 包装脚本必须只在 stdout 输出一个 JSON 对象 |

完整地图状态含义见 [参考手册](reference.md)；规则文件接入问题见 [故障排查](troubleshooting.md)。

## 与规则文件的关系

- MCP 可用时，优先用 MCP：参数和结果都有 schema，客户端能直接展示工具调用。
- 不支持 MCP 的客户端继续用 `setup` 写入规则文件，见 [agent 接入指南](agent-integration.md)。
- 两者可以同时启用；MCP 不会自动改写 `AGENTS.md`，`setup` 也不会替你写 MCP 配置。

## 限制

- 完整地图动作仍仅限 Windows；Unix 没有等价实现。
- MCP 服务器不缓存结果；每次调用都读当前地图与项目声明，慢一点但不会返回过期选择。
- `toolkit_find` 的现场搜索范围仍是地图 + PATH + 仓库 + mise 安装目录，不是全盘扫描。
- 不提供 `resources`、`prompts`、采样或诱导用户授权的交互。
