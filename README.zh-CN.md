**中文** ｜ [English](README.md)

[![CI](https://github.com/haxsd/runtime-census/actions/workflows/ci.yml/badge.svg)](https://github.com/haxsd/runtime-census/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

# runtime-census

找出这台机器上**真正存在**的每一个**工具**——语言运行时只是其中一类——并用声明式方式管理它们。

`node --version` 只能告诉你**现在用哪个**，不会告诉你**装了哪些**。这两件事的
差别，就是「本机只有 Node 16」这类错误结论的来源 —— 而磁盘上可能还躺着同一个
命令的另一份副本、IDE 里捆绑的 JDK、conda 环境，以及去年手装却早已忘记的 CLI。

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

> 用 ZIP 下载而不是 git clone 的：Windows 会给这些文件打上「来自网络」标记，
> PowerShell 会拒绝执行。先解除一次即可：`Get-ChildItem -Recurse | Unblock-File`

在干净的 PATH 上是几秒钟，在 Windows 上 PATH 条目上千时可能到半分钟——`--timing`
会打出各阶段耗时。节选：

```
 4. 运行时清单 —— 磁盘上实际存在的运行时（含纳管与未纳管）
  NODE  共 2 个
    16.20.2        <系统盘>:\nodejs\node.exe                    [系统安装]
    22.23.2        %USERPROFILE%\tools\node22\node.exe          [自定义位置]
  JAVA  共 3 个
    11.0.6         ...\IntelliJ IDEA\jbr\bin\java.exe           [IDE 内置]

 6. 告警 —— 需要人工确认的问题
  [SHADOWED]   'node' 在磁盘上有 2 个副本，其中 1 个不在 PATH 上，无法被直接调用
  [CONVENTION] 发现自定义命名约定 node22 —— 这类约定必须写进声明文件否则会失传
```

需要机器可读格式就加 `--json`；想要英文输出加 `--lang en`。

## 为什么需要它

`which node` 和 `node --version` 是**解析器**：按 PATH 顺序返回第一个赢家。
把它当成**盘点器**用，就会漏掉大部分运行时。常见的四种漏法：

| 遮蔽方式 | 例子 |
|---|---|
| PATH 单值 | 同一个工具装了两份，裸名字只会解析到最靠前的那份 |
| 自定义命名 | 工具被装成 `node22` / `python3.12` / `r2-5.9`，因为原名被占了 |
| 根本不在 PATH | conda 的 Python、pyenv 的版本、随手丢进 `~/toolchains` 或 `~/.local/bin` 的 CLI |
| 宿主内置 | IDE 自带的 JBR 里有完整 JDK，从不注册为系统工具 |

census 逐类盘点，把「用哪个」和「有哪些」两个问题分开回答。它不限于语言运行时：
任何能被声明的工具（编译器、CLI、逆向工具）都走同一条流水线。

## 想让版本按项目自动切换

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

它会装 [mise](https://mise.jdx.dev)、部署机器级声明、把 mise 的 shims 放到**用户级**
PATH 首位，并执行 `mise install`。它不动机器级环境变量、不删你已有的 PATH 条目、
不碰 IDE 自带的运行时。它做的每一步、以及怎么撤销，都列在[命令参考](docs/reference.zh-CN.md)里。

## 当成 skill 安装

仓库根目录有 `SKILL.md`，所以它本身就是一个 Cursor / Claude skill。装法是把
skills 目录**链接**到这份克隆上，而不是复制一份 —— 这样以后 `git pull` 就等于升级 skill：

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

`AGENTS.md` 是配套的**发现契约**，写清了 agent 在判断工具可用性时必须遵守的规则。
可以单独拷进你自己项目的规则文件，不依赖本仓库。

## 文档

| | |
|---|---|
| [命令参考](docs/reference.zh-CN.md) | 全部参数、JSON 结构、告警代码含义、非托管运行时的规范根 |
| [平台注意事项](docs/platform-notes.zh-CN.md) | Windows 的 PATH 顺序、0 字节别名、已知限制 |
| [贡献指南](docs/contributing.zh-CN.md) | 本地检查、CI、编码与行尾符规则 |

## 常见问题

**为什么不直接用 mise？**
mise 只能管到它自己装的东西，它永远不会知道 `<系统盘>:\nodejs`、conda 的 Python、
或者 IDE 自带的 JDK。纳管层和存量层必须分开看 —— 只做前者，会让人误以为
盘点已经完整了。

**census 会不会很慢？**
用定向探测而不是全盘遍历：一次 `stat` 比一次目录枚举便宜一到两个数量级。
真正花时间的是为找到的东西开子进程——所以 `--deep` 才是唯一明显慢的路径。

**为什么不用 Docker？**
容器是另一条路线，隔离更彻底，代价是每个项目都要构建镜像。本项目的目标是
**让原生机器变得可预测**。两者可以并存。

## 许可

MIT © [haxsd](https://github.com/haxsd)
