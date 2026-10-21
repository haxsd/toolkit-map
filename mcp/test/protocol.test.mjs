import assert from 'node:assert/strict';
import test from 'node:test';

import { createProtocolHandler } from '../lib/protocol.mjs';
import { MapRunError } from '../lib/runner.mjs';

const SERVER_INFO = { name: 'toolkit-map', title: 'toolkit-map', version: '0.4.0' };

function createHarness(result = { ok: true, status: 'ok', path: 'C:\\tools\\node.exe' }) {
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

test('tools/list returns three read-only tools in both eras', async () => {
  const { handler } = createHarness();
  const legacy = await handler.handle(legacyRequest(1, 'tools/list'));
  const modern = await handler.handle(modernRequest(2, 'tools/list'));

  assert.deepEqual(legacy.result.tools.map((tool) => tool.name), [
    'toolkit_find',
    'toolkit_status',
    'toolkit_doctor'
  ]);
  for (const tool of legacy.result.tools) {
    assert.equal(tool.inputSchema.type, 'object');
    assert.equal(tool.annotations.readOnlyHint, true);
    assert.equal(tool.annotations.destructiveHint, false);
  }
  assert.equal(legacy.result.resultType, undefined);
  assert.equal(modern.result.resultType, 'complete');
});

test('toolkit_find forwards explicit project and version', async () => {
  const { handler, calls } = createHarness({
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
