package spicy

import "core:strings"

// Reading SPICE text: lines with their "+" continuations, the names cards define, the words
// of a card. Shared by the library reader, the netlist writers, the model repair and the
// importers, so that they all read a card the same way.

// The lines of a SPICE text with each "+" continuation joined onto the line it continues,
// blank lines dropped. Comment lines ("*") are kept as lines of their own and may stand
// between a line and its continuations, as SPICE reads them.
// comments = false: comment lines are left out, and so is the text after a ";" (an inline
// comment).
spice_lines :: proc(text: string, comments := true) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	last := -1 // the line a "+" line continues
	for raw in split_lines(text) {
		t := strings.trim_space(raw)
		if !comments {
			if i := strings.index_byte(t, ';'); i >= 0 do t = strings.trim_space(t[:i])
			if len(t) > 0 && t[0] == '*' do continue
		}
		if len(t) == 0 do continue
		if t[0] == '+' && last >= 0 {
			out[last] = tcat(out[last], " ", strings.trim_space(t[1:]))
			continue
		}
		if t[0] != '*' do last = len(out)
		append(&out, t)
	}
	return out[:]
}

// The cards of a SPICE text: spice_lines without the comments.
spice_cards :: proc(text: string) -> []string {return spice_lines(text, comments = false)}

// Where the card that starts at lines[k] ends (the index after its last "+" line). Blank and
// comment lines between its "+" lines belong to it; the ones after its last "+" line do not.
// text gives a line's text, trimmed.
card_end :: proc(lines: []$T, k: int, text: proc(l: T) -> string) -> int {
	m := k + 1
	for m < len(lines) {
		t := text(lines[m])
		if len(t) > 0 && t[0] == '+' {
			m += 1
			continue
		}
		if len(t) == 0 || t[0] == '*' {
			j := m
			for j < len(lines) && (len(text(lines[j])) == 0 || text(lines[j])[0] == '*') do j += 1
			if j < len(lines) && len(text(lines[j])) > 0 && text(lines[j])[0] == '+' {
				m = j
				continue
			}
		}
		break
	}
	return m
}

// "(", ")" as spaces and "=" with spaces around it: ".model D D(IS=1n)" → ".model D D  IS = 1n ",
// so that strings.fields gives the name, the type and each parameter's key, "=" and value.
replace_parens :: proc(s: string) -> string {
	r, _ := strings.replace_all(s, "(", " ", context.temp_allocator)
	r, _ = strings.replace_all(r, ")", " ", context.temp_allocator)
	r, _ = strings.replace_all(r, "=", " = ", context.temp_allocator)
	return r
}

// The names (lower case) that .model and .subckt lines define; with vacask, VACASK's "model"
// and "subckt" lines too.
card_names :: proc(lines: []string, vacask := false) -> map[string]bool {
	m := make(map[string]bool, 16, context.temp_allocator)
	for l in lines {
		f := strings.fields(replace_parens(l), context.temp_allocator)
		if len(f) < 2 do continue
		switch lower(f[0]) {
		case ".model", ".subckt": m[lower(f[1])] = true
		case "model", "subckt": if vacask do m[lower(f[1])] = true
		}
	}
	return m
}

// The "k = v" pairs of a card's fields from word `from` on (keys in lower case), and the
// flags: the words that are neither a key nor a value ("savecurrents").
card_params :: proc(f: []string, from: int) -> (keys, vals, flags: [dynamic]string) {
	keys = make([dynamic]string, context.temp_allocator)
	vals = make([dynamic]string, context.temp_allocator)
	flags = make([dynamic]string, context.temp_allocator)
	for i := from; i < len(f); {
		if i + 2 < len(f) && f[i + 1] == "=" {
			append(&keys, lower(f[i]))
			append(&vals, f[i + 2])
			i += 3
			continue
		}
		if f[i] != "=" && !(i + 1 < len(f) && f[i + 1] == "=") do append(&flags, f[i])
		i += 1
	}
	return
}

// ".include file", ".inc file", ".lib file section": the file, relative to base_dir.
include_path :: proc(line, base_dir: string) -> (path: string, ok: bool) {
	t := strings.trim_space(line)
	f := strings.fields(t, context.temp_allocator)
	if len(f) < 2 do return "", false
	cmd := lower(f[0])
	if cmd != ".include" && cmd != ".inc" && cmd != ".lib" do return "", false
	p := strings.trim(strings.trim_space(t[len(f[0]):]), "\"'")
	if cmd == ".lib" && len(f) >= 3 {
		p = strings.trim(f[1], "\"'") // ".lib file section"
	}
	if strings.has_prefix(p, "~/") do p = path_join(home_dir(), p[2:])
	if !is_abs(p) && len(base_dir) > 0 do p = path_join(base_dir, p)
	return p, true
}

// Where the model or subcircuit name stands on an element line, counted in strings.fields of
// replace_parens(line): D a k MODEL, Q c b e [s] MODEL, J d g s MODEL, M d g s b MODEL. 0 for
// the other elements (X lines name their subcircuit last, before any parameters).
element_model_field :: proc(letter: u8) -> int {
	switch letter | 0x20 {
	case 'd': return 3
	case 'q', 'j': return 4
	case 'm': return 5
	}
	return 0
}

// "10k", "4.7u", "1Meg", "2.2nF", "1e-6" – a number with an optional SI prefix and unit letters.
is_number_token :: proc(t: string) -> bool {
	i, ok := scan_number(t)
	if !ok do return false
	// prefix and unit: letters only (µ allowed)
	for ch in t[i:] {
		if !((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == 'µ' || ch == 'μ' || ch == '%' || ch == 'Ω') do return false
	}
	return true
}
