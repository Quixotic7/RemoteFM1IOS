/* fm1bench: fm1-emu (joakimeriksson/fm1-emu, MIT, 5fbb066) timed on a real .fwsc (bench/src/lib.rs). */
#pragma once
#include <stddef.h>
#include <stdint.h>

/* `runs` benches of the package pkg[0..len): boot, settle_ms of device time, idle_ms idle, chord_ms with C4 E4 G4
 * held, at `mhz`. jit is ignored where fm1-core's JIT is not compiled in (iOS). split: time cpu0 and cpu1 apart.
 * Writes a NUL-terminated report into out (cap bytes); log (may be NULL) gets each line as it is made.
 * Returns 0, or 1 after a panic. */
int32_t fm1b_bench(const uint8_t *pkg, size_t len, const char *name, uint32_t mhz, int32_t jit, uint32_t runs,
                   int32_t split, uint32_t settle_ms, uint32_t idle_ms, uint32_t chord_ms, uint8_t *out, size_t cap,
                   void (*log)(const char *line));

/* 1 when fm1-core's JIT is compiled into this build (macOS AArch64 only; never on iOS). */
int32_t fm1b_jit_compiled(void);
