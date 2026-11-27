package spicy

import "core:fmt"
import "core:math"
import "core:strings"
import rl "vendor:raylib"

// The waveform viewer: panes of traces, cursors, markers, zoom.

Trace :: struct {
	expr:   string,
	color:  int,
	// evaluated (owned)
	y:      []f64, // real value, or magnitude (dB) for AC
	ph:     []f64, // phase (degrees) for AC, else nil
	unit:   string,
	err:    string,
	hidden: bool,
}

Pane :: struct {
	traces: [dynamic]Trace,
	auto_y: bool,
	y0, y1: f64,
	r0, r1: f64, // the right axis, for a second unit (see pane_axes)
	p0, p1: f64, // phase axis
	rect:   Rect, // plot area of the last frame
	fft:    ^Fft_Pane, // a spectrum pane: the FFT of its traces, on a frequency axis of its own
}

// A spectrum pane. Its traces are time-domain expressions; the pane shows their amplitude
// spectra over the window [t0, t1] (0, 0: the whole run).
Fft_Pane :: struct {
	ax:     X_Axis, // the frequency axis (swapped into the Wave_View while the pane is in use)
	t0, t1: f64,
	window: int, // index into FFT_WINDOWS
	db:     bool, // amplitude in dB (re 1 V / 1 A) instead of linear
	df:     f64, // of the last evaluation
	n:      int,
	w0, w1: f64, // the window actually used
}

// The x axis of a pane. The Wave_View holds the time / frequency / sweep axis shared by
// the ordinary panes; a spectrum pane has its own, and wave_axis_swap exchanges the two
// while that pane is drawn or used, so every axis helper works on either.
X_Axis :: struct {
	x:       []f64, // owned copy of the plot's scale
	x_name:  string,
	x_unit:  string,
	complex: bool,
	log_x:   bool,
	auto_x:  bool,
	x0, x1:  f64,
	history: [dynamic][6]f64, // x0 x1 + y and right-axis range of the active pane
	drag_x0: f64,
	drag_x1: f64,
}

Cursor :: struct {
	on:    bool,
	x:     f64,
	pane:  int,
	trace: int,
}

Marker :: struct {
	pane, trace: int,
	x:           f64,
}

Wave_Sel :: struct {
	pane, trace: int,
}

Wave_Drag :: enum u8 {None, Zoom, Pan, Cursor1, Cursor2}

// The tables of the viewer: the .meas results, and the one-point results (operating point, integrated noise).
TABLE_NONE :: 0
TABLE_MEAS :: 1
TABLE_VALUES :: 2

Wave_View :: struct {
	panes:      [dynamic]Pane,
	active:     int,
	plot_idx:   int,
	plot_kind:  string,
	table:      int, // a table shown instead of the plots: TABLE_NONE, TABLE_MEAS or TABLE_VALUES
	using axis: X_Axis,
	swapped:    int, // pane whose axis is in `axis` (-1: the shared one)
	cursors:    [2]Cursor,
	markers:    [dynamic]Marker,
	sel:        Wave_Sel,
	dirty:      bool,
	next_color: int,
	drag:       Wave_Drag,
	drag_start: [2]f32,
	drag_pane:  int,
	drag_y0:    f64,
	drag_y1:    f64,
}

wave_init :: proc(w: ^Wave_View) {
	w.panes = make([dynamic]Pane)
	append(&w.panes, Pane{auto_y = true})
	w.auto_x = true
	w.sel = {-1, -1}
	w.plot_idx = -1
	w.swapped = -1
}

// Puts pane pi's own axis into w (a spectrum pane), or back again: call it in pairs.
// Ordinary panes and invalid indices do nothing.
wave_axis_swap :: proc(w: ^Wave_View, pi: int) {
	if pi < 0 || pi >= len(w.panes) || w.panes[pi].fft == nil do return
	f := w.panes[pi].fft
	w.axis, f.ax = f.ax, w.axis
	w.swapped = pi if w.swapped != pi else -1
}

axis_free :: proc(a: ^X_Axis) {
	delete(a.x); delete(a.x_name); delete(a.x_unit); delete(a.history)
	a^ = {}
}

pane_free :: proc(p: ^Pane) {
	for &t in p.traces {trace_free_data(&t); delete(t.expr)}
	delete(p.traces)
	if p.fft != nil {
		axis_free(&p.fft.ax)
		free(p.fft)
	}
	p^ = {}
}

pane_is_fft :: proc(w: ^Wave_View, pi: int) -> bool {
	return pi >= 0 && pi < len(w.panes) && w.panes[pi].fft != nil
}

// FFT is offered for traces of a transient analysis in an ordinary pane.
wave_can_fft :: proc(w: ^Wave_View, pane: int) -> bool {
	return w.plot_kind == "tran" && !w.complex && pane >= 0 && pane < len(w.panes) && w.panes[pane].fft == nil
}

// A spectrum pane with the settings of settings.edn (:waveform :fft-…).
fft_pane_new :: proc() -> ^Fft_Pane {
	f := new(Fft_Pane)
	f.window = S.w_fft_window
	f.db = S.w_fft_db
	f.ax.log_x = S.w_fft_log
	f.ax.auto_x = true
	return f
}

// Adds a spectrum pane with the FFT of expr, over the time window shown now (the whole run
// when the view shows all of it, or with :fft-range :all).
wave_add_fft :: proc(w: ^Wave_View, expr: string) {
	f := fft_pane_new()
	if !S.w_fft_all && !w.auto_x && len(w.x) > 1 {
		lo, hi := w.x[0], w.x[len(w.x) - 1]
		if w.x0 > lo + (hi - lo) * 1e-9 || w.x1 < hi - (hi - lo) * 1e-9 do f.t0, f.t1 = w.x0, w.x1
	}
	append(&w.panes, Pane{auto_y = true, fft = f})
	pi := len(w.panes) - 1
	append(&w.panes[pi].traces, Trace{expr = strings.clone(expr), color = w.next_color})
	w.next_color += 1
	w.active = pi
	w.sel = {pi, 0}
	w.dirty = true
}

trace_free_data :: proc(t: ^Trace) {
	delete(t.y); delete(t.ph); delete(t.unit); delete(t.err)
	t.y, t.ph, t.unit, t.err = nil, nil, "", ""
}

wave_clear_panes :: proc(w: ^Wave_View) {
	for &p in w.panes do pane_free(&p)
	clear(&w.panes)
	clear(&w.markers)
	w.cursors = {}
	w.sel = {-1, -1}
}

wave_free :: proc(w: ^Wave_View) {
	wave_clear_panes(w)
	delete(w.panes)
	axis_free(&w.axis)
	delete(w.plot_kind)
	delete(w.markers)
}

wave_mark_dirty :: proc(w: ^Wave_View) {w.dirty = true}

wave_trace_count :: proc(w: ^Wave_View) -> int {
	n := 0
	for p in w.panes do n += len(p.traces)
	return n
}

wave_clear :: proc(w: ^Wave_View) {
	wave_clear_panes(w)
	append(&w.panes, Pane{auto_y = true})
	w.active = 0
	w.next_color = 0
}

wave_select_none :: proc(w: ^Wave_View) {w.sel = {-1, -1}}

is_current_expr :: proc(e: string) -> bool {
	u := strings.trim_left(upper(e), "-+ ")
	return strings.has_prefix(u, "I")
}

wave_add_trace :: proc(w: ^Wave_View, expr: string, new_pane: bool) {
	if len(w.panes) == 0 do append(&w.panes, Pane{auto_y = true})
	w.active = clamp(w.active, 0, len(w.panes) - 1)
	pi := w.active
	if w.panes[pi].fft != nil {
		// probes go to the time-domain panes; the last one, or a new one
		pi = -1
		for p, i in w.panes do if p.fft == nil do pi = i
		if pi < 0 {
			append(&w.panes, Pane{auto_y = true})
			pi = len(w.panes) - 1
		}
	}
	empty := len(w.panes[pi].traces) == 0
	switch {
	case new_pane && !empty:
		append(&w.panes, Pane{auto_y = true})
		pi = len(w.panes) - 1
	case S.w_new_pane_for == "each-trace" && !empty:
		append(&w.panes, Pane{auto_y = true})
		pi = len(w.panes) - 1
	case S.w_new_pane_for == "voltages-and-currents":
		cur := is_current_expr(expr)
		found := -1
		for p, i in w.panes do if p.fft == nil && len(p.traces) > 0 && is_current_expr(p.traces[0].expr) == cur do found = i
		if found >= 0 do pi = found
		else if !empty {
			found = -1
			for p, i in w.panes do if p.fft == nil && len(p.traces) == 0 do found = i
			if found < 0 {
				append(&w.panes, Pane{auto_y = true})
				found = len(w.panes) - 1
			}
			pi = found
		}
	}
	p := &w.panes[pi]
	for t, i in p.traces do if strings.equal_fold(t.expr, expr) {
		w.sel = {pi, i}
		return
	}
	append(&p.traces, Trace{expr = strings.clone(expr), color = w.next_color})
	w.next_color += 1
	p.auto_y = true
	w.active = pi
	w.sel = {pi, len(p.traces) - 1}
	w.dirty = true
}

wave_add_pane :: proc(w: ^Wave_View) {
	append(&w.panes, Pane{auto_y = true})
	w.active = len(w.panes) - 1
}

wave_delete_selected :: proc(w: ^Wave_View) {
	s := w.sel
	if s.pane < 0 || s.pane >= len(w.panes) || s.trace < 0 || s.trace >= len(w.panes[s.pane].traces) do return
	p := &w.panes[s.pane]
	t := &p.traces[s.trace]
	trace_free_data(t)
	delete(t.expr)
	ordered_remove(&p.traces, s.trace)
	// markers and cursors on it
	for i := len(w.markers) - 1; i >= 0; i -= 1 {
		m := &w.markers[i]
		if m.pane == s.pane && m.trace == s.trace do ordered_remove(&w.markers, i)
		else if m.pane == s.pane && m.trace > s.trace do m.trace -= 1
	}
	for &c in w.cursors do if c.pane == s.pane {
		if c.trace == s.trace do c.trace = -1
		else if c.trace > s.trace do c.trace -= 1
	}
	if len(p.traces) == 0 && (len(w.panes) > 1 || p.fft != nil) {
		pane_free(p)
		ordered_remove(&w.panes, s.pane)
		if len(w.panes) == 0 do append(&w.panes, Pane{auto_y = true})
		for i := len(w.markers) - 1; i >= 0; i -= 1 {
			if w.markers[i].pane == s.pane do ordered_remove(&w.markers, i)
			else if w.markers[i].pane > s.pane do w.markers[i].pane -= 1
		}
		for &c in w.cursors {
			if c.pane == s.pane {c.pane = 0; c.trace = -1} else if c.pane > s.pane do c.pane -= 1
		}
	}
	p2 := clamp(s.pane, 0, len(w.panes) - 1)
	w.active = p2
	w.panes[p2].auto_y = true
	w.sel = {-1, -1}
}

wave_fit :: proc(w: ^Wave_View) {
	wave_push_history(w)
	w.auto_x = true
	for &p in w.panes {
		p.auto_y = true
		if p.fft != nil do p.fft.ax.auto_x = true
	}
}

wave_push_history :: proc(w: ^Wave_View) {
	y0, y1, r0, r1: f64
	if w.active >= 0 && w.active < len(w.panes) {
		p := &w.panes[w.active]
		y0, y1, r0, r1 = p.y0, p.y1, p.r0, p.r1
	}
	append(&w.history, [6]f64{w.x0, w.x1, y0, y1, r0, r1})
	if len(w.history) > 50 do ordered_remove(&w.history, 0)
}

wave_zoom_back :: proc(w: ^Wave_View) {
	if w.swapped < 0 && pane_is_fft(w, w.active) {
		a := w.active
		wave_axis_swap(w, a)
		defer wave_axis_swap(w, a)
		wave_zoom_back(w)
		return
	}
	if len(w.history) == 0 {
		wave_fit(w)
		clear(&w.history)
		return
	}
	h := pop(&w.history)
	w.x0, w.x1 = h[0], h[1]
	w.auto_x = false
	if w.active >= 0 && w.active < len(w.panes) {
		p := &w.panes[w.active]
		p.y0, p.y1, p.r0, p.r1 = h[2], h[3], h[4], h[5]
		p.auto_y = false
	}
}

// Zooms the x axis by f about its centre (f > 1 zooms out).
wave_zoom :: proc(w: ^Wave_View, f: f64) {
	if w.swapped < 0 && pane_is_fft(w, w.active) {
		a := w.active
		wave_axis_swap(w, a)
		defer wave_axis_swap(w, a)
		wave_zoom(w, f)
		return
	}
	if len(w.x) == 0 do return
	wave_push_history(w)
	a, b := xv(w, w.x0), xv(w, w.x1)
	c := (a + b) / 2
	h := (b - a) / 2 * f
	w.x0, w.x1 = xi(w, c - h), xi(w, c + h)
	w.auto_x = false
}

// x to the drawing scale (log for AC)
xv :: proc(w: ^Wave_View, x: f64) -> f64 {
	if w.log_x do return math.log10(max(x, 1e-300))
	return x
}
xi :: proc(w: ^Wave_View, v: f64) -> f64 {
	if w.log_x do return math.pow(10, v)
	return v
}

wave_toggle_cursor :: proc(w: ^Wave_View, k: int) {
	c := &w.cursors[k]
	if c.on {
		c.on = false
		return
	}
	c.on = true
	c.pane = w.sel.pane if w.sel.pane >= 0 else w.active
	c.trace = w.sel.trace if w.sel.pane >= 0 else (0 if c.pane < len(w.panes) && len(w.panes[c.pane].traces) > 0 else -1)
	c.x = math.nan_f64() // placed when the axis is known
}

wave_mouse_x: f64
wave_mouse_pane := -1

wave_add_marker_at_mouse :: proc(w: ^Wave_View) {
	if wave_mouse_pane < 0 || wave_mouse_pane >= len(w.panes) do return
	p := &w.panes[wave_mouse_pane]
	if len(p.traces) == 0 do return
	tr := w.sel.trace if w.sel.pane == wave_mouse_pane && w.sel.trace >= 0 else 0
	append(&w.markers, Marker{pane = wave_mouse_pane, trace = tr, x = wave_mouse_x})
}

// The plots the viewer lists, by index into r.plots.
wave_listed_plots :: proc(r: ^Run) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	for &p, i in r.plots do if plot_listed(&p) do append(&out, i)
	return out[:]
}

// Tab: the next analysis, then the measurement table (when the run has results), then the first again.
wave_next_plot :: proc(w: ^Wave_View, r: ^Run, sch: ^Schematic, sim: ^Simulator_Def) {
	// the cycle: the plots (their index), then the tables (-1, -2)
	cycle := make([dynamic]int, context.temp_allocator)
	for pi in wave_listed_plots(r) do append(&cycle, pi)
	if len(r.meas_rows) > 0 do append(&cycle, -1)
	if len(wave_value_rows(r)) > 0 do append(&cycle, -2)
	if len(cycle) < 2 do return
	cur := w.plot_idx
	if w.table == TABLE_MEAS do cur = -1
	if w.table == TABLE_VALUES do cur = -2
	next := 0
	for c, k in cycle do if c == cur do next = (k + 1) % len(cycle)
	if cycle[next] < 0 {
		w.table = TABLE_MEAS if cycle[next] == -1 else TABLE_VALUES
		return
	}
	w.table = TABLE_NONE
	w.plot_idx = cycle[next]
	set_str(&w.plot_kind, plot_kind(&r.plots[w.plot_idx]))
	w.dirty = true
	w.auto_x = true
	for &p in w.panes do p.auto_y = true
	wave_refit_plot_traces(w, r, sch, sim)
}

// The .plot traces that the current analysis can show: the others are left out (no error
// lines), and they appear when their analysis is shown (Tab).
@(private = "file")
wave_plot_trace_ok :: proc(w: ^Wave_View, r: ^Run, sch: ^Schematic, sim: ^Simulator_Def, e: string) -> bool {
	return w.plot_idx >= 0 && w.plot_idx < len(r.plots) && len(plot_expr_error(e, &r.plots[w.plot_idx], sch, sim)) == 0
}

@(private = "file")
wave_refit_plot_traces :: proc(w: ^Wave_View, r: ^Run, sch: ^Schematic, sim: ^Simulator_Def) {
	for &p in w.panes {
		if p.fft != nil do continue
		for i := len(p.traces) - 1; i >= 0; i -= 1 {
			if !wave_is_plot_trace(r, p.traces[i].expr) || wave_plot_trace_ok(w, r, sch, sim, p.traces[i].expr) do continue
			ordered_remove(&p.traces, i)
			w.sel = {-1, -1}
		}
	}
	for e in r.plot_traces {
		if !wave_plot_trace_ok(w, r, sch, sim, e) || wave_trace_shown(w, e) do continue
		wave_add_trace(w, e, false)
	}
}

@(private = "file")
wave_is_plot_trace :: proc(r: ^Run, expr: string) -> bool {
	for e in r.plot_traces do if e == expr do return true
	return false
}

@(private = "file")
wave_trace_shown :: proc(w: ^Wave_View, expr: string) -> bool {
	for &p in w.panes do if p.fft == nil do for t in p.traces do if strings.equal_fold(t.expr, expr) do return true
	return false
}

// A run finished: show its results.
wave_new_run :: proc(w: ^Wave_View, r: ^Run, sch: ^Schematic, sim: ^Simulator_Def) {
	w.table = TABLE_NONE
	if !S.w_keep_traces do wave_clear(w)
	// the same kind of analysis as before, else the first that is not an operating point
	idx := -1
	if len(w.plot_kind) > 0 do for &p, i in r.plots do if plot_kind(&p) == w.plot_kind && plot_listed(&p) && idx < 0 do idx = i
	if idx < 0 do for &p, i in r.plots do if plot_kind(&p) != "op" && plot_listed(&p) && idx < 0 do idx = i
	if idx < 0 && len(r.plots) > 0 do idx = 0
	// .plot directives: the analysis they can be shown in
	idx = plot_pick(r, sch, sim, idx)
	kind_changed := idx >= 0 && plot_kind(&r.plots[idx]) != w.plot_kind
	w.plot_idx = idx
	if idx >= 0 do set_str(&w.plot_kind, plot_kind(&r.plots[idx]))
	w.dirty = true
	if kind_changed || w.auto_x {
		w.auto_x = true
		clear(&w.history)
	}
	for &p in w.panes {
		p.auto_y = true
		if p.fft != nil do p.fft.ax.auto_x = true
	}
	wave_refit_plot_traces(w, r, sch, sim)
}

// Re-evaluates every trace against the current plot.
@(private = "file")
wave_eval :: proc(w: ^Wave_View, d: ^Doc) {
	w.dirty = false
	r := &d.run
	if w.plot_idx < 0 || w.plot_idx >= len(r.plots) do return
	plot := &r.plots[w.plot_idx]
	if len(plot.vecs) == 0 do return
	delete(w.x)
	sc := plot.vecs[0]
	w.x = make([]f64, len(sc.re))
	copy(w.x, sc.re)
	set_str(&w.x_name, sc.name)
	set_str(&w.x_unit, sc.unit)
	w.complex = plot.complex
	w.log_x = false
	if plot.complex && len(w.x) > 2 && w.x[0] > 0 {
		// AC: log x when the points are spread logarithmically
		ra := w.x[len(w.x) - 1] / w.x[0]
		if ra > 20 do w.log_x = true
	}
	sim := doc_sim(d)
	for &p in w.panes {
		if p.fft != nil do fft_eval(w, &p, plot, d, sim)
	}
	for &p in w.panes do if p.fft == nil do for &t in p.traces {
		trace_free_data(&t)
		res := expr_eval(t.expr, plot, &d.sch, sim)
		if len(res.err) > 0 {
			t.err = res.err
			delete(res.unit)
			continue
		}
		t.unit = res.unit
		if res.im == nil {
			t.y = res.re
			continue
		}
		// complex: shown as set in :ac-display
		n := len(res.re)
		t.y = make([]f64, n)
		mode := S.w_ac_display
		if mode == "bode" || mode == "phase" do t.ph = make([]f64, n)
		prev := 0.0
		for i in 0 ..< n {
			re, im := res.re[i], res.im[i]
			mag := abs_c(re, im)
			switch mode {
			case "magnitude": t.y[i] = mag
			case "real-imag": t.y[i] = re
			case: t.y[i] = 20 * math.log10(mag) if mag > 0 else math.nan_f64()
			}
			if t.ph != nil {
				ph := phase_deg(re, im)
				if S.w_phase_unwrap && i > 0 {
					for ph - prev > 180 do ph -= 360
					for ph - prev < -180 do ph += 360
				}
				t.ph[i] = ph
				prev = ph
			}
		}
		if mode == "phase" {
			delete(t.y)
			t.y = t.ph
			t.ph = nil
			set_str(&t.unit, "°")
		} else if mode != "magnitude" && mode != "real-imag" {
			set_str(&t.unit, "dB")
		}
		delete(res.re); delete(res.im)
	}
}

// Spectra of a spectrum pane's traces: each expression is evaluated in the time domain,
// then transformed over the pane's window. All traces share the window, so they share
// the frequency grid as well.
@(private = "file")
fft_eval :: proc(w: ^Wave_View, p: ^Pane, plot: ^Plot, d: ^Doc, sim: ^Simulator_Def) {
	f := p.fft
	delete(f.ax.x)
	f.ax.x = nil
	set_str(&f.ax.x_name, "frequency")
	set_str(&f.ax.x_unit, "Hz")
	f.ax.complex = false
	f.df, f.n = 0, 0
	t := w.x
	ok_plot := plot_kind(plot) == "tran" && !plot.complex && len(t) >= 4
	t0, t1 := f.t0, f.t1
	if ok_plot {
		lo, hi := t[0], t[len(t) - 1]
		// the stored window, if it still lies inside this run; else the whole run
		if t1 <= t0 || t0 < lo - (hi - lo) * 1e-9 || t1 > hi + (hi - lo) * 1e-9 do t0, t1 = lo, hi
	}
	f.w0, f.w1 = t0, t1
	for &tr in p.traces {
		trace_free_data(&tr)
		if !ok_plot {
			tr.err = strings.clone("FFT needs a transient analysis")
			continue
		}
		res := expr_eval(tr.expr, plot, &d.sch, sim)
		if len(res.err) > 0 {
			tr.err = res.err
			delete(res.unit)
			continue
		}
		defer {delete(res.re); delete(res.im); delete(res.unit)}
		sp, ok := spectrum_of(t, res.re, t0, t1, f.window, S.w_fft_max_points)
		if !ok {
			tr.err = strings.clone("too few points for an FFT")
			continue
		}
		if f.ax.x == nil {
			f.ax.x = sp.f
			f.df, f.n = sp.df, sp.n
		} else {
			delete(sp.f)
		}
		tr.y = sp.amp
		if f.db {
			for &a in tr.y do a = 20 * math.log10(a) if a > 0 else math.nan_f64()
			tr.unit = strings.concatenate({"dB", res.unit})
		} else {
			tr.unit = strings.clone(res.unit)
		}
	}
}

// ---------------------------------------------------------------------------
// Axes

nice_step :: proc(span: f64, n: int) -> f64 {
	if span <= 0 do return 1
	raw := span / f64(max(n, 1))
	e := math.floor(math.log10(raw))
	b := math.pow(10, e)
	f := raw / b
	s := 10.0
	if f <= 1 do s = 1
	else if f <= 2 do s = 2
	else if f <= 2.5 do s = 2.5
	else if f <= 5 do s = 5
	return s * b
}

data_range :: proc(xs, ys: []f64, x0, x1: f64) -> (lo, hi: f64, ok: bool) {
	lo, hi = math.INF_F64, -math.INF_F64
	n := min(len(xs), len(ys))
	for i in 0 ..< n {
		if xs[i] < x0 || xs[i] > x1 {
			// keep the neighbours of the window so lines leaving it count
			in_next := i + 1 < n && xs[i + 1] >= x0 && xs[i] < x0
			in_prev := i > 0 && xs[i - 1] <= x1 && xs[i] > x1
			if !in_next && !in_prev do continue
		}
		y := ys[i]
		if math.is_nan(y) || math.is_inf(y) do continue
		lo = min(lo, y)
		hi = max(hi, y)
	}
	return lo, hi, lo <= hi
}

pad_range :: proc(lo, hi: f64) -> (f64, f64) {
	a, b := lo, hi
	if b - a < 1e-30 + abs(a) * 1e-9 {
		d := max(abs(a) * 0.1, 1e-12)
		if a == 0 && b == 0 do d = 1
		return a - d, b + d
	}
	m := (b - a) * S.w_y_margin
	return a - m, b + m
}

interp :: proc(xs, ys: []f64, x: f64) -> f64 {
	n := min(len(xs), len(ys))
	if n == 0 do return math.nan_f64()
	if n == 1 do return ys[0]
	lo, hi := 0, n - 1
	if xs[hi] < xs[lo] {
		// decreasing x (DC sweeps downwards)
		for i in 0 ..< n - 1 {
			a, b := xs[i], xs[i + 1]
			if (x <= a && x >= b) {
				t := (x - a) / (b - a) if b != a else 0
				return ys[i] + (ys[i + 1] - ys[i]) * t
			}
		}
		return ys[0] if abs(x - xs[0]) < abs(x - xs[n - 1]) else ys[n - 1]
	}
	if x <= xs[0] do return ys[0]
	if x >= xs[n - 1] do return ys[n - 1]
	for hi - lo > 1 {
		m := (lo + hi) / 2
		if xs[m] <= x do lo = m
		else do hi = m
	}
	a, b := xs[lo], xs[hi]
	t := (x - a) / (b - a) if b != a else 0
	return ys[lo] + (ys[hi] - ys[lo]) * t
}

trace_label :: proc(t: ^Trace) -> string {
	if w := S.w_ac_display; t.ph != nil && w == "bode" do return t.expr
	return t.expr
}

// ---------------------------------------------------------------------------
// Drawing

@(private = "file")
dash_line :: proc(pts: []rl.Vector2, width: f32, col: rl.Color) {
	dash, gap: f32 = 7, 5
	on := true
	left := dash
	for i in 1 ..< len(pts) {
		a, b := pts[i - 1], pts[i]
		d := b - a
		l := math.sqrt(d.x * d.x + d.y * d.y)
		if l < 0.01 do continue
		u := d / l
		pos: f32 = 0
		for pos < l {
			step := min(left, l - pos)
			p0 := a + u * pos
			p1 := a + u * (pos + step)
			if on do rl.DrawLineEx(p0, p1, width, col)
			pos += step
			left -= step
			if left <= 0.001 {
				on = !on
				left = dash if on else gap
			}
		}
	}
}

// The units of a pane's y axes. The first unit of its visible traces goes on the left axis,
// a second one on a right axis of its own. With a third unit, or a second one while the Bode
// phase axis takes the right side, the axis shows plain numbers (mixed) and the units are in
// the legend and the readouts. Traces without a unit go on the left axis.
Pane_Axes :: struct {
	left, right: string,
	dual, mixed: bool,
}

pane_axes :: proc(w: ^Wave_View, p: ^Pane) -> Pane_Axes {
	a: Pane_Axes
	phase := false
	for t in p.traces {
		if t.hidden || t.y == nil do continue
		if t.ph != nil do phase = true
		if len(t.unit) == 0 do continue
		switch {
		case len(a.left) == 0: a.left = t.unit
		case t.unit == a.left:
		case len(a.right) == 0: a.right = t.unit
		case t.unit != a.right: a.mixed = true
		}
	}
	if len(a.right) > 0 && w.complex && S.w_ac_display == "bode" && phase do a.mixed = true
	a.dual = len(a.right) > 0 && !a.mixed
	return a
}

// The y range of the axis a trace is drawn on.
trace_y_range :: proc(p: ^Pane, a: Pane_Axes, t: Trace) -> (f64, f64) {
	if a.dual && t.unit == a.right do return p.r0, p.r1
	return p.y0, p.y1
}

// Screen height of the value y on an axis showing y0 … y1 in plot.
y_to_scr :: proc(plot: Rect, y, y0, y1: f64) -> f32 {
	return plot.y + plot.h - f32((y - y0) / (y1 - y0)) * plot.h
}

// The value at screen height sy on an axis showing y0 … y1 in plot.
scr_to_y :: proc(plot: Rect, sy: f32, y0, y1: f64) -> f64 {
	return y0 + f64((plot.y + plot.h - sy) / plot.h) * (y1 - y0)
}

// Shows y0 … y1 on the left axis; the right axis zooms and pans with it by the same fractions.
pane_set_y :: proc(p: ^Pane, y0, y1: f64) {
	if p.y1 != p.y0 {
		k := (p.r1 - p.r0) / (p.y1 - p.y0)
		p.r0, p.r1 = p.r0 + (y0 - p.y0) * k, p.r0 + (y1 - p.y0) * k
	}
	p.y0, p.y1 = y0, y1
	p.auto_y = false
}

// Screen points of a trace, min/max per pixel column when there are many.
@(private = "file")
trace_points :: proc(w: ^Wave_View, ys: []f64, pr: Rect, y0, y1: f64) -> []rl.Vector2 {
	xs := w.x
	n := min(len(xs), len(ys))
	a, b := xv(w, w.x0), xv(w, w.x1)
	sx := f64(pr.w) / (b - a) if b != a else 1
	sy := f64(pr.h) / (y1 - y0) if y1 != y0 else 1
	X :: proc(w: ^Wave_View, x, a, sx: f64, pr: Rect) -> f32 {return pr.x + f32((xv(w, x) - a) * sx)}
	Y :: proc(y, y0, sy: f64, pr: Rect) -> f32 {
		v := f64(pr.y + pr.h) - (y - y0) * sy
		return f32(clamp(v, -1e5, 1e5))
	}
	out := make([dynamic]rl.Vector2, 0, min(n, int(pr.w) * 4 + 8), context.temp_allocator)
	// visible index range (+ one each side)
	i0, i1 := 0, n - 1
	monotonic := n > 1 && xs[n - 1] >= xs[0]
	if monotonic {
		for i0 < n - 1 && xs[i0 + 1] < w.x0 do i0 += 1
		for i1 > 0 && xs[i1 - 1] > w.x1 do i1 -= 1
	}
	if i1 < i0 do return out[:]
	if !S.w_decimate || (i1 - i0) < int(pr.w) * 3 || !monotonic {
		for i in i0 ..= i1 {
			if math.is_nan(ys[i]) do continue
			append(&out, rl.Vector2{X(w, xs[i], a, sx, pr), Y(ys[i], y0, sy, pr)})
		}
		return out[:]
	}
	col: f64 = -1e9
	mn, mx: f64
	first, last: f64
	flush :: proc(out: ^[dynamic]rl.Vector2, cx: f32, first, mn, mx, last: f64, y0, sy: f64, pr: Rect) {
		Y :: proc(y, y0, sy: f64, pr: Rect) -> f32 {return f32(clamp(f64(pr.y + pr.h) - (y - y0) * sy, -1e5, 1e5))}
		append(out, rl.Vector2{cx, Y(first, y0, sy, pr)})
		if first < last {
			append(out, rl.Vector2{cx, Y(mn, y0, sy, pr)}, rl.Vector2{cx, Y(mx, y0, sy, pr)})
		} else {
			append(out, rl.Vector2{cx, Y(mx, y0, sy, pr)}, rl.Vector2{cx, Y(mn, y0, sy, pr)})
		}
		append(out, rl.Vector2{cx, Y(last, y0, sy, pr)})
	}
	cx: f32
	for i in i0 ..= i1 {
		y := ys[i]
		if math.is_nan(y) do continue
		px := X(w, xs[i], a, sx, pr)
		c := math.floor(f64(px))
		if c != col {
			if col > -1e9 do flush(&out, cx, first, mn, mx, last, y0, sy, pr)
			col = c
			cx = f32(c) + 0.5
			mn, mx, first = y, y, y
		}
		mn = min(mn, y)
		mx = max(mx, y)
		last = y
	}
	if col > -1e9 do flush(&out, cx, first, mn, mx, last, y0, sy, pr)
	return out[:]
}

ticks_lin :: proc(lo, hi: f64, n: int) -> []f64 {
	out := make([dynamic]f64, context.temp_allocator)
	st := nice_step(hi - lo, n)
	v := math.ceil(lo / st) * st
	for v <= hi + st * 1e-9 && len(out) < 100 {
		append(&out, 0 if abs(v) < st * 1e-9 else v)
		v += st
	}
	return out[:]
}

draw_waves :: proc(d: ^Doc, r: Rect) {
	w := &d.wave
	if w.dirty && d.run.state != .Running do wave_eval(w, d)
	fill(r, th.w_bg)
	push_clip(r)
	defer pop_clip()
	fsz := S.w_font_size * ui_scale
	// header: analysis choice and buttons
	hdr := Rect{r.x, r.y, r.w, fsz + 12}
	body := Rect{r.x, r.y + hdr.h, r.w, r.h - hdr.h}
	draw_wave_header(d, hdr)
	if w.table != TABLE_NONE {
		rows := wave_table_rows(&d.run, w.table)
		if len(rows) > 0 {
			draw_meas_table(rows, body, fsz)
			return
		}
	}
	if len(w.panes) == 0 do append(&w.panes, Pane{auto_y = true})
	if wave_trace_count(w) == 0 {
		msg := "Run the simulation (F5), then click on wires and parts to see their waveforms."
		if d.run.state == .Done do msg = "Click a wire for its voltage, a part for its current. Drag between two wires for a difference."
		if d.run.state == .Running do msg = "Simulating …"
		text_in(body, msg, th.w_text, 1, fsz * 1.1)
		w.panes[0].rect = body
		wave_mouse_pane = -1
		return
	}
	wave_auto_x(w)
	bode := w.complex && S.w_ac_display == "bode"
	lm := fsz * 5.2
	rm := fsz * 4.2 if bode else fsz * 1.2
	for &p in w.panes do if pane_axes(w, &p).dual do rm = fsz * 4.2
	bm := fsz * 2.2
	np := len(w.panes)
	ph := (body.h - bm) / f32(np)
	over_any := hover(body)
	m := ui.mouse
	wave_mouse_pane = -1
	for pi in 0 ..< np {
		p := &w.panes[pi]
		// a spectrum pane draws on its own frequency axis
		wave_axis_swap(w, pi)
		defer wave_axis_swap(w, pi)
		if p.fft != nil do wave_auto_x(w)
		pr := Rect{body.x, body.y + f32(pi) * ph, body.w, ph}
		leg_h: f32 = fsz + 8 if S.w_legend else 4
		plot := Rect{pr.x + lm, pr.y + leg_h, pr.w - lm - rm, ph - leg_h - 6}
		// x labels under every pane whose axis differs from the next one's (the last pane's
		// go into the bottom margin)
		x_labels := pi == np - 1 || p.fft != nil || w.panes[pi + 1].fft != nil
		if pi < np - 1 && x_labels do plot.h -= fsz + 6
		if plot.w < 20 || plot.h < 10 do continue
		p.rect = plot
		has_phase := false
		for t in p.traces do if t.ph != nil && !t.hidden do has_phase = true
		// y range
		axes := pane_axes(w, p)
		if p.auto_y || p.y1 <= p.y0 || (axes.dual && p.r1 <= p.r0) {
			lo, hi := math.INF_F64, -math.INF_F64
			rlo, rhi := math.INF_F64, -math.INF_F64
			plo, phi := math.INF_F64, -math.INF_F64
			for t in p.traces {
				if t.hidden || t.y == nil do continue
				if a, b, ok := data_range(w.x, t.y, w.x0, w.x1); ok {
					if axes.dual && t.unit == axes.right {rlo = min(rlo, a); rhi = max(rhi, b)}
					else {lo = min(lo, a); hi = max(hi, b)}
				}
				if t.ph != nil {
					if a, b, ok := data_range(w.x, t.ph, w.x0, w.x1); ok {plo = min(plo, a); phi = max(phi, b)}
				}
			}
			if lo > hi {lo, hi = -1, 1}
			// spectra in dB: the top 120 dB, not the numerical noise floor far below
			if p.fft != nil && p.fft.db && S.w_fft_db_range > 0 do lo = max(lo, hi - S.w_fft_db_range)
			p.y0, p.y1 = pad_range(lo, hi)
			if rlo > rhi {rlo, rhi = -1, 1}
			p.r0, p.r1 = pad_range(rlo, rhi)
			if plo > phi {plo, phi = -180, 180}
			// phase on multiples of 45°
			p.p0 = math.floor(plo / 45) * 45
			p.p1 = math.ceil(phi / 45) * 45
			if p.p1 - p.p0 < 45 do p.p1 = p.p0 + 45
		}
		fill(plot, th.w_plot)
		// grid + y labels
		ny := max(2, int(plot.h / (fsz * 3)))
		yt := ticks_lin(p.y0, p.y1, ny)
		// with two axes each one's labels take the colour of its first trace
		lcol, rcol := th.w_text, th.w_text
		if axes.dual {
			for t in p.traces do if !t.hidden && t.y != nil && t.unit == axes.left {lcol = trace_color(t.color); break}
			for t in p.traces do if !t.hidden && t.y != nil && t.unit == axes.right {rcol = trace_color(t.color); break}
		}
		for y in yt {
			sy := y_to_scr(plot, y, p.y0, p.y1)
			if S.w_grid do grid_line(plot.x, sy, plot.x + plot.w, sy)
			lab := fmt_eng(y, "" if axes.mixed else axes.left, 3)
			draw_text(lab, plot.x - text_w(lab, fsz) - 6, sy - fsz / 2, lcol, fsz)
		}
		if axes.dual {
			for y in ticks_lin(p.r0, p.r1, ny) {
				sy := y_to_scr(plot, y, p.r0, p.r1)
				lab := fmt_eng(y, axes.right, 3)
				draw_text(lab, plot.x + plot.w + 6, sy - fsz / 2, rcol, fsz)
			}
		}
		if bode && has_phase {
			step := 45.0
			if (p.p1 - p.p0) / step > 8 do step = 90
			for v := p.p0; v <= p.p1 + 1e-9; v += step {
				sy := plot.y + plot.h - f32((v - p.p0) / (p.p1 - p.p0)) * plot.h
				draw_text(fmt.tprintf("%.0f°", v), plot.x + plot.w + 6, sy - fsz / 2, th.w_text, fsz)
			}
		}
		// x grid
		xticks := x_ticks(w, plot, fsz)
		for xt in xticks {
			sx := x_to_scr(w, plot, xt.x)
			if S.w_grid || xt.major do if sx > plot.x + 1 && sx < plot.x + plot.w - 1 {
				if xt.major do grid_line(sx, plot.y, sx, plot.y + plot.h)
				else if S.w_minor_grid do line(sx, plot.y, sx, plot.y + plot.h, alpha(th.w_grid, th.w_grid[3] / 2), 1)
			}
			if x_labels && xt.major {
				lab := fmt_eng(xt.x, w.x_unit, 3)
				draw_text(lab, sx - text_w(lab, fsz) / 2, plot.y + plot.h + 6, th.w_text, fsz)
			}
		}
		stroke(plot, th.w_axis, 1)
		// traces
		push_clip(plot)
		lw := S.w_line_width // screen pixels, not scaled: thin clean traces as in zapped
		for &t, ti in p.traces {
			if t.hidden || t.y == nil do continue
			col := rlc(trace_color(t.color))
			wid := lw
			if w.sel.pane == pi && w.sel.trace == ti do wid = S.w_line_hover
			ty0, ty1 := trace_y_range(p, axes, t)
			pts := trace_points(w, t.y, plot, ty0, ty1)
			if len(pts) >= 2 do rl.DrawSplineLinear(raw_data(pts), i32(len(pts)), wid, col)
			else if len(pts) == 1 do rl.DrawCircleV(pts[0], wid, col)
			if t.ph != nil && bode {
				pp := trace_points(w, t.ph, plot, p.p0, p.p1)
				if S.w_phase_dashed do dash_line(pp, wid * 0.8, col)
				else if len(pp) >= 2 do rl.DrawSplineLinear(raw_data(pp), i32(len(pp)), wid * 0.8, col)
			}
		}
		pop_clip()
		// legend
		if S.w_legend {
			lr := Rect{pr.x + lm, pr.y + 2, plot.w, leg_h - 2}
			if f := p.fft; f != nil && f.n > 0 {
				info := fmt.tprintf("FFT %s … %s · %s · Δf %s · %d points", fmt_eng(f.w0, "s", 4), fmt_eng(f.w1, "s", 4), FFT_WINDOW_NAMES[f.window], fmt_eng(f.df, "Hz", 3), f.n)
				iw := text_w(info, fsz)
				if iw < lr.w * 0.6 {
					draw_text(info, lr.x + lr.w - iw, lr.y + (lr.h - fsz) / 2, th.muted, fsz)
					lr.w -= iw + 12
				}
			}
			draw_legend(w, pi, lr, fsz)
		}
		// markers
		for mk in w.markers {
			if mk.pane != pi || mk.trace < 0 || mk.trace >= len(p.traces) do continue
			t := &p.traces[mk.trace]
			if t.y == nil do continue
			y := interp(w.x, t.y, mk.x)
			sx := x_to_scr(w, plot, mk.x)
			my0, my1 := trace_y_range(p, axes, t^)
			sy := y_to_scr(plot, y, my0, my1)
			if sx < plot.x || sx > plot.x + plot.w do continue
			col := trace_color(t.color)
			rl.DrawCircleV({sx, sy}, S.w_marker_radius * ui_scale, rlc(th.w_marker))
			rl.DrawCircleV({sx, sy}, S.w_marker_radius * ui_scale * 0.55, rlc(col))
			lab := fmt.tprintf("%s, %s", fmt_eng(mk.x, w.x_unit, 4), fmt_eng(y, t.unit, 4))
			lw2 := text_w(lab, fsz)
			lx := sx + 8
			if lx + lw2 > plot.x + plot.w do lx = sx - 8 - lw2
			fill_round({lx - 3, sy - fsz - 8, lw2 + 6, fsz + 4}, alpha(th.w_readout, 220), 3)
			draw_text(lab, lx, sy - fsz - 6, th.w_text, fsz)
		}
		// cursors
		for k in 0 ..< 2 {
			if math.is_nan(w.cursors[k].x) && w.cursors[k].pane == pi && len(w.x) > 0 {
				a, b := xv(w, w.x0), xv(w, w.x1)
				w.cursors[k].x = xi(w, a + (b - a) * (0.33 if k == 0 else 0.66))
			}
			c := w.cursors[k]
			if !c.on || c.pane != pi do continue
			sx := x_to_scr(w, plot, c.x)
			if sx < plot.x || sx > plot.x + plot.w do continue
			col := th.w_cursor1 if k == 0 else th.w_cursor2
			line(sx, plot.y, sx, plot.y + plot.h, col, 1.5 * ui_scale)
			draw_text(fmt.tprintf("%d", k + 1), sx + 3, plot.y + 2, col, fsz)
			if c.trace >= 0 && c.trace < len(p.traces) && p.traces[c.trace].y != nil {
				y := interp(w.x, p.traces[c.trace].y, c.x)
				cy0, cy1 := trace_y_range(p, axes, p.traces[c.trace])
				sy := y_to_scr(plot, y, cy0, cy1)
				line(plot.x, sy, plot.x + plot.w, sy, alpha(col, 110), 1)
				rl.DrawCircleLinesV({sx, sy}, 5 * ui_scale, rlc(col))
			}
		}
		// mouse
		if over_any && r_contains(plot, m) {
			wave_mouse_pane = pi
			wave_mouse_x = scr_to_x(w, plot, m.x)
		}
	}
	// cursor readout
	if w.cursors[0].on || w.cursors[1].on do draw_cursor_box(w, body, fsz)
	wave_interact(d, w)
}

@(private = "file")
grid_line :: proc(x0, y0, x1, y1: f32) {
	col := th.w_grid
	switch S.w_grid_style {
	case "solid":
		line(x0, y0, x1, y1, col, 1)
	case "dotted":
		dash :: 2
		if x0 == x1 {for y := y0; y < y1; y += 5 do fill({x0, y, 1, 1.4}, col)}
		else {for x := x0; x < x1; x += 5 do fill({x, y0, 1.4, 1}, col)}
	case:
		if x0 == x1 {for y := y0; y < y1; y += 8 do fill({x0, y, 1, min(4, y1 - y)}, col)}
		else {for x := x0; x < x1; x += 8 do fill({x, y0, min(4, x1 - x), 1}, col)}
	}
}

X_Tick :: struct {
	x:     f64,
	major: bool,
}

// The x range when it follows the data (log axes start at the first positive x: a
// spectrum's DC bin is at 0 Hz).
wave_auto_x :: proc(w: ^Wave_View) {
	if !w.auto_x && w.x1 > w.x0 do return
	if len(w.x) == 0 {
		w.x0, w.x1 = 0, 1
		return
	}
	lo, hi := w.x[0], w.x[len(w.x) - 1]
	if hi < lo do lo, hi = hi, lo
	if w.log_x && lo <= 0 {
		for x in w.x do if x > 0 {lo = x; break}
		if lo <= 0 do lo = hi / 1e3
	}
	if hi <= lo do hi = lo + 1 if !w.log_x else lo * 10
	w.x0, w.x1 = lo, hi
}

x_to_scr :: proc(w: ^Wave_View, plot: Rect, x: f64) -> f32 {
	a, b := xv(w, w.x0), xv(w, w.x1)
	if b == a do return plot.x
	return plot.x + f32((xv(w, x) - a) / (b - a)) * plot.w
}

scr_to_x :: proc(w: ^Wave_View, plot: Rect, sx: f32) -> f64 {
	a, b := xv(w, w.x0), xv(w, w.x1)
	return xi(w, a + f64((sx - plot.x) / plot.w) * (b - a))
}

@(private = "file")
x_ticks :: proc(w: ^Wave_View, plot: Rect, fsz: f32) -> []X_Tick {
	out := make([dynamic]X_Tick, context.temp_allocator)
	if w.log_x {
		d0 := math.floor(math.log10(max(w.x0, 1e-300)))
		d1 := math.ceil(math.log10(max(w.x1, 1e-300)))
		decades := d1 - d0
		for e := d0; e <= d1; e += 1 {
			base := math.pow(10, e)
			for k in 1 ..= 9 {
				x := base * f64(k)
				if x < w.x0 * 0.999 || x > w.x1 * 1.001 do continue
				major := k == 1 || (decades <= 2 && (k == 2 || k == 5))
				append(&out, X_Tick{x, major})
			}
		}
		return out[:]
	}
	n := max(2, int(plot.w / (fsz * 7)))
	for x in ticks_lin(w.x0, w.x1, n) do append(&out, X_Tick{x, true})
	return out[:]
}

@(private = "file")
draw_legend :: proc(w: ^Wave_View, pi: int, r: Rect, fsz: f32) {
	p := &w.panes[pi]
	axes := pane_axes(w, p)
	x := r.x
	for &t, ti in p.traces {
		lab := t.expr
		if axes.mixed && len(t.unit) > 0 do lab = tcat(lab, " [", t.unit, "]")
		if len(t.err) > 0 do lab = tcat(t.expr, "  – ", t.err)
		tw := text_w(lab, fsz) + 22
		lr := Rect{x, r.y, tw, r.h}
		col := trace_color(t.color)
		sel := w.sel.pane == pi && w.sel.trace == ti
		h := hover(lr)
		if sel do fill_round(lr, alpha(col, 50), 3)
		else if h do fill_round(lr, alpha(th.w_text, 25), 3)
		fill({x + 4, r.y + r.h / 2 - 1.5, 12, 3}, col if !t.hidden else th.muted)
		draw_text(lab, x + 20, r.y + (r.h - fsz) / 2, (th.err if len(t.err) > 0 else col) if !t.hidden else th.muted, fsz)
		if h {
			ui.hot = id_of(tcat("leg", itoa(pi), itoa(ti)))
			ui.cursor = .POINTING_HAND
			tooltip(ui.hot, "Click: select · Double-click: edit · Middle-click: hide · Right-click: menu")
			if ui.pressed[0] {
				w.sel = {pi, ti}
				w.active = pi
				if ui.double do dialog_trace(doc(), pi, ti)
			}
			if ui.pressed[2] do t.hidden = !t.hidden
			if ui.pressed[1] {
				w.sel = {pi, ti}
				legend_menu_sel = {pi, ti}
				fft_item := "FFT" if wave_can_fft(w, pi) else "~FFT"
				open_menu("wave.leg", ui.mouse.x, ui.mouse.y, {"Edit expression…", "Hide / show", "Move to a new pane", "Cursor 1 on this trace", "Cursor 2 on this trace", "-", "Remove", "-", fft_item})
			}
		}
		x += tw + 6
		if x > r.x + r.w do break
	}
}

legend_menu_sel: Wave_Sel

@(private = "file")
draw_cursor_box :: proc(w: ^Wave_View, body: Rect, fsz: f32) {
	lines := make([dynamic]string, context.temp_allocator)
	vals: [2][2]f64
	have: [2]bool
	units: [2]string
	x_unit := w.x_unit
	for k in 0 ..< 2 {
		c := w.cursors[k]
		if !c.on do continue
		// a cursor in a spectrum pane reads on that pane's frequency axis
		wave_axis_swap(w, c.pane)
		defer wave_axis_swap(w, c.pane)
		x_unit = w.x_unit
		y := math.nan_f64()
		name := ""
		if c.pane >= 0 && c.pane < len(w.panes) && c.trace >= 0 && c.trace < len(w.panes[c.pane].traces) {
			t := &w.panes[c.pane].traces[c.trace]
			if t.y != nil {
				y = interp(w.x, t.y, c.x)
				units[k] = t.unit
				name = t.expr
				if t.ph != nil && S.w_ac_display == "bode" {
					ph := interp(w.x, t.ph, c.x)
					append(&lines, fmt.tprintf("Cursor %d  %s:  %s   %s,  %.2f°", k + 1, name, fmt_eng(c.x, w.x_unit, 5), fmt_eng(y, t.unit, 5), ph))
					vals[k] = {c.x, y}
					have[k] = true
					continue
				}
			}
		}
		append(&lines, fmt.tprintf("Cursor %d  %s:  %s   %s", k + 1, name, fmt_eng(c.x, w.x_unit, 5), fmt_eng(y, units[k], 5)))
		vals[k] = {c.x, y}
		have[k] = true
	}
	// differences only between cursors on the same axis
	same_axis := w.cursors[0].pane == w.cursors[1].pane || (!pane_is_fft(w, w.cursors[0].pane) && !pane_is_fft(w, w.cursors[1].pane))
	if have[0] && have[1] && same_axis {
		dx := vals[1][0] - vals[0][0]
		dy := vals[1][1] - vals[0][1]
		unit := units[0] if units[0] == units[1] else ""
		append(&lines, fmt.tprintf("Δx %s   Δy %s", fmt_eng(dx, x_unit, 5), fmt_eng(dy, unit, 5)))
		if dx != 0 {
			su := unit_div(unit, x_unit) if len(unit) > 0 && len(x_unit) > 0 else ""
			append(&lines, fmt.tprintf("slope %s   1/Δx %s", fmt_eng(dy / dx, su, 4), fmt_eng(1 / abs(dx), unit_div("", x_unit), 4)))
		}
	}
	if S.w_cursor_box != true {
		status(strings.join(lines[:], "   |   ", context.temp_allocator))
		return
	}
	bw: f32 = 0
	for l in lines do bw = max(bw, text_w(l, fsz))
	bw += 16
	bh := f32(len(lines)) * (fsz + 4) + 10
	br := Rect{body.x + body.w - bw - 12, body.y + body.h - bh - fsz * 2.6, bw, bh}
	fill_round(br, alpha(th.w_readout, 235), 4)
	stroke_round(br, th.w_readout_border, 4)
	for l, i in lines {
		col := th.w_text
		if i == 0 && w.cursors[0].on do col = th.w_cursor1
		else if (i == 1 && w.cursors[0].on || i == 0 && !w.cursors[0].on) && w.cursors[1].on do col = th.w_cursor2
		draw_text(l, br.x + 8, br.y + 5 + f32(i) * (fsz + 4), col, fsz)
	}
}

@(private = "file")
// The rows of a table: the .meas results, or the one-point results of the run.
wave_table_rows :: proc(r: ^Run, table: int) -> []Meas_Row {
	if table == TABLE_MEAS do return r.meas_rows[:]
	if table == TABLE_VALUES do return wave_value_rows(r)
	return nil
}

// One row per value of each one-point plot (an operating point, the integrated noise).
wave_value_rows :: proc(r: ^Run) -> []Meas_Row {
	out := make([dynamic]Meas_Row, context.temp_allocator)
	for &p in r.plots {
		if plot_listed(&p) do continue
		for v in p.vecs do if len(v.re) > 0 {
			append(&out, Meas_Row{name = v.name, measure = "value", result = fmt_eng(v.re[0], v.unit, 5), analysis = p.name})
		}
	}
	return out[:]
}

// A table: one row per result (.meas or one-point).
draw_meas_table :: proc(rows: []Meas_Row, body: Rect, fsz: f32) {
	heads := [4]string{"Name", "Measurement", "Result", "Analysis"}
	rh := fsz + 8
	cw: [4]f32
	for h, c in heads do cw[c] = text_w(h, fsz)
	for row in rows {
		cells := [4]string{row.name, row.measure, row.result, row.analysis}
		for s, c in cells do cw[c] = max(cw[c], text_w(s, fsz))
	}
	for c in 0 ..< 4 do cw[c] += 24
	y := body.y + 8
	x := body.x + 8
	for h, c in heads {
		draw_text(h, x, y, th.muted, fsz)
		x += cw[c]
	}
	for row in rows {
		y += rh
		cells := [4]string{row.name, row.measure, row.result, row.analysis}
		x = body.x + 8
		for s, c in cells {
			draw_text(s, x, y, th.w_text, fsz)
			x += cw[c]
		}
	}
}

draw_wave_header :: proc(d: ^Doc, r: Rect) {
	w := &d.wave
	fill(r, mix(th.w_bg, th.bar, 0.6))
	line(r.x, r.y + r.h - 1, r.x + r.w, r.y + r.h - 1, th.border)
	b := r_inset(r, 2)
	fsz := S.w_font_size * ui_scale
	// analysis selector
	listed := wave_listed_plots(&d.run)
	names := make([dynamic]string, context.temp_allocator)
	sel := 0
	for pi, k in listed {
		p := &d.run.plots[pi]
		n := p.name
		if len(p.file) > 0 && len(d.run.plots) > 1 do n = tcat(p.name, " (", base_name(p.file), ")")
		append(&names, n)
		if w.table == TABLE_NONE && pi == w.plot_idx do sel = k
	}
	// the tables, after the plots
	kinds := make([dynamic]int, context.temp_allocator)
	if len(d.run.meas_rows) > 0 {
		append(&names, "Measurements")
		append(&kinds, TABLE_MEAS)
	}
	if len(wave_value_rows(&d.run)) > 0 {
		append(&names, "Values")
		append(&kinds, TABLE_VALUES)
	}
	if w.table != TABLE_NONE do for kind, k in kinds do if kind == w.table do sel = len(listed) + k
	if len(names) > 0 {
		cr := cut_left(&b, min(300 * ui_scale, b.w / 2))
		if combo("wave.plot", cr, names[:], &sel) {
			if sel >= len(listed) {
				w.table = kinds[sel - len(listed)]
			} else {
				w.table = TABLE_NONE
				w.plot_idx = listed[sel]
				set_str(&w.plot_kind, plot_kind(&d.run.plots[w.plot_idx]))
				w.dirty = true
				w.auto_x = true
				for &p in w.panes do p.auto_y = true
			}
		}
		cut_left(&b, 6)
	} else {
		text_in(cut_left(&b, 200 * ui_scale), "no results yet", th.muted, 0, fsz)
	}
	tbw :: proc(b: ^Rect, id, label, tip: string, sel := false) -> bool {
		w := text_w(label) + 16
		r := cut_right(b, w)
		cut_right(b, 2)
		return tool_button(id, r, label, true, sel, tip)
	}
	if cur_popout != nil {
		if tbw(&b, "wave.dock", "Dock", "Put the waveforms back into the main window (or close this window)") do run_action("wave/pop-out")
		fs_label := "Exit full screen" if cur_popout.fullscreen else "Full screen"
		if tbw(&b, "wave.full", fs_label, tcat(fs_label, " (", action_keys_text("view/full-screen"), ")")) do run_action("view/full-screen")
	} else {
		if tbw(&b, "wave.popout", "Pop out", tcat("Waveforms in their own window, for another monitor or full screen (", action_keys_text("wave/pop-out"), ")")) do run_action("wave/pop-out")
	}
	cut_right(&b, 8)
	if tbw(&b, "wave.fit", "Fit", "Show everything (double-click the plot)") do wave_fit(w)
	if tbw(&b, "wave.back", "Back", "Previous zoom (Backspace)") do wave_zoom_back(w)
	if tbw(&b, "wave.c2", "C2", "Cursor 2 (key 2)", w.cursors[1].on) do wave_toggle_cursor(w, 1)
	if tbw(&b, "wave.c1", "C1", "Cursor 1 (key 1)", w.cursors[0].on) do wave_toggle_cursor(w, 0)
	if tbw(&b, "wave.pane", "+ Pane", "Add a plot pane (new probes go to the selected pane)") do wave_add_pane(w)
	if tbw(&b, "wave.add", "+ Trace", "Add a trace by expression: V(out), I(R1), V(a,b), db(V(out)), V(out)*I(R1) …") do dialog_trace(d, -1, -1)
	if w.complex {
		modes := [?]string{"bode", "db", "magnitude", "phase", "real-imag"}
		labels := [?]string{"Bode", "dB", "Magnitude", "Phase", "Real"}
		k := 0
		for m, i in modes do if m == S.w_ac_display do k = i
		cr := cut_right(&b, 110 * ui_scale)
		if combo("wave.acmode", cr, labels[:], &k) {
			set_str(&S.w_ac_display, modes[k])
			w.dirty = true
			for &p in w.panes do p.auto_y = true
		}
	}
}

@(private = "file")
wave_interact :: proc(d: ^Doc, w: ^Wave_View) {
	m := ui.mouse
	pi := wave_mouse_pane
	if idx := menu_result("wave.leg"); idx >= 0 {
		s := legend_menu_sel
		if s.pane < len(w.panes) && s.trace < len(w.panes[s.pane].traces) {
			t := &w.panes[s.pane].traces[s.trace]
			switch idx {
			case 0: dialog_trace(d, s.pane, s.trace)
			case 1: t.hidden = !t.hidden
			case 2:
				e := strings.clone(t.expr, context.temp_allocator)
				w.sel = s
				wave_delete_selected(w)
				append(&w.panes, Pane{auto_y = true})
				w.active = len(w.panes) - 1
				wave_add_trace(w, e, false)
			case 3, 4:
				k := idx - 3
				c := &w.cursors[k]
				if !c.on || c.pane != s.pane {
					wave_axis_swap(w, s.pane)
					a, b := xv(w, w.x0), xv(w, w.x1)
					c.x = xi(w, a + (b - a) * (0.33 if k == 0 else 0.66))
					wave_axis_swap(w, s.pane)
				}
				c.on = true
				c.pane = s.pane
				c.trace = s.trace
			case 6:
				w.sel = s
				wave_delete_selected(w)
			case 8:
				if wave_can_fft(w, s.pane) do wave_add_fft(w, t.expr)
			}
		}
	}
	if idx := menu_result("wave.dbl"); idx >= 0 {
		switch idx {
		case 0, 1, 2: wave_place(w, idx, wave_ctx_pane, wave_ctx_trace, wave_ctx_x)
		case 4: wave_fit(w)
		}
	}
	if idx := menu_result("wave.ctx"); idx >= 0 {
		switch idx {
		case 0: wave_fit(w)
		case 1: wave_zoom_back(w)
		case 2: wave_add_marker_at_mouse_at(w, wave_ctx_pane, wave_ctx_x)
		case 3: wave_toggle_cursor(w, 0)
		case 4: wave_toggle_cursor(w, 1)
		case 6: dialog_trace(d, -1, -1)
		case 7: wave_add_pane(w)
		case 8: if len(w.markers) > 0 do clear(&w.markers)
		case 10: wave_clear(w)
		case 11: dialog_open(.Export_CSV)
		case 13: // FFT of the trace under the mouse
			pn := wave_ctx_pane
			if wave_can_fft(w, pn) && wave_ctx_trace >= 0 && wave_ctx_trace < len(w.panes[pn].traces) {
				wave_add_fft(w, w.panes[pn].traces[wave_ctx_trace].expr)
			}
		case 14 ..= 22: // spectrum pane settings (see the menu below)
			if !pane_is_fft(w, wave_ctx_pane) do break
			p := &w.panes[wave_ctx_pane]
			f := p.fft
			switch idx {
			case 14 ..< 14 + len(FFT_WINDOWS): f.window = idx - 14
			case 20:
				f.ax.log_x = !f.ax.log_x
				f.ax.auto_x = true
			case 21: f.db = !f.db
			case 22: // the time window shown in the time-domain panes now
				f.t0, f.t1 = 0, 0
				if !w.auto_x do f.t0, f.t1 = w.x0, w.x1
			}
			p.auto_y = true
			w.dirty = true
		}
	}
	// the pane under the mouse works on its own axis (spectrum panes)
	wave_axis_swap(w, pi)
	// cursor drags
	near_cursor := -1
	if pi >= 0 {
		plot := w.panes[pi].rect
		for k in 0 ..< 2 {
			c := w.cursors[k]
			if !c.on || c.pane != pi do continue
			if abs(x_to_scr(w, plot, c.x) - m.x) < 5 * ui_scale do near_cursor = k
		}
	}
	if w.drag == .None && near_cursor >= 0 && pi >= 0 do ui.cursor = .RESIZE_EW
	if pi >= 0 && w.drag == .None && mouse_free() {
		plot := w.panes[pi].rect
		if ui.pressed[0] {
			w.active = pi
			if ui.double {
				// the trace nearest the mouse gets the marker / cursor
				tr := wave_trace_near(w, pi, m.y, 24 * ui_scale)
				if tr < 0 && w.sel.pane == pi do tr = w.sel.trace
				if tr < 0 && len(w.panes[pi].traces) > 0 do tr = 0
				wave_ctx_pane, wave_ctx_x, wave_ctx_trace = pi, wave_mouse_x, tr
				switch S.w_double_click {
				case "marker": wave_place(w, 0, pi, tr, wave_mouse_x)
				case "cursor": wave_place(w, 1 if w.cursors[0].on && !w.cursors[1].on else 2 if w.cursors[0].on else 1, pi, tr, wave_mouse_x)
				case "fit": wave_fit(w)
				case:
					name := ""
					if tr >= 0 do name = tcat("  (", w.panes[pi].traces[tr].expr, ")")
					open_menu("wave.dbl", m.x, m.y, {tcat("Marker here", name, "\tM"), "Cursor 1 here\t1", "Cursor 2 here\t2", "-", "Fit\tF"})
				}
			} else if near_cursor >= 0 {
				w.drag = .Cursor1 if near_cursor == 0 else .Cursor2
			} else {
				w.drag = .Zoom
				w.drag_start = m
				w.drag_pane = pi
				// click on a trace selects it
				if bt := wave_trace_near(w, pi, m.y, 8 * ui_scale); bt >= 0 do w.sel = {pi, bt}
			}
		}
		if ui.pressed[2] || (ui.pressed[0] && key_down(.SPACE)) {
			w.drag = .Pan
			w.drag_start = m
			w.drag_pane = pi
			w.drag_x0, w.drag_x1 = w.x0, w.x1
			w.drag_y0, w.drag_y1 = w.panes[pi].y0, w.panes[pi].y1
			wave_push_history(w)
		}
		if ui.pressed[1] {
			w.active = pi
			tr := wave_trace_near(w, pi, m.y, 24 * ui_scale)
			if tr < 0 && w.sel.pane == pi do tr = w.sel.trace
			if tr < 0 && len(w.panes[pi].traces) > 0 do tr = 0
			wave_ctx_pane, wave_ctx_x, wave_ctx_trace = pi, wave_mouse_x, tr
			items := make([dynamic]string, context.temp_allocator)
			append(&items, "Fit\tF", "Previous zoom\tBackspace", "Marker here\tM", "Cursor 1\t1", "Cursor 2\t2", "-", "Add trace…", "Add pane\tCtrl+P", "Remove markers", "-", "Remove all traces", "Export CSV…", "-")
			if f := w.panes[pi].fft; f != nil {
				ck :: proc(on: bool, s: string) -> string {return tcat("✓ " if on else "    ", s)}
				// 13: title, 14 … 18: windows, 19: separator, 20 … 22: see the menu results above
				append(&items, "~FFT window")
				for name, i in FFT_WINDOW_NAMES do append(&items, ck(f.window == i, name))
				append(&items, "-", ck(w.log_x, "Logarithmic frequency axis"), ck(f.db, "Amplitude in dB"), "FFT of the time range shown now")
			} else if wave_can_fft(w, pi) && tr >= 0 {
				append(&items, "FFT")
			} else {
				append(&items, "~FFT")
			}
			open_menu("wave.ctx", m.x, m.y, items[:])
		}
		// wheel: zoom x about the mouse (Ctrl: y, Shift: pan)
		if ui.wheel != 0 {
			f := math.pow(S.w_zoom_speed, -f64(ui.wheel))
			p := &w.panes[pi]
			if ui.ctrl {
				my := scr_to_y(plot, m.y, p.y0, p.y1)
				pane_set_y(p, my - (my - p.y0) * f, my + (p.y1 - my) * f)
			} else if ui.shift {
				a, b := xv(w, w.x0), xv(w, w.x1)
				sh := (b - a) * 0.1 * f64(ui.wheel)
				w.x0, w.x1 = xi(w, a - sh), xi(w, b - sh)
				w.auto_x = false
			} else {
				mx := xv(w, wave_mouse_x)
				a, b := xv(w, w.x0), xv(w, w.x1)
				w.x0 = xi(w, mx - (mx - a) * f)
				w.x1 = xi(w, mx + (b - mx) * f)
				w.auto_x = false
				for &q in w.panes do q.auto_y = true
			}
		}
	}
	wave_axis_swap(w, pi)
	switch w.drag {
	case .Zoom:
		pane := w.drag_pane
		if pane < 0 || pane >= len(w.panes) {w.drag = .None; break}
		wave_axis_swap(w, pane)
		defer wave_axis_swap(w, pane)
		plot := w.panes[pane].rect
		a := w.drag_start
		mm := [2]f32{clampf32(m.x, plot.x, plot.x + plot.w), clampf32(m.y, plot.y, plot.y + plot.h)}
		dx, dy := abs(mm.x - a.x), abs(mm.y - a.y)
		// a mostly horizontal drag zooms only x
		only_x := dy < 12 * ui_scale || dy < dx * 0.15
		zr := Rect{min(a.x, mm.x), plot.y if only_x else min(a.y, mm.y), dx, plot.h if only_x else dy}
		if dx > 4 {
			fill(zr, th.w_zoom_box)
			stroke(zr, alpha(th.w_text, 120), 1)
		}
		if !ui.down[0] {
			w.drag = .None
			if dx > 6 {
				wave_push_history(w)
				nx0 := scr_to_x(w, plot, zr.x)
				nx1 := scr_to_x(w, plot, zr.x + zr.w)
				w.x0, w.x1 = nx0, nx1
				w.auto_x = false
				p := &w.panes[pane]
				if !only_x {
					pane_set_y(p, scr_to_y(plot, zr.y + zr.h, p.y0, p.y1), scr_to_y(plot, zr.y, p.y0, p.y1))
				} else {
					for &q in w.panes do q.auto_y = true
				}
			} else if dx <= 3 && dy <= 3 {
				if w.sel.pane != pane do w.sel = {-1, -1}
			}
		}
	case .Pan:
		pane := w.drag_pane
		if pane >= len(w.panes) {w.drag = .None; break}
		wave_axis_swap(w, pane)
		defer wave_axis_swap(w, pane)
		plot := w.panes[pane].rect
		dd := m - w.drag_start
		a, b := xv(w, w.drag_x0), xv(w, w.drag_x1)
		sh := -f64(dd.x / plot.w) * (b - a)
		w.x0, w.x1 = xi(w, a + sh), xi(w, b + sh)
		w.auto_x = false
		p := &w.panes[pane]
		ys := f64(dd.y / plot.h) * (w.drag_y1 - w.drag_y0)
		pane_set_y(p, w.drag_y0 + ys, w.drag_y1 + ys)
		ui.cursor = .RESIZE_ALL
		if !ui.down[0] && !ui.down[2] do w.drag = .None
	case .Cursor1, .Cursor2:
		k := 0 if w.drag == .Cursor1 else 1
		c := &w.cursors[k]
		wave_axis_swap(w, c.pane)
		defer wave_axis_swap(w, c.pane)
		if c.pane < len(w.panes) {
			plot := w.panes[c.pane].rect
			c.x = scr_to_x(w, plot, clampf32(m.x, plot.x, plot.x + plot.w))
			// snap to a data point
			if S.w_snap && len(w.x) > 0 {
				best, bi := math.INF_F64, -1
				for x, i in w.x do if abs(x - c.x) < best {best = abs(x - c.x); bi = i}
				if bi >= 0 && abs(x_to_scr(w, plot, w.x[bi]) - m.x) < 4 do c.x = w.x[bi]
			}
		}
		ui.cursor = .RESIZE_EW
		if !ui.down[0] do w.drag = .None
	case .None:
	}
	// hover readout
	if pi >= 0 && w.drag == .None && S.w_hover_readout && mouse_free() && near_cursor < 0 {
		wave_axis_swap(w, pi)
		defer wave_axis_swap(w, pi)
		p := &w.panes[pi]
		plot := p.rect
		axes := pane_axes(w, p)
		line(m.x, plot.y, m.x, plot.y + plot.h, alpha(th.w_hover, 120), 1)
		sb := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&sb, "%s", fmt_eng(wave_mouse_x, w.x_unit, 5))
		n := 0
		for t in p.traces {
			if t.y == nil || t.hidden do continue
			if n >= S.w_max_tooltip do break
			y := interp(w.x, t.y, wave_mouse_x)
			hy0, hy1 := trace_y_range(p, axes, t)
			sy := y_to_scr(plot, y, hy0, hy1)
			if sy >= plot.y && sy <= plot.y + plot.h do rl.DrawCircleV({m.x, sy}, 3.5 * ui_scale, rlc(trace_color(t.color)))
			fmt.sbprintf(&sb, "\n%s = %s", t.expr, fmt_eng(y, t.unit, 5))
			if t.ph != nil && S.w_ac_display == "bode" do fmt.sbprintf(&sb, ", %.2f°", interp(w.x, t.ph, wave_mouse_x))
			n += 1
		}
		// the y value under the mouse
		my := scr_to_y(plot, m.y, p.y0, p.y1)
		fmt.sbprintf(&sb, "\n(mouse y %s", fmt_eng(my, "" if axes.mixed else axes.left, 4))
		if axes.dual do fmt.sbprintf(&sb, ", %s", fmt_eng(scr_to_y(plot, m.y, p.r0, p.r1), axes.right, 4))
		fmt.sbprintf(&sb, ")")
		ui.tip = strings.to_string(sb)
		if ui.tip_id != id_of("wave.hover") {
			ui.tip_id = id_of("wave.hover")
			ui.tip_since = ui.time - S.tooltip_delay
		}
	}
}

wave_ctx_pane: int
wave_ctx_x: f64
wave_ctx_trace := -1

// The visible trace of a pane whose curve passes nearest the screen height y at the mouse's x
// (within tol pixels), or -1.
wave_trace_near :: proc(w: ^Wave_View, pane: int, y: f32, tol: f32) -> int {
	if pane < 0 || pane >= len(w.panes) do return -1
	p := &w.panes[pane]
	plot := p.rect
	axes := pane_axes(w, p)
	best, bt := tol, -1
	for t, ti in p.traces {
		ty0, ty1 := trace_y_range(p, axes, t)
		if t.y == nil || t.hidden || ty1 == ty0 do continue
		v := interp(w.x, t.y, wave_mouse_x)
		sy := y_to_scr(plot, v, ty0, ty1)
		if abs(sy - y) < best {best = abs(sy - y); bt = ti}
	}
	return bt
}

// Puts a marker (what = 0) or cursor 1 / 2 (what = 1 / 2) on a trace at x.
wave_place :: proc(w: ^Wave_View, what: int, pane, trace: int, x: f64) {
	if pane < 0 || pane >= len(w.panes) || trace < 0 || trace >= len(w.panes[pane].traces) do return
	if what == 0 {
		append(&w.markers, Marker{pane = pane, trace = trace, x = x})
		return
	}
	c := &w.cursors[what - 1]
	c.on = true
	c.pane = pane
	c.trace = trace
	c.x = x
	w.sel = {pane, trace}
}

wave_add_marker_at_mouse_at :: proc(w: ^Wave_View, pane: int, x: f64) {
	if pane < 0 || pane >= len(w.panes) || len(w.panes[pane].traces) == 0 do return
	tr := w.sel.trace if w.sel.pane == pane && w.sel.trace >= 0 else 0
	append(&w.markers, Marker{pane = pane, trace = tr, x = x})
}

// ---------------------------------------------------------------------------
// Saved with the schematic: {:plot "tran" :panes [["V(out)" "I(R1)"] ["V(in)"]]}. A spectrum
// pane is a map: {:fft ["V(in)"] :t0 0 :t1 0 :window :hann :db true :log true}

wave_save_setup :: proc(w: ^Wave_View) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{:plot ")
	strings.write_string(&b, edn_quoted(w.plot_kind))
	strings.write_string(&b, " :panes [")
	for p, i in w.panes {
		if len(p.traces) == 0 do continue
		if i > 0 do strings.write_byte(&b, ' ')
		if p.fft != nil do strings.write_string(&b, "{:fft ")
		strings.write_byte(&b, '[')
		for t, k in p.traces {
			if k > 0 do strings.write_byte(&b, ' ')
			strings.write_string(&b, edn_quoted(t.expr))
		}
		strings.write_byte(&b, ']')
		if f := p.fft; f != nil {
			fmt.sbprintf(&b, " :t0 %.12g :t1 %.12g :window :%s :db %v :log %v}", f.t0, f.t1, FFT_WINDOWS[f.window], f.db, f.ax.log_x)
		}
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

wave_load_setup :: proc(w: ^Wave_View, text: string) {
	if len(strings.trim_space(text)) == 0 do return
	v, err := edn_parse(text, context.temp_allocator)
	if len(err) > 0 || v.kind != .Map do return
	wave_clear_panes(w)
	w.next_color = 0
	set_str(&w.plot_kind, edn_str(v, "plot"))
	if pv, ok := edn_get(v, "panes"); ok && edn_is_coll(pv) {
		for pane in pv.items {
			p := Pane{auto_y = true}
			list := pane
			if pane.kind == .Map {
				fl, has_fft := edn_get(pane, "fft")
				if !has_fft || !edn_is_coll(fl) do continue
				list = fl
				// what the file leaves out comes from settings.edn
				f := fft_pane_new()
				if t0, has := edn_get(pane, "t0"); has && edn_is_num(t0) do f.t0 = edn_num(t0)
				if t1, has := edn_get(pane, "t1"); has && edn_is_num(t1) do f.t1 = edn_num(t1)
				if k := fft_window_index(edn_str(pane, "window")); k >= 0 do f.window = k
				f.db = edn_bool(pane, "db", f.db)
				f.ax.log_x = edn_bool(pane, "log", f.ax.log_x)
				p.fft = f
			} else if !edn_is_coll(pane) do continue
			for t in list.items do if t.kind == .String {
				append(&p.traces, Trace{expr = strings.clone(t.s), color = w.next_color})
				w.next_color += 1
			}
			append(&w.panes, p)
		}
	}
	if len(w.panes) == 0 do append(&w.panes, Pane{auto_y = true})
	w.dirty = true
}

// CSV of the shown traces.
wave_export_csv :: proc(w: ^Wave_View, path: string) -> bool {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, edn_quoted(w.x_name))
	cols := make([dynamic][]f64, context.temp_allocator)
	// spectra have a frequency axis of their own: not in this table
	for p in w.panes do if p.fft == nil do for t in p.traces {
		if t.y == nil do continue
		fmt.sbprintf(&b, ",%s", edn_quoted(t.expr))
		append(&cols, t.y)
		if t.ph != nil {
			fmt.sbprintf(&b, ",%s", edn_quoted(tcat("ph(", t.expr, ")")))
			append(&cols, t.ph)
		}
	}
	strings.write_byte(&b, '\n')
	for x, i in w.x {
		fmt.sbprintf(&b, "%.12g", x)
		for c in cols do fmt.sbprintf(&b, ",%.12g", c[i] if i < len(c) else math.nan_f64())
		strings.write_byte(&b, '\n')
	}
	return write_text(path, strings.to_string(b))
}
