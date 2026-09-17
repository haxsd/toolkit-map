# AGENTS.md —— 运行时发现契约

这个文件是给 AI agent 看的。它规定的不是"这个项目怎么写代码"，而是
**"你在这台机器上找运行时的时候，必须遵守什么规则"**。

把本文件的内容复制到你实际使用的规则文件里（Cursor 的 `.cursor/rules/`、
`AGENTS.md`、`CLAUDE.md`，或任何会在会话开始时注入的上下文）。

---

## 一句话原则

> `node --version` 是解析器，不是盘点器。

它回答的是"按 PATH 顺序，第一个赢家是谁"，**不是**"这台机器上有哪些版本"。
把前者当成后者，就会说出一句关于机器的错误陈述，而且说得很自信——

> "本机只有 Node 16" ← 这句话通常是**错的**。它真正的含义是"PATH 解析到了 Node 16"。

---

## 必须遵守的四条规则

### 规则 1：先读声明，不要猜

在决定用哪个版本之前，先按顺序读这些文件：

| 位置 | 文件 | 作用 |
|---|---|---|
| 项目根目录及各级父目录 | `mise.toml` / `.mise.toml` / `.tool-versions` | 项目**要求**什么版本 |
| 项目根目录 | `.nvmrc` / `.python-version` / `package.json` 的 `engines` | 语言各自的传统声明 |
| 用户全局 | `~/.config/mise/config.toml` | 这台机器**提供**哪些版本 |

声明文件比探测更可靠：它表达的是需求和约定，而不是机器碰巧的现状。

### 规则 2：需要特定版本时，用一次性激活，不要改全局状态

```bash
mise exec -- node -v              # 按当前项目声明执行，最推荐
mise exec node@22 -- node -v      # 显式指定版本
uv run --python 3.12 script.py    # Python 的等价物
fnm exec --using=22 node -v       # 如果用的是 fnm
```

**不要**为了让某条命令用上新版本去改 PATH、改系统环境变量、或者全局安装。
那种做法会污染机器状态，而且让结果不可复现——你自己下次都未必能重现。

粒度优先级：**per-command > per-shell > per-project（带 hook）> 全局改 PATH**。

### 规则 3：盘点要用盘点工具，不要用 `--version` 下结论

```bash
# 跨平台的统一入口（本套件提供）
./scripts/census.sh          # macOS / Linux
.\scripts\census.ps1         # Windows

# 只看 mise 纳管的部分
mise ls                      # 已安装
mise ls-remote node          # 可安装

# 语言各自的盘点命令
py -0p                       # Windows：列出所有注册的 Python
uv python list               # uv 认识的 Python（含未安装的）
conda env list               # conda 环境
fnm list / nvm list          # Node 多版本
where.exe node               # Windows：列出全部命中，而不是只列第一个
which -a node                # Unix：同上
```

### 规则 4：在说出"本机只有 X 版本"之前，必须先完成一次真正的盘点

盘点需要覆盖这五类来源，缺一类就可能漏掉真实存在的运行时：

1. **声明层** —— 项目与全局的声明文件
2. **纳管层** —— mise / fnm / uv / conda 等管理器管理的
3. **约定层** —— PATH 里带版本号的命名 shim（`node22`、`python312`）
4. **非纳管层** —— 版本管理器目录、系统安装目录、IDE 内置运行时、conda 环境
5. **解析层** —— 常见命令实际解析到哪个文件

---

## 最容易踩的坑

### 坑 1：存在 ≠ 可用

Windows 上 `WindowsApps\python3.exe` 是 **0 字节的商店应用别名存根**。
`Get-Command python3` 会成功返回它，`where.exe python3` 也会列出它，
但真正执行时无输出、退出码 9009。

**判断标准**：不要只检查"文件存在"，要检查"文件非空且能执行"。

### 坑 2：PATH 是单值命名空间

PATH 是有序列表，同名命令只有第一个生效。所以：

- `D:\nodejs` 排在前面 → 装在别处的 Node 22 永远不会被 `node` 找到
- 装了 7 个 JDK → `java` 只会是其中 1 个

**PATH 单值不是缺陷，是它的本性**。正确做法是让 PATH 里的那一个位置指向
**间接层**（shim 目录或版本管理器的激活机制），由间接层按目录、按项目、
按命令决定用哪个版本。不要试图把多个具体版本都塞进 PATH 去争同一个名字。

### 坑 3：自定义命名约定会失传

`~/tools/bin/node22.cmd` 这种写法在工程上完全正确——单值命名空间里做并存安装
本来就这么干。但它创造了一个**只存在于文件名里的 API**：

- 想知道要读它，你得先知道它存在
- 想知道它存在，你得先读过它

这是个自指死锁。所以一旦发现这类约定，**必须写进声明文件**，
否则换台机器、换个 agent 就彻底失传。

### 坑 4：IDE 自带的运行时

JetBrains 系 IDE（PyCharm / IntelliJ）的安装目录里有 `jbr/`，
里面是完整的 JDK，版本往往比用户自己装的还新。它们不注册到系统，
`java -version` 永远看不到它们。

**只在明确需要时才使用它们**（比如临时验证某个新语法），
不要把它们当作项目的 JDK——那会让构建依赖某个 IDE 的私有安装。

### 坑 5：Windows PowerShell 5.1 的 `@()` 陷阱

`@($list)` 作用于 `List[object]` 会抛 `Argument types do not match`。
要用 `$list.ToArray()`。写 PowerShell 脚本处理运行时清单时会碰到。

---

## 报告格式要求

向用户报告运行时状况时，明确区分这三件事，不要混为一谈：

| 层次 | 说法 | 例子 |
|---|---|---|
| **声明** | "项目要求 X" | "`.tool-versions` 要求 nodejs 22.23.2" |
| **可用** | "这台机器上装了 X、Y、Z" | "装有 Node 16.20.2 和 22.23.2" |
| **解析** | "现在 `node` 会用到 X" | "当前 `node` 解析到 16.20.2" |

不要说"本机只有 X"，要说"PATH 上的 `node` 解析到 X，机器上另有 Y 未被 PATH 覆盖"。

---

## 项目接入清单

在一个新项目里开始工作前的建议流程：

```bash
# 1. 看项目声明了什么
cat mise.toml .tool-versions .nvmrc 2>/dev/null

# 2. 看本机是否满足
./scripts/census.sh

# 3. 若缺失或版本不符，按声明补齐（而不是改项目去迁就机器）
mise trust && mise install

# 4. 用一次性激活执行命令
mise exec -- npm ci && mise exec -- npm test
```

第 3 步的方向很重要：**让机器去满足项目的声明，而不是改项目去迁就机器**。
如果因为版本对不上就改 `engines` 或降级依赖，会造成"在你机器上能跑、
在 CI 上炸"的隐蔽问题。
