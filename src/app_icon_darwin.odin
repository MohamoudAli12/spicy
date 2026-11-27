package spicy

import "base:intrinsics"
import NS "core:sys/darwin/Foundation"

// The Dock icon. A bare binary has no app bundle to take it from, so it is
// set at run time; it shows while spicy runs.
app_icon_dock :: proc(png: []u8) {
	@(static) done: bool
	if done do return
	done = true
	data := NS.Data.alloc()->initWithBytes(png)
	defer data->release()
	img := intrinsics.objc_send(^NS.Image, NS.Image.alloc(), "initWithData:", data)
	if img == nil do return
	defer img->release()
	intrinsics.objc_send(nil, NS.Application.sharedApplication(), "setApplicationIconImage:", img)
}
