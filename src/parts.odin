package spicy

import "core:math"
import "core:slice"
import "core:strings"

// The parts picker: every symbol drawn in a grid, grouped by category, with its name and
// shortcut under it. It lives in a window of its own (Place › Part…), or in a dialog when
// no window can be made.

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
		rows := (g.count + cols - 1) / cols
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
		first := max(0, int((b.y - y0) / ch))
		last := min(rows - 1, int((b.y + b.h - y0) / ch))
		for row in first ..= last {
			for c in 0 ..< cols {
				i := g.start + row * cols + c
				if i >= g.start + g.count do break
				cell := Rect{b.x + f32(c) * cw, y0 + f32(row) * ch, cw - gap, ch - gap}
				if part_cell(list[i].s, list[i].key, cell, d) do picked = true
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
	s:   ^Symbol,
	key: string, // the shortcut that places it ("" for none)
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
	q:         string,
	built:     bool,
	list:      [dynamic]Part_Entry,
	groups:    [dynamic]Part_Group,
	keys:      [dynamic]string, // owned key texts
}

@(private = "file")
parts_list_update :: proc(q: string) {
	pc := &parts_cache
	if pc.built && pc.gen == symbols_gen && pc.agen == actions_gen && pc.q == q do return
	pc.built, pc.gen, pc.agen = true, symbols_gen, actions_gen
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
	for s in symbols_by_category() {
		k := keys[s.name]
		if len(q) == 0 || strings.contains(lower(s.name), q) || strings.contains(lower(s.desc), q) || strings.contains(lower(s.category), q) || lower(s.key) == q || lower(k) == q {
			kc := strings.clone(k)
			append(&pc.keys, kc)
			append(&pc.list, Part_Entry{s, kc})
		}
	}
	// the categories in CATEGORY_ORDER, the rest after them (still alphabetical)
	slice.stable_sort_by(pc.list[:], proc(a, b: Part_Entry) -> bool {return category_rank(a.s.category) < category_rank(b.s.category)})
	for e, i in pc.list {
		if i == 0 || e.s.category != pc.list[i - 1].s.category do append(&pc.groups, Part_Group{cat = e.s.category, start = i})
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
