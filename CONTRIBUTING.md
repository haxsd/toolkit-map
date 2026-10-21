# 贡献

完整开发约定、测试矩阵与发布流程见 [`docs/contributing.md`](docs/contributing.md)。

提交前至少运行：

```powershell
.\tests\check-docs.ps1
.\tests\check-encodings.ps1
.\scripts\demo.ps1
```

发布相关改动请运行 `tests/release-gate.ps1`。文档保持中文单语；`.ps1` 使用 UTF-8 BOM，`.sh` 使用 LF 且无 BOM。
