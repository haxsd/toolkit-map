# 安全策略

## 支持版本

当前支持最新的 `2.0.x` 版本；更早版本请先升级并复现。

## 报告安全问题

请优先使用 GitHub 仓库 **Security → Report a vulnerability** 的私密报告入口，不要在公开 issue 中披露未修复细节、凭据或完整本机路径。

报告中请包含：

- toolkit-map 版本（`map.ps1 help -Json` 或 `VERSION`）；
- Windows 与 PowerShell 版本；
- `doctor -Bundle -Json` 输出（粘贴前删除用户名、项目路径、凭据等敏感信息）；
- 最小复现步骤，以及问题是否涉及 `install`、MCP 服务器或规则文件写入。

如果私密入口不可用，请先开一个不含敏感细节的 issue，说明需要私下联系。

## 边界

- `status` / `find` / `doctor` 与对应 MCP 查询工具只读；`find` 不执行候选程序或写地图；
- shim 判定基于路径与已知 shim 根（包括 `VOLTA_HOME` 的 `bin`），不执行 shim；不承诺识别“人为把 shim 目录通过 junction/symlink 挂到普通路径”的伪装，这类配置不应使用；
- `scan` / `update` / `add` 是明确的地图维护动作，会写地图并可能执行候选程序进行版本验证；MCP 对应工具默认只预览，执行前必须获得用户明确同意，`confirm:true` 不是身份或授权证明；
- `install` 是显式动作，安装位置与校验边界见 [`reference.md`](reference.md)；
- 本机地图、工具、缓存和凭据不进入发布包；
- 项目不收集遥测。
