#+build !windows
package spicy

// Only Windows lets a program colour its title bar: see titlebar_windows.odin.
titlebar_apply_all :: proc() {}
titlebar_apply_glfw :: proc(win: rawptr) {}
