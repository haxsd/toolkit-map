# 更新记录

## 未发布

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
