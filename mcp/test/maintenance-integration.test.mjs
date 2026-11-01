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
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), prefix)));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function createHandler(mapFile) {
  return createProtocolHandler({
    runMap,
    runMapConfig: {
      script: MAP_SCRIPT,
      powershell: POWERSHELL,
      mapFile
    },
    defaultProject: path.dirname(mapFile),
    serverInfo: { name: 'toolkit-map', title: 'toolkit-map', version: 'test' }
  });
}

function callTool(id, name, args = {}) {
  return {
    jsonrpc: '2.0',
    id,
    method: 'tools/call',
    params: { name, arguments: args }
  };
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

test('a junction into a shim directory cannot disguise a shim as a verified executable', windowsOnly, (t) => {
  const dir = tempDir(t, 'toolkit-map-junction-shim-');
  const shimDir = path.join(dir, 'mise', 'shims');
  fs.mkdirSync(shimDir, { recursive: true });
  const marker = path.join(dir, 'shim-executed.txt');
  fs.writeFileSync(path.join(shimDir, 'faketool.cmd'), `@echo off\r\necho executed>"${marker}"\r\necho faketool 1.2.3\r\n`, 'utf8');
  const alias = path.join(dir, 'alias');
  fs.symlinkSync(shimDir, alias, 'junction');
  const result = runAddInSandbox(dir, path.join(dir, 'map.json'), 'faketool', path.join(alias, 'faketool.cmd'), false, {
    PATH: '', MISE_DATA_DIR: path.join(dir, 'mise'), MISE_SHIMS_DIR: shimDir
  });
  assert.equal(result.code, 0, JSON.stringify(result));
  assert.equal(result.output.verification, 'skipped');
  assert.equal(fs.existsSync(marker), false, 'the linked shim must never execute');
});

test('legacy verified paths stop matching when a parent becomes a shim junction', windowsOnly, (t) => {
  const dir = tempDir(t, 'toolkit-map-legacy-junction-');
  const alias = path.join(dir, 'alias');
  fs.mkdirSync(alias);
  const marker = path.join(dir, 'shim-executed.txt');
  const runtime = path.join(alias, 'faketool.cmd');
  fs.writeFileSync(runtime, `@echo off\r\necho executed>>"${marker}"\r\necho faketool 1.2.3\r\n`, 'utf8');
  const mapFile = path.join(dir, 'map.json');
  const shimDir = path.join(dir, 'mise', 'shims');
  const extraEnv = { PATH: '', MISE_DATA_DIR: path.join(dir, 'mise'), MISE_SHIMS_DIR: shimDir };
  assert.equal(runAddInSandbox(dir, mapFile, 'faketool', runtime, false, extraEnv).output.verification, 'verified');
  fs.mkdirSync(path.dirname(shimDir), { recursive: true });
  fs.renameSync(alias, shimDir);
  fs.symlinkSync(shimDir, alias, 'junction');
  fs.rmSync(marker);
  const result = spawnSync(POWERSHELL, [
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', MAP_SCRIPT,
    'find', 'faketool', '-Project', dir, '-SkipScan', '-MapFile', mapFile, '-Json'
  ], { encoding: 'utf8', windowsHide: true, env: { ...process.env, ...extraEnv, USERPROFILE: dir, TOOLKIT_MAP: '' } });
  assert.ifError(result.error);
  const found = JSON.parse(result.stdout.replace(/^\uFEFF/, ''));
  assert.equal(found.ok, false, JSON.stringify(found));
  assert.equal(found.path, '');
  assert.equal(found.candidates[0].verification, 'skipped');
  assert.equal(fs.existsSync(marker), false);
  const updated = runAddInSandbox(dir, mapFile, 'faketool', runtime, false, extraEnv);
  assert.equal(updated.output.verification, 'skipped');
  assert.equal(fs.existsSync(marker), false, 're-registering must not execute the linked shim');
});

test('a junction cannot register or execute a tool inside a virtual environment', windowsOnly, (t) => {
  const dir = tempDir(t, 'toolkit-map-junction-env-');
  const inner = path.join(dir, '.venv', 'Scripts');
  fs.mkdirSync(inner, { recursive: true });
  const marker = path.join(dir, 'venv-executed.txt');
  fs.writeFileSync(path.join(inner, 'faketool.cmd'), `@echo off\r\necho executed>"${marker}"\r\necho faketool 1.2.3\r\n`, 'utf8');
  const alias = path.join(dir, 'alias');
  fs.symlinkSync(inner, alias, 'junction');
  const result = runAddInSandbox(dir, path.join(dir, 'map.json'), 'faketool', path.join(alias, 'faketool.cmd'));
  assert.notEqual(result.code, 0);
  assert.equal(result.output.status, 'environment_internal');
  assert.equal(fs.existsSync(marker), false);
  assert.equal(fs.existsSync(path.join(dir, 'map.json')), false);
});

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

test('a junction to an ordinary verified tool remains usable', windowsOnly, (t) => {
  const dir = tempDir(t, 'toolkit-map-junction-runtime-');
  const runtimeDir = path.join(dir, 'runtimes', '1.0');
  fs.mkdirSync(runtimeDir, { recursive: true });
  const marker = path.join(dir, 'runtime-executed.txt');
  fs.writeFileSync(path.join(runtimeDir, 'faketool.cmd'), `@echo off\r\necho executed>"${marker}"\r\necho faketool 1.2.3\r\n`, 'utf8');
  const alias = path.join(dir, 'current');
  fs.symlinkSync(runtimeDir, alias, 'junction');
  const result = runAddInSandbox(dir, path.join(dir, 'map.json'), 'faketool', path.join(alias, 'faketool.cmd'), false, {
    PATH: '', MISE_DATA_DIR: path.join(dir, 'mise'), MISE_SHIMS_DIR: path.join(dir, 'mise', 'shims')
  });
  assert.equal(result.code, 0, JSON.stringify(result));
  assert.equal(result.output.verification, 'verified');
  assert.equal(fs.existsSync(marker), true, 'an ordinary linked runtime should still be probed');
});

test('summary rendering is identical for ISO strings and deserialized DateTime values', windowsOnly, (t) => {
  const dir = tempDir(t, 'toolkit-map-summary-date-');
  const fixture = path.join(dir, 'summary-date.ps1');
  const core = path.join(REPO_ROOT, 'scripts', 'map-core.ps1').replace(/'/g, "''");
  const body = [
    ". '" + core + "'",
    '$when = Get-Date',
    "$stamp = $when.ToString('o')",
    '$textMap = @{ scannedAt = $stamp; updatedAt = $stamp; tools = @{} }',
    '$dateMap = @{ scannedAt = $when; updatedAt = $when; tools = @{} }',
    'if ((Get-MapMarkdownContent $textMap) -cne (Get-MapMarkdownContent $dateMap)) { exit 1 }',
    'exit 0'
  ].join('\r\n');
  fs.writeFileSync(fixture, `\uFEFF${body}`, 'utf8');
  const result = spawnSync(POWERSHELL, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', fixture], { encoding: 'utf8', windowsHide: true });
  assert.ifError(result.error);
  assert.equal(result.status, 0, `DateTime and ISO timestamps must render the same: ${result.stderr}`);
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

test('quickstart accepts a wrapper only when its native Node is separately verified', windowsOnly, (t) => {
  const dir = tempDir(t, 'toolkit-map-native-node-');
  const project = path.join(dir, 'project');
  fs.mkdirSync(project);
  const mapFile = path.join(dir, 'map.json');
  const wrapper = path.join(dir, 'runtime-wrapper.cmd');
  fs.writeFileSync(wrapper, `@echo off\r\n"${process.execPath}" %*\r\n`, 'utf8');
  assert.equal(runAddInSandbox(dir, mapFile, 'node', wrapper, true).code, 0);
  const quickstart = path.join(REPO_ROOT, 'scripts', 'quickstart.ps1');
  const invokeQuickstart = () => spawnSync(POWERSHELL, [
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', quickstart,
    '-Project', project, '-Mcp', '-WriteMcp'
  ], {
    encoding: 'utf8', windowsHide: true,
    env: {
      ...process.env,
      USERPROFILE: dir,
      APPDATA: dir,
      LOCALAPPDATA: dir,
      PATH: dir,
      MISE_DATA_DIR: path.join(dir, 'mise'),
      MISE_SHIMS_DIR: path.join(dir, 'mise-shims'),
      VOLTA_HOME: path.join(dir, 'volta'),
      TOOLCHAIN_ROOT: path.join(dir, 'warehouse'),
      TOOLKIT_MAP: mapFile,
      TOOLKIT_MAP_FILE: mapFile,
      TOOLKIT_MAP_SCRIPT: MAP_SCRIPT,
      TOOLKIT_MAP_POWERSHELL: POWERSHELL
    }
  });
  // A path printed by a wrapper is not trusted without its own verified map entry.
  const missingNative = invokeQuickstart();
  assert.ifError(missingNative.error);
  assert.equal(missingNative.status, 2);
  assert.equal(fs.existsSync(path.join(project, '.cursor', 'mcp.json')), false);
  assert.equal(runAddInSandbox(dir, mapFile, 'node', process.execPath).code, 0);
  const recorded = readMap(mapFile);
  const native = recorded.tools.node.candidates.find((item) => item.path.toLowerCase() === process.execPath.toLowerCase());
  assert.ok(native);
  const originalVersion = native.version;
  for (const [field, value] of [['verification', 'unverified'], ['version', '16.20.2']]) {
    const previous = native[field];
    native[field] = value;
    fs.writeFileSync(mapFile, JSON.stringify(recorded), 'utf8');
    const rejected = invokeQuickstart();
    assert.equal(rejected.status, 2, `must reject native Node with ${field}=${value}: ${rejected.stdout}`);
    assert.equal(fs.existsSync(path.join(project, '.cursor', 'mcp.json')), false);
    native[field] = previous;
  }
  assert.equal(native.version, originalVersion);
  fs.writeFileSync(mapFile, JSON.stringify(recorded), 'utf8');
  const result = invokeQuickstart();
  assert.ifError(result.error);
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  const config = JSON.parse(fs.readFileSync(path.join(project, '.cursor', 'mcp.json'), 'utf8').replace(/^\uFEFF/, ''));
  assert.equal(config.mcpServers['toolkit-map'].command.toLowerCase(), process.execPath.toLowerCase());
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
  const candidate = entry.candidates.find((item) => item.path.toLowerCase() === runtime.toLowerCase());
  assert.ok(candidate, JSON.stringify(entry.candidates));
  assert.equal(candidate.userNote, 'manual registration');
  assert.equal(entry.preferredPath.toLowerCase(), runtime.toLowerCase());
});

test('real add failures return a schema-valid frozen error result', windowsOnly, async (t) => {
  const dir = tempDir(t, 'toolkit-map-mcp-failure-');
  const mapFile = path.join(dir, 'map.json');
  const missing = path.join(dir, 'missing-runtime.exe');
  const handler = createHandler(mapFile);

  const response = await handler.handle(callTool(1, 'toolkit_add', {
    tool: 'node',
    path: missing,
    confirm: true
  }));

  assert.equal(response.result.isError, true);
  const result = response.result.structuredContent;
  assert.equal(result.schemaVersion, 2);
  assert.equal(result.action, 'add');
  assert.equal(result.ok, false);
  assert.equal(result.status, 'invalid_path');
  assert.equal(result.path, '');
  assertSchema(findTool('toolkit_add').outputSchema, result, 'real add failure');
  assert.equal(fs.existsSync(mapFile), false);
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

test('a relative TOOLKIT_MAP preview is pinned to the same temporary file on execution', windowsOnly, async (t) => {
  const dir = tempDir(t, 'toolkit-map-relative-target-');
  const runtime = path.join(dir, 'node-runtime.cmd');
  writeFakeRuntime(runtime, '22.99.2');
  const expectedMap = path.join(dir, 'chosen.json');
  const handler = createProtocolHandler({
    runMap,
    runMapConfig: {
      script: MAP_SCRIPT,
      powershell: POWERSHELL,
      cwd: dir,
      env: { ...process.env, USERPROFILE: dir, TOOLKIT_MAP: 'unused\\..\\chosen.json', TOOLKIT_MAP_FILE: '' }
    },
    defaultProject: dir
  });
  const args = { tool: 'node', path: runtime };
  const preview = await handler.handle(callTool(1, 'toolkit_add', args));
  assert.equal(preview.result.structuredContent.mapFile, expectedMap);
  assert.equal(fs.existsSync(expectedMap), false);
  const executed = await handler.handle(callTool(2, 'toolkit_add', { ...args, confirm: true }));
  assert.equal(executed.result.isError, false, JSON.stringify(executed.result));
  assert.equal(executed.result.structuredContent.mapFile, expectedMap);
  assert.ok(readMap(expectedMap).tools.node);
});

test('the preview names the map file that toolkit_add actually writes', windowsOnly, async (t) => {
  const dir = tempDir(t, 'toolkit-map-mcp-target-');
  const bin = path.join(dir, 'bin');
  fs.mkdirSync(bin);
  const runtime = path.join(bin, 'node-runtime.cmd');
  writeFakeRuntime(runtime, '22.99.2');
  const mapFile = path.join(dir, 'from-toolkit-map.json');

  const handler = createProtocolHandler({
    runMap,
    runMapConfig: {
      script: MAP_SCRIPT,
      powershell: POWERSHELL,
      // Deliberately no mapFile/-MapFile: map.ps1 resolves the target from the
      // inherited environment, which is the case the preview has to describe.
      env: { ...process.env, TOOLKIT_MAP: mapFile, TOOLKIT_MAP_FILE: '' }
    },
    defaultProject: dir,
    serverInfo: { name: 'toolkit-map', title: 'toolkit-map', version: 'test' }
  });

  const preview = await handler.handle(callTool(1, 'toolkit_add', {
    tool: 'node',
    path: runtime
  }));
  const planned = preview.result.structuredContent;
  assert.equal(planned.status, 'planned');
  assert.equal(planned.executed, false);
  assert.equal(planned.mapFileKnown, true);
  assert.equal(planned.mapFile, mapFile);
  assert.equal(planned.mapFileSource, 'environment');
  assert.equal(planned.preview.includes(mapFile), true);
  // The preview is still only a preview: nothing may exist yet.
  assert.equal(fs.existsSync(mapFile), false);

  const executed = await handler.handle(callTool(2, 'toolkit_add', {
    tool: 'node',
    path: runtime,
    confirm: true
  }));
  assert.equal(executed.result.isError, false, JSON.stringify(executed.result));
  assert.equal(executed.result.structuredContent.action, 'add');
  assert.equal(executed.result.structuredContent.ok, true);
  assert.equal(fs.existsSync(mapFile), true, 'must write exactly the previewed map file');
  assert.ok(readMap(mapFile).tools.node, 'node must be registered in the previewed map');
});
