# 安全策略

## 支持版本

当前支持最新的 `1.1.x` 版本；更早版本请先升级并复现。

## 报告安全问题

请优先使用 GitHub 仓库 **Security → Report a vulnerability** 的私密报告入口，不要在公开 issue 中披露未修复细节、凭据或完整本机路径。

报告中请包含：

- toolkit-map 版本（`map.ps1 help -Json` 或 `VERSION`）；
- Windows 与 PowerShell 版本；
- `doctor -Bundle -Json` 输出（粘贴前删除用户名、项目路径、凭据等敏感信息）；
- 最小复现步骤，以及问题是否涉及 `install`、MCP 服务器或规则文件写入。

如果私密入口不可用，请先开一个不含敏感细节的 issue，说明需要私下联系。

## 边界

- `scan` / `status` / `find` / `doctor` 与 MCP 工具默认只读；
- `install` 是显式动作，安装位置与校验边界见 [`docs/reference.md`](docs/reference.md)；
- 本机地图、工具、缓存和凭据不进入发布包；
- 项目不收集遥测。
