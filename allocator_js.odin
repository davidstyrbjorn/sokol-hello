#+build js
package main

import "core:mem"

foreign import emscripten "env.o"
foreign emscripten {
	posix_memalign :: proc "c" (ptr: ^rawptr, alignment, size: uint) -> i32 ---
	@(link_name="free")
	c_free :: proc "c" (ptr: rawptr) ---
}

// Emscripten owns memory growth; Odin's standalone Wasm allocator must not compete with it.
emscripten_allocator_proc :: proc(
	data: rawptr, mode: mem.Allocator_Mode, size, alignment: int,
	old_memory: rawptr, old_size: int, loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if size == 0 { return nil, nil }
		ptr: rawptr
		if posix_memalign(&ptr, uint(max(alignment, size_of(rawptr))), uint(size)) != 0 {
			return nil, .Out_Of_Memory
		}
		bytes := mem.byte_slice(ptr, size)
		if mode == .Alloc { mem.zero(ptr, size) }
		return bytes, nil
	case .Free:
		c_free(old_memory)
	case .Resize:
		return mem.default_resize_bytes_align(mem.byte_slice(old_memory, old_size), size, alignment, {procedure = emscripten_allocator_proc}, loc)
	case .Resize_Non_Zeroed:
		return mem.default_resize_bytes_align_non_zeroed(mem.byte_slice(old_memory, old_size), size, alignment, {procedure = emscripten_allocator_proc}, loc)
	case .Query_Features:
		if old_memory != nil {
			(^mem.Allocator_Mode_Set)(old_memory)^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}
		}
	case .Free_All, .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, nil
}
