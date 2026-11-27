package spicy

import "core:fmt"
import "core:log"
import os "core:os"
import "core:strings"
import "core:time"

// settings.edn: the user's preferences, merged over the built-in defaults
// (config/settings.edn, built into the binary). Every key of the user's file is checked
// against the defaults, so a typo is reported instead of silently ignored.

DEFAULT_SETTINGS :: #load("../config/settings.edn", string)

// The netlist language a simulator reads.
Dialect :: enum u8 {Spice, Vacask}
DIALECT_NAMES := [Dialect]string{.Spice = "spice", .Vacask = "vacask"}

// Where a simulator writes its results: one raw file ({raw}), or one per analysis in the run folder.
Raw_Files :: enum u8 {Single, Per_Analysis}
RAW_FILES_NAMES := [Raw_Files]string{.Single = "single", .Per_Analysis = "per-analysis"}

// Where the waveforms are, next to the schematic. View › Move the waveforms goes round in this order.
Layout :: enum u8 {Waves_Top, Waves_Right, Waves_Bottom, Waves_Left}
LAYOUT_NAMES := [Layout]string{.Waves_Top = "waves-top", .Waves_Right = "waves-right", .Waves_Bottom = "waves-bottom", .Waves_Left = "waves-left"}

// When the waveform area shows: always, after a run (when there is something to show), never.
Show_Waves :: enum u8 {After_Run, Always, Never}
SHOW_WAVES_NAMES := [Show_Waves]string{.After_Run = "after-run", .Always = "always", .Never = "never"}

// Where a run's files go: beside the schematic, in the state folder, or a folder of its own
// (Settings.output_dir).
Output_Place :: enum u8 {Beside_Schematic, State_Folder, Folder}

Simulator_Def :: struct {
	id:             string, // "ngspice"
	name:           string,
	dialect:        Dialect,
	raw:            Raw_Files,
	sense_currents: bool,
	command:        []string,
	lines:          []string,
	voltage:        string,
	current:        string,
	pin_current:    string,
	source_current: string,
}

Settings :: struct {
	// ui
	theme:            string,
	scale:            f32, // 0 = automatic
	font, mono_font:  string,
	font_size:        f32,
	layout:           Layout,
	split:            f32,
	show_waves:       Show_Waves,
	toolbar:          bool,
	statusbar:        bool,
	antialias:        bool,
	fps:              int,
	vsync:            bool,
	confirm_close:    bool,
	reopen_files:     bool,
	tooltips:         bool,
	tooltip_delay:    f64,
	// schematic
	grid:             int,
	grid_style:       string,
	grid_major:       int,
	line_width:       f32,
	wire_width:       f32,
	junction_radius:  f32,
	pin_radius:       f32,
	text_size:        f32,
	show_refs:        bool,
	show_values:      bool,
	zoom_speed:       f32,
	zoom_min:         f32,
	zoom_max:         f32,
	initial_zoom:     f32,
	wire_routing:     string,
	cut_through:      bool,
	auto_end_wire:    bool,
	continue_placing: bool,
	rubber_band:      bool,
	fit_on_open:      bool,
	hover_highlight:  bool,
	highlight_net:    bool,
	show_op_values:   bool,
	pan_right_drag:   bool,
	net_prefix:       string,
	undo_levels:      int,
	// waveform
	w_line_width:     f32,
	w_line_hover:     f32,
	w_grid:           bool,
	w_grid_style:     string,
	w_minor_grid:     bool,
	w_font_size:      f32,
	w_legend:         bool,
	w_hover_readout:  bool,
	w_snap:           bool,
	w_cursor_box:     bool,
	w_ac_display:     string,
	w_phase_dashed:   bool,
	w_phase_unwrap:   bool,
	w_decimate:       bool,
	w_y_margin:       f64,
	w_zoom_speed:     f64,
	w_marker_radius:  f32,
	w_keep_traces:    bool,
	w_new_pane_for:   string,
	w_popout_fullscreen: bool,
	w_double_click: string,
	embed_models: bool,
	w_max_tooltip:    int,
	w_fft_window:     int, // index into FFT_WINDOWS
	w_fft_db:         bool,
	w_fft_log:        bool,
	w_fft_db_range:   f64,
	w_fft_max_points: int,
	w_fft_all:        bool, // FFT of the whole run, not the time range shown
	// simulation
	simulator:        string,
	output_place:     Output_Place,
	output_dir:       string, // the folder, for output_place .Folder
	probe_after_run:  bool,
	run_on_save:      bool,
	default_models:   bool,
	model_libraries:  []string,
	extra_lines:      []string,
	timeout:          f64,
	simulators:       [dynamic]Simulator_Def,
	symbol_folders:   []string,
}

S: Settings
settings_path: string

@(private = "file")
defaults_tree, user_tree: Edn
@(private = "file")
settings_arena_gen: int

// Looks a value up by path in the user's settings, then in the defaults.
cfg :: proc(path: ..string) -> Edn {
	lookup :: proc(t: Edn, path: []string) -> (Edn, bool) {
		cur := t
		for k in path {
			v, ok := edn_get(cur, k)
			if !ok do return {}, false
			cur = v
		}
		return cur, true
	}
	if v, ok := lookup(user_tree, path); ok do return v
	v, _ := lookup(defaults_tree, path)
	return v
}

cfg_f :: proc(path: ..string) -> f64 {
	v := cfg(..path)
	if edn_is_num(v) do return edn_num(v)
	d := defaults_value(..path)
	if edn_is_num(d) {
		config_error(fmt.tprintf("settings.edn: :%s should be a number", strings.join(path, " :", context.temp_allocator)))
		return edn_num(d)
	}
	return 0
}

cfg_b :: proc(path: ..string) -> bool {
	v := cfg(..path)
	if v.kind == .Bool do return v.b
	if v.kind == .Nil do return false
	d := defaults_value(..path)
	return d.kind == .Bool && d.b
}

// A keyword setting that is one of an enum's names; fallback when it is not set. A value
// that is none of them is reported, and the default settings' value is used.
cfg_enum :: proc(names: [$E]string, fallback: E, path: ..string) -> E {
	v := cfg(..path)
	if v.kind == .Nil do return fallback
	if v.kind == .String || v.kind == .Keyword || v.kind == .Symbol {
		if e, ok := enum_from_name(names, v.s); ok do return e
	}
	choices := make([dynamic]string, context.temp_allocator)
	for n in names do append(&choices, tcat(":", n))
	config_error(fmt.tprintf("settings.edn: :%s %s is not one of %s", strings.join(path, " :", context.temp_allocator), edn_to_string(v, context.temp_allocator), strings.join(choices[:], " ", context.temp_allocator)))
	d := defaults_value(..path)
	if e, ok := enum_from_name(names, d.s); ok do return e
	return fallback
}

// Strings and keywords both read as text (without the colon).
cfg_s :: proc(path: ..string) -> string {
	v := cfg(..path)
	#partial switch v.kind {
	case .String, .Keyword, .Symbol: return strings.clone(v.s)
	case .Int, .Float: return fmt.aprintf("%v", edn_num(v))
	}
	return ""
}

cfg_list :: proc(path: ..string) -> []string {
	v := cfg(..path)
	out := make([dynamic]string)
	if edn_is_coll(v) {
		for x in v.items do #partial switch x.kind {
		case .String, .Keyword, .Symbol: append(&out, strings.clone(x.s))
		}
	}
	return out[:]
}

@(private = "file")
defaults_value :: proc(path: ..string) -> Edn {
	cur := defaults_tree
	for k in path {
		v, ok := edn_get(cur, k)
		if !ok do return {}
		cur = v
	}
	return cur
}

// Reports keys of the user's file that the defaults do not have.
@(private = "file")
check_keys :: proc(user, def: Edn, where_: string) {
	if user.kind != .Map || def.kind != .Map do return
	for i := 0; i + 1 < len(user.items); i += 2 {
		k := user.items[i]
		name := k.s
		dv, ok := edn_get(def, name)
		if !ok {
			// simulators may be added freely
			if where_ == ":simulators" do continue
			config_error(fmt.tprintf("settings.edn: unknown setting %s :%s", where_, name))
			continue
		}
		if where_ == ":simulators" do continue
		check_keys(user.items[i + 1], dv, tcat(where_, " :", name) if len(where_) > 0 else tcat(":", name))
	}
}

settings_load :: proc() {
	// Settings strings live as long as the program; reloading leaks a little, which is fine
	// for a file edited by hand.
	d, derr := edn_parse(DEFAULT_SETTINGS)
	if len(derr) > 0 do log.errorf("built-in settings: %s", derr)
	defaults_tree = d
	text, path := read_config_file("settings.edn", DEFAULT_SETTINGS)
	settings_path = strings.clone(path)
	u, err := edn_parse(strings.clone(text))
	user_tree = {}
	if len(err) > 0 {
		config_error(fmt.tprintf("settings.edn: %s – using the defaults", err))
	} else if u.kind != .Map {
		config_error("settings.edn: expected a map {…} – using the defaults")
	} else {
		user_tree = u
		check_keys(u, d, "")
	}
	settings_apply()
	watch_file(settings_path, settings_reload)
}

settings_reload :: proc() {
	clear(&config_errors)
	settings_load()
	themes_load()
	app_settings_changed()
}

@(private = "file")
settings_apply :: proc() {
	s := &S
	s.theme = cfg_s("ui", "theme")
	sv := cfg("ui", "scale")
	s.scale = f32(edn_num(sv)) if edn_is_num(sv) else 0
	s.font = cfg_s("ui", "font")
	s.mono_font = cfg_s("ui", "mono-font")
	s.font_size = f32(clampf(cfg_f("ui", "font-size"), 8, 40))
	s.layout = cfg_enum(LAYOUT_NAMES, Layout.Waves_Top, "ui", "layout")
	s.split = f32(clampf(cfg_f("ui", "split"), 0.1, 0.9))
	s.show_waves = cfg_enum(SHOW_WAVES_NAMES, Show_Waves.After_Run, "ui", "show-waves")
	s.toolbar = cfg_b("ui", "toolbar")
	s.statusbar = cfg_b("ui", "statusbar")
	s.antialias = cfg_b("ui", "antialias")
	s.fps = int(clampf(cfg_f("ui", "fps"), 10, 480))
	s.vsync = cfg_b("ui", "vsync")
	s.confirm_close = cfg_b("ui", "confirm-close")
	s.reopen_files = cfg_b("ui", "reopen-files")
	s.tooltips = cfg_b("ui", "tooltips")
	s.tooltip_delay = cfg_f("ui", "tooltip-delay")

	s.grid = max(1, int(cfg_f("schematic", "grid")))
	s.grid_style = cfg_s("schematic", "grid-style")
	s.grid_major = max(1, int(cfg_f("schematic", "grid-major")))
	s.line_width = f32(cfg_f("schematic", "line-width"))
	s.wire_width = f32(cfg_f("schematic", "wire-width"))
	s.junction_radius = f32(cfg_f("schematic", "junction-radius"))
	s.pin_radius = f32(cfg_f("schematic", "pin-radius"))
	s.text_size = f32(clampf(cfg_f("schematic", "text-size"), 6, 60))
	s.show_refs = cfg_b("schematic", "show-refs")
	s.show_values = cfg_b("schematic", "show-values")
	s.zoom_speed = f32(clampf(cfg_f("schematic", "zoom-speed"), 1.01, 3))
	s.zoom_min = f32(clampf(cfg_f("schematic", "zoom-min"), 0.01, 1))
	s.zoom_max = f32(clampf(cfg_f("schematic", "zoom-max"), 1, 100))
	s.initial_zoom = f32(clampf(cfg_f("schematic", "initial-zoom"), 0.1, 20))
	s.wire_routing = cfg_s("schematic", "wire-routing")
	s.cut_through = cfg_b("schematic", "cut-through-parts")
	s.auto_end_wire = cfg_b("schematic", "auto-end-wire")
	s.continue_placing = cfg_b("schematic", "continue-placing")
	s.rubber_band = cfg_b("schematic", "rubber-band-wires")
	s.fit_on_open = cfg_b("schematic", "fit-on-open")
	s.hover_highlight = cfg_b("schematic", "hover-highlight")
	s.highlight_net = cfg_b("schematic", "highlight-net")
	s.show_op_values = cfg_b("schematic", "show-op-values")
	s.pan_right_drag = cfg_b("schematic", "pan-with-right-drag")
	s.net_prefix = cfg_s("schematic", "auto-name-nets")
	if len(s.net_prefix) == 0 do s.net_prefix = "N"
	s.undo_levels = int(clampf(cfg_f("schematic", "undo-levels"), 1, 10000))

	s.w_line_width = f32(cfg_f("waveform", "line-width"))
	s.w_line_hover = f32(cfg_f("waveform", "line-width-hover"))
	s.w_grid = cfg_b("waveform", "grid")
	s.w_grid_style = cfg_s("waveform", "grid-style")
	s.w_minor_grid = cfg_b("waveform", "minor-grid")
	s.w_font_size = f32(clampf(cfg_f("waveform", "font-size"), 6, 40))
	s.w_legend = cfg_s("waveform", "legend") != "none"
	s.w_hover_readout = cfg_b("waveform", "hover-readout")
	s.w_snap = cfg_b("waveform", "snap-to-trace")
	s.w_cursor_box = cfg_s("waveform", "cursor-readout") != "statusbar"
	s.w_ac_display = cfg_s("waveform", "ac-display")
	s.w_phase_dashed = cfg_b("waveform", "phase-dashed")
	s.w_phase_unwrap = cfg_b("waveform", "phase-unwrap")
	s.w_decimate = cfg_b("waveform", "decimate")
	s.w_y_margin = clampf(cfg_f("waveform", "y-margin"), 0, 0.45)
	s.w_zoom_speed = clampf(cfg_f("waveform", "zoom-speed"), 1.01, 3)
	s.w_marker_radius = f32(cfg_f("waveform", "marker-radius"))
	s.w_keep_traces = cfg_b("waveform", "keep-traces")
	s.w_new_pane_for = cfg_s("waveform", "new-pane-for")
	s.w_popout_fullscreen = cfg_b("waveform", "pop-out-full-screen")
	s.w_double_click = cfg_s("waveform", "double-click")
	s.embed_models = cfg_b("schematic", "embed-models")
	s.w_max_tooltip = int(cfg_f("waveform", "max-points-tooltip"))
	{
		name := cfg_s("waveform", "fft-window")
		defer delete(name)
		s.w_fft_window = fft_window_index(name)
		if s.w_fft_window < 0 {
			config_error(fmt.tprintf("settings.edn: :waveform :fft-window :%s is not one of :%s", name, strings.join(FFT_WINDOWS[:], " :", context.temp_allocator)))
			s.w_fft_window = 0
		}
	}
	s.w_fft_db = cfg_b("waveform", "fft-db")
	s.w_fft_log = cfg_b("waveform", "fft-log-freq")
	s.w_fft_db_range = max(cfg_f("waveform", "fft-db-range"), 0)
	{
		want := clampf(cfg_f("waveform", "fft-max-points"), 1024, 1 << 22)
		n := 1024
		for f64(n) * 1.5 < want do n <<= 1 // nearest power of two
		s.w_fft_max_points = n
		r := cfg_s("waveform", "fft-range")
		defer delete(r)
		if r != "shown" && r != "all" do config_error(fmt.tprintf("settings.edn: :waveform :fft-range :%s is not :shown or :all", r))
		s.w_fft_all = r == "all"
	}

	s.simulator = cfg_s("simulation", "simulator")
	{
		place := cfg_s("simulation", "output-dir")
		switch place {
		case "beside-schematic", "": s.output_place = .Beside_Schematic; delete(place)
		case "state-folder": s.output_place = .State_Folder; delete(place)
		case: s.output_place, s.output_dir = .Folder, place
		}
	}
	s.probe_after_run = cfg_b("simulation", "probe-after-run")
	s.run_on_save = cfg_b("simulation", "run-on-save")
	s.default_models = cfg_b("simulation", "default-models")
	s.model_libraries = cfg_list("simulation", "model-libraries")
	s.extra_lines = cfg_list("simulation", "extra-lines")
	s.timeout = cfg_f("simulation", "timeout")

	s.simulators = make([dynamic]Simulator_Def)
	add_sims :: proc(t: Edn) {
		sims, ok := edn_get(t, "simulators")
		if !ok || sims.kind != .Map do return
		for i := 0; i + 1 < len(sims.items); i += 2 {
			id := sims.items[i].s
			exists := false
			for x in S.simulators do if x.id == id do exists = true
			if exists do continue
			sd := Simulator_Def{id = strings.clone(id)}
			sd.name = cfg_s("simulators", id, "name")
			if len(sd.name) == 0 do sd.name = sd.id
			sd.dialect = cfg_enum(DIALECT_NAMES, Dialect.Spice, "simulators", id, "dialect")
			sd.raw = cfg_enum(RAW_FILES_NAMES, Raw_Files.Single, "simulators", id, "raw")
			sd.sense_currents = cfg_b("simulators", id, "sense-currents")
			sd.command = cfg_list("simulators", id, "command")
			sd.lines = cfg_list("simulators", id, "lines")
			sd.voltage = cfg_s("simulators", id, "voltage")
			sd.current = cfg_s("simulators", id, "current")
			sd.pin_current = cfg_s("simulators", id, "pin-current")
			sd.source_current = cfg_s("simulators", id, "source-current")
			if len(sd.voltage) == 0 do sd.voltage = "v({net})"
			if len(sd.current) == 0 do sd.current = "i({ref})"
			if len(sd.pin_current) == 0 do sd.pin_current = sd.current
			if len(sd.source_current) == 0 do sd.source_current = "i({ref})"
			if len(sd.command) == 0 {
				config_error(fmt.tprintf("settings.edn: simulator :%s has no :command", id))
				continue
			}
			append(&S.simulators, sd)
		}
	}
	// the built-in simulators in their order (setting one's program must not move it), then the
	// user's own
	add_sims(defaults_tree)
	add_sims(user_tree)
	s.symbol_folders = cfg_list("symbols", "folders")
	if simulator_def(s.simulator) == nil {
		config_error(fmt.tprintf("settings.edn: :simulation :simulator :%s is not in :simulators", s.simulator))
	}
}

simulator_def :: proc(id: string) -> ^Simulator_Def {
	for &s in S.simulators do if s.id == id do return &s
	return nil
}

// ---------------------------------------------------------------------------
// The program of a simulator, set from the GUI (Simulate › Simulators…). Only the first
// element of its :command in the user's settings.edn changes; the rest of the file (comments,
// layout) stays as it is. Missing parts (:simulators, the simulator, :command) are added.

settings_set_program :: proc(id, program: string) -> (err: string) {
	sim := simulator_def(id)
	if sim == nil do return tcat("unknown simulator ", id)
	text, ok := read_text(settings_path, context.temp_allocator)
	if !ok do return tcat("cannot read ", settings_path)
	root, perr := edn_parse(text, context.temp_allocator)
	if len(perr) > 0 || root.kind != .Map do return tcat("settings.edn cannot be read (", perr, "): fix it first")
	q := edn_quoted(program)
	// the whole command, with the new program, for the places that need it all
	full := strings.builder_make(context.temp_allocator)
	strings.write_string(&full, "[")
	strings.write_string(&full, q)
	for a in sim.command[1:] if len(sim.command) > 0 else nil {
		strings.write_byte(&full, ' ')
		strings.write_string(&full, edn_quoted(a))
	}
	strings.write_string(&full, "]")
	new_text := ""
	splice :: proc(text: string, at, end: int, s: string) -> string {return tcat(text[:at], s, text[end:])}
	// the position just after the "{" or "[" that opens a collection
	inside :: proc(v: Edn) -> int {return v.start + 1}
	sims, has_sims := edn_get(root, "simulators")
	if !has_sims || sims.kind != .Map {
		new_text = splice(text, root.end - 1, root.end - 1, fmt.tprintf("\n ;; set in Simulate › Simulators…\n :simulators {{:%s {{:command %s}}}\n", id, strings.to_string(full)))
	} else if sd, has_sd := edn_get(sims, id); !has_sd || sd.kind != .Map {
		new_text = splice(text, inside(sims), inside(sims), fmt.tprintf(":%s {{:command %s}\n  ", id, strings.to_string(full)))
	} else if cmd, has_cmd := edn_get(sd, "command"); !has_cmd || cmd.kind != .Vector {
		if has_cmd {
			new_text = splice(text, cmd.start, cmd.end, strings.to_string(full))
		} else {
			new_text = splice(text, inside(sd), inside(sd), fmt.tprintf(":command %s ", strings.to_string(full)))
		}
	} else if len(cmd.items) == 0 {
		new_text = splice(text, cmd.start, cmd.end, strings.to_string(full))
	} else {
		new_text = splice(text, cmd.items[0].start, cmd.items[0].end, q)
	}
	// check before writing: the file must still read, with the new program in place
	check, cerr := edn_parse(new_text, context.temp_allocator)
	if len(cerr) > 0 do return tcat("could not update settings.edn (", cerr, ")")
	got := ""
	if s1, ok1 := edn_get(check, "simulators"); ok1 {
		if s2, ok2 := edn_get(s1, id); ok2 {
			if c, ok3 := edn_get(s2, "command"); ok3 && len(c.items) > 0 do got = c.items[0].s
		}
	}
	if got != program do return "could not update settings.edn (unexpected layout): edit :simulators by hand"
	if !write_text(settings_path, new_text) do return tcat("cannot write ", settings_path)
	settings_reload()
	return ""
}

// Sets one value in settings.edn (value as EDN text, e.g. "1.5" or ":auto"), keeping the rest
// of the file (comments, layout) as it is, and reloads the settings.
settings_set :: proc(section, key, value: string) -> (err: string) {
	text, ok := read_text(settings_path, context.temp_allocator)
	if !ok do return tcat("cannot read ", settings_path)
	root, perr := edn_parse(text, context.temp_allocator)
	if len(perr) > 0 || root.kind != .Map do return tcat("settings.edn cannot be read (", perr, "): fix it first")
	new_text := ""
	sec, has_sec := edn_get(root, section)
	switch {
	case !has_sec || sec.kind != .Map:
		if has_sec do return tcat("settings.edn: :", section, " is not a map {…}: fix it first")
		new_text = tcat(text[:root.end - 1], fmt.tprintf("\n :%s {{:%s %s}\n", section, key, value), text[root.end - 1:])
	case:
		if v, has := edn_get(sec, key); has {
			new_text = tcat(text[:v.start], value, text[v.end:])
		} else {
			new_text = tcat(text[:sec.start + 1], fmt.tprintf(":%s %s\n  ", key, value), text[sec.start + 1:])
		}
	}
	// check before writing: the file must still read, with the value in place
	check, cerr := edn_parse(new_text, context.temp_allocator)
	if len(cerr) > 0 do return tcat("could not update settings.edn (", cerr, ")")
	want, _ := edn_parse(value, context.temp_allocator)
	s2, _ := edn_get(check, section)
	got, gok := edn_get(s2, key)
	if !gok || edn_to_string(got) != edn_to_string(want) do return tcat("could not update settings.edn (unexpected layout): set :", section, " :", key, " by hand")
	if !write_text(settings_path, new_text) do return tcat("cannot write ", settings_path)
	settings_reload()
	return ""
}

// Where a simulator's program is: an absolute or relative path, ~/…, or a name found on the
// PATH (with .exe on Windows).
find_program :: proc(cmd: string) -> (path: string, ok: bool) {
	// looked up again at most every 2 s (the toolbar asks every frame)
	Found :: struct {path: string, ok: bool, at: time.Tick}
	@(static) cache: map[string]Found
	if f, hit := cache[cmd]; hit && time.duration_seconds(time.tick_since(f.at)) < 2 do return f.path, f.ok
	path, ok = find_program_now(cmd)
	if old, hit := cache[cmd]; hit {
		delete(old.path)
		cache[cmd] = Found{strings.clone(path), ok, time.tick_now()}
	} else {
		cache[strings.clone(cmd)] = Found{strings.clone(path), ok, time.tick_now()}
	}
	return
}

@(private = "file")
find_program_now :: proc(cmd: string) -> (path: string, ok: bool) {
	c := strings.trim_space(cmd)
	if len(c) == 0 do return "", false
	if strings.has_prefix(c, "~/") || strings.has_prefix(c, "~\\") do c = path_join(home_dir(), c[2:])
	exts := []string{"", ".exe", ".bat", ".cmd"} when ODIN_OS == .Windows else []string{""}
	if strings.contains_any(c, "/\\") {
		for e in exts do if p := tcat(c, e); file_exists(p) do return abs_path(p), true
		return c, false
	}
	sep := ";" when ODIN_OS == .Windows else ":"
	for d in strings.split(os.get_env("PATH", context.temp_allocator), sep, context.temp_allocator) {
		if len(d) == 0 do continue
		for e in exts do if p := path_join(d, tcat(c, e)); file_exists(p) && !dir_exists(p) do return p, true
	}
	return c, false
}
