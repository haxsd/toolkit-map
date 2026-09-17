[中文](README.zh-CN.md) ｜ **English**

# runtime-census

Find every language runtime that **actually exists** on this machine, and manage them declaratively.

`node --version` tells you **which one is active**. It does not tell you **what is installed**.
That gap is where confident, wrong answers like "this machine only has Node 16" come from —
while two Nodes, three Pythons and three JVMs sit on disk.

## Quick start

```powershell
# Windows
git clone https://github.com/haxsd/runtime-census
cd runtime-census
.\scripts\census.ps1
```

```bash
# macOS / Linux
git clone https://github.com/haxsd/runtime-census
cd runtime-census
./scripts/census.sh
```

You get a full inventory in under ten seconds. Excerpt:

```
 4. Runtime inventory — everything present on disk, managed or not
  NODE   2 found
    16.20.2        <system drive>:\nodejs\node.exe                 [system install]
    22.23.2        %USERPROFILE%\tools\node22\node.exe             [custom location]
  PYTHON 3 found
    3.12.10        %LOCALAPPDATA%\Programs\Python\Python312\python.exe
    3.14.7         %USERPROFILE%\miniconda3\python.exe             [conda]
  JAVA   3 found
    1.8.0_144      C:\Program Files\Java\jdk1.8.0_144\bin\java.exe
    11.0.6         ...\IntelliJ IDEA\jbr\bin\java.exe              [bundled with IDE]
    25.0.3         ...\PyCharm\jbr\bin\java.exe                    [bundled with IDE]

 6. Warnings — things that need a human decision
  [SHADOWED]   'node' exists 2 times on disk; 1 of them is not reachable via PATH
  [CONVENTION] found naming convention 'node22' — record it or it will be lost
```

Add `--json` for machine-readable output.

> The CLI currently prints in Chinese. The block above shows the output *structure*,
> translated for readability. Translations are welcome.

## Why this exists

`which node` and `node --version` are **resolvers** — they return the first winner along
PATH. Treating them as **inventories** hides most of what is installed. Four common ways:

| How it hides | Example |
|---|---|
| PATH is single-valued | Seven JDKs installed; `java` is only ever the first one on PATH |
| Custom naming | Node 22 installed as `node22`, because the name `node` was taken by a legacy project |
| Not on PATH at all | conda's Python, pyenv versions — even `py -0p` does not know them |
| Bundled with a host | An IDE's `jbr/` contains a full JDK that never registers as a system runtime |

census walks all four categories, keeping **which one** and **which ones** as separate
questions.

## Per-project version switching

`census` is a zero-dependency single-file script — clone and run, nothing else needed.
If you also want each project to automatically use its own runtime versions, add a
version manager on top:

```powershell
.\scripts\bootstrap.ps1 -DryRun   # see what it would change
.\scripts\bootstrap.ps1
```

```bash
./scripts/bootstrap.sh --dry-run
./scripts/bootstrap.sh
```

bootstrap does five things, all idempotent:

1. Installs [mise](https://mise.jdx.dev) (winget → scoop → choco → npm; `mise.run` → brew on Unix)
2. Writes `templates/mise-config.toml` as the global machine manifest. If nothing is deployed yet it copies the template; if the deployed copy differs, it reports the drift (which `[tools]` keys differ) and **leaves your file alone** — add `-RefreshConfig` / `--refresh-config` to overwrite it, backing up first
3. Creates the canonical root for hand-installed runtimes (`~/toolchains`, override with `TOOLCHAIN_ROOT` or `-ToolsRoot` / `--tools-root`)
4. Puts mise's shims directory at the **front** of the user-level PATH (appended, it loses to every pre-existing direct tool dir) and lists machine-level dirs that still shadow it
5. Runs `mise install` to fetch the declared runtimes

What it deliberately does **not** do: touch machine-level environment variables, delete
existing PATH entries, or modify runtimes bundled with your IDE.

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

## Command reference

### census

| Flag | Description |
|---|---|
| *(none)* | Human-readable report |
| `--json` | JSON output, for programs and agents |
| `--deep` | Also scan common install roots across drives (slower) |
| `--timing` / `-Timing` | Include per-stage timings |

It inventories in five stages:

| Stage | What it covers |
|---|---|
| 1. Declarations | `mise.toml` / `.tool-versions` in the project and globally |
| 2. Managed | Runtimes that mise manages |
| 3. Conventions | Version-suffixed shims on PATH — and the file each one actually points to |
| 4. Inventory | Version manager dirs, system installs, IDE-bundled JBRs, conda envs |
| 5. Resolution | What common commands actually resolve to, their version, and whether they run |

Then it reports these warnings:

| Warning | Meaning | What to do |
|---|---|---|
| `STUB` | The command resolves to a Store app-execution alias whose target app is not installed — probing it gives no output and exit code 9009 | The command does not work; use another |
| `PATH_ORDER` | Declaration and mise agree on a version, but PATH resolves the command to a different copy | Put mise's shims first in the user PATH (bootstrap does); machine-level dirs need admin rights |
| `SHADOWED` | Multiple versions exist, PATH exposes only one | Use an absolute path or activate via a version manager |
| `CONVENTION` | A version convention exists only in a filename | Record it in a declaration file, or it will be lost |
| `PATH_DIRT` | The user PATH has duplicate or quoted entries | Clean them up — they eat into the PATH length limit and hide "I changed it but nothing took effect" bugs |
| `DRIFT` | The deployed global declaration differs from `templates/mise-config.toml` | `bootstrap.ps1 -RefreshConfig` / `bootstrap.sh --refresh-config` (backs up first) |
| `XDG_SHIFT` | `XDG_CONFIG_HOME` is set, so mise's global config moved and `~/.config/mise/config.toml` became a path-dependent config | Unset the variable, or move the declaration |
| `STRAY` | Runtime sits in a non-standard location with no manager tracking it | Record it in a declaration file — **do not migrate** it (see below) |
| `UNDECLARED` | The current project has an `engines` constraint but no readable declaration | Add `mise.toml` / `.tool-versions` — see "Taking over a legacy project" below |
| `MISSING` | Declared but not installed | `mise install` |

### Convention: where unmanaged runtimes live

Runtimes you install by hand — a zip download, a side-by-side install kept for a legacy
project — belong under one root, arranged as `<tool>/<version>/`:

```
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

## Install as a skill

The repo root contains `SKILL.md`, so the repository *is* a Cursor / Claude skill.
Install by **linking** the skills directory to this clone rather than copying it — that
way `git pull` upgrades the skill.

```powershell
git clone https://github.com/haxsd/runtime-census $env:USERPROFILE\Projects\runtime-census
New-Item -ItemType Junction `
  -Path "$env:USERPROFILE\.cursor\skills\runtime-census" `
  -Target "$env:USERPROFILE\Projects\runtime-census"
```

```bash
git clone https://github.com/haxsd/runtime-census ~/Projects/runtime-census
ln -s ~/Projects/runtime-census ~/.cursor/skills/runtime-census
```

Once installed, asking "which Node / Python / Java versions are on this machine", or
hitting an unexpected version mismatch, will load it automatically.

`AGENTS.md` is the companion **discovery contract** — the rules an agent must follow
when judging runtime availability. Copy it into your own project's rules file; it works
standalone.

## Platform notes

- **`mise activate` cannot auto-switch directories on PowerShell 5.1**: its `chpwd` hook
  requires PowerShell 7 or newer. On 5.1, activation only prepends mise's versions as the
  global default — `cd`-ing into a project does not switch anything, which is the only
  reason to use `activate` in the first place. PowerShell profiles are **per-host**
  (5.1 reads `WindowsPowerShell`, 7 reads `PowerShell`), so bootstrap writes the
  activation line into **both** hosts' profiles when PowerShell 7 is available, and tells
  you to open `pwsh` instead. Detect it with a probe, not by looking for the file: the
  `pwsh.exe` in `WindowsApps` is a 0-byte alias.
- **Windows composes PATH as machine entries first, user entries second.** Commands are
  resolved by walking that combined list, so a machine-level direct tool directory
  (`C:\ProgramData\Oracle\Java\javapath`) or a legacy directory early in the user PATH
  always beats mise's shims, which scripts usually append at the end. `mise activate`
  prepends the shims **inside the session only**: interactive shells get the declared
  version, while cmd, GUI apps, IDE tasks and `-NoProfile` scripts silently get the old
  one. That gap is what `[PATH_ORDER]` reports. bootstrap now moves the shims to the
  *front* of the user PATH and lists the machine-level directories, which need admin
  rights to change.
- **Exists ≠ usable (Windows), refined**: `WindowsApps\python3.exe` is a 0-byte Microsoft
  Store app-execution alias; `Get-Command` finds it, `where.exe` lists it, and running it
  produces no output and exits with code 9009. But a 0-byte alias is not automatically
  broken — `pwsh.exe` and `winget.exe` are 0-byte aliases that work, because their target
  apps are installed. File length means "suspect", not "unusable": confirm by running a
  version command and checking for output.
- **Verifying the shell scripts on Windows**: `bash` on PATH is usually
  `C:\WINDOWS\system32\bash.exe`, the WSL relay. Without a distro installed it fails with
  `execvpe(/bin/bash) failed: No such file or directory`, which looks like a syntax error
  in your script but is not. Run `.\scripts\verify-shell.ps1`: it finds a real bash (Git
  Bash, otherwise a `bash` container) and runs `bash -n` over every `.sh` — parse only,
  never execute.
- **The PowerShell 5.1 `@()` trap**: `@($list)` on a `List[object]` throws
  `Argument types do not match` — use `$list.ToArray()`. If the script also sets
  `$ErrorActionPreference = 'SilentlyContinue'`, the error is swallowed entirely and only
  surfaces later as an object mysteriously becoming `$null`, which is very hard to trace.

## FAQ

**Why not just use mise?**
mise can only manage what it installed itself. It will never know about
`<system drive>:\nodejs`, conda's Python, or an IDE's bundled JDK. Managed and
pre-existing layers have to be viewed separately — doing only the former makes people
believe the inventory is complete.

**Why not Docker?**
Containers are a different approach: stronger isolation, at the cost of building an image
per project and more friction sharing the host filesystem. This project's goal is to make
**the native machine predictable**. The two can coexist.

**Isn't a directory scan slow?**
census uses targeted probing rather than a full walk — one `stat` is one to two orders of
magnitude cheaper than a directory enumeration, and a full run finishes in under ten
seconds. The trade-off is that it only covers known install layouts; unusual locations
need `--deep`.

## Known limitations

- Targeted probing only covers **known install layouts**. Runtimes in completely
  non-standard locations require `--deep`.
- `census.sh` only detects JBRs inside `.app` bundles on macOS under common naming;
  non-standard JetBrains Toolbox install paths may be missed.
- mise's native Windows support is less mature than on Unix. Some plugins' build scripts
  assume a Unix-like environment; use WSL or a container for those.
- The `mise.run` installer does not work on Windows (macOS/Linux only) — use
  winget / scoop / choco / npm / a manual download instead.
- CLI output is currently Chinese-only. The warning codes (`STUB`, `SHADOWED`,
  `CONVENTION`, `MISSING`) and the `--json` output are language-neutral.

## License

MIT © [haxsd](https://github.com/haxsd)
