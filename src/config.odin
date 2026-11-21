package spicy

import "base:runtime"
import "core:fmt"
import "core:log"
import os "core:os"
import "core:slice"
import "core:strings"

// Where things live (same layout as loomer and zapped):
//
//   config  $XDG_CONFIG_HOME/spicy   (~/.config/spicy)          prefs.edn settings.edn themes.edn shortcuts.edn
//           ~/Library/Application Support/Spicy   (macOS)
//           %APPDATA%\Spicy                       (Windows)
//   data    $XDG_DATA_HOME/spicy     (~/.local/share/spicy)     symbols/  models/
//           (macOS / Windows: the config folder)
//   state   $XDG_STATE_HOME/spicy    (~/.local/state/spicy)     spicy.log, runs of unsaved schematics
//           ~/Library/Logs/Spicy, %LOCALAPPDATA%\Spicy
//
// prefs.edn is written by spicy (window, recent files, theme picked in the menu …).
// settings.edn, themes.edn and shortcuts.edn are for you: they are written with the
// defaults on the first start (delete one to get the defaults back), and spicy reloads
// them as soon as they change on disk.

config_dir :: proc() -> string {
	if d := os.get_env("SPICY_CONFIG_DIR", context.temp_allocator); len(d) > 0 do return d
	when ODIN_OS == .Windows {
		base := os.get_env("APPDATA", context.temp_allocator)
		if len(base) == 0 do base = home_dir()
		return path_join(base, "Spicy")
	} else when ODIN_OS == .Darwin {
		return path_join(home_dir(), "Library", "Application Support", "Spicy")
	} else {
		xdg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
		if len(xdg) == 0 || !is_abs(xdg) do xdg = path_join(home_dir(), ".config")
		return path_join(xdg, "spicy")
	}
}

data_dir :: proc() -> string {
	when ODIN_OS == .Windows || ODIN_OS == .Darwin {
		return config_dir()
	} else {
		if d := os.get_env("SPICY_CONFIG_DIR", context.temp_allocator); len(d) > 0 do return path_join(d, "data")
		xdg := os.get_env("XDG_DATA_HOME", context.temp_allocator)
		if len(xdg) == 0 || !is_abs(xdg) do xdg = path_join(home_dir(), ".local", "share")
		return path_join(xdg, "spicy")
	}
}

state_dir :: proc() -> string {
	when ODIN_OS == .Windows {
		base := os.get_env("LOCALAPPDATA", context.temp_allocator)
		if len(base) == 0 do base = config_dir()
		return path_join(base, "Spicy")
	} else when ODIN_OS == .Darwin {
		return path_join(home_dir(), "Library", "Logs", "Spicy")
	} else {
		if d := os.get_env("SPICY_CONFIG_DIR", context.temp_allocator); len(d) > 0 do return path_join(d, "state")
		xdg := os.get_env("XDG_STATE_HOME", context.temp_allocator)
		if len(xdg) == 0 || !is_abs(xdg) do xdg = path_join(home_dir(), ".local", "state")
		return path_join(xdg, "spicy")
	}
}

// ---------------------------------------------------------------------------
// prefs.edn: state written by spicy (EDN map, values kept as EDN text).

@(private = "file")
prefs: map[string]string

prefs_path :: proc() -> string {return path_join(config_dir(), "prefs.edn")}

@(private = "file")
put_raw :: proc(key, text: string) {
	h := runtime.heap_allocator()
	if old, ok := prefs[key]; ok {
		if old == text do return
		delete(old, h)
		prefs[key] = strings.clone(text, h)
	} else {
		prefs[strings.clone(key, h)] = strings.clone(text, h)
	}
}

prefs_load :: proc() {
	prefs = make(map[string]string, 32, runtime.heap_allocator())
	text, ok := read_text(prefs_path(), context.temp_allocator)
	if !ok do return
	v, err := edn_parse(text, context.temp_allocator)
	if len(err) > 0 || v.kind != .Map {
		log.warnf("ignoring unreadable %s: %s", prefs_path(), err)
		return
	}
	for i := 0; i + 1 < len(v.items); i += 2 {
		k := v.items[i]
		if k.kind == .Keyword || k.kind == .String do put_raw(k.s, edn_to_string(v.items[i + 1]))
	}
}

prefs_save :: proc() {
	keys := make([dynamic]string, context.temp_allocator)
	for k in prefs do append(&keys, k)
	slice.sort(keys[:])
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, ";; spicy state (EDN), written by spicy. Your settings go in settings.edn.\n{")
	for k, i in keys {
		if i > 0 do strings.write_string(&b, "\n ")
		fmt.sbprintf(&b, ":%s %s", k, prefs[k])
	}
	strings.write_string(&b, "}\n")
	os.make_directory_all(config_dir())
	if !write_text(prefs_path(), strings.to_string(b)) do log.errorf("cannot write %s", prefs_path())
}

pref_value :: proc(key: string) -> (Edn, bool) {
	raw, ok := prefs[key]
	if !ok do return {}, false
	v, err := edn_parse(raw, context.temp_allocator)
	return v, len(err) == 0
}

pref_get :: proc(key: string, default := "") -> string {
	v, ok := pref_value(key)
	if !ok do return default
	#partial switch v.kind {
	case .String, .Keyword, .Symbol: return v.s
	}
	return default
}

pref_f64 :: proc(key: string, default: f64) -> f64 {
	v, ok := pref_value(key)
	if !ok || !edn_is_num(v) do return default
	return edn_num(v)
}

pref_bool :: proc(key: string, default := false) -> bool {
	v, ok := pref_value(key)
	if !ok || v.kind != .Bool do return default
	return v.b
}

pref_list :: proc(key: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	v, ok := pref_value(key)
	if ok && edn_is_coll(v) {
		for x in v.items do if x.kind == .String && !is_blank(x.s) do append(&out, x.s)
	}
	return out[:]
}

// Changes are kept in memory; prefs_save writes them (at exit and after file operations).
pref_put :: proc(key, value: string) {put_raw(key, edn_quoted(value))}
pref_put_edn :: proc(key, edn_text: string) {put_raw(key, edn_text)}
pref_put_f64 :: proc(key: string, v: f64) {put_raw(key, edn_float_str(v))}
pref_put_bool :: proc(key: string, v: bool) {put_raw(key, "true" if v else "false")}
pref_put_list :: proc(key: string, xs: []string) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for x, i in xs {
		if i > 0 do strings.write_byte(&b, ' ')
		edn_quote(&b, x)
	}
	strings.write_byte(&b, ']')
	put_raw(key, strings.to_string(b))
}

// ---------------------------------------------------------------------------
// User-editable config files with built-in defaults (settings, themes, shortcuts).

// Problems found in the user's config files, shown in the app (heap strings).
config_errors: [dynamic]string

config_error :: proc(msg: string) {
	append(&config_errors, strings.clone(msg))
	log.warn(one_line(msg))
}

// Reads a config file from the config folder; writes the default text there when missing.
read_config_file :: proc(name, default_text: string) -> (text: string, path: string) {
	path = path_join(config_dir(), name)
	t, ok := read_text(path, context.temp_allocator)
	if ok do return t, path
	os.make_directory_all(config_dir())
	if write_text(path, default_text) do log.infof("wrote default %s", path)
	return default_text, path
}

// Watches config files and reloads them when they change on disk.
Watched :: struct {
	path:   string,
	mtime:  i64,
	reload: proc(),
}

watched: [dynamic]Watched
watch_next: f64

watch_file :: proc(path: string, reload: proc()) {
	for &w in watched do if w.path == path {
		w.mtime = file_mtime(path)
		return
	}
	append(&watched, Watched{strings.clone(path), file_mtime(path), reload})
}

// Called every main-loop pass (also while idle); checks the files about twice a second.
// True when one was reloaded.
watch_poll :: proc(now: f64) -> (reloaded: bool) {
	if now < watch_next do return
	watch_next = now + 0.5
	for &w in watched {
		m := file_mtime(w.path)
		if m != 0 && m != w.mtime {
			w.mtime = m
			log.infof("%s changed, reloading", w.path)
			w.reload()
			reloaded = true
		}
	}
	return
}
