/// Fixed resource ceilings applied by every decoding operation.
abstract final class DecoderLimit {
  /// The maximum nested collection depth.
  static const int nestingDepth = 100;

  /// The maximum number of documents in one stream.
  static const int documentsPerStream = 1_000;

  /// The maximum number of parsed nodes in one document.
  static const int parsedNodesPerDocument = 1_000_000;

  /// The maximum number of alias tokens in one document.
  static const int aliasesPerDocument = 10_000;

  /// The maximum alias expansion depth.
  static const int aliasExpansionDepth = 100;

  /// The maximum number of materialized nodes in one document.
  static const int constructedNodesPerDocument = 1_000_000;

  /// The maximum UTF-16 code-unit length of one scalar.
  static const int scalarCodeUnits = 16_777_216;
}
