package spicy

import "core:fmt"
import "core:strings"

// Xyce reads ngspice's netlists except for a few cards (models from ngspice libraries,
// netlists exported by other tools, the built-in SW card): the switch models and the
// ngspice-style .options are translated for it.

sim_is_xyce :: proc(sim: ^Simulator_Def) -> bool {
	if lower(sim.id) == "xyce" do return true
	return len(sim.command) > 0 && strings.contains(lower(base_name(sim.command[0])), "xyce")
}

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
	keys, vals, _ := card_params(f, 3)
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
	keys, vals, flags := card_params(f, 1)
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
	append(&dropped, ..flags[:]) // such as savecurrents
	b := strings.builder_make(context.temp_allocator)
	if len(timeint) > 0 do fmt.sbprintf(&b, ".options timeint %s\n", strings.join(timeint[:], " ", context.temp_allocator))
	if len(device) > 0 do fmt.sbprintf(&b, ".options device %s\n", strings.join(device[:], " ", context.temp_allocator))
	if len(dropped) > 0 do fmt.sbprintf(&b, "* ngspice options Xyce does not have: %s\n", strings.join(dropped[:], " ", context.temp_allocator))
	return strings.trim_right(strings.to_string(b), "\n")
}

// Xyce runs one analysis per netlist, and writes resistor, capacitor, diode … currents only
// when asked for them: the .print line for the results of a .tran (else a .dc) asks for every
// voltage and two-pin current (V(*) I(*)) and the pin currents of transistors (IC(Q1) …).
// Written before the .end; nl says what the run then reads (xyce_print_raw, xyce_noise_only).
xyce_analyses :: proc(nl: ^Netlist, b: ^strings.Builder, s: ^Schematic, sim: ^Simulator_Def, dl: []string) {
	// Xyce runs one analysis per netlist: with a .noise, the other analyses are not run
	noise, others := false, 0
	for l in dl {
		low := lower(strings.trim_space(l))
		if strings.has_prefix(low, ".noise") {
			noise = true
			// Xyce 7.10 rejects a reference node, V(out,ref), with a message about PTS_PER_SUMMARY
			open := strings.index_byte(low, '(')
			close := strings.index_byte(low, ')')
			if open >= 0 && close > open && strings.contains(low[open:close], ",") {
				append(&nl.errors, tcat(".noise \"", strings.trim_space(strings.trim_space(l)[len(".noise"):]), "\": Xyce does not accept a reference node in the output. Correct: .noise V(out) V1 dec 10 10 1Meg (or run V(out,ref) on ngspice)"))
			}
		} else if strings.has_prefix(low, ".tran") || strings.has_prefix(low, ".ac") || strings.has_prefix(low, ".dc") || strings.has_prefix(low, ".op") do others += 1
	}
	nl.xyce_noise_only = noise && others == 0
	if noise && others > 0 do append(&nl.warnings, "Xyce runs only the .noise analysis of this schematic: its .tran, .ac, .dc and .op are not run (use ngspice or VACASK to run them together)")
	// the results of a .tran (else of a .dc) with every current, unless the simulator
	// is set to write one raw file per analysis itself
	analysis := ""
	for l in dl {
		low := lower(strings.trim_space(l))
		if strings.has_prefix(low, ".tran") do analysis = "tran"
		else if strings.has_prefix(low, ".dc") && len(analysis) == 0 do analysis = "dc"
	}
	if len(analysis) > 0 && sim.raw != .Per_Analysis {
		nl.xyce_print_raw = true
		fmt.sbprintf(b, ".print %s format=raw V(*) I(*)", analysis)
		for &c in s.comps {
			sym := symbol_find(c.sym)
			if sym == nil || sym.kind != .Part || comp_subckt(&c, sym, nl.local) != nil do continue
			if len(c.ref) == 0 || !strings.contains_rune("QqMmJj", rune(c.ref[0])) do continue
			for pd in sym.pins do if len(pd.cur) > 0 && len(pd.element) == 0 do fmt.sbprintf(b, " I%s(%s)", strings.to_upper(pd.cur, context.temp_allocator), c.ref)
		}
		strings.write_byte(b, '\n')
	}
}
