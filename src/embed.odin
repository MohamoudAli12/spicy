package spicy

import "core:strings"

// Embedding: copies of the models and symbols a schematic uses, kept in the schematic file so
// that it simulates the same on every computer.

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
			for k in card_names(split_lines(t.text)) do defined_here[k] = true
			for l in split_lines(t.text) {
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
