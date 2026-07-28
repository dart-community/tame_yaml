import 'diagnostic.dart';
import 'span.dart';
import 'tags.dart';

/// Categories for every failure produced by this package.
enum YamlErrorCode {
  /// Invalid YAML syntax.
  syntax,

  /// An explicit `%YAML` directive requests a version other than 1.2.
  unsupportedVersion,

  /// A directive is malformed, repeated, or unknown.
  invalidDirective,

  /// The input contains a character YAML doesn't permit.
  invalidCharacter,

  /// A mapping key didn't construct as a [String].
  nonStringKey,

  /// A mapping contains the same string key more than once.
  duplicateKey,

  /// A mapping pair appears directly in a flow sequence,
  /// or an entry in a flow mapping omits its `:`.
  unsupportedFlowEntry,

  /// An explicit tag is outside the allowed list of core tags.
  unsupportedTag,

  /// A supported explicit tag doesn't match its node or scalar text.
  invalidTaggedValue,

  /// A plain `<<` mapping key was detected.
  mergeKey,

  /// An anchor or alias name is outside the accepted character set.
  unsupportedAnchorName,

  /// An alias has no preceding anchor in the same document.
  undefinedAlias,

  /// Alias expansion would create a cycle.
  recursiveAlias,

  /// The single-document API received more than one document.
  documentCount,

  /// An integer can't be represented exactly on the target runtime.
  integerOutOfRange,

  /// A decimal integer is written with a leading zero.
  leadingZeroInteger,

  /// A fixed document, nesting, node, alias, or scalar limit was exceeded.
  resourceLimit,
}

/// A parser failure with source provenance and optional diagnostic context.
final class DecoderException implements Exception {
  /// Creates an internal decoder failure.
  const DecoderException(
    this.code,
    this.message,
    this.span, {
    this.hint,
    this.relatedSpan,
    this.relatedLabel,
  });

  /// Creates the standard error for a tag applied to an incompatible node.
  ///
  /// [kind] names the node the tag was written on,
  /// such as `scalar` or `mapping`.
  factory DecoderException.invalidTaggedValue(
    YamlCoreTag tag,
    String kind,
    SourceSpan span,
  ) => DecoderException(
    YamlErrorCode.invalidTaggedValue,
    'Tag ${quoteForDiagnostic(tag.uri)} mismatches $kind.',
    span,
  );

  /// The stable category of this failure.
  final YamlErrorCode code;

  /// The direct explanation of the failure.
  final String message;

  /// The source range responsible for the failure.
  final SourceSpan span;

  /// Optional remediation shown after the source excerpt.
  final String? hint;

  /// An earlier source range related to this failure.
  final SourceSpan? relatedSpan;

  /// The label rendered beside [relatedSpan].
  final String? relatedLabel;
}
