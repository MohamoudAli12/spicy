package spicy

import os "core:os"
import win32 "core:sys/windows"

// Windows: spicy is built as a GUI program (-subsystem:windows), so Windows opens no console
// window for it. Started from a terminal, it borrows that terminal for its output, so
// --netlist, --run, --help … still print there. A pipe or a redirect (scripts, CI, agents)
// is inherited as it is and needs nothing.

@(private = "file")
ATTACH_PARENT_PROCESS :: ~win32.DWORD(0)
@(private = "file")
FILE_TYPE_UNKNOWN :: 0

foreign import kernel32 "system:Kernel32.lib"
@(private = "file", default_calling_convention = "system")
foreign kernel32 {
	SetStdHandle :: proc(nStdHandle: win32.DWORD, hHandle: win32.HANDLE) -> win32.BOOL ---
}

win_console_attach :: proc() {
	no_handle :: proc(code: win32.DWORD) -> bool {
		h := win32.GetStdHandle(code)
		return h == nil || h == win32.INVALID_HANDLE_VALUE || win32.GetFileType(h) == FILE_TYPE_UNKNOWN
	}
	need_out, need_err := no_handle(win32.STD_OUTPUT_HANDLE), no_handle(win32.STD_ERROR_HANDLE)
	if !need_out && !need_err do return
	if !win32.AttachConsole(ATTACH_PARENT_PROCESS) do return // double-clicked: no terminal
	con := win32.CreateFileW(win32.L("CONOUT$"), win32.GENERIC_READ | win32.GENERIC_WRITE,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE, nil, win32.OPEN_EXISTING, 0, nil)
	if con == win32.INVALID_HANDLE_VALUE do return
	f := os.new_file(uintptr(con), "<console>")
	if need_out {
		SetStdHandle(win32.STD_OUTPUT_HANDLE, con)
		os.stdout = f
	}
	if need_err {
		SetStdHandle(win32.STD_ERROR_HANDLE, con)
		os.stderr = f
	}
	// the terminal printed its prompt when spicy started (it does not wait for GUI
	// programs): start the output on a line of its own
	if len(os.args) > 1 do os.write_string(f, "\n")
}
