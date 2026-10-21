# v1.0 契约冻结

从 `toolkit-map 1.0.0` 起，下面这些接口按本页规则演进。目标不是“永不变”，而是让消费方知道**什么可以安全依赖、什么一定会提前公告**。

机器可读定义：

- [`schemas/result-v2.schema.json`](../schemas/result-v2.schema.json)：所有 `-Json` 动作的 stdout 结果；
- [`schemas/map-v2.schema.json`](../schemas/map-v2.schema.json)：`~/.toolkit/map.json` 的存储格式；
- [`schemas/statuses.json`](../schemas/statuses.json)：状态枚举与含义；
- [`docs/reference.md`](reference.md)：字段与选择规则的人类可读说明；
- [`docs/mcp.md`](mcp.md)：MCP 工具与协议版本。

## 1. CLI 契约

动作名与参数保持稳定：`setup`、`doctor`、`scan`、`status`、`find`、`add`、`update`、`install`、`help`。

- `-Json` 时 stdout **恰好一个** JSON 对象；诊断与告警写 stderr；
- 退出码 `0` 表示 `ok:true`；`1` 表示 `ok:false` 或 `doctor` 返回 `attention_required`；
- 未知动作、异常同样输出结构化结果，不输出半截 JSON；
- 新增动作、参数或字段属于 minor；删除、重命名、改变参数含义属于 major；
- `find` 失败只代表本次搜索范围没有合适副本，不授权安装，也不代表整台机器不存在该工具。
- `doctor -Bundle` 在结果里附加 `bundle`（宿主、地图摘要、检查项、告警、版本）；不包含候选列表与 PATH 快照。提交 issue 前仍应检查并隐去用户名等路径信息。

## 2. JSON 结果 v2

每个结果至少包含：

```json
{
  "schemaVersion": 2,
  "action": "find",
  "ok": true,
  "status": "ok"
}
```

`ok` 是消费方唯一的安全闸门。`status` 说明原因；未知状态必须按失败处理，不能当作 `ok`。`path` 只在 `ok:true` 且 `verification:"verified"`（或调用方显式允许未验证）时可用于执行。

### 状态枚举

| status | 类别 | 含义 |
|---|---|---|
| `ok` | success | 动作成功；`find` 返回符合策略的已验证候选 |
| `planned` | plan | `WhatIf` 计划，未执行变更或联网 |
| `already_available` | success | 已有合适副本，复用而不重复安装 |
| `unverified` | selection | 显式允许未验证候选；不能报告为已验证 |
| `not_found` | selection | 本次搜索范围未发现副本 |
| `no_usable_candidate` | selection | 有副本，但无符合选择策略的可用候选 |
| `version_mismatch` | selection | 无满足要求的已验证副本，或下载版本不符 |
| `requirement_unsupported` | selection | 声明或版本表达式无法判定 |
| `map_missing` | map | 地图不存在 |
| `map_corrupt` | map | 地图无法解析；不覆盖损坏文件 |
| `schema_unsupported` | map | 地图格式版本不受支持；不覆盖原文件 |
| `map_busy` | map | 其他进程持有更新锁；可重试 |
| `attention_required` | diagnostic | `doctor` 有检查项未通过 |
| `operation_failed` | failure | 未分类异常；`message` 保留原因 |
| `checksum_unavailable` | install | 取不到官方 SHA256；未下载 |
| `checksum_conflict` | install | 给定 SHA256 与官方值冲突；未下载 |
| `version_unavailable` | install | 固定版本配方不提供所请求的版本 |
| `installed_not_discovered` | install | 安装完成但未发现可执行文件 |
| `installed_ambiguous` | install | 安装后发现多个新文件；不猜测 |
| `installer_missing` | install | 找不到可直接调用的安装器 |
| `asset_missing` | install | 发布中缺少所需资产 |
| `executable_missing` | install | 归档中缺少可执行文件 |
| `probe_failed` | install | 版本探测失败 |
| `environment_internal` | input | 依赖特定环境的路径不进入地图 |
| `invalid_action` | input | 未知动作 |
| `invalid_argument` | input | 参数缺失、格式错误或名称不合法 |
| `invalid_path` | input | 路径不存在、越界或不能用于该动作 |
| `invalid_project` | input | 项目目录不存在 |
| `rules_invalid` | input | 接入规则标记不完整；`setup` 不会覆盖 |
| `scan_failed` | failure | 扫描内核失败或未返回有效 JSON |

`candidates` 的顺序不是契约：选择结果看 `path`、`status` 与 `requirement`，不要依赖数组下标。新增字段可以出现在任何对象里；消费方必须忽略不认识的字段。

## 3. 地图存储 v2

- `schemaVersion` 固定为 `2`；`scannedAt` 是完整扫描时间，`updatedAt` 是局部更新时间，二者都可能是 `null`；
- `tools` 以工具名为键，值是 `{ preferred, preferredPath, candidates }`；
- 候选至少包含 `path`、`version`、`source`、`verification`、`isShim`、`usable`、`reachable`、`checkedAt`、`size`、`modifiedAt`、`note`；
- 读取 v1 地图时保留原首选路径作为迁移偏好；写入时升级到 v2；
- 未来不兼容格式必须提升 `schemaVersion`，读取方不得把未知格式当空地图覆盖；
- JSON 是权威文件；Markdown 摘要可以重建，不构成独立契约。

完整字段见 [`schemas/map-v2.schema.json`](../schemas/map-v2.schema.json)。

## 4. MCP 契约

三个工具名、参数与结果字段冻结：

| 工具 | 参数 | 结果 |
|---|---|---|
| `toolkit_find` | `tool` 必填；`project`、`version` 可选 | 地图 `find` 结果对象 |
| `toolkit_status` | 无 | 地图 `status` 结果对象 |
| `toolkit_doctor` | `project`、`rulesFile` 可选 | 地图 `doctor` 结果对象 |

- `structuredContent` 是结果对象本身；`ok:false` 时同时返回 `isError:true`；
- 工具只读，不暴露 `install` / `add` / `scan` / `update`；
- 支持旧会话 `initialize`（2024-11-05 至 2025-11-25）与 2026-07-28 的 `server/discover`；新增协议版本属于 minor，移除属于 major；
- stdout 只输出 JSON-RPC；新增工具属于 minor，删除或改参数属于 major。

## 5. 兼容策略

| 变更 | 版本 | 例子 |
|---|---|---|
| 修 bug、改文案、性能优化 | patch | 修正探测超时 |
| 新增字段、动作、工具、协议版本 | minor | 给结果加 `diagnostics` |
| 新增状态值 | minor | 新增一种安装失败原因 |
| 删除/重命名字段、改类型或语义 | major | 把 `path` 改成对象 |
| 地图布局不兼容 | major + `schemaVersion` 提升 | v2 → v3 |
| 修改 `ok` / 退出码含义 | major | `ok:false` 却退出 0 |

新增状态值时，消费方必须继续以 `ok` 为准，并把未知状态按失败处理；新增字段时，消费方必须忽略未知字段。弃用先在一个 minor 的文档与 CHANGELOG 里公告，至少保留到下一个 major。

## 6. 验证方式

- `tests/check-contract.ps1`：静态检查状态枚举、脚本字面量、schema 文档与契约文档是否漂移；
- `mcp/test/contract.test.mjs`：在 Windows 上用临时地图跑真实 `map.ps1`，用 schema 校验 `help` / `add` / `find` / `status` / `doctor` / `setup -WhatIf` 与 map.json；
- CI 在 Windows PowerShell 5.1/7、Linux PowerShell 7 与 Node 22 上运行相应检查。

平台边界不变：完整地图动作仅限 Windows PowerShell 5.1/7；Unix 只有 `census.sh` 扫描内核。MCP 服务器本身可以在其他平台启动，但调用完整地图会返回 `unsupported_platform`。
