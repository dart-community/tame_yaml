import 'dart:convert';

import 'package:tame_yaml/tame_yaml.dart';
import 'package:test/test.dart';

import 'src/helpers.dart';
import 'src/yaml_test_suite/cases.dart';

void main() {
  // These expectations are the review gate for a corpus update: they only
  // change alongside a regenerated `cases.dart` and a reviewed diff.
  test('uses the reviewed YAML test suite revision and classifications', () {
    expect(yamlTestSuiteRevision, '6e6c296ae9c9d2d5c4134b4b64d01b29ac19ff6f');
    expect(yamlTestSuiteCases, hasLength(402));
    expect(_countOf(YamlTestSuiteClassification.accepted), 238);
    expect(_countOf(YamlTestSuiteClassification.profileRejected), 70);
    expect(_countOf(YamlTestSuiteClassification.invalid), 94);
  });

  test('compares every numeric distinction available on the runtime', () {
    expect(_deepEquals(1, 1), isTrue);
    expect(_deepEquals(1.0, 1.0), isTrue);
    // JavaScript represents these literals with the same number object.
    if (!identical(1, 1.0)) {
      expect(_deepEquals(1, 1.0), isFalse);
      expect(_deepEquals(1.0, 1), isFalse);
    }
    expect(_deepEquals(-0.0, -0.0), isTrue);
    expect(_deepEquals(-0.0, 0.0), isFalse);
    expect(_deepEquals(double.nan, double.nan), isTrue);
  });

  for (final testCase in yamlTestSuiteCases) {
    test('${testCase.id}: ${_decode(testCase.descriptionBase64)}', () {
      final source = _decode(testCase.sourceBase64);
      switch (testCase.classification) {
        case YamlTestSuiteClassification.accepted:
          _expectAccepted(testCase, source);
        case YamlTestSuiteClassification.profileRejected:
        case YamlTestSuiteClassification.invalid:
          final expectedCode = testCase.expectedCode;
          if (expectedCode == null) {
            fail('Rejected case ${testCase.id} has no expected error code.');
          }
          expect(() => yamlDecodeAll(source), throwsYaml(expectedCode));
      }
    });
  }
}

/// Decodes the UTF-8 [base64] text vendored with a case.
String _decode(String base64) => utf8.decode(base64Decode(base64));

/// The number of vendored cases reviewed as [classification].
int _countOf(YamlTestSuiteClassification classification) => yamlTestSuiteCases
    .where((testCase) => testCase.classification == classification)
    .length;

/// Expects [source] to decode, and to match the upstream JSON when the case
/// supplies one for a single document.
void _expectAccepted(YamlTestSuiteCase testCase, String source) {
  final documents = yamlDecodeAll(
    source,
    sourceUrl: Uri.parse('yaml-test-suite:${testCase.id}'),
  );

  final encodedJson = testCase.expectedJsonBase64;
  if (encodedJson == null || documents.length != 1) return;

  final expected = jsonDecode(_decode(encodedJson)) as Object?;
  expect(
    _deepEquals(documents.single, expected),
    isTrue,
    reason:
        'decoded=${jsonEncode(documents.single)} '
        'expected=${jsonEncode(expected)}',
  );
}

/// Whether [actual] and [expected] have the same recursively decoded value.
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
      if (!expected.containsKey(key) || !_deepEquals(value, expected[key])) {
        return false;
      }
    }
    return true;
  }
  return actual == expected;
}
