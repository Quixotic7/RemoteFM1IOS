// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 RemoteFM1 contributors
// RFMCore: RemoteLink and the M1 producer (see include/RFMCore.h). M3: an engine (RFMEngine.cpp) can take the link
// over (rfmc_set_external): the producer then neither pops the panel's events nor publishes, and the engine reports
// what it applied back here for the app's Panel card. M4: the lease (rfmc_set_lease, rfmc_claim) and the shared fake.
#include "RFMCore.h"
#include "RFMInternal.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <mutex>
#include <thread>
#include <vector>

#include "RemoteLink.h"
#include "patterns.h"
#include "rfm/fake.h"
#include "SharedFake.h"

// the matrix id at (packed row bit, column), -1 none: felucca-bsp's FM1_KEYMAP (Leo Kuroshita, Hügelton Instruments,
// MPL-2.0) as RemoteFM1's firmware/src/rfm_main.c has it. Note key k is id 14 + k, matrix button b is id b.
static const int8_t kKeymap[6][RFM_NCOL] = {
    {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1}, {5, 11, 4, 10, 3, 9, 2, 8, -1, -1, -1},
    {34, 35, 36, 37, 38, 40, 39, 13, 7, 6, 12},   {23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33},
    {0, 1, 15, 14, 17, 16, 19, 18, 20, 21, 22},     {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
};

static void ledOn(uint8_t *plane, int id)
{
    for (int r = 1; r < 5; r++)
        for (unsigned c = 0; c < RFM_NCOL; c++)
            if (kKeymap[r][c] == id)
                plane[c] |= (uint8_t)(1u << r);
}

static bool ledIs(const uint8_t *plane, int id)
{
    for (int r = 1; r < 5; r++)
        for (unsigned c = 0; c < RFM_NCOL; c++)
            if (kKeymap[r][c] == id)
                return (plane[c] >> r) & 1u;
    return false;
}

static uint16_t slot(uint32_t r, uint32_t g, uint32_t b)   // RGB565, its bytes big-endian in memory (emu_hal_t.lcd)
{
    const uint32_t v = (r >> 3) << 11 | (g >> 2) << 5 | b >> 3;
    uint16_t s;
    uint8_t *p = reinterpret_cast<uint8_t *>(&s);
    p[0] = (uint8_t)(v >> 8);
    p[1] = (uint8_t)v;
    return s;
}

static void rect(uint16_t *f, int x, int y, int w, int h, uint16_t c)
{
    for (int j = y < 0 ? 0 : y; j < y + h && j < (int)RFM_H; j++)
        for (int i = x < 0 ? 0 : x; i < x + w && i < (int)RFM_W; i++)
            f[j * (int)RFM_W + i] = c;
}

struct rfmc {
    explicit rfmc(const RemoteLink::Options &o) : link(o), t0(std::chrono::steady_clock::now()) {}

    // M4: the lease (declared before the link: the link's last stop still reads them)
    std::atomic<rfml_t *> lease{nullptr};
    std::atomic<uint32_t> lastBeat{0};

    RemoteLink link;
    uint32_t period = 50;
    std::chrono::steady_clock::time_point t0;
    std::atomic<bool> pattern{true};

    std::thread th;
    std::mutex mu;                              // want / quit, the condition variable
    std::condition_variable cv;
    bool want = false, quit = false;

    // the producer's own
    uint16_t lcd[RFM_W * RFM_H] = {};
    rfm_leds_t leds{};
    uint32_t frameNo = 0, keys = 0, buttons = 0;
    int32_t master = -1;

    // shared with the readers (pmu)
    std::mutex pmu;
    std::vector<uint16_t> preview = std::vector<uint16_t>(RFM_W * RFM_H);
    uint32_t previewSeq = 0, evSeq = 0;
    std::deque<rfmc_event_t> log;               // the last kLog events
    static constexpr size_t kLog = 64;
    std::atomic<uint32_t> aKeys{0}, aButtons{0};
    std::atomic<int32_t> aMaster{-1};

    // M3: an engine drives the link. The producer holds xmu while it drains or publishes, and checks `external`
    // under it; rfmc_set_external takes xmu, so once it returns the producer has stood aside.
    std::mutex xmu;
    std::atomic<bool> external{false};
    rfm::Spsc<rfm_event_t, 256> xEvents;       // the engine's clock thread -> rfmc_events (the main thread)
    std::atomic<uint32_t> xDropped{0};

    uint32_t now() const
    {
        return (uint32_t)std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0)
            .count();
    }

    void note(const rfm_event_t &e)
    {
        std::lock_guard<std::mutex> g(pmu);
        rfmc_event_t r{};
        r.seq = ++evSeq;
        r.type = e.type;
        r.index = e.index;
        r.source = e.source;
        r.value = e.value;
        log.push_back(r);
        if (log.size() > kLog)
            log.pop_front();
    }

    // the panel's events (FM1VST's audio thread pops them the same way); true if a held key / button changed
    bool drain()
    {
        bool changed = false;
        rfm_event_t e;
        while (link.popEvent(e)) {
            switch (e.type) {
            case RemoteLink::kEvRelease:
                if (keys || buttons) {
                    keys = buttons = 0;
                    changed = true;
                    note(e);
                }
                continue;
            case RFM_EV_KEY:
                if (e.index < RFM_NKEYS) {
                    keys = e.value ? keys | 1u << e.index : keys & ~(1u << e.index);
                    changed = true;
                }
                break;
            case RFM_EV_BUTTON:
                if (e.index < RFM_NBTN) {
                    buttons = e.value ? buttons | 1u << e.index : buttons & ~(1u << e.index);
                    changed = true;
                }
                break;
            case RFM_EV_MASTER:
                master = e.value;
                break;
            default:
                break;
            }
            note(e);
        }
        for (RemoteLink::MidiMsg m; link.popMidi(m);) {}   // (TRS MIDI in: no core here, dropped)
        aKeys.store(keys);
        aButtons.store(buttons);
        aMaster.store(master);
        return changed;
    }

    // one screen and its LEDs: the pattern (or a still screen), the held keys and buttons over it
    void render(uint32_t t)
    {
        if (pattern.load()) {
            pattern_frame(lcd, t, frameNo++);
            pattern_leds(&leds, t);
        } else {
            rect(lcd, 0, 0, RFM_W, RFM_H, slot(16, 18, 24));
            rect(lcd, 0, 0, RFM_W, 4, slot(255, 140, 40));
            std::memset(&leds, 0, sizeof leds);
            for (unsigned c = 0; c < RFM_NCOL; c++)
                leds.faint[c] = 0x1E;
        }
        if (keys || buttons) {                  // held: every LED faint, the held ones lit
            std::memset(&leds, 0, sizeof leds);
            for (unsigned c = 0; c < RFM_NCOL; c++)
                leds.faint[c] = 0x1E;
            for (unsigned k = 0; k < RFM_NKEYS; k++)
                if (keys >> k & 1u)
                    ledOn(leds.lit, 14 + (int)k);
            for (unsigned b = 0; b < RFM_NBTN; b++)
                if (buttons >> b & 1u)
                    ledOn(leds.lit, (int)b);
        }
        // the strip: buttons 0..13, then keys 0..26 (held: lit)
        rect(lcd, 0, 200, RFM_W, 40, slot(8, 8, 10));
        for (int b = 0; b < (int)RFM_NBTN; b++)
            rect(lcd, 2 + b * 17, 205, 15, 12, buttons >> b & 1u ? slot(40, 200, 190) : slot(50, 54, 66));
        for (int k = 0; k < (int)RFM_NKEYS; k++)
            rect(lcd, 2 + k * 236 / 27, 222, 7, 14, keys >> k & 1u ? slot(255, 140, 40) : slot(50, 54, 66));
    }

    void show()
    {
        if (link.engaged()) {
            RemoteSnapshot &s = link.back();
            std::memcpy(s.lcd, lcd, sizeof lcd);
            s.leds = leds;
            s.seq++;
            link.publish();
        }
        std::lock_guard<std::mutex> g(pmu);
        std::memcpy(preview.data(), lcd, sizeof lcd);
        previewSeq++;
    }

    void threadMain()
    {
        for (;;) {
            {
                std::unique_lock<std::mutex> l(mu);
                cv.wait(l, [this] { return quit || want; });
                if (quit)
                    break;
            }
            uint32_t next = 0;
            for (;;) {
                {
                    std::lock_guard<std::mutex> l(mu);
                    if (quit || (!want && !link.engaged()))
                        break;
                }
                {
                    std::lock_guard<std::mutex> xg(xmu);
                    if (!external.load()) {
                        const bool changed = drain();
                        const bool full = link.takeFullRequest();
                        const uint32_t t = now();
                        if (changed || full || (int32_t)(t - next) >= 0) {
                            render(t);
                            show();
                            next = t + period;
                        }
                    }
                }
                std::unique_lock<std::mutex> l(mu);
                cv.wait_for(l, std::chrono::milliseconds(10), [this] { return quit; });
            }
            // the link let go: nothing is held any more
            std::lock_guard<std::mutex> xg(xmu);
            if (!external.load()) {
                drain();
                keys = buttons = 0;
                aKeys.store(0);
                aButtons.store(0);
                render(now());
                show();
            }
        }
    }
};

extern "C" {

rfmc_t *rfmc_new(const rfmc_cfg_t *cfg)
{
    RemoteLink::Options o;
    o.backend = cfg->backend == RFMC_FAKE ? RemoteLink::Backend::Fake : RemoteLink::Backend::Device;
    o.fakeBluetooth = cfg->fake_ble != 0;
    o.fps = cfg->fps ? cfg->fps : 20;
    o.lockPath = cfg->lock_path ? cfg->lock_path : "";
    o.hostName = cfg->host_name && *cfg->host_name ? cfg->host_name : "RemoteFM1 iOS";
    o.sharedFake = cfg->shared_fake != 0;
    o.fakeLabel = cfg->label ? cfg->label : "";
    rfmc_t *c = new rfmc(o);
    c->period = 1000u / (o.fps < 1 || o.fps > 60 ? 20u : o.fps);
    c->th = std::thread([c] { c->threadMain(); });
    return c;
}

void rfmc_free(rfmc_t *c)
{
    if (!c)
        return;
    if (rfml_t *l = c->lease.load())
        rfml_observe(l, nullptr, nullptr);      // (no notification handler runs once this returns)
    {
        std::lock_guard<std::mutex> l(c->mu);
        c->quit = true;
        c->want = false;
    }
    c->cv.notify_all();
    c->th.join();
    delete c;                                   // (~RemoteLink: SESSION 0, then its thread joined)
}

void rfmc_start(rfmc_t *c)
{
    {
        std::lock_guard<std::mutex> l(c->mu);
        c->want = true;
    }
    c->cv.notify_all();
    c->link.start();
}

void rfmc_stop(rfmc_t *c)
{
    c->link.stop();
    {
        std::lock_guard<std::mutex> l(c->mu);
        c->want = false;
    }
    c->cv.notify_all();
}

void rfmc_set_pattern(rfmc_t *c, int on) { c->pattern.store(on != 0); }

// ---- the lease
// the session thread, before it sends: the epoch still ours; the heartbeat about once a second
static bool leaseGate(void *ctx)
{
    rfmc *c = static_cast<rfmc *>(ctx);
    rfml_t *l = c->lease.load(std::memory_order_acquire);
    if (!l)
        return true;
    if (!rfml_current(l))
        return false;
    const uint32_t t = c->now();
    if (t - c->lastBeat.load(std::memory_order_relaxed) >= 1000u) {
        c->lastBeat.store(t, std::memory_order_relaxed);
        rfml_heartbeat(l);
    }
    return true;
}

// the session thread, the dropped run's links closed: the ack
static void leaseDropped(void *ctx)
{
    rfmc *c = static_cast<rfmc *>(ctx);
    if (rfml_t *l = c->lease.load())
        rfml_ack(l);
}

// the lease's notification (its own queue): an epoch newer than ours makes a running link drop (its thread acks);
// a link that isn't running acks here
static void leaseNotified(void *ctx)
{
    rfmc *c = static_cast<rfmc *>(ctx);
    rfml_t *l = c->lease.load();
    if (!l || !rfml_my_epoch(l) || rfml_current(l))
        return;
    if (c->link.wanted() || c->link.engaged())
        c->link.drop();
    else
        rfml_ack(l);
}

void rfmc_set_lease(rfmc_t *c, rfml_t *l)
{
    if (rfml_t *old = c->lease.exchange(l))
        rfml_observe(old, nullptr, nullptr);
    if (l) {
        c->link.setGate(leaseGate, leaseDropped, c);
        rfml_observe(l, leaseNotified, c);
    } else {
        c->link.setGate(nullptr, nullptr, nullptr);
    }
}

int rfmc_claim(rfmc_t *c, uint32_t wait_ms, rfml_claim_t *out)
{
    rfml_t *l = c->lease.load();
    if (!l) {
        rfmc_start(c);
        return 1;
    }
    if (!rfml_claim(l, wait_ms, out) || !rfml_current(l))
        return 0;
    c->lastBeat.store(c->now());
    rfmc_start(c);
    return 1;
}

void rfmc_drop(rfmc_t *c) { c->link.drop(); }

void rfmc_rescan(rfmc_t *c) { c->link.requestRescan(); }

static void copyStr(char *dst, size_t n, const char *src)
{
    std::strncpy(dst, src ? src : "", n - 1);
    dst[n - 1] = 0;
}

void rfmc_status(rfmc_t *c, rfmc_status_t *st)
{
    const RemoteLink::Status s = c->link.status();
    std::memset(st, 0, sizeof *st);
    st->state = s.state;
    st->session_state = s.state == RemoteLink::kOff ? -1 : s.sessionState;
    st->wanted = c->link.wanted();
    st->bulk = s.bulk;
    st->ble = s.ble;
    st->fps = s.fps;
    st->runs = s.runs;
    st->sessions = s.sessions;
    st->frames = s.frames;
    st->acks = s.acks;
    st->pending = s.pending;
    st->in_flight = s.inFlight;
    st->events_in = s.eventsIn;
    st->trs_midi_in = s.trsMidiIn;
    st->trs_midi_dropped = s.trsMidiDropped;
    st->events_dropped = s.eventsDropped;
    st->snapshots = s.snapshotsTaken;
    st->colors = s.colors;
    st->reduced = s.reduced;
    st->refined = s.refined;
    st->held = s.held;
    st->hold = s.hold;
    st->budget = s.budget;
    st->wire_bytes = s.wireBytes;
    st->body_bytes = s.bodyBytes;
    st->wire_cap = s.wireCap;
    st->frame_ms = s.frameMs;
    st->ack_ms_last = s.ackMsLast;
    st->ack_ms_avg = s.ackMsAvg;
    st->ack_ms_max = s.ackMsMax;
    st->ack_timeouts = s.ackTimeouts;
    st->discoveries = s.discoveries;
    st->drops = s.drops;
    st->gate_blocked = s.gateBlocked;
    copyStr(st->text, sizeof st->text, s.text.c_str());
    copyStr(st->log, sizeof st->log, s.lastLog.c_str());
    if (s.haveHello) {
        const rfm_hello_t &h = s.hello;
        st->have_hello = 1;
        st->hello_ble = rfm_hello_is_ble(&h);
        copyStr(st->name, sizeof st->name, h.name);
        copyStr(st->ver, sizeof st->ver, h.ver);
        copyStr(st->fw_ver, sizeof st->fw_ver, h.fw_ver);
        copyStr(st->identity, sizeof st->identity, h.identity);
        st->proto = h.proto;
        st->transports = h.transports;
        st->usb_mode = h.usb_mode;
        st->session = h.session;
        st->max_in_flight = h.max_in_flight;
        st->caps = h.caps;
        st->sxq = h.sxq;
        st->sx_body_max = h.sx_body_max;
        st->bk_body_max = h.bk_body_max;
        st->screen_w = h.screen_w;
        st->screen_h = h.screen_h;
    }
}

uint32_t rfmc_events(rfmc_t *c, uint32_t after, rfmc_event_t *out, uint32_t max)
{
    for (rfm_event_t e; c->xEvents.pop(e);)    // (an engine's: into the log as the producer's are)
        c->note(e);
    std::lock_guard<std::mutex> g(c->pmu);
    uint32_t n = 0;
    size_t first = 0;
    while (first < c->log.size() && c->log[first].seq <= after)
        first++;
    if (c->log.size() - first > max)
        first = c->log.size() - max;
    for (size_t i = first; i < c->log.size(); i++)
        out[n++] = c->log[i];
    return n;
}

void rfmc_panel(rfmc_t *c, uint32_t *keys, uint32_t *buttons, int32_t *master)
{
    if (keys)
        *keys = c->aKeys.load();
    if (buttons)
        *buttons = c->aButtons.load();
    if (master)
        *master = c->aMaster.load();
}

uint32_t rfmc_preview(rfmc_t *c, uint32_t have, uint8_t *rgba)
{
    std::lock_guard<std::mutex> g(c->pmu);
    if (c->previewSeq == have || !rgba)
        return c->previewSeq;
    const uint8_t *p = reinterpret_cast<const uint8_t *>(c->preview.data());
    for (uint32_t i = 0; i < RFM_W * RFM_H; i++, p += 2, rgba += 4) {
        const uint32_t v = (uint32_t)p[0] << 8 | p[1];
        const uint32_t r = v >> 11, g6 = (v >> 5) & 63u, b = v & 31u;
        rgba[0] = (uint8_t)(r << 3 | r >> 2);
        rgba[1] = (uint8_t)(g6 << 2 | g6 >> 4);
        rgba[2] = (uint8_t)(b << 3 | b >> 2);
        rgba[3] = 255;
    }
    return c->previewSeq;
}

void rfmc_fake_key(rfmc_t *c, uint32_t k, int down)
{
    c->link.withFake([&](rfm_fake *f) { if (f) rfm_fake_key(f, k, down); });
}

void rfmc_fake_button(rfmc_t *c, uint32_t b, int down)
{
    c->link.withFake([&](rfm_fake *f) { if (f) rfm_fake_button(f, b, down); });
}

void rfmc_fake_enc(rfmc_t *c, uint32_t e, int32_t detents)
{
    c->link.withFake([&](rfm_fake *f) { if (f) rfm_fake_enc(f, e, detents); });
}

void rfmc_fake_master(rfmc_t *c, uint32_t adc)
{
    c->link.withFake([&](rfm_fake *f) { if (f) rfm_fake_master(f, adc); });
}

void rfmc_fake_trs(rfmc_t *c, const uint8_t *msgs, uint32_t n)
{
    c->link.withFake([&](rfm_fake *f) { if (f && msgs) rfm_fake_trs(f, msgs, n); });
}

int rfmc_fake_state(rfmc_t *c, rfmc_fake_t *out)
{
    int ok = 0;
    std::memset(out, 0, sizeof *out);
    c->link.withFake([&](rfm_fake *f) {
        if (!f)
            return;
        rfm_fake_stats_t fs;
        rfm_fake_stats(f, &fs);
        out->session = rfm_fake_session(f);
        out->frames = fs.frames;
        out->acks = fs.acks;
        out->held_frames = fs.held_frames;
        out->hellos = fs.hellos;
        std::memcpy(out->lit, rfm_fake_leds(f)->lit, sizeof out->lit);
        ok = 1;
    });
    return ok;
}

int rfmc_fake_key_lit(rfmc_t *c, uint32_t k)
{
    rfmc_fake_t s;
    return rfmc_fake_state(c, &s) && k < RFM_NKEYS && ledIs(s.lit, 14 + (int)k);
}

int rfmc_fake_button_lit(rfmc_t *c, uint32_t b)
{
    rfmc_fake_t s;
    return rfmc_fake_state(c, &s) && b < RFM_NBTN && ledIs(s.lit, (int)b);
}

void rfmc_shared_fake(rfmc_shared_t *out)
{
    std::memset(out, 0, sizeof *out);
    const rfm::SharedFake::Record r = rfm::SharedFake::get().record();
    out->session = r.session;
    copyStr(out->last_starter, sizeof out->last_starter, r.lastStarter.c_str());
    out->starts = r.starts;
    out->frames = r.frames;
    out->acks = r.acks;
    out->open_ports = r.openPorts;
    for (const auto &x : r.senders) {
        if (out->nsenders >= 16)
            break;
        rfmc_sender_t &d = out->senders[out->nsenders++];
        copyStr(d.label, sizeof d.label, x.label.c_str());
        d.msgs = x.msgs;
        d.starts = x.starts;
        d.stops = x.stops;
        d.tiles = x.tiles;
        d.after_other = x.afterOther;
        d.after_other_tiles = x.afterOtherTiles;
    }
}

void rfmc_shared_fake_panel(uint8_t *rgba) { rfm::SharedFake::get().panelRGBA(rgba); }

} // extern "C"

// ---- M3: an engine on the link (RFMInternal.h)
RemoteLink *rfmc_link(rfmc_t *c) { return &c->link; }

void rfmc_set_external(rfmc_t *c, int on)
{
    {
        std::lock_guard<std::mutex> g(c->xmu);
        c->external.store(on != 0);
    }
    c->link.requestFull();                      // (the new source's first frame goes whole)
    c->cv.notify_all();
}

void rfmc_external_event(rfmc_t *c, const rfm_event_t &e)
{
    if (!c->xEvents.push(e))
        c->xDropped.fetch_add(1, std::memory_order_relaxed);
}

void rfmc_external_panel(rfmc_t *c, uint32_t keys, uint32_t buttons, int32_t master)
{
    c->aKeys.store(keys, std::memory_order_relaxed);
    c->aButtons.store(buttons, std::memory_order_relaxed);
    c->aMaster.store(master, std::memory_order_relaxed);
}
