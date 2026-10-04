# 故障排查

本页面向已经按 [agent 接入指南](agent-integration.md) 接入后出现问题的场景。命令契约与状态含义见 [参考手册](reference.md)。

先定位你本机的脚本绝对路径，并在每个命令里显式带入当前项目。不要把 `./scripts/map.ps1` 当成当前项目下的文件：

```powershell
$map = "$env:USERPROFILE\Projects\toolkit-map\scripts\map.ps1"   # 换成你本机真实绝对路径
$project = (Get-Location).Path  # 先在要接入的项目打开 PowerShell
$ps = (Get-Process -Id $PID).Path
```

失败时先读 `-Json` 输出里的 `ok`、`status`、`requirement`、`verification`，不要只看退出码。**退出码非零表示本动作未成功，不等于“安装坏了”**：`not_found`、`version_mismatch` 是对本次搜索范围的结论，`doctor` 返回 1 只表示有待处理检查项，都不授权自动安装或改全局环境。

## 脚本被策略拦下

- 症状：直接 `& $map status -Json` 报“禁止运行脚本”“未经数字签名”。
- 动作：不改全局执行策略，遵循组织组策略。用当前宿主单次调用（换你的真实绝对路径）：
  ```powershell
  & $ps -NoProfile -ExecutionPolicy Bypass -File $map status -Json
  ```

## 地图不存在（map_missing）

- 症状：`status` 返回 `status:map_missing`，找不到地图文件。
- 动作：首次建图并接入项目，或只重扫：
  ```powershell
  & $ps -NoProfile -ExecutionPolicy Bypass -File $map setup -Project $project -Json
  ```

## 地图损坏（map_corrupt / schema_unsupported）

- 症状：返回 `map_corrupt`、`schema_unsupported` 或地图无法解析。
- 动作：`scan` 不会覆盖损坏或未来格式的地图。先确认实际地图绝对路径（默认 `~/.toolkit/map.json`，尊重 `TOOLKIT_MAP` / `-MapFile`），备份并将旧文件改名保留；随后才在原路径执行 `scan` 重建。手工登记与备注需从备份恢复；不要直接删掉备份。未来格式应先核对所用版本是否支持。

## 项目目录不存在（invalid_project / operation_failed）

- 症状：提示项目目录不存在，常见于照抄占位路径、仍使用旧项目路径。
- 动作：在真实项目目录打开 PowerShell 后重新设置 `$project = (Get-Location).Path`；源码安装目录 `$map` 和项目 `$project` 是两个不同位置。检查目录时不要顺手创建一个占位项目绕过错误。

## 找不到候选（not_found）

- 症状：`find` 返回 `status:not_found`，`search.complete:false`。
- 动作：这只说明**本次搜索范围**没有合适副本，不代表全盘不存在，也不授权安装。可查看已发现候选与范围，必要时明确安装：
  ```powershell
  & $ps -NoProfile -ExecutionPolicy Bypass -File $map find node -Project $project -Json
  ```

## 有副本但版本不符（version_mismatch）

- 症状：`status:version_mismatch`，存在副本但不满足项目要求。
- 动作：不降级、不改全局。先确认项目要求（`requirement` 字段），再决定是登记合适的已有副本还是明确安装：
  ```powershell
  & $ps -NoProfile -ExecutionPolicy Bypass -File $map find node -Project $project -Json
  ```
  已有合适副本用 `add node -Path <真实二进制绝对路径>` 登记后重新查询。本项目没有 Node/Python/Rust 的 portable 安装配方；确需安装时，通过项目采用的管理器另行处理，不照抄 `install node@22`。`-Version` 会覆盖项目要求，只有已确认具体需求时才显式使用。

## 要求无法判定（requirement_unsupported）

- 症状：`status:requirement_unsupported`，如复杂 mise 配置、`[tools.node]` 表或 LTS 别名。
- 动作：不会忽略项目要求后退回全局版本。改为受支持的字符串声明，或显式传 `-Version`；复杂管理器配置交给管理器处理。

## doctor 有待处理项（attention_required）

- 症状：`doctor` 返回 `status:attention_required`，退出码 1；`agentVerified` 始终为 `false`。
- 动作：逐项读 `checks`：`map` 不通过先建图，`integration` 不通过核对指定规则文件与脚本路径，`freshness` 不通过重扫并检查失效登记，`host` 不通过使用受支持的宿主。修复操作与只读诊断分开：
  ```powershell
  & $ps -NoProfile -ExecutionPolicy Bypass -File $map doctor -Project $project -Json
  ```
  它不访问账号/UI 规则，也不证明模型行为。

## 模型似乎未加载规则

- 症状：agent 直接调用裸 `node`，没先查地图。
- 动作：确认存在一个 agent 能读到的持久入口（全局或项目）。文件接入重新 `setup` 更新标记块；Cursor 全局 UI 接入重新生成并替换 `preview`：
  ```powershell
  & $ps -NoProfile -ExecutionPolicy Bypass -File $map setup -Project $project -Json
  (& $ps -NoProfile -ExecutionPolicy Bypass -File $map setup -Project $project -WhatIf -Json | ConvertFrom-Json).preview
  ```
  检查脚本路径是否与分析范围一致、是否与更具体的规则冲突。不要靠“是否遵守”自述判断，改成实际观察。

## 首次扫描需要等待

- 症状：第一次 `setup`/`scan` 耗时较长，或返回 `map_busy`。
- 动作：完整扫描需要读取大量 PATH 与仓库位置，属正常。`map_busy` 表示其他进程持有更新锁，可稍后重试；可用 `-LockTimeoutSeconds` 调整等待（默认 60 秒，0–300）。

## 浏览器下载的 ZIP 被拦截

从 Release 同时下载源码 ZIP 和 `SHA256SUMS.txt`，用 `Get-FileHash -LiteralPath <ZIP绝对路径> -Algorithm SHA256` 比对 ZIP 的校验值。确认来源和校验一致后，在 ZIP 文件属性中解除锁定，再解压。若组织策略仍禁止执行，按组织要求处理，单次 Bypass 不能覆盖组策略。

## 验收

按 [agent 接入指南的验收步骤](agent-integration.md) 新开一个会话，让 agent 报告项目要求、发现的候选、所选 `path` 与 `verification`，并**先不安装**。
