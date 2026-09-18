[中文](reference.zh-CN.md) ｜ **English** ｜ [README](../README.md)

# Reference

Every flag the two commands accept, what they print, and the conventions behind them.
Platform-specific behaviour lives in [platform notes](platform-notes.md).

For the rule an agent must follow when judging tool availability, see
[AGENTS.md](../AGENTS.md) (Chinese).

## census

Inventory only — it never writes to the machine, which is why it is the default entry
point. A full run takes a few seconds on a lean PATH and up to about half a minute on a
Windows PATH with thousands of entries.

| Flag | Description |
|---|---|
| *(none)* | Human-readable report |
| `--json` | One JSON object on stdout and nothing else — the human-readable sections are suppressed entirely |
| `--deep` | Also scan common install roots (bounded: depth 4, results capped; the slow path) |
| `--timing` | Per-stage timings |
| `-Lang en` / `--lang en` | English output (also via `CENSUS_LANG`); default `zh` |

`census.ps1` accepts one or two dashes (`-Json` or `--json`); `census.sh` uses two.

### What it inventories

| Stage | What it covers |
|---|---|
| 1. Declarations | `mise.toml` / `.tool-versions` in the project and globally |
| 2. Managed | Runtimes that mise manages |
| 3. Conventions | Version-suffixed shims on PATH — and the file each one actually points to |
| 4. Inventory | Version manager dirs, system installs, IDE-bundled JBRs, conda envs |
| 5. Resolution | What common commands actually resolve to, their version, and whether they run |

### JSON output

Both implementations emit the **same schema** (checked by `tests/parity.ps1` in CI), so an
agent or CI job does not need a per-platform parser:

| Field | Contents |
|---|---|
| `schemaVersion` | `1` — bumped when the field set or semantics change |
| `generatedAt`, `host` | Timestamp and `{os, arch, user, cwd}` |
| `declarations` | Every `mise.toml` / `.tool-versions` found: `{scope, path, tools}` |
| `toolsRoot` | Canonical root for hand-installed runtimes |
| `mise` | `{available, tools[]}` for the managed layer |
| `conventions`, `runtimes`, `resolution` | The inventory stages. Consume the fields documented here; an implementation may carry extra fields of its own (see below) |
| `warnings` | `[{kind, tool, message, action, detail}]` — `kind` is a stable ASCII code |
| `timings`, `summary` | Per-stage milliseconds (with `--timing`) and counts |

`kind` codes (`STUB`, `PATH_ORDER`, `DRIFT`, …) never change with the language; `message`
and `action` follow `--lang`.

**The two implementations are not required to be structurally identical.** The fields listed
above are the contract; an implementation may carry extras of its own — `host.powershell` and
`mise.tools[].installPath`, for instance, exist only in the PowerShell version because they
describe facts that only exist on Windows. `tests/parity.ps1` deliberately does not compare
fields one by one; it only enforces the rule above, that machine-readable markers stay ASCII.

### Warning codes

| Warning | Meaning | What to do |
|---|---|---|
| `STUB` | The command resolves to a Store app-execution alias whose target app is not installed — probing it gives no output and exit code 9009 | The command does not work; use another |
| `PATH_ORDER` | Declaration and mise agree on a version, but PATH resolves the command to a copy that does **not** satisfy the declaration (a copy of the declared version itself is fine — only a genuinely wrong version is reported) | Put mise's shims first in the user PATH (bootstrap does); machine-level dirs need admin rights |
| `SHADOWED` | Multiple versions exist, PATH exposes only one | Use an absolute path or activate via a version manager |
| `CONVENTION` | A version convention exists only in a filename | Record it in a declaration file, or it will be lost |
| `PATH_DIRT` | The user PATH has duplicate or quoted entries | Clean them up — they eat into the PATH length limit and hide "I changed it but nothing took effect" bugs |
| `DRIFT` | The deployed global declaration differs from `templates/mise-config.toml` | `bootstrap.ps1 -RefreshConfig` / `bootstrap.sh --refresh-config` (backs up first) |
| `XDG_SHIFT` | `XDG_CONFIG_HOME` is set, so mise's global config moved and `~/.config/mise/config.toml` became a path-dependent config | Unset the variable, or move the declaration |
| `STRAY` | Runtime sits in a non-standard location with no manager tracking it | Record it in a declaration file — **do not migrate** it (see below) |
| `UNDECLARED` | The current project has an `engines` constraint but no readable declaration | Add `mise.toml` / `.tool-versions` |
| `MISSING` | Declared but not installed | `mise install` |

### Convention: where unmanaged runtimes live

Runtimes you install by hand — a zip download, a side-by-side install kept for a legacy
project — belong under one root, arranged as `<tool>/<version>/`:

```text
~/toolchains/
├── node/22.23.2/
└── python/3.12.10/
```

Override the location with `TOOLCHAIN_ROOT`. This buys two things: a single place to
look, and a predictable path so the next agent or teammate can find it without asking.

**Runtimes that are already elsewhere are not migrated.** Their paths may be hard-coded
in project config, IDE settings, or CI scripts, and moving them breaks things days later.
The fix is to *record* them — `census` lists them under `[STRAY]` — not to move them.
A non-standard location is not the real problem; the real problem is that a runtime only
reachable through PATH is lost the moment PATH changes.

## Declaring versions in a project

```toml
# mise.toml at the project root
[tools]
node   = "22"
python = "3.12"

[env]
NODE_ENV = "development"

[tasks]
test  = "npm test"
build = "npm run build"
```

```bash
mise trust && mise install
mise exec -- npm test        # one-shot activation, no global state changed
```

One file covers every language. asdf's `.tool-versions` is supported too — see
`examples/` for both formats.

**The direction matters**: make the machine satisfy the project's declaration, not the
other way round. Editing `engines` or downgrading dependencies to match whatever happens
to be installed produces the nastiest class of bug — passes locally, fails in CI.

## bootstrap

The one-time setup script. Run it only if you want per-project version switching on top of
census. Flags are the same on both platforms, spelled with one dash on PowerShell and two
on the shell script:

| Flag | Description |
|---|---|
| `-DryRun` / `--dry-run` | Print what would change, touch nothing |
| `-RefreshConfig` / `--refresh-config` | Overwrite the deployed machine manifest with the template (backing up first). Without it, drift is only reported |
| `-SkipTools` / `--skip-tools` | Install mise and write the manifest, but do not run `mise install` |
| `-NoProfile` / `--no-rc` | Do not touch shell startup files |
| `-ToolsRoot` / `--tools-root` | Override the canonical root for hand-installed runtimes (default `~/toolchains`) |
| `-ConfigSource` / `--config` | Use a different manifest template instead of `templates/mise-config.toml` |

It performs five idempotent steps:

1. Installs [mise](https://mise.jdx.dev) (winget → scoop → choco → npm; `mise.run` → brew on Unix)
2. Writes `templates/mise-config.toml` as the global machine manifest. If nothing is deployed yet it copies the template; if the deployed copy differs, it reports the drift (which `[tools]` keys differ) and **leaves your file alone**
3. Creates the canonical root for hand-installed runtimes (`~/toolchains`)
4. Puts mise's shims directory at the **front** of the user-level PATH (appended, it loses to every pre-existing direct tool dir) and lists machine-level dirs that still shadow it
5. Runs `mise install` to fetch the declared runtimes

`bootstrap` changes machine state on purpose, so start with `-DryRun` / `--dry-run` and
read the plan before running it for real.

### What bootstrap changes and how to undo it

| `bootstrap` changes | How to undo |
|---|---|
| Installs mise (winget → scoop → choco → npm; `mise.run` → brew) | Uninstall it with the same package manager |
| Writes the machine manifest `~/.config/mise/config.toml` | A `config.toml.bak-<timestamp>` backup is kept next to it; delete the file to leave no machine manifest |
| Moves mise's shims to the front of the **user-level** PATH | Remove that entry in *Edit environment variables for your account*, then reopen terminals |
| Appends the activation line to PowerShell profiles (both hosts when `pwsh` exists) | Delete the two lines marked `runtime-census` in those profile files |
| Runs `mise install` (downloads the declared runtimes) | `mise uninstall <tool>@<version>`; versions that were already there are untouched |
| — | It never touches machine-level environment variables, never deletes PATH entries, never modifies IDE-bundled runtimes |

## verify-shell.ps1

Windows only, and only when you edit the `.sh` implementations: `bash` on PATH is usually
the WSL relay, which fails with `execvpe(/bin/bash) failed: No such file or directory` —
that looks like a syntax error in your script but is not. The script lives in `tests/`
since it is a development check rather than part of the product:

```powershell
.\tests\verify-shell.ps1
```

It finds a real bash (Git Bash, otherwise a `bash` container) and runs `bash -n` over every
`.sh` in `scripts/` and `tests/` — parse only, never execute. See
[contributing](contributing.md) for the rest of the local checks.
