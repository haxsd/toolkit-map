**中文** ｜ [English](contributing.md) ｜ [README](../README.zh-CN.md)

# 贡献指南

同一个工具有两份实现，靠人肉保持同步，而漂移真实发生过：`census.sh` 曾因为一个
辅助函数少收一个字段，导致运行时清单静默变空，而报告看起来一切正常。所以下面这些
检查是契约，不是形式。

## 目录结构

```text
scripts/     产品本身——census 与 bootstrap，每个平台一对
templates/   mise-config.toml，bootstrap 部署的机器声明模板
examples/    两种格式的声明文件样例
tests/       开发期检查，不属于产品对外接口
docs/        命令参考、平台注意事项、本文件——中英各一份
AGENTS.md    给 agent 的发现契约
SKILL.md     让本仓库可以直接作为 Cursor / Claude skill 安装
```

## 本地检查

| 检查 | 做什么 |
|---|---|
| `.\tests\check-encodings.ps1` | 每个 `.ps1` 都带 UTF-8 BOM、每个 `.sh` 都不带，并且每个 `.ps1` 按 cp1252 读法也能解析。加 `-Fix` 可补上缺失的 BOM |
| `.\tests\check-docs.ps1` | 每个文档都有中文对应版本，且所有相对 Markdown 链接都能解析 |
| `.\tests\parity.ps1` | 在同一个沙箱里跑两份实现，断言两边发现了同一批人造问题。Windows 上需要一个真 bash（会自动找到 Git Bash）；`-KeepSandbox` 保留沙箱便于事后翻看 |
| `bash tests/smoke.sh` | `census.sh` 对着一台人造机器的冒烟测试 |
| `.\tests\verify-shell.ps1` | 用真 bash 对所有 `.sh` 执行 `bash -n`——只解析、不执行 |

**该跑多少**：只跑覆盖你改动的那几项——改文档 → `check-docs.ps1`；动 `.sh` → `verify-shell.ps1`；
改告警或解析逻辑 → `parity.ps1`。**发布前才跑全套**：`parity.ps1` 要把两份实现各跑一遍
（约一分钟），每改一处就把全套跑一遍，正是这个仓库显得又慢又重的原因。
想确认"别人克隆下来能不能用"，把跟踪的文件复制到干净目录、按 README 跑一遍即可，不必天天做。

## 容易踩坏的红线

- **每个 `.ps1` 都必须带 UTF-8 BOM。** 否则英文系统上的 PowerShell 5.1 会按 cp1252
  解码中文注释、把它们变成智能引号，脚本直接解析失败——而这个问题在中文系统的
  开发机上完全看不见。
- **每个 `.sh` 都用 LF 且不带 BOM。** BOM 会让 shebang 失效；CRLF 会让脚本报
  `env: 'bash\r': No such file or directory`。`.gitattributes` 已经把 `*.sh` 钉成 `eol=lf`。
- **新增 `.sh` 时要保住可执行位**：`git update-index --chmod=+x scripts/foo.sh`。
  Windows 上的检出无法设置它，而 CI 会直接执行这些脚本。
- **两份实现的 `--json` 共享一份「文档化的核心」，但不要求结构上完全一致。** 消费者可以依赖
  `docs/reference.md` 里列出的字段；某个平台特有的事实（例如 `host.powershell`）允许只在
  对应实现里出现。**文档化**的字段集合或语义变化时递增 `schemaVersion`；新增告警类别时同步
  扩展 `tests/parity.ps1`。逐字段强制两边一致是刻意不做的：对齐的成本比"少一个字段"的代价高。
- **`census` 保持只读。** 任何会改动机器状态的逻辑都放进 `bootstrap`，并且必须先能在
  `-DryRun` / `--dry-run` 下把计划完整打印出来。
- **文档成对存在。** `<name>.md` 与 `<name>.zh-CN.md` 必须同时存在且说同一件事；
  主页是 `README.md` 与 `README.zh-CN.md`。`AGENTS.md` 与 `SKILL.md` 是例外：
  它们是要被整份拷进别的项目的契约，所以刻意只维护单语版本。
- **新增面向用户的文字要走翻译辅助函数**，这样 `--lang en` 才能与默认中文并存。

## CI 跑什么

| 任务 | 步骤 |
|---|---|
| `windows`（宿主是 PowerShell 5.1） | 编码检查 → 文档检查 → `tests/parity.ps1`（Windows PowerShell 5.1 与 shell 版在同一沙箱里对跑） |
| `ubuntu` | 对 `scripts/*.sh` 与 `tests/*.sh` 执行 `bash -n` → `tests/smoke.sh` |

CI 刻意**不跑** bootstrap：它会真的改机器——写 PATH、动 profile、下载运行时。
失败信息会以 `::error::` 注解的形式输出，因为 job 日志需要鉴权、注解不需要——
这是无人值守时唯一能自己看到失败原因的通道。
