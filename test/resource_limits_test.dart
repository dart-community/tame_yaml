import 'package:tame_yaml/src/limits.dart';
import 'package:tame_yaml/tame_yaml.dart';
import 'package:test/test.dart';

import 'src/helpers.dart';

void main() {
  group('fixed resource limits', () {
    test('keeps the documented limit values', () {
      // These ceilings are part of the package's documented contract,
      // so changing one is a deliberate behavior change.
      expect(DecoderLimit.nestingDepth, 100);
      expect(DecoderLimit.documentsPerStream, 1_000);
      expect(DecoderLimit.parsedNodesPerDocument, 1_000_000);
      expect(DecoderLimit.aliasesPerDocument, 10_000);
      expect(DecoderLimit.aliasExpansionDepth, 100);
      expect(DecoderLimit.constructedNodesPerDocument, 1_000_000);
      expect(DecoderLimit.scalarCodeUnits, 16_777_216);
    });

    test('enforces nesting depth at the boundary', () {
      const depth = DecoderLimit.nestingDepth;
      final accepted = '${'[' * depth}null${']' * depth}';

      var value = yamlDecode(accepted);
      for (var level = 0; level < depth; level += 1) {
        value = (value as List<Object?>).single;
      }
      expect(value, isNull);

      final error = captureYamlException(() => yamlDecode('[$accepted]'));
      expect(error.code, YamlErrorCode.resourceLimit);
      expect(error.message, contains('nesting depth'));
    });

    test('enforces the document count at the boundary', () {
      const count = DecoderLimit.documentsPerStream;
      final accepted = List<String>.filled(count, '---').join('\n');
      expect(yamlDecodeAll(accepted), hasLength(count));

      final error = captureYamlException(() => yamlDecodeAll('$accepted\n---'));
      expect(error.code, YamlErrorCode.resourceLimit);
      expect(error.message, contains('documents'));
    });

    test('enforces parsed nodes while parsing the offending node', () {
      final source = List<String>.filled(
        DecoderLimit.parsedNodesPerDocument,
        '-',
      ).join('\n');

      final error = captureYamlException(() => yamlDecode(source));
      expect(error.code, YamlErrorCode.resourceLimit);
      expect(error.message, contains('parsed nodes'));
    });

    test('enforces alias occurrences while reading the document', () {
      final aliases = List<String>.filled(
        DecoderLimit.aliasesPerDocument + 1,
        '*item',
      ).join(',');

      final error = captureYamlException(
        () => yamlDecode('item: &item value\naliases: [$aliases]'),
      );
      expect(error.code, YamlErrorCode.resourceLimit);
      expect(error.message, contains('aliases'));
    });

    test('enforces alias-expansion depth independently', () {
      final source = StringBuffer('a0: &a0 leaf\n');
      for (
        var depth = 1;
        depth <= DecoderLimit.aliasExpansionDepth + 1;
        depth += 1
      ) {
        source.writeln('a$depth: &a$depth [*a${depth - 1}]');
      }

      final error = captureYamlException(() => yamlDecode(source.toString()));
      expect(error.code, YamlErrorCode.resourceLimit);
      expect(error.message, contains('Alias expansion'));
    });

    test('budgets nodes materialized by alias copies', () {
      const templateSize = 1000;
      const aliasCopies = 998;
      final template = List<String>.filled(templateSize, 'null').join(',');
      final aliases = List<String>.filled(aliasCopies, '*base').join(',');

      // Keep this assertion adjacent to the generated corpus so a changed
      // generator cannot silently stop crossing the intended limit.
      expect(
        1 + 1 + (1 + templateSize) + 1 + 1 + aliasCopies * (1 + templateSize),
        greaterThan(DecoderLimit.constructedNodesPerDocument),
      );

      final error = captureYamlException(
        () => yamlDecode('base: &base [$template]\ncopies: [$aliases]'),
      );
      expect(error.code, YamlErrorCode.resourceLimit);
      expect(error.message, contains('constructed nodes'));
    });

    test('enforces decoded scalar size in UTF-16 code units', () {
      final error = captureYamlException(
        () => yamlDecode('a' * (DecoderLimit.scalarCodeUnits + 1)),
      );
      expect(error.code, YamlErrorCode.resourceLimit);
      expect(error.message, contains('UTF-16 code units'));
    });

    test('counts an astral character as two UTF-16 code units', () {
      // Half as many astral characters as the limit still exceeds it.
      expect('😀'.length, 2);
      final source = '😀' * (DecoderLimit.scalarCodeUnits ~/ 2 + 1);

      final error = captureYamlException(() => yamlDecode(source));
      expect(error.code, YamlErrorCode.resourceLimit);
      expect(error.message, contains('UTF-16 code units'));
    });
  });
}
