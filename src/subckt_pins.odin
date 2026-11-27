package spicy

import "core:fmt"
import "core:strings"

// Subcircuits as part models: a part whose value names a .subckt becomes an X instance,
// its pins matched to the subcircuit's ports by name (from "* TERMINALS: D G S" comments, the
// port names, or the device the subcircuit holds) or else in the order of the symbol's own
// netlist line.

// Fills ports, pins (terminal names) and dev of a subcircuit entry. lines[i] is its .subckt line.
subckt_info :: proc(e: ^Lib_Entry, lines: []string, i: int) {
	head := strings.trim_space(lines[i])
	for next := i + 1; next < len(lines) && strings.has_prefix(strings.trim_space(lines[next]), "+"); next += 1 {
		head = tcat(head, " ", strings.trim_space(lines[next])[1:])
	}
	f := strings.fields(head, context.temp_allocator)
	ports := make([dynamic]string)
	for t in f[2:] {
		lt := lower(t)
		if lt == "params:" || lt == "param:" || lt == "params" || strings.contains(t, "=") do break
		append(&ports, strings.clone(t))
	}
	e.ports = ports[:]
	// terminal names from a comment: "* TERMINALS : D G S", "* pins: anode cathode",
	// "*Pin order: Drain=10, Gate=50", "*PIN_ORDER" over lines of "* 1=E1  6=C1", "*PINS C B E",
	// or a bare "*  C B E" of terminal names
	from := max(0, i - 12)
	body := split_lines(e.text)
	comments := make([dynamic]string, context.temp_allocator)
	append(&comments, ..lines[from:i])
	append(&comments, ..body)
	e.pins = e.ports
	is_comment :: proc(l: string) -> bool {
		t := strings.trim_space(l)
		return len(t) >= 2 && (t[0] == '*' || t[0] == ';')
	}
	tokens_of :: proc(s: string) -> []string {
		r, _ := strings.replace_all(s, ",", " ", context.temp_allocator)
		out := make([dynamic]string, context.temp_allocator)
		for x in strings.fields(r, context.temp_allocator) {
			y := strings.trim_right(x, ".;")
			if len(y) > 0 do append(&out, y)
		}
		return out[:]
	}
	all_pairs :: proc(toks: []string) -> bool {
		if len(toks) == 0 do return false
		for x in toks do if eq := strings.index_byte(x, '='); eq <= 0 || eq == len(x) - 1 do return false
		return true
	}
	ROLES :: []string{"d", "g", "s", "c", "b", "e", "a", "k", "bulk"}
	pins_loop: for l, li in comments {
		if !is_comment(l) do continue
		w := strings.trim_left(strings.trim_space(l), "*; \t")
		low := lower(w)
		rest := ""
		keyed := false
		for kw in ([]string{"pin_order", "pin order", "pins", "pin", "terminals", "terminal", "nodes", "node"}) {
			if k := strings.index(low, kw); k >= 0 {
				rest = strings.trim_left(w[k + len(kw):], " \t:-")
				keyed = true
				break
			}
		}
		toks := make([dynamic]string, context.temp_allocator)
		append(&toks, ..tokens_of(rest if keyed else w))
		if keyed && (len(toks) == 0 || all_pairs(toks[:])) {
			// the pairs may go on over the next comment lines
			for m := li + 1; m < len(comments) && is_comment(comments[m]); m += 1 {
				more := tokens_of(strings.trim_left(strings.trim_space(comments[m]), "*; \t"))
				if !all_pairs(more) do break
				append(&toks, ..more)
			}
		}
		// "Drain=10" or "1=E1": one side is a port, the other its name
		if all_pairs(toks[:]) && len(toks) == len(ports) {
			names := make([]string, len(ports))
			ok := true
			for x in toks {
				eq := strings.index_byte(x, '=')
				a, b := x[:eq], x[eq + 1:]
				k, nm := -1, ""
				for p, j in ports {
					if strings.equal_fold(p, b) {k, nm = j, a}
					else if strings.equal_fold(p, a) {k, nm = j, b}
				}
				if k < 0 || len(names[k]) > 0 {ok = false; break}
				names[k] = strings.clone(nm)
			}
			if ok {
				e.pins = names
				break pins_loop
			}
			for n in names do delete(n)
			delete(names)
			continue
		}
		if len(toks) != len(ports) || len(toks) == 0 do continue
		if !keyed {
			// a bare comment: only terminal names ("*              C B E")
			for x in toks {
				known := false
				for r in ROLES do if pin_role(strings.trim_right(x, "0123456789")) == r do known = true
				if !known do continue pins_loop
			}
		}
		names := make([]string, len(toks))
		for x, j in toks do names[j] = strings.clone(x)
		e.pins = names
		break
	}
	subckt_finish(e, nil)
}

// The subcircuit's device, and for a transistor with numbered ports their names from its
// circuit. file_models: the types of the .model cards of the same file (a subcircuit may use
// one defined outside it); nil for none.
subckt_finish :: proc(e: ^Lib_Entry, file_models: map[string]string) {
	if len(e.dev) == 0 {
		delete(e.dev)
		e.dev = strings.clone(subckt_device(e.text, file_models))
	}
	if (e.dev == "NPN" || e.dev == "PNP") && raw_equal(e.pins, e.ports) {
		if len(e.ports) == 3 {
			if r := bjt_port_roles(e); r != nil {e.pins = r; return}
		}
		if r := bjt_port_names(e); r != nil do e.pins = r
	}
	if e.dev == "D" && len(e.ports) == 2 && raw_equal(e.pins, e.ports) {
		if r := diode_port_roles(e); r != nil do e.pins = r
	}
	// "PIN_ORDER C A" on a diode: C is the cathode, not a collector
	if e.dev == "D" && len(e.pins) == 2 {
		r0, r1 := pin_role(e.pins[0]), pin_role(e.pins[1])
		if (r0 == "c" && r1 == "a") || (r0 == "a" && r1 == "c") {
			out := make([]string, 2)
			for p, k in e.pins do out[k] = strings.clone("K" if pin_role(p) == "c" else p)
			e.pins = out
		}
	}
}

// A and K for a two-port diode subcircuit with numbered ports: from the first diode that sits
// across the two ports (directly or through a series R or L). nil when none does (a
// bidirectional TVS: two diodes back to back).
@(private = "file")
diode_port_roles :: proc(e: ^Lib_Entry) -> []string {
	lines := spice_lines(e.text)
	for joined in ([]bool{false, true}) {
		g := node_groups_make()
		if joined {
			// series leads (L) first, then resistors; never one that would join the two ports
			node_groups_join_series(&g, lines, "l", e.ports[0], e.ports[1])
			node_groups_join_series(&g, lines, "r", e.ports[0], e.ports[1])
		}
		p0, p1 := node_group(&g, e.ports[0]), node_group(&g, e.ports[1])
		if p0 == p1 do continue
		for l, n in lines {
			if n == 0 || (l[0] | 0x20) != 'd' do continue
			f := strings.fields(l, context.temp_allocator)
			if len(f) < 3 do continue
			a, k := node_group(&g, f[1]), node_group(&g, f[2])
			out := make([]string, 2)
			if a == p0 && k == p1 {out[0], out[1] = strings.clone("A"), strings.clone("K"); return out}
			if a == p1 && k == p0 {out[0], out[1] = strings.clone("K"), strings.clone("A"); return out}
			delete(out)
		}
	}
	return nil
}

// The terminal names of a transistor subcircuit's three ports, from the transistor terminals
// each one reaches (directly or through a resistor or inductor in series): in a Darlington
// the collector port meets only collectors, the base port the first base, the emitter port
// an emitter. nil when that does not give one of C, B, E to each port.
@(private = "file")
bjt_port_roles :: proc(e: ^Lib_Entry) -> []string {
	lines := spice_lines(e.text)
	for joined in ([]bool{false, true}) {
		g := node_groups_make()
		if joined do node_groups_join_series(&g, lines, "rl")
		seen := make([]u8, 3, context.temp_allocator) // bit 1 c, 2 b, 4 e
		for l, n in lines {
			if n == 0 || (l[0] | 0x20) != 'q' do continue
			f := strings.fields(l, context.temp_allocator)
			if len(f) < 4 do continue
			for t, k in ([]u8{1, 2, 4}) {
				net := node_group(&g, f[1 + k])
				for p, j in e.ports do if node_group(&g, p) == net do seen[j] |= t
			}
		}
		names := [3]string{}
		used: u8 = 0
		ok := true
		for x, j in seen {
			switch x {
			case 1: names[j] = "C"
			case 2: names[j] = "B"
			case 4: names[j] = "E"
			case: ok = false
			}
			if !ok do break
			if used & x != 0 {ok = false; break}
			used |= x
		}
		if ok && used == 7 {
			out := make([]string, 3)
			for nm, j in names do out[j] = strings.clone(nm)
			return out
		}
	}
	return nil
}

// Port names of a subcircuit of several transistors (a dual BJT, "1 2 3 4 5 6"): each port
// meets one terminal of one transistor (directly or through a series R or L), named by the
// terminal and the transistor's number in the subcircuit: E1 B1 C2 …
@(private = "file")
bjt_port_names :: proc(e: ^Lib_Entry) -> []string {
	lines := spice_lines(e.text)
	for joined in ([]bool{false, true}) {
		g := node_groups_make()
		if joined do node_groups_join_series(&g, lines, "rl")
		names := make([]string, len(e.ports), context.temp_allocator)
		hits := make([]int, len(e.ports), context.temp_allocator)
		q := 0
		for l, n in lines {
			if n == 0 || (l[0] | 0x20) != 'q' do continue
			f := strings.fields(l, context.temp_allocator)
			if len(f) < 4 do continue
			q += 1
			for t, k in ([]string{"C", "B", "E"}) {
				net := node_group(&g, f[1 + k])
				for p, j in e.ports do if node_group(&g, p) == net {
					hits[j] += 1
					names[j] = fmt.tprintf("%s%d", t, q)
				}
			}
		}
		ok := q > 1
		for h in hits do if h != 1 do ok = false
		if ok {
			out := make([]string, len(names))
			for nm, j in names do out[j] = strings.clone(nm)
			return out
		}
	}
	return nil
}

// Nodes of a subcircuit joined into groups (union-find over node names, any case): the nodes
// that series elements connect count as one.
@(private = "file")
Node_Groups :: struct {
	parent: map[string]string,
}

@(private = "file")
node_groups_make :: proc() -> Node_Groups {return {parent = make(map[string]string, 16, context.temp_allocator)}}

// The group a node belongs to (its root name).
@(private = "file")
node_group :: proc(g: ^Node_Groups, node: string) -> string {
	r := lower(node)
	for {
		p, ok := g.parent[r]
		if !ok || p == r do return r
		r = p
	}
}

// Joins the two nodes of every element whose letter is in letters ("rl": resistors and
// inductors), except one that would join apart_a and apart_b.
@(private = "file")
node_groups_join_series :: proc(g: ^Node_Groups, lines: []string, letters: string, apart_a := "", apart_b := "") {
	for l, n in lines {
		if n == 0 || strings.index_byte(letters, l[0] | 0x20) < 0 do continue
		f := strings.fields(l, context.temp_allocator)
		if len(f) < 3 do continue
		a, b := node_group(g, f[1]), node_group(g, f[2])
		if len(apart_a) > 0 {
			q0, q1 := node_group(g, apart_a), node_group(g, apart_b)
			if (a == q0 && b == q1) || (a == q1 && b == q0) do continue
		}
		if a != b do g.parent[a] = b
	}
}

@(private = "file")
raw_equal :: proc(a, b: []string) -> bool {return len(a) == len(b) && (len(a) == 0 || raw_data(a) == raw_data(b))}

// The main device of a subcircuit (NMOS, PMOS, NPN, PNP, NJF, PJF, D) from its first
// transistor and the model that transistor uses; "" when there is none.
@(private = "file")
subckt_device :: proc(text: string, file_models: map[string]string) -> string {
	types := make(map[string]string, 8, context.temp_allocator)
	lines := spice_lines(text)
	for l in lines {
		low := lower(l)
		if !strings.has_prefix(low, ".model") do continue
		f := strings.fields(replace_parens(l), context.temp_allocator)
		if len(f) < 3 do continue
		t := upper(f[2])
		if t == "VDMOS" do t = "PMOS" if strings.contains(low, "pchan") else "NMOS"
		types[lower(f[1])] = t
	}
	diode := false
	for l, n in lines {
		if n == 0 || len(l) == 0 do continue
		switch l[0] {
		case 'M', 'm', 'Q', 'q', 'J', 'j':
			f := strings.fields(replace_parens(l), context.temp_allocator)
			for x in f[1:] {
				if t, ok := types[lower(x)]; ok do return t
				if t, ok := file_models[lower(x)]; ok do return t
				if e := lib_find(x); e != nil && e.kind != "subckt" do return e.kind
			}
		case 'D', 'd':
			diode = true
		}
	}
	return "D" if diode else ""
}

// The role of a pin or terminal name: "drain" and "D" are both "d" …
pin_role :: proc(s: string) -> string {
	l := lower(strings.trim_space(s))
	switch l {
	case "drain": return "d"
	case "gate": return "g"
	case "source": return "s"
	case "bulk", "body", "sub", "substrate": return "bulk"
	case "collector", "col": return "c"
	case "base": return "b"
	case "emitter", "emit", "emtr": return "e"
	case "anode", "+": return "a"
	case "cathode", "-": return "k"
	}
	return l
}

// What an op-amp terminal name means: "inp" (non-inverting input), "inn", "out", "vp"
// (positive supply), "vn", or "" (none of them). IN+, +IN, NONINV, V+, VCC, VS- …
opamp_port :: proc(name: string) -> string {
	switch sanitize(strings.trim_space(name)) {
	case "inp", "pin", "in_p", "ip", "vinp", "pvin", "nonin", "noninv", "non_inv", "ninv", "inplus", "in_plus", "plus": return "inp"
	case "inn", "nin", "in_n", "im", "vinn", "nvin", "inv", "inm", "inminus", "in_minus", "minus": return "inn"
	case "out", "vout", "vo", "o", "output", "op_out", "outa": return "out"
	case "vp", "vcc", "vdd", "vsp", "pvs", "vpos", "v_p", "vplus", "vs_p", "pvcc", "vccp", "vs": return "vp"
	case "vn", "vee", "vss", "vsn", "nvs", "vneg", "v_n", "vminus", "vs_n", "nvcc", "gnd": return "vn"
	}
	return ""
}

// Symbol pin indices in the order they first appear in the symbol's SPICE line.
@(private = "file")
template_pins :: proc(sym: ^Symbol) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	t := sym.spice
	for i := 0; i < len(t); i += 1 {
		if t[i] != '{' do continue
		j := strings.index_byte(t[i:], '}')
		if j < 0 do break
		key := t[i + 1:i + j]
		for p, k in sym.pins do if p.name == key {
			seen := false
			for x in out do if x == k do seen = true
			if !seen do append(&out, k)
		}
		i += j
	}
	return out[:]
}

// For every port of the subcircuit, the symbol pin connected to it.
subckt_pin_map :: proc(e: ^Lib_Entry, sym: ^Symbol, c: ^Comp) -> (order: []int, err: string) {
	n := len(e.ports)
	order = make([]int, n, context.temp_allocator)
	names := e.pins
	explicit := comp_attr(c, "pinmap")
	if len(explicit) > 0 {
		names = strings.fields(explicit, context.temp_allocator)
		if len(names) != n do return nil, fmt.tprintf("the pinmap attribute must name %d pins (one per port of %s: %s)", n, e.name, strings.join(e.ports, " ", context.temp_allocator))
	}
	has_role :: proc(sym: ^Symbol, r: string) -> bool {
		for p in sym.pins do if pin_role(p.name) == r do return true
		return false
	}
	ok := true
	for t, i in names {
		r := pin_role(t)
		k := -1
		for p, j in sym.pins do if pin_role(p.name) == r {k = j; break}
		// a MOSFET's bulk terminal goes to the source when the symbol has no bulk pin
		if k < 0 && (r == "bulk" || r == "b") && !has_role(sym, "b") && !has_role(sym, "bulk") {
			for p, j in sym.pins do if pin_role(p.name) == "s" do k = j
		}
		if k < 0 {
			ok = false
			if len(explicit) > 0 do return nil, fmt.tprintf("pinmap: \"%s\" is not a pin of the symbol (%s)", t, pin_list(sym))
			break
		}
		order[i] = k
	}
	if ok do return order, ""
	tp := template_pins(sym)
	if len(tp) == n {
		copy(order, tp)
		return order, ""
	}
	return nil, fmt.tprintf("subcircuit %s has %d ports (%s) and the symbol %d pins (%s); set the attribute pinmap to the symbol pins in port order", e.name, n, strings.join(e.ports, " ", context.temp_allocator), len(sym.pins), pin_list(sym))
}

@(private = "file")
pin_list :: proc(sym: ^Symbol) -> string {
	names := make([dynamic]string, context.temp_allocator)
	for p in sym.pins do append(&names, p.name)
	return strings.join(names[:], " ", context.temp_allocator)
}

// The subcircuit a part's value names, when the part becomes an X instance of it.
comp_subckt :: proc(c: ^Comp, sym: ^Symbol, local: []Lib_Entry) -> ^Lib_Entry {
	if sym.kind != .Part do return nil
	f := strings.fields(c.value, context.temp_allocator)
	if len(f) == 0 do return nil
	e := model_lookup(f[0], local)
	if e == nil || e.kind != "subckt" do return nil
	// a symbol whose own line already calls a subcircuit with as many pins keeps its line
	t := strings.trim_space(sym.spice)
	if len(t) > 0 && (t[0] == 'X' || t[0] == 'x') && len(template_pins(sym)) == len(e.ports) && len(comp_attr(c, "pinmap")) == 0 do return nil
	return e
}

// Model names a part can use (part editor): library and schematic models of the symbol's
// types, and subcircuits of the same device or with as many ports as the symbol has pins.
models_for_symbol :: proc(sym: ^Symbol, local: []Lib_Entry) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	seen := make(map[string]bool, 16, context.temp_allocator)
	add :: proc(out: ^[dynamic]string, seen: ^map[string]bool, e: ^Lib_Entry, sym: ^Symbol) {
		if seen[e.name] do return
		if e.kind == "subckt" {
			fits := false
			for k in sym.models do if e.dev == k || (k == "VDMOS" && (e.dev == "NMOS" || e.dev == "PMOS") && sym_dev_matches(sym, e.dev)) do fits = true
			if len(sym.models) == 0 && len(e.ports) == len(sym.pins) do fits = true
			if !fits do return
		} else {
			fits := false
			for k in sym.models do if e.kind == k do fits = true
			if !fits do return
		}
		seen[e.name] = true
		append(out, entry_display_name(e))
	}
	for &e in local do add(&out, &seen, &e, sym)
	for &e in model_lib do add(&out, &seen, &e, sym)
	return out[:]
}

@(private = "file")
sym_dev_matches :: proc(sym: ^Symbol, dev: string) -> bool {
	for k in sym.models do if k == dev do return true
	return false
}
