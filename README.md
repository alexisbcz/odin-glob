# glob

[![CI](https://github.com/alexisbcz/odin-glob/actions/workflows/ci.yml/badge.svg)](https://github.com/alexisbcz/odin-glob/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Odin](https://img.shields.io/badge/Odin-dev--2026--09-1e5a99.svg)](https://odin-lang.org)

Glob pattern matching, directory walking and gitignore rules for Odin, with explicit allocators and no hidden global state.

- Patterns support `*`, `?`, `[a-z]`, `[!x]`, `[[:digit:]]`, `**`, `{a,b}` alternation and `\` escapes.
- A walker visits a directory tree in a stable order, prunes directories that can't match and can honor nested `.gitignore` files.
- A standalone gitignore matcher handles negation, anchoring, directory-only rules and per-directory precedence the way Git does.

## Install

The repository root is the package, so you can vendor it in two ways.

As a Git submodule inside your project:

```sh
git submodule add https://github.com/alexisbcz/odin-glob libs/glob
```

```odin
import "libs/glob"
```

As a copy in a shared collection that all your projects use:

```sh
git clone https://github.com/alexisbcz/odin-glob ~/odin-shared/glob
odin build . -collection:shared=$HOME/odin-shared
```

```odin
import "shared:glob"
```

## Quick start

```odin
package main

import "core:fmt"
import "shared:glob"

main :: proc() {
	// Match one path.
	ok, err := glob.match("src/**/*.{odin,c}", "src/net/http.odin")
	if err != nil {
		fmt.eprintln("bad pattern:", err)
		return
	}
	fmt.println("matches:", ok)

	// Find files on disk, skipping what .gitignore excludes.
	paths, ferr := glob.find(".", "**/*.odin", {.Gitignore, .Skip_Dirs})
	if ferr != nil {
		fmt.eprintln("find failed:", ferr)
		return
	}
	defer glob.delete_paths(paths)
	for path in paths {
		fmt.println(path)
	}
}
```

## Pattern syntax

Patterns use `/` as the separator on every platform and must match the whole path.

| Syntax | Matches |
| --- | --- |
| `*` | Any run of characters except `/`, including none |
| `?` | One character except `/` |
| `[abc]`, `[a-z]` | One character from the set or range |
| `[!abc]`, `[^abc]` | One character outside the set; never `/` |
| `[[:alpha:]]` | One character from a named class: `alnum`, `alpha`, `blank`, `digit`, `lower`, `punct`, `space`, `upper`, `xdigit` |
| `**` | As a whole segment, zero or more segments: `a/**/b` matches `a/b` and `a/x/y/b` |
| `dir/**` | `dir` itself and everything below it |
| `{a,b}` | Any one of the alternatives, which may contain `/` and nest |
| `\x` | The character `x` literally |

Inside a segment, `**` acts like `*`. Wildcards match names that start with a dot. Pass `{.Ignore_Case}` to compare letters without regard to case.

A malformed pattern returns a `Pattern_Error`: `Unclosed_Class`, `Unclosed_Brace`, `Trailing_Escape`, `Invalid_Range`, `Unknown_Class_Name` or `Nesting_Too_Deep`. `validate` also returns the byte offset of the problem.

## Gitignore rules

`Ignore` follows the format that Git documents. A `!` prefix includes a path again, a trailing `/` matches directories only, and a `/` at the start or in the middle anchors the rule to its directory. The last matching rule wins. Pass the directory of each `.gitignore` as `base`, adding parents before children, so deeper files take precedence.

```odin
ignore: glob.Ignore
glob.ignore_init(&ignore)
defer glob.ignore_destroy(&ignore)

_, _ = glob.ignore_add_string(&ignore, "*.log\nbuild/\n")
_, _ = glob.ignore_add_string(&ignore, "!keep.log\n", "server")

fmt.println(glob.ignore_is_ignored(&ignore, "debug.log", false))       // true
fmt.println(glob.ignore_is_ignored(&ignore, "server/keep.log", false)) // false
fmt.println(glob.ignore_is_ignored(&ignore, "build/out.o", false))     // true, through build/
```

As in Git, a rule can't include a path again once a rule ignores one of its parent directories. `ignore_is_ignored` checks parent directories for you, while `ignore_match` looks at one path only and tells `.Ignored`, `.Included` and `.None` apart. Braces have no special meaning in gitignore rules, and `ignore_add_string` skips malformed lines the way Git does.

## Walking directories

`Walker` visits a tree depth first, with each directory's entries in name order. It never follows symbolic links.

```odin
w: glob.Walker
defer glob.walker_destroy(&w)
if err := glob.walker_init(&w, root, {pattern = pattern, flags = {.Gitignore, .Skip_Dirs}}); err != nil {
	fmt.eprintln("find:", err)
	os.exit(1)
}
for entry in glob.walker_next(&w) {
	fmt.println(entry.path)
}
if path, err := glob.walker_error(&w); err != nil {
	fmt.eprintfln("find: %s: %v", path, err)
	os.exit(1)
}
```

`Walk_Options` also takes `ignore_patterns` for extra rules at the root, `max_depth` and `pattern_options`. Call `walker_skip_dir` right after the walker yields a directory to skip its contents. Entry strings stay valid until the next call to `walker_next`.

## API overview

| Declaration | Purpose | Allocates | Free with |
| --- | --- | --- | --- |
| `match(pattern, path, options, allocator)` | Match one path against a pattern | Scratch only | Not needed |
| `compile(pattern, options, allocator)` | Parse a pattern for repeated use | Yes | `pattern_destroy` |
| `pattern_match(p, path)` | Match against a compiled pattern | No | Not needed |
| `validate(pattern, allocator)` | Check syntax and report the error offset | Scratch only | Not needed |
| `escape(s, allocator)` | Quote special characters | Yes | `delete` |
| `has_meta(s)` | Report whether `s` contains special characters | No | Not needed |
| `find(root, pattern, flags, allocator)` | Collect matching paths below `root` | Yes | `delete_paths` |
| `walker_init(w, root, options, allocator)` | Start a directory walk | Yes | `walker_destroy` |
| `walker_next(w)` | Yield the next entry | Yes | `walker_destroy` |
| `walker_skip_dir(w)`, `walker_error(w)` | Prune a directory, read the error that ended a walk | No | Not needed |
| `ignore_init(m, allocator)` | Prepare a gitignore matcher | Yes | `ignore_destroy` |
| `ignore_add_pattern`, `ignore_add_string`, `ignore_add_file` | Add rules from a line, a string or a file | Yes | `ignore_destroy` |
| `ignore_match`, `ignore_is_ignored` | Evaluate the rules for a path | No | Not needed |
| `Error` | Union of `Pattern_Error`, `os.Error` and `runtime.Allocator_Error` | No | Not needed |

## Examples

Each directory under `examples/` is a runnable program:

```sh
odin run examples/basic
odin run examples/find -- '**/*.odin' .
```

## Design notes

- Every allocating procedure takes `allocator := context.allocator` and says who owns the result.
- Fallible procedures return `(T, Error)`. The library never panics on bad input.
- Matching uses backtracking without allocating. A compiled `Pattern` is read-only, so several threads may share one.
- The package keeps no global mutable state. `Walker` and `Ignore` values are safe to use from one thread at a time.

## Testing

```sh
odin check . -vet -strict-style -disallow-do -no-entry-point
odin test tests -vet -strict-style -disallow-do
vale sync && vale *.md
```

Tests that allocate wrap the allocator in a `mem.Tracking_Allocator` and fail on any leak or bad free.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md). Commits follow Conventional Commits, and every change that users can see gets a line in [CHANGELOG.md](CHANGELOG.md).

## License

MIT. See [LICENSE](LICENSE).
