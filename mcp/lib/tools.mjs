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
  'resolution instead of guessing. Install nothing unless the user explicitly asks for it.'
].join(' ');

const RESULT_SCHEMA = {
  type: 'object',
  properties: {
    schemaVersion: { type: 'integer' },
    action: { type: 'string' },
    ok: { type: 'boolean' },
    status: { type: 'string' },
    tool: { type: 'string' },
    requestedTool: { type: 'string' },
    found: { type: 'boolean' },
    path: { type: 'string' },
    version: { type: 'string' },
    verification: { type: 'string' },
    reason: { type: 'string' },
    requirement: { type: 'object', additionalProperties: true },
    invocation: { type: 'object', additionalProperties: true },
    search: { type: 'object', additionalProperties: true },
    candidates: { type: 'array', items: { type: 'object', additionalProperties: true } },
    hint: { type: 'string' },
    message: { type: 'string' }
  },
  required: ['ok', 'status'],
  additionalProperties: true
};

const READ_ONLY_ANNOTATIONS = {
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false
};

const PROJECT_PROPERTY = {
  type: 'string',
  description: 'Absolute path to the project whose declaration files should be read. Defaults to TOOLKIT_MAP_PROJECT or the server working directory.'
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
          description: 'Optional absolute path to the rule file to inspect instead of <project>/AGENTS.md.'
        }
      },
      additionalProperties: false
    },
    outputSchema: RESULT_SCHEMA,
    annotations: READ_ONLY_ANNOTATIONS
  }
];

export function findTool(name) {
  return TOOLS.find((tool) => tool.name === name) || null;
}
