#!/usr/bin/env python3
"""Writes Swift Codable types for the shapes that the app reads from ko.

usage: gen-ko-model.py OPENAPI CLIENT_MODEL OUTPUT

OPENAPI is share/ko/openapi.json and CLIENT_MODEL is share/ko/client-model.json. A shape that this
script cannot express stops it, so a schema change and the script change together.
"""
import json
import re
import sys

ROOTS = ['ModelJson', 'Edit', 'Edited', 'Candidate']
# ko's ids decode as the typed IDs of ID.swift, which validate them.
IDS = {'PaneId': 'PaneID', 'WindowId': 'WindowID', 'SessionId': 'SessionID'}
KEYWORDS = {
    'protocol', 'default', 'in', 'init', 'class', 'struct', 'enum', 'case', 'switch', 'for', 'as', 'is', 'true',
    'false', 'nil', 'repeat', 'return', 'throw', 'try', 'where', 'while', 'let', 'var', 'func', 'import', 'internal',
    'public', 'private', 'static', 'subscript', 'super', 'self', 'Type', 'Self', 'operator', 'extension', 'do',
    'if', 'else', 'guard', 'break', 'continue', 'defer', 'extension', 'fallthrough', 'open', 'typealias',
}
PREFIX = '#/components/schemas/'


def fail(message):
    sys.exit(f'gen-ko-model: {message}')


def camel(text):
    head, *rest = re.split(r'[_\-]', text)
    return head + ''.join(word[:1].upper() + word[1:] for word in rest)


def upper(text):
    text = camel(text)
    return text[:1].upper() + text[1:]


def ident(text):
    text = camel(text)
    if text == 'none':
        text = 'none_'
    return f'`{text}`' if text in KEYWORDS else text


class Generator:
    def __init__(self, schemas):
        self.schemas = schemas
        self.out = {}

    def ref(self, schema):
        target = schema['$ref']
        if not target.startswith(PREFIX) or target[len(PREFIX):] not in self.schemas:
            fail(f'unknown reference {target}')
        return target[len(PREFIX):]

    def resolve(self, schema):
        while '$ref' in schema:
            schema = self.schemas[self.ref(schema)]
        return schema

    def is_string(self, schema):
        schema = self.resolve(schema)
        if schema.get('type') == 'string' and 'enum' not in schema:
            return True
        alternatives = schema.get('anyOf')
        return bool(alternatives) and all(self.is_string(alternative) for alternative in alternatives)

    def nullable(self, schema):
        alternatives = schema.get('anyOf')
        if alternatives and len(alternatives) == 2 and {'type': 'null'} in alternatives:
            return [alternative for alternative in alternatives if alternative != {'type': 'null'}][0]
        return None

    def type_of(self, schema, where):
        if '$ref' in schema:
            return self.ref(schema)
        inner = self.nullable(schema)
        if inner is not None:
            return self.type_of(inner, where) + '?'
        kind = schema.get('type')
        if kind == 'string':
            return 'String'
        if kind == 'integer':
            return 'Int'
        if kind == 'number':
            return 'Double'
        if kind == 'boolean':
            return 'Bool'
        if kind == 'array':
            return f'[{self.type_of(schema["items"], where)}]'
        if kind == 'object' and 'properties' not in schema:
            extra = schema.get('additionalProperties', True)
            return '[String: JSONValue]' if extra is True else f'[String: {self.type_of(extra, where)}]'
        fail(f'{where}: cannot express {json.dumps(schema)[:200]}')

    def fields(self, schema, where, skip=()):
        """The properties of an object schema, with those of its allOf references."""
        properties, required = {}, set()
        for part in schema.get('allOf', []):
            inner = self.fields(self.resolve(part), where)
            properties.update(inner[0])
            required |= inner[1]
        properties.update(schema.get('properties', {}))
        required |= set(schema.get('required', []))
        for name in skip:
            properties.pop(name, None)
        return properties, required

    def struct(self, name, schema, skip=()):
        properties, required = self.fields(schema, name, skip)
        lines = [f'    public struct {name}: Codable, Equatable, Sendable {{']
        members, parameters, keys = [], [], []
        for key in sorted(properties):
            swift = ident(key)
            kind = self.type_of(properties[key], f'{name}.{key}')
            if key not in required and not kind.endswith('?'):
                kind += '?'
            members.append(f'        public var {swift}: {kind}')
            parameters.append(f'{swift}: {kind}' + (' = nil' if kind.endswith('?') else ''))
            keys.append(key)
        lines += members
        lines.append(f'        public init({", ".join(parameters)}) {{')
        lines += [f'            self.{ident(key)} = {ident(key)}' for key in keys]
        lines.append('        }')
        if any(camel(key) != key for key in keys):
            lines.append('        private enum CodingKeys: String, CodingKey {')
            lines += [f'            case {ident(key)}' + (f' = "{key}"' if camel(key) != key else '') for key in keys]
            lines.append('        }')
        lines.append('    }')
        self.out[name] = '\n'.join(lines)

    def string_enum(self, name, schema):
        lines = [f'    public enum {name}: String, Codable, Equatable, Sendable {{']
        for value in schema['enum']:
            raw = f' = "{value}"' if ident(value) != value else ''
            lines.append(f'        case {ident(value)}{raw}')
        lines.append('    }')
        self.out[name] = '\n'.join(lines)

    def tagged(self, name, schema):
        variants = schema['oneOf']
        tags = [{key for key, value in self.fields(variant, name)[0].items() if 'const' in value} for variant in variants]
        common = set.intersection(*tags)
        if len(common) != 1:
            fail(f'{name}: the variants share no single tag')
        tag = common.pop()
        shared = {key: value for key, value in schema.get('properties', {}).items()}
        shared_required = set(schema.get('required', []))
        cases, decodes, encodes, payloads = [], [], [], []
        for variant in variants:
            fields, required = self.fields(variant, name)
            value = fields[tag]['const']
            case = ident(value)
            own = {key: kind for key, kind in fields.items() if key != tag}
            reference = variant.get('allOf')
            if reference and len(reference) == 1 and not variant.get('properties', {}).keys() - {tag} and not shared:
                payload = self.ref(reference[0])
            elif own or shared:
                payload = name + upper(value)
                merged = {'properties': {**shared, **own}, 'required': sorted(shared_required | (required - {tag}))}
                payloads.append((payload, merged))
            else:
                payload = None
            if payload is None:
                cases.append(f'        case {case}')
                decodes.append(f'            case "{value}": self = .{case}')
                encodes.append(f'            case .{case}: try container.encode("{value}", forKey: .{ident(tag)})')
            else:
                cases.append(f'        case {case}({payload})')
                decodes.append(f'            case "{value}": self = .{case}(try {payload}(from: decoder))')
                encodes.append(f'            case .{case}(let value):\n'
                               f'                try container.encode("{value}", forKey: .{ident(tag)})\n'
                               f'                try value.encode(to: encoder)')
        key = ident(tag)
        lines = [f'    public enum {name}: Codable, Equatable, Sendable {{'] + cases
        lines += [
            f'        private enum Tag: String, CodingKey {{ case {key} = "{tag}" }}',
            '        public init(from decoder: Decoder) throws {',
            '            let container = try decoder.container(keyedBy: Tag.self)',
            f'            switch try container.decode(String.self, forKey: .{key}) {{',
        ] + decodes + [
            f'            case let other: throw DecodingError.dataCorruptedError(forKey: .{key}, in: container, debugDescription: "unknown {name} \\(other)")',
            '            }',
            '        }',
            '        public func encode(to encoder: Encoder) throws {',
            '            var container = encoder.container(keyedBy: Tag.self)',
            '            switch self {',
        ] + encodes + ['            }', '        }', '    }']
        self.out[name] = '\n'.join(lines)
        for payload, merged in payloads:
            self.struct(payload, merged)

    def untagged(self, name, schema):
        cases, decodes, payloads = [], [], []
        for index, alternative in enumerate(schema['anyOf']):
            if '$ref' in alternative:
                payload = self.ref(alternative)
                case = ident(payload[:1].lower() + payload[1:])
            else:
                required = alternative.get('required', [])
                if not required:
                    fail(f'{name}: an alternative has no required property to name it')
                case = ident(required[0])
                payload = name + upper(required[0])
                payloads.append((payload, alternative))
            cases.append(f'        case {case}({payload})')
            decodes.append(f'            if let value = try? {payload}(from: decoder) {{ self = .{case}(value); return }}')
        lines = [f'    public enum {name}: Codable, Equatable, Sendable {{'] + cases + [
            '        public init(from decoder: Decoder) throws {',
        ] + decodes + [
            f'            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no {name} alternative matches"))',
            '        }',
            '        public func encode(to encoder: Encoder) throws {',
            '            switch self {',
        ] + [f'            case .{line.split("case ")[1].split("(")[0]}(let value): try value.encode(to: encoder)' for line in cases] + [
            '            }', '        }', '    }']
        self.out[name] = '\n'.join(lines)
        for payload, alternative in payloads:
            self.struct(payload, alternative)

    def component(self, name):
        schema = self.schemas[name]
        if name in IDS:
            self.out[name] = f'    public typealias {name} = {IDS[name]}'
        elif self.is_string(schema):
            self.out[name] = f'    public typealias {name} = String'
        elif 'enum' in schema:
            self.string_enum(name, schema)
        elif schema.get('type') == 'integer':
            self.out[name] = f'    public typealias {name} = Int'
        elif schema.get('type') == 'boolean':
            self.out[name] = f'    public typealias {name} = Bool'
        elif 'oneOf' in schema:
            self.tagged(name, schema)
        elif 'anyOf' in schema:
            self.untagged(name, schema)
        elif schema.get('type') == 'object' and 'properties' in schema:
            self.struct(name, schema)
        elif schema.get('type') == 'object':
            self.out[name] = f'    public typealias {name} = {self.type_of(schema, name)}'
        else:
            fail(f'{name}: cannot express {json.dumps(schema)[:200]}')

    def reachable(self):
        seen, todo = set(), list(ROOTS)
        while todo:
            name = todo.pop()
            if name in seen:
                continue
            if name not in self.schemas:
                fail(f'root {name} is not in the schemas')
            seen.add(name)

            def walk(value):
                if isinstance(value, dict):
                    for key, inner in value.items():
                        if key == '$ref':
                            todo.append(inner[len(PREFIX):])
                        else:
                            walk(inner)
                elif isinstance(value, list):
                    for inner in value:
                        walk(inner)
            walk(self.schemas[name])
        return sorted(seen)


PREAMBLE = '''// Generated by scripts/gen-ko-model.py from share/ko/openapi.json and share/ko/client-model.json. Do not edit.
public enum KoSchema {
    public enum JSONValue: Codable, Equatable, Sendable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([JSONValue])
        case object([String: JSONValue])

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Int.self) { self = .int(value) }
            else if let value = try? container.decode(Double.self) { self = .double(value) }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
            else { self = .object(try container.decode([String: JSONValue].self)) }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null: try container.encodeNil()
            case .bool(let value): try container.encode(value)
            case .int(let value): try container.encode(value)
            case .double(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            }
        }
    }
'''


def main():
    if len(sys.argv) != 4:
        fail('usage: gen-ko-model.py OPENAPI CLIENT_MODEL OUTPUT')
    schemas = {}
    for path in sys.argv[1:3]:
        with open(path) as file:
            schemas.update(json.load(file)['components']['schemas'])
    generator = Generator(schemas)
    for name in generator.reachable():
        generator.component(name)
    body = '\n\n'.join(generator.out[name] for name in sorted(generator.out))
    with open(sys.argv[3], 'w') as file:
        file.write(PREAMBLE + '\n' + body + '\n}\n')


main()
