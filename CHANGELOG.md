# 更新记录

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
