---
name: toolkit-map
description: "AI agent 的本机工具发现与选择层：调用工具前查询绝对路径、项目要求和验证状态；明确需要安装时才单独安装。避免把 PATH 解析当机器盘点，避免重复安装或改全局环境。"
---

# toolkit-map

先根据本 SKILL.md 的实际位置定位 `scripts/map.ps1`，使用它的绝对路径。**不要把 `./scripts/map.ps1` 当成用户当前项目下的文件**。

安装技能不会自动写入前端的全局规则。希望在各项目持续遵守本流程时，将简短调用规则接入前端支持的全局指令；仅单个项目使用时可运行 `setup -Project <目录>`。接入位置、可复制模板和生效验收见 [agent 接入指南](docs/agent-integration.md)。

## 调用流程

Windows 策略禁止直接执行脚本时，用当前 PowerShell 宿主以 `-NoProfile -ExecutionPolicy Bypass -File <地图脚本绝对路径> <动作与参数>` 单次调用；不修改全局执行策略，遵循组织组策略。

1. 执行 `<地图脚本绝对路径> status -Json`。没有地图时执行 `setup -Project <项目目录>`，或只执行 `scan`；过旧或 PATH 变化时重扫。
2. 执行 `<地图脚本绝对路径> find <工具> -Project <当前项目目录> -Json`。
3. 检查退出码、`ok`、`status`、`requirement`、`verification`。只有成功且已验证的结果默认可以直接使用 `path`。
4. 项目需要环境变量或配套工具时，通过已登记的 mise 执行 `mise exec -- <命令>`。

`find` 在地图没有合适副本时搜索 PATH、仓库和 mise 安装目录。失败只说明本次搜索范围没有合适副本，不代表全盘不存在，也不授权自动安装。

## 安装流程

先查地图和现场；只有明确需要时另行执行 `install <工具>@<版本>`。先用 `-WhatIf -Json` 查看计划。已有其他版本不代表项目要求的版本已满足。

下载前说明预计下载量、展开后的安装占用、实际目标目录及暂存/缓存位置，检查相关盘的可用空间。**仅预计安装占用 ≥1 GB 时询问位置**，下载包大小不触发询问；先问用户使用当前位置还是其他绝对目录，等回答再下载。体积未知时先核实估算；Rust、Android SDK 等预计达到门槛的工具即使精确体积未知也先确认。用户已有明确位置偏好且空间足够时复用，不重复询问；用户指定的门槛优先。

`-WhatIf` 不联网、不估算包体积；大小来自官方资产元数据/说明，未知就报告未知。`TOOLCHAIN_ROOT` 控制 portable 仓库，`TEMP` 控制安装暂存；管理器的数据和缓存目录另行配置。临时环境变量只在当前会话生效，持久化位置偏好需用户明确选择，不自动移动已有安装。详见 [存储与大工具安装](docs/storage.md)。

portable 工具落在 `~/toolchains/<工具>/<版本>/`；`-Via winget` 由包管理器决定安装位置。已有副本用 `add` 登记，不搬路径、不改全局 PATH。不安装 venv/site-packages/node_modules 等应用依赖到工具仓库。

## 动作

| 动作 | 用途 |
|---|---|
| `setup -Project <目录> [-WhatIf]` | 首次建图并接入项目 AGENTS.md；已有文件先备份；`-RulesFile` 可指定文件 |
| `doctor -Project <目录>` | 只读验证地图、宿主与接入文件；不证明模型行为 |
| `scan` | 完整扫描，保留手工副本、备注和偏好 |
| `status` | 完整扫描年龄、局部更新时间和 PATH 变化 |
| `find <工具> [-Project <目录>] [-Version <要求>]` | 动态选择；不满足时失败，不降级 |
| `add <工具> -Path <绝对路径> [-Note <文本>] [-Prefer]` | 登记已有文件；保存路径偏好 |
| `update [工具]` | 重探条目，不刷新完整扫描时间 |
| `install <工具>@<版本> [-WhatIf]` | 明确安装，可用 `-Url` / `-Sha256` 或 `-Via winget` |

所有动作支持 `-Json`；stdout 一个对象，协议 `schemaVersion: 2`。`ok:false` 时必须处理 `status`：`map_missing`、`map_corrupt`、`not_found`、`no_usable_candidate`、`version_mismatch`、`requirement_unsupported`、`map_busy` 等。

## 首选与护栏

项目要求 > 显式偏好 > 已验证副本的默认排序；`-Version` 可以显式覆盖项目要求。shim 永不作首选，IDE 运行时和 conda env 默认不参选。`-AllowUnverified` / `-AllowIdeHost` 只能在用户明确需要时使用，不能为了让查询成功而自行添加。

不执行 shim 探测版本；不把存在等同可用；不把未知要求判成满足。用 `source` 区分仓库、管理器、系统、手工和宿主副本。地图是索引，仓库是存放位置。

## 支持范围

完整地图动作仅限 Windows PowerShell 5.1/7；Unix 目前只有 census.sh 扫描内核。复杂 mise 配置交给管理器，不猜测其含义。

向用户报告时区分：项目要求什么、机器发现哪些副本、当前命令解析到谁。发现范围和验证状态都必须保留。

首次使用见 [README](README.md#首次接入一个项目)；遇到问题见 [故障排查](docs/troubleshooting.md)，撤销见 [卸载指南](docs/uninstall.md)。不把本机环境告警或 doctor 待处理项误报为安装失败。
