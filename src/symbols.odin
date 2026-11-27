package spicy

import "core:fmt"
import "core:log"
import "core:math"
import os "core:os"
import "core:slice"
import "core:strings"

// Symbol library: symbols/standard.edn is built in; .edn files in the data folder's
// symbols/ and in :symbols {:folders […]} are read after it and replace symbols by name.

DEFAULT_SYMBOLS :: #load("../symbols/standard.edn", string)

Gfx_Kind :: enum u8 {Line, Rect, Circle, Arc, Poly, Text}
Gfx_Fill :: enum u8 {None, Line_Color, Body}

Gfx :: struct {
	kind: Gfx_Kind,
	pts:  [][2]f32, // line / poly points; rect: 2 corners; circle/arc: centre
	r:    f32,
	a0, a1: f32, // arc, degrees (0 = +x, 90 = +y / down)
	fill: Gfx_Fill,
	text: string,
	size: f32,
}

Pin_Def :: struct {
	name:    string,
	at:      [2]i32,
	cur:     string,
	element: string, // the SPICE element whose current is the pin's ("L{ref}_P" in a transformer)
}

Sym_Kind :: enum u8 {Part, Ground, Label}

Vacask_Def :: struct {
	line:   string,
	loads:  []string,
	models: []string,
	defs:   string,
}

Symbol :: struct {
	name, desc, category, prefix, key, value: string,
	editor:   Value_Editor,
	models:   []string,
	kind:     Sym_Kind,
	pins:     []Pin_Def,
	gfx:      []Gfx,
	spice:    string,
	defs:     string,
	vacask:   Vacask_Def,
	cur:      string,
	probe:    Probe,
	ref_at:   [2]f32,
	value_at: [2]f32,
	has_ref_at, has_value_at: bool,
	lo, hi:   [2]f32, // bounds (unrotated)
	source:   string, // file it came from
	edn:      string, // the symbol's map as written (copied into schematics that use it)
	like:     string, // :like
}

// How the part dialog edits a part's value (:editor).
Value_Editor :: enum u8 {
	Text, // a line of text
	Model, // a model name, chosen from the library
	Source, // a voltage or current source: DC, a waveform, AC
}
VALUE_EDITOR_NAMES := [Value_Editor]string{.Text = "text", .Model = "model", .Source = "source"}

// What a part's current probe measures (:probe).
Probe :: enum u8 {
	Device, // the current into each pin (a sense source in series when the simulator has no pin currents)
	Source, // the part is a source: its own current
	None, // no current (a ground, a label …)
}
PROBE_NAMES := [Probe]string{.Device = "device", .Source = "source", .None = "none"}

symbols: [dynamic]Symbol
symbols_gen: int // bumped whenever symbols change (the parts picker rebuilds its list then)

symbol_find :: proc(name: string) -> ^Symbol {
	for &s in symbols do if s.name == name do return &s
	return nil
}

user_symbols_dir :: proc() -> string {return path_join(data_dir(), "symbols")}

symbols_load :: proc() {
	clear(&symbols)
	symbols_gen += 1
	parse_symbols(DEFAULT_SYMBOLS, "built-in symbols")
	dirs := make([dynamic]string, context.temp_allocator)
	ud := user_symbols_dir()
	if !dir_exists(ud) {
		os.make_directory_all(ud)
		write_text(path_join(ud, "my-symbols.edn"), MY_SYMBOLS_TEMPLATE)
	}
	append(&dirs, ud)
	for f in S.symbol_folders do append(&dirs, f)
	for d in dirs {
		_, files := list_dir(d, {"edn"})
		for f in files {
			p := path_join(d, f)
			text, ok := read_text(p, context.temp_allocator)
			if !ok do continue
			parse_symbols(strings.clone(text), p)
			watch_file(p, symbols_reload)
		}
	}
	log.debugf("%d symbols", len(symbols))
}

symbols_reload :: proc() {
	clear(&config_errors)
	symbols_load()
	for d in app.docs do register_embedded_symbols(&d.sch, d.path)
	app_settings_changed()
}

MY_SYMBOLS_TEMPLATE :: `;; Your own symbols (EDN): a vector of symbol maps in the format of the built-in library
;; (see the README, or symbols/standard.edn in the spicy sources). A symbol with the :name of
;; a built-in one replaces it. spicy reloads this file when you save it. Example:
;;
;; [{:name "res" :desc "Resistor (box)" :category "Passive" :prefix "R" :key "R" :value "1k"
;;   :pins [{:name "A" :at [16 16]} {:name "B" :at [16 96]}]
;;   :spice "{ref} {A} {B} {value}"
;;   :vacask {:line "{ref} ({A} {B}) spicy_r r={value}" :load ["spice/resistor.osdi"]
;;            :models ["model spicy_r sp_resistor"]}
;;   :ref-at [36 44] :value-at [36 70]
;;   :graphics [[:line 16 16 16 32] [:rect 6 32 26 80] [:line 16 80 16 96]]}]
[]
`

@(private = "file")
num_list :: proc(v: Edn, from: int) -> (out: [dynamic]f32, rest: int) {
	out = make([dynamic]f32)
	i := from
	for i < len(v.items) && edn_is_num(v.items[i]) {
		append(&out, f32(edn_num(v.items[i])))
		i += 1
	}
	return out, i
}

// The symbols a schematic carries that this spicy does not have (a file from someone else):
// added under their own names; symbols of the same name here win.
register_embedded_symbols :: proc(s: ^Schematic, path: string) {
	for t in s.embedded_sym {
		v, err := edn_parse(t, context.temp_allocator)
		if len(err) > 0 || v.kind != .Map do continue
		if symbol_find(edn_str(v, "name")) != nil do continue
		parse_symbols(tcat("[", t, "]"), tcat("embedded in ", base_name(path)))
	}
}

parse_symbols :: proc(text, src: string) {
	v, err := edn_parse(text)
	if len(err) > 0 {
		config_error(tcat(src, ": ", err))
		return
	}
	if !edn_is_coll(v) {
		config_error(tcat(src, ": expected a vector of symbol maps"))
		return
	}
	for m, idx in v.items {
		s, ok := symbol_from_edn(m, src, fmt.tprintf("%s, symbol %d", src, idx + 1))
		if !ok do continue
		s.edn = strings.clone(edn_to_string(m, context.allocator))
		// replace an existing symbol with the same name
		replaced := false
		for &x in symbols do if x.name == s.name {
			x = s
			replaced = true
		}
		if !replaced do append(&symbols, s)
		symbols_gen += 1
	}
}

// One symbol from its EDN map (errors go to the config errors; ok false: unusable).
symbol_from_edn :: proc(m: Edn, src, ctx_in: string) -> (s: Symbol, ok: bool) {
	ctx := ctx_in
	if m.kind != .Map {
		config_error(tcat(ctx, ": not a map"))
		return {}, false
	}
	s = Symbol{source = strings.clone(src)}
	s.name = strings.clone(edn_str(m, "name"))
	if is_blank(s.name) {
		config_error(tcat(ctx, ": :name is missing"))
		return {}, false
	}
	ctx = tcat(src, ", symbol \"", s.name, "\"")
	// :like "nmos" starts from another symbol: its pins, graphics, netlist lines …
	base: ^Symbol
	if like := edn_str(m, "like"); len(like) > 0 {
		base = symbol_find(like)
		if base == nil {
			config_error(tcat(ctx, ": :like \"", like, "\" is not a known symbol"))
			return {}, false
		}
		name := s.name
		s = base^
		s.name = name
		s.source = strings.clone(src)
		s.key = "" // never the key of the other symbol
		s.like = strings.clone(like)
	}
	str :: proc(m: Edn, k, def: string, base_val: string, base: ^Symbol) -> string {
		return strings.clone(edn_str(m, k, base_val if base != nil else def))
	}
	s.desc = str(m, "desc", s.name, s.desc, base)
	s.category = str(m, "category", "Other", s.category, base)
	s.prefix = str(m, "prefix", "X", s.prefix, base)
	s.key = strings.clone(edn_str(m, "key"))
	s.value = str(m, "value", "", s.value, base)
	keyword :: proc(m: Edn, k: string, names: [$E]string, base_val: E, ctx: string) -> E {
		v, has := edn_get(m, k)
		if !has do return base_val
		if e, ok := enum_from_name(names, v.s); ok && (v.kind == .Keyword || v.kind == .String) do return e
		choices := make([dynamic]string, context.temp_allocator)
		for n in names do append(&choices, tcat(":", n))
		config_error(fmt.tprintf("%s: :%s %s is not one of %s", ctx, k, edn_to_string(v), strings.join(choices[:], " ", context.temp_allocator)))
		return base_val
	}
	s.editor = keyword(m, "editor", VALUE_EDITOR_NAMES, s.editor, ctx)
	s.spice = str(m, "spice", "", s.spice, base)
	s.defs = str(m, "defs", "", s.defs, base)
	s.cur = str(m, "cur", "", s.cur, base)
	s.probe = keyword(m, "probe", PROBE_NAMES, s.probe, ctx)
	if base == nil || edn_has(m, "kind") {
		switch edn_str(m, "kind", "part") {
		case "ground": s.kind = .Ground
		case "label": s.kind = .Label
		case: s.kind = .Part
		}
	}
	if mv, has := edn_get(m, "models"); has && edn_is_coll(mv) {
		ms := make([dynamic]string)
		for x in mv.items do append(&ms, strings.clone(x.s))
		s.models = ms[:]
	}
	if vv, has := edn_get(m, "vacask"); has && vv.kind == .Map {
		s.vacask.line = strings.clone(edn_str(vv, "line"))
		s.vacask.defs = strings.clone(edn_str(vv, "defs"))
		strs :: proc(m: Edn, k: string) -> []string {
			out := make([dynamic]string)
			if x, ok := edn_get(m, k); ok {
				if edn_is_coll(x) do for y in x.items do append(&out, strings.clone(y.s))
				else if x.kind == .String do append(&out, strings.clone(x.s))
			}
			return out[:]
		}
		s.vacask.loads = strs(vv, "load")
		s.vacask.models = strs(vv, "models")
	}
	at :: proc(m: Edn, k: string) -> ([2]f32, bool) {
		x, ok := edn_get(m, k)
		if !ok || !edn_is_coll(x) || len(x.items) < 2 do return {}, false
		return {f32(edn_num(x.items[0])), f32(edn_num(x.items[1]))}, true
	}
	if base == nil || edn_has(m, "ref-at") do s.ref_at, s.has_ref_at = at(m, "ref-at")
	if base == nil || edn_has(m, "value-at") do s.value_at, s.has_value_at = at(m, "value-at")
	// pins
	pins := make([dynamic]Pin_Def)
	if base != nil && !edn_has(m, "pins") do append(&pins, ..base.pins)
	if pv, has := edn_get(m, "pins"); has && edn_is_coll(pv) {
		for p in pv.items {
			pd := Pin_Def{name = strings.clone(edn_str(p, "name")), cur = strings.clone(edn_str(p, "cur")), element = strings.clone(edn_str(p, "element"))}
			a, aok := at(p, "at")
			if !aok {
				config_error(tcat(ctx, ": pin without :at [x y]"))
				continue
			}
			pd.at = {i32(math.round(a.x)), i32(math.round(a.y))}
			append(&pins, pd)
		}
	}
	s.pins = pins[:]
	if len(s.pins) == 0 {
		config_error(tcat(ctx, ": no :pins"))
		return {}, false
	}
	// graphics
	gfx := make([dynamic]Gfx)
	if base != nil && !edn_has(m, "graphics") do append(&gfx, ..base.gfx)
	if gv, has := edn_get(m, "graphics"); has && edn_is_coll(gv) {
		for g in gv.items {
			if !edn_is_coll(g) || len(g.items) == 0 || g.items[0].kind != .Keyword {
				config_error(tcat(ctx, ": a graphics item must look like [:line x y x y …]"))
				continue
			}
			kw := g.items[0].s
			nums, rest := num_list(g, 1)
			gi := Gfx{}
			fill := Gfx_Fill.None
			text := ""
			size: f32 = 12
			for k := rest; k < len(g.items); k += 1 {
				it := g.items[k]
				if it.kind == .Keyword && it.s == "fill" do fill = .Line_Color
				if it.kind == .Keyword && it.s == "body" do fill = .Body
				if it.kind == .String do text = strings.clone(it.s)
				if it.kind == .Keyword && it.s == "size" && k + 1 < len(g.items) do size = f32(edn_num(g.items[k + 1]))
			}
			pts_of :: proc(n: []f32) -> [][2]f32 {
				p := make([][2]f32, len(n) / 2)
				for i in 0 ..< len(p) do p[i] = {n[2 * i], n[2 * i + 1]}
				return p
			}
			switch kw {
			case "line":
				if len(nums) < 4 {config_error(tcat(ctx, ": [:line …] needs at least 2 points")); continue}
				gi = {kind = .Line, pts = pts_of(nums[:])}
			case "poly":
				if len(nums) < 6 {config_error(tcat(ctx, ": [:poly …] needs at least 3 points")); continue}
				gi = {kind = .Poly, pts = pts_of(nums[:]), fill = fill}
			case "rect":
				if len(nums) < 4 {config_error(tcat(ctx, ": [:rect x0 y0 x1 y1]")); continue}
				gi = {kind = .Rect, pts = pts_of(nums[:4]), fill = fill}
			case "circle":
				if len(nums) < 3 {config_error(tcat(ctx, ": [:circle cx cy r]")); continue}
				gi = {kind = .Circle, pts = pts_of(nums[:2]), r = nums[2], fill = fill}
			case "arc":
				if len(nums) < 5 {config_error(tcat(ctx, ": [:arc cx cy r from to]")); continue}
				gi = {kind = .Arc, pts = pts_of(nums[:2]), r = nums[2], a0 = nums[3], a1 = nums[4]}
			case "text":
				if len(nums) < 2 {config_error(tcat(ctx, ": [:text x y \"…\"]")); continue}
				gi = {kind = .Text, pts = pts_of(nums[:2]), text = text, size = size}
			case:
				config_error(tcat(ctx, ": unknown graphics item :", kw))
				continue
			}
			append(&gfx, gi)
		}
	}
	s.gfx = gfx[:]
	symbol_bounds(&s)
	if s.kind == .Part && len(s.spice) == 0 do config_error(tcat(ctx, ": :spice is missing"))
	return s, true
}

symbol_bounds :: proc(s: ^Symbol) {
	lo := [2]f32{1e9, 1e9}
	hi := [2]f32{-1e9, -1e9}
	add :: proc(lo, hi: ^[2]f32, p: [2]f32) {
		lo.x = min(lo.x, p.x); lo.y = min(lo.y, p.y)
		hi.x = max(hi.x, p.x); hi.y = max(hi.y, p.y)
	}
	for p in s.pins do add(&lo, &hi, {f32(p.at.x), f32(p.at.y)})
	for g in s.gfx {
		switch g.kind {
		case .Line, .Poly, .Rect: for p in g.pts do add(&lo, &hi, p)
		case .Circle, .Arc:
			add(&lo, &hi, g.pts[0] - g.r)
			add(&lo, &hi, g.pts[0] + g.r)
		case .Text: add(&lo, &hi, g.pts[0])
		}
	}
	if s.kind == .Ground {
		add(&lo, &hi, {-16, 0}); add(&lo, &hi, {16, 16})
	}
	if lo.x > hi.x {lo = {-8, -8}; hi = {8, 8}}
	s.lo, s.hi = lo, hi
}

// Symbols that can be placed (sorted by category, then description) for the part picker.
symbols_by_category :: proc() -> []^Symbol {
	Keyed :: struct {
		s:   ^Symbol,
		key: string,
	}
	k := make([]Keyed, len(symbols), context.temp_allocator)
	for &s, i in symbols do k[i] = {&s, lower(s.desc)}
	slice.stable_sort_by(k, proc(a, b: Keyed) -> bool {
		if a.s.category != b.s.category do return a.s.category < b.s.category
		return a.key < b.key
	})
	out := make([]^Symbol, len(k), context.temp_allocator)
	for x, i in k do out[i] = x.s
	return out
}

// A symbol as an EDN map with everything written out (no :like), in the library format.
symbol_to_edn :: proc(s: ^Symbol) -> string {
	b := strings.builder_make(context.temp_allocator)
	q :: proc(b: ^strings.Builder, key, val: string, always := false) {
		if len(val) == 0 && !always do return
		fmt.sbprintf(b, " :%s ", key)
		edn_quote(b, val)
	}
	n :: proc(f: f32) -> string {return fmt.tprintf("%g", f + 0)} // + 0: no "-0"
	strings.write_string(&b, " {:name ")
	edn_quote(&b, s.name)
	q(&b, "desc", s.desc)
	q(&b, "category", s.category)
	q(&b, "prefix", s.prefix)
	if len(s.key) > 0 do q(&b, "key", s.key)
	q(&b, "value", s.value, true)
	if s.editor != .Text do fmt.sbprintf(&b, " :editor :%s", VALUE_EDITOR_NAMES[s.editor])
	switch s.kind {
	case .Ground: strings.write_string(&b, " :kind :ground")
	case .Label: strings.write_string(&b, " :kind :label")
	case .Part:
	}
	if len(s.models) > 0 {
		strings.write_string(&b, " :models [")
		for x, i in s.models {
			if i > 0 do strings.write_byte(&b, ' ')
			edn_quote(&b, x)
		}
		strings.write_string(&b, "]")
	}
	q(&b, "cur", s.cur)
	if s.probe != .Device do fmt.sbprintf(&b, " :probe :%s", PROBE_NAMES[s.probe])
	strings.write_string(&b, "\n  :pins [")
	for p, i in s.pins {
		if i > 0 do strings.write_string(&b, " ")
		strings.write_string(&b, "{:name ")
		edn_quote(&b, p.name)
		fmt.sbprintf(&b, " :at [%d %d]", p.at.x, p.at.y)
		q(&b, "cur", p.cur)
		q(&b, "element", p.element)
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, "]\n  :spice ")
	edn_quote(&b, s.spice)
	if len(s.defs) > 0 {
		strings.write_string(&b, "\n  :defs ")
		edn_quote(&b, s.defs)
	}
	if len(s.vacask.line) > 0 {
		strings.write_string(&b, "\n  :vacask {:line ")
		edn_quote(&b, s.vacask.line)
		list :: proc(b: ^strings.Builder, key: string, xs: []string) {
			if len(xs) == 0 do return
			fmt.sbprintf(b, " :%s [", key)
			for x, i in xs {
				if i > 0 do strings.write_byte(b, ' ')
				edn_quote(b, x)
			}
			strings.write_string(b, "]")
		}
		list(&b, "load", s.vacask.loads)
		list(&b, "models", s.vacask.models)
		q(&b, "defs", s.vacask.defs)
		strings.write_string(&b, "}")
	}
	if s.has_ref_at do fmt.sbprintf(&b, "\n  :ref-at [%s %s]", n(s.ref_at.x), n(s.ref_at.y))
	if s.has_value_at do fmt.sbprintf(&b, " :value-at [%s %s]", n(s.value_at.x), n(s.value_at.y))
	strings.write_string(&b, "\n  :graphics [")
	for g, i in s.gfx {
		if i > 0 do strings.write_string(&b, "\n             " if i % 4 == 0 else " ")
		fill := ""
		switch g.fill {
		case .Line_Color: fill = " :fill"
		case .Body: fill = " :body"
		case .None:
		}
		switch g.kind {
		case .Line, .Poly:
			strings.write_string(&b, "[:line" if g.kind == .Line else "[:poly")
			for p in g.pts do fmt.sbprintf(&b, " %s %s", n(p.x), n(p.y))
			if g.kind == .Poly do strings.write_string(&b, fill)
			strings.write_string(&b, "]")
		case .Rect:
			fmt.sbprintf(&b, "[:rect %s %s %s %s%s]", n(g.pts[0].x), n(g.pts[0].y), n(g.pts[1].x), n(g.pts[1].y), fill)
		case .Circle:
			fmt.sbprintf(&b, "[:circle %s %s %s%s]", n(g.pts[0].x), n(g.pts[0].y), n(g.r), fill)
		case .Arc:
			fmt.sbprintf(&b, "[:arc %s %s %s %s %s]", n(g.pts[0].x), n(g.pts[0].y), n(g.r), n(g.a0), n(g.a1))
		case .Text:
			fmt.sbprintf(&b, "[:text %s %s ", n(g.pts[0].x), n(g.pts[0].y))
			edn_quote(&b, g.text)
			fmt.sbprintf(&b, " :size %s]", n(g.size))
		}
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

// Adds or replaces symbols (by name) in a symbol file; its leading ";;" comment lines stay
// (head when the file is new).
symbol_file_put :: proc(path, head: string, names, texts: []string) -> bool {
	keep := make([dynamic]string, context.temp_allocator)
	comments := head
	if old, ok := read_text(path, context.temp_allocator); ok {
		lines := split_lines(old)
		k := 0
		for k < len(lines) && strings.has_prefix(strings.trim_left_space(lines[k]), ";") do k += 1
		if k > 0 do comments = tcat(strings.join(lines[:k], "\n", context.temp_allocator), "\n")
		if v, err := edn_parse(old, context.temp_allocator); len(err) == 0 && edn_is_coll(v) {
			for m in v.items {
				nm := edn_str(m, "name")
				replaced := false
				for x in names do if x == nm do replaced = true
				if replaced do continue
				// kept as written (its layout and comments inside)
				if m.end > m.start && m.end <= len(old) {
					append(&keep, tcat(" ", old[m.start:m.end]))
				} else {
					b := strings.builder_make(context.temp_allocator)
					strings.write_byte(&b, ' ')
					edn_write(&b, m)
					append(&keep, strings.to_string(b))
				}
			}
		}
	}
	append(&keep, ..texts)
	os.make_directory_all(dir_name(path))
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, comments)
	strings.write_string(&b, "[\n")
	for t in keep {
		strings.write_string(&b, t)
		strings.write_string(&b, "\n\n")
	}
	strings.write_string(&b, "]\n")
	return write_text(path, strings.to_string(b))
}
