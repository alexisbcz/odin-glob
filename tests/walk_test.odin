package glob_tests

import glob ".."
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

SAMPLE_TREE :: []string {
	"README.md=hello",
	"src/main.odin=package main",
	"src/net/http.odin=package net",
	"src/net/http_test.c=",
	"src/util.c=",
	"docs/guide.md=",
	"empty/",
}

// collect walks `root` with `options` and returns every yielded path.
collect :: proc(t: ^testing.T, root: string, options: glob.Walk_Options, loc := #caller_location) -> [dynamic]string {
	out: [dynamic]string
	w: glob.Walker
	defer glob.walker_destroy(&w)
	err := glob.walker_init(&w, root, options)
	testing.expect_value(t, err, nil, loc = loc)
	for entry in glob.walker_next(&w) {
		append(&out, strings.clone(entry.path))
	}
	_, werr := glob.walker_error(&w)
	testing.expect_value(t, werr, nil, loc = loc)
	return out
}

delete_collected :: proc(paths: [dynamic]string) {
	for p in paths {
		delete(p)
	}
	delete(paths)
}

@(test)
test_find_matches_files_at_any_depth :: proc(t: ^testing.T) {
	root := make_tree(t, SAMPLE_TREE)
	defer remove_tree(root)

	track: mem.Tracking_Allocator
	context.allocator = leak_check_begin(&track)
	defer leak_check_end(t, &track)

	paths, err := glob.find(root, "**/*.odin")
	testing.expect_value(t, err, nil)
	defer glob.delete_paths(paths)
	expect_paths(t, paths, {"src/main.odin", "src/net/http.odin"})
}

@(test)
test_find_with_braces_and_classes :: proc(t: ^testing.T) {
	root := make_tree(t, SAMPLE_TREE)
	defer remove_tree(root)

	paths, err := glob.find(root, "{src,docs}/**/*.{c,md}")
	testing.expect_value(t, err, nil)
	defer glob.delete_paths(paths)
	expect_paths(t, paths, {"docs/guide.md", "src/net/http_test.c", "src/util.c"})
}

@(test)
test_find_returns_directories_unless_skipped :: proc(t: ^testing.T) {
	root := make_tree(t, SAMPLE_TREE)
	defer remove_tree(root)

	paths, err := glob.find(root, "*")
	testing.expect_value(t, err, nil)
	defer glob.delete_paths(paths)
	expect_paths(t, paths, {"README.md", "docs", "empty", "src"})

	files, ferr := glob.find(root, "*", {.Skip_Dirs})
	testing.expect_value(t, ferr, nil)
	defer glob.delete_paths(files)
	expect_paths(t, files, {"README.md"})
}

@(test)
test_find_no_matches_is_empty_not_error :: proc(t: ^testing.T) {
	root := make_tree(t, SAMPLE_TREE)
	defer remove_tree(root)

	paths, err := glob.find(root, "**/*.zig")
	testing.expect_value(t, err, nil)
	defer glob.delete_paths(paths)
	testing.expect_value(t, len(paths), 0)
}

@(test)
test_find_rejects_bad_pattern :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check_begin(&track)
	defer leak_check_end(t, &track)

	paths, err := glob.find(".", "src/{a,b")
	testing.expect_value(t, err, glob.Error(glob.Pattern_Error.Unclosed_Brace))
	testing.expect(t, paths == nil)
}

@(test)
test_find_reports_missing_root :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check_begin(&track)
	defer leak_check_end(t, &track)

	paths, err := glob.find("/definitely/not/a/real/dir", "**")
	testing.expect(t, paths == nil)
	oerr, is_os := err.(os.Error)
	testing.expect(t, is_os)
	testing.expect_value(t, oerr, os.Error(os.General_Error.Not_Exist))
}

@(test)
test_walker_visits_depth_first_in_name_order :: proc(t: ^testing.T) {
	root := make_tree(t, SAMPLE_TREE)
	defer remove_tree(root)

	track: mem.Tracking_Allocator
	context.allocator = leak_check_begin(&track)
	defer leak_check_end(t, &track)

	paths := collect(t, root, {})
	defer delete_collected(paths)
	expect_paths(t, paths[:], {
		"README.md",
		"docs",
		"docs/guide.md",
		"empty",
		"src",
		"src/main.odin",
		"src/net",
		"src/net/http.odin",
		"src/net/http_test.c",
		"src/util.c",
	})
}

@(test)
test_walker_entry_fields :: proc(t: ^testing.T) {
	root := make_tree(t, SAMPLE_TREE)
	defer remove_tree(root)

	w: glob.Walker
	defer glob.walker_destroy(&w)
	testing.expect_value(t, glob.walker_init(&w, root, {pattern = "src/net/http.odin"}), nil)
	entry, ok := glob.walker_next(&w)
	testing.expect(t, ok)
	testing.expect_value(t, entry.path, "src/net/http.odin")
	testing.expect_value(t, entry.name, "http.odin")
	testing.expect_value(t, entry.type, os.File_Type.Regular)
	testing.expect_value(t, entry.size, 11)
	testing.expect_value(t, entry.depth, 3)
	_, ok = glob.walker_next(&w)
	testing.expect(t, !ok)
}

@(test)
test_walker_skip_files_yields_directories :: proc(t: ^testing.T) {
	root := make_tree(t, SAMPLE_TREE)
	defer remove_tree(root)

	paths := collect(t, root, {flags = {.Skip_Files}})
	defer delete_collected(paths)
	expect_paths(t, paths[:], {"docs", "empty", "src", "src/net"})
}

@(test)
test_walker_skip_dir_prunes_subtree :: proc(t: ^testing.T) {
	root := make_tree(t, SAMPLE_TREE)
	defer remove_tree(root)

	track: mem.Tracking_Allocator
	context.allocator = leak_check_begin(&track)
	defer leak_check_end(t, &track)

	out: [dynamic]string
	defer delete_collected(out)
	w: glob.Walker
	defer glob.walker_destroy(&w)
	testing.expect_value(t, glob.walker_init(&w, root), nil)
	for entry in glob.walker_next(&w) {
		if entry.name == "src" {
			glob.walker_skip_dir(&w)
		}
		append(&out, strings.clone(entry.path))
	}
	expect_paths(t, out[:], {"README.md", "docs", "docs/guide.md", "empty", "src"})
}

@(test)
test_walker_max_depth :: proc(t: ^testing.T) {
	root := make_tree(t, SAMPLE_TREE)
	defer remove_tree(root)

	one := collect(t, root, {max_depth = 1})
	defer delete_collected(one)
	expect_paths(t, one[:], {"README.md", "docs", "empty", "src"})

	two := collect(t, root, {max_depth = 2, flags = {.Skip_Dirs}})
	defer delete_collected(two)
	expect_paths(t, two[:], {"README.md", "docs/guide.md", "src/main.odin", "src/util.c"})
}

@(test)
test_walker_ignore_case :: proc(t: ^testing.T) {
	root := make_tree(t, SAMPLE_TREE)
	defer remove_tree(root)

	paths := collect(t, root, {pattern = "readme.MD", pattern_options = {.Ignore_Case}})
	defer delete_collected(paths)
	expect_paths(t, paths[:], {"README.md"})
}

@(test)
test_walker_respects_nested_gitignore :: proc(t: ^testing.T) {
	root := make_tree(t, {
		".gitignore=*.log\nbuild/\n",
		".git/HEAD=ref",
		"app.log=",
		"main.c=",
		"build/out.o=",
		"lib/.gitignore=!keep.log\n/gen\n",
		"lib/keep.log=",
		"lib/drop.log=x",
		"lib/gen/x.c=",
		"lib/sub/gen/y.c=",
		"other/keep.log=",
	})
	defer remove_tree(root)

	track: mem.Tracking_Allocator
	context.allocator = leak_check_begin(&track)
	defer leak_check_end(t, &track)

	paths := collect(t, root, {flags = {.Gitignore, .Skip_Dirs}})
	defer delete_collected(paths)
	expect_paths(t, paths[:], {
		".gitignore",
		"lib/.gitignore",
		"lib/keep.log",
		"lib/sub/gen/y.c",
		"main.c",
	})
}

@(test)
test_walker_ignore_patterns_without_gitignore_flag :: proc(t: ^testing.T) {
	root := make_tree(t, SAMPLE_TREE)
	defer remove_tree(root)

	extra := []string{"src/", "*.md", "!docs/*.md"}
	paths := collect(t, root, {ignore_patterns = extra, flags = {.Skip_Dirs}})
	defer delete_collected(paths)
	expect_paths(t, paths[:], {"docs/guide.md"})
}

@(test)
test_walker_gitignore_overrides_ignore_patterns :: proc(t: ^testing.T) {
	root := make_tree(t, {".gitignore=!*.tmp\n", "a.tmp=", "b.txt="})
	defer remove_tree(root)

	extra := []string{"*.tmp"}
	paths := collect(t, root, {ignore_patterns = extra, flags = {.Gitignore, .Skip_Dirs}})
	defer delete_collected(paths)
	expect_paths(t, paths[:], {".gitignore", "a.tmp", "b.txt"})
}

@(test)
test_walker_init_rejects_bad_ignore_pattern :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check_begin(&track)
	defer leak_check_end(t, &track)

	w: glob.Walker
	defer glob.walker_destroy(&w)
	extra := []string{"[oops"}
	err := glob.walker_init(&w, ".", {ignore_patterns = extra})
	testing.expect_value(t, err, glob.Error(glob.Pattern_Error.Unclosed_Class))
	_, ok := glob.walker_next(&w)
	testing.expect(t, !ok)
}

@(test)
test_walker_error_names_failing_path :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	context.allocator = leak_check_begin(&track)
	defer leak_check_end(t, &track)

	w: glob.Walker
	defer glob.walker_destroy(&w)
	err := glob.walker_init(&w, "/definitely/not/a/real/dir")
	testing.expect(t, err != nil)
	_, ok := glob.walker_next(&w)
	testing.expect(t, !ok)
	path, werr := glob.walker_error(&w)
	testing.expect_value(t, path, "")
	testing.expect_value(t, werr, err)
}

@(test)
test_walker_destroy_zero_value_is_safe :: proc(t: ^testing.T) {
	w: glob.Walker
	glob.walker_destroy(&w)
	_, ok := glob.walker_next(&w)
	testing.expect(t, !ok)
}

@(test)
test_walker_skip_unreadable_dirs :: proc(t: ^testing.T) {
	root := make_tree(t, {"a/x.odin=", "locked/y.odin=", "z.odin="})
	defer remove_tree(root)
	locked := strings.concatenate({root, "/locked"})
	defer delete(locked)
	if os.chmod(locked, {}) != nil {
		return
	}
	defer _ = os.chmod(locked, {.Read_User, .Write_User, .Execute_User})
	if entries, err := os.read_all_directory_by_path(locked, context.allocator); err == nil {
		// Running as root: permissions don't apply, so there is nothing to test.
		os.file_info_slice_delete(entries, context.allocator)
		return
	}

	track: mem.Tracking_Allocator
	context.allocator = leak_check_begin(&track)
	defer leak_check_end(t, &track)

	_, strict := glob.find(root, "**/*.odin")
	testing.expect(t, strict != nil, "an unreadable directory should fail the walk by default")

	paths, err := glob.find(root, "**/*.odin", {.Skip_Unreadable})
	testing.expect_value(t, err, nil)
	defer glob.delete_paths(paths)
	expect_paths(t, paths, {"a/x.odin", "z.odin"})
}
