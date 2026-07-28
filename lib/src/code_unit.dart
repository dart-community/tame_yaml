/// UTF-16 code units used by the decoder, and
/// the predicates that classify them.
abstract final class CodeUnit {
  /// The backspace control character.
  static const int backspace = 0x08;

  /// The horizontal tab character.
  static const int tab = 0x09;

  /// The line-feed character.
  static const int lineFeed = 0x0A;

  /// The vertical-tab control character.
  static const int verticalTab = 0x0B;

  /// The form-feed control character.
  static const int formFeed = 0x0C;

  /// The carriage-return character.
  static const int carriageReturn = 0x0D;

  /// The first C0 control character after carriage return.
  static const int shiftOut = 0x0E;

  /// The last C0 control character.
  static const int unitSeparator = 0x1F;

  /// The space character.
  static const int space = 0x20;

  /// The ASCII bit that distinguishes letter case.
  static const int asciiCaseBit = space;

  /// The exclamation-mark character (`!`).
  static const int exclamationMark = 0x21;

  /// The double-quote character (`"`).
  static const int doubleQuote = 0x22;

  /// The number-sign character (`#`).
  static const int numberSign = 0x23;

  /// The percent-sign character (`%`).
  static const int percentSign = 0x25;

  /// The ampersand character (`&`).
  static const int ampersand = 0x26;

  /// The apostrophe character (`'`).
  static const int apostrophe = 0x27;

  /// The asterisk character (`*`).
  static const int asterisk = 0x2A;

  /// The plus-sign character (`+`).
  static const int plusSign = 0x2B;

  /// The comma character (`,`).
  static const int comma = 0x2C;

  /// The hyphen-minus character (`-`).
  static const int hyphenMinus = 0x2D;

  /// The period character (`.`).
  static const int period = 0x2E;

  /// The slash character (`/`).
  static const int slash = 0x2F;

  /// The digit `0`.
  static const int digit0 = 0x30;

  /// The digit `1`.
  static const int digit1 = 0x31;

  /// The digit `7`.
  static const int digit7 = 0x37;

  /// The digit `9`.
  static const int digit9 = 0x39;

  /// The colon character (`:`).
  static const int colon = 0x3A;

  /// The less-than character (`<`).
  static const int lessThan = 0x3C;

  /// The greater-than character (`>`).
  static const int greaterThan = 0x3E;

  /// The question-mark character (`?`).
  static const int questionMark = 0x3F;

  /// The at-sign character (`@`).
  static const int atSign = 0x40;

  /// The uppercase letter `A`.
  static const int uppercaseA = 0x41;

  /// The uppercase letter `E`.
  static const int uppercaseE = 0x45;

  /// The uppercase letter `F`.
  static const int uppercaseF = 0x46;

  /// The uppercase letter `L`.
  static const int uppercaseL = 0x4C;

  /// The uppercase letter `N`.
  static const int uppercaseN = 0x4E;

  /// The uppercase letter `P`.
  static const int uppercaseP = 0x50;

  /// The uppercase letter `T`.
  static const int uppercaseT = 0x54;

  /// The uppercase letter `U`.
  static const int uppercaseU = 0x55;

  /// The uppercase letter `Z`.
  static const int uppercaseZ = 0x5A;

  /// The left square bracket character (`[`).
  static const int leftBracket = 0x5B;

  /// The backslash character (`\`).
  static const int backslash = 0x5C;

  /// The right square bracket character (`]`).
  static const int rightBracket = 0x5D;

  /// The underscore character (`_`).
  static const int underscore = 0x5F;

  /// The grave-accent (or backtick) character (`` ` ``).
  static const int graveAccent = 0x60;

  /// The lowercase letter `a`.
  static const int lowercaseA = 0x61;

  /// The lowercase letter `b`.
  static const int lowercaseB = 0x62;

  /// The lowercase letter `e`.
  static const int lowercaseE = 0x65;

  /// The lowercase letter `f`.
  static const int lowercaseF = 0x66;

  /// The lowercase letter `n`.
  static const int lowercaseN = 0x6E;

  /// The lowercase letter `o`.
  static const int lowercaseO = 0x6F;

  /// The lowercase letter `r`.
  static const int lowercaseR = 0x72;

  /// The lowercase letter `t`.
  static const int lowercaseT = 0x74;

  /// The lowercase letter `u`.
  static const int lowercaseU = 0x75;

  /// The lowercase letter `v`.
  static const int lowercaseV = 0x76;

  /// The lowercase letter `x`.
  static const int lowercaseX = 0x78;

  /// The lowercase letter `z`.
  static const int lowercaseZ = 0x7A;

  /// The left curly bracket character (`{`).
  static const int leftBrace = 0x7B;

  /// The vertical-bar character (`|`).
  static const int verticalBar = 0x7C;

  /// The right curly bracket character (`}`).
  static const int rightBrace = 0x7D;

  /// The tilde character (`~`).
  static const int tilde = 0x7E;

  /// The delete control character.
  static const int delete = 0x7F;

  /// The last C1 control character before next-line.
  static const int indexControl = 0x84;

  /// The first C1 control character after next-line.
  static const int startOfSelectedArea = 0x86;

  /// The last C1 control character.
  static const int applicationProgramCommand = 0x9F;

  /// The Unicode line-separator character.
  static const int lineSeparator = 0x2028;

  /// The Unicode paragraph-separator character.
  static const int paragraphSeparator = 0x2029;

  /// The first UTF-16 high surrogate.
  static const int highSurrogateStart = 0xD800;

  /// The last UTF-16 high surrogate.
  static const int highSurrogateEnd = 0xDBFF;

  /// The first UTF-16 low surrogate.
  static const int lowSurrogateStart = 0xDC00;

  /// The last UTF-16 low surrogate.
  static const int lowSurrogateEnd = 0xDFFF;

  /// The byte-order-mark character.
  static const int byteOrderMark = 0xFEFF;

  /// The first noncharacter at the end of the basic multilingual plane.
  static const int nonCharacterFffe = 0xFFFE;

  /// The last noncharacter at the end of the basic multilingual plane.
  static const int nonCharacterFfff = 0xFFFF;

  /// The first Unicode code point represented by a surrogate pair.
  static const int firstSupplementaryCodePoint = 0x10000;

  /// The largest Unicode code point.
  static const int maximumCodePoint = 0x10FFFF;

  /// Whether [codeUnit] is a UTF-16 high surrogate.
  static bool isHighSurrogate(int codeUnit) =>
      codeUnit >= highSurrogateStart && codeUnit <= highSurrogateEnd;

  /// Whether [codeUnit] is a UTF-16 low surrogate.
  static bool isLowSurrogate(int codeUnit) =>
      codeUnit >= lowSurrogateStart && codeUnit <= lowSurrogateEnd;

  /// Whether [codeUnit] is an ASCII decimal digit.
  static bool isAsciiDigit(int? codeUnit) =>
      codeUnit != null && codeUnit >= digit0 && codeUnit <= digit9;

  /// Whether [codeUnit] is an ASCII hexadecimal digit.
  static bool isAsciiHexDigit(int? codeUnit) =>
      isAsciiDigit(codeUnit) ||
      codeUnit != null &&
          (codeUnit >= uppercaseA && codeUnit <= uppercaseF ||
              codeUnit >= lowercaseA && codeUnit <= lowercaseF);

  /// Returns the numeric value of an ASCII hexadecimal [codeUnit].
  ///
  /// The caller must first establish that
  /// [codeUnit] satisfies [isAsciiHexDigit].
  static int asciiHexDigitValue(int codeUnit) {
    assert(
      isAsciiHexDigit(codeUnit),
      'Expected an ASCII hexadecimal digit.',
    );
    if (codeUnit <= digit9) return codeUnit - digit0;
    // Setting ASCII's case bit normalizes A–F without allocating a string.
    return (codeUnit | asciiCaseBit) - lowercaseA + 10;
  }
}
