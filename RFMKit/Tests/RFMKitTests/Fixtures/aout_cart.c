// SPDX-License-Identifier: GPL-3.0-only
// A tiny cart with ten output channels (aout1, docs/RFM1-FORMAT.md section 9), made from RemoteFM1's ain_cart.c: the
// .rfm1 exports (no flash), rfm1_audio_out_info (10) and rfm1_audio_out. Every channel holds its own level, so a test
// sees where each lands: the master 1000 (left) and 2000 (right), channel c (3..10) c x 1000. It checks the host's
// calls itself: rfm1_audio_out right before rfm1_audio, the same frame count, its buffer zeroed; a wrong call turns
// the master's left to -1000 from then on. t_* for other hosts' tests.
// Rebuild: build_aout.sh (emcc)
#include <stdint.h>
#define EXPORT(n) __attribute__((export_name(n)))

static uint8_t panel[115384] __attribute__((aligned(8)));
static uint32_t desc[48];
static uint8_t arena[1 << 16] __attribute__((aligned(16)));
static uint32_t arena_at;
static const int32_t LAYOUT[] = { 115384, 0, 4, 8, 12, 16, 44, 48, 75, 102, 146, 148, 115348, 115352, 115366, 115373, 115380,
    192, 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 92, 96, 100, 104, 108, 188 };

EXPORT("rfm1_version") int32_t rfm1_version(void) { return 1; }
EXPORT("rfm1_get") int32_t rfm1_get(int32_t abi) {
    if (abi != 6) return 0;
    desc[0] = 6; desc[1] = (uint32_t)"aouttest"; desc[2] = (uint32_t)"Audio Out Test"; desc[3] = (uint32_t)"1.0";
    desc[5] = (uint32_t)"Other"; desc[6] = (uint32_t)"GPL-3.0-only";
    for (int i = 0; i < 14; i++) desc[9 + i] = (uint32_t)"B";
    desc[25] = (uint32_t)panel;
    return (int32_t)desc;
}
EXPORT("rfm1_layout") int32_t rfm1_layout(int32_t i) { return i >= 0 && i < (int32_t)(sizeof LAYOUT / 4) ? LAYOUT[i] : -1; }
EXPORT("rfm1_alloc") int32_t rfm1_alloc(int32_t n) { uint32_t p = (arena_at + 15) & ~15u; if (p + n > sizeof arena) return 0; arena_at = p + n; return (int32_t)(arena + p); }
EXPORT("rfm1_free") void rfm1_free(int32_t p) { (void)p; }
EXPORT("rfm1_options") void rfm1_options(int32_t a, int32_t b, int32_t c, int32_t d) { (void)a; (void)b; (void)c; (void)d; }
EXPORT("rfm1_boot_options") int32_t rfm1_boot_options(int32_t a, int32_t b, int32_t c) { (void)a; (void)b; (void)c; return 1; }
EXPORT("rfm1_init") void rfm1_init(int32_t demo) { (void)demo; }
EXPORT("rfm1_tick") void rfm1_tick(int32_t ms) { (void)ms; }
EXPORT("rfm1_idle") void rfm1_idle(void) {}

// ---- the outputs
static int16_t *aux;                            // rfm1_audio_out's buffer for the next rfm1_audio
static int32_t aux_frames, pending, out_calls, audio_calls, with_aux, errors, peak;

EXPORT("rfm1_audio_out_info") int32_t rfm1_audio_out_info(void) { return 10; }
EXPORT("rfm1_audio_out") void rfm1_audio_out(int32_t p, int32_t frames) {
    if (pending || frames <= 0 || frames > 4096) errors++;            // (twice without an rfm1_audio)
    aux = (int16_t *)p; aux_frames = frames; pending = 1; out_calls++;
    for (int i = 0; i < 8 * frames; i++) if (aux[i]) { errors++; break; }   // (the host zeroes it)
}
EXPORT("rfm1_audio") void rfm1_audio(int32_t out, int32_t frames) {
    int16_t *o = (int16_t *)out;
    if (pending && aux_frames != frames) errors++;                     // (a block of another size)
    for (int i = 0; i < frames; i++) {
        o[2 * i] = errors ? -1000 : 1000; o[2 * i + 1] = 2000;           // (a wrong call shows: the left flips)
        if (pending && i < aux_frames)
            for (int c = 0; c < 8; c++) aux[8 * i + c] += (int16_t)((c + 3) * 1000);   // (adds, as plat_usb_ch's apps)
    }
    if (pending) with_aux++;
    pending = 0; peak = 2000; audio_calls++;
}

static void fill_rect(int y0, int y1, int x1, uint16_t rgb) {
    uint16_t be = (uint16_t)((rgb >> 8) | (rgb << 8)), *lcd = (uint16_t *)(panel + 148);
    for (int y = y0; y < y1; y++) for (int x = 0; x < 240; x++) lcd[y * 240 + x] = x < x1 ? be : 0;
}
EXPORT("rfm1_frame") void rfm1_frame(void) {
    fill_rect(0, 200, 240, with_aux ? 0x07E0 : 0x2104);
    fill_rect(200, 240, (int)((int64_t)peak * 240 / 32768), 0xFFFF);
    (*(volatile uint32_t *)(panel + 115348))++;
}
EXPORT("rfm1_midi_in") int32_t rfm1_midi_in(int32_t p) { (void)p; return 1; }
EXPORT("rfm1_midi_out_take") int32_t rfm1_midi_out_take(int32_t p) { (void)p; return 0; }
EXPORT("rfm1_halted") int32_t rfm1_halted(void) { return 0; }
EXPORT("rfm1_shutdown") void rfm1_shutdown(void) {}
EXPORT("rfm1_flash_stage") int32_t rfm1_flash_stage(int32_t p, int32_t n) { (void)p; (void)n; return 0; }
EXPORT("rfm1_flash") int32_t rfm1_flash(void) { return 0; }
EXPORT("rfm1_flash_dirty") int32_t rfm1_flash_dirty(void) { return 0; }
EXPORT("rfm1_flash_sync") int32_t rfm1_flash_sync(void) { return 0; }
EXPORT("rfm1_stats") void rfm1_stats(int32_t a, int32_t b) { (void)a; (void)b; }
EXPORT("rfm1_ui_info") void rfm1_ui_info(int32_t a, int32_t b) { (void)a; (void)b; }

// the tests' way in
EXPORT("t_errors") int32_t t_errors(void) { return errors; }
EXPORT("t_out_calls") int32_t t_out_calls(void) { return out_calls; }
EXPORT("t_audio_calls") int32_t t_audio_calls(void) { return audio_calls; }
EXPORT("t_with_aux") int32_t t_with_aux(void) { return with_aux; }
