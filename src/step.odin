package spicy

import "core:fmt"
import "core:math"
import "core:strings"

// .step: one run of the simulator per value of a parameter, for every simulator. Two forms:
//   .step param R list 1k 2k 4.7k
//   .step param R 1k 10k 1k          (start, stop, increment; stop included)
// Each run gets its own netlist, with the value of the parameter set where the netlist defines it.

Step_Value :: struct {
	label:  string, // "R=2k": names the run's plots and log
	assign: string, // "R=2k": the .param line
}

STEP_MAX :: 500

STEP_CORRECT :: "Correct: .step param R list 1k 2k 4.7k or .step param R 1k 10k 1k"

// The values of the arguments of a .step line, or an error with the correct syntax.
step_values :: proc(args: string) -> (vals: [dynamic]Step_Value, err: string) {
	t := strings.fields(args, context.temp_allocator)
	if len(t) < 4 || lower(t[0]) != "param" do return nil, fmt.tprintf("needs param, a name and the values. %s", STEP_CORRECT)
	name := t[1]
	if !is_identifier(name) || (name[0] >= '0' && name[0] <= '9') do return nil, fmt.tprintf("\"%s\" is not a parameter name. %s", name, STEP_CORRECT)
	vals = make([dynamic]Step_Value, context.temp_allocator)
	if lower(t[2]) == "list" {
		for v in t[3:] {
			if _, ok := parse_eng(v); !ok do return vals, fmt.tprintf("\"%s\" is not a number. %s", v, STEP_CORRECT)
			append(&vals, Step_Value{label = tcat(name, "=", v), assign = tcat(name, "=", v)})
		}
		return vals, ""
	}
	if len(t) != 5 do return vals, fmt.tprintf("needs a start, a stop and an increment. %s", STEP_CORRECT)
	start, ok1 := parse_eng(t[2])
	stop, ok2 := parse_eng(t[3])
	incr, ok3 := parse_eng(t[4])
	if !ok1 || !ok2 || !ok3 do return vals, fmt.tprintf("\"%s %s %s\" are not numbers. %s", t[2], t[3], t[4], STEP_CORRECT)
	if incr == 0 do return vals, fmt.tprintf("the increment is 0. %s", STEP_CORRECT)
	steps := (stop - start) / incr
	if steps < 0 do return vals, fmt.tprintf("stop is on the other side of start for this increment. %s", STEP_CORRECT)
	count := int(math.floor(steps + 1e-9)) + 1
	if count > STEP_MAX do return vals, fmt.tprintf("%d values, more than the %d allowed. %s", count, STEP_MAX, STEP_CORRECT)
	for i in 0 ..< count {
		v := start + f64(i) * incr
		text := fmt.tprintf("%g", v)
		append(&vals, Step_Value{label = tcat(name, "=", text), assign = tcat(name, "=", text)})
	}
	return vals, ""
}

// The netlist of one .step run: the value of the parameter is set where the netlist defines it
// (Xyce keeps the first definition of a parameter and VACASK refuses a second one, so a line
// appended at the end would not work). A parameter the netlist does not define gets a new line.
step_netlist :: proc(text, assign: string, vacask: bool) -> string {
	eq := strings.index_byte(assign, '=')
	name, value := assign[:eq], assign[eq + 1:]
	out := make([dynamic]string, context.temp_allocator)
	done := false
	for l in split_lines(text) {
		f := strings.fields(l, context.temp_allocator)
		if len(f) < 2 {
			append(&out, l)
			continue
		}
		key := lower(f[0])
		// VACASK: the parameters line, and the control block's var line of a parameter an
		// analysis uses
		is_def := (key == "parameters" || key == "var") if vacask else (key == ".param" || key == ".params")
		if !is_def {
			append(&out, l)
			continue
		}
		changed := false
		for &t in f[1:] {
			if len(t) > len(name) && strings.equal_fold(t[:len(name)], name) && t[len(name)] == '=' {
				t = tcat(name, "=", value)
				changed = true
				done = true
			}
		}
		if changed {
			lead := l[:len(l) - len(strings.trim_left_space(l))]
			append(&out, tcat(lead, strings.join(f, " ", context.temp_allocator)))
		} else {
			append(&out, l)
		}
	}
	text2 := strings.join(out[:], "\n", context.temp_allocator)
	if done do return text2
	if vacask {
		// before the control block
		cut := strings.index(text2, "\ncontrol")
		if cut < 0 do return tcat(text2, "\nparameters ", assign, "\n")
		return tcat(text2[:cut + 1], "parameters ", assign, "\n", text2[cut + 1:])
	}
	line := tcat(".param ", assign, "\n")
	cut := strings.last_index(text2, "\n.end")
	if cut < 0 do return tcat(text2, "\n", line)
	return tcat(text2[:cut + 1], line, text2[cut + 1:])
}

// The .step lines of the schematic: at most one. Fills nl.steps.
step_check :: proc(nl: ^Netlist, sim: ^Simulator_Def, lines: []string) {
	if len(lines) == 0 do return
	if len(lines) > 1 {
		append(&nl.errors, fmt.tprintf(".step \"%s\": only one .step line is allowed. %s", lines[1], STEP_CORRECT))
		return
	}
	vals, err := step_values(lines[0])
	if len(err) > 0 {
		append(&nl.errors, fmt.tprintf(".step \"%s\": %s", lines[0], err))
		return
	}
	nl.steps = vals[:]
}
