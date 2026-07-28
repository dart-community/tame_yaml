import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:tame_yaml/tame_yaml.dart';

const String _usage = '''
Usage: dart run tool/benchmark.dart [options]

Options:
  --quick             Use shorter warmups and samples.
  --only=NAME         Run one named workload.
  --iterations=COUNT  Use a fixed positive batch size.
  --scaling           Run the input-size scaling workloads.
  --single-run        Run each workload once without timing it.
  -h, --help          Show this help.
''';

const int _usageErrorExitCode = 64;

/// Benchmarks representative successful and rejected YAML workloads.
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

  final workloads = (options.scaling ? _scalingWorkloads : _workloads)
      .where(
        (workload) => options.only == null || workload.name == options.only,
      )
      .toList(growable: false);
  if (workloads.isEmpty) {
    _reportUsageError('Unknown workload: ${options.only}.');
    return;
  }

  if (options.singleRun) {
    for (final workload in workloads) {
      _runBatch(workload, 1);
    }
    print(
      jsonEncode(<String, Object?>{
        'workloads': [for (final workload in workloads) workload.name],
        'checksum': _checksum,
      }),
    );
    return;
  }

  final results = <Map<String, Object?>>[];
  for (final workload in workloads) {
    final iterations = options.iterations ?? _calibrate(workload, options);
    for (var warmup = 0; warmup < options.warmups; warmup += 1) {
      _runBatch(workload, iterations);
    }

    final samples = <double>[
      for (var sample = 0; sample < options.samples; sample += 1)
        _runBatch(workload, iterations).inMicroseconds / iterations,
    ]..sort();
    final median = samples[samples.length ~/ 2];
    // A batch faster than the timer resolution rounds down to zero
    // microseconds. Report that as unmeasured instead of inventing a duration
    // or dividing by it, which would not be representable in JSON.
    final measured = median > 0;
    results.add(<String, Object?>{
      'name': workload.name,
      'sourceCodeUnits': workload.source.length,
      'iterations': iterations,
      'measured': measured,
      'medianMicroseconds': measured ? median : null,
      'operationsPerSecond': measured ? 1000000 / median : null,
    });
  }

  const encoder = JsonEncoder.withIndent('  ');
  print(
    encoder.convert(<String, Object?>{
      'samples': options.samples,
      'warmups': options.warmups,
      'minimumBatchMilliseconds': options.minimumBatch.inMilliseconds,
      'results': results,
      'checksum': _checksum,
    }),
  );
}

/// Writes a command-line [message] and the usage text, then marks failure.
void _reportUsageError(String message) {
  stderr
    ..writeln(message)
    ..writeln()
    ..write(_usage);
  exitCode = _usageErrorExitCode;
}

/// The smallest batch size whose runtime reaches [_Options.minimumBatch].
int _calibrate(_Workload workload, _Options options) {
  var iterations = 1;
  while (true) {
    final elapsed = _runBatch(workload, iterations);
    if (elapsed >= options.minimumBatch) return iterations;
    final scale =
        options.minimumBatch.inMicroseconds / max(elapsed.inMicroseconds, 1);
    iterations = max(iterations + 1, (iterations * scale * 1.1).ceil());
  }
}

Duration _runBatch(_Workload workload, int iterations) {
  final stopwatch = Stopwatch()..start();
  for (var iteration = 0; iteration < iterations; iteration += 1) {
    try {
      _consume(
        workload.decodeAll
            ? yamlDecodeAll(workload.source)
            : yamlDecode(workload.source),
      );
    } on YamlException catch (error) {
      _checksum =
          (_checksum * 31 + error.code.index + error.offset) & 0x7FFFFFFF;
    }
  }
  stopwatch.stop();
  return stopwatch.elapsed;
}

/// Folds a decoded result into [_checksum] so no work can be optimized away.
void _consume(Object? value) {
  final contribution = switch (value) {
    null => 1,
    bool() => value ? 2 : 3,
    int() => value & 0xFFFF,
    double() => value.isNaN ? 5 : value.hashCode,
    String() => value.length,
    List<Object?>() => value.length * 7,
    Map<String, Object?>() => value.length * 11,
    _ => throw StateError('Unexpected decoded value.'),
  };
  _checksum = (_checksum * 31 + contribution) & 0x7FFFFFFF;
}

var _checksum = 0;

final class _Options {
  _Options.parse(List<String> arguments) {
    for (final argument in arguments) {
      if (argument == '--quick') {
        samples = 3;
        warmups = 2;
        minimumBatch = const Duration(milliseconds: 50);
      } else if (_optionValue(argument, '--only') case final value?) {
        only = value;
      } else if (_optionValue(argument, '--iterations') case final value?) {
        iterations = _parseIntegerOption(value, '--iterations');
      } else if (argument == '--scaling') {
        scaling = true;
      } else if (argument == '--single-run') {
        singleRun = true;
      } else {
        throw FormatException('Unknown option: $argument');
      }
    }
    if (iterations case final value? when value <= 0) {
      throw const FormatException('--iterations must be positive.');
    }
  }

  /// The number of timed batches measured per workload.
  int samples = 15;

  /// The number of untimed batches run before measuring.
  int warmups = 5;

  /// The batch runtime that calibration aims for.
  Duration minimumBatch = const Duration(milliseconds: 250);

  /// The single workload to run, or `null` for all of them.
  String? only;

  /// The fixed batch size to use instead of calibrating one.
  int? iterations;

  /// Whether to run the input size scaling workloads.
  bool scaling = false;

  /// Whether to run each workload once, for correctness rather than timing.
  bool singleRun = false;
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

final class _Workload {
  const _Workload(this.name, this.source, {this.decodeAll = false});

  final String name;
  final String source;
  final bool decodeAll;
}

final _workloads = <_Workload>[
  const _Workload('early-syntax-error', '['),
  const _Workload('small-config', _smallConfiguration),
  _Workload('large-block', _largeBlockDocument()),
  _Workload('large-flow', '[${_counting(20000).join(',')}]'),
  _Workload('scalar-styles', _scalarStylesDocument()),
  _Workload('document-stream', _documentStream(), decodeAll: true),
  _Workload('alias-expansion', _aliasExpansionDocument()),
  _Workload('late-syntax-error', '${_largeBlockDocument()}broken: [one, two'),
];

final _scalingWorkloads = <_Workload>[
  for (final size in const [16384, 65536, 262144]) ...[
    _Workload('plain-scalar-$size', 'a' * size),
    _Workload('whitespace-$size', ' ' * size),
    _Workload('comment-$size', '#${'c' * size}'),
    _Workload('tag-text-$size', '!<tag:example.com,2026:${'a' * size}> value'),
    _Workload(
      'missing-delimiter-$size',
      '[${List<String>.filled(size ~/ 8, 'value').join(',')}',
    ),
  ],
];

const _smallConfiguration = '''
server:
  host: localhost
  port: 8080
  tls: true
database:
  hosts: [db-1, db-2, db-3]
  pool:
    minimum: 4
    maximum: 32
features:
  parser: yaml
  patterns: true
  retries: 0o10
''';

/// The decimal numbers below [count], as strings.
List<String> _counting(int count) =>
    List<String>.generate(count, (index) => '$index', growable: false);

String _largeBlockDocument() {
  final buffer = StringBuffer();
  for (var index = 0; index < 5000; index += 1) {
    buffer.writeln('key$index: value$index');
  }
  return buffer.toString();
}

String _scalarStylesDocument() {
  final plain = 'plain text ' * 10000;
  final quoted = r'escaped\ntext\t' * 8000;
  final block = List<String>.filled(5000, '  block scalar content').join('\n');
  return 'plain: $plain\nquoted: "$quoted"\nliteral: |\n$block\n';
}

String _documentStream() => [
  for (var index = 0; index < 1000; index += 1) '---\nid: $index',
].join('\n');

String _aliasExpansionDocument() {
  final base = _counting(100).join(',');
  final copies = List<String>.filled(500, '*base').join(',');
  return 'base: &base [$base]\ncopies: [$copies]';
}
