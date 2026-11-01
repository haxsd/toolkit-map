import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { createProtocolHandler } from '../lib/protocol.mjs';
import { buildInvocation, MapRunError } from '../lib/runner.mjs';
import { findTool, TOOLS } from '../lib/tools.mjs';
import { validate } from './schema-validator.mjs';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

const SERVER_INFO = { name: 'toolkit-map', title: 'toolkit-map', version: '0.4.0' };
const READ_ONLY_TOOLS = ['toolkit_find', 'toolkit_status', 'toolkit_doctor'];
const MAINTENANCE_TOOLS = ['toolkit_scan', 'toolkit_update', 'toolkit_add'];

function legacyRequest(id, method, params = {}) {
  return { jsonrpc: '2.0', id, method, params };
}

function callTool(id, name, args = {}) {
  return legacyRequest(id, 'tools/call', { name, arguments: args });
}

function createHarness(result = { schemaVersion: 2, action: 'status', ok: true, status: 'ok' }) {
  const calls = [];
  const handler = createProtocolHandler({
    serverInfo: SERVER_INFO,
    defaultProject: 'D:\\default-project',
    runMap: async (action, callOptions) => {
      calls.push({ action, options: callOptions });
      return typeof result === 'function' ? result(action, callOptions) : result;
    }
  });
  return { handler, calls };
}

function assertSchema(schema, value, label) {
  assert.deepEqual(validate(schema, value), [], `${label}: ${JSON.stringify(validate(schema, value))}`);
}

test('MCP result schema keeps the frozen envelope and leaves status open for future values', () => {
  const schema = findTool('toolkit_find').outputSchema;

  assert.deepEqual(schema.required.slice().sort(), ['action', 'ok', 'schemaVersion', 'status']);
  assert.equal(schema.properties.schemaVersion.const, 2);
  assert.equal(schema.properties.invocation.oneOf.some((branch) => branch.type === 'null'), true);
  // The schema must not close over today's 30 values: a future minor release may
  // add a status, and a strict client still has to be able to render the result.
  assert.equal(schema.properties.status.type, 'string');
  assert.equal(schema.properties.status.enum, undefined);
  assert.equal(typeof schema.properties.status.pattern, 'string');
  // The known set used for failure classification still has to track the repository.

  assertSchema(schema, {
    schemaVersion: 2,
    action: 'find',
    ok: false,
    status: 'not_found',
    tool: 'node',
    path: '',
    invocation: null
  }, 'toolkit_find not_found');

  assertSchema(schema, {
    schemaVersion: 2,
    action: 'find',
    ok: false,
    status: 'version_mismatch',
    tool: 'node',
    path: '',
    invocation: null
  }, 'toolkit_find version_mismatch');

  assertSchema(schema, {
    schemaVersion: 2,
    action: 'find',
    ok: false,
    status: 'future_failure_status',
    tool: 'node',
    path: '',
    invocation: null
  }, 'toolkit_find future failure status');

  assert.notDeepEqual(validate(schema, { schemaVersion: 2, ok: false, status: 'not_found' }), []);
});

test('tools/list keeps the read-only tools and adds maintenance tools', async () => {
  const { handler } = createHarness();
  const response = await handler.handle(legacyRequest(1, 'tools/list'));

  assert.deepEqual(response.result.tools.map((tool) => tool.name), [...READ_ONLY_TOOLS, ...MAINTENANCE_TOOLS]);

  const byName = new Map(response.result.tools.map((tool) => [tool.name, tool]));
  for (const name of READ_ONLY_TOOLS) {
    const annotations = byName.get(name).annotations;
    assert.equal(annotations.readOnlyHint, true, name);
    assert.equal(annotations.destructiveHint, false, name);
    assert.equal(annotations.openWorldHint, false, name);
  }
  for (const name of MAINTENANCE_TOOLS) {
    const annotations = byName.get(name).annotations;
    assert.equal(annotations.readOnlyHint, false, name);
    assert.equal(byName.get(name).inputSchema.properties.confirm.type, 'boolean', name);
    // Probe and scan work can launch arbitrary programs found on this machine.
    assert.equal(annotations.openWorldHint, true, name);
    // scan/update can drop auto-discovered records, so never claim they are
    // non-destructive by default. Omitting it leaves the spec's safe default.
    assert.notEqual(annotations.destructiveHint, false, name);
  }

  assert.equal(byName.get('toolkit_scan').inputSchema.required, undefined);
  assert.deepEqual(byName.get('toolkit_update').inputSchema.required, undefined);
  assert.deepEqual(byName.get('toolkit_add').inputSchema.required, ['tool', 'path']);
});

test('toolkit_scan previews without calling runMap', async () => {
  const { handler, calls } = createHarness();
  const response = await handler.handle(callTool(1, 'toolkit_scan'));

  assert.equal(calls.length, 0);
  assert.equal(response.result.isError, false);

  const result = response.result.structuredContent;
  assert.equal(result.schemaVersion, 2);
  assert.equal(result.action, 'scan');
  assert.equal(result.ok, true);
  assert.equal(result.status, 'planned');
  assert.equal(result.executed, false);
  assert.equal(result.confirmRequired, true);
  assert.match(result.preview, /scan/);
  assertSchema(findTool('toolkit_scan').outputSchema, result, 'toolkit_scan preview');
});

test('maintenance preview names the map file the confirmed action will use', async () => {
  const savedFile = process.env.TOOLKIT_MAP_FILE;
  const savedMap = process.env.TOOLKIT_MAP;
  try {
    process.env.TOOLKIT_MAP_FILE = 'D:\\maps\\explicit.json';
    delete process.env.TOOLKIT_MAP;
    let result = (await createHarness().handler.handle(callTool(1, 'toolkit_scan'))).result.structuredContent;
    assert.equal(result.preview.includes('-MapFile "D:\\\\maps\\\\explicit.json"'), true, result.preview);

    delete process.env.TOOLKIT_MAP_FILE;
    process.env.TOOLKIT_MAP = 'maps\\custom.json';
    result = (await createHarness().handler.handle(callTool(1, 'toolkit_scan'))).result.structuredContent;
    assert.equal(result.preview.includes('TOOLKIT_MAP="maps\\\\custom.json"'), true, result.preview);
    assert.match(result.preview, /resolved by map\.ps1/);
  } finally {
    if (savedFile === undefined) delete process.env.TOOLKIT_MAP_FILE;
    else process.env.TOOLKIT_MAP_FILE = savedFile;
    if (savedMap === undefined) delete process.env.TOOLKIT_MAP;
    else process.env.TOOLKIT_MAP = savedMap;
  }
});

test('a map result without the frozen envelope is not reported as success', async () => {
  const invalid = [
    { schemaVersion: 2, action: 'find', ok: false, status: 'not_found' },
    { schemaVersion: 2, action: 'scan', ok: true, status: 'future_success' },
    { schemaVersion: 2, action: 'scan', ok: 'yes', status: 'ok' }
  ];
  for (const result of invalid) {
    const response = await createHarness(result).handler.handle(callTool(1, 'toolkit_scan', { confirm: true }));
    assert.equal(response.result.isError, true, JSON.stringify(result));
    assert.equal(response.result.structuredContent.errorCode, 'invalid_output', JSON.stringify(result));
  }

  // Unknown failure statuses still pass through with their explanation.
  const response = await createHarness({
    schemaVersion: 2,
    action: 'scan',
    ok: false,
    status: 'future_failure'
  }).handler.handle(callTool(1, 'toolkit_scan', { confirm: true }));
  assert.equal(response.result.isError, true);
  assert.equal(response.result.structuredContent.status, 'future_failure');
  assert.equal(response.result.structuredContent.errorCode, undefined);
});

test('maintenance annotations keep the conservative destructive and open-world defaults', () => {
  for (const name of MAINTENANCE_TOOLS) {
    const annotations = findTool(name).annotations;
    // Probing can launch arbitrary programs found on this machine.
    assert.equal(annotations.openWorldHint, true, name);
    // scan/update may drop auto-discovered records, so the hint is omitted and
    // the MCP default (destructive) applies instead of claiming false.
    assert.equal('destructiveHint' in annotations, false, name);
    assert.equal(annotations.readOnlyHint, false, name);
  }
});

test('toolkit_add describes version as a probe hint, not a request to skip probing', () => {
  const add = findTool('toolkit_add');
  const version = add.inputSchema.properties.version.description;

  assert.match(version, /hint/i);
  assert.match(version, /does not disable probing/i);
  assert.match(add.description, /version is a probe hint/i);
});

test('toolkit_update previews by default and executes only with confirm:true', async () => {
  const preview = createHarness();
  let response = await preview.handler.handle(callTool(1, 'toolkit_update', { tool: 'Node' }));

  assert.equal(preview.calls.length, 0);
  assert.equal(response.result.structuredContent.status, 'planned');
  assert.equal(response.result.structuredContent.tool, 'node');

  response = await preview.handler.handle(callTool(2, 'toolkit_update', { tool: 'node', confirm: false }));
  assert.equal(preview.calls.length, 0);
  assert.equal(response.result.structuredContent.status, 'planned');

  const execute = createHarness({
    schemaVersion: 2,
    action: 'update',
    ok: true,
    status: 'ok',
    tools: ['node']
  });

  response = await execute.handler.handle(callTool(3, 'toolkit_update', { tool: 'Node', confirm: true }));
  assert.deepEqual(execute.calls, [{
    action: 'update',
    options: { tool: 'node' }
  }]);
  assert.equal(response.result.isError, false);
});

test('toolkit_update omits the optional tool when it is not supplied', async () => {
  const execute = createHarness({
    schemaVersion: 2,
    action: 'update',
    ok: true,
    status: 'ok',
    tools: ['node', 'python']
  });

  const response = await execute.handler.handle(callTool(1, 'toolkit_update', { confirm: true }));
  assert.deepEqual(execute.calls, [{
    action: 'update',
    options: { tool: '' }
  }]);
  assert.equal(response.result.isError, false);
});

test('toolkit_add previews and forwards only allowlisted arguments on confirm', async () => {
  const preview = createHarness();
  const response = await preview.handler.handle(callTool(1, 'toolkit_add', {
    tool: 'Node',
    path: 'C:\\tools\\node.exe',
    note: 'manual note',
    version: '22.1.0',
    prefer: true
  }));

  assert.equal(preview.calls.length, 0);
  assert.equal(response.result.structuredContent.status, 'planned');
  assert.equal(response.result.structuredContent.tool, 'node');
  assert.equal(response.result.structuredContent.path, 'C:\\tools\\node.exe');
  assert.equal(response.result.structuredContent.prefer, true);
  assert.match(response.result.structuredContent.preview, /-Version "22\.1\.0"/);
  assert.match(response.result.structuredContent.preview, /-Note "manual note"/);
  assert.match(response.result.structuredContent.preview, /-Prefer/);
  assertSchema(findTool('toolkit_add').outputSchema, response.result.structuredContent, 'toolkit_add preview');

  const execute = createHarness({
    schemaVersion: 2,
    action: 'add',
    ok: true,
    status: 'ok',
    tool: 'node',
    path: 'C:\\tools\\node.exe'
  });

  const executed = await execute.handler.handle(callTool(2, 'toolkit_add', {
    tool: 'Node',
    path: 'C:\\tools\\node.exe',
    note: 'manual note',
    version: '22.1.0',
    prefer: true,
    confirm: true
  }));

  assert.deepEqual(execute.calls, [{
    action: 'add',
    options: {
      tool: 'node',
      path: 'C:\\tools\\node.exe',
      note: 'manual note',
      version: '22.1.0',
      prefer: true
    }
  }]);
  assert.equal(executed.result.isError, false);
});

test('toolkit_add never forwards an omitted prefer as a truthy flag', async () => {
  const execute = createHarness({
    schemaVersion: 2,
    action: 'add',
    ok: true,
    status: 'ok',
    tool: 'node',
    path: 'C:\\tools\\node.exe'
  });

  await execute.handler.handle(callTool(1, 'toolkit_add', {
    tool: 'node',
    path: 'C:\\tools\\node.exe',
    confirm: true
  }));

  assert.deepEqual(execute.calls[0].options, {
    tool: 'node',
    path: 'C:\\tools\\node.exe',
    note: '',
    version: '',
    prefer: false
  });
});

test('maintenance arguments are strictly typed and reject client map overrides', async () => {
  const { handler, calls } = createHarness();

  const cases = [
    { name: 'toolkit_scan', args: { confirm: 'true' }, message: /confirm must be a boolean/ },
    { name: 'toolkit_scan', args: { confirm: null }, message: /confirm must be a boolean/ },
    { name: 'toolkit_update', args: { tool: 'C:\\nodejs\\node.exe', confirm: true }, message: /tool must be a command name/ },
    { name: 'toolkit_update', args: { tool: 'node; whoami', confirm: true }, message: /tool must be a command name/ },
    { name: 'toolkit_add', args: { tool: 'node', path: 'C:\\node.exe', prefer: 'yes', confirm: true }, message: /prefer must be a boolean/ },
    { name: 'toolkit_add', args: { tool: 'node', path: 'C:\\node.exe', prefer: null, confirm: true }, message: /prefer must be a boolean/ },
    { name: 'toolkit_add', args: { tool: 'node', path: 'C:\\node.exe', mapFile: 'C:\\evil.json', confirm: true }, message: /Unknown argument for toolkit_add: mapFile/ },
    { name: 'toolkit_scan', args: { mapFile: 'C:\\evil.json', confirm: true }, message: /Unknown argument for toolkit_scan: mapFile/ },
    { name: 'toolkit_update', args: { mapFile: 'C:\\evil.json', confirm: true }, message: /Unknown argument for toolkit_update: mapFile/ },
    { name: 'toolkit_add', args: { path: 'C:\\node.exe', confirm: true }, message: /requires a tool name/ },
    { name: 'toolkit_add', args: { tool: 'node', confirm: true }, message: /requires a path/ }
  ];

  for (const item of cases) {
    const response = await handler.handle(callTool(1, item.name, item.args));
    assert.equal(response.error?.code, -32602, `${item.name}: ${JSON.stringify(item.args)}`);
    assert.match(response.error.message, item.message, `${item.name}: ${JSON.stringify(item.args)}`);
  }

  assert.equal(calls.length, 0);
});

test('toolkit_find not_found result keeps invocation:null and its frozen status', async () => {
  const payload = {
    schemaVersion: 2,
    action: 'find',
    ok: false,
    status: 'not_found',
    tool: 'node',
    path: '',
    invocation: null,
    hint: 'not found in this search scope'
  };
  const { handler } = createHarness(payload);
  const response = await handler.handle(callTool(1, 'toolkit_find', { tool: 'node' }));

  assert.equal(response.result.isError, true);
  assert.equal(response.result.structuredContent.invocation, null);
  assert.equal(response.result.structuredContent.status, 'not_found');
  assertSchema(findTool('toolkit_find').outputSchema, response.result.structuredContent, 'toolkit_find not_found forwarded');
});

test('runner failures produce a frozen-contract payload with the attempted action', async () => {
  const { handler } = createHarness(() => {
    throw new MapRunError('timeout', 'map.ps1 did not finish', {
      exitCode: null,
      stderr: 'timed out'
    });
  });

  const response = await handler.handle(callTool(1, 'toolkit_scan', { confirm: true }));
  assert.equal(response.result.isError, true);

  const result = response.result.structuredContent;
  assert.equal(result.schemaVersion, 2);
  assert.equal(result.action, 'scan');
  assert.equal(result.ok, false);
  assert.equal(result.status, 'operation_failed');
  assert.equal(result.errorCode, 'timeout');
  assertSchema(findTool('toolkit_scan').outputSchema, result, 'runner failure');
});

test('maintenance runner invocations keep an argument array and the map contract order', () => {
  const config = {
    script: 'C:\\repo\\scripts\\map.ps1',
    powershell: 'powershell.exe',
    mapFile: 'C:\\temp\\map.json'
  };
  const prefix = [
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', config.script
  ];
  const suffix = ['-MapFile', config.mapFile, '-Json'];

  assert.deepEqual(buildInvocation('scan', {}, config).args, [...prefix, 'scan', ...suffix]);
  assert.deepEqual(buildInvocation('update', {}, config).args, [...prefix, 'update', ...suffix]);
  assert.deepEqual(buildInvocation('update', { tool: 'node' }, config).args, [...prefix, 'update', 'node', ...suffix]);

  const add = buildInvocation('add', {
    tool: 'node',
    path: 'C:\\Program Files\\nodejs\\node.exe',
    version: '22.1.0',
    note: 'manual note with spaces',
    prefer: true
  }, config);
  assert.deepEqual(add.args, [
    ...prefix,
    'add', 'node',
    '-Path', 'C:\\Program Files\\nodejs\\node.exe',
    '-Version', '22.1.0',
    '-Note', 'manual note with spaces',
    '-Prefer',
    ...suffix
  ]);
  assert.equal(add.args.includes('C:\\Program Files\\nodejs\\node.exe'), true);

  const addNoPrefer = buildInvocation('add', {
    tool: 'node',
    path: 'C:\\node.exe',
    prefer: false
  }, config);
  assert.equal(addNoPrefer.args.includes('-Prefer'), false);
});

test('maintenance runner rejects shell-shaped tool names', () => {
  const config = {
    script: 'C:\\repo\\scripts\\map.ps1',
    powershell: 'powershell.exe'
  };

  assert.throws(
    () => buildInvocation('add', { tool: 'node & calc', path: 'C:\\node.exe' }, config),
    /tool must be a command name/
  );
  assert.throws(
    () => buildInvocation('update', { tool: 'node|whoami' }, config),
    /tool must be a command name/
  );
});
