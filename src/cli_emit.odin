package spicy

import "core:fmt"
import "core:os"
import "core:strings"

// ---------------------------------------------------------------------------
// Machine-readable output (command line, scripts, AI agents): EDN by default, --json for
// JSON, --text for the older human-readable text. Errors go to stderr in the same format, with
// an exit code (EXIT_*).

Out_Fmt :: enum u8 {Edn, Json, Text}
out_fmt: Out_Fmt
out_fmt_given: bool // --edn, --json or --text was on the command line

EXIT_OK :: 0
EXIT_PROBLEMS :: 1 // the command ran, the result is "no": a check found errors, a run failed
EXIT_USAGE :: 2 // wrong arguments
EXIT_FILE :: 3 // a file cannot be read, parsed or written
EXIT_TOOL :: 4 // an outside program (simulator …) is missing or failed to start

@(private = "file")
em: struct {
	b:         strings.Builder,
	n:         [dynamic]int,
	after_key: bool,
}

// Takes --edn / --json / --text out of the arguments.
out_fmt_parse :: proc(args: []string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for a in args {
		switch a {
		case "--edn": out_fmt, out_fmt_given = .Edn, true
		case "--json": out_fmt, out_fmt_given = .Json, true
		case "--text": out_fmt, out_fmt_given = .Text, true
		case: append(&out, a)
		}
	}
	return out[:]
}

em_begin :: proc() {
	em.b = strings.builder_make(context.temp_allocator)
	em.n = make([dynamic]int, context.temp_allocator)
	em.after_key = false
}

// The value written since em_begin.
em_string :: proc() -> string {return strings.to_string(em.b)}

// Prints the value written since em_begin to stdout.
em_print :: proc() {fmt.println(strings.to_string(em.b))}

@(private = "file")
em_sep :: proc() {
	if em.after_key {
		em.after_key = false
		return
	}
	if len(em.n) == 0 do return
	if em.n[len(em.n) - 1] > 0 do strings.write_string(&em.b, ", " if out_fmt == .Json else " ")
	em.n[len(em.n) - 1] += 1
}

em_map :: proc() {em_sep(); strings.write_byte(&em.b, '{'); append(&em.n, 0)}
em_map_end :: proc() {pop(&em.n); strings.write_byte(&em.b, '}')}
em_vec :: proc() {em_sep(); strings.write_byte(&em.b, '['); append(&em.n, 0)}
em_vec_end :: proc() {pop(&em.n); strings.write_byte(&em.b, ']')}

@(private = "file")
em_quoted :: proc(s: string) {
	strings.write_byte(&em.b, '"')
	for ch in s {
		switch ch {
		case '"': strings.write_string(&em.b, "\\\"")
		case '\\': strings.write_string(&em.b, "\\\\")
		case '\n': strings.write_string(&em.b, "\\n")
		case '\r': strings.write_string(&em.b, "\\r")
		case '\t': strings.write_string(&em.b, "\\t")
		case:
			if ch < 0x20 do fmt.sbprintf(&em.b, "\\u%04x", int(ch))
			else do strings.write_rune(&em.b, ch)
		}
	}
	strings.write_byte(&em.b, '"')
}

// A map key: a keyword in EDN (:name), a string in JSON.
em_key :: proc(k: string) {
	em_sep()
	if out_fmt == .Json {
		em_quoted(k)
		strings.write_string(&em.b, ": ")
	} else {
		strings.write_byte(&em.b, ':')
		strings.write_string(&em.b, k)
		strings.write_byte(&em.b, ' ')
	}
	em.after_key = true
}

// A map key that is any text (a vector name such as "V(OUT)"): a string in both formats.
em_skey :: proc(k: string) {
	em_sep()
	em_quoted(k)
	strings.write_string(&em.b, ": " if out_fmt == .Json else " ")
	em.after_key = true
}

em_str :: proc(s: string) {em_sep(); em_quoted(s)}
em_kw :: proc(s: string) {em_sep(); if out_fmt == .Json do em_quoted(s); else {strings.write_byte(&em.b, ':'); strings.write_string(&em.b, s)}}
em_bool :: proc(v: bool) {em_sep(); strings.write_string(&em.b, "true" if v else "false")}
em_nil :: proc() {em_sep(); strings.write_string(&em.b, "null" if out_fmt == .Json else "nil")}
em_int :: proc(v: int) {em_sep(); fmt.sbprintf(&em.b, "%d", v)}
em_num :: proc(v: f64) {
	if v != v || v > 1e308 || v < -1e308 {
		em_nil()
		return
	}
	em_sep()
	fmt.sbprintf(&em.b, "%.10g", v)
}
em_strs :: proc(xs: []string) {em_vec(); for x in xs do em_str(x); em_vec_end()}

// Fails the command: the error on stderr (EDN, JSON or text) and the exit code.
cli_fail :: proc(code: int, kind: string, msg: string, details: []string = nil) -> ! {
	if out_fmt == .Text {
		fmt.eprintln("error:", msg)
		for d in details do fmt.eprintln("  ", d)
	} else {
		em_begin()
		em_map()
		em_key("error")
		em_map()
		em_key("kind"); em_kw(kind)
		em_key("message"); em_str(msg)
		em_key("exit"); em_int(code)
		if len(details) > 0 {em_key("details"); em_strs(details)}
		em_map_end()
		em_map_end()
		fmt.eprintln(em_string())
	}
	os.exit(code)
}

cli_usage :: proc(msg: string) -> ! {cli_fail(EXIT_USAGE, "usage", msg)}
