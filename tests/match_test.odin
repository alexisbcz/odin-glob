package glob_tests

import glob ".."
import "core:mem"
import "core:testing"

@(test)
test_literal_matches_whole_path_only :: proc(t: ^testing.T) {
	expect_match(t, "src/main.odin", "src/main.odin", true)
	expect_match(t, "src/main.odin", "src/main.odin.bak", false)
	expect_match(t, "src/main.odin", "x/src/main.odin", false)
	expect_match(t, "", "", true)
	expect_match(t, "", "a", false)
}

@(test)
test_star_stays_within_segment :: proc(t: ^testing.T) {
	expect_match(t, "*.txt", "notes.txt", true)
	expect_match(t, "*.txt", "dir/notes.txt", false)
	expect_match(t, "dir/*", "dir/notes.txt", true)
	expect_match(t, "dir/*", "dir/sub/notes.txt", false)
}

@(test)
test_star_matches_empty_run :: proc(t: ^testing.T) {
	expect_match(t, "a*", "a", true)
	expect_match(t, "*a*", "a", true)
	expect_match(t, "a*b*c", "abc", true)
	expect_match(t, "a*b*c", "axxbyyc", true)
	expect_match(t, "a*b*c", "axxbyy", false)
}

@(test)
test_star_matches_dotfiles :: proc(t: ^testing.T) {
	expect_match(t, "*", ".bashrc", true)
	expect_match(t, "*rc", ".bashrc", true)
}

@(test)
test_question_matches_one_char :: proc(t: ^testing.T) {
	expect_match(t, "?.c", "a.c", true)
	expect_match(t, "?.c", "ab.c", false)
	expect_match(t, "?.c", ".c", false)
	expect_match(t, "a?b", "a/b", false)
}

@(test)
test_question_matches_multibyte_rune :: proc(t: ^testing.T) {
	expect_match(t, "caf?", "café", true)
	expect_match(t, "??", "日本", true)
	expect_match(t, "?", "日本", false)
}

@(test)
test_class_set_and_range :: proc(t: ^testing.T) {
	expect_match(t, "file[123].txt", "file2.txt", true)
	expect_match(t, "file[123].txt", "file4.txt", false)
	expect_match(t, "[a-c]x", "bx", true)
	expect_match(t, "[a-c]x", "dx", false)
	expect_match(t, "[a-cx-z]", "y", true)
}

@(test)
test_class_negation_with_bang_and_caret :: proc(t: ^testing.T) {
	expect_match(t, "[!a]", "b", true)
	expect_match(t, "[!a]", "a", false)
	expect_match(t, "[^a-z]", "Q", true)
	expect_match(t, "[^a-z]", "q", false)
}

@(test)
test_class_bracket_and_dash_literals :: proc(t: ^testing.T) {
	expect_match(t, "[]]", "]", true)
	expect_match(t, "[!]]", "]", false)
	expect_match(t, "[!]]", "x", true)
	expect_match(t, "[a-]", "-", true)
	expect_match(t, "[-a]", "-", true)
	expect_match(t, `[\]a]`, "]", true)
	expect_match(t, `[\-]`, "-", true)
}

@(test)
test_class_never_matches_separator :: proc(t: ^testing.T) {
	expect_match(t, "a[!x]b", "a/b", false)
	expect_match(t, "a[%-0]b", "a/b", false)
}

@(test)
test_class_with_unicode_range :: proc(t: ^testing.T) {
	expect_match(t, "[α-ω]", "λ", true)
	expect_match(t, "[α-ω]", "a", false)
}

@(test)
test_named_classes :: proc(t: ^testing.T) {
	expect_match(t, "v[[:digit:]]", "v7", true)
	expect_match(t, "v[[:digit:]]", "vx", false)
	expect_match(t, "[[:upper:]][[:lower:]]", "Ab", true)
	expect_match(t, "[[:alpha:][:digit:]_]*", "_x1", true)
	expect_match(t, "[[:space:]]", " ", true)
	expect_match(t, "[[:xdigit:]]", "F", true)
	expect_match(t, "[[:xdigit:]]", "g", false)
	expect_match(t, "[![:punct:]]", "!", false)
}

@(test)
test_globstar_alone_matches_everything :: proc(t: ^testing.T) {
	expect_match(t, "**", "", true)
	expect_match(t, "**", "a", true)
	expect_match(t, "**", "a/b/c.txt", true)
}

@(test)
test_globstar_prefix_matches_any_depth :: proc(t: ^testing.T) {
	expect_match(t, "**/main.odin", "main.odin", true)
	expect_match(t, "**/main.odin", "a/b/main.odin", true)
	expect_match(t, "**/main.odin", "a/b/xmain.odin", false)
	expect_match(t, "**/*.odin", "a/b/c.odin", true)
}

@(test)
test_globstar_in_middle_matches_zero_or_more_segments :: proc(t: ^testing.T) {
	expect_match(t, "a/**/b", "a/b", true)
	expect_match(t, "a/**/b", "a/x/b", true)
	expect_match(t, "a/**/b", "a/x/y/b", true)
	expect_match(t, "a/**/b", "ab", false)
	expect_match(t, "a/**/b", "a/xb", false)
}

@(test)
test_globstar_suffix_matches_directory_and_below :: proc(t: ^testing.T) {
	expect_match(t, "src/**", "src", true)
	expect_match(t, "src/**", "src/a", true)
	expect_match(t, "src/**", "src/a/b", true)
	expect_match(t, "src/**", "srcx", false)
	expect_match(t, "src/**", "lib/a", false)
}

@(test)
test_double_star_inside_segment_acts_like_star :: proc(t: ^testing.T) {
	expect_match(t, "a**", "abc", true)
	expect_match(t, "a**", "a/b", false)
	expect_match(t, "**b", "ab", true)
	expect_match(t, "x/a**b/y", "x/acb/y", true)
}

@(test)
test_brace_alternation :: proc(t: ^testing.T) {
	expect_match(t, "*.{png,jpg}", "cat.png", true)
	expect_match(t, "*.{png,jpg}", "cat.jpg", true)
	expect_match(t, "*.{png,jpg}", "cat.gif", false)
	expect_match(t, "{a,b}{c,d}", "bd", true)
}

@(test)
test_brace_nested_and_empty_alternatives :: proc(t: ^testing.T) {
	expect_match(t, "{a,{b,c}d}", "cd", true)
	expect_match(t, "{a,{b,c}d}", "c", false)
	expect_match(t, "lib{,s}", "lib", true)
	expect_match(t, "lib{,s}", "libs", true)
	expect_match(t, "x{}", "x", true)
}

@(test)
test_brace_alternatives_cross_segments :: proc(t: ^testing.T) {
	expect_match(t, "{src,lib/core}/**/*.odin", "lib/core/a/x.odin", true)
	expect_match(t, "{src,lib/core}/**/*.odin", "src/x.odin", true)
	expect_match(t, "{src,lib/core}/**/*.odin", "lib/x.odin", false)
	expect_match(t, "{**/test,docs}/*.md", "a/b/test/x.md", true)
}

@(test)
test_brace_backtracks_into_rest :: proc(t: ^testing.T) {
	// The first alternative matches a prefix but leaves a remainder that fails.
	expect_match(t, "{a,ab}c", "abc", true)
	expect_match(t, "{*,x}y", "xxy", true)
}

@(test)
test_stray_close_brace_and_comma_are_literal :: proc(t: ^testing.T) {
	expect_match(t, "a}b", "a}b", true)
	expect_match(t, "a,b", "a,b", true)
}

@(test)
test_escapes_make_meta_literal :: proc(t: ^testing.T) {
	expect_match(t, `\*`, "*", true)
	expect_match(t, `\*`, "a", false)
	expect_match(t, `a\?`, "a?", true)
	expect_match(t, `\[x]`, "[x]", true)
	expect_match(t, `\{a,b}`, "{a,b}", true)
	expect_match(t, `a\\b`, `a\b`, true)
	expect_match(t, `caf\é`, "café", true)
}

@(test)
test_ignore_case_option :: proc(t: ^testing.T) {
	expect_match(t, "README.md", "readme.MD", true, {.Ignore_Case})
	expect_match(t, "README.md", "readme.MD", false)
	expect_match(t, "[a-c].TXT", "B.txt", true, {.Ignore_Case})
	expect_match(t, "ÉTÉ", "été", true, {.Ignore_Case})
}

@(test)
test_error_unclosed_class :: proc(t: ^testing.T) {
	expect_pattern_error(t, "a[bc", .Unclosed_Class, 1)
	expect_pattern_error(t, "[]", .Unclosed_Class, 0)
	expect_pattern_error(t, "[!", .Unclosed_Class, 0)
	expect_pattern_error(t, `[a\`, .Unclosed_Class, 2)
}

@(test)
test_error_unclosed_brace :: proc(t: ^testing.T) {
	expect_pattern_error(t, "x{a,b", .Unclosed_Brace, 1)
	expect_pattern_error(t, "{a,{b}", .Unclosed_Brace, 0)
}

@(test)
test_error_trailing_escape :: proc(t: ^testing.T) {
	expect_pattern_error(t, `abc\`, .Trailing_Escape, 3)
	expect_pattern_error(t, `{a,\`, .Trailing_Escape, 3)
}

@(test)
test_error_invalid_range :: proc(t: ^testing.T) {
	expect_pattern_error(t, "[z-a]", .Invalid_Range, 2)
}

@(test)
test_error_unknown_class_name :: proc(t: ^testing.T) {
	expect_pattern_error(t, "[[:nope:]]", .Unknown_Class_Name, 1)
}

@(test)
test_error_nesting_too_deep :: proc(t: ^testing.T) {
	deep: [2 * (glob.MAX_BRACE_DEPTH + 1)]byte
	for i in 0 ..< glob.MAX_BRACE_DEPTH + 1 {
		deep[i] = '{'
		deep[len(deep) - 1 - i] = '}'
	}
	expect_pattern_error(t, string(deep[:]), .Nesting_Too_Deep, glob.MAX_BRACE_DEPTH)

	ok: [2 * glob.MAX_BRACE_DEPTH]byte
	for i in 0 ..< glob.MAX_BRACE_DEPTH {
		ok[i] = '{'
		ok[len(ok) - 1 - i] = '}'
	}
	err, _ := glob.validate(string(ok[:]))
	testing.expect_value(t, err, nil)
}

@(test)
test_validate_accepts_good_pattern :: proc(t: ^testing.T) {
	err, offset := glob.validate("src/**/*.{odin,c}")
	testing.expect_value(t, err, nil)
	testing.expect_value(t, offset, 0)
}

@(test)
test_match_returns_error_for_bad_pattern :: proc(t: ^testing.T) {
	ok, err := glob.match("[abc", "a")
	testing.expect_value(t, ok, false)
	testing.expect_value(t, err, glob.Error(glob.Pattern_Error.Unclosed_Class))
}

@(test)
test_compile_and_reuse_without_leaks :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check_begin(&track)
	defer leak_check_end(t, &track)

	p, err := glob.compile("{src,lib}/**/[a-z]*.{odin,c}")
	testing.expect_value(t, err, nil)
	defer glob.pattern_destroy(&p)

	testing.expect_value(t, p.source, "{src,lib}/**/[a-z]*.{odin,c}")
	testing.expect(t, glob.pattern_match(&p, "src/net/http.odin"))
	testing.expect(t, glob.pattern_match(&p, "lib/x.c"))
	testing.expect(t, !glob.pattern_match(&p, "lib/X.c"))
	testing.expect(t, !glob.pattern_match(&p, "test/x.c"))
}

@(test)
test_compile_errors_do_not_leak :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check_begin(&track)
	defer leak_check_end(t, &track)

	bad := []string{"a{b,[c", "{a,b}{c", "x[z-a]", `{a,{b,c\`, "lit*{a,b}[[:bad:]]"}
	for pattern in bad {
		p, err := glob.compile(pattern)
		testing.expectf(t, err != nil, "compile(%q) should fail", pattern)
		glob.pattern_destroy(&p)
	}
}

@(test)
test_pattern_destroy_zero_value_is_safe :: proc(t: ^testing.T) {
	p: glob.Pattern
	glob.pattern_destroy(&p)
	glob.pattern_destroy(&p)
	testing.expect_value(t, p.source, "")
}

@(test)
test_escape_round_trips :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check_begin(&track)
	defer leak_check_end(t, &track)

	name := `weird [file] {v1,v2} *?\.txt`
	escaped, err := glob.escape(name)
	testing.expect_value(t, err, nil)
	defer delete(escaped)
	testing.expect_value(t, escaped, `weird \[file\] \{v1\,v2\} \*\?\\.txt`)
	expect_match(t, escaped, name, true)
	expect_match(t, escaped, "weird f", false)
}

@(test)
test_has_meta :: proc(t: ^testing.T) {
	testing.expect(t, glob.has_meta("*.c"))
	testing.expect(t, glob.has_meta("a{b"))
	testing.expect(t, glob.has_meta(`a\b`))
	testing.expect(t, !glob.has_meta("plain/path.txt"))
}

@(test)
test_many_stars_still_terminate :: proc(t: ^testing.T) {
	expect_match(t, "*a*a*a*b", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", false)
	expect_match(t, "**/**/**/x", "a/b/c/d/e/f/g/h/i/j/x", true)
}

// `src/{a,**}/x` must mean `src/a/x` or `src/**/x`, and the second matches `src/x`.
@(test)
test_globstar_alternative_matches_zero_segments :: proc(t: ^testing.T) {
	expect_match(t, "src/{a,**}/x", "src/x", true)
	expect_match(t, "src/{a,**}/x", "src/a/x", true)
	expect_match(t, "src/{a,**}/x", "src/p/q/x", true)
	expect_match(t, "src/{a,**}/x", "srcx", false)
	expect_match(t, "src/{a,**}/x", "src/xx", false)
	expect_match(t, "{**}/x", "x", true)
	expect_match(t, "{**}/x", "p/x", true)
	expect_match(t, "{b,{**}}/x", "x", true)
	expect_match(t, "{**}/{x,y}", "y", true)
}
