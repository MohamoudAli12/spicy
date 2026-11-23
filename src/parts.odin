package spicy

import "core:math"
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

	// the symbols that match, by category
	q := lower(strings.trim_space(parts_search))
	list := make([dynamic]^Symbol, context.temp_allocator)
	for s in symbols_by_category() {
		if len(q) == 0 || strings.contains(lower(s.name), q) || strings.contains(lower(s.desc), q) || strings.contains(lower(s.category), q) || lower(s.key) == q || lower(action_keys_text(tcat("place/", s.name))) == q do append(&list, s)
	}
	for i in 1 ..< len(list) {
		j := i
		for j > 0 && category_rank(list[j - 1].category) > category_rank(list[j].category) {
			list[j - 1], list[j] = list[j], list[j - 1]
			j -= 1
		}
	}

	// grid: cells as wide as fit, at least ~110 px (scaled)
	cw_min := 112 * ui_scale
	cols := max(1, int(b.w / cw_min))
	cw := math.floor(b.w / f32(cols))
	sym_h := 64 * ui_scale
	ch := sym_h + fs() * 2 + 18 * ui_scale
	head_h := fs() + 14 * ui_scale
	sc := scroll_begin("parts.grid", b)
	y := b.y - sc
	cat := ""
	col := 0
	for s, i in list {
		if s.category != cat || i == 0 {
			// category heading
			if col != 0 do y += ch
			col = 0
			cat = s.category
			if i > 0 do y += 6 * ui_scale
			hr := Rect{b.x, y, b.w - 12 * ui_scale, head_h}
			text_in(hr, cat if len(cat) > 0 else "Other", th.muted, 0, fs(0.95), 2)
			line(hr.x, hr.y + hr.h - 2, hr.x + hr.w, hr.y + hr.h - 2, th.border)
			y += head_h + 4 * ui_scale
		}
		cell := Rect{b.x + f32(col) * cw, y, cw - 6 * ui_scale, ch - 6 * ui_scale}
		if part_cell(s, cell, d) do picked = true
		col += 1
		if col == cols {
			col = 0
			y += ch
		}
	}
	if col != 0 do y += ch
	if len(list) == 0 do text_in({b.x, y, b.w, fs() * 2}, "No part matches the search.", th.muted, 1)
	scroll_end("parts.grid", b, y + sc - b.y + 8)
	return
}

// One cell: the symbol, its name and its shortcut. True when clicked (placing starts).
@(private = "file")
part_cell :: proc(s: ^Symbol, r: Rect, d: ^Doc) -> bool {
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
	k := action_keys_text(tcat("place/", s.name))
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
