package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/ease"
import "core:math/linalg"
import "core:math/rand"
import "core:sort"
import sapp "sokol/app"
import sg "sokol/gfx"
import sglue "sokol/glue"
import shelpers "sokol/helpers"
import sdl "vendor:sdl2"

default_context: runtime.Context

Texture :: enum u16 {
	WALL = 0,
	CONCRETE,
	DIRT,
	GORE,
	HOLE,
	BLOOD_1,
	APPLE,
	TIGER,
	PRAY_1,
	PRAY_2,
	BUSH,
	GUN,
}
Texture_UVs: []Vector2i = {
	Texture.WALL     = {0, 0},
	Texture.CONCRETE = {1, 0},
	Texture.DIRT     = {0, 1},
	Texture.GORE     = {1, 1},
	Texture.HOLE     = {2, 0},
	Texture.BLOOD_1  = {2, 1},
	Texture.APPLE    = {0, 2},
	Texture.TIGER    = {1, 2},
	Texture.PRAY_1   = {2, 2},
	Texture.PRAY_2   = {3, 2},
	Texture.BUSH     = {3, 3},
	Texture.GUN      = {0, 3},
}

ATLAS_SIZE_PER_SPRITE :: 256
ATLAS_SIZE :: 1024
ATLAS_SPRITE_COUNT :: ATLAS_SIZE / ATLAS_SIZE_PER_SPRITE

CELL_SIZE :: 128

Transform :: struct {
	position:           Vector2,
	prev_grid_position: Vector2i,
	grid_position:      Vector2i,
	t:                  f32,
}

LAYER_BUSH :: 2
LAYER_PLAYER :: 1
LAYER_GROUND :: 0
Quad :: struct {
	layer:   u8,
	texture: Texture,
}

Player :: distinct bool
Pray :: distinct bool // the tiger wants to eat Pray
Bush :: distinct bool // the tiger needs to hide from hunter behind Bush
Hunter :: struct {
	moves_until_aim: int,
	y_position:      f32, // derived from moves_until_aim
	aiming:          bool,
	quad_size:       f32,
}

Game_State_Playing :: struct {
	hunter: Hunter,
}

Game_State_Paused :: struct {}

Game_State :: union {
	Game_State_Playing,
	Game_State_Paused,
}

Game :: struct {
	camera:             Camera2D,
	world:              World,
	game_state:         Game_State,
	player_inside_bush: bool,
}
g := Game {
	player_inside_bush = false,
}

quad_renderer: Quad_Renderer
basic_renderer: Basic2D_Renderer

main :: proc() {
	// Note: I started this because i watched a youtube video on it, continue it and move it onto an "easier" abstraction layer into engine.odin
	// sdl.InitSubSystem({.AUDIO})
	// spec: sdl.AudioSpec
	// audio_buf: [^]u8
	// audio_len: u32
	// assert(sdl.LoadWAV("song.wav", &spec, &audio_buf, &audio_len) != nil)

	when ODIN_OS == .JS {
		context.allocator = {
			procedure = emscripten_allocator_proc,
		}
		// Both persistent and temporary allocations must share Emscripten's heap.
		runtime.default_temp_allocator_init(
			&runtime.global_default_temp_allocator_data,
			4 * 1024 * 1024,
			context.allocator,
		)
	}
	context.logger = log.create_console_logger()
	default_context = context

	sapp.run(
		{
			width = CELL_SIZE * 8,
			height = CELL_SIZE * 8,
			window_title = "Hello Sokol",
			allocator = sapp.Allocator(shelpers.allocator(&default_context)),
			logger = sapp.Logger(shelpers.logger(&default_context)),
			init_cb = init_cb,
			frame_cb = frame_cb,
			cleanup_cb = cleanup_cb,
			event_cb = event_cb,
			fullscreen = false,
		},
	)
}

init_cb :: proc "c" () {
	context = default_context

	random_color :: proc() -> [4]f32 {
		r := rand.float32_range(0, 1)
		g := rand.float32_range(0, 1)
		b := rand.float32_range(0, 1)
		return {r, g, b, 1.0}
	}
	random_position :: proc() -> [2]f32 {
		x := rand.float32_range(0, 800)
		y := rand.float32_range(0, 800)
		return {x, y}
	}

	g.camera = {
		position = {0, 0},
		zoom     = 1,
	}

	sg.setup(
		{
			environment = sglue.environment(),
			allocator = sg.Allocator(shelpers.allocator(&default_context)),
			logger = sg.Logger(shelpers.logger(&default_context)),
		},
	)

	g.game_state = Game_State_Playing {
		hunter = {aiming = false, moves_until_aim = 3, y_position = 0, quad_size = 300},
	}

	quad_renderer_init(&quad_renderer, "atlas.png")

	basic2d_init(&basic_renderer)
	basic2d_add_entry(&basic_renderer, "basic", basic_shader_desc)

	entity_world_init(&g.world)
	spawn_player({0, 0})
	for x in 0 ..< 8 {
		for y in 0 ..< 8 {
			spawn_quad({x, y}, .GORE, LAYER_GROUND)
		}
	}
	spawn_pray({3, 2})
	spawn_pray({2, 5})
	spawn_pray({6, 4})

	spawn_bush({2, 1})
	spawn_bush({3, 1})
	spawn_bush({4, 4})
	spawn_bush({4, 5})
}

cleanup_cb :: proc "c" () {
	context = default_context

	quad_renderer_destroy(&quad_renderer)

	sg.shutdown()
}

grid_to_world :: proc(grid_position: Vector2i) -> Vector2 {
	return {f32(grid_position.x), f32(grid_position.y)} * CELL_SIZE
}

spawn_quad :: proc(grid_position: Vector2i, texture: Texture, layer: u8) {
	entity := entity_create(&g.world)
	start_position :=
		grid_to_world(grid_position) +
		{rand.float32_range(-200, 200), rand.float32_range(-200, 200)}
	component_storage_add(
		&g.world.transforms,
		entity,
		Transform {
			grid_position = grid_position,
			position = start_position,
			prev_grid_position = grid_position + {rand.int_range(-1, 2), rand.int_range(-1, 2)},
			t = 0,
		},
	)
	component_storage_add(&g.world.quads, entity, Quad{texture = texture, layer = layer})
}

spawn_player :: proc(grid_position: Vector2i) {
	entity := entity_create(&g.world)
	component_storage_add(
		&g.world.transforms,
		entity,
		Transform {
			grid_position = grid_position,
			position = grid_to_world(grid_position),
			t = 1,
			prev_grid_position = grid_position,
		},
	)
	component_storage_add(&g.world.quads, entity, Quad{texture = .TIGER, layer = LAYER_PLAYER})
	component_storage_add(&g.world.players, entity, true)
}

spawn_pray :: proc(grid_position: Vector2i) {
	entity := entity_create(&g.world)
	component_storage_add(
		&g.world.transforms,
		entity,
		Transform {
			grid_position = grid_position,
			position = grid_to_world(grid_position),
			t = 1,
			prev_grid_position = grid_position,
		},
	)
	texture := Texture.PRAY_1
	if rand.int_range(0, 2) == 1 {
		texture = .PRAY_2
	}
	component_storage_add(&g.world.quads, entity, Quad{texture = texture, layer = LAYER_PLAYER})
	component_storage_add(&g.world.prays, entity, true)
}

spawn_bush :: proc(grid_position: Vector2i) {
	entity := entity_create(&g.world)
	component_storage_add(
		&g.world.transforms,
		entity,
		Transform {
			grid_position = grid_position,
			position = grid_to_world(grid_position),
			t = 1,
			prev_grid_position = grid_position,
		},
	)
	component_storage_add(&g.world.quads, entity, Quad{texture = Texture.BUSH, layer = LAYER_BUSH})
	component_storage_add(&g.world.bushes, entity, true)
}

update_hunter :: proc() {
	state, ok := &g.game_state.(Game_State_Playing)
	assert(ok)
	y_aiming := sapp.heightf() - state.hunter.quad_size
	y_hidden := sapp.heightf()
	t: f32 = clamp(1.0 - (f32(state.hunter.moves_until_aim) / 3.0), 0.0, 1.0)
	state.hunter.y_position = math.lerp(y_hidden, y_aiming, t)
}


draw_hunter :: proc() {
	state, ok := &g.game_state.(Game_State_Playing)
	assert(ok)
	quad_renderer_submit(
		&quad_renderer,
		{sapp.widthf() - 300, state.hunter.y_position},
		{1.0, 1.0} * state.hunter.quad_size,
		{1, 1, 1, 1},
		get_uv_rect(.GUN),
	)
}

draw_quads :: proc() {
	Draw_Command :: struct {
		transform: ^Transform,
		quad:      ^Quad,
	}
	to_draw := make([dynamic]Draw_Command, context.temp_allocator)

	for entity in g.world.quads.entities {
		quad := component_storage_get(&g.world.quads, entity)
		transform := component_storage_get(&g.world.transforms, entity)
		append(&to_draw, Draw_Command{quad = quad, transform = transform})
	}

	sort.bubble_sort_proc(to_draw[:], proc(a: Draw_Command, b: Draw_Command) -> int {
		return a.quad.layer > b.quad.layer ? 1 : -1
	})

	for draw_command in to_draw {
		transform := draw_command.transform
		quad := draw_command.quad
		quad_renderer_submit(
			&quad_renderer,
			transform.position,
			{CELL_SIZE, CELL_SIZE},
			{1, 1, 1, 1},
			get_uv_rect(quad.texture),
		)
	}
}

update_transforms :: proc(dt: f32) {
	for entity in g.world.transforms.entities {
		transform := component_storage_get(&g.world.transforms, entity)

		transform.t = min(1.0, transform.t + dt * 3)
		t := ease.cubic_in_out(transform.t)
		from := grid_to_world(transform.prev_grid_position)
		to := grid_to_world(transform.grid_position)
		transform.position = linalg.lerp(from, to, t)
	}
}

update_general :: proc() {
	if input_key_pressed(.ESCAPE) {
		switch state in g.game_state {
		case Game_State_Playing:
			g.game_state = Game_State_Paused{}
		case Game_State_Paused:
			g.game_state = Game_State_Playing{}
		}
	}
}

update_player :: proc() {
	if len(g.world.players.entities) == 0 {
		return
	}

	entity := g.world.players.entities[0]

	transform := component_storage_get(&g.world.transforms, entity)
	if input_key_pressed(.D) {
		move_player(transform, {1, 0})
	}
	if input_key_pressed(.A) {
		move_player(transform, {-1, 0})
	}
	if input_key_pressed(.S) {
		move_player(transform, {0, 1})
	}
	if input_key_pressed(.W) {
		move_player(transform, {0, -1})
	}
}

update_camera :: proc(dt: f32) {
	camera_speed :: 200
	if input_key_down(sapp.Keycode.RIGHT) {
		g.camera.position.x += camera_speed * dt
	} else if input_key_down(sapp.Keycode.LEFT) {
		g.camera.position.x -= camera_speed * dt
	} else if input_key_down(sapp.Keycode.DOWN) {
		g.camera.position.y -= camera_speed * dt
	} else if input_key_down(sapp.Keycode.UP) {
		g.camera.position.y += camera_speed * dt
	}
	if input_key_down(sapp.Keycode.E) {
		g.camera.zoom += 1 * dt
	} else if input_key_down(sapp.Keycode.Q) {
		g.camera.zoom -= 1 * dt
	}
}

move_player :: proc(transform: ^Transform, direction: Vector2i) {
	state, is_correct_state := &g.game_state.(Game_State_Playing)
	if transform.t >= 1.0 - math.F32_EPSILON && is_correct_state && !state.hunter.aiming {
		transform.prev_grid_position = transform.grid_position
		transform.t = 0
		transform.grid_position += direction
		state.hunter.moves_until_aim -= 1
		if state.hunter.moves_until_aim == -1 {
			state.hunter.moves_until_aim = 3
		}
	}

	// Check if we're standing inside a bush
	g.player_inside_bush = false
	for entity in g.world.bushes.entities {
		bush_transform := component_storage_get(&g.world.transforms, entity)
		if bush_transform.grid_position == transform.grid_position {
			g.player_inside_bush = true
		}
	}

	if is_correct_state && state.hunter.moves_until_aim == 0 {
		fmt.println("...aiming")
		if g.player_inside_bush {
			fmt.println("missed!")
		} else {
			fmt.println("shot!")
		}
	}
}

time: f32 = 0

frame_cb :: proc "c" () {
	context = default_context
	frame_duration := sapp.frame_duration()
	dt := f32(frame_duration)
	time += dt

	{
		switch state in g.game_state {
		case Game_State_Playing:
			update_player()
			update_camera(f32(frame_duration))
			update_hunter()
		case Game_State_Paused:
		}
		update_transforms(dt)
		update_general()
	}

	{
		sg.begin_pass({swapchain = sglue.swapchain()})

		quad_renderer_begin(&quad_renderer, g.camera)

		switch state in g.game_state {
		case Game_State_Playing:
			draw_quads()
			draw_hunter()
		case Game_State_Paused:
		}

		quad_renderer_end(&quad_renderer)

		basic2d_bind(&basic_renderer, "basic")
		basic2d_draw(
			&basic_renderer,
			{0, 0},
			{sapp.widthf(), sapp.heightf()},
			{0.8, 0.2, 0.0, 0.2},
			&g.camera,
			Basic_Params{},
			proc(pass: ^Basic_Params) {
				if g.player_inside_bush {
					pass.color = {0, 0, 0, 0.5}
				}
			},
		)

		sg.end_pass()

		sg.commit()
	}

	input_frame_end()
	free_all(context.temp_allocator)
}

event_cb :: proc "c" (ev: ^sapp.Event) {
	context = default_context
	input_process_event(ev)
}

get_uv_rect :: proc(texture: Texture) -> Vector4 {
	cell := Texture_UVs[texture]
	uv_size :: f32(ATLAS_SIZE_PER_SPRITE) / f32(ATLAS_SIZE)
	return {
		f32(cell.x) * uv_size,
		f32(cell.y) * uv_size,
		f32(cell.x + 1) * uv_size,
		f32(cell.y + 1) * uv_size,
	}
}
