// Example basic shows matching, compiled patterns and gitignore rules. Run it with `odin run examples/basic`.
package main

import glob "../.."
import "core:fmt"
import "core:os"

main :: proc() {
	// One-off match: compiles, matches and frees in one call.
	ok, err := glob.match("src/**/*.{odin,c}", "src/net/http.odin")
	if err != nil {
		fmt.eprintln("bad pattern:", err)
		os.exit(1)
	}
	fmt.println("src/net/http.odin matches:", ok)

	// Compile once, match many times.
	p, cerr := glob.compile("*_test.odin")
	if cerr != nil {
		fmt.eprintln("bad pattern:", cerr)
		os.exit(1)
	}
	defer glob.pattern_destroy(&p)
	for name in ([]string{"parse_test.odin", "parse.odin", "tests/x_test.odin"}) {
		fmt.printf("%-20s %v\n", name, glob.pattern_match(&p, name))
	}

	// Malformed patterns come back as errors, with the offset of the problem.
	if verr, offset := glob.validate("assets/[a-z"); verr != nil {
		fmt.println("validate:", verr, "at byte", offset)
	}

	// Gitignore rules, including negation and nested files.
	ignore: glob.Ignore
	glob.ignore_init(&ignore)
	defer glob.ignore_destroy(&ignore)
	_, _ = glob.ignore_add_string(&ignore, "*.log\nbuild/\n")
	_, _ = glob.ignore_add_string(&ignore, "!keep.log\n", "server")
	for path in ([]string{"debug.log", "server/keep.log", "build/out.o", "main.c"}) {
		fmt.printf("%-16s ignored=%v\n", path, glob.ignore_is_ignored(&ignore, path, false))
	}
}
