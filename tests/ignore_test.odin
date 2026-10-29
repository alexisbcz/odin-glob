package glob_tests

import glob ".."
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

// ignore_from builds a matcher from root-level gitignore text.
ignore_from :: proc(t: ^testing.T, text: string, loc := #caller_location) -> (m: glob.Ignore) {
	glob.ignore_init(&m)
	skipped, err := glob.ignore_add_string(&m, text)
	testing.expect_value(t, err, nil, loc = loc)
	testing.expect_value(t, skipped, 0, loc = loc)
	return m
}

@(test)
test_ignore_unanchored_name_matches_at_any_depth :: proc(t: ^testing.T) {
	m := ignore_from(t, "*.o\n")
	defer glob.ignore_destroy(&m)
	testing.expect(t, glob.ignore_is_ignored(&m, "main.o", false))
	testing.expect(t, glob.ignore_is_ignored(&m, "a/b/main.o", false))
	testing.expect(t, !glob.ignore_is_ignored(&m, "main.c", false))
}

@(test)
test_ignore_leading_slash_anchors_to_root :: proc(t: ^testing.T) {
	m := ignore_from(t, "/build\n")
	defer glob.ignore_destroy(&m)
	testing.expect(t, glob.ignore_is_ignored(&m, "build", true))
	testing.expect(t, !glob.ignore_is_ignored(&m, "src/build", true))
}

@(test)
test_ignore_middle_slash_anchors_to_root :: proc(t: ^testing.T) {
	m := ignore_from(t, "doc/frotz\n")
	defer glob.ignore_destroy(&m)
	testing.expect(t, glob.ignore_is_ignored(&m, "doc/frotz", false))
	testing.expect(t, !glob.ignore_is_ignored(&m, "a/doc/frotz", false))
}

@(test)
test_ignore_trailing_slash_matches_directories_only :: proc(t: ^testing.T) {
	m := ignore_from(t, "logs/\n")
	defer glob.ignore_destroy(&m)
	testing.expect(t, glob.ignore_is_ignored(&m, "logs", true))
	testing.expect(t, glob.ignore_is_ignored(&m, "app/logs", true))
	testing.expect(t, !glob.ignore_is_ignored(&m, "logs", false))
	// Files inside an ignored directory are ignored through their parent.
	testing.expect(t, glob.ignore_is_ignored(&m, "logs/today.txt", false))
	testing.expect_value(t, glob.ignore_match(&m, "logs/today.txt", false), glob.Ignore_Result.None)
}

@(test)
test_ignore_negation_includes_again :: proc(t: ^testing.T) {
	m := ignore_from(t, "*.log\n!keep.log\n")
	defer glob.ignore_destroy(&m)
	testing.expect(t, glob.ignore_is_ignored(&m, "debug.log", false))
	testing.expect(t, !glob.ignore_is_ignored(&m, "keep.log", false))
	testing.expect_value(t, glob.ignore_match(&m, "keep.log", false), glob.Ignore_Result.Included)
	testing.expect_value(t, glob.ignore_match(&m, "main.c", false), glob.Ignore_Result.None)
}

@(test)
test_ignore_last_matching_rule_wins :: proc(t: ^testing.T) {
	m := ignore_from(t, "!keep.log\n*.log\n")
	defer glob.ignore_destroy(&m)
	testing.expect(t, glob.ignore_is_ignored(&m, "keep.log", false))
}

@(test)
test_ignore_cannot_include_below_ignored_parent :: proc(t: ^testing.T) {
	m := ignore_from(t, "build/\n!build/keep.txt\n")
	defer glob.ignore_destroy(&m)
	testing.expect(t, glob.ignore_is_ignored(&m, "build/keep.txt", false))
	testing.expect_value(t, glob.ignore_match(&m, "build/keep.txt", false), glob.Ignore_Result.Included)
}

@(test)
test_ignore_everything_except_one_directory :: proc(t: ^testing.T) {
	m := ignore_from(t, "/*\n!/src\n")
	defer glob.ignore_destroy(&m)
	testing.expect(t, glob.ignore_is_ignored(&m, "README.md", false))
	testing.expect(t, glob.ignore_is_ignored(&m, "docs/a.md", false))
	testing.expect(t, !glob.ignore_is_ignored(&m, "src", true))
	testing.expect(t, !glob.ignore_is_ignored(&m, "src/main.c", false))
}

@(test)
test_ignore_trailing_globstar_excludes_directory_itself :: proc(t: ^testing.T) {
	m := ignore_from(t, "vendor/**\n!vendor/keep.txt\n")
	defer glob.ignore_destroy(&m)
	testing.expect(t, !glob.ignore_is_ignored(&m, "vendor", true))
	testing.expect(t, glob.ignore_is_ignored(&m, "vendor/a/b.c", false))
	testing.expect(t, !glob.ignore_is_ignored(&m, "vendor/keep.txt", false))
}

@(test)
test_ignore_leading_and_middle_globstar :: proc(t: ^testing.T) {
	m := ignore_from(t, "**/tmp\na/**/z\n")
	defer glob.ignore_destroy(&m)
	testing.expect(t, glob.ignore_is_ignored(&m, "tmp", true))
	testing.expect(t, glob.ignore_is_ignored(&m, "x/y/tmp", true))
	testing.expect(t, glob.ignore_is_ignored(&m, "a/z", false))
	testing.expect(t, glob.ignore_is_ignored(&m, "a/b/c/z", false))
	testing.expect(t, !glob.ignore_is_ignored(&m, "b/a/z", false))
}

@(test)
test_ignore_comments_blank_lines_and_escapes :: proc(t: ^testing.T) {
	m := ignore_from(t, "# a comment\n\n   \n\\#hash\n\\!bang\n")
	defer glob.ignore_destroy(&m)
	testing.expect_value(t, len(m.rules), 2)
	testing.expect(t, glob.ignore_is_ignored(&m, "#hash", false))
	testing.expect(t, glob.ignore_is_ignored(&m, "!bang", false))
	testing.expect(t, !glob.ignore_is_ignored(&m, "# a comment", false))
}

@(test)
test_ignore_trailing_spaces :: proc(t: ^testing.T) {
	m := ignore_from(t, "trim.txt   \nkeep\\ \n")
	defer glob.ignore_destroy(&m)
	testing.expect(t, glob.ignore_is_ignored(&m, "trim.txt", false))
	testing.expect(t, glob.ignore_is_ignored(&m, "keep ", false))
	testing.expect(t, !glob.ignore_is_ignored(&m, "keep", false))
}

@(test)
test_ignore_crlf_line_endings :: proc(t: ^testing.T) {
	m := ignore_from(t, "*.tmp\r\n!a.tmp\r\n")
	defer glob.ignore_destroy(&m)
	testing.expect(t, glob.ignore_is_ignored(&m, "b.tmp", false))
	testing.expect(t, !glob.ignore_is_ignored(&m, "a.tmp", false))
}

@(test)
test_ignore_braces_are_literal :: proc(t: ^testing.T) {
	m := ignore_from(t, "{a,b}.txt\n")
	defer glob.ignore_destroy(&m)
	testing.expect(t, glob.ignore_is_ignored(&m, "{a,b}.txt", false))
	testing.expect(t, !glob.ignore_is_ignored(&m, "a.txt", false))
}

@(test)
test_ignore_nested_file_takes_precedence :: proc(t: ^testing.T) {
	m := ignore_from(t, "*.txt\n")
	defer glob.ignore_destroy(&m)
	_, err := glob.ignore_add_string(&m, "!*.txt\n", "sub")
	testing.expect_value(t, err, nil)
	testing.expect(t, !glob.ignore_is_ignored(&m, "sub/a.txt", false))
	testing.expect(t, !glob.ignore_is_ignored(&m, "sub/deeper/a.txt", false))
	testing.expect(t, glob.ignore_is_ignored(&m, "other/a.txt", false))
	testing.expect(t, glob.ignore_is_ignored(&m, "a.txt", false))
}

@(test)
test_ignore_nested_rules_stay_inside_their_directory :: proc(t: ^testing.T) {
	m: glob.Ignore
	glob.ignore_init(&m)
	defer glob.ignore_destroy(&m)
	testing.expect_value(t, glob.ignore_add_pattern(&m, "/out", "pkg/"), nil)
	testing.expect_value(t, m.rules[0].base, "pkg")
	testing.expect(t, glob.ignore_is_ignored(&m, "pkg/out", true))
	testing.expect(t, !glob.ignore_is_ignored(&m, "pkg/x/out", true))
	testing.expect(t, !glob.ignore_is_ignored(&m, "pkgx/out", true))
	testing.expect(t, !glob.ignore_is_ignored(&m, "out", true))
}

@(test)
test_ignore_add_pattern_rejects_malformed_line :: proc(t: ^testing.T) {
	m: glob.Ignore
	glob.ignore_init(&m)
	defer glob.ignore_destroy(&m)
	testing.expect_value(t, glob.ignore_add_pattern(&m, "[abc"), glob.Error(glob.Pattern_Error.Unclosed_Class))
	testing.expect_value(t, glob.ignore_add_pattern(&m, `trailing\`), glob.Error(glob.Pattern_Error.Trailing_Escape))
	testing.expect_value(t, len(m.rules), 0)
}

@(test)
test_ignore_add_string_skips_malformed_lines :: proc(t: ^testing.T) {
	m: glob.Ignore
	glob.ignore_init(&m)
	defer glob.ignore_destroy(&m)
	skipped, err := glob.ignore_add_string(&m, "good\n[bad\nalso[z-a]bad\nfine/\n")
	testing.expect_value(t, err, nil)
	testing.expect_value(t, skipped, 2)
	testing.expect_value(t, len(m.rules), 2)
	testing.expect(t, m.rules[1].dir_only)
}

@(test)
test_ignore_bare_negation_and_slash_add_nothing :: proc(t: ^testing.T) {
	m := ignore_from(t, "!\n/\n!/\n")
	defer glob.ignore_destroy(&m)
	testing.expect_value(t, len(m.rules), 0)
}

@(test)
test_ignore_add_file_reports_missing_file :: proc(t: ^testing.T) {
	m: glob.Ignore
	glob.ignore_init(&m)
	defer glob.ignore_destroy(&m)
	_, err := glob.ignore_add_file(&m, "/definitely/not/here/.gitignore")
	oerr, is_os := err.(os.Error)
	testing.expect(t, is_os)
	testing.expect_value(t, oerr, os.Error(os.General_Error.Not_Exist))
}

@(test)
test_ignore_add_file_reads_rules :: proc(t: ^testing.T) {
	root := make_tree(t, {".gitignore=*.bak\n!important.bak\n"})
	defer remove_tree(root)

	track: mem.Tracking_Allocator
	context.allocator = leak_check_begin(&track)
	defer leak_check_end(t, &track)

	m: glob.Ignore
	glob.ignore_init(&m)
	defer glob.ignore_destroy(&m)
	file, _ := strings.concatenate({root, "/.gitignore"})
	defer delete(file)
	skipped, err := glob.ignore_add_file(&m, file)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, skipped, 0)
	testing.expect(t, glob.ignore_is_ignored(&m, "x.bak", false))
	testing.expect(t, !glob.ignore_is_ignored(&m, "important.bak", false))
}

@(test)
test_ignore_destroy_frees_everything :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check_begin(&track)
	defer leak_check_end(t, &track)

	m: glob.Ignore
	glob.ignore_init(&m)
	_, _ = glob.ignore_add_string(&m, "*.o\n!keep.o\nbuild/\n/docs/**\n[bad\n", "a/b")
	testing.expect_value(t, len(m.rules), 4)
	glob.ignore_destroy(&m)
	testing.expect_value(t, len(m.rules), 0)
}

// Git skips a UTF-8 byte order mark at the start of a .gitignore file.
@(test)
test_gitignore_skips_utf8_bom :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check_begin(&track)
	defer leak_check_end(t, &track)

	m: glob.Ignore
	glob.ignore_init(&m)
	defer glob.ignore_destroy(&m)
	skipped, err := glob.ignore_add_string(&m, "\xef\xbb\xbfbuild\n*.o\n")
	testing.expect_value(t, err, nil)
	testing.expect_value(t, skipped, 0)
	testing.expect(t, glob.ignore_is_ignored(&m, "build", true))
	testing.expect(t, glob.ignore_is_ignored(&m, "x.o", false))
}
