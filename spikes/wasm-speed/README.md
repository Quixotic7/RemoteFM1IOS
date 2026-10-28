# Spike: FM-1 cores as interpreted Wasm (speed)

Question: can a firmware core compiled to WebAssembly and run by an interpreter (iOS allows no JIT) keep up in real
time, and how much of the audio budget does it take compared with the same core native? This is the basis for an
importable ".rfm1" firmware file: a firmware's host build (the fm1core ABI 6 and FM1VST's glue) compiled to wasm32.

## What is here

| Path | What |
| --- | --- |
| `build_wasm.sh` | Felucca 1.6.1 and ChoralRoot 0.26.1 → `build/<id>.wasm` (emcc 6.0.13, `-O3`, `-sSTANDALONE_WASM`, no JS, 8 MiB fixed memory, MVP + sign-ext, sat-float-to-int, bulk memory) |
| `wasm/shim.c` | compiled into each module: the ABI as flat exports (`fm1w_init`, `fm1w_tick`, `fm1w_audio`, ..), `fm1w_alloc`, `fm1w_layout` |
| `host/wcore.{h,cpp}` | the host: loads a module in wasm3 (or WAMR), links the WASI stubs, checks the layout, gives FM1VST's `Device` an ordinary `fm1core_t` whose entry points call into the interpreter and whose `panel` / `keymap` point into linear memory |
| `host/bench.cpp` | the bench, the same loop for native and Wasm |
| `cores/` | the defines `fm1_add_core` would pass; `wasm_compat/os/lock.h` (ChoralRoot's emulator unit includes `<os/lock.h>`) |
| `ios/` | the iPhone app (`com.quixotic7.rfmbench.wasm`): runs the bench at launch, shows it, writes `Documents/results.txt` |
| `third_party/` | wasm3 v0.5.0 and WAMR 2.4.5, sources only (`PINS.txt`: commits) |

Nothing outside this folder is changed. The generated headers (fonts, tables) are copied from the app's core build
(`build/cores/src/cores/*/build/gen`, made by `scripts/build_cores.sh`) into `build/gen` on the first run.

## Build and run

    ./build_wasm.sh                                   # build/felucca.wasm, build/choralroot.wasm
    ./build_wamr.sh mac && ./build_wamr.sh ios        # optional: WAMR's fast interpreter
    WAMR=1 NATIVE_CORES="felucca choralroot" ./build_host.sh mac
    ./build/mac/rfmbench build                        # the Mac run (words: see host/bench.h)
    WAMR=1 NATIVE_CORES="felucca choralroot" ./build_host.sh ios
    ios/build_app.sh                                  # the app, signed for team NCX6SLSFQJ
    ios/run_on_iphone.sh [buf=512 ..]                 # install, run, copy back build/iphone_results.txt (unlock the phone first)

## The bench

FM1VST's `Device` (vendor/FM1VST/engine/device.cpp, as `RFMEngine` uses it): power-on from a fresh flash, then three
passes of: 3 s settle (untimed), 10 s idle, 10 s with D4 F#4 A4 held (velocity 100, core_bench's chord), release.
Host buffers of 128 frames at 48 kHz (2.667 ms) through `Device::render` (device clock, core, resampler). Per buffer
wall time → x real time (device s / wall s), % of the buffer (mean, p99, max). Median over the passes. One power-on
per core: a native core's globals cannot be reset in-process, so native and Wasm both run their passes after a single
boot. n > 1: n Wasm instances rendered one after another in each buffer (what one audio thread hosting n cores
spends), one pass. Checks: the chord's RMS, LCD updates and colours, and an FNV hash of every rendered sample.

**Native, wasm3 and WAMR render bit-identical audio** (the hash, with `-ffp-contract=off` on both sides), for both
cores.

## Results: Mac (M5 Max, CLI, 128-frame buffers)

`build/mac/results.txt`. % = share of one 2.667 ms buffer.

| core | engine | idle x RT | idle mean / p99 / max % | chord x RT | chord mean / p99 / max % |
| --- | --- | --- | --- | --- | --- |
| Felucca | native | 645 | 0.16 / 0.48 / 3.9 | 462 | 0.22 / 0.59 / 4.3 |
| Felucca | wasm3 | 40 | 2.5 / 6.5 / 12 | 28 | 3.6 / 8.8 / 14 |
| Felucca | WAMR fast | 34 | 3.0 / 9.0 / 15 | 23 | 4.3 / 11 / 25 |
| ChoralRoot | native | 130 (pass 1) / 870 | 0.77 / 4.1 / 8.4 (pass 1) | 359 | 0.28 / 0.41 / 0.95 |
| ChoralRoot | wasm3 | 14.5 (pass 1) / 67 | 6.9 / **40 / 81** (pass 1) | 15 | 6.7 / 11 / 14 (pass 1 max 49) |
| ChoralRoot | WAMR fast | 11.7 (pass 1) / 64 | 8.6 / 46 / 55 (pass 1) | 14 | 7.3 / 9.8 / 21 (pass 1 max 50) |

ChoralRoot redraws its screen in pass 1 (75 LCD updates) and not in passes 2–3 (a static screen after the first
chord), so its pass 1 is the representative one; Felucca's passes agree. A ChoralRoot screen update is ~1–2 ms
interpreted (about 10× native) and lands in one buffer: the p99/max above. The DSP (chord held) is 15–25× native.

Several instances, wasm3 (one pass, chord, mean / p99 %): Felucca 2: 7.5 / 21, 4: 14 / 35, 8: 28 / 68.
ChoralRoot 2: 13 / 16 (idle with redraws: p99 65, max 84), 4: 26 / 39 (redraws: 148 / 238), 8: 52 / 76 (redraws 275).
WAMR is 10–25 % slower than wasm3 throughout.

At 512-frame buffers (`buf=512`, the engine's buffer on the simulator), the redraw spike spreads: ChoralRoot wasm3
chord 6.5 / 14 / 15 %, idle 6.6 / 9.2 / 12 %; 4 instances 26 / 58 / 60 %.

Sizes: felucca.wasm 981,320 bytes, choralroot.wasm 1,194,623 bytes (both include the web unit's own exports and
data; not stripped beyond `-O3`). Linear memory 8 MiB per instance (~4 MiB used: data, bss, 1 MiB stack). Load
(parse + compile every function + instantiate): 10–14 ms wasm3, 13–18 ms WAMR; boot 0.2–0.4 ms.

## Results: iPhone 13 Pro Max (A15)

Not measured yet: the phone was locked at every attempt (`passcodeRequired: true`; launch refused with "Locked").
The app is installed; unlock the phone and run `ios/run_on_iphone.sh` (≈3–4 min), then `ios/run_on_iphone.sh buf=512`.

## What the ".rfm1" format must pin down (learned here)

- **No function pointers across the boundary.** In wasm32 the descriptor's entry points are table indices; neither
  wasm3 nor WAMR's public API calls a table slot. The module must export each entry point by name (`wasm/shim.c`).
  The Tier 2 map (`fm1param_t` get / set / text) has the same problem: it needs flat exports too (not done here).
- **Layout.** `fm1panel_t` has no pointers, so its wasm32 layout equals arm64's (checked by `fm1w_layout`). The
  descriptor's does not: every pointer and `size_t` is 32 bits (`fm1core_w32` in host/wcore.cpp). The format should
  specify offsets, or better a versioned export set and no descriptor read at all.
- **Imports.** Felucca needs WASI `fd_write`, `fd_read`, `fd_close`, `fd_seek` (printf and the unused file path);
  ChoralRoot also `clock_time_get`. The host stubs them (writes counted, files EBADF). A format should allow only a
  fixed import list and reject others.
- **Memory.** Fixed size, no growth (the host keeps raw pointers to the panel). Strings and buffers go through a
  scratch area from `fm1w_alloc`. Each instance is isolated: this replaces the 4-slot frameworks.
- **Features.** Build for MVP + sign-ext + sat-conversions + bulk memory (wasm3 0.5.0 lacks reference types, SIMD, tail calls).
- **Porting.** Felucca's web unit built unchanged. ChoralRoot's emulator unit needed one stand-in header
  (`<os/lock.h>`); its `<pthread.h>` is Emscripten's stub (the core-1 thread is never started).
  Melodee (swapcontext) was not tried.
