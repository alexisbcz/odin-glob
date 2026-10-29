package glob

import "base:runtime"
import "core:os"
import "core:strings"

/*
Ignore evaluates gitignore rules against paths.

Rules follow the gitignore format that Git documents:

- Blank lines and lines that start with `#` are skipped. Write `\#` for a literal `#`.
- Trailing spaces are dropped unless a `\` escapes them.
- A leading `!` negates the rule, so a path that an earlier rule ignored is
  included again. Write `\!` for a literal `!`.
- A trailing `/` makes the rule match directories only.
- A rule with a `/` at the start or in the middle is anchored to the directory
  of its `.gitignore`. Any other rule matches at any depth below it.
- `*`, `?`, `[...]` and `**` work as in glob patterns. Braces have no special meaning.

Rules are evaluated in the order they were added and the last matching rule
wins. Add the rules of a parent directory before those of its children, so
that deeper `.gitignore` files take precedence. As in Git, a path stays
ignored when one of its parent directories is ignored; ignore_is_ignored
applies that rule for you.

Create an Ignore with ignore_init and release it with ignore_destroy. A value
is safe to use from one thread at a time. Concurrent calls that only match,
without adding rules, are also safe.
*/
Ignore :: struct {
	// rules holds the compiled rules in the order they were added.
	rules:     [dynamic]Ignore_Rule,
	allocator: runtime.Allocator,
}

// Ignore_Rule is one compiled line of a gitignore file.
Ignore_Rule :: struct {
	// pattern is the compiled pattern, relative to base.
	pattern:  Pattern,
	// base is the directory the rule belongs to, relative to the root. "" means the root.
	base:     string,
	// negated is true for rules that start with `!`.
	negated:  bool,
	// dir_only is true for rules that end with `/`.
	dir_only: bool,
}

// Ignore_Result says what the last matching rule decided about a path.
Ignore_Result :: enum {
	// No rule matched the path.
	None,
	// A rule matched and the path is ignored.
	Ignored,
	// A negated rule matched and the path is included again.
	Included,
}

/*
ignore_init prepares `m` for use. Every rule that `m` stores, including its
copies of patterns and base paths, uses `allocator`. Call ignore_destroy when done.
*/
ignore_init :: proc(m: ^Ignore, allocator := context.allocator) {
	m.allocator = allocator
	m.rules = make([dynamic]Ignore_Rule, allocator)
}

// ignore_destroy frees every rule and the rule list. The matcher is zeroed.
ignore_destroy :: proc(m: ^Ignore) {
	ignore_truncate(m, 0)
	delete(m.rules)
	m^ = {}
}

/*
ignore_add_pattern parses one gitignore line and appends it as a rule.

Inputs:
- m: the matcher.
- line: one line of a gitignore file. Blank lines and comments are accepted and add nothing.
- base: the directory that holds the gitignore file, relative to the root, with
  `/` separators. Use "" for the root.

Returns:
- err: a Pattern_Error when the line is malformed, or an allocator error. On
  error the matcher is unchanged.
*/
ignore_add_pattern :: proc(m: ^Ignore, line: string, base := "") -> Error {
	text := strings.trim_right(line, "\r\n")
	text = trim_unescaped_trailing_spaces(text)
	if text == "" || text[0] == '#' {
		return nil
	}

	rule: Ignore_Rule
	if text[0] == '!' {
		rule.negated = true
		text = text[1:]
	}
	if strings.has_suffix(text, "/") && !strings.has_suffix(text, "\\/") {
		rule.dir_only = true
		text = strings.trim_right(text, "/")
	}
	if text == "" {
		return nil
	}

	anchored := strings.index_byte(text, '/') >= 0
	text = strings.trim_left(text, "/")

	source := text
	if !anchored {
		source = strings.concatenate({"**/", text}, m.allocator) or_return
	}
	defer if !anchored {
		delete(source, m.allocator)
	}

	flags := Compile_Flags{.No_Braces, .Suffix_Excludes_Self}
	pattern, err, _ := compile_internal(source, {}, flags, m.allocator)
	if err != nil {
		return err
	}
	rule.pattern = pattern

	rule.base, err = strings.clone(strings.trim(base, "/"), m.allocator)
	if err != nil {
		pattern_destroy(&rule.pattern)
		return err
	}
	if _, aerr := append(&m.rules, rule); aerr != nil {
		ignore_rule_destroy(m, &rule)
		return aerr
	}
	return nil
}

/*
ignore_add_string parses the whole contents of a gitignore file and appends its rules.

Like Git, it skips lines that are not valid patterns, such as one with an
unclosed `[`, and keeps going. Call ignore_add_pattern line by line if you need
to report them.

Inputs:
- m: the matcher.
- text: the file contents. Both `\n` and `\r\n` line endings work. A UTF-8
  byte order mark at the start is skipped, as Git does.
- base: the directory that holds the file, relative to the root. Use "" for the root.

Returns:
- skipped: how many lines were malformed and left out.
- err: an allocator error. On error the rules added so far stay in place.
*/
ignore_add_string :: proc(m: ^Ignore, text: string, base := "") -> (skipped: int, err: Error) {
	rest := strings.trim_prefix(text, UTF8_BOM)
	for line in strings.split_lines_iterator(&rest) {
		lerr := ignore_add_pattern(m, line, base)
		switch e in lerr {
		case Pattern_Error:
			skipped += 1
		case os.Error, runtime.Allocator_Error:
			return skipped, lerr
		}
	}
	return skipped, nil
}

/*
ignore_add_file reads a gitignore file from disk and appends its rules.

Inputs:
- m: the matcher.
- file_path: where to read the file from, in the operating system's path syntax.
- base: the directory that the rules apply to, relative to the root. Use "" for the root.

Returns:
- skipped: how many lines were malformed and left out.
- err: an `os.Error` such as `.Not_Exist` when the file can't be read, or an allocator error.
*/
ignore_add_file :: proc(m: ^Ignore, file_path: string, base := "") -> (skipped: int, err: Error) {
	data := os.read_entire_file(file_path, m.allocator) or_return
	defer delete(data, m.allocator)
	return ignore_add_string(m, string(data), base)
}

/*
ignore_match returns what the rules decide about `path` on its own, without
looking at its parent directories.

Inputs:
- m: the matcher.
- path: the path relative to the root, with `/` separators and no leading `./`.
- is_dir: whether the path names a directory, which rules ending in `/` need.
*/
ignore_match :: proc(m: ^Ignore, path: string, is_dir: bool) -> Ignore_Result {
	clean := strings.trim(path, "/")
	#reverse for &rule in m.rules {
		if rule.dir_only && !is_dir {
			continue
		}
		rel, ok := relative_to_base(clean, rule.base)
		if !ok {
			continue
		}
		if pattern_match(&rule.pattern, rel) {
			return .Included if rule.negated else .Ignored
		}
	}
	return .None
}

/*
ignore_is_ignored reports whether Git would ignore `path`.

It checks every parent directory of `path` first, because nothing below an
ignored directory can be included again.

Inputs:
- m: the matcher.
- path: the path relative to the root, with `/` separators and no leading `./`.
- is_dir: whether the path names a directory.
*/
ignore_is_ignored :: proc(m: ^Ignore, path: string, is_dir: bool) -> bool {
	clean := strings.trim(path, "/")
	for i in 0 ..< len(clean) {
		if clean[i] == '/' && ignore_match(m, clean[:i], true) == .Ignored {
			return true
		}
	}
	return ignore_match(m, clean, is_dir) == .Ignored
}

@(private)
UTF8_BOM :: "\xef\xbb\xbf"

@(private)
relative_to_base :: proc(path, base: string) -> (rel: string, ok: bool) {
	if base == "" {
		return path, true
	}
	if len(path) > len(base) && strings.has_prefix(path, base) && path[len(base)] == '/' {
		return path[len(base) + 1:], true
	}
	return "", false
}

@(private)
trim_unescaped_trailing_spaces :: proc(s: string) -> string {
	end := len(s)
	for end > 0 && s[end - 1] == ' ' {
		// Count the backslashes in front of this space; an odd count escapes it.
		slashes := 0
		for j := end - 2; j >= 0 && s[j] == '\\'; j -= 1 {
			slashes += 1
		}
		if slashes % 2 == 1 {
			break
		}
		end -= 1
	}
	return s[:end]
}

@(private)
ignore_rule_destroy :: proc(m: ^Ignore, rule: ^Ignore_Rule) {
	pattern_destroy(&rule.pattern)
	delete(rule.base, m.allocator)
	rule^ = {}
}

// ignore_truncate drops every rule after the first `count`.
@(private)
ignore_truncate :: proc(m: ^Ignore, count: int) {
	for i := len(m.rules) - 1; i >= count; i -= 1 {
		ignore_rule_destroy(m, &m.rules[i])
	}
	resize(&m.rules, count)
}
