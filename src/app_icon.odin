package spicy

import "core:c"
import rl "vendor:raylib"

// The program icon, built into the binary. Windows also gets it from the
// resource in assets/spicy.rc (Explorer, the taskbar before a window opens);
// macOS takes it as the Dock icon (app_icon_darwin.odin). The small sizes come
// from assets/logo-small.svg, the larger ones from assets/logo.svg.
@(private = "file")
ICON_PNGS := [?][]u8 {
	#load("../assets/icons/16.png"),
	#load("../assets/icons/24.png"),
	#load("../assets/icons/32.png"),
	#load("../assets/icons/48.png"),
	#load("../assets/icons/64.png"),
	#load("../assets/icons/128.png"),
	#load("../assets/icons/256.png"),
}

@(private = "file")
ICON_PNG_LARGE :: #load("../assets/icons/512.png")

when ODIN_OS == .Windows {
	foreign import glfw_icon "system:kernel32.lib"
} else {
	foreign import glfw_icon "system:c"
}

@(private = "file")
Glfw_Image :: struct {
	width, height: c.int,
	pixels:        [^]u8,
}

@(default_calling_convention = "c", private = "file")
foreign glfw_icon {
	glfwSetWindowIcon :: proc(w: rawptr, count: c.int, images: [^]Glfw_Image) ---
}

@(private = "file")
icon_images: [len(ICON_PNGS)]Glfw_Image
@(private = "file")
icon_count: int
@(private = "file")
icon_loaded: bool

// Sets the icon of a GLFW window (the main one or a pop-out). GLFW ignores
// it on macOS and on native Wayland, where the desktop entry names the icon.
app_icon_apply :: proc(win: rawptr) {
	if win == nil do return
	when ODIN_OS == .Darwin {
		app_icon_dock(ICON_PNG_LARGE)
	} else {
		glfw_icon_set(win)
	}
}

@(private = "file")
glfw_icon_set :: proc(win: rawptr) {
	if !icon_loaded {
		icon_loaded = true
		for png in ICON_PNGS {
			img := rl.LoadImageFromMemory(".png", raw_data(png), c.int(len(png)))
			if img.data == nil do continue
			rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8A8) // kept for the program's lifetime
			icon_images[icon_count] = {img.width, img.height, cast([^]u8)img.data}
			icon_count += 1
		}
	}
	if icon_count > 0 do glfwSetWindowIcon(win, c.int(icon_count), &icon_images[0])
}
