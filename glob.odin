// Package glob matches paths against glob patterns, walks directory trees with
// them and evaluates gitignore rules.
//
// Patterns always use `/` as the path separator, on every platform. The syntax:
//
// - `*` matches any run of characters except `/`, including an empty run.
// - `?` matches exactly one character except `/`.
// - `[abc]`, `[a-z]` and `[[:digit:]]` match one character from a class.
//   `[!abc]` and `[^abc]` match one character that is not in the class.
//   A class never matches `/`.
// - `**` as a whole path segment matches zero or more segments: `a/**/b`
//   matches `a/b`, `a/x/b` and `a/x/y/b`, and `src/**` matches `src` and
//   everything below it. Anywhere else `**` acts like `*`.
// - `{a,b,c}` matches any of the comma-separated alternatives. Alternatives may
//   contain any syntax, including `/` and nested braces.
// - `\` escapes the next character, so `\*` matches a literal `*`.
//
// Wildcards match names that start with a dot, like any other name.
//
// Example:
// 	import "shared:glob"
//
// 	main :: proc() {
// 		ok, err := glob.match("src/**/*.{odin,c}", "src/net/http.odin")
// 		assert(err == nil && ok)
// 	}
package glob

import "base:runtime"
import "core:os"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// Pattern_Error lists the ways a glob or gitignore pattern can be malformed.
Pattern_Error :: enum {
	None,
	// A `[` has no matching `]`.
	Unclosed_Class,
	// A `{` has no matching `}`.
	Unclosed_Brace,
	// The pattern ends with a lone `\`.
	Trailing_Escape,
	// A class range such as `[z-a]` ends before it starts.
	Invalid_Range,
	// A named class such as `[[:foo:]]` is not one of the supported names.
	Unknown_Class_Name,
	// Braces are nested more than MAX_BRACE_DEPTH levels deep.
	Nesting_Too_Deep,
}

/*
Error is the compound error type returned by every fallible procedure in this
package. `nil` means success. Compare it against a specific variant such as
`Pattern_Error.Unclosed_Class`, or switch on it with a type switch.
*/
Error :: union #shared_nil {
	Pattern_Error,
	os.Error,
	runtime.Allocator_Error,
}

// MAX_BRACE_DEPTH is the deepest brace nesting that compile accepts.
MAX_BRACE_DEPTH :: 32

// Option changes how a pattern matches.
Option :: enum {
	// Compare letters without regard to case, using Unicode simple case folding.
	Ignore_Case,
}

// Options is a set of Option flags. The zero value selects the defaults.
Options :: bit_set[Option]

/*
Pattern is a compiled glob pattern.

Create one with compile and release it with pattern_destroy. A compiled
pattern doesn't change while matching, so several threads may match against
the same Pattern at once.
*/
Pattern :: struct {
	// source is the pattern text that compile received, as an owned copy.
	source:    string,
	// options holds the options that compile received.
	options:   Options,
	nodes:     []Node,
	allocator: runtime.Allocator,
}

@(private)
Node_Kind :: enum u8 {
	Literal,
	Any_Char,
	Star,
	Class,
	Alternation,
	// `**/`: nothing, or one or more whole segments each followed by `/`.
	Globstar_Prefix,
	// `/**` at the end of a sequence: nothing, or `/` followed by anything.
	Globstar_Suffix,
	// `**` on its own: anything, including `/`.
	Globstar_Any,
}

@(private)
Named_Class :: enum u8 {
	None,
	Alnum,
	Alpha,
	Blank,
	Digit,
	Lower,
	Punct,
	Space,
	Upper,
	Xdigit,
}

@(private)
Class_Item :: struct {
	lo, hi: rune,
	named:  Named_Class,
}

@(private)
Node :: struct {
	kind:         Node_Kind,
	negated:      bool,
	// segment marks a `**` that ends a brace alternative at the start of a
	// segment, as in `{a,**}/x`. Like `**/`, it may also match zero segments.
	segment:      bool,
	literal:      string,
	items:        []Class_Item,
	alternatives: [][]Node,
}

// Compile_Flag holds internal switches that the gitignore matcher uses.
@(private)
Compile_Flag :: enum {
	// Treat `{`, `}` and `,` as ordinary characters.
	No_Braces,
	// Make a trailing `/**` match only below the directory, not the directory itself.
	Suffix_Excludes_Self,
}

@(private)
Compile_Flags :: bit_set[Compile_Flag]

/*
compile parses `pattern` into a Pattern that can be matched many times.

Inputs:
- pattern: the glob pattern; see the package documentation for the syntax.
- options: matching options, for example `{.Ignore_Case}`.
- allocator: allocates the compiled pattern.

Returns:
- p: the compiled pattern, owned by the caller; free it with `pattern_destroy(&p)`.
- err: a Pattern_Error when the pattern is malformed, or an allocator error.

Example:
	p, err := glob.compile("*.{png,jpg}")
	if err != nil {
		return
	}
	defer glob.pattern_destroy(&p)
	assert(glob.pattern_match(&p, "cat.png"))
*/
compile :: proc(pattern: string, options: Options = {}, allocator := context.allocator) -> (p: Pattern, err: Error) {
	p, err, _ = compile_internal(pattern, options, {}, allocator)
	return
}

/*
validate reports whether `pattern` is well formed, and where it goes wrong if not.

Inputs:
- pattern: the glob pattern to check.
- allocator: used for scratch memory, which is freed before validate returns.

Returns:
- err: nil when the pattern compiles, otherwise a Pattern_Error or an allocator error.
- offset: the byte offset in `pattern` where the problem starts; 0 when err is nil.
*/
validate :: proc(pattern: string, allocator := context.allocator) -> (err: Error, offset: int) {
	p: Pattern
	p, err, offset = compile_internal(pattern, {}, {}, allocator)
	pattern_destroy(&p)
	return
}

// pattern_destroy frees everything that compile allocated for `p` and zeroes it.
pattern_destroy :: proc(p: ^Pattern) {
	if p.source == "" && p.nodes == nil {
		p^ = {}
		return
	}
	nodes_destroy(p.nodes, p.allocator)
	delete(p.source, p.allocator)
	p^ = {}
}

/*
pattern_match reports whether `path` matches the whole compiled pattern.

The path must use `/` as its separator. pattern_match never allocates.
*/
pattern_match :: proc(p: ^Pattern, path: string) -> bool {
	m := Matcher {
		fold = .Ignore_Case in p.options,
	}
	return match_nodes(&m, p.nodes, nil, path)
}

/*
match compiles `pattern`, matches it against `path` and frees the compiled form.

Use compile and pattern_match instead when you test one pattern against many paths.

Inputs:
- pattern: the glob pattern.
- path: the path to test, with `/` as its separator.
- options: matching options.
- allocator: used for the temporary compiled pattern, which is freed before match returns.

Returns:
- matched: true when the whole of `path` matches.
- err: a Pattern_Error when the pattern is malformed, or an allocator error.
*/
match :: proc(pattern, path: string, options: Options = {}, allocator := context.allocator) -> (matched: bool, err: Error) {
	p := compile(pattern, options, allocator) or_return
	defer pattern_destroy(&p)
	return pattern_match(&p, path), nil
}

// META_CHARS lists every byte that has a special meaning in a glob pattern.
META_CHARS :: `*?[]{},\`

// has_meta reports whether `s` contains any character that escape would quote.
has_meta :: proc(s: string) -> bool {
	return strings.contains_any(s, META_CHARS)
}

/*
escape quotes every special character in `s` with `\`, so that the result
matches `s` literally when used as a pattern.

Returns:
- escaped: a new string owned by the caller; free it with `delete(escaped, allocator)`.
- err: an allocator error.
*/
escape :: proc(s: string, allocator := context.allocator) -> (escaped: string, err: runtime.Allocator_Error) {
	b := strings.builder_make_len_cap(0, len(s), allocator) or_return
	for i in 0 ..< len(s) {
		if strings.index_byte(META_CHARS, s[i]) >= 0 {
			strings.write_byte(&b, '\\')
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b), nil
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

@(private)
Parser :: struct {
	src:       string,
	pos:       int,
	flags:     Compile_Flags,
	depth:     int,
	allocator: runtime.Allocator,
}

@(private)
compile_internal :: proc(
	pattern: string,
	options: Options,
	flags: Compile_Flags,
	allocator: runtime.Allocator,
) -> (
	p: Pattern,
	err: Error,
	offset: int,
) {
	parser := Parser {
		src       = pattern,
		flags     = flags,
		allocator = allocator,
	}
	nodes, perr := parse_sequence(&parser, false, true)
	if perr != nil {
		return {}, perr, parser.pos
	}
	source, serr := strings.clone(pattern, allocator)
	if serr != nil {
		nodes_destroy(nodes, allocator)
		return {}, serr, 0
	}
	p = Pattern {
		source    = source,
		options   = options,
		nodes     = nodes,
		allocator = allocator,
	}
	return p, nil, 0
}

@(private)
nodes_destroy :: proc(nodes: []Node, allocator: runtime.Allocator) {
	for &n in nodes {
		node_destroy(&n, allocator)
	}
	delete(nodes, allocator)
}

@(private)
node_destroy :: proc(n: ^Node, allocator: runtime.Allocator) {
	switch n.kind {
	case .Literal:
		delete(n.literal, allocator)
	case .Class:
		delete(n.items, allocator)
	case .Alternation:
		for alt in n.alternatives {
			nodes_destroy(alt, allocator)
		}
		delete(n.alternatives, allocator)
	case .Any_Char, .Star, .Globstar_Prefix, .Globstar_Suffix, .Globstar_Any:
	}
	n^ = {}
}

@(private)
dynamic_nodes_destroy :: proc(nodes: ^[dynamic]Node, allocator: runtime.Allocator) {
	nodes_destroy(nodes[:], allocator)
	nodes^ = nil
}

/*
parse_sequence parses until the end of the pattern or, inside braces, until an
unescaped `,` or `}`, which it leaves for the caller.
*/
@(private)
parse_sequence :: proc(
	p: ^Parser,
	in_brace: bool,
	segment_start: bool,
) -> (
	result: []Node,
	err: Error,
) {
	nodes := make([dynamic]Node, p.allocator) or_return
	lit := strings.builder_make(p.allocator) or_return
	defer strings.builder_destroy(&lit)
	defer if err != nil {
		dynamic_nodes_destroy(&nodes, p.allocator)
	}

	at_segment_start := segment_start
	braces := .No_Braces not_in p.flags

	loop: for p.pos < len(p.src) {
		c := p.src[p.pos]
		switch {
		case c == '\\':
			if p.pos + 1 >= len(p.src) {
				return nil, .Trailing_Escape
			}
			_, w := utf8.decode_rune(p.src[p.pos + 1:])
			strings.write_string(&lit, p.src[p.pos + 1:p.pos + 1 + w])
			p.pos += 1 + w
			at_segment_start = false

		case c == '*':
			end := p.pos
			for end < len(p.src) && p.src[end] == '*' {
				end += 1
			}
			stars := end - p.pos
			next_is_boundary :=
				end == len(p.src) ||
				p.src[end] == '/' ||
				(in_brace && braces && (p.src[end] == ',' || p.src[end] == '}'))
			if stars >= 2 && at_segment_start && next_is_boundary {
				if end < len(p.src) && p.src[end] == '/' {
					flush_literal(p, &nodes, &lit) or_return
					// `**/**/` matches the same paths as `**/`, so keep one node.
					// Repeated nodes would make matching polynomial in their count.
					if len(nodes) == 0 || nodes[len(nodes) - 1].kind != .Globstar_Prefix {
						append(&nodes, Node{kind = .Globstar_Prefix}) or_return
					}
					p.pos = end + 1
					at_segment_start = true
					continue loop
				}
				kind := Node_Kind.Globstar_Any
				text := strings.to_string(lit)
				if .Suffix_Excludes_Self not_in p.flags && len(text) > 0 && text[len(text) - 1] == '/' {
					// Move the separator into the node so that `a/**` also matches `a`.
					resize(&lit.buf, len(lit.buf) - 1)
					kind = .Globstar_Suffix
				}
				flush_literal(p, &nodes, &lit) or_return
				segment := kind == .Globstar_Any && end < len(p.src) && p.src[end] != '/'
				append(&nodes, Node{kind = kind, segment = segment}) or_return
			} else {
				flush_literal(p, &nodes, &lit) or_return
				if len(nodes) == 0 || nodes[len(nodes) - 1].kind != .Star {
					append(&nodes, Node{kind = .Star}) or_return
				}
			}
			p.pos = end
			at_segment_start = false

		case c == '?':
			flush_literal(p, &nodes, &lit) or_return
			append(&nodes, Node{kind = .Any_Char}) or_return
			p.pos += 1
			at_segment_start = false

		case c == '[':
			flush_literal(p, &nodes, &lit) or_return
			node := parse_class(p) or_return
			if _, aerr := append(&nodes, node); aerr != nil {
				delete(node.items, p.allocator)
				return nil, aerr
			}
			at_segment_start = false

		case c == '{' && braces:
			flush_literal(p, &nodes, &lit) or_return
			node := parse_alternation(p, at_segment_start) or_return
			if _, aerr := append(&nodes, node); aerr != nil {
				node_destroy(&node, p.allocator)
				return nil, aerr
			}
			at_segment_start = false

		case (c == ',' || c == '}') && in_brace && braces:
			break loop

		case:
			_, w := utf8.decode_rune(p.src[p.pos:])
			strings.write_string(&lit, p.src[p.pos:p.pos + w])
			p.pos += w
			at_segment_start = c == '/'
		}
	}

	flush_literal(p, &nodes, &lit) or_return
	shrink(&nodes)
	return nodes[:], nil
}

@(private)
flush_literal :: proc(p: ^Parser, nodes: ^[dynamic]Node, lit: ^strings.Builder) -> Error {
	if len(lit.buf) == 0 {
		return nil
	}
	text := strings.clone(strings.to_string(lit^), p.allocator) or_return
	strings.builder_reset(lit)
	if _, err := append(nodes, Node{kind = .Literal, literal = text}); err != nil {
		delete(text, p.allocator)
		return err
	}
	return nil
}

@(private)
parse_alternation :: proc(p: ^Parser, segment_start: bool) -> (node: Node, err: Error) {
	open := p.pos
	if p.depth >= MAX_BRACE_DEPTH {
		return {}, .Nesting_Too_Deep
	}
	p.depth += 1
	defer p.depth -= 1
	p.pos += 1 // Skip `{`.

	alts := make([dynamic][]Node, p.allocator) or_return
	defer if err != nil {
		for alt in alts {
			nodes_destroy(alt, p.allocator)
		}
		delete(alts)
	}

	for {
		alt := parse_sequence(p, true, segment_start) or_return
		if _, aerr := append(&alts, alt); aerr != nil {
			nodes_destroy(alt, p.allocator)
			return {}, aerr
		}
		if p.pos >= len(p.src) {
			p.pos = open
			return {}, .Unclosed_Brace
		}
		c := p.src[p.pos]
		p.pos += 1
		if c == '}' {
			break
		}
	}
	shrink(&alts)
	return Node{kind = .Alternation, alternatives = alts[:]}, nil
}

@(private)
parse_class :: proc(p: ^Parser) -> (node: Node, err: Error) {
	open := p.pos
	i := p.pos + 1
	node.kind = .Class
	if i < len(p.src) && (p.src[i] == '!' || p.src[i] == '^') {
		node.negated = true
		i += 1
	}

	items := make([dynamic]Class_Item, p.allocator) or_return
	defer if err != nil {
		delete(items)
	}

	first := true
	for {
		if i >= len(p.src) {
			p.pos = open
			return {}, .Unclosed_Class
		}
		if p.src[i] == ']' && !first {
			i += 1
			break
		}
		first = false

		if p.src[i] == '[' && i + 1 < len(p.src) && p.src[i + 1] == ':' {
			if end := strings.index(p.src[i + 2:], ":]"); end >= 0 {
				name := p.src[i + 2:i + 2 + end]
				named := named_class_from_string(name)
				if named == .None {
					p.pos = i
					return {}, .Unknown_Class_Name
				}
				append(&items, Class_Item{named = named}) or_return
				i += 2 + end + 2
				continue
			}
		}

		lo := read_class_char(p, &i) or_return
		hi := lo
		if i + 1 < len(p.src) && p.src[i] == '-' && p.src[i + 1] != ']' {
			start := i
			i += 1
			hi = read_class_char(p, &i) or_return
			if hi < lo {
				p.pos = start
				return {}, .Invalid_Range
			}
		}
		append(&items, Class_Item{lo = lo, hi = hi}) or_return
	}

	shrink(&items)
	node.items = items[:]
	p.pos = i
	return node, nil
}

@(private)
read_class_char :: proc(p: ^Parser, i: ^int) -> (r: rune, err: Error) {
	if p.src[i^] == '\\' {
		if i^ + 1 >= len(p.src) {
			p.pos = i^
			return 0, .Unclosed_Class
		}
		i^ += 1
	}
	w: int
	r, w = utf8.decode_rune(p.src[i^:])
	i^ += w
	return r, nil
}

@(private)
named_class_from_string :: proc(name: string) -> Named_Class {
	switch name {
	case "alnum":
		return .Alnum
	case "alpha":
		return .Alpha
	case "blank":
		return .Blank
	case "digit":
		return .Digit
	case "lower":
		return .Lower
	case "punct":
		return .Punct
	case "space":
		return .Space
	case "upper":
		return .Upper
	case "xdigit":
		return .Xdigit
	}
	return .None
}

// ---------------------------------------------------------------------------
// Matching
// ---------------------------------------------------------------------------

@(private)
Matcher :: struct {
	fold:   bool,
	// In prefix mode, running out of input counts as a match. The walker uses
	// it to decide whether anything below a directory could match.
	prefix: bool,
}

// Continuation holds the nodes that must match after the current alternative.
@(private)
Continuation :: struct {
	nodes: []Node,
	next:  ^Continuation,
}

@(private)
match_nodes :: proc(m: ^Matcher, nodes: []Node, next: ^Continuation, s: string) -> bool {
	if is_star_chain(nodes, next) {
		return match_star_chain(m, nodes, next, s)
	}
	nodes, s := nodes, s
	for len(nodes) > 0 {
		n := &nodes[0]
		rest := nodes[1:]
		switch n.kind {
		case .Literal:
			ok, remaining, exhausted := match_literal(n.literal, s, m.fold)
			if exhausted {
				return m.prefix
			}
			if !ok {
				return false
			}
			s = remaining

		case .Any_Char:
			if s == "" {
				return m.prefix
			}
			r, w := utf8.decode_rune(s)
			if r == '/' {
				return false
			}
			s = s[w:]

		case .Class:
			if s == "" {
				return m.prefix
			}
			r, w := utf8.decode_rune(s)
			if r == '/' || class_matches(n, r, m.fold) == n.negated {
				return false
			}
			s = s[w:]

		case .Star:
			if len(rest) == 0 && next == nil {
				return strings.index_byte(s, '/') < 0
			}
			i := 0
			for {
				if match_nodes(m, rest, next, s[i:]) {
					return true
				}
				if i >= len(s) || s[i] == '/' {
					return false
				}
				_, w := utf8.decode_rune(s[i:])
				i += w
			}

		case .Globstar_Prefix:
			if match_nodes(m, rest, next, s) {
				return true
			}
			for i in 0 ..< len(s) {
				if s[i] == '/' && match_nodes(m, rest, next, s[i + 1:]) {
					return true
				}
			}
			return false

		case .Globstar_Suffix:
			if match_nodes(m, rest, next, s) {
				return true
			}
			if s == "" || s[0] != '/' {
				return false
			}
			return match_any_tail(m, rest, next, s, 1)

		case .Globstar_Any:
			if match_any_tail(m, rest, next, s, 0) {
				return true
			}
			return n.segment && len(rest) == 0 && match_without_slash(m, next, s)

		case .Alternation:
			cont := Continuation{rest, next}
			for alt in n.alternatives {
				if match_nodes(m, alt, &cont, s) {
					return true
				}
			}
			return false
		}
		nodes = rest
	}
	if next != nil {
		return match_nodes(m, next.nodes, next.next, s)
	}
	return s == ""
}

// match_without_slash matches the continuation with the `/` that starts it
// removed. It lets a `**` that ends a brace alternative, as in `{a,**}/x`,
// match zero segments, the way `**/x` matches `x`.
@(private)
match_without_slash :: proc(m: ^Matcher, next: ^Continuation, s: string) -> bool {
	c := next
	for c != nil && len(c.nodes) == 0 {
		c = c.next
	}
	if c == nil {
		return false
	}
	first := &c.nodes[0]
	if first.kind != .Literal || !strings.has_prefix(first.literal, "/") {
		return false
	}
	head := [1]Node{{kind = .Literal, literal = first.literal[1:]}}
	after := Continuation{c.nodes[1:], c.next}
	return match_nodes(m, head[:], &after, s)
}

/*
is_star_chain reports whether `nodes` and every continuation after them hold
only stars, literals, `?` and classes, with at least one star.
*/
@(private)
is_star_chain :: proc(nodes: []Node, next: ^Continuation) -> bool {
	has_star := false
	ns, c := nodes, next
	for {
		for &n in ns {
			#partial switch n.kind {
			case .Star:
				has_star = true
			case .Literal, .Any_Char, .Class:
			case:
				return false
			}
		}
		if c == nil {
			return has_star
		}
		ns, c = c.nodes, c.next
	}
}

@(private)
Chain_Cursor :: struct {
	nodes: []Node,
	index: int,
	next:  ^Continuation,
}

/*
match_star_chain matches a sequence that is_star_chain accepted, in time
proportional to len(nodes) * len(s).

When a match fails it only goes back to the most recent star and lets that star
take one more character. Earlier stars never need to take more: whatever they
could absorb, the later star can absorb as well. A star can't take a `/`, and
when the most recent star reaches one, no earlier star can help either, because
it would have to take that `/` itself.
*/
@(private)
match_star_chain :: proc(m: ^Matcher, nodes: []Node, next: ^Continuation, s: string) -> bool {
	cur := Chain_Cursor{nodes, 0, next}
	si := 0
	restart: Chain_Cursor
	restart_si := -1
	for {
		for cur.index >= len(cur.nodes) && cur.next != nil {
			cur = {cur.next.nodes, 0, cur.next.next}
		}
		if cur.index < len(cur.nodes) {
			n := &cur.nodes[cur.index]
			#partial switch n.kind {
			case .Star:
				restart = cur
				restart_si = -1
				if si < len(s) && s[si] != '/' {
					_, w := utf8.decode_rune(s[si:])
					restart_si = si + w
				}
				cur.index += 1
				continue
			case .Literal:
				ok, remaining, exhausted := match_literal(n.literal, s[si:], m.fold)
				if exhausted && m.prefix {
					return true
				}
				if ok {
					si = len(s) - len(remaining)
					cur.index += 1
					continue
				}
			case .Any_Char, .Class:
				if si >= len(s) {
					if m.prefix {
						return true
					}
				} else {
					r, w := utf8.decode_rune(s[si:])
					if r != '/' && (n.kind == .Any_Char || class_matches(n, r, m.fold) != n.negated) {
						si += w
						cur.index += 1
						continue
					}
				}
			}
		} else if si == len(s) {
			return true
		}
		if restart_si < 0 {
			return false
		}
		cur = restart
		si = restart_si
	}
}

// match_any_tail tries every rune boundary of `s` from byte `start` onwards.
@(private)
match_any_tail :: proc(m: ^Matcher, rest: []Node, next: ^Continuation, s: string, start: int) -> bool {
	if len(rest) == 0 && next == nil {
		return true
	}
	i := start
	for {
		if match_nodes(m, rest, next, s[i:]) {
			return true
		}
		if i >= len(s) {
			return false
		}
		_, w := utf8.decode_rune(s[i:])
		i += w
	}
}

/*
match_literal compares `lit` with the start of `s`. `exhausted` is true when
`s` ended while it still agreed with `lit`.
*/
@(private)
match_literal :: proc(lit, s: string, fold: bool) -> (ok: bool, remaining: string, exhausted: bool) {
	if !fold {
		if len(s) >= len(lit) {
			if s[:len(lit)] == lit {
				return true, s[len(lit):], false
			}
			return false, s, false
		}
		return false, s, strings.has_prefix(lit, s)
	}
	li, si := 0, 0
	for li < len(lit) {
		if si >= len(s) {
			return false, s, true
		}
		a, aw := utf8.decode_rune(lit[li:])
		b, bw := utf8.decode_rune(s[si:])
		if !runes_equal_fold(a, b) {
			return false, s, false
		}
		li += aw
		si += bw
	}
	return true, s[si:], false
}

@(private)
runes_equal_fold :: proc(a, b: rune) -> bool {
	return a == b || unicode.to_lower(a) == unicode.to_lower(b) || unicode.to_upper(a) == unicode.to_upper(b)
}

@(private)
class_matches :: proc(n: ^Node, r: rune, fold: bool) -> bool {
	if class_contains(n.items, r) {
		return true
	}
	if fold {
		if lower := unicode.to_lower(r); lower != r && class_contains(n.items, lower) {
			return true
		}
		if upper := unicode.to_upper(r); upper != r && class_contains(n.items, upper) {
			return true
		}
	}
	return false
}

@(private)
class_contains :: proc(items: []Class_Item, r: rune) -> bool {
	for item in items {
		switch item.named {
		case .None:
			if item.lo <= r && r <= item.hi {
				return true
			}
		case .Alnum:
			if unicode.is_letter(r) || unicode.is_digit(r) {
				return true
			}
		case .Alpha:
			if unicode.is_letter(r) {
				return true
			}
		case .Blank:
			if r == ' ' || r == '\t' {
				return true
			}
		case .Digit:
			if '0' <= r && r <= '9' {
				return true
			}
		case .Lower:
			if unicode.is_lower(r) {
				return true
			}
		case .Punct:
			if unicode.is_punct(r) || (r < 0x80 && r > ' ' && r != 0x7f && !unicode.is_letter(r) && !unicode.is_digit(r)) {
				return true
			}
		case .Space:
			if unicode.is_space(r) {
				return true
			}
		case .Upper:
			if unicode.is_upper(r) {
				return true
			}
		case .Xdigit:
			if ('0' <= r && r <= '9') || ('a' <= r && r <= 'f') || ('A' <= r && r <= 'F') {
				return true
			}
		}
	}
	return false
}

// pattern_may_match_below reports whether a path inside `dir_with_slash` could match.
@(private)
pattern_may_match_below :: proc(p: ^Pattern, dir_with_slash: string) -> bool {
	m := Matcher {
		fold   = .Ignore_Case in p.options,
		prefix = true,
	}
	return match_nodes(&m, p.nodes, nil, dir_with_slash)
}
