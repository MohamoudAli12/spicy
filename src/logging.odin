package spicy

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:log"
import os "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import rl "vendor:raylib"

// Logging (ported from loomer, src/logging.odin).
//
// Every message goes to spicy.log in the state folder (appended, rotated to spicy.log.1 at
// start-up when it grows past LOG_ROTATE_BYTES):
//   Linux / BSD  $XDG_STATE_HOME/spicy/spicy.log  (default ~/.local/state/spicy/spicy.log;
//                with SPICY_CONFIG_DIR its state/ subfolder)
//   macOS        ~/Library/Logs/Spicy/spicy.log
//   Windows      %LOCALAPPDATA%\Spicy\spicy.log
// Warnings and errors also go to stderr (everything with -v / --verbose).
// The level is INFO unless changed with
//   --log-level <debug|info|warning|error|fatal>, -v / --verbose (debug), -q / --quiet (warning)
//   or the environment variable SPICY_LOG=<level>   (the command line wins)
// --log-file <path|none> (or SPICY_LOG_FILE) moves or disables the file.
// raylib's own messages are routed through the same logger (its INFO lines at DEBUG).
// `spicy --diagnostics` and Help ▸ Diagnostics show versions, paths and the environment.

LOG_ROTATE_BYTES :: 2 * 1024 * 1024

@(private = "file")
Log_State :: struct {
	mutex:     sync.Mutex,
	level:     log.Level,
	file:      ^os.File,
	path:      string, // "" = no file
	gpu_lines: [dynamic]string, // GL vendor / renderer / version reported by raylib, for the diagnostics
}

@(private = "file")
lg: Log_State

// The logger installed in main(); procs called from C ("c" callbacks) restore it from here.
app_logger: log.Logger

log_level :: proc() -> log.Level {return lg.level}
log_file_path :: proc() -> string {return lg.path}
log_gpu_lines :: proc() -> []string {return lg.gpu_lines[:]}

parse_log_level :: proc(s: string) -> (log.Level, bool) {
	switch strings.to_lower(strings.trim_space(s), context.temp_allocator) {
	case "debug", "trace", "all", "verbose": return .Debug, true
	case "info": return .Info, true
	case "warning", "warn": return .Warning, true
	case "error": return .Error, true
	case "fatal", "none", "off", "quiet": return .Fatal, true
	}
	return .Info, false
}

level_name :: proc(l: log.Level) -> string {
	switch {
	case l < .Info: return "DEBUG"
	case l < .Warning: return "INFO"
	case l < .Error: return "WARN"
	case l < .Fatal: return "ERROR"
	}
	return "FATAL"
}

default_log_dir :: proc() -> string {return state_dir()}

// Removes the logging options from args (they may appear anywhere). Returns the remaining
// arguments, the level, the log file ("" = default, "none" = no file) and an error message
// for a bad option ("" = ok). log_init then opens the file.
log_parse_args :: proc(args: []string) -> (rest: []string, level: log.Level, file: string, err: string) {
	level = log.Level.Info
	if env := os.get_env("SPICY_LOG", context.temp_allocator); len(env) > 0 {
		if l, ok := parse_log_level(env); ok do level = l
		else do err = tcat("SPICY_LOG: unknown level \"", env, "\" (debug, info, warning, error, fatal)")
	}
	file = os.get_env("SPICY_LOG_FILE", context.temp_allocator)

	out := make([dynamic]string, 0, len(args), runtime.heap_allocator())
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		value :: proc(args: []string, i: ^int, a, name: string) -> (string, bool) {
			if strings.has_prefix(a, tcat(name, "=")) do return a[len(name) + 1:], true
			if a == name && i^ + 1 < len(args) {
				i^ += 1
				return args[i^], true
			}
			return "", a == name
		}
		if v, is := value(args, &i, a, "--log-level"); is {
			if l, ok := parse_log_level(v); ok do level = l
			else do err = tcat("--log-level: unknown level \"", v, "\" (debug, info, warning, error, fatal)")
			continue
		}
		if v, is := value(args, &i, a, "--log-file"); is {
			file = v if len(v) > 0 else "none"
			continue
		}
		switch a {
		case "-v", "--verbose": level = .Debug
		case "-q", "--quiet": level = .Warning
		case: append(&out, a)
		}
	}
	return out[:], level, file, err
}

// file: "" = default location, "none" = no log file.
log_init :: proc(level: log.Level, file: string) {
	lg.level = level
	lg.gpu_lines = make([dynamic]string, runtime.heap_allocator())
	if file != "none" {
		path := file if len(file) > 0 else path_join(default_log_dir(), "spicy.log")
		path = abs_path(path)
		os.make_directory_all(dir_name(path))
		if fi, e := os.stat(path, context.temp_allocator); e == nil && fi.size > LOG_ROTATE_BYTES {
			old := tcat(path, ".1")
			os.remove(old)
			os.rename(path, old)
		}
		if f, e := os.open(path, os.O_WRONLY + os.O_CREATE + os.O_APPEND, os.Permissions_Default_File); e == nil {
			lg.file = f
			lg.path = strings.clone(path, runtime.heap_allocator())
		}
	}
	app_logger = log.Logger {
		procedure    = log_proc,
		data         = nil,
		lowest_level = level,
		options      = {},
	}
	// raylib: keep its INFO lines (GPU / display) for the diagnostics; log them at DEBUG.
	rl.SetTraceLogLevel(.INFO)
	rl.SetTraceLogCallback(raylib_log)
}

log_shutdown :: proc() {
	sync.mutex_lock(&lg.mutex)
	defer sync.mutex_unlock(&lg.mutex)
	if lg.file != nil {
		os.flush(lg.file)
		os.close(lg.file)
		lg.file = nil
	}
}

@(private = "file")
log_proc :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
	if level < lg.level do return
	ns := time.now()._nsec
	t: libc.time_t = libc.time_t(ns / 1e9)
	ms := int((ns / 1e6) % 1000)
	tm := crt_localtime(&t)
	date, clock: string
	if tm != nil {
		date = fmt.tprintf("%04d-%02d-%02d", int(tm.tm_year) + 1900, int(tm.tm_mon) + 1, int(tm.tm_mday))
		clock = fmt.tprintf("%02d:%02d:%02d.%03d", int(tm.tm_hour), int(tm.tm_min), int(tm.tm_sec), ms)
	}
	src_loc := fmt.tprintf("%s:%d", base_name(location.file_path), location.line) if location.line > 0 else location.file_path
	msg := strings.trim_right_space(text)

	sync.mutex_lock(&lg.mutex)
	defer sync.mutex_unlock(&lg.mutex)
	// Console: warnings and errors only (the command-line output stays clean), all of it when debugging.
	if lg.level < .Info do fmt.eprintf("%s %-5s [%s] %s\n", clock, level_name(level), src_loc, msg)
	else if level >= .Warning do fmt.eprintf("spicy %-5s %s\n", level_name(level), msg)
	if lg.file != nil {
		os.write_string(lg.file, fmt.tprintf("%s %s %-5s [%s] %s\n", date, clock, level_name(level), src_loc, msg))
		if level >= .Warning do os.flush(lg.file)
	}
}

@(private = "file")
raylib_log :: proc "c" (rl_level: rl.TraceLogLevel, text: cstring, args: ^c.va_list) {
	context = runtime.default_context()
	context.logger = app_logger
	buf: [1024]u8
	n := crt_vsnprintf(buf[:], text, args)
	if n < 0 do return
	msg := string(buf[:min(int(n), len(buf) - 1)])
	{
		t := strings.trim_left(strings.trim_space(msg), "> ")
		for k in ([?]string{"Vendor:", "Renderer:", "Version:", "GLSL:", "PLATFORM:"}) {
			if strings.has_prefix(t, k) && len(lg.gpu_lines) < 8 {
				append(&lg.gpu_lines, strings.clone(t, runtime.heap_allocator()))
			}
		}
	}
	loc := runtime.Source_Code_Location{file_path = "raylib", line = 0}
	#partial switch rl_level {
	case .WARNING:
		// missing glyphs / glyph sizes are expected (fallbacks exist): keep them out of INFO
		log.log(.Debug if strings.has_prefix(msg, "FONT:") else .Warning, "raylib:", msg, location = loc)
	case .ERROR: log.log(.Error, "raylib:", msg, location = loc)
	case .FATAL: log.log(.Fatal, "raylib:", msg, location = loc)
	case: log.log(.Debug, msg, location = loc)
	}
	// No free_all here: the default temp allocator is shared with the frame that called raylib.
}

// Logs a failed assertion / panic before the default handler aborts.
log_assertion_failure :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	log.log(.Fatal, prefix, message, location = loc)
	log_shutdown()
	runtime.default_assertion_failure_proc(prefix, message, loc)
}

// Crash signals: note them in the log before dying.
when ODIN_OS != .Windows {
	@(private = "file")
	crash_signal :: proc "c" (sig: c.int) {
		context = runtime.default_context()
		context.logger = app_logger
		name := "signal"
		switch sig {
		case libc.SIGSEGV: name = "SIGSEGV (segmentation fault)"
		case libc.SIGFPE: name = "SIGFPE (arithmetic error)"
		case libc.SIGILL: name = "SIGILL (illegal instruction)"
		case libc.SIGABRT: name = "SIGABRT (abort)"
		}
		log.fatalf("crashed: %s – log %s", name, lg.path)
		log_shutdown()
		libc.signal(sig, cast(proc "c" (c.int))libc.SIG_DFL)
		libc.raise(sig)
	}
}

log_install_crash_handlers :: proc() {
	when ODIN_OS != .Windows {
		for s in ([?]c.int{libc.SIGSEGV, libc.SIGFPE, libc.SIGILL, libc.SIGABRT}) do libc.signal(s, crash_signal)
	}
}
