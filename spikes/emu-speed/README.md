# emu-speed: fm1-emu's interpreter on the iPhone

How fast does [fm1-emu](https://github.com/joakimeriksson/fm1-emu) (Joakim Eriksson, MIT, pinned 5fbb066) run real
FM-1 update packages (`.fwsc`) without a JIT, as iOS requires, and what would make it fast enough?

**Short answer (measured, iPhone 13 Pro Max, A15, iOS 26.3, interpreter, 240 MHz):** Felucca 1.6.1 runs at
**0.79x idle / 0.74x chord** and ChoralRoot 0.27 (1-core build) at **0.73x / 0.69x**: under real time, so neither plays
on the iPhone at the FM-1's clock. The stock M-VAVE V15 runs at **3.0x / 1.4x**. ChoralRoot 0.25.1 does not run on
fm1-emu at all (it stalls at its splash on every host). Audio and LCD are bit-identical to the Mac's (hashes).
The interpreter is already a pre-decoded micro-op block interpreter, so there is no cheap 2x left in it; the biggest
lever measured is the emulated clock (Felucca and ChoralRoot spend most of their cycles waiting in busy loops).

## What is here

| path | what |
|---|---|
| `bench/` | `fm1bench`: a Rust staticlib (C entry `fm1b_bench`, `bench/include/fm1bench.h`) and a Mac CLI. It depends on fm1-emu's `fm1-core` and `fm1-soc` by path (the FM1VST emu worktree, read-only, unmodified). |
| `ios/` | `RFMBenchEmu` (bundle id `com.quixotic7.rfmbench.emu`): runs the bench at launch on a user-interactive thread, writes `Documents/results.txt`, shows it. `build.sh`, `run_device.sh`. |
| `fm1-emu-fork/` | a copy of `fm1-core` and `fm1-soc` (MIT, `LICENSE` kept) with the one prototype change measured below. |
| `tools/` | `mac_bench.sh` (the Mac table), `ab.sh` (interleaved A/B of builds), `leafprof.py` (xctrace leaf-pc profile by source line). |
| `build/` (git-ignored) | results, traces, DerivedData, and the packages (`build/fwsc/*.fwsc`: never tracked; the stock V15 is M-VAVE's). |

## The bench

As fm1-emu's own hosts drive it (`fm1-plugin/src/engine.rs`, `fm1-web/src/lib.rs`): `stock_from_package`,
`stock_boot`, cpu0 in user mode, `skip_idle` on, `machine::run_dual` + `run_blocks` in chunks of 20 000 cpu0
instructions, the audio taken out after each chunk. MASTER stays at fm1-soc's default (ADC ch 4 = 900).

- boot, settle 3 s of device time, 10 s idle, 10 s with C4 E4 G4 held (key ids 21 25 28, `Action::Key`, queued on the
  device clock through `fm1_soc::script` so every run and every build presses at the same cycle);
- x real time = device seconds / wall seconds of that phase; 3 runs, median;
- per phase: instructions per device second on each core, % of cycles skipped as idle, audio RMS and peak, LCD frames;
  at the end the LCD's lit pixels and an FNV hash of the frame buffer and of the audio (the first total − 1 s);
- a 4th "split" run of the stock V15 times cpu0 and cpu1 apart (a copy of `run_dual` with a clock around each core).

**Clock: 240 MHz.** fm1-soc's `CPU_HZ`, fm1-plugin's `MHZ`, fm1-live's default, the web page's guide ("The real FM-1
runs at 240 MHz") and the FM1VST glue (`(ms + 1) * 240e6 / 1000`) all use 240 MHz. The earlier evaluation note used
360 MHz (`--mhz=360`); the 360 MHz rows below are there to tie to it. fm1-soc counts one instruction per cycle.

**JIT off.** fm1-core compiles its JIT only for `target_arch = "aarch64", target_os = "macos"`; an iOS build has no JIT
code at all. Checked: `nm -u` of the iOS `libfm1bench.a` has no `mmap`, `mprotect`, `pthread_jit_write_protect_np` or
`sys_icache_invalidate` (the Mac binary has all four); the app's entitlements have no `allow-jit`. On the Mac,
`jit_on = false` never reaches `Jit::new`.

## Results

x real time (device s / wall s), median of 3 runs, 240 MHz unless noted. Mac: Apple M5 Max (Mac Studio), shared with
other agents (load 1.5-3 for these runs, up to 15 earlier; back-to-back sessions of the same build differed by up to
8%: Felucca's interpreter measured 1.23-1.41x). iPhone: QPhone64, iPhone 13 Pro Max (iPhone14,3), iOS 26.3, thermal
state 0 at start, the bench thread at user-interactive QoS. Raw output: `build/mac-*.txt`, `build/iphone-interp-240.txt`.

| package | Mac interp idle / chord | Mac JIT idle / chord | **iPhone interp idle / chord** | iPhone / Mac interp |
|---|---|---|---|---|
| Felucca 1.6.1 | 1.30 / 1.28 | 5.05 / 4.95 | **0.79 / 0.74** | 0.60 / 0.57 |
| stock V15 | 5.35 / 2.85 | 7.50 / 4.55 | **2.99 / 1.42** | 0.56 / 0.50 |
| ChoralRoot 0.25.1 | 99 / 101 (stalled) | 117 / 119 (stalled) | 41 / 42 (stalled) | - |
| ChoralRoot 0.27-1core | 1.36 / 1.26 | 5.02 / 5.09 | **0.73 / 0.69** | 0.53 / 0.55 |
| Felucca, 360 MHz | 0.95 / 0.95 | | | |
| V15, 360 MHz | 5.67 / 2.62 | | | |
| ChoralRoot 0.27-1core, 360 MHz | 0.93 / 0.88 | | | |

- iPhone per run: Felucca chord 0.81, 0.69, 0.74; ChoralRoot 0.70, 0.69, 0.68: the first run is the fastest (the phone
  warms; `thermalState` stayed 0, so this is the SoC's own sustained clock, not an iOS throttle state).
- Guest instructions per wall second: Mac interp ~300-330 M, iPhone 160-193 M (Felucca, ChoralRoot), V15 87-103 M.
- **Cores.** Felucca and ChoralRoot 0.27-1core never release core 1. Their core 0 executes 234.7-235.2 M instructions
  per device second at 240 MHz: only 2 % of cycles are skipped as idle. The stock V15 releases core 1: chord core 0
  30.4 M + core 1 41.3 M per device second, 87 % of core 0's cycles skipped. Split timing at chord: core 0 54 % / core 1
  46 % of wall on the Mac interpreter (JIT 62 / 38), **49 % / 51 % on the iPhone**.
- **Audio and LCD.** Every package that runs sounds (chord RMS: Felucca -26.0 dBFS peak 6571, V15 -32.0 peak 8199,
  ChoralRoot 0.27-1core -36.4 peak 5720) and draws (Felucca 57 600 lit px and 329 LCD frames in 10 s, V15 55 823 px,
  ChoralRoot 3 257 px). Idle is silent on all. Each package's audio and LCD hashes are the same in every run, on the Mac
  interpreter, the Mac JIT and the iPhone.
- **ChoralRoot 0.25.1** (and 0.24-beta3 and 0.27 dual-core builds, all tried): stuck at the splash with no audio on
  fm1-emu 5fbb066 on every host, as the FM1VST glue README found. Core 0 sits in `fm1__p33_xfer` / `fm1_p33_read`
  (pc 0x02001c22, called from 0x0201359e; in 0.27 0x02001c4e from 0x020136f2): the dual-core builds raise the core
  supply through the P33 PMU interface before they start core 1 (hal/fm1_power.h), and fm1-soc does not model P33, so
  core 1 is never released (0x10008 = 0) and the boot never finishes. The `-1core` builds skip that and run. Its
  "speed" rows are a stalled machine idle-skipping and mean nothing. The 0.27-1core build is used below as the
  ChoralRoot workload.

## Where the time goes (Mac, interpreter, chord held, 240 MHz)

Two views. **Host side**: xctrace Time Profiler (headless, 1 ms samples, 20 s of chord), each sample's leaf pc
symbolised with `atos -i` (inlined frames and source lines) and bucketed (`tools/leafprof.py`; `build/prof/*-leaf.txt`).
Line attribution of inlined code is approximate (skid), the buckets are good to a few %.

| bucket | Felucca | ChoralRoot 0.27-1core |
|---|---|---|
| block loop: load the op, pc and count, the branch-out test (`run_fast` 518-549) | 34.9 % | 38.6 % |
| execute handlers (`exec_fast` arms, `alu_f`, flags, pairs) | 28.7 % | 23.3 % |
| dispatch: the `match` on the micro-op (`exec_fast` 968) | 11.5 % | 12.9 % |
| block lookup (`block_at`: bmap, the XIP range test, block table) | 8.8 % | 10.1 % |
| memory access (RAM/XIP fast paths, MMIO slow path) | 6.9 % | 5.1 % |
| tick: the per-instruction cycle count and due test | 5.7 % | 7.1 % |
| peripherals / SoC service (timers, audio DMA, LCD, GPIO, SPI flash) | 2.5 % | 1.7 % |
| instruction fetch / decode (`decode_win`) | 0.1 % | 0.1 % |
| dual-core scheduling | 0 (one core) | 0.06 % |
| idle detection | ~0 (2 % of cycles skipped) | ~0 |

**The interpreter's design** (fm1-core): every instruction is decoded once into a cache line (`icache`, 2^18 lines)
holding a pre-resolved micro-op (`Fast`, ~70 kinds, operands and branch targets resolved); straight-line **blocks** of
up to 32 micro-ops are built on first use and found through a direct-mapped pc table (`bmap`). So there is no
per-instruction decode (0.1 %) and a block cache already exists. What remains per guest instruction is the loop around
it: one `match` dispatch, one tick (cycles += 1, compare with the next event), the budget and branch-out tests, and per
block a table lookup. Blocks are short: **3.74 guest instructions per block entry** on Felucca, 3.82 on ChoralRoot
(62 M block entries per device second), because a block ends at every branch. The slow path (`step` / `execute`) is
0.02-0.04 % of instructions. RAM blocks (V15 runs 29 % of its block entries from RAM) are compared byte for byte with
memory on every entry natively (12.5 M compares of 22.7 bytes in 4 s of V15 chord); the wasm build uses a write counter
instead. **The two cores interleave in lock-step**: core 0 runs 1024 instructions, then core 1 runs as many cycles as
passed (`run_dual`), on the one host thread; core 1 stops early when it is back at its start pc with the same
registers (a polling loop).

**Guest side** (`fm1bench --guest 97`: core 0 sampled every 97 instructions): Felucca is in an interrupt handler for
18 % of its instructions with the chord held (14 % idle), ChoralRoot 32 % (9.5 % idle). The rest is the main loop,
and in Felucca's source (main.c) that loop draws one UI frame and then spins `while (fm1_ms - m < 15) ui_input();`:
a busy wait that scans the key matrix over GPIO until 15 ms have passed. fm1-soc's idle skip only catches TIMER4 polls,
so the emulator executes the wait. That is why idle and chord cost the same, and why the clock matters (below).

## What would make it fast enough

Measured on the Mac (interleaved A/B, `tools/ab.sh`, `build/ab-*.txt`) and scaled to the iPhone by the measured
iPhone/Mac ratio of the unmodified build (0.55-0.60 for Felucca and ChoralRoot, 0.50-0.56 for V15). Rows marked
*estimate* were not run on the phone.

| change | what it costs | measured on the Mac | iPhone Felucca / ChoralRoot chord |
|---|---|---|---|
| none (today) | | | **0.74 / 0.69 measured** |
| **lower emulated clock** (a per-firmware setting, no code) | none, but the firmware gets fewer cycles | 240 -> 120 MHz: Felucca chord 1.35 -> 2.36-2.55x, ChoralRoot 1.18-1.28 -> 2.26-2.40x (x1.75-1.9) | ~1.3 / ~1.25 *estimate* |
| prototype: blocks continue past conditional branches + RAM-block write counter natively (`fm1-emu-fork`) | ~40 lines | Felucca +6 %, ChoralRoot +6-7 %, V15 +1 % (chord); identical audio and LCD hashes | ~0.78 / ~0.73 *estimate* |
| both | | Felucca 120 MHz: 2.65-2.72x (fork) vs 2.52-2.59x | ~1.35 / ~1.3 *estimate* |
| PGO (`-Cprofile-use`, Homebrew llvm@23 llvm-profdata) | build step | +1-4 %, within the noise | - |
| `-Ctarget-cpu=apple-m4` (Mac) | flag | no gain measurable (iOS builds default to apple-a7; apple-a15 not tried on the phone) | - |
| direct-threaded handlers (a handler pointer per pre-decoded op, operands unpacked, no `match`) | rewrite of ~70 micro-op kinds | not built | ~1.2-1.4x *estimate* |
| block chaining (successor block cached per exit) | small | not built | <= ~1.05x *estimate* (lookup is 9-10 %) |
| per-block tick accounting | | fm1-emu tried it: 5-7 % slower (PLAN 5.9) | - |
| faster memory paths | | already inlined RAM/XIP fast paths; the bucket is 5-7 % | <= ~1.05x |
| peripheral fast paths | | 2 % of time | ~0 |
| better idle skipping | firmware-specific | Felucca's wait loop scans keys (side effects): no generic skip; V15 already skips 87-89 % | ~0 generic |
| core 1 on a second host thread | sync every 1024 instructions (~4 us) | only V15 uses core 1 (46-51 % of wall); Felucca and ChoralRoot 0.27-1core: nothing | V15 up to ~1.8x in theory, less after the sync cost; 0 for the others |

Reasons:

- **The clock.** Felucca's and ChoralRoot's main loops spin until wall-clock time passes, so they use every cycle they
  are given; the work that must get done is the audio interrupt (18 % / 32 % of instructions at 240 MHz with the chord)
  plus the UI. At a lower clock the spin shrinks and the emulator does less. Swept on the Mac (one run each,
  `build/mhz-sweep.txt`): Felucca keeps the same chord level (-26.0 dBFS) and 154-164 LCD frames per 5 s from 240 down
  to 60 MHz (one odd row at 96 MHz: -30.9 dBFS); ChoralRoot keeps its level down to 96 MHz but loses voices at 80 MHz
  and below (-33 -> -37.6 dBFS, peak 6600 -> 3849) and its screen slows with the clock (69 LCD frames per 5 s at 240,
  42 at 120, 22 at 96): its UI drawing is CPU-bound. V15 already idles: its speed barely moves. So 120 MHz looks safe
  for both on these inputs, with ChoralRoot's UI at about 60 % of its frame rate; a heavier patch or more voices
  needs its own check. It is not the hardware's behaviour, and a firmware that times itself with instruction loops
  rather than timers would run slow.
- **The interpreter.** It already pre-decodes and caches blocks, so the "block cache" step is done. What is left is
  the per-instruction loop and dispatch (~47 % in the block-loop and dispatch buckets) and the per-block lookup
  (~10 %). The cheap part of that (longer blocks: 3.74 -> 4.48 instructions per entry on Felucca) gave 6 %. A direct-
  threaded rewrite attacks the 47 %; interpreters of this kind typically gain 1.2-1.5x from it, but Apple's indirect
  branch predictors already do well on the single `match`, so it is the uncertain one, and it is real work.
- **Dual core** only helps firmwares that use core 1 (V15 here; ChoralRoot's dual-core builds would, once fm1-emu runs
  them), and lock-step slices of 1024 instructions are too short for cross-thread handoff without loosening the timing.

**What the iPhone could run.** Measured: one Felucca or ChoralRoot instance at 240 MHz is 0.69-0.79x, so not even
one plays in real time; one V15 instance takes ~70 % of a P-core at chord (1.42x). Estimated: at 120 MHz one Felucca
or ChoralRoot instance would take ~75-80 % of one P-core, so **one instance**, perhaps two on the A15's two P-cores
with nothing else running (the four E-cores are far slower; the audio and UI threads need a share too). The prototype
adds ~6 %. Real-time use at the FM-1's own 240 MHz would need ~1.4x more interpreter speed than the threaded rewrite is
likely to give, or a JIT, which iOS forbids for App Store apps.

**What didn't work / wasn't done:** the first device attempt failed because the phone was locked (`Unable to launch
... because the device was not, or could not be, unlocked`, `build/iphone-attempt1-locked.txt`); the full run went
through once it was unlocked. The fork build and the 120 MHz build are built (`build/DerivedData-fork`,
`ios/run_device.sh iphone-interp-120.txt mhz=120 ...`) but the phone had locked again when they were due, so their
iPhone rows are estimates. PGO and target-cpu gave nothing measurable on this shared Mac.

## Build and run

```sh
cd spikes/emu-speed
cargo build --release                                   # Mac CLI (rustup's stable toolchain; Homebrew's rust has no iOS std)
target/release/fm1bench [--jit] [--mhz 240] [--runs 3] [--split] felucca=build/fwsc/felucca.fwsc ...
tools/mac_bench.sh                                      # the Mac table -> build/mac-*.txt
target/release/fm1bench --guest 97 ...                  # guest-side sample: in an ISR or not, hot pcs
cargo build --profile profiling && xcrun xctrace record --template 'Time Profiler' --no-prompt \
  --output build/prof/x.trace --launch -- target/profiling/fm1bench --runs 1 --idle 0 --chord 20000 felucca=...
xcrun xctrace export --input build/prof/x.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' --output build/prof/x.xml
python3 -I tools/leafprof.py build/prof/x.xml target/profiling/fm1bench
rustup target add aarch64-apple-ios
ios/build.sh                                            # FORK=1 links fm1-emu-fork instead
ios/run_device.sh iphone.txt [runs=N] [mhz=N] [only=felucca,cr027-1core] [split=0]
```

`run_device.sh` refuses a locked phone, takes the shared `iphone.lock` directory, installs, launches with
`--console` (the app exits when done), and copies `Documents/results.txt` to `build/`.
