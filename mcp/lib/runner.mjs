import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const DEFAULT_TIMEOUT_MS = 120_000;
const MAX_OUTPUT_CHARS = 16 * 1024 * 1024;
const FORCE_KILL_GRACE_MS = 2_000;

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

export function buildInvocation(action, options = {}, config = {}) {
  const env = config.env || process.env;
  const platform = config.platform || process.platform;
  const script = config.script || env.TOOLKIT_MAP_SCRIPT || defaultMapScript();
  const host = config.powershell || defaultPowerShell(platform, env);
  const mapFile = config.mapFile ?? env.TOOLKIT_MAP_FILE ?? '';
  const args = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script];

  switch (action) {
    case 'find':
      if (!options.tool) throw new MapRunError('invalid_action', 'find requires a tool name');
      args.push('find', String(options.tool));
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
        windowsHide: true,
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

  return new Promise((resolve, reject) => {
    let child;
    try {
      child = spawnImpl(invocation.command, invocation.args, {
        windowsHide: true,
        stdio: ['ignore', 'pipe', 'pipe']
      });
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
