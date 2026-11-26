package spicy

import "core:fmt"
import "core:math"
import os "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

// Helpers shared by the whole app (taken from loomer / zapped).

// ---------------------------------------------------------------------------
// Engineering notation

// Parses "4.7u", "100k", "1meg", "2.2nF", "1e-6", "3.3V" ...
// SPICE style: suffixes are case-insensitive, "m" = milli, "meg" = mega.
parse_eng :: proc(s: string) -> (f64, bool) {
	t := strings.trim_space(s)
	if len(t) == 0 do return 0, false
	i := 0
	if i < len(t) && (t[i] == '+' || t[i] == '-') do i += 1
	digits := false
	for i < len(t) && (t[i] >= '0' && t[i] <= '9') {i += 1; digits = true}
	if i < len(t) && t[i] == '.' {
		i += 1
		for i < len(t) && (t[i] >= '0' && t[i] <= '9') {i += 1; digits = true}
	}
	if !digits do return 0, false
	if i < len(t) && (t[i] == 'e' || t[i] == 'E') {
		j := i + 1
		if j < len(t) && (t[j] == '+' || t[j] == '-') do j += 1
		if j < len(t) && t[j] >= '0' && t[j] <= '9' {
			for j < len(t) && t[j] >= '0' && t[j] <= '9' do j += 1
			i = j
		}
	}
	v, ok := strconv.parse_f64(t[:i])
	if !ok do return 0, false
	rest := strings.trim_space(t[i:])
	if len(rest) == 0 do return v, true
	low := strings.to_lower(rest, context.temp_allocator)
	mult := 1.0
	switch {
	case strings.has_prefix(low, "meg"): mult = 1e6
	case strings.has_prefix(low, "mil"): mult = 25.4e-6
	case low[0] == 't': mult = 1e12
	case low[0] == 'g': mult = 1e9
	case low[0] == 'k': mult = 1e3
	case low[0] == 'm': mult = 1e-3
	case low[0] == 'u': mult = 1e-6
	case strings.has_prefix(rest, "µ") || strings.has_prefix(rest, "μ"): mult = 1e-6
	case low[0] == 'n': mult = 1e-9
	case low[0] == 'p': mult = 1e-12
	case low[0] == 'f': mult = 1e-15
	case low[0] == '%': mult = 0.01
	}
	return v * mult, true
}

ENG_PREFIX := [?]string{"a", "f", "p", "n", "µ", "m", "", "k", "M", "G", "T"}

// Formats with an SI prefix: 4.7 µH
fmt_eng :: proc(v: f64, unit := "", digits := 4, allocator := context.temp_allocator) -> string {
	if math.is_nan(v) do return "NaN"
	if math.is_inf(v) do return "∞" if v > 0 else "-∞"
	if v == 0 do return fmt.aprintf("0 %s", unit, allocator = allocator) if len(unit) > 0 else strings.clone("0", allocator)
	a := abs(v)
	e := int(math.floor(math.log10(a) / 3))
	e = clamp(e, -6, 4)
	// dB, dBV, dBA, °: no prefix. A slope of them (dB/Hz, °/Hz) is an ordinary unit and has one.
	log_unit := (strings.has_prefix(unit, "dB") || unit == "°") && !strings.contains(unit, "/") && !strings.contains(unit, "·")
	if log_unit do e = 0
	m := v / math.pow(10, f64(e * 3))
	am := abs(m)
	dec := digits - 1
	if am >= 100 do dec = digits - 3
	else if am >= 10 do dec = digits - 2
	dec = max(dec, 0)
	if e < 4 && !log_unit && math.round(am * math.pow(10, f64(dec))) >= 1000 * math.pow(10, f64(dec)) {
		e += 1
		m = v / math.pow(10, f64(e * 3))
		dec = max(digits - 1, 0)
	}
	num := fmt.tprintf("%.*f", dec, m)
	if strings.contains(num, ".") {
		num = strings.trim_right(num, "0")
		num = strings.trim_right(num, ".")
	}
	p := ENG_PREFIX[e + 6]
	if len(unit) == 0 && len(p) == 0 do return strings.clone(num, allocator)
	return fmt.aprintf("%s %s%s", num, p, unit, allocator = allocator)
}

// Compact SPICE form ("4.7u", "1Meg") that parse_eng reads back.
fmt_spice :: proc(v: f64, allocator := context.temp_allocator) -> string {
	if v == 0 do return strings.clone("0", allocator)
	a := abs(v)
	e := int(math.floor(math.log10(a) / 3))
	e = clamp(e, -5, 4)
	m := v / math.pow(10, f64(e * 3))
	num := fmt.tprintf("%.6g", m)
	PFX := [?]string{"f", "p", "n", "u", "m", "", "k", "Meg", "G", "T"}
	return fmt.aprintf("%s%s", num, PFX[e + 5], allocator = allocator)
}

// ---------------------------------------------------------------------------
// Strings

tcat :: proc(parts: ..string) -> string {return strings.concatenate(parts, context.temp_allocator)}
lower :: proc(s: string) -> string {return strings.to_lower(s, context.temp_allocator)}
upper :: proc(s: string) -> string {return strings.to_upper(s, context.temp_allocator)}
is_blank :: proc(s: string) -> bool {return len(strings.trim_space(s)) == 0}
itoa :: proc(i: int) -> string {return fmt.tprintf("%d", i)}

split_lines :: proc(s: string) -> []string {
	t, _ := strings.replace_all(s, "\r\n", "\n", context.temp_allocator)
	return strings.split(t, "\n", context.temp_allocator)
}

one_line :: proc(s: string) -> string {
	// Windows ends lines with \r\n: neither belongs in a one-line field
	t, _ := strings.replace_all(s, "\r\n", " ", context.temp_allocator)
	t, _ = strings.replace_all(t, "\n", " ", context.temp_allocator)
	t, _ = strings.replace_all(t, "\r", " ", context.temp_allocator)
	return strings.trim_right_space(t)
}

// Replaces s (a heap string) with a heap copy of v.
set_str :: proc(s: ^string, v: string) {
	if s^ == v do return
	old := s^
	s^ = strings.clone(v)
	delete(old)
}

clampf :: proc(v, lo, hi: f64) -> f64 {return max(lo, min(hi, v))}
clampf32 :: proc(v, lo, hi: f32) -> f32 {return max(lo, min(hi, v))}

// ---------------------------------------------------------------------------
// Files & paths

read_text :: proc(path: string, allocator := context.allocator) -> (string, bool) {
	data, err := os.read_entire_file_from_path(path, allocator)
	return string(data), err == nil
}

read_bytes :: proc(path: string, allocator := context.allocator) -> ([]u8, bool) {
	data, err := os.read_entire_file_from_path(path, allocator)
	return data, err == nil
}

write_text :: proc(path: string, text: string) -> bool {
	dir := filepath.dir(path)
	if len(dir) > 0 && !os.exists(dir) do os.make_directory_all(dir)
	return os.write_entire_file_from_bytes(path, transmute([]u8)text) == nil
}

file_exists :: proc(path: string) -> bool {return len(path) > 0 && os.is_file(path)}
dir_exists :: proc(path: string) -> bool {return len(path) > 0 && os.is_dir(path)}
base_name :: proc(path: string) -> string {return filepath.base(path)}
dir_name :: proc(path: string) -> string {return filepath.dir(path)}
// The folder of a file ("" for no file), temporary.
dir_of :: proc(path: string) -> string {return filepath.dir(path) if len(path) > 0 else ""}
stem_name :: proc(path: string) -> string {return filepath.stem(path)}
path_join :: proc(parts: ..string) -> string {
	r, _ := filepath.join(parts, context.temp_allocator)
	return r
}
file_ext_lower :: proc(path: string) -> string {return lower(strings.trim_prefix(filepath.ext(path), "."))}
with_ext :: proc(path, ext: string) -> string {
	e := filepath.ext(path)
	return tcat(path[:len(path) - len(e)], ".", ext)
}
is_abs :: proc(path: string) -> bool {return filepath.is_abs(path)}
home_dir :: proc() -> string {
	h, err := os.user_home_dir(context.temp_allocator)
	if err != nil do return "."
	return h
}
cwd :: proc() -> string {
	d, err := os.get_working_directory(context.temp_allocator)
	if err != nil do return "."
	return d
}
abs_path :: proc(path: string) -> string {
	if len(path) == 0 do return path
	r, err := filepath.abs(path, context.temp_allocator)
	if err != nil do return path
	return r
}

// Modification time (ns) of a file, 0 when missing.
file_mtime :: proc(path: string) -> i64 {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil do return 0
	return fi.modification_time._nsec
}

// Directory listing: (dirs, files) sorted, names only; exts empty = all files.
list_dir :: proc(dir: string, exts: []string, show_hidden := false) -> (dirs: [dynamic]string, files: [dynamic]string) {
	dirs = make([dynamic]string, context.temp_allocator)
	files = make([dynamic]string, context.temp_allocator)
	infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil do return
	for fi in infos {
		if !show_hidden && len(fi.name) > 0 && fi.name[0] == '.' do continue
		if fi.type == .Directory {
			append(&dirs, strings.clone(fi.name, context.temp_allocator))
		} else {
			e := file_ext_lower(fi.name)
			keep := len(exts) == 0
			for x in exts do if x == e do keep = true
			if keep do append(&files, strings.clone(fi.name, context.temp_allocator))
		}
	}
	sort_strings(dirs[:])
	sort_strings(files[:])
	return
}

sort_strings :: proc(a: []string) {
	for i in 1 ..< len(a) {
		j := i
		for j > 0 && lower(a[j - 1]) > lower(a[j]) {
			a[j - 1], a[j] = a[j], a[j - 1]
			j -= 1
		}
	}
}

// Opens a folder or file with the system's default application.
open_external :: proc(target: string) -> bool {
	cmd: []string
	when ODIN_OS == .Windows {
		cmd = {"explorer.exe", target}
	} else when ODIN_OS == .Darwin {
		cmd = {"open", target}
	} else {
		cmd = {"xdg-open", target}
	}
	_, err := os.process_start({command = cmd})
	return err == nil
}

sqrt64 :: proc(x: f64) -> f64 {return math.sqrt(x)}

phase_deg :: proc(re, im: f64) -> f64 {return math.to_degrees(math.atan2(im, re))}
