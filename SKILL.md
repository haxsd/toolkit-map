---
name: toolchain-kit
description: "盘点和管理本机的语言运行时（Node / Python / Java 等的多版本共存）。当需要回答这台机器上到底装了哪些版本、发现 node/python/java 版本与预期不符、遇到某个项目需要旧版本而新版本看不见、要在项目里锁定运行时版本、或者要在一台新机器上一次性配好工具链时使用。Use when asked which runtime versions are installed on this machine, when a version mismatch appears (e.g. only Node 16 is visible while a project needs 22), when pinning per-project tool versions, or when setting up a machine's toolchain declaratively."
---

# toolchain-kit

管理本机语言运行时的工具集。核心作用是解决一个常见的错误认知：

> `node --version` 是**解析器**（回答"按 PATH 顺序现在用哪个"），
> 不是**盘点器**（回答"这台机器上装了哪些"）。

把前者当成后者，就会得出 `本机只有 Node 16` 这种关于机器的错误结论。
真实情况常常是装了 2 个 Node、3 个 Python、3 个 JVM，只是后两个被 PATH 挡住了。

## 铁律

在动任何运行时之前先读这几条，它们决定了后面所有命令的写法。

1. **不要用 `--version` 回答"有哪些"。** 它只能回答"用哪个"。
2. **先读声明，再决定版本。** 项目里的 `mise.toml` / `.tool-versions` /
   `.nvmrc` / `package.json` 的 `engines` 表达的是**需求**；探测只能反映**现状**。
   需求优先。
3. **需要特定版本时用一次性激活，不改全局状态。**
   `mise exec -- <命令>` 优于改 PATH、优于全局安装。
4. **让机器满足项目，而不是改项目迁就机器。** 版本对不上就装、就切，
   不要顺手改 `engines` 或降级依赖——那会造成"本机跑得通、CI 上炸"的隐蔽问题。
5. **说结论之前先完成一次真实盘点。** 不要说"本机只有 X 版本"，
   要说"PATH 上的 `node` 解析到 X，机器上另有 Y 未被 PATH 覆盖"。

完整的契约（含五类盘点来源、五个常见坑、报告格式要求）在 `AGENTS.md`，
需要给其它项目用时直接拷那个文件。

## 三个使用场景

脚本都在**本 skill 目录的 `scripts/` 下**。Windows 用 `.ps1`，macOS/Linux 用 `.sh`。

### 场景一：不知道这台机器上有什么

```powershell
<skill目录>\scripts\census.ps1          # 人类可读报告
<skill目录>\scripts\census.ps1 -Json    # JSON，供程序消费
<skill目录>\scripts\census.ps1 -Timing  # 附带各阶段耗时
```

```bash
<skill目录>/scripts/census.sh
<skill目录>/scripts/census.sh --json
```

输出六节：声明层 / mise 纳管层 / 命名约定层 / 运行时清单 / 解析层 / 告警。
告警有四种，每一种都能直接转成行动：

| 告警 | 含义 | 该做什么 |
|---|---|---|
| `STUB` | 命令解析到 0 字节的假文件 | 这个命令不能用，换一个 |
| `SHADOWED` | 有多个版本，但 PATH 只暴露一个 | 用 `mise exec` 或显式路径 |
| `CONVENTION` | 存在只写在文件名里的版本约定 | 必须写进声明文件，否则会失传 |
| `MISSING` | 声明要求了但没装 | `mise install` |

### 场景二：新机器，要把环境一次配好

```powershell
<skill目录>\scripts\bootstrap.ps1 -DryRun   # 先看会改什么
<skill目录>\scripts\bootstrap.ps1           # 再执行
```

```bash
<skill目录>/scripts/bootstrap.sh --dry-run
<skill目录>/scripts/bootstrap.sh
```

它会装 mise、写入机器声明、把 shims 目录加入用户级 PATH、拉取运行时。
刻意不做：不动机器级环境变量、不删已有的 PATH 条目、不碰 IDE 自带的运行时。

### 场景三：项目里锁定运行时版本

```toml
# 项目根目录 mise.toml
[tools]
node   = "22"
python = "3.12"
```

```bash
mise trust && mise install
mise exec -- npm test        # 一次性激活，零全局状态
```

## 两个平台陷阱

写脚本或判断运行时可用性时会踩到，遇到诡异现象先想到这两条。

**存在 ≠ 可用（Windows）。** `WindowsApps\python3.exe` 是 **0 字节的商店应用
别名存根**：`Get-Command` 能找到它，`where.exe` 也会列出它，但执行时无输出、
退出码 9009。判断时必须检查文件长度，不能只检查是否存在。

**PowerShell 5.1 的 `@()` 陷阱。** `@($list)` 作用于 `List[object]` 会抛出
`Argument types do not match`，必须用 `$list.ToArray()`。而且如果脚本里设了
`$ErrorActionPreference = 'SilentlyContinue'`，这个错误会被完全吞掉，
只在后续表现为某个对象莫名变成 `$null`。

## 本套件不负责的事

- **不安装语言本身之外的开发工具**（jadx、frida、nmap 之类）。它只管运行时版本。
- **不管容器**。需要完全隔离的环境用 Docker 或 devcontainer，那是另一条路线。
- **不改 IDE 自带的运行时**。JetBrains 的 `jbr/` 属于 IDE 的一部分，
  census 会把它单独标为「IDE 内置」，仅供知情，不建议当项目 JDK 用。
