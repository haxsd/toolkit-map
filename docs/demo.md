# 2 分钟演示

这个演示不依赖你机器上真实的 Node 版本，也不会读写 `~/.toolkit/map.json`。它用临时地图和两个假副本复现最常见的事故：

1. agent 直接运行 PATH 上的 Node 16；
2. 项目声明要求 Node 22；
3. 先查地图，返回 Node 22 的绝对路径；
4. 项目改成要求 Node 24 时，地图返回 `version_mismatch`，不降级。

## 运行

在 toolkit-map 源码目录打开 PowerShell：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\demo.ps1
```

不需要 Node，不需要管理员权限，不会改 PATH。

## 预期输出

```text
  toolkit-map 2 分钟演示
  （使用临时地图，不读取也不修改 ~/.toolkit/map.json）

  [1/4] 登记两个已存在的 Node 副本
  16 → C:\Users\you\AppData\Local\Temp\toolkit-map-demo-...\bin\runtime-a.cmd
  22 → C:\Users\you\AppData\Local\Temp\toolkit-map-demo-...\bin\runtime-b.cmd

  [2/4] 项目声明：Node 22（.nvmrc）

  [3/4] agent 直接运行旧版本（模拟 PATH 上的 16）
  node --version → v16.20.2

  [4/4] 先查地图，再执行返回的绝对路径
  requirement → 22（project）
  path        → ...\bin\runtime-b.cmd
  version     → 22.23.2；verification → verified
  执行返回路径 → v22.23.2

  [对照] 把项目要求改成 Node 24
  status → version_mismatch
  path   → ''
  没有满足要求的副本时，地图不降级、不返回 16 的路径。
```

路径会随临时目录变化，关键看三行：`path` 指向 22、`verification` 是 `verified`、失败时 `path` 为空。

## 录制 GIF

演示是纯终端输出，可以直接用 Windows Terminal 录屏，或用 ScreenToGif 录制窗口。建议只保留 30–45 秒：从 `[1/4]` 到 `执行返回路径 → v22.23.2`，失败对照可以剪掉或加速。

录制前先跑一遍，确认输出顺序稳定；不要把真实用户名、项目路径或本机地图路径录进去。需要更干净的路径时，在临时目录运行，或录完后裁掉路径前缀。

## 接下来

- 真实项目接入：见 [README 的首次接入](../README.md#首次接入一个项目)；
- MCP 配置：见 [MCP 接入](mcp.md)；
- 一条命令完成规则接入并生成 MCP 配置：用 `scripts/quickstart.ps1`。
