import 'package:meta/meta.dart';

import 'decoder.dart';
import 'diagnostic.dart';
import 'errors.dart';
import 'span.dart';

/// Decodes the specified YAML [source] that holds at most one document.
///
/// Returns the decoded document, or `null` if [source] is empty or
/// holds nothing but comments and whitespace.
/// Use [yamlDecodeAll] for a source with several documents.
///
/// Scalars resolve with the YAML 1.2 core schema,
/// so the result is built only from values of the following types:
///
/// - `null`
/// - `bool`
/// - `int`
/// - `double`
/// - `String`
/// - `List<Object?>`
/// - `Map<String, Object?>`
///
/// Every collection is recursively unmodifiable,
/// and every mapping keeps its source order.
///
/// Only a strict subset of YAML 1.2 is accepted.
/// The library documentation lists that subset,
/// the deviations from the specification, and the fixed limits.
///
/// [sourceUrl] only labels the source in diagnostics.
/// It never changes how [source] decodes.
///
/// Throws a [YamlException] when [source]
/// falls outside the accepted subset,
/// holds an integer outside the target runtime's exact [int] range,
/// or exceeds a safety limit.
/// A second document is reported as [YamlErrorCode.documentCount].
@useResult
Object? yamlDecode(String source, {Uri? sourceUrl}) {
  final documents = _decode(
    source,
    sourceUrl: sourceUrl,
    singleDocument: true,
  );
  return documents.isEmpty ? null : documents.single;
}

/// Decodes every document in the specified YAML [source], in source order.
///
/// Returns one entry per document, or an empty list if [source] is empty
/// or holds nothing but comments and whitespace.
/// An explicit empty document, written as `---`, contributes one `null`.
///
/// Scalars resolve with the YAML 1.2 core schema,
/// so the entries are built only from values of the following types:
///
/// - `null`
/// - `bool`
/// - `int`
/// - `double`
/// - `String`
/// - `List<Object?>`
/// - `Map<String, Object?>`
///
/// The returned list and every collection within it are
/// recursively unmodifiable, and every mapping keeps its source order.
///
/// Only a strict subset of YAML 1.2 is accepted.
/// The library documentation lists that subset,
/// the deviations from the specification, and the fixed limits.
///
/// [sourceUrl] only labels the source in diagnostics.
/// It never changes how [source] decodes.
///
/// Throws a [YamlException] when [source]
/// falls outside the accepted subset,
/// holds an integer outside the target runtime's exact [int] range,
/// or exceeds a safety limit.
@useResult
List<Object?> yamlDecodeAll(String source, {Uri? sourceUrl}) => _decode(
  source,
  sourceUrl: sourceUrl,
  singleDocument: false,
);

/// Runs the decoder and translates any failure to the public error model.
List<Object?> _decode(
  String source, {
  required Uri? sourceUrl,
  required bool singleDocument,
}) {
  try {
    return decodeYaml(
      source,
      singleDocument: singleDocument,
    );
  } on DecoderException catch (error) {
    throw YamlException._(
      error.message,
      code: error.code,
      sourceUrl: sourceUrl,
      span: error.span,
      excerpt: buildExcerpt(
        error.span,
        relatedSpan: error.relatedSpan,
        relatedLabel: error.relatedLabel,
        hint: error.hint,
      ),
    );
  }
}

/// A failure reported by [yamlDecode] or [yamlDecodeAll].
///
/// Every failure carries a stable [code] to branch on and a location
/// within the decoded string.
///
/// [offset] is zero-based, while [line] and [column] are one-based.
/// [offset] and [column] count UTF-16 code units.
///
/// The source string isn't retained, so [source] is always `null` and
/// [toString] renders an excerpt captured while decoding.
///
/// This implements [FormatException] rather than extending it,
/// so that [offset] is always supplied rather than nullable.
final class YamlException implements FormatException {
  /// Creates a public failure from an internal decoding failure.
  YamlException._(
    this.message, {
    required this.code,
    required this.sourceUrl,
    required SourceSpan span,
    required this._excerpt,
  }) : line = span.startLine + 1,
       column = span.startColumn + 1,
       offset = span.startOffset;

  /// A short description of what went wrong.
  ///
  /// The wording can change between versions, so branch on [code] instead.
  @override
  final String message;

  /// The stable category of this failure.
  final YamlErrorCode code;

  /// The diagnostic label passed to [yamlDecode] or [yamlDecodeAll].
  final Uri? sourceUrl;

  /// The one-based line that holds the offending token.
  final int line;

  /// The one-based UTF-16 code-unit column that holds the offending token.
  final int column;

  /// The zero-based UTF-16 code-unit offset of the offending token.
  @override
  final int offset;

  /// The excerpt rendered while the source string was still available.
  final String _excerpt;

  /// Always `null`, since the decoded source text isn't retained.
  @override
  Object? get source => null;

  /// Describes this failure with its category, location, and excerpt.
  @override
  String toString() {
    final location = sourceUrl == null
        ? 'line $line, column $column'
        : '$sourceUrl:$line:$column';
    return 'YamlException (${code.name}): $message\n$location\n\n$_excerpt';
  }
}
