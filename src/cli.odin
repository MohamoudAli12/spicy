package spicy

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// Command-line editing and queries, for scripts and AI agents: every command reads a
// schematic, prints EDN (or JSON with --json), and edits the file in place (or writes -o).
//   --check --get --set --add --remove --connect --do --list

CLI_HELP :: `editing and queries (output EDN; --json for JSON, --text for text; -o out.edn writes
a copy instead of changing the file):
  spicy --new <file.edn> [--sim ID] [--force]  an empty schematic
  spicy --check <file>                     problems that stop a run (exit 1 when there are errors)
  spicy --get <file> [REF]                 parts, pins and their nets, wires, labels, directives
  spicy --set <file> REF.FIELD=VALUE …     FIELD: value ref at=x,y rot=0..3 mirror=true|false, or a
                                           template attribute; simulator=<id> for the schematic
  spicy --add <file> <symbol> [REF] [--value V] [--at x,y] [--rot N] [--mirror]
  spicy --add <file> ground|label [NAME] (--at x,y | --to REF.PIN)
  spicy --add <file> directive|comment "<text>" [--at x,y]
  spicy --add <file> wire x1,y1 x2,y2
  spicy --remove <file> REF|wire:N|label:N|directive:N|comment:N …
  spicy --connect <file> REF.PIN REF.PIN … [--net NAME]
                                           a wire when the pins line up with nothing between,
                                           else a net label on each pin
  spicy --do <file> <action> [REF …]       a menu action without the GUI: edit/rotate edit/mirror
                                           edit/delete view/netlist sim/run file/export-netlist <out>
  spicy --list symbols|actions|simulators
pins: REF.NAME or REF.N (1 = the first pin); coordinates in schematic units (grid 16)
exit codes: 0 ok, 1 problems found / run failed, 2 usage, 3 file error, 4 simulator missing
`

// Value flags take the next argument.
@(private = "file")
VALUE_FLAGS :: [?]string{"--at", "--rot", "--value", "--net", "--to", "-o", "--sim", "--csv", "--trace"}

@(private = "file")
flag_value :: proc(args: []string, name: string) -> (string, bool) {
	for a, i in args do if a == name {
		if i + 1 >= len(args) do cli_usage(tcat(name, " needs a value"))
		return args[i + 1], true
	}
	return "", false
}

// Every value of a flag that may repeat.
@(private = "file")
flag_values :: proc(args: []string, name: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for a, i in args do if a == name {
		if i + 1 >= len(args) do cli_usage(tcat(name, " needs a value"))
		append(&out, args[i + 1])
	}
	return out[:]
}

@(private = "file")
has_flag :: proc(args: []string, name: string) -> bool {
	for a in args do if a == name do return true
	return false
}

// The arguments that are not flags or flag values.
@(private = "file")
positional :: proc(args: []string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	skip := false
	for a in args {
		if skip {skip = false; continue}
		is_vf := false
		for f in VALUE_FLAGS do if a == f do is_vf = true
		if is_vf {skip = true; continue}
		if strings.has_prefix(a, "--") && len(a) > 2 do continue
		append(&out, a)
	}
	return out[:]
}

@(private = "file")
cli_load :: proc(path: string) -> Schematic {
	if !file_exists(path) do cli_fail(EXIT_FILE, "file", tcat("no such file: ", path))
	sch, _, err := load_schematic_file(path)
	if len(err) > 0 do cli_fail(EXIT_FILE, "parse", err)
	return sch
}

@(private = "file")
cli_save :: proc(sch: ^Schematic, path: string, args: []string) -> string {
	out := path
	if o, ok := flag_value(args, "-o"); ok do out = o
	if file_ext_lower(out) != "edn" do cli_fail(EXIT_USAGE, "usage", tcat("spicy saves schematics as .edn, not ", out, " (use -o out.edn)"))
	sch_embed(sch, dir_of(abs_path(out)))
	if !write_text(out, sch_to_edn(sch)) do cli_fail(EXIT_FILE, "write", tcat("cannot write ", out))
	return out
}

@(private = "file")
parse_xy :: proc(s: string) -> P {
	f := strings.split(s, ",", context.temp_allocator)
	if len(f) != 2 do cli_usage(tcat("a point is x,y, not ", s))
	x, ok1 := strconv.parse_f64(strings.trim_space(f[0]))
	y, ok2 := strconv.parse_f64(strings.trim_space(f[1]))
	if !ok1 || !ok2 do cli_usage(tcat("a point is x,y, not ", s))
	return {i32(x), i32(y)}
}

@(private = "file")
find_comp :: proc(s: ^Schematic, ref: string) -> int {
	for c, i in s.comps do if strings.equal_fold(c.ref, ref) do return i
	return -1
}

// REF.PIN (pin name, or its number from 1) → part, pin, position.
@(private = "file")
parse_pin :: proc(s: ^Schematic, spec: string) -> (ci: int, k: int, at: P) {
	dot := strings.last_index_byte(spec, '.')
	if dot <= 0 do cli_usage(tcat("a pin is REF.PIN (R1.1, Q1.B), not ", spec))
	ci = find_comp(s, spec[:dot])
	if ci < 0 do cli_fail(EXIT_PROBLEMS, "not-found", tcat("no part ", spec[:dot]))
	c := &s.comps[ci]
	sym := symbol_find(c.sym)
	if sym == nil do cli_fail(EXIT_PROBLEMS, "not-found", tcat(c.ref, ": unknown symbol ", c.sym))
	pn := spec[dot + 1:]
	k = -1
	for p, i in sym.pins do if strings.equal_fold(p.name, pn) do k = i
	if k < 0 {
		if n, ok := strconv.parse_int(pn); ok && n >= 1 && n <= len(sym.pins) do k = n - 1
	}
	if k < 0 {
		names := make([dynamic]string, context.temp_allocator)
		for p in sym.pins do append(&names, p.name)
		cli_fail(EXIT_PROBLEMS, "not-found", fmt.tprintf("%s has no pin %s (pins: %s, or 1..%d)", c.ref, pn, strings.join(names[:], " ", context.temp_allocator), len(sym.pins)))
	}
	return ci, k, comp_pin(c, sym, k)
}

@(private = "file")
em_p :: proc(p: P) {em_vec(); em_int(int(p.x)); em_int(int(p.y)); em_vec_end()}

// One part as a map (with its pins and their nets).
@(private = "file")
em_comp :: proc(s: ^Schematic, ni: ^Net_Info, ci: int) {
	c := &s.comps[ci]
	sym := symbol_find(c.sym)
	em_map()
	em_key("ref"); em_str(c.ref)
	em_key("symbol"); em_str(c.sym)
	em_key("value"); em_str(c.value)
	if sym != nil {em_key("description"); em_str(sym.desc)}
	em_key("at"); em_p(c.pos)
	em_key("rot"); em_int(int(c.rot))
	em_key("mirror"); em_bool(c.mirror)
	if len(c.attrs) > 0 {
		em_key("attrs"); em_map()
		for a in c.attrs {em_skey(a.key); em_str(a.val)}
		em_map_end()
	}
	if sym != nil {
		em_key("pins"); em_vec()
		for p, k in sym.pins {
			em_map()
			em_key("name"); em_str(p.name)
			em_key("n"); em_int(k + 1)
			em_key("at"); em_p(comp_pin(c, sym, k))
			net := -1
			if ci < len(ni.pin_net) && k < len(ni.pin_net[ci]) do net = ni.pin_net[ci][k]
			em_key("net"); if net >= 0 do em_str(ni.names[net]); else do em_nil()
			em_map_end()
		}
		em_vec_end()
	}
	em_map_end()
}

@(private = "file")
cli_get :: proc(path: string, args: []string) {
	s := cli_load(path)
	ni := nets_build(&s)
	pos := positional(args)
	em_begin()
	if len(pos) > 0 {
		ci := find_comp(&s, pos[0])
		if ci < 0 do cli_fail(EXIT_PROBLEMS, "not-found", tcat("no part ", pos[0]))
		em_comp(&s, &ni, ci)
		em_print()
		return
	}
	em_map()
	em_key("file"); em_str(path)
	em_key("simulator"); em_str(s.simulator if len(s.simulator) > 0 else S.simulator)
	em_key("parts"); em_vec()
	for _, i in s.comps do em_comp(&s, &ni, i)
	em_vec_end()
	em_key("nets"); em_strs(ni.names[:])
	em_key("wires"); em_vec()
	for w, i in s.wires {
		em_map(); em_key("id"); em_str(fmt.tprintf("wire:%d", i + 1)); em_key("from"); em_p(w.a); em_key("to"); em_p(w.b); em_map_end()
	}
	em_vec_end()
	em_key("labels"); em_vec()
	for f, i in s.flags {
		em_map(); em_key("id"); em_str(fmt.tprintf("label:%d", i + 1)); em_key("name"); em_str("0 (ground)" if is_ground(f) else f.name); em_key("at"); em_p(f.pos); em_map_end()
	}
	em_vec_end()
	nd, nc := 0, 0
	em_key("directives"); em_vec()
	for t in s.texts do if t.directive {
		nd += 1
		em_map(); em_key("id"); em_str(fmt.tprintf("directive:%d", nd)); em_key("text"); em_str(t.text); em_key("at"); em_p(t.pos); em_map_end()
	}
	em_vec_end()
	em_key("comments"); em_vec()
	for t in s.texts do if !t.directive {
		nc += 1
		em_map(); em_key("id"); em_str(fmt.tprintf("comment:%d", nc)); em_key("text"); em_str(t.text); em_key("at"); em_p(t.pos); em_map_end()
	}
	em_vec_end()
	em_map_end()
	em_print()
}

@(private = "file")
cli_check :: proc(path: string, args: []string) {
	if !file_exists(path) do cli_fail(EXIT_FILE, "file", tcat("no such file: ", path))
	s, warn, err := load_schematic_file(path)
	if len(err) > 0 do cli_fail(EXIT_FILE, "parse", err)
	sim := cli_sim(&s, args)
	nl := netlist_build(&s, sim, "check", dir_of(abs_path(path)))
	errors := make([dynamic]string, context.temp_allocator)
	warnings := make([dynamic]string, context.temp_allocator)
	for w in warn do append(&errors, w) // unknown symbols
	for e in nl.errors do append(&errors, e)
	for w in nl.warnings do append(&warnings, w)
	for w in nl.nets.warnings do append(&warnings, w)
	if out_fmt == .Text {
		for e in errors do fmt.println("error:", e)
		for w in warnings do fmt.println("warning:", w)
		if len(errors) == 0 do fmt.println("no errors")
	} else {
		em_begin()
		em_map()
		em_key("file"); em_str(path)
		em_key("simulator"); em_str(sim.id)
		em_key("ok"); em_bool(len(errors) == 0)
		em_key("errors"); em_strs(errors[:])
		em_key("warnings"); em_strs(warnings[:])
		em_key("parts"); em_int(len(s.comps))
		em_key("nets"); em_int(len(nl.nets.names))
		em_map_end()
		em_print()
	}
	if len(errors) > 0 do os.exit(EXIT_PROBLEMS)
}

@(private = "file")
cli_set :: proc(path: string, args: []string) {
	s := cli_load(path)
	pos := positional(args)
	if len(pos) == 0 do cli_usage("--set needs REF.FIELD=VALUE (e.g. R1.value=2k)")
	for a in pos {
		eq := strings.index_byte(a, '=')
		if eq <= 0 do cli_usage(tcat("expected REF.FIELD=VALUE, not ", a))
		lhs, val := a[:eq], a[eq + 1:]
		if strings.equal_fold(lhs, "simulator") {
			if simulator_def(val) == nil do cli_fail(EXIT_PROBLEMS, "not-found", tcat("unknown simulator ", val))
			set_str(&s.simulator, val)
			continue
		}
		dot := strings.index_byte(lhs, '.')
		if dot <= 0 do cli_usage(tcat("expected REF.FIELD=VALUE, not ", a))
		ci := find_comp(&s, lhs[:dot])
		if ci < 0 do cli_fail(EXIT_PROBLEMS, "not-found", tcat("no part ", lhs[:dot]))
		c := &s.comps[ci]
		field := lhs[dot + 1:]
		switch lower(field) {
		case "value": set_str(&c.value, val)
		case "ref", "name":
			if j := find_comp(&s, val); j >= 0 && j != ci do cli_fail(EXIT_PROBLEMS, "exists", tcat("there is already a part ", val))
			set_str(&c.ref, val)
		case "at", "pos": c.pos = parse_xy(val)
		case "rot":
			n, ok := strconv.parse_int(val)
			if !ok do cli_usage("rot is 0..3 (quarter turns clockwise)")
			c.rot = u8(((n % 4) + 4) % 4)
		case "mirror": c.mirror = val == "true" || val == "1" || val == "yes"
		case:
			found := false
			for &at in c.attrs do if at.key == field {
				set_str(&at.val, val)
				found = true
			}
			if !found do append(&c.attrs, Attr{strings.clone(field), strings.clone(val)})
		}
	}
	wires_cleanup(&s)
	out := cli_save(&s, path, args)
	em_begin(); em_map(); em_key("file"); em_str(out); em_key("changed"); em_strs(pos); em_map_end(); em_print()
}

// A free spot to the right of everything (when --at is not given).
@(private = "file")
free_spot :: proc(s: ^Schematic) -> P {
	if len(s.comps) == 0 && len(s.wires) == 0 do return {0, 0}
	mx, my: i32 = -1 << 30, 1 << 30
	for c in s.comps {
		hi := c.pos.x
		if sym := symbol_find(c.sym); sym != nil do hi += i32(max(abs(sym.hi.x), abs(sym.lo.x), abs(sym.hi.y), abs(sym.lo.y)))
		mx = max(mx, hi)
		my = min(my, c.pos.y)
	}
	for w in s.wires {mx = max(mx, w.a.x, w.b.x); my = min(my, w.a.y, w.b.y)}
	g := i32(max(S.grid, 1))
	return snap_to({f32(mx + 4 * g), f32(my)}, int(g))
}

@(private = "file")
cli_add :: proc(path: string, args: []string) {
	s := cli_load(path)
	pos := positional(args)
	if len(pos) == 0 do cli_usage("--add needs what to add: a symbol name, ground, label, directive, comment or wire")
	what := pos[0]
	at := free_spot(&s)
	if v, ok := flag_value(args, "--at"); ok do at = parse_xy(v)
	if v, ok := flag_value(args, "--to"); ok {
		_, _, p := parse_pin(&s, v)
		at = p
	}
	added := ""
	switch lower(what) {
	case "ground", "gnd":
		append(&s.flags, Flag{name = strings.clone("0"), pos = at})
		added = "ground"
	case "label":
		if len(pos) < 2 do cli_usage("--add <file> label NAME (--at x,y | --to REF.PIN)")
		append(&s.flags, Flag{name = strings.clone(pos[1]), pos = at})
		added = pos[1]
	case "directive", "comment":
		if len(pos) < 2 do cli_usage(tcat("--add <file> ", what, " \"<text>\""))
		append(&s.texts, Text{pos = at, text = strings.clone(pos[1]), directive = lower(what) == "directive"})
		added = pos[1]
	case "wire":
		if len(pos) < 3 do cli_usage("--add <file> wire x1,y1 x2,y2")
		a, b := parse_xy(pos[1]), parse_xy(pos[2])
		append(&s.wires, Wire{a = a, b = b})
		added = "wire"
	case:
		sym := symbol_find(what)
		if sym == nil {
			for &x in symbols do if strings.equal_fold(x.name, what) || strings.equal_fold(part_short_name(&x), what) do sym = &x
		}
		if sym == nil do cli_fail(EXIT_PROBLEMS, "not-found", tcat("no symbol ", what, " (spicy --list symbols)"))
		if sym.kind == .Ground {
			append(&s.flags, Flag{name = strings.clone("0"), pos = at})
			added = "ground"
			break
		}
		ref := next_ref(&s, sym.prefix)
		if len(pos) > 1 do ref = pos[1]
		if find_comp(&s, ref) >= 0 do cli_fail(EXIT_PROBLEMS, "exists", tcat("there is already a part ", ref))
		c := Comp{sym = strings.clone(sym.name), ref = strings.clone(ref), value = strings.clone(sym.value), pos = at, attrs = make([dynamic]Attr)}
		if v, ok := flag_value(args, "--value"); ok do set_str(&c.value, v)
		if v, ok := flag_value(args, "--rot"); ok {
			n, _ := strconv.parse_int(v)
			c.rot = u8(((n % 4) + 4) % 4)
		}
		c.mirror = has_flag(args, "--mirror")
		append(&s.comps, c)
		added = ref
	}
	wires_cleanup(&s)
	out := cli_save(&s, path, args)
	ni := nets_build(&s)
	em_begin(); em_map()
	em_key("file"); em_str(out)
	em_key("added"); em_str(added)
	em_key("at"); em_p(at)
	if ci := find_comp(&s, added); ci >= 0 {em_key("part"); em_comp(&s, &ni, ci)}
	em_map_end(); em_print()
}

@(private = "file")
cli_remove :: proc(path: string, args: []string) {
	s := cli_load(path)
	pos := positional(args)
	if len(pos) == 0 do cli_usage("--remove needs REF, wire:N, label:N, directive:N or comment:N")
	// mark first, then delete (indices stay valid)
	for a in pos {
		if colon := strings.index_byte(a, ':'); colon > 0 {
			n, ok := strconv.parse_int(a[colon + 1:])
			if !ok || n < 1 do cli_usage(tcat("expected KIND:N, not ", a))
			kind := lower(a[:colon])
			found := false
			switch kind {
			case "wire": if n <= len(s.wires) {s.wires[n - 1].sel = true; found = true}
			case "label": if n <= len(s.flags) {s.flags[n - 1].sel = true; found = true}
			case "directive", "comment":
				k := 0
				for &t in s.texts do if t.directive == (kind == "directive") {
					k += 1
					if k == n {t.sel = true; found = true}
				}
			case: cli_usage(tcat("unknown kind ", kind))
			}
			if !found do cli_fail(EXIT_PROBLEMS, "not-found", tcat("no ", a))
			continue
		}
		ci := find_comp(&s, a)
		if ci < 0 do cli_fail(EXIT_PROBLEMS, "not-found", tcat("no part ", a))
		s.comps[ci].sel = true
	}
	d := headless_doc(&s)
	sch_delete_selection(d)
	out := cli_save(&d.sch, path, args)
	em_begin(); em_map(); em_key("file"); em_str(out); em_key("removed"); em_strs(pos); em_map_end(); em_print()
}

@(private = "file")
headless_doc :: proc(s: ^Schematic) -> ^Doc {
	d := new(Doc)
	d.sch = s^
	return d
}

@(private = "file")
on_segment :: proc(p, a, b: P) -> bool {
	if a.x == b.x do return p.x == a.x && p.y > min(a.y, b.y) && p.y < max(a.y, b.y)
	if a.y == b.y do return p.y == a.y && p.x > min(a.x, b.x) && p.x < max(a.x, b.x)
	return false
}

// A straight wire a–b touches nothing else on its way (no pin, wire end, label, or wire along it).
@(private = "file")
path_clear :: proc(s: ^Schematic, a, b: P) -> bool {
	if a.x != b.x && a.y != b.y do return false
	for &c in s.comps {
		sym := symbol_find(c.sym)
		if sym == nil do continue
		for k in 0 ..< len(sym.pins) do if on_segment(comp_pin(&c, sym, k), a, b) do return false
	}
	for w in s.wires {
		if on_segment(w.a, a, b) || on_segment(w.b, a, b) || on_segment(a, w.a, w.b) || on_segment(b, w.a, w.b) do return false
	}
	for f in s.flags do if on_segment(f.pos, a, b) do return false
	return true
}

@(private = "file")
cli_connect :: proc(path: string, args: []string) {
	s := cli_load(path)
	pos := positional(args)
	if len(pos) < 2 do cli_usage("--connect needs two or more pins: REF.PIN REF.PIN …")
	pts := make([dynamic]P, context.temp_allocator)
	for p in pos {
		_, _, at := parse_pin(&s, p)
		append(&pts, at)
	}
	how := make([dynamic]string, context.temp_allocator)
	// the net's name: --net, else a label already on one of the pins' nets, else a new one
	ni := nets_build(&s)
	net, has_net := flag_value(args, "--net")
	if !has_net {
		for p in pos {
			ci, k, _ := parse_pin(&s, p)
			if n := ni.pin_net[ci][k]; n >= 0 && ni.label_of[n] {net = ni.names[n]; break}
		}
	}
	all_wired := !has_net
	if all_wired do for i in 1 ..< len(pts) do if !path_clear(&s, pts[i - 1], pts[i]) do all_wired = false
	if all_wired {
		for i in 1 ..< len(pts) {
			append(&s.wires, Wire{a = pts[i - 1], b = pts[i]})
			append(&how, fmt.tprintf("wire %s – %s", pos[i - 1], pos[i]))
		}
	} else {
		if len(net) == 0 {
			taken := make(map[string]bool, 16, context.temp_allocator)
			for n in ni.names do taken[lower(n)] = true
			for f in s.flags do taken[lower(f.name)] = true
			for i := 1; ; i += 1 {
				net = fmt.tprintf("net%d", i)
				if !taken[net] do break
			}
		}
		for p, i in pts {
			append(&s.flags, Flag{name = strings.clone(net), pos = p})
			append(&how, fmt.tprintf("label %s on %s", net, pos[i]))
		}
	}
	wires_cleanup(&s)
	out := cli_save(&s, path, args)
	em_begin(); em_map()
	em_key("file"); em_str(out)
	em_key("connected"); em_strs(pos)
	em_key("by"); em_kw("wire" if all_wired else "label")
	if !all_wired {em_key("net"); em_str(net)}
	em_key("added"); em_strs(how[:])
	em_map_end(); em_print()
}

// Menu actions that make sense without the GUI.
HEADLESS_ACTIONS := [?]string{"edit/rotate", "edit/mirror", "edit/delete", "view/netlist", "file/export-netlist", "sim/run"}

@(private = "file")
cli_do :: proc(path: string, args: []string) {
	pos := positional(args)
	if len(pos) == 0 do cli_usage(tcat("--do needs an action: ", strings.join(HEADLESS_ACTIONS[:], " ", context.temp_allocator)))
	action := pos[0]
	switch action {
	case "view/netlist":
		cli_netlist_or_run(path, true, args)
		return
	case "sim/run":
		cli_netlist_or_run(path, false, args)
		return
	case "file/export-netlist":
		if len(pos) < 2 do cli_usage("--do <file> file/export-netlist <out.cir>")
		s := cli_load(path)
		sim := cli_sim(&s, args)
		nl := netlist_build(&s, sim, tcat("spicy: ", base_name(path)), dir_of(abs_path(path)))
		if len(nl.errors) > 0 do cli_fail(EXIT_PROBLEMS, "netlist", "the netlist has errors", nl.errors[:])
		if !write_text(pos[1], nl.text) do cli_fail(EXIT_FILE, "write", tcat("cannot write ", pos[1]))
		em_begin(); em_map(); em_key("file"); em_str(pos[1]); em_key("warnings"); em_strs(nl.warnings[:]); em_map_end(); em_print()
		return
	case "edit/rotate", "edit/mirror", "edit/delete":
		s := cli_load(path)
		if len(pos) < 2 do cli_usage(tcat("--do <file> ", action, " REF …"))
		for r in pos[1:] {
			ci := find_comp(&s, r)
			if ci < 0 do cli_fail(EXIT_PROBLEMS, "not-found", tcat("no part ", r))
			s.comps[ci].sel = true
		}
		d := headless_doc(&s)
		switch action {
		case "edit/rotate": sch_rotate(d)
		case "edit/mirror": sch_mirror(d)
		case "edit/delete": sch_delete_selection(d)
		}
		for &c in d.sch.comps do c.sel = false
		out := cli_save(&d.sch, path, args)
		em_begin(); em_map(); em_key("file"); em_str(out); em_key("action"); em_str(action); em_key("parts"); em_strs(pos[1:]); em_map_end(); em_print()
		return
	}
	known := false
	for a in actions do if a.name == action do known = true
	if known do cli_fail(EXIT_USAGE, "gui-only", tcat(action, " needs the GUI; without it: ", strings.join(HEADLESS_ACTIONS[:], " ", context.temp_allocator)))
	cli_fail(EXIT_USAGE, "usage", tcat("unknown action ", action, " (spicy --list actions)"))
}

@(private = "file")
cli_list :: proc(args: []string) {
	pos := positional(args)
	what := pos[0] if len(pos) > 0 else ""
	em_begin()
	switch what {
	case "symbols":
		em_vec()
		for s in symbols_by_category() {
			em_map()
			em_key("name"); em_str(s.name)
			em_key("description"); em_str(s.desc)
			em_key("category"); em_str(s.category)
			em_key("prefix"); em_str(s.prefix)
			em_key("value"); em_str(s.value)
			em_key("pins"); em_vec(); for p in s.pins do em_str(p.name); em_vec_end()
			k := action_keys_text(tcat("place/", s.name))
			if len(k) > 0 {em_key("key"); em_str(k)}
			em_map_end()
		}
		em_vec_end()
	case "actions":
		em_vec()
		for a in actions {
			em_map()
			em_key("name"); em_str(a.name)
			em_key("description"); em_str(a.desc)
			em_key("keys"); em_str(action_keys_text(a.name))
			hl := false
			for h in HEADLESS_ACTIONS do if h == a.name do hl = true
			em_key("headless"); em_bool(hl)
			em_map_end()
		}
		em_vec_end()
	case "simulators":
		em_vec()
		for sd in S.simulators {
			em_map()
			em_key("id"); em_str(sd.id)
			em_key("name"); em_str(sd.name)
			em_key("command"); em_strs(sd.command)
			p, ok := find_program(sd.command[0] if len(sd.command) > 0 else "")
			em_key("found"); em_bool(ok)
			if ok {em_key("program"); em_str(p)}
			em_key("default"); em_bool(sd.id == S.simulator)
			em_map_end()
		}
		em_vec_end()
	case: cli_usage("--list symbols|actions|simulators")
	}
	em_print()
}

// --netlist (the netlist text itself) and --run (the results).
cli_netlist_or_run :: proc(path: string, netlist_only: bool, args: []string) {
	s := cli_load(path)
	sim := cli_sim(&s, args)
	if netlist_only {
		// the netlist even when it has errors (they go to stderr, exit 1)
		nl := netlist_build(&s, sim, tcat("spicy: ", base_name(path)), dir_of(abs_path(path)))
		fmt.print(nl.text)
		for x in nl.warnings do fmt.eprintln("warning:", x)
		if len(nl.errors) > 0 do cli_fail(EXIT_PROBLEMS, "netlist", "the netlist has errors", nl.errors[:])
		return
	}
	r: Run
	run_start(&r, &s, path, 0, sim)
	for r.state == .Running {
		time.sleep(5 * time.Millisecond)
		run_poll(&r)
	}
	if r.state == .Failed {
		code := EXIT_TOOL if strings.has_prefix(r.message, "Could not start") else EXIT_PROBLEMS
		cli_fail(code, "run", r.message, r.warnings[:])
	}
	if csv, ok := flag_value(args, "--csv"); ok && len(r.plots) > 0 {
		// the last analysis with traces: not a one-point result (operating point, integrated noise)
		pi := len(r.plots) - 1
		for k := len(r.plots) - 1; k >= 0; k -= 1 do if plot_listed(&r.plots[k]) {
			pi = k
			break
		}
		if !write_csv(&r.plots[pi], csv) do cli_fail(EXIT_FILE, "write", tcat("cannot write ", csv))
	}
	meas_run(&r, &s, sim)
	ratings_check(&r, &s, sim)
	traces := flag_values(args, "--trace")
	stats := make([dynamic]Trace_Stat, context.temp_allocator)
	for e in traces do append(&stats, cli_trace_stat(&r, &s, sim, e))
	if out_fmt == .Text {
		for x in r.warnings do fmt.eprintln("warning:", x)
		fmt.println(r.message)
		for m in r.measures do fmt.println("measure", m)
		for &p in r.plots {
			fmt.printfln("plot \"%s\" (%s, %d points%s)", p.name, base_name(p.file), p.npoints, ", complex" if p.complex else "")
			for v in p.vecs {
				last := len(v.re) - 1
				if last < 0 do continue
				fmt.printfln("  %-28s %s", v.name, fmt_eng(v.re[last], v.unit) if !p.complex else fmt.tprintf("%s ∠ %.1f°", fmt_eng(abs_c(v.re[last], v.im[last]), v.unit), phase_deg(v.re[last], v.im[last])))
			}
		}
		for st in stats {
			if len(st.err) > 0 {
				fmt.printfln("trace %s: %s", st.expr, st.err)
				continue
			}
			fmt.printfln("trace %s (%s): min %s, max %s, last %s", st.expr, st.plot, fmt_eng(st.lo, st.unit), fmt_eng(st.hi, st.unit), fmt_eng(st.last, st.unit))
		}
		return
	}
	// --points: every value, not only the last
	all := has_flag(args, "--points")
	em_begin(); em_map()
	em_key("file"); em_str(path)
	em_key("simulator"); em_str(sim.id)
	em_key("message"); em_str(r.message)
	em_key("warnings"); em_strs(r.warnings[:])
	em_key("measures"); em_strs(r.measures[:])
	em_key("plots"); em_vec()
	for &p in r.plots {
		em_map()
		em_key("name"); em_str(p.name)
		em_key("raw"); em_str(p.file)
		em_key("points"); em_int(p.npoints)
		em_key("complex"); em_bool(p.complex)
		em_key("vectors"); em_vec()
		for v in p.vecs {
			em_map()
			em_key("name"); em_str(v.name)
			em_key("unit"); em_str(v.unit)
			last := len(v.re) - 1
			if last >= 0 {
				if p.complex {
					em_key("final"); em_map(); em_key("mag"); em_num(abs_c(v.re[last], v.im[last])); em_key("phase"); em_num(phase_deg(v.re[last], v.im[last])); em_map_end()
				} else {
					em_key("final"); em_num(v.re[last])
					lo, hi := v.re[0], v.re[0]
					for x in v.re {lo = min(lo, x); hi = max(hi, x)}
					em_key("min"); em_num(lo)
					em_key("max"); em_num(hi)
				}
			}
			if all {
				em_key("re"); em_vec(); for x in v.re do em_num(x); em_vec_end()
				if p.complex {em_key("im"); em_vec(); for x in v.im do em_num(x); em_vec_end()}
			}
			em_map_end()
		}
		em_vec_end()
		em_map_end()
	}
	em_vec_end()
	if len(traces) > 0 {
		em_key("traces"); em_vec()
		for st in stats {
			em_map()
			em_key("expr"); em_str(st.expr)
			if len(st.err) > 0 {
				em_key("error"); em_str(st.err)
			} else {
				em_key("plot"); em_str(st.plot)
				em_key("unit"); em_str(st.unit)
				em_key("min"); em_num(st.lo)
				em_key("max"); em_num(st.hi)
				em_key("final"); em_num(st.last)
			}
			em_map_end()
		}
		em_vec_end()
	}
	em_map_end(); em_print()
}

// One --trace: the range and last value of an expression on the analysis the viewer shows.
Trace_Stat :: struct {
	expr, plot, unit, err: string,
	lo, hi, last:          f64,
}

@(private = "file")
cli_trace_stat :: proc(r: ^Run, s: ^Schematic, sim: ^Simulator_Def, expr: string) -> Trace_Stat {
	st := Trace_Stat{expr = expr}
	if len(r.plots) == 0 {
		st.err = "the run has no results"
		return st
	}
	idx := 0
	for &p, i in r.plots do if plot_kind(&p) != "op" && p.npoints > 1 {idx = i; break}
	// a trace that only another analysis has (a noise vector, say) is read from that one
	if len(plot_expr_error(expr, &r.plots[idx], s, sim)) > 0 {
		for i in 0 ..< len(r.plots) do if len(plot_expr_error(expr, &r.plots[i], s, sim)) == 0 {idx = i; break}
	}
	st.plot = r.plots[idx].name
	res := expr_eval(expr, &r.plots[idx], s, sim)
	defer {
		delete(res.re)
		delete(res.im)
		delete(res.unit)
	}
	if len(res.err) > 0 {
		st.err = strings.clone(res.err, context.temp_allocator)
		delete(res.err)
		return st
	}
	defer delete(res.err)
	st.unit = strings.clone(res.unit, context.temp_allocator)
	if len(res.re) == 0 do return st
	value := proc(res: Eval_Result, i: int) -> f64 {
		// a real result of a complex analysis (db, ph, mag) keeps its sign
		if res.im == nil || res.im[i] == 0 do return res.re[i]
		return abs_c(res.re[i], res.im[i])
	}
	st.lo, st.hi = value(res, 0), value(res, 0)
	for i in 0 ..< len(res.re) {
		x := value(res, i)
		st.lo = min(st.lo, x)
		st.hi = max(st.hi, x)
	}
	st.last = value(res, len(res.re) - 1)
	return st
}

// The command-line commands of this file; false when args[0] is not one of them.
cli_main :: proc(args: []string) -> bool {
	cmd := args[0]
	need_file :: proc(args: []string) -> string {
		if len(args) < 2 || strings.has_prefix(args[1], "--") do cli_usage(tcat(args[0], " needs a schematic file"))
		return args[1]
	}
	switch cmd {
	case "--new":
		load_config()
		path := need_file(args)
		if file_exists(path) && !has_flag(args, "--force") do cli_fail(EXIT_FILE, "exists", tcat(path, " exists (--force replaces it)"))
		s: Schematic
		if v, ok := flag_value(args[2:], "--sim"); ok do s.simulator = v
		out := cli_save(&s, path, args[2:])
		em_begin(); em_map(); em_key("file"); em_str(out); em_key("created"); em_bool(true); em_map_end(); em_print()
	case "--check": load_config(); cli_check(need_file(args), args[2:])
	case "--get": load_config(); cli_get(need_file(args), args[2:])
	case "--set": load_config(); cli_set(need_file(args), args[2:])
	case "--add": load_config(); cli_add(need_file(args), args[2:])
	case "--remove": load_config(); cli_remove(need_file(args), args[2:])
	case "--connect": load_config(); cli_connect(need_file(args), args[2:])
	case "--do": load_config(); cli_do(need_file(args), args[2:])
	case "--list": load_config(); cli_list(args[1:])
	case "--run": load_config(); cli_netlist_or_run(need_file(args), false, args[2:])
	case "--netlist": load_config(); cli_netlist_or_run(need_file(args), true, args[2:])
	case: return false
	}
	return true
}
