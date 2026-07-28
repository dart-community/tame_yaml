import 'package:tame_yaml/tame_yaml.dart';
import 'package:test/test.dart';

import 'src/helpers.dart';

void main() {
  group('block collections', () {
    test('parses compact mappings in a sequence', () {
      expect(
        yamlDecode('''
- one: 1
  two: 2
- three: 3
'''),
        <Object?>[
          <String, Object?>{'one': 1, 'two': 2},
          <String, Object?>{'three': 3},
        ],
      );
    });

    test('parses an indentless sequence under a mapping key', () {
      expect(
        yamlDecode('''
items:
- one
- two
'''),
        <String, Object?>{
          'items': <Object?>['one', 'two'],
        },
      );
    });

    test('parses an explicit key', () {
      expect(
        yamlDecode('? explicit key\n: value'),
        <String, Object?>{'explicit key': 'value'},
      );
    });

    test('locates a zero-indented explicit collection key', () {
      final error = captureYamlException(
        () => yamlDecode('''
?
- one
- two
:
- value
'''),
      );

      expect(error.code, YamlErrorCode.nonStringKey);
      expect(error.line, 2);
      expect(error.column, 1);
    });

    test('applies inherited properties to nested collections', () {
      const expected = <String, Object?>{
        'items': <Object?>['one', 'two'],
      };
      expect(yamlDecode('items: !!seq\n  - one\n  - two\n'), expected);
      expect(yamlDecode('items: !!seq\n  [one, two]\n'), expected);
    });
  });

  group('flow collections', () {
    test('accepts nested flow mappings in a sequence', () {
      expect(
        yamlDecode('[{one: 1}, {two: 2}]'),
        <Object?>[
          <String, Object?>{'one': 1},
          <String, Object?>{'two': 2},
        ],
      );
    });

    test('rejects mapping entries in a sequence', () {
      for (final source in const [
        '[one: 1]',
        '[one: 1, two: 2]',
        '[one, two: 2]',
        '[? one : 1]',
        '[? one]',
        '[: 1]',
        '[one : 1]',
      ]) {
        expect(
          () => yamlDecode(source),
          throwsYaml(YamlErrorCode.unsupportedFlowEntry),
          reason: describeSource(source),
        );
      }
    });

    test('rejects mapping entries written without a value', () {
      for (final source in const [
        '{one}',
        '{one, two}',
        '{one, two: 2}',
        '{one: 1, two}',
        '{? one}',
        '{? }',
        '{? , two: 2}',
      ]) {
        expect(
          () => yamlDecode(source),
          throwsYaml(YamlErrorCode.unsupportedFlowEntry),
          reason: describeSource(source),
        );
      }
    });

    test('keeps an omitted value after the colon', () {
      expect(yamlDecode('{one: }'), <String, Object?>{'one': null});
      expect(yamlDecode('{one:, two: 2}'), <String, Object?>{
        'one': null,
        'two': 2,
      });
      expect(yamlDecode('{one: , two: 2}'), <String, Object?>{
        'one': null,
        'two': 2,
      });
    });

    test('reports an unterminated collection as a syntax error', () {
      // The missing ":" check must not claim an entry that simply ran out of
      // input before its "}".
      for (final source in const ['{key', '{key: value', '[one']) {
        expect(
          () => yamlDecode(source),
          throwsYaml(YamlErrorCode.syntax),
          reason: describeSource(source),
        );
      }
    });

    test('rejects an empty flow mapping entry', () {
      final error = captureYamlException(() => yamlDecode('{,}'));

      expect(error.code, YamlErrorCode.syntax);
      expect(error.message, 'Expected a mapping key.');
    });

    test('accepts explicit and implicit multiline keys', () {
      expect(
        yamlDecode('{? "multi\n   line" : value}\n'),
        <String, Object?>{'multi line': 'value'},
      );
      expect(
        yamlDecode('{"multi\n  line": value}\n'),
        <String, Object?>{'multi line': 'value'},
      );
    });
  });

  group('scalar styles', () {
    test('folds and chomps block scalars at end of input', () {
      expect(yamlDecode('>\n  one\n  two'), 'one two');
      expect(yamlDecode('|\n  one'), 'one');
      expect(yamlDecode('foo: |\n  x\n   '), <String, Object?>{
        'foo': 'x\n \n',
      });
    });

    test('rejects repeated block-scalar header indicators', () {
      for (final source in const [
        '|++\n  value',
        '>-+\n  value',
        '|11\n  value',
      ]) {
        final reason = describeSource(source);
        final error = captureYamlException(() => yamlDecode(source));
        expect(error.code, YamlErrorCode.syntax, reason: reason);
        expect(error.message, 'Invalid block scalar.', reason: reason);
      }
    });

    test('preserves every empty line folded into a plain scalar', () {
      expect(
        yamlDecode('value: first\n\n\n  second'),
        <String, Object?>{'value': 'first\n\nsecond'},
      );
      expect(
        yamlDecode('value: first\n\n\n\n  second'),
        <String, Object?>{'value': 'first\n\n\nsecond'},
      );
    });

    test('handles an escaped continuation containing blank lines', () {
      expect(
        yamlDecode('value: "one\\\n\n  two"\n'),
        <String, Object?>{'value': 'onetwo'},
      );
    });

    test('rejects malformed double-quoted escapes', () {
      for (final source in const [
        '"trailing\\',
        r'"\u12"',
        r'"\uD800"',
        r'"\U00110000"',
      ]) {
        expect(
          () => yamlDecode(source),
          throwsYaml(YamlErrorCode.syntax),
          reason: describeSource(source),
        );
      }
    });
  });

  group('malformed productions', () {
    test('rejects malformed node property lists', () {
      const cases = <(String, String)>[
        (
          'value: !<tag:yaml.org,2002:str>&anchor data',
          'Separate node properties.',
        ),
        ('value: &first &second data', 'Duplicate anchor property.'),
        ('value: !!str !!str data', 'Duplicate tag property.'),
        ('value: !!str\n  !!str data', 'Duplicate tag property.'),
        ('value: !<tag:yaml.org,2002:str data', 'Expected ">" after tag URI.'),
      ];

      for (final (source, message) in cases) {
        final reason = describeSource(source);
        final error = captureYamlException(() => yamlDecode(source));
        expect(error.code, YamlErrorCode.syntax, reason: reason);
        expect(error.message, message, reason: reason);
      }
    });

    test('rejects a compact collection after a tab separator', () {
      for (final source in const [
        '?\t- item',
        '?\t? nested\n: value',
        '?\tnested: value',
      ]) {
        final reason = describeSource(source);
        final error = captureYamlException(() => yamlDecode(source));
        expect(error.code, YamlErrorCode.syntax, reason: reason);
        expect(error.message, 'Invalid YAML indentation.', reason: reason);
      }
    });

    test('rejects an omitted compact mapping key in a block value', () {
      final error = captureYamlException(
        () => yamlDecode('outer: &key : value'),
      );

      expect(error.code, YamlErrorCode.syntax);
      expect(error.message, 'Block mapping not allowed.');
    });

    test('requires a colon after a flow-style block key', () {
      const source = 'first: value\n"second" trailing';
      final error = captureYamlException(() => yamlDecode(source));

      expect(error.code, YamlErrorCode.syntax);
      expect(error.message, 'Expected ":" after mapping key.');
      expect(error.offset, source.indexOf('"second"'));
    });

    test('locates a missing colon at the next block key', () {
      const source = 'first: value\nmissing\nnext: value';
      final error = captureYamlException(() => yamlDecode(source));

      expect(error.code, YamlErrorCode.syntax);
      expect(error.message, 'Expected ":" after mapping key.');
      expect(error.offset, source.indexOf('next'));
    });

    test('rejects indentation after a later quoted mapping value', () {
      const source = 'first: one\nsecond: "value"\n  unexpected';
      final error = captureYamlException(() => yamlDecode(source));

      expect(error.code, YamlErrorCode.syntax);
      expect(error.message, 'Invalid YAML indentation.');
      expect(error.offset, source.indexOf('unexpected'));
    });

    test('rejects an invalid implicit mapping-key start', () {
      const source = 'first: one\n@';
      final error = captureYamlException(() => yamlDecode(source));

      expect(error.code, YamlErrorCode.syntax);
      expect(error.message, 'Expected mapping key.');
      expect(error.offset, source.indexOf('@'));
    });

    test('rejects a mapping key made only of node properties', () {
      for (final source in const [
        'first: one\n&anchor : two',
        '? &anchor : value',
      ]) {
        expect(
          () => yamlDecode(source),
          throwsYaml(YamlErrorCode.nonStringKey),
          reason: describeSource(source),
        );
      }
    });

    test('handles CRLF before unexpected trailing block content', () {
      const source = 'root # comment\r\n  trailing';
      final error = captureYamlException(() => yamlDecode(source));

      expect(error.code, YamlErrorCode.syntax);
      expect(error.offset, source.indexOf('trailing'));
    });
  });

  group('lexical boundaries', () {
    test('does not mistake marker lookalikes for document markers', () {
      expect(yamlDecode('----'), '----');
      expect(yamlDecode('...value'), '...value');
      expect(
        yamlDecode('start: ---value\nend: ...value'),
        <String, Object?>{'start': '---value', 'end': '...value'},
      );
    });

    test('restricts a simple key to 1024 Unicode characters', () {
      // An astral character counts once, not once per UTF-16 code unit.
      for (final character in const ['k', '😀']) {
        final boundary = character * 1024;
        final accepted = <String, Object?>{boundary: 'value'};
        expect(yamlDecode('$boundary: value'), accepted);
        expect(yamlDecode('{$boundary: value}'), accepted);

        for (final source in [
          '$boundary$character: value',
          '{$boundary$character: value}',
        ]) {
          final error = captureYamlException(() => yamlDecode(source));
          expect(error.code, YamlErrorCode.syntax);
          expect(error.message, 'Simple key exceeds 1024 Unicode characters.');
        }
      }
    });
  });

  group('regressions', () {
    test('pins representative parser error locations', () {
      const cases = <(String, int)>[
        ('--- |10\n', 6),
        ('---\n"\\."\n', 5),
        ('---\nkey: value\n... invalid\n', 18),
        ('block: ># comment\n  scalar\n', 8),
      ];

      for (final (source, offset) in cases) {
        final reason = describeSource(source);
        final error = captureYamlException(() => yamlDecodeAll(source));
        expect(error.code, YamlErrorCode.syntax, reason: reason);
        expect(error.offset, offset, reason: reason);
      }
    });

    test('pins the error code of known parser edge cases', () {
      const cases = <String, YamlErrorCode>{
        '---\nkey: value\n... invalid': YamlErrorCode.syntax,
        '---\nflow: [a,\nb,\nc]': YamlErrorCode.syntax,
        '---\n[a, b, c, ]#comment': YamlErrorCode.syntax,
        '---\nblock: >#comment': YamlErrorCode.syntax,
        // The pair is rejected before its key's line span is measured.
        '---\n[ key\n  : value ]': YamlErrorCode.unsupportedFlowEntry,
        'foo: "bar\n\tbaz"': YamlErrorCode.syntax,
        'foo: |\n\t\nbar: 1': YamlErrorCode.syntax,
        '?\tkey:\n': YamlErrorCode.syntax,
        '!<%> value': YamlErrorCode.syntax,
        '!<%FF> value': YamlErrorCode.syntax,
      };

      for (final MapEntry(key: source, value: code) in cases.entries) {
        expect(
          () => yamlDecodeAll(source),
          throwsYaml(code),
          reason: describeSource(source),
        );
      }
    });
  });
}
