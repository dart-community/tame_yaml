import 'dart:convert';
import 'dart:io';

import 'package:tame_yaml/tame_yaml.dart';

const String _usage = '''
Usage: dart run tool/fuzz.dart [options]

Options:
  --iterations=COUNT    Generate this many cases (default: 1000000).
  --details-start=INDEX Emit case details beginning at this zero-based index.
  --details-count=COUNT Emit details for this many cases.
  --raw-characters      Replace four grammar generators with raw characters.
  -h, --help            Show this help.
''';

const int _usageErrorExitCode = 64;

/// Runs the deterministic parser fuzz corpus used during development.
///
/// The default million-case run emits stable hashes suitable for regression
/// tracking. The semantic hash covers decoded data and error codes; the exact
/// hash additionally covers error locations.
void main(List<String> arguments) {
  if (arguments.contains('--help') || arguments.contains('-h')) {
    stdout.write(_usage);
    return;
  }

  final _Options options;
  try {
    options = _Options.parse(arguments);
  } on FormatException catch (error) {
    _reportUsageError(error.message);
    return;
  }

  _run(options);
}

/// Runs the fuzz corpus described by [options].
void _run(_Options options) {
  final iterations = options.iterations;
  final detailsStart = options.detailsStart;
  final detailsCount = options.detailsCount;
  final rawCharacters = options.rawCharacters;

  final random = _FuzzRandom(0x51A7C0DE);
  final total = _HashSummary();
  final kinds = List<_HashSummary>.generate(_kindCount, (_) => _HashSummary());
  var accepted = 0;
  var rejected = 0;
  for (var index = 0; index < iterations; index += 1) {
    final kind = index % _kindCount;
    final source = _generateSource(random, kind, rawCharacters: rawCharacters);
    late final String semantic;
    late final String exact;
    try {
      final documents = yamlDecodeAll(source);
      semantic = 'ok:${_canonical(documents)}';
      exact = semantic;
      accepted += 1;
    } on YamlException catch (error) {
      semantic = 'error:${error.code.name}';
      exact = '$semantic:${error.offset}:${error.line}:${error.column}';
      rejected += 1;
    }
    total.add(semantic, exact);
    kinds[kind].add(semantic, exact);
    if (index >= detailsStart && index < detailsStart + detailsCount) {
      print(
        jsonEncode(<String, Object?>{
          'index': index,
          'sourceCodeUnits': source.codeUnits,
          'semantic': semantic,
          'exact': exact,
        }),
      );
    }
  }
  print(
    jsonEncode(<String, Object?>{
      'iterations': iterations,
      'mode': rawCharacters ? 'raw-characters' : 'grammar',
      'accepted': accepted,
      'rejected': rejected,
      ...total.toJson(),
      'kinds': [for (final kind in kinds) kind.toJson()],
    }),
  );
}

/// The command-line options accepted by the fuzzer.
final class _Options {
  _Options.parse(List<String> arguments) {
    for (final argument in arguments) {
      if (_optionValue(argument, '--iterations') case final value?) {
        iterations = _parseIntegerOption(value, '--iterations');
      } else if (_optionValue(argument, '--details-start') case final value?) {
        detailsStart = _parseIntegerOption(value, '--details-start');
      } else if (_optionValue(argument, '--details-count') case final value?) {
        detailsCount = _parseIntegerOption(value, '--details-count');
      } else if (argument == '--raw-characters') {
        rawCharacters = true;
      } else {
        throw FormatException('Unknown option: $argument');
      }
    }
    if (iterations < 0) {
      throw const FormatException('--iterations must not be negative.');
    }
    if (detailsStart < -1) {
      throw const FormatException('--details-start must not be less than -1.');
    }
    if (detailsCount < 0) {
      throw const FormatException('--details-count must not be negative.');
    }
    if (detailsCount > 0 && detailsStart < 0) {
      throw const FormatException(
        '--details-start is required when --details-count is positive.',
      );
    }
  }

  /// The number of cases to generate.
  int iterations = 1000000;

  /// The zero-based index to begin emitting case details at, or `-1` for none.
  int detailsStart = -1;

  /// The number of cases to emit details for.
  int detailsCount = 0;

  /// Whether to replace four grammar generators with raw characters.
  bool rawCharacters = false;
}

/// Writes a command-line [message] and the usage text, then marks failure.
void _reportUsageError(String message) {
  stderr
    ..writeln(message)
    ..writeln()
    ..write(_usage);
  exitCode = _usageErrorExitCode;
}

/// The value of `--option=value` in [argument], or `null` for other arguments.
String? _optionValue(String argument, String option) =>
    argument.startsWith('$option=')
    ? argument.substring(option.length + 1)
    : null;

/// Parses an integer [value] supplied to [option].
int _parseIntegerOption(String value, String option) {
  try {
    return int.parse(value);
  } on FormatException {
    throw FormatException('$option must be an integer.');
  }
}

/// The number of generator kinds cycled through, one per iteration.
const int _kindCount = 10;

/// The number of leading kinds replaced by raw characters in that mode.
const int _rawCharacterKinds = 4;

String _generateSource(
  _FuzzRandom random,
  int kind, {
  required bool rawCharacters,
}) {
  if (rawCharacters && kind < _rawCharacterKinds) {
    return _randomCharacters(random);
  }
  return switch (kind) {
    0 || 6 => _scalarCase(random),
    1 => _quotedCase(random),
    2 => _simpleKeyCase(random),
    3 => _commentAndWhitespaceCase(random),
    4 => _indentationCase(random),
    5 => _flowCase(random),
    7 => _directiveAndTagCase(random),
    8 => _documentCase(random),
    _ => _anchorCase(random),
  };
}

String _quotedCase(_FuzzRandom random) => switch (random.nextInt(5)) {
  0 => "'${random.word()}''${random.word()}'",
  1 => '"${random.word()}\\n${random.word()}"',
  2 => '"${random.word()}\n  ${random.word()}"',
  3 => '"unterminated ${random.word()}',
  _ => '"${random.word()}\\q"',
};

String _simpleKeyCase(_FuzzRandom random) => switch (random.nextInt(5)) {
  0 => '${random.word()}: ${random.word()}',
  1 => '? ${random.word()}\n: ${random.word()}',
  2 => '${'k' * (1020 + random.nextInt(10))}: value',
  3 => '[${random.word()}\n  : value]',
  _ => '? [${random.word()}]\n: value',
};

String _commentAndWhitespaceCase(_FuzzRandom random) =>
    switch (random.nextInt(5)) {
      0 => '# ${random.word()}\nkey: ${random.word()} # ${random.word()}',
      1 => ' \t # ${random.word()}\r\n\t ',
      2 => '${random.word()} # not part of the scalar',
      3 => 'key:\n  # ${random.word()}\n  ${random.word()}',
      _ => '${random.pick(const ['----', '...value', '---value'])}\n',
    };

String _randomCharacters(_FuzzRandom random) =>
    random.string(random.nextInt(97), () => random.pick(_alphabet));

String _indentationCase(_FuzzRandom random) {
  final first = random.nextInt(5);
  final second = random.nextInt(7);
  final marker = random.pick(const ['-', '?', ':', 'key:']);
  final whitespace = random.pick(const [' ', '  ', '\t', ' \t', '']);
  return '${' ' * first}$marker$whitespace${random.word()}\n'
      '${' ' * second}${random.word()}: ${random.word()}';
}

String _flowCase(_FuzzRandom random) {
  final open = random.pick(const ['[', '{']);
  final close = open == '[' ? ']' : '}';
  final separator = random.pick(const [', ', ',', '\n ', ' # c\n, ']);
  final colon = random.pick(const [': ', ':', '\n: ', '']);
  return '$open${random.word()}$colon${random.word()}'
      '$separator${random.word()}$close';
}

String _scalarCase(_FuzzRandom random) {
  final value = random.pick(const [
    'null',
    'TRUE',
    '012',
    '0o17',
    '0xFF',
    '.inf',
    '1.25e+3',
    'yes',
    '<<',
  ]);
  return switch (random.nextInt(5)) {
    0 => value,
    1 => "'$value'",
    2 => '"$value\\n${random.word()}"',
    3 => '|${random.pick(const ['', '-', '+'])}\n  $value\n',
    _ =>
      '>${random.pick(const ['', '-', '+'])}\n  $value\n  ${random.word()}\n',
  };
}

String _directiveAndTagCase(_FuzzRandom random) {
  final directive = random.pick(const [
    '%YAML 1.2',
    '%YAML 1.1',
    '%TAG !e! tag:yaml.org,2002:',
    '%UNKNOWN value',
  ]);
  final tag = random.pick(const [
    '!!str',
    '!!int',
    '!e!str',
    '!custom',
    '!<tag:yaml.org,2002:%73tr>',
  ]);
  return '$directive\n---\n$tag ${random.word()}';
}

String _documentCase(_FuzzRandom random) {
  final marker = random.pick(const ['---', '...', '----', '... value']);
  return '$marker\n${random.word()}: ${random.nextInt(100)}\n'
      '${random.pick(const ['', '---\nnext', '...\n---\nnext'])}';
}

String _anchorCase(_FuzzRandom random) {
  final name = random.word();
  return random.pick(<String>[
    'base: &$name [${random.word()}, {key: ${random.word()}}]\ncopy: *$name',
    'value: &$name [*$name]',
    'value: *$name\nnext: &$name data',
    '&$name ${random.word()}: value',
  ]);
}

/// A stable, compact rendering of a decoded value, used for hashing.
String _canonical(Object? value) => switch (value) {
  null => 'n',
  bool() => value ? 'b1' : 'b0',
  int() => 'i$value',
  double(isNaN: true) => 'dnan',
  double(isInfinite: true, isNegative: true) => 'd-inf',
  double(isInfinite: true) => 'dinf',
  double() => 'd$value',
  String() => 's${jsonEncode(value)}',
  List<Object?>() => 'l[${value.map(_canonical).join(',')}]',
  Map<String, Object?>() =>
    'm{${value.entries.map(
      (entry) => '${jsonEncode(entry.key)}:${_canonical(entry.value)}',
    ).join(',')}}',
  _ => throw StateError('Unexpected decoded value: ${value.runtimeType}'),
};

/// A running pair of FNV-1a hashes over decoded results.
final class _HashSummary {
  int _semantic = _fnvOffset;
  int _exact = _fnvOffset;

  void add(String semantic, String exact) {
    _semantic = _hashString(_semantic, semantic);
    _exact = _hashString(_exact, exact);
  }

  Map<String, Object?> toJson() => {
    'semanticHash': _format(_semantic),
    'exactHash': _format(_exact),
  };

  static String _format(int hash) => hash.toRadixString(16).padLeft(8, '0');
}

const int _fnvOffset = 0x811C9DC5;
const int _fnvPrime = 0x01000193;

int _hashString(int hash, String value) {
  var result = hash;
  for (final codeUnit in value.codeUnits) {
    result = ((result ^ codeUnit) * _fnvPrime) & 0xFFFFFFFF;
  }
  return result;
}

/// A seeded xorshift generator, kept deterministic across platforms.
final class _FuzzRandom {
  _FuzzRandom(this._state);

  int _state;

  int nextInt(int maximum) {
    var value = _state;
    value ^= value << 13;
    value ^= value >>> 17;
    value ^= value << 5;
    _state = value & 0xFFFFFFFF;
    return _state % maximum;
  }

  T pick<T>(List<T> values) => values[nextInt(values.length)];

  /// A string built from [length] values produced by [nextCharacterCode].
  String string(int length, int Function() nextCharacterCode) =>
      String.fromCharCodes(
        List<int>.generate(length, (_) => nextCharacterCode(), growable: false),
      );

  /// A lowercase ASCII word of one to twelve letters.
  String word() => string(nextInt(12) + 1, () => 0x61 + nextInt(26));
}

/// Character codes that stress boundary handling, including controls,
/// YAML indicators, line separators, surrogates, and a non-BMP code point.
const List<int> _alphabet = [
  0x00,
  0x09,
  0x0A,
  0x0D,
  0x20,
  0x21,
  0x22,
  0x23,
  0x25,
  0x26,
  0x27,
  0x2A,
  0x2C,
  0x2D,
  0x2E,
  0x30,
  0x39,
  0x3A,
  0x3F,
  0x40,
  0x41,
  0x5B,
  0x5C,
  0x5D,
  0x61,
  0x7B,
  0x7C,
  0x7D,
  0x7E,
  0x85,
  0x2028,
  0x2029,
  0xD800,
  0xDFFF,
  0xFEFF,
  0x1F600,
];
