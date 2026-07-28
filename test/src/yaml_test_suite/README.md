# YAML test suite corpus

[`cases.dart`](cases.dart) vendors the
exact inputs and expected JSON from
[`yaml/yaml-test-suite`](https://github.com/yaml/yaml-test-suite)
in a platform-neutral generated form.
The revision it was generated from is recorded as `yamlTestSuiteRevision`
at the top of that file, and pinned as `pinnedYamlTestSuiteRevision` in
[`tool/src/yaml_test_suite_data.dart`](../../../tool/src/yaml_test_suite_data.dart).
It also contains a reviewed classification for every case:

- 238 valid cases accepted by the strict data profile.
- 70 valid cases intentionally rejected by the strict data profile.
- 94 invalid YAML cases rejected by the decoder.

Rejected cases record the exact `YamlErrorCode`.
An invalid input can encounter a more specific directive or
data-profile error before a later syntax error;
the classification still records that the upstream case is invalid.

To download the pinned upstream revision and
regenerate the vendored corpus, run:

```console
dart run tool/generate_yaml_test_suite.dart
```

The tool downloads the exact pinned commit from GitHub,
extracts it in a temporary directory,
and deletes the upstream data after generating `cases.dart`.

To inspect a deliberate upstream update without regenerating the corpus,
pass its full commit SHA with `--revision=` to the audit tool,
which reports how the decoder classifies every upstream case:

```console
dart run tool/audit_yaml_test_suite.dart --revision=COMMIT
```

Review every classification diff before changing
the pinned revision in the tool.
A valid case becoming rejected, an invalid case becoming accepted,
or an error code changing is a behavior change
rather than an automatic corpus update.
`yaml_test_suite_test.dart` asserts the revision and the three counts above,
so a corpus update fails the suite until those expectations are updated
along with it.

The vendored inputs, expected JSON, and descriptions are
copyright 2016-2020 Ingy döt Net and MIT licensed; see [`LICENSE`](LICENSE).
The classifications and surrounding Dart are part of this package.
