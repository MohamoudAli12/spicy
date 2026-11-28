package spicy

import "core:c"
import "core:fmt"
import "core:log"
import "base:runtime"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

// Pop-out waveform windows: a schematic's waveforms in an operating-system window of their
// own, so they can go onto another monitor, be resized freely, or fill a screen (F11).
//
// raylib manages one window. The others are made with the GLFW inside raylib's library (the
// same symbols raylib uses, so there is a single GLFW instance), as in loomer. A pop-out
// window shares the main window's OpenGL objects (font atlases) but has its own context and
// so its own rlgl render batch. Its input arrives through GLFW callbacks into a
// Window_Input that the toolkit reads instead of raylib's (win_input), and it has its own
// toolkit state (focus, popups, hover …): the global `ui` is swapped while it is drawn.
//
// The main loop draws the main window, then, after EndDrawing has polled the events of all
// windows, every pop-out window: popouts_frame.

Popout_Kind :: enum u8 {Waves, Parts}

// doc_id of the parts window (it is not tied to a schematic)
PARTS_WINDOW :: -1

Popout :: struct {
	kind:       Popout_Kind,
	doc_id:     int, // the schematic whose waveforms are shown (PARTS_WINDOW: the parts)
	win:        rawptr, // GLFWwindow*
	batch:      rlgl.RenderBatch,
	st:         UI_State,
	inp:        Window_Input,
	close:      bool, // the window's close button was clicked: dock the waveforms again
	fullscreen: bool,
	windowed:   [4]c.int, // x y w h before going full screen
	shot:       string, // test hook: save a screenshot of the next frame here
	test_action: string, // test hook: run this action inside the window's next frame
}

popouts: [dynamic]^Popout
cur_popout: ^Popout // the pop-out window being drawn (nil: the main window)

@(private = "file")
main_win: rawptr

// ---------------------------------------------------------------------------
// GLFW (inside raylib's library; the system library named here is only a link anchor)

when ODIN_OS == .Windows {
	foreign import glfw_rl "system:kernel32.lib"
} else {
	foreign import glfw_rl "system:c"
}

@(private = "file")
GLFW_RESIZABLE :: 0x00020003
@(private = "file")
GLFW_VISIBLE :: 0x00020004
@(private = "file")
GLFW_SAMPLES :: 0x0002100D
@(private = "file")
GLFW_CLIENT_API :: 0x00022001
@(private = "file")
GLFW_CONTEXT_VERSION_MAJOR :: 0x00022002
@(private = "file")
GLFW_CONTEXT_VERSION_MINOR :: 0x00022003
@(private = "file")
GLFW_OPENGL_FORWARD_COMPAT :: 0x00022006
@(private = "file")
GLFW_OPENGL_PROFILE :: 0x00022008
@(private = "file")
GLFW_CONTEXT_CREATION_API :: 0x0002200B
@(private = "file")
GLFW_SCALE_TO_MONITOR :: 0x0002200C
@(private = "file")
GLFW_PRESS :: 1
@(private = "file")
GLFW_RELEASE :: 0
@(private = "file")
GLFW_REPEAT :: 2
@(private = "file")
GLFW_DONT_CARE :: -1

@(private = "file")
Glfw_Vidmode :: struct {
	width, height, red, green, blue, refresh: c.int,
}

@(private = "file")
Glfw_Mouse_Button_Fn :: #type proc "c" (w: rawptr, button, action, mods: c.int)
@(private = "file")
Glfw_Pos_Fn :: #type proc "c" (w: rawptr, x, y: f64)
@(private = "file")
Glfw_Key_Fn :: #type proc "c" (w: rawptr, key, scancode, action, mods: c.int)
@(private = "file")
Glfw_Char_Fn :: #type proc "c" (w: rawptr, codepoint: c.uint)
@(private = "file")
Glfw_Window_Fn :: #type proc "c" (w: rawptr)
@(private = "file")
Glfw_Focus_Fn :: #type proc "c" (w: rawptr, focused: c.int)

@(default_calling_convention = "c", private = "file")
foreign glfw_rl {
	glfwGetCurrentContext :: proc() -> rawptr ---
	glfwMakeContextCurrent :: proc(w: rawptr) ---
	glfwWindowHint :: proc(hint, value: c.int) ---
	glfwGetWindowAttrib :: proc(w: rawptr, attrib: c.int) -> c.int ---
	glfwCreateWindow :: proc(width, height: c.int, title: cstring, monitor: rawptr, share: rawptr) -> rawptr ---
	glfwDestroyWindow :: proc(w: rawptr) ---
	glfwShowWindow :: proc(w: rawptr) ---
	glfwFocusWindow :: proc(w: rawptr) ---
	glfwSetWindowTitle :: proc(w: rawptr, title: cstring) ---
	glfwSwapBuffers :: proc(w: rawptr) ---
	glfwSwapInterval :: proc(interval: c.int) ---
	glfwGetFramebufferSize :: proc(w: rawptr, width, height: ^c.int) ---
	glfwGetWindowSize :: proc(w: rawptr, width, height: ^c.int) ---
	glfwGetWindowPos :: proc(w: rawptr, x, y: ^c.int) ---
	glfwSetWindowPos :: proc(w: rawptr, x, y: c.int) ---
	glfwSetWindowSizeLimits :: proc(w: rawptr, minw, minh, maxw, maxh: c.int) ---
	glfwSetWindowMonitor :: proc(w: rawptr, monitor: rawptr, x, y, width, height, refresh: c.int) ---
	glfwSetWindowUserPointer :: proc(w: rawptr, p: rawptr) ---
	glfwGetWindowUserPointer :: proc(w: rawptr) -> rawptr ---
	glfwSetMouseButtonCallback :: proc(w: rawptr, cb: Glfw_Mouse_Button_Fn) -> Glfw_Mouse_Button_Fn ---
	glfwSetCursorPosCallback :: proc(w: rawptr, cb: Glfw_Pos_Fn) -> Glfw_Pos_Fn ---
	glfwSetScrollCallback :: proc(w: rawptr, cb: Glfw_Pos_Fn) -> Glfw_Pos_Fn ---
	glfwSetKeyCallback :: proc(w: rawptr, cb: Glfw_Key_Fn) -> Glfw_Key_Fn ---
	glfwSetCharCallback :: proc(w: rawptr, cb: Glfw_Char_Fn) -> Glfw_Char_Fn ---
	glfwSetWindowCloseCallback :: proc(w: rawptr, cb: Glfw_Window_Fn) -> Glfw_Window_Fn ---
	glfwSetWindowFocusCallback :: proc(w: rawptr, cb: Glfw_Focus_Fn) -> Glfw_Focus_Fn ---
	glfwSetWindowShouldClose :: proc(w: rawptr, value: c.int) ---
	glfwCreateStandardCursor :: proc(shape: c.int) -> rawptr ---
	glfwSetCursor :: proc(w: rawptr, cursor: rawptr) ---
	glfwGetMonitors :: proc(count: ^c.int) -> [^]rawptr ---
	glfwGetMonitorPos :: proc(m: rawptr, x, y: ^c.int) ---
	glfwGetMonitorWorkarea :: proc(m: rawptr, x, y, w, h: ^c.int) ---
	glfwGetVideoMode :: proc(m: rawptr) -> ^Glfw_Vidmode ---
}

// ---------------------------------------------------------------------------
// Input callbacks (GLFW key and mouse codes are raylib's)

@(private = "file")
inp_of :: proc "c" (w: rawptr) -> ^Window_Input {
	p := (^Popout)(glfwGetWindowUserPointer(w))
	return &p.inp if p != nil else nil
}

@(private = "file")
cb_button :: proc "c" (w: rawptr, button, action, mods: c.int) {
	idle_note_input()
	in_ := inp_of(w)
	if in_ == nil || button < 0 || button > 2 do return
	// raylib's order is left, right, middle, as GLFW's
	if action == GLFW_PRESS {
		in_.down[button] = true
		in_.pressed[button] = true
	} else if action == GLFW_RELEASE {
		in_.down[button] = false
		in_.released[button] = true
	}
}

@(private = "file")
cb_cursor :: proc "c" (w: rawptr, x, y: f64) {
	idle_note_input()
	in_ := inp_of(w)
	if in_ == nil do return
	// window coordinates -> framebuffer pixels (they differ on macOS Retina screens)
	ww, wh, fw, fh: c.int
	glfwGetWindowSize(w, &ww, &wh)
	glfwGetFramebufferSize(w, &fw, &fh)
	kx := f64(fw) / f64(ww) if ww > 0 else 1
	ky := f64(fh) / f64(wh) if wh > 0 else 1
	in_.mouse = {f32(x * kx), f32(y * ky)}
}

@(private = "file")
cb_scroll :: proc "c" (w: rawptr, x, y: f64) {
	idle_note_input()
	in_ := inp_of(w)
	if in_ == nil do return
	in_.wheel += f32(y)
}

@(private = "file")
cb_key :: proc "c" (w: rawptr, key, scancode, action, mods: c.int) {
	idle_note_input()
	in_ := inp_of(w)
	if in_ == nil || key < 0 || key >= 512 do return
	switch action {
	case GLFW_PRESS:
		in_.kdown[key] = true
		in_.khit[key] = true
	case GLFW_REPEAT: in_.krep[key] = true
	case GLFW_RELEASE: in_.kdown[key] = false
	}
}

@(private = "file")
cb_char :: proc "c" (w: rawptr, cp: c.uint) {
	idle_note_input()
	p := (^Popout)(glfwGetWindowUserPointer(w))
	if p == nil || len(p.inp.chars) >= 64 do return
	context = popout_ctx
	append(&p.inp.chars, rune(cp))
}

@(private = "file")
cb_close :: proc "c" (w: rawptr) {
	idle_note_input()
	p := (^Popout)(glfwGetWindowUserPointer(w))
	if p != nil do p.close = true
	glfwSetWindowShouldClose(w, 0) // spicy closes it (docking the waveforms)
}

@(private = "file")
cb_focus :: proc "c" (w: rawptr, focused: c.int) {
	idle_note_input()
	in_ := inp_of(w)
	if in_ == nil || focused != 0 do return
	// keys held while the window loses the focus never see their release
	in_.kdown = {}
	in_.down = {}
}

@(private = "file")
popout_ctx: runtime.Context // for the callbacks that allocate

// ---------------------------------------------------------------------------

// Remembers the main window (call right after InitWindow).
popouts_init :: proc() {
	main_win = glfwGetCurrentContext()
	app_icon_apply(main_win)
	popout_ctx = context
}

popout_of :: proc(doc_id: int) -> ^Popout {
	for p in popouts do if p.doc_id == doc_id do return p
	return nil
}

// The parts window, nil when it is not open.
parts_window :: proc() -> ^Popout {return popout_of(PARTS_WINDOW)}

// The waveforms of d are shown in a window of their own.
waves_popped_out :: proc(d: ^Doc) -> bool {return d != nil && popout_of(d.id) != nil}

@(private = "file")
doc_index :: proc(id: int) -> int {
	for d, i in app.docs do if d.id == id do return i
	return -1
}

@(private = "file")
popout_title :: proc(p: ^Popout) -> cstring {
	if p.kind == .Parts do return "Parts – spicy"
	i := doc_index(p.doc_id)
	name := doc_title(app.docs[i]) if i >= 0 else "spicy"
	return cstr(fmt.tprintf("%s – waveforms – spicy", name))
}

// The rectangle overlaps a monitor's work area enough to be grabbed by its title bar.
@(private = "file")
on_some_monitor :: proc(x, y, w: int) -> bool {
	n: c.int
	mons := glfwGetMonitors(&n)
	for i in 0 ..< int(n) {
		mx, my, mw, mh: c.int
		glfwGetMonitorWorkarea(mons[i], &mx, &my, &mw, &mh)
		if x + w > int(mx) + 80 && x < int(mx + mw) - 80 && y >= int(my) - 10 && y < int(my + mh) - 40 do return true
	}
	return false
}

// The monitor holding most of the window (its centre).
@(private = "file")
monitor_of :: proc(win: rawptr) -> rawptr {
	x, y, w, h: c.int
	glfwGetWindowPos(win, &x, &y)
	glfwGetWindowSize(win, &w, &h)
	cx, cy := x + w / 2, y + h / 2
	n: c.int
	mons := glfwGetMonitors(&n)
	if n == 0 do return nil
	for i in 0 ..< int(n) {
		mx, my: c.int
		glfwGetMonitorPos(mons[i], &mx, &my)
		vm := glfwGetVideoMode(mons[i])
		if vm == nil do continue
		if cx >= mx && cx < mx + vm.width && cy >= my && cy < my + vm.height do return mons[i]
	}
	return mons[0]
}

// Opens the waveforms of d in their own window (or raises it). False when it cannot be made.
popout_open :: proc(d: ^Doc) -> bool {
	p := popout_create(.Waves, d.id, "wave-window", 1100, 700, 400, 250)
	if p == nil do return false
	if S.w_popout_fullscreen do popout_set_fullscreen(p, true)
	log.infof("waveforms of %s in their own window", doc_title(d))
	return true
}

// To the main window (a part picked in the parts window is placed there).
focus_main_window :: proc() {glfwFocusWindow(main_win)}

// Opens the parts window (or raises it). False when it cannot be made.
parts_window_open :: proc() -> bool {
	p := popout_create(.Parts, PARTS_WINDOW, "parts-window", 560, 720, 300, 300)
	if p == nil do return false
	log.info("parts in their own window")
	return true
}

// A window of its own: geometry from the preference geo_pref (else w × h beside the main window).
@(private = "file")
popout_create :: proc(kind: Popout_Kind, doc_id: int, geo_pref: string, dw, dh, minw, minh: f32) -> ^Popout {
	if p := popout_of(doc_id); p != nil {
		glfwShowWindow(p.win)
		glfwFocusWindow(p.win)
		return p
	}
	if main_win == nil do return nil
	// the same kind of context as the main window, sharing its objects
	attrs := [?]c.int{GLFW_CLIENT_API, GLFW_CONTEXT_VERSION_MAJOR, GLFW_CONTEXT_VERSION_MINOR, GLFW_OPENGL_PROFILE, GLFW_OPENGL_FORWARD_COMPAT, GLFW_CONTEXT_CREATION_API}
	for a in attrs do glfwWindowHint(a, glfwGetWindowAttrib(main_win, a))
	glfwWindowHint(GLFW_SAMPLES, 4 if S.antialias else 0)
	glfwWindowHint(GLFW_RESIZABLE, 1)
	glfwWindowHint(GLFW_VISIBLE, 0)
	glfwWindowHint(GLFW_SCALE_TO_MONITOR, 0)
	k := ui_scale
	w, h := c.int(dw * k), c.int(dh * k)
	gx, gy := 0, 0
	has_geo := false
	if g, ok := pref_value(geo_pref); ok && edn_is_coll(g) && len(g.items) == 4 {
		gx, gy = int(edn_num(g.items[0])), int(edn_num(g.items[1]))
		gw, gh := c.int(edn_num(g.items[2])), c.int(edn_num(g.items[3]))
		if gw > 200 && gh > 150 {
			w, h = gw, gh
			has_geo = true
		}
	}
	rlgl.DrawRenderBatchActive() // flush the main window's batch before switching contexts
	win := glfwCreateWindow(w, h, "spicy", nil, main_win)
	if win == nil {
		glfwMakeContextCurrent(main_win)
		log.errorf("cannot create a window (%v)", kind)
		return nil
	}
	p := new(Popout)
	p.kind = kind
	p.doc_id = doc_id
	p.win = win
	p.inp.chars = make([dynamic]rune)
	glfwSetWindowUserPointer(win, p)
	glfwSetMouseButtonCallback(win, cb_button)
	glfwSetCursorPosCallback(win, cb_cursor)
	glfwSetScrollCallback(win, cb_scroll)
	glfwSetKeyCallback(win, cb_key)
	glfwSetCharCallback(win, cb_char)
	glfwSetWindowCloseCallback(win, cb_close)
	glfwSetWindowFocusCallback(win, cb_focus)
	idle_watch_window(win)
	glfwSetWindowSizeLimits(win, c.int(minw * k), c.int(minh * k), GLFW_DONT_CARE, GLFW_DONT_CARE)
	if has_geo && on_some_monitor(gx, gy, int(w)) {
		glfwSetWindowPos(win, c.int(gx), c.int(gy))
	} else {
		// beside the main window, else centred over it
		mx, my, mw, mh: c.int
		glfwGetWindowPos(main_win, &mx, &my)
		glfwGetWindowSize(main_win, &mw, &mh)
		x, y := mx + mw + 8, my
		if !on_some_monitor(int(x), int(y), int(w)) do x, y = mx + (mw - w) / 2, my + (mh - h) / 2
		glfwSetWindowPos(win, x, y)
	}
	glfwSetWindowTitle(win, popout_title(p))
	glfwMakeContextCurrent(win)
	glfwSwapInterval(0) // the main window paces the loop
	p.batch = rlgl.LoadRenderBatch(1, 8192)
	glfwMakeContextCurrent(main_win)
	append(&popouts, p)
	titlebar_apply_glfw(win) // Windows: the theme's title bar before it is shown
	app_icon_apply(win)
	glfwShowWindow(win)
	glfwFocusWindow(win)
	return p
}

// Closes the window; the waveforms go back into the main window.
popout_close :: proc(p: ^Popout) {
	// asked from inside the window's own frame (Dock, Ctrl+Shift+W there): its context and
	// render batch are still in use, so close it once the frame is done (popouts_frame)
	if p == cur_popout {
		p.close = true
		return
	}
	for q, i in popouts do if q == p {
		if !p.fullscreen {
			x, y, w, h: c.int
			glfwGetWindowPos(p.win, &x, &y)
			glfwGetWindowSize(p.win, &w, &h)
			if w > 0 && h > 0 do pref_put_edn("parts-window" if p.kind == .Parts else "wave-window", fmt.tprintf("[%d %d %d %d]", x, y, w, h))
		}
		rlgl.DrawRenderBatchActive()
		glfwMakeContextCurrent(p.win)
		rlgl.UnloadRenderBatch(p.batch)
		glfwMakeContextCurrent(main_win)
		glfwDestroyWindow(p.win)
		delete(p.inp.chars)
		ordered_remove(&popouts, i)
		if app.dlg_win == p.doc_id do app.dlg_win = 0 // its dialog moves to the main window
		free(p)
		return
	}
}

popouts_shutdown :: proc() {
	for len(popouts) > 0 do popout_close(popouts[0])
}

// Full screen on the monitor the window is on, or back to the window it was.
popout_set_fullscreen :: proc(p: ^Popout, on: bool) {
	if on == p.fullscreen do return
	if on {
		glfwGetWindowPos(p.win, &p.windowed[0], &p.windowed[1])
		glfwGetWindowSize(p.win, &p.windowed[2], &p.windowed[3])
		m := monitor_of(p.win)
		vm := glfwGetVideoMode(m) if m != nil else nil
		if vm == nil do return
		glfwSetWindowMonitor(p.win, m, 0, 0, vm.width, vm.height, vm.refresh)
	} else {
		glfwSetWindowMonitor(p.win, nil, p.windowed[0], p.windowed[1], p.windowed[2], p.windowed[3], 0)
	}
	p.fullscreen = on
	p.inp.kdown = {}
}

// The waveforms of d: into their own window, or back into the main window.
toggle_popout :: proc(d: ^Doc) {
	if p := popout_of(d.id); p != nil {
		popout_close(p)
		return
	}
	if popout_open(d) {
		app.show_waves = true
		status("waveforms in their own window: F11 full screen, close the window to put them back")
	} else {
		status("could not open a window for the waveforms", true)
	}
}

// Full screen: the window under the mouse / with the keyboard (the waveform window, or spicy's).
toggle_fullscreen :: proc() {
	if cur_popout != nil {
		popout_set_fullscreen(cur_popout, !cur_popout.fullscreen)
		return
	}
	rl.ToggleBorderlessWindowed()
}

// Draws every pop-out window. Called once per main-loop iteration, after the main window's
// EndDrawing (which polled the events of all windows).
popouts_frame :: proc() {
	for i := 0; i < len(popouts); i += 1 {
		p := popouts[i]
		if p.close || (p.kind == .Waves && doc_index(p.doc_id) < 0) {
			popout_close(p)
			i -= 1
			continue
		}
		popout_draw(p)
		if p.close {
			popout_close(p)
			i -= 1
		}
	}
}

@(private = "file")
popout_draw :: proc(p: ^Popout) {
	fw, fh: c.int
	glfwGetFramebufferSize(p.win, &fw, &fh)
	if fw <= 0 || fh <= 0 do return // minimised
	p.inp.size = {f32(fw), f32(fh)}
	idx := doc_index(p.doc_id) if p.kind == .Waves else app.cur
	if idx < 0 || idx >= len(app.docs) do return
	d := app.docs[idx]

	// switch to the window: its context, batch, input, toolkit state and schematic
	main_proj := rlgl.GetMatrixProjection()
	main_view := rlgl.GetMatrixModelview()
	saved_ui := ui
	saved_cur := app.cur
	saved_ctx := app.hover_ctx
	rlgl.DrawRenderBatchActive()
	glfwMakeContextCurrent(p.win)
	rlgl.SetRenderBatchActive(&p.batch)
	ui = p.st
	win_input = &p.inp
	cur_popout = p
	app.cur = idx
	app.hover_ctx = .Waves if p.kind == .Waves else .Global

	rlgl.Viewport(0, 0, fw, fh)
	rlgl.MatrixMode(rlgl.PROJECTION)
	rlgl.LoadIdentity()
	rlgl.Ortho(0, f64(fw), f64(fh), 0, 0, 1)
	rlgl.MatrixMode(rlgl.MODELVIEW)
	rlgl.LoadIdentity()
	bg := th.w_bg if p.kind == .Waves else th.panel
	rlgl.ClearColor(bg.r, bg.g, bg.b, 255)
	rlgl.ClearScreenBuffers()
	gl_state_init()

	ui_begin_frame()
	if p.kind == .Parts {
		// the parts window: Esc closes it (when not typing in the search box)
		// (a dialog shown in it takes the Esc)
		if key_pressed(.ESCAPE) && ui.popup_id == 0 && !typing() && !(app.dlg.kind != .None && app.dlg_win == p.doc_id) do p.close = true
	} else if p.fullscreen && key_pressed(.ESCAPE) && !ui.modal && ui.popup_id == 0 && !typing() {
		popout_set_fullscreen(p, false)
	} else do handle_keys()
	if len(p.test_action) > 0 {
		a := p.test_action
		p.test_action = ""
		test_action(a) // (an action, or a test hook as models:)
		delete(a)
	}
	if p.kind == .Parts {
		if picked := parts_panel({0, 0, f32(fw), f32(fh)}, d); picked {
			glfwFocusWindow(main_win) // place it on the schematic
		}
		draw_dialog() // the model table of a group of models clicked here
		draw_popup()
		draw_tooltip()
	} else if doc_index(p.doc_id) >= 0 {
		// (an action – closing the tab … – may have removed the schematic)
		draw_waves(d, {0, 0, f32(fw), f32(fh)})
		draw_dialog()
		draw_popup()
		draw_tooltip()
	}
	ui_end_frame()
	rlgl.DrawRenderBatchActive()
	if len(p.shot) > 0 {
		popout_screenshot(p.shot, fw, fh)
		delete(p.shot)
		p.shot = ""
	}
	glfwSwapBuffers(p.win)
	glfwSetCursor(p.win, std_cursor(ui.cursor))
	// the window's input of this frame is used up
	p.inp.pressed = {}
	p.inp.released = {}
	p.inp.wheel = 0
	clear(&p.inp.chars)
	p.inp.khit = {}
	p.inp.krep = {}

	// back to the main window
	p.st = ui
	ui = saved_ui
	win_input = nil
	cur_popout = nil
	if app.cur == idx do app.cur = saved_cur // unless an action picked another tab
	app.cur = clamp(app.cur, 0, max(0, len(app.docs) - 1))
	app.hover_ctx = saved_ctx
	glfwMakeContextCurrent(main_win)
	rlgl.SetRenderBatchActive(nil)
	rlgl.SetMatrixProjection(main_proj)
	rlgl.SetMatrixModelview(main_view)
	rlgl.MatrixMode(rlgl.MODELVIEW)
	if p.kind == .Waves && idx < len(app.docs) && app.docs[idx].id == p.doc_id do glfwSetWindowTitle(p.win, popout_title(p))
}

// GL state lives in each context: a new context blends with (ONE, ZERO), which would draw
// every glyph quad opaque. rlgl caches the blend mode and skips setting the one it thinks is
// current, so switch away and back to really set alpha blending in this context.
@(private = "file")
gl_state_init :: proc() {
	rlgl.EnableColorBlend()
	rlgl.SetBlendMode(c.int(rlgl.BlendMode.ADDITIVE))
	rlgl.SetBlendMode(c.int(rlgl.BlendMode.ALPHA))
	rlgl.DisableBackfaceCulling()
	rlgl.DisableDepthTest()
}

@(private = "file")
popout_screenshot :: proc(path: string, w, h: c.int) {
	px := rlgl.ReadScreenPixels(w, h)
	img := rl.Image{data = px, width = w, height = h, mipmaps = 1, format = .UNCOMPRESSED_R8G8B8A8}
	rl.ExportImage(img, cstr(path))
	rl.MemFree(px)
}

@(private = "file")
cursors: [16]rawptr

@(private = "file")
std_cursor :: proc(shape: rl.MouseCursor) -> rawptr {
	i := clamp(int(shape), 1, 10) // raylib's cursors are GLFW's standard shapes 0x36001 …
	if cursors[i] == nil do cursors[i] = glfwCreateStandardCursor(c.int(0x36000 + i))
	return cursors[i]
}
