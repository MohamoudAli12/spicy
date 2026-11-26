#+build !windows
package spicy

// Only Windows needs this: see win_console_windows.odin.
win_console_attach :: proc() {}
