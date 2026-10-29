// Package glob_tests holds the unit tests for glob. Run them with `odin test tests`.
package glob_tests

import glob ".."
import "base:runtime"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

// leak_check_begin wraps the current allocator in a tracking allocator.
leak_check_begin :: proc(track: ^mem.Tracking_Allocator) -> runtime.Allocator {
	mem.tracking_allocator_init(track, context.allocator)
	return mem.tracking_allocator(track)
}

// leak_check_end fails the test if anything allocated through `track` is still live.
leak_check_end :: proc(t: ^testing.T, track: ^mem.Tracking_Allocator, loc := #caller_location) {
	testing.expectf(t, len(track.allocation_map) == 0, "%d allocation(s) leaked", len(track.allocation_map), loc = loc)
	for _, entry in track.allocation_map {
		log.errorf("leak: %d bytes at %v", entry.size, entry.location)
	}
	testing.expectf(t, len(track.bad_free_array) == 0, "%d bad free(s)", len(track.bad_free_array), loc = loc)
	mem.tracking_allocator_destroy(track)
}

// expect_match asserts that `pattern` compiles and matches `path` as `want` says.
expect_match :: proc(t: ^testing.T, pattern, path: string, want: bool, options: glob.Options = {}, loc := #caller_location) {
	got, err := glob.match(pattern, path, options)
	testing.expectf(t, err == nil, "match(%q) failed: %v", pattern, err, loc = loc)
	testing.expectf(t, got == want, "match(%q, %q) = %v, want %v", pattern, path, got, want, loc = loc)
}

// expect_pattern_error asserts that compiling `pattern` fails with `want` at `offset`.
expect_pattern_error :: proc(t: ^testing.T, pattern: string, want: glob.Pattern_Error, offset: int, loc := #caller_location) {
	err, at := glob.validate(pattern)
	testing.expectf(t, err == glob.Error(want), "validate(%q) = %v, want %v", pattern, err, want, loc = loc)
	testing.expectf(t, at == offset, "validate(%q) offset = %d, want %d", pattern, at, offset, loc = loc)
}

// expect_paths asserts that two path lists are equal, element by element.
expect_paths :: proc(t: ^testing.T, got, want: []string, loc := #caller_location) {
	if len(got) != len(want) {
		testing.expectf(t, false, "got %d paths %v, want %d paths %v", len(got), got, len(want), want, loc = loc)
		return
	}
	for i in 0 ..< len(got) {
		testing.expectf(t, got[i] == want[i], "path %d = %q, want %q", i, got[i], want[i], loc = loc)
	}
}

/*
make_tree creates a temporary directory holding `entries`. An entry that ends
in `/` is a directory. Any other entry is a file; text after `=` becomes its
contents. Remove the tree with remove_tree.
*/
make_tree :: proc(t: ^testing.T, entries: []string, loc := #caller_location) -> (root: string) {
	err: os.Error
	root, err = os.make_directory_temp("", "odin-glob-*", context.allocator)
	testing.expect_value(t, err, nil, loc = loc)
	for entry in entries {
		name, _, contents := strings.partition(entry, "=")
		full := strings.concatenate({root, "/", name})
		defer delete(full)
		if strings.has_suffix(name, "/") {
			testing.expect_value(t, os.make_directory_all(full), nil, loc = loc)
			continue
		}
		dir, _ := os.split_path(full)
		_ = os.make_directory_all(dir)
		testing.expect_value(t, os.write_entire_file(full, contents), nil, loc = loc)
	}
	return root
}

// remove_tree deletes a tree made by make_tree and frees its path.
remove_tree :: proc(root: string) {
	_ = os.remove_all(root)
	delete(root)
}
