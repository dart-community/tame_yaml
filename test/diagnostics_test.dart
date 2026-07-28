import 'package:tame_yaml/tame_yaml.dart';
import 'package:test/test.dart';

import 'src/helpers.dart';

void main() {
  group('error precedence', () {
    test('validates the whole stream before parsing', () {
      const source = '42: value\nlater: [\u0000';
      final error = captureYamlException(() => yamlDecode(source));
      expect(error.code, YamlErrorCode.invalidCharacter);
      expect(error.offset, source.indexOf('\u0000'));
    });

    test('lets later syntax override a deferred profile error', () {
      for (final source in const [
        '42: value\nlater: [',
        'tagged: !custom value\nlater: [',
      ]) {
        final reason = describeSource(source);
        final error = captureYamlException(() => yamlDecode(source));
        expect(error.code, YamlErrorCode.syntax, reason: reason);
        expect(error.offset, source.length, reason: reason);
      }
    });

    test('lets an immediate alias failure override a profile error', () {
      expect(
        () => yamlDecode('42: value\nlater: *missing'),
        throwsYaml(YamlErrorCode.undefinedAlias),
      );
    });

    test('lets an immediate resource failure override a profile error', () {
      final tooDeep = '${'[' * 101}null${']' * 101}';
      expect(
        () => yamlDecode('42: value\nlater: $tooDeep'),
        throwsYaml(YamlErrorCode.resourceLimit),
      );
    });

    test('reports a completed document before examining the next one', () {
      expect(
        () => yamlDecodeAll('42: value\n...\n%YAML 1.1\n---\nnext'),
        throwsYaml(YamlErrorCode.nonStringKey),
      );
      expect(
        () => yamlDecode('42: value\n---\nnext'),
        throwsYaml(YamlErrorCode.nonStringKey),
      );
    });

    test('validates a mapping key before parsing its value', () {
      final nonString = captureYamlException(
        () => yamlDecode('42: !!int nope'),
      );
      expect(nonString.code, YamlErrorCode.nonStringKey);
      expect(nonString.offset, 0);

      const duplicateSource = 'key: one\nkey: !!int nope';
      final duplicate = captureYamlException(
        () => yamlDecode(duplicateSource),
      );
      expect(duplicate.code, YamlErrorCode.duplicateKey);
      expect(duplicate.offset, duplicateSource.lastIndexOf('key'));
    });
  });

  group('error locations', () {
    test('reports UTF-16 offsets, lines, and columns', () {
      const source = 'value: [😀, @]';
      final error = captureYamlException(() => yamlDecode(source));

      expect(error.code, YamlErrorCode.syntax);
      expect(error.offset, source.indexOf('@'));
      expect(error.line, 1);
      expect(error.column, source.indexOf('@') + 1);
      expect(error.toString(), contains('^'));
      expect(error.toString(), contains('value: [😀, @]'));
    });

    test('counts CRLF as one line break', () {
      const source = 'first: ok\r\nsecond: [\r\n';
      final error = captureYamlException(() => yamlDecode(source));

      expect(error.line, 3);
      expect(error.column, 1);
      expect(error.offset, source.length);
    });
  });

  group('message formatting', () {
    test('does not retain the full source in the public exception', () {
      final source = '${'prefix' * 1000}\ninvalid: [';
      final error = captureYamlException(() => yamlDecode(source));

      expect(error.source, isNull);
      expect(error.toString().length, lessThan(1000));
    });

    test('bounds a source-derived key', () {
      final key = 'key' * 50000;
      final error = captureYamlException(
        () => yamlDecode('? "$key"\n: first\n? "$key"\n: second'),
      );

      expect(error.code, YamlErrorCode.duplicateKey);
      expect(error.message.length, lessThan(1000));
      expect(error.toString().length, lessThan(2000));
    });

    test('bounds a source-derived alias name', () {
      final error = captureYamlException(() => yamlDecode('*${'a' * 100000}'));

      expect(error.code, YamlErrorCode.undefinedAlias);
      expect(error.message.length, lessThan(1000));
    });

    test('escapes a source-derived value into a single-line message', () {
      const encodedKey =
          r'tab\tline\nreturn\rquote\"slash\\control\x01'
          r'next\u0085line\u2028paragraph\u2029bom\uFEFF';
      const source = '"$encodedKey": first\n"$encodedKey": second';
      final error = captureYamlException(() => yamlDecode(source));

      expect(error.code, YamlErrorCode.duplicateKey);
      expect(
        error.message,
        'Duplicate mapping key '
        '"tab\\tline\\nreturn\\rquote\\"slash\\\\control'
        '\\u0001next\\u0085line\\u2028paragraph\\u2029bom\\ufeff".',
      );
      expect(error.message, isNot(contains('\n')));
      expect(error.message, isNot(contains('\r')));
    });

    test('renders an unpaired surrogate as the replacement character', () {
      final error = captureYamlException(
        () => yamlDecode(String.fromCharCode(0xD800)),
      );

      expect(error.code, YamlErrorCode.invalidCharacter);
      expect(error.toString(), contains('�'));
    });

    test('truncates a source-derived value outside surrogate pairs', () {
      final key = '${'a' * 79}😀tail';
      final error = captureYamlException(
        () => yamlDecode('"$key": first\n"$key": second'),
      );

      expect(error.code, YamlErrorCode.duplicateKey);
      expect(error.message, 'Duplicate mapping key "${'a' * 79}…".');
      _expectWellFormedUtf16(error.message);
    });

    test('truncates a source excerpt outside surrogate pairs', () {
      final source =
          '["${'a' * 37}😀${'b' * 56}", '
          '@${'c' * 57}😀d]';
      final error = captureYamlException(() => yamlDecode(source));
      final formatted = error.toString();
      final sourceLine = formatted
          .split('\n')
          .singleWhere((line) => line.startsWith('   1 | '));

      expect(error.code, YamlErrorCode.syntax);
      expect(error.offset, 100);
      expect(sourceLine, startsWith('   1 | …😀'));
      expect(sourceLine, endsWith('${'c' * 57}…'));
      expect('😀'.allMatches(sourceLine), hasLength(1));
      _expectWellFormedUtf16(formatted);
    });
  });

  group('error codes', () {
    test('maps unclassified malformed input to a syntax error', () {
      for (final source in const [
        '[',
        '{key',
        '"unterminated',
        r'"bad\qescape"',
        '!<> value',
        '!! value',
        '%TAG !y! tag:yaml.org,2002:\n---\n!y! value',
        'mapping: [one,, two]',
        '[one two',
        'key: value\n- sequence',
      ]) {
        expect(
          () => yamlDecode(source),
          throwsYaml(YamlErrorCode.syntax),
          reason: describeSource(source),
        );
      }
    });

    test('reports every YamlErrorCode from at least one input', () {
      final sources = <YamlErrorCode, String>{
        YamlErrorCode.syntax: '[',
        YamlErrorCode.unsupportedVersion: '%YAML 1.1\n---\nvalue',
        YamlErrorCode.invalidDirective: '%UNKNOWN value\n---\nvalue',
        YamlErrorCode.invalidCharacter: 'value: \u0000',
        YamlErrorCode.nonStringKey: '42: value',
        YamlErrorCode.duplicateKey: 'key: one\nkey: two',
        YamlErrorCode.unsupportedFlowEntry: '[key: value]',
        YamlErrorCode.unsupportedTag: 'value: !custom data',
        YamlErrorCode.invalidTaggedValue: 'value: !!int nope',
        YamlErrorCode.mergeKey: '<<: value',
        YamlErrorCode.unsupportedAnchorName: 'value: &an:chor data',
        YamlErrorCode.undefinedAlias: 'value: *missing',
        YamlErrorCode.recursiveAlias: 'value: &value [*value]',
        YamlErrorCode.documentCount: '---\none\n---\ntwo',
        YamlErrorCode.integerOutOfRange: '9223372036854775808',
        YamlErrorCode.leadingZeroInteger: '012',
        YamlErrorCode.resourceLimit: '${'[' * 101}null${']' * 101}',
      };

      expect(sources.keys.toSet(), YamlErrorCode.values.toSet());
      for (final MapEntry(key: code, value: source) in sources.entries) {
        expect(() => yamlDecode(source), throwsYaml(code), reason: code.name);
      }
    });
  });
}

/// Expects that [value] contains no unpaired UTF-16 surrogate.
void _expectWellFormedUtf16(String value) {
  for (var index = 0; index < value.length; index += 1) {
    final codeUnit = value.codeUnitAt(index);
    if (codeUnit >= 0xD800 && codeUnit <= 0xDBFF) {
      expect(index + 1, lessThan(value.length));
      expect(value.codeUnitAt(index + 1), inInclusiveRange(0xDC00, 0xDFFF));
      index += 1;
    } else {
      expect(codeUnit, isNot(inInclusiveRange(0xDC00, 0xDFFF)));
    }
  }
}
