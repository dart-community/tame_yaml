/// Provides [yamlDecode] and [yamlDecodeAll] for decoding
/// a strict, unambiguous subset of YAML 1.2
/// into immutable values of built-in Dart types.
///
/// Both functions resolve scalars with the YAML 1.2 core schema,
/// so a decoded value is built only from values of the following types:
///
/// - `null`
/// - `bool`
/// - `int`
/// - `double`
/// - `String`
/// - `List<Object?>`
/// - `Map<String, Object?>`
///
/// Every collection is recursively unmodifiable,
/// and every mapping keeps its source order.
/// Any failure is a [YamlException] categorized by a [YamlErrorCode].
///
/// ## Accepted subset
///
/// Valid YAML that this value domain can't represent predictably is
/// rejected rather than coerced:
///
/// - A mapping key must construct as a string and is never coerced,
///   so `42: value` is rejected while `!!str 42: value` is accepted.
/// - Duplicate keys are rejected after construction,
///   so `name:` and `"name":` collide.
/// - Only the core tags `!!null`, `!!bool`, `!!int`, `!!float`,
///   `!!str`, `!!seq`, and `!!map` are accepted,
///   and each must agree with the node it's written on.
/// - Flow collections must have JSON's structure,
///   so `[a: 1]` and `{a, b: 2}` are rejected instead of
///   decoding as `[{a: 1}]` and `{a: null, b: 2}`.
///   Trailing commas and an omitted value after a `:` remain valid.
/// - An anchor or alias name must
///   start with an ASCII letter, digit, or underscore,
///   and can continue with those, dots, and hyphens.
///   YAML itself allows nearly any character in a name,
///   so narrowing it keeps a name from resembling another construct.
/// - An alias expands to an independent deep copy,
///   and a forward, undefined, cross-document,
///   or recursive alias is rejected.
///
/// ## Deviations from the specification
///
/// In addition to the flow-collection and anchor-name restrictions above,
/// the following safeguards reject otherwise representable constructs that
/// can potentially hide a mistake.
///
/// - `%YAML 1.1`, and any other version the specification would
///   process with a warning, such as `%YAML 1.3`, is rejected.
/// - An unknown directive is rejected rather than ignored.
/// - A plain `<<` mapping key is rejected,
///   so an intended merge can't silently become ordinary data.
///   Quoted `"<<"` and `!!str <<` keys remain ordinary data.
/// - A decimal integer with a leading zero, such as `0644`, is rejected.
///   The core schema reads it as `644` while
///   YAML 1.1 reads it as octal `420`,
///   and both readings produce an `int`,
///   so nothing downstream can catch the difference.
///   Write `0o644`, `644`, or `'0644'` to say which one you meant.
///
/// ## Fixed limits
///
/// Limits aren't configurable and are reset per document,
/// except for the document count, which covers the whole source.
/// Exceeding one throws a [YamlErrorCode.resourceLimit] failure:
///
/// - 100 levels of collection nesting.
/// - 1,000 documents in one source.
/// - 1,000,000 parsed nodes and 1,000,000 constructed nodes per document.
/// - 10,000 alias occurrences and 100 levels of alias expansion
///   per document.
/// - 16,777,216 UTF-16 code units per scalar.
///
/// An integer must also fit the target runtime's exact `int` range:
/// signed 64-bit on native and WebAssembly targets,
/// and the safe-integer range when compiled to JavaScript.
///
/// @docImport 'src/api.dart';
/// @docImport 'src/errors.dart';
library;

export 'src/api.dart' show YamlException, yamlDecode, yamlDecodeAll;
export 'src/errors.dart' show YamlErrorCode;
