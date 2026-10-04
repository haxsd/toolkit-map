# toolkit-map

供 AI agent 使用的本机工具发现与选择层。发现机器上已有的副本，按项目要求选择可验证的调用路径，减少错版本、重复安装和全局环境改动。

**项目声明、机器可用副本、当前 PATH 解析是三件事。** `node --version` 只能说明当前命令运行了哪个版本，不能说明机器上只有这个版本。

**安装后还需要接入 agent 的规则。** 想在所有项目中使用，配置前端的全局规则；只在某个项目使用，配置项目规则即可。克隆仓库或安装技能不会自动修改 Cursor 等前端的全局设置，也不能证明 agent 已开始查询地图。

## 先选择接入位置

| 前端 | 跨项目使用 | 只在当前项目使用 |
|---|---|---|
| Cursor | 在 Customize → Rules 的 User Rules 中粘贴参考规则 | `setup` 生成项目 `AGENTS.md`，或使用 `alwaysApply: true` 的 `.cursor/rules/toolkit-map.mdc` |
| Codex | `CODEX_HOME/AGENTS.md`，默认 `~/.codex/AGENTS.md` | `setup` 生成项目 `AGENTS.md` |
| Claude Code | `~/.claude/CLAUDE.md` | 用 `setup -RulesFile` 写入项目 `CLAUDE.md` |
| 其他本机 agent | 其官方支持的全局指令入口 | 其官方支持的项目规则文件 |

从 [通用参考规则](templates/agent-tool-rules.md) 开始，**将占位路径替换为你本机 `scripts/map.ps1` 的绝对路径**。Cursor 项目规则可用 [MDC 模板](templates/cursor-toolkit-map.mdc)。具体步骤、自动生成规则的命令和生效验收见 [agent 接入指南](docs/agent-integration.md)。规则针对能访问这台机器的 agent；远程/cloud agent 需要在自己的执行机器安装和建图。

## 三分钟接入（Windows）

需要 Windows PowerShell 5.1 或 PowerShell 7，以及 Git。安装过程不改 PATH、不安装运行时。

```powershell
git clone --branch main --depth 1 https://github.com/haxsd/toolkit-map "$env:USERPROFILE\Projects\toolkit-map"
$map = "$env:USERPROFILE\Projects\toolkit-map\scripts\map.ps1"

# Windows 默认执行策略若禁止脚本，仅为当前终端会话放行。
# 先检查下载的源码；此设置不会修改用户级或系统级策略。
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# 先预览生成的接入规则；把目录替换成你的项目。
& $map setup -Project 'D:\your-project' -WhatIf -Json
& $map setup -Project 'D:\your-project'
& $map doctor -Project 'D:\your-project' -Json
& $map find node -Project 'D:\your-project' -Json
```

`setup` 在地图不存在时首次扫描，随后在项目 `AGENTS.md` 中加入带绝对路径的规则。已有内容保留，修改前备份；重复执行不会产生重复区块。也可用 `-RulesFile <绝对路径>` 明确指定接入文件。`-WhatIf` 只返回计划，不扫描、不写文件、不联网。

组织的组策略可能禁止会话级放行，此时遵循组织要求。也可单次调用 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File $map <动作与参数>`。从浏览器下载 ZIP 时，解压前先检查来源与 Release 校验值，再解除 ZIP 的下载标记（文件属性 → 解除锁定）。

上面获取的是主分支源码和最新接入模板；固定版本源码包见 [GitHub Releases](https://github.com/haxsd/toolkit-map/releases)。v0.2.0 已支持 `setup` / `-RulesFile`；生成大工具位置确认规则需 v0.2.1，或者手工复制最新模板。升级后需刷新已接入的规则，具体步骤见 [agent 接入指南](docs/agent-integration.md)。

新开一个 agent 会话，请它查找一个工具。确认它实际先调用了地图，并依据返回的 `requirement`、`verification` 使用路径。`doctor` 能检查文件配置，不能证明前端已把规则交给模型或模型会遵守。

### 可选：安装为技能

仓库根目录的 `SKILL.md` 是使用协议；脚本相对技能目录定位，不能依赖 agent 当前工作目录。

```powershell
New-Item -ItemType Junction -Path "$env:USERPROFILE\.agents\skills\toolkit-map" -Target "$env:USERPROFILE\Projects\toolkit-map"
# Cursor 可将联接放在 ~/.cursor/skills/toolkit-map。
```

不同前端的技能发现方式不同。技能提供按需加载的使用说明；想持续执行“调用工具前先查地图”，仍建议用上面的全局或项目规则明确要求。用户级文件可用 `-RulesFile` 指定，Cursor 账号内的 User Rules 需手工粘贴。详见 [agent 接入指南](docs/agent-integration.md)。

## 常用动作

| 动作 | 用途 |
|---|---|
| `setup -Project <目录>` | 首次建图并生成接入规则；可用 `-WhatIf` 预览 |
| `doctor -Project <目录>` | 只读检查宿主、地图、新鲜度和接入文件 |
| `scan` | 完整盘点，保留仍存在的手工登记、备注与显式偏好 |
| `status` | 完整扫描年龄、条目更新时间、失效路径和 PATH 变化 |
| `find <工具>` | 按当前项目声明选择；缺少匹配版本时明确失败 |
| `add <工具> -Path <路径>` | 登记已有副本；`-Note` 留备注，`-Prefer` 保存偏好 |
| `update [工具]` | 重探条目；不把局部更新当成完整扫描 |
| `install <工具>@<版本>` | 明确需要时安装；`-WhatIf` 只返回计划 |

所有动作都支持 `-Json`，stdout 恰好一个 JSON 对象。成功退出码 0，失败或需要处理时非零；请同时检查 `ok` 和 `status`。

```powershell
& $map find node -Project 'D:\old-project' -Json
& $map find node -Version 22 -Json
& $map find ripgrep -Json       # 与 rg 使用同一清单，兼容旧 ripgrep 仓库目录
& $map install rg@latest -WhatIf -Json
```

## 为什么 agent 可以依据它作决定

- **发现与选择分开**：全局地图缓存机器事实；`find` 每次读取当前或指定项目的要求，不保存某个项目的选择作为机器全局要求。
- **缺版本不降级**：`version_mismatch` 带要求、候选与搜索范围，不会返回不满足要求的路径。
- **验证状态明确**：已验证、未验证、不可用与跳过探测分别记录。默认只选择已验证副本；普通零字节文件不能被选中。
- **shim 不执行、不作首选**：护栏贯穿扫描和地图探测，覆盖自定义 shim 目录；IDE 内置运行时和 conda 环境默认不作首选。
- **已有安装不搬家**：新 portable 工具进统一仓库；登记和扫描不改 PATH，不卸载现有工具。
- **更新不丢记录**：稳定路径 ID、原子写入和进程锁保护地图；损坏或未来格式的地图会报错，不会被当空地图覆盖。

`find` 返回的是可执行文件路径。需要项目环境变量或配套工具时，通过已登记的 mise 执行 `mise exec -- <命令>`，不要把一个二进制路径当成完整工具链环境。

## 地图与仓库

- 地图：`~/.toolkit/map.json`，同名 `.md` 是摘要；`TOOLKIT_MAP` 或 `-MapFile` 可覆盖。
- 统一仓库：`~/toolchains/<工具>/<版本>/`；`TOOLCHAIN_ROOT` 可覆盖。
- `scannedAt` 只记录完整扫描；`updatedAt` 记录条目变更；候选有独立 `checkedAt`。
- 地图与工具仓库都是使用者本机状态，不进入 GitHub 仓库或发布包。

### 大工具不必放在 C 盘

Windows 的用户目录通常在 C 盘，所以统一仓库默认也在那里。**源码放在哪个盘不决定工具装在哪个盘**。新 portable 工具可以用 `TOOLCHAIN_ROOT` 选择其他位置；已有副本继续留在原处，通过地图索引使用。

```powershell
# 在用户选定位置后设置；这里仅对当前 PowerShell 会话生效。
$env:TOOLCHAIN_ROOT = 'D:\toolchains'
& $map install rg@latest -WhatIf -Json  # 先看返回的 warehouse，不下载
```

接入规则要求 agent **仅在预计安装占用 ≥1 GB 时询问位置**，下载包大小不触发询问。体积未知时先核实估算；Rust、Android SDK 等预计达到门槛的工具即使精确体积未知也先确认。已有明确位置偏好且空间足够时复用，不重复询问。**这是 agent 的交互规则，CLI 本身不估算体积或弹出询问**。

只改仓库根还不够：portable 下载/解压使用 `%TEMP%`；mise 和 rustup 有自己的数据、缓存目录。位置偏好如何持久化、C 盘暂存如何处理，以及 Rust 的安装边界见 [存储与大工具安装](docs/storage.md)。

## 支持范围与限制

完整地图动作目前支持 **Windows PowerShell 5.1 / PowerShell 7**。macOS / Linux 目前提供 `census.sh` 扫描内核，尚无 `map.sh`；不要在 Unix 上照搬 Windows 接入命令。

默认发现范围包括已登记路径、PATH、统一仓库、mise 安装目录，以及扫描内核识别的常见运行时位置。搜索失败表示本次范围内未找到可验证副本，**不表示整台机器不存在**。

声明支持常见 `mise.toml`、`.mise.toml`、`.tool-versions`、`.nvmrc`、`.node-version`、`.python-version` 和 `package.json` engines。轻量读取器不解释完整 mise 配置语义（包括 includes、模板、复杂表、环境专属配置）；不支持的要求不能据此降级，必要时显式给 `-Version` 或使用管理器。

安装配方：gh、jadx、rg/ripgrep、fd（Windows x64 portable）与 adb。自定义 zip 用 `-Url` 与可选 `-Sha256`；安装器用 `-Via winget`，落在包管理器自己的位置。portable 下载版本需在暂存和最终位置均通过探测验证；已有合适的已验证副本优先复用，其他已有目标目录拒绝覆盖。任意程序的版本参数仍可能有自己的副作用，本产品保证自己的扫描逻辑不安装工具、不执行识别到的 shim。

## 源码与贡献

`scripts/map.ps1` 是入口，`map-core.ps1` 是地图核心，`toolkit-common.ps1` 共享护栏与声明读取，`tools.json` 定义命令别名和版本探测适配器。`census.ps1` / `census.sh` 是扫描内核；`bootstrap` 是可选的 mise 环境配置工具，会改 PATH/profile，与 `setup` 分开。

详见 [参考手册](docs/reference.md)、[平台说明](docs/platform-notes.md)、[贡献指南](docs/contributing.md) 和 [更新记录](CHANGELOG.md)。

MIT，见 [LICENSE](LICENSE)。
