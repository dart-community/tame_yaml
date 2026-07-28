import 'package:tame_yaml/src/cursor.dart';
import 'package:tame_yaml/src/errors.dart';
import 'package:test/test.dart';

void main() {
  group('parser cursor', () {
    test('tracks UTF-16 positions and Unicode code points independently', () {
      final cursor = ParserCursor('A😀\r\nB\rC');

      expect(cursor.readCodePoint(), 0x41);
      expect(
        cursor.mark,
        _hasPosition(offset: 1, line: 0, column: 1, characterOffset: 1),
      );

      expect(cursor.readCodePoint(), 0x1F600);
      expect(
        cursor.mark,
        _hasPosition(offset: 3, line: 0, column: 3, characterOffset: 2),
      );

      cursor.readBreak();
      expect(
        cursor.mark,
        _hasPosition(offset: 5, line: 1, column: 0, characterOffset: 4),
      );

      expect(cursor.readCodePoint(), 0x42);
      cursor.readBreak();
      expect(
        cursor.mark,
        _hasPosition(offset: 7, line: 2, column: 0, characterOffset: 6),
      );

      expect(cursor.readCodePoint(), 0x43);
      expect(cursor.isDone, isTrue);
    });

    test('counts a lone surrogate as one code point', () {
      for (final codeUnit in const [0xD800, 0xDC00]) {
        final cursor = ParserCursor(String.fromCharCode(codeUnit));

        expect(cursor.readCodePoint(), codeUnit);
        expect(cursor.characterOffset, 1);
        expect(cursor.isDone, isTrue);
      }
    });

    test('reports a syntax failure when reading past the source', () {
      final cursor = ParserCursor('x');
      cursor.readCodeUnit();

      expect(
        cursor.readCodeUnit,
        throwsA(
          isA<DecoderException>()
              .having((error) => error.code, 'code', YamlErrorCode.syntax)
              .having((error) => error.span.startOffset, 'offset', 1),
        ),
      );
    });
  });
}

/// Matches a [ParserMark] with the supplied source coordinates.
Matcher _hasPosition({
  required int offset,
  required int line,
  required int column,
  required int characterOffset,
}) => isA<ParserMark>()
    .having((mark) => mark.offset, 'offset', offset)
    .having((mark) => mark.line, 'line', line)
    .having((mark) => mark.column, 'column', column)
    .having(
      (mark) => mark.characterOffset,
      'characterOffset',
      characterOffset,
    );
