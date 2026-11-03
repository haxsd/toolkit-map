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

AI coding agents usually run `node`, `python` or `git` straight from `PATH`. That breaks in three common ways:

- `PATH` points at Node 16 while the project requires Node 22 — the build fails and the agent keeps guessing;
- several copies exist on the machine (`PATH`, `~/toolchains`, mise installs) and the agent cannot tell which one to use;
- `node --version` only says who `PATH` resolves to, not which version the project requires.

`toolkit-map` answers three questions before the tool call:

1. **What does the project require?** It reads common declarations such as `mise.toml`, `.tool-versions`, `.nvmrc` and Node `engines`.
2. **Which verified copies exist locally?** It scans `PATH`, tool warehouses, mise installs and manually registered paths.
3. **Which absolute path should be used now?** It returns `path`, `version`, `verification` and `requirement`.

**Lookups are strictly read-only — no installs, no PATH changes, no version guessing.** Map maintenance (`scan` / `update` / `add`) is a separate, explicit action that requires user authorization. When no copy satisfies the requirement it returns `version_mismatch` instead of silently falling back; when a declaration cannot be interpreted it returns `requirement_unsupported` and leaves the decision to a version manager or a human.

## How it differs from PATH / mise / asdf

| | Plain PATH | mise / asdf | toolkit-map |
|---|---|---|---|
| Knows project requirements | No | Yes | Yes (reads common declarations) |
| Discovers existing copies | Only one | Only its own installs | PATH, tool warehouses, mise installs, manual entries |
| Returns a verified absolute path | No | Partly | Yes (`version` + `verification` + `requirement`) |
| Requires installs / PATH changes | — | Yes | No (`install` is a separate, explicit action) |
| Fits | Single version | Multi-version | Multi-version plus the tools already on a Windows machine |

> `toolkit-map` does not replace mise / asdf. It completes the chain "project requirement → which local copy → absolute path"; installing stays with a version manager, or with an explicit `install` when you really need it.

## What a lookup returns

Say `PATH` points at Node 16, another Node 22 exists, and the project requires Node 22:

| Situation | toolkit-map returns | What the agent does next |
|---|---|---|
| Verified Node 16 and 22 are found | Node 22, matching the project, with its absolute path | Calls the tool through that path |
| Only Node 16 is found in scope | `version_mismatch`, no path for the wrong version | Reports the gap; installs only if explicitly needed |
| The declaration cannot be interpreted | `requirement_unsupported` | Asks for clarification or hands off to a manager |

Key fields of a successful lookup (example paths, not your machine):

```json
{
  "ok": true,
  "status": "ok",
  "path": "C:\\tools\\node\\22\\node.exe",
  "version": "22.23.2",
  "verification": "verified",
  "requirement": { "version": "22", "scope": "project", "source": "C:\\project\\mise.toml" }
}
```

## Quick start

**Requirements:** Windows, Windows PowerShell 5.1 or PowerShell 7, and Git. MCP access additionally needs Node.js 18+; the map itself does not depend on Node.

Want to see it first? Run `.\scripts\demo.ps1` from the source directory (temporary map, no changes to your machine). To download, wire up the project and write the project-level MCP config in one paste:

```powershell
$project = (Get-Location).Path
$d = Join-Path $env:USERPROFILE 'Projects\toolkit-map'
git clone --branch v2.0.0 --depth 1 https://github.com/haxsd/toolkit-map $d
if ($LASTEXITCODE -ne 0) { throw 'Download did not finish. If you already have an install, follow the upgrade guide instead of overwriting.' }
$ps = (Get-Process -Id $PID).Path
& $ps -NoProfile -ExecutionPolicy Bypass -File "$d\scripts\quickstart.ps1" -Project $project -Mcp -WriteMcp
```

`quickstart` writes the project `AGENTS.md`, finds a Node 18+ through the map, validates the `mcp/server.mjs --print-config` JSON, runs `--check`, and only then writes the project-level MCP config (Cursor `.cursor/mcp.json` by default; `-McpClient claude` writes `.mcp.json`, `both` writes both). Existing servers are preserved and the file is backed up first; an existing file that is not valid JSON or has an unexpected shape is left untouched.

Read the exit code, not only the printed text: `0` means everything completed; `2` means **partial success** — the project rules are already wired up, but MCP was not written (for example no Node 18+, invalid generated config, or a failed startup check); fix the cause and re-run the same command; `1` means project setup itself failed. If the block above succeeded, skip to step 4; the step-by-step route follows.

`-ExecutionPolicy Bypass` applies to that child process only and does not change user or machine policy. If group policy still rejects Bypass, ask for an approved execution policy through your organization; do not edit the registry or group policy to work around it.

### 1. Download the stable release

Open PowerShell in the project you want to wire up and run:

```powershell
$project = (Get-Location).Path
$installDir = Join-Path $env:USERPROFILE 'Projects\toolkit-map'
git clone --branch v2.0.0 --depth 1 https://github.com/haxsd/toolkit-map $installDir
if ($LASTEXITCODE -ne 0) { throw 'Download did not finish. If you already have an install, follow the upgrade guide instead of overwriting.' }
$map = Join-Path $installDir 'scripts\map.ps1'
$ps = (Get-Process -Id $PID).Path
# `toolkit` is a thin wrapper: run map.ps1 once with the current PowerShell host
function toolkit { & $ps -NoProfile -ExecutionPolicy Bypass -File $map @args }
```

Already installed? See the [upgrade steps](docs/agent-integration.md). No Git, or prefer a ZIP? Use the [ZIP route](docs/agent-integration.md).

### 2. Preview and wire up the project

```powershell
toolkit setup -Project $project -WhatIf -Json
toolkit setup -Project $project
toolkit doctor -Project $project -Json
toolkit find git -Project $project
```

`setup` builds the map on first run and writes the rules into the project's `AGENTS.md` (existing content is preserved and backed up before edits). It does not install runtimes or modify `PATH`. The first scan takes as long as candidate discovery and version probing require.

`doctor` returns `ok: true` and `status: ok` when healthy. `find git` shows the absolute path, version and `verified` status. When something is off, follow the `checks` and see [troubleshooting](docs/troubleshooting.md).

### 3. Set up MCP (recommended, optional)

MCP clients can call the map directly instead of relying on the model to remember a rules file. If the one-paste block above succeeded with `-Mcp -WriteMcp`, restart the client and skip to step 4; otherwise generate and validate the config as described in [MCP access](#mcp-access-recommended). Merge only the `toolkit-map` entry, never replace other servers; for Codex, replace the existing `[mcp_servers.toolkit-map]` section rather than appending a duplicate TOML table.

### 4. Verify it inside the agent

Open a new Cursor Agent Chat or Codex session in the same project and send:

> Follow this project's tool discovery rules and look up Git. Do not install anything or change the environment; report the project requirement, the copies found, the absolute path you selected and its verification status. After verification, run `--version` through that absolute path.

Success means you see the agent **actually call the map, then call the returned tool path**. `doctor` only checks local configuration; it cannot prove the model loaded or followed the rules. If the model runs bare `git`, follow the [rules-not-applied checklist](docs/troubleshooting.md).

### Common commands

```powershell
toolkit status -Json                        # map freshness, PATH changes
toolkit find node -Project $project -Json   # read-only lookup; no candidate execution, no map write
toolkit scan -Json                          # explicit rescan (writes the map)
toolkit update node -Json                   # re-probe existing entries (writes the map)
toolkit add node -Path 'C:\existing-node\node.exe' -Json   # register a copy (writes the map)
toolkit install rg@latest -WhatIf -Json     # preview the plan without network access
```

Full commands, statuses, adapters and declaration rules are in the [reference](docs/reference.md).

## MCP access (recommended)

When the client supports MCP, you do not need to paste rules into every project. Ask the map for a verified Node 18+ path, generate the config and paste it once. The commands below assume `$map` and `$installDir` from step 1:

```powershell
# 1. Find a verified Node 18+ through the map, not the old PATH entry.
#    find is read-only: setup or scan must have built the map first; it does not
#    execute new candidates or write the map.
$node = (& $map find node -Version '>=18' -Json | ConvertFrom-Json).path

# 2. Print the mcpServers JSON for Cursor / Claude Code; use --print-config codex for TOML
& $node (Join-Path $installDir 'mcp\server.mjs') --print-config

# 3. Verify the server and the map without an MCP client; check the exit code
& $node (Join-Path $installDir 'mcp\server.mjs') --check
```

Merge the output into `~/.cursor/mcp.json` (or the project's `.cursor/mcp.json`), Claude Code's `.mcp.json`, or Codex's `~/.codex/config.toml`, then restart the client. For Codex, **replace** the existing `[mcp_servers.toolkit-map]` section including its `env` line; do not append a duplicate table.

The MCP adapter provides three lookup tools and three maintenance tools. `toolkit_find`, `toolkit_status` and `toolkit_doctor` are read-only; `toolkit_scan`, `toolkit_update` and `toolkit_add` return a preview by default and require `confirm:true` to request execution. Maintenance may probe local candidate programs to read versions, so obtain explicit user authorization first; `confirm:true` alone does not prove a human or authorization. They never install tools or change `PATH`. See [MCP access](docs/mcp.md#维护工具).

MCP and rule files can coexist. MCP does not rewrite `AGENTS.md`, and `setup` does not write MCP config. See [MCP access](docs/mcp.md) for client-specific config, protocol versions and troubleshooting.

## Supported agents

| Agent | Across projects | Current project only |
|---|---|---|
| Cursor | Customize → Rules → User Rules (paste manually) | Project `AGENTS.md`, or an MDC file with `alwaysApply` |
| Codex | `CODEX_HOME/AGENTS.md`, default `~/.codex/AGENTS.md` | Project `AGENTS.md` |
| Claude Code | `~/.claude/CLAUDE.md` | Project `CLAUDE.md` |

Any agent that can read a rules file can be wired up. Full locations, templates and verification steps are in the [agent integration guide](docs/agent-integration.md).

**Team repositories:** the rule block written by `setup` into a project `AGENTS.md` contains the local absolute path to `map.ps1`, and `-WriteMcp` configs contain the local Node absolute path. Do not commit either to a shared repository. Each teammate should generate them locally, or keep MCP config in a user-level or untracked project file. Commit only a generic template without machine-specific paths.

## Scope

| Capability | Supported now | Boundaries |
|---|---|---|
| Discover installed tools | Registered paths, `PATH`, the tool warehouse, mise installs and locations found by the scanner | Not an exhaustive disk scan; register other locations with `add` |
| Verify and select | Path, version and verification status for runtimes and CLIs; selection follows project requirements | Unknown tools are probed with `--version` by default; special arguments need an adapter; **without a declaration it respects the system default instead of upgrading** |
| Project declarations | Common `mise.toml`, `.tool-versions`, Node/Python version files and Node `engines` | Lightweight reader; does not interpret full TOML / mise environment semantics |
| Portable installs | gh, jadx, rg/ripgrep, fd (Windows x64), adb; custom ZIP | Does not auto-install every discoverable tool; downloaded versions are verified again at the final location |
| MCP access | Three lookup tools plus `toolkit_scan` / `toolkit_update` / `toolkit_add`, zero npm dependencies | Requires Node.js 18+; lookups are read-only; maintenance previews by default, executes only with `confirm:true`, and needs user authorization |
| Interface contract | v1.0 freezes JSON result v2, map v2, 30 status values and the MCP tool contract | Compatibility and deprecation policy in the [contract](docs/contract.md) |
| Installers | Explicit `-Via winget` | Location is decided by the package manager |
| Platforms | Windows PowerShell 5.1 / 7 support the full map | On Unix, only the `census.sh` scanning kernel is available |

## Safety boundaries

- **Lookups are read-only**: `status` / `find` / `doctor` do not install tools, change `PATH` or write configuration; `find` does not execute new candidates or write the map, and candidates discovered read-only stay unverified.
- **Maintenance is explicit**: `scan` / `update` / `add` write the map and are called only when needed; maintain a missing or stale map before looking up.
- **Installs are explicit**: `install` must be called on purpose; run it with `-WhatIf` first to see the plan without network access.
- **MCP maintenance needs authorization**: `toolkit_scan` / `toolkit_update` / `toolkit_add` return a preview by default and require `confirm:true` to request execution. Parameters cannot prove a human or an authorized operator; the client must ask the user. Maintenance may probe local candidates, but never installs tools or changes `PATH`.
- **Backups before edits**: `setup` only maintains the rules file you point it at; existing content is preserved and backed up first; `quickstart -WriteMcp` also backs up client config first.
- **Verification is explicit**: `verified` / `unverified` / `unavailable` / `skipped` are never mixed up, and unverified copies are not selected by default.
- **No credentials in releases**: local maps, tools, caches and credentials are not part of the published package.
- **No global execution-policy changes**: the script runs once through the current host; organizational group policy still applies.

## Documentation

Reference · agent integration · platform notes · storage and large installs · troubleshooting · uninstall · contributing · changelog:

[Reference](docs/reference.md) · [Contract](docs/contract.md) · [MCP access](docs/mcp.md) · [2-minute demo](docs/demo.md) · [Agent integration](docs/agent-integration.md) · [Platform notes](docs/platform-notes.md) · [Storage](docs/storage.md) · [Troubleshooting](docs/troubleshooting.md) · [Uninstall](docs/uninstall.md) · [Contributing](docs/contributing.md) · [Security](SECURITY.md) · [Changelog](CHANGELOG.md)

> The docs are currently written in Chinese; English translations are welcome. The README and the CLI's `-Lang en` output are the English entry points.

## FAQ

- **Without a project declaration, will it pick the newest version?** No. The order is `-Version` argument > project declaration > parent/global declaration > system default (whatever `PATH` resolves to). If `PATH` has Node 16 and the machine also has Node 24, `find node` returns 16. Write a project declaration or pass `-Version` to pin a version.
- **Does it move tools or change `PATH`?** Scanning and wiring up do not; existing copies stay where they are. `install` is a separate, explicit action. `bootstrap` is optional environment setup that does change the machine and is not part of the flow above.
- **Do I need mise?** No. Tools can be discovered, registered and looked up without mise; use mise when the project needs its full manager environment.
- **Where do tools live by default?** The map lives at `~/.toolkit/map.json` and new portable tools at `~/toolchains`. `TOOLCHAIN_ROOT` changes the warehouse location; see [storage](docs/storage.md).
- **Can I undo it?** Yes — remove the integration rules, MCP config entries and skill links while keeping existing tools; see [uninstall](docs/uninstall.md).
- **What about team repositories?** Do not commit the generated rule block or MCP config that contain local absolute paths. Each teammate should generate them locally, or keep MCP config in a user-level or untracked project file; commit only a generic template.
- **Do upgrades apply automatically?** Updating the source does not update old rules. Re-run `setup` for file-based rules; regenerate and paste Cursor User Rules; then verify in a new session.

## Contributing and license

Issues and PRs are welcome. Start with the [contributing guide](docs/contributing.md); for bugs and feature requests use the [issue templates](https://github.com/haxsd/toolkit-map/issues/new/choose) and include reproduction steps plus the output of `doctor -Bundle -Json` (redact usernames in paths before pasting).

Source, protocol, examples and recipes are released under the [MIT](LICENSE) license. Local maps, tools, caches and credentials are not part of the published package.
