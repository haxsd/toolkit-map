#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';

import { createProtocolHandler } from './lib/protocol.mjs';
import { runMap } from './lib/runner.mjs';
import { SERVER_NAME, SERVER_TITLE } from './lib/tools.mjs';

const SERVER_PATH = fileURLToPath(import.meta.url);
const REPO_ROOT = path.resolve(path.dirname(SERVER_PATH), '..');
const MAX_LINE_LENGTH = 1024 * 1024;

function readVersion() {
  try {
    const value = fs.readFileSync(path.join(REPO_ROOT, 'VERSION'), 'utf8').trim();
    return value || '0.0.0';
  } catch {
    return '0.0.0';
  }
}

function assertNodeVersion() {
  const major = Number(process.versions.node.split('.')[0]);
  if (Number.isFinite(major) && major < 18) {
    process.stderr.write(`toolkit-map MCP requires Node.js 18 or newer; current: ${process.versions.node}\n`);
    process.exit(1);
  }
}

function helpText() {
  return [
    'toolkit-map MCP server',
    '',
    '用法：',
    '  node mcp/server.mjs                 启动 stdio MCP 服务器',
    '  node mcp/server.mjs --check         用当前配置执行一次 status，人类可读',
    '  node mcp/server.mjs --print-config  输出 Cursor / Claude Code 的 mcpServers JSON',
    '  node mcp/server.mjs --print-config codex   输出 Codex TOML 配置',
    '  node mcp/server.mjs --version       输出版本',
    '',
    '选项：',
    '  --project <绝对路径>   写入配置的 TOOLKIT_MAP_PROJECT 默认值',
    '  --client <名称>        cursor（默认）、claude、codex',
    '',
    '环境变量：',
    '  TOOLKIT_MAP_SCRIPT        覆盖 scripts/map.ps1 路径',
    '  TOOLKIT_MAP_POWERSHELL    覆盖 PowerShell 宿主',
    '  TOOLKIT_MAP_FILE          覆盖 map.json 路径',
    '  TOOLKIT_MAP_PROJECT       默认项目目录',
    '  TOOLKIT_MAP_TIMEOUT_MS    单次地图调用超时，默认 120000',
    ''
  ].join('\n');
}

function tomlString(value) {
  return `"${String(value)
    .replace(/\\/g, '\\\\')
    .replace(/"/g, '\\"')
    .replace(/\r/g, '\\r')
    .replace(/\n/g, '\\n')}"`;
}

function configEntry(project) {
  const entry = {
    command: process.execPath,
    args: [SERVER_PATH]
  };
  if (project) {
    entry.env = { TOOLKIT_MAP_PROJECT: path.resolve(project) };
  }
  return entry;
}

function printConfig(client, project) {
  const entry = configEntry(project);
  const normalized = String(client || 'cursor').toLowerCase();

  if (normalized === 'codex') {
    const lines = [
      '[mcp_servers.toolkit-map]',
      `command = ${tomlString(entry.command)}`,
      `args = [${entry.args.map(tomlString).join(', ')}]`
    ];
    if (entry.env) {
      const pairs = Object.entries(entry.env).map(([key, value]) => `${tomlString(key)} = ${tomlString(value)}`);
      lines.push(`env = { ${pairs.join(', ')} }`);
    }
    process.stdout.write(`${lines.join('\n')}\n`);
    return;
  }

  if (!['cursor', 'claude', 'claude-code'].includes(normalized)) {
    throw new Error(`Unknown client: ${client}. Use cursor, claude or codex.`);
  }

  process.stdout.write(`${JSON.stringify({ mcpServers: { [SERVER_NAME]: entry } }, null, 2)}\n`);
}

function optionValue(argv, name) {
  const index = argv.indexOf(name);
  if (index < 0) return '';
  const value = argv[index + 1];
  return value && !value.startsWith('-') ? value : '';
}

async function main() {
  const argv = process.argv.slice(2);

  if (argv.includes('--help') || argv.includes('-h')) {
    process.stdout.write(helpText());
    return;
  }

  if (argv.includes('--version')) {
    process.stdout.write(`${readVersion()}\n`);
    return;
  }

  assertNodeVersion();

  const project = optionValue(argv, '--project');
  const client = optionValue(argv, '--client');

  if (argv.includes('--print-config')) {
    const index = argv.indexOf('--print-config');
    const inlineClient = argv[index + 1] && !argv[index + 1].startsWith('-') ? argv[index + 1] : '';
    printConfig(client || inlineClient || 'cursor', project);
    return;
  }

  if (argv.includes('--check')) {
    try {
      const result = await runMap('status', {});
      process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
      process.exitCode = result.ok ? 0 : 1;
    } catch (error) {
      process.stderr.write(`${error.message}\n`);
      if (error.details?.stderr) process.stderr.write(`${error.details.stderr}\n`);
      process.exitCode = 1;
    }
    return;
  }

  const handler = createProtocolHandler({
    runMap,
    serverInfo: { name: SERVER_NAME, title: SERVER_TITLE, version: readVersion() },
    defaultProject: process.env.TOOLKIT_MAP_PROJECT || process.env.CLAUDE_PROJECT_DIR || process.cwd()
  });

  let closing = false;
  let exiting = false;
  let active = 0;

  function maybeExit() {
    if (!closing || active > 0 || exiting) return;
    exiting = true;
    process.exit(0);
  }

  function writeMessage(message) {
    if (exiting || !message) return;
    try {
      process.stdout.write(`${JSON.stringify(message)}\n`);
    } catch {
      // The client closed the pipe; stdin close will end the process.
    }
  }

  async function handleLine(line) {
    active += 1;
    try {
      const trimmed = line.trim();
      if (!trimmed) return;
      if (trimmed.length > MAX_LINE_LENGTH) {
        writeMessage({
          jsonrpc: '2.0',
          id: null,
          error: { code: -32700, message: 'Request line is too large' }
        });
        return;
      }

      let message;
      try {
        message = JSON.parse(trimmed);
      } catch {
        writeMessage({
          jsonrpc: '2.0',
          id: null,
          error: { code: -32700, message: 'Parse error' }
        });
        return;
      }

      try {
        const response = await handler.handle(message);
        writeMessage(response);
      } catch (error) {
        writeMessage({
          jsonrpc: '2.0',
          id: message?.id ?? null,
          error: {
            code: -32603,
            message: 'Internal error',
            data: { message: String(error?.message || error) }
          }
        });
      }
    } finally {
      active -= 1;
      maybeExit();
    }
  }

  const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  rl.on('line', (line) => {
    void handleLine(line);
  });
  rl.on('close', () => {
    closing = true;
    // Give in-flight tool calls a short window to finish before exiting.
    // Without this, `... | node server.mjs` drops the response.
    setTimeout(() => {
      exiting = true;
      process.exit(0);
    }, 5000).unref();
    maybeExit();
  });

  process.stdin.on('error', () => {
    closing = true;
    maybeExit();
  });

  process.stdout.on('error', (error) => {
    if (error?.code === 'EPIPE') process.exit(0);
  });

  for (const signal of ['SIGINT', 'SIGTERM']) {
    process.on(signal, () => {
      closing = true;
      process.exit(0);
    });
  }
}

main().catch((error) => {
  process.stderr.write(`${error?.stack || error}\n`);
  process.exit(1);
});
