package spicy

import "core:fmt"
import "core:math"
import "core:math/cmplx"
import "core:strconv"
import "core:strings"

// Trace expressions: V(out), V(a,b), I(R1), Ic(Q1), raw vector names such as i(@r1[i]),
// numbers with SI suffixes, + - * / ^, and functions abs sqrt exp ln log10 db mag ph re im
// sin cos tan atan d (derivative) min max.

Expr_Ctx :: struct {
	plot:  ^Plot,
	sch:   ^Schematic,
	sim:   ^Simulator_Def,
	n:     int,
	err:   string,
}

Expr_Val :: struct {
	v:    []complex128, // len 1 = constant
	unit: string,
}

Eval_Result :: struct {
	re, im: []f64, // im == nil for real results
	unit:   string,
	err:    string,
}

// Evaluates an expression over a plot. The result is allocated with context.allocator.
expr_eval :: proc(src: string, plot: ^Plot, sch: ^Schematic, sim: ^Simulator_Def) -> Eval_Result {
	ctx := Expr_Ctx{plot = plot, sch = sch, sim = sim, n = plot.npoints}
	p := Parser{src = src, ctx = &ctx}
	v := parse_sum(&p)
	skip_ws(&p)
	if len(ctx.err) == 0 && p.pos < len(p.src) do ctx.err = fmt.tprintf("unexpected \"%s\"", p.src[p.pos:])
	if len(ctx.err) > 0 do return {err = strings.clone(ctx.err)}
	res := Eval_Result{unit = strings.clone(v.unit)}
	res.re = make([]f64, ctx.n)
	cplx := plot.complex
	if cplx do res.im = make([]f64, ctx.n)
	for i in 0 ..< ctx.n {
		x := v.v[0] if len(v.v) == 1 else v.v[i]
		res.re[i] = real(x)
		if cplx do res.im[i] = imag(x)
	}
	return res
}

@(private = "file")
Parser :: struct {
	src: string,
	pos: int,
	ctx: ^Expr_Ctx,
}

@(private = "file")
skip_ws :: proc(p: ^Parser) {for p.pos < len(p.src) && (p.src[p.pos] == ' ' || p.src[p.pos] == '\t') do p.pos += 1}

@(private = "file")
peek :: proc(p: ^Parser) -> u8 {
	skip_ws(p)
	return p.src[p.pos] if p.pos < len(p.src) else 0
}

@(private = "file")
fail :: proc(p: ^Parser, msg: string) -> Expr_Val {
	if len(p.ctx.err) == 0 do p.ctx.err = msg
	return const_val(0)
}

@(private = "file")
const_val :: proc(x: f64) -> Expr_Val {
	v := make([]complex128, 1, context.temp_allocator)
	v[0] = complex(x, 0)
	return {v = v}
}

@(private = "file")
binop :: proc(p: ^Parser, a, b: Expr_Val, op: u8) -> Expr_Val {
	n := max(len(a.v), len(b.v))
	out := make([]complex128, n, context.temp_allocator)
	for i in 0 ..< n {
		x := a.v[0] if len(a.v) == 1 else a.v[i]
		y := b.v[0] if len(b.v) == 1 else b.v[i]
		switch op {
		case '+': out[i] = x + y
		case '-': out[i] = x - y
		case '*': out[i] = x * y
		case '/': out[i] = x / y if y != 0 else complex(math.inf_f64(1), 0)
		case '^': out[i] = cmplx.pow(x, y)
		}
	}
	unit := ""
	switch op {
	case '+', '-': unit = a.unit if a.unit == b.unit || len(b.unit) == 0 else (b.unit if len(a.unit) == 0 else "")
	case '*':
		switch {
		case len(a.unit) == 0: unit = b.unit
		case len(b.unit) == 0: unit = a.unit
		case (a.unit == "V" && b.unit == "A") || (a.unit == "A" && b.unit == "V"): unit = "W"
		}
	case '/':
		switch {
		case len(b.unit) == 0: unit = a.unit
		case a.unit == "V" && b.unit == "A": unit = "Ω"
		case a.unit == "A" && b.unit == "V": unit = "S"
		}
	}
	return {v = out, unit = unit}
}

@(private = "file")
parse_sum :: proc(p: ^Parser) -> Expr_Val {
	a := parse_prod(p)
	for {
		c := peek(p)
		if c != '+' && c != '-' do break
		p.pos += 1
		b := parse_prod(p)
		a = binop(p, a, b, c)
	}
	return a
}

@(private = "file")
parse_prod :: proc(p: ^Parser) -> Expr_Val {
	a := parse_unary(p)
	for {
		c := peek(p)
		if c != '*' && c != '/' do break
		p.pos += 1
		b := parse_unary(p)
		a = binop(p, a, b, c)
	}
	return a
}

@(private = "file")
parse_unary :: proc(p: ^Parser) -> Expr_Val {
	c := peek(p)
	if c == '-' {
		p.pos += 1
		v := parse_unary(p)
		return binop(p, const_val(0), v, '-')
	}
	if c == '+' {
		p.pos += 1
		return parse_unary(p)
	}
	a := parse_primary(p)
	if peek(p) == '^' {
		p.pos += 1
		b := parse_unary(p)
		a = binop(p, a, b, '^')
	}
	return a
}

@(private = "file")
is_ident :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '@' || c == '#' || c == '.' || c == ':' || c == '[' || c == ']' || c == '$'
}

// Text of a balanced (…) starting at p.src[start] == '('; returns the end index after ')'.
@(private = "file")
match_paren :: proc(s: string, start: int) -> int {
	depth := 0
	for i in start ..< len(s) {
		if s[i] == '(' do depth += 1
		if s[i] == ')' {
			depth -= 1
			if depth == 0 do return i + 1
		}
	}
	return -1
}

@(private = "file")
vec_val :: proc(p: ^Parser, v: ^Vec) -> Expr_Val {
	out := make([]complex128, p.ctx.n, context.temp_allocator)
	for i in 0 ..< p.ctx.n do out[i] = complex(v.re[i], v.im[i] if v.im != nil else 0)
	return {v = out, unit = v.unit}
}

@(private = "file")
parse_primary :: proc(p: ^Parser) -> Expr_Val {
	c := peek(p)
	if c == 0 do return fail(p, "expression ends too early")
	if c == '(' {
		p.pos += 1
		v := parse_sum(p)
		if peek(p) != ')' do return fail(p, "missing )")
		p.pos += 1
		return v
	}
	if (c >= '0' && c <= '9') || c == '.' {
		start := p.pos
		for p.pos < len(p.src) && (is_ident(p.src[p.pos]) || ((p.src[p.pos] == '+' || p.src[p.pos] == '-') && (p.src[p.pos - 1] == 'e' || p.src[p.pos - 1] == 'E'))) do p.pos += 1
		x, ok := parse_eng(p.src[start:p.pos])
		if !ok do return fail(p, fmt.tprintf("bad number \"%s\"", p.src[start:p.pos]))
		return const_val(x)
	}
	if !is_ident(c) do return fail(p, fmt.tprintf("unexpected \"%c\"", c))
	start := p.pos
	for p.pos < len(p.src) && is_ident(p.src[p.pos]) do p.pos += 1
	name := p.src[start:p.pos]
	if p.pos < len(p.src) && p.src[p.pos] == '(' {
		end := match_paren(p.src, p.pos)
		if end < 0 do return fail(p, "missing )")
		full := p.src[start:end]
		// a raw vector name like v(out) or i(@r1[i])
		if v := vec_find(p.ctx.plot, full); v != nil {
			p.pos = end
			return vec_val(p, v)
		}
		inner := p.src[p.pos + 1:end - 1]
		lname := lower(name)
		// probes
		if lname == "v" {
			p.pos = end
			parts := strings.split(inner, ",", context.temp_allocator)
			a := probe_voltage(p, strings.trim_space(parts[0]))
			if len(parts) > 1 {
				b := probe_voltage(p, strings.trim_space(parts[1]))
				return binop(p, a, b, '-')
			}
			return a
		}
		if len(lname) >= 1 && lname[0] == 'i' && !is_func(lname) {
			p.pos = end
			return probe_current(p, lname[1:], strings.trim_space(inner))
		}
		// functions
		p.pos += 1
		args := make([dynamic]Expr_Val, context.temp_allocator)
		if peek(p) != ')' {
			for {
				append(&args, parse_sum(p))
				if peek(p) == ',' {p.pos += 1; continue}
				break
			}
		}
		if peek(p) != ')' do return fail(p, "missing )")
		p.pos += 1
		return call_func(p, lname, args[:])
	}
	switch lower(name) {
	case "pi": return const_val(math.PI)
	case "time", "frequency":
		if len(p.ctx.plot.vecs) > 0 do return vec_val(p, &p.ctx.plot.vecs[0])
	}
	if v := vec_find(p.ctx.plot, name); v != nil do return vec_val(p, v)
	return fail(p, fmt.tprintf("no vector \"%s\"", name))
}

@(private = "file")
FUNCS := [?]string{"abs", "sqrt", "exp", "ln", "log", "log10", "db", "mag", "ph", "phase", "re", "real", "im", "imag", "sin", "cos", "tan", "atan", "d", "min", "max", "int", "if"}

@(private = "file")
is_func :: proc(n: string) -> bool {
	for f in FUNCS do if f == n do return true
	return false
}

@(private = "file")
call_func :: proc(p: ^Parser, name: string, args: []Expr_Val) -> Expr_Val {
	if len(args) == 0 do return fail(p, fmt.tprintf("%s() needs an argument", name))
	a := args[0]
	out := make([]complex128, len(a.v), context.temp_allocator)
	unit := a.unit
	switch name {
	case "min", "max":
		if len(args) < 2 do return fail(p, fmt.tprintf("%s(a, b) needs two arguments", name))
		b := args[1]
		n := max(len(a.v), len(b.v))
		o := make([]complex128, n, context.temp_allocator)
		for i in 0 ..< n {
			x := real(a.v[0] if len(a.v) == 1 else a.v[i])
			y := real(b.v[0] if len(b.v) == 1 else b.v[i])
			o[i] = complex(min(x, y) if name == "min" else max(x, y), 0)
		}
		return {v = o, unit = unit}
	case "d":
		// derivative with respect to the x axis
		if len(a.v) == 1 do return const_val(0)
		x := p.ctx.plot.vecs[0].re
		for i in 0 ..< len(a.v) {
			i0, i1 := max(i - 1, 0), min(i + 1, len(a.v) - 1)
			dx := x[i1] - x[i0]
			out[i] = (a.v[i1] - a.v[i0]) / complex(dx, 0) if dx != 0 else 0
		}
		return {v = out, unit = tcat(unit, "/s") if len(unit) > 0 else ""}
	case "int":
		if len(a.v) == 1 do return const_val(0)
		x := p.ctx.plot.vecs[0].re
		acc: complex128
		for i in 0 ..< len(a.v) {
			if i > 0 do acc += (a.v[i] + a.v[i - 1]) * complex((x[i] - x[i - 1]) / 2, 0)
			out[i] = acc
		}
		return {v = out, unit = tcat(unit, "·s") if len(unit) > 0 else ""}
	}
	for x, i in a.v {
		r: complex128
		switch name {
		case "abs", "mag": r = complex(cmplx.abs(x), 0)
		case "sqrt": r = cmplx.sqrt(x)
		case "exp": r = cmplx.exp(x)
		case "ln", "log": r = cmplx.ln(x)
		case "log10": r = cmplx.log10(x)
		case "db": r = complex(20 * math.log10(max(cmplx.abs(x), 1e-300)), 0)
		case "ph", "phase": r = complex(math.to_degrees(cmplx.phase(x)), 0)
		case "re", "real": r = complex(real(x), 0)
		case "im", "imag": r = complex(imag(x), 0)
		case "sin": r = cmplx.sin(x)
		case "cos": r = cmplx.cos(x)
		case "tan": r = cmplx.tan(x)
		case "atan": r = complex(math.atan(real(x)), 0)
		case: return fail(p, fmt.tprintf("unknown function %s()", name))
		}
		out[i] = r
	}
	switch name {
	case "db": unit = "dB"
	case "ph", "phase": unit = "°"
	case "ln", "log", "log10", "exp", "sin", "cos", "tan", "atan": unit = ""
	}
	return {v = out, unit = unit}
}

// Fills {net} {ref} {cur} {pin} into a probe name template.
probe_name :: proc(tmpl, net, ref, cur, pin: string) -> string {
	r := tmpl
	r, _ = strings.replace_all(r, "{net}", net, context.temp_allocator)
	r, _ = strings.replace_all(r, "{ref}", ref, context.temp_allocator)
	r, _ = strings.replace_all(r, "{cur}", cur, context.temp_allocator)
	r, _ = strings.replace_all(r, "{pin}", pin, context.temp_allocator)
	return r
}

@(private = "file")
probe_voltage :: proc(p: ^Parser, net: string) -> Expr_Val {
	if net == "0" || lower(net) == "gnd" do return const_val(0)
	cands := make([dynamic]string, context.temp_allocator)
	if p.ctx.sim != nil do append(&cands, probe_name(p.ctx.sim.voltage, net, "", "", ""))
	append(&cands, tcat("v(", net, ")"), net)
	for c in cands do if v := vec_find(p.ctx.plot, c); v != nil do return vec_val(p, v)
	return fail(p, fmt.tprintf("no voltage for net \"%s\" in this run", net))
}

// I(R1) – a part's current; Ic(Q1), Id(M1) – the current into one pin (by :cur tag or pin name).
@(private = "file")
probe_current :: proc(p: ^Parser, tag, ref: string) -> Expr_Val {
	cands := make([dynamic]string, context.temp_allocator)
	if p.ctx.sch != nil && p.ctx.sim != nil {
		for &c in p.ctx.sch.comps {
			if !strings.equal_fold(c.ref, ref) do continue
			sym := symbol_find(c.sym)
			if sym == nil do break
			for n in current_vector_names(p.ctx.sim, &c, sym, tag) do append(&cands, n)
		}
	}
	append(&cands, tcat("i(", ref, ")"), tcat("i(@", lower(ref), "[i", tag, "])"), tcat(lower(ref), ":flow(br)"), tcat(ref, "#branch"))
	found: ^Vec
	for c in cands do if v := vec_find(p.ctx.plot, c); v != nil {found = v; break}
	// ngspice leaves R, C and L currents at zero in AC: compute them from the pin voltages
	if p.ctx.plot.complex && len(tag) == 0 && (found == nil || vec_all_zero(found)) {
		if v, ok := passive_ac_current(p, ref); ok do return v
	}
	if found != nil do return vec_val(p, found)
	return fail(p, fmt.tprintf("no current I%s(%s) in this run", tag, ref))
}

@(private = "file")
vec_all_zero :: proc(v: ^Vec) -> bool {
	for x in v.re do if x != 0 do return false
	for x in v.im do if x != 0 do return false
	return true
}

// I = (V(A) - V(B)) / Z for a resistor, capacitor or inductor with a plain numeric value.
@(private = "file")
passive_ac_current :: proc(p: ^Parser, ref: string) -> (Expr_Val, bool) {
	s := p.ctx.sch
	if s == nil do return {}, false
	ni := nets_build(s, S.net_prefix)
	for &c, ci in s.comps {
		if !strings.equal_fold(c.ref, ref) do continue
		sym := symbol_find(c.sym)
		if sym == nil || len(sym.pins) != 2 do return {}, false
		kind := upper(sym.prefix)
		if kind != "R" && kind != "C" && kind != "L" do return {}, false
		x, ok := parse_eng(strings.trim_space(c.value))
		if !ok || x == 0 do return {}, false
		err0 := p.ctx.err
		va := probe_voltage(p, ni.names[ni.pin_net[ci][0]])
		vb := probe_voltage(p, ni.names[ni.pin_net[ci][1]])
		if len(p.ctx.err) > len(err0) {
			p.ctx.err = err0
			return {}, false
		}
		f := p.ctx.plot.vecs[0].re
		out := make([]complex128, p.ctx.n, context.temp_allocator)
		for i in 0 ..< p.ctx.n {
			a := va.v[0] if len(va.v) == 1 else va.v[i]
			b := vb.v[0] if len(vb.v) == 1 else vb.v[i]
			w := 2 * math.PI * f[i]
			z: complex128
			switch kind {
			case "R": z = complex(x, 0)
			case "C": z = complex(0, -1 / (w * x)) if w > 0 else complex(1e300, 0)
			case "L": z = complex(0, w * x) if w > 0 else complex(1e-300, 0)
			}
			out[i] = (a - b) / z
		}
		return Expr_Val{v = out, unit = "A"}, true
	}
	return {}, false
}

// Raw vector names that hold the current of a part (tag "") or of one of its pins.
current_vector_names :: proc(sim: ^Simulator_Def, c: ^Comp, sym: ^Symbol, tag: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	ref := c.ref
	lref := lower(ref)
	// pins that name an element (a transformer's windings): that element's current; the part
	// as a whole is its first pin's
	for pd, k in sym.pins {
		if len(pd.element) == 0 do continue
		if len(tag) == 0 ? k != 0 : !(strings.equal_fold(pd.cur, tag) || strings.equal_fold(pd.name, tag)) do continue
		el, _ := strings.replace_all(pd.element, "{ref}", ref, context.temp_allocator)
		lel := lower(el)
		append(&out, probe_name(sim.current, el, el, "", ""), probe_name(sim.current, lel, lel, "", ""), tcat(lel, "#branch"))
		// VACASK: the sense source at the pin
		pin := sense_pin_name(pd.name)
		append(&out, probe_name(sim.pin_current, ref, ref, pd.cur, pin), probe_name(sim.pin_current, lref, lref, pd.cur, pin))
		return out[:]
	}
	if len(tag) == 0 {
		if sym.probe == "source" {
			append(&out, probe_name(sim.source_current, ref, ref, "", ""), probe_name(sim.source_current, lref, lref, "", ""))
		} else {
			pin := sense_pin_name(sym.pins[0].name) if len(sym.pins) > 0 else ""
			append(&out, probe_name(sim.current, ref, ref, sym.cur, pin), probe_name(sim.current, lref, lref, sym.cur, pin))
			// a part that is a subcircuit instance: the sense source spicy puts at its pin
			if len(pin) > 0 do append(&out, tcat("i(vsns_", lref, "_", pin, ")"))
		}
		return out[:]
	}
	for pd in sym.pins {
		if strings.equal_fold(pd.cur, tag) || strings.equal_fold(pd.name, tag) {
			pin := sense_pin_name(pd.name)
			append(&out, probe_name(sim.pin_current, ref, ref, pd.cur, pin), probe_name(sim.pin_current, lref, lref, pd.cur, pin))
			append(&out, tcat("i(vsns_", lref, "_", pin, ")"))
		}
	}
	return out[:]
}

parse_f :: proc(s: string) -> f64 {
	v, _ := strconv.parse_f64(s)
	return v
}
