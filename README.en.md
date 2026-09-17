[中文](README.md) ｜ **English**

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

bootstrap does four things, all idempotent:

1. Installs [mise](https://mise.jdx.dev) (winget → scoop → choco → npm; `mise.run` → brew on Unix)
2. Writes `mise/config.toml` as the global machine manifest (backing up any existing file)
3. Adds mise's shims directory to the **user-level** PATH
4. Runs `mise install` to fetch the declared runtimes

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

Then it reports four kinds of warnings:

| Warning | Meaning | What to do |
|---|---|---|
| `STUB` | The command resolves to a 0-byte placeholder | The command does not work; use another |
| `SHADOWED` | Multiple versions exist, PATH exposes only one | Use an absolute path or activate via a version manager |
| `CONVENTION` | A version convention exists only in a filename | Record it in a declaration file, or it will be lost |
| `MISSING` | Declared but not installed | `mise install` |

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

- **Exists ≠ usable (Windows)**: `WindowsApps\python3.exe` is a 0-byte Microsoft Store
  app-execution-alias stub. `Get-Command` finds it, `where.exe` lists it, but running it
  produces no output and exits with code 9009. Always check file length, not just
  existence.
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
