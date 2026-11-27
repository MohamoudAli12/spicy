package spicy

import "core:fmt"
import "core:log"
import os "core:os"
import "core:strings"

// Importing a model file: it is copied into the data folder's models/ and every subcircuit
// in it gets a symbol (a transistor or diode symbol when the device is recognised, an op-amp
// triangle for an op-amp, else a box with one pin per port).

Import_Result :: struct {
	file:    string, // where the library was copied to
	symbols: [dynamic]string, // names of the symbols made
	models:   [dynamic]string, // .model names
	message:  string,
	repaired: int, // repairs made to the copy (model_repair)
}

// Where an import puts its copy: models/<name>.lib ("DMT10H003SPSWQ.spice.txt" → DMT10H003SPSWQ.lib).
import_dest :: proc(src: string) -> string {
	stem := base_name(src)
	if dot := strings.index_byte(stem, '.'); dot > 0 do stem = stem[:dot]
	return path_join(user_models_dir(), tcat(stem, ".lib"))
}

// Copies a SPICE model file into the models folder and makes a symbol for every
// subcircuit in it. The symbols go into symbols/imported.edn.
// repair: the copy gets model_repair's repairs (the file itself is not changed).
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
		parse_lib_into(&entries, text, .Library, src)
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
		if !e.subckt {
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
		if !e.subckt do continue
		n += 1
		for l in spice_cards(e.text) {
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
	for &e in entries do if e.subckt && called[e.name] do m += 1
	if m == n do clear(&called)
	return called
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

IMPORTED_SYMBOLS_HEAD :: `;; Symbols spicy made for imported SPICE models (File › Import SPICE model…).
;; Edit them freely; importing a model again replaces its symbol. Same format as
;; symbols/standard.edn; :like "nmos" takes everything from that symbol except what is given.
`

// Adds or replaces symbols (by name) in <data>/symbols/imported.edn.
imported_symbols_put :: proc(names, texts: []string) -> bool {
	return symbol_file_put(path_join(user_symbols_dir(), "imported.edn"), IMPORTED_SYMBOLS_HEAD, names, texts)
}
