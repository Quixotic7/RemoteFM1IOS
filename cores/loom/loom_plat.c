/* SPDX-License-Identifier: GPL-3.0-only */
/* LOOM-8's platform extras (app.h: "on the FM-1 in plat_loom.c, in the simulator in host.c") for the core, from
 * FM1VST's core-glue/fm1base/loom_plat.c (v0.6.1's), for v0.9.3. app/app.c includes app/plat_loom.c when PLAT_HOST is
 * off, as the core builds it (the device's code paths); plat_loom.c itself reads the hardware (felucca-bsp's supplies
 * and crash record, the 24 MHz timer around a render), so the compiler reads this file in its place (core.cmake: a
 * clang VFS overlay); every other file of LOOM-8 is compiled unmodified. The same names, as host.c simulates them:
 *
 * - THE SECOND CORE (fm1.toml cpu2 = true: fm1-base's device/cpu2.c on the FM-1, not built here): its job runs at
 *   once, in order, on the host's one thread, as host.c and the browser emulator run it (engine.c's split render, the
 *   same sums). Never given up or barred (no unit faults here).
 * - THE LOAD: the render is timed on the device's simulated 24 MHz clock, which does not move during a render: 0 %.
 * - The supplies as fm1-base's main_fm1.c sets them (VDC14 level 7: 1.60 V, SYSVDD level 15: 1.38 V), no crash
 *   recorded, and the store's copy before the current one read from the NOR image as plat_loom.c reads it. */

/* the second core (plat.h plat_cpu2_*), simulated: a job runs at once */
static int loom_c2_on;
int plat_cpu2_set(int on)
{
    loom_c2_on = on != 0;
    return 0;
}
int plat_cpu2_on(void) { return loom_c2_on; }
int plat_cpu2_run(void (*fn)(uint32_t), uint32_t arg)
{
    if (!loom_c2_on)
        return 0;
    fn(arg);
    return 1;
}
int plat_cpu2_wait(void) { return 0; }
void plat_cpu2_sync(void) {}
int plat_cpu2_busy(void) { return 0; }   /* (a job ran at once) */
int plat_cpu2_gave_up(void) { return 0; }
uint32_t plat_cpu2_bad(void) { return 0; }
int plat_cpu2_barred(void) { return 0; }
uint32_t plat_cpu2_stack(void) { return 0; }

/* the render's load (app_render): simulated time, 0 % */
uint32_t plat_cpu_peak_pct(void) { return 0; }
static uint32_t render_t0(void) { return fm1_ticks(); }
static uint32_t render_pct(uint32_t t0, uint32_t n)
{
    (void)t0;
    (void)n;
    return 0;
}
uint32_t plat_cycles(void) { return fm1_ticks(); }   /* the profiler's clock: the 24 MHz timer, as on the FM-1 */

/* the supplies as fm1_main sets them, the last crash: none */
int plat_vdc14_mv(void) { return 1250 + 50 * 7; }
int plat_sysvdd_mv(void) { return 930 + 30 * 15; }
int plat_last_crash(uint32_t v[5])
{
    (void)v;
    return 0;
}

/* the copy before the current one (storage.c keeps two), as plat_loom.c reads it */
int plat_store_load_prev(uint32_t obj, void *dst, uint32_t max)
{
    uint32_t i;
    st_hdr_t h;
    int cur;
    if (!flash_ok)
        return -1;
    cur = st_current(obj, &h);
    if (cur < 0 || st_head(obj, (uint32_t)!cur, &h) || st_body(obj, (uint32_t)!cur, &h))
        return -1;
    if (h.len > max)
        h.len = max;
    for (i = 0; i < h.len; i++)
        ((uint8_t *)dst)[i] = st_buf[i];
    return (int)h.len;
}
int loom_store_save(uint32_t obj, const void *src, uint32_t len) { return plat_store_save(obj, src, len); }

static void plat_loom_init(void) {}
