import spec from '../../../share/ko/openapi.json';

export type Schema = {
  $ref?: string; type?: string; description?: string; default?: unknown; const?: unknown; enum?: unknown[];
  properties?: Record<string, Schema>; required?: string[]; additionalProperties?: Schema | boolean;
  items?: Schema; prefixItems?: Schema[]; allOf?: Schema[]; oneOf?: Schema[]; anyOf?: Schema[];
  minimum?: number; maximum?: number; minLength?: number; maxLength?: number; minItems?: number; maxItems?: number;
  pattern?: string; contentMediaType?: string; contentEncoding?: string;
};
type Content = Record<string, { schema?: Schema }>;
export type Operation = {
  operationId: string; description: string;
  parameters?: { name: string; in: string; required: boolean; example?: unknown; schema: Schema }[];
  requestBody?: { content: Content };
  responses: Record<string, { description: string; content?: Content }>;
  'x-ko-websocket'?: { send?: Schema; recv?: Schema };
};

export const info = spec.info;
export const schemas = Object.entries(spec.components.schemas as Record<string, Schema>).sort(([a], [b]) => a.localeCompare(b));

const methods = ['get', 'post', 'put', 'patch', 'delete'];
const routes = Object.entries(spec.paths as Record<string, Record<string, Operation>>).flatMap(([path, item]) =>
  methods.filter((method) => item[method]).map((method) => ({ path, method, op: item[method] })));
export const groups = [...new Set(routes.map((route) => route.path.split('/')[1]))].map((slug) => ({
  slug,
  title: slug[0].toUpperCase() + slug.slice(1),
  routes: routes.filter((route) => route.path.split('/')[1] === slug),
}));

const esc = (text: string) => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const code = (text: string) => `<code>${esc(text)}</code>`;

export const prose = (text = '') =>
  text.split(/\n\s*\n/).filter(Boolean).map((part) =>
    `<p>${esc(part).replace(/\s*\n\s*/g, ' ').replace(/`([^`]+)`/g, '<code>$1</code>')}</p>`).join('');

const refName = (schema: Schema) => schema.$ref?.slice(schema.$ref.lastIndexOf('/') + 1);
const wraps = (schema: Schema) => (schema.allOf?.length === 1 && !schema.properties ? schema.allOf[0] : schema);

export const typeHtml = (given: Schema | boolean): string => {
  if (typeof given === 'boolean') return given ? 'any' : 'never';
  const schema = wraps(given);
  const name = refName(schema);
  if (name) return `<a href="#type-${name}">${name}</a>`;
  const union = schema.oneOf ?? schema.anyOf;
  if (union) return union.map(typeHtml).join(' | ');
  if ('const' in schema) return esc(JSON.stringify(schema.const));
  if (schema.enum) return schema.enum.map((value) => esc(JSON.stringify(value))).join(' | ');
  if (schema.prefixItems) return `[${schema.prefixItems.map(typeHtml).join(', ')}]`;
  if (schema.type === 'array') {
    const item = typeHtml(schema.items ?? true);
    return `${item.includes(' | ') ? `(${item})` : item}[]`;
  }
  if (schema.properties || schema.allOf) {
    const fields = Object.entries(schema.properties ?? {}).map(([field, value]) =>
      `${field}${schema.required?.includes(field) ? '' : '?'}: ${typeHtml(value)}`);
    return [...(schema.allOf ?? []).map(typeHtml), ...(fields.length ? [`{ ${fields.join(', ')} }`] : [])].join(' &amp; ');
  }
  if (schema.additionalProperties !== undefined) return `{ [name]: ${typeHtml(schema.additionalProperties)} }`;
  if (schema.type === 'object') return '{}';
  if (schema.contentMediaType) return 'bytes';
  return schema.type ?? 'any';
};

export const limits = (given: Schema): string => {
  const schema = wraps(given);
  const { minimum: min, maximum: max, minLength, maxLength, minItems, maxItems } = schema;
  return [
    min !== undefined && max !== undefined ? `${min} to ${max}` : min !== undefined ? `At least ${min}` : max !== undefined ? `At most ${max}` : '',
    minLength !== undefined && `At least ${minLength} characters`,
    maxLength !== undefined && `At most ${maxLength} characters`,
    minItems !== undefined && minItems === maxItems ? `${minItems} items` : '',
    schema.pattern && `Pattern ${code(schema.pattern)}`,
    schema.contentEncoding && `Encoding ${code(schema.contentEncoding)}`,
    given.default !== undefined && `Default ${code(JSON.stringify(given.default))}`,
  ].filter(Boolean).join('. ');
};

export const fields = (schema: Schema) =>
  Object.entries(schema.properties ?? {}).map(([name, value]) => ({ name, value, required: schema.required?.includes(name) ?? false }));

export const variants = (schema: Schema) => {
  const all = (schema.oneOf ?? []).map((value) => {
    const tag = fields(value).find((field) => 'const' in field.value);
    return tag && { value: { ...value, properties: Object.fromEntries(Object.entries(value.properties!).filter(([name]) => name !== tag.name)) }, tag: `${tag.name}: ${JSON.stringify(tag.value.const)}` };
  });
  return all.length > 0 && all.every((variant) => variant) ? all.map((variant) => variant!) : undefined;
};

export const body = (content: Content = {}) =>
  Object.entries(content).map(([media, { schema }]) => ({ media, schema: schema ?? {} }));
