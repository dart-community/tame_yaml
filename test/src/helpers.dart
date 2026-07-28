import 'package:tame_yaml/tame_yaml.dart';
import 'package:test/test.dart';

/// Matches a closure that throws a [YamlException] with [code].
Matcher throwsYaml(YamlErrorCode code) => throwsA(
  isA<YamlException>().having((error) => error.code, 'code', code),
);

/// Runs [callback] and returns the [YamlException] it throws.
YamlException captureYamlException(void Function() callback) {
  try {
    callback();
  } on YamlException catch (error) {
    return error;
  }
  fail('Expected a YamlException.');
}

/// Renders [source] as a short, single-line label for a test description
/// or a failure reason.
String describeSource(String source) {
  if (source.isEmpty) return '<empty>';

  final escaped = source
      .replaceAll(r'\', r'\\')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r')
      .replaceAll('\t', r'\t');
  if (escaped.length <= _maximumLabelLength) return escaped;

  // Never split a surrogate pair, which would render as a lone replacement
  // character in the test report.
  final last = escaped.codeUnitAt(_maximumLabelLength - 1);
  final end = last >= 0xD800 && last <= 0xDBFF
      ? _maximumLabelLength - 1
      : _maximumLabelLength;
  return '${escaped.substring(0, end)}…';
}

const _maximumLabelLength = 80;
