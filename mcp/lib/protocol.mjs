import {
  INSTRUCTIONS,
  LEGACY_PROTOCOL_VERSIONS,
  MODERN_PROTOCOL_VERSION,
  SERVER_NAME,
  SERVER_TITLE,
  TOOLS,
  findTool
} from './tools.mjs';

const MAX_TOOL_LENGTH = 64;
const MAX_PATH_LENGTH = 4096;
const MAX_VERSION_LENGTH = 128;
const TOOL_NAME_PATTERN = /^[a-z0-9][a-z0-9._+-]*$/;
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/;

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

function validateArguments(tool, rawArguments) {
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
    if (value === undefined || value === null) continue;
    const maxLength = key === 'version' ? MAX_VERSION_LENGTH : key === 'tool' ? MAX_TOOL_LENGTH : MAX_PATH_LENGTH;
    args[key] = assertString(value, key, maxLength);
  }

  if (tool.name === 'toolkit_find') {
    if (!args.tool) throw new RpcError(-32602, 'toolkit_find requires a tool name');
    const name = args.tool.trim().toLowerCase();
    if (!TOOL_NAME_PATTERN.test(name)) {
      throw new RpcError(-32602, 'tool must be a command name, not a path or a name with separators');
    }
    args.tool = name;
  }

  return args;
}

function truncate(value, maxLength = 2000) {
  const text = String(value ?? '');
  return text.length > maxLength ? `${text.slice(0, maxLength)}…` : text;
}

function toolError(error, modern) {
  const isMapRunError = error?.name === 'MapRunError';
  const payload = {
    schemaVersion: 2,
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
  serverInfo = {},
  defaultProject = process.env.TOOLKIT_MAP_PROJECT || process.env.CLAUDE_PROJECT_DIR || process.cwd()
} = {}) {
  if (typeof runMap !== 'function') throw new TypeError('runMap is required');

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

  async function invokeTool(name, args) {
    if (name === 'toolkit_find') {
      return runMap('find', {
        tool: args.tool,
        project: projectFrom(args),
        version: args.version || ''
      });
    }
    if (name === 'toolkit_status') {
      return runMap('status', {});
    }
    if (name === 'toolkit_doctor') {
      return runMap('doctor', {
        project: projectFrom(args),
        rulesFile: args.rulesFile || ''
      });
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
          const args = validateArguments(tool, params?.arguments);

          let result;
          try {
            result = await invokeTool(name, args);
          } catch (error) {
            if (error instanceof RpcError) throw error;
            return resultResponse(id, toolError(error, modern), false);
          }

          if (!result || typeof result !== 'object' || Array.isArray(result)) {
            return resultResponse(id, toolError(new Error('map.ps1 returned a non-object result'), modern), false);
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
