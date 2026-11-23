package spicy

import "core:math"
import "core:strings"
import rl "vendor:raylib"

// Selectable read-only text. Wrap the drawing of a text area in selectable_begin / _end:
// every line drawn in between (draw_text, draw_mono) is recorded, and the mouse selects
// across them: drag to select, double-click for a line, Ctrl+A for all, Ctrl+C to copy.
// The selection is kept in content coordinates (scrolling keeps it in place).

Tsel_Pos :: struct {
	y, x: f32, // the line's place in the content (y includes the scroll)
	off:  int, // byte in the line
}

Tsel_State :: struct {
	id:   u64,
	a, b: Tsel_Pos,
	drag: bool,
	all:  bool, // Ctrl+A: everything (also the lines not drawn now)
}

@(private = "file")
Run :: struct {
	s:          string,
	x, y, size: f32,
	mono:       bool,
}

@(private = "file")
reg: struct {
	on:   bool,
	id:   u64,
	r:    Rect,
	sc:   f32,
	full: string,
	runs: [dynamic]Run,
}

// Starts a selectable area r whose content is scrolled by sc. full: the whole text (copied by
// Ctrl+A, Ctrl+C), when the area does not draw all of it.
selectable_begin :: proc(id_s: string, r: Rect, sc: f32 = 0, full := "") {
	reg.on = true
	reg.id = id_of(id_s)
	reg.r = r
	reg.sc = sc
	reg.full = full
	reg.runs = make([dynamic]Run, context.temp_allocator)
}

// Called by draw_text / draw_mono.
tsel_record :: proc(s: string, x, y, size: f32, mono: bool) {
	if reg.on do append(&reg.runs, Run{s, x, y, size, mono})
}

@(private = "file")
run_w :: proc(r: Run, s: string) -> f32 {return mono_w(s, r.size) if r.mono else text_w(s, r.size)}

@(private = "file")
pos_of :: proc(r: Run, off: int) -> Tsel_Pos {return {math.round(r.y + reg.sc), math.round(r.x), off}}

@(private = "file")
less :: proc(a, b: Tsel_Pos) -> bool {
	if a.y != b.y do return a.y < b.y
	if a.x != b.x do return a.x < b.x
	return a.off < b.off
}

// The byte of run r nearest to screen x.
@(private = "file")
off_at :: proc(r: Run, x: f32) -> int {
	if x <= r.x do return 0
	prev := 0
	for i := 0; i < len(r.s); {
		n := 1
		for i + n < len(r.s) && (r.s[i + n] & 0xC0) == 0x80 do n += 1
		w0 := run_w(r, r.s[:i])
		w1 := run_w(r, r.s[:i + n])
		if x < r.x + (w0 + w1) / 2 do return i
		prev = i + n
		i += n
	}
	return prev
}

// The run nearest to point m (the line under it, else the closest line), and whether m is on text.
@(private = "file")
hit :: proc(m: [2]f32) -> (idx: int, on_text: bool) {
	idx = -1
	best: f32 = 1e9
	for r, i in reg.runs {
		top, bot := r.y - 2, r.y + r.size + 2
		dy: f32 = 0 if m.y >= top && m.y < bot else min(abs(m.y - top), abs(m.y - bot))
		w := run_w(r, r.s)
		dx: f32 = 0 if m.x >= r.x && m.x <= r.x + w else min(abs(m.x - r.x), abs(m.x - r.x - w))
		d := dy * 1000 + dx
		if d < best {
			best = d
			idx = i
			on_text = dy == 0 && dx < 12 * ui_scale
		}
	}
	return
}

// Ends the area: handles the mouse and keys and draws the selection.
selectable_end :: proc() {
	reg.on = false
	ts := &ui.tsel
	id := reg.id
	inside := hover(reg.r)
	ri, on_text := hit(ui.mouse)
	if inside && on_text && ui.hot == 0 do ui.cursor = .IBEAM
	if ui.pressed[0] {
		if inside && on_text && ui.hot == 0 && ri >= 0 {
			r := reg.runs[ri]
			ts.id = id
			ts.all = false
			if ui.double {
				ts.a, ts.b = pos_of(r, 0), pos_of(r, len(r.s))
				ts.drag = false
			} else {
				ts.a = pos_of(r, off_at(r, ui.mouse.x))
				ts.b = ts.a
				ts.drag = true
			}
		} else if ts.id == id && !inside do ts.id = 0
	}
	if ts.id == id && ts.drag {
		if ui.down[0] {
			if ri >= 0 {
				ts.b = pos_of(reg.runs[ri], off_at(reg.runs[ri], ui.mouse.x))
				ts.all = false
			}
		} else do ts.drag = false
	}
	if (inside || ts.id == id) && ui.ctrl && key_pressed(.A) && ui.focus == 0 && len(reg.runs) > 0 {
		ts.id = id
		ts.all = true
		ts.drag = false
		first, last := reg.runs[0], reg.runs[len(reg.runs) - 1]
		ts.a, ts.b = pos_of(first, 0), pos_of(last, len(last.s))
	}
	if ts.id != id do return
	s, e := ts.a, ts.b
	if less(e, s) do s, e = e, s
	if s == e && !ts.all do return
	// highlight, and the selected text
	out := strings.builder_make(context.temp_allocator)
	prev: ^Run
	for &r in reg.runs {
		p0, p1 := pos_of(r, 0), pos_of(r, len(r.s))
		if !ts.all && (less(p1, s) || less(e, p0)) do continue
		a := s.off if !ts.all && p0.y == s.y && p0.x == s.x else 0
		b := e.off if !ts.all && p0.y == e.y && p0.x == e.x else len(r.s)
		a, b = clamp(a, 0, len(r.s)), clamp(b, 0, len(r.s))
		if b <= a && !(b == a && len(r.s) == 0) do continue
		x0 := r.x + run_w(r, r.s[:a])
		x1 := r.x + run_w(r, r.s[:b])
		push_clip(reg.r)
		fill({x0, r.y - 1, max(x1 - x0, 3), r.size + 2}, alpha(th.sel, 150))
		pop_clip()
		if prev != nil do strings.write_string(&out, "\n" if abs(r.y - prev.y) > 1 else "\t")
		strings.write_string(&out, r.s[a:b])
		prev = &r
	}
	if ui.ctrl && key_pressed(.C) && ui.focus == 0 {
		text := reg.full if ts.all && len(reg.full) > 0 else strings.to_string(out)
		if len(text) > 0 {
			rl.SetClipboardText(cstr(text))
			status("copied")
		}
	}
}
