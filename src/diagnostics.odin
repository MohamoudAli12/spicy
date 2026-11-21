package spicy

import "core:fmt"
import os "core:os"
import "core:strings"
import "core:time"
import rl "vendor:raylib"

// About and diagnostics: who made spicy, where it lives, and a plain-text report of versions,
// paths and the environment for bug reports (`spicy --diagnostics`, Help ▸ Diagnostics).

SPICY_AUTHOR :: "Mohamoud Ali"
SPICY_LICENSE :: "GNU AGPL v3"
SPICY_REPO :: "https://github.com/MohamoudAli12/spicy"
SPICY_ISSUES :: SPICY_REPO + "/issues"

// Plain-text report: versions, paths, libraries, fonts, display and environment.
diagnostics_report :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	line :: proc(b: ^strings.Builder, k: string, v: string) {fmt.sbprintf(b, "  %-16s %s\n", k, v)}
	yn :: proc(path: string) -> string {return "" if file_exists(path) || dir_exists(path) else "  (missing)"}

	strings.write_string(&b, "spicy diagnostics\n")
	line(&b, "version", SPICY_VERSION)
	line(&b, "built with", fmt.tprintf("Odin %s, %s/%s, %s", ODIN_VERSION, ODIN_OS, ODIN_ARCH, "debug" when ODIN_DEBUG else "optimised"))
	line(&b, "raylib", rl.VERSION)
	now, _ := time.time_to_rfc3339(time.now(), 0, false, context.temp_allocator)
	line(&b, "now", now)
	line(&b, "log level", level_name(log_level()))
	line(&b, "log file", tcat(log_file_path(), yn(log_file_path())) if len(log_file_path()) > 0 else "(none)")

	strings.write_string(&b, "\nPaths\n")
	exe, _ := os.get_executable_path(context.temp_allocator)
	line(&b, "executable", exe)
	line(&b, "working dir", cwd())
	line(&b, "config dir", tcat(config_dir(), yn(config_dir())))
	line(&b, "data dir", tcat(data_dir(), yn(data_dir())))
	line(&b, "state dir", tcat(state_dir(), yn(state_dir())))
	line(&b, "settings", tcat(settings_path, yn(settings_path)) if len(settings_path) > 0 else "(not loaded)")
	line(&b, "preferences", tcat(prefs_path(), yn(prefs_path())))
	line(&b, "themes", tcat(themes_file, yn(themes_file)) if len(themes_file) > 0 else "(not loaded)")
	line(&b, "shortcuts", tcat(shortcuts_file, yn(shortcuts_file)) if len(shortcuts_file) > 0 else "(not loaded)")
	line(&b, "symbols", tcat(user_symbols_dir(), yn(user_symbols_dir())))
	line(&b, "models", tcat(user_models_dir(), yn(user_models_dir())))

	strings.write_string(&b, "\nLibraries\n")
	line(&b, "symbols", itoa(len(symbols)))
	line(&b, "model entries", itoa(len(model_lib)))
	line(&b, "problems", itoa(len(config_errors) + len(shortcut_errors)))
	for e in config_errors do line(&b, "", e)
	for e in shortcut_errors do line(&b, "", e)

	strings.write_string(&b, "\nSimulators\n")
	for s in S.simulators {
		if len(s.command) == 0 {
			line(&b, s.id, "(no program set)")
			continue
		}
		p, ok := find_program(s.command[0])
		line(&b, s.id, tcat(s.command[0], " → ", p if ok else "not found"))
	}

	if rl.IsWindowReady() {
		strings.write_string(&b, "\nDisplay\n")
		m := rl.GetCurrentMonitor()
		line(&b, "monitor", fmt.tprintf("%s, %dx%d, %d×%d mm, %d Hz", rl.GetMonitorName(m), rl.GetMonitorWidth(m), rl.GetMonitorHeight(m), rl.GetMonitorPhysicalWidth(m), rl.GetMonitorPhysicalHeight(m), rl.GetMonitorRefreshRate(m)))
		line(&b, "window", fmt.tprintf("%dx%d (render %dx%d)", rl.GetScreenWidth(), rl.GetScreenHeight(), rl.GetRenderWidth(), rl.GetRenderHeight()))
		line(&b, "UI scale", fmt.tprintf("%.0f%%", ui_scale * 100))
		for l in log_gpu_lines() {
			k, _, v := strings.partition(l, ":")
			line(&b, strings.to_lower(k, context.temp_allocator), strings.trim_space(v))
		}
		line(&b, "font", sans.path if len(sans.path) > 0 else "(raylib built-in font)")
		line(&b, "mono font", mono.path if len(mono.path) > 0 else "(raylib built-in font)")
	}

	if len(app.docs) > 0 {
		strings.write_string(&b, "\nSession\n")
		for d in app.docs do line(&b, "schematic", d.path if len(d.path) > 0 else "(unsaved)")
	}

	strings.write_string(&b, "\nEnvironment\n")
	vars := [?]string {
		"SPICY_LOG", "SPICY_LOG_FILE", "SPICY_SCALE", "SPICY_CONFIG_DIR", "SPICY_WINDOW", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
		"XDG_SESSION_TYPE", "XDG_CURRENT_DESKTOP", "DISPLAY", "WAYLAND_DISPLAY", "LANG", "APPDATA", "LOCALAPPDATA",
	}
	for v in vars {
		val := os.get_env(v, context.temp_allocator)
		if len(val) > 0 do line(&b, v, val)
	}
	return strings.to_string(b)
}

about_text :: proc() -> string {
	return tcat(
		"A schematic editor and waveform viewer for SPICE simulators (ngspice, Xyce) and VACASK.\n\n",
		"Author: ", SPICY_AUTHOR, "\n",
		"License: ", SPICY_LICENSE, "\n",
		"Source: ", SPICY_REPO, "\n",
		"Bugs and ideas: ", SPICY_ISSUES, "\n\n",
		"Settings: ", settings_path, "\n",
		"Data: ", data_dir(), "\n",
		"Log: ", log_file_path() if len(log_file_path()) > 0 else "(none)",
	)
}
