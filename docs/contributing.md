# 贡献指南

## 仓库结构

```text
scripts/    产品：map.ps1（地图）、census.ps1|sh（扫描内核）、bootstrap.ps1|sh（可选：mise 与 PATH）
templates/  mise-config.toml，bootstrap 部署的机器级声明模板
examples/   声明文件示例（两种格式）
tests/      开发检查，不属于产品面
docs/       参考手册、平台说明、本文件（单语中文）
AGENTS.md   发现契约：agent 判断工具在哪、哪个会生效时的规则
SKILL.md    使用协议：find / install 的硬规矩
```

## 本地检查

| 检查 | 做什么 |
|---|---|
| `.\tests\check-encodings.ps1` | 每个 `.ps1` 带 UTF-8 BOM、每个 `.sh` 都不带，且 `.ps1` 按 cp1252 读法也能解析。加 `-Fix` 可补 BOM |
| `.\tests\check-docs.ps1` | 文档单语（禁止 `.zh-CN.md` 回潮）、所有相对链接与锚点可解析 |
| `.\tests\parity.ps1` | 在同一个沙箱里跑两份扫描内核，断言它们发现同一批人造问题 |
| `bash tests/smoke.sh` | 扫描内核（shell 版）的冒烟测试 |
| `.\tests\verify-shell.ps1` | 对所有 `.sh` 执行 `bash -n`——只解析、不执行 |

**该跑多少**：只跑覆盖你改动的那几项——改文档 → `check-docs`；动 `.sh` → `verify-shell`；
改告警或解析逻辑 → `parity`；动 `map.ps1` → 手动跑一遍 `scan` + `find`。**发布前才跑全套**。
`parity.ps1` 要把两份实现各跑一遍（约一分钟），每改一处就全套跑一遍，正是让这个仓库
显得又慢又重的原因。

想确认"别人克隆下来能不能用"：把跟踪的文件复制到一个干净目录（不要 `.git`），按 README 走一遍，
不必天天做。

## 容易踩坏的红线

- **每个 `.ps1` 带 UTF-8 BOM。** 没有 BOM 时，英文系统的 PowerShell 5.1 会按 cp1252 解码中文注释、
  读成智能引号，脚本直接解析失败——中文系统的开发机上完全看不到这个问题。
- **每个 `.sh` 用 LF 且不带 BOM。** BOM 会让 shebang 失效；CRLF 会让脚本报
  `env: 'bash\r': No such file or directory`。`.gitattributes` 已把 `*.sh` 钉成 `eol=lf`。
- **新增 `.sh` 要保住可执行位**：`git update-index --chmod=+x scripts/foo.sh`。Windows 上的检出
  无法设置它，而 CI 会直接执行这些脚本。
- **`scan` 必须保持只读。** 扫描/探测不得执行 shim（会触发管理器自动安装）、不得写 PATH、
  不得卸载任何东西。只有 `install` 改状态，且只改统一仓库里的那一份。
- **本机状态绝不入库。** 地图（`~/.toolkit/map.json`）、统一仓库（`~/toolchains/`）和当前机器的
  工具清单都留在使用者本机；仓库只提交协议、脚本、配方、模板和通用示例。
- **文档单语（中文）。** 消费方是 agent 与你自己；同时维护中英两份只会互相漂移。
  `AGENTS.md` 与 `SKILL.md` 本来就是契约文件，同样保持单语。
- **两份实现共享文档化的字段，但不要求结构逐字段一致。** `host.powershell` 这类
  平台特有字段允许只在一边出现；字段表在 `docs/reference.md`，据此扩展 `tests/parity.ps1`。

## CI 跑什么

| 任务 | 步骤 |
|---|---|
| `windows`（宿主 PowerShell 5.1） | 编码检查 → 文档检查 → `tests/parity.ps1` |
| `ubuntu` | 对 `scripts/*.sh` 与 `tests/*.sh` 执行 `bash -n` → `tests/smoke.sh` |

CI 刻意**不跑** `bootstrap`：它会真的改机器（写 PATH、动 profile、下载运行时）。
失败信息以 `::error::` 注解输出，因为 job 日志需要鉴权、注解不需要——无人值守时这是唯一
能自己看到失败原因的通道。

## 还没做的

- `map.sh`（Unix 版）：macOS / Linux 上目前只有扫描内核可用，地图的动作还没移植。
- `install` 的降级链：目前支持 GitHub portable 配方、固定 URL 配方和 `-Via winget` 兜底；
  安装器管理的工具登记真实路径但不保证落在统一仓库，其他工具先人工装好再用 `map.ps1 add` 登记。
