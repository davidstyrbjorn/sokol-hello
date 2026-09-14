# Hello Sokol

Normal Linux and browser builds, with no hot reload or dependency downloads.

## Prerequisites

- Python 3 and Odin on `PATH` (this machine: `/home/dave/dev/Odin`).
- The local `sokol/` bindings and C headers, and executable `./sokol-shdc`.
- Linux x86-64: C compiler, `ar`, and development libraries for X11, Xi,
  Xcursor, OpenGL, and pthreads. Odin's native stb image library must be built
  (if missing, follow Odin's diagnostic to build `vendor/stb/src`).
- Web: Emscripten's `emcc` and `emar` on `PATH` (this machine:
  `/usr/lib/emscripten`), and a browser supporting WebGL 2 and WebAssembly.

## Build

```sh
python3 build.py                       # Linux debug by default
python3 build.py -linux -debug
python3 build.py -linux -release
python3 build.py -web -debug
python3 build.py -web -release
```

Native executables are `build/linux/{debug,release}/sokol-hello`.
Web output is `build/web/{debug,release}/` (serve the whole directory).
Add `-compile-sokol` to rebuild the three required Sokol libraries for the
selected target and mode; missing libraries are built automatically. Use this
after changing Sokol headers or compilers. No dependency trees are removed.

Debug enables Odin debugging, Sokol validation, and Emscripten debug information
and assertions. Release optimizes without disabling Odin bounds checks or
assertions. Both GLSL 4.10 and GLSL ES 3.00 are generated into `shader.odin` on
every build; run builds sequentially because that generated file is shared.

```sh
./build/linux/debug/sokol-hello
python3 -m http.server 8000 --directory build/web/debug
# Open http://localhost:8000/
```

Arrow keys move the camera; Q/E zoom. The texture atlas is embedded by Odin's
`#load`, so no runtime asset paths or Emscripten preload files are required.
Edit `web/index_template.html`, not generated HTML. The loader combines Odin
and Emscripten imports and starts Odin after Emscripten initializes; Sokol owns
the browser frame loop. The small web-only stb binding compiles Odin's existing
stb header with Emscripten instead of linking the standalone Wasm libc shim.
Odin allocations use the same Emscripten heap, including the temporary arena.
`web/odin_env.js` declares only the Odin JS imports used by this app; other
unresolved symbols remain link errors.
