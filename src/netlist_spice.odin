package spicy

import "core:fmt"
import "core:strings"

// The SPICE netlist (ngspice, Xyce and other SPICE simulators).

netlist_spice :: proc(nl: ^Netlist, s: ^Schematic, sim: ^Simulator_Def, title: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "* %s\n", title)
	check_pins(nl, s)
	used_syms := make([dynamic]string, context.temp_allocator) // in the order the parts use them
	for &c, ci in s.comps {
		sym := symbol_find(c.sym)
		if sym == nil {
			append(&nl.errors, fmt.tprintf("%s: unknown symbol \"%s\"", c.ref, c.sym))
			continue
		}
		if sym.kind != .Part do continue
		nodes := make([]string, len(sym.pins), context.temp_allocator)
		for k in 0 ..< len(sym.pins) do nodes[k] = nl.nets.names[nl.nets.pin_net[ci][k]]
		if e := comp_subckt(&c, sym, nl.local); e != nil {
			spice_subckt_instance(nl, &b, &c, sym, e, nodes)
			continue
		}
		if lines, ok := nonideal_lines(nl, &c, sym, nodes, false); ok do strings.write_string(&b, lines)
		else do strings.write_string(&b, fill_template(nl, sym.spice, &c, sym, nodes, false))
		strings.write_byte(&b, '\n')
		add_unique(&used_syms, sym.name)
	}
	for name in used_syms {
		sym := symbol_find(name)
		if len(sym.defs) > 0 {
			strings.write_string(&b, sym.defs)
			strings.write_byte(&b, '\n')
		}
	}
	dl := directive_lines(s, sim)
	defined := card_names(dl)
	for &e in nl.local do if e.origin != .Embedded do defined[e.name] = true // in the directives or the files they include
	for name in used_syms {
		sym := symbol_find(name)
		if len(sym.defs) > 0 do for k, v in card_names(split_lines(sym.defs)) do defined[k] = v
	}
	cards, defaults := needed_models(s, defined, nl.local)
	emitted := make(map[string]bool, 16, context.temp_allocator)
	for e in cards {
		write_card(&b, e.text)
		emitted[e.name] = true
	}
	// what those cards and the directives use in turn (the subcircuits and models inside a
	// vendor's op-amp model …), each from the schematic's copies or the libraries
	queue := make([dynamic]string, context.temp_allocator)
	for e in cards do card_refs(&queue, e.text)
	for l in dl do card_refs(&queue, l)
	for len(queue) > 0 {
		n := pop(&queue)
		if emitted[n] || defined[n] do continue
		e := model_lookup(n, nl.local)
		if e == nil do continue // (directives and .include files are in defined: they are in the netlist already)
		write_card(&b, e.text)
		emitted[n] = true
		card_refs(&queue, e.text)
	}
	for d in defaults {
		strings.write_string(&b, d)
		strings.write_byte(&b, '\n')
	}
	for l in sim.lines do fmt.sbprintf(&b, "%s\n", l)
	for l in S.extra_lines do fmt.sbprintf(&b, "%s\n", l)
	have_analysis := false
	for l in dl {
		low := lower(strings.trim_space(l))
		if low == ".end" do continue
		for a in ([?]string{".tran", ".ac", ".dc", ".op", ".noise", ".tf", ".pz", ".sens", ".disto"}) do if strings.has_prefix(low, a) do have_analysis = true
		if p, inc := include_path(l, nl.base_dir); inc && !file_exists(p) {
			has := false
			for e in s.embedded do if e.from == base_name(p) do has = true
			if has {
				fmt.sbprintf(&b, "* %s – not found here: the copies saved in the schematic are used\n", strings.trim_space(l))
				continue
			}
		}
		fmt.sbprintf(&b, "%s\n", spice_fix_directive(l, nl.base_dir))
	}
	if sim_is_xyce(sim) do xyce_analyses(nl, &b, s, sim, dl)
	if !have_analysis do append(&nl.errors, "no analysis: add a .tran, .ac, .dc or .op directive (Simulate › Edit simulation command)")
	strings.write_string(&b, ".end\n")
	return strings.to_string(b)
}

// A library card into a SPICE netlist, each line without its indent: Xyce takes an indented
// line of a subcircuit for something else ("    M1 6 20 5 5 Nmod" in Zetex models gives a
// singular matrix).
write_card :: proc(b: ^strings.Builder, text: string) {
	for l in split_lines(text) {
		strings.write_string(b, strings.trim_left_space(l))
		strings.write_byte(b, '\n')
	}
}

// A part whose value is a subcircuit: "X<ref> <nodes in port order> <name> [params]", with
// 0 V sense sources in series with its pins so that its currents can be probed.
@(private = "file")
spice_subckt_instance :: proc(nl: ^Netlist, b: ^strings.Builder, c: ^Comp, sym: ^Symbol, e: ^Lib_Entry, nodes: []string) {
	order, err := subckt_pin_map(e, sym, c)
	if len(err) > 0 {
		append(&nl.errors, fmt.tprintf("%s: %s", c.ref, err))
		return
	}
	inner := make([]string, len(nodes), context.temp_allocator)
	copy(inner, nodes)
	if sym.probe != .None {
		used := make([]bool, len(nodes), context.temp_allocator)
		for k in order do used[k] = true
		for k in 0 ..< len(nodes) do if used[k] {
			inner[k] = sense_node(c.ref, sym.pins[k].name)
			fmt.sbprintf(b, "%s %s %s 0\n", sense_source(c.ref, sym.pins[k].name), nodes[k], inner[k])
		}
	}
	inst := c.ref if len(c.ref) > 0 && (c.ref[0] == 'X' || c.ref[0] == 'x') else tcat("X", c.ref)
	strings.write_string(b, inst)
	for k in order do fmt.sbprintf(b, " %s", inner[k])
	fmt.sbprintf(b, " %s\n", strings.trim_space(c.value))
}

// LTspice accepts ".tran <stop>"; SPICE needs ".tran <step> <stop>".
spice_fix_directive :: proc(l: string, base_dir := "") -> string {
	f := strings.fields(l, context.temp_allocator)
	// relative .include / .lib paths: from the schematic's folder (the run may be elsewhere)
	if p, ok := include_path(l, base_dir); ok && len(base_dir) > 0 && file_exists(p) {
		cmd := f[0]
		if lower(cmd) == ".lib" && len(f) >= 3 do return fmt.tprintf("%s \"%s\" %s", cmd, p, strings.join(f[2:], " ", context.temp_allocator))
		return fmt.tprintf("%s \"%s\"", cmd, p)
	}
	if len(f) == 2 && lower(f[0]) == ".tran" {
		if stop, ok := parse_eng(f[1]); ok do return tcat(".tran ", fmt_spice(stop / 1000), " ", f[1])
	}
	return l
}

sim_is_ngspice :: proc(sim: ^Simulator_Def) -> bool {
	if lower(sim.id) == "ngspice" do return true
	return len(sim.command) > 0 && strings.contains(lower(base_name(sim.command[0])), "ngspice")
}

// What in a netlist only ngspice's PSpice compatibility mode reads (vendor models are mostly
// written for PSpice): VSWITCH / ISWITCH models, TEMP in expressions, VALUE / TABLE / LAPLACE
// sources. "" when there is none.
pspice_feature :: proc(text: string, base_dir := "", depth := 0) -> string {
	for l in spice_cards(text) {
		low := lower(l)
		// the files it .include's (their paths are absolute in a netlist spicy wrote)
		if p, inc := include_path(l, base_dir); inc {
			if depth < 4 {
				if t, ok := read_text(p, context.temp_allocator); ok {
					if why := pspice_feature(t, dir_of(p), depth + 1); len(why) > 0 do return tcat(why, " in ", base_name(p))
				}
			}
			continue
		}
		if strings.has_prefix(low, ".model") {
			f := strings.fields(replace_parens(low), context.temp_allocator)
			if len(f) >= 3 && (f[2] == "vswitch" || f[2] == "iswitch") do return tcat(upper(f[2]), " switch models")
			continue
		}
		// TEMP inside {…}
		for i := 0; i < len(low); i += 1 {
			if low[i] != '{' do continue
			j := strings.index_byte(low[i:], '}')
			if j < 0 do break
			expr := low[i + 1:i + j]
			for k := strings.index(expr, "temp"); k >= 0; {
				before := k == 0 || !is_ident_char(expr[k - 1])
				after := k + 4 >= len(expr) || !is_ident_char(expr[k + 4])
				if before && after do return "TEMP in expressions"
				nk := strings.index(expr[k + 4:], "temp")
				k = k + 4 + nk if nk >= 0 else -1
			}
			i += j
		}
		if low[0] == 'e' || low[0] == 'g' {
			spaced, _ := strings.replace_all(low, "=", " = ", context.temp_allocator)
			spaced, _ = strings.replace_all(spaced, "{", " { ", context.temp_allocator)
			for w in strings.fields(spaced, context.temp_allocator)[1:] do if w == "value" || w == "table" || w == "laplace" || w == "freq" do return tcat(upper(w), " sources")
		}
	}
	return ""
}
