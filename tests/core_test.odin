package spicy_tests

import "core:math"
import os "core:os"
import "core:strings"
import "core:testing"
import C "../src"

// Settings, symbols and models from a throw-away config folder (never the user's).
setup :: proc() {
	if len(os.get_env("SPICY_CONFIG_DIR", context.temp_allocator)) == 0 {
		os.set_env("SPICY_CONFIG_DIR", "build/testcfg")
	}
	// every test has its own allocator: start the globals afresh (never reuse a freed array)
	C.symbols = {}
	C.model_lib = {}
	C.config_errors = {}
	C.watched = {}
	C.S = {}
	C.settings_load()
	C.symbols_load()
	C.models_load()
}

near :: proc(a, b, rel: f64) -> bool {
	return abs(a - b) <= rel * max(abs(a), abs(b), 1e-15)
}

@(test)
numbers :: proc(t: ^testing.T) {
	cases := [?]struct {
		s: string,
		v: f64,
	}{{"4.7u", 4.7e-6}, {"1k", 1e3}, {"1meg", 1e6}, {"1Meg", 1e6}, {"2M", 2e-3}, {"10m", 10e-3}, {"33n", 33e-9}, {"1e-3", 1e-3}, {"100p", 100e-12}, {"2.2uF", 2.2e-6}}
	for c in cases {
		v, ok := C.parse_eng(c.s)
		testing.expectf(t, ok && near(v, c.v, 1e-12), "parse_eng(%q) = %v %v, want %v", c.s, v, ok, c.v)
	}
	testing.expect_value(t, C.fmt_eng(4.7e-6, "H"), "4.7 µH")
	testing.expect_value(t, C.fmt_eng(-1500, "dB"), "-1500 dB") // no prefix on dB
	testing.expect_value(t, C.fmt_eng(0.5, "V"), "500 mV")
}

@(test)
edn_round_trip :: proc(t: ^testing.T) {
	setup()
	text, _ := C.read_text("examples/rc_lowpass.edn")
	s, err := C.sch_from_edn(text)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(s.comps), 4)
	testing.expect_value(t, len(s.wires), 8)
	out := C.sch_to_edn(&s)
	s2, err2 := C.sch_from_edn(out)
	testing.expect_value(t, err2, "")
	testing.expect_value(t, C.sch_to_edn(&s2), out)
	testing.expect_value(t, s2.comps[0].value, "PULSE(0 1 0 1n 1n 5u 10u) AC 1")
}

// A resistor at (0,0): pins at (16,16) and (16,96).
one_resistor :: proc() -> C.Schematic {
	s: C.Schematic
	append(&s.comps, C.Comp{sym = "res", ref = "R1", value = "1k"})
	return s
}

@(test)
wire_through_part :: proc(t: ^testing.T) {
	setup()
	s := one_resistor()
	// a wire drawn straight through the resistor connects only at its pins
	C.add_wire(&s, {16, -32}, {16, 160}, true)
	testing.expect_value(t, len(s.wires), 2)
	ni := C.nets_build(&s)
	testing.expect(t, ni.pin_net[0][0] != ni.pin_net[0][1], "the resistor must not be shorted")
	// without cut-through it is one wire touching both pins: shorted
	s2 := one_resistor()
	C.add_wire(&s2, {16, -32}, {16, 160}, false)
	ni2 := C.nets_build(&s2)
	testing.expect_value(t, ni2.pin_net[0][0], ni2.pin_net[0][1])
}

@(test)
wire_connectivity :: proc(t: ^testing.T) {
	setup()
	s: C.Schematic
	// a cross: no connection
	append(&s.wires, C.Wire{a = {0, 0}, b = {64, 0}}, C.Wire{a = {32, -32}, b = {32, 32}})
	ni := C.nets_build(&s)
	testing.expect(t, ni.wire_net[0] != ni.wire_net[1], "crossing wires must not connect")
	testing.expect_value(t, len(ni.junctions), 0)
	// a T: connected, with a junction dot
	s2: C.Schematic
	append(&s2.wires, C.Wire{a = {0, 0}, b = {64, 0}}, C.Wire{a = {32, 0}, b = {32, 32}})
	ni2 := C.nets_build(&s2)
	testing.expect_value(t, ni2.wire_net[0], ni2.wire_net[1])
	testing.expect_value(t, len(ni2.junctions), 1)
	// labels with the same name join nets
	s3: C.Schematic
	append(&s3.wires, C.Wire{a = {0, 0}, b = {32, 0}}, C.Wire{a = {100, 0}, b = {132, 0}})
	append(&s3.flags, C.Flag{name = "x", pos = {0, 0}}, C.Flag{name = "x", pos = {132, 0}})
	ni3 := C.nets_build(&s3)
	testing.expect_value(t, ni3.wire_net[0], ni3.wire_net[1])
	testing.expect_value(t, ni3.names[ni3.wire_net[0]], "x")
}

@(test)
merge_collinear :: proc(t: ^testing.T) {
	setup()
	s: C.Schematic
	C.add_wire(&s, {0, 0}, {32, 0}, true)
	C.add_wire(&s, {32, 0}, {64, 0}, true)
	C.wires_cleanup(&s)
	testing.expect_value(t, len(s.wires), 1)
}

@(test)
netlists :: proc(t: ^testing.T) {
	setup()
	text, _ := C.read_text("examples/rc_lowpass.edn")
	s, _ := C.sch_from_edn(text)
	ng := C.simulator_def("ngspice")
	testing.expect(t, ng != nil)
	nl := C.netlist_build(&s, ng, "rc")
	testing.expect_value(t, len(nl.errors), 0)
	testing.expect(t, strings.contains(nl.text, "R1 out N001 1k"), nl.text)
	testing.expect(t, strings.contains(nl.text, ".model 1N4148 D"), nl.text)
	testing.expect(t, strings.contains(nl.text, ".tran 20n 20u"), nl.text) // one-argument .tran gets a step
	vc := C.simulator_def("vacask")
	testing.expect(t, vc != nil)
	nv := C.netlist_build(&s, vc, "rc")
	testing.expect_value(t, len(nv.errors), 0)
	testing.expect(t, strings.contains(nv.text, "load \"spice/diode.osdi\""), nv.text)
	testing.expect(t, strings.contains(nv.text, "m_1n4148"), nv.text) // never read as 1n
	testing.expect(t, strings.contains(nv.text, "analysis tran1 tran"), nv.text)
	// the voltage-controlled switch: an S line and an SW model; for VACASK the embedded Verilog-A
	st, _ := C.read_text("examples/switch.edn")
	sw, _ := C.sch_from_edn(st)
	ns := C.netlist_build(&sw, ng, "sw")
	testing.expect_value(t, len(ns.errors), 0)
	testing.expect(t, strings.contains(ns.text, "S1 out 0 ctl 0 SW"), ns.text)
	testing.expect(t, strings.contains(ns.text, ".model SW SW("), ns.text)
	nsv := C.netlist_build(&sw, vc, "sw")
	testing.expect_value(t, len(nsv.errors), 0)
	testing.expect(t, strings.contains(nsv.text, "load \"spicy_vsw.va\""), nsv.text)
	testing.expect(t, strings.contains(nsv.text, "model sw spicy_vsw ron=1 roff=1000000 vt=0.5 vh=0"), nsv.text)
	testing.expect(t, strings.contains(nsv.text, "embed \"spicy_vsw.va\" <<<FILE"), nsv.text)
	testing.expect(t, strings.contains(nsv.text, "s1 (s1_p s1_n s1_cp s1_cn) sw"), nsv.text)
	// no ground: an error
	s2 := one_resistor()
	nl2 := C.netlist_build(&s2, ng, "x")
	testing.expect(t, len(nl2.errors) > 0)
}

RAW_ASCII :: `Title: test
Date: today
Plotname: Transient Analysis
Flags: real
No. Variables: 3
No. Points: 3
Variables:
	0	time	time
	1	v(out)	voltage
	2	i(v1)	current
Values:
 0	0
	1
	-0.001
 1	1e-3
	2
	-0.002
 2	2e-3
	3
	-0.003
`

@(test)
raw_and_expressions :: proc(t: ^testing.T) {
	setup()
	plots, err := C.raw_parse(transmute([]u8)string(RAW_ASCII), "test.raw")
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(plots), 1)
	p := &plots[0]
	testing.expect_value(t, p.npoints, 3)
	testing.expect_value(t, C.plot_kind(p), "tran")
	ng := C.simulator_def("ngspice")
	r := C.expr_eval("V(out)*2+1", p, nil, ng)
	testing.expect_value(t, r.err, "")
	testing.expect(t, near(r.re[2], 7, 1e-12))
	r2 := C.expr_eval("V(out)*I(V1)", p, nil, ng)
	testing.expect_value(t, r2.err, "")
	testing.expect_value(t, r2.unit, "W")
	testing.expect(t, near(r2.re[1], -0.004, 1e-12))
	r3 := C.expr_eval("V(nope)", p, nil, ng)
	testing.expect(t, len(r3.err) > 0)
	_ = math.PI
}

ASC :: `Version 4
SHEET 1 880 680
WIRE 128 96 32 96
WIRE 32 160 32 96
FLAG 32 240 0
FLAG 128 96 out
SYMBOL voltage 32 144 R0
SYMATTR InstName V1
SYMATTR Value 5
SYMBOL res 112 80 R0
SYMATTR InstName R1
SYMATTR Value 10k
TEXT 0 300 Left 2 !.op
`

@(test)
ltspice_import :: proc(t: ^testing.T) {
	setup()
	s, warnings, err := C.asc_import(transmute([]u8)string(ASC))
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(warnings), 0)
	testing.expect_value(t, len(s.comps), 2)
	testing.expect_value(t, len(s.wires), 2)
	testing.expect_value(t, len(s.flags), 2)
	testing.expect_value(t, s.comps[1].value, "10k")
	testing.expect_value(t, len(s.texts), 1)
	testing.expect(t, s.texts[0].directive)
}

// LTspice orientations: Rn turns clockwise; Mn turns and then mirrors x. pnp and pmos have
// LTspice's npn / nmos pinout (collector / drain at the top). Pins land where LTspice has them,
// and the orientation survives saving.
ASC_ORIENT :: `Version 4
SHEET 1 880 680
SYMBOL res 0 0 M90
SYMBOL pnp 0 0 R0
SYMBOL pmos 256 224 M270
SYMBOL npn 0 0 M270
`

@(test)
ltspice_import_orientation :: proc(t: ^testing.T) {
	setup()
	s, _, err := C.asc_import(transmute([]u8)string(ASC_ORIENT))
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(s.comps), 4)
	pin :: proc(c: ^C.Comp, name: string) -> C.P {
		sym := C.symbol_find(c.sym)
		for p, i in sym.pins do if p.name == name do return C.comp_pin(c, sym, i)
		return {-1, -1}
	}
	check :: proc(t: ^testing.T, s: ^C.Schematic, k: int, name: string, want: C.P) {
		got := pin(&s.comps[k], name)
		testing.expectf(t, got == want, "%s pin %s: %v, want %v", s.comps[k].sym, name, got, want)
	}
	check(t, &s, 0, "A", {16, 16})
	check(t, &s, 0, "B", {96, 16})
	check(t, &s, 1, "C", {64, 0})
	check(t, &s, 1, "B", {0, 48})
	check(t, &s, 1, "E", {64, 96})
	check(t, &s, 2, "D", {256, 176})
	check(t, &s, 2, "G", {176, 224})
	check(t, &s, 2, "S", {160, 176})
	check(t, &s, 3, "C", {0, -64}) // npn M270: (x, y) → (-y, -x)
	check(t, &s, 3, "B", {-48, 0})
	check(t, &s, 3, "E", {-96, -64})
	back, berr := C.sch_from_edn(C.sch_to_edn(&s))
	testing.expect_value(t, berr, "")
	for c, i in s.comps {
		testing.expectf(t, back.comps[i].rot == c.rot && back.comps[i].mirror == c.mirror && back.comps[i].pos == c.pos,
			"%s orientation changes when saved: rot %d → %d", c.sym, c.rot, back.comps[i].rot)
	}
}

// Every built-in symbol written out by the symbol editor reads back the same.
@(test)
symbol_edn_round_trip :: proc(t: ^testing.T) {
	setup()
	for &s in C.symbols {
		text := C.symbol_to_edn(&s)
		m, err := C.edn_parse(text, context.temp_allocator)
		testing.expectf(t, len(err) == 0, "%s: %s", s.name, err)
		s2, ok := C.symbol_from_edn(m, "test", s.name)
		testing.expectf(t, ok, "%s does not read back", s.name)
		testing.expectf(t, C.symbol_to_edn(&s2) == text, "%s changes when written again:\n%s\n%s", s.name, text, C.symbol_to_edn(&s2))
		testing.expectf(t, len(s2.pins) == len(s.pins) && len(s2.gfx) == len(s.gfx), "%s: pins or graphics lost", s.name)
	}
}

// FFT of unevenly spaced transient points (ported from zapped): a sine reads its amplitude
// in both windows; a ±1 square wave has odd harmonics 4/(πk) and no even ones.
@(test)
fft_spectrum_exact :: proc(t: ^testing.T) {
	f0: f64 = 100e3
	n := 3001
	ts := make([]f64, n)
	ys := make([]f64, n)
	sq := make([]f64, n)
	defer {delete(ts); delete(ys); delete(sq)}
	T := 10 / f0
	for i in 0 ..< n {
		// uneven spacing, as a simulator's time steps
		x := f64(i) / f64(n - 1)
		ts[i] = T * (x + 0.002 * math.sin(37 * x))
	}
	for i in 0 ..< n {
		ys[i] = 0.5 + 2 * math.sin(2 * math.PI * 3 * f0 * ts[i])
		ph := math.mod(ts[i] * f0, 1)
		sq[i] = 1 if ph < 0.5 else -1
	}
	for name, win in C.FFT_WINDOWS {
		sp, ok := C.spectrum_of(ts, ys, 0, T, win)
		testing.expect(t, ok, "spectrum")
		k := int(math.round(3 * f0 / sp.df))
		testing.expectf(t, abs(sp.amp[k] - 2) < 0.01, "%s: amplitude %v (want 2)", name, sp.amp[k])
		testing.expectf(t, abs(sp.amp[0] - 0.5) < 0.01, "%s: DC %v (want 0.5)", name, sp.amp[0])
		C.spectrum_free(&sp)
	}
	sp, ok := C.spectrum_of(ts, sq, 0, T, C.fft_window_index("rectangular"))
	testing.expect(t, ok, "square")
	defer C.spectrum_free(&sp)
	for h in 1 ..= 7 {
		a := sp.amp[int(math.round(f64(h) * f0 / sp.df))]
		want := 4 / (math.PI * f64(h)) if h % 2 == 1 else 0
		testing.expectf(t, abs(a - want) < 0.01, "harmonic %d: %v (want %v)", h, a, want)
	}
}

// A spectrum pane is saved with the schematic and read back with its settings.
@(test)
fft_pane_setup_round_trip :: proc(t: ^testing.T) {
	setup()
	w: C.Wave_View
	C.wave_init(&w)
	defer C.wave_free(&w)
	C.wave_add_trace(&w, "V(out)", false)
	C.wave_add_fft(&w, "V(in)")
	testing.expect(t, w.panes[1].fft.window == C.S.w_fft_window && w.panes[1].fft.db == C.S.w_fft_db, "new pane ignores settings.edn")
	w.panes[1].fft.window = C.fft_window_index("flat-top")
	w.panes[1].fft.t0, w.panes[1].fft.t1 = 1e-6, 2e-6
	C.wave_add_trace(&w, "V(a)", false) // a probe never lands in the spectrum pane
	testing.expect(t, len(w.panes[1].traces) == 1, "probe went into the spectrum pane")
	text := C.wave_save_setup(&w)
	w2: C.Wave_View
	C.wave_init(&w2)
	defer C.wave_free(&w2)
	C.wave_load_setup(&w2, text)
	testing.expectf(t, len(w2.panes) == 2 && w2.panes[1].fft != nil, "spectrum pane lost: %s", text)
	if len(w2.panes) == 2 && w2.panes[1].fft != nil {
		f := w2.panes[1].fft
		testing.expect(t, f.window == C.fft_window_index("flat-top") && f.db && f.ax.log_x && f.t0 == 1e-6 && f.t1 == 2e-6, "spectrum settings lost")
	}
	testing.expectf(t, C.wave_save_setup(&w2) == text, "setup changes when saved again:\n%s\n%s", text, C.wave_save_setup(&w2))
}

// Loading the library again (after a model import) frees the old entries and reads the same
// ones: a vendor-style subcircuit keeps its pin names, a .model card its type.
@(test)
library_reload :: proc(t: ^testing.T) {
	setup()
	lib := `* PIN_ORDER C A
.SUBCKT ZD 1 2
D1 2 1 DZ
.MODEL DZ D(BV=5.1)
.ENDS
.MODEL QX NPN(BF=100)
`
	for _ in 0 ..< 3 {
		C.models_load()
		C.parse_lib(lib, .Library, "test.lib")
		zd := C.lib_find("zd")
		testing.expect(t, zd != nil && zd.subckt && zd.origin == .Library && zd.file == "test.lib")
		if zd != nil do testing.expectf(t, len(zd.pins) == 2 && zd.pins[0] == "K" && zd.pins[1] == "A", "ZD pins %v", zd.pins)
		qx := C.lib_find("qx")
		testing.expect(t, qx != nil && !qx.subckt && qx.model_type == "NPN")
		d := C.lib_find("1n4148")
		testing.expect(t, d != nil && d.origin == .Builtin)
	}
}

// Every item of the menu bar's menus does something: an action spicy has, its own proc, or a
// submenu. A line is all a "-" item is.
@(test)
menus_do_something :: proc(t: ^testing.T) {
	setup()
	C.shortcuts_load()
	C.app.docs = {}
	append(&C.app.docs, C.doc_new())
	C.app.cur = 0
	known := make(map[string]bool, context.temp_allocator)
	for a in C.actions do known[a.name] = true // ACTION_INFO's and a place/<symbol> for each symbol
	for m in C.MENUS {
		entries := C.menu_entries(m)
		testing.expectf(t, len(entries) > 0, "menu %s is empty", m)
		for e in entries {
			n := int(len(e.action) > 0) + int(e.pick != nil) + int(e.sub != nil)
			if e.item == "-" {
				testing.expectf(t, n == 0, "%s: a line that does something", m)
				continue
			}
			testing.expectf(t, n == 1, "%s › %q does %d things", m, e.item, n)
			if len(e.action) > 0 do testing.expectf(t, known[e.action], "%s › %q runs %q, not an action", m, e.item, e.action)
		}
	}
}
