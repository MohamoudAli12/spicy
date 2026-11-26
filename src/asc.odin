package spicy

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:unicode/utf16"

// LTspice .asc import. Parts of LTspice's standard library map to spicy symbols with the
// same pin positions; other symbols are reported and left out.

ASC_SYMBOLS := [?][2]string {
	{"res", "res"}, {"res2", "res"}, {"cap", "cap"}, {"polcap", "polcap"}, {"ind", "ind"}, {"ind2", "ind"},
	{"diode", "diode"}, {"zener", "zener"}, {"schottky", "schottky"}, {"led", "led"},
	{"voltage", "voltage"}, {"current", "current"}, {"bv", "bv"}, {"bi", "bi"}, {"bi2", "bi"},
	{"e", "e"}, {"e2", "e"}, {"g", "g"}, {"g2", "g"},
	{"npn", "npn"}, {"npn2", "npn"}, {"pnp", "pnp"}, {"pnp2", "pnp"},
	{"nmos", "nmos"}, {"pmos", "pmos"}, {"opamp", "opamp"}, {"sw", "sw"},
}

// LTspice draws pnp and pmos with the same pinout as npn and nmos (collector / drain at the
// top); spicy's have the emitter / source at the top. Upside down they match pin for pin, so
// these are placed flipped vertically about the middle of the part (y = ASC_FLIP_H / 2).
ASC_FLIPPED := [?]string{"pnp", "pmos"}
ASC_FLIP_H :: 96

// LTspice writes UTF-16 LE (with or without BOM) or plain 8-bit text.
decode_text :: proc(data: []u8) -> string {
	if len(data) >= 2 && ((data[0] == 0xFF && data[1] == 0xFE) || (len(data) > 3 && data[1] == 0 && data[3] == 0)) {
		start := 2 if data[0] == 0xFF else 0
		n := (len(data) - start) / 2
		u := make([]u16, n, context.temp_allocator)
		for i in 0 ..< n do u[i] = u16(data[start + 2 * i]) | u16(data[start + 2 * i + 1]) << 8
		buf := make([]u8, n * 4, context.temp_allocator)
		k := utf16.decode_to_utf8(buf, u)
		return string(buf[:k])
	}
	// latin-1 (µ, Ω) → UTF-8
	b := strings.builder_make(context.temp_allocator)
	for c in data {
		if c < 0x80 do strings.write_byte(&b, c)
		else do strings.write_rune(&b, rune(c))
	}
	return strings.to_string(b)
}

asc_import :: proc(data: []u8) -> (s: Schematic, warnings: [dynamic]string, err: string) {
	text := decode_text(data)
	warnings = make([dynamic]string, context.temp_allocator)
	if !strings.has_prefix(strings.trim_space(text), "Version") do return {}, warnings, "not an LTspice schematic (no \"Version\" line)"
	s.comps = make([dynamic]Comp)
	s.wires = make([dynamic]Wire)
	s.flags = make([dynamic]Flag)
	s.texts = make([dynamic]Text)
	cur := -1 // index of the part that SYMATTR lines belong to
	skipped := make(map[string]int, 8, context.temp_allocator)
	num :: proc(s: string) -> i32 {
		v, _ := strconv.parse_int(s)
		return i32(v)
	}
	for raw_line in split_lines(text) {
		line := strings.trim_right_space(raw_line)
		f := strings.fields(line, context.temp_allocator)
		if len(f) == 0 do continue
		switch f[0] {
		case "WIRE":
			if len(f) >= 5 do append(&s.wires, Wire{a = {num(f[1]), num(f[2])}, b = {num(f[3]), num(f[4])}})
			cur = -1
		case "FLAG":
			if len(f) >= 4 {
				name := f[3]
				if name == "0" || lower(name) == "gnd" do name = "0"
				append(&s.flags, Flag{name = strings.clone(name), pos = {num(f[1]), num(f[2])}})
			}
			cur = -1
		case "SYMBOL":
			cur = -1
			if len(f) < 5 do continue
			lt := lower(f[1])
			if i := strings.last_index_any(lt, "\\/"); i >= 0 do lt = lt[i + 1:]
			mapped := ""
			for m in ASC_SYMBOLS do if m[0] == lt do mapped = m[1]
			if len(mapped) == 0 || symbol_find(mapped) == nil {
				skipped[f[1]] += 1
				continue
			}
			o := f[4]
			mirror := len(o) > 0 && o[0] == 'M'
			deg, _ := strconv.parse_int(o[1:])
			// LTspice's Mn rotates by n and then mirrors; spicy mirrors and then rotates, so a
			// mirrored part turns the other way (M90 = mirror + 270, M270 = mirror + 90).
			q := u8((deg / 90) % 4)
			if mirror do q = (4 - q) % 4
			pos := P{num(f[2]), num(f[3])}
			for fl in ASC_FLIPPED do if fl == lt {
				// flipping y is mirror + half turn; then LTspice's own orientation on top
				pos = xform_p(pos, q, mirror, {0, ASC_FLIP_H})
				q, mirror = (q + 2) % 4, !mirror
			}
			append(&s.comps, Comp{sym = strings.clone(mapped), pos = pos, rot = q, mirror = mirror, attrs = make([dynamic]Attr)})
			cur = len(s.comps) - 1
		case "SYMATTR":
			if cur < 0 || len(f) < 2 do continue
			c := &s.comps[cur]
			// the value is the rest of the line after the attribute name
			rest := strings.trim_space(line[strings.index(line, f[1]) + len(f[1]):])
			switch f[1] {
			case "InstName": set_str(&c.ref, rest)
			case "Value": set_str(&c.value, rest)
			case "Value2", "SpiceLine", "SpiceLine2":
				if len(rest) > 0 do set_str(&c.value, tcat(c.value, " ", rest) if len(c.value) > 0 else rest)
			}
		case "TEXT":
			cur = -1
			// TEXT x y align size !directive / ;comment
			if len(f) < 6 do continue
			idx := 0
			for _ in 0 ..< 5 {
				idx = strings.index_byte(line[idx:], ' ') + idx
				for idx < len(line) && line[idx] == ' ' do idx += 1
			}
			body := line[idx:]
			if len(body) == 0 do continue
			directive := body[0] == '!'
			if body[0] == '!' || body[0] == ';' do body = body[1:]
			body, _ = strings.replace_all(body, "\\n", "\n", context.temp_allocator)
			append(&s.texts, Text{pos = {num(f[1]), num(f[2])}, text = strings.clone(body), directive = directive})
		case "IOPIN", "WINDOW", "SHEET", "Version", "DATAFLAG", "LINE", "RECTANGLE", "CIRCLE", "ARC", "BUSTAP":
		}
	}
	for &c in s.comps {
		sym := symbol_find(c.sym)
		if len(c.ref) == 0 do c.ref = strings.clone(next_ref(&s, sym.prefix))
		if len(c.value) == 0 do c.value = strings.clone(sym.value)
	}
	for k, n in skipped do append(&warnings, fmt.tprintf("left out %d × symbol \"%s\" (not in spicy's library)", n, k))
	wires_cleanup(&s)
	return s, warnings, ""
}
