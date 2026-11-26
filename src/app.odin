package spicy

import "core:fmt"
import "core:log"
import "core:math"
import os "core:os"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

// The application: open schematics (tabs), the window layout, menus, toolbar, status bar
// and every action (menus, toolbar and keys all go through run_action).

Tool :: enum u8 {Select, Wire, Place, Probe, Paste}

Place_Kind :: enum u8 {Part, Ground, Label, Text}

Doc :: struct {
	id:          int,
	path:        string,
	sch:         Schematic,
	dirty:       bool,
	undo, redo:  [dynamic]string,
	// view
	cam:         [2]f32, // schematic point at the centre of the view
	zoom:        f32,
	fitted:      bool,
	user_view:   bool, // zoomed or panned by hand: no automatic refit
	last_rect:   [2]f32,
	// editing
	tool:        Tool,
	place_kind:  Place_Kind,
	place_sym:   string,
	place_rot:   u8,
	place_mirror: bool,
	place_text:  string, // label name or text
	place_directive: bool,
	paste:       Schematic,
	paste_anchor: P,
	wire_active: bool,
	wire_start:  P,
	wire_flip:   bool,
	drag:        Drag,
	probe_from:  int, // net index where a probe drag started (-1)
	inline:      struct {ci: int, field: u8, r: Rect}, // name (1) / value (2) edited in place
	// simulation
	run:         Run,
	sim_override: string,
	wave:        Wave_View,
}

Drag_Kind :: enum u8 {None, Pending, Move, Box, Pan}

Drag :: struct {
	kind:     Drag_Kind,
	start:    [2]f32, // screen
	start_p:  [2]f32, // schematic
	base:     string, // schematic before the move (EDN)
	detach:   bool, // ctrl: move without dragging the wires
	last_d:   P,
}

Dialog_Kind :: enum u8 {
	None, Open, Save_As, Export_Netlist, Export_CSV, Part_Picker, Part_Edit, Label_Name, Text_Edit,
	Sim_Command, Simulator_Pick, Text_View, Shortcuts, Confirm_Close, Message, About, Trace_Edit, Import_Model, Pick_Program, Appearance, Diagnostics,
}

App :: struct {
	docs:        [dynamic]^Doc,
	cur:         int,
	next_id:     int,
	show_waves:  bool,
	layout:      string,
	split:       f32,
	split_drag:  bool,
	hover_ctx:   Key_Ctx,
	sch_rect:    Rect,
	wave_rect:   Rect,
	status:      string,
	status_err:  bool,
	status_time: f64,
	clipboard:   string, // schematic EDN
	quit:        bool,
	quitting:    bool, // closing tabs one by one before exit
	dlg:         Dialog_State,
	dlg_win:     int, // the dialog belongs to the waveform window of this schematic id (0: main window)
	menu_open:   string,
	import_for:  int, // the part whose editor started an import (-1: none)
}

app: App

doc :: proc() -> ^Doc {
	if len(app.docs) == 0 do return nil
	return app.docs[clamp(app.cur, 0, len(app.docs) - 1)]
}

doc_title :: proc(d: ^Doc) -> string {
	n := base_name(d.path) if len(d.path) > 0 else fmt.tprintf("untitled-%d", d.id)
	return tcat(n, " •" if d.dirty else "")
}

doc_new :: proc() -> ^Doc {
	d := new(Doc)
	app.next_id += 1
	d.id = app.next_id
	d.sch.comps = make([dynamic]Comp)
	d.sch.wires = make([dynamic]Wire)
	d.sch.flags = make([dynamic]Flag)
	d.sch.texts = make([dynamic]Text)
	d.zoom = S.initial_zoom
	d.probe_from = -1
	wave_init(&d.wave)
	append(&app.docs, d)
	app.cur = len(app.docs) - 1
	return d
}

doc_free :: proc(d: ^Doc) {
	run_stop(&d.run)
	run_free(&d.run)
	sch_free(&d.sch)
	sch_free(&d.paste)
	for s in d.undo do delete(s)
	for s in d.redo do delete(s)
	delete(d.undo); delete(d.redo)
	delete(d.path); delete(d.place_sym); delete(d.place_text); delete(d.drag.base); delete(d.sim_override)
	wave_free(&d.wave)
	free(d)
}

// Simulator of a schematic: chosen in the menu, else the schematic's own, else settings.
doc_sim :: proc(d: ^Doc) -> ^Simulator_Def {
	if len(d.sim_override) > 0 {
		if s := simulator_def(d.sim_override); s != nil do return s
	}
	if len(d.sch.simulator) > 0 {
		if s := simulator_def(d.sch.simulator); s != nil do return s
	}
	if s := simulator_def(S.simulator); s != nil do return s
	if len(S.simulators) > 0 do return &S.simulators[0]
	return nil
}

// ---------------------------------------------------------------------------
// Undo

doc_push_undo :: proc(d: ^Doc) {
	append(&d.undo, strings.clone(sch_to_edn(&d.sch)))
	for len(d.undo) > S.undo_levels {
		delete(d.undo[0])
		ordered_remove(&d.undo, 0)
	}
	for s in d.redo do delete(s)
	clear(&d.redo)
	d.dirty = true
}

// Undo snapshot taken earlier (before a drag).
doc_push_undo_text :: proc(d: ^Doc, text: string) {
	append(&d.undo, strings.clone(text))
	for s in d.redo do delete(s)
	clear(&d.redo)
	d.dirty = true
}

@(private = "file")
doc_restore :: proc(d: ^Doc, text: string) {
	s, err := sch_from_edn(text)
	if len(err) > 0 do return
	waves := strings.clone(d.sch.waves)
	sch_free(&d.sch)
	d.sch = s
	set_str(&d.sch.waves, waves)
	delete(waves)
	d.dirty = true
	wave_mark_dirty(&d.wave)
}

doc_undo :: proc(d: ^Doc) {
	if len(d.undo) == 0 do return
	append(&d.redo, strings.clone(sch_to_edn(&d.sch)))
	t := pop(&d.undo)
	doc_restore(d, t)
	delete(t)
}

doc_redo :: proc(d: ^Doc) {
	if len(d.redo) == 0 do return
	append(&d.undo, strings.clone(sch_to_edn(&d.sch)))
	t := pop(&d.redo)
	doc_restore(d, t)
	delete(t)
}

// ---------------------------------------------------------------------------
// Files

status :: proc(msg: string, err := false) {
	set_str(&app.status, msg)
	app.status_err = err
	app.status_time = rl.GetTime()
	if err do log.warn(one_line(msg))
}

open_file :: proc(path: string) -> bool {
	p := abs_path(path)
	for d, i in app.docs do if d.path == p {
		app.cur = i
		return true
	}
	sch, warnings, err := load_schematic_file(p)
	if len(err) > 0 {
		log.warnf("cannot open %s: %s", p, one_line(err))
		message("Cannot open", err)
		return false
	}
	// replace an empty untitled tab
	d: ^Doc
	if cd := doc(); cd != nil && len(cd.path) == 0 && !cd.dirty && len(cd.sch.comps) == 0 && len(cd.sch.wires) == 0 {
		d = cd
		sch_free(&d.sch)
	} else {
		d = doc_new()
	}
	d.sch = sch
	if file_ext_lower(p) != "edn" {
		// imported: saving writes an .edn beside it
		d.path = strings.clone(with_ext(p, "edn"))
		d.dirty = true
	} else {
		d.path = strings.clone(p)
	}
	d.fitted = false
	wave_load_setup(&d.wave, d.sch.waves)
	recent_add(p)
	log.infof("opened %s%s", p, fmt.tprintf(" (%d warning(s))", len(warnings)) if len(warnings) > 0 else "")
	for w in warnings do log.warn(w)
	if len(warnings) > 0 do message("Opened with warnings", strings.join(warnings, "\n", context.temp_allocator))
	else do status(tcat("opened ", p))
	pref_put("last-dir", dir_name(p))
	return true
}

save_doc :: proc(d: ^Doc, path: string) -> bool {
	set_str(&d.sch.waves, wave_save_setup(&d.wave))
	sch_embed(&d.sch, dir_of(path))
	if !write_text(path, sch_to_edn(&d.sch)) {
		log.errorf("cannot write %s", path)
		message("Cannot save", tcat("Could not write ", path))
		return false
	}
	if d.path != path do set_str(&d.path, path)
	d.dirty = false
	recent_add(path)
	pref_put("last-dir", dir_name(path))
	log.infof("saved %s", path)
	status(tcat("saved ", path))
	if S.run_on_save do sim_run(d)
	return true
}

recent_add :: proc(path: string) {
	list := make([dynamic]string, context.temp_allocator)
	append(&list, path)
	for r in pref_list("recent") do if r != path && len(list) < 12 do append(&list, r)
	pref_put_list("recent", list[:])
	prefs_save()
}

doc_close :: proc(i: int) {
	d := app.docs[i]
	doc_free(d)
	ordered_remove(&app.docs, i)
	if len(app.docs) == 0 && !app.quitting do doc_new()
	app.cur = clamp(app.cur, 0, max(0, len(app.docs) - 1))
}

// Closes a tab, asking about unsaved changes first.
request_close :: proc(i: int) {
	d := app.docs[i]
	if d.dirty && S.confirm_close {
		app.cur = i
		dialog_open(.Confirm_Close)
		return
	}
	doc_close(i)
}

request_quit :: proc() {
	app.quitting = true
	save_session()
	for len(app.docs) > 0 {
		last := len(app.docs) - 1
		if app.docs[last].dirty && S.confirm_close {
			app.cur = last
			dialog_open(.Confirm_Close)
			return
		}
		// keep the last tab: quitting can happen mid-frame (from the menu or a dialog) and the
		// rest of the frame still draws doc()
		if last == 0 do break
		doc_close(last)
	}
	app.quit = true
}

save_session :: proc() {
	files := make([dynamic]string, context.temp_allocator)
	for d in app.docs do if len(d.path) > 0 && file_exists(d.path) do append(&files, d.path)
	pref_put_list("open-files", files[:])
	if !rl.IsWindowMaximized() && !rl.IsWindowFullscreen() {
		pref_put_edn("window", fmt.tprintf("[%d %d]", rl.GetScreenWidth(), rl.GetScreenHeight()))
	}
	pref_put_bool("maximized", rl.IsWindowMaximized())
	pref_put_bool("show-waves", app.show_waves)
	pref_put("layout", app.layout)
	pref_put_f64("split", f64(app.split))
	prefs_save()
}

// ---------------------------------------------------------------------------
// Simulation

sim_run :: proc(d: ^Doc) {
	sim := doc_sim(d)
	if sim == nil {
		message("No simulator", "settings.edn has no usable :simulators.")
		return
	}
	if d.run.state == .Running do run_stop(&d.run)
	set_str(&d.sch.waves, wave_save_setup(&d.wave))
	run_start(&d.run, &d.sch, d.path, d.id, sim)
	if d.run.state == .Failed {
		message(tcat(sim.name, ": cannot run"), d.run.message)
		return
	}
	status(fmt.tprintf("running %s …", sim.name))
}

on_run_done :: proc(d: ^Doc) {
	r := &d.run
	if r.state == .Failed {
		msg := r.message
		if len(r.log_text) > 0 && !strings.contains(msg, "stopped") do msg = tcat(msg, "\n\nView › Simulator log shows the whole output.")
		message(tcat(r.sim_name, " failed"), msg)
		return
	}
	// first: the .plot and .meas directives may add warnings
	meas_run(r, &d.sch, doc_sim(d))
	wave_new_run(&d.wave, r, &d.sch, doc_sim(d))
	status(r.message)
	if len(r.measures) > 0 do status(strings.join(r.measures[:], "  ·  ", context.temp_allocator))
	if len(r.warnings) > 0 do status(fmt.tprintf("%s – %d warning%s (View › Simulator log)", r.message, len(r.warnings), "" if len(r.warnings) == 1 else "s"))
	if S.show_waves != "never" do app.show_waves = true
	// probe straight away, whatever tool was active (placing parts, drawing wires …),
	// unless the user is in the middle of a drag or a dialog
	if S.probe_after_run && d.tool != .Probe && d.drag.kind == .None && app.dlg.kind == .None {
		tool_set(d, .Probe)
	}
}

// ---------------------------------------------------------------------------
// Actions

run_action :: proc(name: string) {
	d := doc()
	if d == nil do return
	switch name {
	case "file/new":
		doc_new()
	case "file/open":
		dialog_open(.Open)
	case "file/import-model":
		app.import_for = -1
		dialog_open(.Import_Model)
	case "file/save":
		if len(d.path) == 0 do dialog_open(.Save_As)
		else do save_doc(d, d.path)
	case "file/save-as":
		dialog_open(.Save_As)
	case "file/close":
		request_close(app.cur)
	case "file/export-netlist":
		dialog_open(.Export_Netlist)
	case "file/next-tab":
		if len(app.docs) > 0 do app.cur = (app.cur + 1) % len(app.docs)
	case "file/prev-tab":
		if len(app.docs) > 0 do app.cur = (app.cur + len(app.docs) - 1) % len(app.docs)
	case "file/quit":
		request_quit()
	case "edit/undo":
		doc_undo(d)
	case "edit/redo":
		doc_redo(d)
	case "edit/cut":
		sch_copy(d)
		sch_delete_selection(d)
	case "edit/copy":
		sch_copy(d)
	case "edit/paste":
		sch_paste_start(d, app.clipboard)
	case "edit/duplicate":
		sch_copy(d)
		sch_paste_start(d, app.clipboard)
	case "edit/delete":
		sch_delete_selection(d)
	case "edit/select-all":
		sch_select_all(d, true)
	case "edit/rotate":
		sch_rotate(d)
	case "edit/mirror":
		sch_mirror(d)
	case "edit/properties":
		sch_edit_selected(d)
	case "edit/cancel":
		sch_cancel(d)
	case "place/wire":
		tool_set(d, .Wire)
	case "place/label":
		dialog_open(.Label_Name)
	case "place/directive":
		dialog_text(d, -1, true)
	case "place/comment":
		dialog_text(d, -1, false)
	case "place/component":
		// as loomer: a dialog in the main window, or its own window when it was moved there
		if !(pref_bool("parts-own-window") && parts_window_open()) do dialog_open(.Part_Picker)
	case "symbol/new":
		symed_open(nil)
	case "symbol/edit":
		// the selected part's symbol
		for c, i in d.sch.comps do if c.sel {
			if sym := symbol_find(c.sym); sym != nil && sym.kind == .Part do symed_open(sym, d, i)
			break
		}
	case "place/flip-corner":
		d.wire_flip = !d.wire_flip
	case "view/fit":
		if app.hover_ctx == .Waves && app.show_waves do wave_fit(&d.wave)
		else do d.fitted = false
	case "view/zoom-in":
		if app.hover_ctx == .Waves do wave_zoom(&d.wave, 1 / S.w_zoom_speed)
		else do sch_zoom(d, S.zoom_speed)
	case "view/zoom-out":
		if app.hover_ctx == .Waves do wave_zoom(&d.wave, S.w_zoom_speed)
		else do sch_zoom(d, 1 / S.zoom_speed)
	case "view/toggle-waves":
		if p := popout_of(d.id); p != nil do popout_close(p)
		else do app.show_waves = !app.show_waves
	case "wave/pop-out":
		toggle_popout(d)
	case "view/full-screen":
		toggle_fullscreen()
	case "view/next-layout":
		order := [4]string{"waves-top", "waves-right", "waves-bottom", "waves-left"}
		k := 0
		for o, i in order do if o == app.layout do k = i
		app.layout = order[(k + 1) % 4]
		app.show_waves = true
	case "view/netlist":
		show_netlist(d)
	case "view/log":
		show_log(d)
	case "view/appearance":
		dialog_open(.Appearance)
	case "view/theme":
		if len(themes) > 0 {
			k := 0
			for t, i in themes do if t.name == th.name do k = i
			pick_theme(themes[(k + 1) % len(themes)].name)
		}
	case "sim/run":
		sim_run(d)
	case "sim/stop":
		run_stop(&d.run)
		status("simulation stopped")
	case "sim/edit-command":
		dialog_open(.Sim_Command)
	case "sim/probe":
		tool_set(d, .Select if d.tool == .Probe else .Probe)
	case "sim/simulator":
		dialog_open(.Simulator_Pick)
	case "wave/zoom-back":
		wave_zoom_back(&d.wave)
	case "wave/delete-trace":
		wave_delete_selected(&d.wave)
	case "wave/cursor1":
		wave_toggle_cursor(&d.wave, 0)
	case "wave/cursor2":
		wave_toggle_cursor(&d.wave, 1)
	case "wave/marker":
		wave_add_marker_at_mouse(&d.wave)
	case "wave/add-pane":
		wave_add_pane(&d.wave)
	case "wave/clear":
		wave_clear(&d.wave)
	case "wave/export-csv":
		dialog_open(.Export_CSV)
	case "wave/next-plot":
		wave_next_plot(&d.wave, &d.run, &d.sch, doc_sim(d))
	case "help/shortcuts":
		dialog_open(.Shortcuts)
	case "help/settings":
		open_external(settings_path)
	case "help/config-folder":
		open_external(config_dir())
	case "help/diagnostics":
		show_diagnostics()
	case "help/about":
		dialog_open(.About)
	case:
		if strings.has_prefix(name, "place/") {
			sym := symbol_find(name[6:])
			if sym != nil do place_symbol(d, sym)
		}
	}
}

place_symbol :: proc(d: ^Doc, sym: ^Symbol) {
	switch sym.kind {
	case .Label:
		dialog_open(.Label_Name)
		return
	case .Ground:
		tool_set(d, .Place)
		d.place_kind = .Ground
	case .Part:
		tool_set(d, .Place)
		d.place_kind = .Part
	}
	set_str(&d.place_sym, sym.name)
	d.place_rot = 0
	d.place_mirror = false
}

tool_set :: proc(d: ^Doc, t: Tool) {
	d.tool = t
	d.wire_active = false
	d.drag.kind = .None
	d.probe_from = -1
	if t != .Select do sch_select_all(d, false)
}

// Items of the View menu's submenus.
view_submenu :: proc(label: string) -> []string {
	items := make([dynamic]string, context.temp_allocator)
	switch label {
	case "Theme":
		for t in themes do append(&items, tcat("✓ " if t.name == th.name else "   ", t.name))
	case "UI scale":
		cur := S.scale
		append(&items, tcat("✓ " if cur <= 0 else "   ", fmt.tprintf("Automatic (%d %%)", int(math.round(default_ui_scale() * 100)))))
		for x in MENU_SCALES do append(&items, tcat("✓ " if abs(cur - x) < 0.001 else "   ", fmt.tprintf("%d %%", int(math.round(x * 100)))))
	}
	return items[:]
}

MENU_SCALES := [?]f32{0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3}

// UI scale from the View menu (0 = from the monitor); saved as :ui :scale in settings.edn.
set_ui_scale :: proc(v: f32) {
	S.scale = v
	ui_scale = v if v > 0 else default_ui_scale()
	for d in app.docs do wave_mark_dirty(&d.wave)
	if err := settings_set("ui", "scale", ":auto" if v <= 0 else fmt.tprintf("%g", v)); len(err) > 0 do status(err, true)
	else do status(fmt.tprintf("UI scale %d %%", int(math.round(ui_scale * 100))))
}

pick_theme :: proc(name: string) {
	pref_put("theme", name)
	prefs_save()
	if len(S.theme) > 0 && S.theme != name do status(tcat("settings.edn sets :ui :theme \"", S.theme, "\" – change it there"), true)
	theme_apply()
}

app_on_settings_changed :: proc() {
	theme_apply()
	ui_scale = S.scale if S.scale > 0 else default_ui_scale()
	fonts_init()
	rl.SetTargetFPS(i32(S.fps))
	for d in app.docs do wave_mark_dirty(&d.wave)
	if len(config_errors) > 0 || len(shortcut_errors) > 0 {
		all := make([dynamic]string, context.temp_allocator)
		append(&all, ..config_errors[:])
		append(&all, ..shortcut_errors[:])
		message("Problems in the configuration files", strings.join(all[:], "\n", context.temp_allocator))
	} else {
		status("settings reloaded")
	}
}

// ---------------------------------------------------------------------------
// Keyboard

handle_keys :: proc() {
	if ui.modal || ui.popup_id != 0 do return
	if symed.active && cur_popout == nil do return // the symbol editor has keys of its own
	for &a in actions {
		if a.ctx != .Global && a.ctx != app.hover_ctx do continue
		for c in a.keys {
			plain := !c.ctrl && !c.alt && !(c.key >= .F1 && c.key <= .F12)
			if typing() && (plain || c.ctrl) do continue
			if chord_pressed(c, a.repeat, ui.ctrl, ui.shift, ui.alt) {
				run_action(a.name)
				return
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Window

menu_items :: proc(name: string) -> []string {
	d := doc()
	k :: proc(label, action: string) -> string {
		ks := action_keys_text(action)
		return tcat(label, "\t", ks) if len(ks) > 0 else label
	}
	items := make([dynamic]string, context.temp_allocator)
	switch name {
	case "File":
		append(&items, k("New", "file/new"), k("Open…", "file/open"), k("Save", "file/save"), k("Save as…", "file/save-as"), "-", k("Import SPICE model…", "file/import-model"), "-")
		for r in pref_list("recent")[:min(8, len(pref_list("recent")))] do append(&items, tcat("Recent: ", base_name(r)))
		append(&items, "-", k("Export netlist…", "file/export-netlist"), k("Export waveforms (CSV)…", "wave/export-csv"), "-", k("Close", "file/close"), k("Quit", "file/quit"))
	case "Edit":
		append(&items, k("Undo", "edit/undo") if len(d.undo) > 0 else tcat("~", k("Undo", "edit/undo")), k("Redo", "edit/redo") if len(d.redo) > 0 else tcat("~", k("Redo", "edit/redo")), "-",
			k("Cut", "edit/cut"), k("Copy", "edit/copy"), k("Paste", "edit/paste"), k("Duplicate", "edit/duplicate"), k("Delete", "edit/delete"), "-",
			k("Select all", "edit/select-all"), k("Rotate", "edit/rotate"), k("Mirror", "edit/mirror"), k("Properties…", "edit/properties"))
	case "Place":
		append(&items, k("Part…", "place/component"), k("Wire", "place/wire"), k("Ground", "place/ground"), k("Net label…", "place/label"), k("SPICE directive…", "place/directive"), k("Comment…", "place/comment"), k("Import SPICE model…", "file/import-model"), k("New symbol…", "symbol/new"))
	case "View":
		append(&items, k("Fit to window", "view/fit"), k("Zoom in", "view/zoom-in"), k("Zoom out", "view/zoom-out"), "-",
			k(tcat("✓ " if app.show_waves else "", "Waveforms"), "view/toggle-waves"), k("Move the waveforms", "view/next-layout"),
			k(tcat("✓ " if waves_popped_out(d) else "", "Waveforms in their own window"), "wave/pop-out"), k("Full screen", "view/full-screen"), "-",
			k("Netlist", "view/netlist"), k("Simulator log", "view/log"), "-", k("Appearance (scale, text size)…", "view/appearance"), "-")
		append(&items, "Theme\t▸", "UI scale\t▸")
	case "Simulate":
		append(&items, k("Run", "sim/run"), k("Stop", "sim/stop") if d.run.state == .Running else tcat("~", k("Stop", "sim/stop")), k("Edit simulation command…", "sim/edit-command"), "-",
			k(tcat("✓ " if d.tool == .Probe else "", "Probe"), "sim/probe"), "-")
		cur := doc_sim(d)
		for s in S.simulators do append(&items, tcat("✓ " if cur != nil && cur.id == s.id else "   ", "Simulator: ", s.name))
		append(&items, k("Simulators and their programs…", "sim/simulator"))
	case "Waveforms":
		append(&items, k("Fit", "view/fit"), k("Previous zoom", "wave/zoom-back"), k("Add plot pane", "wave/add-pane"), k("Cursor 1", "wave/cursor1"), k("Cursor 2", "wave/cursor2"), k("Marker at the mouse", "wave/marker"), k("Next analysis", "wave/next-plot"), "-",
			k(tcat("✓ " if waves_popped_out(d) else "", "In their own window"), "wave/pop-out"), "-", "Add trace…", k("Remove all traces", "wave/clear"), k("Export CSV…", "wave/export-csv"))
	case "Help":
		// the same layout as zapped's and loomer's Help menus
		append(&items, k("Keyboard shortcuts…", "help/shortcuts"), "-", k("Settings (settings.edn)", "help/settings"), "Themes (themes.edn)", "Shortcuts (shortcuts.edn)", "Symbols folder", k("Config folder", "help/config-folder"), "-", k("Diagnostics…", "help/diagnostics"), k("About spicy", "help/about"))
	}
	return items[:]
}

menu_pick :: proc(name: string, idx: int) {
	items := menu_items(name)
	if idx < 0 || idx >= len(items) do return
	label, _ := menu_split(items[idx])
	label = strings.trim_left(label, "✓ ~")
	d := doc()
	// submenus (View ▸ Theme, View ▸ UI scale)
	if sub := ui.sub_result; sub >= 0 && (label == "Theme" || label == "UI scale") {
		ui.sub_result = -1
		if label == "Theme" {
			if sub < len(themes) do pick_theme(themes[sub].name)
		} else {
			set_ui_scale(0 if sub == 0 else MENU_SCALES[sub - 1] if sub - 1 < len(MENU_SCALES) else S.scale)
		}
		return
	}
	switch {
	case strings.has_prefix(label, "Recent: "):
		rec := pref_list("recent")
		k := 0
		for it, i in items {
			if strings.has_prefix(it, "Recent: ") {
				if i == idx do break
				k += 1
			}
		}
		if k < len(rec) do open_file(rec[k])
		return
	case strings.has_prefix(label, "Simulator: "):
		n := label[len("Simulator: "):]
		for s in S.simulators do if s.name == n {
			set_str(&d.sim_override, s.id)
			status(tcat("simulator: ", s.name))
		}
		return
	case label == "Add trace…":
		dialog_trace(d, -1, -1)
		return
	case label == "Themes (themes.edn)":
		open_external(themes_file)
		return
	case label == "Shortcuts (shortcuts.edn)":
		open_external(shortcuts_file)
		return
	case label == "Symbols folder":
		open_external(user_symbols_dir())
		return
	}
	// match a label to its action
	MAP := [?][2]string {
		{"New", "file/new"}, {"Open…", "file/open"}, {"Save", "file/save"}, {"Save as…", "file/save-as"},
		{"Export netlist…", "file/export-netlist"}, {"Export waveforms (CSV)…", "wave/export-csv"}, {"Close", "file/close"}, {"Quit", "file/quit"},
		{"Undo", "edit/undo"}, {"Redo", "edit/redo"}, {"Cut", "edit/cut"}, {"Copy", "edit/copy"}, {"Paste", "edit/paste"},
		{"Duplicate", "edit/duplicate"}, {"Delete", "edit/delete"}, {"Select all", "edit/select-all"}, {"Rotate", "edit/rotate"},
		{"Mirror", "edit/mirror"}, {"Properties…", "edit/properties"},
		{"Part…", "place/component"}, {"Wire", "place/wire"}, {"Ground", "place/ground"}, {"Net label…", "place/label"},
		{"SPICE directive…", "place/directive"}, {"Comment…", "place/comment"}, {"New symbol…", "symbol/new"},
		{"Fit to window", "view/fit"}, {"Zoom in", "view/zoom-in"}, {"Zoom out", "view/zoom-out"}, {"Waveforms", "view/toggle-waves"},
		{"Move the waveforms", "view/next-layout"}, {"Netlist", "view/netlist"}, {"Simulator log", "view/log"}, {"Appearance (scale, text size)…", "view/appearance"},
		{"Run", "sim/run"}, {"Stop", "sim/stop"}, {"Edit simulation command…", "sim/edit-command"}, {"Probe", "sim/probe"}, {"Simulators and their programs…", "sim/simulator"},
		{"Fit", "view/fit"}, {"Previous zoom", "wave/zoom-back"}, {"Add plot pane", "wave/add-pane"}, {"Cursor 1", "wave/cursor1"},
		{"Cursor 2", "wave/cursor2"}, {"Marker at the mouse", "wave/marker"}, {"Next analysis", "wave/next-plot"},
		{"Remove all traces", "wave/clear"}, {"Export CSV…", "wave/export-csv"},
		{"Waveforms in their own window", "wave/pop-out"}, {"In their own window", "wave/pop-out"}, {"Full screen", "view/full-screen"},
		{"Import SPICE model…", "file/import-model"},
		{"Keyboard shortcuts…", "help/shortcuts"}, {"Settings (settings.edn)", "help/settings"}, {"Config folder", "help/config-folder"},
		{"Diagnostics…", "help/diagnostics"}, {"About spicy", "help/about"},
	}
	for m in MAP do if m[0] == label {
		if name == "Waveforms" && m[1] == "view/fit" {
			wave_fit(&d.wave)
			return
		}
		run_action(m[1])
		return
	}
	for s in symbols do if s.desc == label {
		place_symbol(d, symbol_find(s.name))
		return
	}
}

draw_menubar :: proc(r: Rect) {
	fill(r, th.bar)
	line(r.x, r.y + r.h - 1, r.x + r.w, r.y + r.h - 1, th.border)
	MENUS := [?]string{"File", "Edit", "Place", "View", "Simulate", "Waveforms", "Help"}
	x := r.x + 4
	for m in MENUS {
		w := text_w(m) + 20
		mr := Rect{x, r.y + 2, w, r.h - 4}
		id := tcat("menu.", m)
		open := app.menu_open == m && ui.popup_id == id_of(id)
		if hover(mr) || open {
			fill_round(mr, th.pressed if open else th.hover, 4)
			// sliding between menus while one is open
			if ui.popup_id != 0 && len(app.menu_open) > 0 && app.menu_open != m && r_contains(mr, ui.mouse) {
				app.menu_open = m
				open_menu(id, mr.x, mr.y + mr.h + 2, menu_items(m))
			}
		}
		if hover(mr) && ui.pressed[0] {
			app.menu_open = m
			open_menu(id, mr.x, mr.y + mr.h + 2, menu_items(m))
		}
		text_in(mr, m, th.fg, 1)
		if idx := menu_result(id); idx >= 0 do menu_pick(m, idx)
		x += w
	}
	// theme picker in the top-right corner, as in loomer
	rr := r
	if len(themes) > 0 && r.w > x + 260 * ui_scale {
		names := make([dynamic]string, context.temp_allocator)
		sel := 0
		for t, i in themes {
			append(&names, t.name)
			if t.name == th.name do sel = i
		}
		cw: f32 = 0
		for n in names do cw = max(cw, text_w(n))
		cw = min(cw + 40, 220 * ui_scale)
		cr := cut_right(&rr, cw + 6)
		cr = {cr.x, r.y + 3, cw, r.h - 6}
		// "Theme" before the box, as in loomer
		lw := text_w("Theme") + 8
		lr := cut_right(&rr, lw)
		text_in({lr.x, r.y, lw, r.h}, "Theme", th.muted, 2, 0, 4)
		if combo("menubar.theme", cr, names[:], &sel) do pick_theme(names[sel])
		if hover(cr) do tooltip(id_of("menubar.theme"), "Theme (also in the View menu; themes.edn)")
	}
	// run state on the right
	d := doc()
	if d.run.state == .Running {
		s := fmt.tprintf("%s running  %.1f s", d.run.sim_name, d.run.elapsed)
		text_in(rr, s, th.warn, 2, fs(0.9), 12)
	}
}

draw_toolbar :: proc(r: Rect) {
	fill(r, th.bar)
	line(r.x, r.y + r.h - 1, r.x + r.w, r.y + r.h - 1, th.border)
	d := doc()
	b := r_inset(r, 3)
	h := b.h
	tb :: proc(b: ^Rect, id, label, tip: string, enabled := true, selected := false, col: Color = {}, icon := Icon.None) -> bool {
		w := max(text_w(label) + 18 + (fs(0.8) + (6 if len(label) > 0 else 0) if icon != .None else 0), b.h)
		r := cut_left(b, w)
		cut_left(b, 2)
		return tool_button(id, r, label, enabled, selected, tip, col, icon)
	}
	sep :: proc(b: ^Rect) {
		r := cut_left(b, 10)
		line(r.x + 5, r.y + 4, r.x + 5, r.y + r.h - 4, th.border)
	}
	ks :: proc(desc, action: string) -> string {
		k := action_keys_text(action)
		return tcat(desc, "  (", k, ")") if len(k) > 0 else desc
	}
	if tb(&b, "tb.new", "New", ks("New schematic", "file/new")) do run_action("file/new")
	if tb(&b, "tb.open", "Open", ks("Open a schematic (.edn or LTspice .asc)", "file/open")) do run_action("file/open")
	if tb(&b, "tb.save", "Save", ks("Save", "file/save")) do run_action("file/save")
	sep(&b)
	if tb(&b, "tb.undo", "Undo", ks("Undo", "edit/undo"), len(d.undo) > 0) do run_action("edit/undo")
	if tb(&b, "tb.redo", "Redo", ks("Redo", "edit/redo"), len(d.redo) > 0) do run_action("edit/redo")
	sep(&b)
	if tb(&b, "tb.wire", "Wire", ks("Draw wires", "place/wire"), true, d.tool == .Wire) do run_action("place/wire")
	if tb(&b, "tb.gnd", "Ground", ks("Ground", "place/ground"), true, d.tool == .Place && d.place_kind == .Ground) do run_action("place/ground")
	if tb(&b, "tb.label", "Label", ks("Net label", "place/label"), true, d.tool == .Place && d.place_kind == .Label) do run_action("place/label")
	quick := [?]string{"res", "cap", "ind", "diode", "voltage"}
	for q in quick {
		sym := symbol_find(q)
		if sym == nil do continue
		// the full name ("Resistor", "Voltage source"), as zapped shows its parts
		name := sym.desc
		if i := strings.index(name, " ("); i > 0 do name = name[:i]
		if tb(&b, tcat("tb.", q), name, ks(sym.desc, tcat("place/", q)), true, d.tool == .Place && d.place_kind == .Part && d.place_sym == q) do place_symbol(d, sym)
	}
	if tb(&b, "tb.parts", "Parts…", ks("Part picker", "place/component")) do run_action("place/component")
	if tb(&b, "tb.dir", ".op", ks("SPICE directive", "place/directive")) do run_action("place/directive")
	sep(&b)
	// the waveform pane, on the right: once there are results to show
	if len(d.run.plots) > 0 && b.w > 260 {
		// named for what a click does; as wide as the longer label, so it does not jump
		label := "Hide waveforms" if app.show_waves else "Show waveforms"
		wr := cut_right(&b, max(text_w("Hide waveforms"), text_w("Show waveforms")) + 18)
		cut_right(&b, 6)
		if tool_button("tb.waves", wr, label, true, false, ks("Show / hide the waveform pane", "view/toggle-waves")) do run_action("view/toggle-waves")
	}
	if tb(&b, "tb.cmd", "Sim cmd…", ks("Edit the simulation command", "sim/edit-command")) do run_action("sim/edit-command")
	if tb(&b, "tb.probe", "Probe", ks("Probe mode: click a wire for its voltage, a part for its current", "sim/probe"), true, d.tool == .Probe) do run_action("sim/probe")
	// simulator choice
	cut_left(&b, 6)
	names := make([dynamic]string, context.temp_allocator)
	sel := 0
	cur := doc_sim(d)
	for s, i in S.simulators {
		append(&names, s.name)
		if cur != nil && s.id == cur.id do sel = i
	}
	if len(names) > 0 && b.w > 140 {
		cr := cut_left(&b, 120 * ui_scale)
		if combo("tb.sim", {cr.x, cr.y + 2, cr.w, h - 4}, names[:], &sel) {
			set_str(&d.sim_override, S.simulators[sel].id)
			status(tcat("simulator: ", S.simulators[sel].name))
		}
		// the simulators dialog (programs); marked when the chosen simulator's program is missing
		missing := cur == nil || len(cur.command) == 0
		if !missing {
			_, found := find_program(cur.command[0])
			missing = !found
		}
		tip := tcat(cur.name, ": program not found – set its path here") if missing && cur != nil else "Simulators and their programs"
		if tb(&b, "tb.simset", "" if missing else "…", ks(tip, "sim/simulator"), true, false, th.warn if missing else {}, .Warn if missing else .None) do run_action("sim/simulator")
	}
	// run / stop, after the simulator it runs
	cut_left(&b, 4)
	if d.run.state == .Running {
		if tb(&b, "tb.stop", "Stop", ks("Stop the simulation", "sim/stop"), true, false, th.err, .Stop) do run_action("sim/stop")
	} else {
		if tb(&b, "tb.run", "Run", ks("Run the simulation", "sim/run"), true, false, th.ok, .Play) do run_action("sim/run")
	}
}

draw_tabs :: proc(r: Rect) {
	fill(r, th.bar)
	x := r.x + 4
	for d, i in app.docs {
		title := doc_title(d)
		xs := max(fs() + 4, 18) // the close box, as big as the text
		w := min(text_w(title) + xs + 26 * ui_scale, 260 * ui_scale)
		tr := Rect{x, r.y + 3, w, r.h - 3}
		sel := i == app.cur
		h := hover(tr)
		if sel do fill_round(tr, th.bg, 5)
		else if h do fill_round(tr, th.hover, 5)
		text_in({tr.x, tr.y, tr.w - xs - 4, tr.h}, fit_text(title, tr.w - xs - 16 * ui_scale), th.fg if sel else th.muted, 0, 0, 10 * ui_scale)
		xr := Rect{tr.x + tr.w - xs - 4, tr.y + (tr.h - xs) / 2, xs, xs}
		if tool_button(tcat("tab.x.", itoa(d.id)), xr, "×") {
			request_close(i)
			return
		}
		if h && ui.pressed[0] && !r_contains(xr, ui.mouse) do app.cur = i
		if h && ui.pressed[2] {
			request_close(i)
			return
		}
		if h do tooltip(id_of(tcat("tab", itoa(d.id))), d.path if len(d.path) > 0 else "not saved yet")
		x += w + 2
	}
	if tool_button("tab.new", {x + 2, r.y + 3, r.h - 3, r.h - 3}, "+", true, false, "New schematic") do run_action("file/new")
}

tool_hint :: proc(d: ^Doc) -> string {
	switch d.tool {
	case .Select:
		return "Click to select, drag to move (Ctrl+drag detaches wires), drag on empty space to select an area. Double-click to edit. Letters place parts (R C L D V I Q M …)."
	case .Wire:
		if d.wire_active do return "Click to add a corner, click a pin or wire to finish. Space flips the corner, right-click or Esc ends the wire."
		return "Click to start a wire. Wires may run through parts: they connect only at the pins."
	case .Place:
		return "Click to place. Ctrl+R rotates, Ctrl+E mirrors, right-click or Esc stops."
	case .Paste:
		return "Click to paste. Ctrl+R rotates, Esc cancels."
	case .Probe:
		return "Probe: click a wire for its voltage, drag from one wire to another for the difference, click a part for its current (Alt+click: power). Ctrl+click: new pane. Esc stops."
	}
	return ""
}

draw_statusbar :: proc(r: Rect) {
	fill(r, th.bar)
	line(r.x, r.y, r.x + r.w, r.y, th.border)
	d := doc()
	msg := app.status
	col := th.err if app.status_err else th.muted
	if len(msg) == 0 || rl.GetTime() - app.status_time > 8 {
		msg = tool_hint(d)
		col = th.muted
	} else do idle_redraw_at(app.status_time + 8.001)
	right := ""
	if sim := doc_sim(d); sim != nil do right = sim.name
	if d.run.state == .Done do right = tcat(right, "  ·  ", d.run.message)
	// the version in the lower-right corner, as in loomer
	ver := tcat("spicy ", SPICY_VERSION)
	vw := text_w(ver, fs(0.9)) + 20
	text_in(r, ver, th.muted, 2, fs(0.9), 10)
	line(r.x + r.w - vw, r.y + 4, r.x + r.w - vw, r.y + r.h - 4, th.border)
	rr := Rect{r.x, r.y, r.w - vw, r.h}
	rw := text_w(right, fs(0.9)) + 20
	text_in({r.x, r.y, rr.w - rw, r.h}, fit_text(msg, rr.w - rw - 20, fs(0.9)), col, 0, fs(0.9), 10)
	text_in(rr, right, th.muted, 2, fs(0.9), 10)
}

// Split the main area between the schematic and the waveforms.
draw_main :: proc(r: Rect) {
	if symed.active {
		symed_draw(r)
		return
	}
	d := doc()
	has_waves := app.show_waves && S.show_waves != "never"
	popped := waves_popped_out(d)
	if S.show_waves == "after-run" && len(d.run.plots) == 0 && len(d.wave.panes) <= 1 && wave_trace_count(&d.wave) == 0 do has_waves = has_waves && false
	if S.show_waves == "always" do has_waves = app.show_waves
	if popped do has_waves = false // they are in their own window
	sr, wr := r, Rect{}
	div: Rect
	vert_layout := app.layout == "waves-left" || app.layout == "waves-right"
	collapse_btn: Rect
	collapse_hot: bool
	collapse_glyph: Icon
	// collapsed waveform pane: a thin strip on its side that opens it again (as loomer's panes)
	if !has_waves && !popped && !app.show_waves && len(d.run.plots) > 0 {
		t := fs() + 8
		strip: Rect
		switch app.layout {
		case "waves-bottom": strip = cut_bottom(&sr, t)
		case "waves-left": strip = cut_left(&sr, t)
		case "waves-right": strip = cut_right(&sr, t)
		case: strip = cut_top(&sr, t)
		}
		hv := hover(strip)
		fill(strip, th.hover if hv else th.bar)
		stroke(strip, th.border)
		icon: Icon
		switch app.layout {
		case "waves-bottom": icon = .Up
		case "waves-left": icon = .Right
		case "waves-right": icon = .Left
		case: icon = .Down
		}
		if vert_layout do draw_icon(icon, strip.x + strip.w / 2, strip.y + strip.h / 2, fs(0.7), th.muted)
		else {
			lw := text_w("Waveforms", fs(0.9))
			x := strip.x + (strip.w - lw - fs()) / 2
			draw_icon(icon, x + fs(0.35), strip.y + strip.h / 2, fs(0.7), th.muted)
			draw_text("Waveforms", x + fs(), strip.y + (strip.h - fs(0.9)) / 2, th.muted, fs(0.9))
		}
		if hv {
			ui.cursor = .POINTING_HAND
			tooltip(id_of("waves.strip"), "Show the waveforms")
			if ui.pressed[0] {
				ui.pressed[0] = false
				run_action("view/toggle-waves")
			}
		}
	}
	if has_waves {
		k := app.split
		switch app.layout {
		case "waves-bottom":
			h := r.h * k
			sr = {r.x, r.y, r.w, r.h - h - 4}
			div = {r.x, sr.y + sr.h, r.w, 4}
			wr = {r.x, div.y + 4, r.w, h}
		case "waves-left":
			w := r.w * k
			wr = {r.x, r.y, w, r.h}
			div = {r.x + w, r.y, 4, r.h}
			sr = {div.x + 4, r.y, r.w - w - 4, r.h}
		case "waves-right":
			w := r.w * k
			sr = {r.x, r.y, r.w - w - 4, r.h}
			div = {sr.x + sr.w, r.y, 4, r.h}
			wr = {div.x + 4, r.y, w, r.h}
		case:
			h := r.h * k
			wr = {r.x, r.y, r.w, h}
			div = {r.x, r.y + h, r.w, 4}
			sr = {r.x, div.y + 4, r.w, r.h - h - 4}
		}
		vertical := vert_layout
		fill(div, th.border)
		// a collapse button in the middle of the divider
		{
			bs := fs() + 4
			cb := Rect{div.x + div.w / 2 - bs / 2, div.y + div.h / 2 - bs / 2, bs, bs}
			if vertical do cb.h = bs * 1.6
			else do cb.w = bs * 1.6
			if vertical do cb.y = div.y + div.h / 2 - cb.h / 2
			else do cb.x = div.x + div.w / 2 - cb.w / 2
			chv := hover(cb)
			collapse_btn, collapse_hot = cb, chv
			glyph: Icon
			switch app.layout {
			case "waves-bottom": glyph = .Down
			case "waves-left": glyph = .Left
			case "waves-right": glyph = .Right
			case: glyph = .Up
			}
			collapse_glyph = glyph
			if chv {
				ui.cursor = .POINTING_HAND
				tooltip(id_of("waves.collapse"), "Hide the waveforms")
				if ui.pressed[0] {
					ui.pressed[0] = false
					run_action("view/toggle-waves")
				}
			}
		}
		if hover({div.x - 2, div.y - 2, div.w + 4, div.h + 4}) {
			ui.cursor = .RESIZE_EW if vertical else .RESIZE_NS
			if ui.pressed[0] do app.split_drag = true
		}
		if app.split_drag {
			ui.cursor = .RESIZE_EW if vertical else .RESIZE_NS
			switch app.layout {
			case "waves-bottom": app.split = (r.y + r.h - ui.mouse.y) / r.h
			case "waves-left": app.split = (ui.mouse.x - r.x) / r.w
			case "waves-right": app.split = (r.x + r.w - ui.mouse.x) / r.w
			case: app.split = (ui.mouse.y - r.y) / r.h
			}
			app.split = clampf32(app.split, 0.12, 0.88)
			if !ui.down[0] do app.split_drag = false
		}
	}
	app.sch_rect = sr
	app.wave_rect = wr
	if !app.split_drag && !ui.modal {
		if has_waves && r_contains(wr, ui.mouse) do app.hover_ctx = .Waves
		else if r_contains(sr, ui.mouse) do app.hover_ctx = .Schematic
	}
	draw_schematic(d, sr)
	if has_waves do draw_waves(d, wr)
	if collapse_btn.w > 0 {
		fill_round(collapse_btn, th.accent if collapse_hot else th.bar, 4)
		stroke_round(collapse_btn, th.border, 4)
		draw_icon(collapse_glyph, collapse_btn.x + collapse_btn.w / 2, collapse_btn.y + collapse_btn.h / 2, fs(0.6), th.accent_fg if collapse_hot else th.muted)
	}
}

// UI scale from the monitor: the larger of resolution/1080p and DPI/112 (as in zapped).
// The scale when settings.edn has :scale :auto: SPICY_SCALE (1.5 or 150%), else from the monitor.
default_ui_scale :: proc() -> f32 {
	if env := os.get_env("SPICY_SCALE", context.temp_allocator); len(env) > 0 {
		t := strings.trim_suffix(env, "%")
		if v, ok := strconv.parse_f64(t); ok && v > 0 do return clamp(f32(v / 100 if strings.has_suffix(env, "%") else v), 0.5, 4)
	}
	return auto_ui_scale()
}

auto_ui_scale :: proc() -> f32 {
	when ODIN_OS == .Darwin do return 1 // macOS scales the window itself
	m := rl.GetCurrentMonitor()
	h := f32(rl.GetMonitorHeight(m))
	w := f32(rl.GetMonitorWidth(m))
	s := h / 1080
	if mm := f32(rl.GetMonitorPhysicalWidth(m)); mm > 50 && w > 0 do s = max(s, w / (mm / 25.4) / 112)
	if d := rl.GetWindowScaleDPI(); d.x > 1 do s = max(s, d.x)
	return clamp(math.round(s * 4) / 4, 1, 4)
}

// ---------------------------------------------------------------------------

gui_main :: proc(files: []string) {
	app_settings_changed_hook = app_on_settings_changed
	flags: rl.ConfigFlags = {.WINDOW_RESIZABLE, .WINDOW_HIGHDPI}
	if S.antialias do flags += {.MSAA_4X_HINT}
	if S.vsync do flags += {.VSYNC_HINT}
	rl.SetConfigFlags(flags)
	log.infof("spicy %s starting (%s/%s, log level %s%s)", SPICY_VERSION, ODIN_OS, ODIN_ARCH, level_name(log_level()), tcat(", log file ", log_file_path()) if len(log_file_path()) > 0 else "")
	rl.SetTraceLogLevel(.INFO) // its INFO lines go to the log at DEBUG (GPU details for the diagnostics)
	w, h := i32(1400), i32(900)
	if wv, ok := pref_value("window"); ok && edn_is_coll(wv) && len(wv.items) == 2 {
		w, h = i32(edn_num(wv.items[0])), i32(edn_num(wv.items[1]))
	}
	if env := os.get_env("SPICY_WINDOW", context.temp_allocator); len(env) > 0 {
		parts := strings.split(env, "x", context.temp_allocator)
		if len(parts) == 2 {
			a, _ := strconv.parse_int(parts[0])
			b, _ := strconv.parse_int(parts[1])
			if a > 200 && b > 200 do w, h = i32(a), i32(b)
		}
	}
	rl.InitWindow(max(w, 640), max(h, 400), "spicy")
	rl.SetExitKey(.KEY_NULL)
	rl.SetWindowMinSize(640, 400)
	popouts_init()
	rl.SetTargetFPS(i32(S.fps))
	// the test hooks count frames: no sleeping then
	idle_init(len(os.get_env("SPICY_SCREENSHOT", context.temp_allocator)) == 0 && len(os.get_env("SPICY_ACTIONS", context.temp_allocator)) == 0)
	if pref_bool("maximized") do rl.MaximizeWindow()
	ui_scale = S.scale if S.scale > 0 else default_ui_scale()
	ui.submenu_fn = view_submenu
	fonts_init()
	app.show_waves = pref_bool("show-waves", true)
	// a copy: the prefs and settings strings are freed when they change
	app.layout = strings.clone(pref_get("layout", S.layout))
	if len(S.layout) > 0 && S.layout != "waves-top" do app.layout = strings.clone(S.layout)
	app.split = f32(pref_f64("split", f64(S.split)))
	opened := false
	for f in files {
		if open_file(f) do opened = true
	}
	if !opened && S.reopen_files do for f in pref_list("open-files") do if file_exists(f) do open_file(f)
	if len(app.docs) == 0 do doc_new()
	app.cur = len(app.docs) - 1 if opened else 0
	if len(config_errors) > 0 || len(shortcut_errors) > 0 do app_on_settings_changed()
	log.infof("GUI ready: %dx%d window, UI scale %.0f%%, theme %s, %d schematic(s)", rl.GetScreenWidth(), rl.GetScreenHeight(), ui_scale * 100, th.name, len(app.docs))
	shot := os.get_env("SPICY_SCREENSHOT", context.allocator)
	frames := 0
	test_actions := os.get_env("SPICY_ACTIONS", context.allocator)
	for !app.quit {
		if rl.WindowShouldClose() && !app.quitting do request_quit()
		if app.quit do break
		idle_wait() // sleeps while nothing happens; checks the config files
		for d in app.docs {
			if run_poll(&d.run) do on_run_done(d)
			if d.run.state == .Running do idle_redraw_at(rl.GetTime() + 0.1) // the elapsed time
		}
		fonts_refresh()
		ui_begin_frame()
		handle_keys()
		rl.BeginDrawing()
		rl.ClearBackground(rlc(th.bg))
		sw, sh := screen_w(), screen_h()
		full := Rect{0, 0, sw, sh}
		mb := cut_top(&full, fs() + 12)
		if S.toolbar do draw_toolbar(cut_top(&full, fs() + 18))
		tabs_r := cut_top(&full, fs() + 14)
		sb := Rect{}
		if S.statusbar do sb = cut_bottom(&full, fs() + 10)
		draw_main(full)
		draw_tabs(tabs_r)
		if S.statusbar do draw_statusbar(sb)
		draw_menubar(mb)
		draw_dialog()
		draw_popup()
		draw_tooltip()
		ui_end_frame()
		rl.EndDrawing()
		popouts_frame()
		free_all(context.temp_allocator)
		frames += 1
		// test hook: SPICY_ACTIONS="sim/run;trace:V(out);trace:I(R1)" runs once at start
		if frames == 3 && len(test_actions) > 0 {
			for a in strings.split(test_actions, ";", context.temp_allocator) {
				switch {
				case strings.has_prefix(a, "trace:"): wave_add_trace(&doc().wave, a[6:], false)
				case strings.has_prefix(a, "pane:"): wave_add_trace(&doc().wave, a[5:], true)
				case strings.has_prefix(a, "fft:"): wave_add_fft(&doc().wave, a[4:])
				case strings.has_prefix(a, "edit:"): // open the editor of a part by name
					for c, i in doc().sch.comps do if c.ref == a[5:] do dialog_part(doc(), i)
				case strings.has_prefix(a, "dblclick:"), strings.has_prefix(a, "rclick:"): // a double- or right-click at x,y (fractions of the window) after the run
					test_click_right = strings.has_prefix(a, "rclick:")
					xy := strings.split(a[strings.index_byte(a, ':') + 1:], ",", context.temp_allocator)
					if len(xy) == 2 {
						fx, _ := parse_eng(xy[0])
						fy, _ := parse_eng(xy[1])
						test_click = {f32(fx), f32(fy)}
						test_click_frame = -1
					}
				case strings.has_prefix(a, "in-waves:"): // run inside the waveform window
					for p in popouts do if p.kind == .Waves do p.test_action = strings.clone(a[9:])
				case: run_action(a)
				}
			}
		}
		busy := false
		for d in app.docs do if d.run.state == .Running do busy = true
		if busy && frames > 20 do frames = 20
		if test_click_frame == -1 && frames == 22 do test_click_frame = 0
		if len(shot) > 0 && frames == 29 do for p in popouts {
			p.shot = strings.concatenate({strings.trim_suffix(shot, ".png"), "-waves.png" if p.kind == .Waves else "-parts.png"})
		}
		if len(shot) > 0 && frames == 30 {
			img := rl.LoadImageFromScreen()
			rl.ExportImage(img, cstr(shot))
			rl.UnloadImage(img)
			app.quit = true
		}
	}
	popouts_shutdown() // remembers the waveform window's place
	// request_quit saved the session before closing the tabs; only the popout places are new
	if app.quitting do prefs_save()
	else do save_session()
	rl.CloseWindow()
}

// Imports a SPICE model file (File › Import SPICE model…): copies it into the models folder,
// makes symbols for its subcircuits and starts placing the first one, or – when the import
// was started from a part's editor – makes the part use the imported model.
import_model :: proc(d: ^Doc, path: string) {
	if text, tok := read_text(path, context.temp_allocator); tok && is_circuit_netlist(text) {
		// a whole circuit (elements, not only .model / .subckt): open it as a schematic
		app.import_for = -1
		if open_file(path) do status(tcat("opened the netlist ", base_name(path), " as a schematic – Save writes it as .edn"))
		return
	}
	res, ok := import_model_file(path)
	if !ok {
		message("Import SPICE model", res.message)
		return
	}
	models_load()
	clear(&config_errors)
	symbols_load()
	app_settings_changed()
	names := make([dynamic]string, context.temp_allocator)
	append(&names, ..res.symbols[:])
	append(&names, ..res.models[:])
	summary := fmt.tprintf("%s → %s", base_name(path), res.file)
	// started from a part's editor: that part gets the model
	if ci := app.import_for; ci >= 0 && ci < len(d.sch.comps) {
		app.import_for = -1
		c := &d.sch.comps[ci]
		sym := symbol_find(c.sym)
		if sym != nil {
			fits := models_for_symbol(sym, sch_models(&d.sch, doc_sim(d), dir_of(d.path)))
			for n in names do for f in fits do if strings.equal_fold(n, f) {
				doc_push_undo(d)
				set_str(&c.value, f)
				// the imported file replaces the schematic's copies of the same names
				replaced := drop_embedded(&d.sch, res.file)
				dialog_part(d, ci)
				note := fmt.tprintf("; it replaces %d model(s) saved in the schematic", replaced) if replaced > 0 else ""
				status(tcat(c.ref, " uses ", f, " (", summary, ")", note))
				return
			}
		}
		message("Import SPICE model", fmt.tprintf("Imported %s, but none of it (%s) fits %s.\nIt is in the part picker under Imported.", summary, strings.join(names[:], ", ", context.temp_allocator), c.ref))
		return
	}
	app.import_for = -1
	if len(res.symbols) > 0 {
		if sym := symbol_find(res.symbols[0]); sym != nil {
			place_symbol(d, sym)
			more := fmt.tprintf(" (+%d more in the part picker, Imported)", len(res.symbols) - 1) if len(res.symbols) > 1 else ""
			status(tcat("imported ", summary, ": placing ", sym.name, more, " – click to place, Esc to stop"))
			return
		}
	}
	message("Import SPICE model", fmt.tprintf("Imported %s.\nModels: %s\n\nThey are now offered in the model list of the matching parts (double-click a diode or transistor).", summary, strings.join(res.models[:], ", ", context.temp_allocator)))
}
