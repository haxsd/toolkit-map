function typeMatches(type, value) {
  switch (type) {
    case 'object': return value !== null && typeof value === 'object' && !Array.isArray(value);
    case 'array': return Array.isArray(value);
    case 'string': return typeof value === 'string';
    case 'boolean': return typeof value === 'boolean';
    case 'integer': return Number.isInteger(value);
    case 'number': return typeof value === 'number' && Number.isFinite(value);
    case 'null': return value === null;
    default: return true;
  }
}

function resolveRef(root, ref) {
  if (!ref.startsWith('#/')) throw new Error(`Only local $ref is supported: ${ref}`);
  const parts = ref.slice(2).split('/').map((part) => part.replace(/~1/g, '/').replace(/~0/g, '~'));
  let node = root;
  for (const part of parts) {
    if (!node || typeof node !== 'object' || !(part in node)) {
      throw new Error(`Unresolvable $ref: ${ref}`);
    }
    node = node[part];
  }
  return node;
}

export function validate(schema, value, root = schema) {
  const errors = [];

  function add(path, message) {
    errors.push({ path, message });
  }

  function check(node, current, path) {
    if (!node || typeof node !== 'object') return;

    if (node.$ref) {
      check(resolveRef(root, node.$ref), current, path);
      return;
    }

    if (node.type) {
      const types = Array.isArray(node.type) ? node.type : [node.type];
      if (!types.some((type) => typeMatches(type, current))) {
        add(path, `expected type ${types.join('|')}, got ${current === null ? 'null' : Array.isArray(current) ? 'array' : typeof current}`);
        return;
      }
    }

    if (Object.prototype.hasOwnProperty.call(node, 'const') && current !== node.const) {
      add(path, `expected const ${JSON.stringify(node.const)}, got ${JSON.stringify(current)}`);
    }

    if (Array.isArray(node.enum) && !node.enum.includes(current)) {
      add(path, `expected one of ${node.enum.join('|')}, got ${JSON.stringify(current)}`);
    }

    if (typeof node.pattern === 'string' && typeof current === 'string' && !new RegExp(node.pattern).test(current)) {
      add(path, `does not match pattern ${node.pattern}`);
    }

    if (Array.isArray(node.oneOf)) {
      const matches = node.oneOf.filter((branch) => validate(branch, current, root).length === 0);
      if (matches.length !== 1) {
        add(path, `expected exactly one oneOf match, got ${matches.length}`);
      }
    }

    if (current !== null && typeof current === 'object' && !Array.isArray(current)) {
      for (const required of node.required || []) {
        if (!Object.prototype.hasOwnProperty.call(current, required)) {
          add(path, `missing required property ${required}`);
        }
      }
      if (node.propertyNames) {
        for (const key of Object.keys(current)) check(node.propertyNames, key, `${path}.${key}`);
      }
      for (const [key, child] of Object.entries(node.properties || {})) {
        if (Object.prototype.hasOwnProperty.call(current, key)) {
          check(child, current[key], `${path}.${key}`);
        }
      }
      if (node.additionalProperties && typeof node.additionalProperties === 'object') {
        const known = new Set(Object.keys(node.properties || {}));
        for (const [key, child] of Object.entries(current)) {
          if (!known.has(key)) check(node.additionalProperties, child, `${path}.${key}`);
        }
      }
    }

    if (Array.isArray(current) && node.items) {
      current.forEach((item, index) => check(node.items, item, `${path}[${index}]`));
    }
  }

  check(schema, value, '$');
  return errors;
}
