package spicy

import "core:fmt"
import "core:log"
import os "core:os"
import "core:strings"

// SPICE models and subcircuits beyond the built-in library:
//
// - subcircuits as part models: a part whose value names a .subckt becomes an X instance,
//   its pins matched to the subcircuit's ports by name ("* TERMINALS: D G S" comments or the
//   port names) or else in the order of the symbol's own netlist line;
// - the models a schematic defines itself (.model / .subckt directives, .include / .lib files);
// - VACASK: SPICE subcircuits translated into VACASK subcircuits;
// - importing a model file: it is copied into the data folder's models/ and every
//   subcircuit in it gets a symbol (a transistor or diode symbol when the device is
//   recognised, else a box with one pin per port).

MODEL_EXTS := []string{"lib", "mod", "sub", "subckt", "cir", "inc", "spice", "spi", "sp", "model", "txt", "ckt"}

user_models_dir :: proc() -> string {return path_join(data_dir(), "models")}

// Model files in the data folder's models/ (imported ones), read after the built-in library.
models_load_user :: proc() {
	d := user_models_dir()
	if !dir_exists(d) do return
	_, files := list_dir(d, MODEL_EXTS)
	for f in files {
		p := strings.clone(path_join(d, f))
		text, ok := read_text(p)
		if !ok do continue
		parse_lib(text, p)
	}
}

// ---------------------------------------------------------------------------
// Subcircuit ports, pin names and device

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

// Whether a symbol is the plain box an earlier import made, never edited: the box this import
// would make with the same pin names is the same. Such a box gives way to a better symbol
// (pins spicy can now name: a diode, a transistor).
@(private = "file")
untouched_box :: proc(e: ^Lib_Entry, old: ^Symbol, name, stem: string) -> bool {
	if len(old.like) > 0 || len(old.pins) != len(e.ports) do return false
	tmp := e^
	pins := make([]string, len(old.pins), context.temp_allocator)
	for p, k in old.pins do pins[k] = p.name
	tmp.pins = pins
	box := auto_symbol(&tmp, name, stem)
	if strings.contains(box, ":like") do return false
	v, err := edn_parse(box)
	if len(err) > 0 do return false
	same := lower(edn_to_string(v, context.temp_allocator)) == lower(old.edn) // pin labels keep their case
	if !same do return false
	// and a better one is now made
	return strings.contains(auto_symbol(e, name, stem), ":like")
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
	lines := logical_lines(e.text)
	parent := make(map[string]string, 16, context.temp_allocator)
	find :: proc(parent: ^map[string]string, x: string) -> string {
		r := x
		for {
			p, ok := parent[r]
			if !ok || p == r do return r
			r = p
		}
	}
	for joined in ([]bool{false, true}) {
		clear(&parent)
		if joined {
			// series leads (L) first, then resistors; never one that would join the two ports
			for kind in ([]u8{'l', 'r'}) do for l, n in lines {
				if n == 0 || len(l) == 0 || l[0] | 0x20 != kind do continue
				f := strings.fields(l, context.temp_allocator)
				if len(f) < 3 do continue
				a, b := find(&parent, lower(f[1])), find(&parent, lower(f[2]))
				q0, q1 := find(&parent, lower(e.ports[0])), find(&parent, lower(e.ports[1]))
				if (a == q0 && b == q1) || (a == q1 && b == q0) do continue
				if a != b do parent[a] = b
			}
		}
		p0, p1 := find(&parent, lower(e.ports[0])), find(&parent, lower(e.ports[1]))
		if p0 == p1 do continue
		for l, n in lines {
			if n == 0 || len(l) == 0 || (l[0] != 'D' && l[0] != 'd') do continue
			f := strings.fields(l, context.temp_allocator)
			if len(f) < 3 do continue
			a, k := find(&parent, lower(f[1])), find(&parent, lower(f[2]))
			out := make([]string, 2)
			if a == p0 && k == p1 {out[0], out[1] = strings.clone("A"), strings.clone("K"); return out}
			if a == p1 && k == p0 {out[0], out[1] = strings.clone("K"), strings.clone("A"); return out}
			delete(out)
		}
	}
	return nil
}

@(private = "file")
raw_equal :: proc(a, b: []string) -> bool {return len(a) == len(b) && (len(a) == 0 || raw_data(a) == raw_data(b))}

// The terminal names of a transistor subcircuit's three ports, from the transistor terminals
// each one reaches (directly or through a resistor or inductor in series): in a Darlington
// the collector port meets only collectors, the base port the first base, the emitter port
// an emitter. nil when that does not give one of C, B, E to each port.
@(private = "file")
bjt_port_roles :: proc(e: ^Lib_Entry) -> []string {
	lines := logical_lines(e.text)
	// nets joined through R and L elements
	parent := make(map[string]string, 16, context.temp_allocator)
	find :: proc(parent: ^map[string]string, x: string) -> string {
		r := x
		for {
			p, ok := parent[r]
			if !ok || p == r do return r
			r = p
		}
	}
	for joined in ([]bool{false, true}) {
		clear(&parent)
		if joined {
			for l, n in lines {
				if n == 0 || len(l) == 0 do continue
				if l[0] != 'R' && l[0] != 'r' && l[0] != 'L' && l[0] != 'l' do continue
				f := strings.fields(l, context.temp_allocator)
				if len(f) < 3 do continue
				a, b := find(&parent, lower(f[1])), find(&parent, lower(f[2]))
				if a != b do parent[a] = b
			}
		}
		seen := make([]u8, 3, context.temp_allocator) // bit 1 c, 2 b, 4 e
		for l, n in lines {
			if n == 0 || len(l) == 0 || (l[0] != 'Q' && l[0] != 'q') do continue
			f := strings.fields(l, context.temp_allocator)
			if len(f) < 4 do continue
			for t, k in ([]u8{1, 2, 4}) {
				net := find(&parent, lower(f[1 + k]))
				for p, j in e.ports do if find(&parent, lower(p)) == net do seen[j] |= t
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
	lines := logical_lines(e.text)
	parent := make(map[string]string, 16, context.temp_allocator)
	find :: proc(parent: ^map[string]string, x: string) -> string {
		r := x
		for {
			p, ok := parent[r]
			if !ok || p == r do return r
			r = p
		}
	}
	for joined in ([]bool{false, true}) {
		clear(&parent)
		if joined {
			for l, n in lines {
				if n == 0 || len(l) == 0 do continue
				if l[0] != 'R' && l[0] != 'r' && l[0] != 'L' && l[0] != 'l' do continue
				f := strings.fields(l, context.temp_allocator)
				if len(f) < 3 do continue
				a, b := find(&parent, lower(f[1])), find(&parent, lower(f[2]))
				if a != b do parent[a] = b
			}
		}
		names := make([]string, len(e.ports), context.temp_allocator)
		hits := make([]int, len(e.ports), context.temp_allocator)
		q := 0
		for l, n in lines {
			if n == 0 || len(l) == 0 || (l[0] != 'Q' && l[0] != 'q') do continue
			f := strings.fields(l, context.temp_allocator)
			if len(f) < 4 do continue
			q += 1
			for t, k in ([]string{"C", "B", "E"}) {
				net := find(&parent, lower(f[1 + k]))
				for p, j in e.ports do if find(&parent, lower(p)) == net {
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

// The main device of a subcircuit (NMOS, PMOS, NPN, PNP, NJF, PJF, D) from its first
// transistor and the model that transistor uses; "" when there is none.
@(private = "file")
subckt_device :: proc(text: string, file_models: map[string]string) -> string {
	types := make(map[string]string, 8, context.temp_allocator)
	lines := logical_lines(text)
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

// The lines of a SPICE text with "+" continuation lines joined and blank lines dropped.
logical_lines :: proc(text: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	last := -1 // the line a "+" line continues: comment lines may come between
	for raw in split_lines(text) {
		t := strings.trim_space(raw)
		if len(t) == 0 do continue
		if t[0] == '+' && last >= 0 {
			out[last] = tcat(out[last], " ", strings.trim_space(t[1:]))
			continue
		}
		if t[0] != '*' do last = len(out)
		append(&out, t)
	}
	return out[:]
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

// ---------------------------------------------------------------------------
// Models a schematic defines itself

// The .model and .subckt cards of a schematic's directives and of the files its .include /
// .lib directives name (relative paths from base_dir). Temporary.
sch_models :: proc(s: ^Schematic, sim: ^Simulator_Def, base_dir: string) -> []Lib_Entry {
	out := make([dynamic]Lib_Entry, context.temp_allocator)
	context.allocator = context.temp_allocator
	for t in s.texts {
		if !t.directive do continue
		body := t.text
		if sim != nil {
			b, ok := directive_for(t.text, sim)
			if !ok do continue
			body = b
		}
		parse_lib_into(&out, body, "schematic")
		for l in split_lines(body) {
			p, is_inc := include_path(l, base_dir)
			if !is_inc do continue
			if text, ok := read_text(p); ok do parse_lib_into(&out, text, p)
		}
	}
	embedded_entries(s, &out)
	return out[:]
}

// ".include file", ".inc file", ".lib file section": the file, relative to base_dir.
include_path :: proc(line, base_dir: string) -> (path: string, ok: bool) {
	t := strings.trim_space(line)
	f := strings.fields(t, context.temp_allocator)
	if len(f) < 2 do return "", false
	cmd := lower(f[0])
	if cmd != ".include" && cmd != ".inc" && cmd != ".lib" do return "", false
	p := strings.trim(strings.trim_space(t[len(f[0]):]), "\"'")
	if cmd == ".lib" && len(f) >= 3 {
		p = strings.trim(f[1], "\"'") // ".lib file section"
	}
	if strings.has_prefix(p, "~/") do p = path_join(home_dir(), p[2:])
	if !is_abs(p) && len(base_dir) > 0 do p = path_join(base_dir, p)
	return p, true
}

// A model or subcircuit by name: the schematic's directives and .include files, then the
// copies saved in the schematic (so a file simulates the same on every computer, whatever
// versions the libraries there have), then the libraries. sch_models lists the embedded
// copies after the rest.
model_lookup :: proc(name: string, local: []Lib_Entry) -> ^Lib_Entry {
	n := lower(name)
	for &e in local do if e.name == n do return &e
	return lib_find(name)
}

// Where a part's model comes from, for the part editor; "" when there is no such model.
// differs: the library here has another version of it, which the copy in the schematic hides.
model_source :: proc(name: string, local: []Lib_Entry) -> (from: string, differs: bool) {
	e := model_lookup(name, local)
	if e == nil do return "", false
	switch {
	case entry_is_embedded(e):
		l := lib_find(name)
		return tcat("the copy saved in this schematic (", e.src[len("embedded copy ("):]), l != nil && strings.trim_space(l.text) != strings.trim_space(e.text)
	case e.src == "schematic": return "a directive in this schematic", false
	case e.src == "built-in models": return "spicy's built-in models", false
	}
	return e.src, false
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

// The name as written in the card (models are stored lower case).
entry_display_name :: proc(e: ^Lib_Entry) -> string {
	f := strings.fields(replace_parens(e.text), context.temp_allocator)
	return f[1] if len(f) > 1 else e.name
}

// ---------------------------------------------------------------------------
// VACASK: SPICE subcircuits translated

Vacask_Out :: struct {
	defs:   strings.Builder, // subckt … ends blocks
	loads:  ^[dynamic]string,
	models: ^[dynamic]string, // toplevel model lines
	done:   map[string]bool,
	local:  []Lib_Entry,
}

@(private = "file")
add_unique_s :: proc(list: ^[dynamic]string, x: string) {
	for y in list do if y == x do return
	append(list, x)
}

// Writes the VACASK form of a SPICE subcircuit (and of the subcircuits it uses) to o.defs.
vacask_subckt :: proc(nl: ^Netlist, o: ^Vacask_Out, e: ^Lib_Entry) {
	if o.done[e.name] do return
	o.done[e.name] = true
	lines := logical_lines(e.text)
	local_models := make(map[string]bool, 8, context.temp_allocator)
	for l in lines do if strings.has_prefix(lower(l), ".model") {
		f := strings.fields(replace_parens(l), context.temp_allocator)
		if len(f) > 1 do local_models[lower(f[1])] = true
	}
	body := strings.builder_make(context.temp_allocator)
	params := ""
	for l, n in lines {
		if n == 0 {
			// parameters on the .subckt line: "params: a=1 b=2" or "a=1"
			hf := strings.fields(replace_parens(l), context.temp_allocator)
			ps := make([dynamic]string, context.temp_allocator)
			for i := 2; i + 2 < len(hf); i += 1 do if hf[i + 1] == "=" {
				append(&ps, fmt.tprintf("%s=%s", lower(hf[i]), vacask_value(hf[i + 2])))
				i += 2
			}
			if len(ps) > 0 do params = strings.join(ps[:], " ", context.temp_allocator)
			continue
		}
		t := l
		if t[0] == '*' do continue
		if c := strings.index_any(t, ";$"); c > 0 do t = strings.trim_space(t[:c]) // trailing comments
		low := lower(t)
		switch {
		case strings.has_prefix(low, ".ends"):
		case strings.has_prefix(low, ".model"):
			osdi, ml, err := vacask_model(t)
			if len(err) > 0 {
				append(&nl.errors, fmt.tprintf("VACASK, subcircuit %s: %s", e.name, err))
				continue
			}
			add_unique_s(o.loads, osdi)
			fmt.sbprintf(&body, "  %s\n", ml)
		case strings.has_prefix(low, ".param"):
			rest := strings.trim_space(t[strings.index_byte(t, ' ') + 1:]) if strings.index_byte(t, ' ') > 0 else ""
			r, _ := strings.replace_all(rest, "{", "", context.temp_allocator)
			r, _ = strings.replace_all(r, "}", "", context.temp_allocator)
			fmt.sbprintf(&body, "  parameters %s\n", r)
		case t[0] == '.':
			append(&nl.errors, fmt.tprintf("VACASK, subcircuit %s: \"%s\" cannot be translated", e.name, t))
		case:
			line, err := vacask_element(nl, o, t, local_models)
			if len(err) > 0 {
				append(&nl.errors, fmt.tprintf("VACASK, subcircuit %s: %s", e.name, err))
				continue
			}
			fmt.sbprintf(&body, "  %s\n", line)
		}
	}
	ports := make([dynamic]string, context.temp_allocator)
	for p in e.ports do append(&ports, vnode_name(p))
	fmt.sbprintf(&o.defs, "\n// %s (from %s)\nsubckt %s (%s)\n", entry_display_name(e), e.src, vacask_name(e.name), strings.join(ports[:], " ", context.temp_allocator))
	if len(params) > 0 do fmt.sbprintf(&o.defs, "  parameters %s\n", params)
	strings.write_string(&o.defs, strings.to_string(body))
	strings.write_string(&o.defs, "ends\n")
}

@(private = "file")
vnode_name :: proc(n: string) -> string {return n if n == "0" else sanitize(lower(n))}

// A SPICE element line written in a directive ("V1 in 0 PULSE(0 1 0 1n)"), as opposed to a
// line of VACASK's own syntax ("r1 (a b) res r=1k", "model …", "analysis …").
spice_element_line :: proc(t: string) -> bool {
	f := strings.fields(t, context.temp_allocator)
	if len(f) < 3 || f[1][0] == '(' do return false
	switch lower(f[0]) {
	case "load", "model", "parameters", "subckt", "ends", "include", "embed", "control", "endc",
	     "options", "analysis", "sweep", "save", "print", "global", "ground", "postprocess", "var", "abort":
		return false
	}
	return strings.index_byte("rclviegfhdmqjxsRCLVIEGFHDMQJXS", f[0][0]) >= 0
}

// A SPICE element line of a directive in VACASK form; defined: the models the directives define.
vacask_directive_element :: proc(nl: ^Netlist, o: ^Vacask_Out, line: string, defined: map[string]bool) -> (string, string) {
	// an R, C, L or D: a 0 V sense source at its first node, so that I(R1) can be measured
	// (VACASK gives no current of these devices)
	t := strings.trim_space(line)
	if len(t) > 0 && strings.index_byte("rcldRCLD", t[0]) >= 0 {
		f := strings.fields(t, context.temp_allocator)
		if len(f) >= 3 && f[1][0] != '(' {
			ref := lower(f[0])
			inner := tcat(ref, "_1")
			// the first node replaced in place (the rest of the line as written)
			k := strings.index(t, f[0]) + len(f[0])
			k += strings.index(t[k:], f[1])
			el, err := vacask_element(nl, o, tcat(t[:k], inner, t[k + len(f[1]):]), defined)
			if len(err) > 0 do return el, err
			add_unique_s(o.models, "model vsource vsource")
			return fmt.tprintf("vsns_%s (%s %s) vsource dc=0\n%s", inner, vnode_name(f[1]), vnode_name(inner), el), ""
		}
	}
	return vacask_element(nl, o, line, defined)
}

// One SPICE element line in VACASK form.
@(private = "file")
vacask_element :: proc(nl: ^Netlist, o: ^Vacask_Out, line: string, local_models: map[string]bool) -> (string, string) {
	f := strings.fields(replace_parens(line), context.temp_allocator)
	if len(f) < 3 do return "", fmt.tprintf("\"%s\" is too short", line)
	name := sanitize(lower(f[0]))
	// plain tokens and name=value parameters
	plain := make([dynamic]string, context.temp_allocator)
	kv := make([dynamic]string, context.temp_allocator)
	for i := 1; i < len(f); i += 1 {
		if i + 2 < len(f) && f[i + 1] == "=" {
			append(&kv, fmt.tprintf("%s=%s", lower(f[i]), vacask_value(f[i + 2])))
			i += 2
		} else {
			append(&plain, f[i])
		}
	}
	nodes :: proc(p: []string) -> string {
		out := make([dynamic]string, context.temp_allocator)
		for x in p do append(&out, vnode_name(x))
		return strings.join(out[:], " ", context.temp_allocator)
	}
	extra := tcat(" ", strings.join(kv[:], " ", context.temp_allocator)) if len(kv) > 0 else ""
	is_model :: proc(n: string, local: map[string]bool) -> bool {
		if local[lower(n)] do return true
		e := lib_find(n)
		return e != nil && e.kind != "subckt"
	}
	// a library model used inside the subcircuit goes to the toplevel
	need_model :: proc(nl: ^Netlist, o: ^Vacask_Out, n: string, local: map[string]bool) {
		if local[lower(n)] do return
		e := model_lookup(n, o.local)
		if e == nil || e.kind == "subckt" do return
		osdi, ml, err := vacask_model(e.text)
		if len(err) > 0 {
			append(&nl.errors, err)
			return
		}
		add_unique_s(o.loads, osdi)
		add_unique_s(o.models, ml)
	}
	kind := f[0][0] | 0x20 // lower case letter
	switch kind {
	case 'r', 'c', 'l':
		if len(plain) < 2 do return "", fmt.tprintf("\"%s\": two nodes needed", line)
		val := plain[2] if len(plain) > 2 else ""
		dev, par, osdi := "spicy_r", "r", "spice/resistor.osdi"
		if kind == 'c' do dev, par, osdi = "spicy_c", "c", "spice/capacitor.osdi"
		if kind == 'l' do dev, par, osdi = "spicy_l", "l", "spice/inductor.osdi"
		add_unique_s(o.loads, osdi)
		// "RD 10 1 Rmod1 1.02": a resistor with a .model RES (TC1, TC2): that model, then the value
		if kind == 'r' && len(plain) > 3 && is_model(plain[2], local_models) {
			need_model(nl, o, plain[2], local_models)
			return tcat(fmt.tprintf("%s (%s) %s r=%s", name, nodes(plain[:2]), vacask_name(plain[2]), vacask_value(plain[3])), extra), ""
		}
		add_unique_s(o.models, fmt.tprintf("model %s sp_%s", dev, osdi[6:len(osdi) - 5]))
		s := fmt.tprintf("%s (%s) %s", name, nodes(plain[:2]), dev)
		if len(val) > 0 do s = fmt.tprintf("%s %s=%s", s, par, vacask_value(val))
		return tcat(s, extra), ""
	case 'd', 'm', 'q', 'j':
		// nodes, then the model; an optional area number after it
		mi := -1
		for x, i in plain do if i >= 2 && is_model(x, local_models) {mi = i; break}
		if mi < 0 do return "", fmt.tprintf("\"%s\": no known model", line)
		need_model(nl, o, plain[mi], local_models)
		s := fmt.tprintf("%s (%s) %s", name, nodes(plain[:mi]), vacask_name(plain[mi]))
		if mi + 1 < len(plain) do s = fmt.tprintf("%s area=%s", s, vacask_value(plain[mi + 1]))
		return tcat(s, extra), ""
	case 'e', 'g':
		if len(plain) < 5 do return "", fmt.tprintf("\"%s\": only linear E/G sources (4 nodes and a gain) can be translated", line)
		for x in plain do if lower(x) == "poly" || lower(x) == "value" || lower(x) == "table" do return "", fmt.tprintf("\"%s\": POLY / VALUE / TABLE sources cannot be translated", line)
		dev := "vcvs" if kind == 'e' else "vccs"
		add_unique_s(o.models, fmt.tprintf("model %s %s", dev, dev))
		return fmt.tprintf("%s (%s) %s gain=%s", name, nodes(plain[:4]), dev, vacask_value(plain[4])), ""
	case 'f', 'h':
		if len(plain) < 4 do return "", fmt.tprintf("\"%s\": 2 nodes, a voltage source and a gain needed", line)
		dev := "cccs" if kind == 'f' else "ccvs"
		add_unique_s(o.models, fmt.tprintf("model %s %s", dev, dev))
		return fmt.tprintf("%s (%s) %s ctlinst=\"%s\" gain=%s", name, nodes(plain[:2]), dev, sanitize(lower(plain[2])), vacask_value(plain[3])), ""
	case 'v', 'i':
		if len(plain) < 2 do return "", fmt.tprintf("\"%s\": two nodes needed", line)
		dev := "vsource" if kind == 'v' else "isource"
		add_unique_s(o.models, fmt.tprintf("model %s %s", dev, dev))
		// the value as written (functions keep their parentheses)
		rest := line
		for _ in 0 ..< 3 {
			rest = strings.trim_left_space(rest)
			sp := strings.index_any(rest, " \t")
			rest = rest[sp:] if sp >= 0 else ""
		}
		src, err := vacask_source(strings.trim_space(rest))
		if len(err) > 0 do return "", fmt.tprintf("\"%s\": %s", line, err)
		return fmt.tprintf("%s (%s) %s %s", name, nodes(plain[:2]), dev, src), ""
	case 's':
		// S<name> n+ n- nc+ nc- <SW or VSWITCH model>
		if len(plain) < 5 do return "", fmt.tprintf("\"%s\": 4 nodes and a switch model needed", line)
		if !is_model(plain[4], local_models) do return "", fmt.tprintf("\"%s\": no known model", line)
		need_model(nl, o, plain[4], local_models)
		return fmt.tprintf("%s (%s) %s", name, nodes(plain[:4]), vacask_name(plain[4])), ""
	case 'x':
		if len(plain) < 2 do return "", fmt.tprintf("\"%s\": nodes and a subcircuit needed", line)
		sub := plain[len(plain) - 1]
		e := model_lookup(sub, o.local)
		if e == nil || e.kind != "subckt" do return "", fmt.tprintf("\"%s\": subcircuit %s not found", line, sub)
		vacask_subckt(nl, o, e)
		return fmt.tprintf("%s (%s) %s%s", name, nodes(plain[:len(plain) - 1]), vacask_name(sub), extra), ""
	}
	return "", fmt.tprintf("\"%s\": this kind of element cannot be translated", line)
}

// ---------------------------------------------------------------------------
// Importing a model file

Import_Result :: struct {
	file:    string, // where the library was copied to
	symbols: [dynamic]string, // names of the symbols made
	models:   [dynamic]string, // .model names
	message:  string,
	repaired: int, // repairs made to the copy (model_repair)
}

// Copies a SPICE model file into the models folder and makes a symbol for every
// subcircuit in it. The symbols go into symbols/imported.edn.
// repair: the copy gets model_repair's repairs (the file itself is not changed).
// Where an import puts its copy: models/<name>.lib ("DMT10H003SPSWQ.spice.txt" → DMT10H003SPSWQ.lib).
import_dest :: proc(src: string) -> string {
	stem := base_name(src)
	if dot := strings.index_byte(stem, '.'); dot > 0 do stem = stem[:dot]
	return path_join(user_models_dir(), tcat(stem, ".lib"))
}

import_model_file :: proc(src: string, repair := false) -> (res: Import_Result, ok: bool) {
	res.symbols = make([dynamic]string, context.temp_allocator)
	res.models = make([dynamic]string, context.temp_allocator)
	text, rok := read_text(src, context.temp_allocator)
	if !rok {
		res.message = tcat("cannot read ", src)
		return res, false
	}
	if repair {
		fixed, rep := model_repair(text, import_dest(src))
		if len(rep.fixes) > 0 {
			text = tcat(repair_header(&rep, src), fixed)
			res.repaired = len(rep.fixes)
		}
	}
	entries := make([dynamic]Lib_Entry, context.temp_allocator)
	{
		context.allocator = context.temp_allocator
		parse_lib_into(&entries, text, src)
	}
	if len(entries) == 0 {
		res.message = tcat(base_name(src), " has no .model or .subckt")
		return res, false
	}
	os.make_directory_all(user_models_dir())
	dst := import_dest(src)
	stem := strings.trim_suffix(base_name(dst), ".lib")
	if !write_text(dst, text) {
		res.message = tcat("cannot write ", dst)
		return res, false
	}
	res.file = dst
	// symbols for the subcircuits, except the ones only used inside others (the parts of a
	// vendor op-amp model …); symbols an earlier import made for those are removed
	called := subckts_called(entries[:])
	sym_texts := make([dynamic]string, context.temp_allocator)
	helpers := make([dynamic]string, context.temp_allocator)
	made := make([dynamic]string, context.temp_allocator)
	for &e in entries {
		if e.kind != "subckt" {
			append(&res.models, entry_display_name(&e))
			continue
		}
		name := entry_display_name(&e)
		if called[e.name] {
			append(&helpers, name)
			continue
		}
		append(&res.symbols, name)
		// imported before (and perhaps redrawn in the symbol editor): kept while its pins
		// still fit the subcircuit's ports
		if old := symbol_find(name); old != nil && strings.has_suffix(old.source, "imported.edn") {
			c := Comp{value = name}
			if _, err := subckt_pin_map(&e, old, &c); len(err) == 0 && !untouched_box(&e, old, name, stem) do continue
		}
		append(&sym_texts, auto_symbol(&e, name, stem))
		append(&made, name)
	}
	if len(sym_texts) > 0 || len(helpers) > 0 {
		names := make([dynamic]string, context.temp_allocator)
		append(&names, ..made[:])
		append(&names, ..helpers[:]) // named without a text: taken out of the file
		if !imported_symbols_put(names[:], sym_texts[:]) {
			res.message = "cannot write symbols/imported.edn"
			return res, false
		}
	}
	log.infof("imported %s: %d subcircuit(s), %d model(s)", src, len(res.symbols), len(res.models))
	return res, true
}

// The subcircuits (lower case) that another subcircuit of the file calls: building blocks of
// a bigger model, not parts of their own. When every one is called (they call each other),
// none is left out.
subckts_called :: proc(entries: []Lib_Entry) -> map[string]bool {
	called := make(map[string]bool, context.temp_allocator)
	n := 0
	for &e in entries {
		if e.kind != "subckt" do continue
		n += 1
		// the cards, continuation lines joined
		joined := make([dynamic]string, context.temp_allocator)
		for raw in split_lines(e.text) {
			l := strings.trim_space(raw)
			if len(l) == 0 || l[0] == '*' do continue
			if i := strings.index_byte(l, ';'); i >= 0 do l = strings.trim_space(l[:i])
			if l[0] == '+' {
				if len(joined) > 0 do joined[len(joined) - 1] = tcat(joined[len(joined) - 1], " ", l[1:])
				continue
			}
			append(&joined, l)
		}
		for l in joined {
			if l[0] != 'x' && l[0] != 'X' do continue
			f := strings.fields(replace_parens(l), context.temp_allocator)
			// X<name> <nodes…> <subckt> [PARAMS:] [k=v …]: the last word before the parameters
			last := ""
			for w in f[1:] {
				if strings.contains_rune(w, '=') || strings.equal_fold(w, "params:") do break
				last = w
			}
			if len(last) > 0 {
				k := lower(last)
				if k != e.name do called[strings.clone(k, context.temp_allocator)] = true
			}
		}
	}
	m := 0
	for &e in entries do if e.kind == "subckt" && called[e.name] do m += 1
	if m == n do clear(&called)
	return called
}

// An op-amp triangle for a subcircuit whose terminals are two inputs and an output, with
// or without the two supplies (nothing else).
@(private = "file")
opamp_symbol :: proc(e: ^Lib_Entry, name, file: string) -> (string, bool) {
	n := len(e.pins)
	if n != 3 && n != 5 do return "", false
	pin_name :: proc(k: string) -> string {
		switch k {
		case "inp": return "In+"
		case "inn": return "In-"
		case "out": return "Out"
		case "vp": return "V+"
		}
		return "V-"
	}
	seen: map[string]bool
	seen.allocator = context.temp_allocator
	pins := make([]string, n, context.temp_allocator)
	for p, i in e.pins {
		k := opamp_port(p)
		if len(k) == 0 || seen[k] do return "", false
		seen[k] = true
		pins[i] = pin_name(k)
	}
	if !seen["inp"] || !seen["inn"] || !seen["out"] do return "", false
	supplies := n == 5
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, " {:name ")
	edn_quote(&b, name)
	strings.write_string(&b, " :desc ")
	edn_quote(&b, fmt.tprintf("%s – op-amp subcircuit (%s)", name, file))
	strings.write_string(&b, " :category \"Imported\" :prefix \"U\" :editor :text :value ")
	edn_quote(&b, name)
	strings.write_string(&b, "\n  :pins [{:name \"In-\" :at [-32 48]} {:name \"In+\" :at [-32 80]} {:name \"Out\" :at [32 64]}")
	if supplies do strings.write_string(&b, " {:name \"V+\" :at [0 32]} {:name \"V-\" :at [0 96]}")
	strings.write_string(&b, "]\n  :spice \"X{ref}")
	for p in pins do fmt.sbprintf(&b, " {{%s}}", p)
	strings.write_string(&b, " {value}\"\n  :vacask {:line \"{ref} (")
	for p, i in pins do fmt.sbprintf(&b, "%s{{%s}}", " " if i > 0 else "", p)
	strings.write_string(&b, ") {value}\"}\n")
	if supplies {
		strings.write_string(&b, "  :ref-at [36 40] :value-at [36 88]\n")
		strings.write_string(&b, "  :graphics [[:poly -32 32 32 64 -32 96 :body] [:line -26 48 -18 48] [:line -26 80 -18 80] [:line -22 76 -22 84]\n")
		strings.write_string(&b, "             [:line 0 32 0 48] [:line 0 96 0 80] [:text 4 36 \"V+\" :size 8] [:text 4 92 \"V-\" :size 8]]}")
	} else {
		strings.write_string(&b, "  :ref-at [8 28] :value-at [8 104]\n")
		strings.write_string(&b, "  :graphics [[:poly -32 32 32 64 -32 96 :body] [:line -26 48 -18 48] [:line -26 80 -18 80] [:line -22 76 -22 84]]}")
	}
	return strings.to_string(b), true
}

// The EDN of a symbol for a subcircuit.
auto_symbol :: proc(e: ^Lib_Entry, name, file: string) -> string {
	// a known device with matching terminal names: that device's symbol
	roles := make([dynamic]string, context.temp_allocator)
	for p in e.pins do append(&roles, pin_role(p))
	has :: proc(roles: []string, want: ..string) -> bool {
		for w in want {
			found := false
			for r in roles do if r == w do found = true
			if !found do return false
		}
		return true
	}
	like, what := "", ""
	switch e.dev {
	case "NMOS", "PMOS":
		if len(e.ports) == 3 && has(roles[:], "d", "g", "s") do like = lower(e.dev)
		what = "N-channel MOSFET" if e.dev == "NMOS" else "P-channel MOSFET"
	case "NPN", "PNP":
		if len(e.ports) == 3 && has(roles[:], "c", "b", "e") do like = lower(e.dev)
		what = tcat(e.dev, " transistor")
	case "NJF", "PJF":
		if len(e.ports) == 3 && has(roles[:], "d", "g", "s") && symbol_find(lower(e.dev)) != nil do like = lower(e.dev)
		what = "JFET"
	case "D":
		if len(e.ports) == 2 && has(roles[:], "a", "k") do like = "diode"
		what = "diode"
	}
	if len(like) > 0 && symbol_find(like) == nil do like = ""
	if len(like) == 0 && len(e.dev) == 0 {
		if t, ok := opamp_symbol(e, name, file); ok do return t
	}
	desc := fmt.tprintf("%s – %s subcircuit (%s)", name, what if len(what) > 0 else fmt.tprintf("%d-pin", len(e.ports)), file)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, " {:name ")
	edn_quote(&b, name)
	if len(like) > 0 {
		strings.write_string(&b, " :like ")
		edn_quote(&b, like)
		strings.write_string(&b, " :desc ")
		edn_quote(&b, desc)
		strings.write_string(&b, " :category \"Imported\" :value ")
		edn_quote(&b, name)
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	// a box: inputs left, outputs right, supplies on top and bottom (on the 16 grid)
	n := len(e.ports)
	side := make([]u8, n, context.temp_allocator) // 'l' 'r' 't' 'b'
	nl_, nr_, nt_, nb_ := 0, 0, 0, 0
	for p, i in e.pins {
		l := lower(p)
		switch {
		case strings.contains(l, "out") || l == "o" || l == "q" || l == "y": side[i] = 'r'
		case strings.has_prefix(l, "vcc") || strings.has_prefix(l, "vdd") || l == "v+" || l == "vp" || l == "vs+" || l == "vpos" || l == "vs": side[i] = 't'
		case strings.has_prefix(l, "vee") || strings.has_prefix(l, "vss") || l == "v-" || l == "vn" || l == "vs-" || l == "vneg" || l == "gnd" || l == "0": side[i] = 'b'
		case: side[i] = 'l'
		}
	}
	for x in side do switch x {
	case 'l': nl_ += 1
	case 'r': nr_ += 1
	case 't': nt_ += 1
	case 'b': nb_ += 1
	}
	// nothing recognised: half left, half right
	if nr_ == 0 && nt_ + nb_ == 0 && n > 1 {
		k := 0
		for &x in side {
			if k >= (n + 1) / 2 {x = 'r'; nl_ -= 1; nr_ += 1}
			k += 1
		}
	}
	rows := max(nl_, nr_, 1)
	h := 32 * (rows + 1)
	w := max(96, 32 * (max(nt_, nb_) + 1))
	strings.write_string(&b, " :desc ")
	edn_quote(&b, desc)
	strings.write_string(&b, " :category \"Imported\" :prefix \"X\" :editor :text :value ")
	edn_quote(&b, name)
	strings.write_string(&b, "\n  :pins [")
	spice := strings.builder_make(context.temp_allocator)
	strings.write_string(&spice, "X{ref}")
	gfx := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&gfx, "[:rect 0 0 %d %d :body]", w, h)
	pin_names := make([dynamic]string, context.temp_allocator)
	il, ir, it, ib := 0, 0, 0, 0
	for p, i in e.pins {
		// pin names must be unique and usable in {…}
		pn := sanitize(p) if len(sanitize(p)) > 0 else fmt.tprintf("p%d", i + 1)
		for q in pin_names do if q == pn do pn = fmt.tprintf("%s_%d", pn, i + 1)
		append(&pin_names, pn)
		x, y, tx, ty: int
		switch side[i] {
		case 'l':
			il += 1
			x, y = -32, 32 * il
			tx, ty = 4, y - 6
			fmt.sbprintf(&gfx, " [:line -32 %d 0 %d]", y, y)
		case 'r':
			ir += 1
			x, y = w + 32, 32 * ir
			tx, ty = w - 6 - 7 * len(p), y - 6
			fmt.sbprintf(&gfx, " [:line %d %d %d %d]", w, y, w + 32, y)
		case 't':
			it += 1
			x, y = 32 * it, -32
			tx, ty = x - 3 * len(p), 4
			fmt.sbprintf(&gfx, " [:line %d -32 %d 0]", x, x)
		case:
			ib += 1
			x, y = 32 * ib, h + 32
			tx, ty = x - 3 * len(p), h - 14
			fmt.sbprintf(&gfx, " [:line %d %d %d %d]", x, h, x, h + 32)
		}
		fmt.sbprintf(&gfx, " [:text %d %d ", tx, ty)
		edn_quote(&gfx, p)
		strings.write_string(&gfx, " :size 9]")
		strings.write_string(&b, "{:name ")
		edn_quote(&b, pn)
		fmt.sbprintf(&b, " :at [%d %d]} ", x, y)
		fmt.sbprintf(&spice, " {{%s}}", pn)
	}
	strings.write_string(&spice, " {value}")
	strings.write_string(&b, "]\n  :spice ")
	edn_quote(&b, strings.to_string(spice))
	// VACASK: the translated subcircuit is called with the pins in port order
	vline := strings.builder_make(context.temp_allocator)
	strings.write_string(&vline, "{ref} (")
	for pn, i in pin_names {
		if i > 0 do strings.write_byte(&vline, ' ')
		fmt.sbprintf(&vline, "{{%s}}", pn)
	}
	strings.write_string(&vline, ") {value}")
	strings.write_string(&b, "\n  :vacask {:line ")
	edn_quote(&b, strings.to_string(vline))
	fmt.sbprintf(&b, "}\n  :ref-at [%d %d] :value-at [%d %d]\n  :graphics [%s]}", w + 8, h + 20, w + 8, h + 40, strings.to_string(gfx))
	return strings.to_string(b)
}

IMPORTED_SYMBOLS_HEAD :: `;; Symbols spicy made for imported SPICE models (File › Import SPICE model…).
;; Edit them freely; importing a model again replaces its symbol. Same format as
;; symbols/standard.edn; :like "nmos" takes everything from that symbol except what is given.
`

// Adds or replaces symbols (by name) in <data>/symbols/imported.edn.
imported_symbols_put :: proc(names, texts: []string) -> bool {
	return symbol_file_put(path_join(user_symbols_dir(), "imported.edn"), IMPORTED_SYMBOLS_HEAD, names, texts)
}

// ---------------------------------------------------------------------------
// Missing models and files: reported before the simulator runs (it would only say
// "could not find model" or "Master … not found").

check_models :: proc(nl: ^Netlist, s: ^Schematic, sim: ^Simulator_Def) {
	// .include / .lib files
	for t in s.texts {
		if !t.directive do continue
		body, ok := directive_for(t.text, sim)
		if !ok do continue
		for l in split_lines(body) {
			p, inc := include_path(l, nl.base_dir)
			if !inc || file_exists(p) do continue
			has_copies := false
			for e in s.embedded do if e.from == base_name(p) do has_copies = true
			if has_copies {
				append(&nl.warnings, fmt.tprintf("%s: file not found here; using the copies of its models saved in the schematic", strings.trim_space(l)))
				continue
			}
			note := "" if is_abs(strings.trim(strings.fields(strings.trim_space(l), context.temp_allocator)[1], "\"'")) || len(nl.base_dir) > 0 else " (save the schematic first: relative paths are read from its folder)"
			append(&nl.errors, fmt.tprintf("%s: file not found: %s%s", strings.trim_space(l), p, note))
		}
	}
	// names defined in the schematic's directives and the parts' own definitions
	defined := make(map[string]bool, 16, context.temp_allocator)
	for e in nl.local do defined[e.name] = true
	for t in s.texts do if t.directive {
		for l in split_lines(t.text) {
			f := strings.fields(replace_parens(l), context.temp_allocator)
			if len(f) >= 2 && (lower(f[0]) == ".model" || lower(f[0]) == ".subckt") do defined[lower(f[1])] = true
		}
	}
	reported := make(map[string]bool, 8, context.temp_allocator)
	for &c in s.comps {
		sym := symbol_find(c.sym)
		if sym == nil || sym.kind != .Part do continue
		// parts whose value is a model or subcircuit name
		t := strings.trim_space(sym.spice)
		uses_model := sym.editor == "model" || (len(t) > 0 && (t[0] == 'X' || t[0] == 'x'))
		if !uses_model do continue
		f := strings.fields(c.value, context.temp_allocator)
		if len(f) == 0 {
			append(&nl.errors, fmt.tprintf("%s: no model given", c.ref))
			continue
		}
		name := lower(f[0])
		if defined[name] || lib_find(name) != nil do continue
		in_defs := false
		for k, _ in defined_in(sym.defs) do if k == name do in_defs = true
		for k, _ in defined_in(sym.vacask.defs) do if k == name do in_defs = true
		if in_defs do continue
		if S.default_models && sym.editor == "model" {
			builtin := false
			for d in DEFAULT_MODEL_CARDS do if d[0] == name do builtin = true
			if builtin do continue
		}
		if reported[name] do continue
		reported[name] = true
		hint := "add it with File › Import SPICE model…, a .model / .subckt / .include directive, or :model-libraries in settings.edn"
		if strings.has_suffix(sym.source, "imported.edn") do hint = fmt.tprintf("its model file is gone from %s; import it again with File › Import SPICE model…", user_models_dir())
		append(&nl.errors, fmt.tprintf("%s: model %s not found – %s", c.ref, f[0], hint))
	}
}

@(private = "file")
defined_in :: proc(text: string) -> map[string]bool {
	m := make(map[string]bool, 4, context.temp_allocator)
	for l in split_lines(text) {
		f := strings.fields(replace_parens(l), context.temp_allocator)
		if len(f) >= 2 {
			k := lower(f[0])
			if k == ".model" || k == ".subckt" || k == "model" || k == "subckt" do m[lower(f[1])] = true
		}
	}
	return m
}

// ---------------------------------------------------------------------------
// Embedding: copies of the models and symbols a schematic uses, kept in the file

embedded_free :: proc(s: ^Schematic) {
	for e in s.embedded {delete(e.name); delete(e.from); delete(e.text)}
	for t in s.embedded_sym do delete(t)
	clear(&s.embedded)
	clear(&s.embedded_sym)
}

// Refreshes the copies (called before saving): the cards of every model and subcircuit the
// parts and directives use (from .include files, imported models, :model-libraries and
// spicy's own models), with the cards those use in turn; and the symbols that are not built
// in. A copy the schematic already has is kept as it is, even when the library here has
// another version: it is what the schematic was simulated with (Import… on a part replaces
// it, drop_embedded). Copies no longer used are dropped.
sch_embed :: proc(s: ^Schematic, base_dir: string) {
	old_models := make([dynamic]Embedded_Model, context.temp_allocator)
	for e in s.embedded do append(&old_models, Embedded_Model{strings.clone(e.name, context.temp_allocator), strings.clone(e.from, context.temp_allocator), strings.clone(e.text, context.temp_allocator)})
	old_syms := make([dynamic]string, context.temp_allocator)
	for t in s.embedded_sym do append(&old_syms, strings.clone(t, context.temp_allocator))
	embedded_free(s)
	if !S.embed_models do return
	// where cards can come from, best first
	Src :: struct {e: ^Lib_Entry, from: string}
	includes := make([dynamic]Lib_Entry, context.temp_allocator)
	inc_from := make([dynamic]string, context.temp_allocator)
	defined_here := make(map[string]bool, 16, context.temp_allocator)
	{
		context.allocator = context.temp_allocator
		for t in s.texts {
			if !t.directive do continue
			for l in split_lines(t.text) {
				f := strings.fields(replace_parens(l), context.temp_allocator)
				if len(f) >= 2 && (lower(f[0]) == ".model" || lower(f[0]) == ".subckt") do defined_here[lower(f[1])] = true
				p, inc := include_path(l, base_dir)
				if !inc do continue
				text, ok := read_text(p)
				if !ok do continue
				n0 := len(includes)
				parse_lib_into(&includes, text, p)
				for _ in n0 ..< len(includes) do append(&inc_from, base_name(p))
			}
		}
	}
	// the schematic's .include files; else the copy it has (whatever the library here has
	// now); else the library, spicy's built-in models and default cards included
	find :: proc(name: string, includes: []Lib_Entry, inc_from: []string, old: []Embedded_Model) -> (text, from: string, ok: bool) {
		for &e, i in includes do if e.name == name do return e.text, inc_from[i], true
		for e in old do if e.name == name do return e.text, e.from, true
		if e := lib_find(name); e != nil {
			if e.src == "built-in models" do return e.text, "spicy built-in", true
			return e.text, base_name(e.src), true
		}
		for d in DEFAULT_MODEL_CARDS do if d[0] == name do return d[1], "spicy default", true
		return "", "", false
	}
	// names used: part values, every word of the directives, and (transitively) the words of
	// the cards taken
	queue := make([dynamic]string, context.temp_allocator)
	for c in s.comps {
		f := strings.fields(c.value, context.temp_allocator)
		if len(f) > 0 do append(&queue, lower(f[0]))
	}
	words :: proc(queue: ^[dynamic]string, text: string) {
		for w in strings.fields(replace_parens(text), context.temp_allocator) do append(queue, lower(w))
	}
	for t in s.texts do if t.directive do words(&queue, t.text)
	seen := make(map[string]bool, 32, context.temp_allocator)
	for len(queue) > 0 {
		n := pop(&queue)
		if seen[n] || defined_here[n] do continue
		seen[n] = true
		text, from, ok := find(n, includes[:], inc_from[:], old_models[:])
		if !ok do continue
		append(&s.embedded, Embedded_Model{strings.clone(n), strings.clone(from), strings.clone(text)})
		words(&queue, text)
	}
	// symbols that are not built in (and the symbols they are :like)
	add_sym :: proc(s: ^Schematic, sym: ^Symbol) {
		if sym == nil || sym.source == "built-in symbols" || len(sym.edn) == 0 do return
		for t in s.embedded_sym do if t == sym.edn do return
		if len(sym.like) > 0 do add_sym(s, symbol_find(sym.like)) // the base first
		append(&s.embedded_sym, strings.clone(sym.edn))
	}
	for c in s.comps {
		// the copy the file has, as for models (even when a symbol here has the name)
		kept := false
		for t in old_syms {
			v, err := edn_parse(t, context.temp_allocator)
			if len(err) > 0 || edn_str(v, "name") != c.sym do continue
			kept = true
			dup := false
			for x in s.embedded_sym do if x == t do dup = true
			if !dup do append(&s.embedded_sym, strings.clone(t))
		}
		if !kept do add_sym(s, symbol_find(c.sym))
	}
	// the symbols kept copies are :like (bases before the symbols built on them)
	for i := 0; i < len(s.embedded_sym); i += 1 {
		v, err := edn_parse(s.embedded_sym[i], context.temp_allocator)
		if len(err) > 0 do continue
		base := edn_str(v, "like")
		if len(base) == 0 do continue
		have := false
		for x in s.embedded_sym {
			w, e2 := edn_parse(x, context.temp_allocator)
			if len(e2) == 0 && edn_str(w, "name") == base do have = true
		}
		if have do continue
		for t in old_syms {
			w, e2 := edn_parse(t, context.temp_allocator)
			if len(e2) == 0 && edn_str(w, "name") == base {
				inject_at(&s.embedded_sym, i, strings.clone(t))
				i += 1
				break
			}
		}
	}
}

// The embedded cards that this schematic falls back on (a model nothing else here defines).
embedded_entries :: proc(s: ^Schematic, out: ^[dynamic]Lib_Entry) {
	context.allocator = context.temp_allocator
	for e in s.embedded {
		n0 := len(out)
		parse_lib_into(out, e.text, "embedded")
		for i in n0 ..< len(out) do out[i].src = tcat("embedded copy (", e.from, ")")
	}
}

entry_is_embedded :: proc(e: ^Lib_Entry) -> bool {return strings.has_prefix(e.src, "embedded copy")}

// Forgets the schematic's copies of the models and subcircuits a library file defines (a
// model imported for a part replaces the copy of the same name). The next save copies them
// again from the library.
drop_embedded :: proc(s: ^Schematic, lib_file: string) -> int {
	text, ok := read_text(lib_file, context.temp_allocator)
	if !ok do return 0
	entries := make([dynamic]Lib_Entry, context.temp_allocator)
	{
		context.allocator = context.temp_allocator
		parse_lib_into(&entries, text, lib_file)
	}
	n := 0
	for i := len(s.embedded) - 1; i >= 0; i -= 1 {
		hit := false
		for &e in entries do if e.name == s.embedded[i].name do hit = true
		if !hit do continue
		e := s.embedded[i]
		delete(e.name); delete(e.from); delete(e.text)
		ordered_remove(&s.embedded, i)
		n += 1
	}
	return n
}
