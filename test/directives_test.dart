import 'package:tame_yaml/tame_yaml.dart';
import 'package:test/test.dart';

import 'src/helpers.dart';

void main() {
  group('%YAML directive', () {
    test('accepts version 1.2', () {
      expect(yamlDecode('%YAML 1.2\n---\nname: Dash'), <String, Object?>{
        'name': 'Dash',
      });
    });

    test('accepts a zero-padded version 1.2', () {
      expect(yamlDecode('%YAML 0001.0002\n---\nvalue'), 'value');
    });

    for (final version in const ['1.0', '1.1', '1.3', '2.0']) {
      test('rejects version $version', () {
        expect(
          () => yamlDecode('%YAML $version\n---\nvalue'),
          throwsYaml(YamlErrorCode.unsupportedVersion),
        );
      });
    }

    test('rejects an enormous version without retaining it', () {
      final version = '9' * 100000;
      final error = captureYamlException(
        () => yamlDecode('%YAML $version.2\n---\nvalue'),
      );

      expect(error.code, YamlErrorCode.unsupportedVersion);
      expect(error.toString().length, lessThan(1000));
    });
  });

  group('%TAG directive', () {
    test('resolves a declared handle', () {
      expect(
        yamlDecode('''
%TAG !y! tag:yaml.org,2002:
---
count: !y!int 42
'''),
        <String, Object?>{'count': 42},
      );
    });

    test('resolves a declared primary handle', () {
      expect(
        yamlDecode('''
%TAG ! tag:yaml.org,2002:
---
!str 123
'''),
        '123',
      );
    });

    test('decodes URI escapes in verbatim tags and declared handles', () {
      expect(yamlDecode('!<tag:yaml.org,2002:%73tr> 123'), '123');
      expect(
        yamlDecode('''
%TAG !y! tag:yaml.org,2002:
---
!y!%69nt "42"
'''),
        42,
      );
      expect(
        yamlDecode('''
%TAG !core! tag:yaml.org,2002:
---
!core!%73tr 42
'''),
        '42',
      );
    });

    test('resets declared handles at document boundaries', () {
      expect(
        () => yamlDecodeAll('''
%TAG !y! tag:yaml.org,2002:
---
!y!str first
---
!y!str second
'''),
        throwsYaml(YamlErrorCode.syntax),
      );
    });
  });

  group('invalid directives', () {
    for (final source in const [
      '%YAML 1.2\n%YAML 1.2\n---\nvalue',
      '%TAG !e! tag:example.com,2026:\n%TAG !e! tag:other:\n---\nvalue',
      '%TAG !bad_handle! tag:example.com,2026:\n---\nvalue',
      '%TAG !e! \n---\nvalue',
      '%UNKNOWN feature\n---\nvalue',
      '%YAML nope\n---\nvalue',
      '%TAG !bad\n---\nvalue',
    ]) {
      test('rejects ${describeSource(source)}', () {
        expect(
          () => yamlDecode(source),
          throwsYaml(YamlErrorCode.invalidDirective),
        );
      });
    }

    test('reports one message for malformed tokens and separators', () {
      for (final source in const [
        '%YAML! 1.2\n---\nvalue',
        '%YAML 12\n---\nvalue',
        '%TAG bad tag:yaml.org,2002:\n---\nvalue',
        '%TAG !e!tag:yaml.org,2002:\n---\nvalue',
        '%TAG !e! tag:%GG\n---\nvalue',
      ]) {
        final reason = describeSource(source);
        final error = captureYamlException(() => yamlDecode(source));
        expect(error.code, YamlErrorCode.invalidDirective, reason: reason);
        expect(error.message, 'Invalid YAML directive.', reason: reason);
      }
    });

    test('requires an explicit document start after a directive', () {
      const source = '%YAML 1.2\nvalue';
      final error = captureYamlException(() => yamlDecode(source));

      expect(error.code, YamlErrorCode.invalidDirective);
      expect(error.message, 'Expected "---".');
      expect(error.offset, source.indexOf('value'));
    });
  });
}
