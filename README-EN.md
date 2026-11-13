<div align="center">

# toolkit-map

**Let AI coding agents look up tools before they run them: find the copies installed on this machine, pick the version the project requires, and get a verified absolute path.**

[![CI](https://github.com/haxsd/toolkit-map/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/haxsd/toolkit-map/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/haxsd/toolkit-map)](https://github.com/haxsd/toolkit-map/releases/latest)
[![MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Windows](https://img.shields.io/badge/Windows-PowerShell%205.1%20%2F%207-blue)](docs/platform-notes.md)

English · [简体中文](README.md) · [Quick start](#quick-start) · [Reference](docs/reference.md) · [Agent integration](docs/agent-integration.md) · [Changelog](CHANGELOG.md)

</div>

![How toolkit-map works: project requirements + installed copies → toolkit-map find → a verified absolute path](docs/assets/how-it-works.en.png)

## The problem

AI coding agents usually run `node`, `python` or `git` straight from `PATH`. That breaks when `PATH` points at Node 16 while the project requires Node 22, when several copies exist and the agent cannot tell which one to use, or when `node --version` only says who `PATH` resolves to, not which version the project requires.

`toolkit-map` answers three questions before the tool call:

1. **What does the project require?** It reads common declarations such as `mise.toml`, `.tool-versions`, `.nvmrc` and Node `engines`.
2. **Which verified copies exist locally?** It scans `PATH`, tool warehouses, mise installs and manually registered paths.
3. **Which absolute path should be used now?** It returns `path`, `version`, `verification` and `requirement`.

**Lookups are strictly read-only — no installs, no PATH changes, no version guessing.** Map maintenance (`scan` / `update` / `add`) is a separate action; `setup` pre-authorizes the agent by default to run a targeted `update <tool>` when `find` returns a maintenance suggestion, and there is no pre-authorization until `setup` has been run; `scan` / `add` / `install` still require user confirmation. When no copy satisfies the requirement it returns `version_mismatch` instead of silently falling back; when a declaration cannot be interpreted it returns `requirement_unsupported`. See the [reference](docs/reference.md#和其他工具的区别) for the comparison and a sample result.

## Quick start

**Requirements:** Windows, Windows PowerShell 5.1 or PowerShell 7, and Git. MCP access additionally needs Node.js 18+; the map itself does not depend on Node.

One paste to download, wire the project and write the project-level MCP config:

```powershell
$project = (Get-Location).Path
$d = Join-Path $env:USERPROFILE 'Projects\toolkit-map'
git clone --branch v2.1.0 --depth 1 https://github.com/haxsd/toolkit-map $d
if ($LASTEXITCODE -ne 0) { throw 'Download failed. For an existing install, follow the upgrade steps instead of overwriting it.' }
$ps = (Get-Process -Id $PID).Path
& $ps -NoProfile -ExecutionPolicy Bypass -File "$d\scripts\quickstart.ps1" -Project $project -Mcp -WriteMcp
```

Read the exit code: `0` means everything completed; `2` means partial success (rules are wired, MCP was not written — for example no Node 18+ or a failed startup check); `1` means project setup failed. `-ExecutionPolicy Bypass` applies to that child process only; if an organization policy rejects it, follow the organization process instead of changing the registry or group policy.

Or do the same steps manually:

```powershell
$project = (Get-Location).Path
$installDir = Join-Path $env:USERPROFILE 'Projects\toolkit-map'
git clone --branch v2.1.0 --depth 1 https://github.com/haxsd/toolkit-map $installDir
$map = Join-Path $installDir 'scripts\map.ps1'
$ps = (Get-Process -Id $PID).Path
function toolkit { & $ps -NoProfile -ExecutionPolicy Bypass -File $map @args }
toolkit setup -Project $project -WhatIf -Json   # preview
toolkit setup -Project $project                 # build the map and write AGENTS.md
toolkit doctor -Project $project -Json          # read-only diagnosis
toolkit find git -Project $project              # read-only lookup
```

Existing installs: [upgrade steps](docs/agent-integration.md#升级与刷新规则). No Git or prefer a ZIP: [ZIP route](docs/agent-integration.md#没有-git-时从-zip-接入). MCP clients can call the map directly; configuration, protocol and acceptance are in [MCP access](docs/mcp.md), and rule locations/templates in [agent integration](docs/agent-integration.md).

## Safety boundaries

- **Read-only lookups**: `status` / `find` / `doctor` never install tools, change `PATH` or write configuration; `find` does not execute new candidates or write the map.
- **Maintenance and installation are explicit**: `scan` / `update` / `add` write the map and may probe local candidates; `install` is a separate action and should start with `-WhatIf`. MCP maintenance returns a preview by default; `confirm:true` is a request to execute, not proof of user authorization.
- **No environment changes**: existing tools are never moved, `PATH` is never modified, the global execution policy is untouched, and credentials are never read.
- **Team repositories**: generated rules and MCP configs contain local absolute paths; do not commit them — each teammate generates their own.
- Local maps, tools, caches and credentials never enter a release package. Full boundaries: [security policy](docs/security-policy.md).

## Docs

[Reference](docs/reference.md) · [Contract](docs/contract.md) · [MCP access](docs/mcp.md) · [2-minute demo](docs/demo.md) · [Agent integration](docs/agent-integration.md) · [Platform notes](docs/platform-notes.md) · [Storage](docs/storage.md) · [Troubleshooting](docs/troubleshooting.md) · [Uninstall](docs/uninstall.md) · [Development and contributing](docs/development.md) · [Security](docs/security-policy.md) · [Changelog](CHANGELOG.md)

## FAQ

- **Will it pick the latest version when the project has no declaration?** No. The order is `-Version` > project declarations > parent/global declarations > the system default on `PATH`. If `PATH` has Node 16, `find node` returns 16; write a declaration or pass `-Version` when you need another version.
- **Does it move tools or change `PATH`?** No. Existing copies stay where they are; `install` is a separate, explicit action.
- **Is mise required?** No. Discovery, registration and lookup work without mise; use it when the project needs a full manager environment.
- **Can I undo it?** Yes — remove the integration rules, MCP config entries and skill links while keeping existing tools; see [uninstall](docs/uninstall.md).

## Contributing and license

Issues and PRs are welcome. Start with the [development and contributing guide](docs/development.md); for bugs and feature requests use the [issue templates](https://github.com/haxsd/toolkit-map/issues/new/choose) and include reproduction steps plus the output of `doctor -Bundle -Json` (redact usernames in paths before pasting).

Source, protocol, generic examples and recipes are [MIT](LICENSE) licensed.
