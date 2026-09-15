@header package main
@header import sg "sokol/gfx"

@vs vs

layout(binding = 0) uniform basic_params {
    mat4 model_view_projection;
    vec4 color;
};

in vec2 pos;

out vec4 _color;

void main() {
    gl_Position = model_view_projection * vec4(pos, 0, 1);
    _color = color;
}
@end

@fs fs

out vec4 out_color;
in vec4 _color;

void main() {
    out_color = _color;
}
@end

@program basic vs fs