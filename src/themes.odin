package spicy

import "core:fmt"
import "core:strconv"
import "core:strings"

// Themes from themes.edn (written with config/themes.edn on the first start).

DEFAULT_THEMES :: #load("../config/themes.edn", string)

Color :: [4]u8

Theme :: struct {
	name:   string,
	dark:   bool,
	// ui
	bg, panel, bar, fg, muted, accent, accent_fg, input, border, hover, pressed, sel, warn, ok, err, popup, shadow: Color,
	// schematic
	s_bg, s_grid, s_grid_major, s_wire, s_symbol, s_symbol_fill, s_pin, s_junction, s_ref, s_value, s_text, s_directive, s_label, s_ground, s_select, s_hover, s_net_highlight, s_op_value, s_select_box, s_placing: Color,
	// waveform
	w_bg, w_plot, w_grid, w_axis, w_text, w_cursor1, w_cursor2, w_marker, w_hover, w_zoom_box, w_readout, w_readout_border: Color,
	traces: [dynamic]Color,
}

th: Theme // the current theme
themes: [dynamic]Theme
themes_file: string

Color_Field :: struct {
	group, name: string,
	ptr:         ^Color,
}

theme_fields :: proc(t: ^Theme) -> []Color_Field {
	f := make([dynamic]Color_Field, context.temp_allocator)
	add :: proc(f: ^[dynamic]Color_Field, g, n: string, p: ^Color) {append(f, Color_Field{g, n, p})}
	add(&f, "ui", "bg", &t.bg); add(&f, "ui", "panel", &t.panel); add(&f, "ui", "bar", &t.bar)
	add(&f, "ui", "fg", &t.fg); add(&f, "ui", "muted", &t.muted); add(&f, "ui", "accent", &t.accent)
	add(&f, "ui", "accent-fg", &t.accent_fg); add(&f, "ui", "input", &t.input); add(&f, "ui", "border", &t.border)
	add(&f, "ui", "hover", &t.hover); add(&f, "ui", "pressed", &t.pressed); add(&f, "ui", "sel", &t.sel)
	add(&f, "ui", "warn", &t.warn); add(&f, "ui", "ok", &t.ok); add(&f, "ui", "err", &t.err)
	add(&f, "ui", "popup", &t.popup); add(&f, "ui", "shadow", &t.shadow)
	add(&f, "schematic", "bg", &t.s_bg); add(&f, "schematic", "grid", &t.s_grid); add(&f, "schematic", "grid-major", &t.s_grid_major)
	add(&f, "schematic", "wire", &t.s_wire); add(&f, "schematic", "symbol", &t.s_symbol); add(&f, "schematic", "symbol-fill", &t.s_symbol_fill)
	add(&f, "schematic", "pin", &t.s_pin); add(&f, "schematic", "junction", &t.s_junction); add(&f, "schematic", "ref", &t.s_ref)
	add(&f, "schematic", "value", &t.s_value); add(&f, "schematic", "text", &t.s_text); add(&f, "schematic", "directive", &t.s_directive)
	add(&f, "schematic", "label", &t.s_label); add(&f, "schematic", "ground", &t.s_ground); add(&f, "schematic", "select", &t.s_select)
	add(&f, "schematic", "hover", &t.s_hover); add(&f, "schematic", "net-highlight", &t.s_net_highlight)
	add(&f, "schematic", "op-value", &t.s_op_value); add(&f, "schematic", "select-box", &t.s_select_box); add(&f, "schematic", "placing", &t.s_placing)
	add(&f, "waveform", "bg", &t.w_bg); add(&f, "waveform", "plot", &t.w_plot); add(&f, "waveform", "grid", &t.w_grid)
	add(&f, "waveform", "axis", &t.w_axis); add(&f, "waveform", "text", &t.w_text); add(&f, "waveform", "cursor1", &t.w_cursor1)
	add(&f, "waveform", "cursor2", &t.w_cursor2); add(&f, "waveform", "marker", &t.w_marker); add(&f, "waveform", "hover", &t.w_hover)
	add(&f, "waveform", "zoom-box", &t.w_zoom_box); add(&f, "waveform", "readout", &t.w_readout); add(&f, "waveform", "readout-border", &t.w_readout_border)
	return f[:]
}

mix :: proc(a, b: Color, t: f32) -> Color {
	return {
		u8(f32(a[0]) + (f32(b[0]) - f32(a[0])) * t),
		u8(f32(a[1]) + (f32(b[1]) - f32(a[1])) * t),
		u8(f32(a[2]) + (f32(b[2]) - f32(a[2])) * t),
		u8(f32(a[3]) + (f32(b[3]) - f32(a[3])) * t),
	}
}

alpha :: proc(c: Color, a: u8) -> Color {return {c[0], c[1], c[2], a}}

luma :: proc(c: Color) -> f32 {return (0.299 * f32(c[0]) + 0.587 * f32(c[1]) + 0.114 * f32(c[2])) / 255}

// "#RRGGBB" or "#RRGGBBAA".
parse_color :: proc(s: string) -> (Color, bool) {
	t := strings.trim_prefix(strings.trim_space(s), "#")
	if len(t) != 6 && len(t) != 8 do return {}, false
	v, ok := strconv.parse_u64_of_base(t, 16)
	if !ok do return {}, false
	if len(t) == 6 do return {u8(v >> 16), u8(v >> 8), u8(v), 255}, true
	return {u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)}, true
}

// All colours worked out from bg, fg and accent.
@(private = "file")
derive :: proc(t: ^Theme, bg, fg, ac: Color) {
	dark := luma(bg) < 0.5
	t.dark = dark
	white := Color{255, 255, 255, 255}
	black := Color{0, 0, 0, 255}
	black_text := Color{0x10, 0x10, 0x10, 255}
	t.bg = bg
	t.fg = fg
	t.accent = ac
	// the same rules as zapped and loomer (one look for all three apps)
	t.panel = mix(bg, fg, 0.03) if dark else mix(bg, white, 0.4)
	t.bar = mix(bg, fg, 0.06) if dark else mix(bg, black, 0.03)
	t.muted = mix(bg, fg, 0.6 if dark else 0.55)
	t.accent_fg = black_text if luma(ac) > 0.667 else white
	t.input = mix(bg, black, 0.25) if dark else white
	t.border = mix(bg, fg, 0.2 if dark else 0.25)
	t.hover = mix(bg, fg, 0.12 if dark else 0.08)
	t.pressed = mix(bg, fg, 0.2 if dark else 0.16)
	t.sel = mix(bg, ac, 0.45 if dark else 0.3)
	t.warn = {0xE5, 0xA5, 0x0A, 255} if dark else {0xB4, 0x6E, 0x00, 255}
	t.ok = {0x34, 0xC7, 0x59, 255} if dark else {0x0E, 0x8A, 0x3C, 255}
	t.err = {0xFF, 0x45, 0x3A, 255} if dark else {0xD0, 0x1E, 0x1E, 255}
	t.popup = mix(bg, fg, 0.05)
	t.shadow = {0, 0, 0, 90}

	t.s_bg = mix(bg, black, 0.18) if dark else mix(bg, white, 0.6)
	t.s_grid = mix(t.s_bg, fg, 0.14)
	t.s_grid_major = mix(t.s_bg, fg, 0.3)
	t.s_wire = mix(ac, white, 0.15) if dark else mix(ac, black, 0.2)
	t.s_symbol = mix(fg, white, 0.5) if dark else mix(fg, black, 0.4)
	t.s_symbol_fill = {0, 0, 0, 0}
	t.s_pin = {0xE0, 0x40, 0x40, 255}
	t.s_junction = {} // = wire colour (filled in after overrides)
	t.s_ref = mix(t.s_bg, fg, 0.7)
	t.s_value = fg
	t.s_text = fg
	t.s_directive = {0x30, 0xA0, 0x50, 255} if !dark else {0x7F, 0xD4, 0x8B, 255}
	t.s_label = fg
	t.s_ground = {}
	t.s_select = {0xFF, 0x8C, 0x1A, 255}
	t.s_hover = mix(ac, white, 0.35)
	t.s_net_highlight = {0xFF, 0xD0, 0x40, 255} if dark else {0xE0, 0x90, 0x00, 255}
	t.s_op_value = {0x40, 0xD0, 0x90, 255} if dark else {0x00, 0x80, 0x50, 255}
	t.s_select_box = alpha(ac, 50)
	t.s_placing = alpha(fg, 170)

	t.w_bg = t.s_bg
	t.w_plot = mix(bg, black, 0.25) if dark else white
	t.w_grid = mix(t.w_plot, fg, 0.1)
	t.w_axis = mix(t.w_plot, fg, 0.35)
	t.w_text = mix(bg, fg, 0.75)
	t.w_cursor1 = fg
	t.w_cursor2 = {0xFF, 0xC1, 0x07, 255} if dark else {0xC0, 0x80, 0x00, 255}
	t.w_marker = fg
	t.w_hover = alpha(fg, 110)
	t.w_zoom_box = alpha(ac, 45)
	t.w_readout = {}
	t.w_readout_border = {}
}

themes_load :: proc() {
	clear(&themes)
	text, path := read_config_file("themes.edn", DEFAULT_THEMES)
	themes_file = strings.clone(path)
	themes_parse(strings.clone(text), "themes.edn")
	if len(themes) == 0 {
		config_error("themes.edn: no usable theme – using the built-in themes")
		themes_parse(DEFAULT_THEMES, "built-in themes")
	}
	watch_file(themes_file, settings_reload)
}

@(private = "file")
themes_parse :: proc(text, src: string) {
	v, err := edn_parse(text)
	if len(err) > 0 {
		config_error(tcat(src, ": ", err))
		return
	}
	if !edn_is_coll(v) {
		config_error(tcat(src, ": expected a vector of theme maps [{:name … :bg … :fg … :accent …} …]"))
		return
	}
	for m, i in v.items {
		ctx := fmt.tprintf("%s, theme %d", src, i + 1)
		if m.kind != .Map {
			config_error(tcat(ctx, ": not a map"))
			continue
		}
		name := strings.trim_space(edn_str(m, "name"))
		if is_blank(name) {
			config_error(tcat(ctx, ": :name is missing"))
			continue
		}
		ctx = tcat(src, ", theme \"", name, "\"")
		base: [3]Color
		bad := false
		for k, j in ([3]string{"bg", "fg", "accent"}) {
			c, ok := parse_color(edn_str(m, k))
			if !ok {
				config_error(tcat(ctx, ": :", k, " must be a colour like \"#3C3F41\""))
				bad = true
			}
			base[j] = c
		}
		if bad do continue
		t := Theme{name = strings.clone(name)}
		derive(&t, base[0], base[1], base[2])
		fields := theme_fields(&t)
		for g in ([3]string{"ui", "schematic", "waveform"}) {
			o, ok := edn_get(m, g)
			if !ok || o.kind == .Nil do continue
			if o.kind != .Map {
				config_error(tcat(ctx, ": :", g, " must be a map of colours"))
				continue
			}
			for k := 0; k + 1 < len(o.items); k += 2 {
				key, val := o.items[k].s, o.items[k + 1]
				found: ^Color
				for f in fields do if f.group == g && f.name == key do found = f.ptr
				if found == nil {
					config_error(tcat(ctx, ": unknown colour :", key, " in :", g))
					continue
				}
				c, cok := parse_color(val.s if val.kind == .String else "")
				if !cok {
					config_error(tcat(ctx, ": :", g, " :", key, " must be a colour like \"#3C3F41\""))
					continue
				}
				found^ = c
			}
		}
		// colours that follow others unless set
		if t.s_junction[3] == 0 do t.s_junction = t.s_wire
		if t.s_ground[3] == 0 do t.s_ground = t.s_symbol
		if t.w_readout[3] == 0 do t.w_readout = alpha(mix(t.w_plot, t.fg, 0.08), 235)
		if t.w_readout_border[3] == 0 do t.w_readout_border = mix(t.w_plot, t.fg, 0.3)
		t.traces = make([dynamic]Color)
		if tr, ok := edn_get(m, "traces"); ok && edn_is_coll(tr) {
			for x in tr.items {
				c, cok := parse_color(x.s if x.kind == .String else "")
				if cok do append(&t.traces, c)
				else do config_error(tcat(ctx, ": :traces must hold colours like \"#3C3F41\""))
			}
		}
		if len(t.traces) == 0 {
			append(&t.traces, Color{0x4F, 0xC3, 0xF7, 255}, Color{0xFF, 0x70, 0x43, 255}, Color{0x9C, 0xCC, 0x65, 255}, Color{0xFF, 0xD5, 0x4F, 255}, Color{0xBA, 0x68, 0xC8, 255}, Color{0x4D, 0xB6, 0xAC, 255})
		}
		dup := false
		for x in themes do if x.name == t.name do dup = true
		if dup {
			config_error(tcat(ctx, ": defined twice – the first one is used"))
			continue
		}
		append(&themes, t)
	}
}

// Name of the theme to use: settings.edn wins over the one picked in the menu.
theme_wanted :: proc() -> string {
	if len(S.theme) > 0 do return S.theme
	return pref_get("theme", "Dark")
}

theme_apply :: proc() {
	want := theme_wanted()
	for t in themes do if t.name == want {
		th = t
		return
	}
	if len(themes) > 0 do th = themes[0]
}

trace_color :: proc(i: int) -> Color {
	if len(th.traces) == 0 do return th.fg
	return th.traces[i %% len(th.traces)]
}
