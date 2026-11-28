package spicy

import "core:math"
import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

// A small immediate-mode UI toolkit on raylib (same spirit as loomer's and zapped's).

Rect :: struct {
	x, y, w, h: f32,
}

r_contains :: proc(r: Rect, p: [2]f32) -> bool {return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h}
r_inset :: proc(r: Rect, d: f32) -> Rect {return {r.x + d, r.y + d, r.w - 2 * d, r.h - 2 * d}}
cut_left :: proc(r: ^Rect, w: f32) -> Rect {o := Rect{r.x, r.y, w, r.h}; r.x += w; r.w -= w; return o}
cut_right :: proc(r: ^Rect, w: f32) -> Rect {r.w -= w; return {r.x + r.w, r.y, w, r.h}}
cut_top :: proc(r: ^Rect, h: f32) -> Rect {o := Rect{r.x, r.y, r.w, h}; r.y += h; r.h -= h; return o}
cut_bottom :: proc(r: ^Rect, h: f32) -> Rect {r.h -= h; return {r.x, r.y + r.h, r.w, h}}
rlr :: proc(r: Rect) -> rl.Rectangle {return {r.x, r.y, r.w, r.h}}
rlc :: proc(c: Color) -> rl.Color {return rl.Color{c[0], c[1], c[2], c[3]}}

// ---------------------------------------------------------------------------
// Fonts (no font files are bundled: a system font, or the one set in settings.edn)

SANS_FONTS := [?]string {
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
	"/usr/share/fonts/noto/NotoSans-Regular.ttf",
	"/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
	"/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
	"/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
	"/usr/share/fonts/TTF/LiberationSans-Regular.ttf",
	"/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf",
	"/usr/share/fonts/gnu-free/FreeSans.otf",
	"/usr/share/fonts/truetype/freefont/FreeSans.ttf",
	"C:\\Windows\\Fonts\\segoeui.ttf",
	"C:\\Windows\\Fonts\\arial.ttf",
	"/System/Library/Fonts/Supplemental/Arial.ttf",
	"/Library/Fonts/Arial.ttf",
}

MONO_FONTS := [?]string {
	"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
	"/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
	"/usr/share/fonts/TTF/JetBrainsMono-Regular.ttf",
	"/usr/share/fonts/TTF/FiraCode-Regular.ttf",
	"/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
	"/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf",
	"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	"/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
	"/usr/share/fonts/TTF/LiberationMono-Regular.ttf",
	"C:\\Windows\\Fonts\\consola.ttf",
	"/System/Library/Fonts/Menlo.ttc",
}

FONT_EXTRA :: "•−↶↷▶◀▼▲⚠ΩΩµμΔηφθτω°±·×≤≥→←↑↓–—…‹›✓✗∞√∑≈≠▸▾∠⏵⏹■●"

Font_Set :: struct {
	path:  string,
	cache: map[i32]rl.Font,
}

sans, mono: Font_Set
font_cps: [dynamic]rune
font_known: map[rune]bool // the characters in font_cps
font_stale: bool // new characters seen: rebuild the glyph atlases at the next frame
ui_scale: f32 = 1

fonts_init :: proc() {
	pick :: proc(set: ^Font_Set, user: string, list: []string) {
		for f, _ in set.cache do _ = f
		for _, f in set.cache do rl.UnloadFont(f)
		clear(&set.cache)
		set.path = ""
		if len(user) > 0 {
			if file_exists(user) do set.path = strings.clone(user)
			else do config_error(tcat("settings.edn: font file not found: ", user))
		}
		if len(set.path) == 0 do for p in list do if file_exists(p) {
			set.path = p
			break
		}
	}
	pick(&sans, S.font, SANS_FONTS[:])
	pick(&mono, S.mono_font, MONO_FONTS[:])
	if len(mono.path) == 0 do mono.path = sans.path
	clear(&font_cps)
	for r in 32 ..< 127 do append(&font_cps, rune(r))
	for r in 160 ..< 256 do if r != 0xAD do append(&font_cps, rune(r))
	for r in FONT_EXTRA do append(&font_cps, r)
	clear(&font_known)
	for r in font_cps do font_known[r] = true
}

// Any text may hold characters outside the preloaded set (file names in other scripts …):
// remember them, and the atlases are rebuilt with them before the next frame.
note_glyphs :: proc(s: string) {
	for i in 0 ..< len(s) do if s[i] >= 0x80 {
		for r in s[i:] do if r >= 0x80 && r != utf8.RUNE_ERROR && !font_known[r] {
			font_known[r] = true
			append(&font_cps, r)
			font_stale = true
		}
		return
	}
}

// Called at the start of a frame, when no draw call still uses the old textures.
fonts_refresh :: proc() {
	if !font_stale do return
	font_stale = false
	for set in ([]^Font_Set{&sans, &mono}) {
		for _, f in set.cache do if f.texture.id != rl.GetFontDefault().texture.id do rl.UnloadFont(f)
		clear(&set.cache)
	}}

get_font_of :: proc(set: ^Font_Set, px: f32) -> rl.Font {
	size := i32(math.round(px))
	if size > 24 do size = (size + 1) / 2 * 2 // fewer atlases for big zoomed text
	size = clamp(size, 6, 160)
	if f, ok := set.cache[size]; ok do return f
	f: rl.Font
	if len(set.path) > 0 {
		rl.SetTraceLogLevel(.ERROR)
		f = rl.LoadFontEx(strings.clone_to_cstring(set.path, context.temp_allocator), size, raw_data(font_cps), i32(len(font_cps)))
		rl.SetTraceLogLevel(.WARNING)
		rl.SetTextureFilter(f.texture, .BILINEAR)
	} else {
		f = rl.GetFontDefault()
	}
	set.cache[size] = f
	return f
}

get_font :: proc(px: f32) -> rl.Font {return get_font_of(&sans, px)}

fs :: proc(k: f32 = 1) -> f32 {return math.round(S.font_size * ui_scale * k)}

cstr :: proc(s: string) -> cstring {return strings.clone_to_cstring(s, context.temp_allocator)}

text_w :: proc(s: string, size: f32 = 0) -> f32 {
	sz := size if size > 0 else fs()
	if len(s) == 0 do return 0
	note_glyphs(s)
	return rl.MeasureTextEx(get_font(sz), cstr(s), sz, 0).x
}

mono_w :: proc(s: string, size: f32) -> f32 {
	if len(s) == 0 do return 0
	note_glyphs(s)
	return rl.MeasureTextEx(get_font_of(&mono, size), cstr(s), size, 0).x
}

draw_text :: proc(s: string, x, y: f32, col: Color, size: f32 = 0) {
	if len(s) == 0 do return
	sz := size if size > 0 else fs()
	note_glyphs(s)
	tsel_record(s, x, y, sz, false)
	rl.DrawTextEx(get_font(sz), cstr(s), {math.round(x), math.round(y)}, sz, 0, rlc(col))
}

draw_mono :: proc(s: string, x, y: f32, col: Color, size: f32) {
	if len(s) == 0 do return
	note_glyphs(s)
	tsel_record(s, x, y, size, true)
	rl.DrawTextEx(get_font_of(&mono, size), cstr(s), {math.round(x), math.round(y)}, size, 0, rlc(col))
}

// Text in a rect: align 0 left, 1 centre, 2 right; vertically centred.
text_in :: proc(r: Rect, s: string, col: Color, align := 0, size: f32 = 0, pad: f32 = 6) {
	sz := size if size > 0 else fs()
	w := text_w(s, sz)
	x := r.x + pad
	if align == 1 do x = r.x + (r.w - w) / 2
	if align == 2 do x = r.x + r.w - w - pad
	draw_text(s, x, r.y + (r.h - sz) / 2, col, sz)
}

fit_text :: proc(s: string, w: f32, size: f32 = 0) -> string {
	if text_w(s, size) <= w do return s
	r := s
	for len(r) > 0 {
		_, n := utf8.decode_last_rune_in_string(r)
		r = r[:len(r) - n]
		t := tcat(r, "…")
		if text_w(t, size) <= w do return t
	}
	return ""
}

fill :: proc(r: Rect, c: Color) {rl.DrawRectangleRec(rlr(r), rlc(c))}
// Rounded rectangles as in loomer (FlatLaf): the radius is in UI units (it grows with the UI
// scale), the corners are smooth and the edges sit on whole pixels.
fill_round :: proc(r: Rect, c: Color, rad: f32 = 4) {
	if c[3] == 0 || r.w <= 0 || r.h <= 0 do return
	q := snap_rect(r)
	rr := min(rad * ui_scale, q.w / 2, q.h / 2)
	if rr <= 0.5 {
		rl.DrawRectangleRec(rlr(q), rlc(c))
		return
	}
	rl.DrawRectangleRounded(rlr(q), 2 * rr / min(q.w, q.h), 8, rlc(c))
}

// The rectangle with its edges on whole pixels.
snap_rect :: proc(r: Rect) -> Rect {
	x0, y0 := math.round(r.x), math.round(r.y)
	return {x0, y0, math.round(r.x + r.w) - x0, math.round(r.y + r.h) - y0}
}
stroke :: proc(r: Rect, c: Color, t: f32 = 1) {rl.DrawRectangleLinesEx(rlr(r), t, rlc(c))}
stroke_round :: proc(r: Rect, c: Color, rad: f32 = 4, t: f32 = 1) {
	if c[3] == 0 || r.w <= 0 || r.h <= 0 do return
	q := snap_rect(r)
	tt := max(math.round(t), 1)
	q = {q.x + tt / 2, q.y + tt / 2, q.w - tt, q.h - tt} // the line inside the rectangle, crisp
	rr := min(rad * ui_scale, q.w / 2, q.h / 2)
	if rr <= 0.5 {
		rl.DrawRectangleLinesEx(rlr({q.x - tt / 2, q.y - tt / 2, q.w + tt, q.h + tt}), tt, rlc(c))
		return
	}
	rl.DrawRectangleRoundedLinesEx(rlr(q), 2 * rr / min(q.w, q.h), 8, tt, rlc(c))
}

// Text on the selection colour: white or black, whichever reads better.
sel_fg :: proc() -> Color {
	return Color{255, 255, 255, 255} if luma(th.sel) < 0.6 else Color{0x10, 0x10, 0x10, 255}
}
line :: proc(x0, y0, x1, y1: f32, c: Color, t: f32 = 1) {rl.DrawLineEx({x0, y0}, {x1, y1}, t, rlc(c))}

clip_stack: [dynamic]Rect

push_clip :: proc(r: Rect) {
	c := r
	if len(clip_stack) > 0 {
		p := clip_stack[len(clip_stack) - 1]
		x0, y0 := max(c.x, p.x), max(c.y, p.y)
		x1, y1 := min(c.x + c.w, p.x + p.w), min(c.y + c.h, p.y + p.h)
		c = {x0, y0, max(0, x1 - x0), max(0, y1 - y0)}
	}
	append(&clip_stack, c)
	scissor(c)
}

@(private = "file")
scissor :: proc(c: Rect) {
	if win_input == nil {
		rl.BeginScissorMode(i32(c.x), i32(c.y), i32(c.w), i32(c.h))
		return
	}
	rlgl.DrawRenderBatchActive()
	rlgl.EnableScissorTest()
	rlgl.Scissor(i32(c.x), i32(win_input.size.y - (c.y + c.h)), i32(c.w), i32(c.h))
}

pop_clip :: proc() {
	pop(&clip_stack)
	if win_input == nil do rl.EndScissorMode()
	else {
		rlgl.DrawRenderBatchActive()
		rlgl.DisableScissorTest()
	}
	if len(clip_stack) > 0 do scissor(clip_stack[len(clip_stack) - 1])
}

// ---------------------------------------------------------------------------
// Input of the window being drawn. win_input = nil: the main window, read through raylib;
// else a pop-out window, whose input arrives through GLFW callbacks (popout.odin).

Window_Input :: struct {
	mouse:    [2]f32,
	down:     [3]bool,
	pressed:  [3]bool,
	released: [3]bool,
	wheel:    f32,
	kdown:    [512]bool,
	khit:     [512]bool,
	krep:     [512]bool,
	chars:    [dynamic]rune,
	size:     [2]f32,
}

win_input: ^Window_Input

// test hooks (SPICY_ACTIONS click:x,y, dblclick:x,y, rclick:x,y, type:text): played in turn
// after the run, through the same input as the mouse and keyboard
Test_Event_Kind :: enum u8 {Click, Double, Right, Type}
Test_Event :: struct {
	kind: Test_Event_Kind,
	pos:  [2]f32, // fractions of the window
	text: string,
}
TEST_EVENT_FRAMES :: 6
test_events: [dynamic]Test_Event
test_ev_frame := -2 // -2 off, -1 waiting for the run, then the frame of the first event
test_mouse: Maybe([2]f32) // after a click the mouse stays there (the screenshot shows its hover)

test_events_pending :: proc() -> bool {return test_ev_frame != -2 && len(test_events) > 0}

key_pressed :: proc(k: rl.KeyboardKey) -> bool {
	if win_input != nil do return int(k) >= 0 && int(k) < 512 && win_input.khit[int(k)]
	return rl.IsKeyPressed(k)
}
key_repeated :: proc(k: rl.KeyboardKey) -> bool {
	if win_input != nil do return int(k) >= 0 && int(k) < 512 && win_input.krep[int(k)]
	return rl.IsKeyPressedRepeat(k)
}
key_down :: proc(k: rl.KeyboardKey) -> bool {
	if win_input != nil do return int(k) >= 0 && int(k) < 512 && win_input.kdown[int(k)]
	return rl.IsKeyDown(k)
}
screen_w :: proc() -> f32 {return win_input.size.x if win_input != nil else f32(rl.GetScreenWidth())}
screen_h :: proc() -> f32 {return win_input.size.y if win_input != nil else f32(rl.GetScreenHeight())}

// ---------------------------------------------------------------------------
// Input state

UI_State :: struct {
	mouse:        [2]f32,
	press_pos:    [2]f32,
	delta:        [2]f32,
	wheel:        f32,
	down:         [3]bool,
	pressed:      [3]bool,
	released:     [3]bool,
	double:       bool,
	last_click:   f64,
	last_click_pos: [2]f32,
	ctrl, shift, alt: bool,
	chars:        [dynamic]rune,
	time:         f64,
	hot:          u64,
	active:       u64,
	focus:        u64,
	edit_buf:     [dynamic]u8,
	edit_cur:     int,
	edit_sel_all: bool, // select everything (turned into the anchor below)
	edit_anchor:  int, // the other end of the selection; -1 = none
	edit_drag:    bool, // the mouse is selecting text in the focused field
	edit_scroll:  f32,
	popup_id:     u64,
	popup_rect:   Rect,
	popup_items:  [dynamic]string,
	popup_sel:    int,
	popup_result: int,
	popup_result_id: u64,
	popup_open_frame: bool,
	block:        bool, // mouse over a popup
	modal:        bool, // a dialog is open
	tsel:         Tsel_State, // the selection in read-only text (textsel.odin)
	in_modal:     bool, // drawing the dialog now
	tip:          string,
	tip_id:       u64,
	tip_since:    f64,
	cursor:       rl.MouseCursor,
	scroll:       map[u64]f32,
	focus_next:   u64, // give this field focus on its next frame
	// submenus: an item whose shortcut is "▸" opens the items submenu_fn gives for its label
	submenu_fn:   proc(label: string) -> []string,
	sub_open:     int, // the parent item whose submenu is open; -1 = none
	sub_items:    [dynamic]string,
	sub_rect:     Rect,
	sub_result:   int, // the submenu item picked (menu_result gives the parent item)
	sb_drag:      u64, // the scroll area whose scrollbar thumb is being dragged
	sb_grab:      f32, // where in the thumb it was grabbed
}

ui: UI_State

id_of :: proc(s: string, salt: int = 0) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for b in transmute([]u8)s {
		h ~= u64(b)
		h *= 0x100000001b3
	}
	h ~= u64(salt) * 0x9E3779B97F4A7C15
	return h
}

ui_begin_frame :: proc() {
	m := win_input.mouse if win_input != nil else ([2]f32)(rl.GetMousePosition())
	ui.delta = {m.x - ui.mouse.x, m.y - ui.mouse.y}
	ui.mouse = {m.x, m.y}
	ui.wheel = win_input.wheel if win_input != nil else rl.GetMouseWheelMove()
	btns := [3]rl.MouseButton{.LEFT, .RIGHT, .MIDDLE}
	for b, i in btns {
		if win_input != nil {
			ui.down[i] = win_input.down[i]
			ui.pressed[i] = win_input.pressed[i]
			ui.released[i] = win_input.released[i]
		} else {
			ui.down[i] = rl.IsMouseButtonDown(b)
			ui.pressed[i] = rl.IsMouseButtonPressed(b)
			ui.released[i] = rl.IsMouseButtonReleased(b)
		}
		if ui.pressed[i] do ui.press_pos = ui.mouse
	}
	ui.time = rl.GetTime()
	ui.double = false
	if ui.pressed[0] {
		d := ui.mouse - ui.last_click_pos
		if ui.time - ui.last_click < 0.35 && d.x * d.x + d.y * d.y < 36 do ui.double = true
		ui.last_click = ui.time
		ui.last_click_pos = ui.mouse
	}
	ui.ctrl = key_down(.LEFT_CONTROL) || key_down(.RIGHT_CONTROL) || key_down(.LEFT_SUPER) || key_down(.RIGHT_SUPER)
	ui.shift = key_down(.LEFT_SHIFT) || key_down(.RIGHT_SHIFT)
	ui.alt = key_down(.LEFT_ALT) || key_down(.RIGHT_ALT)
	clear(&ui.chars)
	if win_input != nil do append(&ui.chars, ..win_input.chars[:])
	else do for {
		c := rl.GetCharPressed()
		if c == 0 do break
		append(&ui.chars, c)
	}
	if win_input == nil do test_event_frame()
	ui.block = ui.popup_id != 0 && (r_contains(ui.popup_rect, ui.mouse) || (ui.sub_open >= 0 && r_contains(ui.sub_rect, ui.mouse)))
	ui.hot = 0
	ui.cursor = .DEFAULT
	if !ui.down[0] && !ui.released[0] do ui.active = 0
	ui.popup_open_frame = false
}

// One frame of the test event being played: a click is pressed and released (a double-click
// twice), text is typed on its first frame.
@(private = "file")
test_event_frame :: proc() {
	if test_ev_frame >= 0 && len(test_events) > 0 {
		ev := test_events[0]
		f := test_ev_frame
		switch ev.kind {
		case .Type:
			if f == 0 do for c in ev.text do append(&ui.chars, c)
		case .Click, .Double, .Right:
			test_mouse = ev.pos
			b := 1 if ev.kind == .Right else 0
			n := 2 if ev.kind == .Double else 1
			if f < 2 * n {
				if f % 2 == 0 {
					ui.pressed[b] = true
					ui.down[b] = true
				} else do ui.released[b] = true
			}
			if b == 0 do ui.double = ev.kind == .Double && f == 2
		}
		test_ev_frame += 1
		if test_ev_frame >= TEST_EVENT_FRAMES {
			ordered_remove(&test_events, 0)
			test_ev_frame = 0
		}
	}
	if m, ok := test_mouse.?; ok {
		ui.mouse = {m.x * screen_w(), m.y * screen_h()}
		ui.delta = {}
		if ui.pressed[0] || ui.pressed[1] do ui.press_pos = ui.mouse
	}
}

ui_end_frame :: proc() {
	if ui.pressed[0] && ui.hot == 0 && ui.focus != 0 && ui.focus_next == 0 do ui.focus = 0
	if win_input == nil do rl.SetMouseCursor(ui.cursor)
}

mouse_free :: proc() -> bool {
	if ui.block do return false
	if ui.modal && !ui.in_modal do return false
	return true
}

hover :: proc(r: Rect) -> bool {
	if !mouse_free() do return false
	if len(clip_stack) > 0 && !r_contains(clip_stack[len(clip_stack) - 1], ui.mouse) do return false
	return r_contains(r, ui.mouse)
}

typing :: proc() -> bool {return ui.focus != 0}

key :: proc(k: rl.KeyboardKey) -> bool {return key_pressed(k) || key_repeated(k)}

tooltip :: proc(id: u64, text: string) {
	if !S.tooltips do return
	if ui.tip_id != id {
		ui.tip_id = id
		ui.tip_since = ui.time
	}
	ui.tip = text
}

// ---------------------------------------------------------------------------
// Widgets

button :: proc(id_s: string, r: Rect, text: string, enabled := true, primary := false, selected := false, tip := "") -> bool {
	id := id_of(id_s)
	h := enabled && hover(r)
	if h {
		ui.hot = id
		ui.cursor = .POINTING_HAND
		if ui.pressed[0] do ui.active = id
		if len(tip) > 0 do tooltip(id, tip)
	}
	// as loomer: a filled rounded button with a thin border; hover and press darken it a little
	bg := mix(th.bg, th.fg, 0.13) if th.dark else th.input
	if primary do bg = th.accent
	if selected do bg = mix(th.bg, th.accent, 0.45)
	if ui.active == id && h do bg = mix(bg, th.fg, 0.15)
	else if h do bg = mix(bg, th.fg, 0.07)
	fill_round(r, bg, 4)
	stroke_round(r, th.accent if primary || selected else th.border, 4)
	col := th.accent_fg if primary else th.fg
	if !enabled do col = th.muted
	text_in(r, fit_text(text, r.w - 8), col, 1)
	return h && ui.released[0] && ui.active == id
}

// Icons drawn as shapes, not font characters: fonts lack many symbols (Segoe UI on Windows
// has no ▶ ⚠ ✓), and raylib draws a missing character as "?".
Icon :: enum {None, Play, Stop, Warn, Check, Cross, Up, Down, Left, Right}

// Draws an icon centred on (cx, cy), about s pixels tall.
draw_icon :: proc(icon: Icon, cx, cy, s: f32, col: Color) {
	c := rlc(col)
	h := s / 2
	switch icon {
	case .None:
	case .Play: rl.DrawTriangle({cx - h * 0.8, cy - h}, {cx - h * 0.8, cy + h}, {cx + h, cy}, c)
	case .Stop: rl.DrawRectangleRec({cx - h * 0.8, cy - h * 0.8, h * 1.6, h * 1.6}, c)
	case .Up: rl.DrawTriangle({cx, cy - h * 0.6}, {cx - h, cy + h * 0.6}, {cx + h, cy + h * 0.6}, c)
	case .Down: rl.DrawTriangle({cx - h, cy - h * 0.6}, {cx, cy + h * 0.6}, {cx + h, cy - h * 0.6}, c)
	case .Left: rl.DrawTriangle({cx + h * 0.6, cy - h}, {cx - h * 0.6, cy}, {cx + h * 0.6, cy + h}, c)
	case .Right: rl.DrawTriangle({cx - h * 0.6, cy - h}, {cx - h * 0.6, cy + h}, {cx + h * 0.6, cy}, c)
	case .Warn:
		rl.DrawTriangle({cx, cy - h}, {cx - h * 1.1, cy + h}, {cx + h * 1.1, cy + h}, c)
		bg := rlc(th.bg)
		t := max(1.2, s * 0.12)
		rl.DrawLineEx({cx, cy - h * 0.35}, {cx, cy + h * 0.35}, t, bg)
		rl.DrawCircleV({cx, cy + h * 0.68}, t * 0.6, bg)
	case .Check:
		t := max(1.4, s * 0.14)
		rl.DrawLineEx({cx - h * 0.8, cy}, {cx - h * 0.2, cy + h * 0.6}, t, c)
		rl.DrawLineEx({cx - h * 0.2, cy + h * 0.6}, {cx + h * 0.85, cy - h * 0.6}, t, c)
	case .Cross:
		t := max(1.4, s * 0.14)
		rl.DrawLineEx({cx - h * 0.6, cy - h * 0.6}, {cx + h * 0.6, cy + h * 0.6}, t, c)
		rl.DrawLineEx({cx - h * 0.6, cy + h * 0.6}, {cx + h * 0.6, cy - h * 0.6}, t, c)
	}
}

// Menu text: a leading "✓ " is drawn as a check icon (the font may not have ✓).
menu_text :: proc(r: Rect, label: string, col: Color, pad: f32) {
	// as loomer: a dot for the chosen item, a ring for the other choices
	if strings.has_prefix(label, "✓ ") {
		rl.DrawCircleV({r.x + pad + fs(0.4), r.y + r.h / 2}, fs(0.25), rlc(col))
		text_in({r.x + fs(1.1), r.y, r.w - fs(1.1), r.h}, label[len("✓ "):], col, 0, 0, pad)
		return
	}
	if strings.has_prefix(label, "   ") {
		rl.DrawCircleLinesV({r.x + pad + fs(0.4), r.y + r.h / 2}, fs(0.25), rlc(th.muted))
		text_in({r.x + fs(1.1), r.y, r.w - fs(1.1), r.h}, strings.trim_left(label, " "), col, 0, 0, pad)
		return
	}
	text_in(r, label, col, 0, 0, pad)
}

tool_button :: proc(id_s: string, r: Rect, text: string, enabled := true, selected := false, tip := "", col: Color = {}, icon := Icon.None) -> bool {
	id := id_of(id_s)
	h := enabled && hover(r)
	if h {
		ui.hot = id
		ui.cursor = .POINTING_HAND
		if ui.pressed[0] do ui.active = id
		if len(tip) > 0 do tooltip(id, tip)
	}
	// flat until hovered (loomer)
	if selected do fill_round(r, mix(th.bar, th.accent, 0.35), 4)
	if h && ui.active == id && ui.down[0] do fill_round(r, th.pressed, 4)
	else if h do fill_round(r, th.hover, 4)
	c := col if col[3] != 0 else th.fg
	if !enabled do c = th.muted
	if icon != .None {
		// icon, then the text, centred together
		is := fs(0.8)
		gap: f32 = 6 if len(text) > 0 else 0
		tw := text_w(text)
		x := r.x + (r.w - is - gap - tw) / 2
		draw_icon(icon, x + is / 2, r.y + r.h / 2, is, c)
		if len(text) > 0 do draw_text(text, x + is + gap, r.y + (r.h - fs()) / 2, c)
	} else do text_in(r, text, c, 1)
	return h && ui.released[0] && ui.active == id
}

checkbox :: proc(id_s: string, r: Rect, text: string, v: ^bool) -> bool {
	id := id_of(id_s)
	h := hover(r)
	if h {
		ui.hot = id
		ui.cursor = .POINTING_HAND
		if ui.pressed[0] do ui.active = id
	}
	bs := fs(1.05)
	b := Rect{r.x + 2, r.y + (r.h - bs) / 2, bs, bs}
	fill_round(b, th.accent if v^ else th.input, 3)
	stroke_round(b, th.accent if v^ || h else th.border, 3)
	if v^ {
		line(b.x + bs * 0.22, b.y + bs * 0.52, b.x + bs * 0.42, b.y + bs * 0.72, th.accent_fg, 2)
		line(b.x + bs * 0.42, b.y + bs * 0.72, b.x + bs * 0.78, b.y + bs * 0.3, th.accent_fg, 2)
	}
	text_in({r.x + bs + 4, r.y, r.w - bs - 4, r.h}, text, th.fg, 0, 0, 4)
	if h && ui.released[0] && ui.active == id {
		v^ = !v^
		return true
	}
	return false
}

// Segmented choice (tabs-like buttons); returns true when changed.
segmented :: proc(id_s: string, r: Rect, names: []string, sel: ^int) -> bool {
	changed := false
	w := r.w / f32(len(names))
	for n, i in names {
		br := Rect{r.x + f32(i) * w, r.y, w - 2, r.h}
		if button(tcat(id_s, ".", n), br, n, true, false, sel^ == i) && sel^ != i {
			sel^ = i
			changed = true
		}
	}
	return changed
}

// Single-line text editing core. Returns committed / cancelled.
@(private = "file")
edit_line :: proc(id: u64, r: Rect, init: string) -> (commit: bool, cancelled: bool) {
	h := hover(r)
	if h {
		ui.hot = id
		ui.cursor = .IBEAM
	}
	start := (h && ui.pressed[0] && ui.focus != id) || ui.focus_next == id
	if start {
		ui.focus = id
		ui.focus_next = 0
		clear(&ui.edit_buf)
		append(&ui.edit_buf, ..transmute([]u8)init)
		ui.edit_cur = len(ui.edit_buf)
		ui.edit_sel_all = true
		ui.edit_drag = false
		return
	}
	if ui.focus != id do return
	edit_keys(false)
	if key_pressed(.ENTER) || key_pressed(.KP_ENTER) || key_pressed(.TAB) {
		ui.focus = 0
		return true, false
	}
	if key_pressed(.ESCAPE) {
		ui.focus = 0
		return false, true
	}
	if ui.pressed[0] && !h {
		ui.focus = 0
		return true, false
	}
	if (h && ui.pressed[0]) || (ui.edit_drag && ui.down[0]) {
		// place the cursor at the click; dragging (or Shift+click) selects
		s := string(ui.edit_buf[:])
		x := r.x + 6
		if tw := text_w(s[:ui.edit_cur]); tw > r.w - 14 do x -= tw - (r.w - 14)
		best := 0
		for i := 0; i <= len(s); {
			if text_w(s[:i]) + x <= ui.mouse.x + 2 do best = i
			if i == len(s) do break
			_, n := utf8.decode_rune_in_string(s[i:])
			i += n
		}
		if ui.pressed[0] {
			sel_norm()
			if !ui.shift || ui.edit_anchor < 0 do ui.edit_anchor = ui.edit_cur if ui.shift else best
			ui.edit_drag = true
		}
		ui.edit_cur = best
	}
	if !ui.down[0] do ui.edit_drag = false
	return false, false
}

// Turns "select all" into a selection range.
sel_norm :: proc() {
	if ui.edit_sel_all {
		ui.edit_anchor = 0
		ui.edit_cur = len(ui.edit_buf)
		ui.edit_sel_all = false
	}
	ui.edit_anchor = min(ui.edit_anchor, len(ui.edit_buf))
}

// The selected byte range of the focused field.
sel_range :: proc() -> (a, b: int, ok: bool) {
	if ui.edit_anchor < 0 || ui.edit_anchor == ui.edit_cur do return ui.edit_cur, ui.edit_cur, false
	return min(ui.edit_anchor, ui.edit_cur), max(ui.edit_anchor, ui.edit_cur), true
}

// Deletes the selection; false when there was none.
sel_delete :: proc() -> bool {
	a, b, ok := sel_range()
	ui.edit_anchor = -1
	if !ok do return false
	remove_range(&ui.edit_buf, a, b)
	ui.edit_cur = a
	return true
}

// Shift+movement extends the selection, plain movement ends it.
@(private = "file")
sel_move_begin :: proc() {
	if ui.shift {
		if ui.edit_anchor < 0 do ui.edit_anchor = ui.edit_cur
	} else do ui.edit_anchor = -1
}

// Typing, deleting, moving and clipboard keys for the focused field.
edit_keys :: proc(multiline: bool) {
	sel_norm()
	if len(ui.chars) > 0 {
		sel_delete()
		for c in ui.chars {
			b, n := utf8.encode_rune(c)
			inject_at(&ui.edit_buf, ui.edit_cur, ..b[:n])
			ui.edit_cur += n
		}
	}
	if key(.BACKSPACE) {
		if !sel_delete() && ui.edit_cur > 0 {
			_, n := utf8.decode_last_rune(ui.edit_buf[:ui.edit_cur])
			remove_range(&ui.edit_buf, ui.edit_cur - n, ui.edit_cur)
			ui.edit_cur -= n
		}
	}
	if key(.DELETE) {
		if !sel_delete() && ui.edit_cur < len(ui.edit_buf) {
			_, n := utf8.decode_rune(ui.edit_buf[ui.edit_cur:])
			remove_range(&ui.edit_buf, ui.edit_cur, ui.edit_cur + n)
		}
	}
	if key(.LEFT) {
		a, _, had := sel_range()
		sel_move_begin()
		if had && !ui.shift do ui.edit_cur = a
		else if ui.edit_cur > 0 {_, n := utf8.decode_last_rune(ui.edit_buf[:ui.edit_cur]); ui.edit_cur -= n}
	}
	if key(.RIGHT) {
		_, b, had := sel_range()
		sel_move_begin()
		if had && !ui.shift do ui.edit_cur = b
		else if ui.edit_cur < len(ui.edit_buf) {_, n := utf8.decode_rune(ui.edit_buf[ui.edit_cur:]); ui.edit_cur += n}
	}
	s := string(ui.edit_buf[:])
	if key(.HOME) {
		sel_move_begin()
		if multiline {
			for ui.edit_cur > 0 && s[ui.edit_cur - 1] != '\n' do ui.edit_cur -= 1
		} else do ui.edit_cur = 0
	}
	if key(.END) {
		sel_move_begin()
		if multiline {
			for ui.edit_cur < len(s) && s[ui.edit_cur] != '\n' do ui.edit_cur += 1
		} else do ui.edit_cur = len(ui.edit_buf)
	}
	if multiline && (key(.UP) || key(.DOWN)) {
		sel_move_begin()
		ls := ui.edit_cur
		for ls > 0 && s[ls - 1] != '\n' do ls -= 1
		col := ui.edit_cur - ls
		if key(.UP) && ls > 0 {
			ps := ls - 1
			for ps > 0 && s[ps - 1] != '\n' do ps -= 1
			ui.edit_cur = min(ps + col, ls - 1)
		} else if key(.DOWN) {
			ne := ui.edit_cur
			for ne < len(s) && s[ne] != '\n' do ne += 1
			if ne < len(s) {
				ns := ne + 1
				nend := ns
				for nend < len(s) && s[nend] != '\n' do nend += 1
				ui.edit_cur = min(ns + col, nend)
			}
		}
	}
	if ui.ctrl && key_pressed(.A) {
		ui.edit_anchor = 0
		ui.edit_cur = len(ui.edit_buf)
	}
	if ui.ctrl && (key_pressed(.C) || key_pressed(.X)) {
		// the selection, or the whole text when nothing is selected
		a, b, ok := sel_range()
		if !ok do a, b = 0, len(ui.edit_buf)
		rl.SetClipboardText(cstr(string(ui.edit_buf[a:b])))
		if key_pressed(.X) && ok do sel_delete()
	}
	if ui.ctrl && key_pressed(.V) {
		clip := string(rl.GetClipboardText())
		if !multiline do clip = one_line(clip)
		sel_delete()
		inject_at(&ui.edit_buf, ui.edit_cur, ..transmute([]u8)clip)
		ui.edit_cur += len(clip)
	}
	if multiline && (key_pressed(.ENTER) || key_pressed(.KP_ENTER)) && !ui.ctrl {
		sel_delete()
		inject_at(&ui.edit_buf, ui.edit_cur, '\n')
		ui.edit_cur += 1
	}
	ui.edit_cur = clamp(ui.edit_cur, 0, len(ui.edit_buf))
}

@(private = "file")
draw_field :: proc(id: u64, r: Rect, shown: string, col: Color, placeholder := "") {
	focused := ui.focus == id
	fill_round(r, th.input, 3)
	stroke_round(r, th.accent if focused else (th.muted if ui.hot == id else th.border), 3, 1.5 if focused else 1)
	push_clip(r_inset(r, 1))
	if focused {
		s := string(ui.edit_buf[:])
		tw := text_w(s[:ui.edit_cur])
		x := r.x + 6
		if tw > r.w - 14 do x -= tw - (r.w - 14)
		sel_norm()
		if a, b, ok := sel_range(); ok do fill({x + text_w(s[:a]) - 1, r.y + 3, text_w(s[a:b]) + 2, r.h - 6}, th.sel)
		draw_text(s, x, r.y + (r.h - fs()) / 2, th.fg)
		if math.mod(ui.time, 1.0) < 0.6 do fill({x + tw, r.y + 4, 1.5, r.h - 8}, th.fg)
		idle_redraw_blink(ui.time)
	} else if len(shown) == 0 && len(placeholder) > 0 {
		text_in(r, fit_text(placeholder, r.w - 10), th.muted, 0)
	} else {
		text_in(r, fit_text(shown, r.w - 10), col, 0)
	}
	pop_clip()
}

// Text field editing a heap string. Returns true when the text was committed and changed.
text_field :: proc(id_s: string, r: Rect, s: ^string, placeholder := "") -> bool {
	id := id_of(id_s)
	commit, _ := edit_line(id, r, s^)
	draw_field(id, r, s^, th.fg, placeholder)
	if commit {
		ns := string(ui.edit_buf[:])
		if ns != s^ {
			set_str(s, ns)
			return true
		}
	}
	return false
}

// Live text field: the string follows every key press (search boxes). Returns true on change.
live_field :: proc(id_s: string, r: Rect, s: ^string, placeholder := "") -> bool {
	id := id_of(id_s)
	before := s^
	_, cancelled := edit_line(id, r, s^)
	if ui.focus == id && string(ui.edit_buf[:]) != s^ do set_str(s, string(ui.edit_buf[:]))
	if cancelled do set_str(s, "")
	draw_field(id, r, s^, th.fg, placeholder)
	return s^ != before
}

focus_field :: proc(id_s: string) {ui.focus_next = id_of(id_s)}

// A field that edits init and reports how the editing ended: committed (Enter, Tab, a click
// elsewhere) with the text, or cancelled (Esc). For editors that live only while focused.
edit_field :: proc(id_s: string, r: Rect, init: string) -> (commit: bool, cancelled: bool, text: string) {
	id := id_of(id_s)
	commit, cancelled = edit_line(id, r, init)
	draw_field(id, r, init, th.fg)
	return commit, cancelled, string(ui.edit_buf[:])
}

field_focused :: proc(id_s: string) -> bool {return ui.focus == id_of(id_s)}

// Multi-line text editor (directives). Ctrl+Enter or clicking OK commits outside.
text_area :: proc(id_s: string, r: Rect, s: ^string, mono_font := true) {
	id := id_of(id_s)
	h := hover(r)
	if h {
		ui.hot = id
		ui.cursor = .IBEAM
	}
	if (h && ui.pressed[0] && ui.focus != id) || ui.focus_next == id {
		ui.focus = id
		ui.focus_next = 0
		clear(&ui.edit_buf)
		append(&ui.edit_buf, ..transmute([]u8)s^)
		ui.edit_cur = len(ui.edit_buf)
		ui.edit_sel_all = false
		ui.edit_anchor = -1
	}
	focused := ui.focus == id
	if focused {
		edit_keys(true)
		if string(ui.edit_buf[:]) != s^ do set_str(s, string(ui.edit_buf[:]))
	}
	fill_round(r, th.input, 3)
	stroke_round(r, th.accent if focused else th.border, 3, 1.5 if focused else 1)
	sz := fs()
	lh := sz + 4
	push_clip(r_inset(r, 2))
	txt := s^
	lines := split_lines(txt)
	// cursor line / column
	cl, cc := 0, 0
	if focused {
		for i in 0 ..< min(ui.edit_cur, len(txt)) {
			if txt[i] == '\n' {cl += 1; cc = 0} else do cc += 1
		}
	}
	sc := ui.scroll[id]
	if focused {
		cy := f32(cl) * lh
		if cy - sc > r.h - lh - 8 do sc = cy - r.h + lh + 8
		if cy < sc do sc = cy
	}
	if h && ui.wheel != 0 do sc = max(0, sc - ui.wheel * lh * 3)
	ui.scroll[id] = sc
	sa, sb, has_sel := sel_range()
	loff := 0
	for l, i in lines {
		y := r.y + 6 + f32(i) * lh - sc
		if y > r.y + r.h do break
		if focused && has_sel && sa <= loff + len(l) && sb >= loff {
			// the selected part of this line
			a := clamp(sa - loff, 0, len(l))
			b := clamp(sb - loff, 0, len(l))
			wf := mono_w if mono_font else text_w
			x0 := r.x + 8 + wf(l[:a], sz)
			x1 := r.x + 8 + wf(l[:b], sz) + (sz * 0.4 if sb > loff + len(l) else 0)
			fill({x0, y - 1, x1 - x0, lh}, th.sel)
		}
		loff += len(l) + 1
		if mono_font do draw_mono(l, r.x + 8, y, th.fg, sz)
		else do draw_text(l, r.x + 8, y, th.fg, sz)
		if focused && i == cl do idle_redraw_blink(ui.time)
		if focused && i == cl && math.mod(ui.time, 1.0) < 0.6 {
			pre := l[:min(cc, len(l))]
			x := r.x + 8 + (mono_w(pre, sz) if mono_font else text_w(pre, sz))
			fill({x, y, 1.5, sz + 2}, th.fg)
		}
	}
	pop_clip()
	if !ui.down[0] do ui.edit_drag = false
	if focused && ((h && ui.pressed[0]) || (ui.edit_drag && ui.down[0])) {
		// click: move the cursor
		row := int((ui.mouse.y - r.y - 6 + sc) / lh)
		row = clamp(row, 0, len(lines) - 1)
		off := 0
		for k in 0 ..< row do off += len(lines[k]) + 1
		l := lines[row]
		best := 0
		for i := 0; i <= len(l); i += 1 {
			w := mono_w(l[:i], sz) if mono_font else text_w(l[:i], sz)
			if r.x + 8 + w <= ui.mouse.x + 3 do best = i
		}
		if ui.pressed[0] {
			sel_norm()
			if !ui.shift || ui.edit_anchor < 0 do ui.edit_anchor = ui.edit_cur if ui.shift else off + best
			ui.edit_drag = true
		}
		ui.edit_cur = off + best
	}
}

combo :: proc(id_s: string, r: Rect, items: []string, sel: ^int, enabled := true) -> bool {
	id := id_of(id_s)
	h := enabled && hover(r)
	if h {
		ui.hot = id
		ui.cursor = .POINTING_HAND
	}
	// as loomer: rounded, the accent border while its list is open
	fill_round(r, mix(th.input, th.fg, 0.05) if h else th.input, 4)
	stroke_round(r, th.accent if ui.popup_id == id else th.border, 4)
	cur := items[sel^] if sel^ >= 0 && sel^ < len(items) else ""
	text_in({r.x, r.y, r.w - 18, r.h}, fit_text(cur, r.w - 26), th.fg if enabled else th.muted)
	ax, ay, k := r.x + r.w - 12 * ui_scale, r.y + r.h / 2, 3.5 * ui_scale
	rl.DrawTriangle({ax - k, ay - k * 0.5}, {ax, ay + k * 0.7}, {ax + k, ay - k * 0.5}, rlc(th.muted))
	if h && ui.pressed[0] && ui.popup_id != id {
		ih := fs() + 10
		ph := min(f32(len(items)) * ih + 6, 420)
		y := r.y + r.h + 2
		if y + ph > screen_h() do y = r.y - ph - 2
		w := r.w
		for it in items do w = max(w, text_w(it) + 24)
		popup_open(id, {r.x, y, w, ph}, items, sel^)
	}
	if ui.popup_result_id == id {
		ui.popup_result_id = 0
		if ui.popup_result >= 0 && ui.popup_result < len(items) && ui.popup_result != sel^ {
			sel^ = ui.popup_result
			return true
		}
	}
	return false
}

popup_open :: proc(id: u64, r: Rect, items: []string, sel := -1) {
	ui.popup_id = id
	for it in ui.popup_items do delete(it)
	clear(&ui.popup_items)
	for it in items do append(&ui.popup_items, strings.clone(it))
	ui.popup_rect = r
	ui.popup_sel = sel
	ui.popup_open_frame = true
	// scrolled to show the current item when the list is longer than the popup
	ih := fs() + 10
	total: f32 = 6
	for it in items do total += (8 if it == "-" else ih)
	ui.scroll[id] = clampf32(f32(max(sel, 0)) * ih - (r.h - ih) / 2, 0, max(0, total - r.h)) if sel >= 0 else 0
	ui.sub_open = -1
	ui.sub_result = -1
}

// Menu items: "Label\tShortcut", "-" separator, "~Label" disabled, "✓ Label" checked.
menu_size :: proc(items: []string) -> (w, h: f32) {
	ih := fs() + 10
	w = 180 * ui_scale
	for it in items {
		label, short := menu_split(it)
		w = max(w, text_w(label) + text_w(short) + 60)
	}
	for it in items do h += (8 if it == "-" else ih)
	return w, h + 6
}

menu_split :: proc(it: string) -> (label, short: string) {
	t := strings.index_byte(it, '\t')
	if t < 0 do return it, ""
	return it[:t], it[t + 1:]
}

open_menu :: proc(id_s: string, x, y: f32, items: []string) {
	w, h := menu_size(items)
	sw, sh := screen_w(), screen_h()
	xx := min(x, sw - w - 2)
	yy := y
	if yy + h > sh do yy = max(0, sh - h)
	popup_open(id_of(id_s), {xx, yy, w, min(h, sh)}, items)
}

menu_result :: proc(id_s: string) -> int {
	id := id_of(id_s)
	if ui.popup_result_id == id {
		ui.popup_result_id = 0
		return ui.popup_result
	}
	return -1
}

// Draws the open popup (menus, combo lists) and handles its input. Call last.
draw_popup :: proc() {
	if ui.popup_id == 0 do return
	r := ui.popup_rect
	ih := fs() + 10
	fill_round({r.x + 3, r.y + 3, r.w, r.h}, th.shadow, 6)
	fill_round(r, th.popup, 6)
	stroke_round(r, th.border, 6)
	sc := ui.scroll[ui.popup_id]
	total: f32 = 6
	for it in ui.popup_items do total += (8 if it == "-" else ih)
	if r_contains(r, ui.mouse) && ui.wheel != 0 do sc = clampf32(sc - ui.wheel * ih * 3, 0, max(0, total - r.h))
	// a scrollbar when the list is longer than the popup: shows there is more; drag it or use the wheel
	has_bar := total > r.h + 1
	track := Rect{r.x + r.w - 10, r.y + 2, 10, r.h - 4}
	on_bar := has_bar && r_contains(track, ui.mouse)
	bh, by: f32
	if has_bar {
		bh = max(track.h * r.h / total, 20)
		by = track.y + (track.h - bh) * sc / (total - r.h)
		if on_bar && ui.pressed[0] {
			if ui.mouse.y >= by && ui.mouse.y <= by + bh do ui.sb_drag, ui.sb_grab = ui.popup_id, ui.mouse.y - by
			else do sc = clampf32(sc + (r.h if ui.mouse.y > by else -r.h), 0, total - r.h)
		}
		if ui.sb_drag == ui.popup_id {
			if !ui.down[0] do ui.sb_drag = 0
			else if track.h > bh do sc = clampf32((ui.mouse.y - ui.sb_grab - track.y) / (track.h - bh) * (total - r.h), 0, total - r.h)
		}
		by = track.y + (track.h - bh) * sc / (total - r.h)
	}
	on_bar = on_bar || ui.sb_drag == ui.popup_id // the items ignore the mouse while on the bar
	ui.scroll[ui.popup_id] = sc
	in_sub := ui.sub_open >= 0 && r_contains(ui.sub_rect, ui.mouse)
	push_clip(r)
	y := r.y + 3 - sc
	for it, i in ui.popup_items {
		if it == "-" {
			line(r.x + 8, y + 4, r.x + r.w - 8, y + 4, th.border)
			y += 8
			continue
		}
		ir := Rect{r.x + 4 * ui_scale, y, r.w - 8 * ui_scale, ih}
		y += ih
		label, short := menu_split(it)
		disabled := strings.has_prefix(label, "~")
		if disabled do label = label[1:]
		// only the visible part of the list: items scrolled out of it are clipped, not clickable
		hv := r_contains(ir, ui.mouse) && r_contains(r, ui.mouse) && !disabled && !in_sub && !on_bar
		is_sub := short == "▸" && ui.submenu_fn != nil
		if is_sub && hv && ui.sub_open != i {
			// open the submenu beside the item (on the left when there is no room on the right)
			for x in ui.sub_items do delete(x)
			clear(&ui.sub_items)
			for x in ui.submenu_fn(label) do append(&ui.sub_items, strings.clone(x))
			w, h := menu_size(ui.sub_items[:])
			sx := r.x + r.w - 2
			if sx + w > screen_w() do sx = max(0, r.x - w + 2)
			sy := min(ir.y - 3, screen_h() - h)
			ui.sub_rect = {sx, max(0, sy), w, min(h, screen_h())}
			ui.sub_open = i
		} else if hv && !is_sub do ui.sub_open = -1
		open_here := is_sub && ui.sub_open == i
		// a soft rounded highlight (loomer): the selection colour, not the accent
		if hv || open_here do fill_round(ir, th.sel, 4)
		else if i == ui.popup_sel do fill_round(ir, th.hover, 4)
		col := sel_fg() if hv || open_here else (th.muted if disabled else th.fg)
		menu_text(ir, label, col, 10)
		if is_sub {
			// a small right-pointing triangle
			c := rlc(sel_fg() if hv || open_here else th.muted)
			ax := ir.x + ir.w - 12
			ay := ir.y + ir.h / 2
			k := fs(0.28)
			rl.DrawTriangle({ax - k, ay - k * 1.2}, {ax - k, ay + k * 1.2}, {ax + k, ay}, c)
		} else if len(short) > 0 do text_in(ir, short, sel_fg() if hv || open_here else th.muted, 2, fs(0.9), 10)
		if hv && !is_sub && ui.released[0] && !ui.popup_open_frame {
			ui.popup_result = i
			ui.popup_result_id = ui.popup_id
			ui.popup_id = 0
		}
	}
	pop_clip()
	if has_bar {
		if on_bar do fill_round(track, alpha(th.muted, 40), 3)
		fill_round({track.x + 2, by, 6, bh}, alpha(th.muted, 210 if on_bar else 150), 3)
	}
	if ui.sub_open >= 0 && ui.popup_id != 0 {
		// the open submenu
		sr := ui.sub_rect
		fill_round({sr.x + 3, sr.y + 3, sr.w, sr.h}, th.shadow, 6)
		fill_round(sr, th.popup, 6)
		stroke_round(sr, th.border, 6)
		push_clip(sr)
		sy := sr.y + 3
		for it, j in ui.sub_items {
			if it == "-" {
				line(sr.x + 8, sy + 4, sr.x + sr.w - 8, sy + 4, th.border)
				sy += 8
				continue
			}
			ir := Rect{sr.x + 4 * ui_scale, sy, sr.w - 8 * ui_scale, ih}
			sy += ih
			label, short := menu_split(it)
			hv := r_contains(ir, ui.mouse)
			if hv do fill_round(ir, th.sel, 4)
			menu_text(ir, label, sel_fg() if hv else th.fg, 10)
			if len(short) > 0 do text_in(ir, short, sel_fg() if hv else th.muted, 2, fs(0.9), 10)
			if hv && ui.released[0] && !ui.popup_open_frame {
				ui.popup_result = ui.sub_open
				ui.sub_result = j
				ui.popup_result_id = ui.popup_id
				ui.popup_id = 0
			}
		}
		pop_clip()
		if in_sub do r = sr // a click in the submenu is not a click outside
	}
	if !ui.popup_open_frame && (ui.pressed[0] || ui.pressed[1]) && !r_contains(r, ui.mouse) {
		ui.popup_id = 0
		ui.popup_result_id = 0
		ui.pressed[0] = false
		ui.pressed[1] = false
	}
	if key_pressed(.ESCAPE) do ui.popup_id = 0
}

draw_tooltip :: proc() {
	if len(ui.tip) == 0 || ui.time - ui.tip_since < S.tooltip_delay {
		if len(ui.tip) == 0 do ui.tip_id = 0
		else do idle_redraw_at(ui.tip_since + S.tooltip_delay)
		ui.tip = ""
		return
	}
	lines := split_lines(ui.tip)
	sz := fs(0.9)
	w: f32 = 0
	for l in lines do w = max(w, text_w(l, sz))
	w += 16
	h := f32(len(lines)) * (sz + 4) + 10
	x := min(ui.mouse.x + 14, screen_w() - w - 4)
	y := ui.mouse.y + 20
	if y + h > screen_h() do y = ui.mouse.y - h - 6
	r := Rect{x, y, w, h}
	// as loomer: a small rounded popup with a border and a shadow
	fill_round({r.x + 2, r.y + 2, r.w, r.h}, th.shadow, 4)
	fill_round(r, th.popup, 4)
	stroke_round(r, th.border, 4)
	for l, i in lines do draw_text(l, x + 8, y + 5 + f32(i) * (sz + 4), th.fg, sz)
	ui.tip = ""
}

scroll_begin :: proc(id_s: string, r: Rect) -> f32 {
	push_clip(r)
	return ui.scroll[id_of(id_s)]
}

scroll_end :: proc(id_s: string, r: Rect, content_h: f32) {
	pop_clip()
	id := id_of(id_s)
	sc := ui.scroll[id]
	if hover(r) && ui.wheel != 0 && !ui.ctrl do sc -= ui.wheel * 50
	sc = clampf32(sc, 0, max(0, content_h - r.h))
	ui.scroll[id] = sc
	if content_h > r.h {
		// a scrollbar that can be dragged, or clicked above / below the thumb to page
		bh := max(r.h * r.h / content_h, 24)
		span := r.h - bh
		by := r.y + span * sc / (content_h - r.h)
		track := Rect{r.x + r.w - 10, r.y, 10, r.h}
		thumb := Rect{r.x + r.w - 8, by, 6, bh}
		over := hover(track)
		if over && ui.pressed[0] {
			if r_contains({track.x, by, track.w, bh}, ui.mouse) {
				ui.sb_drag, ui.sb_grab = id, ui.mouse.y - by
			} else {
				sc = clampf32(sc + (r.h if ui.mouse.y > by else -r.h), 0, content_h - r.h)
			}
			ui.pressed[0] = false
		}
		if ui.sb_drag == id {
			if !ui.down[0] do ui.sb_drag = 0
			else if span > 0 do sc = clampf32((ui.mouse.y - ui.sb_grab - r.y) / span * (content_h - r.h), 0, content_h - r.h)
			by = r.y + span * sc / (content_h - r.h)
			thumb.y = by
		}
		ui.scroll[id] = sc
		hot := over || ui.sb_drag == id
		if hot do fill_round(track, alpha(th.muted, 40), 3)
		fill_round(thumb, alpha(th.muted, 200 if hot else 140), 3)
	}
}

// Wrapped text; returns the height used.
draw_wrapped :: proc(s: string, r: Rect, col: Color, size: f32 = 0) -> f32 {
	sz := size if size > 0 else fs()
	y := r.y
	for para in split_lines(s) {
		words := strings.fields(para, context.temp_allocator)
		ln := ""
		for w in words {
			t := w if len(ln) == 0 else tcat(ln, " ", w)
			if text_w(t, sz) > r.w && len(ln) > 0 {
				draw_text(ln, r.x, y, col, sz)
				y += sz + 4
				ln = w
			} else {
				ln = t
			}
		}
		draw_text(ln, r.x, y, col, sz)
		y += sz + 4
	}
	return y - r.y
}
