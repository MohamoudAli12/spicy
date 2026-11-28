package spicy

import "core:log"
import "core:strings"

// Show SPICE model (a part's right-click menu, Edit › SPICE model): the card the netlist takes
// for the part's value, found as the netlist finds it (the schematic's directives and .include
// files, the copies saved in it, the libraries, spicy's defaults), with the models and
// subcircuits it uses after it, in a text window.

// The text shown for part ci of s (a schematic in base_dir, simulated with sim), or why
// there is none (msg).
comp_model_text :: proc(s: ^Schematic, ci: int, sim: ^Simulator_Def, base_dir: string) -> (title, text, msg: string) {
	c := &s.comps[ci]
	sym := symbol_find(c.sym)
	if sym == nil || sym.kind != .Part do return "", "", tcat(c.ref, " is not a part with a SPICE model")
	t := strings.trim_space(sym.spice)
	uses_model := sym.editor == .Model || (len(t) > 0 && (t[0] == 'X' || t[0] == 'x'))
	f := strings.fields(c.value, context.temp_allocator)
	if !uses_model || len(f) == 0 do return "", "", tcat(c.ref, " (", part_short_name(sym), ") has no model: its value is all it takes")
	name := lower(f[0])
	title = tcat(c.ref, ": the SPICE model ", f[0])
	local := sch_models(s, sim, base_dir)
	b := strings.builder_make(context.temp_allocator)
	e := model_lookup(name, local)
	if e != nil {
		from, _ := model_source(name, local)
		// a library's file by its name, its path on a line of its own
		if e.origin == .Library do from = base_name(e.file)
		strings.write_string(&b, tcat("* ", f[0], ", from ", from, "\n"))
		if e.origin == .Library do strings.write_string(&b, tcat("* ", e.file, "\n"))
		strings.write_string(&b, strings.trim_space(e.text))
		strings.write_byte(&b, '\n')
		// what it uses (an X line's subcircuit, a device's model), each once
		queue := make([dynamic]string, context.temp_allocator)
		card_refs(&queue, e.text)
		seen := make(map[string]bool, 16, context.temp_allocator)
		seen[name] = true
		for k in card_names(split_lines(e.text)) do seen[k] = true // defined inside it
		for len(queue) > 0 {
			n := queue[0]
			ordered_remove(&queue, 0)
			if seen[n] do continue
			seen[n] = true
			u := model_lookup(n, local)
			if u == nil do continue
			for k in card_names(split_lines(u.text)) do seen[k] = true
			ufrom, _ := model_source(n, local)
			if u.origin == .Library do ufrom = base_name(u.file)
			strings.write_string(&b, tcat("\n* used by it: ", entry_display_name(u), ", from ", ufrom, "\n"))
			strings.write_string(&b, strings.trim_space(u.text))
			strings.write_byte(&b, '\n')
			card_refs(&queue, u.text)
		}
		return title, strings.to_string(b), ""
	}
	// the symbol's own definition
	if card_names(split_lines(sym.defs))[name] {
		return title, tcat("* ", f[0], ", defined by the symbol ", sym.name, "\n", strings.trim_space(sym.defs), "\n"), ""
	}
	if sym.editor == .Model do for dm in DEFAULT_MODEL_CARDS do if dm[0] == name {
		note := "" if S.default_models else " (off in the settings: the netlist does not have it)"
		return title, tcat("* ", f[0], ", spicy's default card", note, "\n", dm[1], "\n"), ""
	}
	return "", "", tcat(c.ref, ": model ", f[0], " not found (File › Import SPICE model…, or a .model / .include directive)")
}

// Shows it in a text window; a status message says why not.
comp_show_model :: proc(d: ^Doc, ci: int) {
	title, text, msg := comp_model_text(&d.sch, ci, doc_sim(d), dir_of(d.path))
	if len(msg) > 0 {
		status(msg, true)
		return
	}
	log.infof("showing %s", title)
	show_text(title, text)
}
