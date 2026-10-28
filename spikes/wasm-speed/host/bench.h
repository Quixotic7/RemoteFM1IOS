// SPDX-License-Identifier: GPL-3.0-only
// The spike's bench (README.md): native vs interpreted Wasm cores through FM1VST's Device, as the app renders.
#pragma once
#ifdef __cplusplus
extern "C" {
#endif

// Runs the whole bench and returns the report (malloc'd text, the caller frees it). wasm_dir holds <id>.wasm.
// spec: NULL for the default (every core and engine built in, 3 runs, 1 instance; then wasm3 with 2/4/8 instances),
// or words: "cores=felucca,choralroot engines=native,wasm3,wamr runs=3 mruns=1 multi=2,4,8 idle=10 chord=10 settle=3"
// (runs: passes after one power-on; mruns: the same for the n > 1 instance runs).
// progress (may be NULL) gets each line as it is printed.
char *rfmbench_run(const char *wasm_dir, const char *spec, void (*progress)(const char *line));

#ifdef __cplusplus
}
#endif
