import 'code_unit.dart';

/// A source range retained only until its diagnostic is materialized.
///
/// Every parsed node records the range it came from,
/// so the bounds are stored as plain coordinates rather than
/// as separate position objects.
final class SourceSpan {
  /// Creates a source range over [sourceText].
  const SourceSpan(
    this.sourceText, {
    required this.startOffset,
    required this.startLine,
    required this.startColumn,
    required this.endOffset,
    required this.endLine,
    required this.endColumn,
  });

  /// The source text containing this range.
  final String sourceText;

  /// The UTF-16 code-unit offset this range starts at.
  final int startOffset;

  /// The zero-based line this range starts on.
  final int startLine;

  /// The zero-based UTF-16 code-unit column this range starts at.
  final int startColumn;

  /// The UTF-16 code-unit offset this range ends before.
  final int endOffset;

  /// The zero-based line this range ends on.
  final int endLine;

  /// The zero-based UTF-16 code-unit column this range ends before.
  final int endColumn;
}

/// Computes a source span for [source] without
/// retaining a line index for the input.
///
/// The span covers [length] code units from [offset],
/// defaulting to an empty span that points at [offset] alone.
SourceSpan sourceSpanAt(String source, int offset, [int length = 0]) {
  final endOffset = offset + length;
  var line = 0;
  var column = 0;
  var startLine = 0;
  var startColumn = 0;
  for (var index = 0; index < endOffset; index += 1) {
    if (index == offset) {
      startLine = line;
      startColumn = column;
    }
    final codeUnit = source.codeUnitAt(index);
    // Let LF account for a CRLF pair. A lone CR accounts for itself.
    if (codeUnit == CodeUnit.lineFeed ||
        (codeUnit == CodeUnit.carriageReturn &&
            (index + 1 == source.length ||
                source.codeUnitAt(index + 1) != CodeUnit.lineFeed))) {
      line += 1;
      column = 0;
    } else {
      column += 1;
    }
  }
  if (offset >= endOffset) {
    startLine = line;
    startColumn = column;
  }
  return SourceSpan(
    source,
    startOffset: offset,
    startLine: startLine,
    startColumn: startColumn,
    endOffset: endOffset,
    endLine: line,
    endColumn: column,
  );
}
