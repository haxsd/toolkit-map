# 参考手册

首次配置前端请先看 [agent 接入指南](agent-integration.md)：全局与项目规则是不同接入范围，`setup -RulesFile` 只维护本地文件，Cursor 账号内的 User Rules 需要手工粘贴。Cursor `.mdc` 文件应先具备有效 frontmatter，`setup` 不生成该头部。

## 命令与结果

`map.ps1 <动作> [工具] [参数]`。完整地图动作支持 Windows PowerShell 5.1 和 PowerShell 7。

| 动作 | 参数 | 行为 |
|---|---|---|
| `setup` | `-Project <目录>`、`-RulesFile <文件>`、`-WhatIf` | 地图不存在时首次扫描；生成接入规则；保留已有文件内容、修改前备份；重复执行幂等 |
| `doctor` | `-Project`、`-RulesFile` | 只读检查宿主、地图、新鲜度与接入文件 |
| `scan` | `-Throttle`（默认 min(8, CPU 数)） | 调用 census，合并仍存在的已有登记，再完整重扫；各候选的版本探测先并行跑完再按原顺序建图，`-Throttle 1` 为串行，结果相同；结果附带计量字段 probeStats（见“扫描内核”） |
| `status` | `-MaxAgeHours`（默认 24） | 完整扫描年龄、最近更新、失效文件数、PATH 变化 |
| `find` | `<工具>`、`-Project`、`-Version`、`-SkipScan` | 按当前或指定项目声明动态选择；不匹配不降级；没有合适候选时可做限定范围现场搜索 |
| `add` | `<工具> -Path <文件>`、`-Version`、`-Note`、`-Prefer` | 登记已有副本；Version 是提示，不能把探测失败变成已验证；Prefer 保存路径偏好 |
| `update` | `[工具]` | 重探已有文件与新候选，不刷新完整扫描时间 |
| `install` | `<工具>@<版本>`、`-Url`、`-Sha256`、`-Via winget`、`-WingetId`、`-WhatIf` | 单独的明确安装动作；portable 版本验证后落仓库；安装器由包管理器管理 |
| `help` | — | 版本、动作与用法 |

通用：`-Json` 输出机器结果；`-MapFile` 覆盖地图路径；`-LockTimeoutSeconds` 控制更新锁等待（默认 60 秒，0–300）。

`-AllowUnverified` 仅在明确需要时允许选择未验证的普通副本，不允许 shim、跳过探测的商店别名或不可用文件。`-AllowIdeHost` 允许已验证的 IDE 内置运行时。conda 环境副本不作默认首选。

## JSON 输出协议 v2

所有动作的 stdout 恰好一个 JSON 对象。成功退出码 0，失败或 doctor 需要处理时为 1。未知动作与异常同样输出结构化结果。

```jsonc
{
  "schemaVersion": 2,
  "action": "find",
  "ok": true,
  "status": "ok",
  "tool": "node",
  "requestedTool": "node",
  "found": true,
  "path": "C:\\tools\\node\\22\\node.exe",
  "version": "22.23.2",
  "verification": "verified",
  "reason": "requirement_match",
  "requirement": { "version": "22", "scope": "project", "source": "D:\\project\\mise.toml" },
  "invocation": { "executable": "C:\\tools\\node\\22\\node.exe", "arguments": [], "cwd": "D:\\project" },
  "candidates": [],
  "search": { "performed": false, "complete": false, "scope": ["map", "PATH", "warehouse", "mise-installs"] }
}
```

关键状态：

| status | 含义 |
|---|---|
| `ok` | 动作成功；find 默认返回已验证候选 |
| `planned` | WhatIf 计划，未执行变更或联网 |
| `already_available` | 已有合适的已验证副本，复用而不重复安装 |
| `unverified` | 用户显式允许未验证候选；不能报告为已验证 |
| `not_found` | 本次搜索范围未找到副本，不代表全盘不存在 |
| `no_usable_candidate` | 存在副本，但没有符合选择策略的可用候选 |
| `version_mismatch` | 没有满足要求的已验证副本，或下载版本不符 |
| `requirement_unsupported` | 声明/版本表达式无法判定；需显式版本或管理器处理 |
| `map_missing` / `map_corrupt` / `schema_unsupported` | 地图缺失、损坏或版本不支持；损坏文件不会被覆盖 |
| `map_busy` | 其他进程持有更新锁；可重试 |
| `checksum_unavailable` / `checksum_conflict` | 配方安装取不到官方 SHA256，或 `-Sha256` 与官方值不一致；未下载 |
| `version_unavailable` | 固定版本配方不提供所请求的版本；改用 `-Url` 与 `-Sha256` |
| `attention_required` | doctor 有检查项未通过 |
| `operation_failed` | 未分类异常；message 保留原因 |

`found` 表示选到了符合当前策略的候选。检查 `ok`、`verification` 和 `requirement` 后再执行。`search.complete:false` 明确表示不是穷尽全盘搜索。

## 声明与选择

优先级：`-Version` > 最近项目声明 > 父目录声明 > 全局声明。同一目录依次读取 mise.toml、.mise.toml、.tool-versions、.nvmrc、.node-version、.python-version、package.json engines。

支持数值前缀（22、3.12）、完整版本、逗号/分号或 `||` 候选、数值通配符、`^`、`~` 和组合比较（`>=20 <23`）。latest/stable/system/any/* 表示不限制已验证版本，不会联网解析最新版本；LTS 别名等无法确定的要求会失败。带发行版前缀的 Java 要求必须能从候选路径或版本证实发行版。

部分版本比较遵循前缀范围：`<=22` 包含所有稳定的 22.x；`>22` 从 23.0.0 起；`=22.23` 包含稳定的 22.23.x。完整三段比较（如 `<=22.23.2`）仍按该版本边界判断。

读取器不实现完整 TOML / mise 语义。复杂工具表会报告不支持；includes、模板和环境专属配置等需交给管理器处理。二进制选择也不等同于加载项目完整环境。

例如 `[tools.node]`、`[[tools.node]]` 与内联工具表都返回 `requirement_unsupported`，不会忽略项目要求后退回全局版本。可改为支持的 `[tools]` 字符串声明，或明确提供 `-Version`。

选取步骤：排除 shim、不可用文件、默认不允许的未验证/IDE/conda-env 副本 → 筛选项目要求 → 显式路径偏好 → 已验证 → 仓库 → PATH 可达 → 来源 → 版本 → 路径确定性排序。用户偏好不能绕过版本要求和护栏。

## 地图存储 v2

```jsonc
{
  "schemaVersion": 2,
  "scannedAt": "2026-09-30T10:00:00+08:00",
  "updatedAt": "2026-09-30T10:05:00+08:00",
  "warehouse": "C:\\Users\\<用户>\\toolchains",
  "pathSnapshot": "扫描时的 PATH",
  "tools": {
    "node": {
      "preferred": "path-<规范化路径的 SHA256>",
      "preferredPath": "用户显式偏好的路径",
      "candidates": []
    }
  }
}
```

地图只保存机器事实和路径偏好，项目选择在 find 时计算。读取 v1 地图时保留原首选路径作为迁移偏好和既有备注；写入时升级到 v2。需要重算默认排序时可重新登记目标路径或调整 preferredPath。未知未来格式不覆盖。

候选字段：

| 字段 | 含义 |
|---|---|
| `id` | 规范化绝对路径的稳定 SHA256 ID，同版本副本不会撞车 |
| `path`、`version`、`source` | 文件路径、实际版本（或登记提示）、来源 |
| `verification` | verified / unverified / unavailable / skipped |
| `usable` | verified 为 true，unavailable 为 false，其他为 null |
| `reachable` | 所在目录在 PATH 中；不代表该命令会赢得解析 |
| `isShim` | 间接层，不执行版本探测，不作首选 |
| `checkedAt`、`size`、`modifiedAt` | 验证时间与文件指纹；文件变化或旧格式时重新验证 |
| `registered`、`userNote`、`note` | 手工登记标识、用户备注与说明 |

探测只接受成功退出且可提取版本的输出。普通零字节文件不可用；商店执行别名不探测、状态 skipped。文件指纹是大小与修改时间，不是完整内容哈希。

完整扫描与局部更新分别计时。读改写全程持有同一登录会话中的命名 mutex，随后原子替换 JSON 和 Markdown；两文件不是联合事务，JSON 是权威文件。可在摘要写入失败后重试刷新。

## 适配器与安装

统一仓库默认位于用户目录下的 `toolchains`，由 `TOOLCHAIN_ROOT` 覆盖；portable 暂存使用当前进程的 `TEMP`。管理器的数据/缓存目录不受 `TOOLCHAIN_ROOT` 控制。大工具下载前询问位置属于 agent 接入规则，CLI 不自动估算体积或交互拦截；详见 [存储与大工具安装](storage.md)。

`scripts/tools.json` 定义 aliases、warehouseNames、locations 安装位置提示、probe 参数数组、可选 versionPattern，以及 portable recipes。未知工具仅尝试 `--version`；不盲试裸 `version`。为不支持该参数的工具添加适配器。

内置 GitHub portable：gh、jadx、rg（ripgrep 别名）、fd；固定版本：adb（platform-tools 37.0.1，官方带版本号的地址）。当前资产为 Windows x64。配方安装下载前必须取得官方 SHA256：配方钉死的值、GitHub 发布资产的 digest 或上游校验文件（gh 的 checksums.txt、rg 的 .sha256）；都取不到时返回 `checksum_unavailable`，需用 `-Sha256` 给出从官方核实的值，且与官方值冲突时返回 `checksum_conflict`。adb 其他版本返回 `version_unavailable`，请用 `-Url` 与 `-Sha256`。自定义 zip 用 `-Url`，`-Sha256` 可校验归档。证书吊销服务器不可达时，仅 Windows PowerShell 5.1 且本进程开启吊销检查时临时关闭吊销检查重试一次；PowerShell 7 不做这种重试。目录名不能含路径；已有合适的已验证副本优先复用，其他已有目标拒绝覆盖。下载工具须在暂存和最终目录均成功探测并满足要求版本后才完成安装；移动后验证失败会删除该次新建目标，不登记失败副本。若工具已通过最终验证但地图写入失败，保留可用工具，通过 `add` 或 `scan` 恢复登记，不重复下载。没有可执行文件或版本验证失败时返回失败。

winget 是显式安装动作，通过找到的绝对入口调用，跳过 shim 安装器；商店执行别名可在明确的 winget 安装动作中被调用。安装位置由 winget 决定，升级卸载交给 winget。安装成功但无法发现文件会返回 installed_not_discovered，不能把它报告为完整成功。

## 扫描内核

`census.ps1 -Json [-Timing] [-Lang en] [-Deep]`；Unix 用 `census.sh --json [--timing] [--lang en] [--deep]`。

扫描内核 JSON 协议仍为 v1：schemaVersion、generatedAt、host、declarations、toolsRoot、mise、conventions、runtimes、resolution、warnings、timings、probeStats、summary。机器标识字段是稳定 ASCII，文案随语言变化。两平台有意保留平台字段差异。

计量字段（只量不改行为，附加字段，schemaVersion 不变）：

- `timings`：只在 `-Timing` / `--timing` 时填充，每项 `{phase, ms}`。两个内核共用阶段键 declarations、managed、conventions、roots、probe、deep-scan（仅 `-Deep`）、resolution、warnings，可逐阶段对比；path-index 只有 census.ps1 有。census.sh 在 bash 5 及以上用 EPOCHREALTIME 计到毫秒，bash 3.2（macOS 自带）只能到秒。
- `probeStats`：总是输出，`{launches, ms}`。launches 是为读版本而启动的外部进程数（含 mise 查询，不含 awk/sed 这类辅助进程），ms 是这些进程从启动到退出的累计毫秒；census.sh 在 bash 5 以下量不到耗时，ms 为 null。
- 所有版本探测都经由 toolkit-common.ps1 的统一执行器 `Invoke-ToolkitProbe`：shim 护栏在任何执行之前；同一进程内按 路径|长度|修改时间|参数 缓存，文件被替换或换参数即重新启动，命中缓存不计入 launches。缓存不落盘，跨次调用的复用仍只靠地图里的候选校验信息。
- `map.ps1 scan` 的结果带 `probeStats`：`launches`（census 子进程本身 1 个 + census 内的探测 + 地图侧的版本探测，命中探测缓存的不算）、`probeMs`、`wallMs`（整次扫描墙钟），以及分项 `census {launches, probeMs, wallMs}` 与 `map {launches, probeMs, throttle}`（throttle 为实际使用的探测并行度）。census 输出里没有 probeStats 时按 0 计。只出现在动作结果里，不写进 map.json。

扫描数据与文案外置在两个与脚本同目录的 TSV 里，census.ps1 与 census.sh 读同一份：

- `scripts/census-text.tsv`（key<TAB>lang<TAB>text）：所有面向人的文案，每个 key 中英都必须有；不再有 ps1: / sh: 前缀键。
- `scripts/census-data.tsv`（kind<TAB>os<TAB>value）：探测相对位置、conda 环境目录与解释器、候选根目录、解析层命令表、约定命令名，以及 bootstrap 脚本名与刷新命令；os 取 all / win / unix。平台差异（bootstrap 脚本名、刷新命令）写成 os = win / unix 行，读取时以占位符传给文案。

新增工具、探测相对位置、候选根目录或解析层命令只改 census-data.tsv，新增文案只改 census-text.tsv，不用改脚本。

告警：STUB、PATH_ORDER、SHADOWED、CONVENTION、PATH_DIRT、DRIFT、XDG_SHIFT、STRAY、UNDECLARED、MISSING、NO_MISE。它们只诊断工具层，不诊断端口、.env、应用依赖或后台服务。
