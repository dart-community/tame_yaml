import 'package:tame_yaml/tame_yaml.dart';
import 'package:test/test.dart';

import 'src/helpers.dart';

void main() {
  group('anchors and aliases', () {
    test('aliases scalars and sequences', () {
      expect(
        yamlDecode('''
scalar: &scalar value
scalarAlias: *scalar
sequence: &sequence [one, two]
sequenceAlias: *sequence
'''),
        <String, Object?>{
          'scalar': 'value',
          'scalarAlias': 'value',
          'sequence': <Object?>['one', 'two'],
          'sequenceAlias': <Object?>['one', 'two'],
        },
      );
    });

    test('materializes independent recursive copies', () {
      final root =
          yamlDecode('''
defaults: &defaults
  retries: 3
  nested: [one, {two: 2}]
development: *defaults
production: *defaults
''')
              as Map<String, Object?>;
      final defaults = root['defaults'] as Map<String, Object?>;
      final development = root['development'] as Map<String, Object?>;
      final production = root['production'] as Map<String, Object?>;

      expect(development, defaults);
      expect(production, defaults);
      expect(identical(defaults, development), isFalse);
      expect(identical(development, production), isFalse);
      expect(identical(defaults['nested'], development['nested']), isFalse);

      final developmentNested = development['nested'] as List<Object?>;
      final productionNested = production['nested'] as List<Object?>;
      expect(identical(developmentNested[1], productionNested[1]), isFalse);
    });

    test('uses the most recent preceding anchor definition', () {
      expect(
        yamlDecode('''
first: &item one
firstAlias: *item
second: &item two
secondAlias: *item
'''),
        <String, Object?>{
          'first': 'one',
          'firstAlias': 'one',
          'second': 'two',
          'secondAlias': 'two',
        },
      );
    });

    test('keeps a nested redefinition after its enclosing node finishes', () {
      expect(
        yamlDecode('''
outer: &item
  nested: &item inner
  inside: *item
after: *item
'''),
        <String, Object?>{
          'outer': <String, Object?>{
            'nested': 'inner',
            'inside': 'inner',
          },
          'after': 'inner',
        },
      );
    });

    test('does not carry anchors across documents', () {
      expect(
        () => yamlDecodeAll('--- &item\nvalue\n---\n*item'),
        throwsYaml(YamlErrorCode.undefinedAlias),
      );
    });

    test('reports an error in an anchored node at its definition', () {
      final error = captureYamlException(
        () => yamlDecode('''
defaults: &defaults
  duplicate: first
  duplicate: second
copy: *defaults
'''),
      );

      expect(error.code, YamlErrorCode.duplicateKey);
      expect(error.line, 3);
    });

    test('rejects an undefined alias', () {
      expect(
        () => yamlDecode('value: *missing'),
        throwsYaml(YamlErrorCode.undefinedAlias),
      );
    });

    test('rejects a forward alias', () {
      expect(
        () => yamlDecode('alias: *later\nvalue: &later present'),
        throwsYaml(YamlErrorCode.undefinedAlias),
      );
    });

    test('rejects a direct recursive alias', () {
      expect(
        () => yamlDecode('''
value: &value
  self: *value
'''),
        throwsYaml(YamlErrorCode.recursiveAlias),
      );
    });

    test('rejects an indirect recursive alias', () {
      expect(
        () => yamlDecode('''
first: &first
  second: &second
    back: *first
alias: *second
'''),
        throwsYaml(YamlErrorCode.recursiveAlias),
      );
    });

    test('rejects properties on an alias node', () {
      // The properties can sit on the alias' own line or the line before it,
      // and are rejected whatever the anchored node turns out to be.
      for (final source in const [
        'sequence: &sequence [one]\nalias: &alias *sequence',
        'sequence: &sequence [one]\nalias: &alias\n  *sequence',
        'sequence: &sequence [one]\nalias: !!seq\n  *sequence',
        'scalar: &scalar one\nalias: !!str\n  *scalar',
        'scalar: &scalar one\nalias: !custom *scalar',
      ]) {
        expect(
          () => yamlDecode(source),
          throwsYaml(YamlErrorCode.syntax),
          reason: describeSource(source),
        );
      }
    });
  });

  group('anchor and alias names', () {
    test('accepts identifier-shaped names', () {
      for (final name in const [
        'x',
        'A1',
        '_private',
        'a-b.c',
        '0',
        'x_1.2-3',
      ]) {
        expect(
          yamlDecode('value: &$name one\nalias: *$name'),
          <String, Object?>{'value': 'one', 'alias': 'one'},
          reason: name,
        );
      }
    });

    test('rejects names outside the accepted character set', () {
      for (final source in const [
        'value: &an:chor one',
        'value: &x#y one',
        'value: &*x one',
        'value: &&x one',
        'value: &%x one',
        'value: &x"y one',
        'value: &😀 one',
        'value: &.hidden one',
        'value: &-lead one',
      ]) {
        expect(
          () => yamlDecode(source),
          throwsYaml(YamlErrorCode.unsupportedAnchorName),
          reason: describeSource(source),
        );
      }
    });

    test('explains the positional restrictions on accepted names', () {
      final error = captureYamlException(
        () => yamlDecode('value: &.hidden data'),
      );

      expect(error.code, YamlErrorCode.unsupportedAnchorName);
      expect(
        error.toString(),
        endsWith(
          'Start with an ASCII letter, digit, or "_"; '
          'then use those, ".", or "-".',
        ),
      );
    });

    test('reports a rejected alias name in full', () {
      // Scanning follows the specification's wider set first, so the whole
      // intended name is reported rather than a prefix that has no anchor.
      final error = captureYamlException(
        () => yamlDecode('value: &x one\n*x: two'),
      );

      expect(error.code, YamlErrorCode.unsupportedAnchorName);
      expect(error.message, contains('"x:"'));
    });

    test('accepts an alias key separated from its colon', () {
      expect(
        yamlDecode('value: &x one\n*x : two'),
        <String, Object?>{'value': 'one', 'one': 'two'},
      );
    });

    test('accepts an alias as a string mapping key', () {
      expect(
        yamlDecode('''
key: &key aliased
? *key
: value
'''),
        <String, Object?>{'key': 'aliased', 'aliased': 'value'},
      );
    });
  });
}
