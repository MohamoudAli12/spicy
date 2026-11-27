package spicy

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

// Keyboard shortcuts: every command is a named action; config/shortcuts.edn (built in)
// gives the default keys, shortcuts.edn in the config folder overrides them per action.

DEFAULT_SHORTCUTS :: #load("../config/shortcuts.edn", string)

Key_Ctx :: enum u8 {Global, Schematic, Waves}

Key_Chord :: struct {
	key:              rl.KeyboardKey,
	ctrl, shift, alt: bool,
}

Action :: struct {
	name:  string, // "file/save"
	desc:  string,
	ctx:   Key_Ctx,
	keys:  [dynamic]Key_Chord,
	repeat: bool,
}

actions: [dynamic]Action
actions_gen: int // bumped by shortcuts_load
shortcut_errors: [dynamic]string
shortcuts_file: string

Action_Info :: struct {
	name, desc: string,
	ctx:        Key_Ctx,
	repeat:     bool,
}

ACTION_INFO := [?]Action_Info {
	{"file/new", "New schematic", .Global, false},
	{"file/open", "Open a schematic (.edn, LTspice .asc)", .Global, false},
	{"file/save", "Save", .Global, false},
	{"file/save-as", "Save as…", .Global, false},
	{"file/close", "Close the schematic", .Global, false},
	{"file/export-netlist", "Export the netlist…", .Global, false},
	{"file/next-tab", "Next schematic", .Global, false},
	{"file/prev-tab", "Previous schematic", .Global, false},
	{"file/quit", "Quit", .Global, false},
	{"edit/undo", "Undo", .Global, true},
	{"edit/redo", "Redo", .Global, true},
	{"edit/cut", "Cut", .Schematic, false},
	{"edit/copy", "Copy", .Schematic, false},
	{"edit/paste", "Paste", .Schematic, false},
	{"edit/duplicate", "Duplicate the selection", .Schematic, false},
	{"edit/delete", "Delete the selection", .Schematic, false},
	{"edit/select-all", "Select all", .Schematic, false},
	{"edit/rotate", "Rotate (also while placing)", .Schematic, false},
	{"edit/mirror", "Mirror (also while placing)", .Schematic, false},
	{"edit/properties", "Edit the selected part, label or text", .Schematic, false},
	{"edit/cancel", "Stop placing or drawing, leave probe mode, deselect", .Global, false},
	{"place/wire", "Draw wires", .Schematic, false},
	{"place/label", "Place a net label", .Schematic, false},
	{"place/directive", "Place a SPICE directive", .Schematic, false},
	{"place/comment", "Place a comment", .Schematic, false},
	{"place/component", "Part picker", .Schematic, false},
	{"place/flip-corner", "Wire corner the other way", .Schematic, false},
	{"view/fit", "Fit to window", .Global, false},
	{"view/zoom-in", "Zoom in", .Global, true},
	{"view/zoom-out", "Zoom out", .Global, true},
	{"view/toggle-waves", "Show / hide the waveforms", .Global, false},
	{"view/next-layout", "Move the waveforms (top, right, bottom, left)", .Global, false},
	{"view/netlist", "Show the netlist", .Global, false},
	{"view/log", "Show the simulator log", .Global, false},
	{"view/appearance", "Appearance (UI scale, text size)…", .Global, false},
	{"view/theme", "Next theme", .Global, false},
	{"sim/run", "Run the simulation", .Global, false},
	{"sim/stop", "Stop the simulation", .Global, false},
	{"sim/edit-command", "Edit the simulation command", .Global, false},
	{"sim/probe", "Probe mode on / off", .Global, false},
	{"sim/simulator", "Simulators: choose one, set their programs", .Global, false},
	{"wave/zoom-back", "Previous zoom", .Waves, false},
	{"wave/delete-trace", "Delete the selected trace", .Waves, false},
	{"wave/cursor1", "Cursor 1 on / off", .Waves, false},
	{"wave/cursor2", "Cursor 2 on / off", .Waves, false},
	{"wave/marker", "Marker on the trace at the mouse", .Waves, false},
	{"wave/add-pane", "Add a plot pane", .Global, false},
	{"wave/clear", "Remove all traces", .Global, false},
	{"wave/export-csv", "Export the waveforms as CSV…", .Global, false},
	{"wave/next-plot", "Next analysis of the run", .Waves, false},
	{"file/import-model", "Import a SPICE model file (makes symbols for its subcircuits)", .Global, false},
	{"symbol/new", "New symbol (the symbol editor)", .Global, false},
	{"symbol/edit", "Edit the selected part's symbol", .Schematic, false},
	{"wave/pop-out", "Waveforms in their own window / back", .Global, false},
	{"view/full-screen", "Full screen (the waveform window or the main window)", .Global, false},
	{"help/shortcuts", "Keyboard shortcuts", .Global, false},
	{"help/settings", "Open settings.edn", .Global, false},
	{"help/config-folder", "Open the config folder", .Global, false},
	{"help/diagnostics", "Diagnostics (versions, paths, environment)", .Global, false},
	{"help/about", "About spicy", .Global, false},
}

@(private = "file")
Key_Name :: struct {
	name: string,
	key:  rl.KeyboardKey,
}

@(private = "file")
KEY_NAMES := [?]Key_Name {
	{"A", .A}, {"B", .B}, {"C", .C}, {"D", .D}, {"E", .E}, {"F", .F}, {"G", .G}, {"H", .H}, {"I", .I},
	{"J", .J}, {"K", .K}, {"L", .L}, {"M", .M}, {"N", .N}, {"O", .O}, {"P", .P}, {"Q", .Q}, {"R", .R},
	{"S", .S}, {"T", .T}, {"U", .U}, {"V", .V}, {"W", .W}, {"X", .X}, {"Y", .Y}, {"Z", .Z},
	{"0", .ZERO}, {"1", .ONE}, {"2", .TWO}, {"3", .THREE}, {"4", .FOUR},
	{"5", .FIVE}, {"6", .SIX}, {"7", .SEVEN}, {"8", .EIGHT}, {"9", .NINE},
	{"F1", .F1}, {"F2", .F2}, {"F3", .F3}, {"F4", .F4}, {"F5", .F5}, {"F6", .F6},
	{"F7", .F7}, {"F8", .F8}, {"F9", .F9}, {"F10", .F10}, {"F11", .F11}, {"F12", .F12},
	{"Esc", .ESCAPE}, {"Escape", .ESCAPE}, {"Enter", .ENTER}, {"Return", .ENTER}, {"Tab", .TAB},
	{"Space", .SPACE}, {"Backspace", .BACKSPACE}, {"Del", .DELETE}, {"Delete", .DELETE},
	{"Ins", .INSERT}, {"Insert", .INSERT}, {"Home", .HOME}, {"End", .END},
	{"PgUp", .PAGE_UP}, {"PageUp", .PAGE_UP}, {"PgDn", .PAGE_DOWN}, {"PageDown", .PAGE_DOWN},
	{"Left", .LEFT}, {"Right", .RIGHT}, {"Up", .UP}, {"Down", .DOWN},
	{"=", .EQUAL}, {"Equal", .EQUAL}, {"-", .MINUS}, {"Minus", .MINUS},
	{"[", .LEFT_BRACKET}, {"]", .RIGHT_BRACKET}, {";", .SEMICOLON}, {"'", .APOSTROPHE},
	{",", .COMMA}, {"Comma", .COMMA}, {".", .PERIOD}, {"Period", .PERIOD},
	{"/", .SLASH}, {"Slash", .SLASH}, {"\\", .BACKSLASH}, {"`", .GRAVE}, {"Backquote", .GRAVE},
	{"Num0", .KP_0}, {"Num1", .KP_1}, {"Num2", .KP_2}, {"Num3", .KP_3}, {"Num4", .KP_4},
	{"Num5", .KP_5}, {"Num6", .KP_6}, {"Num7", .KP_7}, {"Num8", .KP_8}, {"Num9", .KP_9},
	{"Num+", .KP_ADD}, {"Num-", .KP_SUBTRACT}, {"Num*", .KP_MULTIPLY}, {"Num/", .KP_DIVIDE},
	{"Num.", .KP_DECIMAL}, {"NumEnter", .KP_ENTER},
}

parse_chord :: proc(s: string) -> (Key_Chord, bool) {
	c: Key_Chord
	parts := strings.split(strings.trim_space(s), "+", context.temp_allocator)
	// "Num+" and "Ctrl++" style: re-join empty trailing parts
	keyname := parts[len(parts) - 1]
	mods := parts[:len(parts) - 1]
	if keyname == "" && len(parts) >= 2 {
		keyname = tcat(parts[len(parts) - 2], "+")
		mods = parts[:len(parts) - 2]
		if parts[len(parts) - 2] == "" do keyname = "="
	}
	for m in mods {
		switch lower(m) {
		case "ctrl", "control", "cmd", "command": c.ctrl = true
		case "shift": c.shift = true
		case "alt", "option": c.alt = true
		case: return {}, false
		}
	}
	for k in KEY_NAMES do if strings.equal_fold(k.name, keyname) {
		c.key = k.key
		return c, true
	}
	return {}, false
}

chord_name :: proc(c: Key_Chord) -> string {
	name := "?"
	for k in KEY_NAMES do if k.key == c.key {
		name = k.name
		break
	}
	return tcat("Ctrl+" if c.ctrl else "", "Alt+" if c.alt else "", "Shift+" if c.shift else "", name)
}

action_find :: proc(name: string) -> ^Action {
	for &a in actions do if a.name == name do return &a
	return nil
}

action_keys_text :: proc(name: string) -> string {
	a := action_find(name)
	if a == nil || len(a.keys) == 0 do return ""
	return chord_name(a.keys[0])
}

@(private = "file")
apply_keys :: proc(m: Edn, src: string, user: bool) {
	if m.kind != .Map {
		append(&shortcut_errors, strings.clone(tcat(src, ": expected a map {:action \"Key\" …}")))
		return
	}
	for i := 0; i + 1 < len(m.items); i += 2 {
		name := m.items[i].s
		v := m.items[i + 1]
		a := action_find(name)
		if a == nil {
			if strings.has_prefix(name, "place/") {
				sym := symbol_find(name[6:])
				if sym == nil {
					append(&shortcut_errors, strings.clone(fmt.tprintf("%s: :%s – there is no symbol \"%s\"", src, name, name[6:])))
					continue
				}
				append(&actions, Action{name = strings.clone(name), desc = strings.clone(tcat("Place ", sym.desc)), ctx = .Schematic})
				a = &actions[len(actions) - 1]
			} else {
				append(&shortcut_errors, strings.clone(fmt.tprintf("%s: unknown action :%s", src, name)))
				continue
			}
		}
		clear(&a.keys)
		keys := make([dynamic]string, context.temp_allocator)
		#partial switch v.kind {
		case .String: append(&keys, v.s)
		case .Vector, .List: for x in v.items do if x.kind == .String do append(&keys, x.s)
		case .Nil:
		case: append(&shortcut_errors, strings.clone(fmt.tprintf("%s: :%s must be \"Key\", [\"Key\" …] or nil", src, name)))
		}
		for k in keys {
			c, ok := parse_chord(k)
			if !ok {
				append(&shortcut_errors, strings.clone(fmt.tprintf("%s: :%s – unknown key \"%s\"", src, name, k)))
				continue
			}
			append(&a.keys, c)
		}
	}
}

shortcuts_load :: proc() {
	actions_gen += 1
	for &a in actions do delete(a.keys)
	clear(&actions)
	clear(&shortcut_errors)
	for info in ACTION_INFO do append(&actions, Action{name = info.name, desc = info.desc, ctx = info.ctx, repeat = info.repeat})
	// symbol keys
	for &s in symbols {
		if len(s.key) == 0 do continue
		c, ok := parse_chord(s.key)
		if !ok {
			append(&shortcut_errors, strings.clone(fmt.tprintf("%s: symbol \"%s\" – unknown :key \"%s\"", s.source, s.name, s.key)))
			continue
		}
		a := Action{name = strings.clone(tcat("place/", s.name)), desc = strings.clone(tcat("Place ", s.desc)), ctx = .Schematic}
		append(&a.keys, c)
		append(&actions, a)
	}
	d, err := edn_parse(DEFAULT_SHORTCUTS, context.temp_allocator)
	if len(err) == 0 do apply_keys(d, "built-in shortcuts", false)
	text, path := read_config_file("shortcuts.edn", DEFAULT_SHORTCUTS)
	shortcuts_file = strings.clone(path)
	u, uerr := edn_parse(text, context.temp_allocator)
	if len(uerr) > 0 do append(&shortcut_errors, strings.clone(tcat("shortcuts.edn: ", uerr)))
	else do apply_keys(u, "shortcuts.edn", true)
	// keys used twice in overlapping places
	for i in 0 ..< len(actions) {
		for j in i + 1 ..< len(actions) {
			a, b := &actions[i], &actions[j]
			if a.ctx != b.ctx && a.ctx != .Global && b.ctx != .Global do continue
			for ka in a.keys do for kb in b.keys do if ka == kb {
				append(&shortcut_errors, strings.clone(fmt.tprintf("%s is used by both :%s and :%s", chord_name(ka), a.name, b.name)))
			}
		}
	}
	watch_file(shortcuts_file, shortcuts_reload)
}

shortcuts_reload :: proc() {
	shortcuts_load()
	app_settings_changed()
}

// Whether the chord was pressed this frame (exact modifiers).
chord_pressed :: proc(c: Key_Chord, repeat: bool, ctrl, shift, alt: bool) -> bool {
	if c.ctrl != ctrl || c.shift != shift || c.alt != alt do return false
	if key_pressed(c.key) do return true
	return repeat && key_repeated(c.key)
}
