package spicy

import "core:fmt"
import "core:log"
import os "core:os"

// Set by make with a leading "v" (-define:SPICY_VERSION=v2026-11): -define reads values made of
// digits and dashes as numbers, the "v" keeps it a string. It is stripped here.
@(private = "file")
SPICY_VERSION_RAW :: #config(SPICY_VERSION, "vdev")
#assert(len(SPICY_VERSION_RAW) > 1 && SPICY_VERSION_RAW[0] == 'v', "pass the version with a leading v: -define:SPICY_VERSION=v<version>")
SPICY_VERSION :: SPICY_VERSION_RAW[1:]

HELP :: `spicy – schematic editor and waveform viewer for ngspice, Xyce and VACASK

usage:
  spicy [file.edn | file.asc ...]          open schematics in the GUI (.asc = LTspice, imported)
  spicy --netlist <file> [--sim <id>]      print the netlist (id: ngspice, xyce, vacask, …)
  spicy --run <file> [--sim <id>] [--csv out.csv]
                                           simulate without the GUI and list (or save) the results
  spicy --import-asc <in.asc> <out.edn>    convert an LTspice schematic
  spicy --import-model <file> [--repair | --as-is]
                                           add a SPICE model file (symbols for its subcircuits); a
                                           file with faults is only imported with --repair (the copy
                                           repaired, the file unchanged) or --as-is
  spicy --check-model <file>               report a model file's faults and what --repair would do
  spicy --embed <file.edn>                 save copies of the models and symbols it uses in it
  spicy --set-program <simulator> <path>   the program a simulator runs (saved in settings.edn)
  spicy --paths                            where settings, symbols, models and logs live
  spicy --diagnostics                      versions, paths and environment (for bug reports)
  spicy --check-config                     report problems in the settings, theme, shortcut and symbol files
  spicy --version | --help

options: --log-level <debug|info|warning|error|fatal> (default info, or SPICY_LOG),
         -v / --verbose (debug), -q / --quiet (warning), --log-file <path|none> (or SPICY_LOG_FILE)
environment: SPICY_SCALE=1.5 (UI scale), SPICY_CONFIG_DIR=<dir> (config folder)
`

// Set by the GUI; the command line has nothing to refresh.
app_settings_changed_hook: proc()

app_settings_changed :: proc() {
	if app_settings_changed_hook != nil do app_settings_changed_hook()
}

load_config :: proc() {
	prefs_load()
	settings_load()
	themes_load()
	theme_apply()
	symbols_load()
	models_load()
	shortcuts_load()
}

main :: proc() {
	win_console_attach() // Windows: print to the terminal spicy was started from
	rest0, level, log_file, log_err := log_parse_args(os.args[1:])
	rest := out_fmt_parse(rest0)
	// answered before the log file is opened: these never touch the disk
	if len(rest) > 0 {
		switch rest[0] {
		case "--help", "-h", "--version", "--paths":
			if len(log_err) > 0 do fmt.eprintln("spicy WARN ", log_err)
		}
		switch rest[0] {
		case "--help", "-h":
			fmt.print(HELP)
			fmt.print("\n", CLI_HELP)
			return
		case "--version":
			fmt.println("spicy", SPICY_VERSION)
			return
		case "--paths":
			fmt.printfln("config   %s", config_dir())
			fmt.printfln("data     %s  (symbols/, models/)", data_dir())
			fmt.printfln("state    %s  (spicy.log, runs/)", state_dir())
			return
		}
	}
	log_init(level, log_file)
	context.logger = app_logger
	context.assertion_failure_proc = log_assertion_failure
	log_install_crash_handlers()
	defer log_shutdown()
	if len(log_err) > 0 do log.warn(log_err)
	log.debugf("spicy %s (%s/%s), log level %s, log file %s", SPICY_VERSION, ODIN_OS, ODIN_ARCH, level_name(log_level()), log_file_path())
	log.debugf("arguments: %v", rest)
	if len(rest) > 0 && cli_main(rest) do return
	load_config()
	gui_main(rest[:])
}
