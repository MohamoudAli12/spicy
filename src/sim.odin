package spicy

import "core:fmt"
import "core:log"
import os "core:os"
import "core:strings"
import "core:time"

// Runs a simulator as a separate process (a crash cannot take spicy down), then reads
// the raw file(s) it wrote.

Run_State :: enum u8 {Idle, Running, Done, Failed}

Run :: struct {
	state:      Run_State,
	sim_id:     string,
	sim_name:   string,
	dialect:    string,
	per_analysis: bool, // the simulator writes one raw file per analysis into its run folder
	dir:        string,
	netlist:    string, // path
	raw:        string,
	log_path:   string,
	out_path:   string,
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
}

run_free :: proc(r: ^Run) {
	for &p in r.plots do plot_free(&p)
	delete(r.plots)
	delete(r.sim_id); delete(r.sim_name); delete(r.dialect); delete(r.dir); delete(r.netlist)
	delete(r.raw); delete(r.log_path); delete(r.out_path); delete(r.message)
	delete(r.log_text); delete(r.net_text)
	for w in r.warnings do delete(w)
	delete(r.warnings)
	for k in r.op do delete(k)
	delete(r.op)
	r^ = {}
}

// Folder for the files of a run.
run_dir_for :: proc(doc_path: string, doc_id: int, dialect: string) -> (dir, stem: string) {
	stem = stem_name(doc_path) if len(doc_path) > 0 else fmt.tprintf("untitled-%d", doc_id)
	switch S.output_dir {
	case "beside-schematic", "":
		if len(doc_path) > 0 {
			dir = dir_name(abs_path(doc_path))
			if dialect == "vacask" do dir = path_join(dir, tcat(stem, ".vacask"))
			return
		}
		dir = path_join(state_dir(), "runs", stem)
	case "state-folder":
		dir = path_join(state_dir(), "runs", stem)
	case:
		dir = path_join(S.output_dir, stem)
	}
	return
}

// Writes the netlist and starts the simulator. The result is filled into r.
run_start :: proc(r: ^Run, sch: ^Schematic, doc_path: string, doc_id: int, sim: ^Simulator_Def) {
	run_free(r)
	r.sim_id = strings.clone(sim.id)
	r.sim_name = strings.clone(sim.name)
	r.dialect = strings.clone(sim.dialect)
	r.per_analysis = sim.raw == "per-analysis"
	r.op = make(map[string]f64)
	dir, stem := run_dir_for(doc_path, doc_id, sim.dialect)
	r.dir = strings.clone(dir)
	os.make_directory_all(dir)
	ext := "sim" if sim.dialect == "vacask" else "net"
	r.netlist = strings.clone(path_join(dir, tcat(stem, ".", ext)))
	r.raw = strings.clone(path_join(dir, tcat(stem, ".raw")))
	r.log_path = strings.clone(path_join(dir, tcat(stem, ".log")))
	r.out_path = strings.clone(path_join(dir, tcat(stem, ".out")))

	title := doc_path if len(doc_path) > 0 else stem
	nl := netlist_build(sch, sim, tcat("spicy: ", base_name(title)), dir_of(abs_path(doc_path)) if len(doc_path) > 0 else "")
	r.net_text = strings.clone(nl.text)
	for w in nl.warnings do append(&r.warnings, strings.clone(w))
	if len(nl.errors) > 0 {
		r.state = .Failed
		r.message = strings.clone(strings.join(nl.errors[:], "\n", context.temp_allocator))
		return
	}
	if !write_text(r.netlist, nl.text) {
		r.state = .Failed
		r.message = fmt.aprintf("cannot write %s", r.netlist)
		return
	}
	// old results must not be mistaken for new ones
	os.remove(r.raw)
	os.remove(r.log_path)
	if sim.raw == "per-analysis" {
		_, files := list_dir(dir, {"raw"})
		for f in files do os.remove(path_join(dir, f))
	}
	cmd := make([dynamic]string, context.temp_allocator)
	for a in sim.command {
		x := a
		x, _ = strings.replace_all(x, "{netlist}", r.netlist, context.temp_allocator)
		x, _ = strings.replace_all(x, "{raw}", r.raw, context.temp_allocator)
		x, _ = strings.replace_all(x, "{log}", r.log_path, context.temp_allocator)
		x, _ = strings.replace_all(x, "{dir}", r.dir, context.temp_allocator)
		if strings.has_prefix(x, "~/") do x = path_join(home_dir(), x[2:])
		append(&cmd, x)
	}
	// PSpice models: ngspice's compatibility mode (unless the command sets one itself)
	if len(nl.ngbehavior) > 0 && sim_is_ngspice(sim) && len(cmd) > 0 && !strings.contains(strings.join(sim.command, " ", context.temp_allocator), "ngbehavior") {
		inject_at(&cmd, 1, "-D", tcat("ngbehavior=", nl.ngbehavior))
	}
	out, oerr := os.create(r.out_path)
	if oerr == nil do r.out_file = out
	log.infof("run: %s", strings.join(cmd[:], " ", context.temp_allocator))
	p, err := os.process_start({command = cmd[:], working_dir = r.dir, stdout = r.out_file, stderr = r.out_file})
	if err != nil {
		r.state = .Failed
		r.message = fmt.aprintf("Could not start %s (\"%s\"): %v.\nIs it installed? Set its path under :simulators :%s :command in settings.edn.", sim.name, cmd[0], err, sim.id)
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
	lt, _ := read_text(r.log_path, context.temp_allocator)
	ot, _ := read_text(r.out_path, context.temp_allocator)
	r.log_text = strings.clone(strings.trim_space(tcat(ot, "\n", lt)))
	// raw files
	files := make([dynamic]string, context.temp_allocator)
	// only this run's files: a single-raw simulator runs in the schematic's folder, where the
	// raw files of other schematics may lie
	if r.per_analysis {
		_, fs := list_dir(r.dir, {"raw"})
		for f in fs do append(&files, path_join(r.dir, f))
	} else if file_exists(r.raw) {
		append(&files, r.raw)
	}
	errs := make([dynamic]string, context.temp_allocator)
	for f in files {
		plots, perr := raw_read(f)
		if len(perr) > 0 do append(&errs, perr)
		for p in plots do append(&r.plots, p)
		delete(plots)
	}
	// operating point values for the schematic
	for &p in r.plots {
		if plot_kind(&p) != "op" || p.npoints < 1 do continue
		for v in p.vecs {
			n := lower(v.name)
			if strings.has_prefix(n, "v(") && strings.has_suffix(n, ")") do n = n[2:len(n) - 1]
			r.op[strings.clone(n)] = v.re[0]
		}
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
	n := 0
	for p in r.plots do n += p.npoints
	r.message = fmt.aprintf("%s: %d plot%s, %.2f s", r.sim_name, len(r.plots), "" if len(r.plots) == 1 else "s", r.elapsed)
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
