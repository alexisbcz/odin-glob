# Changelog

This file records all notable changes to this project.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-10-29

### Added

- The `Skip_Unreadable` walk flag, which skips directories that can't be read instead of failing the walk.

### Fixed

- Stacked stars such as `*a*a*a*a*a*a*a*b` no longer take minutes on long names. Runs of `*`, `?`, classes and literals now match in linear time per star.
- Repeated `**/` segments, such as `**/**/**/x`, no longer slow matching down.
- A `**` that ends a brace alternative now matches zero segments, so `src/{a,**}/x` matches `src/x` like `src/**/x` does.
- `ignore_add_string` and `ignore_add_file` skip a UTF-8 byte order mark at the start of the text, as Git does.

## [0.1.0] - 2026-10-29

### Added

- Glob patterns with `*`, `?`, character classes, named classes, `**`, `{a,b}` alternation and `\` escapes, through `match`, `compile`, `pattern_match` and `validate`.
- The `Ignore_Case` option for case-insensitive matching.
- `escape` and `has_meta` for quoting literal paths.
- `Walker` and `find` for walking directory trees with a pattern, a depth limit, extra ignore rules and nested `.gitignore` files.
- The `Ignore` gitignore matcher with negation, anchoring, directory-only rules and per-directory precedence.

[Unreleased]: https://github.com/alexisbcz/odin-glob/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/alexisbcz/odin-glob/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/alexisbcz/odin-glob/releases/tag/v0.1.0
