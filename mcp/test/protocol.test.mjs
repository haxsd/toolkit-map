import assert from 'node:assert/strict';
import test from 'node:test';

import { createProtocolHandler } from '../lib/protocol.mjs';
import { MapRunError } from '../lib/runner.mjs';

const SERVER_INFO = { name: 'toolkit-map', title: 'toolkit-map', version: '0.4.0' };

function createHarness(result = {
  schemaVersion: 2,
  action: 'find',
  ok: true,
  status: 'ok',
  path: 'C:\\tools\\node.exe'
}) {
  const calls = [];
  const handler = createProtocolHandler({
    serverInfo: SERVER_INFO,
    defaultProject: 'D:\\default-project',
    runMap: async (action, options) => {
      calls.push({ action, options });
      return typeof result === 'function' ? result(action, options) : result;
    }
  });
  return { handler, calls };
}

function legacyRequest(id, method, params = {}) {
  return { jsonrpc: '2.0', id, method, params };
}

function modernRequest(id, method, params = {}) {
  return {
    jsonrpc: '2.0',
    id,
    method,
    params: {
      ...params,
      _meta: { 'io.modelcontextprotocol/protocolVersion': '2026-07-28' }
    }
  };
}

test('initialize negotiates a supported legacy version', async () => {
  const { handler } = createHarness();
  const response = await handler.handle(legacyRequest(1, 'initialize', {
    protocolVersion: '2025-06-18',
    capabilities: {},
    clientInfo: { name: 'test', version: '1.0.0' }
  }));

  assert.equal(response.result.protocolVersion, '2025-06-18');
  assert.deepEqual(response.result.capabilities, { tools: { listChanged: false } });
  assert.equal(response.result.serverInfo.name, 'toolkit-map');
  assert.equal(response.result.resultType, undefined);
  assert.match(response.result.instructions, /toolkit_find/);
});

test('initialize falls back to the latest supported legacy version', async () => {
  const { handler } = createHarness();
  const response = await handler.handle(legacyRequest(1, 'initialize', {
    protocolVersion: '1900-01-01'
  }));
  assert.equal(response.result.protocolVersion, '2025-11-25');
});

test('server/discover advertises the modern protocol', async () => {
  const { handler } = createHarness();
  const response = await handler.handle(modernRequest('discover-1', 'server/discover'));

  assert.equal(response.result.resultType, 'complete');
  assert.deepEqual(response.result.supportedVersions, ['2026-07-28']);
  assert.equal(response.result._meta['io.modelcontextprotocol/serverInfo'].name, 'toolkit-map');
  assert.equal(response.result._meta['io.modelcontextprotocol/serverInfo'].version, '0.4.0');
});

test('unsupported modern protocol versions return -32022', async () => {
  const { handler } = createHarness();
  const response = await handler.handle({
    jsonrpc: '2.0',
    id: 1,
    method: 'tools/list',
    params: { _meta: { 'io.modelcontextprotocol/protocolVersion': '2027-01-01' } }
  });

  assert.equal(response.error.code, -32022);
  assert.deepEqual(response.error.data.supported, ['2026-07-28']);
  assert.equal(response.error.data.requested, '2027-01-01');
});

test('tools/list keeps the read-only tools and adds maintenance tools in both eras', async () => {
  const { handler } = createHarness();
  const legacy = await handler.handle(legacyRequest(1, 'tools/list'));
  const modern = await handler.handle(modernRequest(2, 'tools/list'));

  assert.deepEqual(legacy.result.tools.map((tool) => tool.name), [
    'toolkit_find',
    'toolkit_status',
    'toolkit_doctor',
    'toolkit_scan',
    'toolkit_update',
    'toolkit_add'
  ]);
  for (const tool of legacy.result.tools) {
    assert.equal(tool.inputSchema.type, 'object');
    const maintenance = ['toolkit_scan', 'toolkit_update', 'toolkit_add'].includes(tool.name);
    assert.equal(tool.annotations.readOnlyHint, !maintenance);
    if (maintenance) {
      // These actions may launch arbitrary programs while probing versions.
      assert.equal(tool.annotations.openWorldHint, true);
      // scan/update can drop auto-discovered records; do not claim otherwise.
      assert.notEqual(tool.annotations.destructiveHint, false);
    } else {
      assert.equal(tool.annotations.destructiveHint, false);
      assert.equal(tool.annotations.openWorldHint, false);
    }
  }
  assert.equal(legacy.result.resultType, undefined);
  assert.equal(modern.result.resultType, 'complete');
});

test('toolkit_find forwards explicit project and version', async () => {
  const { handler, calls } = createHarness({
    schemaVersion: 2,
    action: 'find',
    ok: true,
    status: 'ok',
    path: 'C:\\tools\\node22\\node.exe',
    version: '22.23.2',
    verification: 'verified'
  });

  const response = await handler.handle(legacyRequest(3, 'tools/call', {
    name: 'toolkit_find',
    arguments: { tool: 'Node', project: 'D:\\work\\app', version: '>=18' }
  }));

  assert.deepEqual(calls, [{
    action: 'find',
    options: { tool: 'node', project: 'D:\\work\\app', version: '>=18' }
  }]);
  assert.equal(response.result.isError, false);
  assert.equal(response.result.structuredContent.path, 'C:\\tools\\node22\\node.exe');
  assert.equal(JSON.parse(response.result.content[0].text).version, '22.23.2');
});

test('toolkit_find falls back to the default project', async () => {
  const { handler, calls } = createHarness();
  await handler.handle(legacyRequest(4, 'tools/call', {
    name: 'toolkit_find',
    arguments: { tool: 'git' }
  }));

  assert.equal(calls[0].options.project, 'D:\\default-project');
  assert.equal(calls[0].options.version, '');
});

test('a map result with ok:false becomes a tool execution error', async () => {
  const { handler } = createHarness({
    schemaVersion: 2,
    action: 'find',
    ok: false,
    status: 'version_mismatch',
    tool: 'node',
    path: '',
    hint: '不会降级'
  });

  const response = await handler.handle(legacyRequest(5, 'tools/call', {
    name: 'toolkit_find',
    arguments: { tool: 'node' }
  }));

  assert.equal(response.result.isError, true);
  assert.equal(response.result.structuredContent.status, 'version_mismatch');
  assert.equal(response.result.structuredContent.path, '');
});

test('runner failures become actionable tool execution errors', async () => {
  const { handler } = createHarness(() => {
    throw new MapRunError('timeout', 'map.ps1 did not finish', {
      exitCode: null,
      stderr: 'timed out'
    });
  });

  const response = await handler.handle(modernRequest(6, 'tools/call', {
    name: 'toolkit_status',
    arguments: {}
  }));

  assert.equal(response.result.resultType, 'complete');
  assert.equal(response.result.isError, true);
  assert.equal(response.result.structuredContent.errorCode, 'timeout');
  assert.match(response.result.structuredContent.diagnostics.stderr, /timed out/);
});

test('unknown tools and invalid arguments are protocol errors', async () => {
  const { handler, calls } = createHarness();

  const unknown = await handler.handle(legacyRequest(7, 'tools/call', {
    name: 'toolkit_install',
    arguments: {}
  }));
  assert.equal(unknown.error.code, -32602);

  const missing = await handler.handle(legacyRequest(8, 'tools/call', {
    name: 'toolkit_find',
    arguments: {}
  }));
  assert.equal(missing.error.code, -32602);

  const pathLike = await handler.handle(legacyRequest(9, 'tools/call', {
    name: 'toolkit_find',
    arguments: { tool: 'C:\\nodejs\\node.exe' }
  }));
  assert.equal(pathLike.error.code, -32602);

  const extra = await handler.handle(legacyRequest(10, 'tools/call', {
    name: 'toolkit_find',
    arguments: { tool: 'node', allowUnverified: true }
  }));
  assert.equal(extra.error.code, -32602);

  assert.equal(calls.length, 0);
});

test('project and rulesFile must be absolute paths', async () => {
  const { handler, calls } = createHarness();

  const cases = [
    { name: 'toolkit_find', arguments: { tool: 'node', project: '' }, field: 'project' },
    { name: 'toolkit_find', arguments: { tool: 'node', project: 'work\\app' }, field: 'project' },
    { name: 'toolkit_find', arguments: { tool: 'node', project: 'work/app' }, field: 'project' },
    { name: 'toolkit_find', arguments: { tool: 'node', project: 'C:work' }, field: 'project' },
    { name: 'toolkit_find', arguments: { tool: 'node', project: 'C:' }, field: 'project' },
    { name: 'toolkit_find', arguments: { tool: 'node', project: '\\rooted' }, field: 'project' },
    { name: 'toolkit_find', arguments: { tool: 'node', project: '\\\\?\\C:\\work' }, field: 'project' },
    { name: 'toolkit_find', arguments: { tool: 'node', project: '\\\\.\\pipe\\work' }, field: 'project' },
    // PowerShell's GetFullPath rejects UNC paths without a share, so these are
    // not deterministic absolute paths even though path.win32 accepts them.
    { name: 'toolkit_find', arguments: { tool: 'node', project: '\\\\server' }, field: 'project' },
    { name: 'toolkit_find', arguments: { tool: 'node', project: '\\\\server\\' }, field: 'project' },
    { name: 'toolkit_find', arguments: { tool: 'node', project: '\\\\' }, field: 'project' },
    { name: 'toolkit_doctor', arguments: { project: 'C:\\work', rulesFile: '' }, field: 'rulesFile' },
    { name: 'toolkit_doctor', arguments: { rulesFile: 'AGENTS.md' }, field: 'rulesFile' },
    { name: 'toolkit_doctor', arguments: { rulesFile: 'C:AGENTS.md' }, field: 'rulesFile' },
    { name: 'toolkit_doctor', arguments: { rulesFile: '\\\\?\\C:\\AGENTS.md' }, field: 'rulesFile' },
    { name: 'toolkit_doctor', arguments: { rulesFile: '\\\\server' }, field: 'rulesFile' }
  ];

  for (const item of cases) {
    const response = await handler.handle(legacyRequest(1, 'tools/call', item));
    assert.equal(response.error?.code, -32602, `${item.name} ${item.field}: ${JSON.stringify(item.arguments)}`);
    assert.match(response.error.message, new RegExp(`${item.field} must be an absolute path`));
  }

  assert.equal(calls.length, 0);
});

test('absolute project paths in Windows, UNC and POSIX form are forwarded', async () => {
  const { handler, calls } = createHarness();
  const projects = ['C:\\work\\app', '\\\\server\\share\\app', '/home/user/app'];

  for (const project of projects) {
    const response = await handler.handle(legacyRequest(1, 'tools/call', {
      name: 'toolkit_find',
      arguments: { tool: 'node', project }
    }));
    assert.equal(response.error, undefined, project);
  }

  const doctor = await handler.handle(legacyRequest(2, 'tools/call', {
    name: 'toolkit_doctor',
    arguments: { project: '/home/user/app', rulesFile: '/home/user/AGENTS.md' }
  }));
  assert.equal(doctor.error, undefined);

  assert.deepEqual(calls.map((call) => call.options.project), [...projects, '/home/user/app']);
  assert.equal(calls[calls.length - 1].options.rulesFile, '/home/user/AGENTS.md');
});

test('toolkit_doctor falls back to the default project when project is omitted', async () => {
  const { handler, calls } = createHarness();

  await handler.handle(legacyRequest(1, 'tools/call', {
    name: 'toolkit_doctor',
    arguments: {}
  }));

  assert.equal(calls[0].options.project, 'D:\\default-project');
  assert.equal(calls[0].options.rulesFile, '');
});

test('unknown methods return -32601 and notifications get no response', async () => {
  const { handler } = createHarness();

  const unknown = await handler.handle(legacyRequest(11, 'resources/list'));
  assert.equal(unknown.error.code, -32601);

  const notification = await handler.handle({
    jsonrpc: '2.0',
    method: 'notifications/initialized'
  });
  assert.equal(notification, null);
});

test('ping works in both eras', async () => {
  const { handler } = createHarness();
  const legacy = await handler.handle(legacyRequest(12, 'ping'));
  const modern = await handler.handle(modernRequest(13, 'ping'));

  assert.deepEqual(legacy.result, {});
  assert.equal(modern.result.resultType, 'complete');
});

test('invalid envelopes are rejected', async () => {
  const { handler } = createHarness();

  const batch = await handler.handle([{ jsonrpc: '2.0', id: 1, method: 'ping' }]);
  assert.equal(batch.error.code, -32600);

  const wrongVersion = await handler.handle({ jsonrpc: '1.0', id: 2, method: 'ping' });
  assert.equal(wrongVersion.error.code, -32600);

  const noMethod = await handler.handle({ jsonrpc: '2.0', id: 3 });
  assert.equal(noMethod.error.code, -32600);
});
