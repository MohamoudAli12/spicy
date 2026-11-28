package spicy

import "core:fmt"
import "core:strings"

// SPICE netlists (.cir .net .sp …) opened as schematics: every element becomes a part, every
// pin gets a short wire with a net label named after its node (ground for node 0), and the
// dot commands (.model .tran .options .subckt …) go into one SPICE directive. Elements spicy
// has no symbol for stay as netlist lines in that directive; their nodes still connect,
// because the labels carry the original node names.

NETLIST_EXTS := []string{"cir", "net", "sp", "spice", "ckt", "spi"}

is_netlist_ext :: proc(path: string) -> bool {
	e := file_ext_lower(path)
	for x in NETLIST_EXTS do if x == e do return true
	return false
}

// A circuit (element lines outside .subckt blocks), not just a model library.
is_circuit_netlist :: proc(text: string) -> bool {
	lines := spice_lines(text)
	// a file with models or subcircuits and no analysis is a library, even when a vendor's label
	// line ("SDM2U30CSP Spice Model v1.0 …") or a misspelt ".SUBCKET" looks like an element
	defines, analysis := false, false
	for l in lines {
		low := lower(l)
		if strings.has_prefix(low, ".model") || strings.has_prefix(low, ".subckt") do defines = true
		if is_analysis_cmd(directive_cmd(low), {".tran", ".ac", ".dc", ".op", ".noise", ".tf", ".four", ".pz", ".sens", ".disto"}) do analysis = true
	}
	if defines && !analysis do return false
	depth := 0
	for l, i in lines {
		if i == 0 && l[0] == '*' do continue // the title
		low := lower(l)
		if strings.has_prefix(low, ".subckt") do depth += 1
		if strings.has_prefix(low, ".ends") do depth = max(0, depth - 1)
		if depth > 0 || l[0] == '*' || l[0] == '.' || l[0] == '+' do continue
		// an element ("R1 a b 1k"), not a vendor's label line ("Inc. BJTs", "Transistor")
		if element_like(l) do return true
	}
	return false
}

@(private = "file")
Placed :: struct {
	sym:   ^Symbol,
	ref:   string,
	value: string,
	nodes: []string, // one per symbol pin
}

netlist_import :: proc(text: string) -> (s: Schematic, warnings: [dynamic]string, err: string) {
	warnings = make([dynamic]string, context.temp_allocator)
	s.comps = make([dynamic]Comp)
	s.wires = make([dynamic]Wire)
	s.flags = make([dynamic]Flag)
	s.texts = make([dynamic]Text)
	s.embedded = make([dynamic]Embedded_Model)
	s.embedded_sym = make([dynamic]string)
	raw := split_lines(text)
	if len(raw) == 0 do return s, warnings, "the file is empty"
	title := strings.trim_space(raw[0])
	// the file's own models and subcircuits (model types; subcircuit ports for X)
	entries := make([dynamic]Lib_Entry, context.temp_allocator)
	{
		context.allocator = context.temp_allocator
		parse_lib_into(&entries, text, .Directive)
	}
	// the type of the .model card of a name, "subckt" for a subcircuit, "" for neither
	model_type :: proc(name: string, entries: []Lib_Entry) -> string {
		n := lower(name)
		e := lib_find(name)
		for &x in entries do if x.name == n {e = &x; break}
		if e == nil do return ""
		return "subckt" if e.subckt else e.model_type
	}
	directives := make([dynamic]string, context.temp_allocator)
	parts := make([dynamic]Placed, context.temp_allocator)
	lines := spice_lines(strings.join(raw[1:], "\n", context.temp_allocator))
	in_block := "" // ".subckt" or ".control": copied as they are
	for l in lines {
		low := lower(l)
		if len(in_block) > 0 {
			append(&directives, l)
			if (in_block == ".subckt" && strings.has_prefix(low, ".ends")) || (in_block == ".control" && strings.has_prefix(low, ".endc")) do in_block = ""
			continue
		}
		if l[0] == '*' do continue
		if l[0] == '.' {
			if low == ".end" || strings.has_prefix(low, ".end ") do continue
			if strings.has_prefix(low, ".title") {
				title = strings.trim_space(l[6:])
				continue
			}
			if strings.has_prefix(low, ".subckt") do in_block = ".subckt"
			if strings.has_prefix(low, ".control") do in_block = ".control"
			append(&directives, l)
			continue
		}
		// an element: strip a trailing comment ("; …", " $ …")
		t := l
		if c := strings.index_byte(t, ';'); c > 0 do t = strings.trim_space(t[:c])
		if c := strings.index(t, " $ "); c > 0 do t = strings.trim_space(t[:c])
		f := strings.fields(t, context.temp_allocator)
		if len(f) < 3 {
			append(&directives, t)
			continue
		}
		rest :: proc(t: string, skip: int) -> string {
			r := t
			for _ in 0 ..< skip {
				r = strings.trim_left_space(r)
				sp := strings.index_any(r, " \t")
				r = r[sp:] if sp >= 0 else ""
			}
			return strings.trim_space(r)
		}
		p: Placed
		p.ref = f[0]
		nn := 0
		kind := f[0][0] | 0x20
		switch kind {
		case 'r': p.sym, nn = symbol_find("res"), 2
		case 'c': p.sym, nn = symbol_find("cap"), 2
		case 'l': p.sym, nn = symbol_find("ind"), 2
		case 'd': p.sym, nn = symbol_find("diode"), 2
		case 'v': p.sym, nn = symbol_find("voltage"), 2
		case 'i': p.sym, nn = symbol_find("current"), 2
		case 'b':
			nn = 2
			p.sym = symbol_find("bi") if len(f) > 3 && strings.has_prefix(lower(f[3]), "i") else symbol_find("bv")
		case 'e', 'g':
			// linear only (4 nodes and a gain); POLY / VALUE / TABLE stay netlist lines
			if len(f) >= 6 && !strings.contains(lower(f[3]), "value") && !strings.contains(lower(f[3]), "poly") && !strings.contains(lower(f[3]), "table") && !strings.contains(f[3], "=") {
				p.sym, nn = symbol_find("e" if kind == 'e' else "g"), 4
			}
		case 's': p.sym, nn = symbol_find("sw"), 4
		case 'q':
			if len(f) >= 5 {
				// 3 nodes and a model, or 4 (substrate) – the substrate is not drawn
				mi := 4
				if model_type(f[4], entries[:]) == "" && len(f) >= 6 && model_type(f[5], entries[:]) != "" do mi = 5
				if mi == 4 {
					typ := model_type(f[4], entries[:])
					p.sym, nn = symbol_find("pnp" if typ == "PNP" else "npn"), 3
				}
			}
		case 'm':
			// D G S B model: drawn when the bulk is the source (power MOSFETs, discrete parts)
			if len(f) >= 6 && f[4] == f[3] {
				typ := model_type(f[5], entries[:])
				if typ == "VDMOS" do typ = "NMOS"
				p.sym = symbol_find("pmos" if typ == "PMOS" else "nmos")
				nn = 3
				p.value = rest(t, 5)
				p.nodes = make([]string, 3, context.temp_allocator)
				p.nodes[0], p.nodes[1], p.nodes[2] = f[1], f[2], f[3]
				append(&parts, p)
				continue
			}
		case 'x':
			// a subcircuit: its symbol (one with that name, else a box made for it)
			sub := ""
			ni := 0
			for k := len(f) - 1; k >= 1; k -= 1 do if !strings.contains(f[k], "=") && lower(f[k]) != "params:" {
				sub, ni = f[k], k - 1
				break
			}
			e: ^Lib_Entry
			for &x in entries do if x.name == lower(sub) do e = &x
			if e == nil do e = lib_find(sub)
			if e != nil && e.subckt && len(e.ports) == ni {
				sym := symbol_find(sub)
				if sym == nil || len(sym.pins) != ni {
					edn := auto_symbol(e, entry_display_name(e), "netlist")
					append(&s.embedded_sym, strings.clone(edn))
					parse_symbols(tcat("[", edn, "]"), "imported netlist")
					sym = symbol_find(entry_display_name(e))
				}
				if sym != nil && len(sym.pins) == ni {
					p.sym = sym
					p.ref = f[0][1:] if len(f[0]) > 1 && (sym.spice[0] == 'X' || sym.spice[0] == 'x') else f[0]
					p.value = rest(t, ni + 1)
					p.nodes = make([]string, ni, context.temp_allocator)
					// the symbol's pins are the ports in order (a box), or matched by name
					order, perr := subckt_pin_map(e, sym, &Comp{})
					if len(perr) == 0 {
						for k, i in order do p.nodes[k] = f[1 + i]
					} else {
						for i in 0 ..< ni do p.nodes[i] = f[1 + i]
					}
					append(&parts, p)
					continue
				}
			}
		}
		if p.sym == nil || nn == 0 || len(f) < nn + 1 {
			append(&directives, t)
			// K (coupled inductors) has no pins: a directive line is its place, as in LTspice
			if f[0][0] != 'k' && f[0][0] != 'K' do append(&warnings, fmt.tprintf("%s: kept as a netlist line in the directive (no symbol for it)", f[0]))
			continue
		}
		p.value = rest(t, nn + 1)
		p.nodes = make([]string, nn, context.temp_allocator)
		for i in 0 ..< nn do p.nodes[i] = f[1 + i]
		append(&parts, p)
	}
	import_transformers(&parts, &directives)
	// layout: rows of parts in the order of the file, each pin with a stub and a label
	snap :: proc(v: f32) -> i32 {return i32(v / 16 + (0.5 if v >= 0 else -0.5)) * 16}
	x, y: f32 = 0, 0
	row_h: f32 = 0
	max_w: f32 = 1600
	if len(title) > 0 && title[0] == '*' do title = strings.trim_space(strings.trim_left(title, "*"))
	if len(title) > 0 {
		append(&s.texts, Text{pos = {0, -96}, text = strings.clone(title)})
	}
	for p in parts {
		sym := p.sym
		w := sym.hi.x - sym.lo.x
		h := sym.hi.y - sym.lo.y
		// room for the name and value on the right
		cw := max(w + 96 + 9 * f32(max(len(p.value), len(p.ref))), 192)
		ch := max(h + 96, 192)
		if x > 0 && x + cw > max_w {
			x = 0
			y += row_h
			row_h = 0
		}
		pos := P{snap(x + 48 - sym.lo.x), snap(y + 48 - sym.lo.y)}
		c := Comp{sym = strings.clone(sym.name), ref = strings.clone(p.ref), value = strings.clone(p.value), pos = pos, attrs = make([dynamic]Attr)}
		append(&s.comps, c)
		cx, cy := (sym.lo.x + sym.hi.x) / 2, (sym.lo.y + sym.hi.y) / 2
		for pin, k in sym.pins {
			a := P{pos.x + pin.at.x, pos.y + pin.at.y}
			// outwards from the nearest side of the symbol
			px, py := f32(pin.at.x), f32(pin.at.y)
			dl, dr, dt, db := px - sym.lo.x, sym.hi.x - px, py - sym.lo.y, sym.hi.y - py
			d := P{0, 0}
			switch min(dl, dr, dt, db) {
			case dt: d = {0, -32}
			case db: d = {0, 32}
			case dl: d = {-32, 0}
			case: d = {32, 0}
			}
			_ = cx; _ = cy
			b := P{a.x + d.x, a.y + d.y}
			append(&s.wires, Wire{a = a, b = b})
			append(&s.flags, Flag{name = strings.clone(p.nodes[k]), pos = b})
		}
		x += cw
		row_h = max(row_h, ch)
	}
	if len(directives) > 0 {
		append(&s.texts, Text{pos = {0, snap(y + row_h + 48)}, text = strings.clone(strings.join(directives[:], "\n", context.temp_allocator)), directive = true})
	}
	if len(s.comps) == 0 do append(&warnings, "no elements spicy could draw: everything is in the directive")
	return s, warnings, ""
}

// Coupled inductors (two or three L parts and the K lines between them) become a transformer
// symbol: "LT1_p … LT1_s … KT1 LT1_p LT1_s 0.998" → T1 (xfmr, "Lp=… Ls=… k=0.998"). The
// first inductor of the first K line is the primary. Left as they are when an inductor has
// more than a plain value (ic=…), when other lines name the inductors (the transformer's are
// called L<ref>_P …), or when the coupling is not two or three inductors all coupled in pairs.
@(private = "file")
import_transformers :: proc(parts: ^[dynamic]Placed, directives: ^[dynamic]string) {
	K_Line :: struct {
		name: string,
		inds: []string, // lower case
		k:    string,
		line: int, // index in directives
	}
	ks := make([dynamic]K_Line, context.temp_allocator)
	for d, i in directives {
		f := strings.fields(d, context.temp_allocator)
		if len(f) < 4 || (f[0][0] | 0x20) != 'k' do continue
		if _, ok := parse_eng(f[len(f) - 1]); !ok do continue
		inds := make([]string, len(f) - 2, context.temp_allocator)
		for x, j in f[1:len(f) - 1] do inds[j] = lower(x)
		append(&ks, K_Line{f[0], inds, f[len(f) - 1], i})
	}
	part_of :: proc(parts: []Placed, name: string) -> int {
		for p, i in parts do if lower(p.ref) == name do return i
		return -1
	}
	used := make([]bool, len(ks), context.temp_allocator)
	drop_lines := make(map[int]bool, 8, context.temp_allocator)
	drop_parts := make(map[int]bool, 8, context.temp_allocator)
	made := make([dynamic]Placed, context.temp_allocator)
	at := make([dynamic]int, context.temp_allocator) // where each goes (its primary's place)
	for k0, i0 in ks {
		if used[i0] do continue
		// the inductors coupled with these, and every K line among them
		group := make([dynamic]string, context.temp_allocator)
		for x in k0.inds do append(&group, x)
		lines := make([dynamic]int, context.temp_allocator)
		for changed := true; changed; {
			changed = false
			for k, i in ks {
				if used[i] do continue
				touches := false
				for x in k.inds do for g in group do if x == g do touches = true
				if !touches do continue
				used[i] = true
				append(&lines, i)
				changed = true
				for x in k.inds {
					have := false
					for g in group do if g == x do have = true
					if !have do append(&group, x)
				}
			}
		}
		n := len(group)
		if n != 2 && n != 3 do continue
		// k of each pair (0-1, 0-2, 1-2)
		pair_k := [3]string{}
		pair_idx :: proc(a, b: int) -> int {
			lo, hi := min(a, b), max(a, b)
			return 0 if lo == 0 && hi == 1 else (1 if lo == 0 else 2)
		}
		idx_of :: proc(group: []string, x: string) -> int {
			for g, i in group do if g == x do return i
			return -1
		}
		ok := true
		for li in lines {
			k := ks[li]
			for a in 0 ..< len(k.inds) do for b in a + 1 ..< len(k.inds) {
				ia, ib := idx_of(group[:], k.inds[a]), idx_of(group[:], k.inds[b])
				if ia == ib {ok = false; continue}
				pi := pair_idx(ia, ib)
				if len(pair_k[pi]) > 0 do ok = false // coupled twice
				pair_k[pi] = k.k
			}
		}
		npairs := 1 if n == 2 else 3
		for pi in 0 ..< npairs do if len(pair_k[pi]) == 0 do ok = false
		// plain inductors, named nowhere else
		pis := make([]int, n, context.temp_allocator)
		for g, i in group {
			pis[i] = part_of(parts[:], g)
			if pis[i] < 0 || parts[pis[i]].sym == nil || parts[pis[i]].sym.name != "ind" || len(strings.fields(parts[pis[i]].value, context.temp_allocator)) != 1 do ok = false
		}
		if !ok do continue
		for d, di in directives {
			own := false
			for li in lines do if ks[li].line == di do own = true
			if own do continue
			for g in group do if has_word(lower(d), g) do ok = false
		}
		if !ok do continue
		// the name: the shortest K line's without the K ("KT1" → T1), else T<n>
		ref := ""
		for li in lines do if ref == "" || len(ks[li].name) - 1 < len(ref) do ref = ks[li].name[1:]
		taken :: proc(parts: []Placed, made: []Placed, r: string) -> bool {
			for p in parts do if strings.equal_fold(p.ref, r) do return true
			for p in made do if strings.equal_fold(p.ref, r) do return true
			return false
		}
		if len(ref) == 0 || !(((ref[0] | 0x20) >= 'a' && (ref[0] | 0x20) <= 'z')) || taken(parts[:], made[:], ref) {
			for j := 1; ; j += 1 {
				ref = fmt.tprintf("T%d", j)
				if !taken(parts[:], made[:], ref) do break
			}
		}
		t: Placed
		t.ref = ref
		ind := [3]^Placed{}
		for i in 0 ..< n do ind[i] = &parts[pis[i]]
		if n == 2 {
			t.sym = symbol_find("xfmr")
			t.value = fmt.tprintf("Lp=%s Ls=%s k=%s", ind[0].value, ind[1].value, pair_k[0])
		} else {
			t.sym = symbol_find("xfmr3")
			b := strings.builder_make(context.temp_allocator)
			fmt.sbprintf(&b, "Lp=%s Ls=%s Lt=%s k=%s", ind[0].value, ind[1].value, ind[2].value, pair_k[0])
			if pair_k[1] != pair_k[0] do fmt.sbprintf(&b, " kpt=%s", pair_k[1])
			if pair_k[2] != pair_k[0] do fmt.sbprintf(&b, " kst=%s", pair_k[2])
			t.value = strings.to_string(b)
		}
		if t.sym == nil do continue
		t.nodes = make([]string, 2 * n, context.temp_allocator)
		for i in 0 ..< n do t.nodes[2 * i], t.nodes[2 * i + 1] = ind[i].nodes[0], ind[i].nodes[1]
		append(&made, t)
		append(&at, pis[0])
		for i in 0 ..< n do drop_parts[pis[i]] = true
		for li in lines do drop_lines[ks[li].line] = true
	}
	if len(made) == 0 do return
	out := make([dynamic]Placed, context.temp_allocator)
	for p, i in parts {
		for m, j in made do if at[j] == i do append(&out, m)
		if !drop_parts[i] do append(&out, p)
	}
	clear(parts)
	append(parts, ..out[:])
	kept := make([dynamic]string, context.temp_allocator)
	for d, i in directives do if !drop_lines[i] do append(&kept, d)
	clear(directives)
	append(directives, ..kept[:])
}

// w appears in s as a whole name (not part of a longer one: "lt1_p" in "i(lt1_p)", not in "rlt1_p").
@(private = "file")
has_word :: proc(s, w: string) -> bool {
	is_name :: proc(c: u8) -> bool {return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '.'}
	from := 0
	for {
		i := strings.index(s[from:], w)
		if i < 0 do return false
		a, b := from + i, from + i + len(w)
		if (a == 0 || !is_name(s[a - 1])) && (b >= len(s) || !is_name(s[b])) do return true
		from = a + 1
	}
}
