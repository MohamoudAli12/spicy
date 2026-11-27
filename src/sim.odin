package spicy

import "core:fmt"
import "core:log"
import os "core:os"
import "core:strings"
import "core:time"

// Runs a simulator as a separate process (a crash cannot take spicy down), then reads
// the raw file(s) it wrote. A run with a .step directive runs the simulator once per step
// value, one after the other; the plots of each step are labelled with its value.

Run_State :: enum u8 {Idle, Running, Done, Failed}

// One simulator process of a run: its files and its command line.
Run_Step :: struct {
	label:    string, // "R=2k" for a .step run, "" for a single run
	netlist:  string,
	raw:      string, // where the results are (a simulator writing a raw file per analysis: Run.dir)
	log_path: string,
	out_path: string, // the simulator's output (stdout and stderr)
	cmd:      [dynamic]string,
}

Run :: struct {
	state:      Run_State,
	sim_id:     string,
	sim_name:   string,
	dialect:    Dialect,
	raw_files:  Raw_Files,
	dir:        string,
	proc_:      os.Process,
	out_file:   ^os.File,
	started:    time.Tick,
	elapsed:    f64,
	plots:      [dynamic]Plot,
	message:    string, // error or summary
	log_text:   string,
	net_text:   string,
	warnings:   [dynamic]string,
	op:         map[string]f64, // net name (lower) -> voltage, from an operating point plot
	plot_traces: [dynamic]string, // .plot directives: shown in the waveform viewer when the run is done
	meas_lines: [dynamic]string, // .meas directives: measured on the results when the run is done
	measures:   [dynamic]string, // their results, one line each
	meas_rows:  [dynamic]Meas_Row, // the same results, for the measurement table
	steps:      [dynamic]Run_Step, // one per simulator process
	cur:        int, // the step that runs
}

run_free :: proc(r: ^Run) {
	for &p in r.plots do plot_free(&p)
	delete(r.plots)
	delete(r.sim_id); delete(r.sim_name); delete(r.dir); delete(r.message)
	delete(r.log_text); delete(r.net_text)
	for w in r.warnings do delete(w)
	delete(r.warnings)
	for k in r.op do delete(k)
	delete(r.op)
	for s in r.plot_traces do delete(s)
	delete(r.plot_traces)
	for s in r.meas_lines do delete(s)
	delete(r.meas_lines)
	for s in r.measures do delete(s)
	delete(r.measures)
	for row in r.meas_rows do delete_meas_row(row)
	delete(r.meas_rows)
	for &st in r.steps do run_step_free(&st)
	delete(r.steps)
	r^ = {}
}

// Folder for the files of a run.
run_dir_for :: proc(doc_path: string, doc_id: int, dialect: Dialect) -> (dir, stem: string) {
	stem = stem_name(doc_path) if len(doc_path) > 0 else fmt.tprintf("untitled-%d", doc_id)
	switch S.output_place {
	case .Beside_Schematic:
		if len(doc_path) > 0 {
			dir = dir_name(abs_path(doc_path))
			if dialect == .Vacask do dir = path_join(dir, tcat(stem, ".vacask"))
			return
		}
		dir = path_join(state_dir(), "runs", stem)
	case .State_Folder:
		dir = path_join(state_dir(), "runs", stem)
	case .Folder:
		dir = path_join(S.output_dir, stem)
	}
	return
}

// Writes the netlist(s) and starts the simulator. The result is filled into r.
run_start :: proc(r: ^Run, sch: ^Schematic, doc_path: string, doc_id: int, sim: ^Simulator_Def) {
	run_free(r)
	r.sim_id = strings.clone(sim.id)
	r.sim_name = strings.clone(sim.name)
	r.dialect, r.raw_files = sim.dialect, sim.raw
	r.op = make(map[string]f64)
	dir, stem := run_dir_for(doc_path, doc_id, sim.dialect)
	r.dir = strings.clone(dir)
	os.make_directory_all(dir)
	ext := "sim" if sim.dialect == .Vacask else "net"

	title := doc_path if len(doc_path) > 0 else stem
	nl := netlist_build(sch, sim, tcat("spicy: ", base_name(title)), dir_of(abs_path(doc_path)) if len(doc_path) > 0 else "")
	r.net_text = strings.clone(nl.text)
	for w in nl.warnings do append(&r.warnings, strings.clone(w))
	for e in nl.plot_traces do append(&r.plot_traces, strings.clone(e))
	for e in nl.meas_lines do append(&r.meas_lines, strings.clone(e))
	if len(nl.errors) > 0 {
		r.state = .Failed
		r.message = strings.clone(strings.join(nl.errors[:], "\n", context.temp_allocator))
		return
	}
	// one step: the schematic's own files; a .step run: a netlist, raw and log per value
	n := max(1, len(nl.steps))
	for k in 0 ..< n {
		text := nl.text
		label := ""
		step_stem := stem
		if len(nl.steps) > 0 {
			label = nl.steps[k].label
			text = step_netlist(nl.text, nl.steps[k].assign, sim.dialect == .Vacask)
			step_stem = tcat(stem, ".step", itoa(k + 1))
		}
		netlist := path_join(dir, tcat(step_stem, ".", ext))
		st := Run_Step{
			label    = strings.clone(label),
			netlist  = strings.clone(netlist),
			raw      = strings.clone(tcat(netlist, ".raw") if nl.xyce_print_raw else path_join(dir, tcat(step_stem, ".raw"))),
			log_path = strings.clone(path_join(dir, tcat(step_stem, ".log"))),
			out_path = strings.clone(path_join(dir, tcat(step_stem, ".out"))),
		}
		if !write_text(st.netlist, text) {
			r.state = .Failed
			r.message = fmt.aprintf("cannot write %s", st.netlist)
			run_step_free(&st)
			return
		}
		for c in run_command(sim, &nl, &st, dir) do append(&st.cmd, strings.clone(c))
		append(&r.steps, st)
	}
	r.cur = 0
	run_launch(r)
}

// The command line of a step: the simulator's :command with the step's files.
@(private = "file")
run_command :: proc(sim: ^Simulator_Def, nl: ^Netlist, st: ^Run_Step, dir: string) -> []string {
	cmd := make([dynamic]string, context.temp_allocator)
	for a in sim.command {
		x := a
		x, _ = strings.replace_all(x, "{netlist}", st.netlist, context.temp_allocator)
		x, _ = strings.replace_all(x, "{raw}", st.raw, context.temp_allocator)
		x, _ = strings.replace_all(x, "{log}", st.log_path, context.temp_allocator)
		x, _ = strings.replace_all(x, "{dir}", dir, context.temp_allocator)
		if strings.has_prefix(x, "~/") do x = path_join(home_dir(), x[2:])
		append(&cmd, x)
	}
	// Xyce with a .print … format=raw line, or a noise-only netlist (its noise is in the
	// _noise.dat file, and -r would only add the transfer function): no -r
	if nl.xyce_print_raw || nl.xyce_noise_only {
		for i := 1; i + 1 < len(cmd); i += 1 do if cmd[i] == "-r" && cmd[i + 1] == st.raw {
			remove_range(&cmd, i, i + 2)
			break
		}
	}
	// PSpice models: ngspice's compatibility mode (unless the command sets one itself)
	if len(nl.ngbehavior) > 0 && sim_is_ngspice(sim) && len(cmd) > 0 && !strings.contains(strings.join(sim.command, " ", context.temp_allocator), "ngbehavior") {
		inject_at(&cmd, 1, "-D", tcat("ngbehavior=", nl.ngbehavior))
	}
	return cmd[:]
}

@(private = "file")
run_step_free :: proc(st: ^Run_Step) {
	delete(st.label); delete(st.netlist); delete(st.raw); delete(st.log_path); delete(st.out_path)
	for c in st.cmd do delete(c)
	delete(st.cmd)
}

// Starts the simulator for the current step.
run_launch :: proc(r: ^Run) {
	st := &r.steps[r.cur]
	// results of an earlier run or step must not be read as this one's (a simulator that
	// fails writes none): a per-analysis simulator writes the same names every step
	if r.raw_files == .Per_Analysis {
		_, files := list_dir(r.dir, {"raw"})
		for f in files do os.remove(path_join(r.dir, f))
	}
	os.remove(st.raw)
	os.remove(tcat(st.netlist, "_noise.dat"))
	os.remove(st.log_path)
	out, oerr := os.create(st.out_path)
	if oerr == nil do r.out_file = out
	log.infof("run: %s", strings.join(st.cmd[:], " ", context.temp_allocator))
	p, err := os.process_start({command = st.cmd[:], working_dir = r.dir, stdout = r.out_file, stderr = r.out_file})
	if err != nil {
		r.state = .Failed
		r.message = fmt.aprintf("Could not start %s (\"%s\"): %v.\nIs it installed? Set its path under :simulators :%s :command in settings.edn.", r.sim_name, st.cmd[0], err, r.sim_id)
		if r.out_file != nil {os.close(r.out_file); r.out_file = nil}
		return
	}
	r.proc_ = p
	r.state = .Running
	r.started = time.tick_now()
}

run_stop :: proc(r: ^Run) {
	if r.state != .Running do return
	_ = os.process_kill(r.proc_)
	_, _ = os.process_wait(r.proc_)
	if r.out_file != nil {os.close(r.out_file); r.out_file = nil}
	r.state = .Failed
	set_str(&r.message, "stopped")
}

// Adds a part of the simulator log: the whole log of a single run, or a headed part of a .step run.
@(private = "file")
run_log_add :: proc(r: ^Run, header, text: string) {
	old := r.log_text
	if len(header) > 0 {
		r.log_text = strings.concatenate({old, header, "\n", text, "\n\n"})
	} else {
		r.log_text = strings.clone(text)
	}
	delete(old)
}

// Called every frame; returns true when the run has just finished.
run_poll :: proc(r: ^Run) -> bool {
	if r.state != .Running do return false
	r.elapsed = time.duration_seconds(time.tick_since(r.started))
	st, err := os.process_wait(r.proc_, 0)
	if err != nil || !st.exited {
		if S.timeout > 0 && r.elapsed > S.timeout {
			run_stop(r)
			set_str(&r.message, fmt.tprintf("stopped after the %.0f s timeout (:simulation :timeout in settings.edn)", S.timeout))
			return true
		}
		return false
	}
	if r.out_file != nil {os.close(r.out_file); r.out_file = nil}
	step := &r.steps[r.cur]
	label := step.label
	lt, _ := read_text(step.log_path, context.temp_allocator)
	ot, _ := read_text(step.out_path, context.temp_allocator)
	text := strings.trim_space(tcat(ot, "\n", lt))
	if len(r.steps) == 1 {
		run_log_add(r, "", text)
	} else {
		run_log_add(r, tcat("== ", label, " =="), text)
	}
	// raw files
	files := make([dynamic]string, context.temp_allocator)
	// only this run's files: a single-raw simulator runs in the schematic's folder, where the
	// raw files of other schematics may lie
	if r.raw_files == .Per_Analysis {
		_, fs := list_dir(r.dir, {"raw"})
		for f in fs do append(&files, path_join(r.dir, f))
	} else if file_exists(step.raw) {
		append(&files, step.raw)
	}
	errs := make([dynamic]string, context.temp_allocator)
	before := len(r.plots)
	for f in files {
		plots, perr := raw_read(f)
		if len(perr) > 0 do append(&errs, perr)
		for &p in plots {
			// VACASK's DC sweep (spicy's "analysis dcN op" in a sweep) is named "Operating Point"
			if r.dialect == .Vacask && strings.has_prefix(base_name(f), "dc") && p.npoints > 1 && strings.contains(lower(p.name), "operating") {
				delete(p.name)
				p.name = strings.clone("DC transfer characteristic")
			}
			append(&r.plots, p)
		}
		delete(plots)
	}
	// Xyce writes its noise analysis to a text file beside the netlist; VACASK's noise is a raw file
	noise_file := tcat(step.netlist, "_noise.dat")
	if file_exists(noise_file) {
		np, nerr := xyce_noise_read(noise_file)
		if len(nerr) > 0 do append(&errs, nerr)
		else do append(&r.plots, np)
	}
	if r.dialect == .Vacask {
		for &p in r.plots[before:] do vacask_noise_density(&p)
	}
	for &p in r.plots[before:] do noise_units(&p)
	// the integrated noise, where the simulator gives none (ngspice has its own, which is used)
	has_totals := false
	for &p in r.plots[before:] do if strings.has_prefix(p.name, "Integrated Noise") do has_totals = true
	if !has_totals {
		n := len(r.plots)
		for i in before ..< n {
			if plot_kind(&r.plots[i]) != "noise" do continue
			if t, ok := noise_totals(&r.plots[i]); ok do append(&r.plots, t)
		}
	}
	// the plots of a .step run say which value they are for
	if len(label) > 0 {
		for i in before ..< len(r.plots) {
			old := r.plots[i].name
			r.plots[i].name = strings.concatenate({old, " [", label, "]"})
			delete(old)
		}
	}
	// operating point values for the schematic
	for &p in r.plots[before:] {
		if plot_kind(&p) != "op" || p.npoints < 1 do continue
		for v in p.vecs {
			n := lower(v.name)
			if strings.has_prefix(n, "v(") && strings.has_suffix(n, ")") do n = n[2:len(n) - 1]
			r.op[strings.clone(n)] = v.re[0]
		}
	}
	if len(r.steps) > 1 && len(r.plots) == before do append(&r.warnings, strings.clone(fmt.tprintf("[%s]: no results", label)))
	// the next value of a .step run
	if r.cur + 1 < len(r.steps) {
		r.cur += 1
		run_launch(r)
		return r.state == .Failed
	}
	if len(r.plots) == 0 {
		r.state = .Failed
		msg := fmt.tprintf("%s finished (exit code %d) without results.", r.sim_name, st.exit_code)
		if len(errs) > 0 do msg = tcat(msg, "\n", strings.join(errs[:], "\n", context.temp_allocator))
		tail := log_errors(r.log_text)
		if len(tail) > 0 do msg = tcat(msg, "\n\n", tail)
		r.message = strings.clone(msg)
		return true
	}
	r.state = .Done
	steps_note := ""
	if len(r.steps) > 1 do steps_note = fmt.tprintf(" (%d steps)", len(r.steps))
	r.message = fmt.aprintf("%s: %d plot%s%s, %.2f s", r.sim_name, len(r.plots), "" if len(r.plots) == 1 else "s", steps_note, r.elapsed)
	if st.exit_code != 0 do set_str(&r.message, fmt.tprintf("%s (exit code %d – see the log)", r.message, st.exit_code))
	return true
}

// Lines of a simulator log that look like errors (or its last lines).
log_errors :: proc(text: string) -> string {
	lines := split_lines(text)
	out := make([dynamic]string, context.temp_allocator)
	for l in lines {
		low := lower(l)
		if strings.contains(low, "error") || strings.contains(low, "fatal") || strings.contains(low, "not found") || strings.contains(low, "failed") || strings.contains(low, "unknown") || strings.contains(low, "singular") || strings.contains(low, "too small") {
			append(&out, strings.trim_space(l))
		}
		if len(out) >= 12 do break
	}
	if len(out) == 0 {
		start := max(0, len(lines) - 10)
		for l in lines[start:] do if !is_blank(l) do append(&out, l)
	}
	return strings.join(out[:], "\n", context.temp_allocator)
}
