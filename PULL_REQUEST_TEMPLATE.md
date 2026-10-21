# Pull Request

## 改动

<!-- 说明改了什么、为什么改；关联 issue 时写 Closes #... -->

## 验证

- [ ] `.\tests\check-docs.ps1`
- [ ] `.\tests\check-encodings.ps1`
- [ ] 与改动相关的契约测试（见 `docs/contributing.md`）
- [ ] 涉及发布流程时运行 `.\tests\release-gate.ps1`

## 兼容性

- [ ] 不改变 JSON result v2、地图 v2 或 MCP 工具契约
- [ ] 如有新增字段/状态/工具，已在 `CHANGELOG.md` 与 `docs/contract.md` 说明
- [ ] 没有提交本机地图、工具仓库、凭据或未脱敏的 `doctor -Bundle` 输出

## 文档

- [ ] 中文文档已同步（项目保持单语中文）
- [ ] 新增稳定标签、版本号与 `VERSION` 一致
