package spicy

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// Minimal EDN reader / writer (enough for harness documents, parts libraries and prefs).

Edn_Kind :: enum u8 {
	Nil,
	Bool,
	Int,
	Float,
	String,
	Keyword,
	Symbol,
	Char,
	Vector,
	List,
	Map,
	Set,
}

Edn :: struct {
	kind:  Edn_Kind,
	b:     bool,
	i:     i64,
	f:     f64,
	s:     string,
	items: [dynamic]Edn, // vector/list/set elements, map: k0 v0 k1 v1 ...
	start: int, // span in the source text
	end:   int,
}

Edn_Parser :: struct {
	src:       string,
	pos:       int,
	err:       string,
	allocator: mem_Allocator,
}

mem_Allocator :: runtime.Allocator

edn_is_num :: proc(v: Edn) -> bool {return v.kind == .Int || v.kind == .Float}
edn_num :: proc(v: Edn) -> f64 {
	#partial switch v.kind {
	case .Int: return f64(v.i)
	case .Float: return v.f
	}
	return 0
}

edn_is_coll :: proc(v: Edn) -> bool {return v.kind == .Vector || v.kind == .List}

// Map lookup by keyword name (without ':').
edn_get :: proc(m: Edn, key: string) -> (Edn, bool) {
	if m.kind != .Map do return {}, false
	for i := 0; i + 1 < len(m.items); i += 2 {
		k := m.items[i]
		if (k.kind == .Keyword || k.kind == .String) && k.s == key do return m.items[i + 1], true
	}
	return {}, false
}

edn_has :: proc(m: Edn, key: string) -> bool {
	v, ok := edn_get(m, key)
	return ok && v.kind != .Nil
}

edn_str :: proc(m: Edn, key: string, default := "") -> string {
	v, ok := edn_get(m, key)
	if !ok do return default
	#partial switch v.kind {
	case .String, .Keyword, .Symbol: return v.s
	case .Int: return fmt.aprintf("%d", v.i)
	case .Float: return fmt.aprintf("%v", v.f)
	case .Nil: return default
	}
	return default
}

edn_f64 :: proc(m: Edn, key: string) -> (f64, bool) {
	v, ok := edn_get(m, key)
	if !ok || !edn_is_num(v) do return 0, false
	return edn_num(v), true
}

edn_bool :: proc(m: Edn, key: string, default := false) -> bool {
	v, ok := edn_get(m, key)
	if !ok do return default
	if v.kind == .Bool do return v.b
	if v.kind == .Nil do return false
	return true
}

edn_parse_all :: proc(src: string, allocator := context.allocator) -> (forms: [dynamic]Edn, err: string) {
	p := Edn_Parser{src = src, allocator = allocator}
	forms = make([dynamic]Edn, allocator)
	for {
		edn_skip(&p)
		if p.pos >= len(p.src) do break
		v, ok := edn_read(&p)
		if !ok {
			return forms, p.err
		}
		if v.kind == .Symbol && v.s == "#_discard" do continue
		append(&forms, v)
	}
	return forms, ""
}

edn_parse :: proc(src: string, allocator := context.allocator) -> (Edn, string) {
	forms, err := edn_parse_all(src, allocator)
	if len(err) > 0 do return {}, err
	if len(forms) == 0 do return {}, "empty input"
	return forms[0], ""
}

@(private = "file")
edn_skip :: proc(p: ^Edn_Parser) {
	for p.pos < len(p.src) {
		c := p.src[p.pos]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == ',' || c == '\f' {
			p.pos += 1
		} else if c == ';' {
			for p.pos < len(p.src) && p.src[p.pos] != '\n' do p.pos += 1
		} else if c == '#' && p.pos + 1 < len(p.src) && p.src[p.pos + 1] == '_' {
			p.pos += 2
			edn_skip(p)
			_, _ = edn_read(p)
		} else if c == '#' && p.pos + 1 < len(p.src) && p.src[p.pos + 1] == '!' {
			for p.pos < len(p.src) && p.src[p.pos] != '\n' do p.pos += 1
		} else {
			break
		}
	}
}

@(private = "file")
is_delim :: proc(c: u8) -> bool {
	switch c {
	case ' ', '\t', '\n', '\r', ',', '(', ')', '[', ']', '{', '}', '"', ';', '\f': return true
	}
	return false
}

@(private = "file")
edn_token :: proc(p: ^Edn_Parser) -> string {
	start := p.pos
	for p.pos < len(p.src) && !is_delim(p.src[p.pos]) do p.pos += 1
	return p.src[start:p.pos]
}

@(private = "file")
edn_fail :: proc(p: ^Edn_Parser, msg: string) -> (Edn, bool) {
	line := 1 + strings.count(p.src[:min(p.pos, len(p.src))], "\n")
	p.err = fmt.tprintf("%s (line %d)", msg, line)
	return {}, false
}

@(private = "file")
edn_read_seq :: proc(p: ^Edn_Parser, close: u8, kind: Edn_Kind, start: int) -> (Edn, bool) {
	v := Edn{kind = kind, start = start}
	v.items = make([dynamic]Edn, p.allocator)
	for {
		edn_skip(p)
		if p.pos >= len(p.src) do return edn_fail(p, "unexpected end of input")
		if p.src[p.pos] == close {
			p.pos += 1
			break
		}
		x, ok := edn_read(p)
		if !ok do return {}, false
		append(&v.items, x)
	}
	if kind == .Map && len(v.items) % 2 != 0 do return edn_fail(p, "map with odd number of forms")
	v.end = p.pos
	return v, true
}

edn_read :: proc(p: ^Edn_Parser) -> (Edn, bool) {
	edn_skip(p)
	if p.pos >= len(p.src) do return edn_fail(p, "unexpected end of input")
	start := p.pos
	c := p.src[p.pos]
	switch c {
	case '[':
		p.pos += 1
		return edn_read_seq(p, ']', .Vector, start)
	case '(':
		p.pos += 1
		return edn_read_seq(p, ')', .List, start)
	case '{':
		p.pos += 1
		return edn_read_seq(p, '}', .Map, start)
	case ']', ')', '}':
		return edn_fail(p, fmt.tprintf("unexpected '%c'", c))
	case '#':
		if p.pos + 1 < len(p.src) && p.src[p.pos + 1] == '{' {
			p.pos += 2
			return edn_read_seq(p, '}', .Set, start)
		}
		// tagged literal: #tag value -> value
		p.pos += 1
		_ = edn_token(p)
		v, ok := edn_read(p)
		v.start = start
		return v, ok
	case '"':
		p.pos += 1
		b := strings.builder_make(p.allocator)
		for {
			if p.pos >= len(p.src) do return edn_fail(p, "unterminated string")
			ch := p.src[p.pos]
			if ch == '"' {
				p.pos += 1
				break
			}
			if ch == '\\' && p.pos + 1 < len(p.src) {
				e := p.src[p.pos + 1]
				p.pos += 2
				switch e {
				case 'n': strings.write_byte(&b, '\n')
				case 't': strings.write_byte(&b, '\t')
				case 'r': strings.write_byte(&b, '\r')
				case 'b': strings.write_byte(&b, '\b')
				case 'f': strings.write_byte(&b, '\f')
				case '"': strings.write_byte(&b, '"')
				case '\\': strings.write_byte(&b, '\\')
				case 'u':
					if p.pos + 4 <= len(p.src) {
						cp, ok := strconv.parse_u64_of_base(p.src[p.pos:p.pos + 4], 16)
						if ok do strings.write_rune(&b, rune(cp))
						p.pos += 4
					}
				case: strings.write_byte(&b, e)
				}
				continue
			}
			strings.write_byte(&b, ch)
			p.pos += 1
		}
		return Edn{kind = .String, s = strings.to_string(b), start = start, end = p.pos}, true
	case ':':
		p.pos += 1
		t := edn_token(p)
		if len(t) == 0 do return edn_fail(p, "empty keyword")
		return Edn{kind = .Keyword, s = strings.clone(t, p.allocator), start = start, end = p.pos}, true
	case '\\':
		p.pos += 1
		// character literal
		if p.pos < len(p.src) {
			r, size := utf8.decode_rune_in_string(p.src[p.pos:])
			p.pos += size
			for p.pos < len(p.src) && !is_delim(p.src[p.pos]) do p.pos += 1
			name := p.src[start + 1:p.pos]
			s: string
			switch name {
			case "newline": s = "\n"
			case "space": s = " "
			case "tab": s = "\t"
			case "return": s = "\r"
			case: s = utf8.runes_to_string({r}, p.allocator)
			}
			return Edn{kind = .Char, s = s, start = start, end = p.pos}, true
		}
		return edn_fail(p, "bad character literal")
	}
	t := edn_token(p)
	if len(t) == 0 {
		p.pos += 1
		return edn_fail(p, fmt.tprintf("unexpected '%c'", c))
	}
	v := Edn{start = start, end = p.pos}
	first := t[0]
	if (first >= '0' && first <= '9') || ((first == '-' || first == '+') && len(t) > 1 && t[1] >= '0' && t[1] <= '9') {
		num := t
		if strings.has_suffix(num, "N") || strings.has_suffix(num, "M") do num = num[:len(num) - 1]
		if strings.contains_any(num, ".eE") {
			f, ok := strconv.parse_f64(num)
			if !ok do return edn_fail(p, fmt.tprintf("bad number %s", t))
			v.kind = .Float
			v.f = f
		} else if strings.contains(num, "/") {
			parts := strings.split(num, "/", context.temp_allocator)
			a, ok1 := strconv.parse_f64(parts[0])
			b, ok2 := strconv.parse_f64(parts[1])
			if !ok1 || !ok2 || b == 0 do return edn_fail(p, fmt.tprintf("bad number %s", t))
			v.kind = .Float
			v.f = a / b
		} else {
			i, ok := strconv.parse_i64(num)
			if !ok {
				f, ok2 := strconv.parse_f64(num)
				if !ok2 do return edn_fail(p, fmt.tprintf("bad number %s", t))
				v.kind = .Float
				v.f = f
			} else {
				v.kind = .Int
				v.i = i
			}
		}
		return v, true
	}
	switch t {
	case "nil": v.kind = .Nil
	case "true": v.kind = .Bool; v.b = true
	case "false": v.kind = .Bool; v.b = false
	case "##Inf": v.kind = .Float; v.f = math.inf_f64(1)
	case "##-Inf": v.kind = .Float; v.f = math.inf_f64(-1)
	case "##NaN": v.kind = .Float; v.f = math.nan_f64()
	case:
		v.kind = .Symbol
		v.s = strings.clone(t, p.allocator)
	}
	return v, true
}

// ---------------------------------------------------------------------------
// Writing

edn_quote :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for r in s {
		switch r {
		case '"': strings.write_string(b, "\\\"")
		case '\\': strings.write_string(b, "\\\\")
		case '\n': strings.write_string(b, "\\n")
		case '\t': strings.write_string(b, "\\t")
		case '\r': strings.write_string(b, "\\r")
		case: strings.write_rune(b, r)
		}
	}
	strings.write_byte(b, '"')
}

edn_quoted :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	edn_quote(&b, s)
	return strings.to_string(b)
}

// EDN number text: whole floats keep ".0" so they read back as doubles.
edn_float_str :: proc(f: f64) -> string {
	if f == math.round(f) && abs(f) < 1e15 do return fmt.tprintf("%d.0", i64(f))
	s := fmt.tprintf("%.10f", f)
	s = strings.trim_right(s, "0")
	if strings.has_suffix(s, ".") do s = tcat(s, "0")
	return s
}

edn_write :: proc(b: ^strings.Builder, v: Edn) {
	switch v.kind {
	case .Nil: strings.write_string(b, "nil")
	case .Bool: strings.write_string(b, "true" if v.b else "false")
	case .Int: fmt.sbprintf(b, "%d", v.i)
	case .Float: strings.write_string(b, edn_float_str(v.f))
	case .String: edn_quote(b, v.s)
	case .Keyword: strings.write_byte(b, ':'); strings.write_string(b, v.s)
	case .Symbol: strings.write_string(b, v.s)
	case .Char:
		switch v.s {
		case "\n": strings.write_string(b, "\\newline")
		case " ": strings.write_string(b, "\\space")
		case "\t": strings.write_string(b, "\\tab")
		case: strings.write_byte(b, '\\'); strings.write_string(b, v.s)
		}
	case .Vector, .List, .Set, .Map:
		open, close := "[", "]"
		#partial switch v.kind {
		case .List: open, close = "(", ")"
		case .Set: open, close = "#{", "}"
		case .Map: open, close = "{", "}"
		}
		strings.write_string(b, open)
		for x, i in v.items {
			if i > 0 do strings.write_byte(b, ' ')
			edn_write(b, x)
		}
		strings.write_string(b, close)
	}
}

edn_to_string :: proc(v: Edn, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	edn_write(&b, v)
	return strings.to_string(b)
}

// Constructors (temp allocator by default).
ek :: proc(s: string) -> Edn {return Edn{kind = .Keyword, s = s}}
es :: proc(s: string) -> Edn {return Edn{kind = .String, s = s}}
ef :: proc(f: f64) -> Edn {return Edn{kind = .Float, f = f}}
ei :: proc(i: i64) -> Edn {return Edn{kind = .Int, i = i}}
eb :: proc(b: bool) -> Edn {return Edn{kind = .Bool, b = b}}
enil :: proc() -> Edn {return Edn{kind = .Nil}}

evec :: proc(xs: ..Edn) -> Edn {
	v := Edn{kind = .Vector}
	v.items = make([dynamic]Edn, 0, len(xs), context.temp_allocator)
	append(&v.items, ..xs)
	return v
}

emap :: proc() -> Edn {
	v := Edn{kind = .Map}
	v.items = make([dynamic]Edn, context.temp_allocator)
	return v
}

emap_put :: proc(m: ^Edn, key: string, val: Edn) {
	append(&m.items, ek(key), val)
}


// Deep copy of v (strings and collections) made with context.allocator.
edn_clone :: proc(v: Edn) -> Edn {
	r := v
	r.s = strings.clone(v.s)
	if v.items != nil {
		r.items = make([dynamic]Edn, 0, len(v.items))
		for x in v.items do append(&r.items, edn_clone(x))
	}
	return r
}
