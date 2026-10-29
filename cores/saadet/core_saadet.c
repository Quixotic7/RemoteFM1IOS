/* SPDX-License-Identifier: GPL-3.0-only */
/* The Saadet core: Saadet (https://github.com/keremimo/saadet, the vendor/saadet submodule at v0.1.1; MPL-2.0 in its
 * fm1-base build, LICENSING.md) on fm1-base (vendor/fm1-base at Saadet's pin, tools/build_base.py: 6c0b47e4bfc5),
 * built with FM1VST's fm1-base glue (core-glue/fm1base, core-glue/plat/plat_glue.h), as core_amb.c is.
 *
 * The sources are those of Saadet's host simulator (./build.sh --host: fm1-base's tools/build.py build_host):
 * fm1-base's host/plat_host.c with the app (platform/app.c, Saadet's platform half: PLAT_HOST, as there) and the o2
 * unit platform/instrument.c (saadet_instrument.c: PLAT_HOST, MELODEE_RAM_AUDIO=1, as fm1.toml's o2_cflags). Here
 * plat_host.c (the script-driven simulator) is replaced, as for AMB-1, by fm1-base's device files without the
 * hardware: plat.h, the app's header, gfx.c, fm1b_config.h, storage.c (APP_STORE_MAP on the NOR image), announce.c
 * (nobody listening), panel.c, radio_none.c (no Bluetooth: the --no-ble host build's FM1B_BLE 0), plat_fm1.c,
 * lib/btdev.c (APP_BTDEV) and app.c. Saadet's overlay of fm1-base (tools/base_overlay.py) changes nothing these
 * compile on the host except panel.c's calibration save (HARDWARE CALIBRATION is not emulated) and plat_host.c's
 * script commands, so the files are fm1-base's as pinned.
 *
 * What differs from app.c's host build (its functions renamed below, ours after it):
 *   - the flash: app.c's host half keeps a 1 MiB array of its own (sd_nor); sd_flash / sd_read / sd_erase / sd_write
 *     here use the core's NOR image (core-glue/common/nor.c), which the host keeps: it is the device's flash, read in
 *     place (FL_XIP) as the device does.
 *   - the LEDs: app.c's host sd_lights draws nothing; here it keeps the lit plane and the three dim planes with their
 *     PWM duty masks, and the panel shows each LED at the brightest duty holding it (sd_core_leds_out), the steady
 *     level the device's scan makes of them.
 * The second core: instrument.c's host build sets MELODEE_DUAL_CORE 0 (the paired kernels render in order on one
 * thread); nothing of CPU1 (hardware/cpu1.h, cpu1_entry.S) is compiled. No swapcontext, threads or clocks.
 * The managers' SysEx (Saadet's editor, app_sysex) is not wired: SysEx in goes to the app's MIDI queue as other MIDI.
 *
 * SAADET_STORE (the store variant, cores/saadet/core.cmake): the same core id; the generated factory banks of
 * Roland, Sequential and Casio are replaced by empty ones (cores/saadet/store/). */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>                       /* before exit.h: its prototypes must not see the macros */
#include <string.h>
#include "fm1core.h"
#include "version.h"
#include "nor.h"
#include "fifo.h"
#include "ticks.h"
#include "panel.h"
#include "exit.h"
#include "env.h"                          /* getenv -> NULL: no environment in a core (common/env.h) */

#define APP_VERSION SAADET_APP_VERSION    /* the firmware's own version (core.cmake: "0.1.1") */
#include "fm1base_hal.h"

/* ---------------------------------------------------------------- the firmware --- */
#define __attribute__(x)                  /* (as the host simulator: .noinit / .pool sections) */
#include "plat.h"
#include "app.h"
#include "gfx.c"
#include "fm1b_config.h"
#include "sys_text.c"                     /* (unity.c: the platform's own screens' faces; panel.c uses them) */
#include "storage.c"
#define ANN_NAME APP_NAME " " APP_VERSION
#include "ann_words.h"
#include "announce.c"
static int ann_wire_send(const uint8_t *p, uint32_t n)   /* nobody reading: not sent */
{
    (void)p;
    (void)n;
    return 1;
}
#include "panel.c"
#include "radio_none.c"
/* felucca-bsp's ota.c, which plat_fm1.c's plat_host_read / plat_host_patience use: no update path here (a host pull
 * fails at once, as with no host listening) */
static uint32_t ota_try_ms = 5000u, ota_deadline;
static uint32_t ota_now_ms(void) { return fm1_ms; }
static int ota_read(uint32_t addr, uint8_t *dst, uint32_t len)
{
    (void)addr;
    (void)dst;
    (void)len;
    return -1;
}
#include "plat_fm1.c"
#include "btdev.c"
/* Saadet's platform half as its host build compiles it; its flash and LED functions are replaced below */
#define PLAT_HOST 1
#define sd_flash_ok sd_host_flash_ok
#define sd_flash sd_host_flash
#define sd_read sd_host_read
#define sd_erase sd_host_erase
#define sd_write sd_host_write
#define sd_lights sd_host_lights
#include "app.c"
#undef sd_flash_ok
#undef sd_flash
#undef sd_read
#undef sd_erase
#undef sd_write
#undef sd_lights
#undef PLAT_HOST
#undef __attribute__

/* the flash: the NOR image (app.c's data windows, sd_data_ok) */
int sd_flash_ok(void) { return 1; }
const uint8_t *sd_flash(uint32_t off) { return sd_data_ok(off, 1u) ? FL_XIP(off) : 0; }
int sd_read(uint32_t off, void *dst, uint32_t n) { return sd_data_ok(off, n) ? fm1nor_read(off, dst, n) : -1; }
int sd_erase(uint32_t off) { return (off & 4095u) || !sd_data_ok(off, 4096u) ? -1 : fm1nor_erase(off); }
int sd_write(uint32_t off, const void *src, uint32_t n)
{
    return sd_data_ok(off, n) ? fm1nor_prog_span(off, src, n) : -1;
}
/* the LEDs (the device's sd_lights: fm1_led, and the three dim planes and their masks, which the base's overlay of
 * fm1_input.h lights (SD_LED_PLANE) in the scan frames where !(sd_led_phase & mask), the phase moving once a scan
 * frame (~1 ms): a PWM duty of 1 / (mask + 1), 0xFF dark, that the eye sees as a steady level). Here they are kept
 * as they are and drawn as those levels (sd_core_leds_out, as FM1VST's Melodee glue draws the same planes): not
 * gated by a phase moving once a UI frame (15 ms), which lit a 1/4 plane one frame in four, a 1/2 one every other
 * frame: the keys and buttons flickered */
static uint8_t sd_core_dim[3][11], sd_core_mask[3] = {255u, 255u, 255u};
void sd_lights(const uint8_t *bright, const uint8_t *dim, const uint8_t *masks)
{
    uint32_t c, p;
    for (c = 0; c < 11u; c++)
        fm1_led[c] = bright[c];
    for (p = 0; p < 3u; p++) {
        for (c = 0; c < 11u; c++)
            sd_core_dim[p][c] = dim[p * 11u + c];
        sd_core_mask[p] = masks[p];
    }
}
/* plat_glue.h's fm1core_pl_out, its LEDs: fm1_led lit, else the brightest duty holding an LED (the overlay ORs the
 * planes in each scan frame, and the duties nest: the brightest one's frames). fm1-base's own planes too
 * (plat_lights' glow, plat_lights_mid), which Saadet does not use. Saadet has no PLAY green (common/panel.h
 * fm1p_leds_brightest: dark) */
static int sd_core_leds_out(fm1panel_t *p)
{
    const uint8_t *const planes[6] = {fm1_led, sd_core_dim[0], sd_core_dim[1], sd_core_dim[2], fm1_led_mid,
                                      fm1_led_dim};
    const uint8_t levels[6] = {FM1P_LED_LIT, fm1p_duty_level(sd_core_mask[0]), fm1p_duty_level(sd_core_mask[1]),
                               fm1p_duty_level(sd_core_mask[2]), FM1P_LED_MID,
                               (uint8_t)(fm1core_fb_dim_lo ? FM1P_LED_FAINT : FM1P_LED_DIM)};
    return fm1p_leds_brightest(p, planes, levels, 6);
}

/* ---------------------------------------------------------------- the hooks (plat_glue.h) --- */
#define FM1CORE_PL_NAME APP_NAME
#define FM1CORE_PL_UI_FRAME() app_frame()
#define FM1CORE_PL_UI_INPUT() app_input_only()
#define FM1CORE_PL_DIM_LEVEL (fm1core_fb_dim_lo ? FM1P_LED_FAINT : FM1P_LED_DIM)
#define FM1CORE_PL_DIM_ON 1
#define FM1CORE_PL_PALETTE APP_PALETTE
#define FM1CORE_PL_DEFAULT_MASTER 512     /* -> master_pos 2048, plat_fm1.c's */

int saadet_core_sync(void);               /* saadet_instrument.c: the rest's autosave and the settings, now */

static void fm1core_pl_flash_boot(void) {}
static void fm1core_pl_app_boot(void)    /* base/device/main_fm1.c fm1_main */
{
    app_init();
    radio_boot_note();
}
static void fm1core_pl_ui_start(void)
{
    lcd_fill(0, 0, 240, 240, 0);
    app_ui_init();
}
static void fm1core_pl_render(int32_t *lr, uint32_t n) { app_render(lr, n, APP_GAIN(master_pos)); }
static void fm1core_pl_master(int32_t knob)   /* main_fm1.c: MASTER's position 0..4092 */
{
    fm1core_fb_master_adc = knob / 16;
    if (!fm1_an.con)
        fm1_an.master = (uint16_t)fm1core_fb_master_adc;
    master_pos = remote.master >= 0 ? (uint32_t)remote.master : (uint32_t)(knob / 4);
}
static void fm1core_pl_loop(void) { ble_poll(); }
static void fm1core_pl_uboot_say(uint32_t left)
{
    if (left) {
        char d[4] = {(char)('0' + left), '.', '.', 0};
        app_say("UPDATE MODE IN", d);
    } else {
        app_say("UPDATE MODE", "CANCELLED");
    }
}
/* the device saves by itself (sound.c autosave_poll: once at rest, not while playing; persist.c settings_poll):
 * the same now */
static int fm1core_pl_sync(void) { return saadet_core_sync(); }
static void fm1core_pl_info(char *buf, uint32_t n)
{
    int e = -1, pl = -1;
    saadet_expect("engine", &e);
    saadet_expect("playing", &pl);
    snprintf(buf, n, "engine %d playing %d", e, pl);
}

/* fm1core_pl_out's LED planes (lit, glow; no FM1CORE_PL_MID_PLANE) -> sd_core_leds_out above */
#define fm1p_leds_planes(panel_, planes_, levels_, n_, green_) \
    ((void)(planes_), (void)(levels_), (void)(n_), (void)(green_), sd_core_leds_out(panel_))
#include "plat_glue.h"
#undef fm1p_leds_planes
#include "exit_end.h"
