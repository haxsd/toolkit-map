**中文** ｜ [English](reference.md) ｜ [README](../README.zh-CN.md)

# 命令参考

两个命令接受的全部参数、输出结构，以及背后的约定。与操作系统相关的行为见
[平台注意事项](platform-notes.zh-CN.md)。

给 agent 用的判断规则见 [AGENTS.md](../AGENTS.md)。

## census

只读盘点，不向机器写任何东西，所以它才是默认入口。在干净的 PATH 上是几秒钟，
在 Windows 上 PATH 条目上千时可能到半分钟。

| 参数 | 说明 |
|---|---|
| （无） | 人类可读报告 |
| `--json` | stdout 上只输出一个 JSON 对象，人类可读的六节**完全不打印** |
| `--deep` | 额外扫描常见安装根目录（有界：深度 4、结果条数封顶；最慢的路径） |
| `--timing` | 附带各阶段耗时 |
| `-Lang en` / `--lang en` | 英文输出（也可用环境变量 `CENSUS_LANG`）；默认 `zh` |

`census.ps1` 单双横线都认（`-Json` 或 `--json`），`census.sh` 用双横线。

### 它盘点什么

| 步骤 | 内容 |
|---|---|
| 1. 声明层 | 项目与全局的 `mise.toml` / `.tool-versions` |
| 2. 纳管层 | mise 管理的运行时 |
| 3. 约定层 | PATH 里带版本号的命名 shim，并解析出它真正指向哪个文件 |
| 4. 清单层 | 版本管理器目录、系统安装目录、IDE 内置 JBR、conda 环境 |
| 5. 解析层 | 常见命令实际解析到哪个文件、什么版本、能否执行 |

### JSON 输出

两个实现输出**同一套结构**（CI 里的 `tests/parity.ps1` 每次都会核对），
所以 agent 或 CI 不需要为平台写两套解析逻辑：

| 字段 | 内容 |
|---|---|
| `schemaVersion` | `1`——字段或语义变化时递增 |
| `generatedAt`、`host` | 时间戳与 `{os, arch, user, cwd}` |
| `declarations` | 找到的每个 `mise.toml` / `.tool-versions`：`{scope, path, tools}` |
| `toolsRoot` | 非托管运行时的规范根 |
| `mise` | 纳管层：`{available, tools[]}` |
| `conventions`、`runtimes`、`resolution` | 三个盘点阶段。消费者按本表与下文列出的字段读；实现可以带自己的附加字段（见下） |
| `warnings` | `[{kind, tool, message, action, detail}]`——`kind` 是稳定的 ASCII 代码 |
| `timings`、`summary` | 各阶段毫秒数（配合 `--timing`）与计数 |

`kind` 代码（`STUB`、`PATH_ORDER`、`DRIFT` …）不随语言变化；`message` 与 `action` 跟随 `--lang`。

**不要求两份实现结构完全一致。** 上表列出的字段是契约，实现可以带自己的附加字段——
例如 `host.powershell`、`mise.tools[].installPath` 只在 PowerShell 版里出现，因为它们
描述的是 Windows 上才有的事实。`tests/parity.ps1` 刻意不比对逐字段相等，只守住
上面那条「机器可读标识符必须是稳定 ASCII」。

### 告警代码

| 告警 | 含义 | 该做什么 |
|---|---|---|
| `STUB` | 命令解析到商店应用执行别名，而目标应用没装——实测无输出、退出码 9009 | 这个命令不能用，换一个 |
| `PATH_ORDER` | 声明和 mise 都指向同一个版本，但 PATH 解析到的副本**不满足**该声明（是声明要求的那个版本的另一份副本不算——只报真正版本不对的情况） | 把 shims 放到用户级 PATH 首位（bootstrap 已做）；机器级目录要管理员权限 |
| `SHADOWED` | 有多个版本，但 PATH 只暴露一个 | 用绝对路径或版本管理器激活 |
| `CONVENTION` | 存在只写在文件名里的版本约定 | 写进声明文件，否则会失传 |
| `PATH_DIRT` | 用户级 PATH 里有重复或带引号的条目 | 清理掉——它们挤占 PATH 长度上限，还会掩盖「改了却没生效」这类问题 |
| `DRIFT` | 部署的全局声明与 `templates/mise-config.toml` 不一致 | `bootstrap.ps1 -RefreshConfig` / `bootstrap.sh --refresh-config`（会先备份） |
| `XDG_SHIFT` | 设置了 `XDG_CONFIG_HOME`，mise 的全局配置搬了家，`~/.config/mise/config.toml` 变成路径相关配置 | 去掉该变量，或把声明迁过去 |
| `STRAY` | 运行时放在非规范位置，且没有管理器纳管 | 登记到声明文件，**不要迁移**（见下） |
| `UNDECLARED` | 当前项目有 `engines` 约束，但找不到可读的声明文件 | 补 `mise.toml` / `.tool-versions` |
| `MISSING` | 声明要求了但没装 | `mise install` |

### 约定：非托管运行时的落脚点

手工装的运行时（zip 下载、为老项目保留的并存安装）统一放在一个根下，
按 `<工具>/<版本>/` 排列：

```text
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

## bootstrap

一次性配置脚本。只在你想在 census 之上再加「按项目自动切换版本」时才需要跑它。
两个平台参数相同，PowerShell 用单横线、shell 脚本用双横线：

| 参数 | 说明 |
|---|---|
| `-DryRun` / `--dry-run` | 只打印将要执行的改动，不实际修改 |
| `-RefreshConfig` / `--refresh-config` | 用模板覆盖已部署的机器声明（覆盖前备份）。不加这个参数时只报告漂移 |
| `-SkipTools` / `--skip-tools` | 只装 mise 和写声明，不执行 `mise install` |
| `-NoProfile` / `--no-rc` | 不修改 shell 启动文件 |
| `-ToolsRoot` / `--tools-root` | 覆盖非托管运行时的规范根（默认 `~/toolchains`） |
| `-ConfigSource` / `--config` | 换一个清单模板，不使用 `templates/mise-config.toml` |

它执行的五个幂等步骤：

1. 安装 [mise](https://mise.jdx.dev)（winget → scoop → choco → npm，Unix 上是 `mise.run` → brew）
2. 把 `templates/mise-config.toml` 写成全局机器声明。还没部署就照抄模板；已经部署且与模板不一致时，**只报告漂移**（差在哪些 `[tools]` 键）并保持你的文件不动
3. 建立非托管运行时的规范根（`~/toolchains`）
4. 把 mise 的 shims 目录放到**用户级** PATH 的**首位**（追加在尾部会输给所有既有的直接工具目录），并列出仍然遮蔽它的机器级目录
5. 执行 `mise install` 拉取声明的运行时

`bootstrap` 刻意改机器状态，所以先跑 `-DryRun` / `--dry-run` 看清计划，确认后再真的执行。

### bootstrap 改了什么、怎么撤销

| `bootstrap` 改了什么 | 怎么撤销 |
|---|---|
| 安装 mise（winget → scoop → choco → npm；Unix 上是 `mise.run` → brew） | 用同一个包管理器卸载 |
| 写入机器声明 `~/.config/mise/config.toml` | 同目录会留一份 `config.toml.bak-<时间戳>` 备份；删掉该文件就等于不再有机器声明 |
| 把 mise 的 shims 移到**用户级** PATH 首位 | 在「编辑账户的环境变量」里删掉那一条，然后重开终端 |
| 往 PowerShell profile 追加激活行（装了 pwsh 时两个宿主都写） | 删掉 profile 里带 `runtime-census` 注释的那两行 |
| 执行 `mise install`（下载声明的运行时） | `mise uninstall <工具>@<版本>`；原本就有的版本不受影响 |
| — | 它从不碰机器级环境变量、不删任何 PATH 条目、不改 IDE 自带的运行时 |

## verify-shell.ps1

只有 Windows 且你改过 `.sh` 实现时才需要：PATH 里的 `bash` 通常是 WSL 的转发壳，
没装发行版时报 `execvpe(/bin/bash) failed: No such file or directory`，看起来像脚本
语法错误，其实不是。它属于开发期检查而不是产品本身，所以放在 `tests/` 下：

```powershell
.\tests\verify-shell.ps1
```

它会找一个真 bash（Git Bash，否则退回 `bash` 容器），对 `scripts/` 与 `tests/` 下所有
`.sh` 执行 `bash -n`——只解析、不执行。其余本地检查见[贡献指南](contributing.zh-CN.md)。
