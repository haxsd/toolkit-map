[中文](contributing.zh-CN.md) ｜ **English** ｜ [README](../README.md)

# Contributing

Two implementations of the same tool have to be kept in step by hand, and the drift is
real: `census.sh` once silently produced an empty runtime inventory because a helper was
missing a field, and the report still looked healthy. So the checks below are the
contract, not a formality.

## Layout

```text
scripts/     the product — census and bootstrap, one pair per platform
templates/   mise-config.toml, the machine manifest bootstrap deploys
examples/    declaration files in both formats
tests/       development checks, never part of the product surface
docs/        reference, platform notes, this file — each in English and Chinese
AGENTS.md    the discovery contract for agents
SKILL.md     makes the repo installable as a Cursor / Claude skill
```

## Local checks

| Check | What it does |
|---|---|
| `.\tests\check-encodings.ps1` | Every `.ps1` carries a UTF-8 BOM, no `.sh` does, and each `.ps1` still parses when read as cp1252. Add `-Fix` to add a missing BOM |
| `.\tests\check-docs.ps1` | Every doc has its Chinese counterpart, and every relative Markdown link resolves |
| `.\tests\parity.ps1` | Runs both implementations in one sandbox and asserts they found the same planted problems. Needs a real bash on Windows (Git Bash is found automatically); `-KeepSandbox` keeps the sandbox for inspection |
| `bash tests/smoke.sh` | Smoke test for `census.sh` against a synthetic machine |
| `.\tests\verify-shell.ps1` | Runs `bash -n` over every `.sh` through a real bash — parse only, never execute |

**How much to run**: only what covers your change — docs → `check-docs.ps1`; `.sh` →
`verify-shell.ps1`; warning or resolution logic → `parity.ps1`. Run the whole set **before
publishing**. `parity.ps1` spawns both implementations (about a minute), and running everything
after every small edit is exactly what makes this repo feel slow and heavy. To check that a
stranger can use a fresh clone, copy the tracked files into a clean directory and follow the
README once — it does not need to be a daily step.

## Rules that are easy to break

- **Every `.ps1` carries a UTF-8 BOM.** Without it, PowerShell 5.1 on an English system
  decodes the Chinese comments as cp1252, turns them into smart quotes, and fails to parse
  the script — a problem completely invisible on a Chinese-locale dev machine.
- **Every `.sh` is LF and has no BOM.** A BOM breaks the shebang; CRLF breaks the script
  with `env: 'bash\r': No such file or directory`. `.gitattributes` pins `*.sh eol=lf`.
- **Keep the executable bit on `.sh` files you add**: `git update-index --chmod=+x
  scripts/foo.sh`. A Windows checkout cannot set it, and CI executes the scripts.
- **The two `--json` schemas share a documented core, not an enforced identity.** Consumers
  may rely on the fields listed in `docs/reference.md`; a fact that only exists on one platform
  (say `host.powershell`) is allowed to appear only in that implementation. Bump
  `schemaVersion` when the *documented* field set or its semantics change, and extend
  `tests/parity.ps1` when you add a warning category. Per-field equality between the two
  implementations is deliberately **not** asserted: keeping them aligned cost more than the
  missing field did.
- **`census` stays read-only.** Anything that changes machine state belongs in `bootstrap`,
  and must be readable in `-DryRun` / `--dry-run` before it is executed.
- **Docs come in pairs.** `<name>.md` and `<name>.zh-CN.md` must both exist and say the
  same thing; the front pages are `README.md` and `README.zh-CN.md`. `AGENTS.md` and
  `SKILL.md` are the exception: they are contracts copied verbatim into other projects,
  so they stay single-language on purpose.
- **New user-facing strings go through the translation helper**, so `--lang en` keeps
  working alongside the Chinese default.

## What CI runs

| Job | Steps |
|---|---|
| `windows` (PowerShell 5.1 host) | encoding check → doc check → `tests/parity.ps1` (Windows PowerShell 5.1 against shell, in one sandbox) |
| `ubuntu` | `bash -n` over `scripts/*.sh` and `tests/*.sh` → `tests/smoke.sh` |

CI deliberately does **not** run bootstrap: it would really change the machine — writing
PATH entries, touching profiles, downloading runtimes. Failures are echoed as `::error::`
annotations, because job logs need authentication while annotations do not — that is the
only channel an unattended run can report through.


