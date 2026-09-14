// Explicitly satisfy Emscripten's symbol checker for the imports supplied by odin.js.
// The loader supplies the odin_env namespace directly; forwarding also supports env imports.
addToLibrary({
    write: (fd, ptr, length) => odinImports.odin_env.write(fd, ptr, length),
    rand_bytes: (ptr, length) => odinImports.odin_env.rand_bytes(ptr, length),
    time_now: () => odinImports.odin_env.time_now(),
});
