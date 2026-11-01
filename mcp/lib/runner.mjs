import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const DEFAULT_TIMEOUT_MS = 120_000;
const MAX_OUTPUT_CHARS = 16 * 1024 * 1024;
const FORCE_KILL_GRACE_MS = 2_000;
const TOOL_NAME_PATTERN = /^[a-z0-9][a-z0-9._+-]*$/;

export class MapRunError extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.name = 'MapRunError';
    this.code = code;
    this.details = details;
  }
}

export function defaultMapScript() {
  return fileURLToPath(new URL('../../scripts/map.ps1', import.meta.url));
}

export function defaultPowerShell(platform = process.platform, env = process.env) {
  if (env.TOOLKIT_MAP_POWERSHELL) return env.TOOLKIT_MAP_POWERSHELL;
  return platform === 'win32' ? 'powershell.exe' : 'pwsh';
}

function pushOption(args, flag, value) {
  if (value === undefined || value === null || String(value) === '') return;
  args.push(flag, String(value));
}

function timeoutFrom(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_TIMEOUT_MS;
}

function assertToolName(value, action) {
  const name = String(value || '').trim().toLowerCase();
  if (!TOOL_NAME_PATTERN.test(name)) {
    throw new MapRunError(
      'invalid_action',
      `${action} tool must be a command name, not a path or a name with separators`
    );
  }
  return name;
}

// Reject paths whose meaning depends on a drive's current directory, as well
// as device namespaces and UNC paths without both a server and a share.
export function isDeterministicAbsolutePath(value) {
  if (typeof value !== 'string' || value === '') return false;
  if (/^\\\\[?.]\\/.test(value)) return false;
  if (/^[A-Za-z]:(?![\\/])/.test(value)) return false;
  if (value.charAt(0) === '\\' && !/^\\\\[^\\/?.*]+\\[^\\/]+/.test(value)) return false;
  return path.win32.isAbsolute(value) || path.posix.isAbsolute(value);
}

function assertAbsolutePath(value, platform) {
  const text = normalizeAddExecutablePath(value, platform);
  if (!text) {
    throw new MapRunError('invalid_action', 'add path must be an absolute path with an unambiguous target');
  }
  return text;
}

const WINDOWS_DRIVE_ABSOLUTE = /^[A-Za-z]:[\\/]/;
const WINDOWS_DRIVE_RELATIVE = /^[A-Za-z]:(?![\\/])/;
const WINDOWS_DEVICE = /^\\\\[?.]\\/;
const WINDOWS_UNC = /^\\\\[^\\?./]/;
// [IO.Path]::GetFullPath throws for these characters on Windows (beyond the
// drive prefix). Claiming a definite target there would describe a path
// map.ps1 can never resolve, so such values stay unknown.
const WINDOWS_INVALID_PATH_CHARACTERS = /[<>"|?*]/;
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/;

function describeValue(value) {
  const text = String(value);
  return text.length > 200 ? `${text.slice(0, 200)}…` : text;
}

function unknownMapTarget(source, reason) {
  return {
    known: false,
    source,
    hint: `cannot determine the map file: ${reason}; set TOOLKIT_MAP_FILE to an exact absolute path`
  };
}

// Mirrors scripts/map-core.ps1 Get-MapPath without touching the disk or running
// any program: -MapFile (the server's mapFile, else TOOLKIT_MAP_FILE), then
// TOOLKIT_MAP, then <home>/.toolkit/map.json.
function resolveMapValue(value, platform, cwd) {
  const text = String(value || '');
  const unobservable = (input) => ({
    path: null,
    reason: `${describeValue(input)} depends on a working directory the server cannot observe`
  });
  if (!text) return { path: null, reason: 'the map file value is empty' };

  if (platform !== 'win32') {
    if (path.posix.isAbsolute(text)) return { path: path.posix.normalize(text) };
    return typeof cwd === 'string' && path.posix.isAbsolute(cwd)
      ? { path: path.posix.resolve(cwd, text) }
      : unobservable(text);
  }

  // "C:maps\map.json" depends on PowerShell's per-drive current directory,
  // which the server cannot observe. Never guess.
  if (WINDOWS_DRIVE_RELATIVE.test(text)) return unobservable(text);

  const device = WINDOWS_DEVICE.test(text);
  // Node's win32 normalization and PowerShell/.NET GetFullPath disagree on
  // forward-slash UNC paths, traversal above a UNC share, and names ending in
  // dots/spaces. Do not promise a target we cannot faithfully represent.
  const unc = /^[\\/]{2}/.test(text);
  if (device || (unc && (!/^\\\\[^\\/]+\\[^\\/]+(?:\\|$)/.test(text) || text.includes('/')))) {
    return { path: null, reason: `${describeValue(text)} uses an ambiguous Windows UNC or device path` };
  }
  const components = text.replace(/^[A-Za-z]:/, '').split(/[\\/]/);
  if ((unc && components.includes('..')) || components.some((part) => part && part !== '.' && part !== '..' && /[. ]$/.test(part))) {
    return { path: null, reason: `${describeValue(text)} contains ambiguous Windows path components` };
  }
  if (!device) {
    const tail = WINDOWS_DRIVE_ABSOLUTE.test(text) ? text.slice(2) : text;
    if (WINDOWS_INVALID_PATH_CHARACTERS.test(tail) || tail.includes(':')) {
      return {
        path: null,
        reason: `${describeValue(text)} contains characters Windows rejects in a path`
      };
    }
  }

  if (!device && text.startsWith('\\\\') && !isDeterministicAbsolutePath(text)) {
    return { path: null, reason: `${describeValue(text)} is not a complete UNC server and share path` };
  }
  if (device || WINDOWS_DRIVE_ABSOLUTE.test(text) || WINDOWS_UNC.test(text)) {
    return { path: path.win32.normalize(text) };
  }

  const base = typeof cwd === 'string' && path.win32.isAbsolute(cwd) && !WINDOWS_DEVICE.test(cwd) ? cwd : null;
  if (text.startsWith('\\') || text.startsWith('/')) {
    // A single leading separator is rooted on the current drive, not absolute.
    if (!base || !WINDOWS_DRIVE_ABSOLUTE.test(base)) return unobservable(text);
    return { path: path.win32.normalize(`${base.slice(0, 2)}${text}`) };
  }
  return base ? { path: path.win32.resolve(base, text) } : unobservable(text);
}

// A maintenance preview must name the exact executable map.ps1 will receive.
// On Windows, a single leading slash is drive-relative, not an absolute path.
export function normalizeAddExecutablePath(value, platform = process.platform) {
  if (typeof value !== 'string' || !value || value !== value.trim() || CONTROL_CHARACTERS.test(value)) return '';
  const windowsLike = WINDOWS_DRIVE_ABSOLUTE.test(value) || value.startsWith('\\\\');
  if (platform === 'win32' || windowsLike) {
    if (!windowsLike) return '';
    const resolved = resolveMapValue(value, 'win32', '');
    return resolved.path || '';
  }
  return path.posix.isAbsolute(value) ? path.posix.normalize(value) : '';
}

export function resolveMapTarget(config = {}) {
  const platform = config.platform || process.platform;
  const env = config.env || process.env;
  const cwd = config.cwd || process.cwd();
  // Same expression as buildInvocation, so a preview can never name a map file
  // the spawned map.ps1 would not receive. An empty value counts as unset.
  const mapFileOption = String(config.mapFile || env.TOOLKIT_MAP_FILE || '');
  const envMap = String(env.TOOLKIT_MAP || '');

  let raw;
  let source;
  if (mapFileOption) {
    raw = mapFileOption;
    source = 'server';
  } else if (envMap) {
    // buildInvocation already forwards TOOLKIT_MAP_FILE as -MapFile; map.ps1
    // reads TOOLKIT_MAP directly, which outranks the default home path.
    raw = envMap;
    source = 'environment';
  } else {
    const home = platform === 'win32' ? env.USERPROFILE : env.HOME;
    if (!home) {
      return unknownMapTarget(
        'unknown',
        platform === 'win32'
          ? 'no server map file is configured and USERPROFILE is not set'
          : 'no server map file is configured and HOME is not set'
      );
    }
    raw = platform === 'win32'
      ? path.win32.join(String(home), '.toolkit', 'map.json')
      : path.posix.join(String(home), '.toolkit', 'map.json');
    source = 'default';
  }

  // Windows PowerShell 5.1 trims surrounding spaces before GetFullPath (it does
  // not fail), and control characters fail outright; other hosts may differ.
  // Guessing would advertise a target that may not be the one written, so such
  // values stay unknown.
  if (platform === 'win32' && raw !== raw.trim()) {
    return unknownMapTarget(
      source,
      `${describeValue(raw)} has surrounding whitespace, which Windows PowerShell 5.1 and PowerShell 7 resolve differently`
    );
  }
  if (CONTROL_CHARACTERS.test(raw)) {
    return unknownMapTarget(source, `${describeValue(raw)} contains control characters`);
  }

  const resolved = resolveMapValue(raw, platform, cwd);
  if (!resolved.path) {
    return unknownMapTarget(source, resolved.reason);
  }
  if (platform === 'win32') {
    // A relative value may inherit unsafe components from the configured cwd.
    const components = resolved.path.replace(/^[A-Za-z]:/, '').split(/[\\/]/);
    if (components.some((part) => part && part !== '.' && part !== '..' && /[. ]$/.test(part))) {
      return unknownMapTarget(source, `${describeValue(resolved.path)} contains ambiguous Windows path components`);
    }
  }
  const extension = (platform === 'win32' ? path.win32 : path.posix).extname(resolved.path);
  if (extension.toLowerCase() === '.md') {
    return unknownMapTarget(source, 'the map file cannot use the .md extension reserved for the Markdown summary');
  }
  return { known: true, path: resolved.path, source };
}

export function buildInvocation(action, options = {}, config = {}) {
  const env = config.env || process.env;
  const platform = config.platform || process.platform;
  const script = config.script || env.TOOLKIT_MAP_SCRIPT || defaultMapScript();
  const host = config.powershell || defaultPowerShell(platform, env);
  const mapFile = config.mapFile || env.TOOLKIT_MAP_FILE || '';
  const args = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script];

  switch (action) {
    case 'find':
      if (!options.tool) throw new MapRunError('invalid_action', 'find requires a tool name');
      args.push('find', assertToolName(options.tool, 'find'));
      pushOption(args, '-Project', options.project);
      pushOption(args, '-Version', options.version);
      if (options.skipScan) args.push('-SkipScan');
      break;
    case 'status':
      args.push('status');
      break;
    case 'doctor':
      args.push('doctor');
      pushOption(args, '-Project', options.project);
      pushOption(args, '-RulesFile', options.rulesFile);
      break;
    case 'scan':
      args.push('scan');
      break;
    case 'update':
      args.push('update');
      if (options.tool) args.push(assertToolName(options.tool, 'update'));
      break;
    case 'add':
      if (!options.tool) throw new MapRunError('invalid_action', 'add requires a tool name');
      if (!options.path) throw new MapRunError('invalid_action', 'add requires a path');
      args.push('add', assertToolName(options.tool, 'add'));
      args.push('-Path', assertAbsolutePath(options.path, platform));
      pushOption(args, '-Version', options.version);
      pushOption(args, '-Note', options.note);
      if (options.prefer === true) args.push('-Prefer');
      break;
    default:
      throw new MapRunError('invalid_action', `Unsupported map action: ${action}`);
  }

  pushOption(args, '-MapFile', mapFile);
  args.push('-Json');
  return { command: host, args, script };
}

function truncate(value, maxLength = 4000) {
  const text = String(value ?? '');
  return text.length > maxLength ? `${text.slice(0, maxLength)}…` : text;
}

function killTree(child, platform) {
  try {
    if (platform === 'win32' && child.pid) {
      const killer = spawn('taskkill', ['/PID', String(child.pid), '/T', '/F'], {
        windowsHide: false,
        shell: false,
        stdio: 'ignore'
      });
      killer.on('error', () => {});
      return;
    }
    child.kill?.('SIGKILL');
  } catch {
    try {
      child.kill?.();
    } catch {
      // Best effort only; the timeout rejection below is the contract.
    }
  }
}

function parseOutput(stdout, stderr, exitCode, signal) {
  const cleaned = stdout.replace(/^\uFEFF/, '').trim();
  if (!cleaned) {
    throw new MapRunError('invalid_output', 'map.ps1 produced no JSON output', {
      exitCode,
      signal,
      stderr: truncate(stderr)
    });
  }
  let parsed;
  try {
    parsed = JSON.parse(cleaned);
  } catch (error) {
    throw new MapRunError('invalid_output', `map.ps1 output is not a single JSON object: ${error.message}`, {
      exitCode,
      signal,
      stdout: truncate(cleaned, 1000),
      stderr: truncate(stderr)
    });
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new MapRunError('invalid_output', 'map.ps1 returned a non-object JSON value', {
      exitCode,
      signal,
      stderr: truncate(stderr)
    });
  }
  return parsed;
}

export function runMap(action, options = {}, config = {}) {
  const platform = config.platform || process.platform;
  const env = config.env || process.env;
  const allowNonWindows = config.allowNonWindows || env.TOOLKIT_MAP_ALLOW_NON_WINDOWS === '1';

  if (platform !== 'win32' && !allowNonWindows) {
    return Promise.reject(new MapRunError(
      'unsupported_platform',
      'The full toolkit-map action set currently requires Windows PowerShell 5.1 or PowerShell 7 on Windows.'
    ));
  }

  let invocation;
  try {
    invocation = buildInvocation(action, options, { ...config, platform, env });
  } catch (error) {
    return Promise.reject(error);
  }

  if (!existsSync(invocation.script)) {
    return Promise.reject(new MapRunError('map_script_missing', `map.ps1 not found: ${invocation.script}`, {
      stderr: ''
    }));
  }

  const timeoutMs = timeoutFrom(config.timeoutMs ?? env.TOOLKIT_MAP_TIMEOUT_MS);
  const spawnImpl = config.spawnImpl || spawn;
  // A preview resolves the map target from the server's startup snapshot. Pass
  // exactly that snapshot so map.ps1 cannot read a later mutation of
  // process.env and write a different map than the preview named.
  const childEnv = config.env ? { ...config.env } : null;
  // Relative map values are resolved against the same directory the preview
  // used. Without this the child could inherit a different working directory
  // and resolve a different map file than the one the preview reported.
  const childCwd = typeof config.cwd === 'string' && config.cwd ? config.cwd : null;

  return new Promise((resolve, reject) => {
    let child;
    try {
      const spawnOptions = {
        // 继承 MCP server 已有的隐藏控制台，不创建新的 conhost。
        windowsHide: false,
        shell: false,
        stdio: ['ignore', 'pipe', 'pipe']
      };
      if (childEnv) spawnOptions.env = childEnv;
      if (childCwd) spawnOptions.cwd = childCwd;
      child = spawnImpl(invocation.command, invocation.args, spawnOptions);
    } catch (error) {
      reject(new MapRunError('spawn_failed', `Failed to start ${invocation.command}: ${error.message}`, {
        stderr: ''
      }));
      return;
    }

    let stdout = '';
    let stderr = '';
    let settled = false;
    let timedOut = false;
    let overflowed = false;
    let timer;
    let forceTimer;

    const settle = (callback) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      clearTimeout(forceTimer);
      callback();
    };

    child.stdout?.setEncoding?.('utf8');
    child.stderr?.setEncoding?.('utf8');

    child.stdout?.on('data', (chunk) => {
      stdout += chunk.toString();
      if (stdout.length > MAX_OUTPUT_CHARS && !overflowed) {
        overflowed = true;
        killTree(child, platform);
      }
    });
    child.stderr?.on('data', (chunk) => {
      if (stderr.length < MAX_OUTPUT_CHARS) stderr += chunk.toString();
    });

    child.on('error', (error) => {
      settle(() => reject(new MapRunError('spawn_failed', `Failed to start ${invocation.command}: ${error.message}`, {
        stderr: truncate(stderr)
      })));
    });

    child.on('close', (exitCode, signal) => {
      settle(() => {
        if (timedOut) {
          reject(new MapRunError('timeout', `map.ps1 did not finish within ${timeoutMs} ms`, {
            exitCode,
            signal,
            stderr: truncate(stderr)
          }));
          return;
        }
        if (overflowed) {
          reject(new MapRunError('output_too_large', 'map.ps1 output exceeded the MCP server limit', {
            exitCode,
            signal,
            stderr: truncate(stderr)
          }));
          return;
        }
        try {
          resolve(parseOutput(stdout, stderr, exitCode, signal));
        } catch (error) {
          reject(error);
        }
      });
    });

    timer = setTimeout(() => {
      timedOut = true;
      killTree(child, platform);
      forceTimer = setTimeout(() => {
        settle(() => reject(new MapRunError('timeout', `map.ps1 did not exit after ${timeoutMs} ms`, {
          exitCode: null,
          signal: null,
          stderr: truncate(stderr)
        })));
      }, FORCE_KILL_GRACE_MS);
      forceTimer.unref?.();
    }, timeoutMs);
  });
}
