**中文** ｜ [English](platform-notes.md) ｜ [README](../README.zh-CN.md)

# 平台注意事项

Windows / macOS / Linux 上行为不一致的地方，以及那些会让一条正常命令看起来坏掉的坑。
每一条都是 `census` 会报出来的东西，而不是被藏起来的。

## PowerShell 5.1 上 `mise activate` 不能自动切换目录

mise 的 `chpwd` 钩子需要 PowerShell 7 及以上。在 5.1 下激活只会把 mise 的版本前置为
全局默认，`cd` 进项目不会切换版本——而后者才是用 `activate` 的唯一理由。

PowerShell 的 profile 是**分宿主**的（5.1 读 `WindowsPowerShell`，7 读 `PowerShell`），
所以只要本机装了 PowerShell 7，bootstrap 会把激活行**两个宿主都写上**，并直接告诉你
改用 `pwsh`。

判断「有没有装 7」必须实测，不能看文件存不存在：`WindowsApps` 里的 `pwsh.exe` 是
0 字节的应用执行别名。

## Windows 组合 PATH 的规则是机器级在前、用户级在后

解析命令时按组合后的顺序逐个目录找，所以机器级的直接工具目录
（`C:\ProgramData\Oracle\Java\javapath`）或用户级里排在靠前的旧目录，永远赢过通常被
追加在尾部的 mise shims。

`mise activate` 只在**当前会话内**把 shims 前置：交互式 shell 用对版本，而 cmd、
图形程序、IDE 任务、`-NoProfile` 脚本都悄悄用旧版本——这个缺口就是 `[PATH_ORDER]`
告警要指出的东西。bootstrap 把 shims 放到用户级 PATH 的**首位**（解决用户级的旧目录），
并单独列出机器级的目录（改它们需要管理员权限）。

## 存在 ≠ 可用（Windows），但 0 字节 ≠ 一定坏

`WindowsApps\python3.exe` 是 0 字节的商店应用执行别名，`Get-Command` 能找到、
`where.exe` 会列出，执行时无输出、退出码 9009。

但 0 字节**不等于一定坏**：`pwsh.exe` 和 `winget.exe` 同样是 0 字节别名，却能正常执行，
因为目标应用装了。文件长度只说明「可疑」，要确认必须真跑一次版本命令看有没有输出。
`census` 就是这么做的：`[STUB]` 只在实测失败时才出现。

## ZIP 下载会丢可执行位（Linux/macOS）

GitHub 打包的 ZIP 不带文件模式，解压后 `./scripts/census.sh` 会报 `Permission denied`
（仓库里它是标记为可执行的）。要么改用 clone，要么解压后执行一次
`chmod +x scripts/*.sh`。

## PATH 里的 `bash` 通常是 WSL 转发壳

Windows 上的 `bash` 一般是 `C:\WINDOWS\system32\bash.exe`；没装发行版时它会报
`execvpe(/bin/bash) failed: No such file or directory`，看起来像脚本语法错误，其实不是。
`tests/verify-shell.ps1` 会找一个真 bash（Git Bash，否则退回 `bash` 容器），对所有
`.sh` 执行 `bash -n`——只解析、不执行。

## PowerShell 5.1 的 `@()` 陷阱

`@($list)` 作用于 `List[object]` 会抛 `Argument types do not match`，要用
`$list.ToArray()`。如果脚本里同时设了 `$ErrorActionPreference = 'SilentlyContinue'`，
这个错误会被完全吞掉，只在后续表现为某个对象莫名变成 `$null`，极难排查。

## 已知限制

- 定向探测只覆盖**已知的安装布局**，装在完全非标准位置的运行时需要 `--deep`。
- `census.sh` 对 macOS 上 `.app` 包内 JBR 的探测只覆盖常见命名，
  JetBrains Toolbox 的非标准安装路径可能漏掉。
- mise 在 Windows 上的原生支持不如 Unix 完善，部分插件的构建脚本假定类 Unix
  环境，这类工具建议走 WSL 或容器。
- Windows 上不能用 mise 的 `mise.run` 安装脚本（只支持 macOS/Linux），需要走
  winget / scoop / choco / npm / 手工下载。
- 命令行输出默认中文。告警代码（`STUB` / `SHADOWED` / `CONVENTION` / `MISSING`）
  与 `--json` 输出是语言无关的；`--lang en` 可以切换两个平台上的文字。
