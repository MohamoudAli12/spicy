package spicy

import "core:fmt"
import "core:math"
import "core:strings"

// Non-ideal values of the standard parts, kept as the part's attributes and edited in its
// dialog: series resistance and inductance, parallel resistance and capacitance, a rating
// that is checked after each run, and a tolerance. Empty (or 0) means ideal. A part with
// any of them is written to the netlist as its own element (same name, so .meas and the
// probes find it) with the extra elements around it, and a 0 V source at its first pin so
// I(ref) is the current at the pins, as measured on a real part.

Nonideal_Role :: enum u8 {
	Series_R, // between the first pin and the element
	Series_L,
	Shunt_R, // across the element itself (a capacitor's leakage)
	Parallel_R, // across the whole part (an inductor's core loss)
	Parallel_C,
	Rating_V, // max |voltage across the part|
	Rating_I, // max |current|
	Rating_P, // max |power|
	Note, // kept with the part, not simulated (tolerance)
}

Nonideal :: struct {
	key, label, hint: string,
	role:             Nonideal_Role,
}

NONIDEAL_R := [?]Nonideal {
	{"lser", "Series inductance", "H, e.g. 5n (leads, wirewound)", .Series_L},
	{"cpar", "Parallel capacitance", "F, e.g. 0.3p", .Parallel_C},
	{"pmax", "Power rating", "W, e.g. 250m – checked after a run", .Rating_P},
	{"tol", "Tolerance", "%, e.g. 1 – noted, not simulated", .Note},
}
NONIDEAL_C := [?]Nonideal {
	{"esr", "ESR", "Ω, e.g. 50m", .Series_R},
	{"esl", "ESL", "H, e.g. 2n", .Series_L},
	{"rleak", "Leakage resistance", "Ω, e.g. 100Meg", .Shunt_R},
	{"vmax", "Voltage rating", "V, e.g. 50 – checked after a run", .Rating_V},
	{"tol", "Tolerance", "%, e.g. 10 – noted, not simulated", .Note},
}
NONIDEAL_L := [?]Nonideal {
	{"dcr", "DC resistance", "Ω, e.g. 20m", .Series_R},
	{"cpar", "Winding capacitance", "F, e.g. 5p (sets the self-resonance)", .Parallel_C},
	{"rpar", "Core loss resistance", "Ω, e.g. 10k", .Parallel_R},
	{"imax", "Current rating", "A, e.g. 2 (saturation) – checked after a run", .Rating_I},
	{"tol", "Tolerance", "%, e.g. 20 – noted, not simulated", .Note},
}
NONIDEAL_V := [?]Nonideal {
	{"rser", "Internal resistance", "Ω, e.g. 0.1", .Series_R},
	{"imax", "Current rating", "A – checked after a run", .Rating_I},
}
NONIDEAL_I := [?]Nonideal {
	{"rpar", "Output resistance", "Ω, e.g. 1Meg", .Parallel_R},
	{"vmax", "Compliance voltage", "V – checked after a run", .Rating_V},
}

// The non-ideal values a symbol offers: the standard two-pin R, C, L and V / I sources
// (and symbols made :like them), not subcircuits or other parts.
nonideal_params :: proc(sym: ^Symbol) -> []Nonideal {
	if sym == nil || sym.kind != .Part || len(sym.pins) != 2 do return nil
	switch upper(sym.prefix) {
	case "R": if sym.editor == "text" do return NONIDEAL_R[:]
	case "C": if sym.editor == "text" do return NONIDEAL_C[:]
	case "L": if sym.editor == "text" do return NONIDEAL_L[:]
	case "V": if sym.editor == "source" do return NONIDEAL_V[:]
	case "I": if sym.editor == "source" do return NONIDEAL_I[:]
	}
	return nil
}

// A non-ideal value of a part, when it is set and not 0.
nonideal_value :: proc(c: ^Comp, key: string) -> (string, bool) {
	v := strings.trim_space(comp_attr(c, key))
	if len(v) == 0 do return "", false
	if x, ok := parse_eng(v); ok && x == 0 do return "", false
	return v, true
}

// Whether the part has non-ideal values that change its netlist.
nonideal_active :: proc(c: ^Comp, sym: ^Symbol) -> bool {
	for p in nonideal_params(sym) {
		if p.role >= .Rating_V do continue
		if _, ok := nonideal_value(c, p.key); ok do return true
	}
	return false
}

// Whether the part named ref has non-ideal values that change its netlist.
comp_nonideal :: proc(sch: ^Schematic, ref: string) -> bool {
	if sch == nil do return false
	for &c in sch.comps do if strings.equal_fold(c.ref, ref) do return nonideal_active(&c, symbol_find(c.sym))
	return false
}

// The netlist lines of a part with non-ideal values (SPICE, or VACASK when vacask), or
// false when it has none. nodes are the part's pin nets (for VACASK, after the sense source
// the caller puts at the first pin). needs gets the symbols whose VACASK devices it uses.
nonideal_lines :: proc(nl: ^Netlist, c: ^Comp, sym: ^Symbol, nodes: []string, vacask: bool, needs: ^[dynamic]string = nil) -> (string, bool) {
	if !nonideal_active(c, sym) do return "", false
	b := strings.builder_make(context.temp_allocator)
	lref := lower(c.ref)
	a, z := nodes[0], nodes[1]
	is_src := sym.editor == "source"
	// SPICE: the 0 V source that measures the current at the first pin (VACASK has one already;
	// a V source is its own current)
	if !vacask && !is_src {
		sn := fmt.tprintf("n_%s_s", lref)
		fmt.sbprintf(&b, "%s %s %s 0\n", sense_source(c.ref, sym.pins[0].name), a, sn)
		a = sn
	}
	elem :: proc(b: ^strings.Builder, kind: u8, ref, key, n1, n2, val: string, vacask: bool, needs: ^[dynamic]string) {
		if vacask {
			model, param, sym := "spicy_r", "r", "res"
			if kind == 'L' do model, param, sym = "spicy_l", "l", "ind"
			if kind == 'C' do model, param, sym = "spicy_c", "c", "cap"
			fmt.sbprintf(b, "%c%s_%s (%s %s) %s %s=%s\n", kind + ('a' - 'A'), lower(ref), key, n1, n2, model, param, vacask_value(val))
			if needs != nil do append(needs, sym)
		} else {
			fmt.sbprintf(b, "%c%s_%s %s %s %s\n", kind, ref, key, n1, n2, val)
		}
	}
	// the series chain from the first pin to the element
	top := a
	k := 0
	for p in nonideal_params(sym) {
		if p.role != .Series_R && p.role != .Series_L do continue
		v, ok := nonideal_value(c, p.key)
		if !ok do continue
		k += 1
		nx := fmt.tprintf("n_%s_%d", lref, k)
		elem(&b, 'R' if p.role == .Series_R else 'L', c.ref, p.key, top, nx, v, vacask, needs)
		top = nx
	}
	// the element itself, between the end of the chain and the second pin
	inner := make([]string, 2, context.temp_allocator)
	inner[0], inner[1] = top, z
	tmpl := sym.vacask.line if vacask else sym.spice
	strings.write_string(&b, fill_template(nl, tmpl, c, sym, inner, vacask))
	strings.write_byte(&b, '\n')
	for p in nonideal_params(sym) {
		v, ok := nonideal_value(c, p.key)
		if !ok do continue
		#partial switch p.role {
		case .Shunt_R: elem(&b, 'R', c.ref, p.key, top, z, v, vacask, needs)
		case .Parallel_R: elem(&b, 'R', c.ref, p.key, a, z, v, vacask, needs)
		case .Parallel_C: elem(&b, 'C', c.ref, p.key, a, z, v, vacask, needs)
		}
	}
	return strings.trim_right(strings.to_string(b), "\n"), true
}

// Compares the parts' ratings with the run's results (transient, DC sweep, operating
// point) and adds a warning for each one exceeded.
ratings_check :: proc(r: ^Run, sch: ^Schematic, sim: ^Simulator_Def) {
	if len(r.plots) == 0 do return
	ni := nets_build(sch, S.net_prefix)
	for &c, ci in sch.comps {
		sym := symbol_find(c.sym)
		params := nonideal_params(sym)
		if len(params) == 0 || ci >= len(ni.pin_net) do continue
		na, nb := ni.names[ni.pin_net[ci][0]], ni.names[ni.pin_net[ci][1]]
		for p in params {
			if p.role != .Rating_V && p.role != .Rating_I && p.role != .Rating_P do continue
			v, ok := nonideal_value(&c, p.key)
			if !ok do continue
			limit, lok := parse_eng(v)
			if !lok {
				append(&r.warnings, strings.clone(fmt.tprintf("%s: the %s \"%s\" is not a number", c.ref, lower(p.label), v)))
				continue
			}
			expr, unit, what := "", "", ""
			switch p.role {
			case .Rating_V: expr, unit, what = fmt.tprintf("V(%s,%s)", na, nb), "V", "across it"
			case .Rating_I: expr, unit, what = fmt.tprintf("I(%s)", c.ref), "A", "through it"
			case .Rating_P: expr, unit, what = fmt.tprintf("V(%s,%s)*I(%s)", na, nb, c.ref), "W", "in it"
			case .Series_R, .Series_L, .Shunt_R, .Parallel_R, .Parallel_C, .Note:
			}
			worst, at, plot_name := 0.0, 0.0, ""
			for &pl in r.plots {
				k := plot_kind(&pl)
				if k != "tran" && k != "dc" && k != "op" do continue
				res := expr_eval(expr, &pl, sch, sim)
				defer {delete(res.re); delete(res.im); delete(res.unit); delete(res.err)}
				if len(res.err) > 0 do continue
				for y, i in res.re do if abs(y) > worst {
					worst = abs(y)
					at = pl.vecs[0].re[i] if k != "op" && len(pl.vecs) > 0 && i < len(pl.vecs[0].re) else math.nan_f64()
					plot_name = pl.name
				}
			}
			if worst <= abs(limit) do continue
			where_ := "" if math.is_nan(at) else fmt.tprintf(" at %s", fmt_eng(at, "s" if strings.contains(lower(plot_name), "transient") else "", 4))
			append(&r.warnings, strings.clone(fmt.tprintf("%s: %s %s%s (%s), above its %s of %s", c.ref, fmt_eng(worst, unit, 4), what, where_, plot_name, lower(p.label), fmt_eng(abs(limit), unit, 4))))
		}
	}
}
