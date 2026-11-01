import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { createProtocolHandler } from '../lib/protocol.mjs';
import { buildInvocation, MapRunError } from '../lib/runner.mjs';
import { findTool, STATUS_VALUES, TOOLS } from '../lib/tools.mjs';
import { validate } from './schema-validator.mjs';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const STATUSES = JSON.parse(fs.readFileSync(path.join(REPO_ROOT, 'schemas', 'statuses.json'), 'utf8').replace(/^\uFEFF/, ''));

const SERVER_INFO = { name: 'toolkit-map', title: 'toolkit-map', version: '0.4.0' };
const READ_ONLY_TOOLS = ['toolkit_find', 'toolkit_status', 'toolkit_doctor'];
const MAINTENANCE_TOOLS = ['toolkit_scan', 'toolkit_update', 'toolkit_add'];

function legacyRequest(id, method, params = {}) {
  return { jsonrpc: '2.0', id, method, params };
}

function callTool(id, name, args = {}) {
  return legacyRequest(id, 'tools/call', { name, arguments: args });
}

function createHarness(result = { schemaVersion: 2, action: 'status', ok: true, status: 'ok' }, options = {}) {
  const calls = [];
  const handler = createProtocolHandler({
    serverInfo: SERVER_INFO,
    defaultProject: 'D:\\default-project',
    runMapConfig: options.runConfig || {},
    runMap: async (action, callOptions, callConfig) => {
      calls.push({ action, options: callOptions, config: callConfig });
      return typeof result === 'function' ? result(action, callOptions, callConfig) : result;
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
  assert.deepEqual([...STATUS_VALUES].sort(), Object.keys(STATUSES.statuses).sort());

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

test('maintenance previews report the exact map file that would be written', async () => {
  const windowsConfig = {
    platform: 'win32',
    cwd: 'C:\\work',
    env: { USERPROFILE: 'C:\\Users\\tester' }
  };

  // Default: USERPROFILE\.toolkit\map.json, exactly like map.ps1 Get-MapPath.
  let harness = createHarness(undefined, { runConfig: windowsConfig });
  let response = await harness.handler.handle(callTool(1, 'toolkit_scan'));

  assert.equal(harness.calls.length, 0);
  let result = response.result.structuredContent;
  assert.equal(result.mapFile, 'C:\\Users\\tester\\.toolkit\\map.json');
  assert.equal(result.mapFileKnown, true);
  assert.equal(result.mapFileSource, 'default');
  assert.equal(result.preview.includes('C:\\Users\\tester\\.toolkit\\map.json'), true);
  assertSchema(findTool('toolkit_scan').outputSchema, result, 'default map target');

  // Inherited TOOLKIT_MAP wins over the default, matching Get-MapPath.
  harness = createHarness(undefined, {
    runConfig: {
      ...windowsConfig,
      env: { ...windowsConfig.env, TOOLKIT_MAP: 'D:\\maps\\custom.json' }
    }
  });
  response = await harness.handler.handle(callTool(1, 'toolkit_update', { tool: 'node' }));
  result = response.result.structuredContent;
  assert.equal(result.mapFile, 'D:\\maps\\custom.json');
  assert.equal(result.mapFileKnown, true);
  assert.equal(result.mapFileSource, 'environment');
  assert.equal(result.preview.includes('D:\\maps\\custom.json'), true);

  // Server-configured -MapFile wins over the inherited TOOLKIT_MAP.
  harness = createHarness(undefined, {
    runConfig: {
      ...windowsConfig,
      mapFile: 'E:\\server\\map.json',
      env: { ...windowsConfig.env, TOOLKIT_MAP: 'D:\\maps\\custom.json' }
    }
  });
  response = await harness.handler.handle(callTool(1, 'toolkit_add', {
    tool: 'node',
    path: 'C:\\tools\\node.exe'
  }));
  result = response.result.structuredContent;
  assert.equal(result.mapFile, 'E:\\server\\map.json');
  assert.equal(result.mapFileSource, 'server');
  assert.equal(result.preview.includes('E:\\server\\map.json'), true);

  // TOOLKIT_MAP_FILE is the runner's -MapFile fallback, so it counts as server config.
  harness = createHarness(undefined, {
    runConfig: {
      ...windowsConfig,
      env: { ...windowsConfig.env, TOOLKIT_MAP_FILE: 'F:\\mcp\\map.json' }
    }
  });
  response = await harness.handler.handle(callTool(1, 'toolkit_scan'));
  result = response.result.structuredContent;
  assert.equal(result.mapFile, 'F:\\mcp\\map.json');
  assert.equal(result.mapFileSource, 'server');
});

test('maintenance previews mirror the -MapFile the runner would pass', async () => {
  const config = {
    platform: 'win32',
    cwd: 'C:\\work',
    mapFile: '',
    env: {
      USERPROFILE: 'C:\\Users\\tester',
      TOOLKIT_MAP_FILE: 'F:\\mcp\\map.json',
      TOOLKIT_MAP: 'D:\\maps\\custom.json'
    }
  };

  // An empty configured map file means "unset": the spawn arguments and the
  // preview must fall back to TOOLKIT_MAP_FILE rather than silently differing.
  assert.deepEqual(buildInvocation('scan', {}, config).args.slice(-3), [
    '-MapFile', 'F:\\mcp\\map.json', '-Json'
  ]);

  const harness = createHarness(undefined, { runConfig: config });
  const response = await harness.handler.handle(callTool(1, 'toolkit_scan'));
  const result = response.result.structuredContent;

  assert.equal(harness.calls.length, 0);
  assert.equal(result.mapFile, 'F:\\mcp\\map.json');
  assert.equal(result.mapFileKnown, true);
  assert.equal(result.mapFileSource, 'server');
  assert.equal(result.preview.includes('F:\\mcp\\map.json'), true);
});

test('maintenance previews describe the -MapFile argument used for every source', async () => {
  const base = { platform: 'win32', cwd: 'C:\\work', env: { USERPROFILE: 'C:\\Users\\tester' } };

  // The default target is pinned as -MapFile when the operation is confirmed.
  let harness = createHarness(undefined, { runConfig: base });
  let result = (await harness.handler.handle(callTool(1, 'toolkit_scan'))).result.structuredContent;
  assert.equal(result.mapFile, 'C:\\Users\\tester\\.toolkit\\map.json');
  assert.equal(result.preview.includes('-MapFile "C:\\Users\\tester\\.toolkit\\map.json"'), true);

  // TOOLKIT_MAP determines the target, but the resolved path is pinned as an argument.
  harness = createHarness(undefined, {
    runConfig: { ...base, env: { ...base.env, TOOLKIT_MAP: 'D:\\maps\\custom.json' } }
  });
  result = (await harness.handler.handle(callTool(1, 'toolkit_scan'))).result.structuredContent;
  assert.equal(result.mapFile, 'D:\\maps\\custom.json');
  assert.equal(result.preview.includes('-MapFile "D:\\maps\\custom.json"'), true);
  assert.match(result.preview, /environment/);

  // The server's mapFile (and TOOLKIT_MAP_FILE) is really passed as -MapFile.
  harness = createHarness(undefined, {
    runConfig: { ...base, mapFile: 'E:\\server\\map.json' }
  });
  result = (await harness.handler.handle(callTool(1, 'toolkit_scan'))).result.structuredContent;
  assert.equal(result.preview.includes('-MapFile "E:\\server\\map.json"'), true);

  harness = createHarness(undefined, {
    runConfig: { ...base, env: { ...base.env, TOOLKIT_MAP_FILE: 'F:\\mcp\\map.json' } }
  });
  result = (await harness.handler.handle(callTool(1, 'toolkit_scan'))).result.structuredContent;
  assert.equal(result.preview.includes('-MapFile "F:\\mcp\\map.json"'), true);
});

test('maintenance previews refuse Windows map paths that GetFullPath rejects', async () => {
  const invalid = [
    'C:\\maps\\bad|name.json',
    'C:\\maps\\bad<name.json',
    'C:\\maps\\bad>name.json',
    'C:\\maps\\bad"name.json',
    'C:\\maps\\bad*name.json',
    'C:\\maps\\bad?name.json',
    'C:\\maps\\drive:name.json'
  ];

  for (const value of invalid) {
    const harness = createHarness(undefined, {
      runConfig: {
        platform: 'win32',
        cwd: 'C:\\work',
        env: { USERPROFILE: 'C:\\Users\\tester', TOOLKIT_MAP: value }
      }
    });
    const result = (await harness.handler.handle(callTool(1, 'toolkit_scan'))).result.structuredContent;
    assert.equal(result.mapFile, undefined, value);
    assert.equal(result.mapFileKnown, false, value);
    assert.equal(result.mapFileSource, 'environment', value);
    assert.match(result.mapFileHint, /characters Windows rejects/i, value);
    assertSchema(findTool('toolkit_scan').outputSchema, result, value);
  }

  // A UNC server without a share is not a valid absolute map path.
  for (const unc of ['\\\\server', '\\\\server\\']) {
    const harness = createHarness(undefined, {
      runConfig: { platform: 'win32', cwd: 'C:\\work', env: { TOOLKIT_MAP: unc } }
    });
    const result = (await harness.handler.handle(callTool(1, 'toolkit_scan'))).result.structuredContent;
    assert.equal(result.mapFileKnown, false, unc);
    assert.match(result.mapFileHint, /cannot determine/i, unc);
  }

  // Device paths differ across PowerShell hosts and cannot be promised safely.
  const device = createHarness(undefined, {
    runConfig: {
      platform: 'win32',
      cwd: 'C:\\work',
      env: { USERPROFILE: 'C:\\Users\\tester', TOOLKIT_MAP: '\\\\?\\C:\\work\\map.json' }
    }
  });
  const deviceResult = (await device.handler.handle(callTool(1, 'toolkit_scan'))).result.structuredContent;
  assert.equal(deviceResult.mapFileKnown, false);
  assert.equal(deviceResult.mapFile, undefined);

  // POSIX allows characters that Windows reserves, so do not over-reject there.
  const posix = createHarness(undefined, {
    runConfig: {
      platform: 'linux',
      cwd: '/work',
      env: { HOME: '/home/tester', TOOLKIT_MAP: '/home/tester/maps/a:b*c.json' }
    }
  });
  const posixResult = (await posix.handler.handle(callTool(1, 'toolkit_scan'))).result.structuredContent;
  assert.equal(posixResult.mapFileKnown, true);
  assert.equal(posixResult.mapFile, '/home/tester/maps/a:b*c.json');
});

test('ambiguous Windows map targets cannot be confirmed or passed to the runner', async () => {
  const ambiguous = [
    '//server/share/map.json',
    '\\\\server\\share\\..\\map.json',
    'C:\\work\\map.json.',
    'C:\\work.\\map.json',
    '\\\\?\\C:\\work\\map.json',
    'C:\\work\\map.md'
  ];
  for (const target of ambiguous) {
    const harness = createHarness(
      (action) => ({ schemaVersion: 2, action, ok: true, status: 'ok' }),
      { runConfig: { platform: 'win32', cwd: 'C:\\work', env: { TOOLKIT_MAP: target } } }
    );
    const preview = await harness.handler.handle(callTool(1, 'toolkit_scan'));
    assert.equal(preview.result.structuredContent.mapFileKnown, false, target);
    const confirmed = await harness.handler.handle(callTool(2, 'toolkit_scan', { confirm: true }));
    assert.equal(confirmed.result.structuredContent.errorCode, 'map_target_unknown', target);
    assert.equal(harness.calls.length, 0, target);
  }
});

test('confirmed maintenance pins the previewed absolute target for every configuration source', async () => {
  const cases = [
    { env: { USERPROFILE: 'C:\\Users\\tester' }, expected: 'C:\\Users\\tester\\.toolkit\\map.json' },
    { env: { TOOLKIT_MAP: 'maps\\..\\chosen.json' }, expected: 'D:\\work\\chosen.json' },
    { env: { TOOLKIT_MAP_FILE: 'E:\\maps\\sub\\..\\chosen.json' }, expected: 'E:\\maps\\chosen.json' }
  ];
  for (const item of cases) {
    const harness = createHarness(
      (action) => ({ schemaVersion: 2, action, ok: true, status: 'ok' }),
      { runConfig: { platform: 'win32', cwd: 'D:\\work', env: item.env } }
    );
    const preview = await harness.handler.handle(callTool(1, 'toolkit_update', { tool: 'node' }));
    assert.equal(preview.result.structuredContent.mapFile, item.expected);
    const confirmed = await harness.handler.handle(callTool(2, 'toolkit_update', { tool: 'node', confirm: true }));
    assert.equal(confirmed.result.isError, false);
    assert.equal(harness.calls[0].config.mapFile, item.expected);
    assert.deepEqual(buildInvocation('update', harness.calls[0].options, harness.calls[0].config).args.slice(-3), [
      '-MapFile', item.expected, '-Json'
    ]);
  }
});

test('maintenance previews never invent a path from blank or padded map values', async () => {
  const defaultEnv = { USERPROFILE: 'C:\\Users\\tester' };
  const cases = [
    {
      label: 'blank TOOLKIT_MAP',
      source: 'environment',
      runConfig: { platform: 'win32', cwd: 'C:\\work', env: { ...defaultEnv, TOOLKIT_MAP: '   ' } }
    },
    {
      label: 'padded TOOLKIT_MAP',
      source: 'environment',
      runConfig: { platform: 'win32', cwd: 'C:\\work', env: { ...defaultEnv, TOOLKIT_MAP: ' D:\\maps\\custom.json ' } }
    },
    {
      label: 'blank configured map file',
      source: 'server',
      runConfig: {
        platform: 'win32',
        cwd: 'C:\\work',
        mapFile: '   ',
        env: { ...defaultEnv, TOOLKIT_MAP: 'D:\\maps\\custom.json' }
      }
    },
    {
      label: 'blank TOOLKIT_MAP_FILE',
      source: 'server',
      runConfig: {
        platform: 'win32',
        cwd: 'C:\\work',
        env: { ...defaultEnv, TOOLKIT_MAP_FILE: '  ', TOOLKIT_MAP: 'D:\\maps\\custom.json' }
      }
    }
  ];

  for (const item of cases) {
    const harness = createHarness(undefined, { runConfig: item.runConfig });
    const response = await harness.handler.handle(callTool(1, 'toolkit_scan'));
    const result = response.result.structuredContent;

    assert.equal(harness.calls.length, 0, item.label);
    assert.equal(result.mapFile, undefined, item.label);
    assert.equal(result.mapFileKnown, false, item.label);
    assert.equal(result.mapFileSource, item.source, item.label);
    assert.match(result.mapFileHint, /cannot determine/i, item.label);
    assert.equal(result.preview.includes('D:\\maps\\custom.json'), false, item.label);
    assert.equal(result.preview.includes('C:\\Users\\tester'), false, item.label);
    assertSchema(findTool('toolkit_scan').outputSchema, result, item.label);
  }

  // A tab is not resolvable by the Windows PowerShell host either, so the
  // preview must stay unknown instead of fabricating a relative path.
  const tabs = createHarness(undefined, {
    runConfig: {
      platform: 'win32',
      cwd: 'C:\\work',
      env: { ...defaultEnv, TOOLKIT_MAP: '\tC:\\maps\\map.json' }
    }
  });
  const tabResponse = await tabs.handler.handle(callTool(1, 'toolkit_scan'));
  const tabResult = tabResponse.result.structuredContent;
  assert.equal(tabResult.mapFile, undefined);
  assert.equal(tabResult.mapFileKnown, false);
  assert.equal(tabResult.mapFileSource, 'environment');
  assert.match(tabResult.mapFileHint, /cannot determine/i);
});

test('maintenance previews read the captured config env instead of the live process env', async () => {
  const savedMap = process.env.TOOLKIT_MAP;
  const savedFile = process.env.TOOLKIT_MAP_FILE;
  process.env.TOOLKIT_MAP = 'C:\\live-machine\\map.json';
  process.env.TOOLKIT_MAP_FILE = 'C:\\live-machine\\mcp-map.json';
  try {
    const harness = createHarness(undefined, {
      runConfig: {
        platform: 'win32',
        cwd: 'C:\\work',
        env: { USERPROFILE: 'C:\\Users\\tester' }
      }
    });
    const response = await harness.handler.handle(callTool(1, 'toolkit_scan'));
    const result = response.result.structuredContent;

    assert.equal(result.mapFile, 'C:\\Users\\tester\\.toolkit\\map.json');
    assert.equal(result.mapFileSource, 'default');
    assert.equal(result.preview.includes('live-machine'), false);
  } finally {
    if (savedMap === undefined) delete process.env.TOOLKIT_MAP;
    else process.env.TOOLKIT_MAP = savedMap;
    if (savedFile === undefined) delete process.env.TOOLKIT_MAP_FILE;
    else process.env.TOOLKIT_MAP_FILE = savedFile;
  }
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

test('maintenance previews resolve relative values against the server working directory', async () => {
  const harness = createHarness(undefined, {
    runConfig: {
      platform: 'win32',
      cwd: 'D:\\work\\app',
      env: { USERPROFILE: 'C:\\Users\\tester', TOOLKIT_MAP: 'maps\\map.json' }
    }
  });

  const response = await harness.handler.handle(callTool(1, 'toolkit_scan'));
  const result = response.result.structuredContent;
  assert.equal(result.mapFile, 'D:\\work\\app\\maps\\map.json');
  assert.equal(result.mapFileKnown, true);
});

test('maintenance previews mark an unknowable map target as unknown instead of guessing', async () => {
  // A drive-relative TOOLKIT_MAP depends on PowerShell's per-drive current
  // directory, which the MCP server cannot observe reliably.
  let harness = createHarness(undefined, {
    runConfig: {
      platform: 'win32',
      cwd: 'C:\\work',
      env: { USERPROFILE: 'C:\\Users\\tester', TOOLKIT_MAP: 'C:maps\\map.json' }
    }
  });
  let response = await harness.handler.handle(callTool(1, 'toolkit_scan'));
  let result = response.result.structuredContent;

  assert.equal(result.mapFile, undefined);
  assert.equal(result.mapFileKnown, false);
  assert.equal(result.mapFileSource, 'environment');
  assert.match(result.mapFileHint, /cannot determine/i);
  assert.equal(result.preview.includes('C:\\Users\\tester'), false);

  // Without USERPROFILE there is no default the server can prove.
  harness = createHarness(undefined, {
    runConfig: { platform: 'win32', cwd: 'C:\\work', env: {} }
  });
  response = await harness.handler.handle(callTool(1, 'toolkit_add', {
    tool: 'node',
    path: 'C:\\tools\\node.exe'
  }));
  result = response.result.structuredContent;

  assert.equal(result.mapFile, undefined);
  assert.equal(result.mapFileKnown, false);
  assert.equal(result.mapFileSource, 'unknown');
  assert.match(result.mapFileHint, /cannot determine/i);
  assertSchema(findTool('toolkit_add').outputSchema, result, 'unknown map target');
});

test('confirmed maintenance refuses an unknown map target without invoking the runner', async () => {
  const cases = [
    ['toolkit_scan', {}],
    ['toolkit_update', { tool: 'node' }],
    ['toolkit_add', { tool: 'node', path: 'C:\\tools\\node.exe' }]
  ];
  for (const [name, args] of cases) {
    const harness = createHarness(
      (action) => ({ schemaVersion: 2, action, ok: true, status: 'ok' }),
      { runConfig: { platform: 'win32', cwd: 'C:\\work', env: { TOOLKIT_MAP: 'C:relative\\map.json' } } }
    );
    const preview = await harness.handler.handle(callTool(1, name, args));
    assert.equal(preview.result.structuredContent.mapFileKnown, false, name);
    const confirmed = await harness.handler.handle(callTool(2, name, { ...args, confirm: true }));
    assert.equal(harness.calls.length, 0, name);
    assert.equal(confirmed.result.isError, true, name);
    assert.equal(confirmed.result.structuredContent.action, name.slice('toolkit_'.length), name);
    assert.equal(confirmed.result.structuredContent.errorCode, 'map_target_unknown', name);
    assert.match(confirmed.result.structuredContent.message, /cannot determine|map file/i, name);
  }
});

test('maintenance previews follow the HOME convention on non-Windows platforms', async () => {
  const harness = createHarness(undefined, {
    runConfig: { platform: 'linux', cwd: '/work', env: { HOME: '/home/tester' } }
  });

  const response = await harness.handler.handle(callTool(1, 'toolkit_scan'));
  const result = response.result.structuredContent;
  assert.equal(result.mapFile, '/home/tester/.toolkit/map.json');
  assert.equal(result.mapFileSource, 'default');
});

test('toolkit_add describes version as a probe hint, not a request to skip probing', () => {
  const add = findTool('toolkit_add');
  const version = add.inputSchema.properties.version.description;

  assert.match(version, /hint/i);
  assert.match(version, /does not disable probing/i);
  assert.match(add.description, /version is a probe hint/i);
});

test('Windows add rejects ambiguous executable paths before preview or execution', async () => {
  const inputs = ['/tmp/node.exe', '//server/share/node.exe', '\\\\server\\share\\..\\node.exe', 'C:\\tools\\node.exe.', 'C:\\tools.\\node.exe'];
  const harness = createHarness(undefined, {
    runConfig: { platform: 'win32', cwd: 'C:\\work', mapFile: 'C:\\maps\\map.json', env: {} }
  });
  for (const value of inputs) {
    const preview = await harness.handler.handle(callTool(1, 'toolkit_add', { tool: 'node', path: value }));
    assert.equal(preview.error?.code, -32602, value);
    const confirmed = await harness.handler.handle(callTool(2, 'toolkit_add', { tool: 'node', path: value, confirm: true }));
    assert.equal(confirmed.error?.code, -32602, value);
  }
  assert.equal(harness.calls.length, 0);
});

test('add preview and execution use the same normalized executable path', async () => {
  const harness = createHarness(
    (action) => ({ schemaVersion: 2, action, ok: true, status: 'ok' }),
    { runConfig: { platform: 'win32', cwd: 'C:\\work', mapFile: 'C:\\maps\\map.json', env: {} } }
  );
  const args = { tool: 'node', path: 'C:\\tools\\subdir\\..\\node.exe' };
  const preview = await harness.handler.handle(callTool(1, 'toolkit_add', args));
  assert.equal(preview.result.structuredContent.path, 'C:\\tools\\node.exe');
  assert.match(preview.result.structuredContent.preview, /node\.exe/);
  const executed = await harness.handler.handle(callTool(2, 'toolkit_add', { ...args, confirm: true }));
  assert.equal(executed.result.isError, false);
  assert.equal(harness.calls[0].options.path, 'C:\\tools\\node.exe');
});

test('toolkit_add preview keeps a spaced path visibly quoted', async () => {
  const harness = createHarness();
  const response = await harness.handler.handle(callTool(1, 'toolkit_add', {
    tool: 'node',
    path: 'C:\\Program Files\\nodejs\\node.exe'
  }));

  const preview = response.result.structuredContent.preview;
  // The preview describes the argument array, so a path with spaces must not
  // look like several shell words that a human could paste into a shell.
  assert.equal(preview.includes('-Path "C:\\Program Files\\nodejs\\node.exe"'), true);
  assert.equal(preview.includes('-Path C:\\Program Files'), false);
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
  }, { runConfig: { platform: 'win32', cwd: 'C:\\work', mapFile: 'C:\\server\\map.json', env: {} } });

  response = await execute.handler.handle(callTool(3, 'toolkit_update', { tool: 'Node', confirm: true }));
  assert.deepEqual(execute.calls, [{
    action: 'update',
    options: { tool: 'node' },
    config: { platform: 'win32', cwd: 'C:\\work', mapFile: 'C:\\server\\map.json', env: {} }
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
  }, { runConfig: { platform: 'win32', cwd: 'C:\\work', mapFile: 'C:\\maps\\map.json', env: {} } });

  const response = await execute.handler.handle(callTool(1, 'toolkit_update', { confirm: true }));
  assert.deepEqual(execute.calls, [{
    action: 'update',
    options: { tool: '' },
    config: { platform: 'win32', cwd: 'C:\\work', mapFile: 'C:\\maps\\map.json', env: {} }
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
  }, { runConfig: { platform: 'win32', cwd: 'C:\\work', mapFile: 'C:\\server\\map.json', env: {} } });

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
    },
    config: { platform: 'win32', cwd: 'C:\\work', mapFile: 'C:\\server\\map.json', env: {} }
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
    { name: 'toolkit_add', args: { tool: 'node', path: 'relative\\node.exe', confirm: true }, message: /path must be an absolute path/ },
    { name: 'toolkit_add', args: { tool: 'node', path: '\\node.exe', confirm: true }, message: /path must be an absolute path/ },
    { name: 'toolkit_add', args: { tool: 'node', path: '\\\\server', confirm: true }, message: /path must be an absolute path/ },
    { name: 'toolkit_add', args: { tool: 'node', path: '\\\\?\\C:\\node.exe', confirm: true }, message: /path must be an absolute path/ },
    { name: 'toolkit_add', args: { tool: 'node', path: 'C:\\node.exe', prefer: 'yes', confirm: true }, message: /prefer must be a boolean/ },
    { name: 'toolkit_add', args: { tool: 'node', path: 'C:\\node.exe', prefer: null, confirm: true }, message: /prefer must be a boolean/ },
    { name: 'toolkit_add', args: { tool: 'node', path: 'C:\\node.exe', mapFile: 'C:\\evil.json', confirm: true }, message: /Unknown argument for toolkit_add: mapFile/ },
    { name: 'toolkit_scan', args: { mapFile: 'C:\\evil.json', confirm: true }, message: /Unknown argument for toolkit_scan: mapFile/ },
    { name: 'toolkit_update', args: { mapFile: 'C:\\evil.json', confirm: true }, message: /Unknown argument for toolkit_update: mapFile/ },
    { name: 'toolkit_add', args: { path: 'C:\\node.exe', confirm: true }, message: /requires a tool name/ },
    { name: 'toolkit_add', args: { tool: 'node', confirm: true }, message: /requires an absolute path/ }
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

test('a syntactically valid map result missing the frozen envelope is rejected', async () => {
  const { handler } = createHarness({ ok: true, status: 'ok' });
  const response = await handler.handle(callTool(1, 'toolkit_status'));

  assert.equal(response.result.isError, true);
  const result = response.result.structuredContent;
  assert.equal(result.schemaVersion, 2);
  assert.equal(result.action, 'status');
  assert.equal(result.ok, false);
  assert.equal(result.status, 'operation_failed');
  assert.match(result.errorCode, /invalid_output/);
  assertSchema(findTool('toolkit_status').outputSchema, result, 'malformed result');
});

test('a future failure status passes through instead of becoming an internal error', async () => {
  const payload = {
    schemaVersion: 2,
    action: 'status',
    ok: false,
    status: 'future_failure_status',
    message: 'added by a newer toolkit-map'
  };
  const { handler } = createHarness(payload);
  const response = await handler.handle(callTool(1, 'toolkit_status'));

  assert.equal(response.result.isError, true);
  const result = response.result.structuredContent;
  assert.equal(result.status, 'future_failure_status');
  assert.equal(result.ok, false);
  assert.equal(result.errorCode, undefined);
  assertSchema(findTool('toolkit_status').outputSchema, result, 'future failure status');
});

test('an unknown status with ok:true is never treated as success', async () => {
  const { handler } = createHarness({
    schemaVersion: 2,
    action: 'status',
    ok: true,
    status: 'future_success_status',
    path: 'C:\\should-not-be-used.exe'
  });
  const response = await handler.handle(callTool(1, 'toolkit_status'));

  assert.equal(response.result.isError, true);
  const result = response.result.structuredContent;
  assert.equal(result.schemaVersion, 2);
  assert.equal(result.action, 'status');
  assert.equal(result.ok, false);
  assert.equal(result.status, 'operation_failed');
  assert.equal(result.errorCode, 'unknown_status');
  assert.equal(result.path, undefined);
});

test('a non-string status is still an invalid map result', async () => {
  const { handler } = createHarness({
    schemaVersion: 2,
    action: 'status',
    ok: false,
    status: 42
  });
  const response = await handler.handle(callTool(1, 'toolkit_status'));

  assert.equal(response.result.isError, true);
  assert.equal(response.result.structuredContent.errorCode, 'invalid_output');
  assert.equal(response.result.structuredContent.action, 'status');
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

test('maintenance runner rejects shell-shaped tool names and relative paths', () => {
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
  assert.throws(
    () => buildInvocation('add', { tool: 'node', path: 'relative\\node.exe' }, config),
    /path must be an absolute path/
  );
  for (const ambiguous of ['\\node.exe', '\\\\server', '\\\\?\\C:\\node.exe']) {
    assert.throws(
      () => buildInvocation('add', { tool: 'node', path: ambiguous }, config),
      /path must be an absolute path/,
      ambiguous
    );
  }
});
