package spicy

import "core:math"
import "core:mem/virtual"
import "core:strings"

// The model catalog: the models and subcircuits of the libraries that a part can use, each
// with its kind (Rectifier, Zener, N-MOSFET …) and ratings, for the parts picker's tiles and
// the model table. Each comes from, in this order: what the user gave it in the model table
// (model-info.edn, beside the model files, which stay as they are), the vendor's "*SRC=" line
// ("*SRC=1N4001G;DI_1N4001G;Diodes;Si;  50.0V  1.00A  2.00us   Glass Passivated Rectifier"),
// the model's own values (BV=, LTspice's Vrev= Iave= Vceo= Icrating= Vds= Ron= type= mfg=).
// Nothing is guessed: what nothing states stays blank.

// The ratings, by quantity (the table names them by device: VR, Vz, VCEO, VDS …).
Rating :: enum u8 {V, I, P, R, T, F}

RATING_UNIT := [Rating]string {
	.V = "V",
	.I = "A",
	.P = "W",
	.R = "Ω",
	.T = "s",
	.F = "Hz",
}

// What of a row the user gave (model-info.edn).
Row_Field :: enum u8 {Kind, V, I, P, R, T, F, Desc}

Catalog_Row :: struct {
	name:   string, // as the file writes it
	key:    string, // lower case: model_lib's name
	kind:   string, // a KINDS name
	symbol: string, // the symbol a part with this model is placed as ("": none fits)
	rating: [Rating]f64, // NaN: not stated
	desc:   string,
	file:   string,
	mine:   bit_set[Row_Field],
	// what the file states (before what the user gave): the model table compares with it
	file_kind:   string,
	file_rating: [Rating]f64,
	file_desc:   string,
}

Kind_Def :: struct {
	name, family, symbol: string, // family: the parts picker's category; symbol: the generic one
	device:               string, // what the model is: D NPN PNP NMOS PMOS NJF PJF SW OPAMP SUB
}

// In the order the picker shows them.
KINDS := [?]Kind_Def {
	{"Rectifier", "Diodes", "diode", "D"},
	{"Switching", "Diodes", "diode", "D"},
	{"Schottky", "Diodes", "schottky", "D"},
	{"Zener", "Diodes", "zener", "D"},
	{"TVS", "Diodes", "zener", "D"},
	{"LED", "Diodes", "led", "D"},
	{"Diode", "Diodes", "diode", "D"},
	{"NPN", "Transistors", "npn", "NPN"},
	{"PNP", "Transistors", "pnp", "PNP"},
	{"N-MOSFET", "Transistors", "nmos", "NMOS"},
	{"P-MOSFET", "Transistors", "pmos", "PMOS"},
	{"N-JFET", "Transistors", "njf", "NJF"},
	{"P-JFET", "Transistors", "pjf", "PJF"},
	{"Op-amp", "Amplifiers", "opamp", "OPAMP"},
	{"Switch", "Sources", "sw", "SW"},
	{"Subcircuit", "Imported", "", "SUB"},
}

// The ratings a kind of device has (the others mean nothing for it).
device_ratings :: proc(kind: string) -> bit_set[Rating] {
	k := kind_def(kind)
	if k == nil do return ~bit_set[Rating]{}
	switch k.device {
	case "D": return {.V, .I, .P, .T}
	case "NPN", "PNP": return {.V, .I, .P, .F}
	case "NMOS", "PMOS", "NJF", "PJF": return {.V, .I, .P, .R}
	}
	return ~bit_set[Rating]{}
}

kind_def :: proc(name: string) -> ^Kind_Def {
	for &k in KINDS do if k.name == name do return &k
	return nil
}

// The kinds a row of this kind may be given in the model table: those of the same device (a
// diode stays a diode).
kinds_like :: proc(kind: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	k := kind_def(kind)
	if k == nil do return out[:]
	for x in KINDS do if x.device == k.device do append(&out, x.name)
	return out[:]
}

models_gen: int // bumped whenever the model libraries are read again (models_load)

@(private = "file")
catalog: struct {
	rows:              [dynamic]Catalog_Row,
	arena:             virtual.Arena,
	ready:             bool,
	mgen, sgen, igen:  int,
}

@(private = "file")
info_gen: int // bumped when model-info.edn is written

@(private = "file")
built_gen: int // bumped each time the catalog is built

// Changes whenever the catalog is built again (the model table copies its rows).
catalog_gen :: proc() -> int {
	_ = catalog_rows()
	return built_gen
}

// The catalog, built again when the libraries, the symbols or model-info.edn changed.
catalog_rows :: proc() -> []Catalog_Row {
	c := &catalog
	if c.ready && c.mgen == models_gen && c.sgen == symbols_gen && c.igen == info_gen do return c.rows[:]
	if !c.ready {
		_ = virtual.arena_init_growing(&c.arena)
		c.rows = make([dynamic]Catalog_Row, virtual.arena_allocator(&c.arena))
	} else {
		virtual.arena_free_all(&c.arena)
		c.rows = make([dynamic]Catalog_Row, virtual.arena_allocator(&c.arena))
	}
	c.ready, c.mgen, c.sgen, c.igen = true, models_gen, symbols_gen, info_gen
	built_gen += 1
	info := model_info_load()
	context.allocator = virtual.arena_allocator(&c.arena)
	seen := make(map[string]bool, 1024, context.temp_allocator)
	// the libraries file by file (model_lib keeps a file's entries together): what a file's
	// subcircuits use is part of them, not a part of its own
	for i := 0; i < len(model_lib); {
		j := i + 1
		for j < len(model_lib) && model_lib[j].file == model_lib[i].file && model_lib[j].origin == model_lib[i].origin do j += 1
		group := model_lib[i:j]
		called := subckts_called(group)
		used := make(map[string]bool, 64, context.temp_allocator)
		for &e in group do if e.subckt {
			q := make([dynamic]string, context.temp_allocator)
			card_refs(&q, e.text)
			for w in q do used[w] = true
		}
		for &e in group {
			if seen[e.name] do continue // the first of a name is the one used (lib_find)
			seen[e.name] = true
			if (e.subckt && called[e.name]) || (!e.subckt && used[e.name]) do continue
			row, ok := catalog_row(&e)
			if !ok do continue
			if mi, has := info[e.name]; has do model_info_apply(&row, mi)
			row.symbol = row_symbol(&e, row.kind)
			append(&c.rows, row)
		}
		i = j
	}
	return c.rows[:]
}

// A library entry as a row (strings in the context allocator); false: no kind spicy knows.
catalog_row :: proc(e: ^Lib_Entry) -> (row: Catalog_Row, ok: bool) {
	dev := entry_device(e)
	if len(dev) == 0 do return
	row.name = strings.clone(entry_display_name(e))
	row.key = strings.clone(e.name)
	row.file = strings.clone(base_name(e.file) if e.origin != .Builtin else "built-in")
	for &r in row.rating do r = math.nan_f64()
	desc := ""
	cat := ""
	if len(e.src) > 0 do cat, desc = src_ratings(e.src, &row.rating)
	params := card_values(e)
	// the model's own values, for what the vendor's line does not state
	if !e.subckt {
		set :: proc(row: ^Catalog_Row, r: Rating, params: map[string]string, keys: ..string) {
			if !math.is_nan(row.rating[r]) do return
			for k in keys do if v, has := params[k]; has {
				if x, ok := parse_eng(v); ok {
					row.rating[r] = x
					return
				}
			}
		}
		switch dev {
		case "D": set(&row, .V, params, "vrev", "bv"); set(&row, .I, params, "iave", "ipk")
		case "NPN", "PNP": set(&row, .V, params, "vceo"); set(&row, .I, params, "icrating")
		case "NMOS", "PMOS": set(&row, .V, params, "vds"); set(&row, .R, params, "ron")
		}
	}
	if len(desc) == 0 do if m, has := params["mfg"]; has do desc = strings.trim(m, "\"'")
	row.desc = strings.clone(desc)
	row.kind = entry_kind(e, dev, cat, desc, params["type"])
	row.file_kind, row.file_rating, row.file_desc = row.kind, row.rating, row.desc
	return row, true
}

// What an entry is: D NPN PNP NMOS PMOS NJF PJF SW (a .model card's type), OPAMP (a
// subcircuit with an op-amp's pins), SUB (another subcircuit); "" for what no kind covers.
@(private = "file")
entry_device :: proc(e: ^Lib_Entry) -> string {
	if e.subckt {
		switch e.dev {
		case "D":
			if !diode_like(e) do return "SUB"
			return e.dev
		case "NPN", "PNP", "NMOS", "PMOS", "NJF", "PJF": return e.dev
		}
		if _, ok := opamp_symbol(e, e.name, ""); ok do return "OPAMP"
		return "SUB"
	}
	switch e.model_type {
	case "D", "NPN", "PNP", "NMOS", "PMOS", "NJF", "PJF", "SW": return e.model_type
	case "VDMOS": return "PMOS" if strings.contains(lower(e.text), "pchan") else "NMOS"
	}
	return ""
}

// A subcircuit with diodes in it that is a diode: two ports, or more (a dual diode, BAV99) of
// diodes and passives only. A TL431 (three ports, behavioural and controlled sources) is not.
@(private = "file")
diode_like :: proc(e: ^Lib_Entry) -> bool {
	if len(e.ports) <= 2 do return true
	for l, n in spice_lines(e.text) {
		if n == 0 || len(l) == 0 do continue
		switch l[0] {
		case 'B', 'b', 'E', 'e', 'F', 'f', 'G', 'g', 'H', 'h': return false
		}
	}
	return true
}

// A diode's kind from the words that name it: the vendor's category and description, then
// LTspice's type= parameter, then the file's name ("Diodes_Zeners.lib"). Other devices have
// one kind each.
@(private = "file")
entry_kind :: proc(e: ^Lib_Entry, dev, cat, desc, lt_type: string) -> string {
	switch dev {
	case "NPN": return "NPN"
	case "PNP": return "PNP"
	case "NMOS": return "N-MOSFET"
	case "PMOS": return "P-MOSFET"
	case "NJF": return "N-JFET"
	case "PJF": return "P-JFET"
	case "SW": return "Switch"
	case "OPAMP": return "Op-amp"
	case "SUB": return "Subcircuit"
	}
	file := base_name(e.file) if e.origin != .Builtin else ""
	for words in ([?]string{tcat(cat, " ", desc), lt_type, file}) {
		if k := diode_kind_in(words); len(k) > 0 do return k
	}
	return "Diode"
}

@(private = "file")
diode_kind_in :: proc(text: string) -> string {
	// words of letters and digits ("Diodes_TVS.lib" gives "diodes tvs lib")
	b := make([]u8, len(text), context.temp_allocator)
	for i in 0 ..< len(text) {
		ch := text[i] | 0x20 if text[i] >= 'A' && text[i] <= 'Z' else text[i]
		b[i] = ch if (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') else ' '
	}
	words := strings.fields(string(b), context.temp_allocator)
	has :: proc(words: []string, prefix: string) -> bool {
		for w in words do if strings.has_prefix(w, prefix) do return true
		return false
	}
	switch {
	case has(words, "zener"): return "Zener"
	case has(words, "tvs"): return "TVS"
	case has(words, "schottky"): return "Schottky"
	case has(words, "led"): return "LED"
	case has(words, "switching"): return "Switching"
	case has(words, "rectifier"): return "Rectifier"
	}
	return ""
}

// The ratings of a "*SRC=" line (after the "="), the first of each quantity; gives the
// category words before them and the description after them.
src_ratings :: proc(src: string, rating: ^[Rating]f64) -> (cat, desc: string) {
	f := strings.split(src, ";", context.temp_allocator)
	if len(f) < 3 do return
	rest := strings.join(f[2:], " ", context.temp_allocator)
	cats := make([dynamic]string, context.temp_allocator)
	descs := make([dynamic]string, context.temp_allocator)
	seen_rating := false
	for w in strings.fields(rest, context.temp_allocator) {
		if r, x, ok := rating_token(w); ok {
			if math.is_nan(rating[r]) do rating[r] = x
			seen_rating = true
			continue
		}
		if seen_rating do append(&descs, w)
		else do append(&cats, w)
	}
	cat = strings.join(cats[:], " ", context.temp_allocator)
	desc = strings.join(descs[:], " ", context.temp_allocator)
	if desc == "-" do desc = ""
	// "BJTs NPN; Darlington": the description says so
	if strings.contains(lower(cat), "darlington") && !strings.contains(lower(desc), "darlington") do desc = strings.trim_space(tcat("Darlington ", desc))
	return
}

// "50.0V" "0.115A" "0.300W" "3.20ohms" "2.00us" "250MHz": a number, an SI prefix and a unit.
rating_token :: proc(w: string) -> (r: Rating, x: f64, ok: bool) {
	if len(w) == 0 || !((w[0] >= '0' && w[0] <= '9') || w[0] == '.') do return
	low := lower(w)
	unit_len := 0
	switch {
	case strings.has_suffix(low, "ohms"): r, unit_len = .R, 4
	case strings.has_suffix(low, "ohm"): r, unit_len = .R, 3
	case strings.has_suffix(low, "hz"): r, unit_len = .F, 2
	case strings.has_suffix(low, "v"): r, unit_len = .V, 1
	case strings.has_suffix(low, "a"): r, unit_len = .I, 1
	case strings.has_suffix(low, "w"): r, unit_len = .P, 1
	case strings.has_suffix(low, "s"): r, unit_len = .T, 1
	case: return
	}
	v, vok := number_si(w[:len(w) - unit_len])
	if !vok do return
	return r, v, true
}

// "2.5", "250M", "4.7u", "100µ": a number with an SI prefix (M is mega here, as datasheets
// write it; in SPICE it is milli).
number_si :: proc(s: string) -> (f64, bool) {
	num := strings.trim_space(s)
	if len(num) == 0 do return 0, false
	scale := 1.0
	if strings.has_suffix(num, "µ") {
		scale, num = 1e-6, num[:len(num) - len("µ")]
	} else {
		switch num[len(num) - 1] {
		case 'p': scale = 1e-12
		case 'n': scale = 1e-9
		case 'u': scale = 1e-6
		case 'm': scale = 1e-3
		case 'k', 'K': scale = 1e3
		case 'M': scale = 1e6
		case 'G': scale = 1e9
		}
		if scale != 1 do num = num[:len(num) - 1]
	}
	v, ok := parse_number_plain(strings.trim_space(num)) // "200 m" (as rating_text writes it)
	return v * scale, ok
}

// A rating as the user types it: "50", "50V", "1.5 A", "250MHz", "77m", "77mΩ" (the unit,
// when written, must be the rating's own).
rating_parse :: proc(text: string, r: Rating) -> (f64, bool) {
	t := strings.trim_space(text)
	units: []string
	switch r {
	case .V: units = {"V", "v"}
	case .I: units = {"A", "a"}
	case .P: units = {"W", "w"}
	case .R: units = {"Ω", "ohms", "ohm", "Ohms", "Ohm"}
	case .T: units = {"s"}
	case .F: units = {"Hz", "hz", "HZ"}
	}
	for u in units do if strings.has_suffix(t, u) {
		t = t[:len(t) - len(u)]
		break
	}
	return number_si(t)
}

// A plain decimal number ("50.0", "1e-3"), nothing after it.
@(private = "file")
parse_number_plain :: proc(s: string) -> (f64, bool) {
	if len(s) == 0 do return 0, false
	for i in 0 ..< len(s) {
		c := s[i]
		if !((c >= '0' && c <= '9') || c == '.' || c == 'e' || c == 'E' || c == '-' || c == '+') do return 0, false
	}
	return parse_eng(s)
}

// A .model card's "k=v" values (keys in lower case); empty for a subcircuit (the values in
// it are those of its inner parts).
@(private = "file")
card_values :: proc(e: ^Lib_Entry) -> map[string]string {
	out := make(map[string]string, 16, context.temp_allocator)
	if e.subckt do return out
	spaced, _ := strings.replace_all(replace_parens(e.text), "=", " = ", context.temp_allocator)
	f := strings.fields(spaced, context.temp_allocator)
	for i := 0; i + 2 < len(f); i += 1 {
		if f[i + 1] == "=" && f[i] != "=" && f[i + 2] != "=" do out[lower(f[i])] = f[i + 2]
	}
	return out
}

// The symbol to place a row's model as: the symbol its import made (a subcircuit), else the
// kind's generic one when the model fits it.
@(private = "file")
row_symbol :: proc(e: ^Lib_Entry, kind: string) -> string {
	if s := symbol_find(entry_display_name(e)); s != nil && entry_fits_symbol(e, s) do return s.name
	if s := symbol_find(e.name); s != nil && entry_fits_symbol(e, s) do return s.name
	k := kind_def(kind)
	if k == nil || len(k.symbol) == 0 do return ""
	if s := symbol_find(k.symbol); s != nil && entry_fits_symbol(e, s) do return s.name
	return ""
}

// The rows of a kind, or of every kind of a family (kind ""), that can be placed.
catalog_count :: proc(family, kind: string) -> int {
	n := 0
	for &r in catalog_rows() {
		if len(r.symbol) == 0 do continue
		k := kind_def(r.kind)
		if k != nil && k.family == family && (kind == "" || r.kind == kind) do n += 1
	}
	return n
}

// ---------------------------------------------------------------------------
// model-info.edn: what the user gave models in the model table
//   {"1n4001g" {:kind "Rectifier" :V 50 :I 1 :desc "Glass passivated"}}
// A value of a key that is not there comes from the model file.

Model_Info :: struct {
	kind:   string,
	rating: [Rating]f64, // NaN: not given
	desc:   string,
	has:    bit_set[Row_Field],
}

RATING_KEY := [Rating]string {
	.V = "V",
	.I = "I",
	.P = "P",
	.R = "R",
	.T = "T",
	.F = "F",
}

// The names of the fields in model-info.edn and in --list models' :yours.
ROW_FIELD_KEY := [Row_Field]string {
	.Kind = "kind",
	.V    = "V",
	.I    = "I",
	.P    = "P",
	.R    = "R",
	.T    = "T",
	.F    = "F",
	.Desc = "desc",
}

model_info_path :: proc() -> string {return path_join(data_dir(), "model-info.edn")}

// The file's entries (temp allocator); errors go to the config errors.
model_info_load :: proc() -> map[string]Model_Info {
	out := make(map[string]Model_Info, 16, context.temp_allocator)
	text, ok := read_text(model_info_path(), context.temp_allocator)
	if !ok do return out
	v, err := edn_parse(text, context.temp_allocator)
	if len(err) > 0 || v.kind != .Map {
		config_error(tcat("model-info.edn: ", err if len(err) > 0 else "not a map"))
		return out
	}
	for i := 0; i + 1 < len(v.items); i += 2 {
		k, m := v.items[i], v.items[i + 1]
		if k.kind != .String || m.kind != .Map do continue
		mi: Model_Info
		for &r in mi.rating do r = math.nan_f64()
		if edn_has(m, "kind") {mi.kind = edn_str(m, "kind"); mi.has += {.Kind}}
		if edn_has(m, "desc") {mi.desc = edn_str(m, "desc"); mi.has += {.Desc}}
		for r in Rating {
			x, has := edn_get(m, RATING_KEY[r])
			if has && edn_is_num(x) {
				mi.rating[r] = edn_num(x)
				mi.has += {Row_Field(int(r) + 1)}
			}
		}
		out[lower(k.s)] = mi
	}
	return out
}

@(private = "file")
model_info_apply :: proc(row: ^Catalog_Row, mi: Model_Info) {
	// a kind of another device is not taken (a diode stays a diode)
	if .Kind in mi.has {
		for k in kinds_like(row.kind) do if k == mi.kind {
			row.kind = strings.clone(mi.kind)
			row.mine += {.Kind}
		}
	}
	if .Desc in mi.has {row.desc = strings.clone(mi.desc); row.mine += {.Desc}}
	for r in Rating do if Row_Field(int(r) + 1) in mi.has {
		row.rating[r] = mi.rating[r]
		row.mine += {Row_Field(int(r) + 1)}
	}
}

// Sets (or, with has false, forgets) what the user gave a model; writes model-info.edn.
// "" when written, else why not.
model_info_put :: proc(key: string, mi: Model_Info) -> string {
	all := model_info_load()
	k := lower(key)
	if card(mi.has) == 0 do delete_key(&all, k)
	else do all[k] = mi
	keys := make([dynamic]string, context.temp_allocator)
	for x in all do append(&keys, x)
	sort_strings(keys[:])
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, ";; What you gave models in spicy's model table: kinds and ratings the model files do\n;; not state (the files stay as they are). A key that is not there comes from the file.\n{")
	for x, i in keys {
		m := all[x]
		if i > 0 do strings.write_string(&b, "\n ")
		edn_quote(&b, x)
		strings.write_string(&b, " {")
		first := true
		sep :: proc(b: ^strings.Builder, first: ^bool) {
			if !first^ do strings.write_byte(b, ' ')
			first^ = false
		}
		if .Kind in m.has {sep(&b, &first); strings.write_string(&b, ":kind "); edn_quote(&b, m.kind)}
		for r in Rating do if Row_Field(int(r) + 1) in m.has {
			sep(&b, &first)
			strings.write_string(&b, tcat(":", RATING_KEY[r], " ", edn_float_str(m.rating[r])))
		}
		if .Desc in m.has {sep(&b, &first); strings.write_string(&b, ":desc "); edn_quote(&b, m.desc)}
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "}\n")
	if !write_text(model_info_path(), strings.to_string(b)) do return tcat("cannot write ", model_info_path())
	info_gen += 1
	return ""
}

// Gives a model the kind, ratings or description in fields ("kind", "V" … "F", "desc"; the
// rating keys as RATING_KEY): an empty value, or one the file states already, is not kept (the
// file's is used). Fields not named stay as they were. "" when saved, else why not.
model_info_set :: proc(key: string, fields: map[string]string) -> string {
	row: ^Catalog_Row
	for &r in catalog_rows() do if r.key == lower(key) do row = &r
	if row == nil do return tcat("no model ", key, " in the libraries (spicy --list models)")
	mi: Model_Info
	if old, ok := model_info_load()[row.key]; ok do mi = old
	else do for &x in mi.rating do x = math.nan_f64()
	for k, v in fields {
		t := strings.trim_space(v)
		switch {
		case k == "kind":
			mi.has -= {.Kind}
			if len(t) == 0 || t == row.file_kind do continue
			ok := false
			for x in kinds_like(row.file_kind) do if x == t do ok = true
			if !ok do return tcat("kind ", t, ": ", row.name, " can be ", strings.join(kinds_like(row.file_kind), ", ", context.temp_allocator))
			mi.kind = t
			mi.has += {.Kind}
		case k == "desc":
			mi.has -= {.Desc}
			if t == row.file_desc do continue
			mi.desc = t
			mi.has += {.Desc}
		case:
			q, found := Rating(0), false
			for r in Rating do if RATING_KEY[r] == k do q, found = r, true
			if !found do return tcat("unknown field ", k, " (kind, V, I, P, R, T, F, desc)")
			field := Row_Field(int(q) + 1)
			// as shown (3 digits): left as it was, not the rounded value
			if field in mi.has && t == rating_text(mi.rating[q], q) do continue
			mi.has -= {field}
			f := row.file_rating[q]
			if len(t) == 0 || (!math.is_nan(f) && t == rating_text(f, q)) do continue
			if q not_in device_ratings(row.file_kind) do return tcat(row.name, " (", row.file_kind, ") has no ", k, " rating")
			x, ok := rating_parse(t, q)
			if !ok do return tcat(k, ": \"", t, "\" is not a number (e.g. 50, 1.5", RATING_UNIT[q], ", 250M)")
			if !math.is_nan(f) && abs(x - f) <= 1e-9 * max(abs(x), abs(f)) do continue
			mi.rating[q] = x
			mi.has += {field}
		}
	}
	return model_info_put(row.key, mi)
}

// A rating as the table shows it ("" for none): 3 digits, an SI prefix, the unit.
rating_text :: proc(x: f64, r: Rating) -> string {
	if math.is_nan(x) do return ""
	return fmt_eng(x, RATING_UNIT[r], 3)
}
