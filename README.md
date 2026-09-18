# toolkit-map

给 agent 用的**本机工具地图**：用工具之前先查地图拿绝对路径；地图里没有，就装进统一仓库再登记。

## 为什么需要它

- **PATH 是单值命名空间**：同名命令只有第一个生效。所以"本机只有 Node 16"这种说法通常是错的，
  它真正的意思是"PATH 解析到了 Node 16"。
- **同一个命令名可能跑的不是同一个文件**：实测踩过——`gh` 在旧会话里走 mise 的 shim，
  在新会话里走机器级 PATH 的另一个副本；靠 `Get-Command`、`Test-Path`、手工比 PATH
  去推测，会推出错误结论（我们自己就错了两回）。
- **agent 需要的是确定的绝对路径**，不是"大概会跑哪个"。

## 安装成技能

仓库根目录有 `SKILL.md`，本身就是 Cursor / Claude 技能。链接安装，`git pull` 即可升级：

```powershell
git clone https://github.com/haxsd/toolkit-map $env:USERPROFILE\Projects\toolkit-map
New-Item -ItemType Junction -Path "$env:USERPROFILE\.cursor\skills\toolkit-map" `
  -Target "$env:USERPROFILE\Projects\toolkit-map"
```

```bash
git clone https://github.com/haxsd/toolkit-map ~/Projects/toolkit-map
ln -s ~/Projects/toolkit-map ~/.cursor/skills/toolkit-map
```

## 六个动作

```powershell
.\scripts\map.ps1 scan                  # 扫描本机，生成/刷新地图（复用 census 的扫描内核）
.\scripts\map.ps1 status                # 地图在不在、多旧、有没有失效候选
.\scripts\map.ps1 find jadx             # 查这个工具该用哪个
.\scripts\map.ps1 add <tool> -Path <p>  # 登记一个已有副本（不搬家）
.\scripts\map.ps1 update [<tool>]       # 重探：路径没了就移除、版本变了就更新
.\scripts\map.ps1 install jadx@latest   # 装进统一仓库并登记为首选
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

- `install` 目前支持 portable 归档（内置 gh / jadx / ripgrep / fd 四个配方，其余用 `-Url` 给直链）；
  只能走安装器的工具需要人工处理后再 `add` 登记。
- Unix 版（`map.sh`）尚未编写；macOS / Linux 上目前只有扫描内核 `census.sh` 可用。

## 许可

MIT，见 [LICENSE](LICENSE)。
