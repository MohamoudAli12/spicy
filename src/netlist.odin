package spicy

import "core:fmt"
import "core:strings"

// Netlist generation, the parts every simulator shares: the netlist of a schematic is built
// by netlist_spice (ngspice, Xyce …, netlist_spice.odin) or netlist_vacask (VACASK's own
// language, netlist_vacask.odin), after the checks that stop a run before it starts.

Netlist :: struct {
	text:     string,
	errors:   [dynamic]string,
	warnings: [dynamic]string,
	nets:     Net_Info,
	base_dir: string, // folder of the schematic (relative .include paths)
	local:    []Lib_Entry, // models and subcircuits the schematic defines itself
	ngbehavior: string, // ngspice compatibility mode the netlist needs ("psa": PSpice models), or ""
	// Xyce: the netlist writes its results itself, with a .print … format=raw line (Xyce's -r
	// raw file has no device currents: no I(R1)). Xyce names that file <netlist>.raw.
	xyce_print_raw: bool,
	xyce_noise_only: bool, // a Xyce netlist whose only analysis is .noise (Xyce runs just that one)
	plot_traces: []string, // the expressions of the .plot directives: shown after the run
	meas_lines:  []string, // the arguments of the .meas directives: measured after the run
	steps:       []Step_Value, // the .step values: one simulator run each
}

// Builds the netlist of a schematic for a simulator.
netlist_build :: proc(s: ^Schematic, sim: ^Simulator_Def, title: string, base_dir := "") -> Netlist {
	nl: Netlist
	nl.base_dir = base_dir
	nl.local = sch_models(s, sim, base_dir)
	nl.errors = make([dynamic]string, context.temp_allocator)
	nl.warnings = make([dynamic]string, context.temp_allocator)
	nl.nets = nets_build(s, S.net_prefix)
	for w in nl.nets.warnings do append(&nl.warnings, w)
	nl.plot_traces = plot_requests(s, sim)
	plot_validate(&nl, s)
	nl.meas_lines = card_lines(s, sim, ".meas")
	meas_check(&nl, s)
	step_check(&nl, sim, card_lines(s, sim, ".step"))
	// LTspice's .tran … startup: the sources ramped up in a copy of the schematic
	sw := startup_schematic(&nl, s) if tran_startup(s, sim) else s
	if sim.dialect == .Vacask {
		nl.text = netlist_vacask(&nl, sw, sim, title)
	} else {
		nl.text = netlist_spice(&nl, sw, sim, title)
		if sim_is_xyce(sim) do nl.text = xyce_fixups(nl.text)
		cards := netlist_cards_deep(nl.text, base_dir)
		if sim_is_ngspice(sim) {
			// its compatibility modes for the whole netlist ("a": "ps" or "lt" alone only covers
			// .include'd files, and spicy writes the models into the netlist): "psa" for PSpice
			// models, "lta" for LTspice's, "ltpsa" for both
			ps := pspice_feature(nl.text, base_dir)
			if len(ps) == 0 do ps = pspice_func_feature(cards)
			lt := ltspice_feature(cards)
			if len(ps) > 0 || len(lt) > 0 {
				nl.ngbehavior = tcat("lt" if len(lt) > 0 else "", "ps" if len(ps) > 0 else "", "a")
				why := ""
				if len(ps) > 0 do why = tcat("PSpice models (", ps, ")")
				if len(lt) > 0 do why = tcat(why, " and " if len(why) > 0 else "", "LTspice models (", lt, ")")
				nl_ := strings.index_byte(nl.text, '\n')
				note := fmt.tprintf("* %s: spicy runs ngspice -D ngbehavior=%s\n", why, nl.ngbehavior)
				nl.text = tcat(nl.text[:nl_ + 1], note, nl.text[nl_ + 1:]) if nl_ >= 0 else tcat(note, nl.text)
			}
		}
		lt_check_netlist(&nl, cards, sim)
	}
	nl.text = micro_to_u(nl.text)
	check_models(&nl, s, sim)
	if len(s.comps) == 0 do append(&nl.errors, "the schematic has no parts")
	ground := false
	for n in nl.nets.names do if n == "0" do ground = true
	if !ground && len(s.comps) > 0 do append(&nl.errors, "there is no ground (press G to place one)")
	return nl
}

// "µ" (as LTspice writes it, "1µ") and Greek "μ" after a number: "u", which every simulator
// reads (Xyce stops at "1µ", VACASK at "2µ" in its parameters). In words and paths they stay.
micro_to_u :: proc(text: string) -> string {
	if !strings.contains(text, "µ") && !strings.contains(text, "μ") do return text
	b := strings.builder_make(context.temp_allocator)
	prev: rune = 0
	for r in text {
		if (r == 'µ' || r == 'μ') && ((prev >= '0' && prev <= '9') || prev == '.') {
			strings.write_byte(&b, 'u')
		} else do strings.write_rune(&b, r)
		prev = r
	}
	return strings.to_string(b)
}

// Directive blocks can be limited to one simulator or dialect with a first line such as
// "#vacask", "#ngspice", "#xyce" or "#spice".
directive_for :: proc(text: string, sim: ^Simulator_Def) -> (body: string, ok: bool) {
	t := strings.trim_left_space(text)
	if !strings.has_prefix(t, "#") do return text, true
	nl := strings.index_byte(t, '\n')
	tag := lower(strings.trim_space(t[1:nl] if nl >= 0 else t[1:]))
	rest := t[nl + 1:] if nl >= 0 else ""
	if tag == sim.id || tag == DIALECT_NAMES[sim.dialect] do return rest, true
	return "", false
}

directive_lines :: proc(s: ^Schematic, sim: ^Simulator_Def) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for t in s.texts {
		if !t.directive do continue
		body, ok := directive_for(t.text, sim)
		if !ok do continue
		for l in split_lines(body) {
			if spicy_card_line(l) do continue // .plot, .meas, .step: for spicy, not the simulator
			if !is_blank(l) do append(&out, strings.trim_right_space(l))
		}
	}
	return out[:]
}

fill_template :: proc(nl: ^Netlist, tmpl: string, c: ^Comp, sym: ^Symbol, pin_nodes: []string, vacask: bool) -> string {
	tmpl := tmpl
	// a VDMOS (power MOSFET) has three nodes, d g s: the body is inside it. A fourth is its
	// thermal node, which VACASK holds at 0 V when the thermal model is off (the source, tied
	// there, shorted to ground: a singular matrix)
	if strings.contains(tmpl, "{S} {S}") {
		name := strings.trim_space(c.value)
		if sp := strings.index_any(name, " \t"); sp >= 0 do name = name[:sp]
		if e := model_lookup(name, nl.local); e != nil && upper(e.model_type) == "VDMOS" {
			tmpl, _ = strings.replace(tmpl, "{S} {S}", "{S}", 1, context.temp_allocator)
		}
	}
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(tmpl) {
		ch := tmpl[i]
		if ch != '{' {
			strings.write_byte(&b, ch)
			i += 1
			continue
		}
		j := strings.index_byte(tmpl[i:], '}')
		if j < 0 {
			strings.write_string(&b, tmpl[i:])
			break
		}
		key := tmpl[i + 1:i + j]
		i += j + 1
		val, found := "", false
		switch key {
		case "ref":
			val, found = lower(c.ref) if vacask else c.ref, true
			// the element's name at the start of a line: with the letter of its kind
			if i == len(key) + 2 || tmpl[i - len(key) - 3] == '\n' do val = element_name(c.ref, sym, vacask)
		case "value":
			val, found = vacask_value(c.value) if vacask else c.value, true
			// a model name ("DI_BC807-16"): as its model line names it
			if vacask && model_lookup(strings.trim_space(c.value), nl.local) != nil do val = vacask_name(strings.trim_space(c.value))
		case "source":
			v, err := vacask_source(c.value)
			if len(err) > 0 do append(&nl.errors, fmt.tprintf("%s: %s", c.ref, err))
			val, found = v, true
		case "expr":
			v := strings.trim_space(c.value)
			if len(v) > 2 && v[1] == '=' do v = tcat(lower(v[:1]), v[1:])
			val, found = v, true
		}
		if !found {
			for p, k in sym.pins do if p.name == key {
				val, found = pin_nodes[k], true
			}
		}
		if !found {
			for a in c.attrs do if a.key == key {
				val, found = a.val, true
			}
		}
		// "name=value" fields of the value ("Lp=1m Ls=100u k=0.99"); {kps|k}: kps, else k
		if !found {
			for alt in strings.split(key, "|", context.temp_allocator) {
				if v, ok := value_field(c.value, alt); ok {
					val, found = vacask_value(v) if vacask else v, true
					break
				}
			}
		}
		if !found {
			alts := strings.split(key, "|", context.temp_allocator)
			missing := alts[len(alts) - 1]
			append(&nl.errors, fmt.tprintf("%s: the value has no %s=… (it needs %s)", c.ref, missing, template_fields(tmpl, sym)))
			continue
		}
		strings.write_string(&b, val)
	}
	return strings.to_string(b)
}

// The value of a "name=value" field in a part's value ("Lp=1m Ls=100u k=0.99"), any case.
value_field :: proc(value, name: string) -> (string, bool) {
	for w in strings.fields(value, context.temp_allocator) {
		eq := strings.index_byte(w, '=')
		if eq > 0 && strings.equal_fold(w[:eq], name) do return w[eq + 1:], true
	}
	return "", false
}

// The value fields a template asks for, for messages: "Lp=… Ls=… k=…".
template_fields :: proc(tmpl: string, sym: ^Symbol) -> string {
	out := make([dynamic]string, context.temp_allocator)
	rest := tmpl
	for {
		i := strings.index_byte(rest, '{')
		if i < 0 do break
		j := strings.index_byte(rest[i:], '}')
		if j < 0 do break
		k := rest[i + 1:i + j]
		rest = rest[i + j + 1:]
		if k == "ref" || k == "value" || k == "source" || k == "expr" || strings.contains(k, "|") do continue
		is_pin := false
		for pd in sym.pins do if pd.name == k do is_pin = true
		if is_pin do continue
		f := tcat(k, "=…")
		dup := false
		for o in out do if o == f do dup = true
		if !dup do append(&out, f)
	}
	return strings.join(out[:], " ", context.temp_allocator)
}

check_pins :: proc(nl: ^Netlist, s: ^Schematic) {
	for &c in s.comps {
		sym := symbol_find(c.sym)
		if sym == nil || sym.kind != .Part do continue
		for k in 0 ..< len(sym.pins) {
			p := comp_pin(&c, sym, k)
			for op in nl.nets.open_pins do if op == p {
				append(&nl.warnings, fmt.tprintf("%s: pin %s is not connected", c.ref, sym.pins[k].name))
			}
		}
	}
}

// Library cards for the models and subcircuits the parts use (first word of the value).
needed_models :: proc(s: ^Schematic, defined: map[string]bool, local: []Lib_Entry) -> (cards: []^Lib_Entry, defaults: []string) {
	out := make([dynamic]^Lib_Entry, context.temp_allocator)
	defs := make([dynamic]string, context.temp_allocator)
	seen := make(map[string]bool, 16, context.temp_allocator)
	for &c in s.comps {
		sym := symbol_find(c.sym)
		if sym == nil || sym.kind != .Part do continue
		f := strings.fields(c.value, context.temp_allocator)
		if len(f) == 0 do continue
		name := lower(f[0])
		if seen[name] || defined[name] do continue
		seen[name] = true
		if e := model_lookup(name, local); e != nil {
			append(&out, e)
			continue
		}
		if S.default_models && (sym.editor == .Model) {
			for d in DEFAULT_MODEL_CARDS do if d[0] == name do append(&defs, d[1])
		}
	}
	return out[:], defs[:]
}

// The names a card or directive may use (the subcircuits of its X lines, the models of its
// devices …): every word of its lines except the element names and .model / .subckt headers.
card_refs :: proc(queue: ^[dynamic]string, text: string) {
	for raw in split_lines(text) {
		l := strings.trim_space(raw)
		if len(l) == 0 || l[0] == '*' do continue
		if i := strings.index_byte(l, ';'); i >= 0 do l = l[:i]
		low := lower(l)
		if strings.has_prefix(low, ".model") || strings.has_prefix(low, ".subckt") || strings.has_prefix(low, ".ends") || strings.has_prefix(low, ".include") || strings.has_prefix(low, ".inc ") || strings.has_prefix(low, ".lib") do continue
		f := strings.fields(replace_parens(l), context.temp_allocator)
		for w, k in f {
			if k == 0 && l[0] != '+' do continue
			if w == "=" do continue
			append(queue, lower(w))
		}
	}
}

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
	for t in s.texts do if t.directive do for k in card_names(split_lines(t.text)) do defined[k] = true
	reported := make(map[string]bool, 8, context.temp_allocator)
	for &c in s.comps {
		sym := symbol_find(c.sym)
		if sym == nil || sym.kind != .Part do continue
		// parts whose value is a model or subcircuit name
		t := strings.trim_space(sym.spice)
		uses_model := sym.editor == .Model || (len(t) > 0 && (t[0] == 'X' || t[0] == 'x'))
		if !uses_model do continue
		f := strings.fields(c.value, context.temp_allocator)
		if len(f) == 0 {
			append(&nl.errors, fmt.tprintf("%s: no model given", c.ref))
			continue
		}
		name := lower(f[0])
		if defined[name] || lib_find(name) != nil do continue
		if card_names(split_lines(sym.defs), vacask = true)[name] || card_names(split_lines(sym.vacask.defs), vacask = true)[name] do continue
		if S.default_models && sym.editor == .Model {
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

// The 0 V sources spicy puts in series with a pin to measure its current: the source
// vsns_<ref>_<pin> runs from the pin's net to the node <ref>_<pin>, which the pin then
// connects to (lower case, the pin name made an identifier by sanitize). The probe
// templates of settings.edn ("vsns_{ref}_{pin}:flow(br)") name them the same way.
// The name of a part's element in the netlist. SPICE: its name, with the letter of its kind in
// front when it does not start with it ("Loadstep", a current source: "ILoadstep"), as LTspice
// writes it; SPICE takes the kind from the first letter ("Loadstep" would be an inductor). Only
// for symbols whose line starts with the name ("{ref} …"; not "X{ref} …"). VACASK: its name in
// lower case, with the letter in front when that is one of VACASK's keywords ("Load": "rload";
// "load …" at the start of a line loads a device file).
element_name :: proc(ref: string, sym: ^Symbol, vacask: bool) -> string {
	if vacask {
		l := lower(ref)
		for k in VACASK_KEYWORDS do if l == k {
			p := lower(sym.prefix[:1]) if sym != nil && len(sym.prefix) > 0 else "x"
			return tcat(p, l)
		}
		return l
	}
	if sym == nil || len(sym.prefix) == 0 || len(ref) == 0 do return ref
	if !strings.has_prefix(strings.trim_space(sym.spice), "{ref}") do return ref
	if lower(ref[:1]) == lower(sym.prefix[:1]) do return ref
	return tcat(sym.prefix[:1], ref)
}

// The words VACASK reads at the start of a line (its lexer, lib/dfllexer.l of VACASK 0.3.4).
VACASK_KEYWORDS := [?]string{"include", "section", "endsection", "model", "global", "ground", "analysis", "sweep", "load", "embed", "subckt", "ends", "parameters", "control", "endc", "save"}

sense_node :: proc(ref, pin: string) -> string {return tcat(lower(ref), "_", sanitize(pin))}

sense_source :: proc(ref, pin: string) -> string {return tcat("vsns_", sense_node(ref, pin))}
