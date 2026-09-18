[中文](platform-notes.zh-CN.md) ｜ **English** ｜ [README](../README.md)

# Platform notes

Behaviour that differs between Windows, macOS and Linux — plus the traps that make a
working command look broken. Each one is something `census` reports rather than hides.

## mise activate does not switch directories on PowerShell 5.1

mise's `chpwd` hook requires PowerShell 7 or newer. On 5.1, activation only prepends
mise's versions as the global default — `cd`-ing into a project switches nothing, which is
the only reason to use `activate` in the first place.

PowerShell profiles are **per-host** (5.1 reads `WindowsPowerShell`, 7 reads `PowerShell`),
so bootstrap writes the activation line into **both** hosts' profiles when PowerShell 7 is
available, and tells you to open `pwsh` instead.

Detect PowerShell 7 with a probe, not by looking for the file: the `pwsh.exe` in
`WindowsApps` is a 0-byte alias.

## Windows composes PATH as machine entries first, user entries second

Commands are resolved by walking that combined list, so a machine-level direct tool
directory (`C:\ProgramData\Oracle\Java\javapath`) or a legacy directory early in the user
PATH always beats mise's shims, which scripts usually append at the end.

`mise activate` prepends the shims **inside the session only**: interactive shells get the
declared version, while cmd, GUI apps, IDE tasks and `-NoProfile` scripts silently get the
old one. That gap is what `[PATH_ORDER]` reports. bootstrap moves the shims to the *front*
of the user PATH and lists the machine-level directories, which need admin rights to change.

## Exists ≠ usable on Windows, but 0 bytes ≠ broken

`WindowsApps\python3.exe` is a 0-byte Microsoft Store app-execution alias; `Get-Command`
finds it, `where.exe` lists it, and running it produces no output and exits with code 9009.

A 0-byte alias is not automatically broken, though: `pwsh.exe` and `winget.exe` are 0-byte
aliases that work, because their target apps are installed. File length means "suspect",
not "unusable" — confirm by running a version command and checking for output. That is
exactly how `census` decides: `[STUB]` appears only after a probe actually fails.

## ZIP downloads lose the executable bit on Linux and macOS

GitHub's ZIP archive does not carry file modes, so `./scripts/census.sh` fails with
`Permission denied` even though the repository has it marked executable. Either clone
instead, or run `chmod +x scripts/*.sh` once after unpacking.

## bash on PATH is usually the WSL relay

On Windows, `bash` is normally `C:\WINDOWS\system32\bash.exe`. Without a distro installed
it fails with `execvpe(/bin/bash) failed: No such file or directory`, which looks like a
syntax error in your script but is not. `tests/verify-shell.ps1` finds a real bash (Git
Bash, otherwise a `bash` container) and runs `bash -n` over every `.sh` — parse only,
never execute.

## The PowerShell 5.1 `@()` trap

`@($list)` on a `List[object]` throws `Argument types do not match` — use
`$list.ToArray()`. If the script also sets `$ErrorActionPreference = 'SilentlyContinue'`,
the error is swallowed entirely and only surfaces later as an object mysteriously becoming
`$null`, which is very hard to trace.

## Known limitations

- Targeted probing only covers **known install layouts**. Runtimes in completely
  non-standard locations require `--deep`.
- `census.sh` only detects JBRs inside `.app` bundles on macOS under common naming;
  non-standard JetBrains Toolbox install paths may be missed.
- mise's native Windows support is less mature than on Unix. Some plugins' build scripts
  assume a Unix-like environment; use WSL or a container for those.
- The `mise.run` installer does not work on Windows (macOS/Linux only) — use
  winget / scoop / choco / npm / a manual download instead.
- CLI output is Chinese by default. The warning codes (`STUB`, `SHADOWED`, `CONVENTION`,
  `MISSING`) and the `--json` output are language-neutral; `--lang en` switches the prose
  on both platforms.
