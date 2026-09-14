#+build js
package stb

// Link against stb_image.c built by emcc, not Odin's standalone Wasm libc shim.
foreign import lib "env.o"

@(default_calling_convention = "c", link_prefix = "stbi_")
foreign lib {
	load_from_memory :: proc(buffer: [^]u8, len: i32, x, y, channels: ^i32, desired_channels: i32) -> [^]u8 ---
	image_free :: proc(pixels: rawptr) ---
}
