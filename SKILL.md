---
name: toolkit-map
description: "本机工具地图：agent 要用任何工具（运行时、编译器、CLI、逆向/渗透工具）之前，先查地图拿到确定的绝对路径——而不是靠 PATH 解析或自己猜。地图里没有就装进统一仓库再登记。当需要确认某个命令实际会跑哪个文件、机器上同一工具存在多份副本、要装一个新工具又不想把机器搞乱，或接手一台陌生机器需要先摸清工具链时使用。Use when you need to know which binary a command will actually run, when a machine has several copies of the same tool, when installing a new CLI without polluting the machine, or when orienting yourself on an unfamiliar machine's toolchain."
---

# toolkit-map —— 先查地图，再动手

## 一句话

**要用工具之前，先 `find` 一次拿绝对路径；地图里没有，就 `install` 到统一仓库再登记。**

不要用 `Get-Command` / `where.exe` / `Test-Path` / 手工比较 PATH 去推测"该用哪个"——
本地实测过：这样推测会错（同一个命令名在旧会话和新会话里跑的不是同一个文件）。

## 铁律

1. **开工前先确认地图存在**：`scripts/map.ps1 status`。没有地图或提示过旧 → `scripts/map.ps1 scan`。
2. **调用任何工具前先 `find`**：`scripts/map.ps1 find <tool> -Json`，用返回的 `path` 执行。
   返回值里还有 `candidates`——**多份副本是常态**，看它们是为了别用错，不是为了挑一个顺手的。
3. **不许猜**。地图没收录 → `find` 会现场搜一次；搜索也找不到 → 按第 4 条装。
4. **装新工具只走 `install`**：`scripts/map.ps1 install <tool>@<版本>`。
   它内部会按 portable 归档 → 解包安装器 → 包管理器 的顺序降级，装完自动登记进地图。
   **不要**手工下载解压到随手找的位置，也不要往 PATH 里加目录。
5. **项目内有自己的版本声明时，以项目为准**，用 `mise exec -- <命令>` 执行；
   机器级声明只代表"这台机器提供哪些版本"。地图给的是机器事实，项目声明是项目意图。
6. **已有的副本不迁移**。发现地图里没有的副本 → `add` 登记；发现地图过时 → `update`。
   搬动别人的路径可能断掉项目配置、IDE 设置或 CI 脚本。

## 五个动作

| 命令 | 什么时候用 | 会做什么 |
|---|---|---|
| `map.ps1 scan` | 第一次用；距离上次超过 24 小时；装了/卸了东西之后 | 扫描本机，重建地图（复用 census 的扫描内核） |
| `map.ps1 status` | 每次开工前 | 地图在不在、多旧、有没有候选路径失效、PATH 变没变 |
| `map.ps1 find <tool> [-Json]` | 要用某工具前 | 返回首选绝对路径 + 版本 + 来源 + **其他候选**；地图没有就现场搜一次 |
| `map.ps1 add <tool> -Path <绝对路径> [-Version v] [-Note 说明]` | 发现地图里没有的副本 | 登记进地图，不搬路径 |
| `map.ps1 update [<tool>]` | `find` 的结果与实际不符时 | 重探：路径消失就移除、版本变了就更新、发现新副本就登记 |
| `map.ps1 install <tool>@<版本>` | 地图和现场都没有 | 装进统一仓库（`~/toolchains/<工具>/<版本>/`）并设为首选 |

## 地图在哪、长什么样

- `~/.toolkit/map.json`（机器可读；`TOOLKIT_MAP` 可覆盖），同名 `.md` 是人类可读摘要
- 每个工具：一个 `preferred` + 若干 `candidates`。关键字段：
  - `source`：`warehouse`（我们的统一仓库）｜`manager`（mise 等）｜`manual`（手装）｜
    `system`（系统安装）｜`ide-host`（IDE 自带）｜`conda-base` / `conda-env`
  - `reachable`：这个文件所在的目录在不在 PATH 上（**存在 ≠ 可用 ≠ 会生效**，三层分开记）
  - `isShim`：是间接层（如 `mise\shims\`），**只登记、不执行**——执行 shim 可能触发自动安装
  - `note`：为什么这条要小心（IDE 自带、conda 环境内、shim、商店别名占位……）

**首选规则**：声明匹配 → 仓库里装的 → 能被 PATH 解析的具体二进制 → 来源优先级 → 版本高者。
shim 不会被选为首选（它指向谁可能变），环境内的副本（conda env）默认不参选。

## 只读护栏

- 扫描/探测**绝不执行 shim 类路径**（会触发管理器自动安装，实测踩过：装出了第二份 gh）。
- 扫描**绝不修改**机器状态：不写 PATH、不动已有副本、不卸载任何东西。
- 只有 `install` 会改状态，且只改统一仓库里的那一份。

## 不做什么

- 不管应用依赖（venv、node_modules、pip/npm 装的库）——那些离开环境没有意义，不进地图。
- 不管应用环境诊断（端口、`.env`、依赖目录、执行位）。
- 不替代包管理器：mise 负责"项目里用哪个版本"，本技能负责"机器上哪个文件是可用的、装哪儿"。
