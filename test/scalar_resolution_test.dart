import 'package:tame_yaml/tame_yaml.dart';
import 'package:test/test.dart';

import 'src/helpers.dart';

void main() {
  group('core schema resolution', () {
    const cases = <String, Object?>{
      '': null,
      '~': null,
      'null': null,
      'Null': null,
      'NULL': null,
      'true': true,
      'True': true,
      'TRUE': true,
      'false': false,
      'False': false,
      'FALSE': false,
      '0': 0,
      '-0': 0,
      '+12': 12,
      '0o17': 15,
      '0x1F': 31,
      '1.': 1.0,
      '.5': 0.5,
      '+.5': 0.5,
      '1e3': 1000.0,
      '1.25': 1.25,
      '.inf': double.infinity,
      '+.Inf': double.infinity,
      '-.INF': double.negativeInfinity,
      'hello': 'hello',
      'yes': 'yes',
      'no': 'no',
      'on': 'on',
      'off': 'off',
      'TRue': 'TRue',
      'nULL': 'nULL',
      '.INf': '.INf',
      '-0x10': '-0x10',
      '0X10': '0X10',
      '1_000': '1_000',
      '0b1010': '0b1010',
      'Infinity': 'Infinity',
      'NaN': 'NaN',
      '2026-07-24': '2026-07-24',
    };

    for (final MapEntry(key: source, value: expected) in cases.entries) {
      test('resolves ${describeSource(source)}', () {
        final actual = yamlDecode(source);
        expect(actual, expected);
        expect(actual?.runtimeType, expected?.runtimeType);
      });
    }

    for (final source in const ['.nan', '.NaN', '.NAN']) {
      test('resolves $source to NaN', () {
        final actual = yamlDecode(source);
        expect(actual, isA<double>());
        expect(actual, isNaN);
      });
    }

    test('resolves -0.0 to negative zero', () {
      final value = yamlDecode('-0.0');
      expect(value, 0.0);
      expect((value as double).isNegative, isTrue);
    });

    test('uses IEEE-754 overflow and underflow for finite float syntax', () {
      final exponent = '9' * 100000;
      expect(yamlDecode('1e$exponent'), double.infinity);
      expect(yamlDecode('-1e$exponent'), double.negativeInfinity);
      expect(yamlDecode('1e-$exponent'), 0.0);
    });

    test('resolves omitted mapping and sequence values to null', () {
      expect(yamlDecode('key:'), <String, Object?>{'key': null});
      expect(yamlDecode('-\n- value'), <Object?>[null, 'value']);
    });

    test('resolves only plain scalars implicitly', () {
      expect(
        yamlDecode('''
plain: true
single: 'true'
double: "42"
literal: |
  null
folded: >
  1.25
'''),
        <String, Object?>{
          'plain': true,
          'single': 'true',
          'double': '42',
          'literal': 'null\n',
          'folded': '1.25\n',
        },
      );
    });
  });

  group('integer range', () {
    // Integer literals outside the JavaScript range cannot be compiled for
    // the web, so the expected values are parsed instead of written directly.
    test('accepts the signed 64-bit boundaries', () {
      expect(
        yamlDecode('9223372036854775807'),
        int.parse('9223372036854775807'),
      );
      expect(
        yamlDecode('-9223372036854775808'),
        int.parse('-9223372036854775808'),
      );
    }, testOn: 'vm');

    test('rejects values beyond the signed 64-bit range', () {
      expect(
        () => yamlDecode('9223372036854775808'),
        throwsYaml(YamlErrorCode.integerOutOfRange),
      );
      expect(
        () => yamlDecode('-9223372036854775809'),
        throwsYaml(YamlErrorCode.integerOutOfRange),
      );
    }, testOn: 'vm');

    test('uses the JavaScript safe-integer range', () {
      expect(yamlDecode('9007199254740991'), 9007199254740991);
      expect(
        () => yamlDecode('9007199254740992'),
        throwsYaml(YamlErrorCode.integerOutOfRange),
      );
    }, testOn: 'js');

    test('range-checks every radix without parsing huge integers', () {
      const isJavaScript = identical(1, 1.0);
      const acceptedHex = isJavaScript
          ? '0x1FFFFFFFFFFFFF'
          : '0x7FFFFFFFFFFFFFFF';
      const rejectedHex = isJavaScript
          ? '0x20000000000000'
          : '0x8000000000000000';
      const acceptedOctal = isJavaScript
          ? '0o377777777777777777'
          : '0o777777777777777777777';
      const rejectedOctal = isJavaScript
          ? '0o400000000000000000'
          : '0o1000000000000000000000';

      expect(yamlDecode(acceptedHex), int.parse(acceptedHex));
      expect(
        yamlDecode(acceptedOctal),
        int.parse(acceptedOctal.substring(2), radix: 8),
      );
      expect(
        () => yamlDecode(rejectedHex),
        throwsYaml(YamlErrorCode.integerOutOfRange),
      );
      expect(
        () => yamlDecode(rejectedOctal),
        throwsYaml(YamlErrorCode.integerOutOfRange),
      );

      expect(
        () => yamlDecode('9' * 100000),
        throwsYaml(YamlErrorCode.integerOutOfRange),
      );
      expect(yamlDecode('0x${'0' * 100000}2A'), 42);
      expect(yamlDecode('0o${'0' * 100000}52'), 42);
    });
  });

  group('leading-zero integers', () {
    for (final source in const [
      '012',
      '00',
      '0644',
      '+00',
      '-012',
      '0000000009',
    ]) {
      test('rejects $source', () {
        expect(
          () => yamlDecode(source),
          throwsYaml(YamlErrorCode.leadingZeroInteger),
        );
      });
    }

    test('rejects a leading zero under an explicit !!int tag', () {
      expect(
        () => yamlDecode('!!int 0644'),
        throwsYaml(YamlErrorCode.leadingZeroInteger),
      );
    });

    test('reports the leading zero before the range check', () {
      expect(
        () => yamlDecode('0${'9' * 100000}'),
        throwsYaml(YamlErrorCode.leadingZeroInteger),
      );
    });

    test('accepts the spellings a leading zero cannot make ambiguous', () {
      expect(yamlDecode('0'), 0);
      expect(yamlDecode('-0'), 0);
      expect(yamlDecode('+0'), 0);
      expect(yamlDecode('0o0644'), 420);
      expect(yamlDecode('0x0FF'), 255);
      expect(yamlDecode('01.5'), 1.5);
      expect(yamlDecode('0.5'), 0.5);
      expect(yamlDecode('00.5'), 0.5);
      expect(yamlDecode('01e3'), 1000.0);
      expect(yamlDecode('!!float 0644'), 644.0);
      expect(yamlDecode("'0644'"), '0644');
      expect(yamlDecode('!!str 0644'), '0644');
      expect(yamlDecode('0644x'), '0644x');
    });
  });
}
