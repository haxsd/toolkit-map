**中文** ｜ [English](README.md)

# runtime-census

找出这台机器上**真正存在**的语言运行时，并用声明式方式管理它们。

`node --version` 只能告诉你**现在用哪个**，不会告诉你**装了哪些**。这两件事的
差别，就是「本机只有 Node 16」这类错误结论的来源 —— 而磁盘上可能躺着
2 个 Node、3 个 Python、3 个 JVM。

## 快速开始

```powershell
# Windows
git clone https://github.com/haxsd/runtime-census
cd runtime-census
.\scripts\census.ps1
```

```bash
# macOS / Linux
git clone https://github.com/haxsd/runtime-census
cd runtime-census
./scripts/census.sh
```

十秒以内输出一份清单。节选：

```
 4. 运行时清单 —— 磁盘上实际存在的运行时（含纳管与未纳管）
  NODE  共 2 个
    16.20.2        <系统盘>:\nodejs\node.exe                    [系统安装]
    22.23.2        %USERPROFILE%\tools\node22\node.exe          [自定义位置]
  PYTHON 共 3 个
    3.12.10        %LOCALAPPDATA%\Programs\Python\Python312\python.exe
    3.14.7         %USERPROFILE%\miniconda3\python.exe          [conda]
  JAVA  共 3 个
    1.8.0_144      C:\Program Files\Java\jdk1.8.0_144\bin\java.exe
    11.0.6         ...\IntelliJ IDEA\jbr\bin\java.exe           [IDE 内置]
    25.0.3         ...\PyCharm\jbr\bin\java.exe                 [IDE 内置]

 6. 告警 —— 需要人工确认的问题
  [SHADOWED]   'node' 在磁盘上有 2 个副本，其中 1 个不在 PATH 上，无法被直接调用
  [CONVENTION] 发现自定义命名约定 node22 —— 这类约定必须写进声明文件否则会失传
```

需要机器可读格式就加 `--json`。

## 为什么需要它

`which node` 和 `node --version` 是**解析器**：按 PATH 顺序返回第一个赢家。
把它当成**盘点器**用，就会漏掉大部分运行时。常见的四种漏法：

| 遮蔽方式 | 例子 |
|---|---|
| PATH 单值 | 装了 7 个 JDK，`java` 只会是 PATH 上排最前的那个 |
| 自定义命名 | 把 Node 22 装成 `node22`，因为 `node` 这个位置已经被项目占用了 |
| 根本不在 PATH | conda 的 Python、pyenv 的版本，连 `py -0p` 都不认 |
| 宿主内置 | IDE 自带的 JBR 里有完整 JDK，从不注册为系统运行时 |

census 逐类盘点，把「用哪个」和「有哪些」两个问题分开回答。

## 让版本按项目自动切换

`census` 是零依赖的单文件脚本，clone 下来就能跑。如果要让不同项目自动使用
不同版本的运行时，再装一层版本管理器：

```powershell
.\scripts\bootstrap.ps1 -DryRun   # 先看会改什么
.\scripts\bootstrap.ps1
```

```bash
./scripts/bootstrap.sh --dry-run
./scripts/bootstrap.sh
```

bootstrap 做五件事，全部幂等：

1. 安装 [mise](https://mise.jdx.dev)（winget → scoop → choco → npm，Unix 上是 `mise.run` → brew）
2. 把 `templates/mise-config.toml` 写成全局机器声明。还没部署就照抄模板；已经部署且与模板不一致时，**只报告漂移**（差在哪些 `[tools]` 键）并保持你的文件不动——要覆盖请加 `-RefreshConfig` / `--refresh-config`，覆盖前自动备份
3. 建立非托管运行时的规范根（`~/toolchains`，可用 `TOOLCHAIN_ROOT` 或 `-ToolsRoot` / `--tools-root` 覆盖）
4. 把 mise 的 shims 目录放到**用户级** PATH 的**首位**（追加在尾部会输给所有既有的直接工具目录），并列出仍然遮蔽它的机器级目录
5. 执行 `mise install` 拉取声明的运行时

它刻意不做：不动机器级环境变量、不删你已有的 PATH 条目、不碰 IDE 自带的运行时。

## 在项目里声明所需版本

```toml
# 项目根目录 mise.toml
[tools]
node   = "22"
python = "3.12"

[env]
NODE_ENV = "development"

[tasks]
test  = "npm test"
build = "npm run build"
```

```bash
mise trust && mise install
mise exec -- npm test        # 一次性激活，不改全局状态
```

一个文件覆盖全部语言。也兼容 asdf 的 `.tool-versions`，两种格式的样例见 `examples/`。

**方向很重要**：让机器去满足项目的声明，而不是改项目迁就机器。因为版本对不上
就改 `engines` 或降级依赖，会造成「本机跑得通、CI 上炸」的隐蔽问题。

## 命令参考

### census

| 参数 | 说明 |
|---|---|
| （无） | 人类可读报告 |
| `--json` | JSON 输出，供程序消费 |
| `--deep` | 追加扫描盘上的常见安装根目录（较慢） |
| `--timing` / `-Timing` | 附各阶段耗时 |

它分五步盘点：

| 步骤 | 内容 |
|---|---|
| 1. 声明层 | 项目与全局的 `mise.toml` / `.tool-versions` |
| 2. 纳管层 | mise 管理的运行时 |
| 3. 约定层 | PATH 里带版本号的命名 shim，并解析出它真正指向哪个文件 |
| 4. 清单层 | 版本管理器目录、系统安装目录、IDE 内置 JBR、conda 环境 |
| 5. 解析层 | 常见命令实际解析到哪个文件、什么版本、能否执行 |

最后给这些告警：

| 告警 | 含义 | 该做什么 |
|---|---|---|
| `STUB` | 命令解析到商店应用执行别名，而目标应用没装——实测无输出、退出码 9009 | 这个命令不能用，换一个 |
| `PATH_ORDER` | 声明和 mise 都指向同一个版本，但 PATH 解析到别的副本 | 把 shims 放到用户级 PATH 首位（bootstrap 已做）；机器级目录要管理员权限 |
| `SHADOWED` | 有多个版本，但 PATH 只暴露一个 | 用绝对路径或版本管理器激活 |
| `CONVENTION` | 存在只写在文件名里的版本约定 | 写进声明文件，否则会失传 |
| `PATH_DIRT` | 用户级 PATH 里有重复或带引号的条目 | 清理掉——它们挤占 PATH 长度上限，还会掩盖「改了却没生效」这类问题 |
| `DRIFT` | 部署的全局声明与 `templates/mise-config.toml` 不一致 | `bootstrap.ps1 -RefreshConfig` / `bootstrap.sh --refresh-config`（会先备份） |
| `XDG_SHIFT` | 设置了 `XDG_CONFIG_HOME`，mise 的全局配置搬了家，`~/.config/mise/config.toml` 变成路径相关配置 | 去掉该变量，或把声明迁过去 |
| `STRAY` | 运行时放在非规范位置，且没有管理器纳管 | 登记到声明文件，**不要迁移**（见下） |
| `UNDECLARED` | 当前项目有 `engines` 约束，但找不到可读的声明文件 | 补 `mise.toml` / `.tool-versions`，见下方「接手锁旧版本的老项目」 |
| `MISSING` | 声明要求了但没装 | `mise install` |

### 约定：非托管运行时的落脚点

手工装的运行时（zip 下载、为老项目保留的并存安装）统一放在一个根下，
按 `<工具>/<版本>/` 排列：

```
~/toolchains/
├── node/22.23.2/
└── python/3.12.10/
```

可用环境变量 `TOOLCHAIN_ROOT` 覆盖。这样做换来两件事：一个统一的查找位置，
以及一个可预测的路径——下一个 agent 或同事不用问就知道去哪找。

**已经装在别处的运行时不要迁移。** 它们的路径可能被项目配置、IDE 设置、CI 脚本
写死，搬走会在几天后以难以排查的方式断掉。正确的做法是**登记**它们（`census`
会以 `[STRAY]` 列出），而不是搬动它们。位置不规范不是真问题，真问题是只靠 PATH
被找到的运行时——PATH 一变它就失传了。

## 当成 skill 安装

仓库根目录有 `SKILL.md`，所以它本身就是一个 Cursor / Claude skill。装法是把
skills 目录**链接**到这份克隆上，而不是复制一份 —— 这样以后 `git pull`
就等于升级 skill。

```powershell
git clone https://github.com/haxsd/runtime-census $env:USERPROFILE\Projects\runtime-census
New-Item -ItemType Junction `
  -Path "$env:USERPROFILE\.cursor\skills\runtime-census" `
  -Target "$env:USERPROFILE\Projects\runtime-census"
```

```bash
git clone https://github.com/haxsd/runtime-census ~/Projects/runtime-census
ln -s ~/Projects/runtime-census ~/.cursor/skills/runtime-census
```

装好之后，提到「这台机器上有哪些 Node / Python / Java 版本」或遇到版本不符预期，
agent 会自动加载它。

`AGENTS.md` 是配套的**发现契约**，写清了 agent 在判断运行时可用性时必须遵守的
规则。可以单独拷进你自己项目的规则文件，不依赖本仓库。

## 平台注意事项

- **PowerShell 5.1 上 `mise activate` 不能自动切换目录**：它的 `chpwd` 钩子需要
  PowerShell 7 及以上。在 5.1 下激活只会把 mise 的版本前置为全局默认，`cd` 进项目
  不会切换版本——而后者才是用 `activate` 的唯一理由。PowerShell 的 profile 是
  **分宿主**的（5.1 读 `WindowsPowerShell`，7 读 `PowerShell`），所以只要本机装了
  PowerShell 7，bootstrap 会把激活行**两个宿主都写上**，并直接告诉你改用 `pwsh`。
  判断"有没有装 7"必须实测，不能看文件存不存在：`WindowsApps` 里的 `pwsh.exe` 是
  0 字节的应用执行别名。
- **Windows 组合 PATH 的规则是机器级在前、用户级在后。** 解析命令时按组合后的顺序
  逐个目录找，所以机器级的直接工具目录（`C:\ProgramData\Oracle\Java\javapath`）
  或用户级里排在靠前的旧目录，永远赢过通常被追加在尾部的 mise shims。
  `mise activate` 只在**当前会话内**把 shims 前置：交互式 shell 用对版本，
  而 cmd、图形程序、IDE 任务、`-NoProfile` 脚本都悄悄用旧版本——这个缺口就是
  `[PATH_ORDER]` 告警要指出的东西。bootstrap 现在把 shims 放到用户级 PATH 的**首位**
  （解决用户级的旧目录），并单独列出机器级的目录（改它们需要管理员权限）。
- **存在 ≠ 可用（Windows），要点更精确**：`WindowsApps\python3.exe` 是 0 字节的
  商店应用执行别名，`Get-Command` 能找到、`where.exe` 会列出，执行时无输出、退出码
  9009。但 0 字节**不等于一定坏**：`pwsh.exe` 和 `winget.exe` 同样是 0 字节别名，
  却能正常执行，因为目标应用装了。文件长度只说明"可疑"，要确认必须真跑一次版本
  命令看有没有输出。
- **在 Windows 上验证 .sh 脚本**：PATH 里的 `bash` 通常是
  `C:\WINDOWS\system32\bash.exe`，也就是 WSL 的转发壳；没装发行版时它会报
  `execvpe(/bin/bash) failed: No such file or directory`，看起来像脚本语法错误，
  其实不是。跑 `.\scripts\verify-shell.ps1`：它会自动找一个真 bash（Git Bash，
  否则退回 bash 容器）对所有 `.sh` 执行 `bash -n`——只解析、不执行。
- **PowerShell 5.1 的 `@()` 陷阱**：`@($list)` 作用于 `List[object]` 会抛
  `Argument types do not match`，要用 `$list.ToArray()`。如果脚本里同时设了
  `$ErrorActionPreference = 'SilentlyContinue'`，这个错误会被完全吞掉，只在
  后续表现为某个对象莫名变成 `$null`，极难排查。

## 常见问题

**为什么不直接用 mise？**
mise 只能管到它自己装的东西，它永远不会知道 `<系统盘>:\nodejs`、conda 的 Python、
或者 IDE 自带的 JDK。纳管层和存量层必须分开看 —— 只做前者，会让人误以为
盘点已经完整了。

**为什么不用 Docker？**
容器是另一条路线，隔离更彻底，代价是每个项目都要构建镜像、与宿主共享文件系统
更麻烦。本项目的目标是**让原生机器变得可预测**。两者可以并存。

**census 会不会很慢？**
用定向探测而不是全盘遍历 —— 一次 `stat` 比一次目录枚举便宜一到两个数量级，
实测十秒以内。代价是只覆盖已知的安装布局，非常规位置需要 `--deep` 兜底。

## 已知限制

- 定向探测只覆盖**已知的安装布局**，装在完全非标准位置的运行时需要 `--deep`。
- `census.sh` 对 macOS 上 `.app` 包内 JBR 的探测只覆盖常见命名，
  JetBrains Toolbox 的非标准安装路径可能漏掉。
- mise 在 Windows 上的原生支持不如 Unix 完善，部分插件的构建脚本假定类 Unix
  环境，这类工具建议走 WSL 或容器。
- Windows 上不能用 mise 的 `mise.run` 安装脚本（只支持 macOS/Linux），需要走
  winget / scoop / choco / npm / 手工下载。
- 命令行输出目前只有中文。告警代码（`STUB` / `SHADOWED` / `CONVENTION` /
  `MISSING`）与 `--json` 输出是语言无关的，可以据此做程序化判断。

## 许可

MIT © [haxsd](https://github.com/haxsd)
