import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;

/// The upstream revision the vendored corpus is generated from.
///
/// Bumping this is a deliberate corpus update: regenerate the corpus and
/// review the resulting classification diff.
const String pinnedYamlTestSuiteRevision =
    '6e6c296ae9c9d2d5c4134b4b64d01b29ac19ff6f';

const String _revisionOption = '--revision=';

/// A full, lowercase commit SHA, the only accepted `--revision` value.
final RegExp _revisionPattern = RegExp(r'^[0-9a-f]{40}$');

/// Thrown when upstream data cannot be obtained or used consistently.
final class YamlTestSuiteDataException implements Exception {
  const YamlTestSuiteDataException(this.message);

  /// A description of what went wrong, ready to print.
  final String message;

  @override
  String toString() => message;
}

/// Runs [action] against the upstream data selected by [arguments].
///
/// [arguments] are either empty, selecting [pinnedYamlTestSuiteRevision], or a
/// single `--revision=COMMIT`; anything else writes [usage] and exits with 64.
/// `--help` and `-h` write [usage] and exit successfully.
///
/// The revision is downloaded and extracted into a temporary directory that is
/// deleted before returning, so [action] must not retain the data directory.
/// Failures are reported to standard error with a non-zero exit code.
Future<void> runWithYamlTestSuiteData(
  List<String> arguments, {
  required String usage,
  required void Function(Directory dataDirectory, String revision) action,
}) async {
  final String revision;
  switch (arguments) {
    case ['--help'] || ['-h']:
      stdout.write(usage);
      return;
    case []:
      revision = pinnedYamlTestSuiteRevision;
    case [final argument]
        when argument.startsWith(_revisionOption) &&
            _revisionPattern.hasMatch(
              argument.substring(_revisionOption.length),
            ):
      revision = argument.substring(_revisionOption.length);
    default:
      stderr.write(usage);
      exitCode = 64;
      return;
  }

  final temporaryDirectory = await Directory.systemTemp.createTemp(
    'tame_yaml_test_suite_',
  );
  try {
    action(await _retrieveData(revision, temporaryDirectory), revision);
  } on IOException catch (error) {
    stderr.writeln('Unable to read or write YAML test suite data: $error');
    exitCode = 1;
  } on ArchiveException catch (error) {
    stderr.writeln('Unable to extract YAML test suite data: $error');
    exitCode = 1;
  } on YamlTestSuiteDataException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  } finally {
    await temporaryDirectory.delete(recursive: true);
  }
}

/// Downloads and extracts [revision] within [temporaryDirectory].
Future<Directory> _retrieveData(
  String revision,
  Directory temporaryDirectory,
) async {
  final archive = File(
    _joinPath(temporaryDirectory.path, 'yaml-test-suite.tar.gz'),
  );
  final source = Uri.https(
    'github.com',
    '/yaml/yaml-test-suite/archive/$revision.tar.gz',
  );
  stdout.writeln('Downloading YAML test suite revision $revision...');
  await _download(source, archive);
  await extractFileToDisk(archive.path, temporaryDirectory.path);

  final dataDirectory = Directory(
    _joinPath(temporaryDirectory.path, 'yaml-test-suite-$revision'),
  );
  if (!dataDirectory.existsSync()) {
    throw YamlTestSuiteDataException(
      'Archive did not contain yaml-test-suite-$revision.',
    );
  }
  return dataDirectory;
}

/// Writes the contents of [source] to [destination].
Future<void> _download(Uri source, File destination) async {
  final http.Response response;
  try {
    response = await http.get(source).timeout(const Duration(seconds: 30));
  } on http.ClientException catch (error) {
    throw YamlTestSuiteDataException('Unable to download $source: $error');
  } on TimeoutException {
    throw YamlTestSuiteDataException('Timed out downloading $source.');
  }

  if (response.statusCode != HttpStatus.ok) {
    throw YamlTestSuiteDataException(
      'Download of $source returned HTTP ${response.statusCode}.',
    );
  }
  await destination.writeAsBytes(response.bodyBytes);
}

/// One case directory in an upstream YAML test suite data directory.
final class YamlTestSuiteInput {
  const YamlTestSuiteInput(this.id, this.directory);

  /// The stable upstream case identifier, such as `229Q` or `DK95/00`.
  final String id;

  /// The directory holding the case's input and metadata files.
  final Directory directory;

  /// The case input document.
  File get source => file('in.yaml');

  /// The expected JSON for the case, which only some cases supply.
  File get expectedJson => file('in.json');

  /// The upstream one-line description of the case.
  File get description => file('===');

  /// Whether upstream marks this case as invalid YAML.
  bool get expectsError => file('error').existsSync();

  /// The file named [name] within this case, which need not exist.
  File file(String name) => File(_joinPath(directory.path, name));
}

/// Lists the cases under [root], in stable identifier order.
///
/// A case is any directory containing an `in.yaml` file, so nested
/// multi-document cases such as `DK95/00` are included alongside flat ones.
List<YamlTestSuiteInput> readYamlTestSuiteInputs(Directory root) => [
  for (final entity in root.listSync(recursive: true, followLinks: false))
    if (entity is File && entity.uri.pathSegments.last == 'in.yaml')
      YamlTestSuiteInput(
        _caseId(root, entity.parent),
        entity.parent,
      ),
]..sort((first, second) => first.id.compareTo(second.id));

/// Returns [directory]'s normalized, slash-separated identifier within [root].
String _caseId(Directory root, Directory directory) {
  final relativePath = directory.absolute.path.substring(
    root.absolute.path.length,
  );
  return relativePath
      .split(Platform.pathSeparator)
      .where((segment) => segment.isNotEmpty)
      .join('/');
}

/// Joins one path [parent] with a single child [name].
String _joinPath(String parent, String name) =>
    '$parent${Platform.pathSeparator}$name';
