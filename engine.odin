package main

import "core:fmt"
import "core:math/linalg/glsl"
import sapp "sokol/app"
import sg "sokol/gfx"
import sglue "sokol/glue"
import shelpers "sokol/helpers"
import stbi "stb"

Vector2i :: [2]int
Vector2 :: [2]f32
Vector4 :: [4]f32

/* *** 0. Entity World stuff *** */

Component_Storage :: struct($T: typeid) {
	sparse:   [dynamic]int, // entity id -> dense index, -1 if missing
	entities: [dynamic]Entity_ID, // dense index -> entity id
	data:     [dynamic]T, // dense index -> component data
}

INVALID_COMPONENT_INDEX :: -1

component_storage_ensure_sparse :: proc(storage: ^Component_Storage($T), entity: Entity_ID) {
	id := int(entity)

	for len(storage.sparse) <= id {
		append(&storage.sparse, INVALID_COMPONENT_INDEX)
	}
}

component_storage_has :: proc(storage: ^Component_Storage($T), entity: Entity_ID) -> bool {
	id := int(entity)

	if id < 0 || id >= len(storage.sparse) {
		return false
	}

	index := storage.sparse[id]
	return index != INVALID_COMPONENT_INDEX
}

component_storage_get :: proc(storage: ^Component_Storage($T), entity: Entity_ID) -> ^T {
	if !component_storage_has(storage, entity) {
		return nil
	}

	return &storage.data[storage.sparse[int(entity)]]
}

component_storage_add :: proc(
	storage: ^Component_Storage($T),
	entity: Entity_ID,
	component: T,
) -> ^T {
	component_storage_ensure_sparse(storage, entity)

	id := int(entity)
	index := storage.sparse[id]

	if index != INVALID_COMPONENT_INDEX {
		storage.data[index] = component
		return &storage.data[index]
	}

	index = len(storage.data)
	storage.sparse[id] = index
	append(&storage.entities, entity)
	append(&storage.data, component)

	return &storage.data[index]
}

component_storage_remove :: proc(storage: ^Component_Storage($T), entity: Entity_ID) {
	if !component_storage_has(storage, entity) {
		return
	}

	// Move the entity we want to remove to the last index, swap with whatever is currently last, then pop

	id := int(entity)
	index := storage.sparse[id]
	last_index := len(storage.data) - 1
	last_entity := storage.entities[last_index]

	storage.data[index] = storage.data[last_index]
	storage.entities[index] = last_entity
	storage.sparse[int(last_entity)] = index

	pop(&storage.data)
	pop(&storage.entities)

	storage.sparse[id] = INVALID_COMPONENT_INDEX
}

component_storage_destroy :: proc(storage: ^Component_Storage($T)) {
	delete(storage.sparse)
	delete(storage.entities)
	delete(storage.data)
}

Entity_ID :: distinct int

/* COMPONENTS */
World_Message :: union {}

World :: struct {
	entities:       [dynamic]Entity_ID,
	free_entities:  [dynamic]Entity_ID,
	next_entity_id: Entity_ID,
	transforms:     Component_Storage(Transform),
	quads:          Component_Storage(Quad),
	players:        Component_Storage(Player),
	messages:       [dynamic]World_Message,
}

entity_world_init :: proc(world: ^World) {
	ESTIMATED_ENTITIES_SPAWN_AT_START :: 256
	world.entities = make([dynamic]Entity_ID, 0, ESTIMATED_ENTITIES_SPAWN_AT_START)
	world.free_entities = make([dynamic]Entity_ID, 0, ESTIMATED_ENTITIES_SPAWN_AT_START)
}

entity_world_destroy :: proc(world: ^World) {
	delete(world.entities)
	delete(world.free_entities)

	component_storage_destroy(&world.transforms)
	component_storage_destroy(&world.quads)
	component_storage_destroy(&world.players)

	world^ = World{}
}

entity_create :: proc(world: ^World) -> Entity_ID {
	// mutates 'entities' & 'free_entities' & 'next_entity_id'
	entity: Entity_ID
	if len(world.free_entities) > 0 {
		last := len(world.free_entities) - 1
		entity = world.free_entities[last]
		pop(&world.free_entities)
	} else {
		entity = world.next_entity_id
		world.next_entity_id += 1
	}

	append(&world.entities, entity)
	return entity
}

entity_destroy :: proc(world: ^World, entity: Entity_ID) {
	if !entity_alive(world, entity) {
		return
	}

	component_storage_remove(&world.transforms, entity)
	component_storage_remove(&world.quads, entity)
	component_storage_remove(&world.players, entity)

	entity_remove_active(world, entity)
	append(&world.free_entities, entity)
}

entity_remove_active :: proc(world: ^World, entity: Entity_ID) {
	// take the last entity, swap it with the entity we want to remove, then pop
	for i := 0; i < len(world.entities); i += 1 {
		if world.entities[i] == entity {
			last := len(world.entities) - 1
			world.entities[i] = world.entities[last]
			pop(&world.entities)
			return
		}
	}
}

entity_alive :: proc(world: ^World, entity: Entity_ID) -> bool {
	for e in world.entities {
		if e == entity {
			return true
		}
	}
	return false
}

entity_world_send_message :: proc(world: ^World, message: World_Message) {
	append(&world.messages, message)
}

entity_world_clear_message :: proc(world: ^World) {
	clear_dynamic_array(&world.messages)
}

/** 1. Renderers **/

Vertex_Data :: struct {
	position: [2]f32,
	uv:       [2]f32,
}

Instance_Data :: struct {
	position: Vector2,
	size:     Vector2,
	color:    Vector4,
	uv_rect:  Vector4,
}

Camera2D :: struct {
	position: Vector2,
	zoom:     f32,
}

Quad_Renderer :: struct {
	shader:          sg.Shader,
	pipeline:        sg.Pipeline,
	vertex_buffer:   sg.Buffer,
	index_buffer:    sg.Buffer,
	image:           sg.Image,
	sampler:         sg.Sampler,
	view:            sg.View,
	instance_buffer: sg.Buffer,
	instance_data:   [dynamic]Instance_Data,
}

sg_range :: proc(s: []$T) -> sg.Range {
	return {ptr = raw_data(s), size = len(s) * size_of(s[0])}
}

sg_range_of :: proc(d: ^$T) -> sg.Range {
	return {ptr = rawptr(d), size = size_of(T)}
}

/* ** 1.1 Basic Quad Renderer ** */

quad_renderer_init :: proc(quad_renderer: ^Quad_Renderer) {
	quad_renderer.instance_data = make([dynamic]Instance_Data, context.allocator)

	quad_renderer.shader = sg.make_shader(main_shader_desc(sg.query_backend()))
	quad_renderer.pipeline = sg.make_pipeline(
		{
			shader = quad_renderer.shader,
			layout = {
				buffers = {
					0 = {stride = i32(size_of(Vertex_Data))},
					1 = {stride = i32(size_of(Instance_Data)), step_func = .PER_INSTANCE},
				},
				attrs = {
					ATTR_main_pos = {
						buffer_index = 0,
						offset = i32(offset_of(Vertex_Data, position)),
						format = .FLOAT2,
					},
					ATTR_main_uv = {
						buffer_index = 0,
						offset = i32(offset_of(Vertex_Data, uv)),
						format = .FLOAT2,
					},
					ATTR_main_instance_pos = {
						buffer_index = 1,
						offset = i32(offset_of(Instance_Data, position)),
						format = .FLOAT2,
					},
					ATTR_main_instance_size = {
						buffer_index = 1,
						offset = i32(offset_of(Instance_Data, size)),
						format = .FLOAT2,
					},
					ATTR_main_instance_color = {
						buffer_index = 1,
						offset = i32(offset_of(Instance_Data, color)),
						format = .FLOAT4,
					},
					ATTR_main_instance_uv_rect = {
						buffer_index = 1,
						offset = i32(offset_of(Instance_Data, uv_rect)),
						format = .FLOAT4,
					},
				},
			},
			index_type = .UINT16,
			colors = {
				0 = {
					blend = {
						enabled = true,
						src_factor_rgb = sg.Blend_Factor.SRC_ALPHA,
						dst_factor_rgb = sg.Blend_Factor.ONE_MINUS_SRC_ALPHA,
						src_factor_alpha = sg.Blend_Factor.ONE,
						dst_factor_alpha = sg.Blend_Factor.ONE_MINUS_SRC_ALPHA,
					},
				},
			},
		},
	)

	//     .src_factor_rgb = SG_BLENDFACTOR_SRC_ALPHA,
	// .dst_factor_rgb = SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
	// .src_factor_alpha = SG_BLENDFACTOR_ONE,
	// .dst_factor_alpha = SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,


	vertices := []Vertex_Data {
		{position = {0, 0}, uv = {0, 0}},
		{position = {1.0, 0}, uv = {1, 0}},
		{position = {0, 1.0}, uv = {0, 1}},
		{position = {1.0, 1.0}, uv = {1, 1}},
	}
	quad_renderer.vertex_buffer = sg.make_buffer({data = sg_range(vertices)})

	indices := []u16{0, 1, 2, 2, 1, 3}
	quad_renderer.index_buffer = sg.make_buffer(
		{usage = {index_buffer = true}, data = sg_range(indices)},
	)

	atlas_bytes := #load("atlas.png", []u8)
	w, h: i32
	pixels := stbi.load_from_memory(raw_data(atlas_bytes), i32(len(atlas_bytes)), &w, &h, nil, 4)
	assert(pixels != nil)

	quad_renderer.image = sg.make_image(
		{
			width = w,
			height = h,
			pixel_format = .RGBA8,
			data = {mip_levels = {0 = {ptr = pixels, size = uint(w * h * 4)}}},
		},
	)
	stbi.image_free(pixels)

	quad_renderer.sampler = sg.make_sampler({})

	quad_renderer.view = sg.make_view({texture = {image = quad_renderer.image}})

	// Create g.instance_buffer?
	quad_renderer.instance_buffer = sg.make_buffer(
		{size = 1024 * size_of(Instance_Data), usage = {dynamic_update = true}},
	)
}

quad_renderer_begin :: proc(qr: ^Quad_Renderer, camera: Camera2D) {
	screen_width := sapp.widthf()
	screen_height := sapp.heightf()

	sg.apply_pipeline(qr.pipeline)

	// Create our shader uniform data and upload it
	half_width := screen_width / 2.0
	half_height := screen_height / 2.0
	params: Vs_Params
	projection := glsl.mat4Ortho3d(0, screen_width, screen_height, 0, -1, 1)
	view :=
		glsl.mat4Scale({camera.zoom, camera.zoom, 1}) *
		glsl.mat4Translate({-camera.position.x, -camera.position.y, 0})
	view_projection := projection * view
	params.view_projection = transmute([16]f32)view_projection
	sg.apply_uniforms(UB_vs_params, sg_range_of(&params))

	clear(&qr.instance_data)
}

quad_renderer_submit :: proc(
	qr: ^Quad_Renderer,
	position: Vector2,
	size: Vector2,
	color: Vector4,
	uv_rect: Vector4,
) {
	append(
		&qr.instance_data,
		Instance_Data{position = position, size = size, color = color, uv_rect = uv_rect},
	)
}

quad_renderer_end :: proc(qr: ^Quad_Renderer) {
	// Upload some data to the GPU
	count := len(qr.instance_data)
	if count == 0 {
		return
	}
	assert(count <= 1024)

	sg.update_buffer(qr.instance_buffer, sg_range(qr.instance_data[:]))

	sg.apply_bindings(
		{
			vertex_buffers = {0 = qr.vertex_buffer, 1 = qr.instance_buffer},
			index_buffer = qr.index_buffer,
			samplers = {SMP_smp = qr.sampler},
			views = {VIEW_tex = qr.view},
		},
	)


	// Commit to an actual draw call
	sg.draw(0, 6, count)

	clear(&qr.instance_data)
}

quad_renderer_destroy :: proc(quad_renderer: ^Quad_Renderer) {
	sg.destroy_view(quad_renderer.view)
	sg.destroy_image(quad_renderer.image)
	sg.destroy_sampler(quad_renderer.sampler)
	sg.destroy_buffer(quad_renderer.index_buffer)
	sg.destroy_buffer(quad_renderer.vertex_buffer)
	sg.destroy_shader(quad_renderer.shader)
	sg.destroy_pipeline(quad_renderer.pipeline)
	sg.destroy_buffer(quad_renderer.instance_buffer)
	delete(quad_renderer.instance_data)
}

/* *** 2. Utility *** */

/* ** 2.1 Elapsed Timer ** */

ElapsedTimer :: struct {
	s:          f32,
	interval_s: f32,
	playing:    bool,
}

elapsed_timer_start :: proc(timer: ^ElapsedTimer, interval_s: f32) {
	timer.s = 0
	timer.interval_s = interval_s
}

elapsed_timer_frame_tick :: proc(timer: ^ElapsedTimer, dt: f32) {
	timer.s += dt
}

elapsed_timer_triggered :: proc(timer: ^ElapsedTimer) -> bool {
	if !timer.playing {
		return false
	}

	if timer.s >= timer.interval_s {
		timer.s = 0
		return true
	}
	return false
}

elapsed_timer_reset :: proc(timer: ^ElapsedTimer) {
	timer.s = 0
	timer.playing = true
}

/* *** 3. Input *** */

Input :: struct {
	key_down:    [400]bool,
	key_pressed: [400]bool,
}

input: Input

input_process_event :: proc(ev: ^sapp.Event) {
	if ev.type == .KEY_DOWN {
		if !ev.key_repeat && !input.key_down[ev.key_code] {
			input.key_pressed[ev.key_code] = true
		}
		input.key_down[ev.key_code] = true
	} else if ev.type == .KEY_UP {
		input.key_down[ev.key_code] = false
	}
}

input_frame_end :: proc() {
	// Keep presses latched until all game logic for this frame has read them.
	input.key_pressed = false
}

input_key_down :: proc(keycode: sapp.Keycode) -> bool {
	return input.key_down[keycode]
}

input_key_pressed :: proc(keycode: sapp.Keycode) -> bool {
	return input.key_pressed[keycode]
}
