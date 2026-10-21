import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { runMap } from '../lib/runner.mjs';
import { validate } from './schema-validator.mjs';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const MAP_SCRIPT = path.join(REPO_ROOT, 'scripts', 'map.ps1');
const POWERSHELL = 'powershell.exe';
const windowsOnly = { skip: process.platform !== 'win32' };

function readJson(relativePath) {
  return JSON.parse(fs.readFileSync(path.join(REPO_ROOT, relativePath), 'utf8').replace(/^\uFEFF/, ''));
}

const STATUSES = readJson('schemas/statuses.json');
const RESULT_SCHEMA = readJson('schemas/result-v2.schema.json');
const MAP_SCHEMA = readJson('schemas/map-v2.schema.json');

function assertValid(schema, value, label) {
  const errors = validate(schema, value);
  assert.deepEqual(errors, [], `${label}: ${JSON.stringify(errors)}`);
}

function writeFakeNode(file, version) {
  fs.writeFileSync(file, `@echo off\r\necho v${version}\r\n`, 'utf8');
}

function mapCli(mapFile, args) {
  const result = spawnSync(POWERSHELL, [
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', MAP_SCRIPT,
    ...args,
    '-MapFile', mapFile,
    '-Json'
  ], { encoding: 'utf8' });

  const stdout = (result.stdout || '').replace(/^\uFEFF/, '').trim();
  assert.ok(stdout, `map.ps1 returned no JSON for ${args.join(' ')}: ${result.stderr}`);
  return JSON.parse(stdout);
}

test('status enum and schemas are frozen consistently', () => {
  const names = Object.keys(STATUSES.statuses).sort();
  const enumValues = [...RESULT_SCHEMA.$defs.status.enum].sort();
  assert.deepEqual(enumValues, names);
  assert.equal(STATUSES.schemaVersion, 2);
  assert.equal(RESULT_SCHEMA.$defs.status.enum.length, 30);
  assert.equal(RESULT_SCHEMA.properties.schemaVersion.const, 2);
  assert.equal(MAP_SCHEMA.properties.schemaVersion.const, 2);
  assert.match(RESULT_SCHEMA.$id, /result-v2\.schema\.json$/);
  assert.match(MAP_SCHEMA.$id, /map-v2\.schema\.json$/);
});

test('VERSION and mcp package stay in sync at 1.x', () => {
  const version = fs.readFileSync(path.join(REPO_ROOT, 'VERSION'), 'utf8').trim();
  const pkg = readJson('mcp/package.json');
  assert.match(version, /^1\.\d+\.\d+$/);
  assert.equal(pkg.version, version);
});

test('real map outputs conform to the frozen result and map schemas', windowsOnly, (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'toolkit-map-contract-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));

  const bin = path.join(dir, 'bin');
  fs.mkdirSync(bin);
  const runtime = path.join(bin, 'runtime-a.cmd');
  writeFakeNode(runtime, '22.23.2');
  const mapFile = path.join(dir, 'map.json');
  const project = path.join(dir, 'project');
  fs.mkdirSync(project);
  fs.writeFileSync(path.join(project, '.nvmrc'), '22\n', 'utf8');

  const help = mapCli(mapFile, ['help']);
  assertValid(RESULT_SCHEMA, help, 'help');
  assert.equal(help.status, 'ok');

  const add = mapCli(mapFile, ['add', 'node', '-Path', runtime, '-Version', '22.23.2']);
  assertValid(RESULT_SCHEMA, add, 'add');
  assert.equal(add.ok, true);

  const map = JSON.parse(fs.readFileSync(mapFile, 'utf8').replace(/^\uFEFF/, ''));
  assertValid(MAP_SCHEMA, map, 'map.json');

  return Promise.all([
    runMap('find', { tool: 'node', project }, {
      script: MAP_SCRIPT,
      mapFile,
      powershell: POWERSHELL
    }),
    runMap('status', {}, {
      script: MAP_SCRIPT,
      mapFile,
      powershell: POWERSHELL
    }),
    runMap('doctor', { project }, {
      script: MAP_SCRIPT,
      mapFile,
      powershell: POWERSHELL
    })
  ]).then(([find, status, doctor]) => {
    assertValid(RESULT_SCHEMA, find, 'find');
    assertValid(RESULT_SCHEMA, status, 'status');
    assertValid(RESULT_SCHEMA, doctor, 'doctor');
    assert.equal(find.ok, true);
    assert.equal(find.requirement.version, '22');
    assert.equal(status.status, 'ok');
    assert.equal(doctor.status, 'attention_required');

    fs.writeFileSync(path.join(project, '.nvmrc'), '24\n', 'utf8');
    return runMap('find', { tool: 'node', project }, {
      script: MAP_SCRIPT,
      mapFile,
      powershell: POWERSHELL
    });
  }).then((mismatch) => {
    assertValid(RESULT_SCHEMA, mismatch, 'find version_mismatch');
    assert.equal(mismatch.ok, false);
    assert.equal(mismatch.status, 'version_mismatch');
    assert.equal(mismatch.path, '');

    const planned = mapCli(mapFile, ['setup', '-Project', project, '-WhatIf']);
    assertValid(RESULT_SCHEMA, planned, 'setup -WhatIf');
    assert.equal(planned.status, 'planned');
  });
});
