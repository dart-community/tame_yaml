A decoder for a strict, unambiguous subset of YAML 1.2 that
produces immutable values of built-in Dart types.

Decoded values are built only from `null`, `bool`, `int`, `double`,
`String`, `List<Object?>`, and `Map<String, Object?>`.
As a result, type tests, casts, and patterns work directly on decoded data.

YAML that this data model can't represent predictably,
that's easy to write by accident, or that can be misread
is rejected rather than coerced.

The public decoding API consists of `yamlDecode`, `yamlDecodeAll`,
`YamlException`, and `YamlErrorCode`. There is no encoder.

## Usage

```dart
import 'package:tame_yaml/tame_yaml.dart';

void main() {
  final config = yamlDecode('''
server:
  host: localhost
  port: 8080
debug: false
''');

  if (config
      case {
        'server': {'host': final String host, 'port': final int port},
        'debug': final bool debug,
      }) {
    print('$host:$port (debug: $debug)');
  } else {
    throw const FormatException('Invalid configuration.');
  }
}
```

Every collection is recursively unmodifiable,
and every mapping keeps its source order.
For a single-document source, use `yamlDecode`.
For a source with multiple documents, use `yamlDecodeAll`.

## The strict profile

`tame_yaml` implements revision 1.2.2 of the YAML specification
but accepts only a strict subset of it,
restricted for clarity and for fit with Dart's native value types.
The subset covers:

- Block collections, and flow collections with
  JSON's structure plus trailing commas.
- Plain, quoted, literal, and folded scalars,
  resolved with the YAML 1.2 core schema.
- String mapping keys, with duplicates rejected.
- The YAML core tags, each validated against the node it's written on.
- Aliases to previously defined anchors, expanded as independent deep copies.

Everything else fails with an error instead of
being coerced or silently reinterpreted:
non-string keys, custom tags, merge keys, recursive aliases,
other YAML versions, and spellings that can be misinterpreted,
such as the integer `0644`.
The [API documentation][] specifies the exact profile,
its deliberate deviations from the specification,
and the fixed safety limits.

[API documentation]: https://pub.dev/documentation/tame_yaml/latest/

## Error handling

Every failure is a `YamlException`, a `FormatException` with a
stable `YamlErrorCode` to branch on and a precise source location.
Printing one is usually enough:

```dart
try {
  yamlDecode('port: 8080\nport: 9090', sourceUrl: Uri.file('config.yaml'));
} on YamlException catch (error) {
  print(error);
}
```

```text
YamlException (duplicateKey): Duplicate mapping key "port".
config.yaml:2:1

   1 | port: 8080
     | ^^^^ First declared here.

   2 | port: 9090
     | ^^^^ Declared again here.

Remove or rename one key.
```
