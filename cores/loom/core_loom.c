/* SPDX-License-Identifier: GPL-3.0-only */
/* The LOOM-8 core: LOOM-8 (https://github.com/charlesvestal/fm1-loom, the vendor/loom submodule at v0.9.3, by Charles
 * Vestal; MPL-2.0, with its base/ = fm1-base at d0133c2), built with FM1VST's fm1-base glue (core-glue/fm1base,
 * core-glue/plat/plat_glue.h), after FM1VST's own LOOM-8 0.6.1 core (core-glue/fm1base/core_loom.c).
 *
 * The sources are those of LOOM-8's host simulator (./build.sh --host: base/tools/build.py build_host): base's
 * host/plat_host.c with the app (app/app.c: the drawing, the engine, the project, the pages, the input, the user
 * sample bank) and the o2 units (fm1.toml: dsp/synth.c, drumline.c, digisophie.c, sample.c, fx.c, bench.c,
 * seq/pattern.c, seq/seq.c: loom_*.c). As in FM1VST's LOOM-8 core, the app is compiled on its device paths (PLAT_HOST
 * off: plat_fm1.c's, the voices' engine order and cost model; not host.c, the simulator's script commands and wall
 * clock), with fm1-base's device files for plat_host.c (plat.h, the app's header, gfx.c, fm1b_config.h, sys_text.c in
 * the app's faces, storage.c on the NOR image, announce.c with nobody listening, panel.c, radio_none.c: no Bluetooth
 * MIDI or audio, plat_fm1.c, lib/btdev.c for APP_BTDEV) and app/plat_loom.c (the hardware: supplies, crash record,
 * the second core) read from loom_plat.c (a clang VFS overlay, core.cmake). The o2 units are compiled as the host
 * build compiles them, with PLAT_HOST (loom_*.c: the simulator's voice order, the factory samples built in, without
 * the 909 hat).
 * Not built: backup and restore over USB (fm1.toml backup), the screen mirror, the managers' SysEx (the user sample
 * bank's page, app_sysex). */
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

#define APP_VERSION FM1CORE_VERSION       /* build.py --release 0.9.3: "0.9.3" (a release: two cores, DEBUG_BUILD 0) */
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
#include "btdev.c"
#include "app.c"                          /* (its app/plat_loom.c: loom_plat.c, the VFS overlay) */
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

static void fm1core_pl_flash_boot(void) {}
static void fm1core_pl_app_boot(void)    /* base/device/main_fm1.c fm1_main */
{
    app_init();                           /* the user bank, the project, the presets, the engine, the second core */
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
/* the lazy save now: ui.c's autosave (a change saved when stopped, not recording, nothing asked or listed, into the
 * project's slot) without its waits (FM1VST's LOOM-8 core); AUTOSAVE off or a project with no slot: only SAVE writes.
 * Playing, recording or asking: deferred */
static int fm1core_pl_sync(void)
{
    if (!ui.dirty || (proj.rsv[2] & AUTOSAVE_OFF) || proj_slot >= NPROJ)
        return 1;
    if (playing() || seq.rec || seq.rec_wait || ui.ask || lst.open || store_held)
        return 0;
    if (project_save(proj_slot) == 0)
        ui.dirty = 0;
    return !ui.dirty;
}
static void fm1core_pl_info(char *buf, uint32_t n)
{
    snprintf(buf, n, "page '%s' track %u scene %u playing %u slot %u dirty %u", ui_page_name(),
             (unsigned)proj.trk_sel + 1u, (unsigned)cur_scene() + 1u, (unsigned)playing(), (unsigned)proj_slot + 1u,
             (unsigned)ui.dirty);
}

#include "plat_glue.h"
#include "exit_end.h"
