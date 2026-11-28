package spicy

import "core:fmt"
import os "core:os"
import "core:strings"

// The command-line commands that print text for a person rather than EDN for a script:
// model files, embedding, LTspice import, the simulator programs and the configuration.
// Their errors go through cli_fail like every command's (as text unless --edn or --json is
// given), with the same exit codes.

// --import-model <file> [--repair | --as-is], --check-model <file>
cli_import_model :: proc(args: []string) {
	check := args[0] == "--check-model"
	USAGE :: "usage: spicy --import-model <file.lib> [--repair | --as-is]  /  spicy --check-model <file.lib>"
	repair, as_is := false, false
	file := ""
	for a in args[1:] {
		switch a {
		case "--repair": repair = true
		case "--as-is": as_is = true
		case:
			if len(file) > 0 || strings.has_prefix(a, "--") do cli_usage(USAGE)
			file = a
		}
	}
	if len(file) == 0 || (repair && as_is) || (check && (repair || as_is)) do cli_usage(USAGE)
	text, ok := read_text(file, context.temp_allocator)
	if !ok do cli_fail(EXIT_FILE, "file", tcat("cannot read ", file))
	if is_circuit_netlist(text) {
		cli_fail(EXIT_PROBLEMS, "not-a-library", fmt.tprintf("%s is a circuit, not a model library: open it (spicy %s) or run it (spicy --run %s)", file, file, file))
	}
	_, rep := model_repair(text, import_dest(file))
	if check {
		if len(rep.fixes) + len(rep.checks) == 0 {
			fmt.println("no problems found")
			return
		}
		fmt.println(repair_report_text(&rep))
		os.exit(EXIT_PROBLEMS)
	}
	if len(rep.fixes) > 0 && !repair && !as_is {
		fmt.println(repair_report_text(&rep))
		cli_fail(EXIT_PROBLEMS, "faults", fmt.tprintf("%s has %d fault(s) spicy can repair: import it again with --repair (only the copy is changed) or --as-is", file, len(rep.fixes)))
	}
	res, imported := import_model_file(file, repair)
	if !imported do cli_fail(EXIT_PROBLEMS, "import", res.message)
	fmt.println("copied to", res.file)
	if res.repaired > 0 do fmt.printfln("repaired %d fault(s) in the copy (spicy --check-model %s lists them)", res.repaired, file)
	if len(rep.checks) > 0 do fmt.printfln("%d thing(s) to check yourself, not changed (spicy --check-model %s lists them)", len(rep.checks), file)
	for n in res.symbols do fmt.println("symbol  ", n)
	for n in res.models do fmt.println("model   ", n)
}

// --embed <file.edn> [--update]: refreshes the copies of models and symbols saved in a
// schematic, as saving it does. A copy whose library here has another version is kept and
// named; with --update the library's version replaces it.
cli_embed :: proc(args: []string) {
	if len(args) < 2 do cli_usage("usage: spicy --embed <file.edn> [--update]")
	update := false
	for a in args[2:] {
		if a == "--update" do update = true
		else do cli_usage(tcat("usage: spicy --embed <file.edn> [--update]   (unknown option ", a, ")"))
	}
	p := abs_path(args[1])
	sch, _, err := load_schematic_file(p)
	if len(err) > 0 do cli_fail(EXIT_FILE, "parse", err)
	differing := embedded_differing(&sch, sch_models(&sch, cli_sim(&sch, args), dir_of(p)))
	if update {
		for n in differing do for u in embedded_use_library(&sch, n) do fmt.printfln("updated  %s (the library's version)", u)
	} else {
		for n in differing do fmt.printfln("differs  %s: the library here has another version (--update uses it)", n)
	}
	sch_embed(&sch, dir_of(p))
	if !write_text(p, sch_to_edn(&sch)) do cli_fail(EXIT_FILE, "write", tcat("cannot write ", p))
	for e in sch.embedded do fmt.printfln("model    %s (from %s)", e.name, e.from)
	for t in sch.embedded_sym {
		v, _ := edn_parse(t, context.temp_allocator)
		fmt.printfln("symbol   %s", edn_str(v, "name"))
	}
}

// --import-asc <in.asc> <out.edn>
cli_import_asc :: proc(args: []string) {
	if len(args) < 3 do cli_usage("usage: spicy --import-asc in.asc out.edn")
	sch, warnings, err := load_schematic_file(args[1])
	if len(err) > 0 do cli_fail(EXIT_FILE, "parse", err)
	for w in warnings do fmt.eprintln("warning:", w)
	if !write_text(args[2], sch_to_edn(&sch)) do cli_fail(EXIT_FILE, "write", tcat("cannot write ", args[2]))
}

// --set-program <simulator> <path>: the program a simulator runs, as Simulate › Simulators… sets it.
cli_set_program :: proc(args: []string) {
	if len(args) < 3 do cli_usage("usage: spicy --set-program <simulator> <path>   e.g. spicy --set-program vacask /opt/vacask/bin/vacask")
	if e := settings_set_program(args[1], args[2]); len(e) > 0 do cli_fail(EXIT_PROBLEMS, "settings", e)
	p, found := find_program(args[2])
	fmt.printfln("%s runs %s (%s), saved in %s", args[1], args[2], p if found else "not found", settings_path)
}

// --check-config: the problems in the settings, theme, shortcut and symbol files.
cli_check_config :: proc() {
	for e in config_errors do fmt.println(e)
	for e in shortcut_errors do fmt.println(e)
	if len(config_errors) + len(shortcut_errors) > 0 do os.exit(EXIT_PROBLEMS)
	fmt.println("no problems found")
}
