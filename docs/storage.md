# 存储位置与磁盘空间：不同对象、默认位置与新安装选盘

本页说明源码、地图、工具仓库与管理器目录的默认位置，以及新安装如何选择其他盘。已有副本不自动迁移；持久化位置偏好只在用户明确选择后配置。

## 一、四个不同对象，别混为一谈

1. **源码目录**：本技能自身的 `SKILL.md` 与 `scripts/map.ps1` 所在目录。例：`C:\Users\you\.codex\skills\toolkit-map\scripts\map.ps1`。它只放脚本，**不决定工具装哪里**。
2. **索引文件（地图）**：默认 `C:\Users\you\.toolkit\map.json`，可用环境变量 `TOOLKIT_MAP` 覆盖。它是扫描结果**索引**，本身很小；仓库才是存放位置。
3. **portable 统一仓库（warehouse）**：`map.ps1` 的 `Get-WarehouseRoot` 先读 `TOOLCHAIN_ROOT`，否则用 `Join-Path $env:USERPROFILE toolchains`，默认 `C:\Users\you\toolchains`。portable 工具落在 `<仓库>\<工具>\<版本>\`。
4. **管理器目录**：如 mise 的 `C:\Users\you\AppData\Local\mise`、rustup 的 `C:\Users\you\.rustup` 与 `C:\Users\you\.cargo`。这些由管理器自己管理，**不是 portable 仓库**，不能当同一对象一刀切改根。

源码与索引都很小，占空间的是**下载缓存、安装展开、多版本、缓存/编译产物、TEMP 暂存**。因此"源码目录在 C 盘"不代表工具一定要装 C 盘。

## 二、体积怎么分

| 阶段 | 例子 | 说明 |
|---|---|---|
| 下载压缩包 | release 的 `.zip`/`.tar.gz` | 小包**不代表**解压后小 |
| 安装展开 | 安装后的目录内容 | 通常远大于压缩包 |
| 多版本 | 同工具多个 `<版本>` | 每份独立占用 |
| 缓存/编译产物/TEMP | 构建产物、`%TEMP%` | 编译类工具会额外膨胀 |

大小来源：官方说明、安装组件清单或可信估算；release 资产元数据只能确认压缩包大小，不能直接作为安装占用。**仅预计安装占用 ≥1 GB 时询问位置**，下载包大小不触发询问。这是交互门槛，不能当作准确体积估算；用户另有偏好则以用户为准。

## 三、关键边界（必须明确）

- 当前 CLI **不估算、也不自动询问下载体积**。大小确认是 **agent 的规则**；人类直接跑 CLI 时**不会被拦截**。
- `install -WhatIf -Json` **不联网**，portable 计划包含 `warehouse`；最新版本未解析时还有配方与 `networkRequired`，**给不出真实包体积**。
- 大小未知**不能按小处理**，先核实估算并报告不确定性。Rust、Android SDK 等预计达到 1 GB 门槛的工具，即使精确体积未知也先询问；不要因为任意小工具体积未知就一律弹出位置问题。
- 示例只用于**新安装**，**不移动**已有副本。
- 临时 env 仅**当前会话**有效；持久化**必须用户明确选择**，且只有**未来新启动的 IDE 进程**才继承。
- **不要为存储改 PATH**。

## 四、portable 暂存的 C 盘问题

portable 暂存固定用 `%TEMP%`。**改 `TOOLCHAIN_ROOT` 不能避免 C 盘暂存**。若已在**已确认的新安装会话**中选定 D 盘，可临时把 `TEMP`/`TMP` 指过去：先建目录并验证存在/可写，还要预留**总峰值空间**（下载 + 展开 + 暂存同时存在）。不要自动永久改 `TEMP`/`TMP`。

### 可复制示例：新安装临时用 D 盘（仅当前会话）

```powershell
# 仅在用户已经选定位置后执行；换盘请替换 D:，不要假定每台机器都有 D 盘。
Get-PSDrive -Name D | Select-Object Root, Used, Free
$root = 'D:\toolchains'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$probe = Join-Path $root ('.write-check-' + [guid]::NewGuid().ToString('N'))
try { [IO.File]::WriteAllText($probe, '') } finally { if ([IO.File]::Exists($probe)) { [IO.File]::Delete($probe) } }

# 2) 本会话临时落位（不改 PATH，不改全局环境）
$env:TOOLCHAIN_ROOT = $root
$tmp = Join-Path $root 'tmp'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
if (-not (Test-Path $tmp)) { throw "临时目录不可用: $tmp" }
$env:TEMP = $tmp
$env:TMP  = $tmp

# 3) 先看计划（不联网），确认 warehouse 后再单独安装。
$map = 'C:\Users\you\Projects\toolkit-map\scripts\map.ps1'  # 替换成真实路径
& $map install rg@latest -WhatIf -Json
```

> 判盘存在可参考 `Get-PSDrive`，但它要求**路径所在盘已存在**；没有 D 盘就不默认 D，示例中的盘符按你的机器替换。

## 五、可选：用户级持久化（必须用户明确选择）

只在用户**确认**后执行；**不要改 PATH**，也**不要自动永久改 `TEMP`/`TMP`**：

```powershell
# 持久化仓库根（仅当用户明确选择 D 盘方案时）
[Environment]::SetEnvironmentVariable('TOOLCHAIN_ROOT','D:\toolchains','User')
# 让当前会话也生效
$env:TOOLCHAIN_ROOT = 'D:\toolchains'
```

持久化后**未来新启动的 IDE 进程**才会继承；已运行的进程不会自动更新。

## 六、管理器：mise 与 rustup

- **mise 不是 portable 仓库**。官方说明（<https://mise.jdx.dev/configuration.html>）：`MISE_DATA_DIR` 管理安装与插件，Windows 默认 `%LOCALAPPDATA%\mise`；`MISE_CACHE_DIR` 控制缓存，Windows 默认 `%TEMP%\mise`。**改 `MISE_DATA_DIR` 不会自动迁移已有数据**，已配置的 shim 可能仍指旧目录——**不要教一刀切修改已有管理器的全局根**。
- **新管理器首次安装**时，可把数据/缓存设到 `D:\toolchains\mise-data`、`D:\toolchains\mise-cache`，后续保持一致：
  ```powershell
  $env:MISE_DATA_DIR  = 'D:\toolchains\mise-data'
  $env:MISE_CACHE_DIR = 'D:\toolchains\mise-cache'
  ```
- **rustup**（<https://rust-lang.github.io/rustup/installation/index.html>）支持**安装前**设置 `RUSTUP_HOME` 与 `CARGO_HOME`，默认 `~/.rustup` 与 `~/.cargo`。例如新安装可分别选 `D:\toolchains\rustup`、`D:\toolchains\cargo`，后续保持相同设置。本项目**没有 rust portable 配方**；地图 `find` **不保证发现所有自定义 rust 目录**，需要时用 `add` 登记已查证的真实 `rustc`/`cargo` 工具链二进制。不要执行代理进行只读盘点，也不要自动迁移既有 Rust。

## 七、agent 询问示例（等回答再下载）

已有明确选定位置且空间充足时，**复用、无需重复问**。否则可这样问：

> "准备安装 Rust 工具链，具体安装占用尚未确认，可能占用较多空间。当前目标在 C 盘的用户目录；继续使用这里，还是指定另一个目录？确认后我再下载，并检查安装盘与缓存盘空间。"

达到询问门槛时，收到明确回答后才下载；预计不到 1 GB 的工具按已有位置策略安装，无需额外询问位置。
