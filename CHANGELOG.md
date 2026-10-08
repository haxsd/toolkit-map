# 更新记录

## 未发布

- 扫描数据外置（收敛计划 C3，不改行为）：探测相对路径（`$script:ProbeRelatives` / `probe_root`）、conda 环境目录与解释器路径、静态候选根目录、解析层默认命令表、约定层命令名与"公认名字"排除表移到同目录的 `scripts/census-data.tsv`（kind<TAB>os<TAB>value），census.ps1 与 census.sh 读同一份；两边现有差异原样写成 os = win / unix 行，没有统一。根目录用 `{APPDATA}` / `{USERPROFILE}` / `{HOME}` / `{MISE_DATA}` 等占位符。缺表或缺必需的 kind 时两个脚本以退出码 2 明确失败。新增 tests/check-data.ps1；smoke.sh 增加缺表用例；scan-guards 单独运行 Get-Resolution 时自行加载数据表。
- 统一探测执行器（收敛计划 P2，不改行为）：toolkit-common.ps1 新增 `Invoke-ToolkitProbe`，返回原始 stdout/stderr、退出码与失败原因（timeout / skipped / unsupported_probe / probe_failed），shim 护栏在任何执行之前；census.ps1 的 `Get-FirstLine` / `Invoke-CaptureWithTimeout` 与地图的 `Get-ProbeText` 改为薄封装，各自的取文本口径不变。原来地图侧按 路径|长度|修改时间 记版本号的 ProbeCache 扩展为执行器里按 路径|长度|修改时间|参数 记原始结果的进程内缓存，census.ps1 的 VersionCache 并入其中；命中缓存不计入 `probeStats.launches`。统一后 .cmd 探测一律用 `cmd /d /s /c`，进程退出后读输出流最多再等 2 秒（不再可能被占着管道的孙进程卡住）。新增 tests/probe-cache.ps1；scan-guards 去掉已无用的 VersionCache 初始化，并断言执行器本身不执行 shim。windows-baseline 改为每个宿主冷启动两轮只计第二轮，宿主按 PS7 → PS5.1 出场。
- 计量（收敛计划 P1，只量不改行为）：census.ps1 / census.sh 的 JSON 新增附加字段 `probeStats {launches, ms}`（版本探测启动的外部进程数与累计耗时，schemaVersion 仍为 1）；`--timing` 两边改用同一组阶段键（census.sh 把原来的 roots 拆成 roots / probe / deep-scan），bash 5 及以上用 EPOCHREALTIME 计到毫秒，文本输出两边同格式并补上合计与探测进程数（census.ps1 原来的合计行丢了数字）。`map.ps1 scan` 的结果新增 `probeStats`（总进程数、探测耗时、整次墙钟及 census/地图分项）。新增 tests/scan-baseline.ps1 与 CI 的 windows-baseline job，在真实 runner 上记录首扫基线；smoke / parity / check-text / map-contract 增加 probeStats 为非负整数的断言。
- 新增 tests/check-sh-vars.sh（CI 的 ubuntu 与 macOS job）：.sh 里 `$VAR` 后紧跟非 ASCII 字符即失败并给出文件与行号，要求写成 `${VAR}`（macOS 的 bash 3.2 会把紧跟的全角字符吞进变量名）；docs/contributing.md 补上这条规则，并修正 version-contract / download-contract 已是独立 CI 步骤的说明。
- census.ps1 与 census.sh 的中英文案合并为同目录的 `scripts/census-text.tsv`（key<TAB>lang<TAB>text），两边读同一份，不再各维护一张表；两边措辞尚未统一的 4 条（PATH_DIRT 文案、DRIFT/MISSING/NO_MISE 处置建议里的 bootstrap 脚本名）用 `ps1:`/`sh:` 前缀分开保存，输出与之前逐字一致。文案表缺失时两个脚本以退出码 2 明确失败。新增 tests/check-text.ps1 检查格式、中英齐全、脚本引用可解析与 `-Lang en` 输出。
- CI：`parity.ps1` 与 `map-smoke.ps1` 增加 PowerShell 7 步骤（census.ps1 与地图动作在 PS7 宿主下也逐条验证）；新增 macOS job，用系统自带的 bash 3.2 做语法检查并跑 `smoke.sh`，守住 census.sh 在 macOS 开箱即用的承诺。
- 测试：census 沙箱的期望告警改由 `tests/fixtures/census-expected.tsv` 统一提供（kind / tool / 字面关键字），`parity.ps1` 与 `smoke.sh` 读同一份，不再各自硬编码、各自漂移；`smoke.sh` 在原有"告警种类"检查之外新增按 JSON 的 kind/tool/关键字断言（纯 awk，不依赖 python3/jq）；`.gitattributes` 钉住 `*.tsv` 为 LF。
- 配方安装强制校验官方 SHA256：下载前依次取配方钉死值、GitHub 发布资产 digest、上游校验文件（gh 的 checksums.txt、rg 的 CertUtil 格式 .sha256）；都取不到返回 `checksum_unavailable` 且不下载，`-Sha256` 与官方值冲突返回 `checksum_conflict`；结果带 `integrity` 说明来源。修复 `$url`/`$Url` 同名（PowerShell 变量不分大小写）导致配方分支无法与 `-Url` 区分的问题。
- adb 改为官方带版本号的 `platform-tools_r37.0.1-win.zip`，钉死 SHA256 并同时校验 Google SDK 仓库清单公布的 SHA-1；其他版本返回 `version_unavailable`，WhatIf 不再需要联网解析 latest。
- 证书重试收窄为吊销检查失败（信任关系 / revocation 类错误），只在 Windows PowerShell 5.1 且本进程开启吊销检查时临时关闭重试一次；PowerShell 7 的 HttpClient 不读 ServicePointManager，原有重试无效，已移除。新增 tests/download-contract.ps1（CI 在 5.1 与 7 下单独运行），install-contract 增加配方校验用例。
- 版本比较不再使用定长整数：日期型构建号等超长数字段（如 `1.2.20240101123456`）不会再让 find 或扫描抛异常；census.ps1 的声明比较同步修复。
- 预发布处理统一：semver 的 `-rc.1` 与 Python 的 `3.12.0rc1`、`a2`、`.dev0` 等都视为预发布，只在完整精确匹配时满足要求（此前 `3.12.0rc1` 会被当成满足 `3.12`）。
- 默认候选排序改用版本排序键：单段版本（`22`）、超长数字段按数值排序，同号正式版优先于预发布；新增表驱动的 tests/version-contract.ps1，CI 在 Windows PowerShell 5.1 / 7 与 Linux PowerShell 7 下单独运行。
- 版本号唯一来源改为根目录 `VERSION`：`help` 读取它，check-docs 校验 README/接入指南中的稳定标签与 CHANGELOG 最新版本一致。
- `map.ps1` 关闭进度条输出，Windows PowerShell 5.1 下载 portable 归档不再被进度刷新拖慢。
- `install -Via winget`：工具名按其他动作规范化并校验，包 ID 不能以 `-` 开头；只把本次安装后新出现的文件标注为 winget 安装，同名旧文件不冒充，多个新文件时不猜测；新建地图直接使用 v2 结构，去掉被 Save-Map 覆盖的无效首选赋值；也搜索用户级 `%LOCALAPPDATA%\Programs`。
- 扫描与探测不再经由脚本型启动器间接执行 shim：npm/npx/pnpm/yarn/corepack 的 `#!/usr/bin/env node` 或"同目录没有 node 就走 PATH"会落到 PATH 上的 node shim。census.sh、census.ps1 与地图探测共用同一套规则，解释器不安全时只登记路径、不执行；smoke.sh 自带假启动器复现该场景。
- 修复 PowerShell 7 在非 UTC 时区下每次 find 都重新探测候选并重写 map.json / map.md：modifiedAt 统一按 UTC ticks 比较，5.1 与 7 行为一致；map-contract 增加连续查询不探测、不写盘的断言。

## v0.2.3 — 首次使用与支持入口

- README 按陌生用户旅程重排：直观场景、稳定版下载、单项目接入、Git 验证与可复制的 agent 验收提示。
- 新增 CI/版本/许可/平台徽章与能力范围表；区分发现、版本选择和有限的自动安装配方。
- 新增故障排查、撤销接入与卸载指南；补齐升级稳定标签、技能入口和规则刷新步骤。
- 新增中文 Bug/功能请求表单与支持链接；保留普通 Issue 入口。
- 发现与安装核心行为不变，预计安装占用 ≥1 GB 的位置确认门槛不变。

## v0.2.2 — 声明与安装边界修复

- 嵌套/点号 mise 工具表不再被忽略；无法解释的工具声明返回 requirement_unsupported，不回退到全局版本。
- 修复 <=22、>22、=22.23 等部分版本比较的范围边界。
- portable 工具移动到最终位置后再次验证；验证失败回滚该次新建目录，不登记失败副本。
- 重复安装仓库内已验证版本改为复用，不下载、不覆盖、不重复登记。
- 补充 Windows 默认脚本执行策略、单次宿主调用和下载 ZIP 标记说明；接入模板与 setup 同步更新。

## v0.2.1 — agent 规则接入与大工具存储选择

- README 明确安装后还需接入前端规则，区分全局与项目使用，新增 Cursor、Codex、Claude Code 指南及可复制通用/MDC 模板。
- setup 生成的规则和技能增加大工具下载前的位置确认：仅预计安装占用 ≥1 GB 时询问；用户已有合适位置偏好时复用。
- 补齐 TOOLCHAIN_ROOT 的临时/持久配置、TEMP 暂存、mise/rustup 的独立存储与缓存边界。已有副本不自动迁移；CLI 本身仍不估算体积或交互询问。

## v0.2.0 — 项目感知与可信发现

- 将机器清单与项目选择分开：find 每次读取当前或指定项目声明，支持 -Project / -Version，项目覆盖全局要求，版本缺失不降级。
- 在地图与两套扫描内核的探测链增加 shim 护栏，支持自定义目录，shim 永不作首选。
- 候选记录 verified/unverified/unavailable/skipped；普通零字节文件不再返回可用；版本探测读取 stdout/stderr、检查退出码并限制等待。
- 修复 PowerShell 7 scan 的宿主路径；PowerShell 专用探测禁用 profile。
- 稳定路径 ID，修复同版本 Prefer；重扫保留手工登记、备注和偏好；局部更新不刷新完整扫描年龄。
- 增加 setup / doctor，支持预览、规则备份、幂等接入；明确区分文件配置与实际 agent 行为。
- 统一地图动作 JSON 协议 v2、错误状态与退出码；v1 地图读取迁移，损坏/未知格式不覆盖。
- 加入进程更新锁、并发回归测试；工具别名/探测/安装配方集中在 tools.json，兼容 rg/ripgrep 的旧仓库目录。
- portable 安装验证实际版本，安装参数不能越出仓库；WhatIf 不联网；安装成功但无法发现文件会明确失败。
- CI 同时验证 PowerShell 5.1/7 的项目选择、接入、并发与扫描护栏，保留 Windows/Unix 扫描一致性检查。

升级说明：JSON 消费方应读取 schemaVersion: 2、ok、status、verification、requirement。默认查询更严格，旧版只有文件存在或版本提示的副本可能不再被选中。完整地图动作仍仅支持 Windows；Unix 保留扫描内核，map.sh 尚未实现。
