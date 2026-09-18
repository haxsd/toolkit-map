# 参考手册

本文件描述三件事：`map.ps1` 的动作与参数、地图文件的格式、以及扫描内核 `census.ps1` 的输出契约。

## 1. map.ps1

```
map.ps1 <动作> [参数] [开关]
```

| 动作 | 参数 | 做什么 |
|---|---|---|
| `scan` | — | 调用 census 扫描本机，重建地图（`~/.toolkit/map.json` 与同名 `.md`） |
| `status` | — | 地图是否存在、扫描时间、候选失效数、PATH 是否变过；给出是否该重扫的建议 |
| `find` | `<工具名>` | 返回首选绝对路径 + 版本 + 来源 + 其他候选；地图里没有就现场搜一次，找到即登记，找不到只报告缺失 |
| `add` | `<工具名> -Path <绝对路径>` | 登记一个已有副本（不搬路径）。可选 `-Version`、`-Note`、`-Prefer` |
| `update` | `[<工具名>]` | 重探：路径消失就移除、版本变了就更新、发现新副本就登记；省略工具名则全量 |
| `install` | `<工具名>@<版本\|latest>` | 明确需要安装且确认本机没有后，装进统一仓库并登记为首选。也可 `install <工具名> -Url <zip 直链> [-Sha256 <校验值>]` |

通用开关：

| 开关 | 作用 |
|---|---|
| `-Json` | 机器可读输出（agent 用这个） |
| `-MapFile <路径>` | 覆盖地图位置（默认 `~/.toolkit/map.json`，也可用环境变量 `TOOLKIT_MAP`） |
| `-SkipScan` | `find` 时不要现场搜索，只在现有地图里查 |
| `-WhatIf` | `install` 只打印计划，不下载不安装 |
| `-Sha256 <校验值>` | `install` 下载归档后校验 SHA256；接受 64 位十六进制值，可带 `sha256:` 前缀 |
| `-MaxAgeHours <小时>` | `status` 判断"过旧"的阈值，默认 24 |

退出码：`0` 成功；`find` 找不到工具时退出码 `1`。这只表示本次查找没有发现可用副本，
不会自动安装；只有明确需要安装时，才另行执行 `install`。

地图文件和统一仓库都是使用者本机状态，不会写入或随 GitHub 仓库发布；本手册中的路径和工具名均为通用示例。

## 2. 地图文件

```jsonc
{
  "schemaVersion": 1,
  "scannedAt": "2026-09-18T13:55:57+08:00",
  "warehouse": "C:\\Users\\<你>\\toolchains",
  "pathSnapshot": "……当时的 PATH，用于检测机器是否变过",
  "censusSummary": { "warnings": ["SHADOWED", "STRAY"], "counts": { "runtimes": 22, "declarations": 1 } },
  "tools": {
    "gh": {
      "preferred": "system-2.101.0",
      "candidates": [
        {
          "id": "system-2.101.0",
          "version": "2.101.0",
          "path": "C:\\Program Files\\GitHub CLI\\gh.exe",
          "source": "system",
          "reachable": true,
          "isShim": false,
          "note": ""
        }
      ]
    }
  }
}
```

候选字段：

| 字段 | 含义 |
|---|---|
| `id` | 工具内唯一标识，`preferred` 指向它 |
| `version` | 版本号（探测不到则为空，例如 shim 与商店别名不探测） |
| `path` | **绝对路径**——agent 要执行的就是它 |
| `source` | `warehouse`（统一仓库）｜`manager`（mise 等）｜`manual`（手装）｜`system`（系统安装）｜`ide-host`（IDE 自带）｜`conda-base` / `conda-env` |
| `reachable` | 该文件所在目录是否在 PATH 上。**存在 ≠ 可用 ≠ 会生效**，三层分开记 |
| `isShim` | 是间接层（如 `mise\shims\`）。只登记、**不执行**：执行 shim 可能触发管理器自动安装 |
| `note` | 为什么这条要小心（IDE 自带、conda 环境内、shim、商店别名占位……） |

**首选规则**（`Select-Preferred`）：

1. 若该工具在某份声明里被点名 → 只在**满足声明的具体二进制**里选（shim 不参与这一步）
2. 环境内的副本（`conda-env`）默认不参选
3. 排序：仓库里装的 → 能被 PATH 解析的具体二进制 → 能被 PATH 解析的 shim → 其余
4. 同层比来源：`warehouse` → `manager` → `manual` → `system` → `ide-host` → `conda-base`
5. 最后比版本，高者优先

## 3. 安装配方

`install` 内置四个 GitHub portable 配方（`gh`、`jadx`、`ripgrep`、`fd`）和一个固定 URL 配方（`adb`）。
只能走安装器的工具可用 `-Via winget` 兜底；这类工具登记真实安装路径，但不保证落在统一仓库。
其他 portable 工具用 `-Url` 给直链，或人工安装后再用 `map.ps1 add` 登记。提供 `-Sha256` 时，
下载归档必须通过校验；目标版本目录已存在时安装会直接失败，不会删除或覆盖已有目录。
配方把 **发布 tag** 与 **资产文件名** 分开写——同一个项目的这两者 `v` 前缀经常不一致
（jadx 的 tag 是 `v1.5.6`，资产却叫 `jadx-1.5.6.zip`）。版本号一律按裸版本处理，
`@latest` 走 GitHub API 解析最新发布。

落点固定为 `<TOOLCHAIN_ROOT>/<工具>/<版本>/`；归档里若多一层同名目录会被压平，
保证"仓库里一律长这样"。

## 4. 扫描内核：census.ps1 / census.sh

`map.ps1 scan` 直接调用 `census.ps1 -Json`，不重复实现盘点。两者也可以单独使用。

| 参数 | 作用 |
|---|---|
| `-Json` / `--json` | 机器可读输出（`schemaVersion` 目前为 1） |
| `-Timing` / `--timing` | 各阶段耗时（随语言与平台，阶段集合略有差异） |
| `-Lang en` / `--lang en` | 英文输出；默认中文 |
| `-Deep` / `--deep` | 宽松深扫（慢，默认关闭） |
| `-ToolsRoot` / `--tools-root` | 覆盖规范根（默认 `~/toolchains`） |

JSON 字段：`schemaVersion`、`generatedAt`、`host`、`declarations`、`toolsRoot`、`mise`、
`conventions`、`runtimes`、`resolution`、`warnings`、`timings`、`summary`。
`runtimes[].pattern`、`source`、`placement`、`warnings[].kind` 都是**稳定的 ASCII 标识符**；
`warnings[].message` / `action` 是散文，跟随 `--lang`。

告警代码：`STUB`（命令指向跑不起来的文件）、`PATH_ORDER`（解析到的版本不满足声明）、
`SHADOWED`（同一工具存在多份副本）、`CONVENTION`（只存在于文件名的命名约定）、
`PATH_DIRT`（PATH 里有重复或带引号的条目）、`DRIFT`（模板与部署副本不一致）、
`XDG_SHIFT`（`XDG_CONFIG_HOME` 让 mise 全局配置搬了家）、`STRAY`（游离副本）、
`UNDECLARED`（项目有版本约束却没有声明文件）、`MISSING`（声明了但没装）。

## 5. 平台差异（有意保留）

两份实现共享一份文档化的字段，但不要求结构逐字段一致：
`host.powershell` 与 `mise.tools[].installPath/source/managed` 只在 PowerShell 版里出现，
因为它们描述的是 Windows 上才有的事实。消费按上面的字段表读即可。
