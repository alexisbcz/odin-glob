/*
Example find lists the files below a directory that match a pattern, skipping
whatever `.gitignore` files exclude.

Usage:
	odin run examples/find -- PATTERN [ROOT]
*/
package main

import glob "../.."
import "core:fmt"
import "core:os"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: find PATTERN [ROOT]")
		os.exit(2)
	}
	pattern := os.args[1]
	root := os.args[2] if len(os.args) > 2 else "."

	w: glob.Walker
	defer glob.walker_destroy(&w)
	if err := glob.walker_init(&w, root, {pattern = pattern, flags = {.Gitignore, .Skip_Dirs}}); err != nil {
		fmt.eprintln("find:", err)
		os.exit(1)
	}

	count := 0
	for entry in glob.walker_next(&w) {
		fmt.println(entry.path)
		count += 1
	}
	if path, err := glob.walker_error(&w); err != nil {
		fmt.eprintfln("find: %s: %v", path, err)
		os.exit(1)
	}
	fmt.eprintfln("%d match(es)", count)
}
