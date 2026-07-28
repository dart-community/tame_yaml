import 'package:tame_yaml/tame_yaml.dart';
import 'package:test/test.dart';

import 'src/helpers.dart';

void main() {
  group('byte order marks', () {
    test('accepts and discards one leading mark', () {
      expect(yamlDecode('\uFEFFname: Dash'), <String, Object?>{'name': 'Dash'});
    });

    test('accepts a mark inside quoted scalar content', () {
      expect(
        yamlDecode('single: \'a\uFEFFb\'\ndouble: "c\uFEFFd"'),
        <String, Object?>{
          'single': 'a\uFEFFb',
          'double': 'c\uFEFFd',
        },
      );
    });

    test('rejects a mark anywhere else', () {
      for (final source in const [
        '\uFEFF\uFEFFvalue',
        'value: before\uFEFFafter',
        'value: |\n  before\uFEFFafter',
        '# before\uFEFFafter',
        'value # before\uFEFFafter',
        '%YAML 1.2\uFEFF\n---\nvalue',
        'value: &anchor\uFEFF data',
        'value: *alias\uFEFF',
      ]) {
        expect(
          () => yamlDecode(source),
          throwsYaml(YamlErrorCode.invalidCharacter),
          reason: describeSource(source),
        );
      }
    });
  });

  group('line breaks', () {
    test('normalizes CRLF and lone CR in structure and block scalars', () {
      expect(
        yamlDecode(
          'literal: |\r\n  one\r  two\r\nfolded: >\r  three\r  four\r',
        ),
        <String, Object?>{
          'literal': 'one\ntwo\n',
          'folded': 'three four\n',
        },
      );
    });

    test('does not normalize an escaped carriage return', () {
      expect(yamlDecode('"escaped\\rvalue"'), 'escaped\rvalue');
    });

    for (final character in const ['\u0085', '\u2028', '\u2029']) {
      test(
        'treats ${_describeCodeUnit(character.codeUnitAt(0))} as content',
        () {
          expect(
            yamlDecode('before${character}after'),
            'before${character}after',
          );
        },
      );
    }
  });

  group('character ranges', () {
    test('rejects every excluded character-range boundary', () {
      const excluded = <int>[
        0x00,
        0x08,
        0x0B,
        0x0C,
        0x0E,
        0x1F,
        0x7F,
        0x84,
        0x86,
        0x9F,
        0xFFFE,
        0xFFFF,
      ];

      for (final codePoint in excluded) {
        final error = captureYamlException(
          () => yamlDecode('value: "${String.fromCharCode(codePoint)}"'),
        );
        expect(
          error.code,
          YamlErrorCode.invalidCharacter,
          reason: _describeCodeUnit(codePoint),
        );
        expect(
          error.toString(),
          endsWith('Escape it inside a double-quoted scalar.'),
          reason: _describeCodeUnit(codePoint),
        );
      }
    });

    test('rejects unpaired UTF-16 surrogates', () {
      for (final codeUnit in const [0xD800, 0xDBFF, 0xDC00, 0xDFFF]) {
        final error = captureYamlException(
          () => yamlDecode('value: ${String.fromCharCode(codeUnit)}'),
        );
        expect(
          error.code,
          YamlErrorCode.invalidCharacter,
          reason: _describeCodeUnit(codeUnit),
        );
        expect(
          error.toString(),
          endsWith('Replace it with a valid Unicode scalar value.'),
          reason: _describeCodeUnit(codeUnit),
        );
      }
    });

    test('accepts a surrogate pair as one astral character', () {
      expect(yamlDecode('value: 😀'), <String, Object?>{'value': '😀'});
    });

    test('allows tabs in content but not in indentation', () {
      expect(yamlDecode('value: before\tafter'), <String, Object?>{
        'value': 'before\tafter',
      });
      expect(
        () => yamlDecode('\tvalue: bad'),
        throwsYaml(YamlErrorCode.syntax),
      );
    });

    test('supports every double-quoted escape width', () {
      expect(yamlDecode(r'"\x41\u03A9\U0001F600"'), 'A\u03A9😀');
    });
  });
}

String _describeCodeUnit(int codeUnit) =>
    'U+${codeUnit.toRadixString(16).toUpperCase().padLeft(4, '0')}';
