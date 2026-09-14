@header package main
@header import sg "sokol/gfx"

@vs vs

layout(binding = 0) uniform vs_params {
    mat4 view_projection;
};

in vec2 pos;
in vec2 uv;

in vec2 instance_pos;
in vec4 instance_color;
in vec4 instance_uv_rect;
in vec2 instance_size;

out vec4 color;
out vec2 tex_coords;

void main() {
    vec2 world_pos = pos * instance_size + instance_pos;
    gl_Position = view_projection * vec4(world_pos, 0, 1);
    color = instance_color;
    tex_coords = mix(instance_uv_rect.xy, instance_uv_rect.zw, uv);
}
@end

@fs fs

out vec4 out_color;
in vec4 color;
in vec2 tex_coords;

layout(binding = 0) uniform texture2D tex;
layout(binding = 0) uniform sampler smp;

void main() {
    out_color = texture(sampler2D(tex, smp), tex_coords) * color;
}
@end

@program main vs fs