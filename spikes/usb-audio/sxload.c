// sxload: a RemoteFM1 session with the real FM-1 that puts a known amount of screen traffic on the link, for the
// USB audio dropout measurement (README.md). libremotefm1 and its macOS back ends (vendor/, unmodified: host.c is
// compiled here with rfm_session_add_link / rfm_session_rx renamed to the taps below, so this tool can also send
// STATS on the unit's link and read STATS_R).
//
//   sxload --mode noise|gradient|static|leds|stats [--bps 280000] [--fps 20] [--seconds 30] [--transport midi|bulk]
//
//   noise     every frame a new full-screen noise image: the encoder sends as much as the budget allows
//   gradient  a scrolling gradient (cheaper tiles, still every tile changes)
//   static    one image, sent once, then nothing but keepalives / LEDs (once a second)
//   leds      the static image and an LED chase that changes every frame (panel traffic only)
//   stats     no session: HELLO only (the back end's discovery), then STATS
// --bps: the screen budget in body bytes a second (budget per frame = bps / fps), as RemoteFM1 for iOS sets it.
// SysEx only by default (the vendor bulk back end is not opened). One line a second: state, frames/s, body and wire
// bytes/s, ACK latency, frames in flight. Before and after: the unit's STATS (USB polls, loop time, sessions).
// Ends with SESSION 0 (the unit goes back to its waiting screen).
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

#include "remote_proto.h"
#include "rfm/macos.h"
#include "rfm/session.h"

static volatile int g_stop;
static void on_sig(int s) { (void)s; g_stop = 1; }
static struct timeval g_t0;
static uint32_t now_ms(void)
{
    struct timeval t;
    gettimeofday(&t, NULL);
    return (uint32_t)((t.tv_sec - g_t0.tv_sec) * 1000 + (t.tv_usec - g_t0.tv_usec) / 1000);
}

// ---- the taps (host.c calls these instead of the session's)
typedef struct {
    int kind, sid;
    rfm_write_fn w;
    void *ctx;
    rfm_rx_t *rx;
} tap_link_t;
static tap_link_t g_tl[RFM_MAX_LINKS];
static int g_ntl;
static uint32_t g_st[RF_ST_N], g_st_n, g_st_seen;

static void tap_msg(void *ctx, uint8_t cmd, const uint8_t *b, uint32_t n)
{
    (void)ctx;
    if (cmd != RFM_STATS_R || n < 1)
        return;
    uint32_t k = b[0];
    if (k > RF_ST_N)
        k = RF_ST_N;
    for (uint32_t i = 0; i < k && 1 + 4 * i + 3 < n; i++)
        g_st[i] = (uint32_t)b[1 + 4 * i] | (uint32_t)b[2 + 4 * i] << 8 | (uint32_t)b[3 + 4 * i] << 16 |
                  (uint32_t)b[4 + 4 * i] << 24;
    g_st_n = k;
    g_st_seen++;
}

int tap_add_link(rfm_session_t *s, int kind, rfm_write_fn w, void *ctx, const char *name)
{
    const int id = rfm_session_add_link(s, kind, w, ctx, name);
    if (id >= 0 && g_ntl < RFM_MAX_LINKS) {
        tap_link_t *t = &g_tl[g_ntl++];
        t->kind = kind, t->sid = id, t->w = w, t->ctx = ctx;
        t->rx = rfm_rx_new(kind, 4096, tap_msg, NULL, t);
    }
    return id;
}

void tap_rx(rfm_session_t *s, int id, const uint8_t *p, uint32_t n, uint32_t now)
{
    for (int i = 0; i < g_ntl; i++)
        if (g_tl[i].sid == id)
            rfm_rx_feed(g_tl[i].rx, p, n);
    rfm_session_rx(s, id, p, n, now);
}

static void send_stats(rfm_session_t *s)
{
    uint8_t f[16];
    int id = s ? rfm_session_midi_link(s) : -1;
    for (int i = 0; i < g_ntl; i++) {
        if (g_tl[i].kind != RFM_LINK_SX || (id >= 0 && g_tl[i].sid != id))
            continue;
        const uint32_t n = rfm_sx_frame(RFM_STATS, NULL, 0, f);
        g_tl[i].w(g_tl[i].ctx, f, n);
    }
}

static void print_stats(const char *when)
{
    if (!g_st_n) {
        fprintf(stderr, "sxload: unit STATS %s: none received\n", when);
        return;
    }
    fprintf(stderr,
            "sxload: unit STATS %s: up %.1f s, sessions %u, polls/s main %u isr %u, USB %u permille, loops/s %u, "
            "loop max %u us, sx rx/s %u, ep1 rx %u, sx ovf %u held %u, midi in dropped %u, frames %u, decode errs %u, "
            "push max %u us, usb resets %u\n",
            when, g_st[RF_ST_UPTIME_MS] / 1000.0, g_st[RF_ST_SESSIONS], g_st[RF_ST_POLLS_MAIN_PS],
            g_st[RF_ST_POLLS_ISR_PS], g_st[RF_ST_USB_PERMILLE], g_st[RF_ST_LOOPS_PS], g_st[RF_ST_LOOP_MAX_US],
            g_st[RF_ST_SX_RX_PS], g_st[RF_ST_EP1_RX], g_st[RF_ST_SX_OVF], g_st[RF_ST_SX_HELD],
            g_st[RF_ST_MIDI_IN_DROPPED], g_st[RF_ST_FRAMES], g_st[RF_ST_DECODE_ERRS], g_st[RF_ST_PUSH_US_MAX],
            g_st[RF_ST_USB_RESETS]);
}

// ---- screens
static uint32_t g_rng = 12345;
static uint32_t rnd(void)
{
    g_rng ^= g_rng << 13;
    g_rng ^= g_rng >> 17;
    g_rng ^= g_rng << 5;
    return g_rng;
}
static uint16_t g_lcd[RFM_W * RFM_H];
static void draw(const char *mode, uint32_t frame)
{
    if (!strcmp(mode, "noise")) {
        for (uint32_t i = 0; i < RFM_W * RFM_H; i++)
            g_lcd[i] = (uint16_t)rnd();
    } else if (!strcmp(mode, "gradient")) {
        for (uint32_t y = 0; y < RFM_H; y++)
            for (uint32_t x = 0; x < RFM_W; x++) {
                const uint32_t r = (x + frame * 3) & 31, g = (y * 2 + frame) & 63, b = ((x + y) / 2 + frame) & 31;
                g_lcd[y * RFM_W + x] = (uint16_t)(r << 11 | g << 5 | b);
            }
    } else if (frame == 0) {                            // static / leds: a fixed picture (bars and a frame)
        for (uint32_t y = 0; y < RFM_H; y++)
            for (uint32_t x = 0; x < RFM_W; x++)
                g_lcd[y * RFM_W + x] = (uint16_t)(x < 4 || y < 4 || x > RFM_W - 5 || y > RFM_H - 5 ? 0xFFFF
                                                  : ((x / 30) & 1) ? 0x001F << ((y / 80) * 5) : 0x0000);
    }
}

static void cb_state(void *ctx, int st, const char *why)
{
    (void)ctx;
    fprintf(stderr, "[%7.3f] session: %s (%s)\n", now_ms() / 1000.0, rfm_session_state_name(st), why);
}
static rfm_mac_t *g_mac;
static void cb_rescan(void *ctx)
{
    (void)ctx;
    if (g_mac)
        rfm_mac_rescan(g_mac);
}
static void cb_log(void *ctx, const char *m)
{
    (void)ctx;
    fprintf(stderr, "[%7.3f] %s\n", now_ms() / 1000.0, m);
}
static void mac_log(void *ctx, const char *m) { cb_log(ctx, m); }

int main(int argc, char **argv)
{
    const char *mode = "noise";
    uint32_t bps = 280000, fps = 20, seconds = 30;
    int transport = RFM_T_MIDI;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--mode") && i + 1 < argc) mode = argv[++i];
        else if (!strcmp(argv[i], "--bps") && i + 1 < argc) bps = (uint32_t)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--fps") && i + 1 < argc) fps = (uint32_t)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = (uint32_t)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--transport") && i + 1 < argc)
            transport = !strcmp(argv[++i], "bulk") ? RFM_T_BULK : RFM_T_MIDI;
        else {
            fprintf(stderr, "usage: sxload --mode noise|gradient|static|leds|stats [--bps N] [--fps N] "
                            "[--seconds N] [--transport midi|bulk]\n");
            return 2;
        }
    }
    gettimeofday(&g_t0, NULL);
    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);
    const int stats_only = !strcmp(mode, "stats");

    rfm_session_cfg_t sc;
    rfm_session_cfg_default(&sc);
    sc.fps = fps;
    sc.budget = bps / fps;
    sc.transport = transport;
    sc.host_name = "sxload";
    rfm_session_cb_t cb = {NULL, NULL, cb_state, cb_rescan, cb_log};
    rfm_session_t *s = rfm_session_new(&sc, &cb);
    rfm_mac_cfg_t mc;
    memset(&mc, 0, sizeof mc);
    mc.allow_devices = 1;
    mc.port_filter = "FM-1";
    mc.use_midi = 1;
    mc.use_bulk = transport == RFM_T_BULK;
    mc.log = mac_log;
    char err[256] = "";
    g_mac = rfm_mac_new(&mc, err, sizeof err);
    if (!g_mac) {
        fprintf(stderr, "sxload: %s\n", err);
        return 1;
    }
    rfm_mac_attach(g_mac, s);
    fprintf(stderr, "sxload: mode %s, budget %u B/frame x %u fps = %u B/s, %s, %u s\n", mode, sc.budget, fps,
            sc.budget * fps, transport == RFM_T_BULK ? "bulk" : "SysEx only", seconds);

    // STATS before (on every SysEx link the back end found; only the unit answers)
    {
        const uint32_t t = now_ms();
        send_stats(NULL);
        while (!g_st_seen && now_ms() - t < 1500) {
            rfm_mac_pump(g_mac, now_ms());
            if (!stats_only)
                rfm_session_poll(s, now_ms());
            rfm_mac_wait(g_mac, 5);
        }
        print_stats("before");
        if (stats_only) {
            rfm_session_stop(s, now_ms());
            rfm_mac_free(g_mac);
            rfm_session_free(s);
            return 0;
        }
    }

    uint32_t frame = 0, next_frame = 0, last = 0, t_active = 0, t_stop = 0;
    const uint32_t period = 1000u / fps;
    int stopping = 0;
    rfm_session_stats_t prev, st, at_active;
    memset(&prev, 0, sizeof prev);
    memset(&at_active, 0, sizeof at_active);
    rfm_leds_t leds;
    memset(&leds, 0, sizeof leds);
    for (;;) {
        const uint32_t now = now_ms();
        const int state = rfm_session_state(s);
        if (state == RFM_S_ACTIVE && !t_active) {
            t_active = now;
            rfm_session_stats(s, &at_active);
        }
        if (!stopping && (g_stop || (t_active && now - t_active >= seconds * 1000u) || now > (seconds + 15) * 1000u)) {
            rfm_session_stats(s, &st);
            const double dt = (now - t_active) / 1000.0;
            if (t_active)
                fprintf(stderr,
                        "sxload: RESULT mode %s budget %u B/s: %.1f s active, %.1f frames/s, body %.0f B/s, wire %.0f "
                        "B/s, ACK mean %.1f ms max %u, timeouts %u, decode errs %u\n",
                        mode, sc.budget * fps, dt, (st.frames - at_active.frames) / dt,
                        (st.body_bytes - at_active.body_bytes) / dt, (st.wire_bytes - at_active.wire_bytes) / dt,
                        st.acks - at_active.acks ? (double)(st.ack_ms_sum - at_active.ack_ms_sum) /
                                                       (st.acks - at_active.acks) : 0.0,
                        st.ack_ms_max, st.ack_timeouts - at_active.ack_timeouts,
                        st.decode_errs - at_active.decode_errs);
            g_st_seen = 0;
            send_stats(s);
            const uint32_t t = now_ms();
            while (!g_st_seen && now_ms() - t < 1500) {
                rfm_mac_pump(g_mac, now_ms());
                rfm_session_poll(s, now_ms());
                rfm_mac_wait(g_mac, 5);
            }
            print_stats("after");
            rfm_session_stop(s, now_ms());
            stopping = 1;
            t_stop = now_ms();
        }
        if (stopping && (rfm_session_state(s) == RFM_S_STOPPED || now_ms() - t_stop > 1500))
            break;
        rfm_mac_pump(g_mac, now_ms());
        if (!stopping && state == RFM_S_ACTIVE && now >= next_frame) {
            draw(mode, frame);
            if (!strcmp(mode, "leds")) {
                memset(&leds, 0, sizeof leds);
                leds.lit[frame % RFM_NCOL] = 0x3F;
                leds.mid[(frame + 3) % RFM_NCOL] = 0x3F;
                leds.flags = (uint8_t)(frame & 1);
            }
            if (frame == 0 || strcmp(mode, "static"))
                rfm_session_set_frame(s, g_lcd);
            rfm_session_set_leds(s, &leds);
            frame++;
            next_frame = now + period;
        }
        rfm_session_poll(s, now_ms());
        if (!stopping && now - last >= 1000) {
            rfm_session_stats(s, &st);
            const double dt = (now - last) / 1000.0;
            const uint32_t acks = st.acks - prev.acks;
            fprintf(stderr, "[%7.3f] %-8s fps %4.1f  body %7.0f B/s  wire %7.0f B/s  ACK %5.1f ms  in flight %u  LEDS %u\n",
                    now / 1000.0, rfm_session_state_name(rfm_session_state(s)), (st.frames - prev.frames) / dt,
                    (st.body_bytes - prev.body_bytes) / dt, (st.wire_bytes - prev.wire_bytes) / dt,
                    acks ? (double)(st.ack_ms_sum - prev.ack_ms_sum) / acks : 0.0, st.in_flight,
                    st.leds_sent - prev.leds_sent);
            prev = st;
            last = now;
        }
        rfm_mac_wait(g_mac, 1);
    }
    fprintf(stderr, "sxload: session %s\n", rfm_session_state_name(rfm_session_state(s)));
    rfm_mac_free(g_mac);
    rfm_session_free(s);
    return 0;
}
