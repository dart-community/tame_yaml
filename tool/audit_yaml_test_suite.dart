import 'dart:convert';
import 'dart:io';

import 'package:tame_yaml/tame_yaml.dart';

import 'src/yaml_test_suite_data.dart';

const String _usage = '''
Usage: dart run tool/audit_yaml_test_suite.dart
       dart run tool/audit_yaml_test_suite.dart --revision=COMMIT

With no arguments, downloads the pinned YAML test suite revision and reports
how the decoder classifies every upstream case. A revision must be a full,
lowercase 40-character commit SHA.
''';

/// Reports how the decoder handles an upstream YAML test suite revision.
Future<void> main(List<String> arguments) => runWithYamlTestSuiteData(
  arguments,
  usage: _usage,
  action: (dataDirectory, _) => _audit(dataDirectory),
);

void _audit(Directory dataDirectory) {
  final inputs = readYamlTestSuiteInputs(dataDirectory);
  if (inputs.isEmpty) {
    throw YamlTestSuiteDataException(
      'No YAML test suite cases found in ${dataDirectory.path}.',
    );
  }
  var validAccepted = 0;
  var validRejected = 0;
  var invalidAccepted = 0;
  var jsonMismatches = 0;
  final validRejections = <YamlErrorCode, int>{};
  final invalidRejections = <YamlErrorCode, int>{};

  for (final input in inputs) {
    final source = input.source.readAsStringSync();
    try {
      final documents = yamlDecodeAll(source, sourceUrl: input.source.uri);
      if (input.expectsError) {
        invalidAccepted += 1;
        stdout.writeln('INVALID_ACCEPTED\t${input.id}');
        continue;
      }
      validAccepted += 1;

      if (input.expectedJson.existsSync() && documents.length == 1) {
        final expected =
            jsonDecode(input.expectedJson.readAsStringSync()) as Object?;
        if (!_deepEquals(documents.single, expected)) {
          jsonMismatches += 1;
          stdout.writeln(
            'JSON_MISMATCH\t${input.id}\t'
            'actual=${jsonEncode(documents.single)}\t'
            'expected=${jsonEncode(expected)}',
          );
        }
      }
    } on YamlException catch (error) {
      if (input.expectsError) {
        invalidRejections[error.code] =
            (invalidRejections[error.code] ?? 0) + 1;
        // An invalid case can hit a directive or data-profile error before the
        // syntax error upstream expects, which is worth reviewing by hand.
        if (error.code != YamlErrorCode.syntax) {
          stdout.writeln(
            'INVALID_REJECTED\t${error.code.name}\t${input.id}\t'
            '${error.message}',
          );
        }
        continue;
      }
      validRejected += 1;
      validRejections[error.code] = (validRejections[error.code] ?? 0) + 1;
      stdout.writeln(
        'VALID_REJECTED\t${error.code.name}\t${input.id}\t${error.message}',
      );
    }
  }

  stdout
    ..writeln('SUMMARY\tcases\t${inputs.length}')
    ..writeln('SUMMARY\tvalidAccepted\t$validAccepted')
    ..writeln('SUMMARY\tvalidRejected\t$validRejected')
    ..writeln('SUMMARY\tinvalidAccepted\t$invalidAccepted')
    ..writeln('SUMMARY\tjsonMismatches\t$jsonMismatches');
  _writeCounts('', validRejections);
  _writeCounts('invalid.', invalidRejections);

  if (invalidAccepted != 0 || jsonMismatches != 0) exitCode = 1;
}

/// Writes one summary line per observed [counts] entry, in error code order.
void _writeCounts(String prefix, Map<YamlErrorCode, int> counts) {
  for (final code in YamlErrorCode.values) {
    final count = counts[code];
    if (count != null) stdout.writeln('SUMMARY\t$prefix${code.name}\t$count');
  }
}

/// Compares a decoded document to upstream expected JSON.
///
/// Numeric types and the sign of zero must match whenever the runtime
/// represents those distinctions, and two not-a-number values compare equal.
bool _deepEquals(Object? actual, Object? expected) {
  if (actual is num &&
      expected is num &&
      actual == 0 &&
      expected == 0 &&
      actual.isNegative != expected.isNegative) {
    return false;
  }
  if (actual is int) return expected is int && actual == expected;
  if (actual is double) {
    if (expected is! double) return false;
    if (actual.isNaN || expected.isNaN) {
      return actual.isNaN && expected.isNaN;
    }
    return actual == expected;
  }
  if (actual is List<Object?> && expected is List<Object?>) {
    if (actual.length != expected.length) return false;
    for (var index = 0; index < actual.length; index += 1) {
      if (!_deepEquals(actual[index], expected[index])) return false;
    }
    return true;
  }
  if (actual is Map<String, Object?> && expected is Map<Object?, Object?>) {
    if (actual.length != expected.length) return false;
    for (final MapEntry(:key, :value) in actual.entries) {
      if (!expected.containsKey(key)) return false;
      if (!_deepEquals(value, expected[key])) return false;
    }
    return true;
  }
  return actual == expected;
}
