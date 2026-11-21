package spicy

import "core:math"

// ---------------------------------------------------------------------------
// FFT of transient waveforms (ported from zapped, src/fft.odin). A simulator's time
// steps are not evenly spaced, so the window is first resampled by linear interpolation
// onto an even grid of N = 2^k points.

// In-place iterative radix-2 FFT (len must be a power of two).
fft_inplace :: proc(re, im: []f64) {
	n := len(re)
	if n < 2 do return
	// bit reversal
	j := 0
	for i in 1 ..< n {
		bit := n >> 1
		for j & bit != 0 {j ~= bit; bit >>= 1}
		j |= bit
		if i < j {
			re[i], re[j] = re[j], re[i]
			im[i], im[j] = im[j], im[i]
		}
	}
	for size := 2; size <= n; size <<= 1 {
		ang := -2 * math.PI / f64(size)
		wr, wi := math.cos(ang), math.sin(ang)
		for start := 0; start < n; start += size {
			cr, ci := 1.0, 0.0
			for k in 0 ..< size / 2 {
				a, b := start + k, start + k + size / 2
				tr := re[b] * cr - im[b] * ci
				ti := re[b] * ci + im[b] * cr
				re[b], im[b] = re[a] - tr, im[a] - ti
				re[a] += tr
				im[a] += ti
				cr, ci = cr * wr - ci * wi, cr * wi + ci * wr
			}
		}
	}
}

// Window functions. The amplitudes are corrected for each window's coherent gain, so a sine
// on a bin reads its true amplitude in any of them. Hann is a good default; flat-top reads
// amplitudes between bins most accurately; rectangular has no leakage when the window
// holds a whole number of periods.
FFT_WINDOWS := [?]string{"hann", "hamming", "blackman", "flat-top", "rectangular"}
FFT_WINDOW_NAMES := [?]string{"Hann", "Hamming", "Blackman", "Flat-top", "Rectangular"}

// Index into FFT_WINDOWS of a window name, or -1.
fft_window_index :: proc(name: string) -> int {
	for w, i in FFT_WINDOWS do if w == name do return i
	return -1
}

// Window value at x = k / n (periodic form).
@(private = "file")
window_at :: proc(window: int, x: f64) -> f64 {
	c :: proc(k, x: f64) -> f64 {return math.cos(2 * math.PI * k * x)}
	switch FFT_WINDOWS[clamp(window, 0, len(FFT_WINDOWS) - 1)] {
	case "hann": return 0.5 - 0.5 * c(1, x)
	case "hamming": return 0.54 - 0.46 * c(1, x)
	case "blackman": return 0.42 - 0.5 * c(1, x) + 0.08 * c(2, x)
	case "flat-top": return 0.21557895 - 0.41663158 * c(1, x) + 0.277263158 * c(2, x) - 0.083578947 * c(3, x) + 0.006947368 * c(4, x)
	}
	return 1
}

Spectrum :: struct {
	f:     []f64, // bin frequencies [Hz], 0 … f_max
	amp:   []f64, // peak amplitude of each sine component (DC: the mean)
	df:    f64, // bin spacing = 1 / window length
	f_max: f64, // highest frequency returned
	n:     int, // FFT length
}

spectrum_free :: proc(s: ^Spectrum) {
	delete(s.f)
	delete(s.amp)
	s^ = {}
}

@(private = "file")
lower_bound :: proc(t: []f64, x: f64) -> int {
	lo, hi := 0, len(t)
	for lo < hi {
		m := (lo + hi) / 2
		if t[m] < x do lo = m + 1
		else do hi = m
	}
	return lo
}

// value at time x (linear interpolation); i is a starting guess that is moved forward,
// since the resampling walks through t in order
@(private = "file")
sample_from :: proc(t, y: []f64, x: f64, i: ^int) -> f64 {
	n := len(t)
	for i^ < n && t[i^] < x do i^ += 1
	k := i^
	if k <= 0 do return y[0]
	if k >= n do return y[n - 1]
	a := (x - t[k - 1]) / max(t[k] - t[k - 1], 1e-300)
	return y[k - 1] + a * (y[k] - y[k - 1])
}

// Single-sided amplitude spectrum of y(t) over [t0, t1] with a window from FFT_WINDOWS
// (corrected for its coherent gain). The FFT has at least 4 points per simulated point,
// at most max_n (a power of two, ≥ 1024). The results are allocated with allocator.
spectrum_of :: proc(t, y: []f64, t0, t1: f64, window: int, max_n := 1 << 18, allocator := context.allocator) -> (sp: Spectrum, ok: bool) {
	if len(t) < 4 || len(y) < len(t) || t1 <= t0 do return
	i0 := max(lower_bound(t, t0), 0)
	i1 := min(lower_bound(t, t1), len(t))
	cnt := i1 - i0
	if cnt < 4 do return
	// at least 4 grid points per simulated point on average, power of two
	n := 1024
	for n < 4 * cnt && n < max_n do n <<= 1
	re := make([]f64, n, context.temp_allocator)
	im := make([]f64, n, context.temp_allocator)
	T := t1 - t0
	dt := T / f64(n) // periodic grid: t0 … t1 - dt
	wsum := 0.0
	at := max(i0 - 1, 0)
	for k in 0 ..< n {
		x := sample_from(t, y, t0 + f64(k) * dt, &at)
		w := window_at(window, f64(k) / f64(n))
		re[k] = x * w
		wsum += w
	}
	fft_inplace(re, im)
	nb := n / 2
	sp.f = make([]f64, nb, allocator)
	sp.amp = make([]f64, nb, allocator)
	for k in 0 ..< nb {
		sp.f[k] = f64(k) / T
		m := math.sqrt(re[k] * re[k] + im[k] * im[k]) / wsum
		sp.amp[k] = m if k == 0 else 2 * m
	}
	sp.df = 1 / T
	sp.f_max = sp.f[nb - 1]
	sp.n = n
	return sp, true
}
