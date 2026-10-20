# toolkit-map

[中文](README.md) · [English](README-EN.md)

> 让 Windows 上的 AI 编程助手先查地图再调用工具，按项目声明选对版本。

## 核心能力

- **发现已有工具**：扫描 PATH、mise 安装目录、统一工具仓库（`~/toolchains`）与已登记路径，识别 shim、未验证副本和 IDE 内置运行时。
- **按项目选版本**：读取 `mise.toml`、`.tool-versions`、`.nvmrc`、`.python-version` 与 `package.json` 的 `engines`，选出满足声明的已验证副本。
- **不降级**：声明要求的版本没有已验证副本时返回 `version_mismatch`，不返回错误版本的调用路径。
- **接入 agent**：`setup` 把规则写入当前项目的 `AGENTS.md`（或 Cursor MDC、Claude Code 规则），新开会话即可生效。
- **只读探测**：扫描不执行 shim、不安装工具、不改 PATH；安装是单独的 `install` 操作。
- **JSON 输出**：所有动作支持 `-Json`，stdout 一个对象；检查 `ok`、`status`、`verification` 后再调用工具。

需要 Windows PowerShell 5.1 / 7 与 Git；macOS / Linux 目前只有 `census.sh` 扫描内核。

## 首次接入一个项目

在要接入的项目目录打开 PowerShell，按顺序执行：

```powershell
$project = (Get-Location).Path
$installDir = Join-Path $env:USERPROFILE 'Projects\toolkit-map'
git clone --branch v0.3.0 --depth 1 https://github.com/haxsd/toolkit-map $installDir
$map = Join-Path $installDir 'scripts\map.ps1'
$ps = (Get-Process -Id $PID).Path
function toolkit { & $ps -NoProfile -ExecutionPolicy Bypass -File $map @args }
toolkit setup -Project $project -WhatIf -Json   # 预览
toolkit setup -Project $project                 # 首次建图并写入项目规则
toolkit doctor -Project $project -Json
```

`setup` 首次建图并把规则写入当前项目的 `AGENTS.md`：已有内容保留、修改前备份；不安装运行时、不改 PATH。`doctor` 返回 `ok: true` 即就绪。没有 Git 时，从 [Releases](https://github.com/haxsd/toolkit-map/releases/latest) 下载 `toolkit-map-v0.3.0.zip`，按 [ZIP 接入指南](docs/agent-integration.md#没有-git-时从-zip-接入) 操作。

## 常用命令

```powershell
toolkit status -Json
toolkit find node -Project $project -Json
toolkit add node -Path 'C:\existing-node\node.exe' -Json
toolkit install rg@latest -WhatIf -Json
```

`find` 的选择顺序：`-Version` > 项目声明 > 父目录 / 全局声明 > 系统默认（PATH 上的那个）。没有声明时尊重系统默认，不会自动选到最新版本。

## 文档

- [参考手册](docs/reference.md)：命令、JSON 协议 v2、声明与选择规则
- [agent 接入指南](docs/agent-integration.md)：Cursor、Codex、Claude Code 与 ZIP 接入
- [故障排查](docs/troubleshooting.md) · [撤销接入与卸载](docs/uninstall.md)
- [平台说明](docs/platform-notes.md)

## 许可证

[MIT](LICENSE)。本机地图（`~/.toolkit/map.json`）、已装工具、缓存与凭据不进入发布包。
