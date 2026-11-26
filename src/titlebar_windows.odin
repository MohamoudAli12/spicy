package spicy

import rl "vendor:raylib"

// Windows draws the title bar itself, so raylib cannot theme it. DWM can: Windows 11
// (build 22000+) takes the exact title bar, title text and border colours; Windows 10
// (1809+) only takes dark or light, and ignores the colour attributes. The main window
// starts hidden and is shown once this is set (gui_main), so it never flashes white.

foreign import dwmapi "system:Dwmapi.lib"
@(private = "file", default_calling_convention = "system")
foreign dwmapi {
	DwmSetWindowAttribute :: proc(hwnd: rawptr, attr: u32, value: rawptr, size: u32) -> i32 ---
}

// GLFW is inside raylib.lib (as for popout.odin's GLFW calls)
foreign import glfw_tb "system:kernel32.lib"
@(private = "file", default_calling_convention = "c")
foreign glfw_tb {
	glfwGetWin32Window :: proc(win: rawptr) -> rawptr ---
}

@(private = "file")
DWMWA_USE_IMMERSIVE_DARK_MODE_OLD :: 19 // Windows 10 before 20H1
@(private = "file")
DWMWA_USE_IMMERSIVE_DARK_MODE :: 20
@(private = "file")
DWMWA_BORDER_COLOR :: 34
@(private = "file")
DWMWA_CAPTION_COLOR :: 35
@(private = "file")
DWMWA_TEXT_COLOR :: 36

// Colours the title bar of a window (an HWND) from the current theme.
titlebar_apply_hwnd :: proc(hwnd: rawptr) {
	if hwnd == nil do return
	dark: i32 = 1 if luma(th.bg) < 0.5 else 0
	if DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, 4) != 0 {
		DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE_OLD, &dark, 4)
	}
	colorref :: proc(c: Color) -> u32 {return u32(c[0]) | u32(c[1]) << 8 | u32(c[2]) << 16}
	caption, text, border := colorref(th.bar), colorref(th.fg), colorref(th.border)
	DwmSetWindowAttribute(hwnd, DWMWA_CAPTION_COLOR, &caption, 4) // the menu bar's colour
	DwmSetWindowAttribute(hwnd, DWMWA_TEXT_COLOR, &text, 4)
	DwmSetWindowAttribute(hwnd, DWMWA_BORDER_COLOR, &border, 4)
}

// A GLFW window (a pop-out).
titlebar_apply_glfw :: proc(win: rawptr) {
	if win != nil do titlebar_apply_hwnd(glfwGetWin32Window(win))
}

// The main window and every pop-out (after a theme change).
titlebar_apply_all :: proc() {
	if !rl.IsWindowReady() do return
	titlebar_apply_hwnd(rl.GetWindowHandle())
	for p in popouts do titlebar_apply_glfw(p.win)
}
