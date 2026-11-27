package spicy

import "core:c/libc"

// The few C runtime functions spicy calls directly (ported from loomer, src/crt.odin).
//
// Windows: Odin's core:c/libc links the *static* C runtime (libucrt.lib), but the
// raylib.lib shipped with Odin is built against the *DLL* runtime (ucrt.lib).
// Calling anything from core:c/libc puts both in one link and MSVC fails with
// LNK2005 "already defined" errors. So on Windows these go to ucrt.lib, the same
// runtime raylib uses, and no core:c/libc procedure may be called anywhere.
// (Odin only links a foreign library when one of its procedures is called, so
// using libc types and constants is fine.)

when ODIN_OS == .Windows {
	foreign import ucrt {
		"system:ucrt.lib",
		"system:legacy_stdio_definitions.lib", // vsnprintf is inline in the UCRT headers
	}

	@(default_calling_convention = "c")
	foreign ucrt {
		@(link_name = "_time64") _crt_time :: proc(timer: ^libc.time_t) -> libc.time_t ---
		@(link_name = "_localtime64") _crt_localtime :: proc(timer: ^libc.time_t) -> ^libc.tm ---
		@(link_name = "vsnprintf") _crt_vsnprintf :: proc(s: [^]u8, n: uint, format: cstring, arg: ^libc.va_list) -> i32 --- // size_t, int
	}

	crt_time :: proc "contextless" () -> libc.time_t {return _crt_time(nil)}
	crt_localtime :: proc "contextless" (t: ^libc.time_t) -> ^libc.tm {return _crt_localtime(t)}
	crt_vsnprintf :: proc "contextless" (buf: []u8, format: cstring, args: ^libc.va_list) -> int {
		return int(_crt_vsnprintf(raw_data(buf), uint(len(buf)), format, args))
	}
} else {
	crt_time :: proc "contextless" () -> libc.time_t {return libc.time(nil)}
	crt_localtime :: proc "contextless" (t: ^libc.time_t) -> ^libc.tm {return libc.localtime(t)}
	crt_vsnprintf :: proc "contextless" (buf: []u8, format: cstring, args: ^libc.va_list) -> int {
		return int(libc.vsnprintf(raw_data(buf), len(buf), format, args))
	}
}
