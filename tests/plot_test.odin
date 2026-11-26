package spicy_tests

import "core:strings"
import "core:testing"
import C "../src"

// The .plot directive: its lines, its checks, and the analysis it is shown in.

@(test)
plot_lines :: proc(t: ^testing.T) {
	args, ok := C.plot_line_args("  .plot V(out), I(R1)  ")
	testing.expect(t, ok)
	testing.expect_value(t, args, "V(out), I(R1)")
	_, ok2 := C.plot_line_args(".plots V(out)")
	testing.expect(t, !ok2) // another card, not .plot
	_, ok3 := C.plot_line_args(".tran 1m")
	testing.expect(t, !ok3)
	args4, ok4 := C.plot_line_args(".plot")
	testing.expect(t, ok4)
	testing.expect_value(t, args4, "")
	parts := C.plot_split("V(a,b), I(R1) ,V(out)*2")
	testing.expect_value(t, len(parts), 3)
	if len(parts) == 3 {
		testing.expect_value(t, parts[0], "V(a,b)")
		testing.expect_value(t, parts[1], "I(R1)")
		testing.expect_value(t, parts[2], "V(out)*2")
	}
}

@(test)
plot_syntax :: proc(t: ^testing.T) {
	good := [?]string{"V(out)", "V(a,b)", "db(V(out))", "-V(out)^2", "I(R1)", "Ic(Q1)", "V(out)*I(R1)/2", "max(V(out), 1e3)", "i(@r1[i])", "time", "1.5k", ".5", "V(out) * (2 + V(in))", "ph(V(out)) / 2", "if(V(out) > 0.5, 1, 0)", "if(V(out), V(out)*10, -1)"}
	for e in good {
		_, err := C.plot_check_expr(e, ".plot V(out), I(R1)")
		testing.expectf(t, len(err) == 0, "%q should be accepted: %s", e, err)
	}
	bad := [?]string{"", "V(", "V(out))", "V()", "V(a,b,c)", "foo(out)", "if(V(out), 1", "if(V(out), 1)", "min(V(out))", "db(V(out), 2)", "1.2.3", "V(out) I(R1)", "V(out)*", "I()", "3 $", "V(out) * ("}
	for e in bad {
		_, err := C.plot_check_expr(e, ".plot V(out), I(R1)")
		testing.expectf(t, len(err) > 0, "%q should be refused", e)
		testing.expectf(t, strings.contains(err, "Correct:"), "%q: the message has no correct syntax: %s", e, err)
	}
}

// The schematic of examples/rc_lowpass.edn with one .plot directive added.
rc_with_plot :: proc(directive: string) -> C.Schematic {
	text, _ := C.read_text("examples/rc_lowpass.edn")
	s, _ := C.sch_from_edn(text)
	append(&s.texts, C.Text{text = strings.clone(directive), directive = true})
	return s
}

@(test)
plot_netlist :: proc(t: ^testing.T) {
	setup()
	ng := C.simulator_def("ngspice")
	testing.expect(t, ng != nil)

	s := rc_with_plot(".plot V(out), I(R1)")
	nl := C.netlist_build(&s, ng, "rc")
	testing.expect_value(t, len(nl.errors), 0)
	testing.expect_value(t, len(nl.plot_traces), 2)
	if len(nl.plot_traces) == 2 {
		testing.expect_value(t, nl.plot_traces[0], "V(out)")
		testing.expect_value(t, nl.plot_traces[1], "I(R1)")
	}
	testing.expect(t, !strings.contains(nl.text, ".plot"), nl.text) // the simulator never sees it
	testing.expect(t, strings.contains(nl.text, ".tran 20n 20u"), nl.text)

	// names the schematic does not have
	bad := [?]struct {
		line, want: string,
	}{
		{".plot V(outt)", `no net "outt"`},
		{".plot I(R9)", `no part "R9"`},
		{".plot V(out) I(R1)", "cannot follow the expression"},
		{".plot V(out),", "needs an expression"},
		{".plot", "needs an expression"},
		{".plot V(out", "is never closed"},
	}
	for b in bad {
		s2 := rc_with_plot(b.line)
		nl2 := C.netlist_build(&s2, ng, "rc")
		found := false
		for e in nl2.errors do if strings.contains(e, b.want) do found = true
		testing.expectf(t, found, "%s: want an error with %q, got %v", b.line, b.want, nl2.errors)
		// every message shows the correct syntax
		for e in nl2.errors do testing.expectf(t, strings.contains(e, "Correct:"), "%s: no correct syntax in %q", b.line, e)
	}

	// the names of the schematic are matched without case; ground under either name
	s3 := rc_with_plot(".plot v(OUT), V(gnd), V(0)")
	nl3 := C.netlist_build(&s3, ng, "rc")
	testing.expect_value(t, len(nl3.errors), 0)

	// a .plot of another simulator's block is not checked for this one
	s4 := rc_with_plot("#vacask\n.plot V(nope)")
	nl4 := C.netlist_build(&s4, ng, "rc")
	testing.expect_value(t, len(nl4.errors), 0)
	testing.expect_value(t, len(nl4.plot_traces), 0)
}

// Copies of the values: a slice of a literal would point into this procedure's stack.
f64s :: proc(xs: ..f64) -> []f64 {
	out := make([]f64, len(xs))
	copy(out, xs)
	return out
}

// Two analyses: an operating point with only out, and a transient with out and in.
two_plots :: proc() -> C.Run {
	r: C.Run
	op := C.Plot{name = "Operating Point", npoints = 1}
	append(&op.vecs, C.Vec{name = "v(out)", unit = "V", re = f64s(1)})
	tr := C.Plot{name = "Transient Analysis", npoints = 3}
	append(&tr.vecs, C.Vec{name = "time", unit = "s", re = f64s(0, 1, 2)})
	append(&tr.vecs, C.Vec{name = "v(out)", unit = "V", re = f64s(0, 1, 2)})
	append(&tr.vecs, C.Vec{name = "v(in)", unit = "V", re = f64s(0, 2, 4)})
	append(&r.plots, op, tr)
	return r
}

@(test)
plot_pick_analysis :: proc(t: ^testing.T) {
	setup()
	ng := C.simulator_def("ngspice")
	s := rc_with_plot(".plot V(in)")
	r := two_plots()
	append(&r.plot_traces, "V(in)")
	// the operating point has no v(in): the transient is chosen
	testing.expect_value(t, C.plot_pick(&r, &s, ng, 0), 1)
	testing.expect_value(t, len(r.warnings), 0)
	// the transient is already the one shown: it stays
	testing.expect_value(t, C.plot_pick(&r, &s, ng, 1), 1)

	// nothing has it: the shown analysis, and a warning for the expression
	clear(&r.plot_traces)
	append(&r.plot_traces, "V(nope)")
	testing.expect_value(t, C.plot_pick(&r, &s, ng, 0), 0)
	testing.expect_value(t, len(r.warnings), 1)
	if len(r.warnings) == 1 do testing.expect(t, strings.contains(r.warnings[0], `.plot "V(nope)"`), r.warnings[0])
}

@(test)
plot_traces_in_viewer :: proc(t: ^testing.T) {
	setup()
	ng := C.simulator_def("ngspice")
	s := rc_with_plot(".plot V(in), V(out)")
	r := two_plots()
	append(&r.plot_traces, "V(in)")
	append(&r.plot_traces, "V(out)")
	w: C.Wave_View
	C.wave_init(&w)
	C.wave_new_run(&w, &r, &s, ng)
	testing.expect_value(t, w.plot_idx, 1)
	testing.expect_value(t, len(w.panes), 1)
	if len(w.panes) == 1 {
		testing.expect_value(t, len(w.panes[0].traces), 2)
		if len(w.panes[0].traces) == 2 {
			testing.expect_value(t, w.panes[0].traces[0].expr, "V(in)")
			testing.expect_value(t, w.panes[0].traces[1].expr, "V(out)")
		}
	}
}

@(test)
comparisons :: proc(t: ^testing.T) {
	setup()
	ng := C.simulator_def("ngspice")
	for e in ([?]string{"V(out) > 0.5", "V(out) == 1", "(V(out) >= 1) * 2", "V(out) != 2 + 1"}) {
		_, err := C.plot_check_expr(e, ".plot V(out), I(R1)")
		testing.expectf(t, len(err) == 0, "%q should be accepted: %s", e, err)
	}
	for e in ([?]string{"V(out) =", "V(out) !", "V(out) >"}) {
		_, err := C.plot_check_expr(e, ".plot V(out), I(R1)")
		testing.expectf(t, len(err) > 0 && strings.contains(err, "Correct:"), "%q should be refused with an example: %s", e, err)
	}
	// V(out) is 0, 1, 2 over time 0, 1, 2
	r := two_plots()
	res := C.expr_eval("V(out) > 0.5", &r.plots[1], nil, ng)
	testing.expect_value(t, res.err, "")
	if len(res.re) == 3 {
		testing.expect_value(t, res.re[0], 0.0)
		testing.expect_value(t, res.re[1], 1.0)
		testing.expect_value(t, res.re[2], 1.0)
	}
	res2 := C.expr_eval("(V(out) == 1) + (V(out) <= 1) * 10", &r.plots[1], nil, ng)
	testing.expect_value(t, res2.err, "")
	if len(res2.re) == 3 {
		testing.expect_value(t, res2.re[0], 10.0)
		testing.expect_value(t, res2.re[1], 1.0 + 10.0)
		testing.expect_value(t, res2.re[2], 0.0)
	}
	// if(c, a, b): a where c is nonzero, otherwise b. V(out) is 0, 1, 2.
	res3 := C.expr_eval("if(V(out) > 0.5, 10, -1)", &r.plots[1], nil, ng)
	testing.expect_value(t, res3.err, "")
	if len(res3.re) == 3 {
		testing.expect_value(t, res3.re[0], -1.0)
		testing.expect_value(t, res3.re[1], 10.0)
		testing.expect_value(t, res3.re[2], 10.0)
	}
	res4 := C.expr_eval("if(V(out), V(out) * 10, 0 - 1)", &r.plots[1], nil, ng)
	testing.expect_value(t, res4.err, "")
	if len(res4.re) == 3 {
		testing.expect_value(t, res4.re[0], -1.0)
		testing.expect_value(t, res4.re[1], 10.0)
		testing.expect_value(t, res4.re[2], 20.0)
	}
	res5 := C.expr_eval("if(V(out) > 0.5, 1)", &r.plots[1], nil, ng)
	testing.expect(t, len(res5.err) > 0, "if() with two arguments should fail")
}

// A noise analysis and a transient analysis in one run: each shows the .plot traces it can
// evaluate, and Tab (wave_next_plot) moves the others in.
@(test)
plot_traces_per_analysis :: proc(t: ^testing.T) {
	setup()
	ng := C.simulator_def("ngspice")
	s := rc_with_plot(".plot V(in), onoise_spectrum")
	r: C.Run
	noise := C.Plot{name = "Noise Spectral Density Curves", npoints = 2}
	append(&noise.vecs, C.Vec{name = "frequency", unit = "Hz", re = f64s(1, 10)})
	append(&noise.vecs, C.Vec{name = "onoise_spectrum", unit = "V/√Hz", re = f64s(3, 4)})
	tr := C.Plot{name = "Transient Analysis", npoints = 3}
	append(&tr.vecs, C.Vec{name = "time", unit = "s", re = f64s(0, 1, 2)})
	append(&tr.vecs, C.Vec{name = "v(in)", unit = "V", re = f64s(0, 2, 4)})
	append(&r.plots, noise, tr)
	append(&r.plot_traces, "V(in)")
	append(&r.plot_traces, "onoise_spectrum")
	w: C.Wave_View
	C.wave_init(&w)
	C.wave_new_run(&w, &r, &s, ng)
	testing.expect_value(t, w.plot_idx, 0)
	if len(w.panes) == 1 {
		testing.expect_value(t, len(w.panes[0].traces), 1)
		if len(w.panes[0].traces) == 1 do testing.expect_value(t, w.panes[0].traces[0].expr, "onoise_spectrum")
	}
	C.wave_next_plot(&w, &r, &s, ng)
	testing.expect_value(t, w.plot_idx, 1)
	if len(w.panes) == 1 {
		testing.expect_value(t, len(w.panes[0].traces), 1)
		if len(w.panes[0].traces) == 1 do testing.expect_value(t, w.panes[0].traces[0].expr, "V(in)")
	}
}

// Xyce refuses a reference node in the .noise output (V(out,ref)): a clear error before the run.
@(test)
xyce_noise_reference :: proc(t: ^testing.T) {
	setup()
	xy := C.simulator_def("xyce")
	testing.expect(t, xy != nil)
	if xy == nil do return
	s := rc_with_plot(".noise V(out,in) V1 dec 5 10 1Meg")
	nl := C.netlist_build(&s, xy, "rc")
	found := false
	for e in nl.errors do if strings.contains(e, "Xyce does not accept a reference node") && strings.contains(e, "Correct:") do found = true
	testing.expect(t, found, "no error for V(out,ref) on Xyce")
	s2 := rc_with_plot(".noise V(out) V1 dec 5 10 1Meg")
	nl2 := C.netlist_build(&s2, xy, "rc")
	for e in nl2.errors do testing.expectf(t, !strings.contains(e, "reference node"), "V(out) refused on Xyce: %s", e)
	ng := C.simulator_def("ngspice")
	s3 := rc_with_plot(".noise V(out,in) V1 dec 5 10 1Meg")
	nl3 := C.netlist_build(&s3, ng, "rc")
	for e in nl3.errors do testing.expectf(t, !strings.contains(e, "reference node"), "V(out,ref) refused on ngspice: %s", e)
}
