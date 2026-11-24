package spicy

import "core:fmt"
import "core:strings"

// The .plot directive. `.plot V(out), I(R1)` in a SPICE directive asks for those traces to be
// shown in the waveform viewer after every run. The line is not sent to the simulator: its
// expressions are checked before the run, and the analysis they can be evaluated in is shown.
// Arguments are separated by commas (V(a,b) keeps its comma); the expressions are the trace
// expressions of the waveform viewer.

// A net (V(...)) or a part (I(...), Ic(...)) that an expression names.
Plot_Ref :: struct {
	kind: u8, // 'v' or 'i'
	name: string,
}

// The arguments of a .plot line, or ok = false when the line is not one.
plot_line_args :: proc(l: string) -> (args: string, ok: bool) {
	t := strings.trim_space(l)
	if len(t) < 5 || lower(t[:5]) != ".plot" do return "", false
	if len(t) > 5 && t[5] != ' ' && t[5] != '\t' do return "", false // .plots and the like
	return strings.trim_space(t[5:]), true
}

// The comma-separated expressions of a .plot argument list, commas inside parentheses kept.
plot_split :: proc(args: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	depth, start := 0, 0
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case '(':
			depth += 1
		case ')':
			depth -= 1
		case ',':
			if depth == 0 {
				append(&out, strings.trim_space(args[start:i]))
				start = i + 1
			}
		}
	}
	append(&out, strings.trim_space(args[start:]))
	return out[:]
}

// Every expression of the .plot lines that apply to this simulator, in schematic order.
plot_requests :: proc(s: ^Schematic, sim: ^Simulator_Def) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for t in s.texts {
		if !t.directive do continue
		body, ok := directive_for(t.text, sim)
		if !ok do continue
		for l in split_lines(body) {
			args, is := plot_line_args(l)
			if !is do continue
			for e in plot_split(args) do append(&out, e)
		}
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// Syntax: the grammar of the trace expressions (expr.odin), without evaluating anything.

@(private = "file")
Plot_Check :: struct {
	src:  string,
	pos:  int,
	refs: [dynamic]Plot_Ref,
	err:  string,
}

@(private = "file")
pc_fail :: proc(c: ^Plot_Check, msg: string) {
	if len(c.err) == 0 do c.err = msg
}

@(private = "file")
pc_peek :: proc(c: ^Plot_Check) -> u8 {
	for c.pos < len(c.src) && (c.src[c.pos] == ' ' || c.src[c.pos] == '\t') do c.pos += 1
	return c.src[c.pos] if c.pos < len(c.src) else 0
}

// The expression grammar: sum of products, products of unaries, unary minus, and ^.
@(private = "file")
pc_sum :: proc(c: ^Plot_Check) {
	pc_prod(c)
	for len(c.err) == 0 {
		ch := pc_peek(c)
		if ch != '+' && ch != '-' do break
		c.pos += 1
		pc_prod(c)
	}
}

@(private = "file")
pc_prod :: proc(c: ^Plot_Check) {
	pc_unary(c)
	for len(c.err) == 0 {
		ch := pc_peek(c)
		if ch != '*' && ch != '/' do break
		c.pos += 1
		pc_unary(c)
	}
}

@(private = "file")
pc_unary :: proc(c: ^Plot_Check) {
	ch := pc_peek(c)
	if ch == '-' || ch == '+' {
		c.pos += 1
		pc_unary(c)
		return
	}
	pc_primary(c)
	if len(c.err) == 0 && pc_peek(c) == '^' {
		c.pos += 1
		pc_unary(c)
	}
}

// A correct example of a function call, for the messages about it.
@(private = "file")
plot_example :: proc(name: string) -> string {
	lname := lower(name)
	switch {
	case lname == "v": return "V(out)"
	case lname[0] == 'i' && !is_func(lname): return tcat(name, "(R1)")
	}
	return tcat(name, "(V(out))")
}

// What is missing when the expression ends, named after the operator it ends with.
@(private = "file")
plot_missing_operand :: proc(src: string) -> string {
	t := strings.trim_space(src)
	if len(t) == 0 do return "the expression is empty. Correct: V(out)"
	switch t[len(t) - 1] {
	case '+', '-': return fmt.tprintf("an operand is missing after \"%c\". Correct: V(out) %c V(in)", t[len(t) - 1], t[len(t) - 1])
	case '*', '/': return fmt.tprintf("an operand is missing after \"%c\". Correct: V(out) %c 2", t[len(t) - 1], t[len(t) - 1])
	case '^': return "an operand is missing after \"^\". Correct: V(out) ^ 2"
	case '(': return "nothing inside \"(\". Correct: (V(out) + 1)"
	case ',': return "an argument is missing after \",\". Correct: max(V(out), 1e3)"
	}
	return "an expression is missing at the end. Correct: V(out)"
}

@(private = "file")
pc_primary :: proc(c: ^Plot_Check) {
	ch := pc_peek(c)
	if ch == 0 {
		pc_fail(c, plot_missing_operand(c.src))
		return
	}
	if ch == '(' {
		c.pos += 1
		pc_sum(c)
		if len(c.err) > 0 do return
		if pc_peek(c) != ')' {
			pc_fail(c, "\"(\" has no closing \")\". Correct: (V(out) + 1)")
			return
		}
		c.pos += 1
		return
	}
	if (ch >= '0' && ch <= '9') || ch == '.' {
		start := c.pos
		for c.pos < len(c.src) && (is_ident(c.src[c.pos]) || ((c.src[c.pos] == '+' || c.src[c.pos] == '-') && (c.src[c.pos - 1] == 'e' || c.src[c.pos - 1] == 'E'))) do c.pos += 1
		tok := c.src[start:c.pos]
		// parse_eng reads "1.2.3" as 1.2 followed by a unit, so a second point is refused here
		if strings.count(tok, ".") > 1 {
			pc_fail(c, fmt.tprintf("\"%s\" has more than one decimal point. Correct: 1.2 or 4.7k", tok))
		} else if _, ok := parse_eng(tok); !ok {
			pc_fail(c, fmt.tprintf("\"%s\" is not a number. Correct: 1.2, 4.7k, 10u or 1e-3", tok))
		}
		return
	}
	if !is_ident(ch) {
		pc_fail(c, fmt.tprintf("\"%c\" is not allowed here. Correct: V(out) * 2", ch))
		return
	}
	start := c.pos
	for c.pos < len(c.src) && is_ident(c.src[c.pos]) do c.pos += 1
	name := c.src[start:c.pos]
	if c.pos >= len(c.src) || c.src[c.pos] != '(' do return // pi, time, or a vector name
	open := c.pos
	end := match_paren(c.src, open)
	if end < 0 {
		pc_fail(c, fmt.tprintf("the \"(\" after \"%s\" is never closed. Correct: %s", name, plot_example(name)))
		return
	}
	inner := c.src[open + 1:end - 1]
	lname := lower(name)
	switch {
	case lname == "v":
		parts := strings.split(inner, ",", context.temp_allocator)
		if len(parts) > 2 {
			pc_fail(c, "V() takes one net or two nets. Correct: V(out) or V(a,b)")
			return
		}
		for p in parts {
			n := strings.trim_space(p)
			if len(n) == 0 {
				pc_fail(c, "V() needs a net name. Correct: V(out)")
				return
			}
			append(&c.refs, Plot_Ref{kind = 'v', name = n})
		}
		c.pos = end
	case lname[0] == 'i' && !is_func(lname) && lname != "if":
		// I(R1), Ic(Q1): the current of a part, or of one pin of it
		n := strings.trim_space(inner)
		if len(n) == 0 {
			pc_fail(c, fmt.tprintf("%s() needs a part name. Correct: %s(R1)", name, name))
			return
		}
		append(&c.refs, Plot_Ref{kind = 'i', name = n})
		c.pos = end
	case:
		if !is_func(lname) {
			pc_fail(c, fmt.tprintf("unknown function \"%s()\". Functions: abs sqrt db mag ph re im ln log10 exp sin cos tan atan d min max int. Correct: db(V(out))", name))
			return
		}
		c.pos = open + 1
		if pc_peek(c) != ')' {
			for {
				pc_sum(c)
				if len(c.err) > 0 || pc_peek(c) != ',' do break
				c.pos += 1
			}
		}
		if len(c.err) > 0 do return
		if pc_peek(c) != ')' {
			pc_fail(c, fmt.tprintf("the \"(\" after \"%s\" is never closed. Correct: %s", name, plot_example(name)))
			return
		}
		c.pos += 1
	}
}

// The names an expression uses, or the first syntax error.
plot_check_expr :: proc(src: string) -> (refs: []Plot_Ref, err: string) {
	c := Plot_Check{src = src, refs = make([dynamic]Plot_Ref, context.temp_allocator)}
	pc_sum(&c)
	if len(c.err) == 0 && pc_peek(&c) != 0 {
		pc_fail(&c, fmt.tprintf("\"%s\" cannot follow the expression. Separate expressions with a comma. Correct: .plot V(out), I(R1)", c.src[c.pos:]))
	}
	return c.refs[:], c.err
}

// The name in names closest to name (case ignored): the likely fix for a typo.
@(private = "file")
plot_nearest :: proc(name: string, names: []string) -> string {
	best, best_d := "", max(int)
	for n in names {
		if d := plot_distance(lower(name), lower(n)); d < best_d {
			best, best_d = n, d
		}
	}
	return best
}

// Edit distance between two strings (insertions, deletions, substitutions).
@(private = "file")
plot_distance :: proc(a, b: string) -> int {
	prev := make([]int, len(b) + 1, context.temp_allocator)
	cur := make([]int, len(b) + 1, context.temp_allocator)
	for j in 0 ..= len(b) do prev[j] = j
	for i in 1 ..= len(a) {
		cur[0] = i
		for j in 1 ..= len(b) {
			cost := 0 if a[i - 1] == b[j - 1] else 1
			cur[j] = min(min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost)
		}
		prev, cur = cur, prev
	}
	return prev[len(b)]
}

// The first names of a list, for a message: "R1, C1, D1 …".
@(private = "file")
plot_list :: proc(names: []string) -> string {
	if len(names) == 0 do return "none"
	n := min(len(names), 8)
	s := strings.join(names[:n], ", ", context.temp_allocator)
	if len(names) > n do return tcat(s, " …")
	return s
}

// Checks the .plot expressions against the syntax and against the parts and nets of the
// schematic. Names with a hierarchy (x1.out), a bus or a raw vector (i(@r1[i])) are left to
// the run, where the simulator's own names are known.
plot_validate :: proc(nl: ^Netlist, s: ^Schematic) {
	for e in nl.plot_traces {
		if len(e) == 0 {
			append(&nl.errors, ".plot needs an expression. Correct: .plot V(out), I(R1)")
			continue
		}
		refs, err := plot_check_expr(e)
		if len(err) > 0 {
			append(&nl.errors, fmt.tprintf(".plot \"%s\": %s", e, err))
			continue
		}
		for r in refs {
			if strings.contains_any(r.name, "@#.:[]$") do continue
			switch r.kind {
			case 'v':
				if r.name == "0" || strings.equal_fold(r.name, "gnd") do continue
				found := false
				nets := make([dynamic]string, context.temp_allocator)
				for n in nl.nets.names {
					if strings.equal_fold(n, r.name) do found = true
					if n != "0" do append(&nets, n)
				}
				if !found {
					near := plot_nearest(r.name, nets[:])
					if len(near) == 0 do near = "out"
					append(&nl.errors, fmt.tprintf(".plot \"%s\": no net \"%s\" in the schematic. Nets here: %s. Correct: V(%s)", e, r.name, plot_list(nets[:]), near))
				}
			case 'i':
				found := false
				parts := make([dynamic]string, context.temp_allocator)
				for &c in s.comps {
					if strings.equal_fold(c.ref, r.name) do found = true
					append(&parts, c.ref)
				}
				if !found {
					near := plot_nearest(r.name, parts[:])
					if len(near) == 0 do near = "R1"
					append(&nl.errors, fmt.tprintf(".plot \"%s\": no part \"%s\" in the schematic. Parts here: %s. Correct: I(%s)", e, r.name, plot_list(parts[:]), near))
				}
			}
		}
	}
}

// ---------------------------------------------------------------------------
// After the run

// Why the expression cannot be evaluated over the plot, or "".
plot_expr_error :: proc(expr: string, plot: ^Plot, sch: ^Schematic, sim: ^Simulator_Def) -> string {
	res := expr_eval(expr, plot, sch, sim)
	defer {
		delete(res.re)
		delete(res.im)
		delete(res.unit)
	}
	if len(res.err) == 0 do return ""
	defer delete(res.err)
	return strings.clone(res.err, context.temp_allocator)
}

// The analysis the .plot traces are shown in: the one the viewer would show (idx) if every
// expression can be evaluated there, else the first analysis where they all can. When none
// can, the expressions that fail are added to the run's warnings.
plot_pick :: proc(r: ^Run, sch: ^Schematic, sim: ^Simulator_Def, idx: int) -> int {
	if len(r.plot_traces) == 0 || len(r.plots) == 0 do return idx
	order := make([dynamic]int, context.temp_allocator)
	if idx >= 0 do append(&order, idx)
	for i in 0 ..< len(r.plots) do if i != idx do append(&order, i)
	for i in order {
		all := true
		for e in r.plot_traces do if len(plot_expr_error(e, &r.plots[i], sch, sim)) > 0 do all = false
		if all do return i
	}
	chosen := max(idx, 0)
	for e in r.plot_traces {
		if msg := plot_expr_error(e, &r.plots[chosen], sch, sim); len(msg) > 0 {
			append(&r.warnings, strings.clone(fmt.tprintf(".plot \"%s\": %s. Correct: a net or part this analysis writes, e.g. V(out) or I(R1)", e, msg)))
		}
	}
	return chosen
}
