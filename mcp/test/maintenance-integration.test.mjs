import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { createProtocolHandler } from '../lib/protocol.mjs';
import { runMap } from '../lib/runner.mjs';
import { findTool } from '../lib/tools.mjs';
import { validate } from './schema-validator.mjs';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const MAP_SCRIPT = path.join(REPO_ROOT, 'scripts', 'map.ps1');
const POWERSHELL = process.env.TOOLKIT_MAP_POWERSHELL || 'C:\\WINDOWS\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
const windowsOnly = { skip: process.platform !== 'win32' };

function tempDir(t, prefix) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function createHandler(mapFile) {
  const config = { script: MAP_SCRIPT, powershell: POWERSHELL, mapFile };
  return createProtocolHandler({
    runMap: (action, options) => runMap(action, options, config),
    defaultProject: path.dirname(mapFile),
    serverInfo: { name: 'toolkit-map', title: 'toolkit-map', version: 'test' }
  });
}

function callTool(id, name, args = {}) {
  return { jsonrpc: '2.0', id, method: 'tools/call', params: { name, arguments: args } };
}

function writeFakeRuntime(file, version) {
  fs.writeFileSync(file, `@echo off\r\necho v${version}\r\n`, 'utf8');
}

function readMap(mapFile) {
  return JSON.parse(fs.readFileSync(mapFile, 'utf8').replace(/^\uFEFF/, ''));
}

function assertSchema(schema, value, label) {
  assert.deepEqual(validate(schema, value), [], `${label}: ${JSON.stringify(validate(schema, value))}`);
}

function runAddInSandbox(dir, mapFile, tool, runtime, prefer = false, extraEnv = {}) {
  const args = [
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', MAP_SCRIPT,
    'add', tool, '-Path', runtime, '-MapFile', mapFile, '-Json'
  ];
  if (prefer) args.push('-Prefer');
  const child = spawnSync(POWERSHELL, args, {
    encoding: 'utf8', windowsHide: true,
    env: { ...process.env, USERPROFILE: dir, TOOLCHAIN_ROOT: path.join(dir, 'warehouse'), TOOLKIT_MAP: '', TOOLKIT_MAP_FILE: '', ...extraEnv }
  });
  assert.ifError(child.error);
  return { code: child.status, output: JSON.parse(child.stdout.replace(/^\uFEFF/, '')), stderr: child.stderr };
}

test('a virtual environment with an arbitrary directory name cannot be registered', windowsOnly, (t) => {
  const dir = tempDir(t, 'toolkit-map-venv-config-');
  const envDir = path.join(dir, 'env');
  const inner = path.join(envDir, 'Scripts');
  fs.mkdirSync(inner, { recursive: true });
  fs.writeFileSync(path.join(envDir, 'pyvenv.cfg'), 'home = C:\\example\\python\n', 'utf8');
  const marker = path.join(dir, 'venv-executed.txt');
  const runtime = path.join(inner, 'faketool.cmd');
  fs.writeFileSync(runtime, `@echo off\r\necho executed>"${marker}"\r\necho faketool 1.2.3\r\n`, 'utf8');
  const result = runAddInSandbox(dir, path.join(dir, 'map.json'), 'faketool', runtime);
  assert.notEqual(result.code, 0);
  assert.equal(result.output.status, 'environment_internal');
  assert.equal(fs.existsSync(marker), false);
});

test('an .md map target is rejected before probing and cannot overwrite existing JSON', windowsOnly, (t) => {
  const dir = tempDir(t, 'toolkit-map-md-target-');
  const mapFile = path.join(dir, 'map.md');
  const marker = path.join(dir, 'probe.txt');
  const runtime = path.join(dir, 'node.cmd');
  fs.writeFileSync(runtime, `@echo off\r\necho probe>"${marker}"\r\necho node 22.1.0\r\n`, 'utf8');
  const original = JSON.stringify({ schemaVersion: 2, tools: {}, scannedAt: null, updatedAt: null });
  fs.writeFileSync(mapFile, original, 'utf8');

  const result = runAddInSandbox(dir, mapFile, 'node', runtime);
  assert.notEqual(result.code, 0);
  assert.equal(result.output.status, 'invalid_argument');
  assert.equal(fs.readFileSync(mapFile, 'utf8'), original);
  assert.equal(fs.existsSync(marker), false, 'reject the invalid map target before any version probe');
});

test('an unrelated or user-edited Markdown sidecar is never overwritten', windowsOnly, (t) => {
  const dir = tempDir(t, 'toolkit-map-md-sidecar-');
  const runtime = path.join(dir, 'node.cmd');
  writeFakeRuntime(runtime, '22.1.0');
  const mapFile = path.join(dir, 'custom.json');
  const markdown = path.join(dir, 'custom.md');
  const unrelated = '# My notes\nThis file is not a toolkit-map summary.\n';
  fs.writeFileSync(markdown, unrelated, 'utf8');

  const result = runAddInSandbox(dir, mapFile, 'node', runtime);
  assert.equal(result.code, 0, JSON.stringify(result));
  assert.ok(readMap(mapFile).tools.node);
  assert.equal(fs.readFileSync(markdown, 'utf8'), unrelated);
  assert.match(result.stderr, /Markdown|摘要/i, 'the skipped summary must be reported');
  assert.match(result.output.summaryWarning, /Markdown|摘要/i, 'JSON/MCP clients must receive the warning too');

  const generatedMap = path.join(dir, 'generated.json');
  const generatedMd = path.join(dir, 'generated.md');
  assert.equal(runAddInSandbox(dir, generatedMap, 'node', runtime).code, 0);
  const initial = fs.readFileSync(generatedMd, 'utf8');
  assert.equal(runAddInSandbox(dir, generatedMap, 'python', runtime).code, 0);
  const refreshed = fs.readFileSync(generatedMd, 'utf8');
  assert.notEqual(refreshed, initial, 'an unedited generated summary should refresh');
  const edited = `${refreshed}\nUser-added note that must survive.\n`;
  fs.writeFileSync(generatedMd, edited, 'utf8');
  const afterEdit = runAddInSandbox(dir, generatedMap, 'git', runtime);
  assert.equal(afterEdit.code, 0, JSON.stringify(afterEdit));
  assert.equal(fs.readFileSync(generatedMd, 'utf8'), edited);
  assert.ok(readMap(generatedMap).tools.git, 'the JSON map still updates');
  assert.match(afterEdit.stderr, /Markdown|摘要/i);
});

test('unconfirmed maintenance previews leave an existing map byte-identical', windowsOnly, async (t) => {
  const dir = tempDir(t, 'toolkit-map-mcp-preview-');
  const mapFile = path.join(dir, 'map.json');
  const original = JSON.stringify({
    schemaVersion: 2,
    scannedAt: null,
    updatedAt: null,
    warehouse: path.join(dir, 'warehouse'),
    pathSnapshot: '',
    tools: {}
  });
  fs.writeFileSync(mapFile, original, 'utf8');

  const handler = createHandler(mapFile);

  let response = await handler.handle(callTool(1, 'toolkit_add', {
    tool: 'node',
    path: path.join(dir, 'bin', 'node.cmd'),
    note: 'preview must not write',
    version: '22.99.2',
    prefer: true
  }));
  assert.equal(response.result.isError, false, JSON.stringify(response.result));
  assert.equal(response.result.structuredContent.status, 'planned');
  assert.equal(fs.readFileSync(mapFile, 'utf8'), original);

  response = await handler.handle(callTool(2, 'toolkit_update', { tool: 'node' }));
  assert.equal(response.result.isError, false, JSON.stringify(response.result));
  assert.equal(response.result.structuredContent.status, 'planned');
  assert.equal(fs.readFileSync(mapFile, 'utf8'), original);

  const absentMap = path.join(dir, 'absent-map.json');
  const absentHandler = createHandler(absentMap);
  response = await absentHandler.handle(callTool(3, 'toolkit_add', {
    tool: 'node',
    path: path.join(dir, 'bin', 'node.cmd'),
    confirm: false
  }));
  assert.equal(response.result.structuredContent.status, 'planned');
  assert.equal(fs.existsSync(absentMap), false);
});

test('confirmed toolkit_add writes only the configured temporary map', windowsOnly, async (t) => {
  const dir = tempDir(t, 'toolkit-map-mcp-add-');
  const bin = path.join(dir, 'bin');
  fs.mkdirSync(bin);
  const runtime = path.join(bin, 'node-runtime.cmd');
  writeFakeRuntime(runtime, '22.99.2');
  const mapFile = path.join(dir, 'map.json');

  const handler = createHandler(mapFile);
  const response = await handler.handle(callTool(1, 'toolkit_add', {
    tool: 'Node',
    path: runtime,
    note: 'manual registration',
    version: '22.99.2',
    prefer: true,
    confirm: true
  }));

  assert.equal(response.result.isError, false, JSON.stringify(response.result));
  const result = response.result.structuredContent;
  assert.equal(result.schemaVersion, 2);
  assert.equal(result.action, 'add');
  assert.equal(result.ok, true);
  assert.equal(result.status, 'ok');
  assertSchema(findTool('toolkit_add').outputSchema, result, 'toolkit_add execution');

  assert.equal(fs.existsSync(mapFile), true);
  const map = readMap(mapFile);
  assert.equal(map.schemaVersion, 2);
  const entry = map.tools.node;
  assert.ok(entry, 'node entry must be registered');
  const candidate = entry.candidates.find((item) => path.basename(item.path) === path.basename(runtime));
  assert.ok(candidate, JSON.stringify(entry.candidates));
  assert.equal(candidate.userNote, 'manual registration');
  assert.equal(path.basename(entry.preferredPath), path.basename(runtime));
});

test('real update against a missing map returns map_missing without creating it', windowsOnly, async (t) => {
  const dir = tempDir(t, 'toolkit-map-mcp-update-');
  const mapFile = path.join(dir, 'map.json');
  const handler = createHandler(mapFile);

  const response = await handler.handle(callTool(1, 'toolkit_update', { tool: 'node', confirm: true }));

  assert.equal(response.result.isError, true);
  const result = response.result.structuredContent;
  assert.equal(result.schemaVersion, 2);
  assert.equal(result.action, 'update');
  assert.equal(result.status, 'map_missing');
  assertSchema(findTool('toolkit_update').outputSchema, result, 'real update failure');
  assert.equal(fs.existsSync(mapFile), false);
});
