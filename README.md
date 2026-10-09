# toolkit-map

**让 AI 编程助手优先复用已经安装的工具，并按项目要求选对版本。**

[![CI](https://github.com/haxsd/toolkit-map/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/haxsd/toolkit-map/actions/workflows/ci.yml)
[![版本](https://img.shields.io/github/v/release/haxsd/toolkit-map)](https://github.com/haxsd/toolkit-map/releases/latest)
[![MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Windows](https://img.shields.io/badge/Windows-PowerShell%205.1%20%2F%207-blue)](docs/platform-notes.md)

适合在 **Windows 本机**用 Cursor、Codex 或 Claude Code 开发，尤其是有多个工具版本、工具散落在不同目录的机器。接入方式是本地 PowerShell 脚本与 agent 规则，无需安装 mise。macOS / Linux 目前只有扫描内核，尚不支持完整地图流程。

[开始使用](#首次接入一个项目) · [其他前端与全局接入](docs/agent-integration.md) · [遇到问题](docs/troubleshooting.md) · [撤销接入](docs/uninstall.md)

## 30 秒看懂它做什么

假设 PATH 上是 Node 16，机器另有 Node 22，而项目声明需要 Node 22：

| 场景 | toolkit-map 的结果 | agent 接下来做什么 |
|---|---|---|
| 发现可验证的 Node 16、22 | 选择满足项目要求的 Node 22，返回绝对路径 | 用该路径调用工具 |
| 本次范围只发现 Node 16 | 返回 `version_mismatch`，不给错误版本的调用路径 | 报告缺口；明确需要安装时再单独处理 |
| 声明无法解释 | 返回 `requirement_unsupported` | 澄清要求或交给管理器，不猜版本 |

成功查询的关键字段如下（示例路径，不是你本机的清单）：

```json
{
  "ok": true,
  "status": "ok",
  "path": "C:\\tools\\node\\22\\node.exe",
  "version": "22.23.2",
  "verification": "verified",
  "requirement": { "version": "22", "scope": "project", "source": "C:\\project\\mise.toml" }
}
```

`node --version` 只说明当前 PATH 调用了谁；地图把项目要求、发现的副本与调用路径分开。查询不安装工具；默认不选 shim、未验证文件或 IDE 内置运行时。搜索范围不是全盘穷尽。

## 首次接入一个项目

推荐先在一个 Cursor 或 Codex 项目中试用，确认成功后再配置跨项目的全局规则。需要 **Windows PowerShell 5.1 / PowerShell 7、Git**。源码发布 ZIP 约 170 KB，工具仓库与实际工具另行存放。

### 1. 下载稳定版

**在你要接入的项目目录打开 PowerShell**，在同一个终端按顺序执行。当前目录就是项目路径，无需反复替换盘符。

```powershell
$project = (Get-Location).Path
$installDir = Join-Path $env:USERPROFILE 'Projects\toolkit-map'
git clone --branch v0.3.0 --depth 1 https://github.com/haxsd/toolkit-map $installDir
if ($LASTEXITCODE -ne 0) { throw '下载未完成。已有安装请按升级指南处理，不要覆盖。' }
$map = Join-Path $installDir 'scripts\map.ps1'
$ps = (Get-Process -Id $PID).Path
```

已有安装见[升级步骤](docs/agent-integration.md#升级与刷新规则)。没有 Git 或希望下载 ZIP 时，改走 [ZIP 接入路线](docs/agent-integration.md#没有-git-时从-zip-接入)，它使用系统 PowerShell 验证地图。

### 2. 预览并接入

检查下载的源码后，使用当前 PowerShell 宿主单次运行脚本；这不会修改全局执行策略。组织组策略的限制需遵循组织要求。

```powershell
& $ps -NoProfile -ExecutionPolicy Bypass -File $map setup -Project $project -WhatIf -Json
& $ps -NoProfile -ExecutionPolicy Bypass -File $map setup -Project $project
& $ps -NoProfile -ExecutionPolicy Bypass -File $map doctor -Project $project -Json
& $ps -NoProfile -ExecutionPolicy Bypass -File $map find git -Project $project
```

预览返回 `status: planned`；`setup` 首次建图并将规则写入当前项目的 `AGENTS.md`，已有内容保留、修改前备份。首次扫描可能需要等待，耗时取决于候选数量与探测情况。它不安装运行时、不改 PATH。

`doctor` 正常时返回 `ok: true`、`status: ok`；Git 查询显示绝对路径、版本和 `验证 verified`。`attention_required` 需按 `checks` 排查，见[故障排查](docs/troubleshooting.md)。先查 Git 是因为下载前已要求安装它，首次成功无需另外安装 Node。

### 3. 在 agent 中验收

在同一项目新开 Cursor Agent Chat 或 Codex 会话，发送：

> 根据本项目的工具发现规则，查询 Git。先不安装、不改环境；报告项目要求、发现的副本、所选绝对路径及验证状态。验证通过后，用这个绝对路径执行 `--version`。

成功标志是看到 agent **实际调用地图，再调用返回的工具路径**。`doctor` 只检查本机配置，不能证明模型已加载或遵守规则。模型直接调用裸 `git` 时，按[规则未生效的排查步骤](docs/troubleshooting.md)处理。

## 能力范围

| 能力 | 当前支持 | 边界 |
|---|---|---|
| 发现已有工具 | 已登记路径、PATH、统一仓库、mise 安装目录，以及扫描内核识别的位置 | 非穷尽全盘；其他位置可用 `add` 登记 |
| 验证与选择 | 运行时与 CLI 的路径、版本、验证状态；按项目要求选择 | 未知工具默认尝试 `--version`；特殊参数需适配器 |
| 项目声明 | 常见 mise、`.tool-versions`、Node/Python 版本文件和 Node `engines` | 轻量读取器，不解释完整 TOML/mise 环境语义 |
| portable 安装 | gh、jadx、rg/ripgrep、fd（Windows x64）、adb；自定义 ZIP | 不自动安装所有能发现的工具；下载版本在最终位置再次验证 |
| 安装器 | 明确使用 `-Via winget` | 位置由包管理器决定 |
| 平台 | Windows PowerShell 5.1 / 7 支持完整地图 | Unix 目前仅 `census.sh` 扫描 |

## 常用命令

下面假定已设置 `$ps`、`$map`、`$project`。每个动作都支持 `-Json`，stdout 一个 JSON 对象；检查退出码、`ok`、`status`、`requirement` 和 `verification` 后再调用工具。

```powershell
& $ps -NoProfile -ExecutionPolicy Bypass -File $map status -Json
& $ps -NoProfile -ExecutionPolicy Bypass -File $map find node -Project $project -Json
& $ps -NoProfile -ExecutionPolicy Bypass -File $map add node -Path 'C:\existing-node\node.exe' -Json
& $ps -NoProfile -ExecutionPolicy Bypass -File $map install rg@latest -WhatIf -Json
```

完整命令、结果状态、适配器与声明规则见[参考手册](docs/reference.md)。全局规则、Claude Code、Cursor MDC 和可选技能安装见[agent 接入指南](docs/agent-integration.md)。

## 常见问题

- **会把工具搬走或改 PATH 吗？** 扫描和接入不会；已有副本留在原处。`install` 是单独的明确操作。`bootstrap` 是可选环境配置，会修改机器，不在上述接入流程中。
- **必须用 mise 吗？** 无需安装 mise 也能发现、登记和查询工具；项目需要完整管理器环境时再使用 mise。
- **工具默认放 C 盘吗？** 地图默认在 `~/.toolkit/map.json`，新 portable 工具默认在 `~/toolchains`。`TOOLCHAIN_ROOT` 可改仓库位置，`TEMP` 与管理器缓存需分别考虑。接入规则仅在预计安装占用 **≥1 GB** 时询问位置，CLI 本身不估算或弹窗。见[存储指南](docs/storage.md)。
- **能撤销吗？** 可以移除接入规则与技能链接，保留已有工具；见[撤销与卸载](docs/uninstall.md)。
- **升级后会自动生效吗？** 源码更新不等于旧规则更新。文件规则重跑 `setup`；Cursor 全局 User Rules 重新生成并粘贴；随后新开会话验收。
- **怎么反馈问题？** 先看[故障排查](docs/troubleshooting.md)，再使用 [问题/建议模板](https://github.com/haxsd/toolkit-map/issues/new/choose)，提供复现步骤与相关诊断结果。

## 贡献与进一步了解

[参考手册](docs/reference.md) · [agent 接入](docs/agent-integration.md) · [平台说明](docs/platform-notes.md) · [存储指南](docs/storage.md) · [贡献指南](docs/contributing.md) · [更新记录](CHANGELOG.md)

源码、协议、通用示例与配方使用 [MIT](LICENSE) 许可。本机地图、工具、缓存和凭据不进入发布包。
