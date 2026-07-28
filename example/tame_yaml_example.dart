import 'package:tame_yaml/tame_yaml.dart';

void main() {
  final pubspec = yamlDecode('''
name: tame_yaml
version: 0.1.0
environment:
  sdk: ^3.12.0
topics:
  - yaml
  - parsing
''');

  switch (pubspec) {
    case {
      'name': final String name,
      'version': final String version,
      'environment': {'sdk': final String sdkConstraint},
      'topics': [final String firstTopic, ...],
    }:
      print('$name $version ($firstTopic) needs Dart $sdkConstraint');
    default:
      throw const FormatException('Invalid pubspec shape.');
  }

  final manifests = yamlDecodeAll('''
---
name: tame_yaml
---
name: tame_yaml_benchmarks
''');
  print('Decoded ${manifests.length} workspace manifests.');

  try {
    final _ = yamlDecode('dependencies:\n  meta: ^1.0.0\n  meta: ^1.16.0');
  } on YamlException catch (error) {
    print('${error.code}: ${error.message}');
  }
}
