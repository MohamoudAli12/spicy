package spicy

import "core:fmt"
import "core:math"
import "core:strings"
import rl "vendor:raylib"

// The schematic editor: drawing and mouse interaction.

View :: struct {
	r:      Rect,
	c:      [2]f32, // screen centre
	cam:    [2]f32,
	z:      f32, // pixels per schematic unit
}

view_of :: proc(d: ^Doc, r: Rect) -> View {
	return {r = r, c = {r.x + r.w / 2, r.y + r.h / 2}, cam = d.cam, z = d.zoom * ui_scale}
}

to_scr :: proc(v: View, p: [2]f32) -> [2]f32 {return v.c + (p - v.cam) * v.z}
to_sch :: proc(v: View, s: [2]f32) -> [2]f32 {return v.cam + (s - v.c) / v.z}

line_w :: proc(v: View, base: f32) -> f32 {return max(1, base * ui_scale * clampf32(v.z / ui_scale / 1.5, 0.6, 2.2))}

// ---------------------------------------------------------------------------
// Symbols

draw_symbol_gfx :: proc(v: View, sym: ^Symbol, pos: P, rot: u8, mirror: bool, col: Color, lw: f32) {
	X :: proc(v: View, pos: P, rot: u8, mirror: bool, p: [2]f32) -> rl.Vector2 {
		s := to_scr(v, xform_f(pos, rot, mirror, p))
		return {s.x, s.y}
	}
	body := th.s_symbol_fill
	for g in sym.gfx {
		switch g.kind {
		case .Line:
			if len(g.pts) == 2 && g.pts[0] == g.pts[1] do continue
			pts := make([]rl.Vector2, len(g.pts), context.temp_allocator)
			for p, i in g.pts do pts[i] = X(v, pos, rot, mirror, p)
			for i in 1 ..< len(pts) do rl.DrawLineEx(pts[i - 1], pts[i], lw, rlc(col))
			for i in 1 ..< len(pts) - 1 do rl.DrawCircleV(pts[i], lw / 2, rlc(col))
		case .Poly:
			pts := make([]rl.Vector2, len(g.pts), context.temp_allocator)
			for p, i in g.pts do pts[i] = X(v, pos, rot, mirror, p)
			fc := col if g.fill == .Line_Color else body
			if g.fill != .None && fc[3] > 0 {
				for i in 1 ..< len(pts) - 1 {
					rl.DrawTriangle(pts[0], pts[i], pts[i + 1], rlc(fc))
					rl.DrawTriangle(pts[0], pts[i + 1], pts[i], rlc(fc))
				}
			}
			for i in 0 ..< len(pts) do rl.DrawLineEx(pts[i], pts[(i + 1) % len(pts)], lw, rlc(col))
		case .Rect:
			a := X(v, pos, rot, mirror, g.pts[0])
			b := X(v, pos, rot, mirror, g.pts[1])
			rr := Rect{min(a.x, b.x), min(a.y, b.y), abs(a.x - b.x), abs(a.y - b.y)}
			if g.fill == .Line_Color || (rr.w < 6 || rr.h < 6) do fill(rr, col)
			else {
				if g.fill == .Body && body[3] > 0 do fill(rr, body)
				stroke(rr, col, lw)
			}
		case .Circle:
			c := X(v, pos, rot, mirror, g.pts[0])
			rad := g.r * v.z
			if g.fill == .Line_Color do rl.DrawCircleV(c, rad, rlc(col))
			else {
				if body[3] > 0 do rl.DrawCircleV(c, rad, rlc(body))
				rl.DrawRing(c, rad - lw / 2, rad + lw / 2, 0, 360, 48, rlc(col))
			}
		case .Arc:
			n := 16
			prev: rl.Vector2
			for i in 0 ..= n {
				a := math.to_radians(g.a0 + (g.a1 - g.a0) * f32(i) / f32(n))
				p := g.pts[0] + {g.r * math.cos(a), g.r * math.sin(a)}
				s := X(v, pos, rot, mirror, p)
				if i > 0 do rl.DrawLineEx(prev, s, lw, rlc(col))
				prev = s
			}
		case .Text:
			s := X(v, pos, rot, mirror, g.pts[0])
			sz := g.size * v.z
			if sz >= 4 do draw_text(g.text, s.x, s.y - sz / 2, col, sz)
		}
	}
}

// Where a part's name and value are written (screen rectangles), kept upright.
Comp_Text :: struct {
	r:    Rect,
	s:    string,
	show: bool,
}

// Where a part's name and value are written: their usual place, moved by where the user
// dragged them.
comp_texts :: proc(v: View, c: ^Comp, sym: ^Symbol) -> (ref, val: Comp_Text) {
	ref, val = comp_texts_usual(v, c, sym)
	ref.r.x += f32(c.ref_off.x) * v.z
	ref.r.y += f32(c.ref_off.y) * v.z
	val.r.x += f32(c.val_off.x) * v.z
	val.r.y += f32(c.val_off.y) * v.z
	return
}

@(private = "file")
comp_texts_usual :: proc(v: View, c: ^Comp, sym: ^Symbol) -> (ref, val: Comp_Text) {
	sz := S.text_size * v.z
	if sz < 5 do return
	ref.s, ref.show = c.ref, S.show_refs
	val.s, val.show = c.value, S.show_values && len(c.value) > 0
	if len(val.s) > 40 do val.s = tcat(val.s[:38], "…")
	lo, hi := comp_bounds(c, sym)
	a, b := to_scr(v, lo), to_scr(v, hi)
	if c.rot % 2 == 1 {
		// horizontal part: name above, value below
		cx := (a.x + b.x) / 2
		rw, vw := text_w(ref.s, sz), text_w(val.s, sz)
		ref.r = {cx - rw / 2, a.y - sz - 2, rw, sz}
		val.r = {cx - vw / 2, b.y + 2, vw, sz}
		return
	}
	centre := comp_xf(c, (sym.lo + sym.hi) / 2)
	place :: proc(v: View, c: ^Comp, at: [2]f32, centre: [2]f32, s: string, sz: f32) -> Rect {
		p := comp_xf(c, at)
		sp := to_scr(v, p)
		w := text_w(s, sz)
		x := sp.x
		if p.x < centre.x - 1 do x -= w
		return {x, sp.y - sz / 2, w, sz}
	}
	ref_at := sym.ref_at if sym.has_ref_at else [2]f32{sym.hi.x + 8, (sym.lo.y + sym.hi.y) / 2 - 10}
	val_at := sym.value_at if sym.has_value_at else [2]f32{sym.hi.x + 8, (sym.lo.y + sym.hi.y) / 2 + 10}
	ref.r = place(v, c, ref_at, centre, ref.s, sz)
	val.r = place(v, c, val_at, centre, val.s, sz)
	return
}

draw_comp_texts :: proc(v: View, c: ^Comp, sym: ^Symbol, col_ref, col_val: Color) {
	ref, val := comp_texts(v, c, sym)
	if ref.show do draw_text(ref.s, ref.r.x, ref.r.y, col_ref, ref.r.h)
	if val.show do draw_text(val.s, val.r.x, val.r.y, col_val, val.r.h)
}

// The part name or value text under the mouse (field 1 name, 2 value).
comp_text_at :: proc(d: ^Doc, v: View, m: [2]f32) -> (ci: int, field: u8) {
	for i := len(d.sch.comps) - 1; i >= 0; i -= 1 {
		c := &d.sch.comps[i]
		sym := symbol_find(c.sym)
		if sym == nil || sym.kind != .Part do continue
		ref, val := comp_texts(v, c, sym)
		grow :: proc(r: Rect) -> Rect {return {r.x - 3, r.y - 2, r.w + 6, r.h + 4}}
		if val.show && r_contains(grow(val.r), m) do return i, 2
		if ref.show && r_contains(grow(ref.r), m) do return i, 1
	}
	return -1, 0
}

// Editing a part's name or value where it is written (double-click on the text).
inline_start :: proc(d: ^Doc, ci: int, field: u8) {
	d.inline = {ci = ci, field = field}
	focus_field("sch.inline")
}

@(private = "file")
draw_inline_edit :: proc(d: ^Doc, v: View) {
	in_ := &d.inline
	if in_.field == 0 do return
	if in_.ci < 0 || in_.ci >= len(d.sch.comps) {
		in_.field = 0
		return
	}
	c := &d.sch.comps[in_.ci]
	sym := symbol_find(c.sym)
	if sym == nil {
		in_.field = 0
		return
	}
	ref, val := comp_texts(v, c, sym)
	t := val if in_.field == 2 else ref
	init := c.value if in_.field == 2 else c.ref
	focused := field_focused("sch.inline")
	h := fs() + 10
	w := max(text_w(string(ui.edit_buf[:]) if focused else init) + 30, 140 * ui_scale)
	r := Rect{t.r.x - 6, t.r.y + t.r.h / 2 - h / 2, w, h}
	in_.r = r
	commit, cancelled, text := edit_field("sch.inline", r, init)
	if commit {
		ns := strings.trim_space(text)
		old := c.value if in_.field == 2 else c.ref
		if ns != old && (len(ns) > 0 || in_.field == 2) {
			doc_push_undo(d)
			if in_.field == 2 do set_str(&c.value, ns)
			else do set_str(&c.ref, ns)
		}
		in_.field = 0
	} else if cancelled || (focused && !field_focused("sch.inline")) {
		in_.field = 0
	}
}

draw_flag :: proc(v: View, f: Flag, col: Color, lw: f32, op_val: string = "") {
	p := to_scr(v, pf(f.pos))
	if is_ground(f) {
		if g := symbol_find("ground"); g != nil do draw_symbol_gfx(v, g, f.pos, f.rot, false, col, lw)
		return
	}
	sz := S.text_size * v.z
	if sz < 4 do return
	tw := text_w(f.name, sz)
	pad := sz * 0.3
	h := sz + pad
	// a tag pointing at the connection point
	dir := f.rot % 4
	r: Rect
	switch dir {
	case 2: r = {p.x - tw - 2 * pad - h / 2, p.y - h / 2, tw + 2 * pad, h}
	case 1: r = {p.x - (tw + 2 * pad) / 2, p.y + h / 2, tw + 2 * pad, h}
	case 3: r = {p.x - (tw + 2 * pad) / 2, p.y - h * 1.5, tw + 2 * pad, h}
	case: r = {p.x + h / 2, p.y - h / 2, tw + 2 * pad, h}
	}
	rl.DrawLineEx({p.x, p.y}, {r.x if dir == 0 else (r.x + r.w if dir == 2 else r.x + r.w / 2), r.y + r.h / 2 if dir % 2 == 0 else (r.y if dir == 1 else r.y + r.h)}, lw, rlc(col))
	fill_round(r, alpha(th.s_bg, 220), 3)
	stroke_round(r, col, 3, max(1, lw * 0.7))
	draw_text(f.name, r.x + pad, r.y + pad / 2, col, sz)
	if len(op_val) > 0 do draw_text(op_val, r.x + r.w + 4, r.y + pad / 2, th.s_op_value, sz * 0.9)
}

flag_rect :: proc(v: View, f: Flag) -> Rect {
	p := to_scr(v, pf(f.pos))
	if is_ground(f) {
		// the lead and the triangle (below the pin, then turned with the symbol), not the pin
		a := to_scr(v, pf(xform_p(f.pos, f.rot, false, {-20, 3})))
		b := to_scr(v, pf(xform_p(f.pos, f.rot, false, {20, 38})))
		return {min(a.x, b.x), min(a.y, b.y), abs(b.x - a.x), abs(b.y - a.y)}
	}
	sz := S.text_size * v.z
	tw := text_w(f.name, sz)
	h := sz * 1.3
	switch f.rot % 4 {
	case 2: return {p.x - tw - h * 1.2, p.y - h / 2, tw + h * 1.2, h}
	case 1: return {p.x - tw / 2 - 4, p.y, tw + 8, h * 1.6}
	case 3: return {p.x - tw / 2 - 4, p.y - h * 1.6, tw + 8, h * 1.6}
	}
	return {p.x - 4, p.y - h / 2, tw + h * 1.2, h}
}

text_rect :: proc(v: View, t: Text) -> Rect {
	sz := S.text_size * v.z
	lines := split_lines(t.text)
	w: f32 = 0
	for l in lines do w = max(w, mono_w(l, sz) if t.directive else text_w(l, sz))
	p := to_scr(v, pf(t.pos))
	return {p.x, p.y, max(w, 10), f32(len(lines)) * (sz + 3)}
}

draw_text_item :: proc(v: View, t: Text, col: Color) {
	sz := S.text_size * v.z
	if sz < 4 do return
	p := to_scr(v, pf(t.pos))
	for l, i in split_lines(t.text) {
		y := p.y + f32(i) * (sz + 3)
		if t.directive do draw_mono(l, p.x, y, col, sz)
		else do draw_text(l, p.x, y, col, sz)
	}
}

// ---------------------------------------------------------------------------
// Hit testing

Hit_Kind :: enum u8 {None, Comp, Wire, Flag, Text}

Hit :: struct {
	kind: Hit_Kind,
	idx:  int,
}

sch_hit :: proc(d: ^Doc, v: View, m: [2]f32) -> Hit {
	s := &d.sch
	p := to_sch(v, m)
	tol := 6 / v.z
	best_w, bw := f32(1e9), -1
	for w, i in s.wires {
		dd := seg_dist(p, pf(w.a), pf(w.b))
		if dd < best_w {best_w = dd; bw = i}
	}
	// a ground's whole body first: the wire to it runs right up to its lead
	for i := len(s.flags) - 1; i >= 0; i -= 1 do if is_ground(s.flags[i]) && r_contains(flag_rect(v, s.flags[i]), m) do return {.Flag, i}
	if bw >= 0 && best_w <= tol * 0.8 do return {.Wire, bw}
	for i := len(s.texts) - 1; i >= 0; i -= 1 do if r_contains(text_rect(v, s.texts[i]), m) do return {.Text, i}
	for i := len(s.flags) - 1; i >= 0; i -= 1 do if r_contains(flag_rect(v, s.flags[i]), m) do return {.Flag, i}
	best_area, bc := f32(1e18), -1
	for &c, i in s.comps {
		sym := symbol_find(c.sym)
		if sym == nil do continue
		lo, hi := comp_bounds(&c, sym)
		lo -= 4
		hi += 4
		if p.x >= lo.x && p.x <= hi.x && p.y >= lo.y && p.y <= hi.y {
			area := (hi.x - lo.x) * (hi.y - lo.y)
			if area < best_area {best_area = area; bc = i}
		}
	}
	if bc >= 0 do return {.Comp, bc}
	if bw >= 0 && best_w <= tol do return {.Wire, bw}
	return {}
}

// Net index at the mouse (wire, pin or flag), -1 if none.
net_at :: proc(d: ^Doc, v: View, ni: ^Net_Info, m: [2]f32) -> int {
	p := to_sch(v, m)
	tol := 7 / v.z
	for w, i in d.sch.wires do if seg_dist(p, pf(w.a), pf(w.b)) <= tol do return ni.wire_net[i]
	for pr in all_pins(&d.sch) {
		if vlen(pf(pr.p) - p) <= tol * 1.3 do return ni.pin_net[pr.comp][pr.pin]
	}
	for f, i in d.sch.flags do if r_contains(flag_rect(v, f), m) do return ni.flag_net[i]
	return -1
}

// A point where a new wire would connect (pin, wire, flag).
is_connection :: proc(s: ^Schematic, p: P) -> bool {
	for w in s.wires do if on_segment(p, w.a, w.b) do return true
	for f in s.flags do if f.pos == p do return true
	for pr in all_pins(s) do if pr.p == p do return true
	return false
}

// ---------------------------------------------------------------------------
// Selection and edits

sch_select_all :: proc(d: ^Doc, on: bool) {
	for &c in d.sch.comps do c.sel = on
	for &w in d.sch.wires do w.sel = on
	for &f in d.sch.flags do f.sel = on
	for &t in d.sch.texts do t.sel = on
}

sel_count :: proc(s: ^Schematic) -> int {
	n := 0
	for c in s.comps do if c.sel do n += 1
	for w in s.wires do if w.sel do n += 1
	for f in s.flags do if f.sel do n += 1
	for t in s.texts do if t.sel do n += 1
	return n
}

hit_selected :: proc(s: ^Schematic, h: Hit) -> bool {
	switch h.kind {
	case .Comp: return s.comps[h.idx].sel
	case .Wire: return s.wires[h.idx].sel
	case .Flag: return s.flags[h.idx].sel
	case .Text: return s.texts[h.idx].sel
	case .None:
	}
	return false
}

hit_set_sel :: proc(s: ^Schematic, h: Hit, on: bool) {
	switch h.kind {
	case .Comp: s.comps[h.idx].sel = on
	case .Wire: s.wires[h.idx].sel = on
	case .Flag: s.flags[h.idx].sel = on
	case .Text: s.texts[h.idx].sel = on
	case .None:
	}
}

sch_delete_selection :: proc(d: ^Doc) {
	if sel_count(&d.sch) == 0 do return
	doc_push_undo(d)
	s := &d.sch
	for i := len(s.comps) - 1; i >= 0; i -= 1 do if s.comps[i].sel {
		c := s.comps[i]
		delete(c.sym); delete(c.ref); delete(c.value)
		for a in c.attrs {delete(a.key); delete(a.val)}
		delete(c.attrs)
		ordered_remove(&s.comps, i)
	}
	for i := len(s.wires) - 1; i >= 0; i -= 1 do if s.wires[i].sel do ordered_remove(&s.wires, i)
	for i := len(s.flags) - 1; i >= 0; i -= 1 do if s.flags[i].sel {delete(s.flags[i].name); ordered_remove(&s.flags, i)}
	for i := len(s.texts) - 1; i >= 0; i -= 1 do if s.texts[i].sel {delete(s.texts[i].text); ordered_remove(&s.texts, i)}
	wires_cleanup(s)
}

// Copy of the selected items (whole schematic structure, sel kept).
sch_selection :: proc(s: ^Schematic) -> Schematic {
	r: Schematic
	r.comps = make([dynamic]Comp)
	r.wires = make([dynamic]Wire)
	r.flags = make([dynamic]Flag)
	r.texts = make([dynamic]Text)
	for c in s.comps do if c.sel do append(&r.comps, comp_clone(c))
	for w in s.wires do if w.sel do append(&r.wires, w)
	for f in s.flags do if f.sel do append(&r.flags, Flag{name = strings.clone(f.name), pos = f.pos, rot = f.rot, sel = true})
	for t in s.texts do if t.sel do append(&r.texts, Text{pos = t.pos, text = strings.clone(t.text), directive = t.directive, sel = true})
	return r
}

// Deep copy that keeps the selection.
sch_copy_full :: proc(s: ^Schematic) -> Schematic {
	r: Schematic
	r.comps = make([dynamic]Comp)
	r.wires = make([dynamic]Wire)
	r.flags = make([dynamic]Flag)
	r.texts = make([dynamic]Text)
	for c in s.comps do append(&r.comps, comp_clone(c))
	for w in s.wires do append(&r.wires, w)
	for f in s.flags do append(&r.flags, Flag{name = strings.clone(f.name), pos = f.pos, rot = f.rot, sel = f.sel})
	for t in s.texts do append(&r.texts, Text{pos = t.pos, text = strings.clone(t.text), directive = t.directive, sel = t.sel})
	r.simulator = strings.clone(s.simulator)
	r.waves = strings.clone(s.waves)
	return r
}

sch_copy :: proc(d: ^Doc) {
	if sel_count(&d.sch) == 0 do return
	sel := sch_selection(&d.sch)
	text := sch_to_edn(&sel)
	sch_free(&sel)
	set_str(&app.clipboard, text)
	rl.SetClipboardText(cstr(text))
	status("copied")
}

sch_paste_start :: proc(d: ^Doc, fallback: string) {
	text := string(rl.GetClipboardText())
	if !strings.contains(text, ":spicy-schematic") do text = fallback
	s, err := sch_from_edn(text)
	if len(err) > 0 || (len(s.comps) + len(s.wires) + len(s.flags) + len(s.texts)) == 0 {
		status("nothing to paste", true)
		return
	}
	sch_free(&d.paste)
	d.paste = s
	lo, hi, _ := sch_bounds(&s)
	d.paste_anchor = snap_to((lo + hi) / 2, S.grid)
	tool_set(d, .Paste)
}

// Point p rotated a quarter turn clockwise about c.
rot_about :: proc(p, c: P) -> P {return {c.x - (p.y - c.y), c.y + (p.x - c.x)}}

// Rotates (or mirrors) the selection about its centre.
@(private = "file")
transform_selection :: proc(s: ^Schematic, mirror: bool) {
	lo := [2]f32{1e9, 1e9}
	hi := [2]f32{-1e9, -1e9}
	add :: proc(lo, hi: ^[2]f32, p: [2]f32) {lo^ = {min(lo.x, p.x), min(lo.y, p.y)}; hi^ = {max(hi.x, p.x), max(hi.y, p.y)}}
	for &c in s.comps do if c.sel {
		if sym := symbol_find(c.sym); sym != nil {a, b := comp_bounds(&c, sym); add(&lo, &hi, a); add(&lo, &hi, b)}
	}
	for w in s.wires do if w.sel {add(&lo, &hi, pf(w.a)); add(&lo, &hi, pf(w.b))}
	for f in s.flags do if f.sel do add(&lo, &hi, pf(f.pos))
	for t in s.texts do if t.sel do add(&lo, &hi, pf(t.pos))
	if lo.x > hi.x do return
	c := snap_to((lo + hi) / 2, S.grid)
	tf :: proc(p, c: P, mirror: bool) -> P {
		if mirror do return {2 * c.x - p.x, p.y}
		return rot_about(p, c)
	}
	for &x in s.comps do if x.sel {
		x.ref_off, x.val_off = {}, {}
		x.pos = tf(x.pos, c, mirror)
		if mirror {
			x.rot = (4 - x.rot) % 4
			x.mirror = !x.mirror
		} else do x.rot = (x.rot + 1) % 4
	}
	for &w in s.wires do if w.sel {w.a = tf(w.a, c, mirror); w.b = tf(w.b, c, mirror)}
	for &f in s.flags do if f.sel {
		f.pos = tf(f.pos, c, mirror)
		if mirror {if f.rot % 2 == 0 do f.rot = (f.rot + 2) % 4} else do f.rot = (f.rot + 1) % 4
	}
	for &t in s.texts do if t.sel do t.pos = tf(t.pos, c, mirror)
}

sch_rotate :: proc(d: ^Doc) {
	#partial switch d.tool {
	case .Place: d.place_rot = (d.place_rot + 1) % 4
	case .Paste:
		sch_select_all_in(&d.paste)
		transform_selection(&d.paste, false)
	case:
		if sel_count(&d.sch) == 0 do return
		doc_push_undo(d)
		transform_selection(&d.sch, false)
		wires_cleanup(&d.sch)
	}
}

sch_mirror :: proc(d: ^Doc) {
	#partial switch d.tool {
	case .Place:
		d.place_mirror = !d.place_mirror
	case .Paste:
		sch_select_all_in(&d.paste)
		transform_selection(&d.paste, true)
	case:
		if sel_count(&d.sch) == 0 do return
		doc_push_undo(d)
		transform_selection(&d.sch, true)
		wires_cleanup(&d.sch)
	}
}

sch_select_all_in :: proc(s: ^Schematic) {
	for &c in s.comps do c.sel = true
	for &w in s.wires do w.sel = true
	for &f in s.flags do f.sel = true
	for &t in s.texts do t.sel = true
}

sch_edit_selected :: proc(d: ^Doc) {
	s := &d.sch
	for c, i in s.comps do if c.sel {
		dialog_part(d, i)
		return
	}
	for f, i in s.flags do if f.sel && !is_ground(f) {
		dialog_label(d, i)
		return
	}
	for t, i in s.texts do if t.sel {
		dialog_text(d, i, t.directive)
		return
	}
}

sch_cancel :: proc(d: ^Doc) {
	if d.tool == .Wire && d.wire_active {
		d.wire_active = false
		return
	}
	if d.tool != .Select {
		tool_set(d, .Select)
		return
	}
	if app.hover_ctx == .Waves {
		wave_select_none(&d.wave)
		return
	}
	sch_select_all(d, false)
}

sch_zoom :: proc(d: ^Doc, f: f32) {
	d.zoom = clampf32(d.zoom * f, S.zoom_min, S.zoom_max)
	d.user_view = true
}

sch_fit :: proc(d: ^Doc, r: Rect) {
	lo, hi, ok := sch_bounds(&d.sch)
	if !ok {
		d.cam = {0, 0}
		d.zoom = S.initial_zoom
		return
	}
	d.cam = (lo + hi) / 2
	w := max(hi.x - lo.x, 64) + 96
	h := max(hi.y - lo.y, 64) + 96
	d.zoom = clampf32(min(r.w / w, r.h / h) / ui_scale, S.zoom_min, min(S.zoom_max, 3))
}

// Wires that run through two pins of part ci are cut there, so dropping a part onto a
// wire puts it in series instead of shorting it.
cut_wires_at_part :: proc(s: ^Schematic, ci: int) {
	sym := symbol_find(s.comps[ci].sym)
	if sym == nil do return
	pins := make([dynamic]P, context.temp_allocator)
	for _, k in sym.pins do append(&pins, comp_pin(&s.comps[ci], sym, k))
	for i := len(s.wires) - 1; i >= 0; i -= 1 {
		w := s.wires[i]
		n := 0
		for p in pins do if on_segment(p, w.a, w.b) do n += 1
		if n >= 2 {
			ordered_remove(&s.wires, i)
			add_wire(s, w.a, w.b, true)
		}
	}
}

// ---------------------------------------------------------------------------
// Drawing + interaction

draw_schematic :: proc(d: ^Doc, r: Rect) {
	s := &d.sch
	// refit when the view changes size (the waveforms appear) unless zoomed by hand
	if d.fitted && !d.user_view && (abs(d.last_rect.x - r.w) > 2 || abs(d.last_rect.y - r.h) > 2) do d.fitted = false
	d.last_rect = {r.w, r.h}
	if !d.fitted {
		if S.fit_on_open || len(s.comps) > 0 do sch_fit(d, r)
		d.fitted = true
		d.user_view = false
	}
	fill(r, th.s_bg)
	push_clip(r)
	defer pop_clip()
	v := view_of(d, r)
	over := hover(r) && !app.split_drag
	m := ui.mouse
	mp := to_sch(v, m)
	msnap := snap_to(mp, S.grid)

	// --- view: zoom and pan
	if over && ui.wheel != 0 && !ui.ctrl {
		before := to_sch(v, m)
		f := math.pow(S.zoom_speed, ui.wheel)
		d.zoom = clampf32(d.zoom * f, S.zoom_min, S.zoom_max)
		v = view_of(d, r)
		after := to_sch(v, m)
		d.cam += before - after
		v = view_of(d, r)
		d.user_view = true
	}
	pan_start := over && (ui.pressed[2] || (ui.pressed[0] && key_down(.SPACE) && !typing()) || (S.pan_right_drag && ui.pressed[1]))
	if pan_start {
		d.drag = {kind = .Pan, start = m}
		d.user_view = true
	}
	if d.drag.kind == .Pan {
		d.cam -= ui.delta / v.z
		v = view_of(d, r)
		ui.cursor = .RESIZE_ALL
		if !ui.down[0] && !ui.down[1] && !ui.down[2] do d.drag.kind = .None
	}

	// --- grid
	g := f32(S.grid)
	if S.grid_style != "none" && g * v.z >= 5 {
		lo := to_sch(v, {r.x, r.y})
		hi := to_sch(v, {r.x + r.w, r.y + r.h})
		x0 := math.floor(lo.x / g) * g
		y0 := math.floor(lo.y / g) * g
		if S.grid_style == "lines" {
			for x := x0; x <= hi.x; x += g {
				sx := to_scr(v, {x, 0}).x
				major := int(math.round(x / g)) % S.grid_major == 0
				line(sx, r.y, sx, r.y + r.h, th.s_grid_major if major else th.s_grid, 1)
			}
			for y := y0; y <= hi.y; y += g {
				sy := to_scr(v, {0, y}).y
				major := int(math.round(y / g)) % S.grid_major == 0
				line(r.x, sy, r.x + r.w, sy, th.s_grid_major if major else th.s_grid, 1)
			}
		} else {
			dot := max(1, 1.2 * ui_scale)
			for x := x0; x <= hi.x; x += g {
				sx := to_scr(v, {x, 0}).x
				for y := y0; y <= hi.y; y += g {
					sy := to_scr(v, {0, y}).y
					rl.DrawRectangleV({sx - dot / 2, sy - dot / 2}, {dot, dot}, rlc(th.s_grid))
				}
			}
		}
	}

	ni := nets_build(s, S.net_prefix)
	hit := sch_hit(d, v, m) if over && d.drag.kind == .None else Hit{}
	hover_net := -1
	if over && (d.tool == .Probe || S.highlight_net && ui.alt) do hover_net = net_at(d, v, &ni, m)
	if d.tool == .Probe && hover_net >= 0 do hit = {}
	lw := line_w(v, S.line_width)
	ww := line_w(v, S.wire_width)
	have_op := len(d.run.op) > 0 && S.show_op_values

	// --- wires
	for w, i in s.wires {
		col := th.s_wire
		width := ww
		if w.sel do col = th.s_select
		else if hit.kind == .Wire && hit.idx == i && S.hover_highlight && d.tool == .Select do col = th.s_hover
		if hover_net >= 0 && ni.wire_net[i] == hover_net {
			col = th.s_net_highlight
			width = ww * 1.8
		}
		a, b := to_scr(v, pf(w.a)), to_scr(v, pf(w.b))
		rl.DrawLineEx({a.x, a.y}, {b.x, b.y}, width, rlc(col))
		rl.DrawCircleV({a.x, a.y}, width / 2, rlc(col))
		rl.DrawCircleV({b.x, b.y}, width / 2, rlc(col))
	}
	// --- parts
	for &c, i in s.comps {
		sym := symbol_find(c.sym)
		if sym == nil {
			p := to_scr(v, pf(c.pos))
			draw_text(tcat("? ", c.sym), p.x, p.y, th.err, S.text_size * v.z)
			continue
		}
		col := th.s_symbol
		if c.sel do col = th.s_select
		else if hit.kind == .Comp && hit.idx == i && S.hover_highlight && (d.tool == .Select || d.tool == .Probe) do col = th.s_hover
		draw_symbol_gfx(v, sym, c.pos, c.rot, c.mirror, col, lw)
		draw_comp_texts(v, &c, sym, th.s_ref if !c.sel else col, th.s_value if !c.sel else col)
		if hover_net >= 0 do for k in 0 ..< len(sym.pins) do if ni.pin_net[i][k] == hover_net {
			pp := to_scr(v, pf(comp_pin(&c, sym, k)))
			rl.DrawCircleV({pp.x, pp.y}, ww * 1.4, rlc(th.s_net_highlight))
		}
	}
	draw_inline_edit(d, v)
	// --- flags
	for f, i in s.flags {
		col := th.s_ground if is_ground(f) else th.s_label
		if f.sel do col = th.s_select
		else if hit.kind == .Flag && hit.idx == i && S.hover_highlight do col = th.s_hover
		if hover_net >= 0 && ni.flag_net[i] == hover_net do col = th.s_net_highlight
		opv := ""
		if have_op && !is_ground(f) {
			if x, ok := d.run.op[lower(f.name)]; ok do opv = fmt_eng(x, "V")
		}
		draw_flag(v, f, col, ww if !is_ground(f) else lw, opv)
	}
	// --- texts
	for t, i in s.texts {
		col := th.s_directive if t.directive else th.s_text
		if t.sel do col = th.s_select
		else if hit.kind == .Text && hit.idx == i && S.hover_highlight do col = th.s_hover
		draw_text_item(v, t, col)
	}
	// --- junctions and open pins
	jr := max(2, S.junction_radius * ui_scale * clampf32(v.z / ui_scale / 1.5, 0.6, 2))
	for j in ni.junctions {
		p := to_scr(v, pf(j))
		rl.DrawCircleV({p.x, p.y}, jr, rlc(th.s_junction))
	}
	if S.pin_radius > 0 {
		pr := S.pin_radius * ui_scale * clampf32(v.z / ui_scale / 1.5, 0.6, 2)
		for op in ni.open_pins {
			p := to_scr(v, pf(op))
			stroke({p.x - pr, p.y - pr, 2 * pr, 2 * pr}, th.s_pin, max(1, lw * 0.7))
		}
	}

	// --- tools
	if !over && d.drag.kind == .None {
		draw_overlays(d, v, r)
		return
	}
	switch d.tool {
	case .Select: interact_select(d, v, r, hit, msnap, mp)
	case .Wire: interact_wire(d, v, msnap, over)
	case .Place: interact_place(d, v, msnap, mp, over)
	case .Paste: interact_paste(d, v, msnap, over)
	case .Probe: interact_probe(d, v, &ni, hit, hover_net, over)
	}
	// op voltage of the net under the mouse
	if over && have_op && d.drag.kind == .None {
		n := hover_net if hover_net >= 0 else net_at(d, v, &ni, m)
		if n >= 0 {
			name := ni.names[n]
			if x, ok := d.run.op[lower(name)]; ok do tooltip(id_of(tcat("op.", name)), fmt.tprintf("V(%s) = %s", name, fmt_eng(x, "V", 5)))
			else if name == "0" do tooltip(id_of("op.0"), "ground (0 V)")
		}
	}
	draw_overlays(d, v, r)
}

draw_overlays :: proc(d: ^Doc, v: View, r: Rect) {
	// empty schematic: a hint
	s := &d.sch
	if len(s.comps) == 0 && len(s.wires) == 0 && len(s.texts) == 0 && d.tool == .Select {
		lines := [?]string{
			"Empty schematic",
			"R C L D V I  place a resistor, capacitor, inductor, diode, voltage or current source",
			"Q M U E B  transistors, MOSFETs, op-amp, controlled and behavioural sources (F2: all parts)",
			"G ground   W wire   N net label   S SPICE directive   F5 run",
		}
		y := r.y + r.h / 2 - 50 * ui_scale
		for l, i in lines {
			sz := fs(1.3) if i == 0 else fs(0.95)
			text_in({r.x, y, r.w, sz + 6}, l, th.fg if i == 0 else th.muted, 1, sz)
			y += sz + 12
		}
	}
	// probe mode badge
	if d.tool == .Probe {
		t := "PROBE  –  click a wire or part   (Esc: back to editing)"
		w := text_w(t, fs(0.85)) + 20
		br := Rect{r.x + r.w - w - 10, r.y + 10, w, fs(0.85) + 10}
		fill_round(br, alpha(th.accent, 220), 4)
		text_in(br, t, th.accent_fg, 1, fs(0.85))
	}
	if d.run.state == .Running {
		t := fmt.tprintf("%s running …  %.1f s", d.run.sim_name, d.run.elapsed)
		w := text_w(t, fs(0.9)) + 20
		br := Rect{r.x + 10, r.y + 10, w, fs(0.9) + 10}
		fill_round(br, alpha(th.warn, 230), 4)
		text_in(br, t, {0, 0, 0, 255}, 1, fs(0.9))
	}
}

@(private = "file")
interact_select :: proc(d: ^Doc, v: View, r: Rect, hit: Hit, msnap: P, mp: [2]f32) {
	s := &d.sch
	m := ui.mouse
	over := hover(r)
	if over && hit.kind != .None && d.drag.kind == .None do ui.cursor = .POINTING_HAND
	// press
	if d.inline.field != 0 && r_contains(d.inline.r, m) do return // clicks in the inline editor
	if over && ui.pressed[0] && d.drag.kind == .None && !key_down(.SPACE) {
		// double-click on a part's name or value: edit it there
		if ui.double {
			if ci, field := comp_text_at(d, v, m); field != 0 {
				sch_select_all(d, false)
				s.comps[ci].sel = true
				inline_start(d, ci, field)
				return
			}
		}
		if ui.double && hit.kind != .None {
			sch_select_all(d, false)
			hit_set_sel(s, hit, true)
			sch_edit_selected(d)
			return
		}
		// a part's name or value: drag it to another place (the part stays)
		if !ui.double && !ui.shift && !ui.alt {
			if ci, field := comp_text_at(d, v, m); field != 0 {
				sch_select_all(d, false)
				s.comps[ci].sel = true
				c := &s.comps[ci]
				d.drag = {kind = .Comp_Text, start = m, start_p = mp, ci = ci, field = field, off0 = c.ref_off if field == 1 else c.val_off}
				set_str(&d.drag.base, sch_to_edn(s))
				return
			}
		}
		if ui.alt && hit.kind == .None {
			// Alt+click probes in the select tool too
			return
		}
		if hit.kind != .None {
			if ui.shift {
				hit_set_sel(s, hit, !hit_selected(s, hit))
			} else if !hit_selected(s, hit) {
				sch_select_all(d, false)
				hit_set_sel(s, hit, true)
			}
			d.drag = {kind = .Pending, start = m, start_p = mp, detach = ui.ctrl}
		} else {
			d.drag = {kind = .Box, start = m, start_p = mp}
		}
	}
	switch d.drag.kind {
	case .Pending:
		if vlen(m - d.drag.start) > 4 * ui_scale && hit_any_selected(s) {
			d.drag.kind = .Move
			set_str(&d.drag.base, sch_to_edn(s))
			d.drag.last_d = {}
			move_base = sch_copy_full(s)
		}
		if !ui.down[0] do d.drag.kind = .None
	case .Move:
		ui.cursor = .RESIZE_ALL
		delta := snap_to(mp - d.drag.start_p, S.grid)
		if delta != d.drag.last_d {
			d.drag.last_d = delta
			apply_move(d, delta)
		}
		if !ui.down[0] {
			d.drag.kind = .None
			if delta != {} {
				moved := make(map[P]bool, 32, context.temp_allocator)
				for &c in s.comps do if c.sel {
					if sym := symbol_find(c.sym); sym != nil do for _, k in sym.pins do moved[comp_pin(&c, sym, k)] = true
				}
				for w in s.wires do if w.sel {moved[w.a] = true; moved[w.b] = true}
				for f in s.flags do if f.sel do moved[f.pos] = true
				if S.rubber_band && !d.drag.detach do wires_orthogonalize(s, moved)
				wires_cleanup(s)
				doc_push_undo_text(d, d.drag.base)
			}
			sch_free(&move_base)
		}
	case .Box:
		a := d.drag.start
		rr := Rect{min(a.x, m.x), min(a.y, m.y), abs(m.x - a.x), abs(m.y - a.y)}
		if rr.w > 3 || rr.h > 3 {
			fill(rr, th.s_select_box)
			stroke(rr, alpha(th.accent, 200), 1)
		}
		if !ui.down[0] {
			d.drag.kind = .None
			if rr.w <= 3 && rr.h <= 3 {
				if !ui.shift do sch_select_all(d, false)
			} else {
				if !ui.shift do sch_select_all(d, false)
				lo := to_sch(v, {rr.x, rr.y})
				hi := to_sch(v, {rr.x + rr.w, rr.y + rr.h})
				inside :: proc(p, lo, hi: [2]f32) -> bool {return p.x >= lo.x && p.x <= hi.x && p.y >= lo.y && p.y <= hi.y}
				for &c in s.comps {
					sym := symbol_find(c.sym)
					if sym == nil do continue
					a2, b2 := comp_bounds(&c, sym)
					if inside((a2 + b2) / 2, lo, hi) do c.sel = true
				}
				for &w in s.wires do if inside(pf(w.a), lo, hi) && inside(pf(w.b), lo, hi) do w.sel = true
				for &f in s.flags do if inside(pf(f.pos), lo, hi) do f.sel = true
				for &t in s.texts do if inside(pf(t.pos), lo, hi) do t.sel = true
			}
		}
	case .Comp_Text:
		ui.cursor = .RESIZE_ALL
		if d.drag.ci >= len(s.comps) {
			d.drag.kind = .None
			break
		}
		c := &s.comps[d.drag.ci]
		dd := mp - d.drag.start_p
		off := d.drag.off0 + P{i32(math.round(dd.x)), i32(math.round(dd.y))}
		if d.drag.field == 1 do c.ref_off = off
		else do c.val_off = off
		if !ui.down[0] {
			d.drag.kind = .None
			if off != d.drag.off0 do doc_push_undo_text(d, d.drag.base)
		}
	case .None, .Pan:
	}
	// context menu
	if over && ui.pressed[1] && d.drag.kind == .None && !S.pan_right_drag {
		ctx_hit = hit
		ctx_point = msnap
		if hit.kind != .None && !hit_selected(s, hit) {
			sch_select_all(d, false)
			hit_set_sel(s, hit, true)
		}
		items: []string
		switch hit.kind {
		case .Comp: items = {"Edit…\tEnter", "Rotate\tCtrl+R", "Mirror\tCtrl+E", "Copy\tCtrl+C", "Delete\tDel", "-", "Probe current", "Probe voltages at the pins", "-", "Edit symbol…", "Reset name and value positions"}
		case .Wire: items = {"Probe voltage", "Name this net…", "-", "Delete\tDel"}
		case .Flag: items = {"Rename…", "Rotate\tCtrl+R", "Delete\tDel"}
		case .Text: items = {"Edit…\tEnter", "Delete\tDel"}
		case .None: items = {"Place part…\tF2", "Wire\tW", "Ground\tG", "Net label…\tN", "SPICE directive…\tS", "Comment…\tT", "-", "Paste\tCtrl+V", "Select all\tCtrl+A", "Fit to window\tF", "-", "Edit simulation command…\tF6", "Run\tF5"}
		}
		open_menu("sch.ctx", m.x, m.y, items)
	}
	if idx := menu_result("sch.ctx"); idx >= 0 do context_pick(d, idx)
}

ctx_hit: Hit
ctx_point: P
move_base: Schematic

hit_any_selected :: proc(s: ^Schematic) -> bool {return sel_count(s) > 0}

@(private = "file")
context_pick :: proc(d: ^Doc, idx: int) {
	h := ctx_hit
	switch h.kind {
	case .Comp:
		switch idx {
		case 0: dialog_part(d, h.idx)
		case 1: sch_rotate(d)
		case 2: sch_mirror(d)
		case 3: sch_copy(d)
		case 4: sch_delete_selection(d)
		case 6: probe_comp(d, h.idx, -1, false, false)
		case 7:
			ni := nets_build(&d.sch, S.net_prefix)
			for n in ni.pin_net[h.idx] do if ni.names[n] != "0" do wave_add_trace(&d.wave, fmt.tprintf("V(%s)", ni.names[n]), false)
		case 9:
			if sym := symbol_find(d.sch.comps[h.idx].sym); sym != nil && sym.kind == .Part do symed_open(sym, d, h.idx)
		case 10:
			doc_push_undo(d)
			for &c in d.sch.comps do if c.sel {c.ref_off = {}; c.val_off = {}}
		}
	case .Wire:
		switch idx {
		case 0:
			ni := nets_build(&d.sch, S.net_prefix)
			n := ni.wire_net[h.idx]
			if ni.names[n] != "0" do wave_add_trace(&d.wave, fmt.tprintf("V(%s)", ni.names[n]), false)
		case 1:
			w := d.sch.wires[h.idx]
			p := w.a
			// a grid point on the wire near the click
			if on_segment(ctx_point, w.a, w.b) do p = ctx_point
			dialog_open(.Label_Name)
			app.dlg.label_at = p
			app.dlg.label_place_now = true
		case 3: sch_delete_selection(d)
		}
	case .Flag:
		switch idx {
		case 0: dialog_label(d, h.idx)
		case 1: sch_rotate(d)
		case 2: sch_delete_selection(d)
		}
	case .Text:
		switch idx {
		case 0: dialog_text(d, h.idx, d.sch.texts[h.idx].directive)
		case 1: sch_delete_selection(d)
		}
	case .None:
		ACTS := [?]string{"place/component", "place/wire", "place/ground", "place/label", "place/directive", "place/comment", "", "edit/paste", "edit/select-all", "view/fit", "", "sim/edit-command", "sim/run"}
		if idx < len(ACTS) && len(ACTS[idx]) > 0 {
			if ACTS[idx] == "view/fit" do d.fitted = false
			else do run_action(ACTS[idx])
		}
	}
}

// Something that is not being moved touches p: a pin, a label, or the middle of a wire.
@(private = "file")
anchored_at :: proc(s: ^Schematic, p: P) -> bool {
	for &c in s.comps do if !c.sel {
		sym := symbol_find(c.sym)
		if sym == nil do continue
		for k in 0 ..< len(sym.pins) do if comp_pin(&c, sym, k) == p do return true
	}
	for f in s.flags do if !f.sel && f.pos == p do return true
	// the middle of a wire, or a wire end that stayed
	for w in s.wires do if !w.sel && (in_segment(p, w.a, w.b) || w.a == p || w.b == p) do return true
	return false
}

// Moves the selection by delta from move_base; connected wire ends follow (rubber band).
@(private = "file")
apply_move :: proc(d: ^Doc, delta: P) {
	sch_free(&d.sch)
	d.sch = sch_copy_full(&move_base)
	s := &d.sch
	moved := make(map[P]bool, 32, context.temp_allocator)
	for &c in s.comps do if c.sel {
		if sym := symbol_find(c.sym); sym != nil do for _, k in sym.pins do moved[comp_pin(&c, sym, k)] = true
		c.pos += delta
	}
	for &f in s.flags do if f.sel {
		moved[f.pos] = true
		f.pos += delta
	}
	for &w in s.wires do if w.sel {
		moved[w.a] = true
		moved[w.b] = true
		w.a += delta
		w.b += delta
	}
	for &t in s.texts do if t.sel do t.pos += delta
	if S.rubber_band && !d.drag.detach && delta != {} {
		// points that connect through the middle of wires: pins, labels and wire ends that stay
		taps := make([dynamic]P, context.temp_allocator)
		for &c in s.comps do if !c.sel {
			if sym := symbol_find(c.sym); sym != nil do for k in 0 ..< len(sym.pins) do append(&taps, comp_pin(&c, sym, k))
		}
		for f in s.flags do if !f.sel do append(&taps, f.pos)
		for w in s.wires do append(&taps, w.a, w.b)
		// a wire end on a moved pin follows it, unless the shorter wire would leave a tap behind
		for &w in s.wires {
			if w.sel do continue
			na, nb := w.a, w.b
			if moved[w.a] do na += delta
			if moved[w.b] do nb += delta
			if na == w.a && nb == w.b do continue
			keeps := true
			for t in taps do if in_segment(t, w.a, w.b) && !on_segment(t, na, nb) do keeps = false
			if keeps do w.a, w.b = na, nb
		}
		// a moved pin that was joined to something staying behind (a pin, a label, the middle of
		// a wire) keeps the connection: a new wire from there to where it went
		stubs := make([dynamic]P, context.temp_allocator)
		for p in moved do if anchored_at(s, p) do append(&stubs, p)
		for p in stubs do append(&s.wires, Wire{a = p, b = p + delta})
		// straight horizontal and vertical wires while dragging, not only at the end
		ends := make(map[P]bool, 32, context.temp_allocator)
		for p in moved do ends[p + delta] = true
		wires_orthogonalize(s, ends)
	}
	d.dirty = true
}

wire_corner :: proc(d: ^Doc, a, b: P) -> P {
	if S.wire_routing == "direct" do return a
	return {a.x, b.y} if d.wire_flip else {b.x, a.y}
}

@(private = "file")
interact_wire :: proc(d: ^Doc, v: View, msnap: P, over: bool) {
	s := &d.sch
	ui.cursor = .CROSSHAIR
	ww := line_w(v, S.wire_width)
	mp := to_scr(v, pf(msnap))
	// snap marker
	if over {
		col := th.s_net_highlight if is_connection(s, msnap) else alpha(th.s_wire, 160)
		rl.DrawCircleLinesV({mp.x, mp.y}, 5 * ui_scale, rlc(col))
	}
	if d.wire_active {
		corner := wire_corner(d, d.wire_start, msnap)
		a, c := to_scr(v, pf(d.wire_start)), to_scr(v, pf(corner))
		col := alpha(th.s_wire, 200)
		rl.DrawLineEx({a.x, a.y}, {c.x, c.y}, ww, rlc(col))
		rl.DrawLineEx({c.x, c.y}, {mp.x, mp.y}, ww, rlc(col))
	}
	if !over do return
	if ui.pressed[0] && !key_down(.SPACE) {
		if !d.wire_active {
			d.wire_active = true
			d.wire_start = msnap
			d.wire_flip = false
			return
		}
		if msnap == d.wire_start {
			if ui.double do d.wire_active = false
			return
		}
		ends := S.auto_end_wire && is_connection(s, msnap)
		doc_push_undo(d)
		corner := wire_corner(d, d.wire_start, msnap)
		add_wire(s, d.wire_start, corner, S.cut_through)
		add_wire(s, corner, msnap, S.cut_through)
		d.wire_start = msnap
		if ends || ui.double do d.wire_active = false
	}
	if ui.pressed[1] {
		if d.wire_active do d.wire_active = false
		else do tool_set(d, .Select)
	}
}

@(private = "file")
interact_place :: proc(d: ^Doc, v: View, msnap: P, mp: [2]f32, over: bool) {
	s := &d.sch
	if !over do return
	ui.cursor = .CROSSHAIR
	lw := line_w(v, S.line_width)
	col := th.s_placing
	switch d.place_kind {
	case .Part, .Ground:
		sym := symbol_find(d.place_sym)
		if sym == nil {
			tool_set(d, .Select)
			return
		}
		// the symbol's middle follows the mouse, pins stay on the grid
		mid := xform_f({0, 0}, d.place_rot, d.place_mirror, (sym.lo + sym.hi) / 2)
		pos := snap_to(mp - mid, S.grid)
		if d.place_kind == .Ground do pos = msnap
		draw_symbol_gfx(v, sym, pos, d.place_rot, d.place_mirror, col, lw)
		for p in sym.pins {
			pp := to_scr(v, pf(xform_p(pos, d.place_rot, d.place_mirror, p.at)))
			rl.DrawCircleLinesV({pp.x, pp.y}, 3 * ui_scale, rlc(th.s_pin))
		}
		if ui.pressed[0] && !key_down(.SPACE) {
			doc_push_undo(d)
			if d.place_kind == .Ground {
				append(&s.flags, Flag{name = strings.clone("0"), pos = pos, rot = d.place_rot})
			} else {
				c := Comp{sym = strings.clone(sym.name), ref = strings.clone(next_ref(s, sym.prefix)), value = strings.clone(d.place_value if len(d.place_value) > 0 else sym.value), pos = pos, rot = d.place_rot, mirror = d.place_mirror, attrs = make([dynamic]Attr)}
				append(&s.comps, c)
				if S.cut_through do cut_wires_at_part(s, len(s.comps) - 1)
			}
			if !S.continue_placing do tool_set(d, .Select)
		}
	case .Label:
		f := Flag{name = d.place_text, pos = msnap, rot = d.place_rot}
		draw_flag(v, f, col, line_w(v, S.wire_width))
		if ui.pressed[0] {
			doc_push_undo(d)
			append(&s.flags, Flag{name = strings.clone(d.place_text), pos = msnap, rot = d.place_rot})
			if !S.continue_placing do tool_set(d, .Select)
		}
	case .Text:
		t := Text{pos = msnap, text = d.place_text, directive = d.place_directive}
		draw_text_item(v, t, col)
		if ui.pressed[0] {
			doc_push_undo(d)
			append(&s.texts, Text{pos = msnap, text = strings.clone(d.place_text), directive = d.place_directive})
			tool_set(d, .Select)
		}
	}
	if ui.pressed[1] do tool_set(d, .Select)
}

@(private = "file")
interact_paste :: proc(d: ^Doc, v: View, msnap: P, over: bool) {
	if !over do return
	p := &d.paste
	delta := msnap - d.paste_anchor
	lw := line_w(v, S.line_width)
	col := th.s_placing
	for w in p.wires {
		a, b := to_scr(v, pf(w.a + delta)), to_scr(v, pf(w.b + delta))
		rl.DrawLineEx({a.x, a.y}, {b.x, b.y}, line_w(v, S.wire_width), rlc(col))
	}
	for c in p.comps do if sym := symbol_find(c.sym); sym != nil do draw_symbol_gfx(v, sym, c.pos + delta, c.rot, c.mirror, col, lw)
	for f in p.flags {
		g := f
		g.pos += delta
		draw_flag(v, g, col, lw)
	}
	for t in p.texts {
		g := t
		g.pos += delta
		draw_text_item(v, g, col)
	}
	if ui.pressed[0] {
		s := &d.sch
		doc_push_undo(d)
		sch_select_all(d, false)
		for c in p.comps {
			n := comp_clone(c)
			n.pos += delta
			n.sel = true
			// fresh names when they are taken
			taken := false
			for x in s.comps do if strings.equal_fold(x.ref, n.ref) do taken = true
			if taken {
				if sym := symbol_find(n.sym); sym != nil do set_str(&n.ref, next_ref(s, sym.prefix))
			}
			append(&s.comps, n)
		}
		for w in p.wires do append(&s.wires, Wire{a = w.a + delta, b = w.b + delta, sel = true})
		for f in p.flags do append(&s.flags, Flag{name = strings.clone(f.name), pos = f.pos + delta, rot = f.rot, sel = true})
		for t in p.texts do append(&s.texts, Text{pos = t.pos + delta, text = strings.clone(t.text), directive = t.directive, sel = true})
		wires_cleanup(s)
		tool_set(d, .Select)
		sch_reselect_last(d, len(p.comps), len(p.flags), len(p.texts))
	}
	if ui.pressed[1] do tool_set(d, .Select)
}

// tool_set clears the selection; select the items just pasted again. Not the wires:
// wires_cleanup may have merged them with others, so the last ones are not the pasted ones.
@(private = "file")
sch_reselect_last :: proc(d: ^Doc, nc, nf, nt: int) {
	s := &d.sch
	for i in max(0, len(s.comps) - nc) ..< len(s.comps) do s.comps[i].sel = true
	for i in max(0, len(s.flags) - nf) ..< len(s.flags) do s.flags[i].sel = true
	for i in max(0, len(s.texts) - nt) ..< len(s.texts) do s.texts[i].sel = true
}

// Adds the current of part ci (pin k, -1 = the part) to the waveforms.
probe_comp :: proc(d: ^Doc, ci, pin: int, power, new_pane: bool) {
	c := &d.sch.comps[ci]
	sym := symbol_find(c.sym)
	if sym == nil || sym.probe == .None {
		status(tcat(c.ref, ": no current to probe for this part"), true)
		return
	}
	expr := ""
	if pin >= 0 && len(sym.pins) > 2 {
		pd := sym.pins[pin]
		tag := pd.cur if len(pd.cur) > 0 else pd.name
		expr = fmt.tprintf("I%s(%s)", tag, c.ref)
	} else {
		expr = fmt.tprintf("I(%s)", c.ref)
		if power && len(sym.pins) == 2 {
			ni := nets_build(&d.sch, S.net_prefix)
			a, b := ni.names[ni.pin_net[ci][0]], ni.names[ni.pin_net[ci][1]]
			expr = fmt.tprintf("V(%s,%s)*I(%s)", a, b, c.ref)
			if b == "0" do expr = fmt.tprintf("V(%s)*I(%s)", a, c.ref)
		}
	}
	wave_add_trace(&d.wave, expr, new_pane)
}

@(private = "file")
interact_probe :: proc(d: ^Doc, v: View, ni: ^Net_Info, hit: Hit, hover_net: int, over: bool) {
	m := ui.mouse
	if over {
		// probe cursor: a little pen tip
		ui.cursor = .CROSSHAIR
		col := th.s_net_highlight if hover_net >= 0 else (th.s_hover if hit.kind == .Comp else th.muted)
		rl.DrawLineEx({m.x + 4, m.y - 4}, {m.x + 16, m.y - 16}, 3, rlc(col))
		rl.DrawCircleV({m.x + 3, m.y - 3}, 3, rlc(col))
		if hover_net >= 0 do draw_text(tcat("V(", ni.names[hover_net], ")"), m.x + 18, m.y - 30, col, fs(0.9))
		else if hit.kind == .Comp do draw_text(tcat("I(", d.sch.comps[hit.idx].ref, ")"), m.x + 18, m.y - 30, col, fs(0.9))
	}
	if over && ui.pressed[0] {
		d.probe_from = hover_net
		probe_press_comp = hit.idx if hit.kind == .Comp else -1
		probe_press_pos = m
	}
	if d.probe_from >= 0 && ui.down[0] && hover_net != d.probe_from && hover_net >= 0 {
		// differential probe: a line from the first net
		a := probe_press_pos
		rl.DrawLineEx({a.x, a.y}, {m.x, m.y}, 2, rlc(th.s_net_highlight))
		draw_text(fmt.tprintf("V(%s,%s)", ni.names[d.probe_from], ni.names[hover_net]), m.x + 18, m.y - 50, th.s_net_highlight, fs(0.9))
	}
	if ui.released[0] && (d.probe_from >= 0 || probe_press_comp >= 0) {
		new_pane := ui.ctrl
		if d.probe_from >= 0 {
			a := ni.names[d.probe_from]
			if hover_net >= 0 && hover_net != d.probe_from {
				b := ni.names[hover_net]
				if b == "0" do wave_add_trace(&d.wave, fmt.tprintf("V(%s)", a), new_pane)
				else if a == "0" do wave_add_trace(&d.wave, fmt.tprintf("-V(%s)", b), new_pane)
				else do wave_add_trace(&d.wave, fmt.tprintf("V(%s,%s)", a, b), new_pane)
			} else if a != "0" {
				wave_add_trace(&d.wave, fmt.tprintf("V(%s)", a), new_pane)
			} else {
				status("that is ground (0 V)")
			}
		} else if probe_press_comp >= 0 && hit.kind == .Comp && hit.idx == probe_press_comp {
			c := &d.sch.comps[hit.idx]
			sym := symbol_find(c.sym)
			pin := -1
			if sym != nil && len(sym.pins) > 2 {
				// the pin nearest the mouse
				best := f32(1e9)
				mp := to_sch(v, m)
				for _, k in sym.pins {
					dd := vlen(pf(comp_pin(c, sym, k)) - mp)
					if dd < best {best = dd; pin = k}
				}
			}
			probe_comp(d, hit.idx, pin, ui.alt, new_pane)
		}
		d.probe_from = -1
		probe_press_comp = -1
	}
	if over && ui.pressed[1] do tool_set(d, .Select)
}

probe_press_comp := -1
probe_press_pos: [2]f32
