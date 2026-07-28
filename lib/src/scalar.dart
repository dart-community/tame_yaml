import 'code_unit.dart';
import 'errors.dart';
import 'span.dart';
import 'tags.dart';

/// The presentation styles a YAML scalar can be written in.
///
/// Only a [plain] scalar resolves to
/// something other than a string on its own,
/// so the rest carry their text through untouched
/// unless an explicit tag says otherwise.
enum ScalarStyle {
  /// An unquoted scalar, such as `true`.
  plain,

  /// A scalar wrapped in single quotes, such as `'true'`.
  singleQuoted,

  /// A scalar wrapped in double quotes, such as `"true"`.
  doubleQuoted,

  /// A block scalar introduced by `|`, which keeps its line breaks.
  literal,

  /// A block scalar introduced by `>`, which folds its line breaks to spaces.
  folded,
}

/// Resolves the scalar [text], written in [style], to its core-schema value.
///
/// A non-`null` [tag] forces the result to that tag's type.
///
/// Throws a [DecoderException], located by [span],
/// when the scalar doesn't match its tag,
/// when a decimal integer carries a leading zero, or
/// when an integer is outside the exact range.
Object? resolveScalar(
  String text,
  ScalarStyle style,
  YamlCoreTag? tag,
  SourceSpan span,
) {
  // Every core tag either resolves or rejects the scalar outright,
  // so a tagged scalar never reaches the untagged resolution below.
  if (tag != null) {
    switch (tag) {
      case YamlCoreTag.string:
        return text;
      case YamlCoreTag.nullValue:
        if (!_isNull(text)) {
          throw DecoderException.invalidTaggedValue(tag, 'scalar', span);
        }
        return null;
      case YamlCoreTag.boolean:
        final value = _resolveBoolean(text);
        if (value == null) {
          throw DecoderException.invalidTaggedValue(tag, 'scalar', span);
        }
        return value;
      case YamlCoreTag.integer:
        final format = _integerFormat(text);
        if (format == null) {
          throw DecoderException.invalidTaggedValue(tag, 'scalar', span);
        }
        return _resolveInteger(text, format, span);
      case YamlCoreTag.float:
        // Deliberately parsed here rather than through [_resolveInteger],
        // because a float is exempt from that function's leading-zero rule:
        // no dialect reads one as octal,
        // so `!!float 0644` is unambiguously 644.0.
        final value =
            _resolveFloat(text) ??
            (_integerFormat(text) == _IntegerFormat.decimal
                ? double.parse(text)
                : null);
        if (value == null) {
          throw DecoderException.invalidTaggedValue(tag, 'scalar', span);
        }
        return value;
      case YamlCoreTag.sequence || YamlCoreTag.mapping:
        throw DecoderException.invalidTaggedValue(tag, 'scalar', span);
    }
  }

  if (style != ScalarStyle.plain) return text;
  if (text.isEmpty) return null;

  // A leading character narrows resolution to the one kind that can match,
  // apart from integers and floats, which share theirs.
  // Text starting with anything else is already a string.
  final first = text.codeUnitAt(0);
  if (CodeUnit.isAsciiDigit(first)) return _resolveNumber(text, span);
  return switch (first) {
    CodeUnit.plusSign ||
    CodeUnit.hyphenMinus ||
    CodeUnit.period => _resolveNumber(text, span),
    CodeUnit.tilde ||
    CodeUnit.lowercaseN ||
    CodeUnit.uppercaseN => _isNull(text) ? null : text,
    CodeUnit.lowercaseT ||
    CodeUnit.uppercaseT ||
    CodeUnit.lowercaseF ||
    CodeUnit.uppercaseF => _resolveBoolean(text) ?? text,
    _ => text,
  };
}

/// Resolves [text] as an integer or a float,
/// the two spellings that share leading characters,
/// or returns [text] itself if it is neither.
Object _resolveNumber(String text, SourceSpan span) {
  final format = _integerFormat(text);
  if (format != null) return _resolveInteger(text, format, span);
  return _resolveFloat(text) ?? text;
}

/// Whether [text] is one of the core-schema null spellings.
bool _isNull(String text) => switch (text) {
  '' || '~' || 'null' || 'Null' || 'NULL' => true,
  _ => false,
};

/// Resolves [text] as a core-schema boolean,
/// or returns `null` if it is not one.
bool? _resolveBoolean(String text) => switch (text) {
  'true' || 'True' || 'TRUE' => true,
  'false' || 'False' || 'FALSE' => false,
  _ => null,
};

/// The integer syntaxes accepted by the YAML 1.2 core schema.
enum _IntegerFormat {
  /// A base-ten integer, such as `-12`, the only format that can carry a sign.
  decimal,

  /// A base-eight integer written with an `0o` prefix, such as `0o14`.
  octal,

  /// A base-sixteen integer written with an `0x` prefix, such as `0xC`.
  hexadecimal,
}

/// The width of the optional leading sign on the non-empty [text].
int _signLength(String text) {
  final first = text.codeUnitAt(0);
  return first == CodeUnit.plusSign || first == CodeUnit.hyphenMinus ? 1 : 0;
}

/// Returns the index where the digits of [text] start, past an optional sign.
///
/// Returns `null` for text no numeric spelling can match:
/// empty text, or a sign with nothing after it.
int? _afterSign(String text) {
  if (text.isEmpty) return null;
  final digitsStart = _signLength(text);
  return digitsStart == text.length ? null : digitsStart;
}

/// Returns the format [text] is written in, or `null` if it is not an integer.
///
/// Recognizes the exact integer grammar without invoking a runtime parser.
_IntegerFormat? _integerFormat(String text) {
  final digitsStart = _afterSign(text);
  if (digitsStart == null) return null;

  // Only an unsigned spelling can state its radix.
  if (digitsStart == 0 &&
      text.length > 2 &&
      text.codeUnitAt(0) == CodeUnit.digit0) {
    final prefix = text.codeUnitAt(1);
    if (prefix == CodeUnit.lowercaseO) {
      for (var digit = 2; digit < text.length; digit += 1) {
        final codeUnit = text.codeUnitAt(digit);
        if (codeUnit < CodeUnit.digit0 || codeUnit > CodeUnit.digit7) {
          return null;
        }
      }
      return _IntegerFormat.octal;
    }
    if (prefix == CodeUnit.lowercaseX) {
      for (var digit = 2; digit < text.length; digit += 1) {
        if (!CodeUnit.isAsciiHexDigit(text.codeUnitAt(digit))) {
          return null;
        }
      }
      return _IntegerFormat.hexadecimal;
    }
  }

  for (var index = digitsStart; index < text.length; index += 1) {
    if (!CodeUnit.isAsciiDigit(text.codeUnitAt(index))) return null;
  }
  return _IntegerFormat.decimal;
}

/// Returns the value of [text], already recognized as [format].
///
/// Throws a [DecoderException], located by [span],
/// when a decimal integer carries a leading zero,
/// or when the value is outside the exact integer range of the runtime.
int _resolveInteger(
  String text,
  _IntegerFormat format,
  SourceSpan span,
) {
  // Only a decimal integer can carry a sign;
  // the others begin past their radix prefix.
  final digitsStart = format == _IntegerFormat.decimal ? _signLength(text) : 2;

  // A leading zero marks octal in YAML 1.1, C, and most shells,
  // and means nothing here, so `0644` reads as
  // two different numbers depending on which the writer assumed.
  // Only base ten is affected: `0o644` and `0x0FF` state their radix outright,
  // and no dialect reads a float as octal.
  if (format == _IntegerFormat.decimal &&
      text.length - digitsStart > 1 &&
      text.codeUnitAt(digitsStart) == CodeUnit.digit0) {
    throw DecoderException(
      YamlErrorCode.leadingZeroInteger,
      'Decimal integer has a leading zero.',
      span,
      hint: 'Remove the zero, write 0o for octal, or quote the value.',
    );
  }

  final negative = text.codeUnitAt(0) == CodeUnit.hyphenMinus;

  // JavaScript represents both literals with the same number object,
  // unlike native and WebAssembly runtimes.
  const isJavaScript = identical(1, 1.0);
  // Comparing digit strings first avoids handing an out-of-range value
  // to the runtime-specific int parser.
  final String maximum;
  if (isJavaScript) {
    maximum = switch (format) {
      .decimal => '9007199254740991',
      .octal => '377777777777777777',
      .hexadecimal => '1fffffffffffff',
    };
  } else {
    maximum = switch (format) {
      .decimal => negative ? '9223372036854775808' : '9223372036854775807',
      .octal => '777777777777777777777',
      .hexadecimal => '7fffffffffffffff',
    };
  }

  var significantStart = digitsStart;
  while (significantStart < text.length &&
      text.codeUnitAt(significantStart) == CodeUnit.digit0) {
    significantStart += 1;
  }
  if (significantStart == text.length) {
    return 0;
  }

  final significantLength = text.length - significantStart;
  if (significantLength > maximum.length ||
      significantLength == maximum.length &&
          _compareDigits(text, significantStart, maximum) > 0) {
    throw DecoderException(
      YamlErrorCode.integerOutOfRange,
      'Integer is outside the exact range.',
      span,
    );
  }

  final radix = switch (format) {
    .decimal => 10,
    .octal => 8,
    .hexadecimal => 16,
  };

  final digits = text.substring(significantStart);
  return int.parse(negative ? '-$digits' : digits, radix: radix);
}

/// Lexically compares the digits of [text] at [start] against the
/// equal-length [maximum], without converting either to an integer.
///
/// Returns a negative value, zero, or a positive value as the digits
/// order before, the same as, or after those of [maximum].
int _compareDigits(String text, int start, String maximum) {
  for (var index = 0; index < maximum.length; index += 1) {
    final actual = CodeUnit.asciiHexDigitValue(text.codeUnitAt(start + index));
    final limit = CodeUnit.asciiHexDigitValue(maximum.codeUnitAt(index));
    if (actual != limit) return actual - limit;
  }
  return 0;
}

/// Resolves [text] as a core-schema float,
/// including the non-finite spellings,
/// or returns `null` if it is not one.
double? _resolveFloat(String text) {
  final special = switch (text) {
    '.inf' ||
    '.Inf' ||
    '.INF' ||
    '+.inf' ||
    '+.Inf' ||
    '+.INF' => double.infinity,
    '-.inf' || '-.Inf' || '-.INF' => double.negativeInfinity,
    '.nan' || '.NaN' || '.NAN' => double.nan,
    _ => null,
  };
  if (special != null) return special;
  if (!_isFiniteFloat(text)) return null;
  return double.parse(text);
}

/// Whether [text] matches the finite float grammar of the core schema.
bool _isFiniteFloat(String text) {
  final digitsStart = _afterSign(text);
  if (digitsStart == null) return false;

  var index = digitsStart;
  var digitsBeforeDot = 0;
  while (index < text.length && CodeUnit.isAsciiDigit(text.codeUnitAt(index))) {
    digitsBeforeDot += 1;
    index += 1;
  }

  var sawDot = false;
  var digitsAfterDot = 0;
  if (index < text.length && text.codeUnitAt(index) == CodeUnit.period) {
    sawDot = true;
    index += 1;
    while (index < text.length &&
        CodeUnit.isAsciiDigit(text.codeUnitAt(index))) {
      digitsAfterDot += 1;
      index += 1;
    }
  }
  if (digitsBeforeDot == 0 && (!sawDot || digitsAfterDot == 0)) return false;

  var sawExponent = false;
  if (index < text.length &&
      (text.codeUnitAt(index) == CodeUnit.uppercaseE ||
          text.codeUnitAt(index) == CodeUnit.lowercaseE)) {
    sawExponent = true;
    index += 1;
    if (index < text.length &&
        (text.codeUnitAt(index) == CodeUnit.plusSign ||
            text.codeUnitAt(index) == CodeUnit.hyphenMinus)) {
      index += 1;
    }
    final exponentStart = index;
    while (index < text.length &&
        CodeUnit.isAsciiDigit(text.codeUnitAt(index))) {
      index += 1;
    }
    if (index == exponentStart) return false;
  }

  return index == text.length && (sawDot || sawExponent);
}
