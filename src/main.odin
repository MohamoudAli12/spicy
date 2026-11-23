package spicy

import "core:fmt"
import "core:log"
import os "core:os"
import "core:strings"
import "core:time"

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
  spicy --import-model <file>              add a SPICE model file (symbols for its subcircuits)
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

// Opens a schematic file (.edn, or .asc imported).
load_schematic_file :: proc(path: string) -> (s: Schematic, warnings: []string, err: string) {
	data, ok := read_bytes(path, context.temp_allocator)
	if !ok do return {}, nil, fmt.tprintf("cannot read %s", path)
	if file_ext_lower(path) == "asc" {
		sch, w, e := asc_import(data)
		return sch, w[:], e
	}
	if is_netlist_ext(path) || (file_ext_lower(path) != "edn" && is_circuit_netlist(string(data))) {
		sch, w, e := netlist_import(string(data))
		return sch, w[:], e
	}
	sch, e := sch_from_edn(string(data))
	if len(e) > 0 do return {}, nil, fmt.tprintf("%s: %s", path, e)
	register_embedded_symbols(&sch, path)
	unknown := make([dynamic]string, context.temp_allocator)
	for c in sch.comps do if symbol_find(c.sym) == nil do append(&unknown, fmt.tprintf("%s: unknown symbol \"%s\"", c.ref, c.sym))
	return sch, unknown[:], ""
}

cli_sim :: proc(sch: ^Schematic, args: []string) -> ^Simulator_Def {
	id := sch.simulator if len(sch.simulator) > 0 else S.simulator
	for a, i in args do if a == "--sim" && i + 1 < len(args) do id = args[i + 1]
	sim := simulator_def(id)
	if sim == nil {
		cli_fail(EXIT_USAGE, "usage", fmt.tprintf("unknown simulator \"%s\" (spicy --list simulators)", id))
	}
	return sim
}

main :: proc() {
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
	if len(rest) > 0 {
		switch rest[0] {
		case "--paths":
			fmt.printfln("config   %s", config_dir())
			fmt.printfln("data     %s  (symbols/, models/)", data_dir())
			fmt.printfln("state    %s  (spicy.log, runs/)", state_dir())
			return
		case "--diagnostics", "--diag":
			load_config()
			fmt.print(diagnostics_report())
			return
		case "--check-config":
			load_config()
			for e in config_errors do fmt.println(e)
			for e in shortcut_errors do fmt.println(e)
			if len(config_errors) + len(shortcut_errors) > 0 do os.exit(1)
			fmt.println("no problems found")
			return
		case "--set-program":
			// the program of a simulator, as Simulate › Simulators… sets it
			if len(rest) < 3 {
				fmt.eprintln("usage: spicy --set-program <simulator> <path>   e.g. spicy --set-program vacask /opt/vacask/bin/vacask")
				os.exit(2)
			}
			load_config()
			if e := settings_set_program(rest[1], rest[2]); len(e) > 0 {
				fmt.eprintln(e)
				os.exit(1)
			}
			p, ok := find_program(rest[2])
			fmt.printfln("%s runs %s (%s), saved in %s", rest[1], rest[2], p if ok else "not found", settings_path)
			return
		case "--embed":
			// refresh the copies of models and symbols saved in a schematic (as saving does)
			if len(rest) < 2 {
				fmt.eprintln("usage: spicy --embed <file.edn>")
				os.exit(2)
			}
			load_config()
			p := abs_path(rest[1])
			sch, _, err := load_schematic_file(p)
			if len(err) > 0 {
				fmt.eprintln(err)
				os.exit(1)
			}
			sch_embed(&sch, dir_of(p))
			if !write_text(p, sch_to_edn(&sch)) {
				fmt.eprintln("cannot write", p)
				os.exit(1)
			}
			for e in sch.embedded do fmt.printfln("model    %s (from %s)", e.name, e.from)
			for t in sch.embedded_sym {
				v, _ := edn_parse(t, context.temp_allocator)
				fmt.printfln("symbol   %s", edn_str(v, "name"))
			}
			return
		case "--import-model":
			if len(rest) < 2 {
				fmt.eprintln("usage: spicy --import-model <file.lib>")
				os.exit(2)
			}
			load_config()
			if text, tok := read_text(rest[1], context.temp_allocator); tok && is_circuit_netlist(text) {
				fmt.eprintfln("%s is a circuit, not a model library: open it (spicy %s) or run it (spicy --run %s)", rest[1], rest[1], rest[1])
				os.exit(1)
			}
			res, ok := import_model_file(rest[1])
			if !ok {
				fmt.eprintln(res.message)
				os.exit(1)
			}
			fmt.println("copied to", res.file)
			for n in res.symbols do fmt.println("symbol  ", n)
			for n in res.models do fmt.println("model   ", n)
			return
		case "--import-asc":
			if len(rest) < 3 {
				fmt.eprintln("usage: spicy --import-asc in.asc out.edn")
				os.exit(2)
			}
			load_config()
			sch, w, err := load_schematic_file(rest[1])
			if len(err) > 0 {
				fmt.eprintln(err)
				os.exit(1)
			}
			for x in w do fmt.eprintln("warning:", x)
			if !write_text(rest[2], sch_to_edn(&sch)) {
				fmt.eprintln("cannot write", rest[2])
				os.exit(1)
			}
			return
		}
	}
	load_config()
	gui_main(rest[:])
}

abs_c :: proc(re, im: f64) -> f64 {return sqrt64(re * re + im * im)}

// CSV of one plot (complex values as magnitude and phase).
write_csv :: proc(p: ^Plot, path: string) -> bool {
	b := strings.builder_make(context.temp_allocator)
	for v, k in p.vecs {
		if k > 0 do strings.write_byte(&b, ',')
		if p.complex && k > 0 do fmt.sbprintf(&b, "\"mag(%s)\",\"ph(%s)\"", v.name, v.name)
		else do fmt.sbprintf(&b, "\"%s\"", v.name)
	}
	strings.write_byte(&b, '\n')
	for i in 0 ..< p.npoints {
		for v, k in p.vecs {
			if k > 0 do strings.write_byte(&b, ',')
			if p.complex && k > 0 do fmt.sbprintf(&b, "%.12g,%.6g", abs_c(v.re[i], v.im[i]), phase_deg(v.re[i], v.im[i]))
			else do fmt.sbprintf(&b, "%.12g", v.re[i])
		}
		strings.write_byte(&b, '\n')
	}
	log.infof("wrote %s", path)
	return write_text(path, strings.to_string(b))
}
