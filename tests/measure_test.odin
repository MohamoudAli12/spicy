package spicy_tests

import "core:math"
import "core:strings"
import "core:testing"
import C "../src"

// .meas, .step and the measurements of a run, on a waveform whose answers are known.

@(test)
meas_parsing :: proc(t: ^testing.T) {
	m, err := C.meas_parse("tran vmax MAX V(out) FROM=1u TO=2u")
	testing.expect_value(t, err, "")
	testing.expect_value(t, m.op, "MAX")
	testing.expect_value(t, m.expr, "V(out)")
	testing.expect(t, m.has_from && m.has_to && m.from == 1e-6 && m.to == 2e-6)

	m2, err2 := C.meas_parse("tran tr TRIG V(in) VAL=0.5 RISE=1 TARG V(out) VAL=0.9 FALL=2")
	testing.expect_value(t, err2, "")
	testing.expect_value(t, m2.expr, "V(in)")
	testing.expect_value(t, m2.targ, "V(out)")
	testing.expect(t, m2.val == 0.5 && m2.edge == .Rise && m2.n == 1)
	testing.expect(t, m2.targ_val == 0.9 && m2.targ_edge == .Fall && m2.targ_n == 2)

	m3, err3 := C.meas_parse("tran x FIND V(a, b) * 2 AT=3m")
	testing.expect_value(t, err3, "")
	testing.expect_value(t, m3.expr, "V(a, b) * 2")
	testing.expect(t, m3.at == 3e-3)

	bad := [?]string{"", "tran x", "xx x MAX V(out)", "tran 9x MAX V(out)", "tran x MEDIAN V(out)", "tran x FIND V(out)", "tran x MAX V(out) FOO=1", "tran x TRIG V(in) TARG V(out) VAL=1", "tran x TRIG V(in) VAL=0.5 TARG V(out) VAL=0.9 CROSS=0", "tran x MAX V(out) +"}
	for b in bad {
		_, e := C.meas_parse(b)
		testing.expectf(t, len(e) > 0 && strings.contains(e, "Correct:"), "%q: want an error with the correct syntax, got %q", b, e)
	}
}

@(test)
step_forms :: proc(t: ^testing.T) {
	vals, err := C.step_values("param R list 1k 2k 4.7k")
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(vals), 3)
	if len(vals) == 3 {
		testing.expect_value(t, vals[1].label, "R=2k")
		testing.expect_value(t, vals[2].assign, "R=4.7k")
	}
	r, err2 := C.step_values("param R 1k 3k 1k")
	testing.expect_value(t, err2, "")
	testing.expect_value(t, len(r), 3)
	if len(r) == 3 {
		testing.expect_value(t, r[2].assign, "R=3000")
	}
	bad := [?]string{"param 9x list 1k", "list 1k", "param R 1k 3k 0", "param R 3k 1k 1k", "param R 1k 1000k 1k", "param R list 1k abc"}
	for b in bad {
		_, e := C.step_values(b)
		testing.expectf(t, len(e) > 0 && strings.contains(e, "Correct:"), "%q: want an error with the correct syntax, got %q", b, e)
	}
	// an existing definition is changed in place (Xyce keeps the first one, VACASK refuses a second)
	out := C.step_netlist("* t\nR1 a b 1k\n.param R=1k\n.end\n", "R=2k", false)
	testing.expect_value(t, out, "* t\nR1 a b 1k\n.param R=2k\n.end\n")
	// no definition: one is added before .end (SPICE) or before control (VACASK)
	out = C.step_netlist("* t\nR1 a b 1k\n.end\n", "R=2k", false)
	testing.expect_value(t, out, "* t\nR1 a b 1k\n.param R=2k\n.end\n")
	out = C.step_netlist("parameters R=1k\nr1 (a b) spicy_r r=R\ncontrol\nendc\n", "R=2k", true)
	testing.expect_value(t, out, "parameters R=2k\nr1 (a b) spicy_r r=R\ncontrol\nendc\n")
	out = C.step_netlist("r1 (a b) spicy_r r=R\ncontrol\nendc\n", "R=2k", true)
	testing.expect_value(t, out, "r1 (a b) spicy_r r=R\nparameters R=2k\ncontrol\nendc\n")
	// VACASK: a parameter an analysis uses is a control block variable too: both change
	out = C.step_netlist("parameters ts=20u\ncontrol\n  var ts=20u\n  analysis tran1 tran step=(ts)/1000 stop=ts\nendc\n", "ts=40u", true)
	testing.expect_value(t, out, "parameters ts=40u\ncontrol\n  var ts=40u\n  analysis tran1 tran step=(ts)/1000 stop=ts\nendc\n")
}

// x = 0 1 2 3 4, y = 0 1 2 1 0
@(test)
measurements :: proc(t: ^testing.T) {
	setup()
	ng := C.simulator_def("ngspice")
	p: C.Plot
	p.name = "Transient Analysis"
	p.npoints = 5
	append(&p.vecs, C.Vec{name = "time", unit = "s", re = f64s(0, 1, 2, 3, 4)})
	append(&p.vecs, C.Vec{name = "v(out)", unit = "V", re = f64s(0, 1, 2, 1, 0)})
	cases := [?]struct {
		src, want: string,
	}{
		{"tran x MAX V(out)", "x = 2 V at 2 s"},
		{"tran x MIN V(out) FROM=1", "x = 0 V at 4 s"},
		{"tran x PP V(out)", "x = 2 V"},
		{"tran x AVG V(out)", "x = 1 V"},
		{"tran x INTEG V(out)", "x = 4 V·s"},
		{"tran x FIND V(out) AT=1.5", "x = 1.5 V at 1.5 s"},
		{"tran x TRIG V(out) VAL=0.5 RISE=1 TARG V(out) VAL=1.5 FALL=1", "x = 2 s"},
	}
	for c in cases {
		m, err := C.meas_parse(c.src)
		testing.expect_value(t, err, "")
		line, e2 := C.meas_on_plot(&m, &p, nil, ng)
		testing.expectf(t, len(e2) == 0 && line == c.want, "%s: got %q (%s), want %q", c.src, line, e2, c.want)
	}
	// a point outside the waveform
	m, _ := C.meas_parse("tran x FIND V(out) AT=9")
	_, e3 := C.meas_on_plot(&m, &p, nil, ng)
	testing.expect(t, strings.contains(e3, "outside"), e3)
}

// The .meas results of a run go to the measurement table, and Tab reaches the table.
@(test)
meas_table :: proc(t: ^testing.T) {
	setup()
	ng := C.simulator_def("ngspice")
	s := rc_with_plot(".meas tran vmax MAX V(out)")
	r := two_plots()
	append(&r.meas_lines, "tran vmax MAX V(out)")
	C.meas_run(&r, &s, ng)
	testing.expect_value(t, len(r.meas_rows), 1)
	if len(r.meas_rows) == 1 {
		testing.expect_value(t, r.meas_rows[0].name, "vmax")
		testing.expect_value(t, r.meas_rows[0].measure, "MAX V(out)")
		testing.expect_value(t, r.meas_rows[0].analysis, "Transient Analysis")
		testing.expect(t, len(r.meas_rows[0].result) > 0, "the result is empty")
	}
	w: C.Wave_View
	C.wave_init(&w)
	C.wave_new_run(&w, &r, &s, ng)
	testing.expect_value(t, w.table, C.TABLE_NONE)
	reached := false
	for _ in 0 ..< 3 {
		C.wave_next_plot(&w, &r, &s, ng)
		if w.table == C.TABLE_MEAS do reached = true
	}
	testing.expect(t, reached, "Tab never reached the measurement table")
}

// The one-point results (operating point) form the values table, reached by Tab.
@(test)
value_table :: proc(t: ^testing.T) {
	setup()
	ng := C.simulator_def("ngspice")
	s := rc_with_plot(".op")
	r := two_plots()
	rows := C.wave_value_rows(&r)
	testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 {
		testing.expect_value(t, rows[0].name, "v(out)")
		testing.expect_value(t, rows[0].analysis, "Operating Point")
	}
	w: C.Wave_View
	C.wave_init(&w)
	C.wave_new_run(&w, &r, &s, ng)
	reached := false
	for _ in 0 ..< 3 {
		C.wave_next_plot(&w, &r, &s, ng)
		if w.table == C.TABLE_VALUES do reached = true
	}
	testing.expect(t, reached, "Tab never reached the values table")
}

// The integrated noise: a flat spectrum of 1 V/√Hz over 10 Hz … 1 kHz is sqrt(990) V.
@(test)
noise_integrated :: proc(t: ^testing.T) {
	setup()
	p: C.Plot
	p.name = "Noise Spectral Density Curves"
	p.npoints = 3
	append(&p.vecs, C.Vec{name = "frequency", unit = "Hz", re = f64s(10, 100, 1000)})
	append(&p.vecs, C.Vec{name = "onoise_spectrum", unit = "V/√Hz", re = f64s(1, 1, 1)})
	append(&p.vecs, C.Vec{name = "inoise_spectrum", unit = "V/√Hz", re = f64s(1, 1, 1)})
	tot, ok := C.noise_totals(&p)
	testing.expect(t, ok, "no integrated noise for a noise plot")
	if ok {
		testing.expect_value(t, tot.name, "Integrated Noise")
		testing.expect(t, abs(tot.vecs[0].re[0] - math.sqrt(f64(990))) < 1e-9, "the output total is not sqrt(990) V")
		testing.expect(t, abs(tot.vecs[1].re[0] - math.sqrt(f64(990))) < 1e-9, "the input total is not sqrt(990) V")
	}
}
