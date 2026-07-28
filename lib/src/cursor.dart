import 'code_unit.dart';
import 'errors.dart';
import 'span.dart';

/// A compact snapshot of a [ParserCursor] position.
///
/// Captured with [ParserCursor.mark] to later
/// reread, slice, or span the source from that position.
final class ParserMark {
  /// Creates a snapshot of the position described by
  /// [offset], [line], [column], and [characterOffset].
  const ParserMark(
    this.offset,
    this.line,
    this.column,
    this.characterOffset,
  );

  /// The UTF-16 code-unit offset this position is at.
  final int offset;

  /// The zero-based line this position is on.
  final int line;

  /// The zero-based UTF-16 code-unit column this position is at.
  final int column;

  /// The number of Unicode code points consumed before this position.
  ///
  /// A surrogate pair counts once, and a lone surrogate counts on its own.
  final int characterOffset;
}

/// A forward-only cursor over UTF-16 source text that
/// tracks line and column positions as it reads.
final class ParserCursor {
  /// Creates a cursor positioned at the start of [source].
  ParserCursor(this.source);

  /// The source text being scanned.
  final String source;

  /// The UTF-16 code-unit offset the cursor is at.
  int offset = 0;

  /// The zero-based line the cursor is on.
  int line = 0;

  /// The zero-based UTF-16 code-unit column the cursor is at.
  int column = 0;

  /// The number of Unicode code points the cursor has consumed.
  ///
  /// A surrogate pair counts once and a lone surrogate counts on its own,
  /// so this can trail [offset] on source text
  /// containing supplementary characters.
  int characterOffset = 0;

  /// Whether the cursor has consumed all of [source].
  bool get isDone => offset == source.length;

  /// A snapshot of the position the cursor is currently at.
  ParserMark get mark => ParserMark(offset, line, column, characterOffset);

  /// Moves the cursor back to the position captured by [mark].
  void restore(ParserMark mark) {
    offset = mark.offset;
    line = mark.line;
    column = mark.column;
    characterOffset = mark.characterOffset;
  }

  /// Returns the code unit [ahead] positions from the cursor
  /// without consuming it, or `null` if that lands outside [source].
  int? peek([int ahead = 0]) {
    final index = offset + ahead;
    if (index < 0 || index >= source.length) return null;
    return source.codeUnitAt(index);
  }

  /// Consumes and returns the next UTF-16 code unit.
  ///
  /// Throws a [DecoderException] if the cursor [isDone].
  int readCodeUnit() {
    if (isDone) _throw('Expected more input.', mark);
    final codeUnit = source.codeUnitAt(offset);
    offset += 1;
    // Let LF account for a CRLF pair. A lone CR accounts for itself.
    if (codeUnit == CodeUnit.lineFeed ||
        (codeUnit == CodeUnit.carriageReturn &&
            (isDone || peek() != CodeUnit.lineFeed))) {
      line += 1;
      column = 0;
    } else {
      column += 1;
    }
    final completesSurrogatePair =
        CodeUnit.isLowSurrogate(codeUnit) &&
        offset >= 2 &&
        CodeUnit.isHighSurrogate(source.codeUnitAt(offset - 2));
    if (!completesSurrogatePair) characterOffset += 1;
    return codeUnit;
  }

  /// Consumes and returns the next Unicode code point.
  ///
  /// A surrogate that isn't part of a valid pair
  /// is consumed and returned on its own.
  int readCodePoint() {
    final first = readCodeUnit();
    if (!CodeUnit.isHighSurrogate(first)) return first;
    final second = peek();
    if (second == null || !CodeUnit.isLowSurrogate(second)) return first;
    readCodeUnit();
    return CodeUnit.firstSupplementaryCodePoint +
        ((first - CodeUnit.highSurrogateStart) << 10) +
        second -
        CodeUnit.lowSurrogateStart;
  }

  /// Consumes the next code unit if it is [codeUnit],
  /// returning whether it was consumed.
  bool consumeCodeUnit(int codeUnit) {
    if (offset >= source.length || source.codeUnitAt(offset) != codeUnit) {
      return false;
    }
    readCodeUnit();
    return true;
  }

  /// Consumes the run of spaces at the cursor,
  /// returning how many were consumed.
  ///
  /// Spaces neither end a line nor pair as surrogates,
  /// so the position moves without the
  /// per-code-unit bookkeeping [readCodeUnit] performs.
  int skipSpaces() {
    final start = offset;
    while (offset < source.length &&
        source.codeUnitAt(offset) == CodeUnit.space) {
      offset += 1;
    }
    final count = offset - start;
    column += count;
    characterOffset += count;
    return count;
  }

  /// Consumes the run of spaces and tabs at the cursor,
  /// as [skipSpaces] does for spaces alone.
  void skipInlineWhitespace() {
    final start = offset;
    while (offset < source.length) {
      final codeUnit = source.codeUnitAt(offset);
      if (codeUnit != CodeUnit.space && codeUnit != CodeUnit.tab) break;
      offset += 1;
    }
    final count = offset - start;
    column += count;
    characterOffset += count;
  }

  /// Whether the next code unit starts a line break.
  bool get isBreak {
    final codeUnit = peek();
    return codeUnit == CodeUnit.lineFeed || codeUnit == CodeUnit.carriageReturn;
  }

  /// Consumes a single LF, CR, or CRLF line break.
  ///
  /// Throws a [DecoderException] if the cursor isn't at a line break.
  void readBreak() {
    if (!isBreak) _throw('Expected a line break.', mark);
    final first = readCodeUnit();
    if (first == CodeUnit.carriageReturn && peek() == CodeUnit.lineFeed) {
      readCodeUnit();
    }
  }

  /// Returns the source text between [start] and [end],
  /// defaulting to the current position if [end] is omitted.
  String slice(ParserMark start, [ParserMark? end]) =>
      source.substring(start.offset, (end ?? mark).offset);

  /// Creates a source span covering [start] up to [end],
  /// defaulting to the current position if [end] is omitted.
  SourceSpan span(ParserMark start, [ParserMark? end]) => SourceSpan(
    source,
    startOffset: start.offset,
    startLine: start.line,
    startColumn: start.column,
    endOffset: end?.offset ?? offset,
    endLine: end?.line ?? line,
    endColumn: end?.column ?? column,
  );

  /// Creates an empty source span pointing at [at],
  /// defaulting to the current position if omitted.
  SourceSpan pointSpan([ParserMark? at]) {
    final position = at ?? mark;
    return span(position, position);
  }

  /// Throws a [DecoderException] reporting [message] as a
  /// syntax error at the position [at].
  Never _throw(String message, ParserMark at) {
    throw DecoderException(
      YamlErrorCode.syntax,
      message,
      pointSpan(at),
    );
  }
}
