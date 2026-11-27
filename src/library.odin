package spicy

import "core:strings"

// The model library: the .model and .subckt cards spicy finds by name (a part's value),
// read from the libraries in settings.edn, the imported model files and spicy's built-in
// models, and the ones a schematic defines itself.

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

MODEL_EXTS := []string{"lib", "mod", "sub", "subckt", "cir", "inc", "spice", "spi", "sp", "model", "txt", "ckt"}

user_models_dir :: proc() -> string {return path_join(data_dir(), "models")}

// The first entry of a name wins (lib_find): the libraries in settings.edn, then the imported
// ones, then spicy's built-in models, so a manufacturer's BSS84 replaces the generic one.
models_load :: proc() {
	clear(&model_lib)
	for p in S.model_libraries {
		text, ok := read_text(p, context.temp_allocator)
		if !ok {
			config_error(tcat("settings.edn: cannot read model library ", p))
			continue
		}
		parse_lib(strings.clone(text), p)
	}
	models_load_user()
	parse_lib(DEFAULT_MODELS_LIB, "built-in models")
}

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

// Reads the .model and .subckt cards of a SPICE library (continuation lines joined).
parse_lib :: proc(text, src: string) {parse_lib_into(&model_lib, text, src)}

parse_lib_into :: proc(list: ^[dynamic]Lib_Entry, text, src: string) {
	lines := split_lines(text)
	first := len(list^)
	defer {
		// subcircuits that use a .model card of the file from outside themselves
		types := make(map[string]string, 64, context.temp_allocator)
		for &e in list[first:] do if e.kind != "subckt" do types[e.name] = e.kind
		for &e in list[first:] do if e.kind == "subckt" && len(e.dev) == 0 do subckt_finish(&e, types)
	}
	i := 0
	for i < len(lines) {
		l := strings.trim_space(lines[i])
		low := lower(l)
		if strings.has_prefix(low, ".model") {
			card := strings.builder_make(context.temp_allocator)
			strings.write_string(&card, l)
			// its "+" lines (blank and comment lines between them are skipped, as SPICE reads them)
			j := card_end(lines, i, proc(l: string) -> string {return strings.trim_space(l)})
			for k in i + 1 ..< j {
				t := strings.trim_space(lines[k])
				if !strings.has_prefix(t, "+") do continue
				strings.write_byte(&card, '\n')
				// "+NK=0.7" as "+ NK=0.7": the parameter on its own
				strings.write_string(&card, "+ ")
				strings.write_string(&card, strings.trim_space(t[1:]))
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

lib_find :: proc(name: string) -> ^Lib_Entry {
	n := lower(name)
	for &e in model_lib do if e.name == n do return &e
	return nil
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

// The name as written in the card (models are stored lower case).
entry_display_name :: proc(e: ^Lib_Entry) -> string {
	f := strings.fields(replace_parens(e.text), context.temp_allocator)
	return f[1] if len(f) > 1 else e.name
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
