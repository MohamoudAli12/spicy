package spicy

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"

// The parts picker: every symbol drawn in a grid, grouped by category, with its name and
// shortcut under it. It lives in a window of its own (Place › Part…), or in a dialog when
// no window can be made. The models of the libraries are tiles by kind in their device's
// group ("Zener, 751 models" under Diodes): a click opens the model table, to pick one by its
// ratings. The symbols imports made for them are not tiles of their own.

// Categories in this order; any other category comes after them, alphabetically.
@(private = "file")
CATEGORY_ORDER := [?]string{"Passive", "Sources", "Diodes", "Transistors", "Amplifiers", "Nets", "Imported"}

@(private = "file")
category_rank :: proc(c: string) -> int {
	for x, i in CATEGORY_ORDER do if x == c do return i
	return len(CATEGORY_ORDER)
}

@(private = "file")
parts_search: string

// The short name shown under a symbol: its description up to " (" ("Voltage source").
part_short_name :: proc(s: ^Symbol) -> string {
	n := s.desc
	if i := strings.index(n, " ("); i > 0 do n = n[:i]
	if i := strings.index(n, "  "); i > 0 do n = n[:i]
	return n
}

// Draws the picker in r. True when a part was picked (placing it has started in d).
parts_panel :: proc(r: Rect, d: ^Doc) -> (picked: bool) {
	fill(r, th.panel)
	b := r_inset(r, 10 * ui_scale)
	// search
	sr := cut_top(&b, fs() + 12)
	live_field("parts.search", sr, &parts_search, "search: name, description, category, key …")
	cut_top(&b, 8 * ui_scale)
	// buttons at the bottom
	bot := cut_bottom(&b, fs() + 14)
	cut_bottom(&b, 8 * ui_scale)
	if button("parts.import", cut_left(&bot, text_w("Import SPICE model…") + 30), "Import SPICE model…") {
		app.import_for = -1
		dialog_open(.Import_Model)
	}
	cut_left(&bot, 6)
	if button("parts.newsym", cut_left(&bot, text_w("New symbol…") + 30), "New symbol…") do symed_open(nil)
	if p := cur_popout; p != nil && p.kind == .Parts {
		// in its own window: a way back into the main window (as loomer)
		t := "Back into main window"
		if button("parts.dock", cut_right(&bot, text_w(t) + 30), t, tip = "Show the parts as a dialog in the main window again") {
			pref_put_bool("parts-own-window", false)
			p.close = true
			dialog_open(.Part_Picker)
		}
	}

	// the symbols that match, by category: built again only when something changed
	parts_list_update(lower(strings.trim_space(parts_search)))
	list := parts_cache.list[:]

	// grid: cells as wide as fit, at least ~110 px (scaled)
	cw_min := 112 * ui_scale
	cols := max(1, int(b.w / cw_min))
	cw := math.floor(b.w / f32(cols))
	sym_h := 64 * ui_scale
	ch := sym_h + fs() * 2 + 18 * ui_scale
	head_h := fs() + 14 * ui_scale
	gap := 6 * ui_scale
	sc := scroll_begin("parts.grid", b)
	y := b.y - sc
	// only what is in view is drawn: thousands of imported parts stay cheap
	for g, gi in parts_cache.groups {
		if gi > 0 do y += gap
		// the symbols, then the kinds' tiles from a row of their own
		ns := 0
		for e in list[g.start:g.start + g.count] do if len(e.kind) == 0 do ns += 1
		sym_rows := (ns + cols - 1) / cols
		rows := sym_rows + (g.count - ns + cols - 1) / cols
		gh := head_h + 4 * ui_scale + f32(rows) * ch
		if y + gh < b.y || y > b.y + b.h {
			y += gh
			continue
		}
		hr := Rect{b.x, y, b.w - 12 * ui_scale, head_h}
		if hr.y + hr.h >= b.y {
			text_in(hr, g.cat if len(g.cat) > 0 else "Other", th.muted, 0, fs(0.95), 2)
			line(hr.x, hr.y + hr.h - 2, hr.x + hr.w, hr.y + hr.h - 2, th.border)
		}
		y0 := y + head_h + 4 * ui_scale
		for k in 0 ..< g.count {
			row, c := k / cols, k % cols
			if k >= ns do row, c = sym_rows + (k - ns) / cols, (k - ns) % cols
			cell := Rect{b.x + f32(c) * cw, y0 + f32(row) * ch, cw - gap, ch - gap}
			if cell.y + cell.h < b.y || cell.y > b.y + b.h do continue // only what is in view
			e := &list[g.start + k]
			if len(e.kind) > 0 {
				kind_cell(e, cell)
			} else if part_cell(e.s, e.key, cell, d) {
				picked = true
			}
		}
		y += gh
	}
	if len(list) == 0 do text_in({b.x, y, b.w, fs() * 2}, "No part matches the search.", th.muted, 1)
	scroll_end("parts.grid", b, y + sc - b.y + 8)
	return
}

@(private = "file")
Part_Entry :: struct {
	s:     ^Symbol, // a kind's tile: its generic symbol (nil: a box)
	key:   string, // the shortcut that places it ("" for none)
	cat:   string, // the group it is in
	kind:  string, // a tile of the models of a kind ("" for a symbol)
	count: int, // a kind's tile: its models (that match the search)
}

@(private = "file")
Part_Group :: struct {
	cat:          string,
	start, count: int,
}

// The picker's list, kept between frames (sorting thousands of symbols every frame is slow).
@(private = "file")
parts_cache: struct {
	gen, agen: int,
	cgen:      int, // the model catalog's
	q:         string,
	built:     bool,
	list:      [dynamic]Part_Entry,
	groups:    [dynamic]Part_Group,
	keys:      [dynamic]string, // owned key texts
}

@(private = "file")
parts_list_update :: proc(q: string) {
	pc := &parts_cache
	cgen := catalog_gen()
	if pc.built && pc.gen == symbols_gen && pc.agen == actions_gen && pc.cgen == cgen && pc.q == q do return
	pc.built, pc.gen, pc.agen, pc.cgen = true, symbols_gen, actions_gen, cgen
	delete(pc.q)
	pc.q = strings.clone(q)
	for k in pc.keys do delete(k)
	clear(&pc.keys)
	clear(&pc.list)
	clear(&pc.groups)
	// shortcut of each symbol, in one pass over the actions
	keys := make(map[string]string, context.temp_allocator)
	for &a in actions do if strings.has_prefix(a.name, "place/") && len(a.keys) > 0 {
		keys[a.name[len("place/"):]] = chord_name(a.keys[0])
	}
	// the symbols imports made for models of the kind tiles: in the tiles, not of their own
	in_tiles := make(map[string]bool, 256, context.temp_allocator)
	rows := catalog_rows()
	for &r in rows do if len(r.symbol) > 0 do in_tiles[r.symbol] = true
	for s in symbols_by_category() {
		if s.category == "Imported" && in_tiles[s.name] do continue
		k := keys[s.name]
		if len(q) == 0 || strings.contains(lower(s.name), q) || strings.contains(lower(s.desc), q) || strings.contains(lower(s.category), q) || lower(s.key) == q || lower(k) == q {
			kc := strings.clone(k)
			append(&pc.keys, kc)
			append(&pc.list, Part_Entry{s = s, key = kc, cat = s.category})
		}
	}
	// a tile per kind of model, after the group's symbols: with a search, the kinds with
	// models it matches (by name or description), or all of a kind the search names
	counts: [len(KINDS)]int
	for &r in rows {
		if len(r.symbol) == 0 do continue
		ki := -1
		for k, i in KINDS do if k.name == r.kind do ki = i
		if ki < 0 do continue
		kd := &KINDS[ki]
		if len(q) == 0 || strings.contains(lower(r.name), q) || strings.contains(lower(r.desc), q) || strings.contains(lower(kd.name), q) || strings.contains(lower(kd.family), q) do counts[ki] += 1
	}
	for &k, i in KINDS do if counts[i] > 0 {
		append(&pc.list, Part_Entry{s = symbol_find(k.symbol) if len(k.symbol) > 0 else nil, cat = k.family, kind = k.name, count = counts[i]})
	}
	// the categories in CATEGORY_ORDER, the rest after them (still alphabetical); in a
	// category the symbols, then the kinds
	slice.stable_sort_by(pc.list[:], proc(a, b: Part_Entry) -> bool {
		ra, rb := category_rank(a.cat), category_rank(b.cat)
		if ra != rb do return ra < rb
		if a.cat != b.cat do return a.cat < b.cat
		return len(a.kind) == 0 && len(b.kind) > 0
	})
	for e, i in pc.list {
		if i == 0 || e.cat != pc.list[i - 1].cat do append(&pc.groups, Part_Group{cat = e.cat, start = i})
		pc.groups[len(pc.groups) - 1].count += 1
	}
}

// One cell: the symbol, its name and its shortcut. True when clicked (placing starts).
@(private = "file")
part_cell :: proc(s: ^Symbol, k: string, r: Rect, d: ^Doc) -> bool {
	id := id_of(tcat("parts.", s.name))
	h := hover(r)
	placing := d != nil && d.tool == .Place && ((s.kind == .Part && d.place_kind == .Part && d.place_sym == s.name) || (s.kind == .Ground && d.place_kind == .Ground))
	if placing do fill_round(r, mix(th.panel, th.accent, 0.25), 6)
	else if h do fill_round(r, th.hover, 6)
	if placing || h do stroke_round(r, th.accent if placing else th.border, 6)
	// the symbol, fitted into the top of the cell
	pad := 10 * ui_scale
	sr := Rect{r.x + pad, r.y + pad, r.w - 2 * pad, 64 * ui_scale - pad}
	ext := s.hi - s.lo
	if ext.x > 0 || ext.y > 0 {
		z := min(sr.w / max(ext.x, 0.01), sr.h / max(ext.y, 0.01))
		z = min(z, 12 * ui_scale) // small symbols (ground) do not fill the whole cell
		v := View{r = sr, c = {sr.x + sr.w / 2, sr.y + sr.h / 2}, cam = (s.lo + s.hi) / 2, z = z}
		push_clip(sr)
		draw_symbol_gfx(v, s, {0, 0}, 0, false, th.fg if h || placing else mix(th.panel, th.fg, 0.85), max(1, 1.4 * ui_scale))
		pop_clip()
	}
	// the name, and the shortcut under it
	ny := r.y + 64 * ui_scale + 2
	text_in({r.x, ny, r.w, fs() + 2}, fit_text(part_short_name(s), r.w - 8), th.fg, 1, 0, 0)
	text_in({r.x, ny + fs() + 2, r.w, fs(0.9) + 2}, k if len(k) > 0 else "–", th.accent if len(k) > 0 else th.muted, 1, fs(0.85), 0)
	if h {
		ui.hot = id
		ui.cursor = .POINTING_HAND
		tooltip(id, tcat(s.desc, "\nclick: place it · right-click: edit the symbol"))
		if ui.pressed[0] {
			place_symbol(d, s)
			return true
		}
		if ui.pressed[1] && s.kind == .Part do symed_open(s)
	}
	return false
}

// A kind's tile: its generic symbol (a box for subcircuits), the kind and how many models.
// A click opens the model table on that kind.
@(private = "file")
kind_cell :: proc(e: ^Part_Entry, r: Rect) {
	id := id_of(tcat("parts.kind.", e.kind))
	h := hover(r)
	if h {
		fill_round(r, th.hover, 6)
		stroke_round(r, th.border, 6)
	}
	pad := 10 * ui_scale
	sr := Rect{r.x + pad, r.y + pad, r.w - 2 * pad, 64 * ui_scale - pad}
	col := th.fg if h else mix(th.panel, th.fg, 0.85)
	if s := e.s; s != nil && (s.hi.x > s.lo.x || s.hi.y > s.lo.y) {
		ext := s.hi - s.lo
		z := min(sr.w / max(ext.x, 0.01), sr.h / max(ext.y, 0.01), 12 * ui_scale)
		v := View{r = sr, c = {sr.x + sr.w / 2, sr.y + sr.h / 2}, cam = (s.lo + s.hi) / 2, z = z}
		push_clip(sr)
		draw_symbol_gfx(v, s, {0, 0}, 0, false, col, max(1, 1.4 * ui_scale))
		pop_clip()
	} else {
		// a subcircuit: a box with pins
		bw, bh := min(sr.w * 0.5, 40 * ui_scale), sr.h * 0.7
		box := Rect{sr.x + (sr.w - bw) / 2, sr.y + (sr.h - bh) / 2, bw, bh}
		stroke(box, col, max(1, 1.4 * ui_scale))
		for k in 0 ..< 2 {
			py := box.y + bh * (0.3 + 0.4 * f32(k))
			line(box.x - 8 * ui_scale, py, box.x, py, col, max(1, 1.4 * ui_scale))
			line(box.x + bw, py, box.x + bw + 8 * ui_scale, py, col, max(1, 1.4 * ui_scale))
		}
	}
	ny := r.y + 64 * ui_scale + 2
	// the catch-all kind beside the Diode symbol: not a second "Diode"
	label := "Other diodes" if e.kind == "Diode" else e.kind
	text_in({r.x, ny, r.w, fs() + 2}, fit_text(label, r.w - 8), th.fg, 1, 0, 0)
	n := tcat(fmt.tprint(e.count), " model" if e.count == 1 else " models")
	text_in({r.x, ny + fs() + 2, r.w, fs(0.9) + 2}, n, th.accent, 1, fs(0.85), 0)
	if h {
		ui.hot = id
		ui.cursor = .POINTING_HAND
		tooltip(id, tcat(e.kind, " models of your libraries: click to pick one by its ratings"))
		if ui.pressed[0] {
			// a search for models goes with it; one that names the kind or group does not
			q := strings.trim_space(parts_search)
			if strings.contains(lower(e.kind), lower(q)) || strings.contains(lower(e.cat), lower(q)) do q = ""
			model_table_open_place(e.cat, e.kind, q)
		}
	}
}
