package spicy

import "core:fmt"
import "core:math"
import "core:strings"
import rl "vendor:raylib"

// Modal dialogs: files, part properties, labels, directives, the simulation command …

Dialog_State :: struct {
	kind:            Dialog_Kind,
	title:           string,
	text:            string, // message / viewer text
	// file browser
	dir:             string,
	name:            string,
	// part / label / text
	idx:             int,
	ref, value:      string,
	attr_keys:       [dynamic]string,
	attr_vals:       [dynamic]string,
	model_sel:       int,
	pinmap:          string,
	src_kind:        int,
	src_args:        [8]string,
	src_dc:          string,
	src_ac:          string,
	ni_vals:         [8]string, // the part's non-ideal values (nonideal_params)
	directive:       bool,
	label_at:        P,
	label_place_now: bool,
	// picker
	search:          string,
	pick:            int,
	// sim command
	sim_tab:         int,
	f:               [8]string,
	// trace
	pane, trace:     int,
	first_frame:     bool,
}

dialog_open :: proc(k: Dialog_Kind) {
	d := doc()
	dl := &app.dlg
	dl.kind = k
	dl.first_frame = true
	// a dialog asked for in a waveform window shows there; from the parts window, in the main one
	app.dlg_win = cur_popout.doc_id if cur_popout != nil && cur_popout.kind == .Waves else 0
	dl.pick = 0
	switch k {
	case .Open, .Save_As, .Export_Netlist, .Export_CSV, .Import_Model, .Pick_Program:
		start := pref_get("last-dir", "")
		if len(d.path) > 0 do start = dir_name(d.path)
		if k == .Pick_Program {
			// where the program is now, else the home folder
			start = home_dir()
			if dl.idx >= 0 && dl.idx < len(S.simulators) && len(S.simulators[dl.idx].command) > 0 {
				if p, ok := find_program(S.simulators[dl.idx].command[0]); ok do start = dir_name(p)
			}
		}
		if len(start) == 0 || !dir_exists(start) do start = cwd()
		set_str(&dl.dir, start)
		nm := ""
		stem := stem_name(d.path) if len(d.path) > 0 else fmt.tprintf("untitled-%d", d.id)
		#partial switch k {
		case .Save_As: nm = tcat(stem, ".edn")
		case .Export_Netlist: nm = tcat(stem, ".cir")
		case .Export_CSV: nm = tcat(stem, ".csv")
		}
		set_str(&dl.name, nm)
		focus_field("dlg.name")
	case .Part_Picker:
		set_str(&dl.search, "")
		focus_field("dlg.search")
	case .Label_Name:
		set_str(&dl.name, "")
		dl.idx = -1
		dl.label_place_now = false
		focus_field("dlg.label")
	case .Sim_Command:
		sim_cmd_load(d)
	case .Simulator_Pick:
		// the program of each simulator, editable
		for i in 0 ..< len(dl.f) do set_str(&dl.f[i], "")
		for s, i in S.simulators do if i < len(dl.f) && len(s.command) > 0 do set_str(&dl.f[i], s.command[0])
	case .Appearance:
		appearance_open()
	case .None, .Part_Edit, .Text_Edit, .Text_View, .Shortcuts, .Confirm_Close, .Message, .About, .Diagnostics, .Trace_Edit, .Import_Repair:
	}
}

message :: proc(title, text: string) {
	set_str(&app.dlg.title, title)
	set_str(&app.dlg.text, text)
	dialog_open(.Message)
}

show_text :: proc(title, text: string) {
	set_str(&app.dlg.title, title)
	set_str(&app.dlg.text, text)
	dialog_open(.Text_View)
}

show_netlist :: proc(d: ^Doc) {
	sim := doc_sim(d)
	if sim == nil do return
	nl := netlist_build(&d.sch, sim, len(d.path) > 0 ? base_name(d.path) : "untitled", dir_of(d.path))
	t := nl.text
	if len(nl.errors) > 0 do t = tcat("* ERRORS:\n* ", strings.join(nl.errors[:], "\n* ", context.temp_allocator), "\n\n", t)
	if len(nl.warnings) > 0 do t = tcat("* warnings:\n* ", strings.join(nl.warnings[:], "\n* ", context.temp_allocator), "\n\n", t)
	show_text(tcat("Netlist for ", sim.name), t)
}

show_log :: proc(d: ^Doc) {
	if len(d.run.log_text) == 0 {
		message("Simulator log", "Nothing yet: run the simulation first (F5).")
		return
	}
	show_text(tcat(d.run.sim_name, " log"), d.run.log_text)
}

dialog_part :: proc(d: ^Doc, ci: int) {
	dl := &app.dlg
	c := &d.sch.comps[ci]
	dl.idx = ci
	set_str(&dl.ref, c.ref)
	set_str(&dl.value, c.value)
	for s in dl.attr_keys do delete(s)
	for s in dl.attr_vals do delete(s)
	clear(&dl.attr_keys)
	clear(&dl.attr_vals)
	set_str(&dl.pinmap, comp_attr(c, "pinmap"))
	sym := symbol_find(c.sym)
	params := nonideal_params(sym)
	for &v, i in dl.ni_vals do set_str(&v, comp_attr(c, params[i].key) if i < len(params) else "")
	attrs: for a in c.attrs {
		if a.key == "pinmap" do continue // its own field
		for p in params do if p.key == a.key do continue attrs // the non-ideal section
		append(&dl.attr_keys, strings.clone(a.key))
		append(&dl.attr_vals, strings.clone(a.val))
	}
	is_src := sym != nil && sym.editor == "source"
	if is_src do source_parse(c.value)
	dl.model_sel = -1
	dialog_open(.Part_Edit)
	// a source has no value field: its value is made from the source editor's fields
	focus_field("dlg.src.dc" if is_src else "dlg.value")
}

dialog_label :: proc(d: ^Doc, fi: int) {
	dialog_open(.Label_Name)
	app.dlg.idx = fi
	set_str(&app.dlg.name, d.sch.flags[fi].name)
}

dialog_text :: proc(d: ^Doc, ti: int, directive: bool) {
	dl := &app.dlg
	dl.idx = ti
	dl.directive = directive
	set_str(&dl.text, d.sch.texts[ti].text if ti >= 0 else "")
	dialog_open(.Text_Edit)
	focus_field("dlg.textarea")
}

dialog_trace :: proc(d: ^Doc, pane, trace: int) {
	dl := &app.dlg
	dl.pane, dl.trace = pane, trace
	e := ""
	if pane >= 0 && pane < len(d.wave.panes) && trace >= 0 && trace < len(d.wave.panes[pane].traces) do e = d.wave.panes[pane].traces[trace].expr
	set_str(&dl.name, e)
	dialog_open(.Trace_Edit)
	focus_field("dlg.expr")
}

// ---------------------------------------------------------------------------
// Independent source editor

SRC_KINDS := [?]string{"DC", "PULSE", "SIN", "EXP", "PWL"}
SRC_ARGS := [?][]string {
	{},
	{"V1 (initial)", "V2 (pulsed)", "Tdelay", "Trise", "Tfall", "Ton", "Tperiod", "Ncycles"},
	{"Voffset", "Vamp", "Freq", "Tdelay", "Theta (damping)", "Phase"},
	{"V1", "V2", "Td1 (rise delay)", "Tau1", "Td2 (fall delay)", "Tau2"},
	{"Points: t1 v1 t2 v2 …"},
}

source_parse :: proc(v: string) {
	dl := &app.dlg
	dl.src_kind = 0
	for &a in dl.src_args do set_str(&a, "")
	set_str(&dl.src_dc, "")
	set_str(&dl.src_ac, "")
	toks := source_tokens(v)
	i := 0
	for i < len(toks) {
		t := toks[i]
		u := upper(t)
		switch {
		case u == "DC" && i + 1 < len(toks):
			set_str(&dl.src_dc, toks[i + 1])
			i += 2
			continue
		case u == "AC" && i + 1 < len(toks):
			ac := toks[i + 1]
			if i + 2 < len(toks) && is_number_token(toks[i + 2]) {
				ac = tcat(ac, " ", toks[i + 2])
				i += 1
			}
			set_str(&dl.src_ac, ac)
			i += 2
			continue
		case strings.contains(t, "("):
			p := strings.index_byte(t, '(')
			name := upper(strings.trim_space(t[:p]))
			inner := strings.trim_suffix(t[p + 1:], ")")
			for k, ki in SRC_KINDS do if k == name do dl.src_kind = ki
			if dl.src_kind == 4 {
				set_str(&dl.src_args[0], strings.trim_space(inner))
			} else {
				args := strings.fields(inner, context.temp_allocator)
				for a, ai in args do if ai < len(dl.src_args) do set_str(&dl.src_args[ai], a)
			}
		case:
			if len(dl.src_dc) == 0 do set_str(&dl.src_dc, t)
		}
		i += 1
	}
}

source_build :: proc() -> string {
	dl := &app.dlg
	b := strings.builder_make(context.temp_allocator)
	if len(dl.src_dc) > 0 || dl.src_kind == 0 {
		strings.write_string(&b, dl.src_dc if len(dl.src_dc) > 0 else "0")
	}
	if dl.src_kind > 0 {
		if strings.builder_len(b) > 0 do strings.write_byte(&b, ' ')
		strings.write_string(&b, SRC_KINDS[dl.src_kind])
		strings.write_byte(&b, '(')
		n := len(SRC_ARGS[dl.src_kind])
		last := -1
		for k in 0 ..< n do if len(strings.trim_space(dl.src_args[k])) > 0 do last = k
		for k in 0 ..= last {
			if k > 0 do strings.write_byte(&b, ' ')
			a := strings.trim_space(dl.src_args[k])
			strings.write_string(&b, a if len(a) > 0 else "0")
		}
		strings.write_byte(&b, ')')
	}
	if len(strings.trim_space(dl.src_ac)) > 0 {
		strings.write_string(&b, " AC ")
		strings.write_string(&b, strings.trim_space(dl.src_ac))
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Simulation command

ANALYSES := [?]string{"Transient", "AC sweep", "DC sweep", "Operating point"}

is_analysis_line :: proc(l: string) -> bool {
	t := lower(strings.trim_space(l))
	return strings.has_prefix(t, ".tran") || strings.has_prefix(t, ".ac") || strings.has_prefix(t, ".dc") || strings.has_prefix(t, ".op")
}

// The directive text and line that hold the analysis, or -1.
find_analysis :: proc(s: ^Schematic) -> (ti, li: int) {
	for t, i in s.texts {
		if !t.directive do continue
		for l, k in split_lines(t.text) do if is_analysis_line(l) do return i, k
	}
	return -1, -1
}

sim_cmd_load :: proc(d: ^Doc) {
	dl := &app.dlg
	for &f in dl.f do set_str(&f, "")
	dl.sim_tab = 0
	set_str(&dl.f[1], "1m")
	set_str(&dl.f[3], "dec")
	set_str(&dl.f[4], "100")
	set_str(&dl.f[5], "1")
	set_str(&dl.f[6], "1Meg")
	ti, li := find_analysis(&d.sch)
	if ti < 0 do return
	l := strings.trim_space(split_lines(d.sch.texts[ti].text)[li])
	tok := strings.fields(l, context.temp_allocator)
	cmd := lower(tok[0])
	args := tok[1:]
	switch {
	case strings.has_prefix(cmd, ".tran"):
		dl.sim_tab = 0
		// .tran [tstep] tstop [tstart [tmax]]
		if len(args) == 1 do set_str(&dl.f[1], args[0])
		if len(args) >= 2 {
			set_str(&dl.f[0], args[0]); set_str(&dl.f[1], args[1])
		}
		if len(args) >= 3 do set_str(&dl.f[2], args[2])
		if len(args) >= 4 do set_str(&dl.f[7], args[3])
	case strings.has_prefix(cmd, ".ac"):
		dl.sim_tab = 1
		if len(args) >= 4 {
			set_str(&dl.f[3], lower(args[0])); set_str(&dl.f[4], args[1]); set_str(&dl.f[5], args[2]); set_str(&dl.f[6], args[3])
		}
	case strings.has_prefix(cmd, ".dc"):
		dl.sim_tab = 2
		for a, i in args do if i < 4 do set_str(&dl.f[i], a)
	case strings.has_prefix(cmd, ".op"):
		dl.sim_tab = 3
	}
}

sim_cmd_build :: proc() -> string {
	dl := &app.dlg
	T :: proc(s: string) -> string {return strings.trim_space(s)}
	switch dl.sim_tab {
	case 0:
		if len(T(dl.f[0])) == 0 do return tcat(".tran ", T(dl.f[1]))
		s := tcat(".tran ", T(dl.f[0]), " ", T(dl.f[1]))
		if len(T(dl.f[2])) > 0 || len(T(dl.f[7])) > 0 do s = tcat(s, " ", T(dl.f[2]) if len(T(dl.f[2])) > 0 else "0")
		if len(T(dl.f[7])) > 0 do s = tcat(s, " ", T(dl.f[7]))
		return s
	case 1:
		return tcat(".ac ", T(dl.f[3]), " ", T(dl.f[4]), " ", T(dl.f[5]), " ", T(dl.f[6]))
	case 2:
		return tcat(".dc ", T(dl.f[0]), " ", T(dl.f[1]), " ", T(dl.f[2]), " ", T(dl.f[3]))
	}
	return ".op"
}

sim_cmd_apply :: proc(d: ^Doc) {
	cmd := sim_cmd_build()
	s := &d.sch
	ti, li := find_analysis(s)
	if ti >= 0 {
		doc_push_undo(d)
		lines := split_lines(s.texts[ti].text)
		out := make([dynamic]string, context.temp_allocator)
		for l, k in lines do append(&out, cmd if k == li else l)
		set_str(&s.texts[ti].text, strings.join(out[:], "\n", context.temp_allocator))
		status(tcat("simulation command: ", cmd))
		return
	}
	// no analysis yet: place the directive with the mouse
	tool_set(d, .Place)
	d.place_kind = .Text
	d.place_directive = true
	set_str(&d.place_text, cmd)
	status("click to place the simulation command")
}

// ---------------------------------------------------------------------------
// Drawing

@(private = "file")
dialog_frame :: proc(w, h: f32) -> (body: Rect) {
	sw, sh := screen_w(), screen_h()
	ww := min(w * ui_scale, sw - 40)
	hh := min(h * ui_scale, sh - 40)
	r := Rect{math_round((sw - ww) / 2), math_round((sh - hh) / 2), ww, hh}
	fill({0, 0, sw, sh}, {0, 0, 0, 90})
	fill_round({r.x + 4, r.y + 6, r.w, r.h}, th.shadow, 8)
	fill_round(r, th.panel, 8)
	stroke_round(r, th.border, 8)
	return r_inset(r, 16)
}

@(private = "file")
math_round :: proc(x: f32) -> f32 {return f32(int(x + 0.5))}

@(private = "file")
row :: proc(b: ^Rect) -> Rect {
	r := cut_top(b, fs() + 14)
	cut_top(b, 6)
	return r
}

@(private = "file")
label_col :: proc(r: ^Rect, text: string, w: f32 = 130) -> Rect {
	l := cut_left(r, w * ui_scale)
	text_in(l, text, th.muted, 0, 0, 0)
	return r^
}

@(private = "file")
title :: proc(b: ^Rect, t: string) {
	r := cut_top(b, fs(1.25) + 8)
	draw_text(t, r.x, r.y, th.fg, fs(1.25))
	cut_top(b, 6)
}

// OK / Cancel row at the bottom. Returns 1 for OK, -1 for cancel.
@(private = "file")
buttons :: proc(b: ^Rect, ok_label := "OK", cancel := true, ok_enabled := true) -> int {
	r := cut_bottom(b, fs() + 16)
	bw := max(text_w(ok_label) + 40, 96 * ui_scale)
	res := 0
	if button("dlg.ok", cut_right(&r, bw), ok_label, ok_enabled, true) do res = 1
	cut_right(&r, 8)
	if cancel && button("dlg.cancel", cut_right(&r, 96 * ui_scale), "Cancel") do res = -1
	if !typing() || ui.focus == id_of("dlg.name") || ui.focus == id_of("dlg.label") || ui.focus == id_of("dlg.expr") || ui.focus == id_of("dlg.search") || ui.focus == id_of("dlg.value") {
		if (key_pressed(.ENTER) || key_pressed(.KP_ENTER)) && ok_enabled && !app.dlg.first_frame do res = 1
	}
	if ui.ctrl && key_pressed(.ENTER) && ok_enabled do res = 1
	if key_pressed(.ESCAPE) && ui.popup_id == 0 && !app.dlg.first_frame do res = -1
	return res
}

dialog_close :: proc() {
	app.dlg.kind = .None
	ui.focus = 0
}

draw_dialog :: proc() {
	dl := &app.dlg
	// a dialog opened in the waveform window is shown there
	here := cur_popout.doc_id if cur_popout != nil else 0
	if app.dlg_win != here {
		ui.modal = false
		return
	}
	ui.modal = dl.kind != .None
	if !ui.modal do return
	ui.in_modal = true
	defer ui.in_modal = false
	d := doc()
	switch dl.kind {
	case .None:
	case .Open, .Save_As, .Export_Netlist, .Export_CSV, .Import_Model, .Pick_Program: draw_file_dialog(d)
	case .Part_Picker: draw_part_picker(d)
	case .Part_Edit: draw_part_edit(d)
	case .Label_Name: draw_label_dialog(d)
	case .Text_Edit: draw_text_dialog(d)
	case .Sim_Command: draw_sim_dialog(d)
	case .Simulator_Pick: draw_sim_pick(d)
	case .Text_View: draw_text_view()
	case .Shortcuts: draw_shortcuts()
	case .Confirm_Close: draw_confirm_close(d)
	case .Message: draw_message()
	case .About: draw_about()
	case .Diagnostics: draw_diagnostics()
	case .Trace_Edit: draw_trace_dialog(d)
	case .Appearance: draw_appearance()
	case .Import_Repair: draw_import_repair(d)
	}
	dl.first_frame = false
	ui.modal = dl.kind != .None
}

// A typed or pasted path without the quotes and spaces around it (Windows' "Copy as path"
// puts it in quotes, and the clipboard may end it with a line break).
clean_path :: proc(s: string) -> string {
	p := strings.trim_space(s)
	for len(p) >= 2 && ((p[0] == '"' && p[len(p) - 1] == '"') || (p[0] == '\'' && p[len(p) - 1] == '\'')) do p = strings.trim_space(p[1:len(p) - 1])
	return p
}

@(private = "file")
draw_file_dialog :: proc(d: ^Doc) {
	dl := &app.dlg
	b := dialog_frame(720, 560)
	exts: []string
	t := ""
	#partial switch dl.kind {
	case .Open: t = "Open a schematic"; exts = {"edn", "asc", "cir", "net", "sp", "spice", "ckt", "spi"}
	case .Save_As: t = "Save the schematic"; exts = {"edn"}
	case .Export_Netlist: t = "Export the netlist"; exts = {"cir", "net", "sp", "sim"}
	case .Export_CSV: t = "Export the waveforms as CSV"; exts = {"csv"}
	case .Import_Model: t = "Import a SPICE model (.lib .mod .sub .cir .txt …)"; exts = MODEL_EXTS
	case .Pick_Program:
		t = "Program of the simulator"
		if dl.idx >= 0 && dl.idx < len(S.simulators) do t = tcat("Program of ", S.simulators[dl.idx].name, " (the simulator's executable)")
	}
	title(&b, t)
	pr := row(&b)
	// buttons as wide as their text at the current scale and font size
	if tool_button("dlg.up", cut_left(&pr, max(text_w("↑") + 18 * ui_scale, pr.h)), "↑", true, false, "Parent folder") {
		set_str(&dl.dir, dir_name(dl.dir))
	}
	cut_left(&pr, 4 * ui_scale)
	if tool_button("dlg.home", cut_left(&pr, text_w("Home") + 22 * ui_scale), "Home", true, false, "Home folder") do set_str(&dl.dir, home_dir())
	cut_left(&pr, 6 * ui_scale)
	// (edit_field, not text_field on a copy of dl.dir: committing would free dl.dir's text)
	if commit, _, typed := edit_field("dlg.dir", pr, dl.dir); commit {
		// a folder, or a file (a pasted program path): go to its folder and pick it
		p := clean_path(typed)
		if dir_exists(p) {
			set_str(&dl.dir, p)
		} else if file_exists(p) && dir_exists(dir_name(p)) {
			name := strings.clone(base_name(p), context.temp_allocator)
			set_str(&dl.dir, dir_name(p))
			set_str(&dl.name, name)
		} else if len(p) > 0 {
			status(tcat("no such folder: ", p), true)
		}
	}
	bot := cut_bottom(&b, fs() + 16)
	cut_bottom(&b, 8)
	nr := cut_bottom(&b, fs() + 14)
	cut_bottom(&b, 8)
	label_col(&nr, "File name", 90)
	text_field("dlg.name", nr, &dl.name, "name.edn")
	// listing
	stroke_round(b, th.border, 4)
	lr := r_inset(b, 2)
	dirs, files := list_dir(dl.dir, exts)
	ih := fs() + 8
	sc := scroll_begin("dlg.files", lr)
	y := lr.y - sc
	picked := ""
	opened := false
	for x in dirs {
		ir := Rect{lr.x, y, lr.w, ih}
		y += ih
		if ir.y + ih < lr.y || ir.y > lr.y + lr.h do continue
		if hover(ir) {
			fill(ir, th.hover)
			if ui.pressed[0] && ui.double {
				set_str(&dl.dir, path_join(dl.dir, x))
				ui.scroll[id_of("dlg.files")] = 0
			}
		}
		text_in(ir, tcat("› ", x, "/"), th.accent, 0)
	}
	for x in files {
		ir := Rect{lr.x, y, lr.w, ih}
		y += ih
		if ir.y + ih < lr.y || ir.y > lr.y + lr.h do continue
		if x == dl.name do fill(ir, th.sel)
		if hover(ir) {
			if x != dl.name do fill(ir, th.hover)
			if ui.pressed[0] {
				picked = x
				if ui.double do opened = true
			}
		}
		text_in(ir, x, th.fg, 0, 0, 20)
	}
	scroll_end("dlg.files", lr, f32(len(dirs) + len(files)) * ih)
	if len(picked) > 0 do set_str(&dl.name, picked)
	ok_label := "Open" if dl.kind == .Open else "Import" if dl.kind == .Import_Model else "Use" if dl.kind == .Pick_Program else "Save"
	res := buttons(&bot, ok_label, true, len(dl.name) > 0)
	if opened do res = 1
	if res < 0 {
		dialog_close()
		if app.quitting do app.quitting = false
		return
	}
	if res > 0 {
		nm := clean_path(dl.name)
		if len(nm) == 0 do return
		p := nm if is_abs(nm) else path_join(dl.dir, nm)
		if p[0] == '~' do p = path_join(home_dir(), p[1:])
		if dir_exists(p) {
			set_str(&dl.dir, p)
			set_str(&dl.name, "")
			return
		}
		kind := dl.kind
		dialog_close()
		#partial switch kind {
		case .Open:
			open_file(p)
		case .Save_As:
			if file_ext_lower(p) != "edn" do p = tcat(p, ".edn")
			if save_doc(d, p) && app.quitting do request_quit()
		case .Export_Netlist:
			sim := doc_sim(d)
			if sim != nil {
				nl := netlist_build(&d.sch, sim, stem_name(p), dir_of(d.path))
				if len(nl.errors) > 0 do message("Netlist problems", strings.join(nl.errors[:], "\n", context.temp_allocator))
				else if write_text(p, nl.text) do status(tcat("netlist written to ", p))
			}
		case .Import_Model:
			import_model(d, p)
		case .Pick_Program:
			i := dl.idx
			if i >= 0 && i < len(S.simulators) {
				name, id := strings.clone(S.simulators[i].name, context.temp_allocator), strings.clone(S.simulators[i].id, context.temp_allocator)
				if e := settings_set_program(id, p); len(e) > 0 {
					message("Simulator program", e)
				} else {
					status(tcat(name, " runs ", p, " (saved in settings.edn)"))
					dialog_open(.Simulator_Pick)
				}
			}
			return
		case .Export_CSV:
			if wave_trace_count(&d.wave) == 0 {
				if d.run.state == .Done && len(d.run.plots) > 0 {
					if write_csv(&d.run.plots[max(0, d.wave.plot_idx)], p) do status(tcat("all vectors written to ", p))
				} else do message("Export CSV", "There are no waveforms yet.")
			} else if wave_export_csv(&d.wave, p) do status(tcat("waveforms written to ", p))
		}
		pref_put("last-dir", dir_name(p))
	}
}

@(private = "file")
draw_part_picker :: proc(d: ^Doc) {
	// as loomer: a dialog in the main window, with a button that moves it into its own window
	b := dialog_frame(720, 640)
	tr := b
	tr.h = fs(1.25) + 8
	sep := "Separate window"
	if button("dlg.sepwin", cut_right(&tr, text_w(sep) + 30), sep, tip = "Show the parts in a window of their own that you can move to another screen and resize. spicy remembers where you put it.") {
		pref_put_bool("parts-own-window", true)
		if parts_window_open() {
			dialog_close()
			return
		}
		pref_put_bool("parts-own-window", false)
		status("could not open a separate window for the parts", true)
	}
	title(&b, "Place a part")
	bot := cut_bottom(&b, fs() + 16)
	if parts_panel(b, d) {
		dialog_close()
		return
	}
	if button("dlg.close", cut_right(&bot, 100 * ui_scale), "Close") || key_pressed(.ESCAPE) do dialog_close()
}

@(private = "file")
draw_part_edit :: proc(d: ^Doc) {
	dl := &app.dlg
	if dl.idx < 0 || dl.idx >= len(d.sch.comps) {
		dialog_close()
		return
	}
	c := &d.sch.comps[dl.idx]
	sym := symbol_find(c.sym)
	is_src := sym != nil && sym.editor == "source"
	local := sch_models(&d.sch, doc_sim(d), dir_of(d.path))
	// the value names a subcircuit: how its ports meet the symbol's pins
	sub: ^Lib_Entry
	if sym != nil && !is_src {
		tc := c^
		tc.value = dl.value
		tc.attrs = make([dynamic]Attr, context.temp_allocator)
		if len(strings.trim_space(dl.pinmap)) > 0 do append(&tc.attrs, Attr{"pinmap", dl.pinmap})
		sub = comp_subckt(&tc, sym, local)
	}
	// where the model comes from
	from, differs := "", false
	if sym != nil && !is_src && sym.kind == .Part {
		if f := strings.fields(dl.value, context.temp_allocator); len(f) > 0 do from, differs = model_source(f[0], local)
	}
	h: f32 = 300 + f32(len(dl.attr_keys)) * 34
	if is_src do h += 330
	if len(from) > 0 do h += 34
	if differs do h += 34
	if sub != nil do h += 110
	params := nonideal_params(sym)
	if sub != nil do params = nil // a subcircuit has its own
	if len(params) > 0 do h += f32(len(params) + 1) * 34 + 6
	b := dialog_frame(620, h)
	title(&b, tcat(c.ref, " – ", sym.desc if sym != nil else c.sym))
	r := row(&b)
	label_col(&r, "Name")
	text_field("dlg.ref", r, &dl.ref)
	r = row(&b)
	label_col(&r, "Value")
	vr := r
	models: []string
	if sym != nil && !is_src && (len(sym.models) > 0 || sym.editor == "model") do models = models_for_symbol(sym, local)
	if sym != nil && !is_src && sym.kind == .Part {
		if button("dlg.import", cut_right(&vr, text_w("Import…") + 24), "Import…") {
			// a model file for this part: after the import the part uses it
			app.import_for = dl.idx
			dialog_open(.Import_Model)
			return
		}
		tooltip(id_of("dlg.import"), "Import a SPICE model file (.lib, .mod, .sub, .txt …) and use it for this part")
		cut_right(&vr, 6)
		if button("dlg.symbol", cut_right(&vr, text_w("Symbol…") + 24), "Symbol…") {
			// apply what was typed first: the editor reads the part's value (its model)
			set_str(&c.value, strings.trim_space(dl.value))
			idx := dl.idx
			dialog_close()
			symed_open(sym, d, idx)
			return
		}
		tooltip(id_of("dlg.symbol"), "Edit this part's symbol: its drawing, pins and their model ports")
		cut_right(&vr, 6)
	}
	if len(models) > 0 {
		mr := cut_right(&vr, 200 * ui_scale)
		cut_right(&vr, 6)
		sel := -1
		for m, i in models do if strings.equal_fold(m, dl.value) do sel = i
		if combo("dlg.model", mr, models, &sel) do set_str(&dl.value, models[sel])
	}
	if is_src {
		// the value follows the source editor
		v := source_build()
		draw_text(v, vr.x + 6, vr.y + (vr.h - fs()) / 2, th.fg)
		set_str(&dl.value, v)
	} else {
		text_field("dlg.value", vr, &dl.value)
	}
	if len(from) > 0 {
		r = row(&b)
		label_col(&r, "Model from")
		text_in(r, fit_text(from, r.w - 8), th.muted, 0, fs(0.9), 4)
		if differs {
			r = row(&b)
			label_col(&r, "")
			text_in(r, fit_text("Your library has another version: use Import… to switch to it", r.w - 8), th.warn, 0, fs(0.9), 4)
		}
	}
	if is_src {
		cut_top(&b, 6)
		r = row(&b)
		label_col(&r, "DC value")
		text_field("dlg.src.dc", r, &dl.src_dc, "0")
		r = row(&b)
		label_col(&r, "Waveform")
		segmented("dlg.src.kind", r, SRC_KINDS[:], &dl.src_kind)
		args := SRC_ARGS[dl.src_kind]
		for a, i in args {
			r = row(&b)
			label_col(&r, a, 170)
			text_field(tcat("dlg.src.a", itoa(i)), r, &dl.src_args[i])
		}
		for _ in len(args) ..< 8 do if dl.src_kind != 4 do cut_top(&b, 0)
		r = row(&b)
		label_col(&r, "AC (mag [phase])", 170)
		text_field("dlg.src.ac", r, &dl.src_ac, "for .ac analysis, e.g. 1")
	}
	if sub != nil {
		cut_top(&b, 6)
		tc := c^
		tc.attrs = make([dynamic]Attr, context.temp_allocator)
		if len(strings.trim_space(dl.pinmap)) > 0 do append(&tc.attrs, Attr{"pinmap", dl.pinmap})
		order, err := subckt_pin_map(sub, sym, &tc)
		info := ""
		if len(err) > 0 {
			info = err
		} else {
			parts := make([dynamic]string, context.temp_allocator)
			for k, i in order {
				pn := sub.ports[i]
				if sub.pins[i] != sub.ports[i] do pn = tcat(pn, " (", sub.pins[i], ")")
				append(&parts, tcat(pn, " = ", sym.pins[k].name))
			}
			info = fmt.tprintf("Subcircuit %s from %s.\nPorts: %s", entry_display_name(sub), base_name(sub.src), strings.join(parts[:], ",  ", context.temp_allocator))
		}
		draw_wrapped(info, cut_top(&b, fs() * 2.8), th.err if len(err) > 0 else th.muted, fs(0.9))
		r = row(&b)
		label_col(&r, "Pin map", 170)
		text_field("dlg.pinmap", r, &dl.pinmap, tcat("automatic; or the symbol pins in port order, e.g. ", pin_names_of(sym)))
	}
	if len(params) > 0 {
		cut_top(&b, 6)
		text_in(row(&b), "Non-ideal behaviour – leave empty for an ideal part", th.muted, 0, fs(0.9), 4)
		for p, i in params {
			r = row(&b)
			label_col(&r, p.label, 170)
			text_field(tcat("dlg.ni", itoa(i)), r, &dl.ni_vals[i], p.hint)
		}
	}
	for k, i in dl.attr_keys {
		r = row(&b)
		label_col(&r, k)
		text_field(tcat("dlg.attr", itoa(i)), r, &dl.attr_vals[i])
	}
	bot := cut_bottom(&b, fs() + 16)
	if sym != nil && len(sym.models) > 0 {
		hint := "Models come from the built-in library, imported files (Import…), :model-libraries in settings.edn, and the schematic's own .model / .subckt / .include directives."
		draw_wrapped(hint, cut_bottom(&b, fs() * 2.6), th.muted, fs(0.9))
	}
	res := buttons(&bot)
	if res < 0 do dialog_close()
	if res > 0 {
		doc_push_undo(d)
		ref := strings.trim_space(dl.ref)
		if len(ref) > 0 do set_str(&c.ref, ref)
		// a source's value is built from its editor's fields now: a field committed by this
		// Enter (or by the click on OK) was read after the value shown above was made
		if is_src do set_str(&dl.value, source_build())
		set_str(&c.value, strings.trim_space(dl.value))
		for k, i in dl.attr_keys do comp_set_attr(c, k, dl.attr_vals[i])
		for p, i in params {
			v := strings.trim_space(dl.ni_vals[i])
			if len(v) > 0 do comp_set_attr(c, p.key, v)
			else do comp_remove_attr(c, p.key)
		}
		pm := strings.trim_space(dl.pinmap)
		if len(pm) > 0 do comp_set_attr(c, "pinmap", pm)
		else do for a, i in c.attrs do if a.key == "pinmap" {
			delete(a.key)
			delete(a.val)
			ordered_remove(&c.attrs, i)
			break
		}
		dialog_close()
	}
}

@(private = "file")
draw_label_dialog :: proc(d: ^Doc) {
	dl := &app.dlg
	b := dialog_frame(460, 190)
	title(&b, "Net label" if dl.idx < 0 else "Rename the net label")
	r := row(&b)
	label_col(&r, "Name", 70)
	text_field("dlg.label", r, &dl.name, "out, vcc, in …")
	if ui.focus == id_of("dlg.label") {
		// the field keeps the text until commit; read it live for the OK button
		set_str(&dl.name, string(ui.edit_buf[:]))
	}
	res := buttons(&b, "OK", true, len(strings.trim_space(dl.name)) > 0)
	if res < 0 do dialog_close()
	if res > 0 {
		name := strings.trim_space(dl.name)
		if name == "gnd" || name == "GND" do name = "0"
		dialog_close()
		if dl.idx >= 0 && dl.idx < len(d.sch.flags) {
			doc_push_undo(d)
			set_str(&d.sch.flags[dl.idx].name, name)
		} else if dl.label_place_now {
			doc_push_undo(d)
			append(&d.sch.flags, Flag{name = strings.clone(name), pos = dl.label_at})
		} else {
			tool_set(d, .Place)
			d.place_kind = .Label
			d.place_rot = 0
			set_str(&d.place_text, name)
		}
	}
}

@(private = "file")
draw_text_dialog :: proc(d: ^Doc) {
	dl := &app.dlg
	b := dialog_frame(680, 440)
	title(&b, "SPICE directive" if dl.directive else "Comment")
	bot := cut_bottom(&b, fs() + 16)
	cut_bottom(&b, 6)
	hr := cut_bottom(&b, fs() + 10)
	if dl.directive {
		text_in(hr, "e.g. .tran 10m · .ac dec 100 1 1Meg · .param R=1k · .include file.lib · #vacask block · Ctrl+Enter: OK", th.muted, 0, fs(0.85), 0)
	}
	cr := cut_bottom(&b, fs() + 12)
	cut_bottom(&b, 4)
	checkbox("dlg.isdir", cr, "SPICE directive (goes into the netlist)", &dl.directive)
	text_area("dlg.textarea", b, &dl.text, dl.directive)
	res := buttons(&bot, "OK", true, len(strings.trim_space(dl.text)) > 0)
	if res < 0 do dialog_close()
	if res > 0 {
		txt := strings.trim_right_space(dl.text)
		dialog_close()
		if dl.idx >= 0 && dl.idx < len(d.sch.texts) {
			doc_push_undo(d)
			t := &d.sch.texts[dl.idx]
			set_str(&t.text, txt)
			t.directive = dl.directive
		} else {
			tool_set(d, .Place)
			d.place_kind = .Text
			d.place_directive = dl.directive
			set_str(&d.place_text, txt)
		}
	}
}

@(private = "file")
draw_sim_dialog :: proc(d: ^Doc) {
	dl := &app.dlg
	b := dialog_frame(600, 420)
	title(&b, "Simulation command")
	segmented("dlg.simtab", row(&b), ANALYSES[:], &dl.sim_tab)
	cut_top(&b, 8)
	F :: proc(b: ^Rect, lab: string, i: int, ph := "") {
		r := row(b)
		label_col(&r, lab, 200)
		text_field(tcat("dlg.f", itoa(i)), r, &app.dlg.f[i], ph)
	}
	switch dl.sim_tab {
	case 0:
		F(&b, "Stop time", 1, "e.g. 10m")
		F(&b, "Time step (optional)", 0, "automatic")
		F(&b, "Start saving at (optional)", 2, "0")
		F(&b, "Max step (optional)", 7, "")
	case 1:
		r := row(&b)
		label_col(&r, "Sweep", 200)
		types := [?]string{"dec", "oct", "lin"}
		k := 0
		for t, i in types do if t == lower(dl.f[3]) do k = i
		if segmented("dlg.actype", r, {"Decade", "Octave", "Linear"}, &k) do set_str(&dl.f[3], types[k])
		F(&b, "Points (per decade / octave / total)", 4)
		F(&b, "Start frequency", 5)
		F(&b, "Stop frequency", 6)
	case 2:
		F(&b, "Source to sweep", 0, "V1")
		F(&b, "Start", 1)
		F(&b, "Stop", 2)
		F(&b, "Step", 3)
	case 3:
		draw_wrapped("The DC operating point: node voltages appear on the schematic after the run (hover a wire).", row(&b), th.muted)
	}
	bot := cut_bottom(&b, fs() + 16)
	cut_bottom(&b, 6)
	text_in(cut_bottom(&b, fs() + 8), sim_cmd_build(), th.accent, 0, 0, 0)
	res := buttons(&bot)
	if res < 0 do dialog_close()
	if res > 0 {
		dialog_close()
		sim_cmd_apply(d)
	}
}

@(private = "file")
draw_sim_pick :: proc(d: ^Doc) {
	dl := &app.dlg
	n := min(len(S.simulators), len(dl.f))
	b := dialog_frame(820, 170 + f32(n) * (fs() * 3 + 54))
	title(&b, "Simulators")
	cur := doc_sim(d)
	for i in 0 ..< n {
		s := &S.simulators[i]
		r := cut_top(&b, fs() * 3 + 46)
		cut_top(&b, 8)
		sel := cur != nil && cur.id == s.id
		if sel do stroke_round(r, th.accent, 5, 2)
		else do stroke_round(r, th.border, 5)
		in_ := r_inset(r, 8)
		// name and "Use"
		top := cut_top(&in_, fs() + 10)
		if button(tcat("dlg.use", fmt.tprint(i)), cut_right(&top, 110 * ui_scale), "In use" if sel else "Use", !sel, false, sel, "Run this schematic with it") {
			set_str(&d.sim_override, s.id)
			status(tcat("simulator: ", s.name))
		}
		draw_text(s.name, top.x, top.y + 4, th.fg)
		cut_top(&in_, 4)
		// the program
		pr := cut_top(&in_, fs() + 10)
		label_col(&pr, "Program", 80)
		fid := tcat("dlg.prog", fmt.tprint(i))
		if button(tcat("dlg.browse", fmt.tprint(i)), cut_right(&pr, 100 * ui_scale), "Browse…") {
			dl.idx = i
			dialog_open(.Pick_Program)
			return
		}
		cut_right(&pr, 6)
		changed := dl.f[i] != (s.command[0] if len(s.command) > 0 else "")
		if button(tcat("dlg.setp", fmt.tprint(i)), cut_right(&pr, 70 * ui_scale), "Save", changed, changed, false, "Save the program in settings.edn") || (text_field(fid, pr, &dl.f[i], "vacask, /opt/vacask/bin/vacask, ~/bin/ngspice …") && changed) {
			name := strings.clone(s.name, context.temp_allocator) // S is reloaded by the save
			if e := settings_set_program(s.id, strings.trim_space(dl.f[i])); len(e) > 0 do message("Simulator program", e)
			else do status(tcat(name, " runs ", dl.f[i], " (saved in settings.edn)"))
			return // settings were reloaded
		}
		// found?
		st := cut_top(&in_, fs(0.9) + 6)
		cut_left(&st, 80 * ui_scale)
		if p, ok := find_program(dl.f[i]); ok {
			draw_icon(.Check, st.x + fs(0.4), st.y + 2 + fs(0.85) / 2, fs(0.75), th.ok)
			draw_text(p, st.x + fs(1.1), st.y + 2, th.ok, fs(0.85))
		} else {
			hint := "not found – give the full path or use Browse…" if len(dl.f[i]) > 0 else "no program set"
			draw_icon(.Cross, st.x + fs(0.4), st.y + 2 + fs(0.85) / 2, fs(0.75), th.err)
			draw_text(hint, st.x + fs(1.1), st.y + 2, th.err, fs(0.85))
		}
	}
	draw_wrapped("The program is saved in settings.edn (:simulators … :command), which also holds the arguments and output names.", cut_top(&b, fs() * 2.5), th.muted, fs(0.9))
	if buttons(&b, "Close", false) != 0 do dialog_close()
}

@(private = "file")
draw_text_view :: proc() {
	dl := &app.dlg
	b := dialog_frame(900, 700)
	title(&b, dl.title)
	bot := cut_bottom(&b, fs() + 16)
	cut_bottom(&b, 8)
	fill_round(b, th.input, 4)
	lr := r_inset(b, 6)
	sz := fs(0.95)
	lines := split_lines(dl.text)
	sc := scroll_begin("dlg.view", lr)
	selectable_begin("dlg.view.sel", lr, sc, dl.text)
	for l, i in lines {
		y := lr.y + f32(i) * (sz + 4) - sc
		if y < lr.y - sz || y > lr.y + lr.h do continue
		col := th.fg
		ll := lower(l)
		if strings.contains(ll, "error") do col = th.err
		else if strings.contains(ll, "warning") do col = th.warn
		else if strings.has_prefix(l, "*") do col = th.muted
		draw_mono(l, lr.x, y, col, sz)
	}
	selectable_end()
	scroll_end("dlg.view", lr, f32(len(lines)) * (sz + 4) + 10)
	if button("dlg.copy", cut_left(&bot, 100 * ui_scale), "Copy") {
		rl.SetClipboardText(cstr(dl.text))
		status("copied")
	}
	if buttons(&bot, "Close", false) != 0 {
		ui.scroll[id_of("dlg.view")] = 0
		dialog_close()
	}
}

// A model file with faults (import_model): what spicy would repair and what the user should
// check, then Repair and import / Import as is / Cancel. Only the copy is repaired.
@(private = "file")
draw_import_repair :: proc(d: ^Doc) {
	dl := &app.dlg
	b := dialog_frame(900, 660)
	title(&b, dl.title)
	intro: string
	if app.import_fixes > 0 {
		intro = fmt.tprintf("spicy found %d fault(s) it can repair. ngspice lets most of them through, sometimes silently losing a value; Xyce and VACASK stop at them. Repairing changes only the copy spicy keeps in its models folder, not %s.", app.import_fixes, base_name(app.import_path))
	} else {
		intro = "Nothing to repair, but some things spicy cannot decide for you. Check them in the datasheet; the file is imported unchanged."
	}
	if app.import_checks > 0 && app.import_fixes > 0 do intro = tcat(intro, fmt.tprintf(" %d other thing(s) are only listed, to check yourself.", app.import_checks))
	ir := cut_top(&b, fs() * 4.2)
	draw_wrapped(intro, ir, th.fg)
	cut_top(&b, 6)
	bot := cut_bottom(&b, fs() + 16)
	cut_bottom(&b, 8)
	fill_round(b, th.input, 4)
	lr := r_inset(b, 6)
	sz := fs(0.95)
	lines := split_lines(dl.text)
	sc := scroll_begin("dlg.repair", lr)
	selectable_begin("dlg.repair.sel", lr, sc, dl.text)
	in_checks := false
	for l, i in lines {
		if strings.has_prefix(l, "To check") || strings.has_prefix(l, "Where (to check)") do in_checks = true
		else if strings.has_prefix(l, "Repairs") || strings.has_prefix(l, "Where (repairs)") do in_checks = false
		y := lr.y + f32(i) * (sz + 4) - sc
		if y < lr.y - sz || y > lr.y + lr.h do continue
		col := th.fg
		if len(l) > 0 && l[0] != ' ' do col = th.accent // headings
		else if in_checks do col = th.warn
		draw_mono(l, lr.x, y, col, sz)
	}
	selectable_end()
	scroll_end("dlg.repair", lr, f32(len(lines)) * (sz + 4) + 10)
	if button("dlg.copy", cut_left(&bot, 100 * ui_scale), "Copy") {
		rl.SetClipboardText(cstr(dl.text))
		status("copied")
	}
	res := 0 // 1 repair and import, 2 as is, -1 cancel
	main_label := "Repair and import" if app.import_fixes > 0 else "Import"
	if button("dlg.ok", cut_right(&bot, max(text_w(main_label) + 40, 96 * ui_scale)), main_label, true, true) do res = 1
	cut_right(&bot, 8)
	if app.import_fixes > 0 {
		if button("dlg.asis", cut_right(&bot, text_w("Import as is") + 40), "Import as is") do res = 2
		cut_right(&bot, 8)
	}
	if button("dlg.cancel", cut_right(&bot, 96 * ui_scale), "Cancel") do res = -1
	if !dl.first_frame {
		if key_pressed(.ENTER) || key_pressed(.KP_ENTER) do res = 1
		if key_pressed(.ESCAPE) && ui.popup_id == 0 do res = -1
	}
	if res == 0 do return
	ui.scroll[id_of("dlg.repair")] = 0
	path := strings.clone(app.import_path, context.temp_allocator)
	dialog_close()
	switch res {
	case 1: import_model_apply(d, path, app.import_fixes > 0)
	case 2: import_model_apply(d, path, false)
	case -1:
		app.import_for = -1
		status("import cancelled")
	}
}

@(private = "file")
draw_shortcuts :: proc() {
	dl := &app.dlg
	b := dialog_frame(760, 680)
	title(&b, "Keyboard shortcuts")
	live_field("dlg.search", row(&b), &dl.search, "search …")
	bot := cut_bottom(&b, fs() + 16)
	cut_bottom(&b, 6)
	draw_wrapped(tcat("Change them in ", shortcuts_file, " (reloaded when saved)."), cut_bottom(&b, fs() * 2.4), th.muted, fs(0.9))
	lr := b
	ih := fs() + 8
	q := lower(dl.search)
	sc := scroll_begin("dlg.keys", lr)
	selectable_begin("dlg.keys.sel", lr, sc)
	y := lr.y - sc
	n := 0
	for a in actions {
		if len(q) > 0 && !strings.contains(lower(a.desc), q) && !strings.contains(a.name, q) && !strings.contains(lower(action_keys_text(a.name)), q) do continue
		ir := Rect{lr.x, y, lr.w, ih}
		y += ih
		n += 1
		if n % 2 == 0 do fill(ir, alpha(th.fg, 8))
		text_in(ir, a.desc if len(a.desc) > 0 else a.name, th.fg, 0, 0, 6)
		text_in(ir, action_keys_text(a.name), th.accent, 2, 0, 12)
	}
	selectable_end()
	scroll_end("dlg.keys", lr, f32(n) * ih)
	if len(shortcut_errors) > 0 do text_in(bot, shortcut_errors[0], th.err, 0, fs(0.9), 0)
	if buttons(&bot, "Close", false) != 0 do dialog_close()
}

@(private = "file")
draw_confirm_close :: proc(d: ^Doc) {
	b := dialog_frame(520, 200)
	title(&b, "Unsaved changes")
	draw_wrapped(tcat("Save the changes to ", doc_title(d), " before closing?"), row(&b), th.fg)
	bot := cut_bottom(&b, fs() + 16)
	res := 0
	if button("dlg.save", cut_right(&bot, 100 * ui_scale), "Save", true, true) do res = 1
	cut_right(&bot, 8)
	if button("dlg.discard", cut_right(&bot, 120 * ui_scale), "Don't save") do res = 2
	cut_right(&bot, 8)
	if button("dlg.cancel", cut_right(&bot, 100 * ui_scale), "Cancel") || key_pressed(.ESCAPE) do res = -1
	if key_pressed(.ENTER) && !app.dlg.first_frame do res = 1
	switch res {
	case -1:
		app.quitting = false
		dialog_close()
	case 1:
		dialog_close()
		if len(d.path) == 0 {
			dialog_open(.Save_As)
			return
		}
		if !save_doc(d, d.path) do return
		fallthrough
	case 2:
		dialog_close()
		d.dirty = false
		if app.quitting do request_quit()
		else do doc_close(app.cur)
	}
}

@(private = "file")
draw_message :: proc() {
	dl := &app.dlg
	lines := split_lines(dl.text)
	h := min(180 + f32(len(lines)) * (fs() + 6) / ui_scale, 640)
	b := dialog_frame(640, h)
	title(&b, dl.title)
	bot := cut_bottom(&b, fs() + 16)
	sc := scroll_begin("dlg.msg", b)
	selectable_begin("dlg.msg.sel", b, sc)
	used := draw_wrapped(dl.text, {b.x, b.y - sc, b.w - 10, b.h}, th.fg)
	selectable_end()
	scroll_end("dlg.msg", b, used)
	if button("dlg.copy", cut_left(&bot, 100 * ui_scale), "Copy") do rl.SetClipboardText(cstr(dl.text))
	if buttons(&bot, "OK", false) != 0 {
		ui.scroll[id_of("dlg.msg")] = 0
		dialog_close()
	}
}

@(private = "file")
draw_about :: proc() {
	b := dialog_frame(620, 400)
	title(&b, tcat("spicy ", SPICY_VERSION))
	bot := cut_bottom(&b, fs() + 16)
	selectable_begin("dlg.about.sel", b)
	draw_wrapped(about_text(), b, th.fg)
	selectable_end()
	if button("dlg.repo", cut_left(&bot, 150 * ui_scale), "Open repository") && !open_external(SPICY_REPO) do status(tcat("cannot open ", SPICY_REPO), true)
	cut_left(&bot, 8)
	if button("dlg.issue", cut_left(&bot, 150 * ui_scale), "Report an issue") && !open_external(SPICY_ISSUES) do status(tcat("cannot open ", SPICY_ISSUES), true)
	if buttons(&bot, "Close", false) != 0 do dialog_close()
}

// Help ▸ Diagnostics: the report, to copy into a bug report.
@(private = "file")
draw_diagnostics :: proc() {
	dl := &app.dlg
	b := dialog_frame(760, 620)
	title(&b, "Diagnostics")
	bot := cut_bottom(&b, fs() + 16)
	cut_bottom(&b, 8)
	fill_round(b, th.input, 4)
	lr := r_inset(b, 6)
	sz := fs(0.95)
	lines := split_lines(dl.text)
	sc := scroll_begin("dlg.diag", lr)
	selectable_begin("dlg.diag.sel", lr, sc, dl.text)
	for l, i in lines {
		y := lr.y + f32(i) * (sz + 4) - sc
		if y < lr.y - sz || y > lr.y + lr.h do continue
		draw_mono(l, lr.x, y, th.fg if len(l) > 0 && l[0] == ' ' else th.accent, sz)
	}
	selectable_end()
	scroll_end("dlg.diag", lr, f32(len(lines)) * (sz + 4) + 10)
	if button("dlg.copy", cut_left(&bot, 100 * ui_scale), "Copy") {
		rl.SetClipboardText(cstr(dl.text))
		status("diagnostics copied to the clipboard")
	}
	cut_left(&bot, 8)
	if button("dlg.logdir", cut_left(&bot, 150 * ui_scale), "Open log folder") do open_external(state_dir())
	if buttons(&bot, "OK", false) != 0 {
		ui.scroll[id_of("dlg.diag")] = 0
		dialog_close()
	}
}

show_diagnostics :: proc() {
	set_str(&app.dlg.text, diagnostics_report())
	dialog_open(.Diagnostics)
}

@(private = "file")
draw_trace_dialog :: proc(d: ^Doc) {
	dl := &app.dlg
	b := dialog_frame(640, 300)
	title(&b, "Add a trace" if dl.trace < 0 else "Edit the trace")
	r := row(&b)
	text_field("dlg.expr", r, &dl.name, "V(out)   I(R1)   V(a,b)   V(out)/V(in)   db(V(out))")
	if ui.focus == id_of("dlg.expr") do set_str(&dl.name, string(ui.edit_buf[:]))
	// net names as hints
	ni := nets_build(&d.sch, S.net_prefix)
	names := make([dynamic]string, context.temp_allocator)
	for n in ni.names do if n != "0" do append(&names, tcat("V(", n, ")"))
	for c in d.sch.comps do append(&names, tcat("I(", c.ref, ")"))
	hint := strings.join(names[:min(len(names), 40)], "  ", context.temp_allocator)
	draw_wrapped(tcat("Functions: db ph mag re im abs sqrt exp ln log10 d (derivative) int (integral) min max if(cond, a, b). Signals: ", hint), cut_top(&b, b.h - fs() - 20), th.muted, fs(0.9))
	res := buttons(&b, "OK", true, len(strings.trim_space(dl.name)) > 0)
	if res < 0 do dialog_close()
	if res > 0 {
		e := strings.trim_space(dl.name)
		w := &d.wave
		if dl.trace >= 0 && dl.pane < len(w.panes) && dl.trace < len(w.panes[dl.pane].traces) {
			set_str(&w.panes[dl.pane].traces[dl.trace].expr, e)
			w.panes[dl.pane].auto_y = true
			w.dirty = true
		} else {
			wave_add_trace(w, e, false)
		}
		dialog_close()
	}
}

@(private = "file")
pin_names_of :: proc(sym: ^Symbol) -> string {
	n := make([dynamic]string, context.temp_allocator)
	for p in sym.pins do append(&n, p.name)
	return strings.join(n[:], " ", context.temp_allocator)
}

// ---------------------------------------------------------------------------
// View › Appearance: UI scale and text sizes, shown at once, written to settings.edn on OK

@(private = "file")
Appearance :: struct {
	scale:                    f32, // 0: automatic
	font, text, wfont:        f32,
	orig_scale, orig_ui:      f32, // to go back to on Cancel
	orig_font, orig_text, orig_wfont: f32,
}

@(private = "file")
ap: Appearance

@(private = "file")
SCALES := [?]f32{0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3}

@(private = "file")
appearance_open :: proc() {
	ap = {scale = S.scale, font = S.font_size, text = S.text_size, wfont = S.w_font_size}
	ap.orig_scale, ap.orig_ui = S.scale, ui_scale
	ap.orig_font, ap.orig_text, ap.orig_wfont = S.font_size, S.text_size, S.w_font_size
}

// The choices shown now, everywhere (not saved yet).
@(private = "file")
appearance_preview :: proc() {
	ui_scale = ap.scale if ap.scale > 0 else default_ui_scale()
	S.font_size, S.text_size, S.w_font_size = ap.font, ap.text, ap.wfont
	for d in app.docs do wave_mark_dirty(&d.wave)
}

@(private = "file")
appearance_restore :: proc() {
	S.scale = ap.orig_scale
	ui_scale = ap.orig_ui
	S.font_size, S.text_size, S.w_font_size = ap.orig_font, ap.orig_text, ap.orig_wfont
	for d in app.docs do wave_mark_dirty(&d.wave)
}

// "−  14 px  +" with the value kept between lo and hi; true when it changed.
@(private = "file")
stepper :: proc(id: string, r: Rect, v: ^f32, lo, hi: f32) -> bool {
	r := r
	bw := fs() + 18
	changed := false
	if button(tcat(id, ".minus"), cut_left(&r, bw), "−", v^ > lo) {v^ = max(lo, v^ - 1); changed = true}
	t := fmt.tprintf("%g px", v^)
	vr := cut_left(&r, text_w("00 px") + 28)
	text_in(vr, t, th.fg, 1, 0, 0)
	if button(tcat(id, ".plus"), cut_left(&r, bw), "+", v^ < hi) {v^ = min(hi, v^ + 1); changed = true}
	return changed
}

@(private = "file")
draw_appearance :: proc() {
	b := dialog_frame(560, 330)
	title(&b, "Appearance")
	changed := false
	// UI scale
	auto := default_ui_scale()
	items := make([dynamic]string, context.temp_allocator)
	values := make([dynamic]f32, context.temp_allocator)
	append(&items, fmt.tprintf("Automatic (%d %%, from the monitor)", int(math.round(auto * 100))))
	append(&values, 0)
	for x in SCALES {
		append(&items, fmt.tprintf("%d %%", int(math.round(x * 100))))
		append(&values, x)
	}
	sel := -1
	for x, i in values do if abs(x - ap.scale) < 0.001 do sel = i
	if sel < 0 {
		// set by hand to another value
		append(&items, fmt.tprintf("%d %%", int(math.round(ap.scale * 100))))
		append(&values, ap.scale)
		sel = len(values) - 1
	}
	r := row(&b)
	label_col(&r, "UI scale", 170)
	if combo("dlg.ap.scale", cut_left(&r, 300 * ui_scale), items[:], &sel) {
		ap.scale = values[sel]
		changed = true
	}
	r = row(&b)
	label_col(&r, "Menus and dialogs", 170)
	if stepper("dlg.ap.font", r, &ap.font, 8, 40) do changed = true
	r = row(&b)
	label_col(&r, "Schematic text", 170)
	if stepper("dlg.ap.text", r, &ap.text, 6, 60) do changed = true
	r = row(&b)
	label_col(&r, "Waveform text", 170)
	if stepper("dlg.ap.wfont", r, &ap.wfont, 6, 40) do changed = true
	cut_top(&b, 4)
	draw_wrapped("Text sizes are pixels at 100 %; the UI scale multiplies them. Changes show at once; OK saves them in settings.edn (:ui :scale, :ui :font-size, :schematic :text-size, :waveform :font-size).", cut_top(&b, fs() * 3.4), th.muted, fs(0.9))
	if changed do appearance_preview()
	bot := cut_bottom(&b, fs() + 16)
	if button("dlg.ap.reset", cut_left(&bot, text_w("Defaults") + 30), "Defaults") {
		ap.scale, ap.font, ap.text, ap.wfont = 0, 14, 14, 12
		appearance_preview()
	}
	res := buttons(&bot)
	if res < 0 {
		appearance_restore()
		dialog_close()
		return
	}
	if res > 0 {
		set := [?][3]string {
			{"ui", "scale", ":auto" if ap.scale <= 0 else fmt.tprintf("%g", ap.scale)},
			{"ui", "font-size", fmt.tprintf("%g", ap.font)},
			{"schematic", "text-size", fmt.tprintf("%g", ap.text)},
			{"waveform", "font-size", fmt.tprintf("%g", ap.wfont)},
		}
		for x in set {
			if err := settings_set(x[0], x[1], x[2]); len(err) > 0 {
				message("Appearance", err)
				return
			}
		}
		dialog_close()
		status(tcat("appearance saved in ", settings_path))
	}
}
