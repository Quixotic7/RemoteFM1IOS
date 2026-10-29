# wasm3 (vendored)

[wasm3](https://github.com/wasm3/wasm3) v0.5.0, commit 6b8bcb1e07bf26ebef09a7211b0a37a446eafd52, MIT ([LICENSE](LICENSE)),
copied unchanged from FM1VST's `third_party/wasm3` (branch `rfm1-target`, d5f8f64): `source/`'s `.c` and `.h` files
(its CMakeLists.txt, `extensions/` and `extra/` were left out there). The interpreter RemoteFM1 runs imported `.rfm1`
firmware in (docs/RFM1-FORMAT.md; RFMCore's `RFMWasmCore.cpp`).

Package.swift builds the twelve units `m3_{bind,code,compile,core,emit,env,exec,function,info,module,optimize,parse}.c`
with wasm3's release flags (-O3, -fomit-frame-pointer, no stack checks, DEBUG undefined: no tracing, no asserts), in
debug builds too: its interpreter relies on the optimiser's tail calls. The `m3_api_*` files (its own WASI, libc and
tracer) are not built; RFMWasmCore.cpp links the format's few WASI stubs itself. `include/CWasm3.h` only includes
`source/wasm3.h`.
