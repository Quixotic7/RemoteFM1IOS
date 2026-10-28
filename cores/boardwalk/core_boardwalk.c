/* SPDX-License-Identifier: GPL-3.0-only */
/* The Boardwalk core: Boardwalk (https://github.com/charlesvestal/fm1-boardwalk, the vendor/boardwalk submodule at
 * v0.9, by Charles Vestal; MPL-2.0, with its base/ = fm1-base at 4587fda), built with FM1VST's fm1-base glue
 * (core-glue/fm1base, core-glue/plat/plat_glue.h) as core_amb.c is.
 *
 * The sources are those of Boardwalk's host simulator (./build.sh --host: base/tools/build.py build_host): base's
 * host/plat_host.c with the app (app/app.c and what it includes: the games, the scene, the art) and the o2 unit
 * app/dsp/bw.c (boardwalk_bw.c). plat_host.c (the script-driven simulator) is replaced, as for AMB-1, by fm1-base's
 * device files without the hardware: plat.h, the app's header, gfx.c, fm1b_config.h, sys_text.c, storage.c
 * (APP_STORE_MAP on the NOR image), announce.c (nobody listening), panel.c, radio_none.c (Boardwalk never enables the
 * radio: fm1.toml ble = false), plat_fm1.c and app.c (its device path: PLAT_HOST off, so no host test player). The
 * screen mirror (fm1.toml mirror = true: device/mirror.c, a computer viewing the screen over USB) is not built:
 * fm1base_hal.h's stand-ins, as for LOOM-8. The managers' SysEx is not wired. */
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

#define APP_VERSION FM1CORE_VERSION
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
static volatile uint8_t midi_usb_lost;  /* (usb.c: MIDI out found no host reading; a core's host always reads) */
#include "plat_fm1.c"
#include "app.c"
#undef __attribute__

/* ---------------------------------------------------------------- the hooks (plat_glue.h) --- */
#define FM1CORE_PL_NAME APP_NAME
#define FM1CORE_PL_UI_FRAME() app_frame()
#define FM1CORE_PL_UI_INPUT() app_input_only()
#define FM1CORE_PL_DIM_LEVEL (fm1core_fb_dim_lo ? FM1P_LED_FAINT : FM1P_LED_DIM)   /* the glow: DIM LO / HI */
#define FM1CORE_PL_DIM_ON 1
#define FM1CORE_PL_MID_PLANE fm1_led_mid  /* plat_lights_mid (felucca-bsp's steady mid level) */
#define FM1CORE_PL_PALETTE APP_PALETTE
#define FM1CORE_PL_DEFAULT_MASTER 512     /* -> master_pos 2048, plat_fm1.c's */
#define FM1CORE_PL_TICK_HOOK()                                                                                 \
    do {                                                                                                       \
        in_tick = 1;                                                                                           \
        app_tick();                       /* 1 kHz, in the timer interrupt on the device (the bells on time) */ \
        in_tick = 0;                                                                                           \
    } while (0)

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
static void fm1core_pl_loop(void) {}
static void fm1core_pl_uboot_say(uint32_t left)
{
    if (left) {
        char d[4] = {(char)('0' + left), '.', '.', 0};
        app_say("UPDATE MODE IN", d);
    } else {
        app_say("UPDATE MODE", "CANCELLED");
    }
}
/* the lazy save now (app_frame's: a while after a change, not while a game plays); deferred while one plays */
static int fm1core_pl_sync(void)
{
    if (!dirty)
        return 1;
    if (ui.game && ui.game->playing && ui.game->playing())
        return 0;
    dirty = 0;
    if (plat_store_save(OBJ_SAVE, &sav, sizeof sav) != 0)
        dirty = 1;
    return !dirty;
}
static void fm1core_pl_info(char *buf, uint32_t n)
{
    snprintf(buf, n, "cabinet %u in game %u tickets %u dirty %u", (unsigned)sav.cab, (unsigned)(ui.game != 0),
             (unsigned)sav.prize.tickets, (unsigned)dirty);
}

#include "plat_glue.h"
#include "exit_end.h"
