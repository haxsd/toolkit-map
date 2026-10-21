import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { runMap } from '../lib/runner.mjs';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const MAP_SCRIPT = path.join(REPO_ROOT, 'scripts', 'map.ps1');
const POWERSHELL = 'powershell.exe';
const windowsOnly = { skip: process.platform !== 'win32' };

function writeFakeNode(file, version) {
  fs.writeFileSync(file, `@echo off\r\necho v${version}\r\n`, 'utf8');
}

function realPath(value) {
  return fs.realpathSync.native(value);
}

function mapAdd(mapFile, tool, toolPath) {
  const output = execFileSync(POWERSHELL, [
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', MAP_SCRIPT,
    'add', tool, '-Path', toolPath,
    '-MapFile', mapFile,
    '-Json'
  ], { encoding: 'utf8' });

  return JSON.parse(output.replace(/^\uFEFF/, ''));
}

test('real map.ps1 selects the version required by the project', windowsOnly, (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'toolkit-map-integration-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));

  const bin = path.join(dir, 'bin');
  fs.mkdirSync(bin);
  const node16 = path.join(bin, 'runtime-a.cmd');
  const node22 = path.join(bin, 'runtime-b.cmd');
  writeFakeNode(node16, '16.99.1');
  writeFakeNode(node22, '22.99.2');

  const mapFile = path.join(dir, 'map.json');
  const added16 = mapAdd(mapFile, 'node', node16);
  const added22 = mapAdd(mapFile, 'node', node22);
  assert.equal(added16.ok, true);
  assert.equal(added22.ok, true);

  const project = path.join(dir, 'project');
  fs.mkdirSync(project);
  fs.writeFileSync(path.join(project, '.nvmrc'), '22.99.2\n', 'utf8');

  return runMap('find', { tool: 'node', project, skipScan: true }, {
    script: MAP_SCRIPT,
    mapFile,
    powershell: POWERSHELL
  }).then((result) => {
    assert.equal(result.ok, true);
    assert.equal(result.status, 'ok');
    assert.equal(result.version, '22.99.2');
    assert.equal(realPath(result.path), realPath(node22));
    assert.equal(result.verification, 'verified');
    assert.equal(result.requirement.version, '22.99.2');
    assert.equal(result.requirement.scope, 'project');
  });
});

test('real map.ps1 returns version_mismatch without falling back', windowsOnly, (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'toolkit-map-integration-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));

  const bin = path.join(dir, 'bin');
  fs.mkdirSync(bin);
  const node16 = path.join(bin, 'runtime-a.cmd');
  writeFakeNode(node16, '16.99.1');

  const mapFile = path.join(dir, 'map.json');
  assert.equal(mapAdd(mapFile, 'node', node16).ok, true);

  const project = path.join(dir, 'project');
  fs.mkdirSync(project);
  fs.writeFileSync(path.join(project, 'package.json'), JSON.stringify({
    engines: { node: '>=18' }
  }), 'utf8');

  return runMap('find', { tool: 'node', project, skipScan: true }, {
    script: MAP_SCRIPT,
    mapFile,
    powershell: POWERSHELL
  }).then((result) => {
    assert.equal(result.ok, false);
    assert.equal(result.status, 'version_mismatch');
    assert.equal(result.path, '');
    assert.equal(result.requirement.version, '>=18');
  });
});

test('MCP server end to end selects the project version and exits cleanly', windowsOnly, async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'toolkit-map-e2e-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));

  const bin = path.join(dir, 'bin');
  fs.mkdirSync(bin);
  const node16 = path.join(bin, 'runtime-a.cmd');
  const node22 = path.join(bin, 'runtime-b.cmd');
  writeFakeNode(node16, '16.99.1');
  writeFakeNode(node22, '22.99.2');

  const mapFile = path.join(dir, 'map.json');
  assert.equal(mapAdd(mapFile, 'node', node16).ok, true);
  assert.equal(mapAdd(mapFile, 'node', node22).ok, true);

  const project = path.join(dir, 'project');
  fs.mkdirSync(project);
  fs.writeFileSync(path.join(project, '.nvmrc'), '22.99.2\n', 'utf8');

  const child = spawn(process.execPath, [path.join(REPO_ROOT, 'mcp', 'server.mjs')], {
    env: { ...process.env, TOOLKIT_MAP_FILE: mapFile, TOOLKIT_MAP_PROJECT: project },
    stdio: ['pipe', 'pipe', 'pipe']
  });
  t.after(() => {
    try { child.kill(); } catch { /* already exited */ }
  });
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  let buffer = '';
  let stderr = '';
  child.stderr.on('data', (chunk) => { stderr += chunk; });

  const resultPromise = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`MCP response timeout. stderr: ${stderr}`)), 30000);
    child.stdout.on('data', (chunk) => {
      buffer += chunk;
      let newline;
      while ((newline = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        if (!line.trim()) continue;
        const message = JSON.parse(line);
        if (message.id === 2) {
          clearTimeout(timer);
          resolve(message);
        }
      }
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      reject(new Error(`server exited early with ${code}: ${stderr}`));
    });
  });

  child.stdin.write(`${JSON.stringify({
    jsonrpc: '2.0',
    id: 1,
    method: 'initialize',
    params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '1' } }
  })}\n`);
  child.stdin.write(`${JSON.stringify({
    jsonrpc: '2.0',
    id: 2,
    method: 'tools/call',
    params: { name: 'toolkit_find', arguments: { tool: 'node', project } }
  })}\n`);

  const message = await resultPromise;
  assert.equal(message.result.isError, false);
  assert.equal(realPath(message.result.structuredContent.path), realPath(node22));
  assert.equal(message.result.structuredContent.version, '22.99.2');

  const exitCode = await new Promise((resolve) => {
    child.on('close', resolve);
    child.stdin.end();
  });
  assert.equal(exitCode, 0);
});
