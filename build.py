#!/usr/bin/env python3
"""Build the app for Linux or the browser, without downloading dependencies."""

import argparse
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent


def run(*args):
    command = [str(arg) for arg in args]
    print(shlex.join(command), flush=True)
    subprocess.run(command, cwd=ROOT, check=True)


def tool(name):
    # Some shell profiles leave literal tildes in PATH; subprocesses do not expand them.
    search_path = os.pathsep.join(os.path.expanduser(p) for p in os.get_exec_path())
    path = shutil.which(name, path=search_path)
    if not path:
        raise RuntimeError(f"{name} not found; add it to PATH (see README.md)")
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    targets = parser.add_mutually_exclusive_group()
    targets.add_argument("-linux", dest="target", action="store_const", const="linux")
    targets.add_argument("-web", dest="target", action="store_const", const="web")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("-debug", dest="mode", action="store_const", const="debug")
    modes.add_argument("-release", dest="mode", action="store_const", const="release")
    parser.add_argument("-compile-sokol", action="store_true", help="rebuild required Sokol libraries")
    parser.set_defaults(target="linux", mode="debug")
    args = parser.parse_args()
    web = args.target == "web"
    debug = args.mode == "debug"
    if not web and (platform.system() != "Linux" or platform.machine() != "x86_64"):
        raise RuntimeError("The bundled native Sokol bindings require Linux x86-64")

    odin = tool("odin")
    cc, ar = (tool("emcc"), tool("emar")) if web else (tool("cc"), tool("ar"))
    odin_root = Path(subprocess.check_output([odin, "root"], text=True).strip())
    out = ROOT / "build" / args.target / args.mode
    out.mkdir(parents=True, exist_ok=True)
    cflags = ["-g", "-O0"] if debug else ["-O2", "-DNDEBUG"]
    libraries = []
    for name in ("app", "gfx", "glue"):
        suffix = "wasm" if web else "linux_x64"
        library = ROOT / "sokol" / name / f"sokol_{name}_{suffix}_gl_{args.mode}.a"
        if args.compile_sokol or not library.exists():
            obj = out / f"sokol_{name}.o"
            run(cc, "-c", *cflags, "-DIMPL", "-DSOKOL_GLES3" if web else "-DSOKOL_GLCORE",
                *([] if web else ["-pthread"]), f"sokol/c/sokol_{name}.c", "-o", obj)
            run(ar, "rcs", library, obj)
        libraries.append(library)

    run(ROOT / "sokol-shdc", "-i", "shader.glsl", "-o", "shader.odin",
        "-l", "glsl410:glsl300es", "-f", "sokol_odin")
    flags = ["-debug"] if debug else ["-o:speed"]
    flags += [f"-define:SOKOL_DEBUG={str(debug).lower()}"]
    if not web:
        run(odin, "build", ".", *flags, f"-out:{out / 'sokol-hello'}")
    else:
        obj = out / "app.wasm.o"
        run(odin, "build", ".", *flags, "-target:js_wasm32", "-build-mode:obj", f"-out:{obj}")
        stb = out / "stb_image.o"
        run(cc, "-c", *cflags, "-I", odin_root / "vendor/stb/src", "web/stb_image.c", "-o", stb)
        shutil.copyfile(odin_root / "core/sys/wasm/js/odin.js", out / "odin.js")
        run(cc, obj, stb, *libraries, "-o", out / "index.html",
            *(["-O0", "-g", "-sASSERTIONS=2"] if debug else ["-O2"]),
            "--shell-file", "web/index_template.html", "--no-entry",
            "-sEXPORTED_FUNCTIONS=['__start','__end']",
            "-sMIN_WEBGL_VERSION=2", "-sMAX_WEBGL_VERSION=2", "-sALLOW_MEMORY_GROWTH=1",
            "-sEXIT_RUNTIME=0", "-sSTACK_SIZE=1048576",
            "--js-library", "web/odin_env.js")
    print(f"Built {out}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Build failed: {error}", file=sys.stderr)
        sys.exit(1)
