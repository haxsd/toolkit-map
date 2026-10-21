import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const SERVER_PATH = fileURLToPath(new URL('../server.mjs', import.meta.url));
const REPO_ROOT = path.resolve(path.dirname(SERVER_PATH), '..');

function startServer() {
  const child = spawn(process.execPath, [SERVER_PATH], {
    stdio: ['pipe', 'pipe', 'pipe'],
    env: { ...process.env, TOOLKIT_MAP_PROJECT: process.cwd() }
  });
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');

  let buffer = '';
  let stderr = '';
  const messages = [];
  const waiters = [];

  child.stdout.on('data', (chunk) => {
    buffer += chunk;
    let newline;
    while ((newline = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      if (!line.trim()) continue;
      const message = JSON.parse(line);
      messages.push(message);
      for (const waiter of [...waiters]) {
        if (waiter.predicate(message)) {
          waiters.splice(waiters.indexOf(waiter), 1);
          waiter.resolve(message);
        }
      }
    }
  });
  child.stderr.on('data', (chunk) => {
    stderr += chunk;
  });

  function waitFor(predicate, timeoutMs = 5000) {
    const existing = messages.find(predicate);
    if (existing) return Promise.resolve(existing);
    return new Promise((resolve, reject) => {
      const waiter = { predicate, resolve };
      waiters.push(waiter);
      const timer = setTimeout(() => {
        const index = waiters.indexOf(waiter);
        if (index >= 0) waiters.splice(index, 1);
        reject(new Error(`Timed out waiting for a response. stderr: ${stderr}`));
      }, timeoutMs);
      const originalResolve = waiter.resolve;
      waiter.resolve = (value) => {
        clearTimeout(timer);
        originalResolve(value);
      };
    });
  }

  function send(message) {
    child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  function close() {
    child.stdin.end();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        child.kill('SIGKILL');
        reject(new Error('Server did not exit after stdin closed'));
      }, 5000);
      child.on('close', (code) => {
        clearTimeout(timer);
        resolve(code);
      });
    });
  }

  return { child, send, waitFor, close, messages, stderr: () => stderr };
}

test('stdio server serves initialize, tools/list and ping without stdout noise', async () => {
  const client = startServer();

  client.send({
    jsonrpc: '2.0',
    id: 1,
    method: 'initialize',
    params: {
      protocolVersion: '2025-06-18',
      capabilities: {},
      clientInfo: { name: 'test', version: '1.0.0' }
    }
  });
  client.send({ jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} });
  client.send({ jsonrpc: '2.0', id: 3, method: 'ping', params: {} });

  const initialize = await client.waitFor((message) => message.id === 1);
  const list = await client.waitFor((message) => message.id === 2);
  const ping = await client.waitFor((message) => message.id === 3);

  assert.equal(initialize.result.protocolVersion, '2025-06-18');
  assert.equal(list.result.tools.length, 3);
  assert.equal(ping.result.resultType, undefined);

  const exitCode = await client.close();
  assert.equal(exitCode, 0);
  assert.equal(client.messages.length, 3, 'stdout must contain only JSON-RPC messages');
});

test('stdio server reports parse errors as JSON-RPC errors', async () => {
  const client = startServer();
  client.child.stdin.write('this is not json\n');

  const response = await client.waitFor((message) => message.error?.code === -32700);
  assert.equal(response.id, null);

  await client.close();
});

test('--print-config emits a stdio entry with absolute paths', () => {
  const project = path.join(REPO_ROOT, 'examples');
  const output = execFileSync(process.execPath, [SERVER_PATH, '--print-config', '--project', project], {
    encoding: 'utf8'
  });
  const config = JSON.parse(output);
  const entry = config.mcpServers['toolkit-map'];

  assert.equal(entry.command, process.execPath);
  assert.deepEqual(entry.args, [SERVER_PATH]);
  assert.equal(entry.env.TOOLKIT_MAP_PROJECT, path.resolve(project));
});

test('--print-config codex emits TOML', () => {
  const output = execFileSync(process.execPath, [SERVER_PATH, '--print-config', 'codex'], {
    encoding: 'utf8'
  });

  assert.match(output, /^\[mcp_servers\.toolkit-map\]/m);
  assert.match(output, /command = "/);
  assert.match(output, /args = \["/);
});

test('--version reads the repository VERSION file', () => {
  const expected = fs.readFileSync(path.join(REPO_ROOT, 'VERSION'), 'utf8').trim();
  const output = execFileSync(process.execPath, [SERVER_PATH, '--version'], { encoding: 'utf8' });
  assert.equal(output.trim(), expected);
});

test('package.json version stays in sync with VERSION', () => {
  const expected = fs.readFileSync(path.join(REPO_ROOT, 'VERSION'), 'utf8').trim();
  const pkg = JSON.parse(fs.readFileSync(path.join(REPO_ROOT, 'mcp', 'package.json'), 'utf8'));
  assert.equal(pkg.version, expected);
});
