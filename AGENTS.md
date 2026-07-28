# AGENTS.md

A focused Dart package that decodes a strict, unambiguous subset of
YAML 1.2 into immutable values of built-in Dart types.
It deliberately rejects valid YAML that is easy to misread
or that its narrow data model can't represent predictably.
## Details

- The package requires Dart 3.12 or later and can and should use
  modern Dart features when appropriate.
- The user-facing reasoning behind the design is recorded in `README.md`.

## Code conventions

- Follow [Effective Dart](https://dart.dev/effective-dart).
- Write modern Dart code that follows best practices.
- All public APIs must have idiomatic API doc comments.
- Prefer `final` classes. Use `sealed` only for exhaustive variant types.
- Code is meant for others to read and learn from. Prioritize clarity.
- Never use `dynamic`. If a top type is needed, use `Object?` instead.
