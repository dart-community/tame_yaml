import 'package:tame_yaml/tame_yaml.dart';
import 'package:test/test.dart';

import 'src/helpers.dart';

void main() {
  group('document API', () {
    test('decodes a stream without documents as empty', () {
      for (final source in const ['', '   \n', '# only a comment']) {
        final reason = describeSource(source);
        expect(yamlDecodeAll(source), isEmpty, reason: reason);
        expect(yamlDecode(source), isNull, reason: reason);
      }
    });

    test('decodes a bare document marker as one null document', () {
      expect(yamlDecodeAll('---'), <Object?>[null]);
      expect(yamlDecode('---'), isNull);
    });

    test('decodes a single document as its root value', () {
      expect(yamlDecodeAll('a: 1'), <Object?>[
        <String, Object?>{'a': 1},
      ]);
      expect(yamlDecode('a: 1'), <String, Object?>{'a': 1});
    });

    test('decodes multiple documents in source order', () {
      expect(
        yamlDecodeAll('''
---
name: first
...
---
name: second
'''),
        <Object?>[
          <String, Object?>{'name': 'first'},
          <String, Object?>{'name': 'second'},
        ],
      );
    });

    test('returns an unmodifiable list of documents', () {
      expect(() => yamlDecodeAll('a: 1').add(null), throwsUnsupportedError);
    });

    test('rejects a stream of several documents in yamlDecode', () {
      expect(yamlDecodeAll('---\n---'), <Object?>[null, null]);
      expect(
        () => yamlDecode('---\n---'),
        throwsYaml(YamlErrorCode.documentCount),
      );
    });

    test('uses sourceUrl only for diagnostics', () {
      final sourceUrl = Uri.parse('file:///tmp/config.yaml');
      expect(
        yamlDecode('answer: 42', sourceUrl: sourceUrl),
        <String, Object?>{'answer': 42},
      );

      final error = captureYamlException(
        () => yamlDecode('[', sourceUrl: sourceUrl),
      );
      expect(error.sourceUrl, sourceUrl);
      expect(error.toString(), contains(sourceUrl.toString()));
    });
  });

  group('native data model', () {
    test('supports Dart type tests and nested patterns', () {
      final data = yamlDecode('''
server:
  host: localhost
  port: 8080
debug: false
features: [yaml, patterns]
''');

      expect(data, isA<Map<String, Object?>>());
      switch (data) {
        case {
          'server': {'host': final String host, 'port': final int port},
          'debug': final bool debug,
          'features': [final String first, final String second],
        }:
          expect(
            (host, port, debug, first, second),
            ('localhost', 8080, false, 'yaml', 'patterns'),
          );
        default:
          fail('Decoded data did not match the documented native shape.');
      }
    });

    test('preserves mapping insertion order', () {
      final map =
          yamlDecode('third: 3\nfirst: 1\nsecond: 2') as Map<String, Object?>;
      expect(map.keys, <String>['third', 'first', 'second']);
    });
  });

  group('immutable collections', () {
    late Map<String, Object?> root;
    late List<Object?> list;

    setUp(() {
      root =
          yamlDecode('''
list:
  - {nested: []}
map: {}
''')
              as Map<String, Object?>;
      list = root['list'] as List<Object?>;
    });

    test('rejects every mutating map operation', () {
      expect(() => root['new'] = true, throwsUnsupportedError);
      expect(
        () => root.addAll(<String, Object?>{'new': true}),
        throwsUnsupportedError,
      );
      expect(
        () => root.addEntries([const MapEntry('new', true)]),
        throwsUnsupportedError,
      );
      expect(() => root.putIfAbsent('new', () => true), throwsUnsupportedError);
      expect(() => root.update('list', (_) => null), throwsUnsupportedError);
      expect(() => root.updateAll((_, _) => null), throwsUnsupportedError);
      expect(() => root.remove('list'), throwsUnsupportedError);
      expect(() => root.removeWhere((_, _) => true), throwsUnsupportedError);
      expect(root.clear, throwsUnsupportedError);
    });

    test('rejects every mutating list operation', () {
      expect(() => list[0] = null, throwsUnsupportedError);
      expect(() => list.add(null), throwsUnsupportedError);
      expect(() => list.addAll(const <Object?>[]), throwsUnsupportedError);
      expect(() => list.insert(0, null), throwsUnsupportedError);
      expect(
        () => list.insertAll(0, const <Object?>[]),
        throwsUnsupportedError,
      );
      expect(() => list.setAll(0, const <Object?>[]), throwsUnsupportedError);
      expect(() => list.remove(null), throwsUnsupportedError);
      expect(() => list.removeAt(0), throwsUnsupportedError);
      expect(list.removeLast, throwsUnsupportedError);
      expect(() => list.removeRange(0, 0), throwsUnsupportedError);
      expect(() => list.removeWhere((_) => true), throwsUnsupportedError);
      expect(() => list.retainWhere((_) => true), throwsUnsupportedError);
      expect(list.clear, throwsUnsupportedError);
      expect(() => list.fillRange(0, 0), throwsUnsupportedError);
      expect(
        () => list.replaceRange(0, 0, const <Object?>[]),
        throwsUnsupportedError,
      );
      expect(
        () => list.setRange(0, 0, const <Object?>[]),
        throwsUnsupportedError,
      );
      expect(list.sort, throwsUnsupportedError);
      expect(list.shuffle, throwsUnsupportedError);
      expect(() => list.length = 0, throwsUnsupportedError);
    });

    test('freezes nested and empty collections', () {
      final nested = list.single as Map<String, Object?>;
      final emptyList = nested['nested'] as List<Object?>;
      final emptyMap = root['map'] as Map<String, Object?>;

      expect(() => nested['new'] = true, throwsUnsupportedError);
      expect(() => emptyList.add(null), throwsUnsupportedError);
      expect(() => emptyMap['new'] = true, throwsUnsupportedError);
    });
  });

  test('exposes an exhaustively switchable YamlErrorCode', () {
    // Adding a code without updating this switch is a compile-time error,
    // which is the guarantee the test exists to protect.
    String describe(YamlErrorCode code) => switch (code) {
      YamlErrorCode.syntax => 'syntax',
      YamlErrorCode.unsupportedVersion => 'unsupportedVersion',
      YamlErrorCode.invalidDirective => 'invalidDirective',
      YamlErrorCode.invalidCharacter => 'invalidCharacter',
      YamlErrorCode.nonStringKey => 'nonStringKey',
      YamlErrorCode.duplicateKey => 'duplicateKey',
      YamlErrorCode.unsupportedFlowEntry => 'unsupportedFlowEntry',
      YamlErrorCode.unsupportedTag => 'unsupportedTag',
      YamlErrorCode.invalidTaggedValue => 'invalidTaggedValue',
      YamlErrorCode.mergeKey => 'mergeKey',
      YamlErrorCode.unsupportedAnchorName => 'unsupportedAnchorName',
      YamlErrorCode.undefinedAlias => 'undefinedAlias',
      YamlErrorCode.recursiveAlias => 'recursiveAlias',
      YamlErrorCode.documentCount => 'documentCount',
      YamlErrorCode.integerOutOfRange => 'integerOutOfRange',
      YamlErrorCode.leadingZeroInteger => 'leadingZeroInteger',
      YamlErrorCode.resourceLimit => 'resourceLimit',
    };

    for (final code in YamlErrorCode.values) {
      expect(describe(code), code.name);
    }
  });
}
