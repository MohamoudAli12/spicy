package spicy

import "core:fmt"
import "core:math"
import "core:strings"

// .meas: measurements on the results of a run, computed from the data. ngspice's own .meas
// needs its control language and does not work with a raw file in batch mode, so spicy measures
// itself, the same way for every simulator:
//   .meas tran NAME MAX|MIN|AVG|RMS|PP|INTEG EXPR [FROM=x] [TO=x]
//   .meas tran NAME FIND EXPR AT=x
//   .meas tran NAME TRIG EXPR VAL=v [RISE=n|FALL=n|CROSS=n] TARG EXPR VAL=v [RISE=n|FALL=n|CROSS=n]
// tran, ac and dc name the analysis. x is the analysis's first vector (time, frequency, sweep).
// A complex result is measured by its magnitude; use db() or mag() in EXPR to choose another.
// TRIG/TARG give the time from the trigger's crossing to the target's crossing after it.

Meas_Edge :: enum u8 {Cross, Rise, Fall}

// One .meas result, as the measurement table shows it.
Meas_Row :: struct {
	name, measure, result, analysis: string, // "vmax", "MAX V(out)", "993 mV at 5 µs", "Transient Analysis"
}

delete_meas_row :: proc(row: Meas_Row) {
	delete(row.name)
	delete(row.measure)
	delete(row.result)
	delete(row.analysis)
}

Meas :: struct {
	name, analysis, op: string,
	expr, targ:         string, // the measured expression; for TRIG/TARG the trigger and the target
	from, to, at:       f64,
	has_from, has_to:   bool,
	val, targ_val:      f64,
	edge, targ_edge:    Meas_Edge,
	n, targ_n:          int,
}

MEAS_CORRECT :: "Correct: .meas tran vmax MAX V(out)"
MEAS_TRIG_CORRECT :: "Correct: .meas tran delay TRIG V(in) VAL=0.5 RISE=1 TARG V(out) VAL=0.9 RISE=1"

// Splits at spaces that are outside parentheses: V(a, b) and V(out) * 2 keep their spaces inside.
meas_tokens :: proc(s: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	depth, start := 0, -1
	for i in 0 ..< len(s) + 1 {
		c: u8 = 0
		if i < len(s) do c = s[i]
		if c == '(' do depth += 1
		if c == ')' do depth -= 1
		if i == len(s) || ((c == ' ' || c == '\t') && depth == 0) {
			if start >= 0 {
				append(&out, s[start:i])
				start = -1
			}
		} else if start < 0 {
			start = i
		}
	}
	return out[:]
}

// Words that end an expression in a measurement.
meas_is_option :: proc(tok: string) -> bool {
	u := upper(tok)
	if u == "TRIG" || u == "TARG" do return true
	// WORD=value: an option, whatever the word (an unknown one is reported as such)
	eq := strings.index_byte(tok, '=')
	if eq <= 0 do return false
	for ch in tok[:eq] do if !((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_') do return false
	return !(tok[eq - 1] == '<' || tok[eq - 1] == '>' || tok[eq - 1] == '!')
}

// The expression from token i up to the next option word, and the index after it.
meas_expr :: proc(t: []string, i: int) -> (string, int) {
	j := i
	for j < len(t) && !meas_is_option(t[j]) do j += 1
	return strings.join(t[i:j], " ", context.temp_allocator), j
}

// The number after a "KEY=" word.
meas_number :: proc(tok, key: string) -> (f64, bool) {
	return parse_eng(tok[len(key):])
}

// VAL= with an optional RISE=, FALL= or CROSS= (the first crossing when none is given).
meas_crossing :: proc(t: []string, i: int, what: string) -> (val: f64, edge: Meas_Edge, n, next: int, err: string) {
	if i >= len(t) || !strings.has_prefix(upper(t[i]), "VAL=") {
		return 0, .Cross, 0, i, fmt.tprintf("%s needs VAL=, the level it crosses. %s", what, MEAS_TRIG_CORRECT)
	}
	v, ok := meas_number(t[i], "VAL=")
	if !ok do return 0, .Cross, 0, i, fmt.tprintf("\"%s\" is not a level. %s", t[i], MEAS_TRIG_CORRECT)
	next = i + 1
	edge, n = .Cross, 1
	if next < len(t) {
		u := upper(t[next])
		key: string
		switch {
		case strings.has_prefix(u, "RISE="): key, edge = "RISE=", .Rise
		case strings.has_prefix(u, "FALL="): key, edge = "FALL=", .Fall
		case strings.has_prefix(u, "CROSS="): key, edge = "CROSS=", .Cross
		}
		if len(key) > 0 {
			k, ok2 := meas_number(t[next], key)
			if !ok2 || k < 1 do return 0, .Cross, 0, i, fmt.tprintf("\"%s\" needs a count of 1 or more. %s", t[next], MEAS_TRIG_CORRECT)
			n = int(k)
			next += 1
		}
	}
	return v, edge, n, next, ""
}

// Parses the arguments of a .meas line (without the word .meas).
meas_parse :: proc(args: string) -> (m: Meas, err: string) {
	t := meas_tokens(args)
	if len(t) < 4 do return m, fmt.tprintf("needs an analysis, a name, a measurement and an expression. %s", MEAS_CORRECT)
	m.analysis = lower(t[0])
	if m.analysis != "tran" && m.analysis != "ac" && m.analysis != "dc" {
		return m, fmt.tprintf("\"%s\" is not an analysis (tran, ac or dc). %s", t[0], MEAS_CORRECT)
	}
	if !is_identifier(t[1]) || (t[1][0] >= '0' && t[1][0] <= '9') do return m, fmt.tprintf("\"%s\" is not a name. %s", t[1], MEAS_CORRECT)
	m.name = t[1]
	m.op = upper(t[2])
	i := 3
	switch m.op {
	case "MAX", "MIN", "AVG", "RMS", "PP", "INTEG":
		m.expr, i = meas_expr(t, i)
		for i < len(t) {
			u := upper(t[i])
			ok := true
			switch {
			case strings.has_prefix(u, "FROM="):
				m.from, ok = meas_number(t[i], "FROM=")
				m.has_from = true
			case strings.has_prefix(u, "TO="):
				m.to, ok = meas_number(t[i], "TO=")
				m.has_to = true
			case:
				return m, fmt.tprintf("\"%s\" is not an option of %s. Correct: .meas tran %s %s V(out) FROM=0 TO=1m", t[i], m.op, m.name, m.op)
			}
			if !ok do return m, fmt.tprintf("\"%s\" is not a number. Correct: .meas tran %s %s V(out) FROM=0 TO=1m", t[i], m.name, m.op)
			i += 1
		}
	case "FIND":
		m.expr, i = meas_expr(t, i)
		if i >= len(t) || !strings.has_prefix(upper(t[i]), "AT=") {
			return m, fmt.tprintf("FIND needs AT=, the point to read. Correct: .meas tran %s FIND V(out) AT=2m", m.name)
		}
		at, ok := meas_number(t[i], "AT=")
		if !ok do return m, fmt.tprintf("\"%s\" is not a number. Correct: .meas tran %s FIND V(out) AT=2m", t[i], m.name)
		m.at = at
		i += 1
	case "TRIG":
		m.expr, i = meas_expr(t, i)
		v, edge, n, next, e := meas_crossing(t, i, "TRIG")
		if len(e) > 0 do return m, e
		m.val, m.edge, m.n, i = v, edge, n, next
		if i >= len(t) || upper(t[i]) != "TARG" {
			return m, fmt.tprintf("TRIG needs TARG, the target crossing. Correct: .meas tran %s TRIG V(in) VAL=0.5 RISE=1 TARG V(out) VAL=0.9 RISE=1", m.name)
		}
		i += 1
		m.targ, i = meas_expr(t, i)
		tv, tedge, tn, tnext, e2 := meas_crossing(t, i, "TARG")
		if len(e2) > 0 do return m, e2
		m.targ_val, m.targ_edge, m.targ_n, i = tv, tedge, tn, tnext
	case:
		return m, fmt.tprintf("\"%s\" is not a measurement (MAX MIN AVG RMS PP INTEG FIND TRIG). %s", t[2], MEAS_CORRECT)
	}
	if i < len(t) do return m, fmt.tprintf("\"%s\" is not part of the measurement. %s", t[i], MEAS_CORRECT)
	if len(m.expr) == 0 do return m, fmt.tprintf("needs an expression. %s", MEAS_CORRECT)
	if _, e := plot_check_expr(m.expr, MEAS_CORRECT); len(e) > 0 do return m, e
	if len(m.targ) > 0 {
		if _, e := plot_check_expr(m.targ, MEAS_TRIG_CORRECT); len(e) > 0 do return m, e
	}
	return m, ""
}

// The name of a .meas line (its second word), for messages about it.
meas_label :: proc(line: string) -> string {
	t := meas_tokens(line)
	return t[1] if len(t) >= 2 else line
}

// Checks the .meas lines (syntax, names) and says what they measure, in the netlist's errors.
meas_check :: proc(nl: ^Netlist, s: ^Schematic) {
	for line in nl.meas_lines {
		m, err := meas_parse(line)
		if len(err) > 0 {
			append(&nl.errors, fmt.tprintf(".meas \"%s\": %s", meas_label(line), err))
			continue
		}
		expr_validate(nl, s, tcat(".meas \"", m.name, "\""), m.expr, MEAS_CORRECT)
		if len(m.targ) > 0 do expr_validate(nl, s, tcat(".meas \"", m.name, "\""), m.targ, MEAS_TRIG_CORRECT)
	}
}

// The first crossing of level val in the given direction with index n, at or after x = after.
meas_cross :: proc(x, y: []f64, val: f64, edge: Meas_Edge, n: int, after: f64) -> (t: f64, ok: bool) {
	count := 0
	for i in 0 ..< len(y) - 1 {
		if x[i + 1] < after do continue
		a, b := y[i], y[i + 1]
		rising := a < val && b >= val
		falling := a > val && b <= val
		hit := rising || falling
		switch edge {
		case .Rise: hit = rising
		case .Fall: hit = falling
		case .Cross:
		}
		if !hit do continue
		count += 1
		if count == n {
			return x[i] + (val - a) * (x[i + 1] - x[i]) / (b - a), true
		}
	}
	return 0, false
}

// The values of a result as real numbers: the magnitude of a complex one.
meas_values :: proc(res: Eval_Result) -> []f64 {
	out := make([]f64, len(res.re), context.temp_allocator)
	for i in 0 ..< len(res.re) {
		out[i] = res.re[i] if res.im == nil else abs_c(res.re[i], res.im[i])
	}
	return out
}

// Value of y at x (x increasing), by linear interpolation.
meas_at :: proc(x, y: []f64, at: f64) -> (f64, bool) {
	for i in 0 ..< len(x) - 1 {
		if x[i] <= at && at <= x[i + 1] {
			if x[i + 1] == x[i] do return y[i], true
			return y[i] + (y[i + 1] - y[i]) * (at - x[i]) / (x[i + 1] - x[i]), true
		}
	}
	return 0, false
}

// The result of one measurement over one plot: its line, or the reason it cannot be made.
meas_on_plot :: proc(m: ^Meas, p: ^Plot, sch: ^Schematic, sim: ^Simulator_Def) -> (line, err: string) {
	if len(p.vecs) == 0 || p.npoints < 2 do return "", "the analysis has too few points"
	x := p.vecs[0].re
	xunit := p.vecs[0].unit
	res := expr_eval(m.expr, p, sch, sim)
	defer {
		delete(res.re)
		delete(res.im)
	}
	if len(res.err) > 0 {
		defer delete(res.err)
		return "", strings.clone(res.err, context.temp_allocator)
	}
	defer delete(res.unit)
	unit := res.unit
	y := meas_values(res)
	in_range := proc(xv: f64, m: ^Meas) -> bool {
		return (!m.has_from || xv >= m.from) && (!m.has_to || xv <= m.to)
	}
	switch m.op {
	case "MAX", "MIN", "PP":
		best, at_x, lo, hi := 0.0, 0.0, 0.0, 0.0
		found := false
		for i in 0 ..< len(y) {
			if !in_range(x[i], m) do continue
			if !found {
				lo, hi = y[i], y[i]
				found = true
			}
			lo, hi = min(lo, y[i]), max(hi, y[i])
		}
		if !found do return "", "no points between FROM and TO"
		switch m.op {
		case "PP":
			return fmt.tprintf("%s = %s", m.name, fmt_eng(hi - lo, unit)), ""
		case "MAX", "MIN":
			best = hi if m.op == "MAX" else lo
			for i in 0 ..< len(y) do if in_range(x[i], m) && y[i] == best {
				at_x = x[i]
				break
			}
			return fmt.tprintf("%s = %s at %s", m.name, fmt_eng(best, unit), fmt_eng(at_x, xunit)), ""
		}
	case "AVG", "RMS", "INTEG":
		// trapezoids over the points in range
		sum, sq, span := 0.0, 0.0, 0.0
		prev := -1
		for i in 0 ..< len(y) {
			if !in_range(x[i], m) do continue
			if prev >= 0 {
				dx := x[i] - x[prev]
				sum += (y[i] + y[prev]) / 2 * dx
				sq += (y[i] * y[i] + y[prev] * y[prev]) / 2 * dx
				span += dx
			}
			prev = i
		}
		if span <= 0 do return "", "no range to measure over"
		switch m.op {
		case "INTEG":
			return fmt.tprintf("%s = %s", m.name, fmt_eng(sum, unit_mul(unit, xunit))), ""
		case "AVG":
			return fmt.tprintf("%s = %s", m.name, fmt_eng(sum / span, unit)), ""
		}
		return fmt.tprintf("%s = %s", m.name, fmt_eng(math.sqrt(sq / span), unit)), ""
	case "FIND":
		v, ok := meas_at(x, y, m.at)
		if !ok do return "", fmt.tprintf("AT=%s is outside the run", fmt_eng(m.at, xunit))
		return fmt.tprintf("%s = %s at %s", m.name, fmt_eng(v, unit), fmt_eng(m.at, xunit)), ""
	case "TRIG":
		tres := expr_eval(m.targ, p, sch, sim)
		defer {
			delete(tres.re)
			delete(tres.im)
			delete(tres.unit)
		}
		if len(tres.err) > 0 {
			defer delete(tres.err)
			return "", strings.clone(tres.err, context.temp_allocator)
		}
		ty := meas_values(tres)
		t1, ok1 := meas_cross(x, y, m.val, m.edge, m.n, x[0])
		if !ok1 do return "", fmt.tprintf("the trigger %s never crosses VAL=%s", m.expr, fmt_eng(m.val, unit))
		t2, ok2 := meas_cross(x, ty, m.targ_val, m.targ_edge, m.targ_n, t1)
		if !ok2 do return "", fmt.tprintf("the target %s never crosses VAL=%s after %s", m.targ, fmt_eng(m.targ_val, tres.unit), fmt_eng(t1, xunit))
		return fmt.tprintf("%s = %s", m.name, fmt_eng(t2 - t1, xunit)), ""
	}
	return "", "unknown measurement"
}

// Every measurement of the run, over each plot of its analysis (a .step run has one per value).
meas_run :: proc(r: ^Run, sch: ^Schematic, sim: ^Simulator_Def) {
	for line in r.meas_lines {
		m, err := meas_parse(line)
		if len(err) > 0 {
			append(&r.warnings, strings.clone(fmt.tprintf(".meas \"%s\": %s", meas_label(line), err)))
			continue
		}
		made := false
		for &p in r.plots do if plot_kind(&p) == m.analysis {
			made = true
			res, msg := meas_on_plot(&m, &p, sch, sim)
			if len(msg) > 0 {
				append(&r.warnings, strings.clone(fmt.tprintf(".meas \"%s\": %s", m.name, msg)))
				continue
			}
			append(&r.measures, strings.clone(fmt.tprintf("%s  (%s)", res, p.name)))
			measure := tcat(m.op, " ", m.expr) if len(m.targ) == 0 else tcat(m.op, " ", m.expr, " → ", m.targ)
			result := strings.trim_prefix(res, tcat(m.name, " = "))
			append(&r.meas_rows, Meas_Row{name = strings.clone(m.name), measure = strings.clone(measure), result = strings.clone(result), analysis = strings.clone(p.name)})
		}
		if !made do append(&r.warnings, strings.clone(fmt.tprintf(".meas \"%s\": the run has no %s analysis. Correct: add a .%s directive", m.name, m.analysis, m.analysis)))
	}
	if len(r.measures) > 0 {
		old := r.log_text
		body := strings.join(r.measures[:], "\n", context.temp_allocator)
		r.log_text = strings.concatenate({old, "\n\nMeasurements:\n", body})
		delete(old)
	}
}
