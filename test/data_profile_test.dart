import 'package:tame_yaml/tame_yaml.dart';
import 'package:test/test.dart';

import 'src/helpers.dart';

void main() {
  group('mapping keys', () {
    test('accepts every supported form of string key', () {
      expect(
        yamlDecode('''
name: Dash
"42": value
? explicit string key
: explicit value
? !!str true
: tagged value
anchor: &key aliased
? *key
: alias value
'''),
        <String, Object?>{
          'name': 'Dash',
          '42': 'value',
          'explicit string key': 'explicit value',
          'true': 'tagged value',
          'anchor': 'aliased',
          'aliased': 'alias value',
        },
      );
    });

    for (final source in const [
      '42: value',
      'true: value',
      'null: value',
      '?\n: value',
      '? [one, two]\n: value',
      '? {complex: key}\n: value',
    ]) {
      test('rejects the non-string key in ${describeSource(source)}', () {
        expect(
          () => yamlDecode(source),
          throwsYaml(YamlErrorCode.nonStringKey),
        );
      });
    }

    test('never coerces a key to a string', () {
      final error = captureYamlException(() => yamlDecode('42: value'));
      expect(error.message, contains('resolves to int'));
    });

    test('rejects duplicates after construction and reports both sites', () {
      const source = 'name: first\n"name": second';
      final error = captureYamlException(() => yamlDecode(source));

      expect(error.code, YamlErrorCode.duplicateKey);
      expect(error.offset, source.indexOf('"name"'));
      expect(error.toString(), contains('First declared here.'));
      expect(error.toString(), contains('Declared again here.'));
      expect(error.toString(), contains('name: first'));
      expect(error.toString(), contains('"name": second'));
    });

    test('uses exact String equality without Unicode normalization', () {
      // Written as escapes so that neither form can be normalized away.
      const composed = '\u00E9';
      const decomposed = 'e\u0301';
      expect(
        yamlDecode('"$composed": composed\n"$decomposed": decomposed'),
        <String, Object?>{composed: 'composed', decomposed: 'decomposed'},
      );
    });
  });

  group('explicit tags', () {
    test('constructs every supported scalar tag', () {
      expect(
        yamlDecode('''
n: !!null ""
b: !!bool "TRUE"
i: !!int "0x1F"
f: !!float 42
s: !!str 123
'''),
        <String, Object?>{
          'n': null,
          'b': true,
          'i': 31,
          'f': 42.0,
          's': '123',
        },
      );
    });

    test('constructs every supported collection tag', () {
      expect(
        yamlDecode('''
items: !!seq [one, two]
config: !!map {enabled: true}
'''),
        <String, Object?>{
          'items': <Object?>['one', 'two'],
          'config': <String, Object?>{'enabled': true},
        },
      );
    });

    test('accepts a verbatim supported tag', () {
      expect(
        yamlDecode('value: !<tag:yaml.org,2002:str> 123'),
        <String, Object?>{'value': '123'},
      );
    });

    test('applies a tag written before its node', () {
      expect(
        yamlDecode('''
i: &anchored
  !!int "42"
f: !!float
  "1"
j: !!int
  &tagged "43"
copy: *anchored
taggedCopy: *tagged
'''),
        <String, Object?>{
          'i': 42,
          'f': 1.0,
          'j': 43,
          'copy': 42,
          'taggedCopy': 43,
        },
      );
    });

    test('rejects an invalid value tagged before its node', () {
      expect(
        () => yamlDecode('''
value: &anchored
  !!int "abc"
'''),
        throwsYaml(YamlErrorCode.invalidTaggedValue),
      );
    });

    for (final tag in const [
      '!date',
      '!Widget',
      '!custom_tag',
      '!custom#fragment',
      '!<tag:example.com,2026:value>',
      '!!set',
      '!!omap',
      '!!pairs',
      '!!binary',
      '!!timestamp',
      '!!value',
      '!!merge',
      '!',
    ]) {
      test('rejects the unsupported tag $tag', () {
        expect(
          () => yamlDecode('value: $tag 123'),
          throwsYaml(YamlErrorCode.unsupportedTag),
        );
      });
    }

    for (final source in const [
      'value: !!int hello',
      'value: !!int 42.0',
      'value: !!float nope',
      'value: !!bool yes',
      'value: !!null nothing',
      'value: !!seq scalar',
      'value: !!map [one]',
      'value: !!str [one]',
    ]) {
      test('rejects the tagged value in ${describeSource(source)}', () {
        expect(
          () => yamlDecode(source),
          throwsYaml(YamlErrorCode.invalidTaggedValue),
        );
      });
    }

    test('range-checks an explicitly tagged integer', () {
      expect(
        () => yamlDecode('value: !!int "9223372036854775808"'),
        throwsYaml(YamlErrorCode.integerOutOfRange),
      );
    });

    test('reports expanded URIs in tag diagnostics', () {
      final mismatch = captureYamlException(
        () => yamlDecode('value: !!int nope'),
      );
      expect(
        mismatch.message,
        'Tag "tag:yaml.org,2002:int" mismatches scalar.',
      );

      final unsupported = captureYamlException(
        () => yamlDecode('''
%TAG !e! tag:example.com,2026:
---
value: !e!thing data
'''),
      );
      expect(
        unsupported.message,
        'Unsupported tag "tag:example.com,2026:thing".',
      );
    });
  });

  group('merge-key guard', () {
    test('rejects a plain merge key', () {
      expect(
        () => yamlDecode('''
defaults: &defaults {retries: 3}
production:
  <<: *defaults
'''),
        throwsYaml(YamlErrorCode.mergeKey),
      );
    });

    test('accepts a quoted or explicitly string-tagged literal key', () {
      expect(yamlDecode('"<<": quoted'), <String, Object?>{'<<': 'quoted'});
      expect(yamlDecode('!!str <<: tagged'), <String, Object?>{'<<': 'tagged'});
    });

    test('accepts << outside key position', () {
      expect(
        yamlDecode('separator: <<\nmarkers: [<<, plain]'),
        <String, Object?>{
          'separator': '<<',
          'markers': <Object?>['<<', 'plain'],
        },
      );
    });
  });
}
