# toolkit-map

给 agent 用的**本机工具地图**：它是这台机器的工具索引，仓库是存放地点，两者分开。

- **要调用工具**：先 `find` 拿绝对路径——它可能在统一仓库里，也可能在系统或管理器里——然后执行它；找不到时只现场探测并登记，不会自动安装。
- **要装工具**：只有明确需要安装时，才先 `find` 确认地图和现场都没有，再单独执行 `install` 进统一仓库，装完自动登记进地图。

## 为什么需要它

- **PATH 是单值命名空间**：同名命令只有第一个生效。所以"本机只有 Node 16"这种说法通常是错的，
  它真正的意思是"PATH 解析到了 Node 16"。
- **同一个命令名可能跑的不是同一个文件**：实测踩过——`gh` 在旧会话里走 mise 的 shim，
  在新会话里走机器级 PATH 的另一个副本；靠 `Get-Command`、`Test-Path`、手工比 PATH
  去推测，会推出错误结论（我们自己就错了两回）。
- **agent 需要的是确定的绝对路径**，不是"大概会跑哪个"。

## 安装成技能

仓库根目录有 `SKILL.md`，本身就是 Cursor / Claude / Codex 技能。下面固定到当前稳定版；需要跟随开发版时把
`--branch v0.1.5` 改为 `main`：

```powershell
git clone --branch v0.1.5 --depth 1 https://github.com/haxsd/toolkit-map $env:USERPROFILE\Projects\toolkit-map
New-Item -ItemType Junction -Path "$env:USERPROFILE\.cursor\skills\toolkit-map" `
  -Target "$env:USERPROFILE\Projects\toolkit-map"

# Codex（用户级技能目录）
New-Item -ItemType Junction -Path "$env:USERPROFILE\.agents\skills\toolkit-map" `
  -Target "$env:USERPROFILE\Projects\toolkit-map"
```

```bash
git clone --branch v0.1.5 --depth 1 https://github.com/haxsd/toolkit-map ~/Projects/toolkit-map
ln -s ~/Projects/toolkit-map ~/.cursor/skills/toolkit-map

# Codex（用户级技能目录）
ln -s ~/Projects/toolkit-map ~/.agents/skills/toolkit-map
```

### 装完还要写规则，否则可能等于没装

**技能装进目录，不等于模型看得见它。** 这取决于前端愿不愿意把技能递给模型，两条通道要分开看：

| 通道 | 实测结果 |
|---|---|
| **技能目录**（`~/.cursor/skills`、`~/.agents/skills` …） | **有的前端会读，有的不会。** Devin 会——它的代码里明确在扫描 `.devin/skills`、`.agents/skills`、`.claude/skills`、`.github/skills` 并构建"名称 + 描述"的技能表；而某个 Cursor 构建**不会**：25 个技能全部就位、联接可读、`SKILL.md` 也在，模型上下文里**仍然没有任何技能清单**，工具表里也没有"读技能"这一类 |
| **规则**（项目根 `AGENTS.md`、Cursor 的 User Rules、`~/.codex/AGENTS.md`） | **会注入**。同一台机器、同一个会话里实测：写进项目 `AGENTS.md` 的约定，被模型在 `<rules>` 区块中原样引用出来 |

所以本产品的约定**必须同时写在规则里**——只装技能目录，在那类前端上等于没装，而且**不会报错**。

三处各写一次（都是粘一段文本）：

- **Cursor**：`Customize → Rules`（User Rules 存在账号里，不在文件系统上，所以只能手工粘一次）
- **Codex**：`~%USERPROFILE%\.codex\AGENTS.md` 里加一节
- **项目级兜底**：项目根放一个 `AGENTS.md`（Cursor 会读项目根与子目录，`Devin` 也认 `AGENTS.md`）

现成文本，直接粘：

```
本机约定：要用工具之前先查工具地图，装工具只走统一仓库。
  <map.ps1 的绝对路径> status
  <map.ps1 的绝对路径> find <工具> -Json
  <map.ps1 的绝对路径> install <工具>@<版本>
不要用 where.exe / Get-Command 猜该用哪个；发现地图里没有的副本用 add 登记（不搬路径）；
装完/卸完东西后跑 update。
```

**怎么验证写没写进去**（新开一个会话，问 agent 两句话）：

1. "你上下文里有没有关于工具地图的规则？" —— 答"有"并引用出来，说明规则通道通了。
2. "你上下文里有没有可用技能清单？" —— 把这一问和上一问分开问，才能区分"技能没被发现"和"发现了但没递给模型"。

## 六个动作

```powershell
.\scripts\map.ps1 scan                  # 扫描本机，生成/刷新地图（复用 census 的扫描内核）
.\scripts\map.ps1 status                # 地图在不在、多旧、有没有失效候选
.\scripts\map.ps1 find jadx             # 查这个工具该用哪个（只查找，不安装）
.\scripts\map.ps1 add <tool> -Path <p>  # 登记一个已有副本（不搬家）
.\scripts\map.ps1 update [<tool>]       # 重探：路径没了就移除、版本变了就更新
.\scripts\map.ps1 install jadx@latest   # 明确需要时才装进统一仓库并登记为首选
```

`find` 的典型输出——**它会把所有副本摆出来**，因为多份副本是常态：

```
  gh → C:\Program Files\GitHub CLI\gh.exe
      版本 2.101.0　来源 system　可被 PATH 解析 True
  另有 2 份副本（不要用错）：
      C:\...\mise\shims\gh.exe  [manager]  — shim（未执行探测，避免触发自动安装）
      C:\...\mise\installs\gh\2.101.0\bin\gh.exe  [manager] 2.101.0
```

## 地图与仓库

- **地图**：`~/.toolkit/map.json`（`TOOLKIT_MAP` 可覆盖），同名 `.md` 是人类可读摘要。
  每个工具 = 一个 `preferred` + 若干 `candidates`；候选带 `source`、`reachable`、
  `isShim`、`note`。
- **统一仓库**：`~/toolchains/<工具>/<版本>/`（`TOOLCHAIN_ROOT` 可覆盖），多版本并列，
  **不进 PATH**——PATH 里只该有一个间接层。
- **首选规则**：声明匹配 → 仓库里装的 → 能被 PATH 解析的具体二进制 → 来源优先级 → 版本高者。
  shim 不作首选（它指向谁可能变），conda 环境内的副本默认不参选。

这两个目录都是**使用者本机状态**，不属于 GitHub 仓库：`~/.toolkit/map.json` 记录本机发现结果，
`~/toolchains/` 存放本机明确安装的工具。GitHub 只发布协议、脚本、安装配方和通用示例；
文档里的工具名是配方或示例，不是某台机器当前安装清单。

## 管什么、不管什么

- **管**：可独立执行的工具——运行时、编译器、CLI、逆向/渗透工具。判断标准是三条同时成立：
  能被直接调用、有独立版本概念、离开任何特定环境仍然成立。
- **不管**：conda 某个 env 里的小包、venv / site-packages / node_modules 这类依赖
  （离开环境就没有意义，不进地图），以及应用层环境诊断（端口、`.env`、依赖目录、执行位）。

## 仓库里还有什么

| 路径 | 作用 |
|---|---|
| `scripts/map.ps1` | 本产品：地图的六个动作 |
| `scripts/census.ps1` / `census.sh` | 扫描内核：`scan` 直接复用它的 JSON 输出。也可单独当盘点报告用 |
| `scripts/bootstrap.ps1` / `bootstrap.sh` | 可选：装 mise、把 shims 收到用户级 PATH 首位（让 `node` 之类跟随项目声明） |
| `AGENTS.md` | 发现契约：agent 判断"工具在哪、哪个会生效"时的规则 |
| `SKILL.md` | 使用协议：`find` / `install` 的硬规矩 |
| `docs/` | [参考手册](docs/reference.md)、[平台说明](docs/platform-notes.md)、[贡献指南](docs/contributing.md)（单语中文） |
| `templates/`、`examples/` | 机器级声明模板与声明文件示例 |

## 已知限制

- `install` 目前支持 GitHub portable 配方（gh / jadx / ripgrep / fd）、固定 URL 配方（adb），以及
  `-Via winget` 的安装器兜底。安装器管理的工具会登记真实路径，但不一定落在统一仓库；其他 portable
  工具需要用 `-Url` 给直链。直链归档可用 `-Sha256` 校验；统一仓库已有同版本目录时会拒绝覆盖。
- Unix 版（`map.sh`）尚未编写；macOS / Linux 上目前只有扫描内核 `census.sh` 可用。

## 许可

MIT，见 [LICENSE](LICENSE)。
