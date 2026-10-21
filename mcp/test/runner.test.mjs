import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { PassThrough } from 'node:stream';
import test from 'node:test';

import { buildInvocation, MapRunError, runMap } from '../lib/runner.mjs';

function fakeChild() {
  const child = new EventEmitter();
  child.pid = 4242;
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  child.killedWith = null;
  child.kill = (signal) => {
    child.killedWith = signal;
    return true;
  };
  return child;
}

function fakeSpawn(onChild) {
  const calls = [];
  const spawnImpl = (command, args, options) => {
    const child = fakeChild();
    calls.push({ command, args, options, child });
    queueMicrotask(() => onChild(child, command, args, options));
    return child;
  };
  return { spawnImpl, calls };
}

function tempScript(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'toolkit-map-mcp-'));
  const script = path.join(dir, 'map.ps1');
  fs.writeFileSync(script, '# fixture', 'utf8');
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return script;
}

const linuxConfig = {
  platform: 'linux',
  allowNonWindows: true,
  powershell: 'fake-powershell'
};

test('buildInvocation uses an argument array and the map contract order', () => {
  const invocation = buildInvocation('find', {
    tool: 'node',
    project: 'C:\\work\\app',
    version: '>=18'
  }, {
    script: 'C:\\repo\\scripts\\map.ps1',
    powershell: 'powershell.exe',
    mapFile: 'C:\\temp\\map.json'
  });

  assert.equal(invocation.command, 'powershell.exe');
  assert.deepEqual(invocation.args, [
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', 'C:\\repo\\scripts\\map.ps1',
    'find', 'node',
    '-Project', 'C:\\work\\app',
    '-Version', '>=18',
    '-MapFile', 'C:\\temp\\map.json',
    '-Json'
  ]);
});

test('buildInvocation omits empty optional values', () => {
  const invocation = buildInvocation('status', {}, {
    script: '/repo/scripts/map.ps1',
    powershell: 'pwsh'
  });
  assert.deepEqual(invocation.args, [
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', '/repo/scripts/map.ps1',
    'status',
    '-Json'
  ]);
});

test('runMap parses one JSON object and strips a UTF-8 BOM', async (t) => {
  const script = tempScript(t);
  const payload = { schemaVersion: 2, action: 'status', ok: true, status: 'ok', tools: 20 };
  const { spawnImpl, calls } = fakeSpawn((child) => {
    child.stdout.write(`\uFEFF${JSON.stringify(payload)}`);
    child.stderr.write('warning on stderr');
    child.emit('close', 0, null);
  });

  const result = await runMap('status', {}, {
    ...linuxConfig,
    script,
    spawnImpl
  });

  assert.deepEqual(result, payload);
  assert.equal(calls[0].command, 'fake-powershell');
  assert.equal(calls[0].options.shell, undefined);
  assert.deepEqual(calls[0].options.stdio, ['ignore', 'pipe', 'pipe']);
});

test('runMap accepts a valid JSON result on a non-zero exit code', async (t) => {
  const script = tempScript(t);
  const { spawnImpl } = fakeSpawn((child) => {
    child.stdout.write(JSON.stringify({ ok: false, status: 'version_mismatch', path: '' }));
    child.emit('close', 1, null);
  });

  const result = await runMap('find', { tool: 'node' }, {
    ...linuxConfig,
    script,
    spawnImpl
  });

  assert.equal(result.ok, false);
  assert.equal(result.status, 'version_mismatch');
});

test('runMap rejects malformed stdout and keeps stderr for diagnostics', async (t) => {
  const script = tempScript(t);
  const { spawnImpl } = fakeSpawn((child) => {
    child.stdout.write('not json');
    child.stderr.write('boom');
    child.emit('close', 1, null);
  });

  await assert.rejects(
    runMap('status', {}, { ...linuxConfig, script, spawnImpl }),
    (error) => {
      assert.equal(error.name, 'MapRunError');
      assert.equal(error.code, 'invalid_output');
      assert.match(error.details.stderr, /boom/);
      return true;
    }
  );
});

test('runMap reports spawn failures', async (t) => {
  const script = tempScript(t);
  const { spawnImpl } = fakeSpawn((child) => {
    child.emit('error', new Error('ENOENT'));
  });

  await assert.rejects(
    runMap('status', {}, { ...linuxConfig, script, spawnImpl }),
    (error) => {
      assert.equal(error.code, 'spawn_failed');
      assert.match(error.message, /ENOENT/);
      return true;
    }
  );
});

test('runMap times out and kills the child', async (t) => {
  const script = tempScript(t);
  const { spawnImpl, calls } = fakeSpawn((child) => {
    setTimeout(() => child.emit('close', null, 'SIGKILL'), 100);
  });

  await assert.rejects(
    runMap('status', {}, { ...linuxConfig, script, spawnImpl, timeoutMs: 20 }),
    (error) => {
      assert.equal(error.code, 'timeout');
      return true;
    }
  );

  assert.equal(calls[0].child.killedWith, 'SIGKILL');
});

test('runMap refuses to run on non-Windows without an explicit override', async () => {
  await assert.rejects(
    runMap('status', {}, { platform: 'linux' }),
    (error) => {
      assert.equal(error.code, 'unsupported_platform');
      return true;
    }
  );
});

test('runMap reports a missing map.ps1 before spawning', async () => {
  await assert.rejects(
    runMap('status', {}, {
      ...linuxConfig,
      script: path.join(os.tmpdir(), 'definitely-missing-map.ps1'),
      spawnImpl: () => {
        throw new Error('should not spawn');
      }
    }),
    (error) => {
      assert.ok(error instanceof MapRunError);
      assert.equal(error.code, 'map_script_missing');
      return true;
    }
  );
});

test('MapRunError keeps a stable name and code', () => {
  const error = new MapRunError('timeout', 'late');
  assert.equal(error.name, 'MapRunError');
  assert.equal(error.code, 'timeout');
});
