package spicy

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:strings"
import rl "vendor:raylib"

// The symbol editor: draws a symbol's graphics, places and names its pins, and saves it to
// a symbol file (the one it came from; built-in symbols and new ones go to my-symbols.edn).
// It takes the place of the schematic while open.
//
// A symbol for a subcircuit (an imported model) lists the subcircuit's ports: every pin is
// given a port, and Save writes the netlist line ("X{ref} {pin for port 1} … {value}") so
// the pins may have any names and places. "Start from" copies the drawing and pins of any
// symbol (op-amp, transformer, transistors …) to begin with.
//
// Everything the editor holds lives in one arena, freed when it closes.

Symed_Tool :: enum u8 {Select, Line, Rect, Circle, Arc, Text, Pin}
SYMED_TOOLS := [Symed_Tool]string {
	.Select = "Select",
	.Line   = "Line",
	.Rect   = "Rectangle",
	.Circle = "Circle",
	.Arc    = "Arc",
	.Text   = "Text",
	.Pin    = "Pin",
}
SYMED_TOOL_KEYS := [Symed_Tool]rl.KeyboardKey {
	.Select = .S,
	.Line   = .L,
	.Rect   = .R,
	.Circle = .C,
	.Arc    = .A,
	.Text   = .T,
	.Pin    = .P,
}

Symed_Sel :: enum u8 {None, Gfx, Pin, Ref, Value}

// What undo restores: the symbol, its pins and graphics, and the pins' ports.
Symed_State :: struct {
	sym:        Symbol, // .pins and .gfx are set from the arrays below when used
	pins:       [dynamic]Pin_Def,
	gfx:        [dynamic]Gfx,
	port_of:    [dynamic]int, // per pin: the model port it connects to (-1: none)
	spice_auto: bool, // the netlist line follows the pins (subcircuit call)
	ref_auto, value_auto: bool, // the name / value go right of the drawing until dragged
}

Symed :: struct {
	active:     bool,
	arena:      virtual.Arena,
	using st:   Symed_State,
	orig:       string, // the name it was opened with ("" new)
	file:       string, // where Save writes
	model:      string, // subcircuit the symbol is for ("" none)
	ports:      []string, // its ports as on the .subckt line
	terms:      []string, // their terminal names
	for_doc:    int, // the part that opened the editor (doc id, part index)
	for_comp:   int,
	tool:       Symed_Tool,
	sel:        Symed_Sel,
	sel_idx:    int,
	vertex:     int, // dragged vertex of the selection (-1: the whole item, -2: radius)
	cam:        [2]f32,
	zoom:       f32,
	fitted:     bool,
	panning:    bool,
	drag:       bool,
	drag_from:  [2]f32, // symbol coordinates at the press
	drag_snap:  Symed_State, // before the drag (for undo)
	drag_base:  [dynamic][2]f32, // the dragged item's points at the press
	drag_r:     f32,
	drawing:    bool,
	draw_pts:   [dynamic][2]f32,
	undo, redo: [dynamic]Symed_State,
	dirty:      bool,
	label_pins: bool, // the Pin tool also writes the pin's name beside it
	template:   int,
	confirm:    string, // an action waiting for a second click ("close", "replace")
	msg:        string,
	msg_err:    bool,
}

symed: Symed

@(private = "file")
alloc :: proc() -> runtime.Allocator {return virtual.arena_allocator(&symed.arena)}

@(private = "file")
cl :: proc(s: string) -> string {return strings.clone(s, alloc())}

@(private = "file")
cl_list :: proc(xs: []string) -> []string {
	out := make([]string, len(xs), alloc())
	for x, i in xs do out[i] = cl(x)
	return out
}

@(private = "file")
gfx_clone :: proc(g: Gfx) -> Gfx {
	r := g
	r.pts = make([][2]f32, len(g.pts), alloc())
	copy(r.pts, g.pts)
	r.text = cl(g.text)
	return r
}

@(private = "file")
pin_clone :: proc(p: Pin_Def) -> Pin_Def {
	return {name = cl(p.name), at = p.at, cur = cl(p.cur), element = cl(p.element)}
}

// A deep copy (in the arena) of a symbol's text fields; its pins and graphics are not copied.
@(private = "file")
sym_fields_clone :: proc(s: Symbol) -> Symbol {
	r := s
	r.name, r.desc, r.category, r.prefix, r.key = cl(s.name), cl(s.desc), cl(s.category), cl(s.prefix), cl(s.key)
	r.value, r.spice, r.defs, r.cur = cl(s.value), cl(s.spice), cl(s.defs), cl(s.cur)
	r.source, r.edn, r.like = cl(s.source), "", ""
	r.models = cl_list(s.models)
	r.vacask = {line = cl(s.vacask.line), defs = cl(s.vacask.defs), loads = cl_list(s.vacask.loads), models = cl_list(s.vacask.models)}
	r.pins, r.gfx = nil, nil
	return r
}

@(private = "file")
state_clone :: proc(s: ^Symed_State) -> Symed_State {
	r: Symed_State
	r.sym = sym_fields_clone(s.sym)
	r.pins = make([dynamic]Pin_Def, 0, len(s.pins), alloc())
	for p in s.pins do append(&r.pins, pin_clone(p))
	r.gfx = make([dynamic]Gfx, 0, len(s.gfx), alloc())
	for g in s.gfx do append(&r.gfx, gfx_clone(g))
	r.port_of = make([dynamic]int, 0, len(s.port_of), alloc())
	append(&r.port_of, ..s.port_of[:])
	r.spice_auto = s.spice_auto
	r.ref_auto, r.value_auto = s.ref_auto, s.value_auto
	return r
}

// The symbol as it stands (pins and graphics included), with its bounds.
@(private = "file")
current :: proc() -> Symbol {
	s := symed.sym
	s.pins = symed.pins[:]
	s.gfx = symed.gfx[:]
	symbol_bounds(&s)
	if symed.ref_auto || symed.value_auto {
		ref_at, value_at := label_places(&s)
		if symed.ref_auto do s.ref_at, symed.sym.ref_at = ref_at, ref_at
		if symed.value_auto do s.value_at, symed.sym.value_at = value_at, value_at
		s.has_ref_at, s.has_value_at = true, true
		symed.sym.has_ref_at, symed.sym.has_value_at = true, true
	}
	return s
}

// The name and value right of everything in the symbol (pins, lines and the full width of
// texts such as pin labels), one above the other at its middle.
@(private = "file")
label_places :: proc(s: ^Symbol) -> (ref_at, value_at: [2]f32) {
	right := s.hi.x
	for p in s.pins do right = max(right, f32(p.at.x) + 6) // the pin square
	for g in s.gfx do if g.kind == .Text do right = max(right, g.pts[0].x + text_w(g.text, g.size))
	x := math.ceil((right + 8) / SNAP) * SNAP
	mid := math.round((s.lo.y + s.hi.y) / 2 / SNAP) * SNAP
	return {x, mid - 10}, {x, mid + 10}
}

// Before every change: what undo goes back to.
@(private = "file")
push_undo :: proc() {
	append(&symed.undo, state_clone(&symed.st))
	clear(&symed.redo)
	symed.dirty = true
	symed.confirm = ""
}

@(private = "file")
undo_redo :: proc(from, to: ^[dynamic]Symed_State) {
	if len(from) == 0 do return
	append(to, state_clone(&symed.st))
	symed.st = pop(from)
	symed.sel = .None
	symed.dirty = true
}

// ---------------------------------------------------------------------------
// Opening, saving, closing

// Opens the editor on a symbol (nil: a new one). d / ci: the part it was opened from, whose
// value may name the subcircuit the symbol is for.
symed_open :: proc(src: ^Symbol, d: ^Doc = nil, ci := -1) {
	if symed.active do symed_close()
	symed = {}
	if err := virtual.arena_init_growing(&symed.arena); err != nil {
		status("cannot open the symbol editor (out of memory)", true)
		return
	}
	symed.active = true
	symed.for_doc, symed.for_comp = -1, -1
	symed.zoom = 4
	symed.label_pins = true
	symed.template = -1
	symed.undo = make([dynamic]Symed_State, alloc())
	symed.redo = make([dynamic]Symed_State, alloc())
	symed.drag_base = make([dynamic][2]f32, alloc())
	symed.draw_pts = make([dynamic][2]f32, alloc())
	symed.pins = make([dynamic]Pin_Def, alloc())
	symed.gfx = make([dynamic]Gfx, alloc())
	symed.port_of = make([dynamic]int, alloc())
	if src != nil {
		symed.sym = sym_fields_clone(src^)
		for p in src.pins do append(&symed.pins, pin_clone(p))
		for g in src.gfx do append(&symed.gfx, gfx_clone(g))
		symed.orig = cl(src.name)
		// back into the file it came from; built-in symbols are replaced from my-symbols.edn
		if strings.has_suffix(lower(src.source), ".edn") && file_exists(src.source) do symed.file = cl(src.source)
	} else {
		symed.sym = Symbol{name = cl("new_symbol"), desc = cl("New symbol"), category = cl("My symbols"), prefix = cl("X"), kind = .Part}
		symed.spice_auto = true
		symed.ref_auto, symed.value_auto = true, true
		append(&symed.gfx, Gfx{kind = .Rect, pts = make([][2]f32, 2, alloc()), fill = .Body})
		symed.gfx[0].pts[0], symed.gfx[0].pts[1] = {0, 0}, {64, 64}
	}
	if len(symed.file) == 0 do symed.file = cl(path_join(user_symbols_dir(), "my-symbols.edn"))
	for _ in symed.pins do append(&symed.port_of, -1)
	// the subcircuit: the part's value, else a model with the symbol's name
	e: ^Lib_Entry
	comp: ^Comp
	if d != nil && ci >= 0 && ci < len(d.sch.comps) {
		symed.for_doc, symed.for_comp = d.id, ci
		comp = &d.sch.comps[ci]
		if f := strings.fields(comp.value, context.temp_allocator); len(f) > 0 {
			e = model_lookup(f[0], sch_models(&d.sch, doc_sim(d), dir_of(d.path)))
		}
	}
	if (e == nil || !e.subckt) && src != nil do e = lib_find(src.name)
	if e != nil && e.subckt {
		symed.model = cl(entry_display_name(e))
		symed.ports = cl_list(e.ports)
		symed.terms = cl_list(e.pins)
		symed.spice_auto = true
		if src != nil {
			tc := Comp{value = e.name}
			if comp != nil do tc = comp^
			if order, err := subckt_pin_map(e, src, &tc); len(err) == 0 {
				for k, port in order do if k < len(symed.port_of) do symed.port_of[k] = port
			}
		}
		if src == nil {
			// a new symbol for a model: a box with its pins
			symed.sym.name = cl(e.name)
			symed.sym.desc = cl(tcat(e.name, " (subcircuit)"))
			symed.sym.value = cl(e.name)
			add_missing_pins()
		}
	}
	symed.dirty = src == nil
	status("symbol editor: draw with the tools above, Save when done (Esc: select tool)")
}

symed_close :: proc() {
	virtual.arena_destroy(&symed.arena)
	symed = {}
}

// Pins for the model's ports that have none yet, in a column on the left of the drawing.
@(private = "file")
add_missing_pins :: proc() {
	s := current()
	y := i32(16)
	if len(s.pins) > 0 || len(s.gfx) > 0 do y = i32(math.floor(s.lo.y / 16)) * 16 + 16
	x := i32(math.floor(min(s.lo.x, 0) / 16)) * 16 - 32
	for port, i in symed.ports {
		used := false
		for p in symed.port_of do if p == i do used = true
		if used do continue
		name := sanitize_pin(symed.terms[i] if i < len(symed.terms) else port)
		for unique_pin(name) == false do name = tcat(name, "_")
		add_pin({x, y}, name, i)
		y += 16
	}
}

@(private = "file")
add_pin :: proc(at: [2]i32, name: string, port: int) {
	append(&symed.pins, Pin_Def{name = cl(name), at = at})
	append(&symed.port_of, port)
	if symed.label_pins {
		t := Gfx{kind = .Text, pts = make([][2]f32, 1, alloc()), text = cl(name), size = 9}
		t.pts[0] = {f32(at.x) + 4, f32(at.y) - 6}
		append(&symed.gfx, t)
	}
}

// Pin names go into {…} in netlist lines: no spaces, braces or "|".
@(private = "file")
sanitize_pin :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for ch in strings.trim_space(s) {
		switch ch {
		case ' ', '\t', '{', '}', '|', '"': strings.write_byte(&b, '_')
		case: strings.write_rune(&b, ch)
		}
	}
	return strings.to_string(b)
}

@(private = "file")
unique_pin :: proc(name: string, except := -1) -> bool {
	for p, i in symed.pins do if i != except && p.name == name do return false
	return true
}

// The netlist lines of a symbol for a subcircuit: its pins in port order.
@(private = "file")
auto_lines :: proc() -> (spice, vacask: string, err: string) {
	if len(symed.model) == 0 {
		// a new symbol without a model: a subcircuit call with the pins in their order
		b := strings.builder_make(context.temp_allocator)
		v := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "X{ref}")
		strings.write_string(&v, "{ref} (")
		for p, i in symed.pins {
			fmt.sbprintf(&b, " {{%s}}", p.name)
			fmt.sbprintf(&v, "%s{{%s}}", " " if i > 0 else "", p.name)
		}
		strings.write_string(&b, " {value}")
		strings.write_string(&v, ") {value}")
		return strings.to_string(b), strings.to_string(v), ""
	}
	pin_for := make([]int, len(symed.ports), context.temp_allocator)
	for &x in pin_for do x = -1
	missing := make([dynamic]string, context.temp_allocator)
	for port, k in symed.port_of {
		if port < 0 || port >= len(pin_for) do continue
		if pin_for[port] >= 0 do return "", "", fmt.tprintf("two pins (%s, %s) are given port %s", symed.pins[pin_for[port]].name, symed.pins[k].name, symed.ports[port])
		pin_for[port] = k
	}
	for k, i in pin_for do if k < 0 do append(&missing, symed.ports[i])
	if len(missing) > 0 do return "", "", tcat("no pin for the port(s) ", strings.join(missing[:], " ", context.temp_allocator))
	b := strings.builder_make(context.temp_allocator)
	v := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "X{ref}")
	strings.write_string(&v, "{ref} (")
	for k, i in pin_for {
		fmt.sbprintf(&b, " {{%s}}", symed.pins[k].name)
		fmt.sbprintf(&v, "%s{{%s}}", " " if i > 0 else "", symed.pins[k].name)
	}
	strings.write_string(&b, " {value}")
	strings.write_string(&v, ") {value}")
	return strings.to_string(b), strings.to_string(v), ""
}

@(private = "file")
set_msg :: proc(m: string, err := false) {
	symed.msg = cl(m)
	symed.msg_err = err
}

// Writes the symbol to its file and reloads the library. False (with a message) when it
// is not complete yet.
@(private = "file")
save :: proc() -> bool {
	s := current()
	s.name = strings.trim_space(s.name)
	if len(s.name) == 0 {set_msg("give the symbol a name", true); return false}
	if len(s.pins) == 0 {set_msg("a symbol needs at least one pin (Pin tool)", true); return false}
	for p, i in s.pins {
		if len(p.name) == 0 {set_msg("every pin needs a name", true); return false}
		if !unique_pin(p.name, i) {set_msg(tcat("two pins are called ", p.name), true); return false}
	}
	if symed.spice_auto {
		sp, va, err := auto_lines()
		if len(err) > 0 {set_msg(tcat("Ports: ", err), true); return false}
		s.spice, s.vacask = sp, Vacask_Def{line = va}
		if len(s.prefix) == 0 do s.prefix = "X"
		if len(symed.model) > 0 && len(s.value) == 0 do s.value = symed.model
	} else if len(strings.trim_space(s.spice)) == 0 {
		set_msg("the netlist line is empty", true)
		return false
	}
	// another symbol with this name is replaced only after a second click
	if s.name != symed.orig && symbol_find(s.name) != nil && symed.confirm != "replace" {
		symed.confirm = "replace"
		set_msg(tcat("a symbol called ", s.name, " exists: Save again to replace it"), true)
		return false
	}
	text := symbol_to_edn(&s)
	tmpl := MY_SYMBOLS_TEMPLATE
	head := tmpl[:strings.index(tmpl, "[]")]
	if strings.has_suffix(symed.file, "imported.edn") do head = IMPORTED_SYMBOLS_HEAD
	file := symed.file
	// a copy under a new name goes to my-symbols.edn (the original stays where it is)
	if s.name != symed.orig && len(symed.orig) > 0 && !strings.has_suffix(file, "my-symbols.edn") do file = path_join(user_symbols_dir(), "my-symbols.edn")
	if !symbol_file_put(file, head, {s.name}, {text}) {
		set_msg(tcat("cannot write ", file), true)
		return false
	}
	symbols_reload()
	// the part the editor was opened from uses the symbol
	for d in app.docs do if d.id == symed.for_doc && symed.for_comp < len(d.sch.comps) {
		c := &d.sch.comps[symed.for_comp]
		if c.sym != s.name {
			doc_push_undo(d)
			set_str(&c.sym, s.name)
		}
	}
	symed.orig = cl(s.name)
	symed.file = cl(file)
	symed.sym.name = cl(s.name)
	symed.dirty = false
	symed.confirm = ""
	set_msg(tcat("saved to ", file))
	status(tcat("symbol ", s.name, " saved to ", file))
	return true
}

// ---------------------------------------------------------------------------
// Drawing and interaction

@(private = "file")
SNAP :: 4 // graphics; pins sit on the 16 grid

@(private = "file")
snapf :: proc(p: [2]f32, g: f32) -> [2]f32 {return {math.round(p.x / g) * g + 0, math.round(p.y / g) * g + 0}} // + 0: no -0

@(private = "file")
view_for :: proc(r: Rect) -> View {
	return {r = r, c = {r.x + r.w / 2, r.y + r.h / 2}, cam = symed.cam, z = symed.zoom * ui_scale}
}

@(private = "file")
fit :: proc(r: Rect) {
	s := current()
	lo, hi := s.lo - 32, s.hi + 32
	if s.has_ref_at do hi.x = max(hi.x, s.ref_at.x + 64)
	if s.has_value_at do hi.x = max(hi.x, s.value_at.x + 64)
	symed.cam = (lo + hi) / 2
	symed.zoom = clamp(min(r.w / (hi.x - lo.x), r.h / (hi.y - lo.y)) / ui_scale, 0.5, 12)
}

// The text rectangles of the name and value (screen), as on the schematic.
@(private = "file")
label_rects :: proc(v: View, s: ^Symbol) -> (ref, val: Comp_Text) {
	c := Comp{ref = tcat(s.prefix if len(s.prefix) > 0 else "X", "1"), value = s.value if len(s.value) > 0 else "value"}
	return comp_texts(v, &c, s)
}

@(private = "file")
gfx_hit :: proc(v: View, g: Gfx, p: [2]f32, tol: f32) -> bool {
	switch g.kind {
	case .Line:
		for i in 1 ..< len(g.pts) do if seg_dist(p, g.pts[i - 1], g.pts[i]) <= tol do return true
	case .Poly:
		for i in 0 ..< len(g.pts) do if seg_dist(p, g.pts[i], g.pts[(i + 1) % len(g.pts)]) <= tol do return true
		if g.fill != .None && point_in_poly(p, g.pts) do return true
	case .Rect:
		a, b := g.pts[0], g.pts[1]
		c := [4][2]f32{a, {b.x, a.y}, b, {a.x, b.y}}
		for i in 0 ..< 4 do if seg_dist(p, c[i], c[(i + 1) % 4]) <= tol do return true
		if g.fill == .Line_Color && p.x >= min(a.x, b.x) && p.x <= max(a.x, b.x) && p.y >= min(a.y, b.y) && p.y <= max(a.y, b.y) do return true
	case .Circle:
		dd := vlen(p - g.pts[0])
		if abs(dd - g.r) <= tol || (g.fill == .Line_Color && dd <= g.r) do return true
	case .Arc:
		if abs(vlen(p - g.pts[0]) - g.r) <= tol {
			a := math.to_degrees(math.atan2(p.y - g.pts[0].y, p.x - g.pts[0].x))
			lo, hi := min(g.a0, g.a1), max(g.a0, g.a1)
			for k in -1 ..= 1 do if a + f32(k) * 360 >= lo - 5 && a + f32(k) * 360 <= hi + 5 do return true
		}
	case .Text:
		sz := g.size * v.z
		sp := to_scr(v, g.pts[0])
		m := to_scr(v, p)
		return r_contains({sp.x - 2, sp.y - sz / 2 - 2, text_w(g.text, sz) + 4, sz + 4}, m)
	}
	return false
}

@(private = "file")
point_in_poly :: proc(p: [2]f32, pts: [][2]f32) -> bool {
	inside := false
	j := len(pts) - 1
	for i in 0 ..< len(pts) {
		a, b := pts[i], pts[j]
		if (a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x do inside = !inside
		j = i
	}
	return inside
}

// What is under the mouse: pins first, then the name and value, then graphics (top first).
@(private = "file")
hit_at :: proc(v: View, m: [2]f32) -> (Symed_Sel, int) {
	p := to_sch(v, m)
	tol := 6 / v.z
	for pd, i in symed.pins do if vlen(p - {f32(pd.at.x), f32(pd.at.y)}) <= tol * 1.4 do return .Pin, i
	s := current()
	ref, val := label_rects(v, &s)
	if r_contains(r_inset(val.r, -3), m) do return .Value, 0
	if r_contains(r_inset(ref.r, -3), m) do return .Ref, 0
	for i := len(symed.gfx) - 1; i >= 0; i -= 1 do if gfx_hit(v, symed.gfx[i], p, tol) do return .Gfx, i
	return .None, -1
}

// The vertex of the selected item under the mouse: point index, -2 for a circle's / arc's
// rim, -1 none.
@(private = "file")
vertex_at :: proc(v: View, p: [2]f32) -> int {
	if symed.sel != .Gfx || symed.sel_idx >= len(symed.gfx) do return -1
	g := symed.gfx[symed.sel_idx]
	tol := 7 / v.z
	switch g.kind {
	case .Line, .Poly, .Rect:
		for q, i in g.pts do if vlen(p - q) <= tol do return i
	case .Circle, .Arc:
		if abs(vlen(p - g.pts[0]) - g.r) <= tol do return -2
	case .Text:
	}
	return -1
}

// Draws the editor in r (the main area) and handles its input.
symed_draw :: proc(r: Rect) {
	r := r
	if !symed.active do return
	fill(r, th.bg)
	bar := cut_top(&r, fs() + 18)
	panel := cut_right(&r, 380 * ui_scale)
	canvas := r
	draw_toolbar_row(bar)
	if !symed.active do return // closed from the bar
	draw_panel(panel)
	if !symed.active do return
	draw_canvas(canvas)
	if !typing() && ui.popup_id == 0 && !ui.modal do keys()
}

@(private = "file")
draw_toolbar_row :: proc(r: Rect) {
	r := r
	fill(r, th.bar)
	line(r.x, r.y + r.h - 1, r.x + r.w, r.y + r.h - 1, th.border)
	cut_left(&r, 6)
	for t in Symed_Tool {
		label := SYMED_TOOLS[t]
		key := fmt.tprintf("%v", SYMED_TOOL_KEYS[t])
		b := cut_left(&r, text_w(label) + 22)
		if tool_button(tcat("symed.tool.", label), r_inset(b, 3), label, true, symed.tool == t, tcat(label, " (", key, ")")) {
			symed.tool = t
			symed.drawing = false
		}
	}
	cut_left(&r, 12)
	if tool_button("symed.undo", r_inset(cut_left(&r, text_w("Undo") + 22), 3), "Undo", len(symed.undo) > 0, false, "Ctrl+Z") do undo_redo(&symed.undo, &symed.redo)
	if tool_button("symed.redo", r_inset(cut_left(&r, text_w("Redo") + 22), 3), "Redo", len(symed.redo) > 0, false, "Ctrl+Y") do undo_redo(&symed.redo, &symed.undo)
	if tool_button("symed.fit", r_inset(cut_left(&r, text_w("Fit") + 22), 3), "Fit", true, false, "F") do symed.fitted = false
	closing := symed.confirm == "close"
	cl_label := "Discard changes" if closing else "Close"
	if tool_button("symed.close", r_inset(cut_right(&r, text_w(cl_label) + 24), 3), cl_label, true, false, "", th.err if closing else {}) {
		if symed.dirty && !closing {
			symed.confirm = "close"
			set_msg("unsaved changes: click Discard changes to close without saving", true)
		} else {
			symed_close()
			return
		}
	}
	if tool_button("symed.save", r_inset(cut_right(&r, text_w("Save") + 24), 3), "Save", true, false, "Ctrl+S", th.accent) do save()
	title := tcat("Symbol editor – ", symed.sym.name, " •" if symed.dirty else "", "   ", base_name(symed.file))
	text_in(r, fit_text(title, r.w - 20), th.muted, 2, fs(0.9), 10)
}

@(private = "file")
draw_canvas :: proc(r: Rect) {
	if !symed.fitted {
		fit(r)
		symed.fitted = true
	}
	fill(r, th.s_bg)
	push_clip(r)
	defer pop_clip()
	v := view_for(r)
	m := ui.mouse
	over := hover(r) && ui.popup_id == 0 && !ui.modal
	p := to_sch(v, m)
	// grid: dots every 16, lines through the origin
	g := f32(16)
	if g * v.z >= 6 {
		x0 := math.floor(to_sch(v, {r.x, r.y}).x / g) * g
		y0 := math.floor(to_sch(v, {r.x, r.y}).y / g) * g
		x1, y1 := to_sch(v, {r.x + r.w, r.y + r.h}).x, to_sch(v, {r.x + r.w, r.y + r.h}).y
		for x := x0; x <= x1; x += g do for y := y0; y <= y1; y += g {
			sp := to_scr(v, {x, y})
			rl.DrawRectangleV({sp.x - 1, sp.y - 1}, {2, 2}, rlc(th.s_grid))
		}
	}
	o := to_scr(v, {0, 0})
	line(o.x - 10, o.y, o.x + 10, o.y, th.s_grid_major, 1)
	line(o.x, o.y - 10, o.x, o.y + 10, th.s_grid_major, 1)
	s := current()
	lw := line_w(v, 1.5)
	draw_symbol_gfx(v, &s, {0, 0}, 0, false, th.s_symbol, lw)
	// the selection over it
	if symed.sel == .Gfx && symed.sel_idx < len(symed.gfx) {
		one := s
		one.gfx = symed.gfx[symed.sel_idx:symed.sel_idx + 1]
		draw_symbol_gfx(v, &one, {0, 0}, 0, false, th.s_select, lw + 1)
		for q in symed.gfx[symed.sel_idx].pts {
			sp := to_scr(v, q)
			stroke({sp.x - 4, sp.y - 4, 8, 8}, th.s_select, 1)
		}
	}
	// pins with their names (the names are not part of the drawing)
	for pd, i in symed.pins {
		sp := to_scr(v, {f32(pd.at.x), f32(pd.at.y)})
		col := th.s_select if symed.sel == .Pin && symed.sel_idx == i else th.s_pin
		if col[3] == 0 do col = th.accent
		stroke({sp.x - 5, sp.y - 5, 10, 10}, col, 2)
		port := ""
		if i < len(symed.port_of) && symed.port_of[i] >= 0 && symed.port_of[i] < len(symed.ports) do port = tcat(" → ", symed.ports[symed.port_of[i]])
		else if len(symed.ports) > 0 do port = " → ?"
		draw_text(tcat(pd.name, port), sp.x + 7, sp.y + 4, th.err if port == " → ?" else th.muted, fs(0.8))
	}
	// name and value
	ref, val := label_rects(v, &s)
	draw_text(ref.s, ref.r.x, ref.r.y, th.s_select if symed.sel == .Ref else th.s_ref, ref.r.h)
	draw_text(val.s, val.r.x, val.r.y, th.s_select if symed.sel == .Value else th.s_value, val.r.h)
	// zoom and pan
	if over && ui.wheel != 0 {
		before := to_sch(v, m)
		symed.zoom = clamp(symed.zoom * (1.15 if ui.wheel > 0 else 1 / 1.15), 0.5, 20)
		v2 := view_for(r)
		symed.cam += before - to_sch(v2, m)
		v = view_for(r)
	}
	if over && ui.pressed[2] do symed.panning = true
	if symed.panning {
		symed.cam -= ui.delta / v.z
		if !ui.down[2] do symed.panning = false
	}
	// tools
	switch symed.tool {
	case .Select: select_tool(v, r, over, p)
	case .Line: line_tool(v, over, p)
	case .Rect, .Circle, .Arc: shape_tool(v, over, p)
	case .Text:
		if over && ui.pressed[0] {
			push_undo()
			t := Gfx{kind = .Text, pts = make([][2]f32, 1, alloc()), text = cl("text"), size = 12}
			t.pts[0] = snapf(p, SNAP)
			append(&symed.gfx, t)
			symed.sel, symed.sel_idx = .Gfx, len(symed.gfx) - 1
			symed.tool = .Select
			focus_field("symed.gtext")
		}
	case .Pin:
		at := snapf(p, 16)
		if over {
			sp := to_scr(v, at)
			stroke({sp.x - 5, sp.y - 5, 10, 10}, th.s_placing, 2)
		}
		if over && ui.pressed[0] {
			push_undo()
			// the next model port without a pin, else P<n>
			port := -1
			name := ""
			for pt, i in symed.ports {
				used := false
				for q in symed.port_of do if q == i do used = true
				if !used {
					port = i
					name = sanitize_pin(symed.terms[i] if i < len(symed.terms) else pt)
					break
				}
			}
			if len(name) == 0 {
				for k := len(symed.pins) + 1; ; k += 1 {
					name = fmt.tprintf("P%d", k)
					if unique_pin(name) do break
				}
			}
			for !unique_pin(name) do name = tcat(name, "_")
			add_pin({i32(at.x), i32(at.y)}, name, port)
			symed.sel, symed.sel_idx = .Pin, len(symed.pins) - 1
		}
	}
	hint := ""
	switch symed.tool {
	case .Select: hint = "click to select, drag to move (a square handle moves one point) · Del deletes · arrows nudge · middle-drag pans, wheel zooms"
	case .Line: hint = "click the points, double-click or Enter to finish, Esc to cancel"
	case .Rect: hint = "drag from corner to corner"
	case .Circle: hint = "drag from the centre"
	case .Arc: hint = "drag from the centre; set the angles on the right"
	case .Text: hint = "click where the text goes"
	case .Pin: hint = "click to place a pin (pins sit on the 16 grid)"
	}
	draw_text(hint, r.x + 10, r.y + r.h - fs(0.9) - 8, th.muted, fs(0.9))
	ps := snapf(p, SNAP)
	coord := fmt.tprintf("%g, %g", ps.x, ps.y)
	draw_text(coord, r.x + r.w - text_w(coord, fs(0.9)) - 10, r.y + r.h - fs(0.9) - 8, th.muted, fs(0.9))
}

@(private = "file")
select_tool :: proc(v: View, r: Rect, over: bool, p: [2]f32) {
	if over {
		k, _ := hit_at(v, ui.mouse)
		if k != .None || vertex_at(v, p) != -1 do ui.cursor = .POINTING_HAND
	}
	if over && ui.pressed[0] {
		symed.vertex = vertex_at(v, p)
		if symed.vertex == -1 {
			symed.sel, symed.sel_idx = hit_at(v, ui.mouse)
		}
		if symed.sel != .None {
			symed.drag = true
			symed.drag_from = p
			symed.drag_snap = state_clone(&symed.st)
			clear(&symed.drag_base)
			#partial switch symed.sel {
			case .Gfx:
				append(&symed.drag_base, ..symed.gfx[symed.sel_idx].pts)
				symed.drag_r = symed.gfx[symed.sel_idx].r
			case .Pin:
				pd := symed.pins[symed.sel_idx]
				append(&symed.drag_base, [2]f32{f32(pd.at.x), f32(pd.at.y)})
			case .Ref:
				s := current()
				ref, _ := label_rects(v, &s)
				append(&symed.drag_base, symed.sym.ref_at if symed.sym.has_ref_at else to_sch(v, {ref.r.x, ref.r.y + ref.r.h / 2}))
			case .Value:
				s := current()
				_, val := label_rects(v, &s)
				append(&symed.drag_base, symed.sym.value_at if symed.sym.has_value_at else to_sch(v, {val.r.x, val.r.y + val.r.h / 2}))
			}
		}
	}
	if !symed.drag do return
	ui.cursor = .RESIZE_ALL
	d := p - symed.drag_from
	moved := vlen(d * v.z) > 3
	if moved || !ui.down[0] {
		#partial switch symed.sel {
		case .Gfx:
			g := &symed.gfx[symed.sel_idx]
			switch {
			case symed.vertex >= 0:
				q := snapf(p, SNAP)
				g.pts[symed.vertex] = q
			case symed.vertex == -2:
				g.r = max(2, math.round(vlen(p - g.pts[0]) / 2) * 2)
			case:
				dd := snapf(d, SNAP)
				for &q, i in g.pts do q = symed.drag_base[i] + dd
			}
		case .Pin:
			at := snapf(symed.drag_base[0] + d, 16)
			old := symed.pins[symed.sel_idx].at
			symed.pins[symed.sel_idx].at = {i32(at.x), i32(at.y)}
			// the pin's own name label goes along
			delta := [2]f32{at.x - f32(old.x), at.y - f32(old.y)}
			if delta != {} do for &g in symed.gfx do if g.kind == .Text && g.text == symed.pins[symed.sel_idx].name && vlen(g.pts[0] - {f32(old.x), f32(old.y)}) < 40 do g.pts[0] += delta
		case .Ref:
			symed.sym.ref_at = snapf(symed.drag_base[0] + d, SNAP)
			symed.sym.has_ref_at = true
			symed.ref_auto = false
		case .Value:
			symed.sym.value_at = snapf(symed.drag_base[0] + d, SNAP)
			symed.sym.has_value_at = true
			symed.value_auto = false
		}
	}
	if !ui.down[0] {
		symed.drag = false
		if moved {
			append(&symed.undo, symed.drag_snap)
			clear(&symed.redo)
			symed.dirty = true
		}
	}
}

@(private = "file")
line_tool :: proc(v: View, over: bool, p: [2]f32) {
	q := snapf(p, SNAP)
	finish :: proc() {
		if len(symed.draw_pts) >= 2 {
			push_undo()
			g := Gfx{kind = .Line, pts = make([][2]f32, len(symed.draw_pts), alloc())}
			copy(g.pts, symed.draw_pts[:])
			append(&symed.gfx, g)
		}
		clear(&symed.draw_pts)
		symed.drawing = false
	}
	if over && ui.pressed[0] {
		if ui.double && symed.drawing {
			finish()
			return
		}
		if !symed.drawing {
			clear(&symed.draw_pts)
			symed.drawing = true
		}
		if len(symed.draw_pts) == 0 || symed.draw_pts[len(symed.draw_pts) - 1] != q do append(&symed.draw_pts, q)
	}
	if symed.drawing {
		if key_pressed(.ENTER) || key_pressed(.KP_ENTER) || (over && ui.pressed[1]) do finish()
		else if key_pressed(.ESCAPE) {
			clear(&symed.draw_pts)
			symed.drawing = false
		}
	}
	if symed.drawing && len(symed.draw_pts) > 0 {
		lw := line_w(v, 1.5)
		for i in 1 ..< len(symed.draw_pts) {
			a, b := to_scr(v, symed.draw_pts[i - 1]), to_scr(v, symed.draw_pts[i])
			line(a.x, a.y, b.x, b.y, th.s_placing, lw)
		}
		a, b := to_scr(v, symed.draw_pts[len(symed.draw_pts) - 1]), to_scr(v, q)
		line(a.x, a.y, b.x, b.y, th.s_placing, lw)
	}
}

@(private = "file")
shape_tool :: proc(v: View, over: bool, p: [2]f32) {
	q := snapf(p, SNAP)
	if over && ui.pressed[0] {
		symed.drawing = true
		clear(&symed.draw_pts)
		append(&symed.draw_pts, q)
	}
	if !symed.drawing || len(symed.draw_pts) == 0 do return
	a := symed.draw_pts[0]
	rad := math.round(vlen(q - a) / 2) * 2
	g: Gfx
	switch symed.tool {
	case .Rect:
		g = {kind = .Rect, pts = make([][2]f32, 2, context.temp_allocator)}
		g.pts[0], g.pts[1] = a, q
	case .Circle:
		g = {kind = .Circle, pts = make([][2]f32, 1, context.temp_allocator), r = rad}
		g.pts[0] = a
	case .Arc:
		g = {kind = .Arc, pts = make([][2]f32, 1, context.temp_allocator), r = rad, a0 = -90, a1 = 90}
		g.pts[0] = a
	case .Select, .Line, .Text, .Pin:
		return
	}
	preview := Symbol{gfx = []Gfx{g}}
	draw_symbol_gfx(v, &preview, {0, 0}, 0, false, th.s_placing, line_w(v, 1.5))
	if key_pressed(.ESCAPE) {
		symed.drawing = false
		return
	}
	if !ui.down[0] {
		symed.drawing = false
		empty := (g.kind == .Rect && (g.pts[0].x == g.pts[1].x || g.pts[0].y == g.pts[1].y)) || (g.kind != .Rect && g.r < 2)
		if empty do return
		push_undo()
		append(&symed.gfx, gfx_clone(g))
		symed.sel, symed.sel_idx = .Gfx, len(symed.gfx) - 1
	}
}

@(private = "file")
delete_selected :: proc() {
	#partial switch symed.sel {
	case .Gfx:
		if symed.sel_idx >= len(symed.gfx) do return
		push_undo()
		ordered_remove(&symed.gfx, symed.sel_idx)
	case .Pin:
		if symed.sel_idx >= len(symed.pins) do return
		push_undo()
		name := symed.pins[symed.sel_idx].name
		at := symed.pins[symed.sel_idx].at
		ordered_remove(&symed.pins, symed.sel_idx)
		ordered_remove(&symed.port_of, symed.sel_idx)
		// and its name label
		for g, i in symed.gfx do if g.kind == .Text && g.text == name && vlen(g.pts[0] - {f32(at.x), f32(at.y)}) < 40 {
			ordered_remove(&symed.gfx, i)
			break
		}
	case:
		return
	}
	symed.sel = .None
}

@(private = "file")
nudge :: proc(d: [2]f32) {
	#partial switch symed.sel {
	case .Gfx:
		push_undo()
		for &q in symed.gfx[symed.sel_idx].pts do q += d * SNAP
	case .Pin:
		push_undo()
		symed.pins[symed.sel_idx].at += {i32(d.x) * 16, i32(d.y) * 16}
	}
}

@(private = "file")
keys :: proc() {
	if ui.ctrl {
		if key_pressed(.Z) && !ui.shift do undo_redo(&symed.undo, &symed.redo)
		if key_pressed(.Y) || (key_pressed(.Z) && ui.shift) do undo_redo(&symed.redo, &symed.undo)
		if key_pressed(.S) do save()
		if key_pressed(.D) && symed.sel == .Gfx {
			push_undo()
			g := gfx_clone(symed.gfx[symed.sel_idx])
			for &q in g.pts do q += 8
			append(&symed.gfx, g)
			symed.sel_idx = len(symed.gfx) - 1
		}
		return
	}
	if key_pressed(.DELETE) || key_pressed(.BACKSPACE) do delete_selected()
	if key(.LEFT) do nudge({-1, 0})
	if key(.RIGHT) do nudge({1, 0})
	if key(.UP) do nudge({0, -1})
	if key(.DOWN) do nudge({0, 1})
	if key_pressed(.F) do symed.fitted = false
	if key_pressed(.ESCAPE) && !symed.drawing {
		if symed.tool != .Select do symed.tool = .Select
		else do symed.sel = .None
	}
	if !symed.drawing do for t in Symed_Tool do if key_pressed(SYMED_TOOL_KEYS[t]) do symed.tool = t
}

// ---------------------------------------------------------------------------
// The panel on the right: the symbol's fields, the model's ports, the selection

@(private = "file")
prow :: proc(b: ^Rect, label: string) -> Rect {
	r := cut_top(b, fs() + 12)
	cut_top(b, 6)
	if len(label) > 0 {
		lr := cut_left(&r, 110 * ui_scale)
		text_in(lr, label, th.muted, 0, fs(0.9), 0)
	}
	return r
}

@(private = "file")
heading :: proc(b: ^Rect, t: string) {
	cut_top(b, 6)
	r := cut_top(b, fs() + 8)
	text_in(r, t, th.fg, 0, fs(), 0)
	line(r.x, r.y + r.h, r.x + r.w, r.y + r.h, th.border)
	cut_top(b, 6)
}

// A text field bound to an arena string: assigns on commit, true when it changed.
@(private = "file")
afield :: proc(id: string, r: Rect, s: ^string, undoable := true) -> bool {
	commit, _, text := edit_field(id, r, s^)
	if commit && text != s^ {
		if undoable do push_undo()
		s^ = cl(text)
		return true
	}
	return false
}

@(private = "file")
num_field :: proc(id: string, r: Rect, x: ^f32) -> bool {
	commit, _, text := edit_field(id, r, fmt.tprintf("%g", x^))
	if commit {
		if v, ok := parse_eng(text); ok && f32(v) != x^ {
			push_undo()
			x^ = f32(v)
			return true
		}
	}
	return false
}

@(private = "file")
draw_panel :: proc(r: Rect) {
	fill(r, th.panel)
	line(r.x, r.y, r.x, r.y + r.h, th.border)
	b := r_inset(r, 12)
	heading(&b, "Symbol")
	afield("symed.name", prow(&b, "Name"), &symed.sym.name)
	afield("symed.desc", prow(&b, "Description"), &symed.sym.desc)
	afield("symed.cat", prow(&b, "Category"), &symed.sym.category)
	afield("symed.prefix", prow(&b, "Name prefix"), &symed.sym.prefix)
	afield("symed.value", prow(&b, "Value"), &symed.sym.value)
	if symed.spice_auto {
		sp, _, err := auto_lines()
		rr := prow(&b, "Netlist line")
		text_in(rr, fit_text(err if len(err) > 0 else sp, rr.w), th.err if len(err) > 0 else th.muted, 0, fs(0.85), 4)
	} else {
		afield("symed.spice", prow(&b, "Netlist line"), &symed.sym.spice)
	}
	// starting from another symbol
	all := make([dynamic]string, context.temp_allocator)
	syms := make([dynamic]^Symbol, context.temp_allocator)
	for s in symbols_by_category() do if s.kind == .Part {
		append(&all, tcat(s.category, " – ", s.desc))
		append(&syms, s)
	}
	rr := prow(&b, "Start from")
	ub := cut_right(&rr, text_w("Use") + 24)
	cut_right(&rr, 6)
	combo("symed.template", rr, all[:], &symed.template)
	if button("symed.use", ub, "Use", symed.template >= 0 && symed.template < len(syms)) do use_template(syms[symed.template])
	// the model's ports
	if len(symed.model) > 0 {
		heading(&b, tcat("Model ", symed.model))
		missing := make([dynamic]string, context.temp_allocator)
		for port, i in symed.ports {
			used := false
			for q in symed.port_of do if q == i do used = true
			if !used do append(&missing, port)
		}
		info := tcat("Ports: ", strings.join(symed.ports, " ", context.temp_allocator))
		if len(missing) > 0 do info = tcat(info, "\nWithout a pin: ", strings.join(missing[:], " ", context.temp_allocator))
		h := draw_wrapped(info, {b.x, b.y, b.w, fs() * 4}, th.err if len(missing) > 0 else th.muted, fs(0.9))
		cut_top(&b, h + 6)
		if len(missing) > 0 {
			br := prow(&b, "")
			if button("symed.addpins", br, "Add pins for the ports without one") {
				push_undo()
				add_missing_pins()
			}
		}
	}
	checkbox("symed.labelpins", prow(&b, ""), "Pin tool writes the pin name beside the pin", &symed.label_pins)
	// the selection
	switch symed.sel {
	case .Pin:
		if symed.sel_idx >= len(symed.pins) do break
		pd := &symed.pins[symed.sel_idx]
		heading(&b, "Pin")
		old := pd.name
		commit, _, text := edit_field("symed.pname", prow(&b, "Name"), pd.name)
		if commit && text != old {
			nn := sanitize_pin(text)
			if len(nn) == 0 || !unique_pin(nn, symed.sel_idx) {
				set_msg(tcat("there is already a pin called ", nn), true)
			} else {
				push_undo()
				rename_pin(symed.sel_idx, old, nn)
			}
		}
		if len(symed.ports) > 0 {
			items := make([dynamic]string, context.temp_allocator)
			append(&items, "–")
			for port, i in symed.ports {
				t := symed.terms[i] if i < len(symed.terms) else port
				append(&items, port if t == port else tcat(port, " (", t, ")"))
			}
			sel := symed.port_of[symed.sel_idx] + 1
			if combo("symed.pport", prow(&b, "Model port"), items[:], &sel) {
				push_undo()
				symed.port_of[symed.sel_idx] = sel - 1
			}
		}
		x, y := f32(pd.at.x), f32(pd.at.y)
		xr := prow(&b, "Position")
		yr := cut_right(&xr, xr.w / 2 - 3)
		cut_right(&xr, 6)
		if num_field("symed.px", xr, &x) || num_field("symed.py", yr, &y) {
			at := snapf({x, y}, 16)
			symed.pins[symed.sel_idx].at = {i32(at.x), i32(at.y)}
		}
		if button("symed.pdel", prow(&b, ""), "Delete pin") do delete_selected()
	case .Gfx:
		if symed.sel_idx >= len(symed.gfx) do break
		g := &symed.gfx[symed.sel_idx]
		heading(&b, fmt.tprintf("%v", g.kind))
		#partial switch g.kind {
		case .Text:
			afield("symed.gtext", prow(&b, "Text"), &g.text)
			num_field("symed.gsize", prow(&b, "Size"), &g.size)
		case .Arc:
			num_field("symed.ga0", prow(&b, "From (°)"), &g.a0)
			num_field("symed.ga1", prow(&b, "To (°)"), &g.a1)
			num_field("symed.gr", prow(&b, "Radius"), &g.r)
		case .Circle:
			num_field("symed.gr", prow(&b, "Radius"), &g.r)
		}
		if g.kind == .Rect || g.kind == .Circle || g.kind == .Poly {
			fills := []string{"Outline", "Filled (line colour)", "Body colour"}
			sel := int(g.fill)
			if combo("symed.gfill", prow(&b, "Fill"), fills, &sel) {
				push_undo()
				g.fill = Gfx_Fill(sel)
			}
		}
		if button("symed.gdel", prow(&b, ""), "Delete") do delete_selected()
	case .Ref, .Value:
		heading(&b, "Name" if symed.sel == .Ref else "Value")
		draw_wrapped("Where the part's name / value is written. Drag it on the drawing.", {b.x, b.y, b.w, fs() * 3}, th.muted, fs(0.9))
		cut_top(&b, fs() * 3)
	case .None:
		heading(&b, "How to")
		help := "Draw with the tools above (keys S L R C A T P). Pins are where wires connect: each pin of a model's symbol needs a model port. Pin names may be anything; their labels are text items you can move or delete.\n\nStart from copies the drawing and pins of another symbol: op-amp, transformer, transistor …\n\nSave writes the symbol to "
		help = tcat(help, base_name(symed.file), " and every part using it changes.")
		h := draw_wrapped(help, {b.x, b.y, b.w, fs() * 12}, th.muted, fs(0.9))
		cut_top(&b, h)
	}
	if len(symed.msg) > 0 {
		mr := cut_bottom(&b, fs() * 3)
		draw_wrapped(symed.msg, mr, th.err if symed.msg_err else th.ok, fs(0.9))
	}
}

// A pin's new name, in the netlist lines and its label too.
@(private = "file")
rename_pin :: proc(k: int, old, nn: string) {
	symed.pins[k].name = cl(nn)
	for &g in symed.gfx do if g.kind == .Text && g.text == old do g.text = cl(nn)
	if !symed.spice_auto {
		a, _ := strings.replace_all(symed.sym.spice, tcat("{", old, "}"), tcat("{", nn, "}"), context.temp_allocator)
		symed.sym.spice = cl(a)
		b, _ := strings.replace_all(symed.sym.vacask.line, tcat("{", old, "}"), tcat("{", nn, "}"), context.temp_allocator)
		symed.sym.vacask.line = cl(b)
	}
}

// Another symbol's drawing, pins and name/value places; a model's ports are given to the
// pins whose names match.
@(private = "file")
use_template :: proc(t: ^Symbol) {
	push_undo()
	clear(&symed.gfx)
	clear(&symed.pins)
	clear(&symed.port_of)
	for g in t.gfx do append(&symed.gfx, gfx_clone(g))
	for p in t.pins {
		append(&symed.pins, pin_clone(p))
		port := -1
		for pt, i in symed.ports {
			term := symed.terms[i] if i < len(symed.terms) else pt
			if pins_match(pt, p.name) || pins_match(term, p.name) {
				used := false
				for q in symed.port_of do if q == i do used = true
				if !used {
					port = i
					break
				}
			}
		}
		append(&symed.port_of, port)
	}
	symed.sym.ref_at, symed.sym.has_ref_at = t.ref_at, t.has_ref_at
	symed.sym.value_at, symed.sym.has_value_at = t.value_at, t.has_value_at
	symed.ref_auto, symed.value_auto = !t.has_ref_at, !t.has_value_at
	if !symed.spice_auto {
		// a symbol of its own: the template's netlist lines and editor too
		symed.sym.spice = cl(t.spice)
		symed.sym.defs = cl(t.defs)
		symed.sym.vacask = {line = cl(t.vacask.line), defs = cl(t.vacask.defs), loads = cl_list(t.vacask.loads), models = cl_list(t.vacask.models)}
		symed.sym.editor = t.editor
		symed.sym.models = cl_list(t.models)
		symed.sym.cur = cl(t.cur)
		symed.sym.probe = t.probe
		if len(symed.sym.value) == 0 do symed.sym.value = cl(t.value)
		if len(symed.sym.prefix) == 0 || symed.sym.prefix == "X" do symed.sym.prefix = cl(t.prefix)
	}
	symed.sel = .None
	symed.fitted = false
	if len(symed.ports) > 0 do set_msg("pick the model port of every pin (select a pin) or rename the pins to the port names")
}

// A model port and a symbol pin that mean the same terminal: "In+" and "inp", "V+" and "vcc" …
@(private = "file")
pins_match :: proc(port, pin: string) -> bool {
	if strings.equal_fold(port, pin) || pin_role(port) == pin_role(pin) || sanitize(port) == sanitize(pin) do return true
	k := opamp_port(port)
	return len(k) > 0 && k == opamp_port(pin)
}
