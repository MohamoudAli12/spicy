package spicy

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"

// SPICE raw files (ngspice, Xyce, VACASK): binary or ASCII, real or complex, several
// plots one after the other.

Vec :: struct {
	name: string,
	unit: string, // "V", "A", "s", "Hz", ""
	re:   []f64,
	im:   []f64, // nil for real plots
}

Plot :: struct {
	title:   string,
	name:    string, // "Transient Analysis"
	file:    string,
	complex: bool,
	vecs:    [dynamic]Vec,
	npoints: int,
}

plot_free :: proc(p: ^Plot) {
	delete(p.title); delete(p.name); delete(p.file)
	for v in p.vecs {
		delete(v.name); delete(v.unit); delete(v.re)
		if v.im != nil do delete(v.im)
	}
	delete(p.vecs)
	p^ = {}
}

// A plot the viewer lists: curves over a sweep. A single value (an operating point, the
// integrated noise) has no curve to draw, so it is not listed.
plot_listed :: proc(p: ^Plot) -> bool {
	return p.npoints > 1 && len(p.vecs) > 1
}

plot_kind :: proc(p: ^Plot) -> string {
	n := lower(p.name)
	// a .step run labels the plot with its value: " [R=2k]", which says nothing of the analysis
	if i := strings.index(n, " ["); i >= 0 do n = n[:i]
	switch {
	case strings.contains(n, "transient"): return "tran"
	// "dc" first: ngspice's "DC transfer characteristic" has an "ac" in it
	case strings.contains(n, "dc"): return "dc"
	case strings.contains(n, "ac"): return "ac"
	case strings.contains(n, "operating"): return "op"
	case strings.contains(n, "noise"): return "noise"
	}
	return "other"
}

vec_find :: proc(p: ^Plot, name: string) -> ^Vec {
	for &v in p.vecs do if strings.equal_fold(v.name, name) do return &v
	return nil
}

@(private = "file")
guess_unit :: proc(name, typ: string) -> string {
	switch lower(typ) {
	case "voltage": return "V"
	case "current": return "A"
	case "time": return "s"
	case "frequency": return "Hz"
	}
	n := lower(name)
	switch {
	case n == "time": return "s"
	case n == "frequency": return "Hz"
	case strings.has_prefix(n, "i(") || strings.contains(n, ":flow(") || strings.has_suffix(n, ".i") || strings.has_prefix(n, "i") && strings.contains(n, "#branch"): return "A"
	case strings.has_prefix(n, "v(") || lower(typ) == "notype": return "V"
	}
	return ""
}

// Reads every plot of a raw file. Strings and arrays use context.allocator.
raw_read :: proc(path: string) -> (plots: [dynamic]Plot, err: string) {
	data, ok := read_bytes(path, context.temp_allocator)
	if !ok do return nil, fmt.tprintf("cannot read %s", path)
	return raw_parse(data, path)
}

raw_parse :: proc(data: []u8, path: string) -> (plots: [dynamic]Plot, err: string) {
	plots = make([dynamic]Plot)
	pos := 0
	for pos < len(data) {
		// skip blank lines between plots
		for pos < len(data) && (data[pos] == '\n' || data[pos] == '\r' || data[pos] == ' ') do pos += 1
		if pos >= len(data) do break
		p := Plot{file = strings.clone(path), vecs = make([dynamic]Vec)}
		nvars, npoints := 0, 0
		binary := false
		header_ok := false
		names := make([dynamic][2]string, context.temp_allocator)
		// header lines
		for pos < len(data) {
			e := pos
			for e < len(data) && data[e] != '\n' do e += 1
			line := strings.trim_right(string(data[pos:e]), "\r")
			pos = min(e + 1, len(data))
			colon := strings.index_byte(line, ':')
			key := lower(strings.trim_space(line[:colon])) if colon >= 0 else ""
			val := strings.trim_space(line[colon + 1:]) if colon >= 0 else ""
			switch key {
			case "title": p.title = strings.clone(val)
			case "plotname": p.name = strings.clone(val)
			case "flags":
				fl := lower(val)
				p.complex = strings.contains(fl, "complex")
			case "no. variables": nvars, _ = strconv.parse_int(val)
			case "no. points": npoints, _ = strconv.parse_int(val)
			case "variables":
				for k := 0; k < nvars && pos < len(data); k += 1 {
					e2 := pos
					for e2 < len(data) && data[e2] != '\n' do e2 += 1
					vl := strings.trim_right(string(data[pos:e2]), "\r")
					pos = min(e2 + 1, len(data))
					f := strings.fields(vl, context.temp_allocator)
					if len(f) >= 2 {
						typ := f[2] if len(f) >= 3 else ""
						append(&names, [2]string{f[1], typ})
					}
				}
			case "binary":
				binary = true
				header_ok = true
			case "values":
				header_ok = true
			}
			if header_ok do break
		}
		if !header_ok || nvars == 0 {
			plot_free(&p)
			if len(plots) == 0 do return plots, fmt.tprintf("%s: not a raw file", path)
			break
		}
		if len(names) != nvars {
			plot_free(&p)
			return plots, fmt.tprintf("%s: %d variables listed, %d expected", path, len(names), nvars)
		}
		stride := nvars * (2 if p.complex else 1)
		if binary {
			avail := (len(data) - pos) / (8 * stride)
			npoints = min(npoints, avail)
		}
		for n in names {
			v := Vec{name = strings.clone(n[0]), unit = strings.clone(guess_unit(n[0], n[1]))}
			v.re = make([]f64, npoints)
			if p.complex do v.im = make([]f64, npoints)
			append(&p.vecs, v)
		}
		p.npoints = npoints
		if binary {
			for i in 0 ..< npoints {
				base := pos + i * stride * 8
				for k in 0 ..< nvars {
					if p.complex {
						p.vecs[k].re[i] = read_f64(data, base + 16 * k)
						p.vecs[k].im[i] = read_f64(data, base + 16 * k + 8)
					} else {
						p.vecs[k].re[i] = read_f64(data, base + 8 * k)
					}
				}
			}
			pos += npoints * stride * 8
		} else {
			// ASCII: "idx <tab> value" then one value per line; complex "re,im"
			for i in 0 ..< npoints {
				for k in 0 ..< nvars {
					// next non-empty line
					for pos < len(data) && (data[pos] == '\n' || data[pos] == '\r') do pos += 1
					e := pos
					for e < len(data) && data[e] != '\n' do e += 1
					line := strings.trim_space(string(data[pos:e]))
					pos = min(e + 1, len(data))
					f := strings.fields(line, context.temp_allocator)
					if len(f) == 0 do continue
					tok := f[len(f) - 1]
					if p.complex {
						c := strings.index_byte(tok, ',')
						re_s, im_s := tok, "0"
						if c >= 0 do re_s, im_s = tok[:c], tok[c + 1:]
						p.vecs[k].re[i], _ = strconv.parse_f64(re_s)
						p.vecs[k].im[i], _ = strconv.parse_f64(im_s)
					} else {
						p.vecs[k].re[i], _ = strconv.parse_f64(tok)
					}
				}
			}
		}
		append(&plots, p)
	}
	return plots, ""
}

@(private = "file")
read_f64 :: proc(d: []u8, off: int) -> f64 {
	if off + 8 > len(d) do return 0
	v: f64
	mem.copy(&v, &d[off], 8)
	return v
}
