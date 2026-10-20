# toolkit-map

[中文](README.md) · [English](README-EN.md)

> A tool map for AI coding agents on Windows: look up a tool before calling it, and use the version the project declares.

## Features

- **Discovery**: scans PATH, mise installs, the unified tool warehouse (`~/toolchains`) and registered paths; flags shims, unverified copies and IDE-bundled runtimes.
- **Project-aware selection**: reads `mise.toml`, `.tool-versions`, `.nvmrc`, `.python-version` and `package.json` `engines`, then picks a verified copy that satisfies the declaration.
- **No downgrade**: when no verified copy matches, returns `version_mismatch` instead of a path to the wrong version.
- **Agent integration**: `setup` writes the rules into the project's `AGENTS.md` (or Cursor MDC / Claude Code rules), picked up by new sessions.
- **Read-only probing**: scans never execute shims, install tools or modify PATH; installing is a separate explicit `install` action.
- **JSON output**: every action supports `-Json` and prints one object; check `ok`, `status` and `verification` before using the tool.

Requires Windows PowerShell 5.1 / 7 and Git. macOS / Linux currently ship only the `census.sh` scan kernel.

## First project setup

Open PowerShell in the project you want to wire up and run:

```powershell
$project = (Get-Location).Path
$installDir = Join-Path $env:USERPROFILE 'Projects\toolkit-map'
git clone --branch v0.3.0 --depth 1 https://github.com/haxsd/toolkit-map $installDir
$map = Join-Path $installDir 'scripts\map.ps1'
$ps = (Get-Process -Id $PID).Path
function toolkit { & $ps -NoProfile -ExecutionPolicy Bypass -File $map @args }
toolkit setup -Project $project -WhatIf -Json   # preview
toolkit setup -Project $project                 # build the map, write project rules
toolkit doctor -Project $project -Json
```

`setup` builds the map and writes the rules into the project's `AGENTS.md` (existing content kept, backup before edits); it does not install runtimes or modify PATH. `doctor` returning `ok: true` means ready. Without Git, download `toolkit-map-v0.3.0.zip` from [Releases](https://github.com/haxsd/toolkit-map/releases/latest) and follow the [ZIP setup guide](docs/agent-integration.md#没有-git-时从-zip-接入).

## Commands

```powershell
toolkit status -Json
toolkit find node -Project $project -Json
toolkit add node -Path 'C:\existing-node\node.exe' -Json
toolkit install rg@latest -WhatIf -Json
```

`find` selection order: `-Version` > project declaration > parent / global declaration > system default (whatever PATH resolves to). With no declaration it respects the system default and will not pick the newest version automatically.

## Docs

- [Reference](docs/reference.md): commands, JSON protocol v2, declaration and selection rules
- [Agent integration](docs/agent-integration.md): Cursor, Codex, Claude Code and ZIP setup
- [Troubleshooting](docs/troubleshooting.md) · [Uninstall](docs/uninstall.md)
- [Platform notes](docs/platform-notes.md)

## License

[MIT](LICENSE). The local map (`~/.toolkit/map.json`), installed tools, caches and credentials are never part of release packages.
