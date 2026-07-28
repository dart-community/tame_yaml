import 'code_unit.dart';
import 'span.dart';

/// Whether [codeUnit] would disturb a terminal rather than render as itself.
///
/// Line breaks are included, so a caller rendering text that might
/// legitimately contain one has to permit it before consulting this.
bool isUnprintable(int codeUnit) =>
    codeUnit < CodeUnit.space ||
    codeUnit >= CodeUnit.delete &&
        codeUnit <= CodeUnit.applicationProgramCommand ||
    codeUnit == CodeUnit.lineSeparator ||
    codeUnit == CodeUnit.paragraphSeparator ||
    codeUnit == CodeUnit.byteOrderMark;

/// Quotes [value] for a compact, single-line diagnostic.
///
/// Control characters are escaped, and an
/// overlong value is truncated with a trailing ellipsis.
String quoteForDiagnostic(String value) {
  const maximumCodeUnits = 80;
  var end = value.length < maximumCodeUnits ? value.length : maximumCodeUnits;
  if (end < value.length &&
      end > 0 &&
      CodeUnit.isHighSurrogate(value.codeUnitAt(end - 1)) &&
      CodeUnit.isLowSurrogate(value.codeUnitAt(end))) {
    end -= 1;
  }

  final buffer = StringBuffer('"');
  for (var index = 0; index < end; index += 1) {
    final codeUnit = value.codeUnitAt(index);
    switch (codeUnit) {
      case CodeUnit.tab:
        buffer.write(r'\t');
      case CodeUnit.lineFeed:
        buffer.write(r'\n');
      case CodeUnit.carriageReturn:
        buffer.write(r'\r');
      case CodeUnit.doubleQuote:
        buffer.write(r'\"');
      case CodeUnit.backslash:
        buffer.write(r'\\');
      default:
        if (isUnprintable(codeUnit)) {
          buffer
            ..write(r'\u')
            ..write(codeUnit.toRadixString(16).padLeft(4, '0'));
        } else {
          buffer.writeCharCode(codeUnit);
        }
    }
  }
  if (end < value.length) buffer.write('…');
  buffer.write('"');
  return buffer.toString();
}

/// Builds the complete source excerpt and optional remediation hint.
String buildExcerpt(
  SourceSpan span, {
  SourceSpan? relatedSpan,
  String? relatedLabel,
  String? hint,
}) {
  final buffer = StringBuffer();
  if (relatedSpan != null) {
    buffer.writeln(
      _renderSpan(relatedSpan, relatedLabel ?? 'Related location.'),
    );
    buffer.writeln();
  }
  buffer.write(
    _renderSpan(span, relatedSpan == null ? null : 'Declared again here.'),
  );
  if (hint != null) {
    buffer
      ..writeln()
      ..writeln()
      ..write(hint);
  }
  return buffer.toString();
}

/// Renders the source line and caret indicator for [span].
String _renderSpan(SourceSpan span, String? label) {
  final source = span.sourceText;
  final offset = span.startOffset;
  var lineStart = offset;
  while (lineStart > 0) {
    final previous = source.codeUnitAt(lineStart - 1);
    if (previous == CodeUnit.lineFeed || previous == CodeUnit.carriageReturn) {
      break;
    }
    lineStart -= 1;
  }
  var lineEnd = offset;
  while (lineEnd < source.length) {
    final value = source.codeUnitAt(lineEnd);
    if (value == CodeUnit.lineFeed || value == CodeUnit.carriageReturn) break;
    lineEnd += 1;
  }

  const maximumWidth = 120;
  var windowStart = lineStart;
  if (offset - windowStart > maximumWidth ~/ 2) {
    windowStart = offset - maximumWidth ~/ 2;
  }
  if (windowStart > lineStart &&
      CodeUnit.isLowSurrogate(source.codeUnitAt(windowStart)) &&
      CodeUnit.isHighSurrogate(source.codeUnitAt(windowStart - 1))) {
    // Keep truncation boundaries outside surrogate pairs.
    windowStart -= 1;
  }
  var windowEnd = lineEnd;
  if (windowEnd - windowStart > maximumWidth) {
    windowEnd = windowStart + maximumWidth;
  }
  if (windowEnd < lineEnd &&
      CodeUnit.isHighSurrogate(source.codeUnitAt(windowEnd - 1)) &&
      CodeUnit.isLowSurrogate(source.codeUnitAt(windowEnd))) {
    windowEnd -= 1;
  }
  final leadingEllipsis = windowStart > lineStart;
  final trailingEllipsis = windowEnd < lineEnd;
  final rawLine = source.substring(windowStart, windowEnd);
  final displayLine =
      '${leadingEllipsis ? '…' : ''}'
      '${_sanitizeExcerpt(rawLine)}${trailingEllipsis ? '…' : ''}';
  final caretColumn = offset - windowStart + (leadingEllipsis ? 1 : 0);
  var caretLength = span.endOffset - offset;
  if (caretLength < 1) {
    caretLength = 1;
  }
  final available = displayLine.length - caretColumn;
  if (available > 0 && caretLength > available) caretLength = available;
  if (caretLength > 40) caretLength = 40;
  final suffix = label == null ? '' : ' $label';
  final lineNumber = '${span.startLine + 1}'.padLeft(4);
  final carets = '^' * caretLength;
  return '$lineNumber | $displayLine\n'
      '     | ${' ' * caretColumn}$carets$suffix';
}

/// Replaces control characters that could corrupt terminal diagnostics.
String _sanitizeExcerpt(String text) {
  final buffer = StringBuffer();
  for (var index = 0; index < text.length; index += 1) {
    final codeUnit = text.codeUnitAt(index);
    if (codeUnit == CodeUnit.tab) {
      // One space preserves UTF-16 diagnostic columns.
      buffer.write(' ');
    } else if (CodeUnit.isHighSurrogate(codeUnit) &&
        index + 1 < text.length &&
        CodeUnit.isLowSurrogate(text.codeUnitAt(index + 1))) {
      index += 1;
      buffer
        ..writeCharCode(codeUnit)
        ..writeCharCode(text.codeUnitAt(index));
    } else if (CodeUnit.isHighSurrogate(codeUnit) ||
        CodeUnit.isLowSurrogate(codeUnit) ||
        isUnprintable(codeUnit)) {
      buffer.write('�');
    } else {
      buffer.writeCharCode(codeUnit);
    }
  }
  return buffer.toString();
}
