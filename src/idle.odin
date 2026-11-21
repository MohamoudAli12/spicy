package spicy

import "core:c"
import rl "vendor:raylib"

// Idle: spicy draws frames only while something happens.
//
// The toolkit is immediate mode, so a frame lays out and draws everything. Drawing 60 of
// them a second while nobody touches the window wastes CPU, so the main loop calls
// idle_wait before each frame. While there is input (in any window), a mouse button is held
// or a simulation runs, it returns at once and spicy runs at the full frame rate. Otherwise
// it sleeps in GLFW's event wait until
//   - an event arrives in any window (input, resize, expose, focus …): it wakes at once,
//   - a timer some widget asked for runs out (idle_redraw_at: tooltip delay, caret blink,
//     status message timeout, simulation progress), or
//   - the config files are due to be checked (watch_poll), which needs no frame unless one
//     of them was reloaded.
// The main window's events go to raylib's GLFW callbacks; they are wrapped here to note that
// something happened. The pop-out windows' callbacks call idle_note_input themselves.

when ODIN_OS == .Windows {
	foreign import glfw_idle "system:kernel32.lib"
} else {
	foreign import glfw_idle "system:c"
}

@(private = "file")
Fn_Win :: #type proc "c" (w: rawptr)
@(private = "file")
Fn_Win_I :: #type proc "c" (w: rawptr, a: c.int)
@(private = "file")
Fn_Win_II :: #type proc "c" (w: rawptr, a, b: c.int)
@(private = "file")
Fn_Win_III :: #type proc "c" (w: rawptr, a, b, d: c.int)
@(private = "file")
Fn_Win_IIII :: #type proc "c" (w: rawptr, a, b, d, e: c.int)
@(private = "file")
Fn_Win_U :: #type proc "c" (w: rawptr, a: c.uint)
@(private = "file")
Fn_Win_DD :: #type proc "c" (w: rawptr, x, y: f64)
@(private = "file")
Fn_Win_FF :: #type proc "c" (w: rawptr, x, y: f32)
@(private = "file")
Fn_Drop :: #type proc "c" (w: rawptr, n: c.int, paths: [^]cstring)

@(default_calling_convention = "c", private = "file")
foreign glfw_idle {
	glfwGetCurrentContext :: proc() -> rawptr ---
	glfwWaitEventsTimeout :: proc(timeout: f64) ---
	glfwSetWindowRefreshCallback :: proc(w: rawptr, cb: Fn_Win) -> Fn_Win ---
	glfwSetWindowCloseCallback :: proc(w: rawptr, cb: Fn_Win) -> Fn_Win ---
	glfwSetWindowSizeCallback :: proc(w: rawptr, cb: Fn_Win_II) -> Fn_Win_II ---
	glfwSetFramebufferSizeCallback :: proc(w: rawptr, cb: Fn_Win_II) -> Fn_Win_II ---
	glfwSetWindowIconifyCallback :: proc(w: rawptr, cb: Fn_Win_I) -> Fn_Win_I ---
	glfwSetWindowMaximizeCallback :: proc(w: rawptr, cb: Fn_Win_I) -> Fn_Win_I ---
	glfwSetWindowFocusCallback :: proc(w: rawptr, cb: Fn_Win_I) -> Fn_Win_I ---
	glfwSetWindowContentScaleCallback :: proc(w: rawptr, cb: Fn_Win_FF) -> Fn_Win_FF ---
	glfwSetCursorEnterCallback :: proc(w: rawptr, cb: Fn_Win_I) -> Fn_Win_I ---
	glfwSetCursorPosCallback :: proc(w: rawptr, cb: Fn_Win_DD) -> Fn_Win_DD ---
	glfwSetScrollCallback :: proc(w: rawptr, cb: Fn_Win_DD) -> Fn_Win_DD ---
	glfwSetMouseButtonCallback :: proc(w: rawptr, cb: Fn_Win_III) -> Fn_Win_III ---
	glfwSetKeyCallback :: proc(w: rawptr, cb: Fn_Win_IIII) -> Fn_Win_IIII ---
	glfwSetCharCallback :: proc(w: rawptr, cb: Fn_Win_U) -> Fn_Win_U ---
	glfwSetDropCallback :: proc(w: rawptr, cb: Fn_Drop) -> Fn_Drop ---
}

@(private = "file")
GLFW_PRESS :: 1
@(private = "file")
GLFW_RELEASE :: 0

// Frames still drawn after the last event: an immediate-mode toolkit may show the effect of
// an event (a popup opening, the focus moving …) only in the frame after the one that saw it.
@(private = "file")
SETTLE_FRAMES :: 3

@(private = "file")
idle_state: struct {
	enabled:   bool,
	input:     bool, // an event arrived since the last idle_wait
	settle:    int, // frames to draw before sleeping again
	redraw_at: f64, // a frame is wanted by then (set while drawing the previous frame)
	// a press and its release processed in one wait would cancel out before raylib's
	// frame sees the press: the release is held back to the following frame
	btn_new:   [8]bool,
	btn_held:  [8]struct {held: bool, win: rawptr, mods: c.int},
	key_new:   [512]bool,
	key_held:  [512]struct {held: bool, win: rawptr, scancode, mods: c.int},
	any_held:  bool,
	// raylib's callbacks
	refresh:   Fn_Win,
	close:     Fn_Win,
	size:      Fn_Win_II,
	fbsize:    Fn_Win_II,
	iconify:   Fn_Win_I,
	maximize:  Fn_Win_I,
	focus:     Fn_Win_I,
	scale:     Fn_Win_FF,
	enter:     Fn_Win_I,
	pos:       Fn_Win_DD,
	scroll:    Fn_Win_DD,
	button:    Fn_Win_III,
	key:       Fn_Win_IIII,
	char:      Fn_Win_U,
	drop:      Fn_Drop,
}

// Something happened in a window: draw frames again.
idle_note_input :: proc "contextless" () {idle_state.input = true}

// Asks for a frame at time t (rl.GetTime) at the latest, e.g. when a tooltip is due.
idle_redraw_at :: proc(t: f64) {idle_state.redraw_at = min(idle_state.redraw_at, t)}

// Asks for a frame at the next change of a blinking caret (on for 0.6 s of every second).
idle_redraw_blink :: proc(t: f64) {
	ph := t - f64(int(t))
	idle_redraw_at(t - ph + (0.6 if ph < 0.6 else 1.0))
}

// Wraps the main window's (raylib's) GLFW callbacks; call right after InitWindow.
// Not enabled for the test hooks, which count frames.
idle_init :: proc(enabled: bool) {
	s := &idle_state
	s.enabled = enabled
	s.settle = SETTLE_FRAMES
	if !enabled do return
	w := glfwGetCurrentContext()
	if w == nil {
		s.enabled = false
		return
	}
	s.refresh = glfwSetWindowRefreshCallback(w, proc "c" (w: rawptr) {
		idle_note_input()
		if idle_state.refresh != nil do idle_state.refresh(w)
	})
	s.close = glfwSetWindowCloseCallback(w, proc "c" (w: rawptr) {
		idle_note_input() // the close button: the loop checks WindowShouldClose
		if idle_state.close != nil do idle_state.close(w)
	})
	s.size = glfwSetWindowSizeCallback(w, proc "c" (w: rawptr, a, b: c.int) {
		idle_note_input()
		if idle_state.size != nil do idle_state.size(w, a, b)
	})
	s.fbsize = glfwSetFramebufferSizeCallback(w, proc "c" (w: rawptr, a, b: c.int) {
		idle_note_input()
		if idle_state.fbsize != nil do idle_state.fbsize(w, a, b)
	})
	s.iconify = glfwSetWindowIconifyCallback(w, proc "c" (w: rawptr, a: c.int) {
		idle_note_input()
		if idle_state.iconify != nil do idle_state.iconify(w, a)
	})
	s.maximize = glfwSetWindowMaximizeCallback(w, proc "c" (w: rawptr, a: c.int) {
		idle_note_input()
		if idle_state.maximize != nil do idle_state.maximize(w, a)
	})
	s.focus = glfwSetWindowFocusCallback(w, proc "c" (w: rawptr, a: c.int) {
		idle_note_input()
		if idle_state.focus != nil do idle_state.focus(w, a)
	})
	s.scale = glfwSetWindowContentScaleCallback(w, proc "c" (w: rawptr, x, y: f32) {
		idle_note_input()
		if idle_state.scale != nil do idle_state.scale(w, x, y)
	})
	s.enter = glfwSetCursorEnterCallback(w, proc "c" (w: rawptr, a: c.int) {
		idle_note_input()
		if idle_state.enter != nil do idle_state.enter(w, a)
	})
	s.pos = glfwSetCursorPosCallback(w, proc "c" (w: rawptr, x, y: f64) {
		idle_note_input()
		if idle_state.pos != nil do idle_state.pos(w, x, y)
	})
	s.scroll = glfwSetScrollCallback(w, proc "c" (w: rawptr, x, y: f64) {
		idle_note_input()
		if idle_state.scroll != nil do idle_state.scroll(w, x, y)
	})
	s.button = glfwSetMouseButtonCallback(w, proc "c" (w: rawptr, b, action, mods: c.int) {
		idle_note_input()
		s := &idle_state
		if b >= 0 && b < len(s.btn_new) {
			if action == GLFW_PRESS do s.btn_new[b] = true
			else if action == GLFW_RELEASE && s.btn_new[b] {
				s.btn_held[b] = {true, w, mods}
				s.any_held = true
				return
			}
		}
		if s.button != nil do s.button(w, b, action, mods)
	})
	s.key = glfwSetKeyCallback(w, proc "c" (w: rawptr, k, scancode, action, mods: c.int) {
		idle_note_input()
		s := &idle_state
		if k >= 0 && k < len(s.key_new) {
			if action == GLFW_PRESS do s.key_new[k] = true
			else if action == GLFW_RELEASE && s.key_new[k] {
				s.key_held[k] = {true, w, scancode, mods}
				s.any_held = true
				return
			}
		}
		if s.key != nil do s.key(w, k, scancode, action, mods)
	})
	s.char = glfwSetCharCallback(w, proc "c" (w: rawptr, cp: c.uint) {
		idle_note_input()
		if idle_state.char != nil do idle_state.char(w, cp)
	})
	s.drop = glfwSetDropCallback(w, proc "c" (w: rawptr, n: c.int, paths: [^]cstring) {
		idle_note_input()
		if idle_state.drop != nil do idle_state.drop(w, n, paths)
	})
}

// Called once per main-loop pass, before the frame. Returns when a frame should be drawn;
// in between it sleeps, checking the config files when they are due.
idle_wait :: proc() {
	s := &idle_state
	// the previous frame has seen the presses: hand over the releases held back
	s.btn_new = {}
	s.key_new = {}
	if s.any_held {
		s.any_held = false
		for &h, b in s.btn_held do if h.held {
			h.held = false
			if s.button != nil do s.button(h.win, c.int(b), GLFW_RELEASE, h.mods)
		}
		for &h, k in s.key_held do if h.held {
			h.held = false
			if s.key != nil do s.key(h.win, c.int(k), h.scancode, GLFW_RELEASE, h.mods)
		}
		s.input = true
	}
	defer s.redraw_at = max(f64)
	watch_poll(rl.GetTime())
	if !s.enabled do return
	if s.input {
		s.input = false
		s.settle = SETTLE_FRAMES
	}
	if s.settle > 0 {
		s.settle -= 1
		return
	}
	if mouse_held() do return
	for {
		now := rl.GetTime()
		if now >= s.redraw_at do return
		wake := min(s.redraw_at, watch_next)
		if wake > now do glfwWaitEventsTimeout(wake - now)
		if s.input {
			s.input = false
			s.settle = SETTLE_FRAMES
			return
		}
		if watch_poll(rl.GetTime()) do return // a config file was reloaded
	}
}

// A mouse button is held in some window (a drag may scroll or zoom without motion).
@(private = "file")
mouse_held :: proc() -> bool {
	for b in ([]rl.MouseButton{.LEFT, .RIGHT, .MIDDLE}) do if rl.IsMouseButtonDown(b) do return true
	for p in popouts do if p.inp.down[0] || p.inp.down[1] || p.inp.down[2] do return true
	return false
}

// A pop-out window's resizes, exposes and minimising wake the main loop too (its input
// callbacks call idle_note_input).
idle_watch_window :: proc(win: rawptr) {
	glfwSetWindowRefreshCallback(win, proc "c" (w: rawptr) {idle_note_input()})
	glfwSetFramebufferSizeCallback(win, proc "c" (w: rawptr, a, b: c.int) {idle_note_input()})
	glfwSetWindowIconifyCallback(win, proc "c" (w: rawptr, a: c.int) {idle_note_input()})
	glfwSetCursorEnterCallback(win, proc "c" (w: rawptr, a: c.int) {idle_note_input()})
}
