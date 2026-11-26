package spicy

import "core:math"
import "core:strconv"
import "core:strings"

// Noise results of Xyce and VACASK, shown as ngspice shows them: onoise_spectrum and
// inoise_spectrum in V/√Hz, so one .plot line works on every simulator.
//   Xyce writes its noise analysis to a text file beside the netlist (<netlist>_noise.dat), with
//   V²/Hz power densities: the square root gives V/√Hz.
//   VACASK writes its noise analysis as a raw file whose onoise and n(…) are V²/Hz: the same.

NOISE_PLOT :: "Noise Spectral Density Curves"

// The noise file of an Xyce run: frequency, Re and Im of the output, then the output and input
// noise power densities after a ZONE line.
xyce_noise_read :: proc(path: string) -> (p: Plot, err: string) {
	text, ok := read_text(path, context.temp_allocator)
	if !ok do return {}, tcat("cannot read ", path)
	freq := make([dynamic]f64)
	onoise := make([dynamic]f64)
	inoise := make([dynamic]f64)
	in_data := false
	for l in split_lines(text) {
		t := strings.trim_space(l)
		if strings.has_prefix(t, "ZONE") {
			in_data = true
			continue
		}
		if !in_data do continue
		f := strings.fields(t, context.temp_allocator)
		if len(f) < 5 do continue
		x, ok1 := strconv.parse_f64(f[0])
		on, ok2 := strconv.parse_f64(f[3])
		in_, ok3 := strconv.parse_f64(f[4])
		if !ok1 || !ok2 || !ok3 do continue
		append(&freq, x)
		append(&onoise, math.sqrt(on))
		append(&inoise, math.sqrt(in_))
	}
	if len(freq) == 0 do return {}, tcat("no noise data in ", path)
	p.name = strings.clone(NOISE_PLOT)
	p.file = strings.clone(path)
	p.npoints = len(freq)
	append(&p.vecs, Vec{name = strings.clone("frequency"), unit = strings.clone("Hz"), re = freq[:]})
	append(&p.vecs, Vec{name = strings.clone("onoise_spectrum"), unit = strings.clone("V/√Hz"), re = onoise[:]})
	append(&p.vecs, Vec{name = strings.clone("inoise_spectrum"), unit = strings.clone("V/√Hz"), re = inoise[:]})
	return p, ""
}

// VACASK's noise densities are power densities (V²/Hz): onoise and the per-instance n(…)
// become the square root, in V/√Hz, and onoise is named onoise_spectrum as in ngspice.
// VACASK has no input-referred spectrum: it is the output spectrum over the power gain
// (its gain vector, |H|²), as the VACASK docs give: inoise = onoise / sqrt(gain), in V/√Hz.
vacask_noise_density :: proc(p: ^Plot) {
	if plot_kind(p) != "noise" do return
	// the same name on every simulator: VACASK calls it "Small-Signal Noise Analysis"
	delete(p.name)
	p.name = strings.clone(NOISE_PLOT)
	gain: []f64
	for v in p.vecs do if v.name == "gain" do gain = v.re
	for &v in p.vecs {
		if v.name != "onoise" && !strings.has_prefix(v.name, "n(") do continue
		for &x in v.re do x = math.sqrt(max(x, 0))
		if v.name == "onoise" {
			delete(v.name)
			v.name = strings.clone("onoise_spectrum")
		}
		delete(v.unit)
		v.unit = strings.clone("V/√Hz")
	}
	onoise: []f64
	for v in p.vecs do if v.name == "onoise_spectrum" do onoise = v.re
	if len(gain) == 0 || len(gain) != len(onoise) do return
	in_ := make([]f64, len(onoise))
	for i in 0 ..< len(onoise) do if gain[i] > 0 do in_[i] = onoise[i] / math.sqrt(gain[i])
	append(&p.vecs, Vec{name = strings.clone("inoise_spectrum"), unit = strings.clone("V/√Hz"), re = in_})
}

// ngspice's raw file gives no unit to its noise spectra: they are V/√Hz, as on the other simulators.
noise_units :: proc(p: ^Plot) {
	if plot_kind(p) != "noise" do return
	for &v in p.vecs do if v.name == "onoise_spectrum" || v.name == "inoise_spectrum" {
		if len(v.unit) == 0 {
			delete(v.unit)
			v.unit = strings.clone("V/√Hz")
		}
	}
}

// The integrated noise of a noise analysis: the spectrum squared, integrated over the sweep
// (trapezoidal rule), and the square root: the RMS noise voltage over the band. Named and laid
// out as ngspice's "Integrated Noise" plot, so the three simulators show the same thing.
noise_totals :: proc(p: ^Plot) -> (t: Plot, ok: bool) {
	f, on, in_: []f64
	for v in p.vecs {
		switch v.name {
		case "frequency": f = v.re
		case "onoise_spectrum": on = v.re
		case "inoise_spectrum": in_ = v.re
		}
	}
	if len(f) < 2 || len(on) != len(f) || len(in_) != len(f) do return {}, false
	t.name = strings.clone("Integrated Noise")
	t.npoints = 1
	// the values live on the heap: a slice literal would die with this procedure
	out := make([]f64, 1)
	out[0] = noise_band_rms(f, on)
	append(&t.vecs, Vec{name = strings.clone("v(onoise_total)"), unit = strings.clone("V"), re = out})
	inn := make([]f64, 1)
	inn[0] = noise_band_rms(f, in_)
	append(&t.vecs, Vec{name = strings.clone("v(inoise_total)"), unit = strings.clone("V"), re = inn})
	return t, true
}

@(private = "file")
noise_band_rms :: proc(f, s: []f64) -> f64 {
	sum := 0.0
	for i in 0 ..< len(f) - 1 do sum += 0.5 * (s[i] * s[i] + s[i + 1] * s[i + 1]) * abs(f[i + 1] - f[i])
	return math.sqrt(sum)
}
