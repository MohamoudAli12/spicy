package spicy

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

// The VACASK netlist: VACASK has a language of its own, so parts, sources, models,
// subcircuits, options and analyses are translated from their SPICE form.

netlist_vacask :: proc(nl: ^Netlist, s: ^Schematic, sim: ^Simulator_Def, title: string) -> string {
	body := strings.builder_make(context.temp_allocator)
	loads := make([dynamic]string, context.temp_allocator)
	models := make([dynamic]string, context.temp_allocator)
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
			inner := sense_node(c.ref, sym.pins[k].name)
			fmt.sbprintf(&body, "%s (%s %s) vsource dc=0\n", sense_source(c.ref, sym.pins[k].name), nodes[k], inner)
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
			needs := make([dynamic]string, context.temp_allocator)
			all, has_ni := nonideal_lines(nl, &c, sym, nodes, true, &needs)
			if !has_ni do all = fill_template(nl, sym.vacask.line, &c, sym, nodes, true)
			for n in needs do if ns := symbol_find(n); ns != nil {
				for l in ns.vacask.loads do add_unique(&loads, l)
				for m in ns.vacask.models do add_unique(&models, m)
			}
			out_lines := make([dynamic]string, context.temp_allocator)
			for dev_line in strings.split(all, "\n", context.temp_allocator) {
				// SPICE "ic=…" on a C or L: VACASK's devices have no such parameter. With uic the
				// run starts from 0 V and 0 A anyway, so ic=0 is dropped; other values are not
				// carried over (a warning says so)
				if strings.contains(lower(dev_line), " ic=") {
					kept := make([dynamic]string, context.temp_allocator)
					// the device's two nodes: "name (a b) model …"
					pa, pb := "", ""
					if o, cl_ := strings.index_byte(dev_line, '('), strings.index_byte(dev_line, ')'); o >= 0 && cl_ > o {
						nf := strings.fields(dev_line[o + 1:cl_], context.temp_allocator)
						if len(nf) >= 2 do pa, pb = nf[0], nf[1]
					}
					for w in strings.fields(dev_line, context.temp_allocator) {
						if strings.has_prefix(lower(w), "ic=") {
							v, ok := parse_eng(w[3:])
							if strings.contains(dev_line, " spicy_c ") && ok && len(pa) > 0 {
								append(&cap_ic, ic_entry(pa, pb, fmt.tprintf("%.12g", v)))
							} else if !ok || v != 0 {
								append(&nl.warnings, fmt.tprintf("%s: %s is not supported by VACASK and was left out", c.ref, w))
							}
							continue
						}
						append(&kept, w)
					}
					append(&out_lines, strings.join(kept[:], " ", context.temp_allocator))
					continue
				}
				append(&out_lines, dev_line)
			}
			line = strings.join(out_lines[:], "\n", context.temp_allocator)
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
	n_op, n_tran, n_ac, n_dc, n_noise := 0, 0, 0, 0, 0
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
	vacask_own := make(map[string]bool, 16, context.temp_allocator)
	for tx in s.texts {
		if !tx.directive do continue
		tt := strings.trim_left_space(tx.text)
		if !strings.has_prefix(tt, "#") do continue
		if body, ok := directive_for(tx.text, sim); ok && body != tx.text {
			for l in split_lines(body) do vacask_own[strings.trim_space(l)] = true
		}
	}
	spice_elems := make([dynamic]string, context.temp_allocator)
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
			// SPICE element lines ("V1 in 0 PULSE(…)", "R5 a b 1k") are translated like the
			// lines of a subcircuit; the lines of #vacask blocks are VACASK syntax
			if !vacask_own[t] && spice_element_line(t) {
				append(&spice_elems, t)
				continue
			}
			append(&verbatim, t)
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
			append(&control, fmt.tprintf("analysis ac%d ac from=%s to=%s mode=\"%s\" points=%s", n_ac, vacask_value(f[3]), vacask_value(f[4]), lower(f[1]), vacask_points(f[1], f[2])))
		case ".noise":
			// .noise V(out) V1 dec points fstart fstop: after replace_parens, f = .noise V out V1 dec points fstart fstop
			if len(f) < 8 || lower(f[1]) != "v" || strings.contains(f[2], ",") {
				append(&nl.errors, ".noise needs: V(out) source dec|oct|lin points fstart fstop (one output node)")
				continue
			}
			n_noise += 1
			append(&control, fmt.tprintf("analysis noise%d noise out=[\"%s\"] in=\"%s\" from=%s to=%s mode=\"%s\" points=%s", n_noise, vacask_name(f[2]), vacask_name(f[3]), vacask_value(f[6]), vacask_value(f[7]), lower(f[4]), vacask_points(f[4], f[5])))
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
	if n_op + n_tran + n_ac + n_dc + n_noise == 0 && !strings.contains(strings.join(verbatim[:], "\n", context.temp_allocator), "analysis") {
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
		if e.subckt {
			vacask_subckt(nl, &vo, e)
			continue
		}
		append(&all_cards, e.text)
	}
	for e in sub_needed do vacask_subckt(nl, &vo, e)
	elem_lines := make([dynamic]string, context.temp_allocator)
	for t in spice_elems {
		line, err := vacask_directive_element(nl, &vo, t, defined)
		if len(err) > 0 {
			append(&nl.errors, tcat("VACASK: ", err))
			continue
		}
		append(&elem_lines, line)
	}
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
	for l in elem_lines do fmt.sbprintf(&b, "%s\n", l)
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

// The pins of a part that get a VACASK sense source (two-pin parts: the first pin).
vacask_sensed :: proc(sym: ^Symbol, sim: ^Simulator_Def) -> int {
	if !sim.sense_currents || sym.kind != .Part do return 0
	if sym.probe == "none" || sym.probe == "source" do return 0
	if len(sym.pins) == 2 do return 1
	return len(sym.pins)
}

// ngspice's ".options k=v …" as VACASK options (into opts, in order; a later key replaces
// an earlier one). What VACASK has no equivalent for is reported in a warning.
@(private = "file")
vacask_options :: proc(nl: ^Netlist, l: string, opts: ^[dynamic][2]string) {
	f := strings.fields(replace_parens(l), context.temp_allocator)
	keys, vals, flags := card_params(f, 1)
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
	append(&dropped, ..flags[:]) // such as savecurrents
	if len(dropped) > 0 do append(&nl.warnings, fmt.tprintf("VACASK has no option like %s (left out)", strings.join(dropped[:], " ", context.temp_allocator)))
}

@(private = "file")
set_option :: proc(opts: ^[dynamic][2]string, k, v: string) {
	for &o in opts do if o[0] == k {o[1] = v; return}
	append(opts, [2]string{k, v})
}

// The points of a VACASK sweep. For lin, SPICE gives the number of frequencies and VACASK the
// number of intervals (points + 1 frequencies), so lin N becomes N - 1: the same frequencies.
// dec and oct count points per decade or octave on both.
@(private = "file")
vacask_points :: proc(mode, points: string) -> string {
	if lower(mode) != "lin" do return points
	n, ok := strconv.parse_int(points)
	if !ok || n < 2 do return points
	return fmt.tprintf("%d", n - 1)
}

// SPICE numbers ("1Meg", "10m") as plain numbers; anything else as it is, without {} braces.
vacask_value :: proc(v: string) -> string {
	t := strings.trim_space(v)
	if x, ok := parse_eng(t); ok && is_number_token(t) do return fmt.tprintf("%.12g", x)
	if is_identifier(t) do return vacask_name(t)
	if strings.has_prefix(t, "{") && strings.has_suffix(t, "}") do return t[1:len(t) - 1]
	return t
}

// Model names for VACASK: lower case, and never starting with a digit ("1N4148" would read as 1n).
vacask_name :: proc(n: string) -> string {
	l := lower(n)
	// VACASK names are identifiers: "di_bc807-16" and "s1g-13-f" with '_' for the rest
	if !is_identifier(l) {
		b := transmute([]u8)strings.clone(l, context.temp_allocator)
		for &ch in b do if !is_ident_char(ch) do ch = '_'
		l = string(b)
	}
	if len(l) > 0 && l[0] >= '0' && l[0] <= '9' do return tcat("m_", l)
	return l
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
	args :: proc(t: string) -> []string {
		o := strings.index_byte(t, '(')
		c := strings.last_index_byte(t, ')')
		if o < 0 do return {}
		if c < o do c = len(t)
		return strings.fields(t[o + 1:c], context.temp_allocator)
	}
	i := 0
	for i < len(toks) {
		tk := toks[i]
		lt := lower(tk)
		switch {
		case lt == "dc" && i + 1 < len(toks):
			fmt.sbprintf(&b, " dc=%s", vacask_value(toks[i + 1]))
			i += 2
			continue
		case lt == "ac" && i + 1 < len(toks):
			fmt.sbprintf(&b, " mag=%s", vacask_value(toks[i + 1]))
			if i + 2 < len(toks) && is_number_token(toks[i + 2]) {
				fmt.sbprintf(&b, " phase=%s", vacask_value(toks[i + 2]))
				i += 1
			}
			i += 2
			continue
		case strings.has_prefix(lt, "pulse("):
			a := args(tk)
			names := [?]string{"val0", "val1", "delay", "rise", "fall", "width", "period"}
			strings.write_string(&b, " type=\"pulse\"")
			for x, k in a do if k < len(names) do fmt.sbprintf(&b, " %s=%s", names[k], vacask_value(x))
		case strings.has_prefix(lt, "sin("):
			a := args(tk)
			names := [?]string{"sinedc", "ampl", "freq", "delay", "theta", "tdphase"}
			strings.write_string(&b, " type=\"sine\"")
			for x, k in a do if k < len(names) do fmt.sbprintf(&b, " %s=%s", names[k], vacask_value(x))
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
				fmt.sbprintf(&b, " %s=%s", names[k], vacask_value(x))
			}
		case strings.has_prefix(lt, "pwl("):
			a := args(tk)
			strings.write_string(&b, " type=\"pwl\" wave=[")
			for x, k in a {
				if k > 0 do strings.write_string(&b, ", ")
				strings.write_string(&b, vacask_value(x))
			}
			strings.write_string(&b, "]")
		case is_number_token(tk):
			fmt.sbprintf(&b, " dc=%s", vacask_value(tk))
		case:
			return strings.to_string(b), fmt.tprintf("VACASK: cannot translate \"%s\" in the source value", tk)
		}
		i += 1
	}
	return strings.trim_space(strings.to_string(b)), ""
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
	case "VSWITCH":
		// PSpice: RON ROFF VON VOFF (on at VON, off at VOFF; VON < VOFF is a switch that is on
		// at low voltages) → the same switch with vt halfway, vh half the band and its sense
		osdi, module = SPICY_VSW_FILE, "spicy_vsw"
		von, voff := 1.0, 0.0
		kept := make([dynamic][2]string, context.temp_allocator)
		for p in params {
			v, _ := parse_eng(p[1])
			switch p[0] {
			case "von": von = v
			case "voff": voff = v
			case "ron", "roff": append(&kept, p)
			case: return "", "", fmt.tprintf("model %s: VSWITCH parameter %s is not available in VACASK", name, p[0])
			}
		}
		clear(&params)
		append(&params, ..kept[:])
		append(&params, [2]string{"vt", fmt.tprintf("%.9g", (von + voff) / 2)})
		append(&params, [2]string{"vh", fmt.tprintf("%.9g", abs(von - voff) / 2)})
		if von < voff do append(&params, [2]string{"sense", "-1"})
	case "R", "RES":
		// resistor model: TC1 TC2 (TCE, TNOM); PSpice's R is a scale factor of the value
		osdi, module = "spice/resistor.osdi", "sp_resistor"
		for p in params do if p[0] == "r" {
			if v, _ := parse_eng(p[1]); v != 1 do return "", "", fmt.tprintf("model %s: the resistance scale factor R=%s is not available in VACASK", name, p[1])
		}
		kept := make([dynamic][2]string, context.temp_allocator)
		for p in params do if p[0] != "r" do append(&kept, p)
		clear(&params)
		append(&params, ..kept[:])
	case:
		return "", "", fmt.tprintf("model %s: type %s is not supported for VACASK", name, kind)
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "model %s %s", vacask_name(name), module)
	if typ != 0 do fmt.sbprintf(&b, " type=%d", typ)
	dropped := make([dynamic]string, context.temp_allocator)
	for p in params {
		if p[0] == "level" || p[0] == "type" do continue
		if vacask_pspice_only(module, p[0]) do continue
		if module == "sp_diode" && !slice.contains(VACASK_DIODE_PARAMS, p[0]) {
			// as ngspice: a parameter the diode does not have is left out (VACASK would stop)
			append(&dropped, p[0])
			continue
		}
		fmt.sbprintf(&b, " %s=%s", p[0], vacask_value(p[1]))
	}
	if len(dropped) > 0 {
		return osdi, fmt.tprintf("// %s: %s left out (not parameters of VACASK's diode)\n%s", name, strings.join(dropped[:], ", ", context.temp_allocator), strings.to_string(b)), ""
	}
	return osdi, strings.to_string(b), ""
}

// The model parameters of VACASK's sp_diode (devices/spice/diode.va), aliases included.
@(private = "file")
VACASK_DIODE_PARAMS := []string{"af", "bv", "bv_max", "cj", "cj0", "cjo", "cjp", "cjsw", "cta", "ctc", "ctp", "eg", "fc", "fcs", "fv_max", "gap1", "gap2", "ib", "ibv", "id_max", "ik", "ikf", "ikp", "ikr", "is", "isr", "isw", "js", "jsw", "jtun", "jtunsw", "keg", "kf", "level", "lm", "lp", "m", "mj", "mjsw", "model_area", "model_lm", "model_lp", "model_pj", "model_wm", "model_wp", "n", "nbv", "nr", "ns", "ntun", "nz", "pb", "pd_max", "php", "qpscale", "rs", "rsw", "tbv1", "tcv", "te_max", "tlev", "tlevc", "tm1", "tm2", "tnom", "tpb", "tphp", "tref", "trs", "trs1", "trs2", "tt", "ttt1", "ttt2", "tvj", "var", "vb", "vj", "vjsw", "vp", "vrb", "wm", "wp", "xm", "xoi", "xom", "xp", "xti", "xtitun", "xw"}

// PSpice parameters of vendor models that VACASK's SPICE modules do not have, as ngspice
// does not: left out (VACASK stops at a parameter it does not know). T_ABS etc. set one
// device's temperature, TIKF is IKF's temperature coefficient, N on a MOSFET is the bulk
// junction's emission coefficient.
@(private = "file")
vacask_pspice_only :: proc(module, p: string) -> bool {
	switch p {
	case "t_abs", "t_rel_global", "t_rel_local", "t_measured": return true
	}
	switch module {
	case "sp_diode": return p == "tikf"
	case "sp_mos1", "sp_mos2", "sp_mos3": return p == "n"
	}
	return false
}

@(private = "file")
has_switch_model :: proc(models: []string) -> bool {
	for m in models do if strings.contains(m, "spicy_vsw") do return true
	return false
}

SPICY_VSW_FILE :: "spicy_vsw.va"

// Voltage-controlled switch for VACASK, from a SPICE SW model (RON ROFF VT VH). The
// conductance moves smoothly (log scale) from 1/roff to 1/ron as V(cp,cn) passes vt, over
// a band vh wide (10 mV when vh is 0); unlike SPICE it has no hysteresis. sense = -1: on
// below vt (a PSpice VSWITCH with VON < VOFF).
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
    parameter real sense = 1.0 from [-1:1] exclude (-1:1);
    real w, alpha, g;
    analog begin
        w = vh > 0 ? 2 * vh : 0.01;
        alpha = 0.5 * (1.0 + tanh(sense * (V(cp, cn) - vt) / (0.25 * w)));
        g = exp(-(ln(roff) + alpha * (ln(ron) - ln(roff))));
        I(p, n) <+ g * V(p, n);
    end
endmodule
`

Vacask_Out :: struct {
	defs:   strings.Builder, // subckt … ends blocks
	loads:  ^[dynamic]string,
	models: ^[dynamic]string, // toplevel model lines
	done:   map[string]bool,
	local:  []Lib_Entry,
}

// Writes the VACASK form of a SPICE subcircuit (and of the subcircuits it uses) to o.defs.
vacask_subckt :: proc(nl: ^Netlist, o: ^Vacask_Out, e: ^Lib_Entry) {
	if o.done[e.name] do return
	o.done[e.name] = true
	lines := spice_lines(e.text)
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
			add_unique(o.loads, osdi)
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
	fmt.sbprintf(&o.defs, "\n// %s (from %s)\nsubckt %s (%s)\n", entry_display_name(e), entry_from(e), vacask_name(e.name), strings.join(ports[:], " ", context.temp_allocator))
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
			inner := sense_node(ref, "1")
			// the first node replaced in place (the rest of the line as written)
			k := strings.index(t, f[0]) + len(f[0])
			k += strings.index(t[k:], f[1])
			el, err := vacask_element(nl, o, tcat(t[:k], inner, t[k + len(f[1]):]), defined)
			if len(err) > 0 do return el, err
			add_unique(o.models, "model vsource vsource")
			return fmt.tprintf("%s (%s %s) vsource dc=0\n%s", sense_source(ref, "1"), vnode_name(f[1]), vnode_name(inner), el), ""
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
		return e != nil && !e.subckt
	}
	// a library model used inside the subcircuit goes to the toplevel
	need_model :: proc(nl: ^Netlist, o: ^Vacask_Out, n: string, local: map[string]bool) {
		if local[lower(n)] do return
		e := model_lookup(n, o.local)
		if e == nil || e.subckt do return
		osdi, ml, err := vacask_model(e.text)
		if len(err) > 0 {
			append(&nl.errors, err)
			return
		}
		add_unique(o.loads, osdi)
		add_unique(o.models, ml)
	}
	kind := f[0][0] | 0x20 // lower case letter
	switch kind {
	case 'r', 'c', 'l':
		if len(plain) < 2 do return "", fmt.tprintf("\"%s\": two nodes needed", line)
		val := plain[2] if len(plain) > 2 else ""
		dev, par, osdi := "spicy_r", "r", "spice/resistor.osdi"
		if kind == 'c' do dev, par, osdi = "spicy_c", "c", "spice/capacitor.osdi"
		if kind == 'l' do dev, par, osdi = "spicy_l", "l", "spice/inductor.osdi"
		add_unique(o.loads, osdi)
		// "RD 10 1 Rmod1 1.02": a resistor with a .model RES (TC1, TC2): that model, then the value
		if kind == 'r' && len(plain) > 3 && is_model(plain[2], local_models) {
			need_model(nl, o, plain[2], local_models)
			return tcat(fmt.tprintf("%s (%s) %s r=%s", name, nodes(plain[:2]), vacask_name(plain[2]), vacask_value(plain[3])), extra), ""
		}
		add_unique(o.models, fmt.tprintf("model %s sp_%s", dev, osdi[6:len(osdi) - 5]))
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
		add_unique(o.models, fmt.tprintf("model %s %s", dev, dev))
		return fmt.tprintf("%s (%s) %s gain=%s", name, nodes(plain[:4]), dev, vacask_value(plain[4])), ""
	case 'f', 'h':
		if len(plain) < 4 do return "", fmt.tprintf("\"%s\": 2 nodes, a voltage source and a gain needed", line)
		dev := "cccs" if kind == 'f' else "ccvs"
		add_unique(o.models, fmt.tprintf("model %s %s", dev, dev))
		return fmt.tprintf("%s (%s) %s ctlinst=\"%s\" gain=%s", name, nodes(plain[:2]), dev, sanitize(lower(plain[2])), vacask_value(plain[3])), ""
	case 'v', 'i':
		if len(plain) < 2 do return "", fmt.tprintf("\"%s\": two nodes needed", line)
		dev := "vsource" if kind == 'v' else "isource"
		add_unique(o.models, fmt.tprintf("model %s %s", dev, dev))
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
		if e == nil || !e.subckt do return "", fmt.tprintf("\"%s\": subcircuit %s not found", line, sub)
		vacask_subckt(nl, o, e)
		return fmt.tprintf("%s (%s) %s%s", name, nodes(plain[:len(plain) - 1]), vacask_name(sub), extra), ""
	}
	return "", fmt.tprintf("\"%s\": this kind of element cannot be translated", line)
}
