[中文](README.zh-CN.md) ｜ **English**

[![CI](https://github.com/haxsd/runtime-census/actions/workflows/ci.yml/badge.svg)](https://github.com/haxsd/runtime-census/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

# runtime-census

Find every **tool** that actually exists on this machine — language runtimes are just one
kind of tool — and manage them declaratively.

`node --version` tells you **which one is active**. It does not tell you **what is
installed** — so "this machine only has Node 16" is usually wrong, while another copy of
the same command, an IDE's bundled JDK, a conda environment and a CLI you installed by
hand last year all sit on disk.

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

> Downloaded the ZIP instead of cloning? Windows marks those files as coming from the
> internet and PowerShell refuses to run them. Unblock once:
> `Get-ChildItem -Recurse | Unblock-File`

A full run takes a few seconds on a lean PATH and up to about half a minute on a Windows
PATH with thousands of entries — `--timing` prints the per-stage cost. Excerpt:

```
 4. Runtime inventory — everything present on disk, managed or not
  NODE   2 found
    16.20.2        <system drive>:\nodejs\node.exe                 [system install]
    22.23.2        %USERPROFILE%\tools\node22\node.exe             [custom location]
  JAVA   3 found
    11.0.6         ...\IntelliJ IDEA\jbr\bin\java.exe              [bundled with IDE]

 6. Warnings — things that need a human decision
  [SHADOWED]   'node' exists 2 times on disk; 1 of them is not reachable via PATH
  [CONVENTION] found naming convention 'node22' — record it or it will be lost
```

Add `--json` for machine-readable output, or `--lang en` / `CENSUS_LANG=en` for English
prose — the block above uses the English wording.

## Why this exists

`which node` and `node --version` are **resolvers** — they return the first winner along
PATH. Treating them as **inventories** hides most of what is installed. Four common ways:

| How it hides | Example |
|---|---|
| PATH is single-valued | Two versions of the same tool installed; the bare name is only ever the first one on PATH |
| Custom naming | A tool installed as `node22` / `python3.12` / `r2-5.9`, because the plain name was taken |
| Not on PATH at all | conda's Python, pyenv versions, a CLI dropped into `~/toolchains` or `~/.local/bin` |
| Bundled with a host | An IDE's `jbr/` contains a full JDK that never registers as a system tool |

census walks all four categories, keeping **which one** and **which ones** as separate
questions. It is not limited to language runtimes: anything you can declare — a compiler,
a CLI, a reversing tool — gets the same treatment.

## Per-project versions, if you want them

`census` is a zero-dependency single-file script — clone and run, nothing else needed. To
also make each project switch runtimes by itself, add a version manager on top:

```powershell
.\scripts\bootstrap.ps1 -DryRun   # see what it would change
.\scripts\bootstrap.ps1
```

```bash
./scripts/bootstrap.sh --dry-run
./scripts/bootstrap.sh
```

It installs [mise](https://mise.jdx.dev), deploys a machine-level manifest, moves mise's
shims to the front of the **user** PATH, and runs `mise install`. It never touches
machine-level environment variables, never deletes PATH entries, and never modifies
IDE-bundled runtimes. Every step it takes — and how to undo it — is listed in the
[reference](docs/reference.md#what-bootstrap-changes-and-how-to-undo-it).

## Install as a skill

The repo root contains `SKILL.md`, so the repository itself is a Cursor / Claude skill.
Link it rather than copying, so that `git pull` upgrades the skill:

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

`AGENTS.md` is the companion **discovery contract** — the rules an agent must follow when
judging tool availability. Copy it into your own project's rules file; it works standalone.
Both files are written in Chinese.

## Documentation

- [docs/reference](docs/reference.md) — every flag, the JSON schema, all warning codes, the tools-root convention
- [docs/platform-notes](docs/platform-notes.md) — Windows PATH order, 0-byte aliases, known limitations
- [docs/contributing](docs/contributing.md) — local checks, CI, encoding and line-ending rules

## FAQ

**Why not just use mise?**
mise can only manage what it installed itself. It will never know about
`<system drive>:\nodejs`, conda's Python, or an IDE's bundled JDK. Managed and
pre-existing layers have to be viewed separately — looking at only the former makes people
believe the inventory is complete.

**Isn't a directory scan slow?**
It uses targeted probing rather than a full walk: one `stat` is one to two orders of
magnitude cheaper than a directory enumeration. What does cost time is spawning processes
for what it finds, hence `--deep` being the slow path.

**Why not Docker?**
Containers are a different trade-off: stronger isolation, at the cost of an image per
project. This project's goal is to make **the native machine predictable**. The two can
coexist.

## License

MIT © [haxsd](https://github.com/haxsd)
