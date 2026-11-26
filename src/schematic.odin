package spicy

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"

// The schematic: parts, wires, net flags (labels and grounds) and texts (comments and
// SPICE directives). Coordinates are integer schematic units (16 per grid step).

P :: [2]i32

Attr :: struct {
	key, val: string,
}

Comp :: struct {
	sym:    string,
	ref:    string,
	value:  string,
	pos:    P,
	rot:    u8, // quarter turns clockwise
	mirror: bool,
	attrs:  [dynamic]Attr, // extra fields for the :spice template
	sel:    bool,
}

Wire :: struct {
	a, b: P,
	sel:  bool,
}

Flag :: struct {
	name: string, // "0" = ground
	pos:  P,
	rot:  u8, // label text direction / ground orientation
	sel:  bool,
}

Text :: struct {
	pos:       P,
	text:      string,
	directive: bool,
	sel:       bool,
}

Schematic :: struct {
	comps:     [dynamic]Comp,
	wires:     [dynamic]Wire,
	flags:     [dynamic]Flag,
	texts:     [dynamic]Text,
	simulator: string, // per-schematic override ("" = settings)
	waves:     string, // EDN text of the waveform setup (panes and traces)
	// copies of what the schematic needs beyond a standard spicy (models.odin, sch_embed),
	// so that the file simulates anywhere
	embedded:     [dynamic]Embedded_Model,
	embedded_sym: [dynamic]string, // EDN maps of the symbols of imported / own parts
}

Embedded_Model :: struct {
	name: string, // lower case
	from: string, // the file it was copied from (an .include's file name, or a library)
	text: string, // the .model / .subckt card
}

is_ground :: proc(f: Flag) -> bool {return f.name == "0"}

sch_free :: proc(s: ^Schematic) {
	for &c in s.comps {
		delete(c.sym); delete(c.ref); delete(c.value)
		for a in c.attrs {delete(a.key); delete(a.val)}
		delete(c.attrs)
	}
	for f in s.flags do delete(f.name)
	for t in s.texts do delete(t.text)
	delete(s.comps); delete(s.wires); delete(s.flags); delete(s.texts)
	delete(s.simulator); delete(s.waves)
	embedded_free(s)
	delete(s.embedded); delete(s.embedded_sym)
	s^ = {}
}

comp_clone :: proc(c: Comp) -> Comp {
	r := c
	r.sym = strings.clone(c.sym)
	r.ref = strings.clone(c.ref)
	r.value = strings.clone(c.value)
	r.attrs = make([dynamic]Attr)
	for a in c.attrs do append(&r.attrs, Attr{strings.clone(a.key), strings.clone(a.val)})
	return r
}

comp_attr :: proc(c: ^Comp, key: string) -> string {
	for a in c.attrs do if a.key == key do return a.val
	return ""
}

comp_set_attr :: proc(c: ^Comp, key, val: string) {
	for &a in c.attrs do if a.key == key {
		set_str(&a.val, val)
		return
	}
	append(&c.attrs, Attr{strings.clone(key), strings.clone(val)})
}

// ---------------------------------------------------------------------------
// Geometry

xform_f :: proc(pos: P, rot: u8, mirror: bool, p: [2]f32) -> [2]f32 {
	q := p
	if mirror do q.x = -q.x
	for _ in 0 ..< rot % 4 do q = {-q.y, q.x}
	return q + {f32(pos.x), f32(pos.y)}
}

xform_p :: proc(pos: P, rot: u8, mirror: bool, p: P) -> P {
	q := p
	if mirror do q.x = -q.x
	for _ in 0 ..< rot % 4 do q = {-q.y, q.x}
	return q + pos
}

comp_xf :: proc(c: ^Comp, p: [2]f32) -> [2]f32 {return xform_f(c.pos, c.rot, c.mirror, p)}

comp_pin :: proc(c: ^Comp, s: ^Symbol, i: int) -> P {return xform_p(c.pos, c.rot, c.mirror, s.pins[i].at)}

// Rotated bounding box of a part (schematic units).
comp_bounds :: proc(c: ^Comp, s: ^Symbol) -> (lo, hi: [2]f32) {
	a := comp_xf(c, s.lo)
	b := comp_xf(c, s.hi)
	return {min(a.x, b.x), min(a.y, b.y)}, {max(a.x, b.x), max(a.y, b.y)}
}

// p lies on segment a-b (endpoints included).
on_segment :: proc(p, a, b: P) -> bool {
	if p.x < min(a.x, b.x) || p.x > max(a.x, b.x) || p.y < min(a.y, b.y) || p.y > max(a.y, b.y) do return false
	cross := i64(b.x - a.x) * i64(p.y - a.y) - i64(b.y - a.y) * i64(p.x - a.x)
	return cross == 0
}

// p lies strictly inside segment a-b.
in_segment :: proc(p, a, b: P) -> bool {return p != a && p != b && on_segment(p, a, b)}

seg_dist :: proc(p, a, b: [2]f32) -> f32 {
	d := b - a
	l2 := d.x * d.x + d.y * d.y
	if l2 < 1e-9 do return vlen(p - a)
	t := clamp(((p.x - a.x) * d.x + (p.y - a.y) * d.y) / l2, 0, 1)
	return vlen(p - (a + d * t))
}

vlen :: proc(v: [2]f32) -> f32 {return math.sqrt(v.x * v.x + v.y * v.y)}

pf :: proc(p: P) -> [2]f32 {return {f32(p.x), f32(p.y)}}

snap_to :: proc(p: [2]f32, grid: int) -> P {
	g := f32(grid)
	return {i32(math.round(p.x / g) * g), i32(math.round(p.y / g) * g)}
}

// ---------------------------------------------------------------------------
// Connectivity

Net_Info :: struct {
	names:      [dynamic]string, // net index -> name ("0" ground)
	pin_net:    [dynamic][]int, // per part, per pin
	wire_net:   [dynamic]int,
	flag_net:   [dynamic]int,
	point_net:  map[P]int,
	junctions:  [dynamic]P,
	open_pins:  [dynamic]P,
	warnings:   [dynamic]string,
	label_of:   [dynamic]bool, // net has a user-given name
}

@(private = "file")
uf_find :: proc(parent: []int, i: int) -> int {
	r := i
	for parent[r] != r do r = parent[r]
	x := i
	for parent[x] != r {
		n := parent[x]
		parent[x] = r
		x = n
	}
	return r
}

@(private = "file")
uf_union :: proc(parent: []int, a, b: int) {
	ra, rb := uf_find(parent, a), uf_find(parent, b)
	if ra != rb do parent[max(ra, rb)] = min(ra, rb)
}

// Works out the nets. All results use the temp allocator.
nets_build :: proc(s: ^Schematic, net_prefix := "N") -> Net_Info {
	ni: Net_Info
	ta := context.temp_allocator
	ni.names = make([dynamic]string, ta)
	ni.pin_net = make([dynamic][]int, ta)
	ni.wire_net = make([dynamic]int, ta)
	ni.flag_net = make([dynamic]int, ta)
	ni.point_net = make(map[P]int, 256, ta)
	ni.junctions = make([dynamic]P, ta)
	ni.open_pins = make([dynamic]P, ta)
	ni.warnings = make([dynamic]string, ta)
	ni.label_of = make([dynamic]bool, ta)

	idx := make(map[P]int, 256, ta)
	pts := make([dynamic]P, ta)
	add_pt :: proc(idx: ^map[P]int, pts: ^[dynamic]P, p: P) -> int {
		if i, ok := idx[p]; ok do return i
		idx[p] = len(pts)
		append(pts, p)
		return len(pts) - 1
	}
	for w in s.wires {
		add_pt(&idx, &pts, w.a)
		add_pt(&idx, &pts, w.b)
	}
	pin_pts := make([dynamic][]P, ta)
	for &c in s.comps {
		sym := symbol_find(c.sym)
		n := len(sym.pins) if sym != nil else 0
		pp := make([]P, n, ta)
		for i in 0 ..< n {
			pp[i] = comp_pin(&c, sym, i)
			add_pt(&idx, &pts, pp[i])
		}
		append(&pin_pts, pp)
	}
	for f in s.flags do add_pt(&idx, &pts, f.pos)

	parent := make([]int, len(pts), ta)
	for i in 0 ..< len(parent) do parent[i] = i
	for w in s.wires do uf_union(parent, idx[w.a], idx[w.b])
	// a point inside a wire connects to it (T junctions, pins on wires)
	inside := make([]int, len(pts), ta) // how many wires pass through the point
	for p, i in pts {
		for w in s.wires {
			if in_segment(p, w.a, w.b) {
				uf_union(parent, i, idx[w.a])
				inside[i] += 1
			}
		}
	}
	// labels with the same name are one net
	first_of := make(map[string]int, 16, ta)
	for f in s.flags {
		i := idx[f.pos]
		if j, ok := first_of[f.name]; ok do uf_union(parent, i, j)
		else do first_of[f.name] = i
	}
	// net names
	root_net := make(map[int]int, 64, ta)
	root_name := make(map[int]string, 64, ta)
	for f in s.flags {
		r := uf_find(parent, idx[f.pos])
		if old, ok := root_name[r]; ok {
			if old != f.name {
				if old == "0" || f.name == "0" {
					append(&ni.warnings, fmt.tprintf("net label \"%s\" is connected to ground", f.name if old == "0" else old))
					root_name[r] = "0"
				} else {
					append(&ni.warnings, fmt.tprintf("one net has two names: \"%s\" and \"%s\" (\"%s\" is used)", old, f.name, min(old, f.name)))
					root_name[r] = min(old, f.name)
				}
			}
		} else {
			root_name[r] = f.name
		}
	}
	// unnamed nets numbered from top-left to bottom-right
	order := make([dynamic]int, ta)
	for i in 0 ..< len(pts) do if uf_find(parent, i) == i do append(&order, i)
	// sort the roots by the position of their point
	sort_pts := pts[:]
	for i in 1 ..< len(order) {
		j := i
		for j > 0 {
			pa, pb := sort_pts[order[j - 1]], sort_pts[order[j]]
			if pa.y < pb.y || (pa.y == pb.y && pa.x <= pb.x) do break
			order[j - 1], order[j] = order[j], order[j - 1]
			j -= 1
		}
	}
	used := make(map[string]bool, 64, ta)
	for _, n in root_name do used[lower(n)] = true
	auto_n := 1
	for r in order {
		name, named := root_name[r]
		if !named {
			for {
				name = fmt.tprintf("%s%03d", net_prefix, auto_n)
				auto_n += 1
				if !used[lower(name)] do break
			}
		}
		root_net[r] = len(ni.names)
		append(&ni.names, name)
		append(&ni.label_of, named)
	}
	net_of :: proc(parent: []int, root_net: map[int]int, i: int) -> int {return root_net[uf_find(parent, i)]}
	for p, i in pts do ni.point_net[p] = net_of(parent, root_net, i)
	for pp in pin_pts {
		nets := make([]int, len(pp), ta)
		for p, k in pp do nets[k] = ni.point_net[p]
		append(&ni.pin_net, nets)
	}
	for w in s.wires do append(&ni.wire_net, ni.point_net[w.a])
	for f in s.flags do append(&ni.flag_net, ni.point_net[f.pos])

	// junction dots and unconnected pins
	ends := make([]int, len(pts), ta)
	pins_at := make([]int, len(pts), ta)
	flags_at := make([]int, len(pts), ta)
	for w in s.wires {
		ends[idx[w.a]] += 1
		ends[idx[w.b]] += 1
	}
	for pp in pin_pts do for p in pp do pins_at[idx[p]] += 1
	for f in s.flags do flags_at[idx[f.pos]] += 1
	for p, i in pts {
		n := ends[i] + 2 * inside[i] + pins_at[i]
		if ends[i] + inside[i] > 0 && n >= 3 do append(&ni.junctions, p)
		if pins_at[i] == 1 && ends[i] + inside[i] + flags_at[i] == 0 do append(&ni.open_pins, p)
	}
	return ni
}

// ---------------------------------------------------------------------------
// Editing helpers

// Next free name for a prefix: R1, R2 …
next_ref :: proc(s: ^Schematic, prefix: string) -> string {
	n := 0
	for c in s.comps {
		if len(c.ref) > len(prefix) && strings.equal_fold(c.ref[:len(prefix)], prefix) {
			if v, ok := parse_int_str(c.ref[len(prefix):]); ok do n = max(n, v)
		}
	}
	return fmt.tprintf("%s%d", prefix, n + 1)
}

parse_int_str :: proc(s: string) -> (int, bool) {
	if len(s) == 0 do return 0, false
	v := 0
	for ch in s {
		if ch < '0' || ch > '9' do return 0, false
		v = v * 10 + int(ch - '0')
	}
	return v, true
}

// All pin positions with their part index.
Pin_Ref :: struct {
	p:    P,
	comp: int,
	pin:  int,
}

all_pins :: proc(s: ^Schematic) -> []Pin_Ref {
	out := make([dynamic]Pin_Ref, context.temp_allocator)
	for &c, ci in s.comps {
		sym := symbol_find(c.sym)
		if sym == nil do continue
		for _, k in sym.pins do append(&out, Pin_Ref{comp_pin(&c, sym, k), ci, k})
	}
	return out[:]
}

// Adds a wire segment. With cut_through, the segment is split at every pin it passes and
// the pieces running between two pins of one part are dropped (no short across the part).
add_wire :: proc(s: ^Schematic, a, b: P, cut_through: bool) {
	if a == b do return
	if !cut_through {
		append(&s.wires, Wire{a = a, b = b})
		wires_cleanup(s)
		return
	}
	pins := all_pins(s)
	Hit :: struct {
		t:    i64,
		p:    P,
		comp: int,
	}
	hits := make([dynamic]Hit, context.temp_allocator)
	d := b - a
	len2 := i64(d.x) * i64(d.x) + i64(d.y) * i64(d.y)
	tof :: proc(p, a, d: P) -> i64 {return i64(p.x - a.x) * i64(d.x) + i64(p.y - a.y) * i64(d.y)}
	append(&hits, Hit{0, a, -1}, Hit{len2, b, -1})
	for pr in pins {
		if on_segment(pr.p, a, b) do append(&hits, Hit{tof(pr.p, a, d), pr.p, pr.comp})
	}
	slice.sort_by(hits[:], proc(x, y: Hit) -> bool {return x.t < y.t})
	// pins of the same part at one point count once; remember which parts sit at each stop
	Stop :: struct {
		p:     P,
		comps: [dynamic]int,
	}
	stops := make([dynamic]Stop, context.temp_allocator)
	for h in hits {
		if len(stops) == 0 || stops[len(stops) - 1].p != h.p {
			append(&stops, Stop{p = h.p, comps = make([dynamic]int, context.temp_allocator)})
		}
		if h.comp >= 0 do append(&stops[len(stops) - 1].comps, h.comp)
	}
	for i in 1 ..< len(stops) {
		p0, p1 := stops[i - 1], stops[i]
		inside := false
		for c0 in p0.comps do for c1 in p1.comps do if c0 == c1 do inside = true
		if !inside do append(&s.wires, Wire{a = p0.p, b = p1.p})
	}
	wires_cleanup(s)
}

// Joins collinear wires that overlap, or that meet end to end where nothing else connects,
// and removes zero-length and duplicate wires.
wires_cleanup :: proc(s: ^Schematic) {
	for i := len(s.wires) - 1; i >= 0; i -= 1 do if s.wires[i].a == s.wires[i].b do ordered_remove(&s.wires, i)
	changed := true
	for changed {
		changed = false
		outer: for i in 0 ..< len(s.wires) {
			for j in i + 1 ..< len(s.wires) {
				if m, ok := try_merge(s, s.wires[i], s.wires[j]); ok {
					m.sel = s.wires[i].sel || s.wires[j].sel
					s.wires[i] = m
					ordered_remove(&s.wires, j)
					changed = true
					break outer
				}
			}
		}
	}
}

@(private = "file")
try_merge :: proc(s: ^Schematic, w1, w2: Wire) -> (Wire, bool) {
	// collinear?
	d1 := w1.b - w1.a
	if !(on_line(w2.a, w1.a, d1) && on_line(w2.b, w1.a, d1)) do return {}, false
	// parametrise along d1
	axis := 0 if abs(d1.x) >= abs(d1.y) else 1
	lo1, hi1 := min(w1.a[axis], w1.b[axis]), max(w1.a[axis], w1.b[axis])
	lo2, hi2 := min(w2.a[axis], w2.b[axis]), max(w2.a[axis], w2.b[axis])
	if hi1 < lo2 || hi2 < lo1 do return {}, false
	if hi1 == lo2 || hi2 == lo1 {
		// end to end: only when the shared point has no other connection
		shared := w1.b if (w1.b == w2.a || w1.b == w2.b) else w1.a
		if point_busy(s, shared, w1, w2) do return {}, false
	}
	// the union: the two extreme endpoints
	ps := [4]P{w1.a, w1.b, w2.a, w2.b}
	lo, hi := ps[0], ps[0]
	for p in ps {
		if p[axis] < lo[axis] do lo = p
		if p[axis] > hi[axis] do hi = p
	}
	return Wire{a = lo, b = hi}, true
}

@(private = "file")
on_line :: proc(p, a: P, d: P) -> bool {
	return i64(d.x) * i64(p.y - a.y) - i64(d.y) * i64(p.x - a.x) == 0
}

// Something besides w1 and w2 connects at p (a pin, a flag or another wire).
@(private = "file")
point_busy :: proc(s: ^Schematic, p: P, w1, w2: Wire) -> bool {
	for w in s.wires {
		if (w.a == w1.a && w.b == w1.b) || (w.a == w2.a && w.b == w2.b) do continue
		if on_segment(p, w.a, w.b) do return true
	}
	for f in s.flags do if f.pos == p do return true
	for pr in all_pins(s) do if pr.p == p do return true
	return false
}

// Wires made diagonal by dragging become two straight segments (an L).
wires_orthogonalize :: proc(s: ^Schematic, moved_ends: map[P]bool) {
	n := len(s.wires)
	for i in 0 ..< n {
		w := s.wires[i]
		if w.a.x == w.b.x || w.a.y == w.b.y do continue
		// the moved end is the one that left its line; bend near it
		corner: P
		if moved_ends[w.b] {
			corner = {w.b.x, w.a.y} if abs(w.b.x - w.a.x) >= abs(w.b.y - w.a.y) else {w.a.x, w.b.y}
		} else {
			corner = {w.a.x, w.b.y} if abs(w.b.x - w.a.x) >= abs(w.b.y - w.a.y) else {w.b.x, w.a.y}
		}
		s.wires[i].b = corner
		append(&s.wires, Wire{a = corner, b = w.b, sel = w.sel})
	}
	wires_cleanup(s)
}

// ---------------------------------------------------------------------------
// EDN file format

sch_to_edn :: proc(s: ^Schematic) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, ";; spicy schematic (EDN)\n{:spicy-schematic 1")
	if len(s.simulator) > 0 do fmt.sbprintf(&b, "\n :simulator :%s", s.simulator)
	strings.write_string(&b, "\n :components [")
	for c, i in s.comps {
		if i > 0 do strings.write_string(&b, "\n              ")
		fmt.sbprintf(&b, "{{:symbol %s :ref %s :value %s :at [%d %d]", edn_quoted(c.sym), edn_quoted(c.ref), edn_quoted(c.value), c.pos.x, c.pos.y)
		if c.rot != 0 do fmt.sbprintf(&b, " :rot %d", int(c.rot) * 90)
		if c.mirror do strings.write_string(&b, " :mirror true")
		if len(c.attrs) > 0 {
			strings.write_string(&b, " :attrs {")
			for a, k in c.attrs {
				if k > 0 do strings.write_byte(&b, ' ')
				fmt.sbprintf(&b, "%s %s", edn_quoted(a.key), edn_quoted(a.val))
			}
			strings.write_string(&b, "}")
		}
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, "]\n :wires [")
	for w, i in s.wires {
		if i > 0 do strings.write_string(&b, (i % 4 == 0) ? "\n         " : " ")
		fmt.sbprintf(&b, "[%d %d %d %d]", w.a.x, w.a.y, w.b.x, w.b.y)
	}
	strings.write_string(&b, "]\n :flags [")
	for f, i in s.flags {
		if i > 0 do strings.write_string(&b, "\n         ")
		fmt.sbprintf(&b, "{{:name %s :at [%d %d]", edn_quoted(f.name), f.pos.x, f.pos.y)
		if f.rot != 0 do fmt.sbprintf(&b, " :rot %d", int(f.rot) * 90)
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, "]\n :texts [")
	for t, i in s.texts {
		if i > 0 do strings.write_string(&b, "\n         ")
		fmt.sbprintf(&b, "{{:at [%d %d] :text %s", t.pos.x, t.pos.y, edn_quoted(t.text))
		if t.directive do strings.write_string(&b, " :directive true")
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, "]")
	if len(s.waves) > 0 do fmt.sbprintf(&b, "\n :waves %s", s.waves)
	if len(s.embedded) + len(s.embedded_sym) > 0 {
		strings.write_string(&b, "\n ;; copies of the models and symbols this schematic uses, so that it simulates on any\n ;; computer with spicy (used before the models of the computer that opens it; refreshed on every save, keeping\n ;; the copies; :schematic :embed-models in settings.edn)")
		strings.write_string(&b, "\n :embedded {:models [")
		for e, i in s.embedded {
			if i > 0 do strings.write_string(&b, "\n                     ")
			fmt.sbprintf(&b, "{{:name %s :from %s\n                      :text %s}", edn_quoted(e.name), edn_quoted(e.from), edn_quoted(e.text))
		}
		strings.write_string(&b, "]\n            :symbols [")
		for t, i in s.embedded_sym {
			if i > 0 do strings.write_string(&b, "\n                      ")
			strings.write_string(&b, t)
		}
		strings.write_string(&b, "]}")
	}
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

@(private = "file")
edn_p :: proc(m: Edn, key: string) -> P {
	v, ok := edn_get(m, key)
	if !ok || !edn_is_coll(v) || len(v.items) < 2 do return {}
	return {i32(math.round(edn_num(v.items[0]))), i32(math.round(edn_num(v.items[1])))}
}

@(private = "file")
edn_rot :: proc(m: Edn) -> u8 {
	r, ok := edn_f64(m, "rot")
	if !ok do return 0
	q := int(math.round(r / 90))
	return u8(((q % 4) + 4) % 4)
}

sch_from_edn :: proc(text: string) -> (s: Schematic, err: string) {
	v, perr := edn_parse(text, context.temp_allocator)
	if len(perr) > 0 do return {}, perr
	if v.kind != .Map || !edn_has(v, "spicy-schematic") do return {}, "not a spicy schematic (no :spicy-schematic key)"
	s.comps = make([dynamic]Comp)
	s.wires = make([dynamic]Wire)
	s.flags = make([dynamic]Flag)
	s.texts = make([dynamic]Text)
	s.simulator = strings.clone(edn_str(v, "simulator"))
	if cv, ok := edn_get(v, "components"); ok && edn_is_coll(cv) {
		for m in cv.items {
			c := Comp{
				sym = strings.clone(edn_str(m, "symbol")),
				ref = strings.clone(edn_str(m, "ref")),
				value = strings.clone(edn_str(m, "value")),
				pos = edn_p(m, "at"),
				rot = edn_rot(m),
				mirror = edn_bool(m, "mirror"),
				attrs = make([dynamic]Attr),
			}
			if av, ok2 := edn_get(m, "attrs"); ok2 && av.kind == .Map {
				for i := 0; i + 1 < len(av.items); i += 2 {
					append(&c.attrs, Attr{strings.clone(av.items[i].s), strings.clone(edn_str_of(av.items[i + 1]))})
				}
			}
			append(&s.comps, c)
		}
	}
	if wv, ok := edn_get(v, "wires"); ok && edn_is_coll(wv) {
		for w in wv.items {
			if !edn_is_coll(w) || len(w.items) < 4 do continue
			n :: proc(e: Edn) -> i32 {return i32(math.round(edn_num(e)))}
			append(&s.wires, Wire{a = {n(w.items[0]), n(w.items[1])}, b = {n(w.items[2]), n(w.items[3])}})
		}
	}
	if fv, ok := edn_get(v, "flags"); ok && edn_is_coll(fv) {
		for m in fv.items do append(&s.flags, Flag{name = strings.clone(edn_str(m, "name")), pos = edn_p(m, "at"), rot = edn_rot(m)})
	}
	if tv, ok := edn_get(v, "texts"); ok && edn_is_coll(tv) {
		for m in tv.items do append(&s.texts, Text{pos = edn_p(m, "at"), text = strings.clone(edn_str(m, "text")), directive = edn_bool(m, "directive")})
	}
	if wv, ok := edn_get(v, "waves"); ok && wv.kind == .Map {
		s.waves = strings.clone(edn_to_string(wv))
	}
	s.embedded = make([dynamic]Embedded_Model)
	s.embedded_sym = make([dynamic]string)
	if ev, ok := edn_get(v, "embedded"); ok && ev.kind == .Map {
		if mv, ok2 := edn_get(ev, "models"); ok2 && edn_is_coll(mv) {
			for m in mv.items {
				t := edn_str(m, "text")
				if len(t) == 0 do continue
				append(&s.embedded, Embedded_Model{strings.clone(lower(edn_str(m, "name"))), strings.clone(edn_str(m, "from")), strings.clone(t)})
			}
		}
		if sv, ok2 := edn_get(ev, "symbols"); ok2 && edn_is_coll(sv) {
			for m in sv.items do if m.kind == .Map do append(&s.embedded_sym, strings.clone(edn_to_string(m)))
		}
	}
	return s, ""
}

edn_str_of :: proc(v: Edn) -> string {
	#partial switch v.kind {
	case .String, .Keyword, .Symbol: return v.s
	case .Int: return fmt.tprintf("%d", v.i)
	case .Float: return fmt.tprintf("%v", v.f)
	case .Bool: return "true" if v.b else "false"
	}
	return ""
}

sch_clone :: proc(s: ^Schematic) -> Schematic {
	r, _ := sch_from_edn(sch_to_edn(s))
	return r
}

// Bounding box of everything (schematic units).
sch_bounds :: proc(s: ^Schematic) -> (lo, hi: [2]f32, ok: bool) {
	lo = {1e9, 1e9}
	hi = {-1e9, -1e9}
	add :: proc(lo, hi: ^[2]f32, p: [2]f32) {
		lo.x = min(lo.x, p.x); lo.y = min(lo.y, p.y)
		hi.x = max(hi.x, p.x); hi.y = max(hi.y, p.y)
	}
	for &c in s.comps {
		sym := symbol_find(c.sym)
		if sym == nil do continue
		a, b := comp_bounds(&c, sym)
		add(&lo, &hi, a); add(&lo, &hi, b)
		ok = true
	}
	for w in s.wires {add(&lo, &hi, pf(w.a)); add(&lo, &hi, pf(w.b)); ok = true}
	for f in s.flags {add(&lo, &hi, pf(f.pos) - 16); add(&lo, &hi, pf(f.pos) + 16); ok = true}
	for t in s.texts {
		lines := split_lines(t.text)
		w: f32 = 0
		for l in lines do w = max(w, f32(len(l)) * 8)
		add(&lo, &hi, pf(t.pos))
		add(&lo, &hi, pf(t.pos) + {w, f32(len(lines)) * 18})
		ok = true
	}
	return
}
