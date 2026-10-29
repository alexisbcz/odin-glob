package glob

import "base:runtime"
import "core:os"
import "core:slice"
import "core:strings"

// Walk_Flag changes what a Walker visits and yields.
Walk_Flag :: enum {
	// Don't yield files, symbolic links or other entries that are not directories.
	Skip_Files,
	// Don't yield directories. The walker still descends into them.
	Skip_Dirs,
	// Read the `.gitignore` file in every directory and skip what it ignores.
	// The `.git` directory is skipped too.
	Gitignore,
	// Skip directories below the root that can't be read, for example because
	// of their permissions, instead of ending the walk with an error. The
	// directory itself is still yielded. The root must always be readable.
	Skip_Unreadable,
}

// Walk_Flags is a set of Walk_Flag values.
Walk_Flags :: bit_set[Walk_Flag]

// Walk_Options configures a Walker. The zero value visits everything below the root.
Walk_Options :: struct {
	// pattern selects which paths to yield. "" yields every path. The walker
	// doesn't descend into directories that can't contain a match.
	pattern:         string,
	// pattern_options applies to pattern.
	pattern_options: Options,
	// flags changes what the walker visits.
	flags:           Walk_Flags,
	// ignore_patterns holds extra gitignore lines that apply from the root.
	// They work with or without the Gitignore flag, and `.gitignore` files
	// that the walker reads take precedence over them.
	ignore_patterns: []string,
	// max_depth limits how deep the walker goes. 1 visits only the root's own
	// entries. 0 means no limit.
	max_depth:       int,
}

/*
Walk_Entry describes one path that the walker yields.

The strings point into the walker's own buffers and stay valid until the next
call to walker_next. Clone them to keep them longer.
*/
Walk_Entry :: struct {
	// path is relative to the root and uses `/` as its separator.
	path:  string,
	// name is the last element of path.
	name:  string,
	// type is the entry's file type. Symbolic links are reported as `.Symlink` and never followed.
	type:  os.File_Type,
	// size is the length in bytes for regular files.
	size:  i64,
	// depth is 1 for entries directly inside the root, 2 for their children and so on.
	depth: int,
}

// Walker visits a directory tree depth first. Each directory's entries come in
// byte order of their names.
//
// Create one with walker_init, loop with walker_next and release it with
// walker_destroy. A Walker is safe to use from one thread at a time.
//
// Example:
// 	w: glob.Walker
// 	if err := glob.walker_init(&w, ".", {pattern = "**/*.odin"}); err != nil {
// 		return
// 	}
// 	defer glob.walker_destroy(&w)
// 	for entry in glob.walker_next(&w) {
// 		fmt.println(entry.path)
// 	}
// 	if err := glob.walker_error(&w); err != nil {
// 		fmt.eprintln(err)
// 	}
Walker :: struct {
	root:           string,
	options:        Walk_Options,
	pattern:        Pattern,
	has_pattern:    bool,
	ignore:         Ignore,
	use_ignore:     bool,
	stack:          [dynamic]Walk_Frame,
	path:           [dynamic]byte,
	pending_dir:    bool,
	skip_pending:   bool,
	err:            Error,
	err_path:       string,
	allocator:      runtime.Allocator,
}

@(private)
Walk_Frame :: struct {
	entries:    []os.File_Info,
	index:      int,
	prefix_len: int,
	rule_count: int,
}

/*
walker_init prepares `w` to walk the tree below `root`.

Inputs:
- w: the walker to set up.
- root: the directory to walk, in the operating system's path syntax.
- options: what to visit; see Walk_Options.
- allocator: used for every allocation the walker makes.

Returns:
- err: a Pattern_Error for a malformed pattern or ignore line, an `os.Error`
  when `root` can't be read, or an allocator error. Call walker_destroy even
  when walker_init fails.
*/
walker_init :: proc(w: ^Walker, root: string, options: Walk_Options = {}, allocator := context.allocator) -> (err: Error) {
	w^ = {}
	w.allocator = allocator
	defer if err != nil && w.err == nil {
		w.err = err
	}
	w.options = options
	w.options.ignore_patterns = nil
	w.stack = make([dynamic]Walk_Frame, allocator)
	w.path = make([dynamic]byte, allocator)
	ignore_init(&w.ignore, allocator)
	w.root = strings.clone(root if root != "" else ".", allocator) or_return

	if options.pattern != "" {
		w.pattern = compile(options.pattern, options.pattern_options, allocator) or_return
		w.has_pattern = true
	}
	for line in options.ignore_patterns {
		ignore_add_pattern(&w.ignore, line) or_return
	}
	w.use_ignore = .Gitignore in options.flags || len(w.ignore.rules) > 0

	if err = walker_push(w); err != nil {
		walker_fail(w, err)
	}
	return err
}

// walker_destroy frees everything the walker owns. The walker is zeroed.
walker_destroy :: proc(w: ^Walker) {
	for frame in w.stack {
		os.file_info_slice_delete(frame.entries, w.allocator)
	}
	delete(w.stack)
	delete(w.path)
	pattern_destroy(&w.pattern)
	ignore_destroy(&w.ignore)
	delete(w.root, w.allocator)
	delete(w.err_path, w.allocator)
	w^ = {}
}

/*
walker_next returns the next entry. It returns `ok = false` when the walk is
over or has failed; call walker_error to tell the two apart.
*/
walker_next :: proc(w: ^Walker) -> (entry: Walk_Entry, ok: bool) {
	if w.err != nil {
		return {}, false
	}
	if w.pending_dir {
		w.pending_dir = false
		if !w.skip_pending {
			if err := walker_descend(w); err != nil {
				walker_fail(w, err)
				return {}, false
			}
		}
		w.skip_pending = false
	}

	for len(w.stack) > 0 {
		frame := &w.stack[len(w.stack) - 1]
		if frame.index >= len(frame.entries) {
			walker_pop(w)
			continue
		}
		info := frame.entries[frame.index]
		frame.index += 1
		depth := len(w.stack)

		resize(&w.path, frame.prefix_len)
		if _, err := append(&w.path, info.name); err != nil {
			walker_fail(w, err)
			return {}, false
		}
		path := string(w.path[:])
		is_dir := info.type == .Directory

		if w.use_ignore {
			if .Gitignore in w.options.flags && is_dir && info.name == ".git" {
				continue
			}
			if ignore_match(&w.ignore, path, is_dir) == .Ignored {
				continue
			}
		}

		matched := !w.has_pattern || pattern_match(&w.pattern, path)
		descend := is_dir && (w.options.max_depth <= 0 || depth < w.options.max_depth)
		if descend && w.has_pattern {
			descend = walker_may_match_below(w)
		}
		skip_kind := Walk_Flag.Skip_Dirs if is_dir else Walk_Flag.Skip_Files
		yield := matched && skip_kind not_in w.options.flags

		if yield {
			w.pending_dir = descend
			path = string(w.path[:])
			return Walk_Entry {
				path = path,
				name = path[frame.prefix_len:],
				type = info.type,
				size = info.size,
				depth = depth,
			}, true
		}
		if descend {
			if err := walker_descend(w); err != nil {
				walker_fail(w, err)
				return {}, false
			}
		}
	}
	return {}, false
}

/*
walker_skip_dir stops the walker from descending into the directory that
walker_next returned last. It does nothing if that entry was not a directory.
*/
walker_skip_dir :: proc(w: ^Walker) {
	if w.pending_dir {
		w.skip_pending = true
	}
}

/*
walker_error returns the error that ended the walk, or nil when the walk ran
to completion or is still going.

Returns:
- path: the directory or file that failed, relative to the root. It stays valid until walker_destroy.
- err: an `os.Error` or an allocator error.
*/
walker_error :: proc(w: ^Walker) -> (path: string, err: Error) {
	return w.err_path, w.err
}

// find walks the tree below `root` and returns every path that matches `pattern`.
//
// Inputs:
// - root: the directory to search, in the operating system's path syntax.
// - pattern: the glob pattern, relative to `root`, with `/` separators.
// - flags: walk flags, for example `{.Gitignore}` or `{.Skip_Dirs}`.
// - allocator: allocates the result and the walker's scratch memory.
//
// Returns:
// - paths: the matching paths relative to `root`, in walk order. The caller owns
//   them; free them with `delete_paths(paths, allocator)`.
// - err: a Pattern_Error, an `os.Error` or an allocator error. On error no paths are returned.
//
// Example:
// 	paths, err := glob.find(".", "**/*.odin")
// 	if err != nil {
// 		return
// 	}
// 	defer glob.delete_paths(paths)
find :: proc(root, pattern: string, flags: Walk_Flags = {}, allocator := context.allocator) -> (paths: []string, err: Error) {
	w: Walker
	defer walker_destroy(&w)
	walker_init(&w, root, {pattern = pattern, flags = flags}, allocator) or_return

	out := make([dynamic]string, allocator) or_return
	defer if err != nil {
		delete_paths(out[:], allocator)
	}
	for entry in walker_next(&w) {
		s := strings.clone(entry.path, allocator) or_return
		if _, aerr := append(&out, s); aerr != nil {
			delete(s, allocator)
			return nil, aerr
		}
	}
	_, err = walker_error(&w)
	if err != nil {
		return nil, err
	}
	shrink(&out)
	return out[:], nil
}

// delete_paths frees a slice returned by find, together with every string in it.
delete_paths :: proc(paths: []string, allocator := context.allocator) {
	for p in paths {
		delete(p, allocator)
	}
	delete(paths, allocator)
}

// walker_push reads the directory named by the current path and pushes it.
@(private)
walker_push :: proc(w: ^Walker) -> Error {
	rel := string(w.path[:])
	dir := w.root
	if rel != "" {
		dir = strings.concatenate({w.root, "/", rel}, w.allocator) or_return
	}
	defer if rel != "" {
		delete(dir, w.allocator)
	}

	entries := os.read_all_directory_by_path(dir, w.allocator) or_return
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {
		return a.name < b.name
	})

	frame := Walk_Frame {
		entries    = entries,
		rule_count = len(w.ignore.rules),
	}
	if .Gitignore in w.options.flags {
		if gerr := walker_read_gitignore(w, dir, rel); gerr != nil {
			os.file_info_slice_delete(entries, w.allocator)
			ignore_truncate(&w.ignore, frame.rule_count)
			return gerr
		}
	}

	if rel != "" {
		if _, err := append(&w.path, '/'); err != nil {
			os.file_info_slice_delete(entries, w.allocator)
			ignore_truncate(&w.ignore, frame.rule_count)
			return err
		}
	}
	frame.prefix_len = len(w.path)
	if _, err := append(&w.stack, frame); err != nil {
		os.file_info_slice_delete(entries, w.allocator)
		ignore_truncate(&w.ignore, frame.rule_count)
		return err
	}
	return nil
}

/*
walker_descend pushes the directory named by the current path. With
Skip_Unreadable, it drops an operating system error and leaves the directory
unvisited. Allocator errors still end the walk.
*/
@(private)
walker_descend :: proc(w: ^Walker) -> Error {
	err := walker_push(w)
	if err == nil || .Skip_Unreadable not_in w.options.flags {
		return err
	}
	if oerr, is_os := err.(os.Error); is_os {
		if _, is_alloc := oerr.(runtime.Allocator_Error); !is_alloc {
			return nil
		}
	}
	return err
}

@(private)
walker_pop :: proc(w: ^Walker) {
	frame := pop(&w.stack)
	os.file_info_slice_delete(frame.entries, w.allocator)
	ignore_truncate(&w.ignore, frame.rule_count)
}

@(private)
walker_fail :: proc(w: ^Walker, err: Error) {
	w.err = err
	delete(w.err_path, w.allocator)
	w.err_path, _ = strings.clone(string(w.path[:]), w.allocator)
	w.pending_dir = false
}

// walker_may_match_below checks whether anything inside the current path could match.
@(private)
walker_may_match_below :: proc(w: ^Walker) -> bool {
	n := len(w.path)
	if _, err := append(&w.path, '/'); err != nil {
		return true
	}
	defer resize(&w.path, n)
	return pattern_may_match_below(&w.pattern, string(w.path[:]))
}

// walker_read_gitignore adds the rules of `dir/.gitignore`, if the file exists.
@(private)
walker_read_gitignore :: proc(w: ^Walker, dir, rel: string) -> Error {
	file := strings.concatenate({dir, "/.gitignore"}, w.allocator) or_return
	defer delete(file, w.allocator)
	_, err := ignore_add_file(&w.ignore, file, rel)
	if oerr, is_os := err.(os.Error); is_os && oerr == os.General_Error.Not_Exist {
		return nil
	}
	return err
}
