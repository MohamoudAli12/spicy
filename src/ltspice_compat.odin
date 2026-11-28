package spicy

import "core:fmt"
import "core:strings"

// LTspice models on the other simulators. LTspice's own libraries and many vendor files written
// for it use what only LTspice reads: text parameters (mfg=OnSemi, type=silicon), the ideal
// diode (D with Ron, Roff, Vfwd …) and functions such as uplim() or buf(). ngspice reads the
// first two, and uplim / dnlim, in its LTspice compatibility mode ("lta", which spicy turns on
// as it does "psa" for PSpice models); without it, mfg= stops ngspice and the ideal diode is
// a plain diode. Xyce and VACASK have no ideal diode, Xyce no VDMOS. What a simulator cannot
// run is said before the run (netlist_build), and by --check-model.
//
// Each simulator's answers were found by running each function and model on it (ngspice 47,
// Xyce 7.10, VACASK 0.3.4).

// The parameters of LTspice's ideal diode (a D model with any of them).
LT_IDEAL_DIODE_PARAMS := []string{"ron", "roff", "vfwd", "vrev", "rrev", "epsilon", "revepsilon", "ilimit", "revilimit"}

// LTspice functions of B sources and expressions that a simulator lacks. ngspice: "lt" or "ps"
// for the compatibility mode that has it, "" for none. xyce: Xyce has it.
Lt_Func :: struct {
	name:    string,
	ngspice: string,
	no_ng:   bool, // not in ngspice in any mode
	xyce:    bool,
	instead: string, // what to write instead, "" for nothing simple
}

LT_FUNCS := []Lt_Func {
	{"uplim", "lt", false, false, ""},
	{"dnlim", "lt", false, false, ""},
	{"uplim_tanh", "lt", false, false, ""},
	{"dnlim_tanh", "lt", false, false, ""},
	{"buf", "", true, false, "x>0.5 ? 1 : 0"},
	{"inv", "", true, false, "x>0.5 ? 0 : 1"},
	{"absdelay", "", true, false, ""},
	{"delay", "", true, false, ""},
	{"idt", "", true, false, ""},
	{"idtmod", "", true, false, ""},
	{"sdt", "", true, true, ""},
	{"hypot", "", true, false, "sqrt(x*x+y*y)"},
	{"round", "", true, false, ""},
	{"rand", "", true, false, ""},
	{"random", "", true, false, ""},
	{"white", "", true, false, ""},
	{"table", "", true, true, "pwl(x, x1,y1, x2,y2 …) on ngspice"},
	{"atan2", "", true, true, ""},
	{"if", "ps", false, true, "c ? a : b"},
	{"int", "ps", false, true, ""},
	{"u", "", false, false, "x>0 ? 1 : 0"},
}

// The cards of a netlist with the files it .include's (their own .include's too, a few deep),
// without its .control … .endc block.
netlist_cards_deep :: proc(text: string, base_dir := "", depth := 0) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	control := false
	for l in spice_cards(text) {
		low := lower(l)
		if strings.has_prefix(low, ".control") do control = true
		if control {
			if strings.has_prefix(low, ".endc") do control = false
			continue
		}
		if p, inc := include_path(l, base_dir); inc {
			if depth < 4 {
				if t, ok := read_text(p, context.temp_allocator); ok do append(&out, ..netlist_cards_deep(t, dir_of(p), depth + 1))
			}
			continue
		}
		append(&out, l)
	}
	return out[:]
}

// A .model card's name, type (upper case) and parameters (keys lower case); ok false for any
// other card.
@(private = "file")
model_card :: proc(card: string) -> (name, typ: string, keys, vals: []string, ok: bool) {
	cs := spice_cards(card) // its "+" lines joined, comments left out
	if len(cs) == 0 || !strings.has_prefix(lower(cs[0]), ".model") do return
	f := strings.fields(replace_parens(cs[0]), context.temp_allocator)
	if len(f) < 3 do return
	k, v, _ := card_params(f, 3)
	return f[1], upper(f[2]), k[:], v[:], true
}

// The ideal-diode parameters of a D model card, nil for none (or another card).
lt_ideal_diode_params :: proc(card: string) -> []string {
	_, typ, keys, _, ok := model_card(card)
	if !ok || typ != "D" do return nil
	out := make([dynamic]string, context.temp_allocator)
	for k in keys do for p in LT_IDEAL_DIODE_PARAMS do if k == p do add_unique(&out, tcat(upper(k[:1]), k[1:]))
	return out[:] if len(out) > 0 else nil
}

// LTspice's text parameters of a model card: mfg=… and a type= that is not a number.
@(private = "file")
lt_text_param :: proc(card: string) -> string {
	_, _, keys, vals, ok := model_card(card)
	if !ok do return ""
	for k, i in keys {
		if k == "mfg" do return "mfg="
		if k == "type" && !is_number_token(vals[i]) do return "type="
	}
	return ""
}

Lt_Func_Use :: struct {
	fn:      ^Lt_Func,
	element: string, // "B1", or "B1 in subcircuit LTB"; ".param" / ".func" for those lines
}

// The functions the .func lines of a text define, as "<subcircuit>|<name>" (lower case): a
// .func in a subcircuit is its own, one outside it is everyone's ("|<name>").
defined_funcs :: proc(lines: []string) -> map[string]bool {
	out := make(map[string]bool, 4, context.temp_allocator)
	sub := ""
	for l in lines {
		low := lower(strings.trim_space(l))
		f := strings.fields(replace_parens(low), context.temp_allocator)
		switch {
		case strings.has_prefix(low, ".subckt"): sub = f[1] if len(f) > 1 else ""
		case strings.has_prefix(low, ".ends"): sub = ""
		case strings.has_prefix(low, ".func") && len(f) > 1: out[tcat(sub, "|", f[1])] = true
		}
	}
	return out
}

func_defined :: proc(funcs: map[string]bool, sub, name: string) -> bool {
	return funcs[tcat("|", name)] || funcs[tcat(lower(sub), "|", name)]
}

// The LTspice functions the cards use (each once per element), except those a .func defines.
// funcs: the .func's around them, when the cards are only some of the text.
lt_funcs_used :: proc(cards: []string, funcs: map[string]bool = nil, in_sub := "") -> []Lt_Func_Use {
	own := funcs if funcs != nil else defined_funcs(cards)
	out := make([dynamic]Lt_Func_Use, context.temp_allocator)
	sub := in_sub
	for c in cards {
		low := lower(c)
		if strings.has_prefix(low, ".subckt") {
			f := strings.fields(c, context.temp_allocator)
			sub = f[1] if len(f) > 1 else ""
			continue
		}
		if strings.has_prefix(low, ".ends") {
			sub = ""
			continue
		}
		if strings.has_prefix(low, ".model") || strings.has_prefix(low, ".lib") || strings.has_prefix(low, ".option") do continue
		f0 := strings.fields(c, context.temp_allocator)[0]
		// PSpice's TABLE sources ("E1 a b TABLE {V(x)} = …"), not the function
		source := low[0] == 'e' || low[0] == 'g'
		el := f0 if len(sub) == 0 else tcat(f0, " in subcircuit ", sub)
		seen := make(map[string]bool, 4, context.temp_allocator)
		// a name followed by "(", the name starting the word
		for i := 0; i < len(low); i += 1 {
			if !is_ident_start(low[i]) || (i > 0 && (is_ident_char(low[i - 1]) || low[i - 1] == '.' || low[i - 1] == '@')) do continue
			j := i
			for j < len(low) && is_ident_char(low[j]) do j += 1
			k := j
			for k < len(low) && low[k] == ' ' do k += 1
			name := low[i:j]
			if i == 0 || k >= len(low) || low[k] != '(' || func_defined(own, sub, name) || seen[name] {
				i = j - 1
				continue
			}
			if source && name == "table" {
				i = j - 1
				continue
			}
			for &fn in LT_FUNCS do if fn.name == name {
				seen[name] = true
				append(&out, Lt_Func_Use{&fn, el})
			}
			i = j - 1
		}
	}
	return out[:]
}

// What in a netlist only ngspice's LTspice compatibility mode reads, "" for nothing.
ltspice_feature :: proc(cards: []string) -> string {
	for c in cards {
		if p := lt_text_param(c); len(p) > 0 do return tcat("LTspice's ", p, " model parameter")
		if lt_ideal_diode_params(c) != nil do return "LTspice ideal diodes"
	}
	for u in lt_funcs_used(cards) do if u.fn.ngspice == "lt" do return tcat("LTspice's ", u.fn.name, "()")
	return ""
}

// The PSpice functions ngspice reads only in its PSpice mode (if(), int()), "" for none.
pspice_func_feature :: proc(cards: []string) -> string {
	for u in lt_funcs_used(cards) do if u.fn.ngspice == "ps" do return tcat(u.fn.name, "()")
	return ""
}

// Who has a function, for the message: "ngspice has it", "Xyce has it", "".
lt_func_where :: proc(fn: ^Lt_Func) -> string {
	ng, xy := !fn.no_ng, fn.xyce
	switch {
	case ng && xy: return "ngspice and Xyce have it"
	case ng: return "ngspice has it"
	case xy: return "Xyce has it"
	}
	return "neither ngspice nor Xyce has it"
}

lt_func_message :: proc(u: Lt_Func_Use, sim_name: string) -> string {
	msg := fmt.tprintf("%s: %s() is an LTspice function %s does not have (%s)", u.element, u.fn.name, sim_name, lt_func_where(u.fn))
	if len(u.fn.instead) > 0 do msg = tcat(msg, ". Correct: ", u.fn.instead)
	return msg
}

// The ideal-diode warning for a simulator that has none.
lt_ideal_diode_message :: proc(model: string, params: []string, sim_name: string) -> string {
	return fmt.tprintf("model %s: an LTspice ideal diode (%s): %s has no ideal diode and simulates a plain diode, with a wrong result. Correct: run it on ngspice", model, strings.join(params, ", ", context.temp_allocator), sim_name)
}

// The cards of a netlist the circuit uses: its top-level lines, then each subcircuit an element
// reaches (".subckt NAME" … ".ends") and the models they name. A simulator reads the rest of an
// .include'd library without complaint, whatever is in it.
lt_used_cards :: proc(cards: []string) -> []string {
	top := make([dynamic]string, context.temp_allocator)
	subs := make(map[string][dynamic]string, 8, context.temp_allocator)
	names := make(map[string]string, 8, context.temp_allocator) // as written
	models := make(map[string]string, 8, context.temp_allocator)
	stack := make([dynamic]string, context.temp_allocator)
	for c in cards {
		low := lower(c)
		f := strings.fields(replace_parens(low), context.temp_allocator)
		if strings.has_prefix(low, ".subckt") && len(f) > 1 {
			append(&stack, f[1])
			subs[f[1]] = make([dynamic]string, context.temp_allocator)
			names[f[1]] = strings.fields(replace_parens(c), context.temp_allocator)[1]
			continue
		}
		if strings.has_prefix(low, ".ends") {
			if len(stack) > 0 do pop(&stack)
			continue
		}
		if strings.has_prefix(low, ".model") && len(f) > 1 {
			models[f[1]] = c
			continue
		}
		if len(stack) > 0 do append(&subs[stack[len(stack) - 1]], c)
		else do append(&top, c)
	}
	out := make([dynamic]string, context.temp_allocator)
	used := make(map[string]bool, 8, context.temp_allocator)
	refer :: proc(lines: []string, subs: map[string][dynamic]string, names, models: map[string]string, used: ^map[string]bool, out: ^[dynamic]string) {
		for l in lines do for w in strings.fields(replace_parens(lower(l)), context.temp_allocator) {
			if used[w] do continue
			if m, ok := models[w]; ok {
				used[w] = true
				append(out, m)
			}
			if body, ok := subs[w]; ok {
				used[w] = true
				append(out, tcat(".subckt ", names[w]))
				start := len(out)
				append(out, ..body[:])
				append(out, ".ends")
				inner := make([]string, len(out) - start - 1, context.temp_allocator)
				copy(inner, out[start:len(out) - 1])
				refer(inner, subs, names, models, used, out)
			}
		}
	}
	append(&out, ..top[:])
	refer(top[:], subs, names, models, &used, &out)
	return out[:]
}

// Before a SPICE run: what this simulator cannot run (errors), or runs wrongly (warnings).
// ngspice's modes are chosen in netlist_build.
lt_check_netlist :: proc(nl: ^Netlist, cards: []string, sim: ^Simulator_Def) {
	ng, xy := sim_is_ngspice(sim), sim_is_xyce(sim)
	if !ng && !xy do return
	name := "ngspice" if ng else "Xyce"
	used := lt_used_cards(cards)
	for u in lt_funcs_used(used, defined_funcs(cards)) {
		if (ng && u.fn.no_ng) || (xy && !u.fn.xyce) do append(&nl.errors, lt_func_message(u, name))
	}
	if !xy do return
	for c in used {
		mname, typ, _, _, ok := model_card(c)
		if !ok do continue
		if typ == "VDMOS" do append(&nl.errors, fmt.tprintf("model %s: VDMOS (an LTspice power MOSFET) is not a Xyce model. Correct: run it on ngspice or VACASK", mname))
		lt_diode_warn(nl, c, "Xyce")
	}
}

// The warning for an LTspice ideal diode on a simulator that has none (Xyce, VACASK).
lt_diode_warn :: proc(nl: ^Netlist, card, sim_name: string) {
	p := lt_ideal_diode_params(card)
	if p == nil do return
	name, _, _, _, _ := model_card(card)
	add_unique(&nl.warnings, lt_ideal_diode_message(name, p, sim_name))
}

// LTspice's instance parameters of R, C, L and V parts (from a SpiceLine: "10u Rser=5m
// Lser=1n"), which no simulator here reads, as spicy's non-ideal values of the part (its
// ESR, ESL, … which every simulator runs). LTspice's equivalent circuits (its help, "C.
// Capacitor" …): a capacitor is Rser, C and Lser in series, Rpar and Cpar across the whole;
// an inductor Rser and L in series, Rpar and Cpar across the whole; a voltage source Rser in
// series, Cpar across. spicy's leakage resistance is across the capacitance alone, not with
// the ESR and ESL: a difference of Rser / Rpar (1e-9 for 1 mOhm and 1 MOhm).
Lt_Inst_Param :: struct {
	prefix:  u8, // the part's (spicy symbol's) prefix
	lt, key: string, // LTspice's name (lower case), spicy's
}

@(private = "file")
LT_INST_PARAMS := []Lt_Inst_Param {
	{'C', "rser", "esr"}, {'C', "lser", "esl"}, {'C', "rpar", "rleak"}, {'C', "v", "vmax"},
	{'L', "rser", "dcr"}, {'L', "rpar", "rpar"}, {'L', "cpar", "cpar"}, {'L', "ipk", "imax"},
	{'V', "rser", "rser"},
	{'R', "pwr", "pmax"}, {'R', "tol", "tol"},
}

// LTspice's part data that is not simulated: kept with the part as it is.
@(private = "file")
LT_INST_NOTES := []string{"mfg", "pn", "type", "irms"}

// LTspice parameters spicy has no element for: left out, with a warning.
@(private = "file")
LT_INST_MISSING := []Lt_Inst_Param {
	{'C', "cpar", "capacitance across a capacitor"},
	{'C', "rlshunt", "resistance across a capacitor's ESL"},
	{'V', "cpar", "capacitance across a voltage source"},
}

// The words of a part's value: spaces inside "…" and (…) do not split.
@(private = "file")
value_words :: proc(v: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	depth, quoted, start := 0, false, -1
	for i := 0; i <= len(v); i += 1 {
		ch: u8 = ' ' if i == len(v) else v[i]
		if quoted {
			if ch == '"' do quoted = false
			continue
		}
		switch ch {
		case '"': quoted = true
		case '(': depth += 1
		case ')': depth = max(depth - 1, 0)
		case ' ', '\t':
			if depth == 0 {
				if start >= 0 do append(&out, v[start:i])
				start = -1
				continue
			}
		}
		if start < 0 do start = i
	}
	return out[:]
}

// Moves LTspice's instance parameters out of the part's value into its non-ideal values
// (and its notes); a warning for each one spicy cannot simulate. Parts with no non-ideal
// values (subcircuits, diodes …) are left as they are.
lt_instance_params :: proc(c: ^Comp, warnings: ^[dynamic]string) {
	sym := symbol_find(c.sym)
	if len(nonideal_params(sym)) == 0 do return
	prefix := upper(sym.prefix)[0]
	kept := make([dynamic]string, context.temp_allocator)
	changed := false
	words: for w in value_words(c.value) {
		eq := strings.index_byte(w, '=')
		if eq <= 0 {
			append(&kept, w)
			continue
		}
		name := lower(strings.trim_space(w[:eq]))
		val := strings.trim(strings.trim_space(w[eq + 1:]), "\"")
		for p in LT_INST_MISSING do if p.prefix == prefix && p.lt == name {
			if x, ok := parse_eng(val); !ok || x != 0 {
				append(warnings, fmt.tprintf("%s: LTspice's %s left out (spicy has no %s)", c.ref, w, p.key))
			}
			changed = true
			continue words
		}
		key, note := "", false
		for p in LT_INST_PARAMS do if p.prefix == prefix && p.lt == name do key = p.key
		for n in LT_INST_NOTES do if n == name do key, note = n, true
		if len(key) == 0 {
			append(&kept, w)
			continue
		}
		changed = true
		if x, ok := parse_eng(val); ok && x == 0 && !note do continue // 0: ideal, as when unset
		comp_set_attr(c, key, val)
	}
	if changed do set_str(&c.value, strings.join(kept[:], " ", context.temp_allocator))
}
