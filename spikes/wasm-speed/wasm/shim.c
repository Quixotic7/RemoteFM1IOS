/* SPDX-License-Identifier: GPL-3.0-only */
/* The fm1core ABI as flat Wasm exports (the spike's ".rfm1" entry points).
 *
 * Inside a Wasm module the descriptor's function pointers are indices into the module's function table, which
 * an interpreter's public API (wasm3's, WAMR's) does not let a host call by index. So the module exports one
 * function per entry point, each calling through the module's own descriptor: the host never dereferences a
 * function pointer, only reads data (strings, the panel, the keymap) out of linear memory at 32-bit offsets.
 *
 * Pointers in these exports are linear-memory offsets (wasm32: 32-bit); the host copies strings and buffers in
 * through fm1w_alloc. fm1w_layout() lets the host check fm1panel_t's and fm1core_t's offsets against its own
 * understanding (the panel has no pointers, so its layout is the same as on arm64; the descriptor is not). */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include "fm1core.h"

#define EXPORT(name) __attribute__((export_name(#name), used))

static const fm1core_t *C;

EXPORT(fm1w_get) uint32_t fm1w_get(uint32_t abi)
{
    C = fm1core_get(abi);
    return (uint32_t)(uintptr_t)C;
}
EXPORT(fm1w_alloc) uint32_t fm1w_alloc(uint32_t n) { return (uint32_t)(uintptr_t)malloc(n); }
EXPORT(fm1w_free) void fm1w_free(uint32_t p) { free((void *)(uintptr_t)p); }

/* layout: index -> value (sizes and offsets); -1 past the end */
EXPORT(fm1w_layout) int32_t fm1w_layout(int32_t i)
{
    static const int32_t L[] = {
        sizeof(fm1panel_t),
        offsetof(fm1panel_t, keys), offsetof(fm1panel_t, buttons), offsetof(fm1panel_t, keys_tap),
        offsetof(fm1panel_t, buttons_tap), offsetof(fm1panel_t, enc), offsetof(fm1panel_t, master),
        offsetof(fm1panel_t, key_vel), offsetof(fm1panel_t, key_lean), offsetof(fm1panel_t, led),
        offsetof(fm1panel_t, led_play_green), offsetof(fm1panel_t, lcd), offsetof(fm1panel_t, lcd_writes),
        offsetof(fm1panel_t, btn_id), offsetof(fm1panel_t, enc_id), offsetof(fm1panel_t, enc_dir),
        offsetof(fm1panel_t, ready),
        sizeof(fm1core_t),
        offsetof(fm1core_t, abi_version), offsetof(fm1core_t, id), offsetof(fm1core_t, name),
        offsetof(fm1core_t, version), offsetof(fm1core_t, source_url), offsetof(fm1core_t, family),
        offsetof(fm1core_t, license), offsetof(fm1core_t, gated), offsetof(fm1core_t, flash_size),
        offsetof(fm1core_t, button_names), offsetof(fm1core_t, params), offsetof(fm1core_t, nparams),
        offsetof(fm1core_t, panel), offsetof(fm1core_t, keymap), offsetof(fm1core_t, options),
        offsetof(fm1core_t, credits),
    };
    return i >= 0 && i < (int32_t)(sizeof L / sizeof L[0]) ? L[i] : -1;
}

/* the entry points (NULL in the descriptor: a no-op, or 0) */
EXPORT(fm1w_options) void fm1w_options(uint32_t path, int32_t no_flash, int32_t save, int32_t headless)
{
    C->options((const char *)(uintptr_t)path, no_flash, save, headless);
}
EXPORT(fm1w_boot_options) int32_t fm1w_boot_options(int32_t fail, uint32_t reason, int32_t stage)
{
    return C->boot_options ? C->boot_options(fail, (const char *)(uintptr_t)reason, stage) : 1;
}
EXPORT(fm1w_init) void fm1w_init(int32_t demo) { C->init(demo); }
EXPORT(fm1w_tick) void fm1w_tick(uint32_t ms) { C->tick(ms); }
EXPORT(fm1w_frame) void fm1w_frame(void) { C->frame(); }
EXPORT(fm1w_idle) void fm1w_idle(void) { C->idle(); }
EXPORT(fm1w_audio) void fm1w_audio(uint32_t out, uint32_t frames) { C->audio((int16_t *)(uintptr_t)out, frames); }
EXPORT(fm1w_midi_in) int32_t fm1w_midi_in(uint32_t pkt) { return C->midi_in(pkt); }
EXPORT(fm1w_midi_out_take) int32_t fm1w_midi_out_take(uint32_t pkt) { return C->midi_out_take((uint32_t *)(uintptr_t)pkt); }
EXPORT(fm1w_halted) int32_t fm1w_halted(void) { return C->halted ? C->halted() : 0; }
EXPORT(fm1w_shutdown) void fm1w_shutdown(void) { if (C->shutdown) C->shutdown(); }
EXPORT(fm1w_flash_stage) int32_t fm1w_flash_stage(uint32_t bytes, uint32_t n)
{
    return C->flash_stage((const uint8_t *)(uintptr_t)bytes, n);
}
EXPORT(fm1w_flash) uint32_t fm1w_flash(void) { return (uint32_t)(uintptr_t)C->flash(); }
EXPORT(fm1w_flash_dirty) uint32_t fm1w_flash_dirty(void) { return C->flash_dirty(); }
EXPORT(fm1w_flash_sync) int32_t fm1w_flash_sync(void) { return C->flash_sync(); }
EXPORT(fm1w_stats) void fm1w_stats(uint32_t shed, uint32_t cpu) { C->stats((uint32_t *)(uintptr_t)shed, (uint32_t *)(uintptr_t)cpu); }
EXPORT(fm1w_ui_info) void fm1w_ui_info(uint32_t buf, uint32_t n) { C->ui_info((char *)(uintptr_t)buf, n); }
