# Changelog

This file records all notable changes to this project.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-29

### Added

- Glob patterns with `*`, `?`, character classes, named classes, `**`, `{a,b}` alternation and `\` escapes, through `match`, `compile`, `pattern_match` and `validate`.
- The `Ignore_Case` option for case-insensitive matching.
- `escape` and `has_meta` for quoting literal paths.
- `Walker` and `find` for walking directory trees with a pattern, a depth limit, extra ignore rules and nested `.gitignore` files.
- The `Ignore` gitignore matcher with negation, anchoring, directory-only rules and per-directory precedence.

[Unreleased]: https://github.com/alexisbcz/odin-glob/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/alexisbcz/odin-glob/releases/tag/v0.1.0
