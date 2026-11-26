package spicy_tests

import "core:testing"
import C "../src"

// Units of trace expressions: products, quotients, powers, and numbers that carry a unit.

@(test)
unit_algebra :: proc(t: ^testing.T) {
	testing.expect_value(t, C.unit_mul("V", "A"), "W")
	testing.expect_value(t, C.unit_div("V", "A"), "Ω")
	testing.expect_value(t, C.unit_div("A", "V"), "S")
	testing.expect_value(t, C.unit_mul("A", "s"), "C")
	testing.expect_value(t, C.unit_div("C", "F"), "V")
	testing.expect_value(t, C.unit_div("C", "V"), "F")
	testing.expect_value(t, C.unit_mul("V", "s"), "V·s")
	testing.expect_value(t, C.unit_div("V", "s"), "V/s")
	testing.expect_value(t, C.unit_div("", "s"), "Hz")
	testing.expect_value(t, C.unit_div("", "Hz"), "s")
	testing.expect_value(t, C.unit_mul("V/s", "s"), "V")
	testing.expect_value(t, C.unit_mul("Ω", "A"), "V")
	testing.expect_value(t, C.unit_mul("W", "s"), "J")
	testing.expect_value(t, C.unit_pow("V", 2), "V²")
	testing.expect_value(t, C.unit_pow("V²/Hz", 0.5), "V/√Hz")
	testing.expect_value(t, C.unit_mul("V/√Hz", "V/√Hz"), "V²/Hz")
	testing.expect_value(t, C.unit_div("V", "A·s"), "V/(A·s)")
	// a shared unit, a plain number, or no unit for a mismatch
	testing.expect_value(t, C.unit_sum("V", "V"), "V")
	testing.expect_value(t, C.unit_sum("V", ""), "V")
	testing.expect_value(t, C.unit_sum("", "A"), "A")
	testing.expect_value(t, C.unit_sum("V", "A"), "")
	testing.expect_value(t, C.unit_sum("Ω", "V/A"), "Ω")
	// units outside the algebra: kept with a plain number, written out over a unit
	testing.expect_value(t, C.unit_mul("dB", ""), "dB")
	testing.expect_value(t, C.unit_div("dB", "Hz"), "dB/Hz")
	testing.expect_value(t, C.unit_div("°", "Hz"), "°/Hz")
	testing.expect_value(t, C.unit_mul("dB", "dB"), "")
	testing.expect_value(t, C.unit_sum("dB", "V"), "")
}

// The letters after a number's SPICE scale factor give its unit; SPICE reads the scale first.
@(test)
number_units :: proc(t: ^testing.T) {
	cases := [?]struct {
		s, unit: string,
	} {
		{"1", ""},
		{"1k", ""},
		{"1kohm", "Ω"},
		{"1us", "s"},
		{"1nF", "F"},
		{"1F", ""}, // femto
		{"1V", "V"},
		{"2.5mA", "A"},
		{"1Hz", "Hz"},
		{"1MHz", "Hz"}, // milli hertz, as in SPICE
		{"1megHz", "Hz"},
		{"1e3ohm", "Ω"},
		{"10uH", "H"},
		{"1kx", ""},
	}
	for c in cases do testing.expectf(t, C.number_unit(c.s) == c.unit, "%q: unit %q, want %q", c.s, C.number_unit(c.s), c.unit)
}

// The unit of evaluated expressions over a plot with a voltage, a current and time.
@(test)
expr_units :: proc(t: ^testing.T) {
	setup()
	ng := C.simulator_def("ngspice")
	p := C.Plot{name = "Transient Analysis", npoints = 3}
	append(&p.vecs, C.Vec{name = "time", unit = "s", re = f64s(0, 1, 2)})
	append(&p.vecs, C.Vec{name = "v(out)", unit = "V", re = f64s(1, 2, 3)})
	append(&p.vecs, C.Vec{name = "i(r1)", unit = "A", re = f64s(1, 1, 1)})
	cases := [?]struct {
		e, unit: string,
	} {
		{"V(out)", "V"},
		{"V(out) * 2", "V"},
		{"V(out) * i(r1)", "W"},
		{"V(out) / i(r1)", "Ω"},
		{"i(r1) * 1kohm", "V"},
		{"i(r1) * 1k", "A"},
		{"V(out) / 1kohm", "A"},
		{"d(V(out))", "V/s"},
		{"d(V(out)) * 1us", "V"},
		{"int(i(r1))", "C"},
		{"int(i(r1)) / 1nF", "V"},
		{"V(out)^2", "V²"},
		{"sqrt(V(out)^2)", "V"},
		{"V(out) + 1", "V"},
		{"V(out) + i(r1)", ""},
		{"-V(out)", "V"},
		{"V(out) > 1", ""},
		{"if(V(out) > 1, V(out), 0)", "V"},
		{"max(V(out), 1)", "V"},
		{"1 / 1us", "Hz"},
		{"db(V(out))", "dB"},
		{"ph(V(out))", "°"},
		{"ln(V(out))", ""},
	}
	for c in cases {
		res := C.expr_eval(c.e, &p, nil, ng)
		testing.expectf(t, len(res.err) == 0, "%q: %s", c.e, res.err)
		testing.expectf(t, res.unit == c.unit, "%q: unit %q, want %q", c.e, res.unit, c.unit)
	}
}
