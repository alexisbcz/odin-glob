package glob_tests

import "core:strings"
import "core:testing"
import "core:time"

// Stacked stars used to backtrack through every split of the input, which
// took more than a minute for this pattern on a 60-byte name.
@(test)
test_stacked_stars_match_in_linear_time :: proc(t: ^testing.T) {
	name := strings.repeat("a", 60)
	defer delete(name)
	hit := strings.concatenate({name, "b"})
	defer delete(hit)

	start := time.now()
	expect_match(t, "*a*a*a*a*a*a*a*b", name, false)
	expect_match(t, "*a*a*a*a*a*a*a*b", hit, true)
	expect_match(t, "x/*a*a*a*a*a*a*a*b", hit, false)
	expect_match(t, "*a*a*a*a*a*a*a*b", "aaaaaaa/b", false)
	expect_match(t, "**/*a*a*a*a*a*a*a*b", name, false)
	expect_match(t, "{*a*a*a*a*a*a*a*b,x}", name, false)
	elapsed := time.since(start)
	testing.expectf(t, elapsed < 2 * time.Second, "stacked stars took %v", elapsed)
}

@(test)
test_star_backtracking_still_correct :: proc(t: ^testing.T) {
	expect_match(t, "*ab*cd", "xabyabzcd", true)
	expect_match(t, "*ab*cd", "xabyabzc", false)
	expect_match(t, "a*/b*", "axx/byy", true)
	expect_match(t, "a*/b*", "axx/c/byy", false)
	expect_match(t, "*.c", "a.c.c", true)
	expect_match(t, "*?", "", false)
	expect_match(t, "*?*", "x", true)
	expect_match(t, "*[0-9]*x", "ab1cd2x", true)
	expect_match(t, "*[0-9]*x", "ab1cd2", false)
	expect_match(t, "*A*", "xay", true, {.Ignore_Case})
	expect_match(t, "{a,b}*c*d", "bxcxd", true)
	expect_match(t, "{a,b}*c*d", "bxcx", false)
}

// Each `**/` used to add a nested loop over the path, so ten of them took minutes.
@(test)
test_repeated_globstar_segments_are_fast :: proc(t: ^testing.T) {
	path := strings.repeat("a/", 40)
	defer delete(path)

	start := time.now()
	expect_match(t, "**/**/**/**/**/**/**/**/**/**/x", path, false)
	expect_match(t, "**/**/x", "x", true)
	expect_match(t, "**/**/x", "a/b/x", true)
	elapsed := time.since(start)
	testing.expectf(t, elapsed < 2 * time.Second, "repeated globstars took %v", elapsed)
}
