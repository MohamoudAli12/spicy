package spicy

import "core:fmt"
import "core:strings"

// Repairs of a vendor's SPICE model library at import (File › Import SPICE model…,
// --import-model, --check-model): faults ngspice lets through, often silently losing a value,
// and that stop Xyce and VACASK. Each has one right answer and is repaired when the user says
// so; what would need a guess is only reported (Repair_Kind from Type_Vs_Description on).

Repair_Kind :: enum u8 {
	Comment_Semicolon, // a comment line that starts with ";"
	Inline_Semicolon,  // "+ BF=650;	350;": the text after ";" in a model card
	Simulator_Line,    // ".SIMULATOR DEFAULT"
	Non_Ascii,         // "IBV=100µ", a non-breaking space between a name and its pins
	Glued_Ends,        // "… N=3.00 ).ENDS"
	Run_Together,      // "Inc. … *SYM=HZEN .SUBCKT DI_X 1 2": a header run onto a label line
	Model_After_Ends,  // ".ENDS X" then ".MODEL ZDiode …", the name used by other parts too
	Name_From_Src,     // "*SRC=BZT52C20T;DI_BZT52C20T…" over ".SUBCKT DI_BZT52C20" (a copy's name)
	Local_Model_Name,  // "D1 1 2 SMCJ26A" in a subcircuit whose only model is SMCJ26AQ
	Misspelt_Subckt,   // ".SUBCKET X 1 2"
	Label_Line,        // "Inc. BJTs": text outside .model / .subckt
	Comment_In_Card,   // a comment line between the "+" lines of a card
	Plus_In_Line,      // "RC=0.015  +CJE=250E-12": two lines run together
	Missing_Equals,    // "NE 1.33"
	Duplicate_Param,   // "TR=250u … TR=23.7E-9"
	Unclosed_Paren,    // ".MODEL X NPN (IS=… " with no ")"
	After_Paren,       // text after the card's closing ")"
	Missing_Ends,      // a .SUBCKT with no .ENDS
	Stray_Ends,        // an .ENDS outside a subcircuit
	Numeric_Name,      // ".MODEL 5401 PNP": a number to SPICE
	Duplicate_Card,    // the same card again, unchanged
	Nbv,               // a diode with BV and N≠1 but no NBV
	// to check (not changed)
	Type_Vs_Description,
	Differing_Duplicate,
	Undefined_Model,
	Capacitance_Unit,
	Implausible_N,
}

FIRST_CHECK :: Repair_Kind.Type_Vs_Description

Repair_Item :: struct {
	kind:   Repair_Kind,
	line:   int, // in the original file
	part:   string,
	detail: string,
}

Repair_Report :: struct {
	fixes:  [dynamic]Repair_Item,
	checks: [dynamic]Repair_Item,
}

// What a kind of problem is, and why it matters.
repair_kind_text :: proc(k: Repair_Kind) -> string {
	switch k {
	case .Comment_Semicolon: return "comment lines that start with \";\" (made \"*\" comments)"
	case .Inline_Semicolon: return "\";\" comments inside model cards (removed: Xyce and VACASK stop at them)"
	case .Misspelt_Subckt: return ".SUBCKT misspelt (\".SUBCKET\" made \".SUBCKT\")"
	case .Non_Ascii: return "non-ASCII characters (\"µ\" made \"u\": SPICE reads \"100µ\" as 100; non-breaking spaces made spaces)"
	case .Run_Together: return ".SUBCKT or .MODEL run onto the end of another line (put on its own line)"
	case .Glued_Ends: return ".ENDS on the same line as a card (put on its own line)"
	case .Model_After_Ends: return "models after their subcircuit's .ENDS, under a name other parts use too (moved inside: SPICE gives every part the first)"
	case .Name_From_Src: return "parts named as an earlier part (renamed to the name on their *SRC= line)"
	case .Local_Model_Name: return "elements naming a model their subcircuit lacks (its only unused model of that kind used)"
	case .Simulator_Line: return ".SIMULATOR lines (made comments: no simulator here knows them)"
	case .Label_Line: return "text outside .model and .subckt (made comments: it reads as a circuit element)"
	case .Comment_In_Card: return "comment lines between a card's \"+\" lines (moved before the card)"
	case .Plus_In_Line: return "\"+\" in the middle of a line (removed: ngspice ignores \"+CJE=…\" and so loses the value)"
	case .Missing_Equals: return "parameters without \"=\" (\"NE 1.33\" made \"NE=1.33\")"
	case .Duplicate_Param: return "parameters given twice (the last kept, as PSpice and ngspice do; Xyce stops)"
	case .Unclosed_Paren: return "model cards with an unclosed \"(\" (closed)"
	case .After_Paren: return "text after a card's closing \")\" (removed: a line pasted twice)"
	case .Missing_Ends: return "subcircuits with no .ENDS (added after their last element or model)"
	case .Stray_Ends: return ".ENDS outside a subcircuit (removed)"
	case .Numeric_Name: return "model names that are numbers (renamed: SPICE reads them as values)"
	case .Duplicate_Card: return "cards given twice, unchanged (the copies removed)"
	case .Nbv: return "diodes with BV but no NBV (NBV=1 added: PSpice's default; ngspice would take N and can stall)"
	case .Type_Vs_Description: return "NPN/PNP cards whose description says the other type"
	case .Differing_Duplicate: return "names defined more than once with different values (spicy uses the first)"
	case .Undefined_Model: return "models or subcircuits used but defined nowhere"
	case .Implausible_N: return "diodes with an emission coefficient N below 0.01 or above 100000 (a unit wrong?)"
	case .Capacitance_Unit: return "capacitances of a millifarad or more (a unit like \"p\" missing?)"
	}
	return ""
}

@(private = "file")
Rline :: struct {
	text: string,
	n:    int, // line in the original file
}

@(private = "file")
add_item :: proc(rep: ^Repair_Report, k: Repair_Kind, n: int, part, detail: string) {
	it := Repair_Item{k, n, part, detail}
	if k >= FIRST_CHECK do append(&rep.checks, it)
	else do append(&rep.fixes, it)
}

// A circuit element line ("Q1 c b e QX"): a name, then nodes. Vendor label lines ("Inc. BJTs",
// "BJTs - Single device of dual", "Transistor") are not.
element_like :: proc(t: string) -> bool {
	if len(t) == 0 || !is_ident_start(t[0]) do return false
	f := strings.fields(t, context.temp_allocator)
	if len(f) < 3 do return false
	for i in 0 ..< len(f[0]) do if !is_ident_char(f[0][i]) do return false
	alnum := false
	for i in 0 ..< len(f[1]) do if is_ident_char(f[1][i]) do alnum = true
	return alnum
}

// The names an element line may use as its model or subcircuit: Q c b e [s] model, D a k model,
// M d g s b model, J d g s model, X … subckt.
@(private = "file")
model_candidates :: proc(t: string) -> []string {
	f := strings.fields(replace_parens(t), context.temp_allocator)
	out := make([dynamic]string, context.temp_allocator)
	if len(f) < 3 do return out[:]
	if f[0][0] | 0x20 == 'x' {
		// the last word that is not a parameter
		for k := len(f) - 1; k >= 2; k -= 1 {
			if strings.contains_rune(f[k], '=') || f[k] == "=" || (k + 1 < len(f) && f[k + 1] == "=") do continue
			if lower(f[k]) == "params:" do continue
			append(&out, lower(f[k]))
			break
		}
		return out[:]
	}
	from := element_model_field(f[0][0])
	if from == 0 do return out[:]
	for k in from ..< len(f) {
		x := f[k]
		if x == "=" || (k + 1 < len(f) && f[k + 1] == "=") do break // the parameters start
		if !is_ident_start(x[0]) do continue
		append(&out, lower(x))
	}
	return out[:]
}

// The model name a vendor's "*SRC=part;model;…" line gives a card or subcircuit ("" for none).
@(private = "file")
src_name :: proc(L: []Rline, start: int) -> string {
	for k := start - 1; k >= 0 && k >= start - 10; k -= 1 {
		t := L[k].text
		if len(t) == 0 do continue
		if t[0] != '*' do break
		if strings.has_prefix(upper(t), "*SRC=") {
			f := strings.split(t[5:], ";", context.temp_allocator)
			if len(f) >= 2 do return strings.trim_space(f[1])
			return ""
		}
	}
	return ""
}

@(private = "file")
is_numeric_name :: proc(s: string) -> bool {
	if len(s) == 0 do return false
	for i in 0 ..< len(s) do if s[i] < '0' || s[i] > '9' do return false
	return true
}

// The end of the model card at L[k] (spice_text.odin's card_end on repair lines).
@(private = "file")
rcard_end :: proc(L: []Rline, k: int) -> int {return card_end(L, k, proc(l: Rline) -> string {return l.text})}

// Token spans of a line: runs of anything but spaces, tabs and parentheses.
@(private = "file")
spans_of :: proc(s: string, from: int) -> [][2]int {
	out := make([dynamic][2]int, context.temp_allocator)
	i := from
	for i < len(s) {
		for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '(' || s[i] == ')') do i += 1
		j := i
		for j < len(s) && s[j] != ' ' && s[j] != '\t' && s[j] != '(' && s[j] != ')' do j += 1
		if j > i do append(&out, [2]int{i, j})
		i = j
	}
	return out[:]
}

// Where the parameters of a card line start: after ".MODEL name type", or after the "+".
@(private = "file")
params_from :: proc(s: string) -> int {
	if len(s) > 0 && s[0] == '+' do return 1
	sp := spans_of(s, 0)
	if len(sp) < 3 do return len(s)
	t := s[sp[2][0]:sp[2][1]] // "NPN" or "D(IS=…" written together
	if p := strings.index_byte(t, '('); p >= 0 do return sp[2][0] + p
	return sp[2][1]
}

// The repaired text of a model library and what was repaired or needs checking. Allocates in
// the temp allocator.
// replacing: the library file the result replaces (an earlier import of the same file), whose
// names do not count as defined elsewhere.
model_repair :: proc(text: string, replacing := "") -> (fixed: string, rep: Repair_Report) {
	context.allocator = context.temp_allocator
	rep.fixes = make([dynamic]Repair_Item)
	rep.checks = make([dynamic]Repair_Item)

	// 0. characters, and an .ENDS run onto the end of a card
	pre := make([dynamic]Rline)
	{
		part := ""
		for raw, i in split_lines(text) {
			r := raw
			tt := strings.trim_space(r)
			if lt := lower(tt); strings.has_prefix(lt, ".model") || strings.has_prefix(lt, ".subc") {
				f := strings.fields(replace_parens(tt), context.temp_allocator)
				part = f[1] if len(f) > 1 else ""
			}
			if len(tt) > 0 && tt[0] != '*' && tt[0] != ';' {
				if strings.contains(r, "\u00a0") || strings.contains(r, "µ") || strings.contains(r, "μ") {
					r, _ = strings.replace_all(r, "\u00a0", " ")
					r, _ = strings.replace_all(r, "µ", "u")
					r, _ = strings.replace_all(r, "μ", "u")
					d := strings.trim_space(r)
					add_item(&rep, .Non_Ascii, i + 1, part, d[:min(40, len(d))])
				}
				lr := lower(r)
				// ".SUBCKT"/".MODEL" after text on a line that is no card: on its own line
				if tt[0] != '.' && tt[0] != '+' {
					k := -1
					for kw in ([]string{" .subckt ", "\t.subckt ", " .model ", "\t.model "}) do if x := strings.index(lr, kw); x >= 0 && (k < 0 || x < k) do k = x
					if k > 0 {
						f := strings.fields(r[k:], context.temp_allocator)
						part = f[1] if len(f) > 1 else part
						add_item(&rep, .Run_Together, i + 1, part, "")
						append(&pre, Rline{strings.trim_right_space(r[:k]), i + 1})
						append(&pre, Rline{strings.trim_space(r[k:]), i + 1})
						continue
					}
				}
				if k := strings.index(lr, ".ends"); k > 0 && strings.has_suffix(strings.trim_right_space(r[:k]), ")") {
					add_item(&rep, .Glued_Ends, i + 1, part, "")
					append(&pre, Rline{strings.trim_right_space(r[:k]), i + 1})
					append(&pre, Rline{r[k:], i + 1})
					continue
				}
			}
			append(&pre, Rline{r, i + 1})
		}
	}

	// 1. lines
	L := make([dynamic]Rline)
	in_card := false
	part := "" // the card or subcircuit the line belongs to (for the report)
	for pr in pre {
		t := strings.trim_space(pr.text)
		n := pr.n
		if lt := lower(t); strings.has_prefix(lt, ".subcket ") || strings.has_prefix(lt, ".subkt ") || strings.has_prefix(lt, ".subcircuit ") {
			sp := strings.index_byte(t, ' ')
			t = tcat(".SUBCKT", t[sp:])
			f := strings.fields(t, context.temp_allocator)
			part = f[1] if len(f) > 1 else ""
			add_item(&rep, .Misspelt_Subckt, n, part, "")
		}
		if lt := lower(t); strings.has_prefix(lt, ".model") || strings.has_prefix(lt, ".subckt") {
			f := strings.fields(replace_parens(t), context.temp_allocator)
			part = f[1] if len(f) > 1 else ""
		}
		if strings.has_prefix(t, ";") {
			add_item(&rep, .Comment_Semicolon, n, part, "")
			t = tcat("*", t[1:])
		}
		low := lower(t)
		if strings.has_prefix(low, ".simulator") {
			add_item(&rep, .Simulator_Line, n, "", t)
			t = tcat("* ", t)
		}
		if strings.has_prefix(low, ".model") do in_card = true
		else if len(t) > 0 && t[0] != '+' && t[0] != '*' do in_card = false
		if in_card && len(t) > 0 && (t[0] == '.' || t[0] == '+') {
			// "N = 1.667" as "N=1.667" (the same card to every simulator; not reported)
			if strings.contains_rune(t, '=') {
				nb := strings.builder_make()
				for p := 0; p < len(t); p += 1 {
					if t[p] == ' ' || t[p] == '\t' {
						q := p
						for q < len(t) && (t[q] == ' ' || t[q] == '\t') do q += 1
						if q < len(t) && t[q] == '=' {p = q - 1; continue}
						if p > 0 && t[p - 1] == '=' {p = q - 1; continue}
					}
					strings.write_byte(&nb, t[p])
				}
				t = strings.to_string(nb)
			}
			if k := strings.index_byte(t, ';'); k > 0 {
				add_item(&rep, .Inline_Semicolon, n, part, strings.trim_space(t[k:])[:min(40, len(strings.trim_space(t[k:])))])
				t = strings.trim_right_space(t[:k])
			}
			// "RC=0.015  +CJE=250E-12"
			for j := 1; j < len(t); j += 1 {
				if t[j] != '+' || (t[j - 1] != ' ' && t[j - 1] != '\t') do continue
				k := j + 1
				for k < len(t) && t[k] == ' ' do k += 1
				if k >= len(t) || !is_ident_start(t[k]) do continue
				e := k
				for e < len(t) && is_ident_char(t[e]) do e += 1
				for e < len(t) && t[e] == ' ' do e += 1
				if e >= len(t) || t[e] != '=' do continue
				add_item(&rep, .Plus_In_Line, n, part, t[k:min(len(t), k + 20)])
				t = tcat(t[:j], t[j + 1:])
			}
		}
		append(&L, Rline{t, n})
	}

	// 2. subcircuit ends, label lines
	out := make([dynamic]Rline)
	label :: proc(rep: ^Repair_Report, out: ^[dynamic]Rline, l: Rline) {
		add_item(rep, .Label_Line, l.n, "", l.text[:min(40, len(l.text))])
		append(out, Rline{tcat("* ", l.text), l.n})
	}
	is_body_text :: proc(t: string) -> bool {return len(t) > 0 && t[0] != '*' && t[0] != '.' && t[0] != '+'}
	all_refs := make(map[string]bool) // every name an element uses, anywhere
	for l in L do if element_like(l.text) do for c in model_candidates(l.text) do all_refs[c] = true
	i := 0
	for i < len(L) {
		t := L[i].text
		low := lower(t)
		if strings.has_prefix(low, ".subckt") {
			j := i + 1
			for j < len(L) && !strings.has_prefix(lower(L[j].text), ".ends") && !strings.has_prefix(lower(L[j].text), ".subckt") do j += 1
			last := j
			if j >= len(L) || !strings.has_prefix(lower(L[j].text), ".ends") {
				// no .ends: the subcircuit ends after its last element and the last model its
				// elements use (the vendor's next part follows)
				refs := make(map[string]bool)
				for k in i + 1 ..< j do if element_like(L[k].text) do for c in model_candidates(L[k].text) do refs[c] = true
				last = i
				for k in i + 1 ..< j {
					x := L[k].text
					if element_like(x) do last = k
					else if strings.has_prefix(lower(x), ".model") {
						f := strings.fields(replace_parens(x), context.temp_allocator)
						if len(f) >= 2 && refs[lower(f[1])] do last = k
					}
				}
				for last + 1 < j && strings.has_prefix(L[last + 1].text, "+") do last += 1
				// a model right after (blank lines between) that no element anywhere uses: the
				// subcircuit's own, under a name its element misspells
				for {
					m := last + 1
					for m < j && len(L[m].text) == 0 do m += 1
					if m >= j || !strings.has_prefix(lower(L[m].text), ".model") do break
					g := strings.fields(replace_parens(L[m].text), context.temp_allocator)
					if len(g) < 2 || all_refs[lower(g[1])] do break
					// named as the subcircuit, or as a name its elements use with a letter more or less
					mn := lower(g[1])
					sf := strings.fields(t, context.temp_allocator)
					akin := len(sf) > 1 && lower(sf[1]) == mn
					for c in refs do if strings.has_prefix(mn, c) || strings.has_prefix(c, mn) do akin = true
					if !akin do break
					last = m
					for last + 1 < j && strings.has_prefix(L[last + 1].text, "+") do last += 1
				}
				f := strings.fields(t, context.temp_allocator)
				add_item(&rep, .Missing_Ends, L[i].n, f[1] if len(f) > 1 else "", "")
			}
			for k in i ..= min(last, len(L) - 1) {
				if is_body_text(L[k].text) && !element_like(L[k].text) do label(&rep, &out, L[k])
				else do append(&out, L[k])
			}
			if last != j || j >= len(L) do append(&out, Rline{".ENDS", L[min(last, len(L) - 1)].n})
			i = last + 1
			continue
		}
		if strings.has_prefix(low, ".ends") {
			add_item(&rep, .Stray_Ends, L[i].n, "", "")
			i += 1
			continue
		}
		if is_body_text(t) do label(&rep, &out, L[i])
		else do append(&out, L[i])
		i += 1
	}
	L = out

	// 2b. a model after its subcircuit's .ENDS whose name other top-level models share (each part
	// with its own "ZDiode"): it belongs to that subcircuit
	{
		count := make(map[string]int)
		d := 0
		for l in L {
			lw := lower(l.text)
			if strings.has_prefix(lw, ".subckt") do d += 1
			else if strings.has_prefix(lw, ".ends") do d = max(0, d - 1)
			else if d == 0 && strings.has_prefix(lw, ".model") {
				f := strings.fields(replace_parens(l.text), context.temp_allocator)
				if len(f) > 1 do count[lower(f[1])] += 1
			}
		}
		moved := make(map[int]bool)
		out = make([dynamic]Rline)
		refs := make(map[string]bool)
		here := make(map[string]bool)
		sub := ""
		d = 0
		for k := 0; k < len(L); k += 1 {
			if moved[k] do continue
			lw := lower(L[k].text)
			if strings.has_prefix(lw, ".subckt") {
				d += 1
				if d == 1 {
					clear(&refs)
					clear(&here)
					f := strings.fields(L[k].text, context.temp_allocator)
					sub = f[1] if len(f) > 1 else ""
				}
			} else if strings.has_prefix(lw, ".ends") {
				d = max(0, d - 1)
				for m := k + 1; d == 0; {
					for m < len(L) && (len(L[m].text) == 0 || L[m].text[0] == '*') do m += 1
					if m >= len(L) || !strings.has_prefix(lower(L[m].text), ".model") do break
					f := strings.fields(replace_parens(L[m].text), context.temp_allocator)
					if len(f) < 2 do break
					nm := lower(f[1])
					if count[nm] < 2 || !refs[nm] || here[nm] do break
					e := rcard_end(L[:], m)
					for q in m ..< e {
						append(&out, L[q])
						moved[q] = true
					}
					add_item(&rep, .Model_After_Ends, L[m].n, sub, f[1])
					here[nm] = true
					m = e
				}
			} else if d >= 1 {
				if element_like(L[k].text) do for c in model_candidates(L[k].text) do refs[c] = true
				else if strings.has_prefix(lw, ".model") {
					f := strings.fields(replace_parens(L[k].text), context.temp_allocator)
					if len(f) > 1 do here[lower(f[1])] = true
				}
			}
			append(&out, L[k])
		}
		L = out
	}

	// 3. model cards
	out = make([dynamic]Rline)
	depth := 0
	i = 0
	for i < len(L) {
		t := L[i].text
		low := lower(t)
		if strings.has_prefix(low, ".subckt") do depth += 1
		if strings.has_prefix(low, ".ends") do depth = max(0, depth - 1)
		if !strings.has_prefix(low, ".model") {
			append(&out, L[i])
			i += 1
			continue
		}
		m := rcard_end(L[:], i)
		card := make([dynamic]Rline)
		for k in i ..< m {
			x := L[k].text
			if len(x) > 0 && x[0] == '+' || k == i do append(&card, L[k])
			else if len(x) > 0 {
				add_item(&rep, .Comment_In_Card, L[k].n, "", "")
				append(&out, L[k])
			}
		}
		fields0 := strings.fields(replace_parens(card[0].text), context.temp_allocator)
		name := fields0[1] if len(fields0) > 1 else ""
		typ := upper(fields0[2]) if len(fields0) > 2 else ""
		// the closing ")" and what follows it
		opened, closed_at := false, -1
		depth_p := 0
		find: for &c, ci in card {
			for p in 0 ..< len(c.text) {
				switch c.text[p] {
				case '(':
					depth_p += 1
					opened = true
				case ')':
					depth_p -= 1
					if opened && depth_p == 0 {
						rest := strings.trim_space(c.text[p + 1:])
						for d in card[ci + 1:] do rest = tcat(rest, strings.trim_space(d.text))
						if len(rest) > 0 {
							add_item(&rep, .After_Paren, c.n, name, rest[:min(40, len(rest))])
							c.text = c.text[:p + 1]
							resize(&card, ci + 1)
						}
						closed_at = ci
						break find
					}
				}
			}
		}
		if opened && closed_at < 0 {
			add_item(&rep, .Unclosed_Paren, card[0].n, name, "")
			card[len(card) - 1].text = tcat(card[len(card) - 1].text, " )")
		}
		// "NE 1.33" without "=", right to left
		for &c in card {
			sp := spans_of(c.text, params_from(c.text))
			for k := len(sp) - 2; k >= 0; k -= 1 {
				a := c.text[sp[k][0]:sp[k][1]]
				b := c.text[sp[k + 1][0]:sp[k + 1][1]]
				if strings.contains_rune(a, '=') || strings.contains_rune(b, '=') do continue
				ok_a := is_ident_start(a[0])
				for q in 0 ..< len(a) do if !is_ident_char(a[q]) do ok_a = false
				if !ok_a do continue
				if k > 0 && strings.has_suffix(c.text[sp[k - 1][0]:sp[k - 1][1]], "=") do continue
				if _, ok := parse_eng(b); !ok || !is_number_token(b) do continue
				add_item(&rep, .Missing_Equals, c.n, name, tcat(a, " ", b))
				c.text = tcat(c.text[:sp[k][1]], "=", c.text[sp[k + 1][0]:])
			}
		}
		// a parameter given twice: the last kept
		{
			Occ :: struct {ci, s, e: int, key: string}
			occ := make([dynamic]Occ)
			count := make(map[string]int)
			for c, ci in card {
				for s in spans_of(c.text, params_from(c.text)) {
					tok := c.text[s[0]:s[1]]
					eq := strings.index_byte(tok, '=')
					if eq <= 0 || eq == len(tok) - 1 do continue
					key := upper(tok[:eq])
					append(&occ, Occ{ci, s[0], s[1], key})
					count[key] += 1
				}
			}
			seen := make(map[string]int)
			#reverse for o in occ {
				seen[o.key] += 1
				if seen[o.key] == 1 do continue
				c := &card[o.ci]
				add_item(&rep, .Duplicate_Param, c.n, name, c.text[o.s:o.e])
				e := o.e
				for e < len(c.text) && c.text[e] == ' ' do e += 1
				c.text = tcat(c.text[:o.s], c.text[e:])
			}
		}
		// parameters of the repaired card
		params := make(map[string]string)
		for c in card {
			for s in spans_of(c.text, params_from(c.text)) {
				tok := c.text[s[0]:s[1]]
				if eq := strings.index_byte(tok, '='); eq > 0 do params[upper(tok[:eq])] = tok[eq + 1:]
			}
		}
		if typ == "D" || strings.has_prefix(typ, "D(") {
			nv, has_n := parse_eng(params["N"])
			if has_n && (nv < 0.01 || nv > 1e5) do add_item(&rep, .Implausible_N, card[0].n, name, tcat("N=", params["N"]))
			if _, has_bv := params["BV"]; has_bv && has_n && nv != 1 {
				if _, has := params["NBV"]; !has {
					add_item(&rep, .Nbv, card[0].n, name, "")
					lc := &card[len(card) - 1]
					if strings.has_suffix(lc.text, ")") do lc.text = tcat(strings.trim_right(lc.text[:len(lc.text) - 1], " "), " NBV=1 )")
					else do lc.text = tcat(lc.text, " NBV=1")
				}
			}
		}
		for k in ([]string{"CJO", "CJ0", "CJE", "CJC", "CJS", "CGSO", "CGDO", "CGBO", "CBD", "CBS", "CJ"}) {
			if v, ok := parse_eng(params[k]); ok && v >= 1e-3 do add_item(&rep, .Capacitance_Unit, card[0].n, name, tcat(k, "=", params[k]))
		}
		if depth == 0 && (typ == "NPN" || typ == "PNP") {
			// the description just above: the comment lines before the card
			says_npn, says_pnp := false, false
			for k := len(out) - 1; k >= 0 && k >= len(out) - 8; k -= 1 {
				x := out[k].text
				if len(x) == 0 do continue
				if x[0] != '*' do break
				u := upper(x)
				if strings.contains(u, "NPN") do says_npn = true
				if strings.contains(u, "PNP") do says_pnp = true
			}
			if (typ == "NPN" && says_pnp && !says_npn) || (typ == "PNP" && says_npn && !says_pnp) {
				add_item(&rep, .Type_Vs_Description, card[0].n, name, fmt.tprintf("%s %s card; its description says %s", "an" if typ == "NPN" else "a", typ, "PNP" if typ == "NPN" else "NPN"))
			}
		}
		append(&out, ..card[:])
		i = m
	}
	L = out

	// 4. blocks at the top: numeric names, duplicates
	Block :: struct {start, end: int, name, key: string} // lines [start, end)
	blocks := make([dynamic]Block)
	i = 0
	for i < len(L) {
		low := lower(L[i].text)
		if strings.has_prefix(low, ".subckt") || strings.has_prefix(low, ".model") {
			e := i + 1
			if low[1] == 's' {
				for e < len(L) && !strings.has_prefix(lower(L[e - 1].text), ".ends") do e += 1
			} else {
				for e < len(L) && strings.has_prefix(L[e].text, "+") do e += 1
			}
			kb := strings.builder_make()
			for x in L[i:e] {
				if len(x.text) == 0 || x.text[0] == '*' do continue
				for w in strings.fields(upper(x.text), context.temp_allocator) {
					strings.write_string(&kb, w)
					strings.write_byte(&kb, ' ')
				}
			}
			f := strings.fields(replace_parens(L[i].text), context.temp_allocator)
			append(&blocks, Block{i, e, f[1] if len(f) > 1 else "", strings.to_string(kb)})
			i = e
			continue
		}
		i += 1
	}
	top := make(map[string]bool)
	for b in blocks do top[lower(b.name)] = true
	drop := make(map[int]bool) // line indices
	first := make(map[string]int) // name -> block index
	defined := make(map[string]bool)
	for b, bi in blocks {
		n := lower(b.name)
		defined[n] = true
		if fi, ok := first[n]; ok {
			// a copy's name over another part's description: the name the description gives
			if nn := src_name(L[:], b.start); len(nn) > 0 && !strings.equal_fold(nn, b.name) && !top[lower(nn)] {
				t := L[b.start].text
				k := strings.index(t, b.name)
				L[b.start].text = tcat(t[:k], nn, t[k + len(b.name):])
				if e := L[b.end - 1].text; strings.has_prefix(lower(e), ".ends") {
					if k = strings.index(e, b.name); k > 0 do L[b.end - 1].text = tcat(e[:k], nn, e[k + len(b.name):])
				}
				add_item(&rep, .Name_From_Src, L[b.start].n, b.name, tcat("now ", nn))
				top[lower(nn)] = true
				defined[lower(nn)] = true
				first[lower(nn)] = bi
				blocks[bi].name = nn
				continue
			}
			if blocks[fi].key == b.key {
				add_item(&rep, .Duplicate_Card, L[b.start].n, b.name, fmt.tprintf("as at line %d", L[blocks[fi].start].n))
				for k in b.start ..< b.end do drop[k] = true
			} else {
				add_item(&rep, .Differing_Duplicate, L[b.start].n, b.name, fmt.tprintf("also at line %d", L[blocks[fi].start].n))
			}
			continue
		}
		first[n] = bi
	}
	// model names that are numbers: "M5401", and where elements use them
	renamed := make(map[string]string)
	for &b in blocks {
		if !strings.has_prefix(lower(L[b.start].text), ".model") || !is_numeric_name(b.name) || drop[b.start] do continue
		nn := tcat("M", b.name)
		for defined[lower(nn)] do nn = tcat("M", nn)
		defined[lower(nn)] = true
		renamed[lower(b.name)] = nn
		add_item(&rep, .Numeric_Name, L[b.start].n, b.name, tcat("now ", nn))
		t := L[b.start].text
		k := strings.index(t, b.name)
		L[b.start].text = tcat(t[:k], nn, t[k + len(b.name):])
		b.name = nn
	}
	if len(renamed) > 0 {
		// the model's place on the element line (a number there is what the vendor meant)
		for &l in L {
			if !element_like(l.text) do continue
			from := element_model_field(l.text[0])
			if from == 0 do continue
			f := strings.fields(l.text, context.temp_allocator)
			for k in from ..< len(f) {
				if strings.contains_rune(f[k], '=') do break
				if nn, ok := renamed[lower(f[k])]; ok {
					f[k] = nn
					l.text = strings.join(f, " ")
					break
				}
			}
		}
	}
	// warnings on a copy that is removed: said once, at the copy kept
	{
		gone := make(map[int]bool)
		for k in 0 ..< len(L) do if drop[k] do gone[L[k].n] = true
		kept := make([dynamic]Repair_Item)
		for it in rep.checks do if !(it.kind == .Type_Vs_Description && gone[it.line]) do append(&kept, it)
		rep.checks = kept
	}
	// used but defined nowhere: at the top of the file, in the subcircuit itself, or in spicy's
	// libraries (a card inside another subcircuit does not count); a model for D, Q, M, J and a
	// subcircuit for X
	top_model := make(map[string]bool)
	top_sub := make(map[string]bool)
	for b in blocks {
		if drop[b.start] do continue
		if strings.has_prefix(lower(L[b.start].text), ".model") do top_model[lower(b.name)] = true
		else do top_sub[lower(b.name)] = true
	}
	for li := 0; li < len(L); li += 1 {
		if !strings.has_prefix(lower(L[li].text), ".subckt") || drop[li] do continue
		f := strings.fields(L[li].text, context.temp_allocator)
		sub := f[1] if len(f) > 1 else ""
		e := li + 1
		for e < len(L) && !strings.has_prefix(lower(L[e].text), ".ends") do e += 1
		Local :: struct {name, typ: string}
		models := make([dynamic]Local)
		subs := make(map[string]bool)
		used := make(map[string]bool)
		for k in li + 1 ..< e {
			lk := lower(L[k].text)
			g := strings.fields(replace_parens(L[k].text), context.temp_allocator)
			if strings.has_prefix(lk, ".model") && len(g) > 2 do append(&models, Local{lower(g[1]), upper(g[2])})
			else if strings.has_prefix(lk, ".subckt") && len(g) > 1 do subs[lower(g[1])] = true
			else if element_like(L[k].text) do for c in model_candidates(L[k].text) do used[c] = true
		}
		for k in li + 1 ..< e {
			l := &L[k]
			if !element_like(l.text) do continue
			cands := model_candidates(l.text)
			if len(cands) == 0 do continue
			letter := l.text[0] | 0x20
			found := false
			for c in cands {
				if letter == 'x' && (subs[c] || top_sub[c]) do found = true
				if letter != 'x' && top_model[c] do found = true
				if letter != 'x' do for m in models do if m.name == c do found = true
				for &le in model_lib do if le.name == c && le.src != replacing && (le.kind == "subckt") == (letter == 'x') do found = true
			}
			if found do continue
			name := cands[len(cands) - 1] if letter == 'x' else cands[0]
			g := strings.fields(l.text, context.temp_allocator)
			for x in g do if strings.equal_fold(x, name) {name = x; break} // as written
			// the subcircuit's only model of this kind, used by nothing else: that one
			kinds: []string
			switch letter {
			case 'd': kinds = {"D"}
			case 'q': kinds = {"NPN", "PNP", "LPNP"}
			case 'm': kinds = {"NMOS", "PMOS", "VDMOS"}
			case 'j': kinds = {"NJF", "PJF"}
			}
			fit := -1
			nfit := 0
			for m, mi in models do for t in kinds do if m.typ == t && !used[m.name] {fit = mi; nfit += 1}
			if nfit == 1 {
				written := models[fit].name
				for m in L[li + 1:e] do if strings.has_prefix(lower(m.text), ".model") {
					h := strings.fields(replace_parens(m.text), context.temp_allocator)
					if len(h) > 1 && lower(h[1]) == models[fit].name do written = h[1]
				}
				for x, xi in g do if xi > 0 && x == name {g[xi] = written; break}
				add_item(&rep, .Local_Model_Name, l.n, sub, fmt.tprintf("%s: %s made %s", g[0], name, written))
				l.text = strings.join(g, " ")
				used[models[fit].name] = true
				continue
			}
			add_item(&rep, .Undefined_Model, l.n, sub, fmt.tprintf("%s uses %s", g[0], name))
		}
		li = e
	}

	for len(L) > 0 && len(L[len(L) - 1].text) == 0 do pop(&L)
	b := strings.builder_make()
	for l, k in L {
		if drop[k] do continue
		strings.write_string(&b, l.text)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b), rep
}

// How many items there are of each kind.
@(private = "file")
repair_counts :: proc(items: []Repair_Item) -> (c: [Repair_Kind]int) {
	for it in items do c[it.kind] += 1
	return
}

// The report for the import dialog and the command line: a summary per kind, then each place.
repair_report_text :: proc(rep: ^Repair_Report) -> string {
	context.allocator = context.temp_allocator
	b := strings.builder_make()
	section :: proc(b: ^strings.Builder, head: string, items: []Repair_Item) {
		if len(items) == 0 do return
		fmt.sbprintf(b, "%s\n", head)
		for n, k in repair_counts(items) do if n > 0 {
			num := fmt.tprintf("%d", n)
			fmt.sbprintf(b, "  %s%s  %s\n", strings.repeat(" ", max(0, 5 - len(num))), num, repair_kind_text(k))
		}
		fmt.sbprintf(b, "\n")
	}
	section(&b, fmt.tprintf("Repairs spicy can make (%d):", len(rep.fixes)), rep.fixes[:])
	section(&b, fmt.tprintf("To check yourself (%d, not changed):", len(rep.checks)), rep.checks[:])
	details :: proc(b: ^strings.Builder, head: string, items: []Repair_Item) {
		if len(items) == 0 do return
		fmt.sbprintf(b, "%s\n", head)
		for it in items {
			what := it.detail
			if len(what) == 0 do what = repair_kind_text(it.kind)
			fmt.sbprintf(b, "  line %-6d %-18s %s\n", it.line, it.part, what)
		}
		fmt.sbprintf(b, "\n")
	}
	details(&b, "Where (repairs):", rep.fixes[:])
	details(&b, "Where (to check):", rep.checks[:])
	return strings.trim_right_space(strings.to_string(b))
}

// The comment block on top of a repaired copy.
repair_header :: proc(rep: ^Repair_Report, src: string) -> string {
	context.allocator = context.temp_allocator
	b := strings.builder_make()
	fmt.sbprintf(&b, "* Repaired by spicy when imported from %s (the original is unchanged):\n", base_name(src))
	for n, k in repair_counts(rep.fixes[:]) do if n > 0 do fmt.sbprintf(&b, "*   %d %s\n", n, repair_kind_text(k))
	if len(rep.checks) > 0 do fmt.sbprintf(&b, "* Not changed, to check: %d (spicy --check-model on the original lists them)\n", len(rep.checks))
	strings.write_string(&b, "*\n")
	return strings.to_string(b)
}
