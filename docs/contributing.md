# 贡献指南

## 结构

| 路径 | 职责 |
|---|---|
| scripts/map.ps1 | 命令入口、安装与 JSON 结果 |
| scripts/map-core.ps1 | 候选、验证、存储、锁、项目选择、setup/doctor |
| scripts/toolkit-common.ps1 | 地图和 Windows 扫描内核共享的护栏、声明读取 |
| scripts/tools.json | 命令别名、安装位置提示、探测参数、portable 配方 |
| scripts/census.ps1 / census.sh | Windows / Unix 扫描内核 |
| scripts/census-text.tsv | 两个扫描内核共用的中英文案（key、lang、text），必须与脚本同目录 |
| scripts/bootstrap.ps1 / bootstrap.sh | 可选的 mise 环境配置，会修改机器 |
| tests/ | 隔离回归测试 |
| AGENTS.md / SKILL.md | 发现契约与 agent 使用协议 |

## 开发检查

先按 AGENTS.md 查地图拿到 Git、PowerShell、Bash 的绝对路径。需要项目版本时用一次性激活，不改全局 PATH。

| 检查 | 覆盖 |
|---|---|
| tests/check-encodings.ps1 | .ps1 的 UTF-8 BOM、英文系统解析；.sh 无 BOM |
| tests/check-docs.ps1 | 中文单语文档、相对链接与 VERSION 版本号一致 |
| tests/check-text.ps1 | census-text.tsv 格式、每个 key 中英齐全、脚本引用可解析、-Lang en 输出与缺失文案表时失败 |
| tests/map-smoke.ps1 | 失效路径修复、版本 stderr、安装失败和拒绝覆盖 |
| tests/map-contract.ps1 | 动态项目选择、验证状态、重扫保留、查询缓存、并发、接入和 JSON |
| tests/install-contract.ps1 | portable 暂存、校验、版本验证、回滚、已有副本复用、winget 兜底登记与配方官方校验 |
| tests/download-contract.ps1 | 官方 SHA256 来源、校验文件解析、固定版本配方与证书重试条件（CI 中 PowerShell 5.1 / 7 独立步骤） |
| tests/version-contract.ps1 | 版本要求比较、预发布、超长数字段与候选排序（表驱动，CI 中 Windows PowerShell 5.1 / 7 与 Linux PowerShell 7 独立步骤） |
| tests/scan-guards.ps1 | 扫描解析层和底层执行器都跳过 shim |
| tests/parity.ps1 | 两个扫描内核在同一沙箱识别相同问题 |
| tests/verify-shell.ps1 | .sh 语法 |
| tests/smoke.sh | Unix 扫描、JSON、语言、自定义 shim 与脚本启动器护栏、probeStats 与 `--timing` 阶段键 |
| tests/check-sh-vars.sh | .sh 里 `$VAR` 后不能紧跟非 ASCII 字符（bash 3.2 兼容） |
| tests/scan-baseline.ps1 | 用临时地图在真实机器上跑一次 scan，打印首扫墙钟时间与进程启动次数（CI 的 windows-baseline job，只量不判） |

按改动范围检查；发布前跑全套。map-contract 同时用 PowerShell 5.1 和 7 执行；真实扫描另用临时 -MapFile 验证，不污染本机地图。测试使用假工具、临时目录与独立地图，不安装工具。

新增探测适配器时在 tools.json 定义 probe 参数数组；命令名和安装名不同时定义 aliases/warehouseNames。locations 可使用 Windows 环境变量提示常见安装位置。仅在成功退出并能提取版本时标为 verified。

## 必须守住的边界

- .ps1 带 UTF-8 BOM；.sh 用 LF、无 BOM，保留 Git 可执行位。
- .sh 里变量后面紧跟中文或全角标点时一律写 `${VAR}`：macOS 自带的 bash 3.2 会把 `$VAR（` 里的全角字符吞进变量名，`set -u` 下直接报 unbound variable。tests/check-sh-vars.sh 在 CI 的 ubuntu 与 macOS job 里检查。
- 扫描不执行识别到的 shim、不安装工具、不写 PATH、不卸载已有副本。
- 用户机器清单和工具仓库不入库，发布包只包含被 Git 跟踪的源码、协议和通用示例。
- 项目要求在查询时计算；不能把某个项目要求缓存成机器全局选择。
- 缺少匹配版本或无法判定要求时失败，不把未知当满足。
- 地图写入必须经过完整读改写锁与原子写入；损坏/未来格式不能当空地图覆盖。
- 新接入规则先预览，已有内容保留、备份，重复执行幂等。
- 文档单语中文；扫描内核文案可保留已有英文输出。

## 发布

1. 修改根目录 `VERSION`（help 自动读取），再按 tests/check-docs.ps1 的提示同步 CHANGELOG 与文档中的稳定标签。
2. 全套检查与两个宿主的契约测试通过。
3. 推送分支，PR CI 通过后合并 main。
4. 从合并提交创建版本标签，用 git archive 生成源码 zip 与 SHA256 校验文件。
5. 发布 GitHub Release，附兼容性说明；确认标签、main 与发布提交一致。

仍待扩展：Unix 地图动作、更多管理器/平台适配器、复杂声明委托。bootstrap 的可选环境配置与 setup 的规则接入保持分开。