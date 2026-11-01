# wasm3 (vendored)

[wasm3](https://github.com/wasm3/wasm3) v0.5.0, commit 6b8bcb1e07bf26ebef09a7211b0a37a446eafd52, MIT ([LICENSE](LICENSE)),
copied from FM1VST's `third_party/wasm3` (branch `rfm1-target`, d5f8f64): `source/`'s `.c` and `.h` files
(its CMakeLists.txt, `extensions/` and `extra/` were left out there). The interpreter RemoteFM1 runs imported `.rfm1`
firmware in (docs/RFM1-FORMAT.md; RFMCore's `RFMWasmCore.cpp`).

Package.swift builds the twelve units `m3_{bind,code,compile,core,emit,env,exec,function,info,module,optimize,parse}.c`
with wasm3's release flags (-O3, -fomit-frame-pointer, no stack checks, DEBUG undefined: no tracing, no asserts), in
debug builds too: its interpreter relies on the optimiser's tail calls. The `m3_api_*` files (its own WASI, libc and
tracer) are not built; RFMWasmCore.cpp links the format's few WASI stubs itself. `include/CWasm3.h` only includes
`source/wasm3.h`.

## Local patches

Two changes. First, in `source/m3_core.c` `m3_Realloc` (2026-11-01, for Fantasy CFW firmwares of up to 512 MiB): a first
allocation (`i_ptr == NULL`, a module's linear memory) is `calloc (i_newSize, 1)` with no `memset`, so the system's
zero pages are handed out lazily and memory a firmware never touches costs no RAM. Before, `realloc` + `memset` made
every declared byte dirty at load. The whole patch:

```c
    if (UNLIKELY(i_newSize == i_oldSize)) return i_ptr;
+   if (i_ptr == NULL)
+       return calloc (i_newSize, 1);
    void * newPtr = realloc (i_ptr, i_newSize);
```

Second, `source/m3_config.h`: `d_m3MaxDuplicateFunctionImpl` 32 (was 3), the export names wasm3 keeps per function.
A toolchain that folds identical functions (several `return 0` entry points) gives one function four or more export
names; with 3, wasm3 lost the rest and the loader refused the file ("no export rfm1_flash_sync"), though the web
player runs it.
