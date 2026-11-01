export const SERVER_NAME = 'toolkit-map';
export const SERVER_TITLE = 'toolkit-map';
export const MODERN_PROTOCOL_VERSION = '2026-07-28';
export const LEGACY_PROTOCOL_VERSIONS = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];

export const INSTRUCTIONS = [
  'Use toolkit_find before running a version-sensitive command (node, python, git, java, etc.).',
  'Pass the absolute project directory when you know it. Use only the returned absolute path,',
  'and only when ok is true and verification is "verified". toolkit-map never installs tools,',
  'changes PATH, or falls back to a version that does not satisfy the project requirement.',
  'When the result is not ok, report the requirement, the candidates found, and the current',
  'resolution instead of guessing. Install nothing unless the user explicitly asks for it.',
  'toolkit_scan, toolkit_update and toolkit_add are maintenance tools. They update the map',
  'file configured by the server and may update its generated Markdown summary; they never install',
  'tools and never change PATH. A changed or unrelated summary is preserved, with a warning. They return a',
  'planned preview unless the caller passes confirm:true; get explicit human authorization first.',
  'The preview reports the resolved map file, or marks it unknown; execution is refused while the target is unknown.',
  'Never retry with a client-chosen map file.'
].join(' ');

// Keep this list in sync with schemas/statuses.json. The MCP tests compare both.
export const STATUS_VALUES = [
  'ok',
  'planned',
  'already_available',
  'unverified',
  'not_found',
  'no_usable_candidate',
  'version_mismatch',
  'requirement_unsupported',
  'map_missing',
  'map_corrupt',
  'schema_unsupported',
  'map_busy',
  'attention_required',
  'operation_failed',
  'checksum_unavailable',
  'checksum_conflict',
  'version_unavailable',
  'installed_not_discovered',
  'installed_ambiguous',
  'installer_missing',
  'asset_missing',
  'executable_missing',
  'probe_failed',
  'environment_internal',
  'invalid_action',
  'invalid_argument',
  'invalid_path',
  'invalid_project',
  'rules_invalid',
  'scan_failed'
];

const RESULT_SCHEMA = {
  type: 'object',
  properties: {
    schemaVersion: { type: 'integer', const: 2 },
    action: { type: 'string', pattern: '^[a-z][a-z0-9_-]*$' },
    ok: { type: 'boolean' },
    // No enum: a future minor may add a status, and a strict client must still
    // be able to render the result. Unknown statuses are classified in
    // protocol.mjs against STATUS_VALUES, never by the schema.
    status: { type: 'string', pattern: '^[a-z][a-z0-9_-]*$' },
    tool: { type: 'string' },
    requestedTool: { type: 'string' },
    found: { type: 'boolean' },
    path: { type: 'string' },
    version: { type: 'string' },
    source: { type: 'string' },
    note: { type: 'string' },
    verification: { type: 'string', enum: ['verified', 'unverified', 'unavailable', 'skipped', ''] },
    reason: { type: 'string' },
    requirement: { type: 'object', additionalProperties: true },
    invocation: {
      oneOf: [
        { type: 'object', additionalProperties: true },
        { type: 'null' }
      ]
    },
    search: { type: 'object', additionalProperties: true },
    candidates: { type: 'array', items: { type: 'object', additionalProperties: true } },
    hint: { type: 'string' },
    message: { type: 'string' },
    mapFile: { type: 'string' },
    mapFileKnown: { type: 'boolean' },
    mapFileSource: { type: 'string' },
    mapFileHint: { type: 'string' },
    summaryWarning: { type: 'string' },
    preview: { type: 'string' },
    prefer: { type: 'boolean' },
    executed: { type: 'boolean' },
    confirmRequired: { type: 'boolean' }
  },
  required: ['schemaVersion', 'action', 'ok', 'status'],
  additionalProperties: true
};

const READ_ONLY_ANNOTATIONS = {
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false
};

const MAINTENANCE_ANNOTATIONS = {
  readOnlyHint: false,
  // destructiveHint is intentionally omitted. scan and update can drop
  // auto-discovered records, so claiming non-destructive would be false; the
  // MCP default for an omitted hint is true.
  idempotentHint: false,
  // Maintenance actions may execute arbitrary programs while probing versions.
  openWorldHint: true
};

const CONFIRM_PROPERTY = {
  type: 'boolean',
  default: false,
  description: [
    'Defaults to false, which returns only a structured planned preview and does not run the map action.',
    'Pass true to execute only when the preview identifies the map target; an unknown target is rejected.',
    'This flag is a workflow guard, not a permission or security boundary; candidate',
    'version probing may execute programs found on this machine, so obtain explicit human authorization first.'
  ].join(' ')
};

const PROJECT_PROPERTY = {
  type: 'string',
  description: 'Absolute path to the project whose declaration files should be read. Relative paths and Windows device or drive-relative paths are rejected. Defaults to TOOLKIT_MAP_PROJECT or the server working directory.'
};

export const TOOLS = [
  {
    name: 'toolkit_find',
    title: 'Find a verified tool for a project',
    description: [
      'Look up which local copy of a tool the project should use and return its verified absolute path.',
      'Call this before running node, python, git or another version-sensitive command instead of relying on PATH,',
      '`where`, `Get-Command` or `node --version`. The result distinguishes the project requirement, all verified',
      'candidates, and the selected path. It never installs anything or changes PATH. If ok is false, do not run a',
      'different version as a fallback; report the gap or ask the user.'
    ].join(' '),
    inputSchema: {
      type: 'object',
      properties: {
        tool: {
          type: 'string',
          description: 'Tool name to look up, for example node, python, git or java. Command paths and separators are rejected.',
          examples: ['node', 'python', 'git']
        },
        project: PROJECT_PROPERTY,
        version: {
          type: 'string',
          description: 'Optional explicit version range. Overrides project declarations for this lookup only, for example ">=18" or "22".'
        }
      },
      required: ['tool'],
      additionalProperties: false
    },
    outputSchema: RESULT_SCHEMA,
    annotations: READ_ONLY_ANNOTATIONS
  },
  {
    name: 'toolkit_status',
    title: 'Check toolkit-map freshness',
    description: [
      'Report whether the local tool map exists, how old the last full scan is, whether PATH changed, and how many',
      'registered files are missing. Read-only. Use it when a lookup looks stale or before trusting results after',
      'installing or moving tools.'
    ].join(' '),
    inputSchema: {
      type: 'object',
      properties: {},
      additionalProperties: false
    },
    outputSchema: RESULT_SCHEMA,
    annotations: READ_ONLY_ANNOTATIONS
  },
  {
    name: 'toolkit_doctor',
    title: 'Diagnose toolkit-map integration',
    description: [
      'Run read-only checks for the PowerShell host, map file, freshness and the rule block in the selected project.',
      'Use it when toolkit_find fails unexpectedly or when the user asks whether agent integration is configured.',
      'agentVerified is always false: this cannot prove that a model actually follows the rules.'
    ].join(' '),
    inputSchema: {
      type: 'object',
      properties: {
        project: PROJECT_PROPERTY,
        rulesFile: {
          type: 'string',
          description: 'Optional absolute path to the rule file to inspect instead of <project>/AGENTS.md. Relative paths and Windows device or drive-relative paths are rejected.'
        }
      },
      additionalProperties: false
    },
    outputSchema: RESULT_SCHEMA,
    annotations: READ_ONLY_ANNOTATIONS
  },
  {
    name: 'toolkit_scan',
    title: 'Refresh the tool map with an explicit confirmation',
    description: [
      'Maintenance action that scans this machine and refreshes the server-configured tool map. It never installs',
      'tools and never changes PATH. By default it returns only a structured planned preview and runs nothing;',
      'pass confirm:true to execute the scan. Scanning probes candidate versions and may execute programs found',
      'on this machine, so obtain explicit human authorization first. The preview reports the resolved absolute',
      'map path, or marks it unknown when the server cannot determine it without running map.ps1. confirm is a',
      'workflow guard, not a permission or security boundary. Client arguments cannot select a different map file.'
    ].join(' '),
    inputSchema: {
      type: 'object',
      properties: {
        confirm: CONFIRM_PROPERTY
      },
      additionalProperties: false
    },
    outputSchema: RESULT_SCHEMA,
    annotations: MAINTENANCE_ANNOTATIONS
  },
  {
    name: 'toolkit_update',
    title: 'Re-probe registered tools with an explicit confirmation',
    description: [
      'Maintenance action that re-probes one registered tool, or every registered tool when tool is omitted, and',
      'updates the server-configured map. It never installs tools and never changes PATH. By default it returns',
      'only a structured planned preview and runs nothing; pass confirm:true to execute. Candidate version probing',
      'may execute programs found on this machine, so obtain explicit human authorization first. The preview reports',
      'the resolved absolute map path, or marks it unknown when the server cannot determine it without running',
      'map.ps1. confirm is a workflow guard, not a permission or security boundary. Client arguments cannot select',
      'a different map file.'
    ].join(' '),
    inputSchema: {
      type: 'object',
      properties: {
        tool: {
          type: 'string',
          description: 'Optional tool name to re-probe, for example node. When omitted, every registered tool is updated. Command paths and separators are rejected.'
        },
        confirm: CONFIRM_PROPERTY
      },
      additionalProperties: false
    },
    outputSchema: RESULT_SCHEMA,
    annotations: MAINTENANCE_ANNOTATIONS
  },
  {
    name: 'toolkit_add',
    title: 'Register an existing executable with an explicit confirmation',
    description: [
      'Maintenance action that registers an existing executable in the server-configured map without moving or',
      'installing it. It never changes PATH. By default it returns only a structured planned preview and runs',
      'nothing; pass confirm:true to execute. The path must be absolute. version is a probe hint: toolkit-map',
      'still probes the executable and only falls back to the hint when probing cannot report a version, so',
      'probing may execute the program. Obtain explicit human authorization first. The preview reports the',
      'resolved map file when the server can determine it without running map.ps1. confirm is a workflow guard,',
      'not a permission or security boundary. Client arguments cannot select a different map file.'
    ].join(' '),
    inputSchema: {
      type: 'object',
      properties: {
        tool: {
          type: 'string',
          description: 'Tool name to register, for example node. Command paths and separators are rejected.'
        },
        path: {
          type: 'string',
          description: 'Absolute path to the existing executable (Windows drive/UNC or POSIX). Relative paths are rejected.'
        },
        note: {
          type: 'string',
          description: 'Optional human note to keep with this candidate.'
        },
        version: {
          type: 'string',
          description: 'Optional version hint recorded only when probing cannot report a version. It does not disable probing: toolkit-map still executes the program, so obtain explicit human authorization first.'
        },
        prefer: {
          type: 'boolean',
          default: false,
          description: 'When true, also mark this path as the preferred copy for the tool.'
        },
        confirm: CONFIRM_PROPERTY
      },
      required: ['tool', 'path'],
      additionalProperties: false
    },
    outputSchema: RESULT_SCHEMA,
    annotations: MAINTENANCE_ANNOTATIONS
  }
];

export function findTool(name) {
  return TOOLS.find((tool) => tool.name === name) || null;
}
