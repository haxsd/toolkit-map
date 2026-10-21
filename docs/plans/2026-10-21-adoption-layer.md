# 采用层（v0.4.0）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 在不改扫描内核与 JSON 协议的前提下，增加 MCP stdio 适配器、一条命令接入流程和可复现 demo，让陌生用户在 5 分钟内把 toolkit-map 接进 Cursor / Claude Code / Codex。

**Architecture:** `mcp/` 是零依赖 Node 18+ 薄封装：把 MCP 的 `toolkit_find` / `toolkit_status` / `toolkit_doctor` 转成对现有 `scripts/map.ps1 -Json` 的调用，只做参数校验、超时、错误映射和结果转发。引擎、地图 schema、状态码与 PowerShell 5.1/7 契约都不变。MCP 同时支持 2025-06-18 一类的 `initialize` 旧会话与 2026-07-28 的 `server/discover` 新模型。

**Tech Stack:** Node.js 18+（仅标准库）、MCP JSON-RPC 2.0 over stdio、现有 Windows PowerShell 地图动作、GitHub Actions。

**Spec:** 本文件；接口契约见 `docs/mcp.md` 与 `docs/reference.md`。

## Global Constraints

- 不修改 `scripts/map.ps1`、`scripts/map-core.ps1`、`scripts/census.*` 的行为与 `schemaVersion: 2`。
- `mcp/` 不引入 npm 运行时依赖；`node_modules` 不进入发布包。
- MCP 工具全部只读：只允许 `find`、`status`、`doctor`，不暴露 `install` / `add` / `scan`。
- 工具返回必须保留 `ok`、`status`、`path`、`verification`、`requirement`，不降级、不自行安装。
- Node 18+；Windows 完整地图；Unix 返回明确的“不支持”工具错误，不伪装成功。
- stdout 只能出现 JSON-RPC 消息；日志与诊断一律走 stderr。
- 新增 `.ps1` 必须带 UTF-8 BOM；`.sh` 使用 LF 且无 BOM。
- 版本号唯一来源是根目录 `VERSION`；发布前同步 README、接入指南与 CHANGELOG。

---

## Task 1: MCP 协议核心（可注入的纯逻辑）

**Files:**
- Create: `mcp/lib/protocol.mjs`
- Create: `mcp/lib/tools.mjs`
- Test: `mcp/test/protocol.test.mjs`

**Interfaces:**
- `createProtocolHandler({ runMap, serverInfo }) -> { handle(message): Promise<object|null> }`
- `runMap(action, options) -> Promise<object>`，action 为 `find|status|doctor`
- `TOOLS`：三个工具定义，含 `name`、`description`、`inputSchema`、`annotations`

- [x] **Step 1: 写失败测试**

覆盖：`initialize` 回显受支持版本；`tools/list` 三个工具且 schema 合法；`tools/call` 正确拼参数；地图 `ok:false` 映射为 `isError:true`；未知工具返回 `-32602`；`server/discover` 返回 `resultType:complete`。

- [x] **Step 2: 运行确认失败**

Run: `node --test mcp/test/protocol.test.mjs`
Expected: FAIL，模块不存在。

- [x] **Step 3: 实现协议与工具定义**

旧会话走 `initialize`，新会话按 `_meta.io.modelcontextprotocol/protocolVersion` 识别；不支持的现代版本返回 `-32022` 并列出 `2026-07-28`。

- [x] **Step 4: 通过测试**

Run: `node --test mcp/test/protocol.test.mjs`
Expected: PASS。

## Task 2: PowerShell 运行器

**Files:**
- Create: `mcp/lib/runner.mjs`
- Test: `mcp/test/runner.test.mjs`

**Interfaces:**
- `runMap(action, options, config) -> Promise<object>`
- `config` 可由环境变量覆盖：`TOOLKIT_MAP_SCRIPT`、`TOOLKIT_MAP_POWERSHELL`、`TOOLKIT_MAP_FILE`、`TOOLKIT_MAP_TIMEOUT_MS`

- [x] **Step 1: 写失败测试**

用假的 `node` 子进程脚本验证参数顺序、BOM 清理、非零退出但含合法 JSON、超时、stderr 诊断。不执行真实 PowerShell。

- [x] **Step 2: 实现运行器**

`spawn` 不经过 shell；Windows 默认 `powershell.exe`，可用环境变量覆盖；超时结束进程树；只解析 stdout 的单个 JSON 对象。

- [x] **Step 3: 通过测试**

Run: `node --test mcp/test/runner.test.mjs`
Expected: PASS。

## Task 3: stdio 服务器与配置生成

**Files:**
- Create: `mcp/server.mjs`
- Create: `mcp/package.json`
- Test: `mcp/test/server.test.mjs`

**Interfaces:**
- 启动：`node mcp/server.mjs`
- `--print-config [cursor|claude|codex]` 输出可粘贴配置
- `--version` 读取根目录 `VERSION`
- `--help` 输出用法

- [x] **Step 1: 写失败测试**

用子进程喂 NDJSON，断言 stdout 每行都是合法 JSON-RPC、没有日志污染；断言 `--print-config` 含绝对 Node 路径与 `server.mjs` 绝对路径。

- [x] **Step 2: 实现 stdio 循环**

按行读取、并发处理、按 `id` 回包；stdin 关闭即退出；所有异常转成 JSON-RPC 错误。

- [x] **Step 3: 通过测试**

Run: `node --test mcp/test/server.test.mjs`
Expected: PASS。

## Task 4: 真实地图集成测试

**Files:**
- Create: `mcp/test/integration.test.mjs`
- Create: `mcp/test/fixtures/project/.nvmrc`

- [x] **Step 1: 只在 Windows 运行**

用临时 `-MapFile` 与假 `node.cmd` 登记两个版本，通过真实 `map.ps1` 调用 `toolkit_find`，断言选中项目要求的版本；非 Windows 直接 skip。

- [x] **Step 2: 通过测试**

Run: `node --test mcp/test/integration.test.mjs`
Expected: Windows PASS；其他平台 SKIP。

## Task 5: 文档与配置示例

**Files:**
- Create: `docs/mcp.md`
- Modify: `README.md`、`README-EN.md`、`docs/agent-integration.md`、`docs/reference.md`、`CHANGELOG.md`
- Modify: `.github/workflows/ci.yml`

- [x] **Step 1: 写 MCP 接入文档**

覆盖 Cursor / Claude Code / Codex 配置位置、Node 18+ 绝对路径、三工具契约、只读边界、故障排查、与规则文件的关系。

- [x] **Step 2: README 增加 MCP 入口**

放在手工规则之前；保留“规则文件仍可用”的说明。

- [x] **Step 3: CI 增加 MCP job**

Windows 与 Ubuntu 跑 `node --check` 与 `node --test mcp/test`；Windows 另跑真实地图集成测试。

- [x] **Step 4: 文档检查**

Run: `.\tests\check-docs.ps1`
Expected: PASS。

## Task 6: 一条命令接入与 demo

**Files:**
- Create: `scripts/quickstart.ps1`（UTF-8 BOM）
- Create: `scripts/demo.ps1`（UTF-8 BOM）
- Create: `docs/demo.md`
- Modify: `README.md`、`README-EN.md`

- [x] **Step 1: quickstart 先预览后执行**

`quickstart -Project <目录> [-Mcp] [-WhatIf]`：复用已有安装或浅克隆稳定标签；执行 `setup`；`-Mcp` 时用地图找到 Node 18+ 绝对路径并打印配置，不覆盖已有配置文件。

- [x] **Step 2: demo 使用临时地图**

构造 Node 16 / Node 22 两个假副本与要求 22 的项目，完整演示“PATH 是 16 → find 返回 22 的绝对路径”。不写本机地图。

- [x] **Step 3: 验证**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\demo.ps1`
Expected: 退出码 0，输出包含 `version_mismatch` 对照与最终 Node 22 路径。

## Task 7: v1.0 契约冻结

**Files:**
- Create: `docs/contract.md`
- Create: `schemas/map-v2.schema.json`、`schemas/result-v2.schema.json`
- Create: `tests/contract-freeze.ps1`

- [x] **Step 1: 冻结字段与状态枚举**
- [x] **Step 2: 用 schema 校验真实输出**
- [x] **Step 3: 写明“只增不改”与弃用策略**
- [ ] **Step 4: 发布 v1.0.0**（代码版本已到 1.0.0；标签与 Release 待创建）

## 验收标准

- Cursor / Claude Code / Codex 任一客户端加入配置后能看到三个工具，并能返回真实绝对路径。
- `toolkit_find` 在项目要求不满足时返回 `isError:true`，且不返回错误版本路径。
- 关闭 stdin 后服务器立即退出，stdout 无日志污染。
- 新增测试在 Windows 与 Ubuntu CI 都通过；文档检查、编码检查通过。
- README 的首次接入路径不再要求用户先理解规则文件。

## 明确不做

- GUI、daemon、后台常驻服务。
- 通过 MCP 暴露安装、改 PATH、改全局配置。
- macOS / Linux 完整地图。
- 为 MCP 引入 npm 依赖或构建步骤。

## 执行记录（2026-10-21）

- Task 1–7 已完成（Task 7 的标签/Release 除外）：`mcp/` 适配器、运行器、stdio 服务器、真实地图集成测试、文档与 CI、quickstart 与 demo、v1.0 契约与 schema、`doctor -Bundle`。
- 验证：MCP 与契约测试共 35 项通过；`check-docs.ps1`、`check-encodings.ps1`、`check-text.ps1`、`check-data.ps1`、`check-contract.ps1`、`doctor-bundle.ps1` 通过；`scripts/demo.ps1` 与 `scripts/quickstart.ps1 -WhatIf` 在本机人工跑通。
- 端到端：Node 22 启动 MCP，项目 `.nvmrc` 要求 22，`toolkit_find` 返回 `D:\dev\toolchain\node22\node.exe`，未使用 PATH 上的 Node 16。
- 未完成：v1.0.0 标签与 GitHub Release 尚未创建；GIF 尚未录制。
