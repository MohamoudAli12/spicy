package spicy

import "core:fmt"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

// The model table: the models of a kind of part, one row each with its ratings, sorted by
// any column (click its heading; again for the other way round). Opened from a device tile of
// the parts picker (a pick places a part with that model) or from a part's editor (a pick is
// its value). Under the table, what the model files do not say can be given to the selected
// model (model-info.edn).

@(private = "file")
Col :: enum u8 {Name, Kind, V, I, P, R, T, F, Desc, File}

@(private = "file")
mt: struct {
	place:     bool, // a pick places a part; else it is the part editor's value
	title:     string,
	sym:       string, // the part editor's symbol: its models only
	family:    string, // placing: the family shown
	rows:      [dynamic]Catalog_Row, // strings in the arena
	shown:     [dynamic]int, // rows after the search and the kind, sorted
	kinds:     [dynamic]string, // "All kinds", then those of the rows
	kind:      int,
	search:    string,
	sort:      Col,
	desc:      bool,
	sel:       string, // the selected row's key
	gen:       int, // the catalog the rows were copied from
	shown_for: string, // search, kind and sort the shown rows are for
	arena:     virtual.Arena,
	ready:     bool,
	// what the user gives the selected model
	ed_key:    string,
	ed_kinds:  []string,
	ed_kind:   int,
	ed_val:    [Rating]string,
	ed_desc:   string,
	ed_sheet:  string,
}

// From a device tile of the parts picker: the models of a family, the tile's kind selected.
model_table_open_place :: proc(family, kind, search: string) {
	mt_reset()
	mt.place = true
	mt.family = strings.clone(family, mt_alloc())
	mt.title = strings.concatenate({family, ": pick a model to place"}, mt_alloc())
	set_str(&mt.search, search)
	mt_load()
	for k, i in mt.kinds do if k == kind do mt.kind = i
	dialog_open(.Model_Table)
	focus_field("dlg.search")
}

// From a part's editor (app.dlg keeps its state): the models the part's symbol can use.
model_table_open_part :: proc(sym: ^Symbol, ref, value: string) {
	mt_reset()
	mt.sym = strings.clone(sym.name, mt_alloc())
	mt.title = strings.concatenate({ref, ": pick a model (", part_short_name(sym), ")"}, mt_alloc())
	set_str(&mt.search, "")
	mt_load()
	f := strings.fields(value, context.temp_allocator)
	if len(f) > 0 do mt.sel = strings.clone(lower(f[0]), mt_alloc())
	app.dlg.kind = .Model_Table
	app.dlg.first_frame = true
	focus_field("dlg.search")
}

@(private = "file")
mt_alloc :: proc() -> mem.Allocator {
	if !mt.ready {
		_ = virtual.arena_init_growing(&mt.arena)
		mt.ready = true
	}
	return virtual.arena_allocator(&mt.arena)
}

@(private = "file")
mt_reset :: proc() {
	_ = mt_alloc()
	virtual.arena_free_all(&mt.arena)
	mt.rows = make([dynamic]Catalog_Row, mt_alloc())
	mt.shown = make([dynamic]int, mt_alloc())
	mt.kinds = make([dynamic]string, mt_alloc())
	mt.place, mt.sym, mt.family, mt.title, mt.sel, mt.ed_key = false, "", "", "", "", ""
	mt.kind, mt.sort, mt.desc, mt.shown_for = 0, .Name, false, ""
}

// The rows, from the catalog (copied: the catalog is built again when it changes).
@(private = "file")
mt_load :: proc() {
	a := mt_alloc()
	clear(&mt.rows)
	clear(&mt.kinds)
	mt.shown_for = ""
	cat := catalog_rows()
	mt.gen = catalog_gen()
	add :: proc(r: Catalog_Row, a: mem.Allocator) {
		x := r
		x.name = strings.clone(r.name, a); x.key = strings.clone(r.key, a); x.kind = strings.clone(r.kind, a)
		x.symbol = strings.clone(r.symbol, a); x.desc = strings.clone(r.desc, a); x.file = strings.clone(r.file, a)
		x.sheet = strings.clone(r.sheet, a)
		x.file_kind = strings.clone(r.file_kind, a); x.file_desc = strings.clone(r.file_desc, a)
		append(&mt.rows, x)
	}
	if mt.place {
		for &r in cat {
			k := kind_def(r.kind)
			if k != nil && k.family == mt.family && len(r.symbol) > 0 do add(r, a)
		}
	} else if sym := symbol_find(mt.sym); sym != nil {
		context.allocator = context.temp_allocator // catalog_row's strings: add copies them
		// the schematic's own models first (directives, saved copies), then the libraries
		by_key := make(map[string]int, len(cat), context.temp_allocator)
		for &r, i in cat do by_key[r.key] = i
		seen := make(map[string]bool, 256, context.temp_allocator)
		d := doc()
		local := sch_models(&d.sch, doc_sim(d), dir_of(d.path)) if d != nil else nil
		for list in ([?][]Lib_Entry{local, model_lib[:]}) {
			for &e in list {
				if seen[e.name] || !entry_fits_symbol(&e, sym) do continue
				seen[e.name] = true
				if i, ok := by_key[e.name]; ok {
					// the schematic's copy of a library model: the kind, ratings and datasheet are
					// the part's (the library row's, with what the user gave it), the copy is where
					row := cat[i]
					if e.origin == .Directive do row.file = "this schematic"
					else if e.origin == .Embedded do row.file = tcat("saved in the schematic (", e.file, ")")
					add(row, a)
					continue
				}
				row, ok := catalog_row(&e)
				if e.origin == .Library || e.origin == .Builtin {
					// not in the catalog: a part of a subcircuit, not one of its own
					if ok do continue
				}
				if !ok {
					row = {name = entry_display_name(&e), key = e.name, kind = e.model_type if !e.subckt else "Subcircuit"}
					for &x in row.rating do x = math.nan_f64()
					row.file_rating = row.rating
					row.file_kind = row.kind
				}
				row.file = "this schematic" if e.origin == .Directive else tcat("saved in the schematic (", e.file, ")") if e.origin == .Embedded else row.file
				add(row, a)
			}
		}
	}
	append(&mt.kinds, "All kinds")
	for k in KINDS {
		for &r in mt.rows do if r.kind == k.name {
			append(&mt.kinds, k.name)
			break
		}
	}
	// kinds no KINDS name (a schematic's resistor model …)
	for &r in mt.rows {
		have := false
		for k in mt.kinds do if k == r.kind do have = true
		if !have do append(&mt.kinds, r.kind)
	}
}

// The rows to show: those matching the search and the kind, sorted.
@(private = "file")
mt_update_shown :: proc() {
	q := lower(strings.trim_space(mt.search))
	key := tcat(q, "|", mt.kinds[mt.kind] if mt.kind < len(mt.kinds) else "", "|", fmt.tprint(int(mt.sort)), "|", "d" if mt.desc else "a")
	if key == mt.shown_for do return
	mt.shown_for = strings.clone(key, mt_alloc())
	clear(&mt.shown)
	kind := mt.kinds[mt.kind] if mt.kind > 0 && mt.kind < len(mt.kinds) else ""
	for &r, i in mt.rows {
		if len(kind) > 0 && r.kind != kind do continue
		if len(q) > 0 && !strings.contains(lower(r.name), q) && !strings.contains(lower(r.desc), q) && !strings.contains(lower(r.file), q) do continue
		append(&mt.shown, i)
	}
	slice.sort_by(mt.shown[:], proc(a, b: int) -> bool {
		x, y := &mt.rows[a], &mt.rows[b]
		less, same := false, false
		switch mt.sort {
		case .Name: less, same = name_less(x.name, y.name), strings.equal_fold(x.name, y.name)
		case .Kind: less, same = kind_rank(x.kind) < kind_rank(y.kind), x.kind == y.kind
		case .Desc: less, same = lower(x.desc) < lower(y.desc), lower(x.desc) == lower(y.desc)
		case .File: less, same = lower(x.file) < lower(y.file), lower(x.file) == lower(y.file)
		case .V, .I, .P, .R, .T, .F:
			q := Rating(int(mt.sort) - int(Col.V))
			u, v := x.rating[q], y.rating[q]
			// not stated: last, whichever way
			if math.is_nan(u) || math.is_nan(v) {
				if math.is_nan(u) && math.is_nan(v) do return name_less(x.name, y.name)
				return !math.is_nan(u)
			}
			less, same = u < v, u == v
		}
		if same do return name_less(x.name, y.name)
		return !less if mt.desc else less
	})
}

// Names in the order a person reads them: "BZX5V1" before "BZX10", case ignored.
@(private = "file")
name_less :: proc(a, b: string) -> bool {
	i, j := 0, 0
	for i < len(a) && j < len(b) {
		ca, cb := a[i], b[j]
		if is_digit(ca) && is_digit(cb) {
			// the numbers, by value
			i0, j0 := i, j
			for i < len(a) && is_digit(a[i]) do i += 1
			for j < len(b) && is_digit(b[j]) do j += 1
			na, nb := strings.trim_left(a[i0:i], "0"), strings.trim_left(b[j0:j], "0")
			if len(na) != len(nb) do return len(na) < len(nb)
			if na != nb do return na < nb
			continue
		}
		la, lb := ca | 0x20 if ca >= 'A' && ca <= 'Z' else ca, cb | 0x20 if cb >= 'A' && cb <= 'Z' else cb
		if la != lb do return la < lb
		i += 1
		j += 1
	}
	return len(a) - i < len(b) - j
}

@(private = "file")
is_digit :: proc(c: u8) -> bool {return c >= '0' && c <= '9'}

@(private = "file")
kind_rank :: proc(k: string) -> int {
	for x, i in KINDS do if x.name == k do return i
	return len(KINDS)
}

// The heading of a rating's column, for the devices in the table (VR for diodes, Vz for
// Zeners, VCEO for bipolar transistors, VDS for MOSFETs).
@(private = "file")
rating_heading :: proc(r: Rating) -> string {
	diode, zener, bjt, fet := false, false, false, false
	for i in mt.shown {
		x := &mt.rows[i]
		k := kind_def(x.kind)
		if k == nil do continue
		switch k.device {
		case "D": if x.kind == "Zener" || x.kind == "TVS" do zener = true; else do diode = true
		case "NPN", "PNP": bjt = true
		case "NMOS", "PMOS", "NJF", "PJF": fet = true
		}
	}
	diodes := diode || zener
	only :: proc(a, b, c: bool) -> bool {return a && !b && !c}
	switch r {
	case .V:
		if only(diodes, bjt, fet) do return "VR / Vz" if diode && zener else "Vz" if zener else "VR"
		if only(bjt, diodes, fet) do return "VCEO"
		if only(fet, diodes, bjt) do return "VDS"
		return "V"
	case .I:
		if only(diodes, bjt, fet) do return "IF"
		if only(bjt, diodes, fet) do return "IC"
		if only(fet, diodes, bjt) do return "ID"
		return "I"
	case .P: return "P"
	case .R: return "RDS(on)" if only(fet, diodes, bjt) else "R"
	case .T: return "trr"
	case .F: return "fT"
	}
	return ""
}


draw_model_table :: proc(d: ^Doc) {
	dl := &app.dlg
	if mt.gen != catalog_gen() {
		// the catalog changed (a model given a kind or ratings, a model imported): copy again
		sel := mt.sel
		kind := mt.kinds[mt.kind] if mt.kind < len(mt.kinds) else ""
		sel_c, kind_c := strings.clone(sel, context.temp_allocator), strings.clone(kind, context.temp_allocator)
		search := strings.clone(mt.search, context.temp_allocator)
		place, sym, family, title := mt.place, strings.clone(mt.sym, context.temp_allocator), strings.clone(mt.family, context.temp_allocator), strings.clone(mt.title, context.temp_allocator)
		sort, desc := mt.sort, mt.desc
		mt_reset()
		mt.place, mt.sort, mt.desc = place, sort, desc
		mt.sym, mt.family, mt.title = strings.clone(sym, mt_alloc()), strings.clone(family, mt_alloc()), strings.clone(title, mt_alloc())
		set_str(&mt.search, search)
		mt_load()
		for k, i in mt.kinds do if k == kind_c do mt.kind = i
		mt.sel = strings.clone(sel_c, mt_alloc())
	}
	b := dialog_frame(1040, 680)
	text_in(cut_top(&b, fs(1.1) + 10), mt.title, th.fg, 0, fs(1.1), 0)
	cut_top(&b, 6)
	// search and kind
	top := cut_top(&b, fs() + 12)
	kr := cut_right(&top, 200 * ui_scale)
	cut_right(&top, 8)
	live_field("dlg.search", top, &mt.search, "search: name, description, file …")
	combo("mt.kind", kr, mt.kinds[:], &mt.kind)
	cut_top(&b, 8)
	mt_update_shown()

	bot := cut_bottom(&b, fs() + 16)
	cut_bottom(&b, 8)
	// the editor of the selected model
	sel_row: ^Catalog_Row
	for &r in mt.rows do if r.key == mt.sel do sel_row = &r
	ed := cut_bottom(&b, 3 * (fs() + 12) + 20)
	cut_bottom(&b, 8)

	// the columns: name, kind, the ratings some row shown states, description, file
	cols := make([dynamic]Col, context.temp_allocator)
	append(&cols, Col.Name, Col.Kind)
	for q in Rating {
		for i in mt.shown do if !math.is_nan(mt.rows[i].rating[q]) {
			append(&cols, Col(int(Col.V) + int(q)))
			break
		}
	}
	append(&cols, Col.Desc, Col.File)
	width :: proc(c: Col) -> f32 {
		switch c {
		case .Name: return 170
		case .Kind: return 96
		case .Desc: return 0 // the rest
		case .File: return 170
		case .V, .I, .P, .R, .T, .F: return 82
		}
		return 80
	}
	fixed: f32 = 0
	for c in cols do fixed += width(c) * ui_scale
	desc_w := max(120 * ui_scale, b.w - 12 - fixed)
	heading :: proc(c: Col) -> string {
		switch c {
		case .Name: return "Model"
		case .Kind: return "Kind"
		case .Desc: return "Description"
		case .File: return "File"
		case .V, .I, .P, .R, .T, .F: return rating_heading(Rating(int(c) - int(Col.V)))
		}
		return ""
	}
	// headings: a click sorts by the column, another the other way round
	hr := cut_top(&b, fs() + 12)
	fill_round(hr, th.hover, 4)
	x := hr.x
	for c in cols {
		w := desc_w if c == .Desc else width(c) * ui_scale
		cr := Rect{x, hr.y, w, hr.h}
		x += w
		id := id_of(tcat("mt.col.", heading(c)))
		if hover(cr) {
			ui.hot = id
			ui.cursor = .POINTING_HAND
			if ui.pressed[0] {
				if mt.sort == c do mt.desc = !mt.desc
				else do mt.sort, mt.desc = c, false
			}
		}
		text_in(cr, heading(c), th.fg if mt.sort == c else th.muted, 0, fs(0.95), 6)
		if mt.sort == c {
			// the way it is sorted: a small triangle (drawn, not a glyph)
			tx := cr.x + 6 + text_w(heading(c), fs(0.95)) + 8 * ui_scale
			cy := cr.y + cr.h / 2
			s := 4 * ui_scale
			if mt.desc do tri({tx - s, cy - s / 2}, {tx, cy + s / 2}, {tx + s, cy - s / 2}, th.accent)
			else do tri({tx - s, cy + s / 2}, {tx + s, cy + s / 2}, {tx, cy - s / 2}, th.accent)
		}
	}
	mt_update_shown()
	// the rows (only those in view are drawn)
	lr := b
	ih := fs() + 10
	sc := scroll_begin("mt.rows", lr)
	y := lr.y - sc
	picked := false
	first := max(0, int(sc / ih))
	last := min(len(mt.shown) - 1, int((sc + lr.h) / ih))
	if dl.first_frame && len(mt.sel) > 0 {
		// opened scrolled to the selected model
		for i, n in mt.shown do if mt.rows[i].key == mt.sel {
			ui.scroll[id_of("mt.rows")] = max(0, f32(n) * ih - lr.h / 2)
			break
		}
	}
	for n in first ..= last {
		if n < 0 do break
		r := &mt.rows[mt.shown[n]]
		ir := Rect{lr.x, y + f32(n) * ih, lr.w - 12, ih}
		selected := r.key == mt.sel
		if selected do fill_round(ir, th.sel, 4)
		if hover(ir) && hover(lr) {
			if !selected do fill_round(ir, th.hover, 4)
			if ui.pressed[0] {
				mt.sel = strings.clone(r.key, mt_alloc())
				if ui.double do picked = true
			}
		}
		col := sel_fg() if selected else th.fg
		x = ir.x
		for c in cols {
			w := desc_w if c == .Desc else width(c) * ui_scale
			cr := Rect{x, ir.y, w, ir.h}
			x += w
			t := ""
			mine := false
			switch c {
			case .Name: t = r.name
			case .Kind: t, mine = r.kind, .Kind in r.mine
			case .Desc: t, mine = r.desc, .Desc in r.mine
			case .File: t = r.file
			case .V, .I, .P, .R, .T, .F:
				q := Rating(int(c) - int(Col.V))
				t, mine = rating_text(r.rating[q], q), Row_Field(int(q) + 1) in r.mine
			}
			// what the user gave: in the accent colour
			tc := col if !mine || selected else th.accent
			text_in(cr, fit_text(t, w - 12, fs(0.95)), tc, 0, fs(0.95), 6)
		}
	}
	scroll_end("mt.rows", lr, f32(len(mt.shown)) * ih)
	if len(mt.shown) == 0 do text_in({lr.x, lr.y + 8, lr.w, fs() * 2}, "No model matches." if len(mt.rows) > 0 else "No models: import a SPICE model file (File › Import SPICE model…).", th.muted, 1)

	mt_editor(ed, sel_row)

	// count, Cancel, Place / Use
	text_in(bot, fmt_count(len(mt.shown), len(mt.rows)), th.muted, 0, fs(0.9), 0)
	ok := "Place" if mt.place else "Use"
	res := buttons(&bot, ok, true, sel_row != nil)
	if picked && sel_row != nil do res = 1
	if res < 0 {
		mt_close()
		return
	}
	if res > 0 && sel_row != nil {
		if mt.place {
			sym := symbol_find(sel_row.symbol)
			dialog_close()
			if sym != nil && d != nil do place_model(d, sym, sel_row.name)
		} else {
			set_str(&dl.value, sel_row.name)
			mt_close()
		}
	}
}

@(private = "file")
fmt_count :: proc(shown, all: int) -> string {
	if shown == all do return tcat(fmt.tprint(all), " model" if all == 1 else " models")
	return tcat(fmt.tprint(shown), " of ", fmt.tprint(all), " models")
}

// Cancel: back to the part's editor when it opened the table.
@(private = "file")
mt_close :: proc() {
	if mt.place {
		dialog_close()
		return
	}
	app.dlg.kind = .Part_Edit
	app.dlg.first_frame = false
	ui.focus = 0
}

// Under the table: the kind, ratings and description of the selected model, which the user
// can give where the file says nothing (or says it wrong). Kept in model-info.edn.
@(private = "file")
mt_editor :: proc(r: Rect, row: ^Catalog_Row) {
	b := r
	fill_round(b, th.hover, 6)
	b = r_inset(b, 7)
	if row == nil {
		text_in(b, "Select a model to give it the kind, ratings, description or datasheet its file does not state.", th.muted, 0, fs(0.9), 4)
		return
	}
	if mt.ed_key != row.key {
		// a newly selected model: its values into the fields
		mt.ed_key = strings.clone(row.key, mt_alloc())
		mt.ed_kinds = kinds_like(row.file_kind)
		mt.ed_kinds = slice.clone(mt.ed_kinds, mt_alloc())
		mt.ed_kind = 0
		for k, i in mt.ed_kinds do if k == row.kind do mt.ed_kind = i
		for q in Rating do set_str(&mt.ed_val[q], rating_text(row.rating[q], q))
		set_str(&mt.ed_desc, row.desc)
		set_str(&mt.ed_sheet, row.sheet)
	}
	l1 := cut_top(&b, fs() + 12)
	cut_top(&b, 6)
	l2 := cut_top(&b, fs() + 12)
	cut_top(&b, 6)
	l3 := b
	// line 1: kind and ratings
	lab :: proc(r: ^Rect, t: string) {
		text_in(cut_left(r, text_w(t, fs(0.9)) + 10), t, th.muted, 0, fs(0.9), 2)
	}
	lab(&l1, "Kind")
	kr := cut_left(&l1, 120 * ui_scale)
	if len(mt.ed_kinds) > 1 do combo("mt.ed.kind", kr, mt.ed_kinds, &mt.ed_kind)
	else do text_in(kr, row.kind, th.fg, 0, fs(0.9), 4)
	for q in Rating {
		if q not_in device_ratings(row.file_kind) do continue
		cut_left(&l1, 10)
		h := rating_heading(q)
		lab(&l1, h)
		text_field(tcat("mt.ed.", RATING_KEY[q]), cut_left(&l1, 78 * ui_scale), &mt.ed_val[q], RATING_UNIT[q])
	}
	// line 2: description, Save, the file's values
	reset_l := "Use the file's values"
	save_l := "Save"
	rb := cut_right(&l2, text_w(reset_l) + 24)
	cut_right(&l2, 6)
	sb := cut_right(&l2, text_w(save_l) + 36)
	cut_right(&l2, 10)
	lab(&l2, "Description")
	text_field("mt.ed.desc", l2, &mt.ed_desc)
	// line 3: the datasheet (Save keeps it), a file picked or the one typed opened
	open_l, browse_l := "Open", "Browse…"
	ob := cut_right(&l3, text_w(open_l) + 30)
	cut_right(&l3, 6)
	bb := cut_right(&l3, text_w(browse_l) + 24)
	cut_right(&l3, 10)
	lab(&l3, "Datasheet")
	text_field("mt.ed.sheet", l3, &mt.ed_sheet, "a PDF file or a https:// link")
	if button("mt.ed.browse", bb, browse_l, tip = "Pick a datasheet file (Save keeps it for this model)") do datasheet_browse(.Model_Table, mt.ed_sheet, "")
	if button("mt.ed.open", ob, open_l, len(strings.trim_space(mt.ed_sheet)) > 0, tip = "Open the datasheet: a file in your PDF viewer, a link in your browser") {
		if e := datasheet_open(mt.ed_sheet, ""); len(e) > 0 do status_error(e)
	}
	if button("mt.ed.save", sb, save_l, tip = "Keep these for this model (in model-info.edn; the model file is not changed)") do mt_save(row)
	if button("mt.ed.reset", rb, reset_l, card(row.mine) > 0, tip = "Forget what you gave this model: the file's kind and ratings, no datasheet") {
		if e := model_info_put(row.key, {}); len(e) > 0 do status_error(e)
		else do status(tcat(row.name, ": the file's values"))
		mt.ed_key = ""
	}
}

// The editor's fields are kept (what differs from the file: model_info_set).
@(private = "file")
mt_save :: proc(row: ^Catalog_Row) {
	fields := make(map[string]string, 8, context.temp_allocator)
	if mt.ed_kind < len(mt.ed_kinds) do fields["kind"] = mt.ed_kinds[mt.ed_kind]
	for q in Rating do if q in device_ratings(row.file_kind) do fields[RATING_KEY[q]] = mt.ed_val[q]
	fields["desc"] = mt.ed_desc
	fields["datasheet"] = mt.ed_sheet
	name := strings.clone(row.name, context.temp_allocator)
	if e := model_info_set(row.key, fields); len(e) > 0 {
		status_error(e)
		return
	}
	status(tcat(name, ": saved in ", model_info_path()))
	mt.ed_key = ""
}

@(private = "file")
status_error :: proc(msg: string) {status(msg, true)}

// A filled triangle in any winding (raylib draws only counter-clockwise ones).
@(private = "file")
tri :: proc(a, b, c: [2]f32, col: Color) {
	if (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) > 0 do rl.DrawTriangle(a, c, b, rlc(col))
	else do rl.DrawTriangle(a, b, c, rlc(col))
}

// A datasheet file picked for the selected model: into its editor's field (Save keeps it).
model_table_set_sheet :: proc(path: string) {set_str(&mt.ed_sheet, path)}
