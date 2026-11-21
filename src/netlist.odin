package spicy

import "core:fmt"
import "core:strings"

// Netlist generation: SPICE (ngspice, Xyce …) or VACASK.

DEFAULT_MODELS_LIB :: #load("../models/standard.lib", string)

Lib_Entry :: struct {
	name: string, // lower case
	kind: string, // model type (D, NPN …) or "subckt"
	text: string, // the cards
	src:  string,
	// subcircuits
	ports: []string, // as on the .subckt line
	pins:  []string, // terminal names (from a "TERMINALS: D G S" comment, else the ports)
	dev:   string, // main device: NMOS PMOS NPN PNP NJF PJF D, or ""
}

model_lib: [dynamic]Lib_Entry

models_load :: proc() {
	clear(&model_lib)
	parse_lib(DEFAULT_MODELS_LIB, "built-in models")
	for p in S.model_libraries {
		text, ok := read_text(p, context.temp_allocator)
		if !ok {
			config_error(tcat("settings.edn: cannot read model library ", p))
			continue
		}
		parse_lib(strings.clone(text), p)
	}
	models_load_user()
}

// Reads the .model and .subckt cards of a SPICE library (continuation lines joined).
parse_lib :: proc(text, src: string) {parse_lib_into(&model_lib, text, src)}

parse_lib_into :: proc(list: ^[dynamic]Lib_Entry, text, src: string) {
	lines := split_lines(text)
	i := 0
	for i < len(lines) {
		l := strings.trim_space(lines[i])
		low := lower(l)
		if strings.has_prefix(low, ".model") {
			card := strings.builder_make(context.temp_allocator)
			strings.write_string(&card, l)
			j := i + 1
			for j < len(lines) && strings.has_prefix(strings.trim_space(lines[j]), "+") {
				strings.write_byte(&card, '\n')
				strings.write_string(&card, strings.trim_space(lines[j]))
				j += 1
			}
			full := strings.to_string(card)
			f := strings.fields(replace_parens(full), context.temp_allocator)
			if len(f) >= 3 {
				kind := upper(f[2])
				append(list, Lib_Entry{name = strings.clone(lower(f[1])), kind = strings.clone(kind), text = strings.clone(full), src = src})
			}
			i = j
			continue
		}
		if strings.has_prefix(low, ".subckt") {
			f := strings.fields(l, context.temp_allocator)
			b := strings.builder_make(context.temp_allocator)
			j := i
			for j < len(lines) {
				strings.write_string(&b, lines[j])
				strings.write_byte(&b, '\n')
				if strings.has_prefix(lower(strings.trim_space(lines[j])), ".ends") do break
				j += 1
			}
			if len(f) >= 2 {
				e := Lib_Entry{name = strings.clone(lower(f[1])), kind = "subckt", text = strings.clone(strings.trim_space(strings.to_string(b))), src = src}
				subckt_info(&e, lines, i)
				append(list, e)
			}
			i = j + 1
			continue
		}
		i += 1
	}
}

replace_parens :: proc(s: string) -> string {
	r, _ := strings.replace_all(s, "(", " ", context.temp_allocator)
	r, _ = strings.replace_all(r, ")", " ", context.temp_allocator)
	r, _ = strings.replace_all(r, "=", " = ", context.temp_allocator)
	return r
}

lib_find :: proc(name: string) -> ^Lib_Entry {
	n := lower(name)
	for &e in model_lib do if e.name == n do return &e
	return nil
}

// Model names of a type (for the part editor).
lib_models_of :: proc(kinds: []string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for e in model_lib {
		for k in kinds do if e.kind == k {
			// the original spelling from the card
			f := strings.fields(replace_parens(e.text), context.temp_allocator)
			append(&out, f[1] if len(f) > 1 else e.name)
		}
	}
	return out[:]
}

DEFAULT_MODEL_CARDS := [?][2]string {
	{"d", ".model D D"},
	{"dz", ".model DZ D(BV=5.1 IBV=1m RS=2)"},
	{"ds", ".model DS D(IS=1u RS=0.05 N=1.05 CJO=100p BV=40 IBV=1m)"},
	{"led", ".model LED D(IS=1e-22 N=1.5 RS=2 BV=5 IBV=10u)"},
	{"npn", ".model NPN NPN"},
	{"pnp", ".model PNP PNP"},
	{"nmos", ".model NMOS NMOS(LEVEL=1 VTO=1 KP=20m)"},
	{"pmos", ".model PMOS PMOS(LEVEL=1 VTO=-1 KP=20m)"},
	{"sw", ".model SW SW(RON=1 ROFF=1Meg VT=0.5 VH=0)"},
}

// ---------------------------------------------------------------------------

Netlist :: struct {
	text:     string,
	errors:   [dynamic]string,
	warnings: [dynamic]string,
	nets:     Net_Info,
	dialect:  string,
	base_dir: string, // folder of the schematic (relative .include paths)
	local:    []Lib_Entry, // models and subcircuits the schematic defines itself
	ngbehavior: string, // ngspice compatibility mode the netlist needs ("psa": PSpice models), or ""
}

// Directive blocks can be limited to one simulator or dialect with a first line such as
// "#vacask", "#ngspice", "#xyce" or "#spice".
directive_for :: proc(text: string, sim: ^Simulator_Def) -> (body: string, ok: bool) {
	t := strings.trim_left_space(text)
	if !strings.has_prefix(t, "#") do return text, true
	nl := strings.index_byte(t, '\n')
	tag := lower(strings.trim_space(t[1:nl] if nl >= 0 else t[1:]))
	rest := t[nl + 1:] if nl >= 0 else ""
	if tag == sim.id || tag == sim.dialect do return rest, true
	return "", false
}

@(private = "file")
fill_template :: proc(nl: ^Netlist, tmpl: string, c: ^Comp, sym: ^Symbol, pin_nodes: []string, vacask: bool) -> string {
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
		case "value":
			val, found = vacask_value(c.value) if vacask else c.value, true
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

// Builds the netlist of a schematic for a simulator.
netlist_build :: proc(s: ^Schematic, sim: ^Simulator_Def, title: string, base_dir := "") -> Netlist {
	nl: Netlist
	nl.base_dir = base_dir
	nl.local = sch_models(s, sim, base_dir)
	nl.errors = make([dynamic]string, context.temp_allocator)
	nl.warnings = make([dynamic]string, context.temp_allocator)
	nl.dialect = sim.dialect
	nl.nets = nets_build(s, S.net_prefix)
	for w in nl.nets.warnings do append(&nl.warnings, w)
	if sim.dialect == "vacask" {
		nl.text = netlist_vacask(&nl, s, sim, title)
	} else {
		nl.text = netlist_spice(&nl, s, sim, title)
		if sim_is_xyce(sim) do nl.text = xyce_fixups(nl.text)
		if sim_is_ngspice(sim) {
			if why := pspice_feature(nl.text, base_dir); len(why) > 0 {
				// "psa": PSpice syntax in the whole netlist ("ps" alone only covers .include'd
				// files, and spicy writes the models into the netlist)
				nl.ngbehavior = "psa"
				nl_ := strings.index_byte(nl.text, '\n')
				note := fmt.tprintf("* PSpice models (%s): spicy runs ngspice -D ngbehavior=psa\n", why)
				nl.text = tcat(nl.text[:nl_ + 1], note, nl.text[nl_ + 1:]) if nl_ >= 0 else tcat(note, nl.text)
			}
		}
	}
	check_models(&nl, s, sim)
	if len(s.comps) == 0 do append(&nl.errors, "the schematic has no parts")
	ground := false
	for n in nl.nets.names do if n == "0" do ground = true
	if !ground && len(s.comps) > 0 do append(&nl.errors, "there is no ground (press G to place one)")
	return nl
}

@(private = "file")
directive_lines :: proc(s: ^Schematic, sim: ^Simulator_Def) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for t in s.texts {
		if !t.directive do continue
		body, ok := directive_for(t.text, sim)
		if !ok do continue
		for l in split_lines(body) do if !is_blank(l) do append(&out, strings.trim_right_space(l))
	}
	return out[:]
}

// Model names defined by .model / .subckt lines.
@(private = "file")
defined_names :: proc(lines: []string) -> map[string]bool {
	m := make(map[string]bool, 16, context.temp_allocator)
	for l in lines {
		f := strings.fields(replace_parens(l), context.temp_allocator)
		if len(f) >= 2 && (lower(f[0]) == ".model" || lower(f[0]) == ".subckt") do m[lower(f[1])] = true
	}
	return m
}

@(private = "file")
check_pins :: proc(nl: ^Netlist, s: ^Schematic) {
	for &c, ci in s.comps {
		sym := symbol_find(c.sym)
		if sym == nil || sym.kind != .Part do continue
		for k in 0 ..< len(sym.pins) {
			p := comp_pin(&c, sym, k)
			for op in nl.nets.open_pins do if op == p {
				append(&nl.warnings, fmt.tprintf("%s: pin %s is not connected", c.ref, sym.pins[k].name))
			}
		}
		_ = ci
	}
}

// Library cards for the models and subcircuits the parts use (first word of the value).
@(private = "file")
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
		if S.default_models && (sym.editor == "model") {
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

@(private = "file")
netlist_spice :: proc(nl: ^Netlist, s: ^Schematic, sim: ^Simulator_Def, title: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "* %s\n", title)
	check_pins(nl, s)
	used_syms := make(map[string]bool, 16, context.temp_allocator)
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
		strings.write_string(&b, fill_template(nl, sym.spice, &c, sym, nodes, false))
		strings.write_byte(&b, '\n')
		used_syms[sym.name] = true
	}
	for name in used_syms {
		sym := symbol_find(name)
		if len(sym.defs) > 0 {
			strings.write_string(&b, sym.defs)
			strings.write_byte(&b, '\n')
		}
	}
	dl := directive_lines(s, sim)
	defined := defined_names(dl)
	for &e in nl.local do if !entry_is_embedded(&e) do defined[e.name] = true // in the directives or the files they include
	for name in used_syms {
		sym := symbol_find(name)
		if len(sym.defs) > 0 do for k, v in defined_names(split_lines(sym.defs)) do defined[k] = v
	}
	cards, defaults := needed_models(s, defined, nl.local)
	emitted := make(map[string]bool, 16, context.temp_allocator)
	for e in cards {
		strings.write_string(&b, e.text)
		strings.write_byte(&b, '\n')
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
		strings.write_string(&b, e.text)
		strings.write_byte(&b, '\n')
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
	if !have_analysis do append(&nl.errors, "no analysis: add a .tran, .ac, .dc or .op directive (Simulate › Edit simulation command)")
	strings.write_string(&b, ".end\n")
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Xyce reads ngspice's netlists except for a few cards (models from ngspice libraries,
// netlists exported by other tools, the built-in SW card): the switch models and the
// ngspice-style .options are translated for it.

sim_is_xyce :: proc(sim: ^Simulator_Def) -> bool {
	if lower(sim.id) == "xyce" do return true
	return len(sim.command) > 0 && strings.contains(lower(base_name(sim.command[0])), "xyce")
}

sim_is_ngspice :: proc(sim: ^Simulator_Def) -> bool {
	if lower(sim.id) == "ngspice" do return true
	return len(sim.command) > 0 && strings.contains(lower(base_name(sim.command[0])), "ngspice")
}

// What in a netlist only ngspice's PSpice compatibility mode reads (vendor models are mostly
// written for PSpice): VSWITCH / ISWITCH models, TEMP in expressions, VALUE / TABLE / LAPLACE
// sources. "" when there is none.
pspice_feature :: proc(text: string, base_dir := "", depth := 0) -> string {
	// cards with their "+" continuation lines joined
	cards := make([dynamic]string, context.temp_allocator)
	for raw in split_lines(text) {
		l := strings.trim_space(raw)
		if len(l) == 0 || l[0] == '*' do continue
		if l[0] == '+' && len(cards) > 0 {
			cards[len(cards) - 1] = tcat(cards[len(cards) - 1], " ", l[1:])
			continue
		}
		append(&cards, l)
	}
	for l in cards {
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
				before := k == 0 || !is_word_byte(expr[k - 1])
				after := k + 4 >= len(expr) || !is_word_byte(expr[k + 4])
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

@(private = "file")
is_word_byte :: proc(b: u8) -> bool {return (b >= 'a' && b <= 'z') || (b >= '0' && b <= '9') || b == '_'}

xyce_fixups :: proc(text: string) -> string {
	fx: Xyce_Fix
	// .model and .options cards as one line each (their "+" continuation lines joined)
	lines := make([dynamic]string, context.temp_allocator)
	for l in split_lines(text) {
		t := strings.trim_left_space(l)
		if strings.has_prefix(t, "+") && len(lines) > 0 {
			prev := lower(strings.trim_left_space(lines[len(lines) - 1]))
			if strings.has_prefix(prev, ".model") || strings.has_prefix(prev, ".option") {
				lines[len(lines) - 1] = tcat(lines[len(lines) - 1], " ", t[1:])
				continue
			}
		}
		append(&lines, l)
	}
	b := strings.builder_make(context.temp_allocator)
	for l, i in lines {
		low := lower(strings.trim_space(l))
		switch {
		case strings.has_prefix(low, ".model"): strings.write_string(&b, xyce_model(l, &fx))
		case strings.has_prefix(low, ".option"): strings.write_string(&b, xyce_options(l, &fx))
		case: strings.write_string(&b, l)
		}
		if i < len(lines) - 1 do strings.write_byte(&b, '\n')
	}
	out := strings.to_string(b)
	// Xyce sizes its time steps by the local truncation error, which collapses at the
	// abrupt edges of ideal switches ("time step too small"); ERROPTION=1 steps by the
	// solver's convergence instead (and the .tran step / breakpoints), as ngspice manages them.
	if fx.switches && !fx.own_timeint {
		if strings.contains(out, "\n.options timeint ") {
			out, _ = strings.replace(out, "\n.options timeint ", "\n.options timeint erroption=1 ", 1, context.temp_allocator)
		} else {
			cut := strings.last_index(lower(out), "\n.end")
			if cut >= 0 do out = tcat(out[:cut], "\n* ideal switches: time steps by convergence\n.options timeint erroption=1", out[cut:])
		}
	}
	return out
}

@(private = "file")
Xyce_Fix :: struct {
	switches:    bool, // ngspice switch models were translated
	own_timeint: bool, // the netlist sets Xyce's time integration options itself
}

// "k = v" pairs of a card from word `from` on (keys in lower case; flags without a value
// are left out).
@(private = "file")
card_params :: proc(f: []string, from: int) -> (keys, vals: [dynamic]string) {
	keys = make([dynamic]string, context.temp_allocator)
	vals = make([dynamic]string, context.temp_allocator)
	for i := from; i < len(f); {
		if i + 2 < len(f) && f[i + 1] == "=" {
			append(&keys, lower(f[i]))
			append(&vals, f[i + 2])
			i += 3
		} else do i += 1
	}
	return
}

// ngspice's SW / CSW switch models as Xyce's VSWITCH / ISWITCH. ngspice switches abruptly at
// VT ± VH (with hysteresis); Xyce goes smoothly from VOFF to VON, so VON = VT + |VH| and
// VOFF = VT - |VH|, a little apart when there is no hysteresis.
@(private = "file")
xyce_model :: proc(l: string, fx: ^Xyce_Fix) -> string {
	f := strings.fields(replace_parens(l), context.temp_allocator)
	if len(f) < 3 do return l
	typ := lower(f[2])
	if typ != "sw" && typ != "csw" do return l
	fx.switches = true
	keys, vals := card_params(f, 3)
	th, hy := "vt", "vh"
	on, off := "VON", "VOFF"
	if typ == "csw" do th, hy, on, off = "it", "ih", "ION", "IOFF"
	t_s, h_s := "0", "0"
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, ".model %s %s(", f[1], "VSWITCH" if typ == "sw" else "ISWITCH")
	n := 0
	for k, i in keys {
		switch k {
		case th: t_s = vals[i]
		case hy: h_s = vals[i]
		case "ron", "roff":
			fmt.sbprintf(&b, "%s%s=%s", " " if n > 0 else "", upper(k), vals[i])
			n += 1
		}
	}
	sep := " " if n > 0 else ""
	t, tok := parse_eng(t_s)
	h, hok := parse_eng(h_s)
	if tok && hok {
		h = abs(h)
		if h == 0 do h = 1e-3 * max(abs(t), 1e-3)
		fmt.sbprintf(&b, "%s%s=%.9g %s=%.9g)", sep, on, t + h, off, t - h)
	} else {
		// expressions: let Xyce work them out
		ts := strings.trim(t_s, "{}")
		hs := strings.trim(h_s, "{}")
		fmt.sbprintf(&b, "%s%s={(%s)+abs(%s)+1e-6} %s={(%s)-abs(%s)-1e-6})", sep, on, ts, hs, off, ts, hs)
	}
	return strings.to_string(b)
}

// ngspice's ".options k=v …" as Xyce's ".options <package> k=v …"; what Xyce has no
// equivalent for is left out (in a comment). Xyce's own ".options timeint …" stays.
@(private = "file")
xyce_options :: proc(l: string, fx: ^Xyce_Fix) -> string {
	f := strings.fields(replace_parens(l), context.temp_allocator)
	if len(f) < 2 do return l
	if len(f) < 3 || f[2] != "=" {
		// ".options timeint method=gear" (Xyce) or ".options savecurrents" (an ngspice flag)
		w := lower(f[1])
		if w == "timeint" do fx.own_timeint = true
		for pk in ([?]string{"timeint", "device", "nonlin", "nonlin-tran", "nonlin-hb", "linsol", "linsol-hb", "output", "restart", "hbint", "parser", "measure", "sensitivity", "diagnostic"}) do if w == pk do return l
	}
	keys, vals := card_params(f, 1)
	timeint := make([dynamic]string, context.temp_allocator)
	device := make([dynamic]string, context.temp_allocator)
	dropped := make([dynamic]string, context.temp_allocator)
	for k, i in keys {
		kv := tcat(k, "=", vals[i])
		switch k {
		case "method", "reltol", "abstol", "maxord": append(&timeint, kv)
		case "temp", "tnom", "gmin": append(&device, kv)
		case: append(&dropped, kv)
		}
	}
	// flags such as savecurrents
	for i := 1; i < len(f); i += 1 {
		if f[i] == "=" {i += 1; continue}
		if i + 1 < len(f) && f[i + 1] == "=" do continue
		append(&dropped, f[i])
	}
	b := strings.builder_make(context.temp_allocator)
	if len(timeint) > 0 do fmt.sbprintf(&b, ".options timeint %s\n", strings.join(timeint[:], " ", context.temp_allocator))
	if len(device) > 0 do fmt.sbprintf(&b, ".options device %s\n", strings.join(device[:], " ", context.temp_allocator))
	if len(dropped) > 0 do fmt.sbprintf(&b, "* ngspice options Xyce does not have: %s\n", strings.join(dropped[:], " ", context.temp_allocator))
	return strings.trim_right(strings.to_string(b), "\n")
}

// ---------------------------------------------------------------------------
// VACASK

// ngspice's ".options k=v …" as VACASK options (into opts, in order; a later key replaces
// an earlier one). What VACASK has no equivalent for is reported in a warning.
@(private = "file")
vacask_options :: proc(nl: ^Netlist, l: string, opts: ^[dynamic][2]string) {
	f := strings.fields(replace_parens(l), context.temp_allocator)
	keys, vals := card_params(f, 1)
	dropped := make([dynamic]string, context.temp_allocator)
	for k, i in keys {
		v := vals[i]
		name := ""
		switch k {
		case "method":
			m := lower(v)
			switch m {
			case "gear", "trap", "euler", "bdf", "bdf2", "gear2", "am": v = tcat("\"", m, "\"")
			case "trapezoidal": v = "\"trap\""
			case: append(&dropped, tcat(k, "=", v)); continue
			}
			name = "tran_method"
		case "maxord": name, v = "tran_maxord", vacask_value(v)
		case "itl4": name, v = "tran_itl", vacask_value(v)
		case "trtol": name, v = "tran_lteratio", vacask_value(v) // both: LTE overestimation factor
		case "reltol", "abstol", "vntol", "chgtol", "gmin", "temp", "tnom": name, v = k, vacask_value(v)
		case: append(&dropped, tcat(k, "=", v)); continue
		}
		set_option(opts, name, v)
	}
	// flags such as savecurrents
	for i := 1; i < len(f); i += 1 {
		if f[i] == "=" {i += 1; continue}
		if i + 1 < len(f) && f[i + 1] == "=" do continue
		append(&dropped, f[i])
	}
	if len(dropped) > 0 do append(&nl.warnings, fmt.tprintf("VACASK has no option like %s (left out)", strings.join(dropped[:], " ", context.temp_allocator)))
}

@(private = "file")
set_option :: proc(opts: ^[dynamic][2]string, k, v: string) {
	for &o in opts do if o[0] == k {o[1] = v; return}
	append(opts, [2]string{k, v})
}

// SPICE numbers ("1Meg", "10m") as plain numbers; anything else as it is, without {} braces.
vacask_value :: proc(v: string) -> string {
	t := strings.trim_space(v)
	if x, ok := parse_eng(t); ok && is_number_token(t) do return fmt.tprintf("%.12g", x)
	if is_identifier(t) do return vacask_name(t)
	if strings.has_prefix(t, "{") && strings.has_suffix(t, "}") do return t[1:len(t) - 1]
	return t
}

// "10k", "4.7u", "1Meg", "2.2nF", "1e-6" – a number with an optional SI prefix and unit letters.
is_number_token :: proc(t: string) -> bool {
	i := 0
	if i < len(t) && (t[i] == '+' || t[i] == '-') do i += 1
	digits := false
	for i < len(t) && t[i] >= '0' && t[i] <= '9' {i += 1; digits = true}
	if i < len(t) && t[i] == '.' {
		i += 1
		for i < len(t) && t[i] >= '0' && t[i] <= '9' {i += 1; digits = true}
	}
	if !digits do return false
	if i < len(t) && (t[i] == 'e' || t[i] == 'E') {
		j := i + 1
		if j < len(t) && (t[j] == '+' || t[j] == '-') do j += 1
		if j < len(t) && t[j] >= '0' && t[j] <= '9' {
			for j < len(t) && t[j] >= '0' && t[j] <= '9' do j += 1
			i = j
		}
	}
	// prefix and unit: letters only (µ allowed)
	for ch in t[i:] {
		if !((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == 'µ' || ch == 'μ' || ch == '%' || ch == 'Ω') do return false
	}
	return true
}

// Model names for VACASK: lower case, and never starting with a digit ("1N4148" would read as 1n).
vacask_name :: proc(n: string) -> string {
	l := lower(n)
	if len(l) > 0 && l[0] >= '0' && l[0] <= '9' do return tcat("m_", l)
	return l
}

is_identifier :: proc(t: string) -> bool {
	if len(t) == 0 do return false
	for ch in t do if !((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_') do return false
	return true
}

// Splits "PULSE(0 1 0 1n 1n 5u 10u) AC 1" into tokens, with function arguments grouped.
source_tokens :: proc(v: string) -> [dynamic]string {
	out := make([dynamic]string, context.temp_allocator)
	t, _ := strings.replace_all(v, ",", " ", context.temp_allocator)
	i := 0
	for i < len(t) {
		for i < len(t) && (t[i] == ' ' || t[i] == '\t') do i += 1
		if i >= len(t) do break
		start := i
		for i < len(t) && t[i] != ' ' && t[i] != '\t' && t[i] != '(' do i += 1
		// a function: name, optional spaces, (args)
		k := i
		for k < len(t) && (t[k] == ' ' || t[k] == '\t') do k += 1
		if k < len(t) && t[k] == '(' {
			e := strings.index_byte(t[k:], ')')
			end := k + e + 1 if e >= 0 else len(t)
			append(&out, tcat(strings.trim_space(t[start:i]), t[k:end]))
			i = end
			continue
		}
		append(&out, t[start:i])
	}
	return out
}

// SPICE source value → VACASK vsource/isource parameters.
vacask_source :: proc(v: string) -> (string, string) {
	b := strings.builder_make(context.temp_allocator)
	toks := source_tokens(v)
	num :: proc(s: string) -> string {return vacask_value(s)}
	args :: proc(t: string) -> []string {
		o := strings.index_byte(t, '(')
		c := strings.last_index_byte(t, ')')
		if o < 0 do return {}
		if c < o do c = len(t)
		return strings.fields(t[o + 1:c], context.temp_allocator)
	}
	have_type := false
	i := 0
	for i < len(toks) {
		tk := toks[i]
		lt := lower(tk)
		switch {
		case lt == "dc" && i + 1 < len(toks):
			fmt.sbprintf(&b, " dc=%s", num(toks[i + 1]))
			i += 2
			continue
		case lt == "ac" && i + 1 < len(toks):
			fmt.sbprintf(&b, " mag=%s", num(toks[i + 1]))
			if i + 2 < len(toks) && is_number_token(toks[i + 2]) {
				fmt.sbprintf(&b, " phase=%s", num(toks[i + 2]))
				i += 1
			}
			i += 2
			continue
		case strings.has_prefix(lt, "pulse("):
			a := args(tk)
			names := [?]string{"val0", "val1", "delay", "rise", "fall", "width", "period"}
			strings.write_string(&b, " type=\"pulse\"")
			for x, k in a do if k < len(names) do fmt.sbprintf(&b, " %s=%s", names[k], num(x))
			have_type = true
		case strings.has_prefix(lt, "sin("):
			a := args(tk)
			names := [?]string{"sinedc", "ampl", "freq", "delay", "theta", "tdphase"}
			strings.write_string(&b, " type=\"sine\"")
			for x, k in a do if k < len(names) do fmt.sbprintf(&b, " %s=%s", names[k], num(x))
			have_type = true
		case strings.has_prefix(lt, "exp("):
			a := args(tk)
			strings.write_string(&b, " type=\"exp\"")
			names := [?]string{"val0", "val1", "delay", "tau1", "td2", "tau2"}
			td1 := 0.0
			if len(a) > 2 do td1, _ = parse_eng(a[2])
			for x, k in a {
				if k >= len(names) do break
				if k == 4 {
					td2, _ := parse_eng(x)
					fmt.sbprintf(&b, " td2=%.12g", td2 - td1)
					continue
				}
				fmt.sbprintf(&b, " %s=%s", names[k], num(x))
			}
			have_type = true
		case strings.has_prefix(lt, "pwl("):
			a := args(tk)
			strings.write_string(&b, " type=\"pwl\" wave=[")
			for x, k in a {
				if k > 0 do strings.write_string(&b, ", ")
				strings.write_string(&b, num(x))
			}
			strings.write_string(&b, "]")
			have_type = true
		case is_number_token(tk):
			fmt.sbprintf(&b, " dc=%s", num(tk))
		case:
			return strings.to_string(b), fmt.tprintf("VACASK: cannot translate \"%s\" in the source value", tk)
		}
		i += 1
	}
	_ = have_type
	return strings.trim_space(strings.to_string(b)), ""
}

sanitize :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for ch in lower(s) {
		switch {
		case ch == '+': strings.write_byte(&b, 'p')
		case ch == '-': strings.write_byte(&b, 'n')
		case (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '_': strings.write_rune(&b, ch)
		case: strings.write_byte(&b, '_')
		}
	}
	return strings.to_string(b)
}

sense_pin_name :: proc(pin: string) -> string {return sanitize(pin)}

// The pins of a part that get a VACASK sense source (two-pin parts: the first pin).
vacask_sensed :: proc(sym: ^Symbol, sim: ^Simulator_Def) -> int {
	if !sim.sense_currents || sym.kind != .Part do return 0
	if sym.probe == "none" || sym.probe == "source" do return 0
	if len(sym.pins) == 2 do return 1
	return len(sym.pins)
}

VACASK_MODEL_TYPES := [?][3]string {
	// spice type, osdi file, module
	{"D", "spice/diode.osdi", "sp_diode"},
	{"NPN", "spice/bjt.osdi", "sp_bjt"},
	{"PNP", "spice/bjt.osdi", "sp_bjt"},
	{"VDMOS", "spice/vdmos.osdi", "sp_vdmos"},
	{"NJF", "spice/jfet1.osdi", "sp_jfet1"},
	{"PJF", "spice/jfet1.osdi", "sp_jfet1"},
}

// ".model NAME TYPE(p=v …)" → loads and "model NAME module type=… p=v".
vacask_model :: proc(card: string) -> (load: string, line: string, err: string) {
	f := strings.fields(replace_parens(one_line(card)), context.temp_allocator)
	if len(f) < 3 do return "", "", "bad .model line"
	name := f[1]
	kind := upper(f[2])
	params := make([dynamic][2]string, context.temp_allocator)
	flags := make([dynamic]string, context.temp_allocator)
	i := 3
	for i < len(f) {
		if f[i] == "+" {i += 1; continue}
		if i + 2 < len(f) && f[i + 1] == "=" {
			append(&params, [2]string{lower(f[i]), f[i + 2]})
			i += 3
		} else {
			append(&flags, lower(f[i]))
			i += 1
		}
	}
	module, osdi := "", ""
	typ := 0
	level := 1
	for p in params do if p[0] == "level" {
		lv, _ := parse_eng(p[1])
		level = int(lv)
	}
	switch kind {
	case "D": osdi, module = "spice/diode.osdi", "sp_diode"
	case "NPN": osdi, module, typ = "spice/bjt.osdi", "sp_bjt", 1
	case "PNP": osdi, module, typ = "spice/bjt.osdi", "sp_bjt", -1
	case "NJF", "PJF":
		typ = 1 if kind == "NJF" else -1
		osdi, module = "spice/jfet1.osdi", "sp_jfet1"
		if level == 2 do osdi, module = "spice/jfet2.osdi", "sp_jfet2"
	case "VDMOS":
		typ = 1
		for fl in flags do if fl == "pchan" do typ = -1
		osdi, module = "spice/vdmos.osdi", "sp_vdmos"
	case "NMOS", "PMOS":
		typ = 1 if kind == "NMOS" else -1
		switch level {
		case 1: osdi, module = "spice/mos1.osdi", "sp_mos1"
		case 2: osdi, module = "spice/mos2.osdi", "sp_mos2"
		case 3: osdi, module = "spice/mos3.osdi", "sp_mos3"
		case 6: osdi, module = "spice/mos6.osdi", "sp_mos6"
		case 9: osdi, module = "spice/mos9.osdi", "sp_mos9"
		case 8, 49: osdi, module = "spice/bsim3v3.osdi", "sp_bsim3v3"
		case 14, 54: osdi, module = "spice/bsim4v8.osdi", "sp_bsim4v8"
		case: return "", "", fmt.tprintf("model %s: MOSFET level %d is not available in VACASK", name, level)
		}
	case "SW":
		// no switch in VACASK: a Verilog-A one embedded in the netlist (compiled by VACASK)
		osdi, module = SPICY_VSW_FILE, "spicy_vsw"
	case:
		return "", "", fmt.tprintf("model %s: type %s is not supported for VACASK", name, kind)
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "model %s %s", vacask_name(name), module)
	if typ != 0 do fmt.sbprintf(&b, " type=%d", typ)
	for p in params {
		if p[0] == "level" || p[0] == "type" do continue
		fmt.sbprintf(&b, " %s=%s", p[0], vacask_value(p[1]))
	}
	return osdi, strings.to_string(b), ""
}

@(private = "file")
netlist_vacask :: proc(nl: ^Netlist, s: ^Schematic, sim: ^Simulator_Def, title: string) -> string {
	body := strings.builder_make(context.temp_allocator)
	loads := make([dynamic]string, context.temp_allocator)
	models := make([dynamic]string, context.temp_allocator)
	add_unique :: proc(list: ^[dynamic]string, x: string) {
		for y in list do if y == x do return
		append(list, x)
	}
	check_pins(nl, s)
	used := make(map[string]bool, 16, context.temp_allocator)
	sub_needed := make([dynamic]^Lib_Entry, context.temp_allocator)
	vnode :: proc(n: string) -> string {return n if n == "0" else lower(n)}
	// initial conditions for the transient analysis (VACASK takes them there, not on the
	// devices): capacitors' "ic=" (used with uic, as in SPICE) and .ic directives (always)
	cap_ic := make([dynamic]string, context.temp_allocator)
	dir_ic := make([dynamic]string, context.temp_allocator)
	ic_entry :: proc(a, b, v: string) -> string {
		if b == "0" do return fmt.tprintf("\"%s\", %s", a, v)
		if a == "0" do return fmt.tprintf("\"%s\", %s", b, vacask_value(tcat("-", v)) if v[0] != '-' else v[1:])
		return fmt.tprintf("\"%s\", \"%s\", %s", a, b, v)
	}
	for &c, ci in s.comps {
		sym := symbol_find(c.sym)
		if sym == nil {
			append(&nl.errors, fmt.tprintf("%s: unknown symbol \"%s\"", c.ref, c.sym))
			continue
		}
		if sym.kind != .Part do continue
		sub := comp_subckt(&c, sym, nl.local)
		if sub == nil && len(sym.vacask.line) == 0 {
			append(&nl.errors, fmt.tprintf("%s: the symbol \"%s\" has no :vacask netlist line", c.ref, sym.name))
			continue
		}
		used[sym.name] = true
		nodes := make([]string, len(sym.pins), context.temp_allocator)
		for k in 0 ..< len(sym.pins) do nodes[k] = vnode(nl.nets.names[nl.nets.pin_net[ci][k]])
		// sense sources in series with the pins
		ns := vacask_sensed(sym, sim)
		for k in 0 ..< ns {
			inner := fmt.tprintf("%s_%s", lower(c.ref), sense_pin_name(sym.pins[k].name))
			fmt.sbprintf(&body, "vsns_%s (%s %s) vsource dc=0\n", inner, nodes[k], inner)
			nodes[k] = inner
		}
		if ns > 0 do add_unique(&models, "model vsource vsource")
		line: string
		if sub != nil {
			order, err := subckt_pin_map(sub, sym, &c)
			if len(err) > 0 {
				append(&nl.errors, fmt.tprintf("%s: %s", c.ref, err))
				continue
			}
			ln := strings.builder_make(context.temp_allocator)
			fmt.sbprintf(&ln, "%s (", lower(c.ref))
			for k, i in order {
				if i > 0 do strings.write_byte(&ln, ' ')
				strings.write_string(&ln, nodes[k])
			}
			vf := strings.fields(c.value, context.temp_allocator)
			fmt.sbprintf(&ln, ") %s", vacask_name(vf[0]))
			for x in vf[1:] do fmt.sbprintf(&ln, " %s", lower(x))
			line = strings.to_string(ln)
			append(&sub_needed, sub)
		} else {
			line = fill_template(nl, sym.vacask.line, &c, sym, nodes, true)
			// SPICE "ic=…" on a C or L: VACASK's devices have no such parameter. With uic the
			// run starts from 0 V and 0 A anyway, so ic=0 is dropped; other values are not
			// carried over (a warning says so)
			if strings.contains(lower(line), " ic=") {
				kept := make([dynamic]string, context.temp_allocator)
				// the device's two nodes: "name (a b) model …"
				pa, pb := "", ""
				if o, cl_ := strings.index_byte(line, '('), strings.index_byte(line, ')'); o >= 0 && cl_ > o {
					nf := strings.fields(line[o + 1:cl_], context.temp_allocator)
					if len(nf) >= 2 do pa, pb = nf[0], nf[1]
				}
				for w in strings.fields(line, context.temp_allocator) {
					if strings.has_prefix(lower(w), "ic=") {
						v, ok := parse_eng(w[3:])
						if strings.contains(line, " spicy_c ") && ok && len(pa) > 0 {
							append(&cap_ic, ic_entry(pa, pb, fmt.tprintf("%.12g", v)))
						} else if !ok || v != 0 {
							append(&nl.warnings, fmt.tprintf("%s: %s is not supported by VACASK and was left out", c.ref, w))
						}
						continue
					}
					append(&kept, w)
				}
				line = strings.join(kept[:], " ", context.temp_allocator)
			}
		}
		strings.write_string(&body, line)
		strings.write_byte(&body, '\n')
		for l in sym.vacask.loads do add_unique(&loads, l)
		for m in sym.vacask.models do add_unique(&models, m)
		if strings.contains(line, " vsource ") do add_unique(&models, "model vsource vsource")
		if strings.contains(line, " isource ") do add_unique(&models, "model isource isource")
		if strings.contains(line, " vcvs ") do add_unique(&models, "model vcvs vcvs")
		if strings.contains(line, " vccs ") do add_unique(&models, "model vccs vccs")
	}
	// directives
	dl := directive_lines(s, sim)
	control := make([dynamic]string, context.temp_allocator)
	params := make([dynamic]string, context.temp_allocator)
	model_cards := make([dynamic]string, context.temp_allocator)
	verbatim := make([dynamic]string, context.temp_allocator)
	user_opts := make([dynamic][2]string, context.temp_allocator) // from .options
	n_op, n_tran, n_ac, n_dc := 0, 0, 0, 0
	// .ic v(node)=value v(a,b)=value
	for l in dl {
		t := strings.trim_space(l)
		if !strings.has_prefix(lower(t), ".ic ") && !strings.has_prefix(lower(t), ".ic\t") do continue
		f := strings.fields(replace_parens(t[3:]), context.temp_allocator)
		for i := 0; i < len(f); {
			if lower(f[i]) != "v" {i += 1; continue}
			j := i + 1
			nodes := make([dynamic]string, context.temp_allocator)
			for j < len(f) && f[j] != "=" && f[j] != "," {append(&nodes, vnode(f[j])); j += 1}
			if j + 1 < len(f) && f[j] == "=" && len(nodes) >= 1 {
				append(&dir_ic, ic_entry(nodes[0], nodes[1] if len(nodes) > 1 else "0", vacask_value(f[j + 1])))
				i = j + 2
			} else {
				append(&nl.warnings, tcat("cannot read ", t))
				break
			}
		}
	}
	in_subckt := false
	for l in dl {
		t := strings.trim_space(l)
		if len(t) == 0 || t[0] == '*' || t[0] == ';' do continue
		// .subckt blocks and .include files are read into nl.local and translated when used
		lt := lower(t)
		if strings.has_prefix(lt, ".subckt") do in_subckt = true
		if in_subckt {
			if strings.has_prefix(lt, ".ends") do in_subckt = false
			continue
		}
		if _, inc := include_path(t, nl.base_dir); inc do continue
		if t[0] == '+' do continue
		if t[0] != '.' {
			append(&verbatim, t) // VACASK syntax written by the user (#vacask blocks)
			continue
		}
		f := strings.fields(replace_parens(t), context.temp_allocator)
		cmd := lower(f[0])
		switch cmd {
		case ".end", ".backanno", ".ic": // .ic: read above, into the transient analyses
		case ".op":
			n_op += 1
			append(&control, fmt.tprintf("analysis op%d op", n_op))
		case ".tran":
			n_tran += 1
			pos := make([dynamic]string, context.temp_allocator)
			uic := false
			for x in f[1:] {
				if lower(x) == "uic" do uic = true
				else do append(&pos, x)
			}
			if len(pos) == 1 {
				stop, _ := parse_eng(pos[0])
				inject_at(&pos, 0, fmt.tprintf("%.6g", stop / 1000))
			}
			if len(pos) < 2 {
				append(&nl.errors, ".tran needs a stop time")
				continue
			}
			a := fmt.tprintf("analysis tran%d tran step=%s stop=%s", n_tran, vacask_value(pos[0]), vacask_value(pos[1]))
			if len(pos) > 2 do a = tcat(a, " start=", vacask_value(pos[2]))
			if len(pos) > 3 do a = tcat(a, " maxstep=", vacask_value(pos[3]))
			else do a = tcat(a, " maxstep=", vacask_value(pos[0]))
			if uic do a = tcat(a, " icmode=\"uic\"")
			ics := make([dynamic]string, context.temp_allocator)
			append(&ics, ..dir_ic[:])
			if uic do append(&ics, ..cap_ic[:])
			if len(ics) > 0 do a = tcat(a, " ic={", strings.join(ics[:], ", ", context.temp_allocator), "}")
			append(&control, a)
		case ".ac":
			n_ac += 1
			if len(f) < 5 {
				append(&nl.errors, ".ac needs: dec|oct|lin points fstart fstop")
				continue
			}
			append(&control, fmt.tprintf("analysis ac%d ac from=%s to=%s mode=\"%s\" points=%s", n_ac, vacask_value(f[3]), vacask_value(f[4]), lower(f[1]), f[2]))
		case ".dc":
			n_dc += 1
			if len(f) < 5 {
				append(&nl.errors, ".dc needs: source start stop step")
				continue
			}
			append(&control, fmt.tprintf("sweep %s instance=\"%s\" parameter=\"dc\" from=%s to=%s step=%s", lower(f[1]), lower(f[1]), vacask_value(f[2]), vacask_value(f[3]), vacask_value(f[4])))
			append(&control, fmt.tprintf("  analysis dc%d op", n_dc))
		case ".param", ".params":
			rest := strings.trim_space(t[len(f[0]):])
			r, _ := strings.replace_all(rest, "{", "", context.temp_allocator)
			r, _ = strings.replace_all(r, "}", "", context.temp_allocator)
			append(&params, tcat("parameters ", r))
		case ".model":
			append(&model_cards, t)
		case ".option", ".options", ".opt", ".opts":
			vacask_options(nl, t, &user_opts)
		case:
			append(&nl.warnings, fmt.tprintf("VACASK: \"%s\" is ignored (put VACASK lines in a directive starting with #vacask)", t))
		}
	}
	if n_op + n_tran + n_ac + n_dc == 0 && !strings.contains(strings.join(verbatim[:], "\n", context.temp_allocator), "analysis") {
		append(&nl.errors, "no analysis: add a .tran, .ac, .dc or .op directive (Simulate › Edit simulation command)")
	}
	// models: from directives, libraries and defaults
	defined := make(map[string]bool, 16, context.temp_allocator)
	for m in model_cards {
		ff := strings.fields(replace_parens(m), context.temp_allocator)
		if len(ff) > 1 do defined[lower(ff[1])] = true
	}
	cards, defaults := needed_models(s, defined, nl.local)
	all_cards := make([dynamic]string, context.temp_allocator)
	append(&all_cards, ..model_cards[:])
	vo := Vacask_Out{defs = strings.builder_make(context.temp_allocator), loads = &loads, models = &models, done = make(map[string]bool, 8, context.temp_allocator), local = nl.local}
	for e in cards {
		if e.kind == "subckt" {
			vacask_subckt(nl, &vo, e)
			continue
		}
		append(&all_cards, e.text)
	}
	for e in sub_needed do vacask_subckt(nl, &vo, e)
	append(&all_cards, ..defaults[:])
	for card in all_cards {
		osdi, line, err := vacask_model(card)
		if len(err) > 0 {
			append(&nl.errors, err)
			continue
		}
		add_unique(&loads, osdi)
		add_unique(&models, line)
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s\n\n", title)
	for l in loads do fmt.sbprintf(&b, "load \"%s\"\n", l)
	strings.write_byte(&b, '\n')
	for p in params do fmt.sbprintf(&b, "%s\n", p)
	for m in models do fmt.sbprintf(&b, "%s\n", m)
	for name in used {
		sym := symbol_find(name)
		if len(sym.vacask.defs) > 0 do fmt.sbprintf(&b, "\n%s\n", sym.vacask.defs)
	}
	strings.write_string(&b, strings.to_string(vo.defs))
	strings.write_byte(&b, '\n')
	strings.write_string(&b, strings.to_string(body))
	for l in sim.lines do fmt.sbprintf(&b, "%s\n", l)
	for l in S.extra_lines do fmt.sbprintf(&b, "%s\n", l)
	ctrl_opts := make([dynamic]string, context.temp_allocator)
	ctrl_extra := make([dynamic]string, context.temp_allocator)
	for v in verbatim {
		// user lines: control statements go into the control block, options before the
		// analyses (VACASK applies them to the analyses that follow)
		low := lower(v)
		if strings.has_prefix(low, "options") {
			append(&ctrl_opts, v)
		} else if strings.has_prefix(low, "analysis") || strings.has_prefix(low, "sweep") || strings.has_prefix(low, "save") {
			append(&ctrl_extra, v)
		} else {
			fmt.sbprintf(&b, "%s\n", v)
		}
	}
	strings.write_string(&b, "\ncontrol\n  save default\n")
	opts := make([dynamic][2]string, context.temp_allocator)
	switches := strings.contains(strings.to_string(body), " spicy_vsw") || has_switch_model(models[:])
	// translated SPICE subcircuits: converge on the solution only, as SPICE does (vendor
	// models have milliohm parasitics whose KCL residual rounding exceeds abstol); likewise
	// switches, whose off resistance (up to GΩ) leaves nodes almost floating
	if len(vo.done) > 0 || switches do set_option(&opts, "nr_residualcheck", "0")
	if switches {
		// Hard switching (power converters): at every switch edge diodes commutate and
		// nodes with no capacitance (diode–transformer nodes) jump. VACASK's defaults then
		// give up where SPICE carries on:
		// - trapezoidal integration rings on the inductors and drives the step to ~1e-14 s
		//   (SPICE users set .options method=gear for this; VACASK's default is trap),
		// - 10 NR iterations are too few for the diodes' junction limiting to settle,
		// - a step whose LTE is 2.5x too big is rejected even at the smallest possible step
		//   ("Timestep too small"), where SPICE accepts it.
		// .options in the schematic (method=, itl4=) and #vacask options lines still win.
		set_option(&opts, "tran_method", "\"gear\"")
		set_option(&opts, "tran_itl", "50")
		set_option(&opts, "tran_redofactor", "10")
	}
	for o in user_opts do set_option(&opts, o[0], o[1])
	if len(opts) > 0 {
		strings.write_string(&b, "  options")
		for o in opts do fmt.sbprintf(&b, " %s=%s", o[0], o[1])
		strings.write_byte(&b, '\n')
	}
	for c in ctrl_opts do fmt.sbprintf(&b, "  %s\n", c)
	for c in control do fmt.sbprintf(&b, "  %s\n", c)
	for c in ctrl_extra do fmt.sbprintf(&b, "  %s\n", c)
	strings.write_string(&b, "endc\n")
	for l in loads do if l == SPICY_VSW_FILE do fmt.sbprintf(&b, "\nembed \"%s\" <<<FILE\n%s>>>FILE\n", SPICY_VSW_FILE, SPICY_VSW_VA)
	return strings.to_string(b)
}

SPICY_VSW_FILE :: "spicy_vsw.va"

// Voltage-controlled switch for VACASK, from a SPICE SW model (RON ROFF VT VH). The
// conductance moves smoothly (log scale) from 1/roff to 1/ron as V(cp,cn) passes vt, over
// a band vh wide (10 mV when vh is 0); unlike SPICE it has no hysteresis.
SPICY_VSW_VA :: `// spicy: voltage-controlled switch (SPICE SW model) for VACASK
`+"`"+`include "constants.vams"
`+"`"+`include "disciplines.vams"

module spicy_vsw(p, n, cp, cn);
    inout p, n, cp, cn;
    electrical p, n, cp, cn;
    parameter real ron = 1.0 from (0:inf);
    parameter real roff = 1.0e12 from (0:inf);
    parameter real vt = 0.0;
    parameter real vh = 0.0 from [0:inf);
    real w, alpha, g;
    analog begin
        w = vh > 0 ? 2 * vh : 0.01;
        alpha = 0.5 * (1.0 + tanh((V(cp, cn) - vt) / (0.25 * w)));
        g = exp(-(ln(roff) + alpha * (ln(ron) - ln(roff))));
        I(p, n) <+ g * V(p, n);
    end
endmodule
`

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
	if sym.probe != "none" {
		used := make([]bool, len(nodes), context.temp_allocator)
		for k in order do used[k] = true
		for k in 0 ..< len(nodes) do if used[k] {
			n := fmt.tprintf("%s_%s", lower(c.ref), sense_pin_name(sym.pins[k].name))
			fmt.sbprintf(b, "Vsns_%s %s %s 0\n", n, nodes[k], n)
			inner[k] = n
		}
	}
	inst := c.ref if len(c.ref) > 0 && (c.ref[0] == 'X' || c.ref[0] == 'x') else tcat("X", c.ref)
	strings.write_string(b, inst)
	for k in order do fmt.sbprintf(b, " %s", inner[k])
	fmt.sbprintf(b, " %s\n", strings.trim_space(c.value))
}

@(private = "file")
has_switch_model :: proc(models: []string) -> bool {
	for m in models do if strings.contains(m, "spicy_vsw") do return true
	return false
}
