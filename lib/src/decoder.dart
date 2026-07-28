import 'code_unit.dart';
import 'errors.dart';
import 'parser.dart';
import 'span.dart';

/// Validates and decodes [source] with the fixed package profile.
///
/// Returns one value per document, in source order.
/// When [singleDocument] is `true`,
/// a stream holding more than one document is rejected instead.
///
/// Throws a [DecoderException] for any character, syntax, or profile failure.
List<Object?> decodeYaml(
  String source, {
  required bool singleDocument,
}) {
  _validateCharacters(source);
  return YamlParser(source, singleDocument: singleDocument).decode();
}

/// Rejects characters YAML doesn't permit in [source].
///
/// Runs ahead of the parser so a stray control character is
/// reported as [YamlErrorCode.invalidCharacter] rather than as
/// whatever syntax error it happens to trigger first.
///
/// Throws a [DecoderException] at the first offending offset.
void _validateCharacters(String source) {
  for (var index = 0; index < source.length; index += 1) {
    final codeUnit = source.codeUnitAt(index);
    // Printable ASCII, which dominates ordinary input, is always permitted.
    if (codeUnit >= CodeUnit.space && codeUnit < CodeUnit.delete) continue;
    if (CodeUnit.isHighSurrogate(codeUnit)) {
      if (index + 1 < source.length &&
          CodeUnit.isLowSurrogate(source.codeUnitAt(index + 1))) {
        index += 1;
        continue;
      }
      _invalidCharacter(
        source,
        index,
        'Unpaired high surrogate.',
        hint: 'Replace it with a valid Unicode scalar value.',
      );
    }
    if (CodeUnit.isLowSurrogate(codeUnit)) {
      _invalidCharacter(
        source,
        index,
        'Unpaired low surrogate.',
        hint: 'Replace it with a valid Unicode scalar value.',
      );
    }

    final invalid =
        codeUnit <= CodeUnit.backspace ||
        codeUnit == CodeUnit.verticalTab ||
        codeUnit == CodeUnit.formFeed ||
        (codeUnit >= CodeUnit.shiftOut && codeUnit <= CodeUnit.unitSeparator) ||
        (codeUnit >= CodeUnit.delete && codeUnit <= CodeUnit.indexControl) ||
        (codeUnit >= CodeUnit.startOfSelectedArea &&
            codeUnit <= CodeUnit.applicationProgramCommand) ||
        codeUnit == CodeUnit.nonCharacterFffe ||
        codeUnit == CodeUnit.nonCharacterFfff;
    if (invalid) {
      _invalidCharacter(
        source,
        index,
        "YAML doesn't permit this character.",
        hint: 'Escape it inside a double-quoted scalar.',
      );
    }
  }
}

/// Throws a [YamlErrorCode.invalidCharacter] failure spanning the
/// single code unit at [offset] of [source], using [message] and [hint].
Never _invalidCharacter(
  String source,
  int offset,
  String message, {
  required String hint,
}) {
  throw DecoderException(
    YamlErrorCode.invalidCharacter,
    message,
    sourceSpanAt(source, offset, 1),
    hint: hint,
  );
}
