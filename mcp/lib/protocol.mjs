import { isDeterministicAbsolutePath, MapRunError, normalizeAddExecutablePath, resolveMapTarget } from './runner.mjs';
import {
  INSTRUCTIONS,
  LEGACY_PROTOCOL_VERSIONS,
  MODERN_PROTOCOL_VERSION,
  SERVER_NAME,
  SERVER_TITLE,
  STATUS_VALUES,
  TOOLS,
  findTool
} from './tools.mjs';

const MAX_TOOL_LENGTH = 64;
const MAX_PATH_LENGTH = 4096;
const MAX_VERSION_LENGTH = 128;
const MAX_NOTE_LENGTH = 4000;
const TOOL_NAME_PATTERN = /^[a-z0-9][a-z0-9._+-]*$/;
const ACTION_PATTERN = /^[a-z][a-z0-9_-]*$/;
const STATUS_PATTERN = /^[a-z][a-z0-9_-]*$/;
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/;
const BOOLEAN_ARGUMENTS = new Set(['confirm', 'prefer']);
const TOOL_ARGUMENT_TOOLS = new Set(['toolkit_find', 'toolkit_update', 'toolkit_add']);
const ACTION_BY_TOOL = {
  toolkit_find: 'find',
  toolkit_status: 'status',
  toolkit_doctor: 'doctor',
  toolkit_scan: 'scan',
  toolkit_update: 'update',
  toolkit_add: 'add'
};

class RpcError extends Error {
  constructor(code, message, data) {
    super(message);
    this.name = 'RpcError';
    this.code = code;
    this.data = data;
  }
}

function errorResponse(id, code, message, data) {
  const error = { code, message };
  if (data !== undefined) error.data = data;
  return { jsonrpc: '2.0', id: id ?? null, error };
}

function resultResponse(id, result, modern) {
  return {
    jsonrpc: '2.0',
    id,
    result: modern ? { resultType: 'complete', ...result } : result
  };
}

function protocolVersionOf(message) {
  return message?.params?._meta?.['io.modelcontextprotocol/protocolVersion'] || null;
}

function assertSupportedModern(message) {
  const version = protocolVersionOf(message);
  if (version && version !== MODERN_PROTOCOL_VERSION) {
    throw new RpcError(-32022, 'Unsupported protocol version', {
      supported: [MODERN_PROTOCOL_VERSION],
      requested: version
    });
  }
  return Boolean(version);
}

function assertString(value, name, maxLength) {
  if (typeof value !== 'string') {
    throw new RpcError(-32602, `${name} must be a string`);
  }
  if (value.length > maxLength) {
    throw new RpcError(-32602, `${name} is too long (max ${maxLength} characters)`);
  }
  if (CONTROL_CHARACTERS.test(value)) {
    throw new RpcError(-32602, `${name} contains control characters`);
  }
  return value;
}

function validateArguments(tool, rawArguments, platform = process.platform) {
  const raw = rawArguments === undefined || rawArguments === null ? {} : rawArguments;
  if (typeof raw !== 'object' || Array.isArray(raw)) {
    throw new RpcError(-32602, 'arguments must be an object');
  }

  const properties = tool.inputSchema.properties || {};
  const allowed = new Set(Object.keys(properties));
  for (const key of Object.keys(raw)) {
    if (!allowed.has(key)) throw new RpcError(-32602, `Unknown argument for ${tool.name}: ${key}`);
  }

  const args = {};
  for (const [key, value] of Object.entries(raw)) {
    if (BOOLEAN_ARGUMENTS.has(key)) {
      if (value === undefined) continue;
      if (typeof value !== 'boolean') {
        throw new RpcError(-32602, `${key} must be a boolean`);
      }
      args[key] = value;
      continue;
    }
    if (value === undefined || value === null) continue;
    const maxLength = key === 'version'
      ? MAX_VERSION_LENGTH
      : key === 'tool'
        ? MAX_TOOL_LENGTH
        : key === 'note'
          ? MAX_NOTE_LENGTH
          : MAX_PATH_LENGTH;
    args[key] = assertString(value, key, maxLength);
  }

  if ((tool.name === 'toolkit_find' || tool.name === 'toolkit_add') && !args.tool) {
    throw new RpcError(-32602, `${tool.name} requires a tool name`);
  }
  if (tool.name === 'toolkit_add' && !args.path) {
    throw new RpcError(-32602, 'toolkit_add requires an absolute path');
  }

  if (TOOL_ARGUMENT_TOOLS.has(tool.name) && args.tool !== undefined) {
    const name = args.tool.trim().toLowerCase();
    if (!TOOL_NAME_PATTERN.test(name)) {
      throw new RpcError(-32602, 'tool must be a command name, not a path or a name with separators');
    }
    args.tool = name;
  }

  if (tool.name === 'toolkit_add') {
    const normalized = normalizeAddExecutablePath(args.path, platform);
    if (!normalized) throw new RpcError(-32602, 'path must be an absolute path with an unambiguous target');
    args.path = normalized;
  }

  if ((tool.name === 'toolkit_find' || tool.name === 'toolkit_doctor')
      && args.project !== undefined && !isDeterministicAbsolutePath(args.project)) {
    throw new RpcError(-32602, 'project must be an absolute path');
  }
  if (tool.name === 'toolkit_doctor'
      && args.rulesFile !== undefined && !isDeterministicAbsolutePath(args.rulesFile)) {
    throw new RpcError(-32602, 'rulesFile must be an absolute path');
  }

  return args;
}

function truncate(value, maxLength = 2000) {
  const text = String(value ?? '');
  return text.length > maxLength ? `${text.slice(0, maxLength)}…` : text;
}

function toolError(error, modern, action = 'unknown') {
  const isMapRunError = error?.name === 'MapRunError';
  const safeAction = typeof action === 'string' && ACTION_PATTERN.test(action) ? action : 'unknown';
  const payload = {
    schemaVersion: 2,
    action: safeAction,
    ok: false,
    status: 'operation_failed',
    errorCode: isMapRunError ? error.code || 'operation_failed' : 'operation_failed',
    message: truncate(error?.message || error, 4000)
  };

  if (isMapRunError && error.details) {
    payload.diagnostics = {
      exitCode: error.details.exitCode ?? null,
      stderr: truncate(error.details.stderr, 4000)
    };
    if (error.code === 'unsupported_platform') {
      payload.hint = '完整地图目前只支持 Windows；请使用 Windows PowerShell 5.1 或 PowerShell 7。';
    } else if (error.code === 'map_script_missing') {
      payload.hint = '找不到 scripts/map.ps1；请从仓库根目录启动，或设置 TOOLKIT_MAP_SCRIPT。';
    }
  }

  return {
    content: [{ type: 'text', text: JSON.stringify(payload) }],
    structuredContent: payload,
    isError: true,
    ...(modern ? { resultType: 'complete' } : {})
  };
}

export function createProtocolHandler({
  runMap,
  runMapConfig,
  serverInfo = {},
  defaultProject = process.env.TOOLKIT_MAP_PROJECT || process.env.CLAUDE_PROJECT_DIR || process.cwd()
} = {}) {
  if (typeof runMap !== 'function') throw new TypeError('runMap is required');

  const runnerConfig = runMapConfig || {};
  const info = {
    name: SERVER_NAME,
    title: SERVER_TITLE,
    version: '0.0.0',
    ...serverInfo
  };

  function legacyServerInfo() {
    return { name: info.name, title: info.title, version: info.version };
  }

  function modernServerInfo() {
    return { name: info.name, version: info.version };
  }

  function projectFrom(args) {
    const project = args.project || defaultProject;
    return project ? String(project) : process.cwd();
  }

  function maintenancePreview(action, args) {
    const quote = (value) => `"${String(value).replace(/"/g, '\\"')}"`;
    const target = action === 'update' && args.tool
      ? ` ${args.tool}`
      : action === 'add'
        ? ` ${args.tool} -Path ${quote(args.path)}`
          + (args.version ? ` -Version ${quote(args.version)}` : '')
          + (args.note ? ` -Note ${quote(args.note)}` : '')
          + (args.prefer === true ? ' -Prefer' : '')
        : '';
    // Resolved with Get-MapPath's precedence, without touching the disk and
    // without running PowerShell. Unknown values stay explicitly unknown.
    const mapTarget = resolveMapTarget(runnerConfig);
    // Confirmation pins this exact resolved target as -MapFile, regardless of
    // whether it originally came from server config, TOOLKIT_MAP or the home.
    const mapArgument = mapTarget.known ? ` -MapFile "${mapTarget.path}"` : '';
    const resolution = mapTarget.known
      ? ` with the resolved ${mapTarget.source} map file (argument array, no shell)`
      : ' against a map file the server cannot determine without running map.ps1; set TOOLKIT_MAP_FILE to an absolute path';
    const result = {
      schemaVersion: 2,
      action,
      ok: true,
      status: 'planned',
      executed: false,
      confirmRequired: true,
      preview: `would run map.ps1 ${action}${target}${mapArgument} -Json${resolution}`,
      mapFileKnown: mapTarget.known,
      mapFileSource: mapTarget.source,
      hint: [
        mapTarget.known
          ? 'No map action was run. Call again with confirm:true to execute.'
          : 'No map action was run. Configure an exact map target before execution; confirm:true cannot override an unknown target.',
        'confirm is a workflow guard, not a permission or security boundary.',
        'Candidate version probing may execute programs found on this machine, so obtain explicit human authorization first.'
      ].join(' ')
    };
    if (mapTarget.known) result.mapFile = mapTarget.path;
    else result.mapFileHint = mapTarget.hint;
    if (args.tool) result.tool = args.tool;
    if (args.path) result.path = args.path;
    if (args.note) result.note = args.note;
    if (args.version) result.version = args.version;
    if (action === 'add') result.prefer = args.prefer === true;
    return result;
  }

  function contractProblem(result, expectedAction) {
    if (!result || typeof result !== 'object' || Array.isArray(result)) {
      return { code: 'invalid_output', message: 'map.ps1 returned a non-object result' };
    }
    if (result.schemaVersion !== 2) {
      return { code: 'invalid_output', message: 'map.ps1 result is missing schemaVersion 2' };
    }
    if (typeof result.action !== 'string' || !ACTION_PATTERN.test(result.action)) {
      return { code: 'invalid_output', message: 'map.ps1 result has an invalid action' };
    }
    if (result.action !== expectedAction) {
      return {
        code: 'invalid_output',
        message: `map.ps1 result action "${result.action}" does not match "${expectedAction}"`
      };
    }
    if (typeof result.ok !== 'boolean') {
      return { code: 'invalid_output', message: 'map.ps1 result is missing a boolean ok' };
    }
    if (typeof result.status !== 'string' || !STATUS_PATTERN.test(result.status)) {
      return { code: 'invalid_output', message: `map.ps1 result has an invalid status: ${String(result.status)}` };
    }
    if (!STATUS_VALUES.includes(result.status)) {
      // Compatibility policy: consumers must treat unknown statuses as failures.
      // A future minor may add a status, so a failure result must pass through;
      // an unknown status paired with ok:true is never accepted as success.
      if (result.ok === true) {
        return {
          code: 'unknown_status',
          message: `map.ps1 reported success with an unknown status: ${result.status}`
        };
      }
    }
    return null;
  }

  function maintenanceRunnerConfig() {
    const target = resolveMapTarget(runnerConfig);
    if (!target.known) throw new MapRunError('map_target_unknown', target.hint);
    return { ...runnerConfig, mapFile: target.path };
  }

  async function invokeTool(name, args) {
    if (name === 'toolkit_find') {
      return runMap('find', {
        tool: args.tool,
        project: projectFrom(args),
        version: args.version || ''
      }, runnerConfig);
    }
    if (name === 'toolkit_status') {
      return runMap('status', {}, runnerConfig);
    }
    if (name === 'toolkit_doctor') {
      return runMap('doctor', {
        project: projectFrom(args),
        rulesFile: args.rulesFile || ''
      }, runnerConfig);
    }
    if (name === 'toolkit_scan') {
      if (args.confirm !== true) return maintenancePreview('scan', args);
      return runMap('scan', {}, maintenanceRunnerConfig());
    }
    if (name === 'toolkit_update') {
      if (args.confirm !== true) return maintenancePreview('update', args);
      return runMap('update', { tool: args.tool || '' }, maintenanceRunnerConfig());
    }
    if (name === 'toolkit_add') {
      if (args.confirm !== true) return maintenancePreview('add', args);
      return runMap('add', {
        tool: args.tool,
        path: args.path,
        note: args.note || '',
        version: args.version || '',
        prefer: args.prefer === true
      }, maintenanceRunnerConfig());
    }
    throw new RpcError(-32602, `Unknown tool: ${name}`);
  }

  async function handle(message) {
    if (Array.isArray(message)) {
      return errorResponse(null, -32600, 'Batch requests are not supported by MCP');
    }
    if (!message || typeof message !== 'object' || message.jsonrpc !== '2.0') {
      return errorResponse(message?.id ?? null, -32600, 'Invalid JSON-RPC 2.0 request');
    }

    const { id, method, params } = message;
    if (typeof method !== 'string') {
      return errorResponse(id ?? null, -32600, 'Request method must be a string');
    }

    if (method.startsWith('notifications/')) {
      // The legacy handshake ends with notifications/initialized. Other
      // notifications (cancellation, progress) need no reply.
      return null;
    }

    if (id === undefined) return null;

    try {
      switch (method) {
        case 'initialize': {
          const requested = params?.protocolVersion;
          if (typeof requested !== 'string' || !requested) {
            throw new RpcError(-32602, 'initialize requires protocolVersion');
          }
          const version = LEGACY_PROTOCOL_VERSIONS.includes(requested)
            ? requested
            : LEGACY_PROTOCOL_VERSIONS[0];
          return resultResponse(id, {
            protocolVersion: version,
            capabilities: { tools: { listChanged: false } },
            serverInfo: legacyServerInfo(),
            instructions: INSTRUCTIONS
          }, false);
        }

        case 'server/discover': {
          assertSupportedModern(message);
          return resultResponse(id, {
            supportedVersions: [MODERN_PROTOCOL_VERSION],
            capabilities: { tools: {} },
            _meta: { 'io.modelcontextprotocol/serverInfo': modernServerInfo() },
            instructions: INSTRUCTIONS,
            ttlMs: 3600000,
            cacheScope: 'public'
          }, true);
        }

        case 'ping': {
          const modern = assertSupportedModern(message);
          return resultResponse(id, {}, modern);
        }

        case 'tools/list': {
          const modern = assertSupportedModern(message);
          if (params?.cursor) {
            return resultResponse(id, { tools: [] }, modern);
          }
          return resultResponse(id, { tools: TOOLS }, modern);
        }

        case 'tools/call': {
          const modern = assertSupportedModern(message);
          const name = params?.name;
          if (typeof name !== 'string' || !name) {
            throw new RpcError(-32602, 'tools/call requires a tool name');
          }
          const tool = findTool(name);
          if (!tool) throw new RpcError(-32602, `Unknown tool: ${name}`);
          const args = validateArguments(tool, params?.arguments, runnerConfig.platform || process.platform);
          const action = ACTION_BY_TOOL[name];

          let result;
          try {
            result = await invokeTool(name, args);
          } catch (error) {
            if (error instanceof RpcError) throw error;
            return resultResponse(id, toolError(error, modern, action), false);
          }

          const problem = contractProblem(result, action);
          if (problem) {
            return resultResponse(
              id,
              toolError(new MapRunError(problem.code, problem.message), modern, action),
              false
            );
          }

          return resultResponse(id, {
            content: [{ type: 'text', text: JSON.stringify(result) }],
            structuredContent: result,
            isError: result.ok !== true
          }, modern);
        }

        default:
          throw new RpcError(-32601, `Method not found: ${method}`);
      }
    } catch (error) {
      if (error instanceof RpcError) {
        return errorResponse(id, error.code, error.message, error.data);
      }
      return errorResponse(id, -32603, 'Internal error', {
        message: truncate(error?.message || error, 2000)
      });
    }
  }

  return { handle };
}
