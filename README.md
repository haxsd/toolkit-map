# toolchain-kit

一套**跨机器可移植**的运行时管理约定，解决一个具体问题：

> **"本机只有 Node 16"** —— 这句话通常是错的。

---

## 问题是什么

Agent（以及人）判断"这台机器上有什么运行时"，默认用的命令是 `node --version`、
`python --version`、`java -version`。这些命令是**解析器**：

- 它们回答"按 PATH 顺序，第一个赢家是谁"
- 它们**不回答**"这台机器上装了哪些版本"

把前者的答案当成后者，就会得出一句关于机器的、自信的错误陈述。

在一个真实案例里，`node --version` 报告 16.20.2，而磁盘上实际有：

| 运行时 | 磁盘上真实存在 | agent 探测到 |
|---|---|---|
| Node | `D:\nodejs` 16.20.2 | 能 |
| Node | `~/tools/node22` **22.23.2** | **不能**，被 `node22` 这个名字藏了 |
| Python | `Python312` 3.12.10 | 能 |
| Python | `miniconda3` **3.14.7** | **不能**，conda 完全没进 PATH |
| Java | `jdk1.8.0_144` | 能 |
| Java | PyCharm 内置 JBR **OpenJDK 25.0.3** | **不能**，藏在 IDE 里 |
| Java | IntelliJ 内置 JBR **OpenJDK 11.0.6** | **不能**，同上 |

2 个 Node、3 个 Python、3 个 JVM —— 探测只看见其中 1 个 Node、1 个 Python、1 个 Java。

### 四层遮蔽机制

**PATH 单值遮蔽。** PATH 是有序列表，同名命令只有第一个生效。装在前面的那个
永远赢，后面的等于不存在。

**自定义命名约定遮蔽。** 把 Node 22 装成 `node22.cmd` 在工程上完全正确
（单值命名空间里做并存安装本来就这么干），但它创造了一个**只存在于文件名里的
API**：想知道要读它，你得先知道它存在；想知道它存在，你得先读过它。
这是个自指死锁。

**无 PATH 遮蔽。** conda 的 Python 根本不在 PATH 上，`py -0p` 也不认它，
对所有常规探测手段完全隐形。

**宿主遮蔽。** IDE 捆绑的 JVM 被当作宿主程序的一部分，从不注册为系统运行时。

### 还顺带发现的两个坑

- `WindowsApps\python3.exe` 是 **0 字节的商店应用别名存根**：`Get-Command`
  能找到它，执行时却无输出、退出码 9009。**存在 ≠ 可用。**
- Windows PowerShell 5.1 里 `@($list)` 作用于 `List[object]` 会抛
  `Argument types do not match`。写相关脚本时要用 `.ToArray()`。

---

## 解决方案：三层分离

核心洞察是 **PATH 单值不是缺陷，是它的本性**。所以不要去对抗它，而是让那个
唯一的槽位指向**间接层**：

```
┌─ 声明层 ─────────────────────────────────────────────┐
│  项目: mise.toml / .tool-versions     要求用哪个版本   │
│  机器: ~/.config/mise/config.toml     提供哪些版本     │
└──────────────────────────────────────────────────────┘
                        ↓ 交给
┌─ 解析层 ─────────────────────────────────────────────┐
│  PATH 里的唯一工具链条目 = mise 的 shims 目录          │
│  由它按「当前目录的声明 → 全局默认 → 显式指定」决定     │
└──────────────────────────────────────────────────────┘
                        ↓ 从
┌─ 存储层 ─────────────────────────────────────────────┐
│  %LOCALAPPDATA%\mise\installs\<工具>\<版本>\           │
│  所有版本并排存放，一个都不进 PATH                     │
└──────────────────────────────────────────────────────┘
```

**激活粒度的优先级**（从高到低）：

```
per-command  >  per-shell  >  per-project（带 hook）  >  全局改 PATH
```

Agent 应该优先用 `mise exec -- <命令>`：零全局状态、一次性、可并发、
可写进脚本。全局改 PATH 是最后手段，也是绝大多数此类问题的来源。

---

## 快速开始

### 新机器：一条命令到位

```powershell
# Windows
git clone <本仓库> ; cd toolchain-kit
.\scripts\bootstrap.ps1 -DryRun     # 先看会改什么
.\scripts\bootstrap.ps1             # 实际执行
```

```bash
# macOS / Linux
git clone <本仓库> && cd toolchain-kit
./scripts/bootstrap.sh --dry-run
./scripts/bootstrap.sh
```

bootstrap 只做四件事，且每件都是幂等的：

1. 安装 mise（winget → scoop → choco → npm，Unix 上是 `mise.run` → brew）
2. 把 `mise/config.toml` 写成全局机器声明（覆盖前自动备份）
3. 把 mise 的 shims 目录加进**用户级** PATH
4. 执行 `mise install` 拉取声明的运行时

它刻意**不做**：不动机器级环境变量、不删已有的 PATH 条目、不动 IDE 自带的运行时。

### 盘点本机到底有什么

```powershell
.\scripts\census.ps1            # 人类可读报告
.\scripts\census.ps1 -Json      # JSON，供 agent 消费
.\scripts\census.ps1 -Timing    # 附带各阶段耗时
```

```bash
./scripts/census.sh
./scripts/census.sh --json
```

`census` 和 `--version` 的区别，正是本套件存在的理由。它盘点**五类来源**：

| 阶段 | 内容 |
|---|---|
| 1. 声明层 | 项目与全局的 `mise.toml` / `.tool-versions` |
| 2. 纳管层 | mise 管理的运行时 |
| 3. 约定层 | PATH 里带版本号的命名 shim，**并解析出它真正指向的文件** |
| 4. 运行时清单 | 版本管理器目录、系统安装目录、IDE 内置 JBR、conda 环境、PATH 的父目录 |
| 5. 解析层 | 常见命令实际解析到哪个文件、什么版本、是否可执行 |

然后给出六类告警：`STUB`（解析到假文件）、`SHADOWED`（多版本被遮蔽）、
`CONVENTION`（自定义约定待文档化）、`MISSING`（声明了没装）、`NO_MISE`。

在实测的机器上，它用 7.7 秒挖出了全部 2 个 Node、3 个 Python、3 个 JVM，
以及用户自己发明但没记录的 `node22` 约定。

### 项目里声明所需版本

```toml
# mise.toml —— 放在项目根目录
[tools]
node   = "22"
python = "3.12"

[env]
NODE_ENV = "development"

[tasks]
test  = "npm test"
build = "npm run build"
```

一个文件覆盖全部语言，语义对任何 agent、任何 harness 都一致。

```bash
mise trust && mise install       # 首次
mise exec -- npm test            # 一次性激活执行
```

**方向很重要**：让机器去满足项目的声明，而不是改项目去迁就机器。
因为版本对不上就改 `engines` 或降级依赖，会造成"在你机器上能跑、
在 CI 上炸"的隐蔽问题。

---

## 给 agent 的契约

`AGENTS.md` 是这套东西真正生效的关键。把它复制进你实际使用的规则文件
（Cursor 规则、`AGENTS.md`、`CLAUDE.md`），agent 才会遵守：

1. **先读声明，不要猜** —— 声明表达需求，探测只能反映现状
2. **需要特定版本用一次性激活，不改全局状态**
3. **盘点用盘点工具，不用 `--version` 下结论**
4. **说出"本机只有 X 版本"之前，必须先完成一次真正的盘点**

以及报告格式要求：明确区分**声明**（项目要求什么）、**可用**（机器上装了什么）、
**解析**（现在会用到哪个）。不能说"本机只有 X"，要说"PATH 上的 `node` 解析到 X，
机器上另有 Y 未被 PATH 覆盖"。

---

## 目录结构

```
toolchain-kit/
├── README.md                本文件
├── AGENTS.md                给 AI agent 的运行时发现契约
├── mise/
│   └── config.toml          全局机器声明模板
├── examples/
│   ├── mise.toml            项目级声明样例（推荐格式）
│   └── .tool-versions       项目级声明样例（兼容 asdf 格式）
└── scripts/
    ├── census.ps1           Windows 运行时普查
    ├── census.sh            Unix 运行时普查
    ├── bootstrap.ps1        Windows 一键引导
    └── bootstrap.sh         Unix 一键引导
```

---

## 设计取舍

**为什么选 mise 而不是自己写 shim 脚本。**
自己写命名 shim（`node22` 那种）简单、显式、零依赖，但约定是私有的。
mise 的价值在于它的约定是**公开的**：`mise ls`、`mise exec`、`.tool-versions`
这些名字任何 agent 都认识，不需要先读文档。

**为什么还要保留 census。**
mise 只能管到它自己装的东西。它永远不会知道 `D:\nodejs`、conda 的 Python、
或者 PyCharm 里的 JDK。**纳管层和存量层必须分开看**，只做前者会让人误以为
盘点已经完整了。

**为什么 census 用定向探测而不是全盘遍历。**
早期版本用带通配符的目录遍历，实测耗时 116 秒（其中 101 秒花在目录枚举上）。
改成"枚举一层子目录 + 对每个目录做存在性检查"之后降到 7.7 秒。
一次 `stat` 比一次目录枚举便宜一到两个数量级。

**为什么 bootstrap 默认不写 shell 启动文件。**
写激活行能让 `cd` 进项目时自动切版本，体验更好，但那是在改用户的 shell 配置。
默认需要通过参数显式开启，比默认改掉再让用户去发现更合适。

---

## 已知限制

- `census.ps1` 的定向探测覆盖的是**已知的安装布局**。装在完全非标准位置的运行时
  要靠 `-Deep`（有深度上限的全盘扫描，慢）。
- `census.sh` 在 macOS 上对 `.app` 包的 JBR 探测只覆盖了常见命名，
  JetBrains Toolbox 的非标准安装路径可能漏掉。
- mise 在 Windows 上的原生支持不如 Unix 完善。某些插件的构建脚本假定
  类 Unix 环境，这类工具建议通过 WSL 或容器处理。
- Windows 上 mise 的 `mise.run` 安装脚本不可用（只支持 macOS/Linux），
  必须走 winget / scoop / choco / npm / 手工下载。

---

## 许可

MIT
