package spicy

import "core:fmt"
import "core:strings"

// Units of trace expressions. A unit is kept as powers of volt, ampere and second, which covers
// every unit of a circuit result: Ω = V/A, S = A/V, F = A·s/V, H = V·s/A, W = V·A, C = A·s,
// J = V·A·s, Hz = 1/s, and noise densities such as V/√Hz = V·s^½. Units outside this algebra
// (dB, °) pass through operations with a plain number, and are dropped otherwise.

Dims :: struct {
	v, a, s: f64,
}

// Named units, in the order they are preferred when a result is written.
@(private = "file")
NAMED := [?]struct {
	name: string,
	d:    Dims,
}{
	{"V", {1, 0, 0}},
	{"A", {0, 1, 0}},
	{"s", {0, 0, 1}},
	{"Hz", {0, 0, -1}},
	{"Ω", {1, -1, 0}},
	{"S", {-1, 1, 0}},
	{"F", {-1, 1, 1}},
	{"H", {1, -1, 1}},
	{"W", {1, 1, 0}},
	{"C", {0, 1, 1}},
	{"J", {1, 1, 1}},
	{"V/s", {1, 0, -1}},
	{"A/s", {0, 1, -1}},
	{"V·s", {1, 0, 1}},
	{"V/√Hz", {1, 0, 0.5}},
	{"A/√Hz", {0, 1, 0.5}},
	{"V²/Hz", {2, 0, 1}},
	{"A²/Hz", {0, 2, 1}},
	{"V²", {2, 0, 0}},
	{"A²", {0, 2, 0}},
}

@(private = "file")
dims_eq :: proc(x, y: Dims) -> bool {
	return abs(x.v - y.v) < 1e-9 && abs(x.a - y.a) < 1e-9 && abs(x.s - y.s) < 1e-9
}

@(private = "file")
dims_add :: proc(x, y: Dims, k: f64 = 1) -> Dims {return {x.v + k * y.v, x.a + k * y.a, x.s + k * y.s}}

// The powers of a unit, or ok = false for a unit outside the algebra (dB, °, …).
// "" is dimensionless.
unit_dims :: proc(u: string) -> (d: Dims, ok: bool) {
	t := strings.trim_space(u)
	if len(t) == 0 do return {}, true
	for n in NAMED do if n.name == t do return n.d, true
	t, _ = strings.remove_all(t, "(", context.temp_allocator)
	t, _ = strings.remove_all(t, ")", context.temp_allocator)
	sign := 1.0
	rest := t
	for len(rest) > 0 {
		// one factor: [√]name[²|³|^n], then · * or / before the next
		end := len(rest)
		sep := ""
		for sp in ([?]string{"·", "*", "/"}) {
			if i := strings.index(rest, sp); i >= 0 && i < end {
				end = i
				sep = sp
			}
		}
		f := strings.trim_space(rest[:end])
		if len(f) > 0 && f != "1" {
			fd, fok := unit_factor(f)
			if !fok do return {}, false
			d = dims_add(d, fd, sign)
		}
		if len(sep) == 0 do break
		if sep == "/" do sign = -1
		rest = rest[end + len(sep):]
	}
	return d, true
}

@(private = "file")
unit_factor :: proc(f: string) -> (d: Dims, ok: bool) {
	e := 1.0
	t := f
	if strings.has_prefix(t, "√") {
		e = 0.5
		t = t[len("√"):]
	}
	switch {
	case strings.has_suffix(t, "²"):
		e *= 2
		t = t[:len(t) - len("²")]
	case strings.has_suffix(t, "³"):
		e *= 3
		t = t[:len(t) - len("³")]
	case strings.contains(t, "^"):
		i := strings.index_byte(t, '^')
		x, xok := parse_eng(t[i + 1:])
		if !xok do return {}, false
		e *= x
		t = t[:i]
	}
	base: Dims
	switch t {
	case "V": base = {1, 0, 0}
	case "A": base = {0, 1, 0}
	case "s": base = {0, 0, 1}
	case "Hz": base = {0, 0, -1}
	case "Ω", "ohm": base = {1, -1, 0}
	case "S": base = {-1, 1, 0}
	case "F": base = {-1, 1, 1}
	case "H": base = {1, -1, 1}
	case "W": base = {1, 1, 0}
	case "C": base = {0, 1, 1}
	case "J": base = {1, 1, 1}
	case: return {}, false
	}
	return {base.v * e, base.a * e, base.s * e}, true
}

// The unit of a set of powers: a named unit when there is one, else built from V, A and s.
unit_name :: proc(d: Dims) -> string {
	if dims_eq(d, {}) do return ""
	for n in NAMED do if dims_eq(n.d, d) do return n.name
	num := make([dynamic]string, context.temp_allocator)
	den := make([dynamic]string, context.temp_allocator)
	for x in ([?]struct {
			n: string,
			e: f64,
		}{{"V", d.v}, {"A", d.a}, {"s", d.s}}) {
		if abs(x.e) < 1e-9 do continue
		part := unit_power(x.n, abs(x.e))
		if x.e > 0 do append(&num, part)
		else do append(&den, part)
	}
	top := strings.join(num[:], "·", context.temp_allocator) if len(num) > 0 else "1"
	if len(den) == 0 do return top
	bottom := strings.join(den[:], "·", context.temp_allocator)
	if len(den) > 1 do bottom = tcat("(", bottom, ")")
	return tcat(top, "/", bottom)
}

@(private = "file")
unit_power :: proc(n: string, e: f64) -> string {
	switch {
	case abs(e - 1) < 1e-9: return n
	case abs(e - 2) < 1e-9: return tcat(n, "²")
	case abs(e - 3) < 1e-9: return tcat(n, "³")
	case abs(e - 0.5) < 1e-9: return tcat("√", n)
	}
	return fmt.tprintf("%s^%g", n, e)
}

// The unit of a product. A unit outside the algebra times one inside it is written out
// (dB·Hz); two outside it give no unit.
unit_mul :: proc(x, y: string) -> string {
	if len(x) == 0 do return y
	if len(y) == 0 do return x
	dx, okx := unit_dims(x)
	dy, oky := unit_dims(y)
	if okx && oky do return unit_name(dims_add(dx, dy))
	if okx != oky do return tcat(x, "·", y)
	return ""
}

// The unit of a quotient. A unit outside the algebra over one inside it is written out, as the
// slope of a Bode plot in dB/Hz; otherwise a unit outside the algebra gives no unit.
unit_div :: proc(x, y: string) -> string {
	if len(y) == 0 do return x
	dx, okx := unit_dims(x)
	dy, oky := unit_dims(y)
	if okx && oky do return unit_name(dims_add(dx, dy, -1))
	if !okx && oky do return tcat(x, "/", y)
	return ""
}

// The unit of a sum, a difference, min, max or if: the shared unit. A plain number takes the
// unit of the other side (V(out) + 1 is in V). Different units give no unit.
unit_sum :: proc(x, y: string) -> string {
	if x == y || len(y) == 0 do return x
	if len(x) == 0 do return y
	dx, okx := unit_dims(x)
	dy, oky := unit_dims(y)
	if okx && oky && dims_eq(dx, dy) do return unit_name(dx)
	return ""
}

// The unit of a power with a plain-number exponent.
unit_pow :: proc(x: string, e: f64) -> string {
	if len(x) == 0 || e == 1 do return x
	d, ok := unit_dims(x)
	if !ok do return ""
	return unit_name({d.v * e, d.a * e, d.s * e})
}

// The unit written after a number, as SPICE allows (1kohm, 1us, 1nF): the letters after the
// scale factor. SPICE reads the scale first, so 1F is one femto with no unit, 1MHz is one milli
// hertz and 1A is one ampere. Letters that name no unit give a plain number, as in SPICE.
number_unit :: proc(text: string) -> string {
	i := 0
	for i < len(text) && ((text[i] >= '0' && text[i] <= '9') || text[i] == '.' || text[i] == '+' || text[i] == '-') do i += 1
	if i < len(text) && (text[i] == 'e' || text[i] == 'E') {
		j := i + 1
		if j < len(text) && (text[j] == '+' || text[j] == '-') do j += 1
		if j < len(text) && text[j] >= '0' && text[j] <= '9' {
			for j < len(text) && text[j] >= '0' && text[j] <= '9' do j += 1
			i = j
		}
	}
	rest := text[i:]
	if len(rest) == 0 do return ""
	low := lower(rest)
	switch {
	case strings.has_prefix(low, "meg"): rest = rest[3:]
	case strings.has_prefix(low, "mil"): return ""
	case strings.contains("tgkmunpf", low[:1]): rest = rest[1:]
	}
	switch lower(rest) {
	case "v": return "V"
	case "a": return "A"
	case "s", "sec": return "s"
	case "hz": return "Hz"
	case "ohm", "ohms": return "Ω"
	case "f": return "F"
	case "h": return "H"
	case "w": return "W"
	case "c": return "C"
	case "j": return "J"
	}
	return ""
}
